import SwiftUI
import AVFoundation
import MediaToolbox
import Accelerate
import Combine

// MARK: - Asset Type

enum AssetType: String, Codable {
    case video, audio, subtitle, image
    var label: String {
        switch self { case .video: return "视频"; case .audio: return "音频"; case .subtitle: return "字幕"; case .image: return "图片" }
    }
    var icon: String {
        switch self { case .video: return "film"; case .audio: return "music.note"; case .subtitle: return "captions.bubble"; case .image: return "photo" }
    }
    var color: Color {
        switch self { case .video: return Color(hex:"#3DBFBA"); case .audio: return Color(hex:"#5DB85D"); case .subtitle: return Color(hex:"#8B7ED8"); case .image: return Color(hex:"#E8A54B") }
    }
}

// MARK: - Media Asset

struct MediaAsset: Identifiable, Equatable, Codable {
    var id = UUID()
    var url: URL
    var name: String
    var type: AssetType
    var duration: Double = 0
    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func == (lhs: MediaAsset, rhs: MediaAsset) -> Bool { lhs.id == rhs.id }
}

// MARK: - Subtitle Style

struct SubtitleStyle: Equatable, Codable {
    var fontName: String  = "PingFang SC"
    var fontSize: CGFloat = 48
    var bold: Bool        = false
    var italic: Bool      = false
    var textColor: Color      = .white
    var backgroundColor: Color = .black
    var backgroundOpacity: Double = 0.7
    var bottomMargin: Double  = 5      // % from bottom edge
    var widthPercent: Double  = 95
    var alignment: String     = "center" // "left" / "center" / "right"
    var lineSpacing: Double   = 6      // px between bilingual lines

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, bold, italic
        case textColorHex, backgroundColorHex, backgroundOpacity
        case bottomMargin, widthPercent, alignment, lineSpacing
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(textColor.toHex(), forKey: .textColorHex)
        try c.encode(backgroundColor.toHex(), forKey: .backgroundColorHex)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(bottomMargin, forKey: .bottomMargin)
        try c.encode(widthPercent, forKey: .widthPercent)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lineSpacing, forKey: .lineSpacing)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        bold = try c.decode(Bool.self, forKey: .bold)
        italic = try c.decode(Bool.self, forKey: .italic)
        textColor = Color(hex: try c.decode(String.self, forKey: .textColorHex))
        backgroundColor = Color(hex: try c.decode(String.self, forKey: .backgroundColorHex))
        backgroundOpacity = try c.decode(Double.self, forKey: .backgroundOpacity)
        bottomMargin = try c.decode(Double.self, forKey: .bottomMargin)
        widthPercent = try c.decode(Double.self, forKey: .widthPercent)
        alignment = try c.decode(String.self, forKey: .alignment)
        lineSpacing = try c.decode(Double.self, forKey: .lineSpacing)
    }

    init() {}
}

// MARK: - Clips

struct SubtitleClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var assetID: UUID?     // 关联的素材库 ID，手动添加的字幕可为 nil
    var text: String
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
}

struct VideoClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var assetID: UUID
    var name: String   = ""
    var url: URL?      = nil
    var startTime: Double
    var endTime: Double
    var trimStart: Double = 0  // source in-point (seconds into the source file)
    var duration: Double { endTime - startTime }
    // Export overrides (0 = use original)
    var overrideResolution: String = "原始分辨率"
    var overrideFPS: Int           = 0
    var overrideBitrate: Int       = 0   // kbps
    var volume: Float              = 1.0
    // Transform
    var scaleX: Double   = 1.0
    var scaleY: Double   = 1.0
    var lockAspect: Bool = true
    var offsetX: Double  = 0    // normalized offset (-1...1), 0 = centered
    var offsetY: Double  = 0
    // Crop: normalized 0...1, fraction to remove from each edge
    var cropTop: Double    = 0
    var cropBottom: Double = 0
    var cropLeft: Double   = 0
    var cropRight: Double  = 0
    // 源视频原始尺寸（用于预览裁剪框计算）
    var videoWidth: Double  = 0
    var videoHeight: Double = 0
}

struct AudioClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var assetID: UUID
    var name: String   = ""
    var url: URL?      = nil
    var startTime: Double
    var endTime: Double
    var trimStart: Double = 0  // source in-point (seconds into the source file)
    var duration: Double { endTime - startTime }
    var volume: Float  = 1.0
    var leftChannel: Float  = 1.0
    var rightChannel: Float = 1.0
    var sampleRate: Int = 44100
    var format: String = "AAC"
    // 淡入淡出
    var fadeInEnabled: Bool   = false
    var fadeOutEnabled: Bool  = false
    var fadeInDuration: Double  = 1.0  // seconds
    var fadeOutDuration: Double = 1.0  // seconds
}

struct ImageClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var assetID: UUID
    var name: String   = ""
    var imageURL: URL?  = nil   // original image
    var videoURL: URL?  = nil   // generated video for preview/export
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    var imageWidth: Int  = 0
    var imageHeight: Int = 0
    var scaleX: Double   = 1.0
    var scaleY: Double   = 1.0
    var lockAspect: Bool = true
    var offsetX: Double  = 0    // normalized offset (-1...1), 0 = centered
    var offsetY: Double  = 0
    // Crop: normalized 0...1, fraction of image to remove from each edge
    var cropTop: Double    = 0
    var cropBottom: Double = 0
    var cropLeft: Double   = 0
    var cropRight: Double  = 0
}

struct Track<Clip: Identifiable & Equatable & Codable>: Identifiable, Codable {
    var id = UUID()
    var clips: [Clip]   = []
    var label: String   = ""
    var isMuted: Bool   = false
    var isVisible: Bool = true
}

// MARK: - Export Settings

enum ExportContent: String, CaseIterable, Codable {
    case video        // full video + audio + burned-in subtitles
    case audioOnly    // export audio track only (m4a)
    case subtitleOnly // export subtitles as SRT
}

struct ExportSettings {
    var outputPath: URL?         = nil
    var filename: String         = ""
    var resolution: String       = "1080p  1920×1080"
    var fps: Int                 = 30
    var bitrate: Int             = 8000   // kbps
    var content: ExportContent   = .video
    static let resolutions = ["原始分辨率","4K  3840×2160","1080p  1920×1080","720p  1280×720","480p  854×480"]
    static let fpsOptions  = [24, 25, 30, 60]
}

// MARK: - Thumbnail & Waveform

struct ThumbnailFrame {
    let time: Double
    let image: NSImage
}

struct WaveformData {
    let totalDuration: Double
    let samples: [Float]  // normalized 0..1 peak values
}

// MARK: - Project Document (for .bcj file)

struct ProjectDocument: Codable {
    var name: String
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var subtitleStyles: [SubtitleStyle]
    var mediaAssets: [MediaAsset]
    var exportSettings: ExportSettings
    var previewResolution: String
}

extension ExportSettings: Codable {}

// MARK: - Snapshot (for undo/redo)

struct ProjectSnapshot {
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var subtitleStyles: [SubtitleStyle]
    var duration: Double
    var mediaAssets: [MediaAsset]? = nil  // optional: only saved when asset list changes (e.g. removeAsset)
}

// MARK: - Project State

final class ProjectState: ObservableObject {
    // Media
    @Published var mediaAssets: [MediaAsset] = []

    // Tracks
    @Published var videoTracks: [Track<VideoClip>]    = [Track(label: "视频")]
    @Published var audioTracks: [Track<AudioClip>]    = [Track(label: "音频")]
    @Published var imageTracks: [Track<ImageClip>]       = []
    @Published var subtitleTracks: [Track<SubtitleClip>] = [Track(label: "字幕")]
    @Published var subtitleStyles: [SubtitleStyle]    = [SubtitleStyle(), SubtitleStyle()]

    // Playback
    @Published var currentTime: Double  = 0
    @Published var duration: Double     = 60
    @Published var isPlaying: Bool      = false
    @Published var playerItem: AVPlayerItem? = nil
    var pendingSeekTime: Double? = nil
    /// End time of the last video clip on the timeline — used to black out
    /// the preview when the playhead is past all clip content.
    @Published var lastVideoEndTime: Double = 0
    /// Bumped whenever the user drags the playhead/ruler — PlayerView
    /// observes this and tells AVPlayer to seek to `currentTime`. The
    /// periodic time observer doesn't bump it (so playback doesn't loop).
    @Published var seekRequest: Int     = 0

