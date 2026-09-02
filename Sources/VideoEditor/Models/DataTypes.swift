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
    @Published var refreshSeekRequest: Int = 0
    /// 播放/暂停请求。每个窗口一份 clock，所以天然按窗口隔离——
    /// 原来空格走 NotificationCenter 的裸广播（不带目标窗口），
    /// 多开两个窗口按一次空格，两边的预览一起播/停
    @Published var togglePlaybackRequest: Int = 0
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
    /// 与素材库左侧标签页共用的 SVG 图标名
    var svgIcon: String {
        switch self { case .video: return "video"; case .audio: return "audio"; case .subtitle: return "subtitle"; case .image: return "image" }
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
    // 思源黑体简体。**用族名不用 PostScript 名**：粗体是靠选同族的 Bold 成员实现的，
    // 写死 SourceHanSansSC-Regular 的话字重就切不动了
    var fontName: String  = "Source Han Sans SC"
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
    var mergeLineBreaks: Bool = true

    /// 纯英文字幕的默认字号。英文字形比汉字扁而宽，中文那档 48 落到英文上会顶满整行。
    /// **只要出现一个汉字就按中文算** —— 中英混排的双语字幕仍旧走 48
    static func defaultFontSize(forSubtitles texts: [String]) -> CGFloat {
        let hasCJK = texts.contains { text in
            text.unicodeScalars.contains { u in
                (0x4E00...0x9FFF).contains(u.value)    // CJK 基本区
                || (0x3400...0x4DBF).contains(u.value) // 扩展 A
                || (0x3040...0x30FF).contains(u.value) // 假名
                || (0xAC00...0xD7AF).contains(u.value) // 谚文
            }
        }
        return hasCJK ? 48 : 32
    }    // 合并换行：去掉字幕中的手动换行，按宽度自动重排

    /// 字幕层的排版尺寸（文字尺寸 + 内边距），**预览和导出共用这一份**。
    ///
    /// 预览侧原来是另一套：`.background(GeometryReader)` 实测 SwiftUI 的 Label 高度，
    /// 再 `DispatchQueue.main.async` 写回 `@State`，堆叠时读这份实测值。
    /// 结果是**快速拖动播放头时字幕间距忽大忽小** —— 字幕一条接一条切换，
    /// 每条文字长短不同、高度一直在变，而异步写回跟不上帧率，
    /// 那几帧就用了上一条字幕的高度来排版。导出没这个毛病，因为它一直是同步算的。
    ///
    /// 统一到这里之后：没有异步状态、不存在竞态，预览和导出的行距也必然一致。
    ///
    /// - Parameters:
    ///   - scale: 预览传 `预览区宽 / previewRenderSize.width`，导出传 `renderSize.width / previewRenderSize.width`
    ///   - renderWidth: 对应坐标系下的画面宽度
    func layerSize(text: String, scale: CGFloat, renderWidth: CGFloat) -> CGSize {
        let padH: CGFloat = 10 * scale, padV: CGFloat = 3 * scale
        let scaledSize = fontSize * scale
        var ctFont = CTFontCreateWithName(fontName as CFString, scaledSize, nil)
        if bold, let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil,
                                                             .boldTrait, .boldTrait) {
            ctFont = bf
        }
        let attrStr = NSAttributedString(
            string: text,
            attributes: [.init(kCTFontAttributeName as String): ctFont])
        let setter = CTFramesetterCreateWithAttributedString(attrStr)
        let maxW = renderWidth * widthPercent / 100
        let constraint = CGSize(width: maxW - padH * 2, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, constraint, nil)
        return CGSize(width: ceil(size.width) + padH * 2,
                      height: ceil(size.height) + padV * 2)
    }

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
    var markers: [Marker]? = nil
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
    var mirrorH: Bool = false
    var mirrorV: Bool = false
    var rotation: Int = 0
    var reversed: Bool = false
    // 色调调节
    var colorAdjust: ColorAdjust = .identity
    // 转场：从前一个 clip 到本 clip 的转场效果（nil = 无转场）
    var inTransition: Transition? = nil
    var markers: [Marker]? = nil
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
    var markers: [Marker]? = nil
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
    var mirrorH: Bool = false
    var mirrorV: Bool = false
    /// 旋转角度（度）。属性区的「旋转90°」按钮走整档，预览里拖旋转手柄是任意角度。
    /// 老 .bcj 存的是整数，JSON 里 90 能直接解成 90.0，不影响打开
    var rotation: Double = 0
    // 色调调节
    var colorAdjust: ColorAdjust = .identity
    // 描边。用可选类型是为了兼容旧 .bcj —— 自动合成的 Codable 遇到缺失的非可选字段会直接解码失败
    var strokeColorHex: String? = nil
    var strokeWidth: Double? = nil
    var strokeSoftness: Double? = nil
    var markers: [Marker]? = nil
    /// 画面圆角（px）。同样用可选类型，理由见上面那条注释
    var cornerRadius: Double? = nil
    /// 不透明度 0~1。同上，可选是为了兼容老 .bcj
    var opacity: Double? = nil

    /// 圆角半径，nil = 不切
    var corner: Double { cornerRadius ?? 0 }
    /// 不透明度，没设过就是全不透明
    var alpha: Double { opacity ?? 1 }
    var strokeColor: Color { Color(hex: strokeColorHex ?? "#FFFFFF") }
    /// 描边宽度（px），0 = 不描边
    var strokeW: Double { strokeWidth ?? 0 }
    /// 描边柔和度，0 = 硬边
    var strokeSoft: Double { strokeSoftness ?? 0 }
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
    /// 描边柔和度 0~1。0 = 硬边（默认），1 = 完全糊开。跟图片描边同一个语义
    var strokeSoftness: Double = 0
    var bgColor: Color    = .black
    var bgOpacity: Double = 0          // 背景不透明度，0=无背景框
    var alignment: String = "center"   // left/center/right
    var rotation: Double  = 0          // 旋转角度(度)
    var opacity: Double   = 1
    var animation: TextAnimation = .none
    var markers: [Marker]? = nil
    // 裁剪：0~1 比例，从各边往里裁掉多少（跟图片片段同一个语义）。
    // 只露半个字这种做法就靠它
    var cropTop: Double    = 0
    var cropBottom: Double = 0
    var cropLeft: Double   = 0
    var cropRight: Double  = 0
    // 文本框尺寸。nil = 跟着文字自适应；
    // 双击进编辑态后拖四边横条写的是这两个值，字号不变
    var boxWidth: Double?  = nil
    var boxHeight: Double? = nil
    var mirrorH: Bool = false
    var mirrorV: Bool = false
    /// 范围框缩放是否锁比例（面板上的开关，不影响渲染）
    var lockBoxAspect: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, text, startTime, endTime, posX, posY
        case fontName, fontSize, bold, italic
        case textColorHex, strokeColorHex, strokeWidth, strokeSoftness, bgColorHex, bgOpacity
        case alignment, rotation, opacity, animation
        case markers
        case cropTop, cropBottom, cropLeft, cropRight
        case boxWidth, boxHeight
        case mirrorH, mirrorV, lockBoxAspect
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
        try c.encode(strokeSoftness, forKey: .strokeSoftness)
        try c.encode(bgColor.toHex(), forKey: .bgColorHex)
        try c.encode(bgOpacity, forKey: .bgOpacity)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(animation, forKey: .animation)
        try c.encodeIfPresent(markers, forKey: .markers)
        try c.encode(cropTop, forKey: .cropTop)
        try c.encode(cropBottom, forKey: .cropBottom)
        try c.encode(cropLeft, forKey: .cropLeft)
        try c.encode(cropRight, forKey: .cropRight)
        try c.encodeIfPresent(boxWidth, forKey: .boxWidth)
        try c.encodeIfPresent(boxHeight, forKey: .boxHeight)
        try c.encode(mirrorH, forKey: .mirrorH)
        try c.encode(mirrorV, forKey: .mirrorV)
        try c.encode(lockBoxAspect, forKey: .lockBoxAspect)
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
        strokeSoftness = (try? c.decode(Double.self, forKey: .strokeSoftness)) ?? 0
        bgColor     = Color(hex: (try? c.decode(String.self, forKey: .bgColorHex)) ?? "#000000")
        bgOpacity   = (try? c.decode(Double.self, forKey: .bgOpacity)) ?? 0
        alignment   = (try? c.decode(String.self, forKey: .alignment)) ?? "center"
        rotation    = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        opacity     = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        animation   = (try? c.decode(TextAnimation.self, forKey: .animation)) ?? .none
        markers = try? c.decode([Marker].self, forKey: .markers)
        cropTop    = (try? c.decode(Double.self, forKey: .cropTop)) ?? 0
        cropBottom = (try? c.decode(Double.self, forKey: .cropBottom)) ?? 0
        cropLeft   = (try? c.decode(Double.self, forKey: .cropLeft)) ?? 0
        cropRight  = (try? c.decode(Double.self, forKey: .cropRight)) ?? 0
        boxWidth   = try? c.decode(Double.self, forKey: .boxWidth)
        boxHeight  = try? c.decode(Double.self, forKey: .boxHeight)
        mirrorH    = (try? c.decode(Bool.self, forKey: .mirrorH)) ?? false
        mirrorV    = (try? c.decode(Bool.self, forKey: .mirrorV)) ?? false
        lockBoxAspect = (try? c.decode(Bool.self, forKey: .lockBoxAspect)) ?? true
    }
    init(text: String = "标题文字", startTime: Double, endTime: Double) {
        self.text = text; self.startTime = startTime; self.endTime = endTime
    }
}

