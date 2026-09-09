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
        /// 派这个任务的是哪条会话。每张画布、每条对话各看各的 ——
        /// 一份全局清单会让 A 画布看见 B 画布在跑什么
        var conversationID: UUID?
        var startedAt = Date()
        var state: State = .running
        /// 产出的素材。成功了才有
        var url: URL?
        /// 等着用户点「换一家试试」时，点了要跑的那件事。
        /// 闭包放在 Item 上而不是 State 里 —— State 要能比较，闭包比不了
        var pendingRetry: (() -> Void)?

        enum State: Equatable {
            case running
            case done
            case failed(String)
            /// 这家没成，问用户要不要改用另一家。**自动模式下不擅自换** ——
            /// 每次生成都花钱，换谁得他点头
            case needsConfirm(reason: String, nextName: String)
        }

        var isRunning: Bool { state == .running }
    }

    @Published private(set) var items: [Item] = []
    /// 完成之后要在会话里报一声的那些，报完清掉
    @Published var unreadFinished: [Item] = []

    /// 当前这条会话派出去的任务
    var currentItems: [Item] {
        let cid = AIVideoService.shared.currentConversationId
        return items.filter { $0.conversationID == cid }
    }

    var runningCount: Int { currentItems.filter(\.isRunning).count }

    /// 卡住等用户点头的有几个。入口标签要专门报一声 ——
    /// 不报的话它跟「没有任务」长得一样，用户压根不会去点开看
    var needsConfirmCount: Int {
        currentItems.filter {
            if case .needsConfirm = $0.state { return true }
            return false
        }.count
    }

    /// 还没了结的：在跑的，和等用户点「换一家」的。这两种都不能清
    private func isPending(_ item: Item) -> Bool {
        if case .needsConfirm = item.state { return true }
        return item.isRunning
    }

    func add(id: UUID, title: String, kind: AIVideoService.ProviderCategory) {
        let cid = AIVideoService.shared.currentConversationId
        // **新一轮开始时，把上一轮已经了结的清掉**。原来只增不减，全靠用户
        // 自己点「清除已完成」，跑几轮之后列表全是历史，正在跑的反而要翻半天。
        //
        // 判据是「手上一个没了结的都没有」＝ 上一轮收工了。这样一轮里连提交好几个
        // 不会互相清掉，刚跑完的结果也能留着看一会儿，到下次开工才收走
        if !items.contains(where: { $0.conversationID == cid && isPending($0) }) {
            items.removeAll { $0.conversationID == cid && !isPending($0) }
        }
        // 别的会话的历史也不能无限攒着。留 50 条封顶，从最老的已了结的开始扔
        while items.count > 50, let old = items.lastIndex(where: { !isPending($0) }) {
            items.remove(at: old)
        }
        items.insert(Item(id: id, title: title, kind: kind,
                          conversationID: AIVideoService.shared.currentConversationId), at: 0)
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

    /// 这家没成，把「要不要改用另一家」摆到卡片上等用户点。
    /// 卡片一直在那儿，用户几分钟后回来也看得见；输入框上方那条确认栏
    /// 只在当前会话露脸，他要是切走了就永远错过了
    func askRetry(id: UUID, reason: String, nextName: String, retry: @escaping () -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .needsConfirm(reason: reason, nextName: nextName)
        items[i].pendingRetry = retry
    }

    func confirmRetry(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let go = items[i].pendingRetry
        items[i].pendingRetry = nil
        go?()
    }

    /// 用户说算了。按失败记账，理由照原样留着
    func declineRetry(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if case .needsConfirm(let reason, _) = items[i].state {
            items[i].state = .failed(reason)
        }
        items[i].pendingRetry = nil
        unreadFinished.append(items[i])
    }

    /// 换了一家重新提交：**同一张卡片接着用**。
    /// 不这么做的话用户会先看到一条「失败」再冒出一条新任务，
    /// 像是自己的活儿丢了、又莫名多出来一个
    func replace(oldID: UUID, newID: UUID, title: String,
                 kind: AIVideoService.ProviderCategory) {
        guard let i = items.firstIndex(where: { $0.id == oldID }) else {
            add(id: newID, title: title, kind: kind)
            return
        }
        // 开始时间沿用第一次提交的 —— 用户关心的是"这活儿等了多久"，
        // 不是"这次重试等了多久"
        items[i] = Item(id: newID, title: title, kind: kind,
                        conversationID: items[i].conversationID,
                        startedAt: items[i].startedAt,
                        state: .running, url: nil)
    }

    func cancel(id: UUID) {
        AIVideoService.shared.cancel(taskID: id)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let (title, kind) = (items[i].title, items[i].kind)
        // 不直接从列表里抹掉，改成记成「已取消」：卡片上看得见，
        // 模型查 list_background_tasks 也查得到。下一轮开工时会被自动清走
        items[i].state = .failed("已被用户取消")
        items[i].pendingRetry = nil
        // **取消不往会话里留话。**
        //
        // 试过留一句「用户取消了 X」，模型把它当成一件没办成的事主动补做：
        // 用户取消完再要 3 张，它提交「1 张（补的）+ 3 张」。
        // 在那句话里明写「不要补做、不要重新提交」也照样补。
        // 而列表堆积已经由 add() 里的自动清理解决了，这句话没有留下的必要
        _ = (title, kind)
    }

    /// 清掉**这条会话**已经结束的，留着在跑的。
    /// 按钮长在当前会话的面板上，不该顺手把别的会话的记录也扫了
    func clearFinished() {
        let cid = AIVideoService.shared.currentConversationId
        items.removeAll { !$0.isRunning && $0.conversationID == cid }
    }
}
