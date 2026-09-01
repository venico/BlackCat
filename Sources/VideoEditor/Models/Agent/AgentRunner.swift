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

    /// 一轮里发生过什么，给界面显示
    struct Step: Identifiable {
        let id = UUID()
        var toolName: String
        var summary: String
        var isError = false
    }

    @Published var isRunning = false
    @Published var steps: [Step] = []
    @Published var streamingText = ""
    /// 正等着用户点确认的那个工具调用
    @Published var pendingConfirm: PendingConfirm?

    struct PendingConfirm: Identifiable {
        let id = UUID()
        let toolName: String
        let detail: String
        let onAnswer: (Bool) -> Void
    }

    /// 一轮最多让它调多少次工具。绕圈子的话到这就停
    private let maxSteps = 24
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// 中断时也要把抑制标志放掉，否则后面手工操作就再也进不了撤销栈
    func cancel(project: ProjectState) {
        project.suppressUndoPush = false
        cancel()
    }

    /// 跑一轮。`history` 会被就地追加，方便上层保存会话
    func run(prompt: String,
             history: inout [AgentMessage],
             mode: AgentMode,
             project: ProjectState,
             onFinish: @escaping (String) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        steps = []
        streamingText = ""

        history.append(.user(prompt))
        var msgs = history

        // 整轮一个撤销点：开跑前打一次，期间工具内部的 pushUndo 全部跳过
        if mode != .plan {
            project.pushUndo()
            project.suppressUndoPush = true
        }

        let tools = AgentToolbox.readTools + (mode == .plan ? [] : AgentToolbox.editTools)
        let system = Self.systemPrompt(mode: mode)

        task = Task { [weak self] in
            guard let self else { return }
            var finalText = ""
            do {
                for _ in 0..<maxSteps {
                    if Task.isCancelled { break }
                    let turn = try await AgentLLM.send(messages: msgs, tools: tools,
                                                       systemPrompt: system)
                    if !turn.text.isEmpty {
                        finalText = turn.text
                        self.streamingText = turn.text
                    }
                    guard !turn.toolCalls.isEmpty else { break }
                    msgs.append(.assistant(text: turn.text, calls: turn.toolCalls))

                    for call in turn.toolCalls {
                        if Task.isCancelled { break }
                        let result = await self.execute(call, mode: mode, project: project)
                        self.steps.append(Step(toolName: call.name,
                                               summary: String(result.text.prefix(120)),
                                               isError: result.isError))
                        msgs.append(.toolResult(callID: call.id, name: call.name,
                                                text: result.text, imageData: result.imageData))
                    }
                }
            } catch {
                finalText = "出错了：\(error.localizedDescription)"
                self.steps.append(Step(toolName: "模型", summary: finalText, isError: true))
            }
            if !finalText.isEmpty { msgs.append(.assistant(text: finalText, calls: [])) }
            project.suppressUndoPush = false
            self.isRunning = false
            onFinish(finalText)
        }
        history = msgs
    }

    // MARK: - 单个工具

    private func execute(_ call: AgentToolCall, mode: AgentMode,
                         project: ProjectState) async -> AgentToolResult {
        let all = AgentToolbox.readTools + AgentToolbox.editTools
        guard let spec = all.first(where: { $0.name == call.name }) else {
            return .fail("没有叫 \(call.name) 的工具。")
        }
        // 模式先拦一道
        if let reason = mode.rejection(for: spec.risk) { return .fail(reason) }
        if mode.needsConfirm(for: spec.risk) {
            let ok = await confirm(spec.name, detail: describe(call))
            guard ok else { return .fail("用户拒绝了这一步，换个做法或者停下来问问他。") }
        }

        if let r = await AgentToolbox.runReadTool(call.name, args: call.arguments, project: project) {
            return r
        }
        if let r = AgentToolbox.runEditTool(call.name, args: call.arguments, project: project) {
            return r
        }
        return .fail("工具 \(call.name) 还没接上。")
    }

    private func confirm(_ tool: String, detail: String) async -> Bool {
        await withCheckedContinuation { cont in
            pendingConfirm = PendingConfirm(toolName: tool, detail: detail) { [weak self] ok in
                self?.pendingConfirm = nil
                cont.resume(returning: ok)
            }
        }
    }

    private func describe(_ call: AgentToolCall) -> String {
        let args = call.arguments.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "，")
        return args.isEmpty ? call.name : "\(call.name)（\(args)）"
    }

    // MARK: - 系统提示词

    static func systemPrompt(mode: AgentMode) -> String {
        var s = """
        你是黑猫剪辑里的剪辑助手，直接操作用户当前打开的项目。

        怎么干活：
        · 动手之前先调 get_project 和 list_tracks 看清楚现状，别凭空猜时间轴上有什么。
        · 要改某条片段必须先拿到它的 id（list_tracks 会给），不要按名字猜。
        · 涉及画面好坏的判断（太暗、主体位置、有没有穿帮），调 capture_frame 亲眼看，别靠推测。
        · 一次只做用户要求的事。顺手多改的东西他没法预料，只会添乱。
        · 干完用一两句话说清楚你改了什么，不用复述每一步工具调用。

        说话风格：中文，简短，别用「好的」「我将为您」这类开场白。

        """
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
            """
        case .full:
            s += """
            当前是**全权模式**：所有操作都不会再问用户。正因如此，动手前更要确认清楚，
            尤其是删除类操作。
            """
        }
        return s
    }
}
