import SwiftUI
import AVFoundation
import MediaToolbox
import Accelerate
import Combine
import NaturalLanguage

// MARK: - PlaybackClock（高频播放状态，独立 ObservableObject）
// 播放时 currentTime 每秒更新 30 次。如果放在 ProjectState 里，
// 所有监听 ProjectState 的视图（属性区、素材库等）都会被迫重新 evaluate body。
// 拆分后只有 PlayerView 和 TimelineView 监听 PlaybackClock，其余视图不受影响。

final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 60
    @Published var lastVideoEndTime: Double = 0
    @Published var seekRequest: Int = 0
    var pendingSeekTime: Double? = nil
}

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
    var importDate: Date?
    var fileSize: Int64?
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
    var mergeLineBreaks: Bool = false   // 合并换行：去掉字幕中的手动换行，按宽度自动重排

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, bold, italic
        case textColorHex, backgroundColorHex, backgroundOpacity
        case bottomMargin, widthPercent, alignment, lineSpacing, mergeLineBreaks
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
        try c.encode(mergeLineBreaks, forKey: .mergeLineBreaks)
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
        mergeLineBreaks = (try? c.decode(Bool.self, forKey: .mergeLineBreaks)) ?? false
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

// MARK: - Transition

enum TransitionType: String, Codable, CaseIterable {
    case dissolve       // 淡入淡出
    case fadeToBlack    // 渐黑
    case pushLeft       // 从右推入
    case pushRight      // 从左推入
    case pushUp         // 从下推入
    case pushDown       // 从上推入
    case zoom           // 缩放（前片放大淡出 + 后片缩小淡入）
    case slideLeft      // 滑入(左)：后片从右滑入覆盖，前片不动
    case slideRight     // 滑入(右)：后片从左滑入覆盖
    case slideUp        // 滑入(上)：后片从下滑入覆盖
    case slideDown      // 滑入(下)：后片从上滑入覆盖

    var label: String {
        switch self {
        case .dissolve:    return "淡入淡出"
        case .fadeToBlack: return "渐黑"
        case .pushLeft:    return "推入(左)"
        case .pushRight:   return "推入(右)"
        case .pushUp:      return "推入(上)"
        case .pushDown:    return "推入(下)"
        case .zoom:        return "缩放"
        case .slideLeft:   return "滑入(左)"
        case .slideRight:  return "滑入(右)"
        case .slideUp:     return "滑入(上)"
        case .slideDown:   return "滑入(下)"
        }
    }

    var icon: String {
        switch self {
        case .dissolve:    return "circle.lefthalf.filled"
        case .fadeToBlack: return "circle.filled.ipad.landscape"
        case .pushLeft:    return "arrow.left.square"
        case .pushRight:   return "arrow.right.square"
        case .pushUp:      return "arrow.up.square"
        case .pushDown:    return "arrow.down.square"
        case .zoom:        return "plus.magnifyingglass"
        case .slideLeft:   return "arrow.left.to.line"
        case .slideRight:  return "arrow.right.to.line"
        case .slideUp:     return "arrow.up.to.line"
        case .slideDown:   return "arrow.down.to.line"
        }
    }

    /// 是否为滑入类（A 不动，仅 B 位移覆盖）
    var isSlide: Bool {
        switch self {
        case .slideLeft, .slideRight, .slideUp, .slideDown: return true
        default: return false
        }
    }

    /// 是否为推入类（A、B 同时位移）
    var isPush: Bool {
        switch self {
        case .pushLeft, .pushRight, .pushUp, .pushDown: return true
        default: return false
        }
    }
}

struct Transition: Identifiable, Equatable, Codable {
    var id = UUID()
    var type: TransitionType = .dissolve
    var duration: Double = 0.5  // 秒，以切割点为中心
}

/// 编译后的转场参数，供 VideoComposition instruction 构建使用
struct TransitionCompInfo {
    let trackA: AVMutableCompositionTrack   // 前一个 clip 的 track
    let trackB: AVMutableCompositionTrack   // 后一个 clip 的 track
    let clipA: VideoClip
    let clipB: VideoClip
    let type: TransitionType
    /// 效果区间开始（= cutT - half）
    let overlapStart: CMTime
    /// 效果区间结束（dissolve/push = cutT + half；fadeToBlack = cutT + half 但 A/B 各占一半）
    let overlapEnd: CMTime
    /// 原始切割点（fadeToBlack 用来分隔 A 淡出段 / B 淡入段）
    let cutT: CMTime
    let half: Double         // 单边时长（秒）
    let renderSize: CGSize
    let natSizeA: CGSize
    let natSizeB: CGSize
}

// MARK: - Video Clip

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
    var audioTrackIndex: Int       = 0   // 多音轨时选择哪个音频流（0=默认第一个）
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
    // 播放速率：1.0=正常，2.0=2倍速，0.5=半速（0.1~4.0）
    // 语义：时间轴宽度不变，源素材消耗量 = duration * speed
    var speed: Double = 1.0
    // 色调调节
    var colorAdjust: ColorAdjust = .identity
    // 转场：从前一个 clip 到本 clip 的转场效果（nil = 无转场）
    var inTransition: Transition? = nil
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
    // 播放速率
    var speed: Double = 1.0
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
    // 色调调节
    var colorAdjust: ColorAdjust = .identity
}

// MARK: - Text Template (文字样式模板)

struct TextTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "模板"
    var fontName: String = "PingFang SC"
    var fontSize: CGFloat = 64
    var bold: Bool = true
    var italic: Bool = false
    var textColorHex: String = "#FFFFFF"
    var strokeColorHex: String = "#000000"
    var strokeWidth: Double = 0
    var bgColorHex: String = "#000000"
    var bgOpacity: Double = 0
    var alignment: String = "center"
    var rotation: Double = 0
    var opacity: Double = 1
    var animation: TextAnimation = .none

    static func from(_ clip: TextClip, name: String) -> TextTemplate {
        TextTemplate(
            name: name,
            fontName: clip.fontName, fontSize: clip.fontSize,
            bold: clip.bold, italic: clip.italic,
            textColorHex: clip.textColor.toHex(),
            strokeColorHex: clip.strokeColor.toHex(),
            strokeWidth: clip.strokeWidth,
            bgColorHex: clip.bgColor.toHex(),
            bgOpacity: clip.bgOpacity,
            alignment: clip.alignment,
            rotation: clip.rotation,
            opacity: clip.opacity,
            animation: clip.animation
        )
    }

    func apply(to clip: inout TextClip) {
        clip.fontName = fontName; clip.fontSize = fontSize
        clip.bold = bold; clip.italic = italic
        clip.textColor = Color(hex: textColorHex)
        clip.strokeColor = Color(hex: strokeColorHex)
        clip.strokeWidth = strokeWidth
        clip.bgColor = Color(hex: bgColorHex)
        clip.bgOpacity = bgOpacity
        clip.alignment = alignment
        clip.rotation = rotation
        clip.opacity = opacity
        clip.animation = animation
    }
}

// MARK: - Text Clip (文字/标题图层)

enum TextAnimation: String, Codable, CaseIterable {
    case none, fadeIn, popIn, slideUp, typewriter
    var label: String {
        switch self {
        case .none:       return "无"
        case .fadeIn:     return "淡入"
        case .popIn:      return "弹入"
        case .slideUp:    return "上滑入"
        case .typewriter: return "打字机"
        }
    }
}

struct TextClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String      = "标题文字"
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    // 位置：画面比例，文字中心点 (0~1)，(0.5,0.5)=正中
    var posX: Double = 0.5
    var posY: Double = 0.5
    // 样式
    var fontName: String  = "PingFang SC"
    var fontSize: CGFloat = 64
    var bold: Bool        = true
    var italic: Bool      = false
    var textColor: Color  = .white
    var strokeColor: Color = .black
    var strokeWidth: Double = 0        // 描边宽度(px)，0=无描边
    var bgColor: Color    = .black
    var bgOpacity: Double = 0          // 背景不透明度，0=无背景框
    var alignment: String = "center"   // left/center/right
    var rotation: Double  = 0          // 旋转角度(度)
    var opacity: Double   = 1
    var animation: TextAnimation = .none

    enum CodingKeys: String, CodingKey {
        case id, text, startTime, endTime, posX, posY
        case fontName, fontSize, bold, italic
        case textColorHex, strokeColorHex, strokeWidth, bgColorHex, bgOpacity
        case alignment, rotation, opacity, animation
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(posX, forKey: .posX)
        try c.encode(posY, forKey: .posY)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(textColor.toHex(), forKey: .textColorHex)
        try c.encode(strokeColor.toHex(), forKey: .strokeColorHex)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(bgColor.toHex(), forKey: .bgColorHex)
        try c.encode(bgOpacity, forKey: .bgOpacity)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(animation, forKey: .animation)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        text      = try c.decode(String.self, forKey: .text)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime   = try c.decode(Double.self, forKey: .endTime)
        posX      = (try? c.decode(Double.self, forKey: .posX)) ?? 0.5
        posY      = (try? c.decode(Double.self, forKey: .posY)) ?? 0.5
        fontName  = (try? c.decode(String.self, forKey: .fontName)) ?? "PingFang SC"
        fontSize  = (try? c.decode(CGFloat.self, forKey: .fontSize)) ?? 64
        bold      = (try? c.decode(Bool.self, forKey: .bold)) ?? true
        italic    = (try? c.decode(Bool.self, forKey: .italic)) ?? false
        textColor   = Color(hex: (try? c.decode(String.self, forKey: .textColorHex)) ?? "#FFFFFF")
        strokeColor = Color(hex: (try? c.decode(String.self, forKey: .strokeColorHex)) ?? "#000000")
        strokeWidth = (try? c.decode(Double.self, forKey: .strokeWidth)) ?? 0
        bgColor     = Color(hex: (try? c.decode(String.self, forKey: .bgColorHex)) ?? "#000000")
        bgOpacity   = (try? c.decode(Double.self, forKey: .bgOpacity)) ?? 0
        alignment   = (try? c.decode(String.self, forKey: .alignment)) ?? "center"
        rotation    = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        opacity     = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        animation   = (try? c.decode(TextAnimation.self, forKey: .animation)) ?? .none
    }
    init(text: String = "标题文字", startTime: Double, endTime: Double) {
        self.text = text; self.startTime = startTime; self.endTime = endTime
    }
}

