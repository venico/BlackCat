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

        // Skill 的列表进提示词，正文按需读 —— read_skill 是只读的，
        // 计划模式也给，不然它连方案都拟不出来
        let tools = AgentToolbox.readTools
                  + AgentToolbox.skillTools.filter { mode != .plan || $0.risk == .readOnly }
                  + (mode == .plan ? [] : AgentToolbox.editTools + AgentToolbox.generateTools
                                         + AgentToolbox.shellTools)
                  // 这家有原生联网就用原生（搜索在服务端跑，模型自己决定搜什么词）；
                  // 没有、或者走了中转站发不过去，才挂这个外挂工具兜底
                  + (webSearch && !AgentLLM.canUseNativeSearch() ? AgentToolbox.searchTools : [])
        let system = Self.systemPrompt(mode: mode, inCanvas: project.showCanvas)
                   + AgentMemory.shared.promptSection
                   + AgentSkills.shared.promptSection

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
            var finalText = ""
            do {
                for _ in 0..<maxSteps {
                    if Task.isCancelled { break }
                    self.mutate(cid) { $0.phase = "正在思考" }
                    let turn = try await AgentLLM.send(messages: msgs, tools: tools,
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
                        self.mutate(cid) {
                            $0.steps.append(Step(toolName: call.name,
                                                 summary: String(result.text.prefix(120)),
                                                 isError: result.isError))
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
        · Skill 说明书里给的命令，用 run_command 照着跑，别自己改写、也别自己发明命令。
          命令失败先看输出里的报错，按说明书里的重试链处理，连试三次还不行就停下来告诉用户。

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
            当前是**自动模式**：常规改动直接做；删除、导出这类操作会弹窗问用户，
            他拒绝了就换个思路，别硬来。
            run_command 里装软件、改 shell 配置这种会动到环境的，先把命令和后果说清楚，
            等用户点头再跑；只是查信息的命令不用问，直接跑。
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
