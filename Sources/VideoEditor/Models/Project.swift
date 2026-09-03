import SwiftUI
import AVFoundation
import MediaToolbox
import Accelerate
import Combine
import NaturalLanguage

// MARK: - Project State

final class ProjectState: ObservableObject {
    // Media
    /// 素材库转发口。数据本体在 `MediaLibrary.shared`，全 app 一份、多窗口共用。
    /// 保留这个同名属性是为了让原有 80 处调用点不用改；
    /// 变更通知靠 init 里订阅 `MediaLibrary.shared.$assets` 转发 objectWillChange
    var mediaAssets: [MediaAsset] {
        get { MediaLibrary.shared.assets }
        set { MediaLibrary.shared.assets = newValue }
    }

    // Tracks
    // 六种类型各留一条空轨。空项目就能看到完整的轨道结构，
    // 第一个素材直接落在对应的空轨上，不用先凭空多出一条轨道来
    /// 时间线标签页。**一个标签页 = 一整套轨道**，互不影响；
    /// 素材库是全项目共享的，删素材会影响所有标签页里引用它的片段
    @Published var tabs: [TimelineTab] = [TimelineTab(name: "时间线 1")]
    @Published var activeTab: Int = 0

    /// 下面这些都是当前标签页的轨道。
    /// 保留成同名属性，几千处调用方一行都不用改
    var videoTracks: [Track<VideoClip>] {
        get { tab.videoTracks } set { withTab { $0.videoTracks = newValue } }
    }
    var audioTracks: [Track<AudioClip>] {
        get { tab.audioTracks } set { withTab { $0.audioTracks = newValue } }
    }
    var imageTracks: [Track<ImageClip>] {
        get { tab.imageTracks } set { withTab { $0.imageTracks = newValue } }
    }
    var subtitleTracks: [Track<SubtitleClip>] {
        get { tab.subtitleTracks } set { withTab { $0.subtitleTracks = newValue } }
    }
    var textTracks: [Track<TextClip>] {
        get { tab.textTracks } set { withTab { $0.textTracks = newValue } }
    }
    var shapeTracks: [Track<ShapeClip>] {
        get { tab.shapeTracks } set { withTab { $0.shapeTracks = newValue } }
    }
    /// 滤镜轨道。多条 = 叠加，从下往上依次套
    var filterTracks: [Track<FilterClip>] {
        get { tab.filterTracks } set { withTab { $0.filterTracks = newValue } }
    }
    var adjustTracks: [Track<AdjustClip>] {
        get { tab.adjustTracks } set { withTab { $0.adjustTracks = newValue } }
    }
    var effectTracks: [Track<EffectClip>] {
        get { tab.effectTracks } set { withTab { $0.effectTracks = newValue } }
    }
    var compoundTracks: [Track<CompoundClip>] {
        get { tab.compoundTracks } set { withTab { $0.compoundTracks = newValue } }
    }

    /// 当前标签页。activeTab 万一越界就退回第一个，绝不崩
    var tab: TimelineTab {
        tabs.indices.contains(activeTab) ? tabs[activeTab] : (tabs.first ?? TimelineTab())
    }
    private func withTab(_ mutate: (inout TimelineTab) -> Void) {
        guard tabs.indices.contains(activeTab) else { return }
        mutate(&tabs[activeTab])
    }

    @Published var textTemplates: [TextTemplate] = []  // 文字样式模板
    @Published var selectedFilterClipID: UUID? = nil
    @Published var selectedAdjustClipID: UUID? = nil
    @Published var selectedEffectClipID: UUID? = nil
    @Published var selectedMarkerID: UUID? = nil

    // 复合片段编辑栈
    struct CompositionLevel {
        var name: String
        var snapshot: ProjectSnapshot
        var compoundTrackIndex: Int
        var compoundClipIndex: Int
        var activeStart: Double = 0
        var activeDuration: Double = .infinity
        var savedUndoStack: [ProjectSnapshot] = []
        var savedRedoStack: [ProjectSnapshot] = []
        var savedUndoCount: Int = 0
        var savedRedoCount: Int = 0
    }
    @Published var compositionStack: [CompositionLevel] = []
    var isInsideCompound: Bool { !compositionStack.isEmpty }

    enum OverlayTrackRef: Equatable, Codable {
        case image(UUID)
        case subtitle(UUID)
        case text(UUID)
        case shape(UUID)
        case filter(UUID)
        case adjust(UUID)
        case effect(UUID)
        case compound(UUID)

        var trackID: UUID {
            switch self {
            case .image(let id), .subtitle(let id), .text(let id), .shape(let id),
                 .filter(let id), .adjust(let id), .effect(let id),
                 .compound(let id): return id
            }
        }
    }