// MARK: - Shape Clip (图形图层)

enum ShapeType: String, Codable, CaseIterable {
    case rectangle, ellipse, triangle, parallelogram, trapezoid, line, arrow, pen

    var label: String {
        switch self {
        case .rectangle:     return "矩形"
        case .ellipse:       return "圆形"
        case .triangle:      return "三角形"
        case .parallelogram: return "平行四边形"
        case .trapezoid:     return "梯形"
        case .line:          return "线段"
        case .arrow:         return "箭头"
        case .pen:           return "钢笔"
        }
    }

    /// 是否闭合路径（可填充）。线段/箭头为开放路径，仅描边。钢笔由 penClosed 决定。
    var isClosed: Bool {
        switch self {
        case .line, .arrow: return false
        case .pen:          return true
        default:            return true
        }
    }
}

// MARK: - 钢笔路径锚点

struct PenPoint: Identifiable, Equatable, Codable {
    var id = UUID()
    var x: Double       // 归一化坐标 0~1（相对于 clip 的 width×height 边界框）
    var y: Double
    var ctrlInDX: Double = 0    // 入控制柄偏移（归一化，相对于锚点）
    var ctrlInDY: Double = 0
    var ctrlOutDX: Double = 0   // 出控制柄偏移
    var ctrlOutDY: Double = 0
    var smooth: Bool = true     // 平滑模式：拖动一个控制柄另一个联动
}

/// 线段/箭头两端端点样式
enum LineCapStyle: String, Codable, CaseIterable {
    case none, arrow, round, square
    var label: String {
        switch self {
        case .none:   return "无端点"
        case .arrow:  return "箭头"
        case .round:  return "圆头"
        case .square: return "方头"
        }
    }
}

