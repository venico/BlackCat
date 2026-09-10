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
        // 复合片段栈挂在 ProjectState 上，是全局一份、不跟着标签页走。
        // 不先退出来的话，在标签 1 里进了复合片段，切到标签 2 那个栈还在，
        // 面包屑就跟过去了。退出会把内容写回所在标签页，切走前先收干净
        while isInsideCompound { exitCompound() }
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
        // 全关掉就没有「当前在哪条时间线里」了，复合片段的面包屑也得跟着收
        while isInsideCompound { exitCompound() }
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
        // 数据都要丢了，栈直接清掉，别走 exitCompound —— 那条路会把复合片段的
        // 内容写回轨道，写进删完新补的那条空时间线里
        if i == activeTab { compositionStack.removeAll() }
        tabs.remove(at: i)
        if tabs.isEmpty { tabs = [TimelineTab(name: "时间线 1")] }
        activeTab = min(max(activeTab, 0), tabs.count - 1)
        isSaved = false
        activateTab(activeTab)
    }

    /// 复制一条时间线，插在被复制的那条后面并切过去。
    ///
    /// 轨道 id 和片段 id **全部换新**：两条时间线里出现同一个 id，选中态、
    /// 预览的片段-轨道映射这些按 id 找东西的地方就会串台。
    /// 换了轨道 id，三张顺序表（overlay / video / audio）里的引用必须跟着改，
    /// 漏改的表现是复制出来的时间线轨道一条都不显示。
    /// 复合片段**内部**的 id 不动 —— 它自带一套自己的顺序表，是自包含的
    func duplicateTab(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        // 复合片段栈是全局一份，复制前先收干净，免得内容写进复制出来的那条
        while isInsideCompound { exitCompound() }

        var copy = tabs[i]
        copy.id = UUID()
        copy.isTabOpen = true
        var base = tabs[i].name + " 复制"
        let used = Set(tabs.map(\.name))
        if used.contains(base) {
            var n = 2
            while used.contains("\(base) \(n)") { n += 1 }
            base = "\(base) \(n)"
        }
        copy.name = base

        var map: [UUID: UUID] = [:]
        copy.videoTracks     = ProjectState.reIDTracks(copy.videoTracks, &map)
        copy.audioTracks     = ProjectState.reIDTracks(copy.audioTracks, &map)
        copy.imageTracks     = ProjectState.reIDTracks(copy.imageTracks, &map)
        copy.subtitleTracks  = ProjectState.reIDTracks(copy.subtitleTracks, &map)
        copy.textTracks      = ProjectState.reIDTracks(copy.textTracks, &map)
        copy.shapeTracks     = ProjectState.reIDTracks(copy.shapeTracks, &map)
        copy.filterTracks    = ProjectState.reIDTracks(copy.filterTracks, &map)
        copy.adjustTracks    = ProjectState.reIDTracks(copy.adjustTracks, &map)
        copy.effectTracks    = ProjectState.reIDTracks(copy.effectTracks, &map)
        copy.compoundTracks  = ProjectState.reIDTracks(copy.compoundTracks, &map)

        copy.overlayTrackOrder = copy.overlayTrackOrder.map { ref in
            guard let n = map[ref.trackID] else { return ref }
            switch ref {
            case .image:    return .image(n)
            case .subtitle: return .subtitle(n)
            case .text:     return .text(n)
            case .shape:    return .shape(n)
            case .filter:   return .filter(n)
            case .adjust:   return .adjust(n)
            case .effect:   return .effect(n)
            case .compound: return .compound(n)
            }
        }
        copy.videoSectionOrder = copy.videoSectionOrder.map { ref in
            guard let n = map[ref.trackID] else { return ref }
            switch ref {
            case .video:    return .video(n)
            case .compound: return .compound(n)
            }
        }
        copy.audioSectionOrder = copy.audioSectionOrder.map { ref in
            guard let n = map[ref.trackID] else { return ref }
            switch ref {
            case .audio:    return .audio(n)
            case .compound: return .compound(n)
            }
        }

        tabs.insert(copy, at: i + 1)
        isSaved = false
        activateTab(i + 1)
    }

    /// 轨道和片段换一批新 id，顺带把「老轨道 id → 新轨道 id」记进 map 供顺序表重映射
    static func reIDTracks<C: UUIDIdentified>(_ tracks: [Track<C>],
                                              _ map: inout [UUID: UUID]) -> [Track<C>] {
        tracks.map { t in
            var nt = t
            let newID = UUID()
            map[t.id] = newID
            nt.id = newID
            nt.clips = t.clips.map { var c = $0; c.id = UUID(); return c }
            return nt
        }
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


/// 片段的 id 可以就地换掉（复制时间线要用）
protocol UUIDIdentified: Identifiable, Equatable, Codable {
    var id: UUID { get set }
}

extension VideoClip: UUIDIdentified {}
extension AudioClip: UUIDIdentified {}
extension ImageClip: UUIDIdentified {}
extension SubtitleClip: UUIDIdentified {}
extension TextClip: UUIDIdentified {}
extension ShapeClip: UUIDIdentified {}
extension FilterClip: UUIDIdentified {}
extension AdjustClip: UUIDIdentified {}
extension EffectClip: UUIDIdentified {}
extension CompoundClip: UUIDIdentified {}
