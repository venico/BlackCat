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

    enum OverlayTrackRef: Equatable, Codable {
        case image(UUID)
        case subtitle(UUID)
        case text(UUID)

        var trackID: UUID {
            switch self {
            case .image(let id), .subtitle(let id), .text(let id): return id
            }
        }
    }
    @Published var overlayTrackOrder: [OverlayTrackRef] = []

    func syncOverlayOrder() {
        var currentIDs = Set<UUID>()
        var newOrder: [OverlayTrackRef] = []
        for t in imageTracks { currentIDs.insert(t.id) }
        for t in subtitleTracks { currentIDs.insert(t.id) }
        for t in textTracks { currentIDs.insert(t.id) }
        for ref in overlayTrackOrder {
            let rid: UUID
            switch ref {
            case .image(let id): rid = id
            case .subtitle(let id): rid = id
            case .text(let id): rid = id
            }
            if currentIDs.contains(rid) { newOrder.append(ref); currentIDs.remove(rid) }
        }
        for t in imageTracks where currentIDs.contains(t.id) { newOrder.append(.image(t.id)); currentIDs.remove(t.id) }
        for t in subtitleTracks where currentIDs.contains(t.id) { newOrder.append(.subtitle(t.id)); currentIDs.remove(t.id) }
        for t in textTracks where currentIDs.contains(t.id) { newOrder.append(.text(t.id)); currentIDs.remove(t.id) }
        overlayTrackOrder = newOrder
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

    // Timeline
    @Published var pixelsPerSecond: Double = 30
    weak var timelineHScrollView: NSScrollView?
    private var _zoomScrollTarget: Double? = nil
    private var _zoomWorkItem: DispatchWorkItem? = nil
    /// 变速音频临时文件缓存：key = "path|trimStart|srcDurSec|speed|trackIdx"
    var audioSpeedCache: [String: URL] = [:]
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
        return maxEnd
    }

    /// 缩放下限：确保缩到最小时能完整显示所有内容并有富余
    var minPixelsPerSecond: Double {
        let end = contentEndTime
        guard end > 0 else { return 0.4 }
        // 让内容只占可见区域的 85%，留出 15% 富余
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

    // Clipboard for copy/cut/paste
    enum ClipboardItem {
        case video(VideoClip, trackIndex: Int)
        case audio(AudioClip, trackIndex: Int)
        case image(ImageClip, trackIndex: Int)
        case subtitle(SubtitleClip, trackIndex: Int)
        case text(TextClip, trackIndex: Int)
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

    // Preview resolution (for subtitle/image scaling to match export)
    @Published var previewResolution: String = "1080p  1920×1080"
    static let previewResolutions = ["4K  3840×2160", "1080p  1920×1080", "720p  1280×720", "480p  854×480"]

    var previewRenderSize: CGSize {
        let pattern = #"(\d{3,5})\s*[×xX]\s*(\d{3,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: previewResolution, range: NSRange(previewResolution.startIndex..., in: previewResolution)),
              let wRange = Range(match.range(at: 1), in: previewResolution),
              let hRange = Range(match.range(at: 2), in: previewResolution),
              let w = Int(previewResolution[wRange]), let h = Int(previewResolution[hRange])
        else { return CGSize(width: 1920, height: 1080) }
        return CGSize(width: w, height: h)
    }

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
    }
}