struct ShapeClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var type: ShapeType = .rectangle
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    // 位置：中心点画面比例 (0~1)，(0.5,0.5)=正中
    var posX: Double = 0.5
    var posY: Double = 0.5
    // 大小：previewRenderSize 坐标系下的基准像素（导出时按比例缩放，与 TextClip.fontSize 一致）
    var width: Double  = 300
    var height: Double = 200
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var lockAspect: Bool = true
    var rotation: Double = 0            // 旋转角度(度)
    var mirrorH: Bool = false
    var mirrorV: Bool = false
    var opacity: Double  = 1
    // 填充
    var fillEnabled: Bool = true
    var fillColor: Color  = .white
    var fillOpacity: Double = 1
    // 描边
    var strokeEnabled: Bool = false
    var strokeColor: Color  = .white
    var strokeWidth: Double = 4
    var strokeOpacity: Double = 1
    var strokeDashed: Bool = false
    // 线段/箭头端点样式（起点/终点）
    var capStart: LineCapStyle = .none
    var capEnd: LineCapStyle = .none
    // 圆角（仅矩形有效）
    var cornerRadius: Double = 0
    // 阴影
    var shadowEnabled: Bool = false
    var shadowColor: Color  = .black
    var shadowOpacity: Double = 0.5
    var shadowRadius: Double = 8
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 4
    // 钢笔路径（仅 .pen 类型）
    var penPoints: [PenPoint]? = nil
    var penClosed: Bool = false
    var markers: [Marker]? = nil
    // 裁剪：0~1 比例，从各边往里裁掉多少（跟图片、文字同一个语义）。
    // 四边横条拖的是它；不等比缩放走属性区的 scaleX/scaleY
    var cropTop: Double    = 0
    var cropBottom: Double = 0
    var cropLeft: Double   = 0
    var cropRight: Double  = 0

    /// 是否闭合路径（pen 由 penClosed 决定，其余由 ShapeType 决定）
    var effectiveIsClosed: Bool { type == .pen ? penClosed : type.isClosed }

    enum CodingKeys: String, CodingKey {
        case id, type, startTime, endTime, posX, posY
        case width, height, scaleX, scaleY, lockAspect, rotation, opacity
        case fillEnabled, fillColorHex, fillOpacity
        case strokeEnabled, strokeColorHex, strokeWidth, strokeOpacity, strokeDashed
        case capStart, capEnd
        case cornerRadius
        case shadowEnabled, shadowColorHex, shadowOpacity, shadowRadius, shadowOffsetX, shadowOffsetY
        case penPoints, penClosed
        case markers
        case cropTop, cropBottom, cropLeft, cropRight
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(posX, forKey: .posX)
        try c.encode(posY, forKey: .posY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(scaleX, forKey: .scaleX)
        try c.encode(scaleY, forKey: .scaleY)
        try c.encode(lockAspect, forKey: .lockAspect)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(fillEnabled, forKey: .fillEnabled)
        try c.encode(fillColor.toHex(), forKey: .fillColorHex)
        try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(strokeEnabled, forKey: .strokeEnabled)
        try c.encode(strokeColor.toHex(), forKey: .strokeColorHex)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(strokeOpacity, forKey: .strokeOpacity)
        try c.encode(strokeDashed, forKey: .strokeDashed)
        try c.encode(capStart, forKey: .capStart)
        try c.encode(capEnd, forKey: .capEnd)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(shadowEnabled, forKey: .shadowEnabled)
        try c.encode(shadowColor.toHex(), forKey: .shadowColorHex)
        try c.encode(shadowOpacity, forKey: .shadowOpacity)
        try c.encode(shadowRadius, forKey: .shadowRadius)
        try c.encode(shadowOffsetX, forKey: .shadowOffsetX)
        try c.encode(shadowOffsetY, forKey: .shadowOffsetY)
        try c.encodeIfPresent(penPoints, forKey: .penPoints)
        try c.encode(penClosed, forKey: .penClosed)
        try c.encodeIfPresent(markers, forKey: .markers)
        try c.encode(cropTop, forKey: .cropTop)
        try c.encode(cropBottom, forKey: .cropBottom)
        try c.encode(cropLeft, forKey: .cropLeft)
        try c.encode(cropRight, forKey: .cropRight)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        type      = (try? c.decode(ShapeType.self, forKey: .type)) ?? .rectangle
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime   = try c.decode(Double.self, forKey: .endTime)
        posX      = (try? c.decode(Double.self, forKey: .posX)) ?? 0.5
        posY      = (try? c.decode(Double.self, forKey: .posY)) ?? 0.5
        width     = (try? c.decode(Double.self, forKey: .width)) ?? 300
        height    = (try? c.decode(Double.self, forKey: .height)) ?? 200
        scaleX    = (try? c.decode(Double.self, forKey: .scaleX)) ?? 1
        scaleY    = (try? c.decode(Double.self, forKey: .scaleY)) ?? 1
        lockAspect = (try? c.decode(Bool.self, forKey: .lockAspect)) ?? true
        rotation  = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        opacity   = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        fillEnabled = (try? c.decode(Bool.self, forKey: .fillEnabled)) ?? true
        fillColor = Color(hex: (try? c.decode(String.self, forKey: .fillColorHex)) ?? "#F5B942")
        fillOpacity = (try? c.decode(Double.self, forKey: .fillOpacity)) ?? 1
        strokeEnabled = (try? c.decode(Bool.self, forKey: .strokeEnabled)) ?? false
        strokeColor = Color(hex: (try? c.decode(String.self, forKey: .strokeColorHex)) ?? "#FFFFFF")
        strokeWidth = (try? c.decode(Double.self, forKey: .strokeWidth)) ?? 4
        strokeOpacity = (try? c.decode(Double.self, forKey: .strokeOpacity)) ?? 1
        strokeDashed = (try? c.decode(Bool.self, forKey: .strokeDashed)) ?? false
        capStart = (try? c.decode(LineCapStyle.self, forKey: .capStart)) ?? .none
        capEnd = (try? c.decode(LineCapStyle.self, forKey: .capEnd)) ?? .none
        cornerRadius = (try? c.decode(Double.self, forKey: .cornerRadius)) ?? 0
        shadowEnabled = (try? c.decode(Bool.self, forKey: .shadowEnabled)) ?? false
        shadowColor = Color(hex: (try? c.decode(String.self, forKey: .shadowColorHex)) ?? "#000000")
        shadowOpacity = (try? c.decode(Double.self, forKey: .shadowOpacity)) ?? 0.5
        shadowRadius = (try? c.decode(Double.self, forKey: .shadowRadius)) ?? 8
        shadowOffsetX = (try? c.decode(Double.self, forKey: .shadowOffsetX)) ?? 0
        shadowOffsetY = (try? c.decode(Double.self, forKey: .shadowOffsetY)) ?? 4
        penPoints = try? c.decode([PenPoint].self, forKey: .penPoints)
        penClosed = (try? c.decode(Bool.self, forKey: .penClosed)) ?? false
        cropTop    = (try? c.decode(Double.self, forKey: .cropTop)) ?? 0
        cropBottom = (try? c.decode(Double.self, forKey: .cropBottom)) ?? 0
        cropLeft   = (try? c.decode(Double.self, forKey: .cropLeft)) ?? 0
        cropRight  = (try? c.decode(Double.self, forKey: .cropRight)) ?? 0
        markers = try? c.decode([Marker].self, forKey: .markers)
    }
    init(type: ShapeType, startTime: Double, endTime: Double) {
        self.type = type; self.startTime = startTime; self.endTime = endTime
        if type == .pen {
            fillEnabled = false
            strokeEnabled = true
            strokeColor = .white
            strokeWidth = 3
            width = 100; height = 100
        } else if !type.isClosed {
            fillEnabled = false
            strokeEnabled = true
            height = (type == .arrow) ? 48 : 8
            if type == .arrow { capEnd = .arrow }
        }
    }
}

