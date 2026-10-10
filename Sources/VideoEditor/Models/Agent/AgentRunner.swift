// AgentRunner.swift
//
// Agent 的执行循环：问模型 → 它要调工具 → 调完把结果回给它 → 再问，直到它不再要工具。
//
// 三件事在这里兜底：
//   · **整轮一个撤销点**。开跑前打一次快照，中间改多少地方都算一步，⌘Z 一次全回去
//   · 模式拦截。计划模式挡掉所有写操作，自动模式的危险操作先弹窗
//   · 步数上限。模型偶尔会绕圈子，不设上限就会一直烧 token

import Foundation
import SwiftUI

@MainActor
final class AgentRunner: ObservableObject {

    /// 这一轮的步骤、用时、花费（按会话取）。收尾写回会话时用 ——
    /// 不能用上面那几个 @Published，那是「界面正看着哪条」的镜像，用户切走了就是别人的
    func summary(of convID: UUID?) -> (steps: [Step], elapsed: TimeInterval, tokens: Int) {
        guard let convID, let st = states[convID] else { return ([], 0, 0) }
        return (st.steps, st.elapsed, st.totalTokens)
    }

    /// 气泡里要显示实时步骤，会话列表里每一条都得能观察到它，做成单例最省事
    static let shared = AgentRunner()

    /// 这一轮的步骤挂在哪条回复上。气泡靠它认领「我是正在跑的那条」
    @Published var runningMessageID: UUID?


    /// 一轮里发生过什么，给界面显示
    struct Step: Identifiable {
        let id = UUID()
        var toolName: String
        var summary: String
        var isError = false
        /// 调这一步时传了什么参数
        var args: String = ""
        /// 工具返回的完整内容。`summary` 只是它的头一截，展开时看这个
        var detail: String = ""
        /// 这一步之前模型说的话（它的思路）。有些轮次会先解释再动手
        var thinking: String = ""
        /// 这一步工具返回的图存在哪（截帧那类）。空 = 没有图
        var imagePath: String = ""
    }

