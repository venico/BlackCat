import SwiftUI
import AVFoundation
import MediaToolbox
import Accelerate
import Combine
import NaturalLanguage

// MARK: - Project State

final class ProjectState: ObservableObject {
    // Media
    @Published var mediaAssets: [MediaAsset] = []

    // Tracks
    @Published var videoTracks: [Track<VideoClip>]    = [Track(label: "视频")]
    @Published var audioTracks: [Track<AudioClip>]    = []
    @Published var imageTracks: [Track<ImageClip>]       = []
    @Published var subtitleTracks: [Track<SubtitleClip>] = []
    @Published var textTracks: [Track<TextClip>] = []
    @Published var textTemplates: [TextTemplate] = []  // 文字样式模板
    @Published var shapeTracks: [Track<ShapeClip>] = []  // 图形图层
    @Published var compoundTracks: [Track<CompoundClip>] = []
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
        case compound(UUID)

        var trackID: UUID {
            switch self {
            case .image(let id), .subtitle(let id), .text(let id), .shape(let id), .compound(let id): return id
            }
        }
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
    @Published var overlayTrackOrder: [OverlayTrackRef] = []

    enum VideoSectionRef: Equatable, Hashable {
        case video(UUID)
        case compound(UUID)
        var trackID: UUID { switch self { case .video(let id), .compound(let id): return id } }
    }
    enum AudioSectionRef: Equatable, Hashable {
        case audio(UUID)
        case compound(UUID)
        var trackID: UUID { switch self { case .audio(let id), .compound(let id): return id } }
    }
    @Published var videoSectionOrder: [VideoSectionRef] = []
    @Published var audioSectionOrder: [AudioSectionRef] = []

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
        for t in compoundTracks where compoundTrackKind(t) == .overlay { currentIDs.insert(t.id) }
        for ref in overlayTrackOrder {
            let rid: UUID
            switch ref {
            case .image(let id): rid = id
            case .subtitle(let id): rid = id
            case .text(let id): rid = id
            case .shape(let id): rid = id
            case .compound(let id): rid = id
            }
            if currentIDs.contains(rid) { newOrder.append(ref); currentIDs.remove(rid) }
        }
        var newRefs: [OverlayTrackRef] = []
        for t in imageTracks where currentIDs.contains(t.id) { newRefs.append(.image(t.id)); currentIDs.remove(t.id) }
        for t in subtitleTracks where currentIDs.contains(t.id) { newRefs.append(.subtitle(t.id)); currentIDs.remove(t.id) }
        for t in textTracks where currentIDs.contains(t.id) { newRefs.append(.text(t.id)); currentIDs.remove(t.id) }
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
        return maxEnd
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

    /// 缩放至适合：让所有内容刚好填满时间轴可见区域
    func zoomToFit() {
        let end = contentEndTime
        guard end > 0 else { return }
        let availableWidth = max(timelineVisibleWidth - 40, 100)
        zoomTo(availableWidth / end)
    }

    func zoomTo(_ newPPS: Double) {
        let minPPS = min(minPixelsPerSecond, 3000)
        let clamped = newPPS.clamped(to: minPPS...3000)
        let oldPPS = pixelsPerSecond
        guard clamped != oldPPS else { return }
        guard let sv = timelineHScrollView, let doc = sv.documentView else {
            pixelsPerSecond = clamped
            return
        }
        // 连续快速缩放时，用上次 pending target 而非实际滚动位置（因为上次 async 可能还没执行）
        let effectiveScrollX = _zoomScrollTarget ?? sv.contentView.bounds.origin.x
        let playheadInViewport = currentTime * oldPPS - effectiveScrollX
        let targetX = max(0, currentTime * clamped - playheadInViewport)
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
    /// 素材库里正在重命名的素材
    @Published var renamingAssetID: UUID? = nil
    /// 轨道区正在重命名的视频/图片/音频片段
    @Published var renamingClipID: UUID? = nil

    /// 改素材名，同时重命名磁盘文件。扩展名强制保持不变。
    /// 片段与素材靠 assetID 关联，改名不影响关联；已在轨道上的片段保留自己的标题
    func renameAsset(id: UUID, to newName: String) {
        let input = newName.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
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
            pushUndo()
            mediaAssets[i].name = finalName
        }
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

    @Published var mediaLibraryTab: String = "video"      // 素材库当前标签（提升到 ProjectState，转场图标点击可切换）
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
    /// Toast message for import feedback (e.g. duplicate file skipped)
    @Published var importToastMessage: String? = nil

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
    @Published var showSettings = false

    // Preview resolution (for subtitle/image scaling to match export)
    @Published var previewResolution: String = "1080p"
    static let previewResolutions = ExportSettings.resolutions

    /// 源文件实测尺寸（已应用 preferredTransform）。clip.videoWidth 在部分路径下
    /// 可能是 0 或未含旋转，不能作为唯一依据，这里按 URL 自己测一份
    @Published var nativeSizeCache: [URL: CGSize] = [:]
    private var loadingNativeSizes: Set<URL> = []

    private func nativeSize(for clip: VideoClip) -> CGSize? {
        guard let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url else { return nil }
        if let cached = nativeSizeCache[url] { return applyRotation(cached, clip.rotation) }
        loadNativeSize(url)
        // 缓存未就绪时先用片段上的值顶着，加载完会刷新
        guard clip.videoWidth > 0, clip.videoHeight > 0 else { return nil }
        return applyRotation(CGSize(width: clip.videoWidth, height: clip.videoHeight), clip.rotation)
    }

    private func applyRotation(_ size: CGSize, _ rotation: Int) -> CGSize {
        abs(rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
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

    /// 「原始」预览用的源尺寸。选中片段优先 —— selectedVideoClipID 是 @Published，
    /// 选中即刻重绘；currentTime 走独立的 PlaybackClock，不触发本对象刷新，只能兜底
    var nativeVideoSize: CGSize? {
        let allClips = videoTracks.flatMap(\.clips)

        if let id = selectedVideoClipID,
           let clip = allClips.first(where: { $0.id == id }),
           let s = nativeSize(for: clip) { return s }

        // 播放头命中的片段，多轨重叠时取上层（videoTracks 靠后的轨道压在上面）
        let t = currentTime
        for track in videoTracks.reversed() {
            for clip in track.clips where clip.startTime <= t && clip.endTime > t {
                if let s = nativeSize(for: clip) { return s }
            }
        }
        for clip in allClips {
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

    static let mediaLibraryKey = "savedMediaBookmarks"
    /// 正在访问安全范围的 URL（app 退出时需要 stop）
    var accessedURLs: [URL] = []

    init() {
        loadSavedMediaLibrary()
        $mediaAssets
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] assets in
                self?.saveMediaLibrary(assets)
            }
            .store(in: &cancellables)
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