// MARK: - Marker (片段标记，time 为片段内偏移)

struct Marker: Identifiable, Equatable, Codable {
    var id = UUID()
    var time: Double
    var title: String = ""
    var color: MarkerColor = .cyan

    enum MarkerColor: String, Codable, CaseIterable {
        case cyan, pink, orange, green, purple
        var swiftUIColor: Color {
            switch self {
            case .cyan:   return Color(hex: "#4DD8E0")
            case .pink:   return Color(hex: "#E85D75")
            case .orange: return Color(hex: "#E8A54B")
            case .green:  return Color(hex: "#A4C639")
            case .purple: return Color(hex: "#B07DE8")
            }
        }
    }
}

// MARK: - Filter Clip（滤镜片段）

/// 内置滤镜。都用 Core Image 现成的，不引第三方库 ——
/// 系统自带两百多个 CIFilter，而且导出和预览本来就跑在 CIImage 这条链上
enum FilterKind: String, Codable, CaseIterable {
    // 彩色系
    case vibrance   // 鲜艳
    case chrome     // 明艳
    case instant    // 拍立得
    case process    // 冲印
    case transfer   // 胶片
    case fade       // 褪色
    case sepia      // 怀旧
    case cool       // 冷调
    // 黑白系（对比从强到弱）
    case noir       // 黑白
    case mono       // 灰白
    case tonal      // 灰调
    // 特殊
    case posterize  // 色阶
    case comic      // 漫画
    case vignette   // 暗角
    case lut        // 外部 .cube 文件

    var label: String {
        switch self {
        case .vibrance: return "鲜艳"
        case .chrome: return "明艳"
        case .instant: return "拍立得"
        case .process: return "冲印"
        case .transfer: return "胶片"
        case .fade: return "褪色"
        case .sepia: return "怀旧"
        case .cool: return "冷调"
        case .noir: return "黑白"
        case .mono: return "灰白"
        case .tonal: return "灰调"
        case .posterize: return "色阶"
        case .comic: return "漫画"
        case .vignette: return "暗角"
        case .lut: return "LUT"
        }
    }

    /// 列表里显示的那些（LUT 是导入进来的，不进内置列表）
    static var builtins: [FilterKind] { allCases.filter { $0 != .lut } }
}

/// 时间轴上的一段滤镜。**覆盖这段时间内的整幅画面** ——
/// 跟文字、图形那种「叠一个图层上去」不一样，它是在所有内容合成完之后才套上去的
struct FilterClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var kind: FilterKind = .noir
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    /// 强度 0~1。靠原图和滤镜结果按比例混合实现，所有滤镜统一这一个参数
    var intensity: Double = 1
    /// LUT 文件路径（仅 kind == .lut）
    var lutPath: String? = nil
    /// 显示名。LUT 用文件名，内置的用 kind 的名字
    var name: String {
        if kind == .lut, let p = lutPath {
            return (p as NSString).lastPathComponent
        }
        return kind.label
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, startTime, endTime, intensity, lutPath
    }
    init(kind: FilterKind = .noir, startTime: Double, endTime: Double) {
        self.kind = kind; self.startTime = startTime; self.endTime = endTime
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decode(FilterKind.self, forKey: .kind)) ?? .noir
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
        lutPath = try? c.decode(String.self, forKey: .lutPath)
    }
}

