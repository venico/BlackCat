// AgentBackgroundTasks.swift
//
// Agent 派出去的后台任务。
//
// 生成一次图/视频要几十秒到几分钟，Agent **不干等** —— 提交完就接着做别的，
// 结果在这里排队，聊天框左上角的入口能看到进度，完成了在会话里给张卡片。
// 干等的话一句话的活儿要卡住整轮对话，中间什么都干不了。

import Foundation
import SwiftUI

@MainActor
final class AgentBackgroundTasks: ObservableObject {
    static let shared = AgentBackgroundTasks()

    struct Item: Identifiable {
        let id: UUID
        var title: String
        var kind: AIVideoService.ProviderCategory
        var startedAt = Date()
        var state: State = .running
        /// 产出的素材。成功了才有
        var url: URL?

        enum State: Equatable {
            case running
            case done
            case failed(String)
        }

        var isRunning: Bool { state == .running }
    }

    @Published private(set) var items: [Item] = []
    /// 完成之后要在会话里报一声的那些，报完清掉
    @Published var unreadFinished: [Item] = []

    var runningCount: Int { items.filter(\.isRunning).count }

    func add(id: UUID, title: String, kind: AIVideoService.ProviderCategory) {
        items.insert(Item(id: id, title: title, kind: kind), at: 0)
    }

    func finish(id: UUID, url: URL) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .done
        items[i].url = url
        unreadFinished.append(items[i])
    }

    func fail(id: UUID, _ message: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .failed(message)
        unreadFinished.append(items[i])
    }

    func cancel(id: UUID) {
        AIVideoService.shared.cancel(taskID: id)
        items.removeAll { $0.id == id }
    }

    /// 清掉已经结束的，留着在跑的
    func clearFinished() {
        items.removeAll { !$0.isRunning }
    }
}