    /// 工具返回的图落盘：步骤条展开时要显示，模型想在回复里给用户看也得有个路径
    static func saveStepImage(_ data: Data) -> String? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/agent-captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8)).jpg")
        do { try data.write(to: url); return url.path } catch { return nil }
    }

    // 下面这几个 @Published 是**当前正看着那条会话**的镜像。
    // 真身在 states 里按会话分开存 —— 一条会话在跑，不该让另一条的
    // 发送按钮变成「停止」，更不该点一下把别人的活儿停了
    @Published var isRunning = false
    @Published var steps: [Step] = []
    /// 这一轮跑了多久。计时器每 0.5 秒推一次
    @Published var elapsed: TimeInterval = 0
    /// 累计烧掉的 token。中转站不回 usage 的话会一直是 0，界面就不显示这段
    @Published var totalTokens = 0
    /// 此刻在干什么：「正在思考」还是「正在跑某个工具」
    @Published var phase = ""
    @Published var streamingText = ""
    /// 正等着用户点确认的那个工具调用
    @Published var pendingConfirm: PendingConfirm?
    /// 正等着用户选的那道选择题（ask_user）
    @Published var pendingQuestion: PendingQuestion?

    /// 一条会话跑一轮的全部状态
    private struct RunState {
        var isRunning = false
        var runningMessageID: UUID?
        var steps: [Step] = []
        var elapsed: TimeInterval = 0
        var totalTokens = 0
        var phase = ""
        var streamingText = ""
        var pendingConfirm: PendingConfirm?
        var pendingQuestion: PendingQuestion?
        /// 用户在这一轮跑着的时候又发来的话，等下一步之前塞给模型
        var queuedInputs: [String] = []
        var startedAt: Date?
        var task: Task<Void, Never>?
        var ticker: Timer?
    }
    private var states: [UUID: RunState] = [:]
    /// 界面正看着哪条会话
    private var visibleID: UUID?

    /// 切会话：把镜像换成那条自己的状态
    func switchTo(_ id: UUID?) {
        visibleID = id
        publish(id.flatMap { states[$0] } ?? RunState())
    }

    private func publish(_ st: RunState) {
        isRunning = st.isRunning
        runningMessageID = st.runningMessageID
        steps = st.steps
        elapsed = st.elapsed
        totalTokens = st.totalTokens
        phase = st.phase
        streamingText = st.streamingText
        pendingConfirm = st.pendingConfirm
        pendingQuestion = st.pendingQuestion
    }

    private func mutate(_ id: UUID, _ body: (inout RunState) -> Void) {
        var st = states[id] ?? RunState()
        body(&st)
        states[id] = st
        if id == visibleID { publish(st) }
    }

    /// 这一轮挂在哪条会话上。外部（聊天面板）设置正在跑的那条回复用
    func setRunningMessage(_ msgID: UUID?, in convID: UUID?) {
        guard let convID else { return }
        mutate(convID) { $0.runningMessageID = msgID }
    }

    struct PendingConfirm: Identifiable {
        let id = UUID()
        let toolName: String
        let detail: String
        let onAnswer: (Bool) -> Void
    }

    /// 一道选择题。`onAnswer(nil)` = 用户没答（按了停止）
    struct PendingQuestion: Identifiable {
        let id = UUID()
        let question: String
        let options: [String]
        let onAnswer: (String?) -> Void
    }

    /// 一轮最多让它调多少次工具。绕圈子的话到这就停。
    /// 走设置（AI → 通用 → 步数上限），每轮开跑时读一次
    private var maxSteps: Int { max(1, Int(AppSettings.shared.agentMaxSteps)) }

    /// 停的是**当前看着那条**的活儿
    /// 这一轮还在跑时用户又发了一句。不另起一轮，下一步之前交给模型，它自己决定怎么调整。
    /// 学的是 Claude Code：干活中途插话直接进当前这轮，而不是等它做完
    /// - Returns: 收下了返回 true；这条会话没在跑就是 false，调用方照常起一轮
    func enqueue(_ text: String, in convID: UUID?) -> Bool {
        guard let convID, states[convID]?.isRunning == true else { return false }
        mutate(convID) { $0.queuedInputs.append(text) }
        return true
    }

    /// 取走排着的话
    private func drainQueue(_ cid: UUID) -> [String] {
        let q = states[cid]?.queuedInputs ?? []
        if !q.isEmpty { mutate(cid) { $0.queuedInputs = [] } }
        return q
    }

    private static func queuedNote(_ q: [String]) -> String {
        "[你干活的时候用户又发来了话，看看要不要调整接下来的做法；跟前面冲突的以这几句为准]\n"
            + q.map { "「\($0)」" }.joined(separator: "\n")
    }

    func cancel() {
        guard let id = visibleID else { return }
        // 停了就不再塞，排着的话已经显示在会话里，下一轮会进历史
        states[id]?.queuedInputs = []
        // 正等着选的那道题先放掉，不然执行循环一直挂在那儿
        states[id]?.pendingQuestion?.onAnswer(nil)
        states[id]?.task?.cancel()
        states[id]?.ticker?.invalidate()
        mutate(id) {
            $0.task = nil
            $0.ticker = nil
            $0.isRunning = false
            $0.phase = ""
        }
    }

    /// 中断时也要把抑制标志放掉，否则后面手工操作就再也进不了撤销栈
    func cancel(project: ProjectState) {
        project.suppressUndoPush = false
        cancel()
    }

    /// 跑一轮。`history` 会被就地追加，方便上层保存会话
    func run(prompt: String,
             images: [Data] = [],
             history: inout [AgentMessage],
             mode: AgentMode,
             project: ProjectState,
             webSearch: Bool = false,
             onFinish: @escaping (_ reply: String, _ history: [AgentMessage]) -> Void) {
        // 这一轮归哪条会话。整轮的状态都写进它名下，别的会话不受影响
        let cid = AIVideoService.shared.currentConversationId ?? UUID()
        guard states[cid]?.isRunning != true else { return }
        mutate(cid) {
            $0.isRunning = true
            $0.steps = []
            $0.streamingText = ""
        }
        AgentContext.$conversationID.withValue(cid) { AgentToolbox.ocrCallsThisRound = 0 }

        history.append(.user(prompt, images: images))
        var msgs = history

        // 整轮一个撤销点：开跑前打一次，期间工具内部的 pushUndo 全部跳过
        // 同一个项目里另一条会话正在跑的话，它已经打开了这个开关：
        // 这轮的改动并进它那一步，收尾时也别去关它的（不然它后面每个工具都单独记一步撤销）
        let ownsUndo = mode != .plan && !project.suppressUndoPush
        if ownsUndo {
            project.pushUndo()
            project.suppressUndoPush = true
        }


        let began = Date()
        states[cid]?.ticker?.invalidate()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.mutate(cid) { $0.elapsed = Date().timeIntervalSince(began) }
            }
        }
        mutate(cid) {
            $0.startedAt = began
            $0.elapsed = 0
            $0.totalTokens = 0
            $0.phase = "正在思考"
            $0.ticker = ticker
        }

        let task = Task { [weak self] in
            guard let self else { return }
            // 整轮挂在这条会话名下：点亮哪些工具组、外部服务、每轮计数，全按它取。
            // 不挂的话这些只认「界面正开着哪条」，用户一切会话就串了
            await AgentContext.$conversationID.withValue(cid) {
            // 外接的 MCP 服务在这轮之前连一次（只连一次，之后走缓存）。
            // **必须在 Task 里** —— run 本身是同步的，而且工具表要等连上
            // 才知道对方有哪些工具
            await AgentMCP.shared.ensureConnected()
            // 用户这句话点到哪个外部服务，就挂哪个的工具
            AgentMCP.shared.activate(matching: prompt)
            // 工具组同理：这句话点到哪组就挂哪组，没点到的留给 enable_tools
            AgentToolGate.shared.activate(matching: prompt)

            // **提示词要等连上之后再拼**：外部服务清单来自刚才那次连接，
            // 在 Task 外面拼的话第一轮永远是空的，模型根本不知道有哪些服务可要
            let system = Self.systemPrompt(mode: mode, inCanvas: project.showCanvas)
                       + AgentMemory.shared.promptSection
                       + AgentSkills.shared.promptSection
                       + AgentMCP.shared.promptSection
                       + AgentToolGate.shared.promptSection(inCanvas: project.showCanvas)

            // Skill 的列表进提示词，正文按需读 —— read_skill 是只读的，
            // 计划模式也给，不然它连方案都拟不出来。
            //
            // **每轮重算**：模型可能这一步刚 enable_service 要来一个外部服务，
            // 下一步就得能看见那些工具；算一次存着的话它要了也用不上
            @MainActor func buildTools() -> [AgentToolSpec] {
                AgentToolGate.shared.tools(mode: mode, inCanvas: project.showCanvas)
                + (mode == .plan ? [] : AgentToolbox.mcpGateTool + AgentToolbox.mcpTools)
                // 这家有原生联网就用原生（搜索在服务端跑，模型自己决定搜什么词）；
                // 没有、或者走了中转站发不过去，才挂这个外挂工具兜底
                + (webSearch && !AgentLLM.canUseNativeSearch() ? AgentToolbox.searchTools : [])
            }

            var finalText = ""
            // 循环是自然跑完（步数用尽）还是它自己收尾的，收场白不一样
            var ranOut = true
            do {
                for _ in 0..<maxSteps {
                    if Task.isCancelled { break }
                    // 用户中途追加的话，下一次问模型之前带上
                    let queued = self.drainQueue(cid)
                    if !queued.isEmpty { msgs.append(.user(Self.queuedNote(queued))) }
                    self.mutate(cid) { $0.phase = "正在思考" }
                    let turn = try await AgentLLM.send(messages: msgs.compactedForSending(),
                                                       tools: buildTools(),
                                                       systemPrompt: system, webSearch: webSearch)
                    // 显示用的是**计费量**：缓存命中只收一成，按原始总量报等于虚高一倍
                    self.mutate(cid) { $0.totalTokens += (turn.billed > 0 ? turn.billed : turn.tokens) }
                    if !turn.text.isEmpty {
                        finalText = turn.text
                        self.mutate(cid) { $0.streamingText = turn.text }
                    }
                    guard !turn.toolCalls.isEmpty else {
                        // 模型准备收尾了，可用户刚好又发了话 —— 不收尾，带上接着做
                        let late = self.drainQueue(cid)
                        if !late.isEmpty {
                            msgs.append(.assistant(text: turn.text, calls: []))
                            msgs.append(.user(Self.queuedNote(late)))
                            continue
                        }
                        ranOut = false; break
                    }
                    msgs.append(.assistant(text: turn.text, calls: turn.toolCalls))

                    for call in turn.toolCalls {
                        if Task.isCancelled { break }
                        // 顶上那行要能一眼看出**这会儿在对什么动手**，
                        // 光「正在裁剪片段」不够 —— 一轮里裁十条，看着像卡住了。
                        // 参数带上一个最有信息量的，跟展开后每一步的写法对齐
                        self.mutate(cid) {
                            $0.phase = AgentPhaseText.phase(for: call.name)
                                     + Self.phaseObject(call)
                        }
                        let result = await self.execute(call, mode: mode, project: project,
                                                        convID: cid)
                        // 参数和完整结果都留着 —— 事后要复盘「它到底传了什么、
                        // 拿回来什么」，只存 120 字的摘要根本查不出问题。
                        // 结果掐到 4000 字：再长也读不完，还会把存档撑大
                        let args = call.arguments
                            .map { "\($0.key)=\(Self.brief($0.value))" }
                            .sorted().joined(separator: "，")
                        let full = result.text.count > 4000
                            ? String(result.text.prefix(4000)) + "\n……（还有 \(result.text.count - 4000) 字）"
                            : result.text
                        let imagePath = result.imageData.flatMap { Self.saveStepImage($0) } ?? ""
                        self.mutate(cid) {
                            $0.steps.append(Step(toolName: call.name,
                                                 summary: String(result.text.prefix(120)),
                                                 isError: result.isError,
                                                 args: args,
                                                 detail: full,
                                                 // 模型这一轮动手前说的话，就是它的思路
                                                 thinking: turn.text,
                                                 imagePath: imagePath))
                        }
                        // 发给模型的结果也要有上限。轨道清单、逐帧扫描这类一条能有上万字，
                        // 而且历史每轮重发 —— 一条超长结果会一路收费到任务结束。
                        // 存档里那份是完整的（上面的 full），复盘不受影响
                        var toModel = result.text.count > 3000
                            ? String(result.text.prefix(3000))
                              + "\n……（结果太长，这里截掉了 \(result.text.count - 3000) 字。"
                              + "要看剩下的就缩小范围再查一次，别重复调同样的参数。）"
                            : result.text
                        // 图存了盘就告诉它路径：想让用户也看到这张图，回复里直接插进去就行
                        if !imagePath.isEmpty {
                            // 先说清「图已经附上了」：只提路径的话，模型会以为工具只给了个路径、
                            // 没去看后面附着的图（实测它回「截图工具只返回了图片路径，我看不到」）
                            toModel += "\n（画面已作为图片附在这条结果里，直接看图判断就行。"
                                + "另外它存在 \(imagePath)，要给用户看，就在回复里单独一行写 ![说明](<\(imagePath)>)，路径有空格所以要带尖括号）"
                        }
                        msgs.append(.toolResult(callID: call.id, name: call.name,
                                                text: toModel, imageData: result.imageData))
                    }
                }
            } catch {
                // 用户自己按的停止，不该报成错
                let cancelled = error.isUserCancellation
                ranOut = false
                finalText = cancelled ? "已取消" : "出错了：\(error.localizedDescription)"
                self.mutate(cid) {
                    $0.steps.append(Step(toolName: "模型", summary: finalText, isError: !cancelled))
                }
            }
            // **步数用光要明说**。原来跑满就悄悄退出，用户看到的是它说了半截话
            // 然后不动了，压根不知道活儿没干完（实测它逐帧 OCR 刷了 243 步被截断）
            if ranOut && !Task.isCancelled {
                let note = "（这一轮的步数用完了，活儿没干完就停在这儿了。"
                    + "跟我说「接着做」我从这儿继续；要是它在反复做同一件事，换个说法直接告诉它怎么做更快。）"
                finalText = finalText.isEmpty ? note : finalText + "\n\n" + note
                self.mutate(cid) {
                    $0.steps.append(Step(toolName: "模型", summary: "步数用完，未完成", isError: true))
                }
                DiagLog.log("[Agent] 步数用尽（\(maxSteps) 轮），任务未完成")
            }
            if !finalText.isEmpty { msgs.append(.assistant(text: finalText, calls: [])) }
            // 回了「做不了」却没报缺口的，替它记一笔
            if !Task.isCancelled {
                AgentToolbox.autoReportGapIfNeeded(prompt: prompt, reply: finalText,
                                                   calledTools: self.states[cid]?.steps.map(\.toolName) ?? [])
            }
            if ownsUndo { project.suppressUndoPush = false }
            self.states[cid]?.ticker?.invalidate()
            self.mutate(cid) {
                $0.ticker = nil
                $0.elapsed = Date().timeIntervalSince(began)
                $0.phase = ""
                $0.isRunning = false
            }
            // **这一轮的完整记录（工具调用、结果、最后的回复）要从这里交回去。**
            // 原来是在 run 末尾 `history = msgs` 同步写回 —— 那时这个 Task 还没开跑，
            // 写回去的只有用户这句话。同一次运行里 Agent 的记忆于是只剩用户连着说的几句、
            // 一句自己的回复都没有，看着就像前面的要求还没做，下一轮连上一条一起又做一遍（实测）
            onFinish(finalText, msgs)
            }
        }
        mutate(cid) { $0.task = task }
        // 先把用户这句写进去：这一轮跑着的时候用户切走再切回来，记忆里至少有这一句
        history = msgs
    }

    // MARK: - 后台接着做

    /// 生成任务挂的「做完之后接着做」，由 AgentBackgroundTasks 在生成了结后调。
    ///
    /// 跟 `run` 的区别：不占会话界面（不写 states，用户该聊别的照聊），
    /// 上下文只有「生成出了什么 + 要接着做什么」这一句，不带会话历史；
    /// **危险工具一律不给**（生成、删除这类）—— 后台没人看着，
    /// 不能让它自己接着花钱，链也就不会自己往下长
    func runFollowUp(prompt: String, mode: AgentMode, project: ProjectState,
                     convID: UUID) async -> (text: String, ok: Bool) {
        // 后台助手也挂在发起它的会话名下，跟那条会话共用点亮的工具组，别的会话不受影响
        await AgentContext.$conversationID.withValue(convID) {
            await runFollowUpInConversation(prompt: prompt, mode: mode, project: project, convID: convID)
        }
    }

    private func runFollowUpInConversation(prompt: String, mode: AgentMode, project: ProjectState,
                                           convID: UUID) async -> (text: String, ok: Bool) {
        AgentToolGate.shared.activate(matching: prompt)
        // 系统提示词和工具表**跟主会话一字不差**：这两样是缓存前缀，对上了就直接命中，
        // 另拼一份的话每次都从头算，后台助手的请求明显比主会话慢。
        // 「你是后台助手」这些交代放进用户消息里；危险工具照样挂着，执行时挡（见 execute）
        let system = Self.systemPrompt(mode: mode, inCanvas: project.showCanvas)
                   + AgentMemory.shared.promptSection
                   + AgentSkills.shared.promptSection
                   + AgentMCP.shared.promptSection
                   + AgentToolGate.shared.promptSection(inCanvas: project.showCanvas)
        let brief = """
            （这条是系统发的，不是用户说的）你现在是后台助手：用户之前交代的事，前半截在后台刚做完，\
            你来把后半截做完。用户这会儿不一定在看，不要反问，按最合理的理解直接做。
            只做交代的这件事。不能生成、配音、导出、删除 —— 真要用到这些，就停下来，在汇报里说清需要用户决定什么。
            做完用一两句话汇报：做了什么、放在哪（哪条时间线、第几秒）。

            """
        var msgs: [AgentMessage] = [.user(brief + prompt, images: [])]
        // 整件事一个撤销点，⌘Z 一次撤回。主会话这会儿也在跑的话它已经关了快照，
        // 这边的改动就并进它那一步，别去动那个开关
        let ownsUndo = !project.suppressUndoPush
        if ownsUndo { project.pushUndo(); project.suppressUndoPush = true }
        defer { if ownsUndo { project.suppressUndoPush = false } }

        // 生成一跑就是几分钟，池子里的连接这期间可能已经被对端悄悄断掉，
        // 直接复用会干等 60 秒才超时（实测）。开跑前换新连接
        await AgentLLM.freshConnection()

        var finalText = ""
        do {
            for _ in 0..<min(maxSteps, 20) {
                if Task.isCancelled { return ("已取消", false) }
                let tools = AgentToolGate.shared.tools(mode: mode, inCanvas: project.showCanvas)
                    + (mode == .plan ? [] : AgentToolbox.mcpGateTool + AgentToolbox.mcpTools)
                let turn = try await AgentLLM.send(messages: msgs.compactedForSending(),
                                                   tools: tools, systemPrompt: system,
                                                   webSearch: false)
                if !turn.text.isEmpty { finalText = turn.text }
                guard !turn.toolCalls.isEmpty else {
                    return (finalText.isEmpty ? "做完了。" : finalText, true)
                }
                msgs.append(.assistant(text: turn.text, calls: turn.toolCalls))
                for call in turn.toolCalls {
                    if Task.isCancelled { return ("已取消", false) }
                    let result = await execute(call, mode: mode, project: project,
                                               convID: convID, background: true)
                    let toModel = result.text.count > 3000
                        ? String(result.text.prefix(3000)) + "\n……（结果太长，截掉了）"
                        : result.text
                    msgs.append(.toolResult(callID: call.id, name: call.name,
                                            text: toModel, imageData: result.imageData))
                }
            }
        } catch {
            return (error.isUserCancellation ? "已取消" : "出错了：\(error.localizedDescription)", false)
        }
        DiagLog.log("[Agent] 后台接着做：步数用尽，未完成")
        return ((finalText.isEmpty ? "" : finalText + "\n") + "步数用完了，没做完。", false)
    }

    // MARK: - 单个工具

    /// 工具执行时挂上「替哪条会话干活」。工具里读参考图、生成名额、报结果都按这个取 ——
    /// 不挂的话它们只能看「界面上正开着哪条」，用户一切会话就串到别处去了
    private func execute(_ call: AgentToolCall, mode: AgentMode,
                         project: ProjectState, convID: UUID,
                         background: Bool = false) async -> AgentToolResult {
        await AgentContext.$conversationID.withValue(convID) {
            await executeInConversation(call, mode: mode, project: project,
                                        convID: convID, background: background)
        }
    }

    private func executeInConversation(_ call: AgentToolCall, mode: AgentMode,
                                       project: ProjectState, convID: UUID,
                                       background: Bool) async -> AgentToolResult {
        guard let spec = AgentToolbox.allSpecs.first(where: { $0.name == call.name }) else {
            return .fail("没有叫 \(call.name) 的工具。")
        }
        if call.name == "view_attachments" { return AgentToolbox.viewAttachments(call.arguments) }
        if call.name == "report_gap" { return AgentToolbox.runGapTool(call.arguments) }
        if call.name == "search_tools" {
            return AgentToolGate.shared.search(call.arguments["query"] as? String ?? "")
        }
        if call.name == "ask_user" {
            guard !background else {
                return .fail("后台助手不能问用户。按最合理的理解做，在汇报里说清你是怎么理解的。")
            }
            let question = (call.arguments["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let options = Array(AgentToolbox.askOptions(call.arguments).prefix(4))
            guard !question.isEmpty, options.count >= 2 else {
                return .fail("ask_user 要一个 question 和 2～4 个 options。")
            }
            guard let answer = await ask(question, options: options, convID: convID) else {
                return .fail("用户没回答，这一轮停了。")
            }
            return .ok("用户的回答：\(answer)\n照这个接着做，不用再确认一遍。")
        }
        // 后台助手的工具表里本来就没有危险工具，模型硬调（照历史名字猜）也在这儿挡住
        if background && spec.risk == .dangerous {
            return .fail("后台助手不能做这一步（生成、删除这类）。停下来，在汇报里说清需要用户决定什么。")
        }
        // 模式先拦一道
        if let reason = mode.rejection(for: spec.risk) { return .fail(reason) }
        if mode.needsConfirm(for: spec.risk) {
            let ok = await confirm(spec.name, detail: describe(call), convID: convID)
            guard ok else { return .fail("用户拒绝了这一步，换个做法或者停下来问问他。") }
        }

        // 会动项目的一步跑完，让属性面板重读一遍
        if spec.risk != .readOnly {
            defer { project.inspectorRevision &+= 1 }
            return await executeTool(call, project: project)
        }
        return await executeTool(call, project: project)
    }

    private func executeTool(_ call: AgentToolCall, project: ProjectState) async -> AgentToolResult {
        if let r = await AgentToolbox.runReadTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runEditTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runPropsTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runKeyframeTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runGenerateTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = await AgentToolbox.runSkillTool(call.name, args: call.arguments) {
            return r
        }
        if let r = await AgentToolbox.runMediaTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runStudioTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runStudioTool2(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runCanvasTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = await AgentToolbox.runCanvasEditTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runSettingsTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runProjectTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = await AgentToolbox.runLibraryTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if call.name == "enable_tools" {
            guard let g = call.arguments["group"] as? String else { return .fail("缺 group") }
            return AgentToolGate.shared.enable(g)
        }
        if let r = await AgentToolbox.runShellTool(call.name, args: call.arguments) {
            return r
        }
        if let r = await AgentToolbox.runSearchTool(call.name, args: call.arguments) {
            return r
        }
        if let r = await AgentToolbox.runMCPTool(call.name, args: call.arguments) {
            return r
        }
        return .fail("工具 \(call.name) 还没接上。")
    }

    private func ask(_ question: String, options: [String], convID: UUID) async -> String? {
        await withCheckedContinuation { cont in
            mutate(convID) {
                $0.pendingQuestion = PendingQuestion(question: question, options: options) { [weak self] ans in
                    // 只认第一次：停止按钮和点选项可能前后脚到，resume 两次会崩
                    guard self?.states[convID]?.pendingQuestion != nil else { return }
                    self?.mutate(convID) { $0.pendingQuestion = nil }
                    cont.resume(returning: ans)
                }
            }
        }
    }

    private func confirm(_ tool: String, detail: String, convID: UUID) async -> Bool {
        await withCheckedContinuation { cont in
            mutate(convID) {
                $0.pendingConfirm = PendingConfirm(toolName: tool, detail: detail) { [weak self] ok in
                    self?.mutate(convID) { $0.pendingConfirm = nil }
                    cont.resume(returning: ok)
                }
            }
        }
    }

    /// 参数值压成一行。图片这类长 base64 只留个说明，别把存档撑爆
    /// 从这次调用里挑一个最能说明「动的是什么」的参数，给顶上那行用。
    /// 挑不出来就不写 —— 宁可短，也别把一长串 id 糊在标题上
    static func phaseObject(_ call: AgentToolCall) -> String {
        let keys = ["path", "prompt", "text", "name", "query", "command",
                    "language", "kind", "group", "clip_id", "node_id", "asset_id"]
        for k in keys {
            guard let v = call.arguments[k] else { continue }
            var s = "\(v)".replacingOccurrences(of: "\n", with: " ")
                           .trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if s.count > 18 { s = String(s.prefix(18)) + "…" }
            return "（\(s)）"
        }
        return ""
    }

    static func brief(_ v: Any) -> String {
        let s = "\(v)"
        return s.count > 200 ? String(s.prefix(200)) + "…（略）" : s
    }

    private func describe(_ call: AgentToolCall) -> String {
        if call.name == "run_command", let cmd = call.arguments["command"] as? String {
            let why = (call.arguments["purpose"] as? String).map { "\($0)\n\n" } ?? ""
            return why + cmd
        }
        let args = call.arguments.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "，")
        return args.isEmpty ? call.name : "\(call.name)（\(args)）"
    }

    // MARK: - 系统提示词

    static func systemPrompt(mode: AgentMode, inCanvas: Bool = false) -> String {
        var s = """
        你是黑猫剪辑里的剪辑助手，直接操作用户当前打开的项目。

        怎么干活：
        · **你就跑在这个剪辑软件里面**，项目、素材库、时间轴都归你直接操作。
          需要把电脑上的文件弄进来就调 import_media —— 绝不要去开剪映之类的别家剪辑
          软件，也不用 AppleScript 绕。（实测出过：让它导入下载好的视频，它跑去开剪映了）
        · 动手之前先调 get_project 和 list_tracks 看清楚现状，别凭空猜时间轴上有什么。
        · 要改某条片段必须先拿到它的 id（list_tracks 会给），不要按名字猜。
        · 涉及画面好坏的判断（太暗、主体位置、有没有穿帮），调 capture_frame 亲眼看，别靠推测。
        · 一次只做用户要求的事。顺手多改的东西他没法预料，只会添乱。
        · **说「没有这个功能」「做不了」之前，先用 search_tools 换几个说法搜一遍**。
          你的工具很多、分组挂着，手上没看到不等于没有（实测：加图形、改圆角投影其实都有，它却回没有）。
          get_properties / set_properties 能读改任何片段的全部属性，专门工具没开放的参数先试它。
          要动画（移动、缩放、旋转、淡入淡出、字变大）或音量渐强渐弱，用 set_keyframes 打关键帧。
          都试过还是做不了，调 report_gap 记下来，再如实告诉用户。
        · 干完用一两句话说清楚你改了什么，不用复述每一步工具调用。
        · 生成图片/视频/音频是后台任务，**提交完就接着做别的，别在那儿等**。
          用户问「好了没」的时候再去查 list_background_tasks。
        · **要几张就提交几个任务，要一张就只提交一个。** 别拿同一个提示词同时找
          好几家模型「以防万一」—— 每提交一次都在花用户的钱。某一家失败了，
          软件会问用户要不要换一家重试，不用你提前铺开。
          用户点名了模型（「用 image2 生成」）就只用那一个，别顺手再加一家。
        · Skill 说明书里给的命令，用 run_command 照着跑，别自己改写、也别自己发明命令。
          命令失败先看输出里的报错，按说明书里的重试链处理，连试三次还不行就停下来告诉用户。
        · **要记住什么，必须调 remember 工具**。用户说「记住」「写进记忆」「以后都…」
          「我习惯…」的时候，先调工具、拿到成功结果，再回话。
          光在回复里写「已记住」是假的 —— 你这轮说完就忘，下次开新会话它根本不在。
          装 Skill 同理：调 install_skill，别自己去读网页拼文件。

        对话历史里带 `[系统记录·你上一轮实际执行过的工具]` 的那几段，是系统替你补的
        执行记录（为省 token 只留了工具名、参数和结果摘要）。两个方向都别搞错：

        · 别因为前面几轮看着都是纯文字回答，就跟着只回文字 —— 该调工具就调。
        · **那是记录，不是你的说话格式。** 绝不要自己写出 `[系统记录…]`、`<tool_log>`
          或者「· generate_image(…) → 已提交后台任务」这类假的执行记录。
          **要做事就真的发起工具调用；没发起调用，就不许说自己做了。**
          说「已提交」「正在生成」「图片生成完成」「已记住」而实际没调工具，
          等于骗用户 —— 他会一直等一个根本不存在的任务。

        **什么时候用表格**：只有「同结构的多条数据」才排表格 —— 轨道清单、素材清单、
        任务状态、参数对照这种。三个硬条件，缺一个就别用：**三行以上**、
        **每格十来个字以内**、**最多三列**。聊天区就四百来点宽，四列必然挤烂。
        一两条信息、讲你做了什么、格子里是长句子的，一律用句子或短横线列表。
        `list_tracks`、`list_assets` 返回的本来就是表格，可以原样贴出来。

        **要给用户看图就直接插进回复**：单独一行写 `![说明](图片地址)`，聊天框会把图显示出来，
        网上的图片地址和本机路径都行（路径有空格就写成 `![说明](<路径>)`）。
        别只贴一串图片链接让用户自己点开。

        说话风格：中文，简短，别用「好的」「我将为您」这类开场白。**不要用 emoji**，
        该标状态就用文字（成功 / 失败 / 已完成），面板里 emoji 跟界面图标混在一起很乱。

        """

        if inCanvas {
            s += """

            **用户现在打开的是 AI 画布，不是时间轴。**
            画布是一块自由排布的创作台，上面摆着一张张卡片（图片/视频/音频/文字），
            卡片之间连线表示「上游是下游的参考素材」。
            · 你生成的图片/视频会**自动落到画布上**成为一张新卡片，不会进时间轴。
              别跟用户说「放到时间轴上」「等好了叫我放进时间轴」——他现在不在那儿。
            · 时间轴那套工具（加片段、分割、加字幕这些）在画布上一般用不着，
              用户明确说要放进时间轴时才用。
            · **画布上有什么，先调 read_canvas 看**，别猜。用户说「这几张图」「上面那张」
              指的都是画布上的卡片，得先读出来才知道他指哪张。
            · 卡片你也能动手：加卡片、改提示词、连线、让它开始生成、放到时间轴，
              工具名都带 canvas。要看清楚某张卡片**画面里**是什么，
              拿它的文件去调 capture_frame 或 read_frame_text，跟看时间轴素材一样。
            · **「把这张图改成…」＝ 拿原图当参考重新生成**，不是改改提示词让它重跑。
              后者出来的是一张毫不相干的新图，用户要的「改」变成了「换」。
              做法：新建一张卡片写好提示词，generate_canvas_node 时把原图填进
              reference（会自动连线）；原图那张留着别动，好坏可以对比。
            · 用户说「画布上的图」而画布上**不止一张**时，先说清楚你打算动哪张，
              或者用 ask_user 让他选 —— 别自己挑一张就改，改错了他得重新生成一次（花钱）。
            · 画布卡片**能指定用哪家模型**（generate_canvas_node 的 model 参数）。
              用户说「用 seedream 再来一版」就填上，别回他「画布不支持切换模型」。

            """
        }

        switch mode {
        case .plan:
            s += """
            当前是**计划模式**：你只能看，不能改。
            看清楚之后把打算怎么做列成几步告诉用户，等他切到自动模式再执行。
            """
        case .auto:
            s += """
            当前是**自动模式**：常规改动直接做。

            删除、导出这类不好回头的操作，**直接调工具就行 —— 软件自己会弹确认框**，
            用户在框里点允许或拒绝。**不要先用文字问一遍**「确认要删吗」再等回复，
            那样等于问两次，用户还得多打一轮字。他在框里拒绝了就换个思路，别硬来。

            run_command 同理：装软件、改 shell 配置这种会动到环境的照样直接调，
            确认框会把命令原文摊给用户看。只是查信息的命令不用问，直接跑。
            """
        case .full:
            s += """
            当前是**全权模式**：所有操作都不会再问用户。**包括 run_command 里装软件、
            改 shell 配置这些**，用户已经授权了，别再退回去让他自己敲命令。
            正因如此，动手前更要确认清楚，尤其是删除类操作。
            """
        }
        return s
    }
}

/// 是不是用户主动取消。
///
/// 两种都要认：Swift 并发取消抛的是 `CancellationError`，
/// URLSession 那边取消报的是 `URLError.cancelled`。
/// 只认一种的话，另一种会以「未能完成操作。(Swift.CancellationError 错误1。)」
/// 这样一句系统文案露到界面上
extension Error {
    var isUserCancellation: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// 折叠着的步骤栏标题上报哪一步。
///
/// 只报改动项目、要等的那些。查询类（读工程、列素材、列轨道）一秒能过好几个，
/// 标题跟着闪反而看不清，也没什么可看的 —— 一律落到「正在执行」
enum AgentPhaseText {
    private static let table: [String: String] = [
        "generate_video":        "正在生成视频",
        "generate_image":        "正在生成图片",
        "generate_audio":        "正在生成音频",
        "web_search":            "正在联网搜索",
        "run_command":           "正在执行命令",
        "run_skill_script":      "正在跑 Skill",
        "import_media":          "正在导入素材",
        "export_video":          "正在导出成片",
        "transcribe":            "正在识别语音",
        "update_clip":           "正在调整片段",
        "trim_clip":             "正在裁剪片段",
        "read_frame_text":       "正在认画面上的字",
        "scan_text":             "正在扫画面上的文字",
        "add_transition":        "正在加转场",
        "add_shape":             "正在加图形",
        "translate_subtitles":   "正在翻译字幕",
        "subtitles_to_speech":   "正在配音",
        "enhance_clarity":       "正在提升清晰度",
        "remove_background_music": "正在分离人声",
        "scene_split":           "正在检测镜头",
        "analyze_highlights":    "正在挑精彩片段",
        "save_project":          "正在保存",
        "undo":                  "正在撤销",
        "redo":                  "正在重做",
        "rename":                "正在改名",
        "delete_asset":          "正在删素材",
        "group_clips":           "正在打包片段",
        "ungroup_clip":          "正在拆开复合片段",
        "new_timeline":          "正在新建时间线",
        "switch_timeline":       "正在切换时间线",
        "remove_image_background": "正在抠图",
        "add_asset_to_timeline": "正在放进时间轴",
        "add_subtitle":          "正在加字幕",
        "add_text":              "正在加标题文字",
        "add_filter":            "正在加滤镜",
        "add_effect":            "正在加特效",
        "add_adjust":            "正在加调节",
        "capture_frame":         "正在截取画面",
        "ask_user":              "正在等你选择",
        "view_attachments":      "正在看你发的图",
        "search_tools":          "正在找合适的工具",
        "save_skill":            "正在存成技能",
        "report_gap":            "正在记录能力缺口",
        "get_properties":        "正在读属性",
        "set_properties":        "正在改属性",
        "list_keyframes":        "正在看关键帧",
        "set_keyframes":         "正在打关键帧",
        "delete_keyframes":      "正在删关键帧",
        "split_at":              "正在分割片段",
        "move_clip":             "正在移动片段",
        "move_track":            "正在调整轨道顺序",
        "add_track":             "正在新建轨道",
        "delete_track":          "正在删除轨道",
        "set_track":             "正在调整轨道",
        "edit_timeline":         "正在调整时间线",
        "delete_timeline":       "正在删除时间线",
        "marker":                "正在处理标记",
        "copy_clips":            "正在复制片段",
        "align_clips":           "正在对齐图层",
        "compound_edit":         "正在进出复合片段",
        "text_template":         "正在处理文字模板",
        "set_project":           "正在改项目设置",
        "set_cover":             "正在设封面",
        "new_project":           "正在新建项目",
        "open_project":          "正在打开项目",
        "save_frame":            "正在截帧存素材",
        "library_folder":        "正在整理素材库",
        "relink_asset":          "正在重新关联素材",
        "add_to_ai_reference":   "正在加 AI 参考",
        "online_audio":          "正在查在线音频库",
        "canvas_edit":           "正在处理画布卡片",
        "app_settings":          "正在改设置",
        "get_clip":              "正在看片段属性",
        "select_clips":          "正在选中片段",
        "asset_attribution":     "正在查素材署名",
        "delete_clip":           "正在删除片段",
        "get_project":           "正在看项目情况",
        "list_tracks":           "正在看轨道",
        "list_assets":           "正在看素材库",
        "seek":                  "正在移动播放头",
        "remember":              "正在记下来",
        "forget":                "正在忘掉一条",
        "set_subtitle_default_size": "正在调字幕字号",
        "list_background_tasks": "正在看后台任务",
        "read_skill":            "正在读 Skill",
        "install_skill":         "正在装 Skill",
        "enable_service":        "正在接入外部服务",
        "enable_tools":          "正在取工具",
        "read_canvas":           "正在看画布",
        "add_canvas_node":       "正在往画布加卡片",
        "update_canvas_node":    "正在改画布卡片",
        "connect_canvas_nodes":  "正在连卡片",
        "disconnect_canvas_nodes": "正在断开连线",
        "generate_canvas_node":  "正在让卡片开跑",
        "delete_canvas_node":    "正在删卡片",
        "canvas_to_timeline":    "正在把卡片放进时间轴",
    ]

    static func phase(for tool: String) -> String { table[tool] ?? "正在执行" }

    /// 步骤条上那行标题。跟 `phase` 同一张表，去掉「正在」——
    /// 步骤是**已经做完**的事，写「正在导出成片」不对。
    /// 表里没有的就直接用工具名，比笼统的「执行」有用
    static func label(for tool: String) -> String {
        guard let t = table[tool] else { return tool }
        return t.hasPrefix("正在") ? String(t.dropFirst(2)) : t
    }
}


/// 这会儿在替哪条会话干活。工具执行期间由 AgentRunner 挂上（task-local，跟着这一轮的
/// 异步调用走，别的会话同时在跑也互不影响）；不在工具执行里就是 nil，按界面当前会话算
enum AgentContext {
    @TaskLocal static var conversationID: UUID?

    private static let noConversation = UUID()
    /// 按会话分开存东西时用的键：在替哪条会话干活就是哪条，否则是界面当前那条
    @MainActor static var key: UUID {
        conversationID ?? AIVideoService.shared.currentConversationId ?? noConversation
    }
}