/// 调节片段。跟滤镜一样是独立轨道上的一段，只作用于排在它下面的图层。
///
/// 参数直接复用 `ColorAdjust` —— 片段属性区里那组「调节」和这里是同一套东西，
/// 只是入口不同：那边挂在某一个片段上，这里覆盖一段时间内的所有画面
struct AdjustClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    var adjust: ColorAdjust = .identity
    /// 显示名。默认「调节」，可以改
    var customName: String? = nil
    var name: String { customName ?? "调节" }

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, adjust, customName
    }
    init(startTime: Double, endTime: Double) {
        self.startTime = startTime; self.endTime = endTime
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        adjust = (try? c.decode(ColorAdjust.self, forKey: .adjust)) ?? .identity
        customName = try? c.decode(String.self, forKey: .customName)
    }
}

struct Track<Clip: Identifiable & Equatable & Codable>: Identifiable, Equatable, Codable {
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
    /// 画面比例，"原始" = 跟随素材比例
    var aspectRatio: String      = "原始"
    static let resolutions = ["原始", "4K", "1080p", "720p", "480p"]
    static let aspectRatios = ["原始", "16:9", "1.85:1", "2:1", "2.35:1", "4:3", "1:1", "3:4", "9:16", "1:2", "自定义"]
    static let customAspect = "自定义"
    static let fpsOptions  = [24, 25, 30, 60]

    /// "16:9" → 1.777…；"原始" 返回 nil
    static func parseAspect(_ s: String) -> CGFloat? {
        let p = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        return CGFloat(p[0] / p[1])
    }

    /// 分辨率标称值对应的**短边**像素。1080p 竖屏 = 1080 宽，横屏 = 1080 高。
    /// 兼容旧格式 "1080p  1920×1080"
    static func shortSide(for resolution: String, fallback: CGSize) -> CGFloat {
        if resolution.hasPrefix("4K")   { return 2160 }
        if resolution.hasPrefix("1080") { return 1080 }
        if resolution.hasPrefix("720")  { return 720 }
        if resolution.hasPrefix("480")  { return 480 }
        return min(fallback.width, fallback.height)   // 原始
    }

    /// 分辨率 + 比例换算出的实际输出尺寸。
    /// 分辨率定的是短边，比例决定另一边往哪个方向长 —— 1080p + 1:2 = 1080×2160。
    /// 比例为「自定义」时直接用 custom 指定的尺寸
    static func outputSize(resolution: String, aspectRatio: String, fallback: CGSize,
                           custom: CGSize? = nil) -> CGSize {
        if aspectRatio == customAspect, let c = custom, c.width >= 2, c.height >= 2 {
            return CGSize(width: max(2, (c.width / 2).rounded() * 2),
                          height: max(2, (c.height / 2).rounded() * 2))
        }
        let short = shortSide(for: resolution, fallback: fallback)
        guard short > 0 else { return fallback }

        // 比例「原始」= 跟随素材
        let target: CGFloat
        if let t = parseAspect(aspectRatio) {
            target = t
        } else {
            guard fallback.width > 0, fallback.height > 0 else { return fallback }
            target = fallback.width / fallback.height
        }

        let w: CGFloat, h: CGFloat
        if target >= 1 {
            h = short; w = short * target        // 横向或正方：短边是高
        } else {
            w = short; h = short / target        // 竖向：短边是宽
        }
        // 编码器要求偶数边长
        return CGSize(width: max(2, (w / 2).rounded() * 2),
                      height: max(2, (h / 2).rounded() * 2))
    }
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

/// 项目封面的**设计稿**（v5.3.0）。
///
/// 存的是「怎么做出这张封面」而不是最终图片：底图是哪个素材的哪一帧、
/// 上面叠了什么文字和图形。这样下次打开还能接着改。
/// 渲染好的成品另存成 PNG（`renderedPath`），欢迎页直接读它，不用每次重画
struct ProjectCover: Codable, Equatable {
    /// 底图来源：素材库里那个素材的路径，或者用户上传的图片
    var sourcePath: String?
    /// 底图是视频时取第几秒那一帧
    var frameTime: Double = 0
    /// 叠在封面上的文字。复用时间轴那套 `TextClip` —— 属性面板照搬得动，
    /// 只是时间相关的字段（开始/持续）在封面里没有意义，界面上不显示
    var texts: [TextClip] = []
    /// 叠在封面上的图形，同上
    var shapes: [ShapeClip] = []
    /// 底图的变换。字段跟外面图片片段的属性区对齐 ——
    /// 偏移是相对画面尺寸的比例（-1~1），缩放 1 = 铺满
    var baseOffsetX: Double = 0
    var baseOffsetY: Double = 0
    var baseScale: Double = 1
    /// 垂直方向的缩放。nil = 跟 `baseScale` 等比
    var baseScaleY: Double? = nil
    /// 缩放是否锁比例（只是面板上的开关，不影响渲染）
    var baseLockAspect: Bool = true
    var baseOpacity: Double = 1
    var baseRotation: Double = 0
    var baseMirrorH: Bool = false
    var baseMirrorV: Bool = false

    /// 裁剪（各边裁掉的比例 0~1），字段跟图片片段一致
    var cropTop: Double = 0
    var cropBottom: Double = 0
    var cropLeft: Double = 0
    var cropRight: Double = 0

    /// 色调，复用片段那套 `ColorAdjust`
    var colorAdjust: ColorAdjust = .identity

    /// 描边，跟图片片段一样：颜色存十六进制、宽度像素、柔和度 0~1
    /// 画面圆角（px），跟图片片段同一个语义
    var cornerRadius: Double = 0
    var strokeColorHex: String? = nil
    var strokeWidth: Double? = nil
    var strokeSoftness: Double? = nil

    /// 渲染好的成品图。相对项目文件所在目录，换台机器也找得到
    var renderedPath: String?

    var isEmpty: Bool { sourcePath == nil && texts.isEmpty && shapes.isEmpty }

    init() {}

    // MARK: - 解码容错

