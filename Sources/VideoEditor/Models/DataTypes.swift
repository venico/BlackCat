import SwiftUI
import AVFoundation
import Accelerate
import MediaToolbox

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
