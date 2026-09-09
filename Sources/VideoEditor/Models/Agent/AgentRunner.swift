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

    /// 一轮最多让它调多少次工具。绕圈子的话到这就停
    private let maxSteps = 24

    /// 停的是**当前看着那条**的活儿
    func cancel() {
        guard let id = visibleID else { return }
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
             onFinish: @escaping (String) -> Void) {
        // 这一轮归哪条会话。整轮的状态都写进它名下，别的会话不受影响
        let cid = AIVideoService.shared.currentConversationId ?? UUID()
        guard states[cid]?.isRunning != true else { return }
        mutate(cid) {
            $0.isRunning = true
            $0.steps = []
            $0.streamingText = ""
        }

        history.append(.user(prompt, images: images))
        var msgs = history

        // 整轮一个撤销点：开跑前打一次，期间工具内部的 pushUndo 全部跳过
        if mode != .plan {
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
            // 外接的 MCP 服务在这轮之前连一次（只连一次，之后走缓存）。
            // **必须在 Task 里** —— run 本身是同步的，而且工具表要等连上
            // 才知道对方有哪些工具
            await AgentMCP.shared.ensureConnected()
            // 用户这句话点到哪个外部服务，就挂哪个的工具
            AgentMCP.shared.activate(matching: prompt)

            // **提示词要等连上之后再拼**：外部服务清单来自刚才那次连接，
            // 在 Task 外面拼的话第一轮永远是空的，模型根本不知道有哪些服务可要
            let system = Self.systemPrompt(mode: mode, inCanvas: project.showCanvas)
                       + AgentMemory.shared.promptSection
                       + AgentSkills.shared.promptSection
                       + AgentMCP.shared.promptSection

            // Skill 的列表进提示词，正文按需读 —— read_skill 是只读的，
            // 计划模式也给，不然它连方案都拟不出来。
            //
            // **每轮重算**：模型可能这一步刚 enable_service 要来一个外部服务，
            // 下一步就得能看见那些工具；算一次存着的话它要了也用不上
            @MainActor func buildTools() -> [AgentToolSpec] {
                AgentToolbox.readTools
                + AgentToolbox.skillTools.filter { mode != .plan || $0.risk == .readOnly }
                + (mode == .plan ? [] : AgentToolbox.editTools + AgentToolbox.generateTools
                                       + AgentToolbox.shellTools
                                       + AgentToolbox.mcpGateTool + AgentToolbox.mcpTools)
                // 这家有原生联网就用原生（搜索在服务端跑，模型自己决定搜什么词）；
                // 没有、或者走了中转站发不过去，才挂这个外挂工具兜底
                + (webSearch && !AgentLLM.canUseNativeSearch() ? AgentToolbox.searchTools : [])
            }

            var finalText = ""
            do {
                for _ in 0..<maxSteps {
                    if Task.isCancelled { break }
                    self.mutate(cid) { $0.phase = "正在思考" }
                    let turn = try await AgentLLM.send(messages: msgs, tools: buildTools(),
                                                       systemPrompt: system, webSearch: webSearch)
                    self.mutate(cid) { $0.totalTokens += turn.tokens }
                    if !turn.text.isEmpty {
                        finalText = turn.text
                        self.mutate(cid) { $0.streamingText = turn.text }
                    }
                    guard !turn.toolCalls.isEmpty else { break }
                    msgs.append(.assistant(text: turn.text, calls: turn.toolCalls))

                    for call in turn.toolCalls {
                        if Task.isCancelled { break }
                        self.mutate(cid) { $0.phase = AgentPhaseText.phase(for: call.name) }
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
                        self.mutate(cid) {
                            $0.steps.append(Step(toolName: call.name,
                                                 summary: String(result.text.prefix(120)),
                                                 isError: result.isError,
                                                 args: args,
                                                 detail: full,
                                                 // 模型这一轮动手前说的话，就是它的思路
                                                 thinking: turn.text))
                        }
                        msgs.append(.toolResult(callID: call.id, name: call.name,
                                                text: result.text, imageData: result.imageData))
                    }
                }
            } catch {
                // 用户自己按的停止，不该报成错
                let cancelled = error.isUserCancellation
                finalText = cancelled ? "已取消" : "出错了：\(error.localizedDescription)"
                self.mutate(cid) {
                    $0.steps.append(Step(toolName: "模型", summary: finalText, isError: !cancelled))
                }
            }
            if !finalText.isEmpty { msgs.append(.assistant(text: finalText, calls: [])) }
            project.suppressUndoPush = false
            self.states[cid]?.ticker?.invalidate()
            self.mutate(cid) {
                $0.ticker = nil
                $0.elapsed = Date().timeIntervalSince(began)
                $0.phase = ""
                $0.isRunning = false
            }
            onFinish(finalText)
        }
        mutate(cid) { $0.task = task }
        history = msgs
    }

    // MARK: - 单个工具

    private func execute(_ call: AgentToolCall, mode: AgentMode,
                         project: ProjectState, convID: UUID) async -> AgentToolResult {
        let all = AgentToolbox.readTools + AgentToolbox.editTools
                + AgentToolbox.generateTools + AgentToolbox.skillTools
                + AgentToolbox.shellTools + AgentToolbox.searchTools
                + AgentToolbox.mcpGateTool + AgentToolbox.mcpTools
        guard let spec = all.first(where: { $0.name == call.name }) else {
            return .fail("没有叫 \(call.name) 的工具。")
        }
        // 模式先拦一道
        if let reason = mode.rejection(for: spec.risk) { return .fail(reason) }
        if mode.needsConfirm(for: spec.risk) {
            let ok = await confirm(spec.name, detail: describe(call), convID: convID)
            guard ok else { return .fail("用户拒绝了这一步，换个做法或者停下来问问他。") }
        }

        if let r = await AgentToolbox.runReadTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runEditTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runGenerateTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = await AgentToolbox.runSkillTool(call.name, args: call.arguments) {
            return r
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
        · 动手之前先调 get_project 和 list_tracks 看清楚现状，别凭空猜时间轴上有什么。
        · 要改某条片段必须先拿到它的 id（list_tracks 会给），不要按名字猜。
        · 涉及画面好坏的判断（太暗、主体位置、有没有穿帮），调 capture_frame 亲眼看，别靠推测。
        · 一次只做用户要求的事。顺手多改的东西他没法预料，只会添乱。
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
        "add_asset_to_timeline": "正在放进时间轴",
        "add_subtitle":          "正在加字幕",
        "add_text":              "正在加标题文字",
        "add_filter":            "正在加滤镜",
        "add_effect":            "正在加特效",
        "add_adjust":            "正在加调节",
        "capture_frame":         "正在截取画面",
        "split_at":              "正在分割片段",
        "move_clip":             "正在移动片段",
        "delete_clip":           "正在删除片段",
    ]

    static func phase(for tool: String) -> String { table[tool] ?? "正在执行" }
}