    /// **手写解码，每个字段都用 decodeIfPresent**。
    ///
    /// Swift 自动合成的 Codable 对「属性有默认值但 JSON 里缺这个键」并不宽容 ——
    /// 缺一个键就抛错，整个 `ProjectDocument` 跟着解不出来，表现是
    /// 「文件格式不正确，项目打不开」。加了裁剪/色调/描边那几个字段之后，
    /// 之前存的封面全少这几个键，老项目当场打不开（实测踩到）。
    /// `CanvasNode` 早有同款教训 —— **以后往这个结构加字段，照着加一行 decodeIfPresent**
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        frameTime = try c.decodeIfPresent(Double.self, forKey: .frameTime) ?? 0
        texts = try c.decodeIfPresent([TextClip].self, forKey: .texts) ?? []
        shapes = try c.decodeIfPresent([ShapeClip].self, forKey: .shapes) ?? []
        baseOffsetX = try c.decodeIfPresent(Double.self, forKey: .baseOffsetX) ?? 0
        baseOffsetY = try c.decodeIfPresent(Double.self, forKey: .baseOffsetY) ?? 0
        baseScale = try c.decodeIfPresent(Double.self, forKey: .baseScale) ?? 1
        baseScaleY = try c.decodeIfPresent(Double.self, forKey: .baseScaleY)
        baseLockAspect = try c.decodeIfPresent(Bool.self, forKey: .baseLockAspect) ?? true
        baseOpacity = try c.decodeIfPresent(Double.self, forKey: .baseOpacity) ?? 1
        baseRotation = try c.decodeIfPresent(Double.self, forKey: .baseRotation) ?? 0
        baseMirrorH = try c.decodeIfPresent(Bool.self, forKey: .baseMirrorH) ?? false
        baseMirrorV = try c.decodeIfPresent(Bool.self, forKey: .baseMirrorV) ?? false
        cropTop = try c.decodeIfPresent(Double.self, forKey: .cropTop) ?? 0
        cropBottom = try c.decodeIfPresent(Double.self, forKey: .cropBottom) ?? 0
        cropLeft = try c.decodeIfPresent(Double.self, forKey: .cropLeft) ?? 0
        cropRight = try c.decodeIfPresent(Double.self, forKey: .cropRight) ?? 0
        colorAdjust = try c.decodeIfPresent(ColorAdjust.self, forKey: .colorAdjust) ?? .identity
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth)
        strokeSoftness = try c.decodeIfPresent(Double.self, forKey: .strokeSoftness)
        renderedPath = try c.decodeIfPresent(String.self, forKey: .renderedPath)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
    }
}

struct ProjectDocument: Codable {
    var name: String
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var subtitleStyles: [SubtitleStyle]
    var textTracks: [Track<TextClip>]?     // 文字/标题图层（向后兼容：旧 .bcj 无此字段）
    var textTemplates: [TextTemplate]?    // 文字样式模板（向后兼容）
    var shapeTracks: [Track<ShapeClip>]?   // 图形图层（向后兼容：旧 .bcj 无此字段）
    var filterTracks: [Track<FilterClip>]? // 滤镜轨道（同上，可选是为了兼容旧文件）
    var adjustTracks: [Track<AdjustClip>]? // 调节轨道（同上）
    var effectTracks: [Track<EffectClip>]? // 特效轨道（同上）
    /// 时间线标签页。**新文件存这个**，上面那些散字段只为读旧文件保留 ——
    /// 旧 .bcj 里没有 tabs，打开时把散字段收成一个标签页
    var tabs: [TimelineTab]?
    var activeTab: Int?
    /// 这个片子的设定（主角名字、基调之类）。跟着项目走，换个项目就不该再提
    var agentMemory: [MemoryEntry]?
    var mediaAssets: [MediaAsset]
    var exportSettings: ExportSettings
    var previewResolution: String
    var previewAspectRatio: String?   // 向后兼容：旧 .bcj 无此字段
    var customOutputWidth: Int?
    var customOutputHeight: Int?
    var projectFPS: Int?
    var projectBitrate: Int?
    var subtitleBottomMargin: Double?
    var subtitleLineSpacing: Double?
    /// 项目封面（v5.3.0）。用户自己设计的那张，欢迎页最近文件优先显示它；
    /// 没设计过就还是按老规矩从素材里自动取一张
    var cover: ProjectCover?
    var overlayTrackOrder: [ProjectState.OverlayTrackRef]?
    /// 复合片段轨道。**必须存**——不存的话保存再打开，时间轴上的复合片段整个消失。
    /// 可选是为了兼容没有这个字段的旧 .bcj
    var compoundTracks: [Track<CompoundClip>]?
    /// 视频/音频区的轨道顺序。复合片段按归属规则可能落在这两个区里，
    /// 只存 overlayTrackOrder 的话它重新打开后位置会跑掉
    var videoSectionOrder: [ProjectState.VideoSectionRef]?
    var audioSectionOrder: [ProjectState.AudioSectionRef]?
}

extension ExportSettings: Codable {}

// MARK: - Compound Clip (复合片段)

