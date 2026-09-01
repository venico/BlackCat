// ProjectState+Tabs.swift
//
// 时间线标签页的增删切换。
//
// **关闭和删除是两回事**：关闭只把标签从栏上收起来，时间线数据还在，
// 从「更多 → 显示所有标签页」能全部拿回来；删除才是真的把这条时间线丢掉。

import Foundation

extension ProjectState {

    /// 标签栏上显示的那些（按 tabs 里的顺序）
    var openTabs: [TimelineTab] { tabs.filter(\.isTabOpen) }

    /// 新建一条时间线，切过去
    @discardableResult
    func addTimelineTab() -> UUID {
        pushUndo()
        // 名字取没被占用的最小编号，关掉再开也不会撞名
        var n = tabs.count + 1
        let used = Set(tabs.map(\.name))
        while used.contains("时间线 \(n)") { n += 1 }
        var t = TimelineTab(name: "时间线 \(n)")
        t.isTabOpen = true
        tabs.append(t)
        activateTab(tabs.count - 1)
        isSaved = false
        return t.id
    }

    /// 切到第 i 个标签页
    func switchToTab(_ i: Int) {
        guard tabs.indices.contains(i), i != activeTab else { return }
        activateTab(i)
    }

    /// 真正切过去。**顺序表必须补齐再重建** ——
    /// 轨道区是照 overlayTrackOrder / videoSectionOrder 画的，
    /// 新建的标签页那三张表都是空的，不补的话轨道一条都不显示
    private func activateTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        // 选中态是跟着轨道走的，切过去之后那些 id 在新标签页里根本不存在
        clearClipSelections()
        selectedClipIDs.removeAll()
        activeTab = i
        if !tabs[i].isTabOpen { tabs[i].isTabOpen = true }
        syncOverlayOrder()
        rebuildTimelinePreview()
    }

    func switchToTab(id: UUID) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { switchToTab(i) }
    }

    /// 关闭标签页：只是收起来，时间线还在
    func closeTab(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].isTabOpen = false
        isSaved = false
        // 关掉的正好是当前这个，就落到旁边还开着的那个上
        if i == activeTab, let next = nextOpenTab(from: i) { switchToTab(next) }
    }

    func closeAllTabs() {
        pushUndo()
        for i in tabs.indices { tabs[i].isTabOpen = false }
        isSaved = false
    }

    func showAllTabs() {
        for i in tabs.indices { tabs[i].isTabOpen = true }
        isSaved = false
    }

    /// 删除时间线：连数据一起丢掉。
    /// 最后一条也能删 —— 删完补一条全新的空时间线，
    /// 轨道区不该出现「一个时间线都没有」的状态
    func deleteTab(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        tabs.remove(at: i)
        if tabs.isEmpty { tabs = [TimelineTab(name: "时间线 1")] }
        activeTab = min(max(activeTab, 0), tabs.count - 1)
        isSaved = false
        activateTab(activeTab)
    }

    func renameTab(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        tabs[i].name = trimmed
        isSaved = false
    }

    /// 从第 i 个往两边找一个还开着的
    private func nextOpenTab(from i: Int) -> Int? {
        for j in stride(from: i + 1, to: tabs.count, by: 1) where tabs[j].isTabOpen { return j }
        for j in stride(from: i - 1, through: 0, by: -1) where tabs[j].isTabOpen { return j }
        return nil
    }
}
