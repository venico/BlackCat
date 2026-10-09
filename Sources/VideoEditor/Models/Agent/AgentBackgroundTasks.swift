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
        /// 这个任务该怎么取消。**画布卡片必须给** ——
        /// 它登记时用的 id 是卡片 id，不是生成任务 id，
        /// 拿卡片 id 去取消生成任务根本对不上号：任务照跑，卡片一直转圈（实测）
        var cancelAction: (() -> Void)?
        /// 后台接着做的那类任务，跑完的汇报原文。有它就按它报，不报「完成了：文件名」
        var resultText: String?
        /// 卡片上显示的类别。生成类用 kind 的名字；识别、配音这些不是生成，另给一个
        var label: String?
        var displayKind: String { label ?? kind.rawValue }

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

    func add(id: UUID, title: String, kind: AIVideoService.ProviderCategory,
             conversationID: UUID? = nil, label: String? = nil,
             cancelAction: (() -> Void)? = nil) {
        let cid = conversationID ?? AIVideoService.shared.agentConversationID
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
        var item = Item(id: id, title: title, kind: kind, conversationID: cid)
        item.cancelAction = cancelAction
        item.label = label
        items.insert(item, at: 0)
    }

    func finish(id: UUID, url: URL) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .done
        items[i].url = url
        report(items[i])
        resolveFollowUp(taskID: id, output: "文件 " + url.path, error: nil)
    }

    /// 不产出单个文件的活儿（识别出一条字幕轨、按镜头切开……）做完了，报它改了什么
    func finishWork(id: UUID, summary: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .done
        items[i].resultText = summary
        report(items[i])
        resolveFollowUp(taskID: id, output: summary, error: nil)
    }

    /// 登记一件「靠状态位看进度」的后台活儿：语音识别、配音、超分、导出……
    ///
    /// 这些活儿的底层函数只管开跑、不给回调，完成时只在右下角弹个提示，
    /// Agent 这边收不到 —— 连着做的后半截就断了。这里开跑后盯着 `busy`，
    /// 它一落下就比对前后的时间线，把「多了哪条轨、哪段被切开、素材库进了什么」
    /// 当结果报出来（`outcome` 给了就按它报）。
    ///
    /// - Returns: 任务 id；`busy` 一开始就是假（底层没起跑，比如缺组件、没选中）返回 nil
    @discardableResult
    func watch(title: String, label: String, project p: ProjectState,
               busy: @escaping () -> Bool,
               cancel: (() -> Void)? = nil,
               outcome: (() -> (ok: Bool, text: String)?)? = nil) -> UUID? {
        guard busy() else { return nil }
        let id = UUID()
        let before = TimelineDigest(p)
        add(id: id, title: title, kind: .text, label: label, cancelAction: cancel)
        Task { @MainActor [weak self, weak p] in
            while busy() { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let self,
                  let i = self.items.firstIndex(where: { $0.id == id }),
                  self.items[i].isRunning else { return }   // 用户点了取消，cancel() 已经记过账
            let r: (ok: Bool, text: String)
            if let own = outcome?() {
                r = own
            } else if let p {
                let diff = TimelineDigest(p).changes(since: before, in: p)
                r = diff.isEmpty ? (false, "没有产出，具体原因看右下角的提示") : (true, diff)
            } else {
                r = (false, "项目窗口已经关了")
            }
            if r.ok { self.finishWork(id: id, summary: r.text) } else { self.fail(id: id, r.text) }
        }
        return id
    }

    func fail(id: UUID, _ message: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .failed(message)
        report(items[i])
        resolveFollowUp(taskID: id, output: nil, error: message)
    }

    /// 在会话里说一声。
    ///
    /// **必须在这儿报，不能让界面去监听** —— 聊天面板同时有两份实例活着
    /// （侧栏一份、画布上那张卡片一份，共用同一个单例），各自监听就各报一遍，
    /// 用户看到的是同一条完成消息出现两次（实测）。
    /// 不是当前这条会话的先存着，等切回去再报
    private func report(_ item: Item) {
        guard item.conversationID == AIVideoService.shared.currentConversationId else {
            unreadFinished.append(item)
            return
        }
        switch item.state {
        case .done:
            if let r = item.resultText {
                AIVideoService.shared.appendAgentNote(item.title + "：" + r, kind: .taskDone)
                return
            }
            let name = item.url?.lastPathComponent ?? ""
            AIVideoService.shared.appendAgentNote(
                item.title + "完成了" + (name.isEmpty ? "。" : "：" + name), kind: .taskDone)
        case .failed(let why):
            AIVideoService.shared.appendAgentNote(item.title + "没成：" + why, kind: .taskFailed)
        default: break
        }
    }

    /// 切回某条会话时，把攒着的那些补报出来
    func flushUnread() {
        let cid = AIVideoService.shared.currentConversationId
        let mine = unreadFinished.filter { $0.conversationID == cid }
        guard !mine.isEmpty else { return }
        unreadFinished.removeAll { m in mine.contains { $0.id == m.id } }
        for item in mine { report(item) }
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
        report(items[i])
        resolveFollowUp(taskID: id, output: nil, error: "用户没让换家重试")
    }

    /// 换了一家重新提交：**同一张卡片接着用**。
    /// 不这么做的话用户会先看到一条「失败」再冒出一条新任务，
    /// 像是自己的活儿丢了、又莫名多出来一个
    func replace(oldID: UUID, newID: UUID, title: String,
                 kind: AIVideoService.ProviderCategory) {
        // 挂在旧任务上的「接着做」跟到新任务上，不然换家成功了也没人接着干
        for f in followUps.indices where followUps[f].waiting.remove(oldID) != nil {
            followUps[f].waiting.insert(newID)
            followUps[f].labels[newID] = followUps[f].labels[oldID]
        }
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
        // 登记时给了取消办法的（画布卡片）走它自己那条，
        // 否则按「id 就是生成任务 id」来取消
        if let custom = items.first(where: { $0.id == id })?.cancelAction {
            custom()
        } else {
            AIVideoService.shared.cancel(taskID: id)
        }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let (title, kind) = (items[i].title, items[i].kind)
        // 不直接从列表里抹掉，改成记成「已取消」：卡片上看得见，
        // 模型查 list_background_tasks 也查得到。下一轮开工时会被自动清走
        items[i].state = .failed("已被用户取消")
        items[i].pendingRetry = nil
        resolveFollowUp(taskID: id, output: nil, error: "已被用户取消")
        // **取消不往会话里留话。**
        //
        // 试过留一句「用户取消了 X」，模型把它当成一件没办成的事主动补做：
        // 用户取消完再要 3 张，它提交「1 张（补的）+ 3 张」。
        // 在那句话里明写「不要补做、不要重新提交」也照样补。
        // 而列表堆积已经由 add() 里的自动清理解决了，这句话没有留下的必要
        _ = (title, kind)
    }

    // MARK: - 做完之后接着做

    /// 生成任务上挂的「做完之后接着做的事」。
    ///
    /// Agent 提交生成就收工了（不干等），生成完只在会话里报一声，
    /// 「放到轨道上」这类后半截没人接 —— 用户得再说一遍。挂上这个之后，
    /// 等它挂的那几个任务都有了结果，自动起一个后台助手去把后半截做完。
    struct FollowUp {
        let id: UUID
        let instruction: String
        /// 还没出结果的任务。一次生成多张时是好几个，全部了结才开工，只跑一次
        var waiting: Set<UUID>
        /// 任务的补充说明（画布卡片 id 之类），交给后台助手找东西用
        var labels: [UUID: String]
        /// 了结的任务各产出了什么（「文件 /路径」或者一句改动说明）
        var done: [(label: String, output: String)] = []
        var failed: [String] = []
        let conversationID: UUID?
        let mode: AgentMode
        weak var project: ProjectState?
    }
    private var followUps: [FollowUp] = []

    /// 同时挂着（等生成 + 正在做）的「接着做」最多几个。
    /// 后台助手不能再生成，链不会自己往下长；这个上限防的是一次挂太多、
    /// 一齐起跑互相踩（都往同一条时间线末尾放）
    nonisolated static let maxFollowUps = 5
    /// 上限按会话算：这条会话挂满了不影响别的会话再挂
    var canAttachFollowUp: Bool {
        let cid = AIVideoService.shared.agentConversationID
        return followUps.filter { $0.conversationID == cid }.count < Self.maxFollowUps
    }

    func attachFollowUp(instruction: String, taskIDs: [UUID], labels: [UUID: String] = [:],
                        project: ProjectState, mode: AgentMode) {
        guard !taskIDs.isEmpty else { return }
        followUps.append(FollowUp(id: UUID(), instruction: instruction,
                                  waiting: Set(taskIDs), labels: labels,
                                  conversationID: AIVideoService.shared.agentConversationID,
                                  mode: mode, project: project))
    }

    /// 这个任务挂着的「接着做」写的是什么。查后台任务时一并报给模型
    func followUpInstruction(for taskID: UUID) -> String? {
        followUps.first { $0.waiting.contains(taskID) }?.instruction
    }

    private func resolveFollowUp(taskID: UUID, output: String?, error: String?) {
        guard let f = followUps.firstIndex(where: { $0.waiting.contains(taskID) }) else { return }
        followUps[f].waiting.remove(taskID)
        let label = followUps[f].labels[taskID] ?? ""
        if let output { followUps[f].done.append((label, output)) }
        else { followUps[f].failed.append(error ?? "没成") }
        guard followUps[f].waiting.isEmpty else { return }
        launch(followUps[f])
    }

    /// 每条会话最后排上队的那个后台助手，同一条会话的下一个等它跑完再开始。
    /// **按会话分开排**：不同会话的助手各干各的、可以同时跑，互不等待
    private var helperChains: [UUID: Task<Void, Never>] = [:]

    private func launch(_ fu: FollowUp) {
        let title = "接着做「" + String(fu.instruction.prefix(20)) + "」"
        guard !fu.done.isEmpty, let project = fu.project else {
            followUps.removeAll { $0.id == fu.id }
            AIVideoService.shared.appendAgentNote(
                title + "没做：" + (fu.done.isEmpty ? "前面的活儿没成，没有东西可接着用。"
                                                  : "发起它的项目窗口已经关了。"),
                kind: .taskFailed)
            return
        }
        var context = "刚才后台的活儿做完了：\n"
        for d in fu.done {
            context += "- " + d.output + (d.label.isEmpty ? "" : "（\(d.label)）") + "\n"
        }
        if !fu.failed.isEmpty {
            context += "另有 \(fu.failed.count) 个没成：" + fu.failed.joined(separator: "；") + "\n"
        }
        context += "\n要接着做的事：" + fu.instruction
        let cid = fu.conversationID
        // 后台助手**排队一个一个做**。一次提交几张图、各挂「放到时间轴末尾」时，
        // 几个助手同时跑会读到同一个「末尾」，片段叠在一起
        let chainKey = cid ?? fu.id
        let previous = helperChains[chainKey]
        let work = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else {
                self?.followUps.removeAll { $0.id == fu.id }
                return
            }
            let r = await AgentRunner.shared.runFollowUp(prompt: context, mode: fu.mode,
                                                         project: project, convID: cid ?? UUID())
            guard let self else { return }
            self.followUps.removeAll { $0.id == fu.id }
            guard let i = self.items.firstIndex(where: { $0.id == fu.id }),
                  self.items[i].isRunning else { return }   // 用户点了取消就不再报
            self.items[i].state = r.ok ? .done : .failed(r.text)
            self.items[i].resultText = r.ok ? r.text : nil
            self.report(self.items[i])
        }
        helperChains[chainKey] = work
        add(id: fu.id, title: title, kind: .text, conversationID: cid, label: "后台助手",
            cancelAction: { work.cancel() })
    }

    /// 清掉**这条会话**已经结束的，留着在跑的。
    /// 按钮长在当前会话的面板上，不该顺手把别的会话的记录也扫了
    func clearFinished() {
        let cid = AIVideoService.shared.currentConversationId
        items.removeAll { !$0.isRunning && $0.conversationID == cid }
    }
}