    /// 一帧要合成的 overlay 图层清单，**从底到顶**。
    ///
    /// 预览（OverlayStack）和导出（writerExport）必须走同一份，不能各自遍历
    /// `overlayTrackOrder`——因为那张表并不包含全部要画的东西：
    /// 按复合片段的归属规则，含视频的进 `videoSectionOrder`、只含音频的进
    /// `audioSectionOrder`，只有纯 overlay 内容的才进 `overlayTrackOrder`。
    /// 前两类的**内部** overlay（字幕/文字/图形/图片）仍然要烧到画面上，
    /// 得单独补进来，压在所有 overlay 之下——它们本质是视频层，overlay 层理应盖在其上。
    ///
    /// 曾经预览侧自己做了这个兜底而导出侧没有，于是复合片段里的字幕"预览有、导出没有"。
    /// 静态方法是因为导出跑在 nonisolated 上下文里，只有数据快照、拿不到 ProjectState 实例。
    ///
    /// - Returns: 从底到顶。调用方按这个顺序依次合成即可（后合成的盖在先合成的上面）
    static func overlayLayersBottomUp(
        overlayTrackOrder: [OverlayTrackRef],
        imageTracks: [Track<ImageClip>] = [],
        subtitleTracks: [Track<SubtitleClip>] = [],
        textTracks: [Track<TextClip>] = [],
        shapeTracks: [Track<ShapeClip>] = [],
        filterTracks: [Track<FilterClip>] = [],
        adjustTracks: [Track<AdjustClip>] = [],
        effectTracks: [Track<EffectClip>] = [],
        compoundTracks: [Track<CompoundClip>] = []
    ) -> [OverlayTrackRef] {
        // 没登记的一律补进来，压在最底下。不只是复合轨道——任何一条轨道只要
        // 没进 overlayTrackOrder 就会彻底不显示，而"渲染完全照这张表走"之后，
        // 表里漏一条的后果从"顺序不对"升级成"整条内容消失"
        let listed = Set(overlayTrackOrder.map(\.trackID))
        var unlisted: [OverlayTrackRef] = []
        for t in imageTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.image(t.id))
        }
        for t in subtitleTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.subtitle(t.id))
        }
        for t in textTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.text(t.id))
        }
        for t in shapeTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.shape(t.id))
        }
        for t in filterTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.filter(t.id))
        }
        for t in adjustTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.adjust(t.id))
        }
        for t in effectTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.effect(t.id))
        }
        for t in compoundTracks where t.isVisible && !listed.contains(t.id) {
            unlisted.append(.compound(t.id))
        }
        // overlayTrackOrder 是从顶到底存的（index 0 = 最上面），反过来即从底到顶
        return unlisted + overlayTrackOrder.reversed()
    }

    /// 叠加层在某一时刻的内容指纹。
    ///
    /// 光栅化的结果靠它判断要不要重画 —— 图层挪了、文字改了、字幕换了一条，
    /// 指纹就变。只盯参数不盯内容的话，改完画面还停在旧的那张图上
    func overlayContentKey(at t: Double) -> String {
        var out = ""
        for track in imageTracks where track.isVisible {
            for c in track.clips where c.startTime <= t && c.endTime > t {
                out += "i\(c.id)\(c.offsetX)\(c.offsetY)\(c.scaleX)\(c.scaleY)\(c.rotation)\(c.opacity ?? 1)\(c.cornerRadius ?? 0)"
            }
        }
        for track in textTracks where track.isVisible {
            for c in track.clips where c.startTime <= t && c.endTime > t {
                out += "t\(c.id)\(c.text)\(c.posX)\(c.posY)\(c.fontSize)\(c.rotation)\(c.opacity)"
            }
        }
        for track in shapeTracks where track.isVisible {
            for c in track.clips where c.startTime <= t && c.endTime > t {
                out += "s\(c.id)\(c.posX)\(c.posY)\(c.scaleX)\(c.scaleY)\(c.rotation)\(c.opacity)"
            }
        }
        for track in subtitleTracks where track.isVisible {
            for c in track.clips where c.startTime <= t && c.endTime > t {
                out += "b\(c.id)\(c.text)"
            }
        }
        return out
    }

    /// 顶层的 overlay 图层清单，从底到顶
    var overlayLayersBottomUp: [OverlayTrackRef] {
        Self.overlayLayersBottomUp(
            overlayTrackOrder: overlayTrackOrder,
            imageTracks: imageTracks, subtitleTracks: subtitleTracks,
            textTracks: textTracks, shapeTracks: shapeTracks,
            filterTracks: filterTracks, adjustTracks: adjustTracks,
            effectTracks: effectTracks, compoundTracks: compoundTracks)
    }

    enum CompoundTrackKind { case overlay, video, audio }

    func compoundTrackKind(_ track: Track<CompoundClip>) -> CompoundTrackKind {
        for clip in track.clips {
            if compoundHasVideo(clip) { return .video }
        }
        for clip in track.clips {
            if compoundHasAudio(clip) { return .audio }
        }
        return .overlay
    }

    func compoundHasVideo(_ compound: CompoundClip) -> Bool {
        if !compound.videoTracks.flatMap(\.clips).isEmpty { return true }
        for t in compound.compoundTracks {
            for c in t.clips { if compoundHasVideo(c) { return true } }
        }
        return false
    }

    func compoundHasAudio(_ compound: CompoundClip) -> Bool {
        if !compound.audioTracks.flatMap(\.clips).isEmpty { return true }
        for t in compound.compoundTracks {
            for c in t.clips { if compoundHasAudio(c) { return true } }
        }
        return false
    }
    /// Shift 在重叠处是在「循环加选」还是「循环减选」。
    /// 纯交互状态，不参与渲染，所以不用 @Published
    var shiftCycleRemoving = false
    /// Agent 跑一轮期间为 true：期间所有 pushUndo 都跳过，
    /// 整轮只在开跑前打一个快照（见 AgentRunner）
    var suppressUndoPush = false

    var overlayTrackOrder: [OverlayTrackRef] {
        get { tab.overlayTrackOrder } set { withTab { $0.overlayTrackOrder = newValue } }
    }

    // Codable：这两个要跟着项目文件存盘，否则复合片段重新打开后位置会跑掉
    enum VideoSectionRef: Equatable, Hashable, Codable {
        case video(UUID)
        case compound(UUID)
        var trackID: UUID { switch self { case .video(let id), .compound(let id): return id } }
    }
    enum AudioSectionRef: Equatable, Hashable, Codable {
        case audio(UUID)
        case compound(UUID)
        var trackID: UUID { switch self { case .audio(let id), .compound(let id): return id } }
    }
    var videoSectionOrder: [VideoSectionRef] {
        get { tab.videoSectionOrder } set { withTab { $0.videoSectionOrder = newValue } }
    }
    var audioSectionOrder: [AudioSectionRef] {
        get { tab.audioSectionOrder } set { withTab { $0.audioSectionOrder = newValue } }
    }

    func syncVideoSectionOrder() {
        var validIDs = Set<UUID>()
        for t in videoTracks { validIDs.insert(t.id) }
        for t in compoundTracks where compoundTrackKind(t) == .video { validIDs.insert(t.id) }
        var newOrder: [VideoSectionRef] = []
        for ref in videoSectionOrder where validIDs.contains(ref.trackID) {
            newOrder.append(ref); validIDs.remove(ref.trackID)
        }
        for t in videoTracks where validIDs.contains(t.id) { newOrder.append(.video(t.id)); validIDs.remove(t.id) }
        for t in compoundTracks where validIDs.contains(t.id) { newOrder.append(.compound(t.id)) }
        videoSectionOrder = newOrder
    }

    func syncAudioSectionOrder() {
        var validIDs = Set<UUID>()
        for t in audioTracks { validIDs.insert(t.id) }
        for t in compoundTracks where compoundTrackKind(t) == .audio { validIDs.insert(t.id) }
        var newOrder: [AudioSectionRef] = []
        for ref in audioSectionOrder where validIDs.contains(ref.trackID) {
            newOrder.append(ref); validIDs.remove(ref.trackID)
        }
        for t in audioTracks where validIDs.contains(t.id) { newOrder.append(.audio(t.id)); validIDs.remove(t.id) }
        for t in compoundTracks where validIDs.contains(t.id) { newOrder.append(.compound(t.id)) }
        audioSectionOrder = newOrder
    }

    func syncOverlayOrder() {
        var currentIDs = Set<UUID>()
        var newOrder: [OverlayTrackRef] = []
        for t in imageTracks { currentIDs.insert(t.id) }
        for t in subtitleTracks { currentIDs.insert(t.id) }
        for t in textTracks { currentIDs.insert(t.id) }
        for t in shapeTracks { currentIDs.insert(t.id) }
        for t in filterTracks { currentIDs.insert(t.id) }
        for t in adjustTracks { currentIDs.insert(t.id) }
        for t in effectTracks { currentIDs.insert(t.id) }
        for t in compoundTracks where compoundTrackKind(t) == .overlay { currentIDs.insert(t.id) }
        for ref in overlayTrackOrder {
            let rid: UUID
            switch ref {
            case .image(let id): rid = id
            case .subtitle(let id): rid = id
            case .text(let id): rid = id
            case .shape(let id): rid = id
            case .filter(let id): rid = id
            case .adjust(let id): rid = id
            case .effect(let id): rid = id
            case .compound(let id): rid = id
            }
            if currentIDs.contains(rid) { newOrder.append(ref); currentIDs.remove(rid) }
        }
        var newRefs: [OverlayTrackRef] = []
        for t in imageTracks where currentIDs.contains(t.id) { newRefs.append(.image(t.id)); currentIDs.remove(t.id) }
        for t in subtitleTracks where currentIDs.contains(t.id) { newRefs.append(.subtitle(t.id)); currentIDs.remove(t.id) }
        for t in textTracks where currentIDs.contains(t.id) { newRefs.append(.text(t.id)); currentIDs.remove(t.id) }
        for t in filterTracks where currentIDs.contains(t.id) { newRefs.append(.filter(t.id)); currentIDs.remove(t.id) }
        for t in adjustTracks where currentIDs.contains(t.id) { newRefs.append(.adjust(t.id)); currentIDs.remove(t.id) }
        for t in effectTracks where currentIDs.contains(t.id) { newRefs.append(.effect(t.id)); currentIDs.remove(t.id) }
        for t in shapeTracks where currentIDs.contains(t.id) { newRefs.append(.shape(t.id)); currentIDs.remove(t.id) }
        for t in compoundTracks where currentIDs.contains(t.id) { newRefs.append(.compound(t.id)); currentIDs.remove(t.id) }
        overlayTrackOrder = newRefs + newOrder
        syncVideoSectionOrder()
        syncAudioSectionOrder()
    }

    /// 新轨道插入到指定轨道的正上方（重叠自动新建时用）
    func insertOverlayRefAbove(_ newRef: OverlayTrackRef, above anchorTrackID: UUID) {
        syncOverlayOrder()
        overlayTrackOrder.removeAll { $0.trackID == newRef.trackID }
        if let idx = overlayTrackOrder.firstIndex(where: { $0.trackID == anchorTrackID }) {
            overlayTrackOrder.insert(newRef, at: idx)
        } else {
            overlayTrackOrder.insert(newRef, at: 0)
        }
    }

    var orderedSubtitleIndices: [Int] {
        var result: [Int] = []
        for ref in overlayTrackOrder {
            if case .subtitle(let id) = ref,
               let i = subtitleTracks.firstIndex(where: { $0.id == id }) {
                result.append(i)
            }
        }
        let existing = Set(result)
        for i in subtitleTracks.indices where !existing.contains(i) { result.append(i) }
        return result
    }

    @Published var subtitleBottomMargin: Double = 5   // 全局：所有字幕整体距下边缘 %
    @Published var subtitleLineSpacing: Double  = 6   // 全局：字幕轨道之间的间距 pt

    // Playback — 高频属性委托给 PlaybackClock，避免刷新全部视图
    let clock = PlaybackClock()
    var currentTime: Double {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    var duration: Double {
        get { clock.duration }
        set { clock.duration = newValue }
    }
    var isPlaying: Bool {
        get { clock.isPlaying }
        set { clock.isPlaying = newValue }
    }
    var lastVideoEndTime: Double {
        get { clock.lastVideoEndTime }
        set { clock.lastVideoEndTime = newValue }
    }
    var seekRequest: Int {
        get { clock.seekRequest }
        set { clock.seekRequest = newValue }
    }
    var pendingSeekTime: Double? {
        get { clock.pendingSeekTime }
        set { clock.pendingSeekTime = newValue }
    }
    @Published var playerItem: AVPlayerItem? = nil
    var videoClipTrackIDMap: [UUID: CMPersistentTrackID] = [:]

    // Timeline
    @Published var pixelsPerSecond: Double = 30
    weak var timelineHScrollView: NSScrollView?
    private var _zoomScrollTarget: Double? = nil
    private var _zoomWorkItem: DispatchWorkItem? = nil
    /// 变速音频临时文件缓存：key = "path|trimStart|srcDurSec|speed|trackIdx"
    var audioSpeedCache: [String: URL] = [:]
    /// 倒放视频临时文件缓存：key = "path|trimStart|srcDurSec"
    var reversedVideoCache: [String: URL] = [:]
    /// 本项目起的 ffmpeg 子进程的归属标记 —— 关窗时按它只收自己的
    let ffmpegOwnerID = UUID()
    /// 关窗收掉后置位：让正在跑的生成流程认出"这是被取消的"，而不是"失败了要重试"
    var ffmpegCancelled = false
    /// 窗口已关。关窗后这个对象还会被残留的 Task 持有一阵子，@Published 一变
    /// 又会调度新的预览重建、重建里再唤起倒放 —— 所有会起后台活儿的入口都查它
    var isShutDown = false
    @Published var snapEnabled: Bool = true
    @Published var showImageTracks: Bool = true
    var timelineVisibleWidth: Double = 800  // 由 GeometryReader 更新

    /// 所有轨道内容的实际最大结束时间
    var contentEndTime: Double {
        var maxEnd: Double = 0
        for t in videoTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in audioTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in imageTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in subtitleTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in textTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in shapeTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        // 复合片段也是时间轴上的内容。漏掉它，「缩放至适合」会把复合片段留在视口外，
        // 滚动区总宽和缩放下限也会算短
        for t in compoundTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        return maxEnd
    }

    /// 时间轴内容区的总宽度（像素）：内容长度 + 末尾余量。
    ///
    /// 余量给三屏而不是固定值，因为它同时决定两件事：能把素材拖到内容之后多远，
    /// 以及滚动条有多长（滚动条长度就是「视口 / 这个宽度」，余量太小时内容一短
    /// 滚动条就长得几乎占满整条轨道，看着不像能拖的东西）。
    ///
    /// 刻度尺和内容区必须用同一个值算，否则会出现「滚得过去但那截没有刻度」。
    func timelineContentWidth(viewportWidth: Double) -> Double {
        let contentSec = max(duration, contentEndTime)
        return contentSec * pixelsPerSecond + max(300, viewportWidth * 3)
    }

    /// 缩放下限：确保缩到最小时能完整显示所有内容并有富余
    var minPixelsPerSecond: Double {
        let content = contentEndTime
        guard content > 0 else { return 0.4 }
        // 让"内容 或 至少 15 秒范围"占可见区域 85%：
        // 只有图片/文字/图形这类短内容时，也能缩回秒显示（不再被短内容卡在帧显示）
        let end = max(content, 15)
        return (timelineVisibleWidth * 0.85) / end
    }

    /// 缩放至适合：让所有内容刚好填满时间轴可见区域，并回到开头。
    ///
    /// 回开头是必须的——缩放到"刚好装下全部内容"之后，视口本来就该对齐内容起点；
    /// 沿用 zoomTo 默认的"保持播放头相对位置"会让左边空出一截、右边被截掉，
    /// 反而看不全，跟这个操作的名字自相矛盾。
    func zoomToFit() {
        let end = contentEndTime
        guard end > 0 else {
            // 空时间轴：没有"内容"可以适配，但"回到开头"这半件事仍然该做，
            // 否则在空项目里点它毫无反应，看着像坏了
            if let sv = timelineHScrollView {
                sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
                sv.reflectScrolledClipView(sv.contentView)
            }
            return
        }
        let availableWidth = max(timelineVisibleWidth - 40, 100)
        zoomTo(availableWidth / end, scrollTo: 0)
    }

    /// - Parameter forcedX: 指定缩放后的横向滚动位置（内容坐标，pt）。
    ///   传 nil 走默认行为：保持播放头在视口里的相对位置不动。
    func zoomTo(_ newPPS: Double, scrollTo forcedX: Double? = nil) {
        let minPPS = min(minPixelsPerSecond, 3000)
        let clamped = newPPS.clamped(to: minPPS...3000)
        let oldPPS = pixelsPerSecond

        // 缩放比例没变（已经在这个档位上）时，如果调用方指定了滚动位置就只滚不缩。
        // 否则"缩放至合适"在已经合适的时候点下去会毫无反应，而用户要的是回到开头
        guard clamped != oldPPS else {
            if let x = forcedX, let sv = timelineHScrollView, let doc = sv.documentView {
                let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
                sv.contentView.setBoundsOrigin(NSPoint(x: min(max(0, x), maxX), y: 0))
                sv.reflectScrolledClipView(sv.contentView)
            }
            return
        }
        guard let sv = timelineHScrollView, let doc = sv.documentView else {
            pixelsPerSecond = clamped
            return
        }
        // 连续快速缩放时，用上次 pending target 而非实际滚动位置（因为上次 async 可能还没执行）
        let effectiveScrollX = _zoomScrollTarget ?? sv.contentView.bounds.origin.x
        let playheadInViewport = currentTime * oldPPS - effectiveScrollX
        let targetX = forcedX ?? max(0, currentTime * clamped - playheadInViewport)
        _zoomScrollTarget = targetX

        // ① 预扩容 documentView —— 防止 NSScrollView 在新 PPS 下把 scroll 位置 clamp 到旧的小内容宽度
        let newContentW = max(contentEndTime * clamped + 300, max(timelineVisibleWidth, 800))
        if newContentW > doc.frame.width {
            doc.setFrameSize(NSSize(width: newContentW, height: doc.frame.height))
        }
        // ② 同步设置 scroll —— SwiftUI 还没 re-render，先抢占正确位置
        let maxX1 = max(0, doc.frame.width - sv.contentView.bounds.width)
        sv.contentView.setBoundsOrigin(NSPoint(x: min(targetX, maxX1), y: 0))
        sv.reflectScrolledClipView(sv.contentView)

        // ③ 触发 SwiftUI 重新布局
        pixelsPerSecond = clamped

        // ④ 布局完成后修正（SwiftUI 可能覆盖了我们的 scroll）
        _zoomWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak sv] in
            guard let self = self, let sv = sv, let doc = sv.documentView,
                  let target = self._zoomScrollTarget else { return }
            self._zoomScrollTarget = nil
            let maxX2 = max(0, doc.frame.width - sv.contentView.bounds.width)
            sv.contentView.setBoundsOrigin(NSPoint(x: min(max(0, target), maxX2), y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }
        _zoomWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }
    @Published var showVideoTracks: Bool = true
    @Published var showAudioTracks: Bool = true
    @Published var showSubtitleTracks: Bool = true
    @Published var showTextTracks: Bool = true
    @Published var showShapeTracks: Bool = true
    @Published var showCompoundTracks: Bool = true

    // 删除确认
    @Published var showDeleteConfirm: Bool = false
    @Published var showAssetDeleteConfirm: Bool = false
    var pendingDeleteAssetID: UUID? = nil
    @Published var showClearLibraryConfirm: Bool = false

    // Selection (single — used by Inspector)
    @Published var selectedVideoClipID: UUID?    = nil
    @Published var selectedAudioClipID: UUID?    = nil
    @Published var selectedImageClipID: UUID?    = nil
    @Published var selectedSubtitleClipID: UUID? = nil
    @Published var selectedTextClipID: UUID?     = nil
    @Published var editingTextClipID: UUID?     = nil
    @Published var selectedShapeClipID: UUID?    = nil
    @Published var selectedCompoundClipID: UUID? = nil
    @Published var renamingCompoundClipID: UUID? = nil
    /// 源文件已经不在的素材。片段和卡片据此显示「素材丢失」。
    ///
    /// **必须缓存**：`MediaAsset.fileExists` 是计算属性，每次都发一次
    /// `FileManager` 查询。素材库几十项无所谓，时间轴上百个片段每帧渲染都查
    /// 就是几百次系统调用。这里存成集合，UI 只读它，刷新时机见 `refreshMissingAssets`
    @Published private(set) var missingAssetIDs: Set<UUID> = []

    /// 重新盘一遍哪些素材的文件没了。
    ///
    /// 调用时机：打开项目、导入素材、改名/重新关联之后、**app 重新激活时**
    /// （用户很可能刚在 Finder 里挪了文件或改了名）
    func refreshMissingAssets() {
        var missing = Set<UUID>()
        for a in mediaAssets where !FileManager.default.fileExists(atPath: a.url.path) {
            missing.insert(a.id)
        }
        guard missing != missingAssetIDs else { return }
        missingAssetIDs = missing
    }

    /// 监听素材库的删除/恢复广播。
    ///
    /// **素材库全 app 一份，时间轴却是每个窗口一份** —— 在 A 窗口删素材，
    /// B 窗口时间轴上引用它的片段还留着，指向一个已经不在库里的素材
    /// （实测：「多窗口删除时片段还留着删的素材」）。跟画布卡片同一个道理
    private func installLibraryObservers() {
        let center = NotificationCenter.default
        libraryObservers.append(center.addObserver(
            forName: .assetRemovedFromLibrary, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["assetID"] as? UUID,
                  note.userInfo?["origin"] as? UUID != self.instanceID   // 发起方自己已经删过了
            else { return }
            self.removeClipsReferencingAsset(id)
        })
        libraryObservers.append(center.addObserver(
            forName: .assetRestoredToLibrary, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["assetID"] as? UUID,
                  note.userInfo?["origin"] as? UUID != self.instanceID
            else { return }
            self.restoreClipsAfterAssetRestore(id)
        })
    }

    /// 别的窗口删了素材：把本窗口引用它的片段也清掉，先存一份备份好恢复
    private func removeClipsReferencingAsset(_ assetID: UUID) {
        guard clipCountForAsset(assetID) > 0 else { return }
        clipsRemovedByAssetDeletion[assetID] = currentSnapshot(includeAssets: false)
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll    { $0.assetID == assetID } }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll    { $0.assetID == assetID } }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll    { $0.assetID == assetID } }
        for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll { $0.assetID == assetID } }
        DiagLog.log("[素材库] 别的窗口删了素材，本窗口清掉引用它的片段")
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 发起方撤销了那次删除：本窗口的片段也回来
    private func restoreClipsAfterAssetRestore(_ assetID: UUID) {
        guard let snap = clipsRemovedByAssetDeletion.removeValue(forKey: assetID) else { return }
        applySnapshot(snap)
        DiagLog.log("[素材库] 别的窗口撤销了删除，本窗口片段恢复")
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 素材库里正在重命名的素材
    @Published var renamingAssetID: UUID? = nil
    /// 轨道区正在重命名的视频/图片/音频片段
    @Published var renamingClipID: UUID? = nil

    /// 改素材名 —— **一改全改**（用户 2026-08-25 要求）：磁盘文件名、素材名、
    /// 所有引用它的时间轴片段、画布上的卡片，一起换成新名字。扩展名强制不变。
    ///
    /// 这推翻了 v4.2.0「片段名和素材名两套独立」的设计：那时片段名是加进时间轴
    /// 那一刻拷过去的副本，之后各改各的。现在素材是唯一的真相源
    func renameAsset(id: UUID, to newName: String) {
        let input = newName.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
        let oldName = mediaAssets[i].name
        let oldURL = mediaAssets[i].url
        let ext = oldURL.pathExtension

        // 用户输入里若已带原扩展名就去掉，最后统一补回 —— 不允许改后缀
        let ns = input as NSString
        let base = ns.pathExtension.lowercased() == ext.lowercased() ? ns.deletingPathExtension : input
        guard !base.isEmpty else { return }
        let finalName = ext.isEmpty ? base : "\(base).\(ext)"
        guard finalName != mediaAssets[i].name else { return }

        let dir = oldURL.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(finalName)

        // 文件还在就改磁盘；改失败则整个操作放弃，避免素材名和文件名对不上
        if FileManager.default.fileExists(atPath: oldURL.path) {
            guard !FileManager.default.fileExists(atPath: newURL.path) else {
                showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                 title: "重命名失败", subtitle: "同目录下已存在 \(finalName)")
                return
            }
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "重命名失败", subtitle: error.localizedDescription,
                                 autoCountdown: false)
                return
            }
            // 文件路径变了，素材和所有引用它的片段一起改指向
            relinkAsset(id: id, newURL: newURL)
        } else {
            // 文件本来就不在（素材丢失状态下改名）：只改名字，不动路径。
            // 这条分支 `relinkAsset` 不会跑，所以要自己把通知发出去
            pushUndo()
            mediaAssets[i].name = finalName
            NotificationCenter.default.post(
                name: .mediaFileRelocated, object: nil,
                userInfo: ["assetID": id, "newName": finalName])
        }
        syncClipNames(assetID: id, to: finalName)
    }

    /// 所有引用这个素材的片段，名字一律跟着素材走 —— 包括复合片段内部那些。
    /// 单独改过名的片段也会被覆盖，这是定好的口径（素材是唯一真相源）
    private func syncClipNames(assetID: UUID, to name: String) {
        func fixVideo(_ tracks: inout [Track<VideoClip>]) {
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].assetID == assetID {
                    tracks[ti].clips[ci].name = name
                }
            }
        }
        func fixAudio(_ tracks: inout [Track<AudioClip>]) {
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].assetID == assetID {
                    tracks[ti].clips[ci].name = name
                }
            }
        }
        func fixImage(_ tracks: inout [Track<ImageClip>]) {
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].assetID == assetID {
                    tracks[ti].clips[ci].name = name
                }
            }
        }
        fixVideo(&videoTracks); fixAudio(&audioTracks); fixImage(&imageTracks)
        for ti in compoundTracks.indices {
            for ci in compoundTracks[ti].clips.indices {
                fixVideo(&compoundTracks[ti].clips[ci].videoTracks)
                fixAudio(&compoundTracks[ti].clips[ci].audioTracks)
                fixImage(&compoundTracks[ti].clips[ci].imageTracks)
            }
        }
    }

    /// 按片段 id 反查它用的素材。右键菜单判断「要不要给重新关联」用
    func assetIDOfSelectedClip(_ clipID: UUID) -> UUID? {
        assetID(ofClip: clipID)
    }

    /// 片段改名的统一入口。有重命名入口的只有视频/音频/图片三类
    /// （字幕、文字、图形片段本来就没有名字这个字段）。
    ///
    /// **素材还在库里就等于改素材** —— 磁盘文件、素材名、其它引用同一素材的片段、
    /// 画布卡片全部跟着变。
    ///
    /// 素材**不在库里**（片段的 assetID 悬空，比如素材被移除过）时退回只改片段自己：
    /// 不然 `renameAsset` 查不到素材会直接 return，表现是「改了名什么都没发生」
    func renameClipOrAsset(clipID: UUID, to newName: String) {
        if let aid = assetID(ofClip: clipID), mediaAssets.contains(where: { $0.id == aid }) {
            renameAsset(id: aid, to: newName)
        } else {
            renameClip(id: clipID, to: newName)
        }
    }

    private func assetID(ofClip id: UUID) -> UUID? {
        for t in videoTracks { if let c = t.clips.first(where: { $0.id == id }) { return c.assetID } }
        for t in audioTracks { if let c = t.clips.first(where: { $0.id == id }) { return c.assetID } }
        for t in imageTracks { if let c = t.clips.first(where: { $0.id == id }) { return c.assetID } }
        return nil
    }

    /// 改轨道片段标题，不动素材
    func renameClip(id: UUID, to newName: String) {
        let t = newName.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        for ti in videoTracks.indices {
            if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                guard videoTracks[ti].clips[ci].name != t else { return }
                pushUndo(); videoTracks[ti].clips[ci].name = t; return
            }
        }
        for ti in imageTracks.indices {
            if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                guard imageTracks[ti].clips[ci].name != t else { return }
                pushUndo(); imageTracks[ti].clips[ci].name = t; return
            }
        }
        for ti in audioTracks.indices {
            if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                guard audioTracks[ti].clips[ci].name != t else { return }
                pushUndo(); audioTracks[ti].clips[ci].name = t; return
            }
        }
    }
    @Published var penDrawingMode: Bool = false
    @Published var penEditingClipID: UUID? = nil
    var penRawPoints: [(x: Double, y: Double, cInDX: Double, cInDY: Double, cOutDX: Double, cOutDY: Double, smooth: Bool)] = []
    // Transition selection
    @Published var selectedTransitionClipID: UUID? = nil  // 当前选中的转场（clip ID，其 inTransition 被编辑）

    var selectedSubtitleClip: SubtitleClip? {
        guard let id = selectedSubtitleClipID else { return nil }
        for t in subtitleTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedTextClip: TextClip? {
        guard let id = selectedTextClipID else { return nil }
        for t in textTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedShapeClip: ShapeClip? {
        guard let id = selectedShapeClipID else { return nil }
        for t in shapeTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedVideoClip: VideoClip? {
        guard let id = selectedVideoClipID else { return nil }
        for t in videoTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedImageClip: ImageClip? {
        guard let id = selectedImageClipID else { return nil }
        for t in imageTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedAudioClip: AudioClip? {
        guard let id = selectedAudioClipID else { return nil }
        for t in audioTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
        return nil
    }

    var selectedCompoundClip: CompoundClip? {
        guard let id = selectedCompoundClipID else { return nil }
        for t in compoundTracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // 语音识别状态（Whisper）
    enum TranscribeState: Equatable {
        case idle
        case downloading(Double)  // 首次下载模型，进度 0~1
        case running(Double)      // 识别进度 0~1
        case done(Int)            // 生成字幕条数
        case failed(String)       // 失败原因
    }
    @Published var transcribeState: TranscribeState = .idle
    @Published var showWhisperModelPicker = false
    /// 识别前问「直接识别 / 识别+AI校对」的弹窗
    @Published var showTranscribeOptions = false

    /// 翻译的触发器。
    ///
    /// 翻译那两百来行逻辑长在工具栏的 TranslateToolGroup 里，依赖它自己的一堆私有辅助，
    /// 右键菜单够不着。这里放两个计数器当信号：右键菜单 +1，工具栏那边 onChange 收到就执行。
    /// 比把整套逻辑搬进 ProjectState 风险小得多
    @Published var translateSelectedTick = 0
    @Published var translateTrackTick = 0
    /// 校对用哪个文字模型（AIVideoService.Provider 的 rawValue）。
    /// 跟「AI 生成」共用配置，不再单独一套 Key
    @Published var transcribeAIModel = "deepseek-ai"
    @Published var selectedWhisperModel: WhisperTranscriber.ModelSize = .small
    var transcribeTask: Task<Void, Never>? = nil
    var isTranscribing: Bool {
        switch transcribeState {
        case .downloading, .running(_): return true
        default: return false
        }
    }
    func cancelTranscribe() {
        transcribeTask?.cancel()
        transcribeTask = nil
        WhisperTranscriber.killCurrentProcess()
        transcribeState = .idle
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "语音识别", subtitle: "已停止", autoCountdown: false)
    }
    // 音源分离状态（demucs）
    enum SeparateState: Equatable {
        case idle
        case downloading(Double)      // 首次下载模型，进度 0~1
        case running(Double, String)  // 处理进度 0~1 + 当前阶段
        case failed(String)
    }
    @Published var separateState: SeparateState = .idle
    var separateTask: Task<Void, Never>? = nil
    var isSeparatingAudio: Bool {
        switch separateState {
        case .downloading, .running: return true
        default: return false
        }
    }
    func cancelSeparate() {
        separateTask?.cancel()
        separateTask = nil
        AudioSeparator.killCurrentProcess()
        separateState = .idle
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "分离音轨", subtitle: "已停止", autoCountdown: false)
    }

    // 图片去背状态。BiRefNet 首次要加载几百 MB 模型，得让用户看见在干什么
    enum RemoveBackgroundState: Equatable {
        case idle
        case loadingModel     // 首次加载 CoreML 模型，最慢的一段
        case processing       // 推理 / 色键
        case composing        // 写文件 + 建轨道

        /// 没有细粒度进度可报，按阶段给个近似值，让进度条别停着不动
        var progress: Double {
            switch self {
            case .idle:         return 0
            case .loadingModel: return 0.25
            case .processing:   return 0.65
            case .composing:    return 0.92
            }
        }
    }

    // 字幕转语音进度
    @Published var speechTotal: Int = 0
    @Published var speechDone: Int = 0
    var speechTask: Task<Void, Never>? = nil
    var isGeneratingSpeech: Bool { speechTotal > 0 }

    @Published var removeBackgroundState: RemoveBackgroundState = .idle
    var removeBackgroundTask: Task<Void, Never>? = nil
    var isRemovingBackground: Bool { removeBackgroundState != .idle }

    func cancelRemoveBackground() {
        removeBackgroundTask?.cancel()
        removeBackgroundTask = nil
        removeBackgroundState = .idle
        showSuccessToast(icon: "stop.fill", iconColor: .yellow,
                         title: "去除背景", subtitle: "已停止", autoCountdown: false)
    }

    // 清晰度提升状态（FSRCNN）
    enum ClarityScale: Int, Equatable { case x2 = 2, x4 = 4 }

    enum ClarityEnhanceState: Equatable {
        case idle
        case downloadingModel(Double)
        case extractingFrames(Double)
        case inferring(Double)
        case encoding
        /// 云端引擎（fal.ai）。整段上传上去跑，没有帧级进度，只能按阶段推进，
        /// 所以进度和阶段名都由 FalUpscaleService.Stage 直接给出
        case cloud(progress: Double, stage: String)
        // 没有 .failed case：失败统一走 showSuccessToast 报错（跟本功能其它错误
        // 路径一致），这个状态机不需要单独携带失败态，见 whole-branch review：
        // 之前留着这个 case 是死代码，从没被赋值过，进度气泡里对应分支也永远
        // 渲染不到

        /// 卡片上显示的阶段名。时间轴那边用通知卡片，画布上用这个 —— 同一个状态机
        var canvasLabel: String {
            switch self {
            case .idle:                     return ""
            case .downloadingModel:         return "下载模型中…"
            case .extractingFrames:         return "抽帧中…"
            case .inferring:                return "超分中…"
            case .encoding:                 return "编码中…"
            case .cloud(_, let stage):      return stage
            }
        }

        /// 卡片上进度条的值
        var canvasProgress: Double {
            switch self {
            case .idle:                          return 0
            case .downloadingModel(let p):       return p
            case .extractingFrames(let p):       return p
            case .inferring(let p):              return p
            case .encoding:                      return 0.95
            case .cloud(let p, _):               return p
            }
        }

        /// 没有细粒度进度可报的阶段，按阶段给个近似值，让进度条别停着不动
        /// 各阶段在进度条上占的区间。这个分配必须反映**真实耗时占比**，不然进度条
        /// 就是在骗人——最早那版按"下载10% + 抽帧10% + 推理70% + 编码5%"分，是照
        /// 文件序列式那三个串行阶段设计的；改成管道式之后现实完全变了：
        ///  · 模型只有 20KB，而且通常早就下载过（只有 !isDownloaded 才走那个分支）
        ///  · 抽帧和推理在管道下是**同时**进行的，extractingFrames 只剩"探测尺寸 +
        ///    启动两个 ffmpeg 进程"，一瞬间就过去
        ///  · 编码同理，最后只剩 close stdin 之后的 flush + 写 moov box
        ///  · 真实情况是 99% 的时间都在 inferring
        /// 结果就是进度条一进来直接跳 20%，然后所有时间都在 20%~90% 之间爬。
        /// 现在让 inferring 几乎占满整条，前后只留一点点给真实存在的头尾。
        var approximateProgress: Double {
            switch self {
            case .idle:                    return 0
            case .downloadingModel(let p): return p * 0.02
            case .extractingFrames:        return 0.03
            case .inferring(let p):        return 0.03 + p * 0.94
            case .encoding:                return 0.99
            case .cloud(let p, _):         return p
            }
        }

        /// 云端阶段名（"上传中" / "排队中" / …）。本地引擎没有这一层，返回 nil。
        /// 云端在"处理中"会长时间停在同一个百分比上，光看进度条像卡死了，
        /// 得把当前在干什么显出来
        var cloudStage: String? {
            if case .cloud(_, let s) = self { return s }
            return nil
        }
    }
    @Published var clarityEnhanceState: ClarityEnhanceState = .idle
    /// 进度卡片上显示的"预计还需多久"（秒）。开工前用 estimatedMsPerFrame 给个
    /// 初值，跑起来之后换成按**实际速度**推算——实测速度比开工前的静态估算准得多，
    /// 而且会自我校正，不用担心估算模型跟真实机器有出入
    @Published var clarityETASeconds: Double? = nil
    /// 推理阶段真正开始的时刻，算实测速度用
    var clarityInferStartTime: Date? = nil
    /// 开工时就插好的那条占位轨道/片段。存在这里是为了让 cancelClarityEnhance()
    /// 能**立刻**把它撤掉——后台线程的取消检查点在每批开头，等它跑到再清理的话，
    /// 用户点完取消还要眼看着占位继续呼吸一会儿
    var clarityPlaceholderTrackID: UUID? = nil
    var clarityPlaceholderClipID: UUID? = nil
    var clarityEnhanceTask: Task<Void, Never>? = nil
    /// 处理流水线整体跑在专属线程上（不受 Swift Task 协作式取消管辖，
    /// 详见 Task 9 的设计说明），取消要靠这个跨线程共享标志
    var clarityCancelFlag: ClarityCancelFlag? = nil
    var isEnhancingClarity: Bool {
        switch clarityEnhanceState {
        case .idle: return false
        default: return true
        }
    }
    func cancelClarityEnhance() {
        clarityCancelFlag?.cancel()
        ClarityFrameIO.killCurrentProcess()
        // 云端任务光断本地是不够的——不通知 fal 取消的话它会把这单跑完，用户照样被扣钱
        FalUpscaleService.cancelCurrentTask()
        clarityEnhanceTask?.cancel()
        clarityEnhanceTask = nil
        clarityCancelFlag = nil
        clarityEnhanceState = .idle
        clarityETASeconds = nil
        clarityInferStartTime = nil
        // 占位轨道立刻撤掉，别让它在用户点完取消之后还继续呼吸
        if let cid = clarityPlaceholderClipID { placeholderClipIDs.remove(cid) }
        if let tid = clarityPlaceholderTrackID {
            videoTracks.removeAll { $0.id == tid }
            videoSectionOrder.removeAll { $0.trackID == tid }
        }
        clarityPlaceholderClipID = nil
        clarityPlaceholderTrackID = nil
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "清晰度提升", subtitle: "已停止", autoCountdown: false)
    }

    // MARK: - 场景检测 / 大模型分析
    @Published var isReversingVideo: Bool = false
    @Published var isDetectingScenes: Bool = false
    @Published var sceneDetectProgress: Double = 0
    var sceneDetectTask: Task<Void, Never>? = nil

    func cancelSceneDetect() {
        sceneDetectTask?.cancel()
        sceneDetectTask = nil
        SceneDetector.killCurrentProcess()
        isDetectingScenes = false
        sceneDetectProgress = 0
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "智能分割", subtitle: "已停止", autoCountdown: false)
    }

    @Published var isLLMAnalyzing: Bool = false
    @Published var llmAnalyzeProgress: Double = 0
    var llmAnalyzeTask: Task<Void, Never>? = nil

    func cancelLLMAnalyze() {
        llmAnalyzeTask?.cancel()
        llmAnalyzeTask = nil
        WhisperTranscriber.killCurrentProcess()
        isLLMAnalyzing = false
        llmAnalyzeProgress = 0
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "大模型分析", subtitle: "已停止", autoCountdown: false)
    }

    /// 侧边栏当前在看哪一栏：`ai` / `library`（素材库）/ `transition`（转场）。
    /// **默认 AI 生成** —— 进软件先落在这儿
    @Published var mediaLibraryTab: String = "ai"
    /// 素材库里的六个分类标签：video / audio / image / subtitle / text / shape。
    /// 原来这六类各占一个侧边栏图标，v5.3.0 合并进素材库，改成里面的标签页
    @Published var libraryCategory: String = "video"
    /// 「效果」栏下的分类：转场 / 滤镜 / 特效 / 调节
    @Published var effectCategory: String = "transition"
    /// 素材库用缩略图还是列表看。侧边栏和画布素材库**共用这一份**，
    /// 一边切了另一边跟着变（跟排序设置一个待遇）
    /// 缩略图 / 列表，**每个分类各记各的**。
    /// 原先是一个全局开关：在图片里切成列表，回到视频也跟着变成列表
    @Published var mediaGridModeByKey: [String: Bool] = [:]

    /// 侧边栏素材库当前分类用哪种视图
    var mediaGridMode: Bool {
        get { gridMode(for: libraryCategory) }
        set { setGridMode(newValue, for: libraryCategory) }
    }

    func gridMode(for key: String) -> Bool { mediaGridModeByKey[key] ?? true }
    func setGridMode(_ on: Bool, for key: String) { mediaGridModeByKey[key] = on }

    /// 项目封面的设计稿。属性区那个入口点开就是编辑它，
    /// 确认后渲染成 PNG 给欢迎页用（见 `ProjectCover`）
    @Published var cover: ProjectCover?
    /// 封面设计弹窗开着没
    @Published var showCoverDesigner = false

    /// 当前看的是哪类素材。只在素材库那一栏有意义；
    /// 文字/图形是预置面板、转场和 AI 更不是素材，都返回 nil
    var currentLibraryAssetType: AssetType? {
        guard mediaLibraryTab == "library" else { return nil }
        switch libraryCategory {
        case "video":    return .video
        case "audio":    return .audio
        case "image":    return .image
        case "subtitle": return .subtitle
        default:         return nil
        }
    }

    enum MediaSortOrder: String, CaseIterable {
        case name = "名称"
        case duration = "时长"
        case importDate = "导入时间"
        case fileSize = "文件大小"
    }
    @Published var mediaSortOrder: MediaSortOrder = .importDate
    @Published var mediaSortAscending: Bool = false
    @Published var mediaSearchText: String = ""
    // Multi-selection (used by box-select & bulk delete)
    @Published var selectedClipIDs: Set<UUID>    = []
    @Published var textClipViewSizes: [UUID: CGSize] = [:]

    // Clipboard for copy/cut/paste
    enum ClipboardItem {
        case video(VideoClip, trackIndex: Int)
        case audio(AudioClip, trackIndex: Int)
        case image(ImageClip, trackIndex: Int)
        case subtitle(SubtitleClip, trackIndex: Int)
        case text(TextClip, trackIndex: Int)
        case shape(ShapeClip, trackIndex: Int)
        case filter(FilterClip, trackIndex: Int)
        case effect(EffectClip, trackIndex: Int)
        case adjust(AdjustClip, trackIndex: Int)
        case compound(CompoundClip, trackIndex: Int)
    }
    var clipboard: [ClipboardItem] = []
    @Published var clipboardIsCut: Bool = false
    @Published var clipboardSourceIDs: Set<UUID> = []

    // Project file management
    @Published var projectName: String = "未命名项目"
    @Published var projectFileURL: URL? = nil
    @Published var showWelcome: Bool = true
    @Published var isSaved: Bool = false
    struct SaveToast: Identifiable, Equatable {
        let id = UUID()
        let path: String
    }
    @Published var saveToasts: [SaveToast] = []

    // 右上角成功提示（5s 倒计时自动消失）
    struct SuccessToastItem: Identifiable {
        let id = UUID()
        let icon: String
        let iconColor: Color
        let title: String
        let subtitle: String
        var countdown: Int = 5
        var autoCountdown: Bool = true
        var revealURL: URL? = nil
    }
    @Published var successToasts: [SuccessToastItem] = []
    var successTimer: Timer?

    func showSuccessToast(icon: String, iconColor: Color = .green, title: String, subtitle: String, autoCountdown: Bool = true, revealURL: URL? = nil) {
        let item = SuccessToastItem(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle, countdown: autoCountdown ? 5 : 0, autoCountdown: autoCountdown, revealURL: revealURL)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { successToasts.append(item) }
        if autoCountdown {
            startSuccessTimerIfNeeded()
        } else {
            let id = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dismissSuccessToast(id)
            }
        }
    }

    func dismissSuccessToast(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) { successToasts.removeAll { $0.id == id } }
        if successToasts.isEmpty { successTimer?.invalidate(); successTimer = nil }
    }

    func startSuccessTimerIfNeeded() {
        guard successTimer == nil else { return }
        successTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            for i in self.successToasts.indices.reversed() {
                guard self.successToasts[i].autoCountdown else { continue }
                self.successToasts[i].countdown -= 1
                if self.successToasts[i].countdown <= 0 {
                    withAnimation(.easeOut(duration: 0.25)) { self.successToasts.remove(at: i) }
                }
            }
            if self.successToasts.filter({ $0.autoCountdown }).isEmpty { timer.invalidate(); self.successTimer = nil }
        }
    }

    // 并发转码（最多5个同时运行，多余排队）
    static let maxConcurrentTranscodes = 5
    class TranscodeTask: ObservableObject, Identifiable {
        let id = UUID()
        let inputURL: URL
        let outputURL: URL
        let type: AssetType
        let displayName: String
        @Published var progress: Double = 0
        var process: Process?
        var isRunning: Bool = false
        var isCancelled: Bool = false
        init(inputURL: URL, outputURL: URL, type: AssetType, displayName: String) {
            self.inputURL = inputURL; self.outputURL = outputURL
            self.type = type; self.displayName = displayName
        }
    }
    @Published var activeTasks: [TranscodeTask] = []
    var pendingTasks: [TranscodeTask] = []
    @Published var isTranscoding: Bool = false
    @Published var transcodingFileName: String = ""
    @Published var transcodingProgress: Double = 0

    // Export
    @Published var exportSettings  = ExportSettings()
    @Published var showExportSheet = false
    /// AI 画布是否展开。每个窗口一份 —— 开关是界面状态，
    /// 画布**内容**是全局的（跟会话走，B5 接）
    @Published var showCanvas = false
    /// 聊天区点开的图片/视频，全屏查看用。nil 表示没在看
    @Published var mediaPreview: MediaPreviewItem?
    /// 画布的视图状态（缩放/平移/撤销栈）
    let canvas = CanvasState()
    @Published var showSettings = false
    /// 新建项目表单。菜单栏「新建项目」和欢迎页「新建项目」都开它——
    /// 菜单栏原来是把整个欢迎页调出来，等于让用户在已经打开项目的情况下
    /// 退回启动页再点一次，多绕一步
    @Published var showNewProjectSheet = false

    // Preview resolution (for subtitle/image scaling to match export)
    @Published var previewResolution: String = "1080p"
    static let previewResolutions = ExportSettings.resolutions

    /// 源文件实测尺寸（已应用 preferredTransform）。clip.videoWidth 在部分路径下
    /// 可能是 0 或未含旋转，不能作为唯一依据，这里按 URL 自己测一份
    @Published var nativeSizeCache: [URL: CGSize] = [:]
    private var loadingNativeSizes: Set<URL> = []

    /// 片段素材的原始尺寸。**不看 clip.rotation** —— 手动旋转是画布**内**的操作，
    /// 不该反过来把画布也翻过来（表现：分割后把后半段转 90°，16:9 的画布变成 9:16）。
    /// 素材自身的竖拍方向另有 preferredTransform 处理，见 loadNativeSize
    /// 片段画面**转正后**的尺寸（含 preferredTransform，不含用户旋转）。
    /// 预览上的裁剪框要用它 —— clip.videoWidth 存的是未转正的 naturalSize，
    /// 竖拍视频拿它画框会是横的，跟画面对不上
    func orientedSize(for clip: VideoClip) -> CGSize? { nativeSize(for: clip) }

    private func nativeSize(for clip: VideoClip) -> CGSize? {
        guard let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url else { return nil }
        if let cached = nativeSizeCache[url] { return cached }
        loadNativeSize(url)
        // 缓存未就绪时先用片段上的值顶着，加载完会刷新
        guard clip.videoWidth > 0, clip.videoHeight > 0 else { return nil }
        return CGSize(width: clip.videoWidth, height: clip.videoHeight)
    }

    private func loadNativeSize(_ url: URL) {
        // nativeVideoSize 是计算属性，SwiftUI 每次重绘都会走到这里，
        // 只靠 cache 判空挡不住异步写入前的重复启动
        guard nativeSizeCache[url] == nil, !loadingNativeSizes.contains(url) else { return }
        loadingNativeSizes.insert(url)
        Task { [weak self] in
            defer { Task { @MainActor in self?.loadingNativeSizes.remove(url) } }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let sz = try? await track.load(.naturalSize) else { return }
            // 竖屏素材常见 naturalSize 是横的，靠 preferredTransform 转正
            var final = sz
            if let tf = try? await track.load(.preferredTransform) {
                let applied = sz.applying(tf)
                final = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
            guard final.width > 0, final.height > 0 else { return }
            await MainActor.run { self?.nativeSizeCache[url] = final }
        }
    }

    /// 「原始」比例下画布用的源尺寸 —— 取**时间轴上第一个视频片段**。
    ///
    /// 以前是"选中片段优先"，于是画布会跟着选中和旋转到处变：把一个片段分成两半、
    /// 后半段转 90°，选中它画布就从 16:9 翻成 9:16，导出尺寸也就不固定了。
    /// 画布该由素材定、由项目定，不该由"现在选中谁"定。
    /// 导出那边同样取第一个可见视频片段（firstVideoClipID），两边对齐。
    var nativeVideoSize: CGSize? {
        // 多轨重叠时取上层（videoTracks 靠后的轨道压在上面），与导出一致只认可见轨
        let firstClip = videoTracks
            .filter(\.isVisible)
            .flatMap(\.clips)
            .min { $0.startTime < $1.startTime }
        if let c = firstClip, let s = nativeSize(for: c) { return s }
        // 可见轨里没有可用尺寸时，兜底扫一遍全部片段
        for clip in videoTracks.flatMap(\.clips) {
            if let s = nativeSize(for: clip) { return s }
        }
        return nil
    }

    /// 预览画面比例。"原始" = 跟随素材比例，"自定义" = 用 customOutputSize
    @Published var previewAspectRatio: String = "原始"
    /// 比例选「自定义」时的输出尺寸
    @Published var customOutputWidth: Int = 1920
    @Published var customOutputHeight: Int = 1080
    /// 项目级帧率 / 码率，导出时作为默认值
    @Published var projectFPS: Int = 30
    @Published var projectBitrate: Int = 5000
    /// 预览比例选「自定义」时，让项目设置里的尺寸输入框获得焦点
    @Published var focusCustomSizeField: Bool = false

    /// 清空选中，让属性区回到项目设置
    func clearSelectionForProjectSettings() {
        selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil
        selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil
        selectedCompoundClipID = nil; selectedTransitionClipID = nil
        selectedClipIDs.removeAll()
    }
    static let previewAspectRatios = ExportSettings.aspectRatios

    /// 与导出共用同一套换算：分辨率定短边，比例决定朝哪个方向长
    var previewRenderSize: CGSize {
        ExportSettings.outputSize(
            resolution: previewResolution,
            aspectRatio: previewAspectRatio,
            fallback: nativeVideoSize ?? CGSize(width: 1920, height: 1080),
            custom: CGSize(width: customOutputWidth, height: customOutputHeight))
    }

    static func parseAspect(_ s: String) -> CGFloat? { ExportSettings.parseAspect(s) }

    // Undo / Redo
    @Published var undoCount: Int = 0
    @Published var redoCount: Int = 0
    var undoStack: [ProjectSnapshot] = []
    var redoStack: [ProjectSnapshot] = []
    var lastUndoPushTime: Date = .distantPast

    // Debounce timer for preview rebuild (prevents flickering during interactive edits)
    var rebuildDebounceTimer: Timer?
    var rebuildTask: Task<Void, Never>?
    var lastRebuildFingerprint: Int = 0

    // Auto-save timer (debounced 3 seconds after last edit)
    var autoSaveTimer: Timer?

    // Thumbnail & Waveform cache
    @Published var mediaThumbnails: [UUID: NSImage] = [:]          // asset ID → single thumbnail (media library)
    @Published var assetThumbnails: [UUID: [ThumbnailFrame]] = [:] // asset ID → timeline thumbnail strip
    @Published var thumbnailsReloading: Set<UUID> = []              // 正在重建缩略图的 asset IDs
    /// 正在生成缩略图的 asset IDs。不用 @Published —— 只是防重入，不需要驱动 UI
    var thumbnailsGenerating: Set<UUID> = []
    /// 封面生成中的素材（防重复起线程：挂起机器上 UI 刷新会反复触发 loadMediaThumbnail）
    var coverGenerating: Set<UUID> = []
    /// 波形生成中的素材（防重复起线程，同上）
    var waveformGenerating: Set<UUID> = []
    @Published var waveformCache: [UUID: WaveformData] = [:]       // asset ID → waveform peaks
    var imageVideoCache: [UUID: URL] = [:]                         // asset ID → generated video file
    var avAssetCache: [URL: AVURLAsset] = [:]             // URL → cached AVURLAsset（避免重复创建）

    /// 获取或创建缓存的 AVURLAsset
    func cachedAVAsset(url: URL) -> AVURLAsset {
        if let cached = avAssetCache[url] { return cached }
        let asset = AVURLAsset(url: url)
        avAssetCache[url] = asset
        return asset
    }

    // Translation
    @Published var translationTargetLang: String = "中文（简体）"
    @Published var translatingTrackIDs: Set<UUID> = []
    @Published var translationProgress: Double = 0         // 0...1
    @Published var translationTotal: Int = 0               // 总字幕数
    @Published var translationDone: Int = 0                // 已完成数
    var translationTask: Task<Void, Never>? = nil

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        translationTotal = 0
        translationDone = 0
        translationProgress = 0
        translatingTrackIDs.removeAll()
        let pending = placeholderClipIDs
        placeholderClipIDs.removeAll()
        for ti in subtitleTracks.indices {
            subtitleTracks[ti].clips.removeAll { pending.contains($0.id) }
        }
        showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "翻译", subtitle: "已停止", autoCountdown: false)
    }
    /// 占位字幕 ID 集合（翻译中显示呼吸效果）
    @Published var placeholderClipIDs: Set<UUID> = []
    static let supportedLanguages = [
        "中文（简体）","中文（繁体）","English","日本語",
        "한국어","Français","Deutsch","Español",
        "Русский","العربية","Português","Italiano"
    ]

    var cancellables = Set<AnyCancellable>()

    /// 正在访问安全范围的 URL（app 退出时需要 stop）
    var accessedURLs: [URL] = []

    /// 字幕轨道要带样式，单独造一条
    static func makeEmptySubtitleTrack() -> Track<SubtitleClip> {
        var t = Track<SubtitleClip>(label: "字幕")
        t.subtitleStyle = SubtitleStyle()
        return t
    }

    /// 把默认那几条空轨排进各自的顺序表。
    /// 顺序表初始是空的，不排一遍这些轨道就没有稳定的上下位置
    func seedDefaultTrackOrder() {
        syncVideoSectionOrder()
        syncAudioSectionOrder()
        syncOverlayOrder()
    }

    /// 这个窗口自己的标识。删素材的广播靠它区分「我是发起方」还是「别的窗口」
    let instanceID = UUID()
    /// 因为素材库删除而删掉的片段备份（**别的窗口**才用得上）。
    /// 发起方那次删除进的是自己的撤销栈，能正常 ⌘Z；
    /// 别的窗口没参与那次操作，栈里没有对应的一步，只能存备份等恢复广播
    private var clipsRemovedByAssetDeletion: [UUID: ProjectSnapshot] = [:]
    private var libraryObservers: [Any] = []

    init() {
        seedDefaultTrackOrder()
        installLibraryObservers()
        // 素材库是全局的，加载和存盘都归 MediaLibrary 自己管。
        // 这里只把它的变更转成本对象的 objectWillChange，
        // 让所有读 project.mediaAssets 的视图照常刷新（另一个窗口改的也能收到）
        MediaLibrary.shared.$assets
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                // 别的窗口导入的素材，本窗口也得有缩略图 —— 缩略图缓存是
                // ProjectState 级的，只补缺的那些，已有的直接跳过
                DispatchQueue.main.async { self.refreshMediaLibrary() }
            }
            .store(in: &cancellables)
        // 冷启动/新建项目时，全局库是从磁盘读回来的，缩略图缓存还是空的。
        // 以前这一步由 loadSavedMediaLibrary() 顺带做，那条路已经并进 MediaLibrary，
        // 缩略图得在这里补，否则素材库里一片没有封面
        DispatchQueue.main.async { [weak self] in self?.refreshMediaLibrary() }
        syncVideoSectionOrder()
        syncAudioSectionOrder()
    }

    deinit {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// User-initiated playhead move — updates `currentTime` AND tells the
    /// player to seek (via `seekRequest` counter observed by PlayerView).
    func requestSeek(to t: Double) {
        currentTime = max(t, 0)
        seekRequest &+= 1
        selectedMarkerID = nil
    }

    // MARK: - Marker helpers

    struct MarkerAbsolute: Identifiable {
        var id: UUID { marker.id }
        var marker: Marker
        var absoluteTime: Double
    }

    var allMarkersAbsolute: [MarkerAbsolute] {
        var result: [MarkerAbsolute] = []
        func collect<C: Identifiable & Equatable & Codable>(_ tracks: [Track<C>], startTime: KeyPath<C, Double>, markers: KeyPath<C, [Marker]?>) {
            for track in tracks {
                for clip in track.clips {
                    for m in clip[keyPath: markers] ?? [] {
                        result.append(.init(marker: m, absoluteTime: clip[keyPath: startTime] + m.time))
                    }
                }
            }
        }
        collect(videoTracks, startTime: \.startTime, markers: \.markers)
        collect(audioTracks, startTime: \.startTime, markers: \.markers)
        collect(imageTracks, startTime: \.startTime, markers: \.markers)
        collect(subtitleTracks, startTime: \.startTime, markers: \.markers)
        collect(textTracks, startTime: \.startTime, markers: \.markers)
        collect(shapeTracks, startTime: \.startTime, markers: \.markers)
        collect(compoundTracks, startTime: \.startTime, markers: \.markers)
        return result
    }

    func addMarkerToSelectedClip() {
        let t = currentTime
        if let id = selectedVideoClipID, let clip = selectedVideoClip {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            updateVideoClip(id: id) { $0.markers = ($0.markers ?? []) + [m] }
            selectedMarkerID = m.id
        } else if let id = selectedAudioClipID, let clip = audioTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            for i in audioTracks.indices {
                if let j = audioTracks[i].clips.firstIndex(where: { $0.id == id }) {
                    audioTracks[i].clips[j].markers = (audioTracks[i].clips[j].markers ?? []) + [m]; break
                }
            }
            selectedMarkerID = m.id
        } else if let id = selectedImageClipID, let clip = imageTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            updateImageClip(id: id) { $0.markers = ($0.markers ?? []) + [m] }
            selectedMarkerID = m.id
        } else if let id = selectedSubtitleClipID, let clip = subtitleTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            for i in subtitleTracks.indices {
                if let j = subtitleTracks[i].clips.firstIndex(where: { $0.id == id }) {
                    subtitleTracks[i].clips[j].markers = (subtitleTracks[i].clips[j].markers ?? []) + [m]; break
                }
            }
            selectedMarkerID = m.id
        } else if let id = selectedTextClipID, let clip = textTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            for i in textTracks.indices {
                if let j = textTracks[i].clips.firstIndex(where: { $0.id == id }) {
                    textTracks[i].clips[j].markers = (textTracks[i].clips[j].markers ?? []) + [m]; break
                }
            }
            selectedMarkerID = m.id
        } else if let id = selectedShapeClipID, let clip = shapeTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            for i in shapeTracks.indices {
                if let j = shapeTracks[i].clips.firstIndex(where: { $0.id == id }) {
                    shapeTracks[i].clips[j].markers = (shapeTracks[i].clips[j].markers ?? []) + [m]; break
                }
            }
            selectedMarkerID = m.id
        } else if let id = selectedCompoundClipID, let clip = compoundTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            let offset = t - clip.startTime
            guard offset >= 0 && offset <= clip.duration else { return }
            pushUndo()
            let m = Marker(time: offset, title: "标记")
            for i in compoundTracks.indices {
                if let j = compoundTracks[i].clips.firstIndex(where: { $0.id == id }) {
                    compoundTracks[i].clips[j].markers = (compoundTracks[i].clips[j].markers ?? []) + [m]; break
                }
            }
            selectedMarkerID = m.id
        }
    }

    func removeMarker(id: UUID) {
        pushUndo()
        func removeFrom<C>(_ tracks: inout [Track<C>], markers: WritableKeyPath<C, [Marker]?>) -> Bool {
            for i in tracks.indices {
                for j in tracks[i].clips.indices {
                    if tracks[i].clips[j][keyPath: markers]?.contains(where: { $0.id == id }) == true {
                        tracks[i].clips[j][keyPath: markers]?.removeAll { $0.id == id }
                        return true
                    }
                }
            }
            return false
        }
        if removeFrom(&videoTracks, markers: \.markers) ||
           removeFrom(&audioTracks, markers: \.markers) ||
           removeFrom(&imageTracks, markers: \.markers) ||
           removeFrom(&subtitleTracks, markers: \.markers) ||
           removeFrom(&textTracks, markers: \.markers) ||
           removeFrom(&shapeTracks, markers: \.markers) ||
           removeFrom(&compoundTracks, markers: \.markers) {
            if selectedMarkerID == id { selectedMarkerID = nil }
        }
    }

    func updateMarker(id: UUID, _ modify: (inout Marker) -> Void) {
        func update<C>(_ tracks: inout [Track<C>], markers: WritableKeyPath<C, [Marker]?>) -> Bool {
            for i in tracks.indices {
                for j in tracks[i].clips.indices {
                    if let k = tracks[i].clips[j][keyPath: markers]?.firstIndex(where: { $0.id == id }) {
                        modify(&tracks[i].clips[j][keyPath: markers]![k])
                        return true
                    }
                }
            }
            return false
        }
        _ = update(&videoTracks, markers: \.markers) ||
            update(&audioTracks, markers: \.markers) ||
            update(&imageTracks, markers: \.markers) ||
            update(&subtitleTracks, markers: \.markers) ||
            update(&textTracks, markers: \.markers) ||
            update(&shapeTracks, markers: \.markers) ||
            update(&compoundTracks, markers: \.markers)
    }

    func findMarker(id: UUID) -> MarkerAbsolute? {
        allMarkersAbsolute.first { $0.id == id }
    }
}

// MARK: - 清晰度提升（跨线程取消标志）

final class ClarityCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
}