struct CompoundClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String = "复合片段"
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    var internalStart: Double = 0

    var videoTracks: [Track<VideoClip>] = []
    var audioTracks: [Track<AudioClip>] = []
    var imageTracks: [Track<ImageClip>] = []
    var subtitleTracks: [Track<SubtitleClip>] = []
    var textTracks: [Track<TextClip>] = []
    var shapeTracks: [Track<ShapeClip>] = []
    var compoundTracks: [Track<CompoundClip>] = []
    var overlayTrackOrder: [ProjectState.OverlayTrackRef] = []
    var markers: [Marker]? = nil

    /// 复合片段内部的 overlay 图层清单，从底到顶。没登记进自己那份
    /// overlayTrackOrder 的轨道会补在最底下——漏一条就是整条内容不显示
    var overlayLayersBottomUp: [ProjectState.OverlayTrackRef] {
        ProjectState.overlayLayersBottomUp(
            overlayTrackOrder: overlayTrackOrder,
            imageTracks: imageTracks, subtitleTracks: subtitleTracks,
            textTracks: textTracks, shapeTracks: shapeTracks,
            compoundTracks: compoundTracks)
    }

    /// 字幕轨按**自己的** overlayTrackOrder 排，index 0 排最上面。
    ///
    /// 预览和导出都得用这个，不能直接拿 `subtitleTracks` 的数组顺序：进入复合片段
    /// 编辑后走的是外层那条路径（`ProjectState.orderedSubtitleIndices`，按
    /// overlayTrackOrder 排），依据不一样的话，双语字幕的上下位置里外互换。
    /// 排不进去的（比如 flattened 展开嵌套时新生成的轨）按原顺序追加在后面
    var orderedSubtitleTracks: [Track<SubtitleClip>] {
        var result: [Track<SubtitleClip>] = []
        for ref in overlayTrackOrder {
            if case .subtitle(let id) = ref,
               let t = subtitleTracks.first(where: { $0.id == id }) {
                result.append(t)
            }
        }
        let seen = Set(result.map(\.id))
        result.append(contentsOf: subtitleTracks.filter { !seen.contains($0.id) })
        return result
    }

    func flattened() -> CompoundClip {
        guard !compoundTracks.isEmpty else { return self }
        var r = self
        r.compoundTracks = []
        for nTrack in compoundTracks {
            guard nTrack.isVisible else { continue }
            for nested in nTrack.clips {
                let flat = nested.flattened()
                let ni = flat.internalStart
                let ne = flat.internalStart + flat.duration
                let muted = nTrack.isMuted
                for st in flat.videoTracks where st.isVisible {
                    var mc: [VideoClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.trimStart += (vs - c.startTime) * max(0.01, c.speed)
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty {
                        var t = Track<VideoClip>(clips: mc)
                        t.isMuted = st.isMuted || muted
                        r.videoTracks.append(t)
                    }
                }
                for st in flat.audioTracks where st.isVisible && !st.isMuted && !muted {
                    var mc: [AudioClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.trimStart += (vs - c.startTime) * max(0.01, c.speed)
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty { r.audioTracks.append(Track(clips: mc)) }
                }
                for st in flat.imageTracks where st.isVisible {
                    var mc: [ImageClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty { r.imageTracks.append(Track(clips: mc)) }
                }
                for st in flat.subtitleTracks where st.isVisible {
                    var mc: [SubtitleClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty {
                        var t = Track<SubtitleClip>(clips: mc)
                        t.subtitleStyle = st.subtitleStyle
                        r.subtitleTracks.append(t)
                    }
                }
                for st in flat.textTracks where st.isVisible {
                    var mc: [TextClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty { r.textTracks.append(Track(clips: mc)) }
                }
                for st in flat.shapeTracks where st.isVisible {
                    var mc: [ShapeClip] = []
                    for var c in st.clips {
                        let vs = max(c.startTime, ni); let ve = min(c.endTime, ne)
                        guard ve - vs > 0.01 else { continue }
                        c.startTime = nested.startTime + (vs - ni)
                        c.endTime   = nested.startTime + (ve - ni)
                        mc.append(c)
                    }
                    if !mc.isEmpty { r.shapeTracks.append(Track(clips: mc)) }
                }
            }
        }
        return r
    }
}

// MARK: - Snapshot (for undo/redo)

struct ProjectSnapshot {
    var videoTracks: [Track<VideoClip>]
    var audioTracks: [Track<AudioClip>]
    var imageTracks: [Track<ImageClip>]
    var subtitleTracks: [Track<SubtitleClip>]
    var textTracks: [Track<TextClip>]
    var shapeTracks: [Track<ShapeClip>]
    /// 滤镜轨道。可选是为了不动那些逐字段构造快照的老代码
    var filterTracks: [Track<FilterClip>] = []
    var adjustTracks: [Track<AdjustClip>] = []
    var effectTracks: [Track<EffectClip>] = []
    var compoundTracks: [Track<CompoundClip>]
    var overlayTrackOrder: [ProjectState.OverlayTrackRef]
    var videoSectionOrder: [ProjectState.VideoSectionRef] = []
    var audioSectionOrder: [ProjectState.AudioSectionRef] = []
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

// MARK: - Shape Geometry（图形路径，素材库缩略图 / 预览 / 导出共用）

enum ShapeGeometry {
    /// 支持圆角的形状。其余的（圆、线段、箭头、钢笔）属性区里那一项要灰掉
    static func supportsCorner(_ type: ShapeType) -> Bool {
        switch type {
        case .rectangle, .triangle, .trapezoid, .parallelogram: return true
        default: return false
        }
    }

    /// 在给定矩形内生成图形路径。圆角由调用方按 `cornerRadius` 走 `roundedPolygon`。
    static func path(for type: ShapeType, in r: CGRect) -> Path {
        var p = Path()
        switch type {
        case .rectangle:
            p.addRect(r)
        case .ellipse:
            p.addEllipse(in: r)
        case .triangle, .parallelogram, .trapezoid:
            let pts = polygonPoints(for: type, in: r) ?? []
            if let first = pts.first {
                p.move(to: first)
                for q in pts.dropFirst() { p.addLine(to: q) }
                p.closeSubpath()
            }
        case .line:
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        case .arrow:
            let y = r.midY
            let headLen = r.width * 0.28
            let wing = headLen * 0.55
            p.move(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
            p.move(to: CGPoint(x: r.maxX - headLen, y: y - wing))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
            p.addLine(to: CGPoint(x: r.maxX - headLen, y: y + wing))
        case .pen:
            break // pen 使用 penPath() 单独生成
        }
        return p
    }

    /// 从归一化 PenPoint 数组生成贝塞尔路径
    static func penPath(points: [PenPoint], closed: Bool, in r: CGRect) -> Path {
        guard points.count >= 2 else {
            var p = Path()
            if let pt = points.first {
                let pos = CGPoint(x: r.minX + pt.x * r.width, y: r.minY + pt.y * r.height)
                p.addEllipse(in: CGRect(x: pos.x - 3, y: pos.y - 3, width: 6, height: 6))
            }
            return p
        }
        var p = Path()
        func mapPt(_ pt: PenPoint) -> CGPoint {
            CGPoint(x: r.minX + pt.x * r.width, y: r.minY + pt.y * r.height)
        }
        func addSegment(from a: PenPoint, to b: PenPoint) {
            let ap = mapPt(a), bp = mapPt(b)
            let hasCtrl = abs(a.ctrlOutDX) > 1e-6 || abs(a.ctrlOutDY) > 1e-6
                       || abs(b.ctrlInDX) > 1e-6 || abs(b.ctrlInDY) > 1e-6
            if hasCtrl {
                let cp1 = CGPoint(x: ap.x + a.ctrlOutDX * r.width, y: ap.y + a.ctrlOutDY * r.height)
                let cp2 = CGPoint(x: bp.x + b.ctrlInDX * r.width, y: bp.y + b.ctrlInDY * r.height)
                p.addCurve(to: bp, control1: cp1, control2: cp2)
            } else {
                p.addLine(to: bp)
            }
        }
        p.move(to: mapPt(points[0]))
        for i in 1..<points.count { addSegment(from: points[i - 1], to: points[i]) }
        if closed { addSegment(from: points.last!, to: points.first!); p.closeSubpath() }
        return p
    }

    /// 多边形顶点（用于圆角）。仅三角/平行四边形/梯形返回，其余 nil。
    static func polygonPoints(for type: ShapeType, in r: CGRect) -> [CGPoint]? {
        switch type {
        case .triangle:
            return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .parallelogram:
            let dx = r.width * 0.25
            return [CGPoint(x: r.minX + dx, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX - dx, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .trapezoid:
            let dx = r.width * 0.22
            return [CGPoint(x: r.minX + dx, y: r.minY), CGPoint(x: r.maxX - dx, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default:
            return nil
        }
    }

    /// 给多边形顶点加圆角（二次贝塞尔近似）。
    static func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        let n = pts.count
        guard n >= 3 else { return path }
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n]
            let cur = pts[i]
            let next = pts[(i + 1) % n]
            let d1 = CGPoint(x: prev.x - cur.x, y: prev.y - cur.y)
            let d2 = CGPoint(x: next.x - cur.x, y: next.y - cur.y)
            let len1 = max(hypot(d1.x, d1.y), 0.001)
            let len2 = max(hypot(d2.x, d2.y), 0.001)
            let r = min(radius, len1 / 2, len2 / 2)
            let p1 = CGPoint(x: cur.x + d1.x / len1 * r, y: cur.y + d1.y / len1 * r)
            let p2 = CGPoint(x: cur.x + d2.x / len2 * r, y: cur.y + d2.y / len2 * r)
            if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
            path.addQuadCurve(to: p2, control: cur)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 通知卡片文件名显示

extension String {
    /// 通知卡片 subtitle 用的文件名截断：按视觉宽度（CJK 算 2），头部 + ... + 尾 6 字符 + 后缀。
    /// 卡片文本区实测约 152pt，10pt 字体下约 27 个视觉宽度单位，超了会被系统硬截在末尾、看不到后缀
    func truncatedFileName(maxVisualWidth: Int = 26) -> String {
        func w(_ c: Character) -> Int {
            guard let s = c.unicodeScalars.first else { return 1 }
            let v = s.value
            let cjk = (0x4E00...0x9FFF).contains(v)   // CJK 统一汉字
                || (0x3400...0x4DBF).contains(v)      // 扩展 A
                || (0x3000...0x303F).contains(v)      // CJK 标点
                || (0xFF00...0xFFEF).contains(v)      // 全角
                || (0x3040...0x309F).contains(v)      // 平假名
                || (0x30A0...0x30FF).contains(v)      // 片假名
                || (0xAC00...0xD7AF).contains(v)      // 韩文
            return cjk ? 2 : 1
        }
        func vw(_ s: String) -> Int { s.reduce(0) { $0 + w($1) } }
        guard vw(self) > maxVisualWidth else { return self }

        let ext: String, base: String
        if let dot = lastIndex(of: ".") {
            ext = String(self[dot...]); base = String(self[..<dot])
        } else {
            ext = ""; base = self
        }

        // 尾段固定 6 字符在全中文名（每字算 2）或窄预算下会把额度吃光，逐步缩短
        var tailLen = min(6, base.count)
        var tail = String(base.suffix(tailLen))
        var budget = maxVisualWidth - 3 - vw(tail) - vw(ext)
        while budget <= 0 && tailLen > 1 {
            tailLen -= 1
            tail = String(base.suffix(tailLen))
            budget = maxVisualWidth - 3 - vw(tail) - vw(ext)
        }
        guard budget > 0 else { return "...\(tail)\(ext)" }

        var head = ""
        var used = 0
        for ch in base {
            let cw = w(ch)
            if used + cw > budget { break }
            head.append(ch)
            used += cw
        }
        guard !head.isEmpty else { return "...\(tail)\(ext)" }
        return "\(head)...\(tail)\(ext)"
    }
}