/// 时间线的粗略快照。一件后台活儿做完，前后一比就知道它产出了什么，
/// 不用每个底层函数各自开个回调
@MainActor
struct TimelineDigest {
    private var tracks: [UUID: (kind: String, label: String, count: Int)] = [:]
    private var order: [UUID] = []
    private var assets: Set<UUID> = []

    init(_ p: ProjectState) {
        func put<C>(_ ts: [Track<C>], _ kind: String) {
            for t in ts { tracks[t.id] = (kind, t.label, t.clips.count); order.append(t.id) }
        }
        put(p.videoTracks, "视频"); put(p.audioTracks, "音频"); put(p.subtitleTracks, "字幕")
        put(p.imageTracks, "图片"); put(p.textTracks, "文字"); put(p.shapeTracks, "图形")
        assets = Set(p.mediaAssets.map(\.id))
    }

    /// 比 `old` 多了什么。没变化返回空串
    func changes(since old: TimelineDigest, in p: ProjectState) -> String {
        var out: [String] = []
        for id in order {
            guard let t = tracks[id] else { continue }
            let name = t.label.isEmpty ? "" : "「\(t.label)」"
            if let o = old.tracks[id] {
                if o.count != t.count { out.append("\(t.kind)轨\(name)片段 \(o.count) → \(t.count) 段") }
            } else {
                out.append("新增\(t.kind)轨\(name)（\(t.count) 段）")
            }
        }
        let added = p.mediaAssets.filter { !old.assets.contains($0.id) }
        if !added.isEmpty {
            out.append("素材库新增 " + added.map { "「\($0.name)」(\($0.url.path))" }.joined(separator: "、"))
        }
        return out.joined(separator: "；")
    }
}