struct Track<Clip: Identifiable & Equatable & Codable>: Identifiable, Codable {
    var id = UUID()
    var clips: [Clip]   = []
    var label: String   = ""
    var isMuted: Bool   = false
    var isVisible: Bool = true
    var subtitleStyle: SubtitleStyle? = nil  // 仅字幕轨道使用，style 随 track 生死
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
    var bitrate: Int             = 5000   // kbps（1080p 标准画质，网络视频常用 2-6 Mbps）
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
    var textTracks: [Track<TextClip>]?     // 文字/标题图层（向后兼容：旧 .bcj 无此字段）
    var textTemplates: [TextTemplate]?    // 文字样式模板（向后兼容）
    var mediaAssets: [MediaAsset]
    var exportSettings: ExportSettings
    var previewResolution: String
    var subtitleBottomMargin: Double?
    var subtitleLineSpacing: Double?
    var overlayTrackOrder: [ProjectState.OverlayTrackRef]?
}

extension ExportSettings: Codable {}

// MARK: - Snapshot (for undo/redo)

struct ProjectSnapshot {
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var textTracks: [Track<TextClip>]
    var overlayTrackOrder: [ProjectState.OverlayTrackRef]
    var subtitleBottomMargin: Double
    var subtitleLineSpacing: Double
    var duration: Double
    var mediaAssets: [MediaAsset]? = nil
}

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
    private var audioSpeedCache: [String: URL] = [:]
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
    private var successTimer: Timer?

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

    private func startSuccessTimerIfNeeded() {
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
    private var pendingTasks: [TranscodeTask] = []
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
    @Published var thumbnailsReloading: Set<UUID> = []              // 正在重建缩略图的 asset IDs
    @Published var waveformCache: [UUID: WaveformData] = [:]       // asset ID → waveform peaks
    var imageVideoCache: [UUID: URL] = [:]                         // asset ID → generated video file
    private var avAssetCache: [URL: AVURLAsset] = [:]             // URL → cached AVURLAsset（避免重复创建）

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
        audioTracks = []
        imageTracks = []
        subtitleTracks = []
        textTracks = []
        subtitleBottomMargin = 5
        subtitleLineSpacing = 6
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0; duration = 60
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedTextClipID = nil
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

        guard url.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法访问项目文件"
                alert.informativeText = "系统安全权限不足，请重新选择文件或检查权限设置。\n路径：\(url.path)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
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
        // 加载字幕轨道，兼容旧 .bcj（subtitleStyles 单独数组）：把旧 style 迁移进 track
        var loadedSubtitleTracks = doc.subtitleTracks
        for i in loadedSubtitleTracks.indices {
            if loadedSubtitleTracks[i].subtitleStyle == nil,
               i < doc.subtitleStyles.count {
                loadedSubtitleTracks[i].subtitleStyle = doc.subtitleStyles[i]
            }
        }
        subtitleTracks = loadedSubtitleTracks
        textTracks = doc.textTracks ?? []
        textTemplates = doc.textTemplates ?? []
        subtitleBottomMargin = doc.subtitleBottomMargin ?? doc.subtitleStyles.first?.bottomMargin ?? 5
        subtitleLineSpacing = doc.subtitleLineSpacing ?? doc.subtitleStyles.first?.lineSpacing ?? 6
        overlayTrackOrder = doc.overlayTrackOrder ?? []
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

        syncOverlayOrder()
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
        if projectFileURL == nil && !silent {
            let panel = NSSavePanel()
            panel.title = "保存项目"
            panel.nameFieldStringValue = (projectName.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名项目" : projectName) + ".bcj"
            panel.allowedContentTypes = [.init(filenameExtension: "bcj") ?? .json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            projectName = url.deletingPathExtension().lastPathComponent
            projectFileURL = url
        } else if projectFileURL == nil {
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let name = projectName.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名项目" : projectName
            projectName = name
            projectFileURL = docDir.appendingPathComponent("\(name).bcj")
        }
        guard let fileURL = projectFileURL else { return }
        let doc = ProjectDocument(
            name: projectName,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            imageTracks: imageTracks,
            subtitleTracks: subtitleTracks,
            subtitleStyles: subtitleTracks.map { $0.subtitleStyle ?? SubtitleStyle() },  // 向后兼容旧格式
            textTracks: textTracks,
            textTemplates: textTemplates.isEmpty ? nil : textTemplates,
            mediaAssets: mediaAssets,
            exportSettings: exportSettings,
            previewResolution: previewResolution,
            subtitleBottomMargin: subtitleBottomMargin,
            subtitleLineSpacing: subtitleLineSpacing,
            overlayTrackOrder: overlayTrackOrder.isEmpty ? nil : overlayTrackOrder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            isSaved = true
        } catch {
            isSaved = false
            if silent {
                showImportToast("自动保存失败：\(error.localizedDescription)")
            } else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
        guard !silent else { return }
        showSuccessToast(icon: "checkmark", title: "已保存", subtitle: fileURL.lastPathComponent, revealURL: fileURL)
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
        let snapshot = currentSnapshot(includeAssets: true)
        undoStack.append(snapshot)
        if undoStack.count > 30 { undoStack.removeFirst() }
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
        guard let type = Self.assetType(for: ext) else { return }
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
        generateThumbnails(assetID: assetID, url: url)
    }

    func reloadThumbnails(assetID: UUID, url: URL) {
        guard !thumbnailsReloading.contains(assetID) else { return }
        thumbnailsReloading.insert(assetID)
        generateThumbnails(assetID: assetID, url: url, isReload: true)
    }

    private func generateThumbnails(assetID: UUID, url: URL, isReload: Bool = false) {
        if !isReload { assetThumbnails[assetID] = [] }
        let id = assetID
        let pps = pixelsPerSecond
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0.1 else {
                await MainActor.run { self.thumbnailsReloading.remove(id) }
                return
            }
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 104)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.3, preferredTimescale: 600)

            let thumbWidth = 48.0
            let neededFrames = Int(dur * pps / thumbWidth)
            let frameCount = max(10, min(200, neededFrames))
            let interval = dur / Double(frameCount)
            var times: [NSValue] = []
            var t = 0.0
            while t < dur {
                times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
                t += interval
            }

            var frames: [ThumbnailFrame] = []
            let semaphore = DispatchSemaphore(value: 0)
            var remaining = times.count
            gen.generateCGImagesAsynchronously(forTimes: times) { requested, cgImage, actual, result, error in
                if result == .succeeded, let cg = cgImage {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    frames.append(ThumbnailFrame(time: requested.seconds, image: img))
                }
                remaining -= 1
                if remaining == 0 { semaphore.signal() }
            }
            await Task.detached(priority: .utility) { semaphore.wait() }.value
            let sorted = frames.sorted(by: { $0.time < $1.time })
            await MainActor.run {
                self.assetThumbnails[id] = sorted
                self.thumbnailsReloading.remove(id)
            }
        }
    }

    func refreshAllThumbnails() {
        var seen = Set<UUID>()
        for t in videoTracks {
            for c in t.clips {
                guard !seen.contains(c.assetID), let url = c.url else { continue }
                seen.insert(c.assetID)
                reloadThumbnails(assetID: c.assetID, url: url)
            }
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
            let chunkTarget = 2000  // samples per peak
            // 直接在原始缓冲区上计算峰值，避免反复 append/removeFirst 的内存拷贝
            var runningPeak: Int16 = 0
            var samplesInChunk = 0

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

                for sample in samples {
                    let absSample = sample == Int16.min ? Int16.max : abs(sample)
                    if absSample > runningPeak { runningPeak = absSample }
                    samplesInChunk += 1
                    if samplesInChunk >= chunkTarget {
                        allPeaks.append(Float(runningPeak) / Float(Int16.max))
                        runningPeak = 0
                        samplesInChunk = 0
                    }
                }
            }
            if samplesInChunk > 0 {
                allPeaks.append(Float(runningPeak) / Float(Int16.max))
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
        let snap = currentSnapshot(includeAssets: true)
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
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 清空素材库及时间轴上所有关联片段
    func clearMediaLibrary() {
        pushUndoSavingAssets()
        mediaAssets.removeAll()
        mediaThumbnails.removeAll()
        waveformCache.removeAll()
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll() }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll() }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll() }
        for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll() }
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
        pushUndoSavingAssets()
        if let i = mediaAssets.firstIndex(where: { $0.id == id }) {
            mediaAssets[i].url = newURL
            mediaAssets[i].name = newURL.lastPathComponent
        }
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
        // 图片轨：更新 imageURL 并清理旧缓存视频，重新生成
        for ti in imageTracks.indices {
            for ci in imageTracks[ti].clips.indices where imageTracks[ti].clips[ci].assetID == id {
                imageTracks[ti].clips[ci].imageURL = newURL
                imageTracks[ti].clips[ci].videoURL = nil
            }
        }
        imageVideoCache.removeValue(forKey: id)
        // 清理旧缓存，重新加载素材资源
        mediaThumbnails.removeValue(forKey: id)
        waveformCache.removeValue(forKey: id)
        if let asset = mediaAssets.first(where: { $0.id == id }) {
            loadMediaResources(asset)
        }
        // 重新加载时长和尺寸
        Task {
            let avAsset = AVURLAsset(url: newURL)
            if let dur = try? await avAsset.load(.duration) {
                await MainActor.run {
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == id }) {
                        self.mediaAssets[i].duration = dur.seconds
                    }
                }
            }
            if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first {
                let sz = try? await vTrack.load(.naturalSize)
                await MainActor.run {
                    if let sz {
                        for ti in self.videoTracks.indices {
                            for ci in self.videoTracks[ti].clips.indices where self.videoTracks[ti].clips[ci].assetID == id {
                                self.videoTracks[ti].clips[ci].videoWidth = sz.width
                                self.videoTracks[ti].clips[ci].videoHeight = sz.height
                            }
                        }
                    }
                }
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
                    syncOverlayOrder()
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
                    newTrack.subtitleStyle = newSubtitleStyle()
                    subtitleTracks.append(newTrack)
                    syncOverlayOrder()
                }
            }
            return
        }
    }

    /// 为新字幕轨自动计算 bottomMargin，避免与已有轨道重叠
    func newSubtitleStyle() -> SubtitleStyle {
        SubtitleStyle()
    }

    func resolveTextOverlap(id: UUID) {
        for ti in textTracks.indices {
            guard let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = textTracks[ti].clips[ci]
            let hasOverlap = textTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = textTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in textTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !textTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        textTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<TextClip>(label: "文字")
                    newTrack.clips.append(removed)
                    textTracks.append(newTrack)
                    syncOverlayOrder()
                }
            }
            return
        }
    }

    func moveTextClipToTrack(id: UUID, from: Int, to: Int) {
        guard textTracks.indices.contains(from), textTracks.indices.contains(to) else { return }
        guard let idx = textTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = textTracks[from].clips.remove(at: idx)
        textTracks[to].clips.append(clip)
    }

    func updateTextTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in textTracks.indices {
            if let j = textTracks[i].clips.firstIndex(where: { $0.id == id }) {
                if let s = start { textTracks[i].clips[j].startTime = s }
                if let e = end   { textTracks[i].clips[j].endTime   = e }
                return
            }
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
            if selectedTextClipID == id     { selectedTextClipID = nil }
        } else {
            // Move current primary into multi-set if needed
            if let pid = selectedVideoClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedImageClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedAudioClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedSubtitleClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedTextClipID, pid != id { selectedClipIDs.insert(pid) }
            selectedClipIDs.insert(id)
            // Set as new primary based on type
            if videoTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedVideoClipID = id
                selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedImageClipID = id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if audioTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedAudioClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if subtitleTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedSubtitleClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedTextClipID = nil
            } else if textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedTextClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            }
        }
    }

    /// 把当前主选中片段合并进 selectedClipIDs（用于向左/右全选等场景）
    private func mergePrimaryIntoSelection() {
        if let pid = selectedVideoClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedImageClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedAudioClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedSubtitleClipID { selectedClipIDs.insert(pid) }
        if let pid = selectedTextClipID     { selectedClipIDs.insert(pid) }
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

    /// 上次 rebuild 使用的轨道指纹，跳过无变化的重复 rebuild
    private var lastRebuildFingerprint: Int = 0

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

        // 指纹检测：跳过无变化的重复 rebuild（seekTo 除外）
        var hasher = Hasher()
        hasher.combine(vTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.trimStart)\($0.speed)\($0.volume)\($0.scaleX)\($0.scaleY)\($0.offsetX)\($0.offsetY)\($0.cropTop)\($0.cropBottom)\($0.cropLeft)\($0.cropRight)\($0.audioTrackIndex)\($0.inTransition?.type.rawValue ?? "")\($0.inTransition?.duration ?? 0)\($0.colorAdjust.brightness)\($0.colorAdjust.contrast)\($0.colorAdjust.saturation)\($0.colorAdjust.hue)" }.joined())
        hasher.combine(iTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.scaleX)\($0.scaleY)\($0.offsetX)\($0.offsetY)\($0.cropTop)\($0.cropBottom)\($0.cropLeft)\($0.cropRight)\($0.colorAdjust.brightness)\($0.colorAdjust.contrast)\($0.colorAdjust.saturation)\($0.colorAdjust.hue)" }.joined())
        hasher.combine(aTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.trimStart)\($0.speed)\($0.volume)\($0.leftChannel)\($0.rightChannel)\($0.fadeInEnabled)\($0.fadeInDuration)\($0.fadeOutEnabled)\($0.fadeOutDuration)" }.joined())
        hasher.combine(vTracks.map { "\($0.isVisible)\($0.isMuted)" }.joined())
        hasher.combine(iTracks.map { "\($0.isVisible)" }.joined())
        hasher.combine(aTracks.map { "\($0.isVisible)\($0.isMuted)" }.joined())
        let fp = hasher.finalize()
        if seekTo == nil && fp == lastRebuildFingerprint { return }
        lastRebuildFingerprint = fp
        rebuildTask?.cancel()
        rebuildTask = Task {
            let composition = AVMutableComposition()
            var audioParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float, startTime: Double, duration: Double, fadeIn: Double, fadeOut: Double)] = []
            var videoCompTracks: [(track: AVMutableCompositionTrack, clip: VideoClip, startTime: Double, endTime: Double)] = []  // from video clips
            var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []  // from image clips (on top)
            let renderSize = previewRenderSize

            // 视频轨道 — 第一遍：预加载 assetDur，计算平均分配的 half
            // aExtend = A 延伸量（借 A 的 asset 尾部），bAdvance = B 提前量（借 B 的 trimStart 前内容）
            struct TransAdj { let clipAID: UUID; let clipBID: UUID; let half: Double; let type: TransitionType }
            var transAdjusts: [TransAdj] = []
            var clipAssetDurSec: [UUID: Double] = [:]
            for track in vTracks {
                let sortedClips = track.clips.sorted { $0.startTime < $1.startTime }
                for clip in sortedClips {
                    guard let url = clip.url else { continue }
                    let dur = (try? await self.cachedAVAsset(url: url).load(.duration))?.seconds ?? 0
                    clipAssetDurSec[clip.id] = dur
                }
                guard sortedClips.count >= 2 else { continue }
                for i in 1..<sortedClips.count {
                    let cA = sortedClips[i - 1], cB = sortedClips[i]
                    guard let trans = cB.inTransition,
                          abs(cA.endTime - cB.startTime) < 0.05 else { continue }
                    let wantedHalf = trans.duration / 2
                    let half: Double
                    if trans.type == .fadeToBlack {
                        // fadeToBlack 无 overlap，half 直接用 wantedHalf（各自消耗自己的内容）
                        half = wantedHalf
                    } else {
                        // 平均分配：A 延伸 half（受 asset 尾部余量限制），B 提前 half（受 trimStart 限制）
                        // A 消耗的源素材 = duration * speed，剩余可延伸 = assetDur - trimStart - duration*speed
                        let availA = max(0, (clipAssetDurSec[cA.id] ?? 0) - (cA.trimStart + cA.duration * cA.speed))
                        let availB = cB.trimStart
                        half = max(0, min(wantedHalf, min(availA, availB)))
                    }
                    if half > 0.005 {
                        transAdjusts.append(TransAdj(clipAID: cA.id, clipBID: cB.id, half: half, type: trans.type))
                    }
                }
            }

            // 视频轨道 — 第二遍：按 transAdjusts 插入（A 延伸 + B 提前）
            for track in vTracks {
                let sortedClips = track.clips.sorted(by: { $0.startTime < $1.startTime })
                for clip in sortedClips {
                    guard let url = clip.url else { continue }
                    let asset = self.cachedAVAsset(url: url)
                    let assetDurSec = clipAssetDurSec[clip.id] ?? 0
                    let assetDur = CMTime(seconds: assetDurSec, preferredTimescale: 600)
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxSrcDur = assetDur - trimSt
                    // 变速：源素材消耗 = duration * speed，timeline 时长上限 = maxSrcDur / speed
                    let speed = max(0.01, clip.speed)
                    let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / speed, preferredTimescale: 600)
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxTimelineDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let srcContentDurSec = useDur.seconds * speed  // 源素材实际消耗量（秒）

                    // 查询该 clip 作为 A 需要延伸多少，作为 B 需要提前多少
                    let aExtend  = transAdjusts.first(where: { $0.clipAID == clip.id && $0.type != .fadeToBlack })?.half ?? 0
                    let bAdvance = transAdjusts.first(where: { $0.clipBID == clip.id && $0.type != .fadeToBlack })?.half ?? 0

                    // 视频 source range：从 (trimStart - bAdvance) 开始，读 (srcContentDur + bAdvance + aExtend) 秒源素材
                    let actualTrimSt = CMTime(seconds: clip.trimStart - bAdvance, preferredTimescale: 600)
                    let actualSrcDur = CMTime(seconds: srcContentDurSec + bAdvance + aExtend, preferredTimescale: 600)
                    let actualRange  = CMTimeRange(start: actualTrimSt, duration: actualSrcDur)
                    let at           = CMTime(seconds: clip.startTime - bAdvance, preferredTimescale: 600)
                    let targetDurSec = useDur.seconds + bAdvance + aExtend   // timeline 上的目标时长
                    if track.isVisible,
                       let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? vt.insertTimeRange(actualRange, of: vAsset, at: at)
                        // 变速：把 actualSrcDur 缩放到 targetDur
                        if abs(speed - 1.0) > 0.001 {
                            let compRange = CMTimeRange(start: at, duration: actualSrcDur)
                            vt.scaleTimeRange(compRange, toDuration: CMTime(seconds: targetDurSec, preferredTimescale: 600))
                        }
                        videoCompTracks.append((vt, clip,
                                                clip.startTime - bAdvance,         // 实际开始（B 提前）
                                                clip.startTime + useDur.seconds + aExtend)) // 实际结束（A 延伸）
                    }
                    if !track.isMuted {
                        let audioAt = CMTime(seconds: clip.startTime, preferredTimescale: 44100)
                        if abs(speed - 1.0) > 0.001 {
                            // 变速：ffmpeg atempo 预处理，生成已变速的临时音频文件（正常速度 insert）
                            if let speedURL = await self.generateSpeedAudio(
                                inputURL: url, trimStart: clip.trimStart,
                                srcDurSec: srcContentDurSec, speed: speed,
                                audioTrackIndex: clip.audioTrackIndex),
                               let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let sAsset = AVURLAsset(url: speedURL)
                                if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                    let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                    let ins = CMTimeMinimum(sDur, CMTime(seconds: useDur.seconds, preferredTimescale: 44100))
                                    try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: audioAt)
                                    audioParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, ins.seconds, 0, 0))
                                }
                            }
                        } else {
                            // 正常速度
                            let allAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                            let idx = min(clip.audioTrackIndex, max(allAudioTracks.count - 1, 0))
                            if let aAsset = allAudioTracks.isEmpty ? nil : allAudioTracks[idx] as AVAssetTrack?,
                               let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let ats: CMTimeScale = 44100
                                let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                                let useDurC = CMTime(seconds: useDur.seconds, preferredTimescale: ats)
                                try? at2.insertTimeRange(CMTimeRange(start: trimSt, duration: useDurC), of: aAsset, at: audioAt)
                                audioParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, useDur.seconds, 0, 0))
                            }
                        }
                    }
                }
            }

            // 收集转场信息
            var transitionInfos: [TransitionCompInfo] = []
            for adj in transAdjusts {
                guard let entryA = videoCompTracks.first(where: { $0.clip.id == adj.clipAID }),
                      let entryB = videoCompTracks.first(where: { $0.clip.id == adj.clipBID }) else { continue }
                let ts: CMTimeScale = 600
                let cutT         = CMTime(seconds: entryB.clip.startTime, preferredTimescale: ts)
                let overlapStart = CMTime(seconds: entryB.clip.startTime - adj.half, preferredTimescale: ts)
                let overlapEnd   = CMTime(seconds: entryB.clip.startTime + adj.half, preferredTimescale: ts)
                let natSizeA = (try? await entryA.track.load(.naturalSize)) ?? .zero
                let natSizeB = (try? await entryB.track.load(.naturalSize)) ?? .zero
                transitionInfos.append(TransitionCompInfo(
                    trackA: entryA.track, trackB: entryB.track,
                    clipA: entryA.clip, clipB: entryB.clip,
                    type: adj.type,
                    overlapStart: overlapStart, overlapEnd: overlapEnd, cutT: cutT,
                    half: adj.half, renderSize: renderSize,
                    natSizeA: natSizeA, natSizeB: natSizeB
                ))
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
                    let asset = self.cachedAVAsset(url: url)
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
                    let asset    = self.cachedAVAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let aspeed   = max(0.01, clip.speed)
                    let ats: CMTimeScale = 44100
                    let trimSt   = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                    let maxSrcDur = assetDur - trimSt
                    let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / aspeed, preferredTimescale: ats)
                    let useDur   = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: ats), maxTimelineDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let srcDurSec = useDur.seconds * aspeed
                    let at        = CMTime(seconds: clip.startTime, preferredTimescale: ats)

                    if abs(aspeed - 1.0) > 0.001 {
                        // 变速：ffmpeg atempo 预处理
                        if let speedURL = await self.generateSpeedAudio(
                            inputURL: url, trimStart: clip.trimStart,
                            srcDurSec: srcDurSec, speed: aspeed, audioTrackIndex: 0),
                           let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
                            let sAsset = AVURLAsset(url: speedURL)
                            if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                let ins  = CMTimeMinimum(sDur, useDur)
                                try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: at)
                                let effDur  = ins.seconds
                                let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  effDur) : 0
                                let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, effDur - fadeIn)) : 0
                                audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, effDur, fadeIn, fadeOut))
                            }
                        }
                    } else {
                        // 正常速度
                        guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                        if let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
                            try? at2.insertTimeRange(CMTimeRange(start: trimSt, duration: useDur), of: aAsset, at: at)
                            let effDur  = useDur.seconds
                            let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  effDur) : 0
                            let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, effDur - fadeIn)) : 0
                            audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, effDur, fadeIn, fadeOut))
                        }
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
                if param.fadeIn > 0 || param.fadeOut > 0 {
                    // volume ramp 必须按时间递增顺序添加：淡入 → 中间 → 淡出，否则 AVFoundation 抛异常崩溃
                    // 1) 淡入：0 → volume
                    if param.fadeIn > 0 {
                        p.setVolumeRamp(fromStartVolume: 0, toEndVolume: param.volume,
                                        timeRange: CMTimeRange(start: clipStart,
                                                               duration: CMTime(seconds: param.fadeIn, preferredTimescale: ts)))
                    }
                    // 2) 中间段：保持基准音量（淡入结束 → 淡出开始）
                    let midStartSec = param.startTime + param.fadeIn
                    let midDurSec   = clipDur - param.fadeIn - param.fadeOut
                    if midDurSec > 0.001 {
                        p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: param.volume,
                                        timeRange: CMTimeRange(start: CMTime(seconds: midStartSec, preferredTimescale: ts),
                                                               duration: CMTime(seconds: midDurSec, preferredTimescale: ts)))
                    }
                    // 3) 淡出：volume → 0
                    if param.fadeOut > 0 {
                        let fadeOutStart = CMTime(seconds: param.startTime + clipDur - param.fadeOut, preferredTimescale: ts)
                        p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: 0,
                                        timeRange: CMTimeRange(start: fadeOutStart,
                                                               duration: CMTime(seconds: param.fadeOut, preferredTimescale: ts)))
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
                // 多 track 时必须指定 Invalid，否则 AVFoundation 从某个 active track 取帧时序
                // 转场区间 A/B 切换会导致帧时序混乱，播放抖动
                vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

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
                // 所有转场的 overlapStart / overlapEnd 加入 boundaries
                for ti in transitionInfos {
                    cmBoundaries.append(ti.overlapStart)
                    cmBoundaries.append(ti.overlapEnd)
                    if ti.type == .fadeToBlack { cmBoundaries.append(ti.cutT) }
                }
                // 去重 + 排序
                let sortedCM = Array(Set(cmBoundaries.map { $0.value })).sorted().map { CMTime(value: $0, timescale: ts) }

                // 用自定义 compositor 替代 layerInstructions，同时支持色调调节 + 转场渐变
                vc.customVideoCompositorClass = ColorCompositor.self
                // 每次重建前清空旧数据（避免旧 key 残留）
                ColorCompositor.clearStore()
                var colorInstructions: [AVVideoCompositionInstruction] = []
                for i in 0..<(sortedCM.count - 1) {
                    let segStartCM = sortedCM[i]
                    let segEndCM   = sortedCM[i + 1]
                    let segDur = segEndCM - segStartCM
                    guard segDur.seconds > 0.001 else { continue }

                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: segStartCM, duration: segDur)

                    var entries:      [CompositorTrackEntry] = []
                    var activeTracks: [AVCompositionTrack]   = []
                    var hasTween = false

                    // 视频 track（底层）
                    for (idx, entry) in videoCompTracks.enumerated() {
                        let clipStart = videoClipCMRanges[idx].start
                        let clipEnd   = videoClipCMRanges[idx].end
                        guard segStartCM >= clipStart && segStartCM < clipEnd else { continue }
                        // 只需要检查 track 有效，不需要 natSize（compositor 用实际 buffer 算 fit）
                        guard (try? await entry.track.load(.naturalSize)) != nil else { continue }
                        let clip = entry.clip
                        var te = CompositorTrackEntry(
                            trackID:     entry.track.trackID,
                            userScaleX:  CGFloat(clip.scaleX),
                            userScaleY:  CGFloat(clip.scaleY),
                            userOffsetX: CGFloat(clip.offsetX),
                            userOffsetY: CGFloat(clip.offsetY),
                            cropTop:     CGFloat(clip.cropTop),
                            cropBottom:  CGFloat(clip.cropBottom),
                            cropLeft:    CGFloat(clip.cropLeft),
                            cropRight:   CGFloat(clip.cropRight),
                            colorAdjust: clip.colorAdjust,
                            opacityRamp: nil,
                            pushRamp:    nil)
                        // 转场渐变
                        for trans in transitionInfos {
                            let isA = entry.track === trans.trackA
                            let isB = entry.track === trans.trackB
                            guard isA || isB else { continue }
                            let effStart: CMTime
                            let effEnd: CMTime
                            if trans.type == .fadeToBlack {
                                effStart = isA ? trans.overlapStart : trans.cutT
                                effEnd   = isA ? trans.cutT : trans.overlapEnd
                            } else {
                                effStart = trans.overlapStart
                                effEnd   = trans.overlapEnd
                            }
                            guard segStartCM >= effStart && segStartCM < effEnd else { continue }
                            let fOp: Float = isA ? 1.0 : 0.0
                            let tOp: Float = isA ? 0.0 : 1.0
                            switch trans.type {
                            case .dissolve, .fadeToBlack:
                                te.opacityRamp = (from: fOp, to: tOp,
                                                  start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .pushLeft, .pushRight, .pushUp, .pushDown:
                                // dx/dy 以 renderSize 为单位，compositor 运行时在 fit 坐标系叠加偏移
                                let (dx, dy): (CGFloat, CGFloat) = {
                                    switch trans.type {
                                    case .pushLeft:  return (-renderSize.width,  0)
                                    case .pushRight: return ( renderSize.width,  0)
                                    case .pushUp:    return (0,  renderSize.height)
                                    default:         return (0, -renderSize.height)
                                    }
                                }()
                                te.pushRamp = (dx: dx, dy: dy, isA: isA,
                                               start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .zoom:
                                // 前片(A)放大淡出，后片(B)从放大缩回 + 淡入
                                te.opacityRamp = (from: fOp, to: tOp,
                                                  start: effStart.seconds, end: effEnd.seconds)
                                te.zoomRamp = (from: isA ? 1.0 : 1.4, to: isA ? 1.4 : 1.0,
                                               start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .slideLeft, .slideRight, .slideUp, .slideDown:
                                // 后片(B)从边缘滑入覆盖，前片(A)保持不动
                                if isB {
                                    let (dx, dy): (CGFloat, CGFloat) = {
                                        switch trans.type {
                                        case .slideLeft:  return (-renderSize.width,  0)
                                        case .slideRight: return ( renderSize.width,  0)
                                        case .slideUp:    return (0,  renderSize.height)
                                        default:          return (0, -renderSize.height)
                                        }
                                    }()
                                    te.pushRamp = (dx: dx, dy: dy, isA: false,
                                                   start: effStart.seconds, end: effEnd.seconds)
                                }
                                hasTween = true
                            }
                            break
                        }
                        entries.append(te)
                        activeTracks.append(entry.track)
                    }

                    // 图片 track（顶层）
                    for (idx, entry) in imageCompTracks.enumerated() {
                        let clipStartCM = imageClipCMRanges[idx].start
                        let clipEndCM   = imageClipCMRanges[idx].end
                        guard segStartCM >= clipStartCM && segStartCM < clipEndCM else { continue }
                        let iclip = entry.clip
                        let te = CompositorTrackEntry(
                            trackID:     entry.track.trackID,
                            userScaleX:  CGFloat(iclip.scaleX),
                            userScaleY:  CGFloat(iclip.scaleY),
                            userOffsetX: CGFloat(iclip.offsetX),
                            userOffsetY: CGFloat(iclip.offsetY),
                            cropTop:     CGFloat(iclip.cropTop),
                            cropBottom:  CGFloat(iclip.cropBottom),
                            cropLeft:    CGFloat(iclip.cropLeft),
                            cropRight:   CGFloat(iclip.cropRight),
                            colorAdjust: iclip.colorAdjust,
                            opacityRamp: nil,
                            pushRamp:    nil)
                        entries.append(te)
                        activeTracks.append(entry.track)
                    }

                    // 注册 track IDs：通过 layerInstructions 告知框架需要哪些 source frames
                    instr.layerInstructions = activeTracks.map {
                        AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
                    }
                    instr.enablePostProcessing = hasTween

                    // 向 ColorCompositor 静态字典注册数据（不用 associated object，避免 copy 丢失）
                    let colorData = ColorCompositionData()
                    colorData.entries    = entries
                    colorData.renderSize = renderSize
                    // key = segStartCM 转为 timescale=600 后的整数值
                    let key = CMTimeConvertScale(segStartCM, timescale: 600, method: .default).value
                    ColorCompositor.setData(colorData, forStartValue: key)

                    colorInstructions.append(instr)
                }

                if !colorInstructions.isEmpty {
                    vc.instructions = colorInstructions
                    videoComposition = vc
                }
            }

            let visualEnd = max(vEnd, iEnd)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lastVideoEndTime = visualEnd
                self.duration = max(endTime, 0.01)
                self.pendingSeekTime = restoreTime
                if composition.tracks.isEmpty && endTime < 0.01 {
                    self.playerItem = nil
                } else {
                    let item = AVPlayerItem(asset: composition)
                    // varispeed：变速时音调随之改变（与剪映普通变速一致）
                    // 不能用默认的 .spectral（保持音调），否则 scaleTimeRange 变速的音频会部分/全部静音
                    item.audioTimePitchAlgorithm = .varispeed
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

    // MARK: - Transition ramp helper

    /// 为处于转场效果区间内的 layerInstruction 设置 opacity/transform ramp。
    /// 必须在 setTransform 之后调用（ramp 会覆盖静态 transform）。
    static func applyTransitionRamp(
        li: AVMutableVideoCompositionLayerInstruction,
        track: AVMutableCompositionTrack,
        clip: VideoClip,
        transform t: CGAffineTransform,
        natSize: CGSize,
        renderSize: CGSize,
        segStart: CMTime,
        transitions: [TransitionCompInfo]
    ) {
        let ts: CMTimeScale = 600
        for trans in transitions {
            let isA = track === trans.trackA
            let isB = track === trans.trackB
            guard isA || isB else { continue }

            // 确定该 track 在此时间段的效果区间
            // dissolve/push：A 和 B 都在 [overlapStart, overlapEnd]（平均分配，同时重叠）
            // fadeToBlack：A 在 [overlapStart, cutT]，B 在 [cutT, overlapEnd]
            let segStart_forA: CMTime
            let segEnd_forA:   CMTime
            let segStart_forB: CMTime
            let segEnd_forB:   CMTime
            if trans.type == .fadeToBlack {
                segStart_forA = trans.overlapStart;  segEnd_forA = trans.cutT
                segStart_forB = trans.cutT;          segEnd_forB = trans.overlapEnd
            } else {
                segStart_forA = trans.overlapStart;  segEnd_forA = trans.overlapEnd
                segStart_forB = trans.overlapStart;  segEnd_forB = trans.overlapEnd
            }

            let effectStart = isA ? segStart_forA : segStart_forB
            let effectEnd   = isA ? segEnd_forA   : segEnd_forB
            guard segStart >= effectStart && segStart < effectEnd else { continue }

            let fadeRange = CMTimeRange(start: effectStart, duration: effectEnd - effectStart)
            let fromOpacity: Float = isA ? 1 : 0
            let toOpacity:   Float = isA ? 0 : 1

            // Push 偏移：A 推出（→ pushDX），B 从反方向推入（← pushDX）
            let pushDX: CGFloat
            let pushDY: CGFloat
            switch trans.type {
            case .pushLeft:  pushDX = -renderSize.width;  pushDY = 0
            case .pushRight: pushDX =  renderSize.width;  pushDY = 0
            case .pushUp:    pushDX = 0; pushDY =  renderSize.height
            case .pushDown:  pushDX = 0; pushDY = -renderSize.height
            default:         pushDX = 0; pushDY = 0
            }

            switch trans.type {
            case .dissolve, .fadeToBlack:
                li.setOpacityRamp(fromStartOpacity: fromOpacity, toEndOpacity: toOpacity,
                                  timeRange: fadeRange)
            case .pushLeft, .pushRight, .pushUp, .pushDown:
                // concatenating 在 renderSize 输出坐标系追加偏移，不受 natSize→renderSize 的 scale 影响
                // translatedBy 是在 natSize 输入坐标系偏移，4K 视频 scale=0.5 会导致偏移量减半
                let offsetFwd = CGAffineTransform(translationX:  pushDX, y:  pushDY)
                let offsetRev = CGAffineTransform(translationX: -pushDX, y: -pushDY)
                let fromT = isA ? t : t.concatenating(offsetRev)
                let toT   = isA ? t.concatenating(offsetFwd) : t
                li.setTransformRamp(fromStart: fromT, toEnd: toT, timeRange: fadeRange)
            case .zoom:
                // 前片(A)放大淡出，后片(B)从放大缩回 + 淡入；以 render 中心为锚缩放
                let cx = renderSize.width / 2, cy = renderSize.height / 2
                func zoomAffine(_ s: CGFloat) -> CGAffineTransform {
                    CGAffineTransform(translationX: cx, y: cy)
                        .scaledBy(x: s, y: s)
                        .translatedBy(x: -cx, y: -cy)
                }
                let fromS: CGFloat = isA ? 1.0 : 1.4
                let toS:   CGFloat = isA ? 1.4 : 1.0
                li.setOpacityRamp(fromStartOpacity: fromOpacity, toEndOpacity: toOpacity,
                                  timeRange: fadeRange)
                li.setTransformRamp(fromStart: t.concatenating(zoomAffine(fromS)),
                                    toEnd:     t.concatenating(zoomAffine(toS)),
                                    timeRange: fadeRange)
            case .slideLeft, .slideRight, .slideUp, .slideDown:
                // 后片(B)从边缘滑入到原位；前片(A)保持不动（不设 ramp）
                if isB {
                    let (sdx, sdy): (CGFloat, CGFloat) = {
                        switch trans.type {
                        case .slideLeft:  return (-renderSize.width,  0)
                        case .slideRight: return ( renderSize.width,  0)
                        case .slideUp:    return (0,  renderSize.height)
                        default:          return (0, -renderSize.height)
                        }
                    }()
                    let offsetRev = CGAffineTransform(translationX: -sdx, y: -sdy)
                    li.setTransformRamp(fromStart: t.concatenating(offsetRev),
                                        toEnd: t, timeRange: fadeRange)
                }
            }
            break
        }
    }

    /// Select a clip for preview and seek to its start so the user sees it.
    func loadClipForPreview(_ clip: VideoClip) {
        rebuildTimelinePreview(seekTo: clip.startTime)
    }

    // MARK: - Import

    /// 支持的素材扩展名
    private static let supportedExtensions: Set<String> = [
        "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv",
        "mp3","wav","aac","m4a","flac","aiff","aif","caf","au",
        "ogg","wma","opus","ac3","ape","dts",
        "srt","ass","vtt",
        "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic",
        "avif","heif","jfif","svg","dng","cr2","nef","arw","raf","orf"
    ]

    /// AVFoundation 原生支持的视频容器，无需转码
    private static let nativeVideoExtensions: Set<String> = ["mp4","mov","m4v"]

    /// 需要 FFmpeg 转码的视频格式
    private static let needsTranscodeExtensions: Set<String> = [
        "avi","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv"
    ]

    /// 支持智能 remux 的容器（编码兼容时直接 copy，不兼容才转码）
    private static let smartRemuxExtensions: Set<String> = ["mkv", "ts", "mts", "m2ts"]

    /// 需要 FFmpeg 转码的音频格式（转为 m4a）
    private static let needsTranscodeAudioExtensions: Set<String> = [
        "ogg","wma","opus","ac3","ape","dts"
    ]

    private static func assetType(for ext: String) -> AssetType? {
        switch ext {
        case "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv": return .video
        case "mp3","wav","aac","m4a","flac","aiff","aif","caf","au",
             "ogg","wma","opus","ac3","ape","dts": return .audio
        case "srt","ass","vtt": return .subtitle
        case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic",
             "avif","heif","jfif","svg","dng","cr2","nef","arw","raf","orf": return .image
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

        // 需要转码的音频格式，先转为 M4A 再导入
        if type == .audio && Self.needsTranscodeAudioExtensions.contains(ext) {
            let fileName = url.deletingPathExtension().lastPathComponent
            let shortHash = String(url.path.hashValue, radix: 16, uppercase: false).suffix(8)
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BlackCatTranscode", isDirectory: true)
                .appendingPathComponent("\(fileName)_\(shortHash).m4a")
            if mediaAssets.contains(where: { $0.url == outputURL }) {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
                return
            }
            transcodeAudioAndImport(url: url, outputURL: outputURL, displayName: url.lastPathComponent)
            return
        }

        // 需要转码或智能 remux 的视频格式
        if type == .video && (Self.needsTranscodeExtensions.contains(ext) || Self.smartRemuxExtensions.contains(ext)) {
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
    private func importFileDirectly(url: URL, type: AssetType, displayName: String? = nil) {
        // 兜底去重：防止任何路径绕过前置检查
        guard !mediaAssets.contains(where: { $0.url == url }) else { return }
        let fSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        var asset = MediaAsset(url: url, name: displayName ?? url.lastPathComponent, type: type)
        asset.importDate = Date()
        asset.fileSize = fSize
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

    /// 取消所有转码
    func cancelTranscoding() {
        for task in activeTasks {
            task.process?.terminate()
            task.process = nil
            try? FileManager.default.removeItem(at: task.outputURL)
        }
        for task in pendingTasks {
            try? FileManager.default.removeItem(at: task.outputURL)
        }
        activeTasks.removeAll()
        pendingTasks.removeAll()
        isTranscoding = false
        transcodingProgress = 0
        transcodingFileName = ""
    }

    /// 取消单个转码任务
    func cancelTranscodeTask(_ taskID: UUID) {
        if let task = activeTasks.first(where: { $0.id == taskID }) {
            task.isCancelled = true
            task.process?.terminate()
            task.process = nil
            try? FileManager.default.removeItem(at: task.outputURL)
            showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: task.displayName, subtitle: "已停止", autoCountdown: false)
        }
        activeTasks.removeAll { $0.id == taskID }
        pendingTasks.removeAll { $0.id == taskID }
        drainPendingTasks()
        if activeTasks.isEmpty && pendingTasks.isEmpty {
            isTranscoding = false
            transcodingProgress = 0
            transcodingFileName = ""
        }
    }

    private func enqueueTranscodeTask(_ task: TranscodeTask) {
        isTranscoding = true
        let runningCount = activeTasks.filter { $0.isRunning }.count
        if runningCount < Self.maxConcurrentTranscodes {
            activeTasks.append(task)
            task.isRunning = true
            if task.type == .audio {
                runAudioTranscode(task)
            } else {
                runVideoTranscode(task)
            }
        } else {
            pendingTasks.append(task)
            activeTasks.append(task)
        }
    }

    private func finishTranscodeTask(_ taskID: UUID) {
        guard let task = activeTasks.first(where: { $0.id == taskID }) else {
            drainPendingTasks()
            if activeTasks.isEmpty && pendingTasks.isEmpty {
                isTranscoding = false; transcodingProgress = 0; transcodingFileName = ""
            }
            return
        }
        let name = task.displayName
        let wasCancelled = task.isCancelled
        activeTasks.removeAll { $0.id == taskID }
        drainPendingTasks()
        if !wasCancelled {
            showSuccessToast(icon: "checkmark", title: name, subtitle: "转码完成")
        }
        if activeTasks.isEmpty && pendingTasks.isEmpty {
            isTranscoding = false
            transcodingProgress = 0
            transcodingFileName = ""
        }
    }

    private func drainPendingTasks() {
        while activeTasks.filter({ $0.isRunning }).count < Self.maxConcurrentTranscodes,
              !pendingTasks.isEmpty {
            let task = pendingTasks.removeFirst()
            guard activeTasks.contains(where: { $0.id == task.id }) else { continue }
            task.isRunning = true
            if task.type == .audio {
                runAudioTranscode(task)
            } else {
                runVideoTranscode(task)
            }
        }
    }

    private func runAudioTranscode(_ task: TranscodeTask) {
        guard let ffmpeg = Self.findFFmpeg() else {
            showImportToast("未找到 FFmpeg，无法转码 \(task.displayName)")
            finishTranscodeTask(task.id)
            return
        }
        let outputDir = task.outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        Task.detached { [weak self] in
            let ok = Self.runFFmpegSync(ffmpeg: ffmpeg, arguments: [
                "-i", task.inputURL.path,
                "-c:a", "aac", "-b:a", "192k",
                "-y", task.outputURL.path
            ])
            await MainActor.run {
                guard !task.isCancelled else { return }
                if ok {
                    self?.importFileDirectly(url: task.outputURL, type: .audio, displayName: task.displayName)
                } else {
                    self?.showImportToast("「\(task.displayName)」转码失败")
                }
                self?.finishTranscodeTask(task.id)
            }
        }
    }

    private func runVideoTranscode(_ task: TranscodeTask) {
        guard let ffmpeg = Self.findFFmpeg() else {
            showImportToast("未找到 FFmpeg，无法转码 \(task.displayName)")
            finishTranscodeTask(task.id)
            return
        }

        Task.detached { [weak self] in
            // 用 ffprobe 检测编解码器兼容性
            let ffmpegDir = ffmpeg.deletingLastPathComponent().path
            let codecs = Self.probeCodecs(ffmpegDir: ffmpegDir, inputPath: task.inputURL.path)
            let videoCompatible = ["h264", "hevc", "mpeg4"].contains(codecs.video)
            let audioCompatible = ["aac", "alac", "mp3", ""].contains(codecs.audio)

            let totalDuration = Self.probeVideoDuration(ffmpegDir: ffmpegDir, inputPath: task.inputURL.path)

            // 构建 ffmpeg 参数：智能选择 copy 或转码
            var args: [String] = []
            if videoCompatible && audioCompatible {
                // 全兼容：纯封装转换（最快）
                args = ["-i", task.inputURL.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "copy", "-c:a", "copy",
                        "-movflags", "+faststart", "-y", task.outputURL.path]
            } else if videoCompatible {
                // 视频兼容、音频不兼容：copy视频，转码音��
                args = ["-i", task.inputURL.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                        "-movflags", "+faststart", "-y", task.outputURL.path]
            } else {
                // 视频不兼容：完整转码
                args = ["-hwaccel", "videotoolbox",
                        "-i", task.inputURL.path,
                        "-c:v", "h264_videotoolbox", "-b:v", "8000k",
                        "-profile:v", "high", "-level:v", "4.2",
                        "-c:a", audioCompatible ? "copy" : "aac"]
                if !audioCompatible { args += ["-b:a", "192k"] }
                args += ["-movflags", "+faststart", "-y", task.outputURL.path]
            }

            let process = Process()
            await MainActor.run { task.process = process }
            process.executableURL = ffmpeg
            process.arguments = args

            let pipe = Pipe()
            process.standardError = pipe

            do { try process.run() } catch {
                await MainActor.run {
                    self?.showImportToast("转码失败")
                    self?.finishTranscodeTask(task.id)
                }
                return
            }

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
                            Task { @MainActor [weak self] in
                                task.progress = prog
                                self?.objectWillChange.send()
                            }
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
                task.process = nil
                guard !task.isCancelled else { return }
                if process.terminationStatus == 0 {
                    self?.importFileDirectly(url: task.outputURL, type: .video)
                } else {
                    self?.showImportToast("转码失败")
                }
                self?.finishTranscodeTask(task.id)
            }
        }
    }

    /// 将不兼容的音频格式转为 M4A（AAC）再导入
    private func transcodeAudioAndImport(url: URL, outputURL: URL, displayName: String? = nil) {
        let name = displayName ?? url.lastPathComponent
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !mediaAssets.contains(where: { $0.url == outputURL }) {
                importFileDirectly(url: outputURL, type: .audio, displayName: name)
            } else {
                showImportToast("「\(name)」已在素材库中，已跳过")
            }
            return
        }
        enqueueTranscodeTask(TranscodeTask(inputURL: url, outputURL: outputURL, type: .audio, displayName: name))
    }

    /// 将非原生视频格式转为 MP4
    private func transcodeAndImport(url: URL) {
        let fileName = url.deletingPathExtension().lastPathComponent
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlackCatTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let shortHash = String(url.path.hashValue, radix: 16, uppercase: false).suffix(8)
        let outputURL = outputDir.appendingPathComponent("\(fileName)_\(shortHash).mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !mediaAssets.contains(where: { $0.url == outputURL }) {
                importFileDirectly(url: outputURL, type: .video)
            } else {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
            }
            return
        }
        enqueueTranscodeTask(TranscodeTask(inputURL: url, outputURL: outputURL, type: .video, displayName: url.lastPathComponent))
    }

    /// 同步执行 FFmpeg 命令，返回是否成功
    static func runFFmpegSync(ffmpeg: URL, arguments: [String]) -> Bool {
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
    // MARK: - 变速音频预处理（ffmpeg atempo）

    /// 构建 atempo filter 字符串（atempo 范围 0.5~2.0，超出则串联）
    static func buildAtempoFilter(speed: Double) -> String {
        var filters: [String] = []
        var r = speed
        while r > 2.0 + 1e-6 { filters.append("atempo=2.0"); r /= 2.0 }
        while r < 0.5 - 1e-6 { filters.append("atempo=0.5"); r /= 0.5 }
        if abs(r - 1.0) > 1e-6 { filters.append(String(format: "atempo=%.6f", r)) }
        if filters.isEmpty { filters.append("atempo=1.0") }
        return filters.joined(separator: ",")
    }

    /// 用 ffmpeg 生成变速音频临时文件，带缓存。
    /// - Returns: 临时 .m4a URL（正常速度，duration ≈ srcDurSec / speed）
    func generateSpeedAudio(inputURL: URL, trimStart: Double, srcDurSec: Double,
                             speed: Double, audioTrackIndex: Int) async -> URL? {
        let key = "\(inputURL.path)|\(trimStart)|\(srcDurSec)|\(speed)|\(audioTrackIndex)"
        if let cached = audioSpeedCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let ffmpeg = Self.findFFmpeg() else { return nil }
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc_spd_\(UUID().uuidString).m4a")
        let filterStr = Self.buildAtempoFilter(speed: speed)
        var args = ["-y"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", srcDurSec), "-i", inputURL.path]
        args += ["-vn"]
        if audioTrackIndex > 0 { args += ["-map", "0:a:\(audioTrackIndex)"] }
        args += ["-af", filterStr, "-c:a", "aac", "-ar", "44100", "-ac", "2", tmpURL.path]
        let ok = await Task.detached(priority: .userInitiated) {
            Self.runFFmpegSync(ffmpeg: ffmpeg, arguments: args)
        }.value
        if ok {
            audioSpeedCache[key] = tmpURL
            return tmpURL
        }
        return nil
    }

    static func findFFmpeg() -> URL? {
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
    /// 用 ffprobe 检测视频/音频编解码器名称
    private static func probeCodecs(ffmpegDir: String, inputPath: String) -> (video: String, audio: String) {
        let probePath = ffmpegDir + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probePath) else { return ("", "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probePath)
        proc.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let vCodec = (try? pipe.fileHandleForReading.readDataToEndOfFile())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: probePath)
        proc2.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe2 = Pipe()
        proc2.standardOutput = pipe2
        proc2.standardError = Pipe()
        try? proc2.run()
        proc2.waitUntilExit()
        let aCodec = (try? pipe2.fileHandleForReading.readDataToEndOfFile())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (vCodec, aCodec)
    }

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
            let trackIdx: Int
            if let emptyIdx = audioTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                audioTracks.append(Track(label: "音频"))
                trackIdx = audioTracks.count - 1
            }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[trackIdx].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: 0, endTime: dur))
                    self.duration = max(self.duration, dur)
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
                if subtitleTracks[idx].subtitleStyle == nil {
                    subtitleTracks[idx].subtitleStyle = newSubtitleStyle()
                }
            } else {
                var newTrack = Track<SubtitleClip>(clips: clips, label: "字幕")
                newTrack.subtitleStyle = newSubtitleStyle()
                subtitleTracks.append(newTrack)
                syncOverlayOrder()
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
                syncOverlayOrder()
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
            let audioTrackIdx: Int
            if let emptyIdx = audioTracks.firstIndex(where: { $0.clips.isEmpty }) {
                audioTrackIdx = emptyIdx
            } else {
                audioTracks.append(Track(label: "音频"))
                audioTrackIdx = audioTracks.count - 1
            }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[audioTrackIdx].clips.append(
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
                syncOverlayOrder()
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
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()
    }

    private func pushUndoSavingAssets() {
        var snap = currentSnapshot()
        snap.mediaAssets = mediaAssets
        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
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

    private func currentSnapshot(includeAssets: Bool = false) -> ProjectSnapshot {
        ProjectSnapshot(videoTracks: videoTracks, audioTracks: audioTracks,
                        imageTracks: imageTracks,
                        subtitleTracks: subtitleTracks,
                        textTracks: textTracks,
                        overlayTrackOrder: overlayTrackOrder,
                        subtitleBottomMargin: subtitleBottomMargin,
                        subtitleLineSpacing: subtitleLineSpacing,
                        duration: duration,
                        mediaAssets: includeAssets ? mediaAssets : nil)
    }
    private func applySnapshot(_ s: ProjectSnapshot) {
        videoTracks    = s.videoTracks
        audioTracks    = s.audioTracks
        imageTracks    = s.imageTracks
        subtitleTracks = s.subtitleTracks
        textTracks     = s.textTracks
        overlayTrackOrder = s.overlayTrackOrder
        subtitleBottomMargin = s.subtitleBottomMargin
        subtitleLineSpacing  = s.subtitleLineSpacing
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
                            // 分割点在时间轴上的偏移 * speed = 源素材消耗量
                            trimStart: c.trimStart + (t - c.startTime) * c.speed,
                            overrideResolution: c.overrideResolution,
                            overrideFPS: c.overrideFPS,
                            overrideBitrate: c.overrideBitrate)
                        newClip.volume = c.volume
                        newClip.speed = c.speed   // 继承速率
                        newClip.videoWidth = c.videoWidth; newClip.videoHeight = c.videoHeight
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
                        var newClip = AudioClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime) * c.speed,
                            volume: c.volume, leftChannel: c.leftChannel, rightChannel: c.rightChannel,
                            sampleRate: c.sampleRate, format: c.format)
                        newClip.speed = c.speed
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
                        var newClip = SubtitleClip(text: c.text, startTime: t, endTime: c.endTime)
                        newClip.assetID = c.assetID
                        subtitleTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        }

        if changed {
            undoStack.append(snap)
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
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
        if let id = selectedTextClipID     { ids.insert(id) }
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
        for i in textTracks.indices {
            let before = textTracks[i].clips.count
            textTracks[i].clips.removeAll { ids.contains($0.id) }
            if textTracks[i].clips.count != before { changed = true }
        }

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedTextClipID     = nil
        selectedClipIDs.removeAll()

        if changed {
            undoStack.append(snap)
            if undoStack.count > 30 { undoStack.removeFirst() }
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
        collectToClipboard(isCut: false)
    }

    func cutSelected() {
        collectToClipboard(isCut: true)
    }

    private func collectToClipboard(isCut: Bool) {
        var items: [ClipboardItem] = []
        var srcIDs: Set<UUID> = []

        var allIDs = selectedClipIDs
        if let id = selectedVideoClipID    { allIDs.insert(id) }
        if let id = selectedImageClipID    { allIDs.insert(id) }
        if let id = selectedAudioClipID    { allIDs.insert(id) }
        if let id = selectedSubtitleClipID { allIDs.insert(id) }
        if let id = selectedTextClipID     { allIDs.insert(id) }

        for id in allIDs {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.video(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.image(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.audio(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.subtitle(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in textTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.text(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
        }

        guard !items.isEmpty else { return }
        clipboard = items
        clipboardIsCut = isCut
        clipboardSourceIDs = isCut ? srcIDs : []
    }

    /// 粘贴剪贴板内容到当前播放头位置
    func pasteAtPlayhead() {
        guard !clipboard.isEmpty else { return }
        let snap = currentSnapshot()
        let t = currentTime

        // 如果是剪切，先删除原始片段
        if clipboardIsCut, !clipboardSourceIDs.isEmpty {
            let srcIDs = clipboardSourceIDs
            for i in videoTracks.indices    { videoTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in imageTracks.indices    { imageTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in audioTracks.indices    { audioTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll { srcIDs.contains($0.id) } }
            for i in textTracks.indices     { textTracks[i].clips.removeAll     { srcIDs.contains($0.id) } }
            clipboardIsCut = false
            clipboardSourceIDs = []
        }

        func startOf(_ item: ClipboardItem) -> Double {
            switch item {
            case .video(let c, _): return c.startTime
            case .image(let c, _): return c.startTime
            case .audio(let c, _): return c.startTime
            case .subtitle(let c, _): return c.startTime
            case .text(let c, _): return c.startTime
            }
        }
        let earliest = clipboard.map { startOf($0) }.min() ?? 0

        selectedClipIDs.removeAll()
        selectedVideoClipID = nil
        selectedImageClipID = nil
        selectedAudioClipID = nil
        selectedSubtitleClipID = nil
        selectedTextClipID = nil
        for item in clipboard {
            let offset = startOf(item) - earliest

            switch item {
            case .video(let clip, let trackIdx):
                var newClip = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                        startTime: t + offset, endTime: t + offset + clip.duration, trimStart: clip.trimStart)
                newClip.volume = clip.volume
                newClip.videoWidth = clip.videoWidth; newClip.videoHeight = clip.videoHeight
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
                    selectedClipIDs.insert(newClip.id)
                }

            case .image(let clip, let trackIdx):
                var newClip = ImageClip(assetID: clip.assetID, name: clip.name, imageURL: clip.imageURL,
                                         videoURL: clip.videoURL, startTime: t + offset, endTime: t + offset + clip.duration,
                                         imageWidth: clip.imageWidth, imageHeight: clip.imageHeight)
                newClip.scaleX = clip.scaleX; newClip.scaleY = clip.scaleY
                newClip.lockAspect = clip.lockAspect
                newClip.offsetX = clip.offsetX; newClip.offsetY = clip.offsetY
                newClip.cropTop = clip.cropTop; newClip.cropBottom = clip.cropBottom
                newClip.cropLeft = clip.cropLeft; newClip.cropRight = clip.cropRight
                let idx = imageTracks.indices.contains(trackIdx) ? trackIdx : 0
                if imageTracks.indices.contains(idx) {
                    imageTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }

            case .audio(let clip, let trackIdx):
                var newClip = AudioClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                        startTime: t + offset, endTime: t + offset + clip.duration, trimStart: clip.trimStart)
                newClip.volume = clip.volume
                newClip.leftChannel = clip.leftChannel
                newClip.rightChannel = clip.rightChannel
                newClip.sampleRate = clip.sampleRate
                newClip.format = clip.format
                let idx = audioTracks.indices.contains(trackIdx) ? trackIdx : 0
                if audioTracks.indices.contains(idx) {
                    audioTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }

            case .subtitle(let clip, let trackIdx):
                let st = t + offset
                var newClip = SubtitleClip(text: clip.text, startTime: st, endTime: st + clip.duration)
                newClip.assetID = clip.assetID
                var idx = subtitleTracks.indices.contains(trackIdx) ? trackIdx : 0
                if subtitleTracks.indices.contains(idx) {
                    let hasOverlap = subtitleTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        var placed = false
                        for dti in subtitleTracks.indices where dti != idx {
                            let noOverlap = !subtitleTracks[dti].clips.contains {
                                $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                            }
                            if noOverlap { idx = dti; placed = true; break }
                        }
                        if !placed {
                            var newTrack = Track<SubtitleClip>(label: "字幕")
                            newTrack.subtitleStyle = newSubtitleStyle()
                            subtitleTracks.append(newTrack)
                            syncOverlayOrder()
                            idx = subtitleTracks.count - 1
                        }
                    }
                    subtitleTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }

            case .text(let clip, let trackIdx):
                let st = t + offset
                var newClip = TextClip(text: clip.text, startTime: st, endTime: st + clip.duration)
                newClip.fontName = clip.fontName; newClip.fontSize = clip.fontSize
                newClip.bold = clip.bold; newClip.italic = clip.italic
                newClip.textColor = clip.textColor; newClip.strokeColor = clip.strokeColor
                newClip.strokeWidth = clip.strokeWidth; newClip.bgColor = clip.bgColor
                newClip.bgOpacity = clip.bgOpacity; newClip.alignment = clip.alignment
                newClip.rotation = clip.rotation; newClip.opacity = clip.opacity
                newClip.posX = clip.posX; newClip.posY = clip.posY
                newClip.animation = clip.animation
                let idx = textTracks.indices.contains(trackIdx) ? trackIdx : 0
                if textTracks.indices.contains(idx) {
                    textTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }
            }
        }

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// Move the selected clip so its start aligns with the current playhead.
    func alignSelectedToPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false
        if let id = selectedVideoClipID {
            for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = videoTracks[ti].clips[ci].duration
                    videoTracks[ti].clips[ci].startTime = t
                    videoTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
        } else if let id = selectedAudioClipID {
            for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = audioTracks[ti].clips[ci].duration
                    audioTracks[ti].clips[ci].startTime = t
                    audioTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
        } else if let id = selectedImageClipID {
            for ti in imageTracks.indices {
                if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = imageTracks[ti].clips[ci].duration
                    imageTracks[ti].clips[ci].startTime = t
                    imageTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
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
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
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
            var newTrack = Track<SubtitleClip>(label: "字幕")
            newTrack.subtitleStyle = newSubtitleStyle()
            subtitleTracks.append(newTrack)
            syncOverlayOrder()
            trackIdx = subtitleTracks.count - 1
        }

        let start = currentTime
        let end   = min(currentTime + 2.0, max(duration, currentTime + 2.0))
        let clip  = SubtitleClip(text: "新字幕", startTime: start, endTime: end)
        subtitleTracks[trackIdx].clips.append(clip)
        subtitleTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        selectedSubtitleClipID = clip.id

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }

    // MARK: - 文字/标题图层

    /// 在播放头插入文字图层（选中文字则在其轨道，否则用最后一条文字轨道，无则新建）
    func addTextAtPlayhead() {
        let snap = currentSnapshot()
        let trackIdx: Int
        if let tid = selectedTextClipID,
           let i = textTracks.firstIndex(where: { $0.clips.contains { $0.id == tid } }) {
            trackIdx = i
        } else if !textTracks.isEmpty {
            trackIdx = textTracks.count - 1
        } else {
            textTracks.append(Track<TextClip>(label: "文字"))
            syncOverlayOrder()
            trackIdx = textTracks.count - 1
        }
        let start = currentTime
        let end   = currentTime + 3.0
        let clip  = TextClip(text: "标题文字", startTime: start, endTime: end)
        textTracks[trackIdx].clips.append(clip)
        textTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        // 选中新建的文字，清其他选中
        selectedTextClipID = clip.id
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        isSaved = false
    }

    /// 更新指定文字片段（Inspector 编辑用）
    func updateTextClip(id: UUID, _ mutate: (inout TextClip) -> Void) {
        for ti in textTracks.indices {
            if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&textTracks[ti].clips[ci])
                isSaved = false
                return
            }
        }
    }

    /// 删除指定文字片段
    func deleteTextClip(id: UUID) {
        let snap = currentSnapshot()
        for ti in textTracks.indices {
            if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                textTracks[ti].clips.remove(at: ci)
                if selectedTextClipID == id { selectedTextClipID = nil }
                undoStack.append(snap)
                if undoStack.count > 30 { undoStack.removeFirst() }
                redoStack.removeAll()
                undoCount = undoStack.count; redoCount = 0
                isSaved = false
                return
            }
        }
    }

    // MARK: - 文字样式模板

    func saveTextTemplate(from clipID: UUID, name: String) {
        guard let clip = textTracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { return }
        let template = TextTemplate.from(clip, name: name)
        textTemplates.append(template)
        isSaved = false
        scheduleAutoSave()
    }

    func saveTextTemplateFromClip(_ clipID: UUID) {
        let idx = textTemplates.count + 1
        saveTextTemplate(from: clipID, name: "模板 \(idx)")
    }

    func applyTextTemplate(_ template: TextTemplate, to clipID: UUID) {
        pushUndo()
        updateTextClip(id: clipID) { clip in
            template.apply(to: &clip)
        }
    }

    func deleteTextTemplate(id: UUID) {
        textTemplates.removeAll { $0.id == id }
        isSaved = false
        scheduleAutoSave()
    }

    // MARK: - 自动语音识别（Whisper）

    func downloadModelAndTranscribe() {
        guard !isTranscribing else { return }
        let model = selectedWhisperModel
        transcribeState = .downloading(0)
        transcribeTask = Task {
            do {
                try await WhisperTranscriber.downloadModel(model) { p in
                    DispatchQueue.main.async { self.transcribeState = .downloading(p) }
                }
                await MainActor.run {
                    self.transcribeState = .idle
                    self.autoTranscribeSelectedClip()
                }
            } catch is CancellationError {
                await MainActor.run { self.transcribeState = .idle }
            } catch {
                await MainActor.run {
                    self.transcribeState = .failed("模型下载失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 对选中的视频/音频片段做语音识别并生成字幕轨道。
    /// 未选中片段时，识别时间轴上第一个视频片段。
    func autoTranscribeSelectedClip() {
        guard !isTranscribing else { return }

        // 解析识别目标：选中视频 > 选中音频 > 第一个视频片段
        var url: URL?
        var trimStart = 0.0, srcDur = 0.0, offset = 0.0, speed = 1.0
        if let vid = selectedVideoClipID,
           let c = videoTracks.flatMap(\.clips).first(where: { $0.id == vid }) {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        } else if let aid = selectedAudioClipID,
                  let c = audioTracks.flatMap(\.clips).first(where: { $0.id == aid }) {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        } else if let c = videoTracks.flatMap(\.clips).sorted(by: { $0.startTime < $1.startTime }).first {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        }

        guard let mediaURL = url else {
            transcribeState = .failed("请先选择一个视频或音频片段")
            return
        }
        if !WhisperTranscriber.modelReady {
            showWhisperModelPicker = true
            return
        }

        guard WhisperTranscriber.whisperReady else {
            transcribeState = .failed("语音识别引擎未就绪（whisper-cli 缺失）")
            return
        }

        transcribeState = .running(0)

        // 识别用自动检测原声，再按需翻译到「翻译目标语言」
        let displayName = translationTargetLang
        let isTargetSimplified = (displayName == "中文（简体）")
        let targetBase = WhisperTranscriber.langCode(forDisplayName: displayName)  // zh/en/it...

        let capSpeed = speed, capOffset = offset
        transcribeTask = Task {
            do {
                try Task.checkCancellation()
                await MainActor.run { self.transcribeState = .running(0.1) }
                let segs = try await WhisperTranscriber.transcribe(
                    mediaURL: mediaURL, trimStart: trimStart,
                    duration: srcDur, language: "auto", prompt: nil)
                try Task.checkCancellation()

                await MainActor.run { self.transcribeState = .running(0.7) }
                let sample = segs.prefix(12).map(\.text).joined(separator: " ")
                let recog = NLLanguageRecognizer()
                recog.processString(sample)
                let detected = recog.dominantLanguage?.rawValue ?? ""
                let detectedBase = String(detected.split(separator: "-").first ?? "")
                let sameLang = (detectedBase == targetBase)
                    || (detectedBase.hasPrefix("zh") && targetBase == "zh")

                var finalSegs: [(start: Double, end: Double, text: String)] = []
                if sameLang {
                    for (i, s) in segs.enumerated() {
                        try Task.checkCancellation()
                        let text = isTargetSimplified ? OpenCC.toSimplified(s.text) : s.text
                        finalSegs.append((s.start, s.end, text))
                        let p = 0.7 + 0.25 * Double(i + 1) / Double(max(segs.count, 1))
                        await MainActor.run { self.transcribeState = .running(p) }
                    }
                } else {
                    for (i, s) in segs.enumerated() {
                        try Task.checkCancellation()
                        let t = await Translator.translate(s.text, to: displayName)
                        finalSegs.append((s.start, s.end, t))
                        let p = 0.7 + 0.25 * Double(i + 1) / Double(max(segs.count, 1))
                        await MainActor.run { self.transcribeState = .running(p) }
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self.pushUndo()
                    var track = Track<SubtitleClip>(label: "识别字幕")
                    track.subtitleStyle = self.newSubtitleStyle()
                    for s in finalSegs {
                        let st = capOffset + s.start / capSpeed
                        let en = capOffset + s.end   / capSpeed
                        track.clips.append(SubtitleClip(text: s.text, startTime: st, endTime: en))
                    }
                    track.clips.sort { $0.startTime < $1.startTime }
                    self.subtitleTracks.append(track)
                    self.syncOverlayOrder()
                    self.transcribeState = .idle
                    self.transcribeTask = nil
                    self.showSuccessToast(icon: "checkmark", title: "语音识别", subtitle: "完成，生成 \(finalSegs.count) 条字幕")
                }
            } catch is CancellationError {
                await MainActor.run {
                    WhisperTranscriber.killCurrentProcess()
                    self.transcribeState = .idle
                    self.transcribeTask = nil
                }
            } catch {
                await MainActor.run {
                    if self.transcribeState != .idle {
                        self.transcribeState = .failed(error.localizedDescription)
                    }
                    self.transcribeTask = nil
                }
            }
        }
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