    // Timeline
    @Published var pixelsPerSecond: Double = 30
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
        pixelsPerSecond = availableWidth / end
    }
    @Published var showVideoTracks: Bool = true
    @Published var showAudioTracks: Bool = true
    @Published var showSubtitleTracks: Bool = true

    // 删除确认
    @Published var showDeleteConfirm: Bool = false
    @Published var showAssetDeleteConfirm: Bool = false
    var pendingDeleteAssetID: UUID? = nil

    // Selection (single — used by Inspector)
    @Published var selectedVideoClipID: UUID?    = nil
    @Published var selectedAudioClipID: UUID?    = nil
    @Published var selectedImageClipID: UUID?    = nil
    @Published var selectedSubtitleClipID: UUID? = nil
    // Multi-selection (used by box-select & bulk delete)
    @Published var selectedClipIDs: Set<UUID>    = []

    // Clipboard for copy/cut/paste
    enum ClipboardItem {
        case video(VideoClip, trackIndex: Int)
        case audio(AudioClip, trackIndex: Int)
        case image(ImageClip, trackIndex: Int)
        case subtitle(SubtitleClip, trackIndex: Int)
    }
    var clipboard: ClipboardItem?
    @Published var clipboardIsCut: Bool = false
    @Published var clipboardSourceID: UUID?

    // Project file management
    @Published var projectName: String = "未命名项目"
    @Published var projectFileURL: URL? = nil
    @Published var showWelcome: Bool = true
    @Published var isSaved: Bool = false
    @Published var saveToasts: [UUID] = []
    /// Toast message for import feedback (e.g. duplicate file skipped)
    @Published var importToastMessage: String? = nil

    // 转码状态
    @Published var isTranscoding: Bool = false
    @Published var transcodingFileName: String = ""
    @Published var transcodingProgress: Double = 0  // 0...1
    private var transcodingProcess: Process?
    private var transcodingOutputURL: URL?

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
    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []

    // Debounce timer for preview rebuild (prevents flickering during interactive edits)
    private var rebuildDebounceTimer: Timer?
    private var rebuildTask: Task<Void, Never>?

    // Auto-save timer (debounced 3 seconds after last edit)
    private var autoSaveTimer: Timer?

    // Thumbnail & Waveform cache
    @Published var mediaThumbnails: [UUID: NSImage] = [:]          // asset ID → single thumbnail (media library)
    @Published var assetThumbnails: [UUID: [ThumbnailFrame]] = [:] // asset ID → timeline thumbnail strip
    @Published var waveformCache: [UUID: WaveformData] = [:]       // asset ID → waveform peaks
    var imageVideoCache: [UUID: URL] = [:]                         // asset ID → generated video file

    // Translation
    @Published var translationTargetLang: String = "中文（简体）"
    @Published var translatingTrackIndices: Set<Int> = []  // 正在翻译中的轨道 index
    @Published var translationProgress: Double = 0         // 0...1
    @Published var translationTotal: Int = 0               // 总字幕数
    @Published var translationDone: Int = 0                // 已完成数
    /// 占位字幕 ID 集合（翻译中显示呼吸效果）
    @Published var placeholderClipIDs: Set<UUID> = []
    static let supportedLanguages = [
        "中文（简体）","中文（繁体）","English","日本語",
        "한국어","Français","Deutsch","Español",
        "Русский","العربية","Português","Italiano"
    ]

    private var cancellables = Set<AnyCancellable>()

    private static let mediaLibraryKey = "savedMediaBookmarks"
    /// 正在访问安全范围的 URL（app 退出时需要 stop）
    private var accessedURLs: [URL] = []

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

    // MARK: - Project File (.bcj)

    func createNewProject(name: String, directory: URL) {
        projectName = name
        let fileURL = directory.appendingPathComponent("\(name).bcj")
        projectFileURL = fileURL
        // 重置到空项目状态（素材库保留，不清空）
        videoTracks = [Track(label: "视频")]
        audioTracks = [Track(label: "音频")]
        imageTracks = []
        subtitleTracks = [Track(label: "字幕")]
        subtitleStyles = [SubtitleStyle(), SubtitleStyle()]
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0; duration = 60
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()
        assetThumbnails.removeAll()
        waveformCache.removeAll()
        imageVideoCache.removeAll()
        playerItem = nil
        showWelcome = false
        isSaved = true
        // 为保留的素材重新生成缩略图
        for asset in mediaAssets {
            if mediaThumbnails[asset.id] == nil {
                loadMediaResources(asset)
            }
        }
        saveProject(silent: true)
    }

    func openProject(url: URL) {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法打开项目"
                alert.informativeText = "文件不存在：\(url.lastPathComponent)\n路径：\(url.path)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }

        guard url.startAccessingSecurityScopedResource() else { return }
        accessedURLs.append(url)
        defer { /* keep access alive */ }

        guard let data = try? Data(contentsOf: url) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法读取项目"
                alert.informativeText = "文件可能已损坏：\(url.lastPathComponent)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
        guard let doc = try? JSONDecoder().decode(ProjectDocument.self, from: data) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法解析项目"
                alert.informativeText = "文件格式不正确：\(url.lastPathComponent)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }

        projectName = url.deletingPathExtension().lastPathComponent
        projectFileURL = url
        videoTracks = doc.videoTracks
        audioTracks = doc.audioTracks
        imageTracks = doc.imageTracks
        subtitleTracks = doc.subtitleTracks
        subtitleStyles = doc.subtitleStyles
        exportSettings = doc.exportSettings
        previewResolution = doc.previewResolution

        // 恢复媒体资源（以项目文件为准，完全替换）
        mediaAssets.removeAll()
        mediaThumbnails.removeAll()
        for asset in doc.mediaAssets {
            if asset.url.startAccessingSecurityScopedResource() {
                accessedURLs.append(asset.url)
            }
            mediaAssets.append(asset)
            loadMediaResources(asset)
        }

        // 重建时间轴缩略图和波形
        for track in videoTracks {
            for clip in track.clips {
                if let url = clip.url {
                    loadTimelineThumbnails(assetID: clip.assetID, url: url)
                }
            }
        }
        for track in audioTracks {
            for clip in track.clips {
                if let url = clip.url {
                    loadWaveform(assetID: clip.assetID, url: url)
                }
            }
        }

        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0
        showWelcome = false
        isSaved = true
        rebuildTimelinePreview()
    }

    /// Schedule auto-save after a 3-second idle period.
    /// Each call resets the timer, so rapid edits are batched.
    func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.isSaved, self.projectFileURL != nil else { return }
            self.saveProject(silent: true)
        }
    }

    func saveProject(silent: Bool = false) {
        guard let fileURL = projectFileURL else { return }
        let doc = ProjectDocument(
            name: projectName,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            imageTracks: imageTracks,
            subtitleTracks: subtitleTracks,
            subtitleStyles: subtitleStyles,
            mediaAssets: mediaAssets,
            exportSettings: exportSettings,
            previewResolution: previewResolution
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: fileURL, options: .atomic)
        isSaved = true
        guard !silent else { return }
        let toastID = UUID()
        if saveToasts.count >= 5 { saveToasts.removeFirst() }
        saveToasts.append(toastID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.saveToasts.removeAll { $0 == toastID }
        }
    }

    /// Show a brief import feedback toast (auto-dismiss after 3 seconds)
    private func showImportToast(_ message: String) {
        importToastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.importToastMessage == message {
                self?.importToastMessage = nil
            }
        }
    }

    /// Remove an asset from the media library AND remove any timeline clips
    /// referencing it (with undo support including asset restoration).
    /// Shows a confirmation alert before proceeding.
    func removeAsset(id: UUID) {
        let assetName = mediaAssets.first(where: { $0.id == id })?.name ?? "未知素材"

        // Count timeline clips that reference this asset
        var clipCount = 0
        for t in videoTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in audioTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in imageTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in subtitleTracks { clipCount += t.clips.filter { $0.assetID == id }.count }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确定移除「\(assetName)」？"
        if clipCount > 0 {
            alert.informativeText = "时间轴上有 \(clipCount) 个片段使用了此素材，将一并移除。"
        } else {
            alert.informativeText = "素材将从素材库中移除。"
        }
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // User confirmed — save snapshot WITH mediaAssets for undo
        var snapshot = currentSnapshot()
        snapshot.mediaAssets = mediaAssets
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()

        // Remove timeline clips (all track types including subtitle)
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll { $0.assetID == id } }
        // Clean up caches
        mediaThumbnails.removeValue(forKey: id)
        assetThumbnails.removeValue(forKey: id)
        waveformCache.removeValue(forKey: id)
        imageVideoCache.removeValue(forKey: id)
        // Remove from asset list
        mediaAssets.removeAll { $0.id == id }
        // Deselect
        selectedVideoClipID = nil
        selectedAudioClipID = nil
        selectedImageClipID = nil
        selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()
        rebuildTimelinePreview()
    }

    private func saveMediaLibrary(_ assets: [MediaAsset]) {
        let bookmarks: [Data] = assets.compactMap { asset in
            try? asset.url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.mediaLibraryKey)
    }

    private func loadSavedMediaLibrary() {
        // 兼容旧版纯路径格式，自动迁移
        if let paths = UserDefaults.standard.stringArray(forKey: "savedMediaAssetPaths") {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                importFileFromRestore(url)
            }
            UserDefaults.standard.removeObject(forKey: "savedMediaAssetPaths")
            saveMediaLibrary(mediaAssets)
            return
        }

        guard let dataArray = UserDefaults.standard.array(forKey: Self.mediaLibraryKey) as? [Data] else { return }
        for data in dataArray {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                      options: .withSecurityScope,
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessedURLs.append(url)
            importFileFromRestore(url)
        }
    }

    /// 从持久化数据恢复素材（不触发重复保存）
    private func importFileFromRestore(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let type: AssetType
        switch ext {
        case "mp4","mov","mkv","avi","m4v": type = .video
        case "mp3","wav","aac","m4a","flac": type = .audio
        case "srt","ass","vtt": type = .subtitle
        case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic": type = .image
        default: return
        }
        guard !mediaAssets.contains(where: { $0.url == url }) else { return }
        let asset = MediaAsset(url: url, name: url.lastPathComponent, type: type)
        mediaAssets.append(asset)
        if asset.fileExists {
            loadMediaResources(asset)
        }
    }

    func refreshMediaLibrary() {
        for asset in mediaAssets {
            if asset.fileExists && mediaThumbnails[asset.id] == nil {
                loadMediaResources(asset)
            }
        }
    }

    private func loadMediaResources(_ asset: MediaAsset) {
        let aid = asset.id
        let url = asset.url
        switch asset.type {
        case .video:
            loadMediaThumbnail(assetID: aid, url: url)
            loadTimelineThumbnails(assetID: aid, url: url)
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where: { $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        case .audio:
            loadWaveform(assetID: aid, url: url)
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where: { $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        case .image:
            loadImageThumbnail(assetID: aid, url: url)
        case .subtitle: break
        }
    }

    // MARK: - Helpers

    var selectedSubtitleClip: SubtitleClip? {
        guard let id = selectedSubtitleClipID else { return nil }
        for t in subtitleTracks { if let c = t.clips.first(where:{ $0.id == id }) { return c } }
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

    // MARK: - Thumbnail & Waveform Generation

    /// Generate a single thumbnail for the media library (video assets only).
    func loadMediaThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { self.mediaThumbnails[id] = img }
            }
        }
    }

    /// Generate timeline thumbnail strip for a video asset (evenly spaced frames).
    func loadTimelineThumbnails(assetID: UUID, url: URL) {
        guard assetThumbnails[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0.1 else { return }
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 104)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

            let interval = max(1.0, dur / 30.0)  // at most ~30 frames
            var frames: [ThumbnailFrame] = []
            var t = 0.0
            while t < dur {
                let time = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    frames.append(ThumbnailFrame(time: t, image: img))
                }
                t += interval
            }
            await MainActor.run { self.assetThumbnails[id] = frames }
        }
    }

    /// Generate waveform peak data for an audio asset.
    func loadWaveform(assetID: UUID, url: URL) {
        guard waveformCache[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0 else { return }
            guard let track = try? await av.loadTracks(withMediaType: .audio).first else { return }
            guard let reader = try? AVAssetReader(asset: av) else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            reader.startReading()

            var allPeaks: [Float] = []
            var buf16: [Int16] = []
            let chunkTarget = 2000  // samples per peak

            while let sampleBuf = output.copyNextSampleBuffer() {
                guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuf) else { continue }
                var length = 0
                var dataPtr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPtr)
                guard let ptr = dataPtr else { continue }
                let count = length / MemoryLayout<Int16>.size
                let samples = UnsafeBufferPointer(
                    start: UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: count), count: count)
                buf16.append(contentsOf: samples)

                while buf16.count >= chunkTarget {
                    let chunk = Array(buf16.prefix(chunkTarget))
                    buf16.removeFirst(chunkTarget)
                    let peak = chunk.map { abs(Float($0)) }.max() ?? 0
                    allPeaks.append(peak / Float(Int16.max))
                }
            }
            if !buf16.isEmpty {
                let peak = buf16.map { abs(Float($0)) }.max() ?? 0
                allPeaks.append(peak / Float(Int16.max))
            }

            await MainActor.run {
                self.waveformCache[id] = WaveformData(totalDuration: dur, samples: allPeaks)
            }
        }
    }

    /// Load an image file as thumbnail for the media library.
    func loadImageThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        if let img = NSImage(contentsOf: url) {
            mediaThumbnails[assetID] = img
        }
    }

    // MARK: - Relink missing asset

    /// Update all timeline clips that reference a given asset to use a new URL.
    /// 删除素材并移除时间轴上所有引用该素材的片段
    func removeAssetAndClips(assetID: UUID) {
        let snap = currentSnapshot()
        mediaAssets.removeAll { $0.id == assetID }
        for i in videoTracks.indices {
            videoTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in audioTracks.indices {
            audioTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in imageTracks.indices {
            imageTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in subtitleTracks.indices {
            subtitleTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        mediaThumbnails.removeValue(forKey: assetID)
        undoStack.append(snap)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 统计素材在时间轴上被引用的片段数
    func clipCountForAsset(_ assetID: UUID) -> Int {
        var count = 0
        for t in videoTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in audioTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in imageTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in subtitleTracks { count += t.clips.filter { $0.assetID == assetID }.count }
        return count
    }

    func relinkAsset(id: UUID, newURL: URL) {
        for ti in videoTracks.indices {
            for ci in videoTracks[ti].clips.indices where videoTracks[ti].clips[ci].assetID == id {
                videoTracks[ti].clips[ci].url = newURL
            }
        }
        for ti in audioTracks.indices {
            for ci in audioTracks[ti].clips.indices where audioTracks[ti].clips[ci].assetID == id {
                audioTracks[ti].clips[ci].url = newURL
            }
        }
        rebuildTimelinePreview()
    }

    // MARK: - Cross-track move

    func moveVideoClipToTrack(id: UUID, from: Int, to: Int) {
        guard videoTracks.indices.contains(from), videoTracks.indices.contains(to) else { return }
        guard let idx = videoTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = videoTracks[from].clips.remove(at: idx)
        videoTracks[to].clips.append(clip)
    }

    func moveImageClipToTrack(id: UUID, from: Int, to: Int) {
        guard imageTracks.indices.contains(from), imageTracks.indices.contains(to) else { return }
        guard let idx = imageTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = imageTracks[from].clips.remove(at: idx)
        imageTracks[to].clips.append(clip)
    }

    func moveAudioClipToTrack(id: UUID, from: Int, to: Int) {
        guard audioTracks.indices.contains(from), audioTracks.indices.contains(to) else { return }
        guard let idx = audioTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = audioTracks[from].clips.remove(at: idx)
        audioTracks[to].clips.append(clip)
    }

    func moveSubtitleClipToTrack(id: UUID, from: Int, to: Int) {
        guard subtitleTracks.indices.contains(from), subtitleTracks.indices.contains(to) else { return }
        guard let idx = subtitleTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = subtitleTracks[from].clips.remove(at: idx)
        subtitleTracks[to].clips.append(clip)
    }

    // MARK: - Overlap resolution

    /// 检查片段是否与同轨道其他片段重叠，如果重叠则自动新建轨道并移过去
    func resolveVideoOverlap(id: UUID) {
        for ti in videoTracks.indices {
            guard let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = videoTracks[ti].clips[ci]
            let hasOverlap = videoTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = videoTracks[ti].clips.remove(at: ci)
                // 尝试找一个没有重叠的已有轨道
                var placed = false
                for dti in videoTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !videoTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        videoTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<VideoClip>(label: "视频")
                    newTrack.clips.append(removed)
                    videoTracks.append(newTrack)
                }
            }
            return
        }
    }

    func resolveImageOverlap(id: UUID) {
        for ti in imageTracks.indices {
            guard let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = imageTracks[ti].clips[ci]
            let hasOverlap = imageTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = imageTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in imageTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !imageTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        imageTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<ImageClip>(label: "图片")
                    newTrack.clips.append(removed)
                    imageTracks.append(newTrack)
                }
            }
            return
        }
    }

    func resolveAudioOverlap(id: UUID) {
        for ti in audioTracks.indices {
            guard let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = audioTracks[ti].clips[ci]
            let hasOverlap = audioTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = audioTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in audioTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !audioTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        audioTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<AudioClip>(label: "音频")
                    newTrack.clips.append(removed)
                    audioTracks.append(newTrack)
                }
            }
            return
        }
    }

    func resolveSubtitleOverlap(id: UUID) {
        for ti in subtitleTracks.indices {
            guard let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = subtitleTracks[ti].clips[ci]
            let hasOverlap = subtitleTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = subtitleTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in subtitleTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !subtitleTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        subtitleTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<SubtitleClip>(label: "字幕")
                    newTrack.clips.append(removed)
                    subtitleTracks.append(newTrack)
                    subtitleStyles.append(SubtitleStyle())
                }
            }
            return
        }
    }

    // MARK: - Multi-select helpers

    /// Shift+click: toggle a clip in/out of multi-selection
    func shiftToggleClip(_ id: UUID) {
        if selectedClipIDs.contains(id) {
            selectedClipIDs.remove(id)
            // Also clear primary if it matches
            if selectedVideoClipID == id    { selectedVideoClipID = nil }
            if selectedImageClipID == id    { selectedImageClipID = nil }
            if selectedAudioClipID == id    { selectedAudioClipID = nil }
            if selectedSubtitleClipID == id { selectedSubtitleClipID = nil }
        } else {
            // Move current primary into multi-set if needed
            if let pid = selectedVideoClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedImageClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedAudioClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedSubtitleClipID, pid != id { selectedClipIDs.insert(pid) }
            selectedClipIDs.insert(id)
            // Set as new primary based on type
            if videoTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedVideoClipID = id
                selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            } else if imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedImageClipID = id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            } else if audioTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedAudioClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedSubtitleClipID = nil
            } else if subtitleTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedSubtitleClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil
            }
        }
    }

    /// 把当前主选中片段合并进 selectedClipIDs（用于向左/右全选等场景）
    private func mergePrimaryIntoSelection() {
        if let pid = selectedVideoClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedImageClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedAudioClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedSubtitleClipID { selectedClipIDs.insert(pid) }
    }

    /// 向左全选：选中同轨道中 startTime <= 当前片段的所有片段
    func selectLeftOf(_ id: UUID) {
        mergePrimaryIntoSelection()
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
    }

    /// 向右全选：选中同轨道中 startTime >= 当前片段的所有片段
    func selectRightOf(_ id: UUID) {
        mergePrimaryIntoSelection()
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
    }

    // MARK: - Preview

    /// Debounced rebuild — coalesces rapid changes (e.g. dragging sliders)
    /// into a single rebuild after a short delay, preventing flicker.
    func rebuildTimelinePreviewDebounced() {
        rebuildDebounceTimer?.invalidate()
        rebuildDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.rebuildTimelinePreview()
        }
    }

    /// Build a full timeline composition from all clips and load it as the
    /// playerItem. If `seekTo` is given, also seeks to that time after load.
    /// Gaps between clips are rendered black by AVPlayer automatically.
    func rebuildTimelinePreview(seekTo: Double? = nil) {
        // Snapshot the clip arrays so the async task captures stable values.
        let vTracks = videoTracks
        let iTracks = imageTracks
        let aTracks = audioTracks
        let sTracks = subtitleTracks
        // 默认保留当前播放位置
        let restoreTime = seekTo ?? currentTime
        // endTime 取所有轨道（不管可见性），保证播放头范围正确
        let vEnd = vTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let iEnd = iTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let aEnd = aTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let sEnd = sTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let endTime = max(vEnd, max(iEnd, max(aEnd, sEnd)))
        rebuildTask?.cancel()
        rebuildTask = Task {
            let composition = AVMutableComposition()
            var audioParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float, startTime: Double, duration: Double, fadeIn: Double, fadeOut: Double)] = []
            var videoCompTracks: [(track: AVMutableCompositionTrack, clip: VideoClip, startTime: Double, endTime: Double)] = []  // from video clips
            var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []  // from image clips (on top)
            let renderSize = previewRenderSize

            // 视频轨道
            for track in vTracks {
                for clip in track.clips.sorted(by: { $0.startTime < $1.startTime }) {
                    guard let url = clip.url else { continue }
                    let asset = AVURLAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxDur  = assetDur - trimSt
                    let useDur  = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let range = CMTimeRange(start: trimSt, duration: useDur)
                    let at    = CMTime(seconds: clip.startTime, preferredTimescale: 600)

                    if track.isVisible,
                       let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        videoCompTracks.append((vt, clip, clip.startTime, clip.startTime + useDur.seconds))
                    }
                    if !track.isMuted,
                       let aAsset = try? await asset.loadTracks(withMediaType: .audio).first,
                       let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? at2.insertTimeRange(range, of: aAsset, at: at)
                        audioParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, useDur.seconds, 0, 0))
                    }
                }
            }

            // 图片轨道（上层）
            for track in iTracks {
                guard track.isVisible else { continue }
                for clip in track.clips {
                    var url = clip.videoURL
                    if let u = url, !FileManager.default.fileExists(atPath: u.path) {
                        url = nil
                    }
                    if url == nil, let imgURL = clip.imageURL {
                        url = await Self.createVideoFromImage(imageURL: imgURL, duration: clip.duration)
                        if let u = url {
                            await MainActor.run {
                                self.imageVideoCache[clip.assetID] = u
                                self.updateImageClip(id: clip.id) { $0.videoURL = u }
                            }
                        }
                    }
                    guard let url else { continue }
                    let asset = AVURLAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), assetDur)
                    guard useDur.seconds > 0.01 else { continue }
                    if let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        // 先填充 clip 之前的空白区间（确保 track 在所有 segment 都有 sample）
                        // AVVideoComposition 的 instruction 要求至少 1 个 layerInstruction，
                        // 而不活跃的 clip 也需要 layerInstruction（opacity=0），
                        // track 必须在该时间段有 sample 数据才能被引用。
                        if clip.startTime > 0.01 {
                            var pos = CMTime.zero
                            let fillEnd = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        // 在 clip 的时间位置插入实际内容
                        let range = CMTimeRange(start: .zero, duration: useDur)
                        let at = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        // clip 之后也填充到 endTime（处理视频比图片长的情况）
                        let afterEnd = clip.startTime + useDur.seconds
                        if endTime > afterEnd + 0.01 {
                            var pos = CMTime(seconds: afterEnd, preferredTimescale: 600)
                            let fillEnd = CMTime(seconds: endTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        imageCompTracks.append((track: vt, clip: clip))
                    }
                }
            }

            for track in aTracks {
                guard track.isVisible && !track.isMuted else { continue }
                for clip in track.clips {
                    guard let url = clip.url else { continue }
                    let asset = AVURLAsset(url: url)
                    guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxDur  = assetDur - trimSt
                    let useDur  = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let range = CMTimeRange(start: trimSt, duration: useDur)
                    let at    = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                    if let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? at2.insertTimeRange(range, of: aAsset, at: at)
                        let fadeIn  = clip.fadeInEnabled  ? min(clip.fadeInDuration,  clip.duration) : 0
                        let fadeOut = clip.fadeOutEnabled ? min(clip.fadeOutDuration, clip.duration) : 0
                        audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, useDur.seconds, fadeIn, fadeOut))
                    }
                }
            }

            // 用空白音频轨道撑开 composition 到 endTime
            let compositionDur = composition.duration.seconds
            if endTime > compositionDur + 0.1 {
                if let padTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                    padTrack.insertEmptyTimeRange(
                        CMTimeRange(start: CMTime(seconds: compositionDur, preferredTimescale: 600),
                                    duration: CMTime(seconds: endTime - compositionDur, preferredTimescale: 600)))
                }
            }

            // 构建 AudioMix — 音量 + 淡入淡出 + 左右声道
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParams.map { param in
                let p = AVMutableAudioMixInputParameters(track: composition.track(withTrackID: param.trackID))
                p.trackID = param.trackID
                let ts: CMTimeScale = 600
                let clipStart = CMTime(seconds: param.startTime, preferredTimescale: ts)
                let clipDur   = param.duration
                if param.fadeIn > 0 {
                    // 淡入：从 0 → volume
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: param.volume,
                                    timeRange: CMTimeRange(start: clipStart,
                                                           duration: CMTime(seconds: param.fadeIn, preferredTimescale: ts)))
                }
                if param.fadeOut > 0 {
                    // 淡出：从 volume → 0
                    let fadeOutStart = CMTime(seconds: param.startTime + clipDur - param.fadeOut, preferredTimescale: ts)
                    p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: fadeOutStart,
                                                           duration: CMTime(seconds: param.fadeOut, preferredTimescale: ts)))
                }
                // 中间段保持基准音量（淡入结束到淡出开始）
                if param.fadeIn > 0 || param.fadeOut > 0 {
                    let midStart = CMTime(seconds: param.startTime + param.fadeIn, preferredTimescale: ts)
                    let midEnd   = param.startTime + clipDur - param.fadeOut
                    let midDur   = midEnd - (param.startTime + param.fadeIn)
                    if midDur > 0 {
                        p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: param.volume,
                                        timeRange: CMTimeRange(start: midStart,
                                                               duration: CMTime(seconds: midDur, preferredTimescale: ts)))
                    }
                } else {
                    p.setVolume(param.volume, at: .zero)
                }
                // 左右声道不全是 1.0 时，用 MTAudioProcessingTap 处理
                if param.left != 1.0 || param.right != 1.0 {
                    if let tap = makeChannelTap(left: param.left, right: param.right) {
                        p.audioTapProcessor = tap
                    }
                }
                return p
            }

            // Build AVVideoComposition to layer image tracks on top of video tracks.
            // We need time-segmented instructions so image layers only appear during
            // their clip range and disappear afterwards (letting video show through).
            let allVideoTracks = videoCompTracks.map(\.track) + imageCompTracks.map(\.track)
            var videoComposition: AVMutableVideoComposition? = nil
            if !allVideoTracks.isEmpty && composition.duration.seconds > 0.01 {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: 30)

                // Collect image clip time ranges — 使用 CMTime 量化后的值避免精度偏差
                let ts: CMTimeScale = 600
                let imageClipCMRanges = imageCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.clip.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.clip.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                // Collect video clip time ranges
                let videoClipCMRanges = videoCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                // Collect all time boundaries (CMTime)
                var cmBoundaries: [CMTime] = [.zero, composition.duration]
                for r in imageClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                for r in videoClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                // 去重 + 排序
                let sortedCM = Array(Set(cmBoundaries.map { $0.value })).sorted().map { CMTime(value: $0, timescale: ts) }

                var instructions: [AVMutableVideoCompositionInstruction] = []
                for i in 0..<(sortedCM.count - 1) {
                    let segStartCM = sortedCM[i]
                    let segEndCM   = sortedCM[i + 1]
                    let segDur = segEndCM - segStartCM
                    guard segDur.seconds > 0.001 else { continue }

                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: segStartCM, duration: segDur)
                    instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

                    var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                    // 所有 image track 都有 sample（填充了整个时间线），
                    // 不活跃的 clip 用 opacity=0 隐藏。
                    for (idx, entry) in imageCompTracks.enumerated() {
                        let clipStartCM = imageClipCMRanges[idx].start
                        let clipEndCM   = imageClipCMRanges[idx].end
                        let clipActive = segStartCM >= clipStartCM && segStartCM < clipEndCM
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                        if clipActive {
                            if let natSize = try? await entry.track.load(.naturalSize), natSize.width > 0, natSize.height > 0 {
                                let t = Self.imageTransform(clip: entry.clip, natSize: natSize, renderSize: renderSize)
                                li.setTransform(t, at: .zero)
                                let c = entry.clip
                                if c.cropTop > 0.001 || c.cropBottom > 0.001 || c.cropLeft > 0.001 || c.cropRight > 0.001 {
                                    li.setCropRectangle(Self.imageCropRect(clip: c, natSize: natSize), at: .zero)
                                }
                            }
                        } else {
                            li.setOpacity(0, at: .zero)
                        }
                        layerInstructions.append(li)
                    }
                    for (idx, entry) in videoCompTracks.enumerated() {
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                        let clipStart = videoClipCMRanges[idx].start
                        let clipEnd   = videoClipCMRanges[idx].end
                        let active = segStartCM >= clipStart && segStartCM < clipEnd
                        if active {
                            if let natSize = try? await entry.track.load(.naturalSize), natSize.width > 0, natSize.height > 0 {
                                let t = Self.videoTransform(clip: entry.clip, natSize: natSize, renderSize: renderSize)
                                li.setTransform(t, at: .zero)
                                let c = entry.clip
                                if c.cropTop > 0.001 || c.cropBottom > 0.001 || c.cropLeft > 0.001 || c.cropRight > 0.001 {
                                    li.setCropRectangle(Self.videoCropRect(clip: c, natSize: natSize), at: .zero)
                                }
                            }
                        } else {
                            li.setOpacity(0, at: .zero)
                        }
                        layerInstructions.append(li)
                    }
                    instruction.layerInstructions = layerInstructions
                    instructions.append(instruction)
                }

                if !instructions.isEmpty {
                    vc.instructions = instructions
                    videoComposition = vc
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lastVideoEndTime = endTime
                self.duration = max(endTime, 0.01)
                self.pendingSeekTime = restoreTime
                if composition.tracks.isEmpty && endTime < 0.01 {
                    self.playerItem = nil
                } else {
                    let item = AVPlayerItem(asset: composition)
                    item.audioMix = audioMix
                    if let vc = videoComposition {
                        item.videoComposition = vc
                    }
                    self.playerItem = item
                }
            }
        }
    }

    // MARK: - Image transform helpers

    /// Compute the CGAffineTransform for an image clip, accounting for scale and offset.
    /// Scale is based on the FULL image (not crop region), so cropping one edge doesn't affect scale.
    /// Crop is handled separately via setCropRectangle.
    static func imageTransform(clip: ImageClip, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard natSize.width > 0, natSize.height > 0 else {
            return CGAffineTransform(scaleX: 0, y: 0)
        }
        // Base scale: fit FULL image into render size (crop does NOT affect scale)
        let baseScale = min(renderSize.width / natSize.width, renderSize.height / natSize.height)
        let finalSX = baseScale * CGFloat(clip.scaleX)
        let finalSY = baseScale * CGFloat(clip.scaleY)
        // Center the full image, then apply user offset
        let tx = (renderSize.width  - natSize.width  * finalSX) / 2 + CGFloat(clip.offsetX) * renderSize.width
        let ty = (renderSize.height - natSize.height * finalSY) / 2 + CGFloat(clip.offsetY) * renderSize.height
        return CGAffineTransform(scaleX: finalSX, y: finalSY)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Compute the crop rectangle in the source image's coordinate space.
    static func imageCropRect(clip: ImageClip, natSize: CGSize) -> CGRect {
        let x = natSize.width  * CGFloat(clip.cropLeft)
        let y = natSize.height * CGFloat(clip.cropTop)
        let w = natSize.width  * (1 - CGFloat(clip.cropLeft + clip.cropRight))
        let h = natSize.height * (1 - CGFloat(clip.cropTop  + clip.cropBottom))
        return CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
    }

    // MARK: - Video transform helpers

    static func videoTransform(clip: VideoClip, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard natSize.width > 0, natSize.height > 0 else {
            return CGAffineTransform(scaleX: 0, y: 0)
        }
        let baseScale = min(renderSize.width / natSize.width, renderSize.height / natSize.height)
        let finalSX = baseScale * CGFloat(clip.scaleX)
        let finalSY = baseScale * CGFloat(clip.scaleY)
        let tx = (renderSize.width  - natSize.width  * finalSX) / 2 + CGFloat(clip.offsetX) * renderSize.width
        let ty = (renderSize.height - natSize.height * finalSY) / 2 + CGFloat(clip.offsetY) * renderSize.height
        return CGAffineTransform(scaleX: finalSX, y: finalSY)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    static func videoCropRect(clip: VideoClip, natSize: CGSize) -> CGRect {
        let x = natSize.width  * CGFloat(clip.cropLeft)
        let y = natSize.height * CGFloat(clip.cropTop)
        let w = natSize.width  * (1 - CGFloat(clip.cropLeft + clip.cropRight))
        let h = natSize.height * (1 - CGFloat(clip.cropTop  + clip.cropBottom))
        return CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
    }

    /// Select a clip for preview and seek to its start so the user sees it.
    func loadClipForPreview(_ clip: VideoClip) {
        rebuildTimelinePreview(seekTo: clip.startTime)
    }

    // MARK: - Import

    /// 支持的素材扩展名
    private static let supportedExtensions: Set<String> = [
        "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv",
        "mp3","wav","aac","m4a","flac","ogg","wma",
        "srt","ass","vtt",
        "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic"
    ]

    /// AVFoundation 原生支持的视频容器，无需转码
    private static let nativeVideoExtensions: Set<String> = ["mp4","mov","m4v"]

    /// 需要 FFmpeg 转码的视频格式
    private static let needsTranscodeExtensions: Set<String> = [
        "mkv","avi","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv"
    ]

    private static func assetType(for ext: String) -> AssetType? {
        switch ext {
        case "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv": return .video
        case "mp3","wav","aac","m4a","flac","ogg","wma": return .audio
        case "srt","ass","vtt": return .subtitle
        case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic": return .image
        default: return nil
        }
    }

    /// 导入文件或文件夹（文件夹会递归扫描）
    func importFile(_ url: URL) {
        // 确保沙盒环境下有访问权限
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }

        // 如果是文件夹，递归扫描
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            importFolder(url)
            return
        }

        guard !mediaAssets.contains(where: { $0.url == url }) else {
            showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
            return
        }
        let ext = url.pathExtension.lowercased()
        guard let type = Self.assetType(for: ext) else { return }

        // 需要转码的视频格式，先转为 MP4 再导入
        if type == .video && Self.needsTranscodeExtensions.contains(ext) {
            // 检查转码后的文件是否已在素材库中（防止同一源文件重复导入）
            let fileName = url.deletingPathExtension().lastPathComponent
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BlackCatTranscode", isDirectory: true)
                .appendingPathComponent("\(fileName).mp4")
            if mediaAssets.contains(where: { $0.url == outputURL }) {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
                return
            }
            transcodeAndImport(url: url)
            return
        }

        importFileDirectly(url: url, type: type)
    }

    /// 直接导入（原生格式或转码完成后的文件）
    private func importFileDirectly(url: URL, type: AssetType) {
        // 兜底去重：防止任何路径绕过前置检查
        guard !mediaAssets.contains(where: { $0.url == url }) else { return }
        let asset = MediaAsset(url: url, name: url.lastPathComponent, type: type)
        let aid = asset.id
        mediaAssets.append(asset)
        // Trigger thumbnail / waveform generation
        if type == .video {
            loadMediaThumbnail(assetID: aid, url: url)
            loadTimelineThumbnails(assetID: aid, url: url)
        } else if type == .audio {
            loadWaveform(assetID: aid, url: url)
        } else if type == .image {
            loadImageThumbnail(assetID: aid, url: url)
        }
        if type != .subtitle && type != .image {
            Task {
                let av = AVURLAsset(url: url)
                if let d = try? await av.load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where:{ $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        }
    }

    // MARK: - FFmpeg Transcode

    /// 取消当前转码，终止进程并清除临时文件
    func cancelTranscoding() {
        transcodingProcess?.terminate()
        transcodingProcess = nil
        isTranscoding = false
        transcodingProgress = 0
        transcodingFileName = ""
        // 删除未完成的临时文件
        if let outputURL = transcodingOutputURL {
            try? FileManager.default.removeItem(at: outputURL)
            transcodingOutputURL = nil
        }
    }

    /// 将非原生视频格式转为 MP4。策略：先快速 remux（-c copy），失败再硬件转码
    private func transcodeAndImport(url: URL) {
        let fileName = url.deletingPathExtension().lastPathComponent
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlackCatTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("\(fileName).mp4")

        // 如果已处理过，检查是否已在素材库中
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !mediaAssets.contains(where: { $0.url == outputURL }) {
                importFileDirectly(url: outputURL, type: .video)
            } else {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
            }
            return
        }

        // 查找 ffmpeg
        guard let ffmpeg = Self.findFFmpeg() else {
            showImportToast("未找到 FFmpeg，无法导入 \(url.pathExtension.uppercased()) 格式")
            return
        }

        transcodingOutputURL = outputURL

        Task.detached { [weak self] in
            // ═══════ 第一步：快速 remux（视频 copy，音频转 AAC 兼容 MP4） ═══════
            let remuxOK = Self.runFFmpegSync(ffmpeg: ffmpeg, arguments: [
                "-i", url.path,
                "-c:v", "copy",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart",
                "-y", outputURL.path
            ])

            if remuxOK {
                // 验证 AVFoundation 能否播放（H.264/H.265 可以，VP9/AV1 不行）
                let asset = AVURLAsset(url: outputURL)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                if playable {
                    await MainActor.run {
                        self?.importFileDirectly(url: outputURL, type: .video)
                    }
                    return
                }
                // 编码不兼容，删掉 remux 文件，走转码
                try? FileManager.default.removeItem(at: outputURL)
            }

            // ═══════ 第二步：硬件转码（仅当 remux 不可用时） ═══════
            await MainActor.run {
                self?.isTranscoding = true
                self?.transcodingFileName = url.lastPathComponent
                self?.transcodingProgress = 0
            }

            let totalDuration = Self.probeVideoDuration(ffmpegDir: ffmpeg.deletingLastPathComponent().path, inputPath: url.path)

            let process = Process()
            await MainActor.run { self?.transcodingProcess = process }
            process.executableURL = ffmpeg
            process.arguments = [
                "-hwaccel", "videotoolbox",
                "-i", url.path,
                "-c:v", "h264_videotoolbox",
                "-b:v", "8000k",
                "-profile:v", "high",
                "-level:v", "4.2",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart",
                "-y", outputURL.path
            ]

            let pipe = Pipe()
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    self?.isTranscoding = false
                    self?.showImportToast("转码失败：\(error.localizedDescription)")
                }
                return
            }

            // 解析进度
            let handle = pipe.fileHandleForReading
            var buffer = ""
            while process.isRunning {
                if let data = try? handle.availableData, !data.isEmpty,
                   let str = String(data: data, encoding: .utf8) {
                    buffer += str
                    if let range = buffer.range(of: "time=\\d{2}:\\d{2}:\\d{2}\\.\\d+", options: .regularExpression) {
                        let timeStr = String(buffer[range]).replacingOccurrences(of: "time=", with: "")
                        let currentSec = Self.parseFFmpegTime(timeStr)
                        if totalDuration > 0 {
                            let prog = min(currentSec / totalDuration, 1.0)
                            Task { @MainActor in self?.transcodingProgress = prog }
                        }
                        if let lastCR = buffer.lastIndex(of: "\r") {
                            buffer = String(buffer[buffer.index(after: lastCR)...])
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.waitUntilExit()

            await MainActor.run {
                self?.isTranscoding = false
                self?.transcodingProgress = 0
                self?.transcodingProcess = nil
                if process.terminationStatus == 0 {
                    self?.importFileDirectly(url: outputURL, type: .video)
                    self?.showImportToast("「\(url.lastPathComponent)」导入完成")
                } else {
                    self?.showImportToast("转码失败，FFmpeg 退出码: \(process.terminationStatus)")
                }
            }
        }
    }

    /// 同步执行 FFmpeg 命令，返回是否成功
    private static func runFFmpegSync(ffmpeg: URL, arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 查找 FFmpeg 可执行文件
    private static func findFFmpeg() -> URL? {
        // 优先从 app bundle 内部查找（已内置）
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledFFmpeg = bundlePath.appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: bundledFFmpeg.path) {
                return bundledFFmpeg
            }
        }
        // 回退到系统安装的版本
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // 尝试通过 which 查找
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffmpeg"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 用 ffprobe 获取视频总时长（秒）
    private static func probeVideoDuration(ffmpegDir: String, inputPath: String) -> Double {
        let probePath = ffmpegDir + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probePath) else { return 0 }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probePath)
        proc.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
           let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let dur = Double(str) {
            return dur
        }
        return 0
    }

    /// 解析 FFmpeg 的 "HH:MM:SS.xx" 时间格式为秒数
    private static func parseFFmpegTime(_ str: String) -> Double {
        let parts = str.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    /// 递归扫描文件夹，导入所有支持的素材
    private func importFolder(_ folderURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                importFile(fileURL)
            }
        }
    }

    func addToTimeline(_ asset: MediaAsset) {
        pushUndo()
        switch asset.type {
        case .video:
            // 每条视频放到独立的视频轨道，方便多轨编辑
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            Task {
                let avAsset = AVURLAsset(url: asset.url)
                let dur = (try? await avAsset.load(.duration))?.seconds ?? 30
                var natW: Double = 0, natH: Double = 0
                if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first,
                   let sz = try? await vTrack.load(.naturalSize) {
                    natW = sz.width; natH = sz.height
                }
                let finalW = natW, finalH = natH
                await MainActor.run {
                    self.videoTracks[trackIdx].clips.append(
                        VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: 0, endTime: dur, videoWidth: finalW, videoHeight: finalH))
                    self.duration = max(self.duration, dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .audio:
            if audioTracks.isEmpty { audioTracks.append(Track(label: "音频")) }
            let st = audioTracks[0].clips.map(\.endTime).max() ?? 0
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[0].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: st, endTime: st + dur))
                    self.duration = max(self.duration, st + dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .subtitle:
            let ext = asset.url.pathExtension.lowercased()
            var clips: [SubtitleClip]
            switch ext {
            case "ass": clips = parseASS(url: asset.url)
            case "vtt": clips = parseVTT(url: asset.url)
            default:    clips = parseSRT(url: asset.url)
            }
            // 给每个字幕片段打上素材 ID，供级联删除使用
            for i in clips.indices { clips[i].assetID = asset.id }
            // Use the first empty subtitle track if available; otherwise create
            // a brand-new track so each imported subtitle file lives on its own
            // line (so bilingual / multi-language workflows don't merge).
            if let idx = subtitleTracks.firstIndex(where: { $0.clips.isEmpty }) {
                subtitleTracks[idx].clips = clips
                if subtitleStyles.indices.contains(idx) == false {
                    subtitleStyles.append(SubtitleStyle())
                }
            } else {
                subtitleTracks.append(
                    Track(clips: clips, label: "字幕"))
                subtitleStyles.append(SubtitleStyle())
            }
            if let mx = clips.map(\.endTime).max() { duration = max(duration, mx) }
            if let i = mediaAssets.firstIndex(where:{ $0.id == asset.id }) {
                mediaAssets[i].duration = clips.last?.endTime ?? 0
            }
        case .image:
            let trackIdx: Int
            if let emptyIdx = imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                imageTracks.append(Track(label: "图片"))
                trackIdx = imageTracks.count - 1
            }
            let dur = 5.0
            let videoURL = imageVideoCache[asset.id]
            var imgW = 0, imgH = 0
            if let img = NSImage(contentsOf: asset.url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imgW = cg.width; imgH = cg.height
            }
            imageTracks[trackIdx].clips.append(
                ImageClip(assetID: asset.id, name: asset.name, imageURL: asset.url,
                          videoURL: videoURL, startTime: 0, endTime: dur,
                          imageWidth: imgW, imageHeight: imgH))
            duration = max(duration, dur)
            // Generate video if not cached yet, then update clip
            if videoURL == nil {
                let aid = asset.id
                let imgURL = asset.url
                let ti = trackIdx
                Task {
                    guard let vURL = await Self.createVideoFromImage(imageURL: imgURL, duration: dur) else { return }
                    await MainActor.run {
                        self.imageVideoCache[aid] = vURL
                        for ci in self.imageTracks[ti].clips.indices where self.imageTracks[ti].clips[ci].assetID == aid {
                            self.imageTracks[ti].clips[ci].videoURL = vURL
                        }
                        self.rebuildTimelinePreview()
                    }
                }
            } else {
                rebuildTimelinePreview()
            }
        }
    }

    /// Add asset to timeline at a specific time position (used for drag-drop from media library)
    func addToTimelineAt(_ asset: MediaAsset, time: Double) {
        pushUndo()
        let insertTime = max(0, time)
        switch asset.type {
        case .video:
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            Task {
                let avAsset = AVURLAsset(url: asset.url)
                let dur = (try? await avAsset.load(.duration))?.seconds ?? 30
                var natW: Double = 0, natH: Double = 0
                if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first,
                   let sz = try? await vTrack.load(.naturalSize) {
                    natW = sz.width; natH = sz.height
                }
                let finalW = natW, finalH = natH
                await MainActor.run {
                    self.videoTracks[trackIdx].clips.append(
                        VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: insertTime, endTime: insertTime + dur,
                                  videoWidth: finalW, videoHeight: finalH))
                    self.duration = max(self.duration, insertTime + dur)
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .audio:
            if audioTracks.isEmpty { audioTracks.append(Track(label: "音频")) }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[0].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: insertTime, endTime: insertTime + dur))
                    self.duration = max(self.duration, insertTime + dur)
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .image:
            let trackIdx: Int
            if let emptyIdx = imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                imageTracks.append(Track(label: "图片"))
                trackIdx = imageTracks.count - 1
            }
            let dur = 5.0
            let videoURL = imageVideoCache[asset.id]
            var imgW = 0, imgH = 0
            if let img = NSImage(contentsOf: asset.url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imgW = cg.width; imgH = cg.height
            }
            imageTracks[trackIdx].clips.append(
                ImageClip(assetID: asset.id, name: asset.name, imageURL: asset.url,
                          videoURL: videoURL, startTime: insertTime, endTime: insertTime + dur,
                          imageWidth: imgW, imageHeight: imgH))
            duration = max(duration, insertTime + dur)
            if videoURL == nil {
                let aid = asset.id; let imgURL = asset.url; let ti = trackIdx
                Task {
                    guard let vURL = await Self.createVideoFromImage(imageURL: imgURL, duration: dur) else { return }
                    await MainActor.run {
                        self.imageVideoCache[aid] = vURL
                        for ci in self.imageTracks[ti].clips.indices where self.imageTracks[ti].clips[ci].assetID == aid {
                            self.imageTracks[ti].clips[ci].videoURL = vURL
                        }
                        self.rebuildTimelinePreview()
                    }
                }
            } else {
                rebuildTimelinePreview()
            }
        case .subtitle:
            // Subtitles use parsed timing, not drop position — delegate to normal add
            addToTimeline(asset)
        }
    }

    // MARK: - Mutation helpers

    func updateSubtitleText(id: UUID, text: String) {
        pushUndoThrottled()
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                subtitleTracks[i].clips[j].text = text; return
            }
        }
    }

    func updateSubtitleTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                if let s = start { subtitleTracks[i].clips[j].startTime = s }
                if let e = end   { subtitleTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    func updateVideoClip(id: UUID, _ modify: (inout VideoClip) -> Void) {
        pushUndoThrottled()
        for i in videoTracks.indices {
            if let j = videoTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&videoTracks[i].clips[j]); return
            }
        }
    }

    func updateImageClip(id: UUID, _ modify: (inout ImageClip) -> Void) {
        pushUndoThrottled()
        for i in imageTracks.indices {
            if let j = imageTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&imageTracks[i].clips[j]); return
            }
        }
    }

    func updateAudioClip(id: UUID, _ modify: (inout AudioClip) -> Void) {
        pushUndoThrottled()
        for i in audioTracks.indices {
            if let j = audioTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&audioTracks[i].clips[j]); return
            }
        }
    }

    // MARK: - 字幕文件读取（编码检测 + 换行符统一）

    /// 尝试多种编码读取字幕文件，统一换行符为 \n，去除 BOM
    private func readSubtitleFile(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var content: String?

        // ── 第一步：用 macOS 内置引擎自动检测编码 ──
        // NSString.stringEncoding(for:) 能准确区分 Big5 / GBK / UTF-8 等
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        var convertedNS: NSString?
        var usedLossy: ObjCBool = false
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding.utf16.rawValue,
                    big5,
                    gb18030
                ] as [UInt],
                .useOnlySuggestedEncodingsKey: false as NSNumber,
                .allowLossyKey: false as NSNumber
            ],
            convertedString: &convertedNS,
            usedLossyConversion: &usedLossy)
        if detected != 0, !usedLossy.boolValue, let ns = convertedNS {
            content = ns as String
        }

        // ── 第二步：自动检测失败则手动逐个尝试 ──
        if content == nil {
            let encodings: [String.Encoding] = [
                .utf8,
                .utf16,
                String.Encoding(rawValue: big5),
                String.Encoding(rawValue: gb18030)
            ]
            for enc in encodings {
                if let s = String(data: data, encoding: enc), !s.isEmpty {
                    content = s; break
                }
            }
        }

        guard var text = content else { return nil }

        // 去除 BOM
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst())
        }

        // 统一换行符：\r\n → \n，单独 \r → \n
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        return text
    }

    // MARK: - SRT Parser

    func parseSRT(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        // 用正则切分空行块（兼容 \n\n、\r\n\r\n、混合换行）
        let blocks = raw.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 2, let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = srtTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = srtTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let idx = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let text = lines.dropFirst(idx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }
    private func srtTime(_ s: String) -> Double? {
        let c = s.replacingOccurrences(of: ",", with: ".")
        let p = c.components(separatedBy: ":"); guard p.count == 3 else { return nil }
        guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    // MARK: - ASS 解析

    func parseASS(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        var inEvents = false
        var formatFields: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("[events]") { inEvents = true; continue }
            if trimmed.hasPrefix("[") && !trimmed.lowercased().hasPrefix("[events]") { inEvents = false; continue }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                let fields = trimmed.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                formatFields = fields
                continue
            }
            guard trimmed.hasPrefix("Dialogue:") || trimmed.hasPrefix("dialogue:") else { continue }
            let content = String(trimmed.drop(while: { $0 != ":" }).dropFirst())
                .trimmingCharacters(in: .whitespaces)
            // ASS Dialogue 字段用逗号分隔，但 Text 字段可能包含逗号
            let parts = content.components(separatedBy: ",")
            // 使用实际 Format 行定义的字段数（不强制最小值）
            let fieldCount = formatFields.isEmpty ? 10 : formatFields.count
            guard parts.count >= fieldCount else { continue }
            let startIdx = formatFields.firstIndex(of: "start") ?? 1
            let endIdx = formatFields.firstIndex(of: "end") ?? 2
            let textIdx = formatFields.firstIndex(of: "text") ?? (fieldCount - 1)
            guard startIdx < parts.count, endIdx < parts.count, textIdx < parts.count else { continue }
            guard let s = assTime(parts[startIdx].trimmingCharacters(in: .whitespaces)),
                  let e = assTime(parts[endIdx].trimmingCharacters(in: .whitespaces)) else { continue }
            // Text 是最后一个字段，可能包含逗号，所以取 textIdx 之后的所有内容
            let text = parts[textIdx...].joined(separator: ",")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // 去除 ASS 样式标签 {\xxx}
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                // \N 换行符
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }

    private func assTime(_ s: String) -> Double? {
        // ASS 时间格式: H:MM:SS.cc (百分之一秒)
        let p = s.components(separatedBy: ":"); guard p.count == 3 else { return nil }
        guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    // MARK: - VTT 解析

    func parseVTT(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        let blocks = raw.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            // VTT 时间戳可能有位置信息在 --> 后面，去掉
            let endPart = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? parts[1]
            guard let s = vttTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = vttTime(endPart.trimmingCharacters(in: .whitespaces)) else { continue }
            let idx = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let text = lines.dropFirst(idx + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // 去除 VTT 标签 <b> <i> 等
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }

    private func vttTime(_ s: String) -> Double? {
        // VTT 时间格式: HH:MM:SS.mmm 或 MM:SS.mmm
        let p = s.components(separatedBy: ":")
        if p.count == 3 {
            guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        } else if p.count == 2 {
            guard let m = Double(p[0]), let sec = Double(p[1]) else { return nil }
            return m * 60 + sec
        }
        return nil
    }

    /// User-initiated playhead move — updates `currentTime` AND tells the
    /// player to seek (via `seekRequest` counter observed by PlayerView).
    func requestSeek(to t: Double) {
        currentTime = max(t, 0)
        seekRequest &+= 1
    }

    // MARK: - Undo / Redo

    private var lastUndoPushTime: Date = .distantPast

    func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()
    }

    /// 节流版 pushUndo — 1秒内连续编辑只记录一次（适合滑块、步进器等高频操作）
    func pushUndoThrottled() {
        isSaved = false
        scheduleAutoSave()
        if Date().timeIntervalSince(lastUndoPushTime) > 1.0 {
            pushUndo()
        }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
        isSaved = false
        scheduleAutoSave()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
        isSaved = false
        scheduleAutoSave()
    }

    private func currentSnapshot() -> ProjectSnapshot {
        ProjectSnapshot(videoTracks: videoTracks, audioTracks: audioTracks,
                        imageTracks: imageTracks,
                        subtitleTracks: subtitleTracks, subtitleStyles: subtitleStyles,
                        duration: duration)
    }
    private func applySnapshot(_ s: ProjectSnapshot) {
        videoTracks    = s.videoTracks
        audioTracks    = s.audioTracks
        imageTracks    = s.imageTracks
        subtitleTracks = s.subtitleTracks
        subtitleStyles = s.subtitleStyles
        duration       = s.duration
        if let assets = s.mediaAssets {
            mediaAssets = assets
            // Regenerate thumbnails for restored assets
            for asset in assets {
                if asset.fileExists { loadMediaResources(asset) }
            }
        }
        rebuildTimelinePreview()
    }

    // MARK: - Edit operations

    /// Split ONLY the currently selected clip at the playhead. If nothing selected, do nothing.
    func splitAtPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false

        if let id = selectedVideoClipID {
            outer: for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = videoTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        videoTracks[ti].clips[ci].endTime = t
                        var newClip = VideoClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime),
                            overrideResolution: c.overrideResolution,
                            overrideFPS: c.overrideFPS,
                            overrideBitrate: c.overrideBitrate)
                        newClip.volume = c.volume
                        newClip.scaleX = c.scaleX; newClip.scaleY = c.scaleY
                        newClip.lockAspect = c.lockAspect
                        newClip.offsetX = c.offsetX; newClip.offsetY = c.offsetY
                        newClip.cropTop = c.cropTop; newClip.cropBottom = c.cropBottom
                        newClip.cropLeft = c.cropLeft; newClip.cropRight = c.cropRight
                        videoTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedAudioClipID {
            outer: for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = audioTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        audioTracks[ti].clips[ci].endTime = t
                        let newClip = AudioClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime),
                            volume: c.volume, leftChannel: c.leftChannel, rightChannel: c.rightChannel,
                            sampleRate: c.sampleRate, format: c.format)
                        audioTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedSubtitleClipID {
            outer: for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = subtitleTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        subtitleTracks[ti].clips[ci].endTime = t
                        let newClip = SubtitleClip(text: c.text, startTime: t, endTime: c.endTime)
                        subtitleTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        }

        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
        }
    }

    /// Delete every selected clip — multi-selection (box-select) + the
    /// single-selection IDs used by the Inspector.
    func deleteSelected() {
        let snap = currentSnapshot()
        var changed = false

        // Pool of all IDs to remove
        var ids = selectedClipIDs
        if let id = selectedVideoClipID    { ids.insert(id) }
        if let id = selectedImageClipID    { ids.insert(id) }
        if let id = selectedAudioClipID    { ids.insert(id) }
        if let id = selectedSubtitleClipID { ids.insert(id) }
        guard !ids.isEmpty else { return }

        for i in videoTracks.indices {
            let before = videoTracks[i].clips.count
            videoTracks[i].clips.removeAll { ids.contains($0.id) }
            if videoTracks[i].clips.count != before { changed = true }
        }
        for i in imageTracks.indices {
            let before = imageTracks[i].clips.count
            imageTracks[i].clips.removeAll { ids.contains($0.id) }
            if imageTracks[i].clips.count != before { changed = true }
        }
        for i in audioTracks.indices {
            let before = audioTracks[i].clips.count
            audioTracks[i].clips.removeAll { ids.contains($0.id) }
            if audioTracks[i].clips.count != before { changed = true }
        }
        for i in subtitleTracks.indices {
            let before = subtitleTracks[i].clips.count
            subtitleTracks[i].clips.removeAll { ids.contains($0.id) }
            if subtitleTracks[i].clips.count != before { changed = true }
        }

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()

        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
        }
    }

    // MARK: - Copy / Cut / Paste

    /// 复制当前选中的片段到剪贴板
    func copySelected() {
        if let id = selectedVideoClipID {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .video(clip, trackIndex: ti)
                    clipboardIsCut = false; clipboardSourceID = nil; return
                }
            }
        }
        if let id = selectedImageClipID {
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .image(clip, trackIndex: ti)
                    clipboardIsCut = false; clipboardSourceID = nil; return
                }
            }
        }
        if let id = selectedAudioClipID {
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .audio(clip, trackIndex: ti)
                    clipboardIsCut = false
                    clipboardSourceID = nil
                    return
                }
            }
        }
        if let id = selectedSubtitleClipID {
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .subtitle(clip, trackIndex: ti)
                    clipboardIsCut = false
                    clipboardSourceID = nil
                    return
                }
            }
        }
    }

    /// 剪切当前选中的片段（粘贴时移除原始片段）
    func cutSelected() {
        if let id = selectedVideoClipID {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .video(clip, trackIndex: ti)
                    clipboardIsCut = true; clipboardSourceID = id; return
                }
            }
        }
        if let id = selectedImageClipID {
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .image(clip, trackIndex: ti)
                    clipboardIsCut = true; clipboardSourceID = id; return
                }
            }
        }
        if let id = selectedAudioClipID {
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .audio(clip, trackIndex: ti)
                    clipboardIsCut = true
                    clipboardSourceID = id
                    return
                }
            }
        }
        if let id = selectedSubtitleClipID {
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    clipboard = .subtitle(clip, trackIndex: ti)
                    clipboardIsCut = true
                    clipboardSourceID = id
                    return
                }
            }
        }
    }

    /// 粘贴剪贴板内容到当前播放头位置，放在同类型的当前选中轨道或原始轨道
    func pasteAtPlayhead() {
        guard let item = clipboard else { return }
        let snap = currentSnapshot()
        let t = currentTime

        // 如果是剪切，先删除原始片段
        if clipboardIsCut, let srcID = clipboardSourceID {
            for i in videoTracks.indices {
                videoTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in imageTracks.indices {
                imageTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in audioTracks.indices {
                audioTracks[i].clips.removeAll { $0.id == srcID }
            }
            for i in subtitleTracks.indices {
                subtitleTracks[i].clips.removeAll { $0.id == srcID }
            }
            // 剪切只能粘贴一次
            clipboardIsCut = false
            clipboardSourceID = nil
        }

        switch item {
        case .video(let clip, let trackIdx):
            var newClip = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                    startTime: t, endTime: t + clip.duration, trimStart: clip.trimStart)
            newClip.volume = clip.volume
            newClip.overrideResolution = clip.overrideResolution
            newClip.overrideFPS = clip.overrideFPS
            newClip.overrideBitrate = clip.overrideBitrate
            newClip.scaleX = clip.scaleX; newClip.scaleY = clip.scaleY
            newClip.lockAspect = clip.lockAspect
            newClip.offsetX = clip.offsetX; newClip.offsetY = clip.offsetY
            newClip.cropTop = clip.cropTop; newClip.cropBottom = clip.cropBottom
            newClip.cropLeft = clip.cropLeft; newClip.cropRight = clip.cropRight
            let idx = videoTracks.indices.contains(trackIdx) ? trackIdx : 0
            if videoTracks.indices.contains(idx) {
                videoTracks[idx].clips.append(newClip)
                selectedVideoClipID = newClip.id
                selectedAudioClipID = nil
                selectedSubtitleClipID = nil
            }

        case .image(let clip, let trackIdx):
            var newClip = ImageClip(assetID: clip.assetID, name: clip.name, imageURL: clip.imageURL,
                                     videoURL: clip.videoURL, startTime: t, endTime: t + clip.duration,
                                     imageWidth: clip.imageWidth, imageHeight: clip.imageHeight)
            newClip.scaleX = clip.scaleX; newClip.scaleY = clip.scaleY
            newClip.lockAspect = clip.lockAspect
            newClip.offsetX = clip.offsetX; newClip.offsetY = clip.offsetY
            newClip.cropTop = clip.cropTop; newClip.cropBottom = clip.cropBottom
            newClip.cropLeft = clip.cropLeft; newClip.cropRight = clip.cropRight
            let idx = imageTracks.indices.contains(trackIdx) ? trackIdx : 0
            if imageTracks.indices.contains(idx) {
                imageTracks[idx].clips.append(newClip)
                selectedImageClipID = newClip.id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            }

        case .audio(let clip, let trackIdx):
            var newClip = AudioClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                    startTime: t, endTime: t + clip.duration, trimStart: clip.trimStart)
            newClip.volume = clip.volume
            newClip.leftChannel = clip.leftChannel
            newClip.rightChannel = clip.rightChannel
            newClip.sampleRate = clip.sampleRate
            newClip.format = clip.format
            let idx = audioTracks.indices.contains(trackIdx) ? trackIdx : 0
            if audioTracks.indices.contains(idx) {
                audioTracks[idx].clips.append(newClip)
                selectedAudioClipID = newClip.id
                selectedVideoClipID = nil
                selectedSubtitleClipID = nil
            }

        case .subtitle(let clip, let trackIdx):
            let newClip = SubtitleClip(text: clip.text, startTime: t, endTime: t + clip.duration)
            let idx = subtitleTracks.indices.contains(trackIdx) ? trackIdx : 0
            if subtitleTracks.indices.contains(idx) {
                subtitleTracks[idx].clips.append(newClip)
                selectedSubtitleClipID = newClip.id
                selectedVideoClipID = nil
                selectedAudioClipID = nil
            }
        }

        undoStack.append(snap)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
    }

    /// Move the selected clip so its start aligns with the current playhead.
    func alignSelectedToPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false
        if let id = selectedVideoClipID {
            updateVideoClip(id: id) { c in
                let d = c.duration; c.startTime = t; c.endTime = t + d
            }; changed = true
        } else if let id = selectedAudioClipID {
            updateAudioClip(id: id) { c in
                let d = c.duration; c.startTime = t; c.endTime = t + d
            }; changed = true
        } else if let id = selectedSubtitleClipID {
            for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where:{ $0.id==id }) {
                    let d = subtitleTracks[ti].clips[ci].duration
                    subtitleTracks[ti].clips[ci].startTime = t
                    subtitleTracks[ti].clips[ci].endTime   = t + d
                    changed = true; break
                }
            }
        }
        if changed {
            undoStack.append(snap)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
        }
    }

    // MARK: - Image → Video generation

    static func createVideoFromImage(imageURL: URL, duration: Double) async -> URL? {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let width = cgImage.width
        let height = cgImage.height

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Write 1 frame per second
        let totalFrames = max(Int(duration), 1)
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 1))
        }
        // Final frame at exact end
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(pb, withPresentationTime: CMTime(seconds: duration, preferredTimescale: 600))

        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }

    /// Insert a new subtitle clip into the active subtitle track at the playhead.
    func insertSubtitleAtPlayhead() {
        let snap = currentSnapshot()

        let trackIdx: Int
        if let sid = selectedSubtitleClipID {
            // 选中了字幕片段 → 在其所在轨道新建
            trackIdx = subtitleTracks.firstIndex { $0.clips.contains { $0.id == sid } } ?? 0
        } else {
            // 没选中任何字幕 → 新建轨道（放在最后）
            let newTrack = Track<SubtitleClip>(label: "字幕")
            subtitleTracks.append(newTrack)
            subtitleStyles.append(SubtitleStyle())
            trackIdx = subtitleTracks.count - 1
        }

        let start = currentTime
        let end   = min(currentTime + 2.0, max(duration, currentTime + 2.0))
        let clip  = SubtitleClip(text: "新字幕", startTime: start, endTime: end)
        subtitleTracks[trackIdx].clips.append(clip)
        subtitleTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        selectedSubtitleClipID = clip.id

        undoStack.append(snap)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v>>16)&0xFF)/255, green: Double((v>>8)&0xFF)/255, blue: Double(v&0xFF)/255)
    }

    func toHex() -> String {
        let nc = NSColor(self).usingColorSpace(.sRGB) ?? .white
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nc.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Channel Volume Tap

/// 存储左右声道音量，传给 MTAudioProcessingTap
private struct ChannelVols {
    var left: Float
    var right: Float
}

/// 创建一个音频处理 Tap，对左右声道分别应用音量
func makeChannelTap(left: Float, right: Float) -> MTAudioProcessingTap? {
    let ctx = UnsafeMutablePointer<ChannelVols>.allocate(capacity: 1)
    ctx.initialize(to: ChannelVols(left: left, right: right))

    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: UnsafeMutableRawPointer(ctx),
        `init`: { (_, clientInfo, storageOut) in
            storageOut.pointee = clientInfo
        },
        finalize: { tap in
            let s = MTAudioProcessingTapGetStorage(tap)
            s.assumingMemoryBound(to: ChannelVols.self).deinitialize(count: 1)
            s.assumingMemoryBound(to: ChannelVols.self).deallocate()
        },
        prepare: nil,
        unprepare: nil,
        process: { (tap, frames, _, buf, framesOut, flagsOut) in
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, buf, flagsOut, nil, framesOut) == noErr else { return }
            let vols = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: ChannelVols.self).pointee
            let abl = UnsafeMutableAudioBufferListPointer(buf)
            for i in 0..<abl.count {
                guard let data = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(abl[i].mDataByteSize) / MemoryLayout<Float>.size
                var vol = (i == 0) ? vols.left : vols.right
                vDSP_vsmul(data, 1, &vol, data, 1, vDSP_Length(n))
            }
        }
    )

    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr else { ctx.deallocate(); return nil }
    return tap
}
