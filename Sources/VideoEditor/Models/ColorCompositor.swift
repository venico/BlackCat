// ColorCompositor.swift
import AVFoundation
import CoreImage
import ObjectiveC

// MARK: - ColorAdjust

struct ColorAdjust: Codable, Equatable {
    // 基础
    var brightness: Double = 0    // -1 ~ 1
    var contrast:   Double = 0    // -1 ~ 1
    var saturation: Double = 0    // -1 ~ 1
    var vibrance:   Double = 0    // -1 ~ 1，自然饱和（只提低饱和的部分，肤色不容易过）
    // 光影
    var exposure:   Double = 0    // -2 ~ 2 EV
    var gamma:      Double = 1    // 0.25 ~ 4，**中性值是 1 不是 0**
    var highlight:  Double = 0    // -1 ~ 1
    var shadow:     Double = 0    // -1 ~ 1
    // 色彩
    var temperature: Double = 0   // -1 ~ 1，负=冷 正=暖
    var tint:        Double = 0   // -1 ~ 1，负=绿 正=品红
    var hue:         Double = 0   // degrees -180 ~ 180

    var isIdentity: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && vibrance == 0
        && exposure == 0 && abs(gamma - 1) < 0.001 && highlight == 0 && shadow == 0
        && temperature == 0 && tint == 0 && abs(hue) < 0.01
    }
    static let identity = ColorAdjust()

    // 老项目文件里没有新增的这些键。**自动合成的 Codable 遇到缺键会整个解不开**，
    // 所以这里手写一份，缺的一律走默认值
    enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, vibrance
        case exposure, gamma, highlight, shadow
        case temperature, tint, hue
    }

    init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0,
         vibrance: Double = 0, exposure: Double = 0, gamma: Double = 1,
         highlight: Double = 0, shadow: Double = 0,
         temperature: Double = 0, tint: Double = 0, hue: Double = 0) {
        self.brightness = brightness; self.contrast = contrast
        self.saturation = saturation; self.vibrance = vibrance
        self.exposure = exposure; self.gamma = gamma
        self.highlight = highlight; self.shadow = shadow
        self.temperature = temperature; self.tint = tint; self.hue = hue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness  = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast    = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation  = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance    = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        exposure    = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        gamma       = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
        highlight   = try c.decodeIfPresent(Double.self, forKey: .highlight) ?? 0
        shadow      = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint        = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        hue         = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
    }

    /// 给 CALayer.filters 用的同一条链。叠加层（图片/文字/图形是 SwiftUI 画的，
    /// 不经过合成器）靠它拿到跟视频一致的效果
    var ciFilters: [CIFilter] {
        guard !isIdentity else { return [] }
        var out: [CIFilter] = []
        func add(_ name: String, _ params: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            for (k, v) in params { f.setValue(v, forKey: k) }
            out.append(f)
        }
        if exposure != 0 { add("CIExposureAdjust", ["inputEV": exposure]) }
        if abs(gamma - 1) > 0.001 { add("CIGammaAdjust", ["inputPower": max(0.05, gamma)]) }
        if highlight != 0 || shadow != 0 {
            let sh = 0.25 * max(min(shadow, 1), -1)
            let hi = 0.25 * max(min(highlight, 1), -1)
            add("CIToneCurve", [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: min(max(0.25 + sh, 0), 1)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: min(max(0.75 + hi, 0), 1)),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if brightness != 0 || contrast != 0 || saturation != 0 {
            add("CIColorControls", [kCIInputBrightnessKey: brightness,
                                    kCIInputContrastKey: 1.0 + contrast,
                                    kCIInputSaturationKey: 1.0 + saturation])
        }
        if vibrance != 0 { add("CIVibrance", ["inputAmount": vibrance]) }
        if temperature != 0 || tint != 0 {
            add("CITemperatureAndTint", [
                "inputNeutral": CIVector(x: 6500 + temperature * 3000, y: tint * 100),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if abs(hue) > 0.01 { add("CIHueAdjust", [kCIInputAngleKey: hue * .pi / 180.0]) }
        return out
    }

    /// 调色链。顺序照专业调色的习惯走：曝光 → 影调 → 颜色
    static func apply(_ img: CIImage, _ adj: ColorAdjust) -> CIImage {
        guard !adj.isIdentity else { return img }
        var out = img

        if adj.exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": adj.exposure])
        }
        if abs(adj.gamma - 1) > 0.001 {
            out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": max(0.05, adj.gamma)])
        }
        // 高光/阴影走色调曲线的两个控制点：往上抬是提亮、往下拉是压暗。
        // 比 CIHighlightShadowAdjust 省一个模糊半径，而且两个方向都能调
        if adj.highlight != 0 || adj.shadow != 0 {
            let s = 0.25 * max(min(adj.shadow, 1), -1)
            let h = 0.25 * max(min(adj.highlight, 1), -1)
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: min(max(0.25 + s, 0), 1)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: min(max(0.75 + h, 0), 1)),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if adj.brightness != 0 || adj.contrast != 0 || adj.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adj.brightness,
                kCIInputContrastKey:   1.0 + adj.contrast,
                kCIInputSaturationKey: 1.0 + adj.saturation
            ])
        }
        if adj.vibrance != 0 {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": adj.vibrance])
        }
        // 色温色调：inputNeutral 说的是「这张图现在的白点」，
        // 把它报得比 6500 高，滤镜就会往回压成暖色 —— 所以正值 = 暖
        if adj.temperature != 0 || adj.tint != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + adj.temperature * 3000,
                                         y: adj.tint * 100),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }
        if abs(adj.hue) > 0.01 {
            out = out.applyingFilter("CIHueAdjust",
                                     parameters: [kCIInputAngleKey: adj.hue * .pi / 180.0])
        }
        return out
    }
}

// MARK: - CompositorTrackEntry

struct CompositorTrackEntry {
    let trackID:     CMPersistentTrackID
    let userScaleX:  CGFloat
    let userScaleY:  CGFloat
    var userOffsetX: CGFloat
    var userOffsetY: CGFloat
    let cropTop:     CGFloat
    let cropBottom:  CGFloat
    let cropLeft:    CGFloat
    let cropRight:   CGFloat
    var colorAdjust: ColorAdjust
    var mirrorH: Bool = false
    var mirrorV: Bool = false
    var rotation: Double = 0
    /// 画面圆角（px，源坐标）。0 = 不切
    var cornerRadius: Double = 0
    /// 图层自身的不透明度（跟转场的 opacityRamp 是两回事，两者相乘）
    var baseOpacity: Double = 1
    var naturalSize: CGSize?
    /// 素材自带的方向（手机竖拍视频 naturalSize 是横的，靠它转正）。
    /// AVFoundation 只在**没有**自定义 compositor 时才自动应用 preferredTransform，
    /// 我们用了 ColorCompositor，就得自己来 —— 不然画布按转正后的竖尺寸算、
    /// 画面却还是横着铺，就是「画布竖的、视频横的」
    var sourceTransform: CGAffineTransform = .identity
    var opacityRamp: (from: Float,  to: Float,  start: Double, end: Double)?
    var pushRamp:    (dx: CGFloat, dy: CGFloat, isA: Bool, start: Double, end: Double)?
    var zoomRamp:    (from: CGFloat, to: CGFloat, start: Double, end: Double)?
    /// 旋转转场：角度（度），绕画面中心
    var rotateRamp:  (from: CGFloat, to: CGFloat, start: Double, end: Double)?
    /// 擦除转场：只露出从一条边扫开的那一块
    var wipeRamp:    (type: TransitionType, start: Double, end: Double)?

    func effectiveOpacity(at t: Double) -> Float {
        guard let r = opacityRamp else { return 1.0 }
        let frac = Float((t - r.start) / max(r.end - r.start, 1e-6))
        return r.from + (r.to - r.from) * Swift.max(0, Swift.min(1, frac))
    }

    /// 根据实际 source buffer 尺寸在 render 空间中计算 CIImage 变换。
    /// 公式和导出 videoTransform 一致（y-down 语义），由 ColorCompositor 统一做 y 翻转。
    /// - Parameters:
    ///   - srcSize: 图像实际占的范围，用来居中
    ///   - scaleBasis: 算贴合倍率用的尺寸，默认同 srcSize。
    ///     自由旋转时传**转之前**的尺寸 —— 按转完的外接矩形算倍率的话，
    ///     转的过程中画面会一起缩放
    func fitTransform(srcSize: CGSize, renderSize: CGSize, at t: Double,
                      scaleBasis: CGSize? = nil) -> CGAffineTransform {
        guard srcSize.width > 0, srcSize.height > 0 else { return .identity }
        let basis = scaleBasis ?? srcSize
        guard basis.width > 0, basis.height > 0 else { return .identity }
        let baseScale = min(renderSize.width / basis.width, renderSize.height / basis.height)
        let sx = baseScale * userScaleX
        let sy = baseScale * userScaleY
        let tx = (renderSize.width  - srcSize.width  * sx) / 2 + userOffsetX * renderSize.width
        let ty = (renderSize.height - srcSize.height * sy) / 2 - userOffsetY * renderSize.height
        var result = CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        // 推入/滑入：平移偏移
        if let ramp = pushRamp {
            let frac = CGFloat((t - ramp.start) / max(ramp.end - ramp.start, 1e-6))
            let c = Swift.max(0, Swift.min(1, frac))
            let pdx = ramp.isA ? ramp.dx * c : -ramp.dx * (1 - c)
            let pdy = ramp.isA ? ramp.dy * c : -ramp.dy * (1 - c)
            result = result.concatenating(CGAffineTransform(translationX: pdx, y: pdy))
        }
        // 缩放转场：以 render 中心为锚追加缩放
        if let zr = zoomRamp {
            let frac = CGFloat((t - zr.start) / max(zr.end - zr.start, 1e-6))
            let c = Swift.max(0, Swift.min(1, frac))
            let s = zr.from + (zr.to - zr.from) * c
            let cx = renderSize.width / 2, cy = renderSize.height / 2
            let zoomT = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -cx, y: -cy)
            result = result.concatenating(zoomT)
        }
        // 旋转转场：以 render 中心为锚追加旋转
        if let rr = rotateRamp {
            let frac = CGFloat((t - rr.start) / max(rr.end - rr.start, 1e-6))
            let c = Swift.max(0, Swift.min(1, frac))
            let deg = rr.from + (rr.to - rr.from) * c
            let cx = renderSize.width / 2, cy = renderSize.height / 2
            let rotT = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: deg * .pi / 180)
                .translatedBy(x: -cx, y: -cy)
            result = result.concatenating(rotT)
        }
        return result
    }

    /// 擦除转场这一刻露出的范围（render 坐标，CIImage y 朝上）。nil = 不裁
    func wipeRect(at t: Double, bounds: CGRect) -> CGRect? {
        guard let w = wipeRamp else { return nil }
        let frac = CGFloat((t - w.start) / max(w.end - w.start, 1e-6))
        let c = Swift.max(0, Swift.min(1, frac))
        let W = bounds.width, H = bounds.height
        switch w.type {
        case .wipeLeft:  return CGRect(x: W * (1 - c), y: 0, width: W * c, height: H)   // 从右往左扫
        case .wipeRight: return CGRect(x: 0, y: 0, width: W * c, height: H)             // 从左往右扫
        case .wipeUp:    return CGRect(x: 0, y: 0, width: W, height: H * c)             // 从下往上扫
        case .wipeDown:  return CGRect(x: 0, y: H * (1 - c), width: W, height: H * c)   // 从上往下扫
        default:         return nil
        }
    }
}

// MARK: - ColorCompositionData

final class ColorCompositionData: NSObject {
    var entries:    [CompositorTrackEntry] = []
    var renderSize: CGSize = .zero
    /// 滤镜轨道。**在所有画面合成完之后**统一套上去
    var filterTracks: [Track<FilterClip>] = []
    /// 闪白转场这段用白底（默认黑底）
    var whiteBase = false
    /// 模糊转场：整帧模糊，切点处最糊
    var blurRamp: (start: Double, end: Double, cut: Double)?
    /// 特效类转场（圆形 / 百叶窗 / 复印机 / 波纹 / 翻页）：拿前后两片各自的整帧混合
    var frameBlend: (type: TransitionType, start: Double, end: Double,
                     trackA: CMPersistentTrackID, trackB: CMPersistentTrackID)?
    /// 导出用。只画视频层和转场：叠加层、滤镜这些由导出的逐帧处理另画；
    /// 预览那几样按轨道号存的临时状态（拖动偏移、实时调色）也不能套过来 —— 轨道号是两份合成各自编的
    var forExport = false
    /// 预览用：这个项目窗口自己的实时状态（拖动偏移、实时调色、效果轨、叠加层）。导出不带
    var live: PreviewCompositorState?
}

/// 自带数据的合成指令。导出用它：数据跟着指令走，不经全局存储，
/// 跟同时开着的预览（以及别的窗口）互不干扰
final class ColorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let data: ColorCompositionData

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], data: ColorCompositionData) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
        self.data = data
    }
}

// MARK: - PreviewCompositorState
// 一个项目窗口自己的预览实时状态。
//
// 原来这些全是 ColorCompositor 上的静态变量，所有打开的项目共用一份：
// 两个窗口都开着时，后重建的那个会把前一个的滤镜、叠加层、分段数据整个盖掉，
// 前一个窗口的预览就套上了别的项目的滤镜，或者滤镜干脆没了。
// 现在每个 ProjectState 一份，挂在预览指令的数据上（ColorCompositionData.live）带进合成器，
// 跟导出「数据跟着指令走」是同一个做法。

final class PreviewCompositorState: @unchecked Sendable {
    private let lock = NSLock()
    /// 滤镜 / 调节 / 特效轨道。**不能只在重建时塞进分段数据**：拖强度、改特效参数
    /// 是不重建的，只推这几样再逼播放器重画当前帧
    private var filterTracks: [Track<FilterClip>] = []
    private var adjustTracks: [Track<AdjustClip>] = []
    private var effectTracks: [Track<EffectClip>] = []
    private var overlay = ColorCompositor.OverlayInput()
    private var dragOffsets: [CMPersistentTrackID: (x: CGFloat, y: CGFloat)] = [:]
    /// 拖色调滑块时的实时覆盖值。走这条就不用重建整个 composition ——
    /// 重建要重新 load playerItem，代价大到只能防抖，表现就是"松手才变"
    private var liveColorAdjusts: [CMPersistentTrackID: ColorAdjust] = [:]

    func setFilterTracks(_ tracks: [Track<FilterClip>]) {
        lock.lock(); defer { lock.unlock() }
        filterTracks = tracks
    }

    func getFilterTracks() -> [Track<FilterClip>] {
        lock.lock(); defer { lock.unlock() }
        return filterTracks
    }

    func setAdjustTracks(_ tracks: [Track<AdjustClip>]) {
        lock.lock(); defer { lock.unlock() }
        adjustTracks = tracks
    }

    func setEffectTracks(_ tracks: [Track<EffectClip>]) {
        lock.lock(); defer { lock.unlock() }
        effectTracks = tracks
    }

    func setOverlayInput(_ input: ColorCompositor.OverlayInput) {
        lock.lock(); defer { lock.unlock() }
        overlay = input
    }

    func setDragOffset(trackID: CMPersistentTrackID, offsetX: CGFloat, offsetY: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        dragOffsets[trackID] = (offsetX, offsetY)
    }

    func clearDragOffsets() {
        lock.lock(); defer { lock.unlock() }
        dragOffsets.removeAll()
    }

    /// 色调滑块拖动中的实时值。配合 `clock.refreshSeekRequest` 的 jitter seek
    /// 逼播放器重绘当前帧，滑块就跟图片一样即时响应
    func setLiveColorAdjust(trackID: CMPersistentTrackID, _ adj: ColorAdjust) {
        lock.lock(); defer { lock.unlock() }
        liveColorAdjusts[trackID] = adj
    }

    /// 整份重建时调：新的分段数据里已经是真值，拖动中的临时覆盖作废
    func clearTransient() {
        lock.lock(); defer { lock.unlock() }
        dragOffsets.removeAll()
        liveColorAdjusts.removeAll()
    }

    func dragOffset(trackID: CMPersistentTrackID) -> (x: CGFloat, y: CGFloat)? {
        lock.lock(); defer { lock.unlock() }
        return dragOffsets[trackID]
    }

    func liveColorAdjust(trackID: CMPersistentTrackID) -> ColorAdjust? {
        lock.lock(); defer { lock.unlock() }
        return liveColorAdjusts[trackID]
    }

    /// 把叠加层画到帧上。顺序跟导出一致：从底到顶
    /// - Parameter explicit: 不走手上那份、直接用给定的数据画（Agent 截帧用：
    ///   没有效果轨时手上那份是空的，叠加层归 SwiftUI 画，截帧里就没有字幕）
    func drawOverlays(_ image: CIImage, at t: Double, renderSize: CGSize,
                      input explicit: ColorCompositor.OverlayInput? = nil) -> CIImage {
        lock.lock()
        let input = explicit ?? overlay
        let filterTracks = self.filterTracks
        let adjustTracks = self.adjustTracks
        let effectTracks = self.effectTracks
        lock.unlock()
        guard !input.order.isEmpty else { return image }
        var out = image
        var subtitleDone = false
        for ref in input.order {
            switch ref {
            case .image(let tid):
                guard let track = input.imageTracks.first(where: { $0.id == tid }), track.isVisible,
                      let clip = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }),
                      let layer = OverlayRenderer.renderImageOverlay(
                        clip: clip, renderSize: renderSize, ciCache: input.imageCICache)
                else { continue }
                out = layer.composited(over: out)
            case .subtitle:
                guard !subtitleDone, let info = input.subtitleInfo,
                      let layer = OverlayRenderer.renderSubtitleOverlay(atTime: t, info: info)
                else { continue }
                subtitleDone = true
                out = layer.composited(over: out)
            case .text(let tid):
                guard let track = input.textTracks.first(where: { $0.id == tid }), track.isVisible,
                      let layer = OverlayRenderer.renderTextOverlay(
                        atTime: t, clips: track.clips,
                        fontScale: input.fontScale, renderSize: renderSize)
                else { continue }
                out = layer.composited(over: out)
            case .shape(let tid):
                guard let track = input.shapeTracks.first(where: { $0.id == tid }), track.isVisible,
                      let layer = OverlayRenderer.renderShapeOverlay(
                        atTime: t, clips: track.clips,
                        scale: input.fontScale, renderSize: renderSize)
                else { continue }
                out = layer.composited(over: out)
            case .compound(let tid):
                guard let info = input.subtitleInfo else { continue }
                out = OverlayRenderer.composeCompoundOverlays(
                    trackID: tid, tracks: input.compoundTracks, atTime: t,
                    onto: out, renderSize: renderSize,
                    imageCICache: input.imageCICache, subtitleInfo: info)
            case .filter(let tid):
                // 滤镜只作用于排在它下面的图层，走到这一层就把已经画好的套一遍
                guard let track = filterTracks.first(where: { $0.id == tid }), track.isVisible
                else { continue }
                for clip in track.clips where clip.startTime <= t && clip.endTime > t {
                    out = FilterEngine.apply(clip, to: out)
                        .cropped(to: CGRect(origin: .zero, size: renderSize))
                }
            case .adjust(let tid):
                guard let track = adjustTracks.first(where: { $0.id == tid }), track.isVisible
                else { continue }
                for clip in track.clips where clip.startTime <= t && clip.endTime > t {
                    out = ColorAdjust.apply(out, clip.adjust)
                        .cropped(to: CGRect(origin: .zero, size: renderSize))
                }
            case .effect(let tid):
                guard let track = effectTracks.first(where: { $0.id == tid }), track.isVisible
                else { continue }
                for clip in track.clips where clip.startTime <= t && clip.endTime > t {
                    out = EffectEngine.apply(clip, to: out, renderSize: renderSize)
                        .cropped(to: CGRect(origin: .zero, size: renderSize))
                }
            }
        }
        return out
    }
}

// MARK: - ColorCompositor
// 预览和导出的指令都是 ColorInstruction，分段数据跟着指令走；
// 预览要的实时状态（拖动偏移、实时调色、效果轨、叠加层）在数据的 live 上，各项目各一份

final class ColorCompositor: NSObject, AVVideoCompositing {

    /// 叠加层（图片/字幕/文字/图形/复合）。
    ///
    /// **画进帧里再做特效**，跟导出走同一份 OverlayRenderer ——
    /// 原先预览是让 SwiftUI 单独画这些图层、各自套一遍特效，
    /// 漩涡这种改几何的就会出现「图片扭一套、视频扭另一套」，两边对不上
    struct OverlayInput {
        var order: [ProjectState.OverlayTrackRef] = []
        var imageTracks: [Track<ImageClip>] = []
        var textTracks: [Track<TextClip>] = []
        var shapeTracks: [Track<ShapeClip>] = []
        var compoundTracks: [Track<CompoundClip>] = []
        var subtitleInfo: OverlayRenderer.SubtitleRenderInfo? = nil
        var imageCICache: [URL: CIImage] = [:]
        var fontScale: CGFloat = 1
    }

    // ---- AVVideoCompositing ----

    private static let sharedCtx: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}



    /// 特效类转场：前片 → 后片，progress 0~1。预览和导出共用，两张图都得是铺满 extent 的整帧
    static func blendTransition(_ type: TransitionType, from a: CIImage, to b: CIImage,
                                progress: Double, extent: CGRect) -> CIImage {
        let p = CGFloat(max(0, min(1, progress)))
        let W = extent.width, H = extent.height
        let center = CIVector(x: extent.midX, y: extent.midY)
        let diag = sqrt(W * W + H * H) / 2
        /// 白 = 露后片、黑 = 留前片的遮罩，拿它把两帧拼起来
        func masked(_ mask: CIImage, top: CIImage, bottom: CIImage) -> CIImage {
            top.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: bottom,
                kCIInputMaskImageKey: mask.cropped(to: extent)
            ]).cropped(to: extent)
        }
        func circle(radius r: CGFloat) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center, "inputRadius0": max(0, r - 2), "inputRadius1": r + 2,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ])?.outputImage ?? CIImage(color: .black)
        }
        switch type {
        case .circleOpen:
            return masked(circle(radius: diag * p), top: b, bottom: a)
        case .circleClose:
            return masked(circle(radius: diag * (1 - p)), top: a, bottom: b)
        case .blinds:
            // 10 条横杠，每条从自己的上沿往下长
            let n = 10
            let bandH = H / CGFloat(n)
            var mask = CIImage(color: .black).cropped(to: extent)
            for i in 0..<n {
                let r = CGRect(x: extent.minX, y: extent.minY + CGFloat(i) * bandH + bandH * (1 - p),
                               width: W, height: bandH * p)
                mask = CIImage(color: .white).cropped(to: r).composited(over: mask)
            }
            return masked(mask, top: b, bottom: a)
        case .copyMachine:
            return a.applyingFilter("CICopyMachineTransition", parameters: [
                kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: extent),
                kCIInputTimeKey: p, kCIInputWidthKey: W * 0.2, kCIInputAngleKey: 0,
                "inputOpacity": 1.3, kCIInputColorKey: CIColor(red: 0.6, green: 1, blue: 0.8)
            ]).cropped(to: extent)
        case .ripple:
            let shading = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.25)).cropped(to: extent)
            return a.applyingFilter("CIRippleTransition", parameters: [
                kCIInputTargetImageKey: b, kCIInputShadingImageKey: shading,
                kCIInputCenterKey: center, kCIInputExtentKey: CIVector(cgRect: extent),
                kCIInputTimeKey: p, kCIInputWidthKey: W * 0.08, kCIInputScaleKey: 50
            ]).cropped(to: extent)
        case .pageCurl:
            let shading = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)).cropped(to: extent)
            return a.applyingFilter("CIPageCurlTransition", parameters: [
                kCIInputTargetImageKey: b, "inputBacksideImage": a, kCIInputShadingImageKey: shading,
                kCIInputExtentKey: CIVector(cgRect: extent), kCIInputTimeKey: p,
                kCIInputAngleKey: CGFloat.pi * 0.85, kCIInputRadiusKey: min(W, H) * 0.15
            ]).cropped(to: extent)
        case .glitch:
            // 前半段是前片、后半段是后片，中间那一下最乱：横条错位 + 红蓝拉开
            let k = 1 - abs(2 * p - 1)
            let src = p < 0.5 ? a : b
            // 每秒换 20 次花样，同一时刻结果固定（导出和预览一致）
            let seed = Int(p * 20)
            var torn = src
            let bands = 8
            for i in 0..<bands {
                let r = hash01(seed &* 31 &+ i)
                guard r > 0.45 else { continue }
                let y = extent.minY + CGFloat(hash01(seed &* 17 &+ i &* 7)) * H
                let h = H * (0.02 + 0.08 * CGFloat(hash01(seed &+ i &* 13)))
                let dx = (CGFloat(hash01(seed &* 7 &+ i)) - 0.5) * W * 0.25 * k
                let slice = src.cropped(to: CGRect(x: extent.minX, y: y, width: W, height: h))
                    .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                torn = slice.composited(over: torn)
            }
            return rgbSplit(torn.cropped(to: extent), dx: W * 0.012 * k, extent: extent)
        case .shake:
            // 镜头猛晃：放大一点藏住边，随机偏移，中间最狠；切点前后 15% 叠化过去
            let k = 1 - abs(2 * p - 1)
            let mix = max(0, min(1, (p - 0.35) / 0.3))
            let src = dissolve(from: a, to: b, mix: mix, extent: extent)
            let seed = Int(p * 30)
            let dx = (CGFloat(hash01(seed &* 11)) - 0.5) * W * 0.06 * k
            let dy = (CGFloat(hash01(seed &* 23 &+ 5)) - 0.5) * H * 0.06 * k
            let s = 1 + 0.08 * k
            let tr = CGAffineTransform(translationX: extent.midX + dx, y: extent.midY + dy)
                .scaledBy(x: s, y: s).translatedBy(x: -extent.midX, y: -extent.midY)
            return src.clampedToExtent().transformed(by: tr).cropped(to: extent)
        case .chromatic:
            let k = 1 - abs(2 * p - 1)
            let src = dissolve(from: a, to: b, mix: p, extent: extent)
            return rgbSplit(src, dx: W * 0.03 * k, extent: extent)
        case .lightLeak:
            // 一团暖光从左扫到右，最亮的时候（中间）叠化过去
            let k = 1 - abs(2 * p - 1)
            let mix = max(0, min(1, (p - 0.3) / 0.4))
            let src = dissolve(from: a, to: b, mix: mix, extent: extent)
            let cx = extent.minX + W * (-0.2 + 1.4 * p)
            let glow = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: extent.midY + H * 0.1),
                "inputRadius0": 0, "inputRadius1": max(W, H) * 0.75,
                "inputColor0": CIColor(red: 1, green: 0.62, blue: 0.3, alpha: 0.95 * k),
                "inputColor1": CIColor(red: 1, green: 0.3, blue: 0.1, alpha: 0)
            ])?.outputImage?.cropped(to: extent) ?? CIImage.empty()
            return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: src])
                .cropped(to: extent)
        case .splitScreen:
            // 后片切成三条竖条，中间那条从上、两边从下，依次错开滑进来
            var out = a
            for i in 0..<3 {
                let delay = CGFloat(i) * 0.15
                let q = max(0, min(1, (p - delay) / (1 - 0.3)))
                let e = 1 - (1 - q) * (1 - q)          // 先快后慢
                let dir: CGFloat = i == 1 ? 1 : -1
                let strip = CGRect(x: extent.minX + W * CGFloat(i) / 3, y: extent.minY, width: W / 3, height: H)
                out = b.cropped(to: strip)
                    .transformed(by: CGAffineTransform(translationX: 0, y: dir * H * (1 - e)))
                    .cropped(to: extent)
                    .composited(over: out)
            }
            return out.cropped(to: extent)
        default:
            // 兜底：叠化
            return b.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ]).composited(over: a).cropped(to: extent)
        }
    }

    /// 0~1 的伪随机数，同一个输入永远同一个结果（故障、抖动要预览和导出画得一模一样）
    private static func hash01(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x = x ^ (x >> 31)
        return Double(x % 10_000) / 10_000
    }

    /// 叠化：后片按 mix 渐显盖在前片上
    private static func dissolve(from a: CIImage, to b: CIImage, mix: CGFloat, extent: CGRect) -> CIImage {
        guard mix > 0.001 else { return a }
        guard mix < 0.999 else { return b }
        return b.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: mix)
        ]).composited(over: a).cropped(to: extent)
    }

    /// 红绿蓝三层左右拉开（红往左、蓝往右），拉开量 dx 像素
    private static func rgbSplit(_ img: CIImage, dx: CGFloat, extent: CGRect) -> CIImage {
        guard dx > 0.5 else { return img }
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            img.clampedToExtent().applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: -dx, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: dx, y: 0))
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }

    /// 模糊转场的整帧模糊。预览和导出共用，半径按画面高度折算（1080 高时最糊 36）
    static func transitionBlur(_ image: CIImage, at t: Double,
                               ramp: (start: Double, end: Double, cut: Double),
                               bounds: CGRect) -> CIImage {
        let half = max(ramp.end - ramp.start, 1e-6) / 2
        let k = max(0, 1 - abs(t - ramp.cut) / half)
        let r = 36 * (bounds.height / 1080) * CGFloat(k)
        guard r > 0.3 else { return image }
        return image.clampedToExtent().applyingGaussianBlur(sigma: Double(r)).cropped(to: bounds)
    }

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        guard let data = (req.videoCompositionInstruction as? ColorInstruction)?.data else {
            // 不是我们的指令（拿不到数据）：透传第一个 source frame（自动 fit-to-output）
            if let firstIDVal = req.videoCompositionInstruction.requiredSourceTrackIDs?.first,
               let firstID   = (firstIDVal as? NSNumber)?.int32Value,
               let outBuf    = req.renderContext.newPixelBuffer(),
               let srcBuf    = req.sourceFrame(byTrackID: CMPersistentTrackID(firstID)) {
                let outW = CGFloat(CVPixelBufferGetWidth(outBuf))
                let outH = CGFloat(CVPixelBufferGetHeight(outBuf))
                let srcW = CGFloat(CVPixelBufferGetWidth(srcBuf))
                let srcH = CGFloat(CVPixelBufferGetHeight(srcBuf))
                let scale = min(outW / max(srcW, 1), outH / max(srcH, 1))
                let tx = (outW - srcW * scale) / 2
                let ty = (outH - srcH * scale) / 2
                var ci = CIImage(cvPixelBuffer: srcBuf)
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: tx, y: ty)))
                ci = ci.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
                Self.sharedCtx.render(ci, to: outBuf,
                                      bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                                      colorSpace: CGColorSpaceCreateDeviceRGB())
                req.finish(withComposedVideoFrame: outBuf)
            } else {
                DiagLog.log("[预览] 合成器透传失败（无数据且拿不到 source frame）t=\(String(format: "%.2f", req.compositionTime.seconds))")
                req.finish(with: NSError(domain: "ColorCompositor", code: 1, userInfo: nil))
            }
            return
        }

        guard let outBuf = req.renderContext.newPixelBuffer() else {
            DiagLog.log("[预览] 合成器拿不到输出 pixelBuffer")
            req.finish(with: NSError(domain: "ColorCompositor", code: 2, userInfo: nil))
            return
        }

        let t      = req.compositionTime.seconds
        let outW   = CGFloat(CVPixelBufferGetWidth(outBuf))
        let outH   = CGFloat(CVPixelBufferGetHeight(outBuf))
        let bounds = CGRect(x: 0, y: 0, width: outW, height: outH)
        let renderSize = outW > 0 && outH > 0 ? CGSize(width: outW, height: outH) : data.renderSize

        // **底色不算画面**：先在透明底上合成，滤镜 / 调节 / 特效只碰得到有内容的地方，
        // 最后再垫黑底。原来一开始就铺一层不透明的黑，调亮之后视频四周的黑边跟着发灰。
        // 闪白转场的白底是转场画面本身，照常参与
        var result: CIImage = data.whiteBase
            ? CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: bounds)
            : CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)

        // 特效类转场：前后两片先各自画好整帧，循环完再一起混
        var blendA: CIImage?
        var blendB: CIImage?
        for var entry in data.entries {
            guard let srcBuf = req.sourceFrame(byTrackID: entry.trackID) else { continue }

            if !data.forExport, let drag = data.live?.dragOffset(trackID: entry.trackID) {
                entry.userOffsetX = drag.x
                entry.userOffsetY = drag.y
            }
            if !data.forExport, let live = data.live?.liveColorAdjust(trackID: entry.trackID) {
                entry.colorAdjust = live
            }

            let srcW = CGFloat(CVPixelBufferGetWidth(srcBuf))
            let srcH = CGFloat(CVPixelBufferGetHeight(srcBuf))
            var ci = CIImage(cvPixelBuffer: srcBuf)

            // 1. 色调
            if !entry.colorAdjust.isIdentity {
                ci = ColorAdjust.apply(ci, entry.colorAdjust)
            }

            // 2. 归一到 naturalSize（和导出 videoTransform 一致）。如果 naturalSize 和
            // buffer 尺寸不同，先把 CIImage pre-scale 过去，让后面的定位与导出一致。
            var effectiveSize = CGSize(width: srcW, height: srcH)
            if let ns = entry.naturalSize, ns.width > 0, ns.height > 0 {
                if abs(ns.width - srcW) > 0.5 || abs(ns.height - srcH) > 0.5 {
                    ci = ci.transformed(by: CGAffineTransform(scaleX: ns.width / srcW, y: ns.height / srcH))
                }
                effectiveSize = ns
            }
            // 2.5 素材自带方向：竖拍视频先转正，后面的裁剪和用户旋转都基于转正后的画面
            //     （用户说的"左边"是他在预览里看到的左边，不是文件里的左边）。
            //
            //     **不能把 preferredTransform 直接套到 CIImage 上**：它是按 y-down 的
            //     视频坐标定义的，而 CIImage 是 y-up，直接用旋转方向就反了，画面正好
            //     倒过来（实测竖拍视频头朝下）。这里只取它的旋转角再反号。
            //     导出那条路走 layerInstruction，本来就是 y-down，直接用原变换即可。
            let srcAngle = -atan2(entry.sourceTransform.b, entry.sourceTransform.a)
            if abs(srcAngle) > 0.001 {
                let e = ci.extent
                let m = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                    .concatenating(CGAffineTransform(rotationAngle: srcAngle))
                    .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
                ci = ci.transformed(by: m)
                let ne = ci.extent
                ci = ci.transformed(by: CGAffineTransform(translationX: -ne.origin.x,
                                                          y: -ne.origin.y))
                effectiveSize = ci.extent.size
            }

            // 整幅画面（未裁剪）的范围，下面的旋转锚点和 fit 尺寸都以它为准 ——
            // 裁剪只该遮住一块，不该顺带改变画面的缩放和位置
            let fullExtent = ci.extent
            let fullCX = fullExtent.midX, fullCY = fullExtent.midY

            // 3. 裁剪：在**源坐标**里裁。裁剪比例是相对视频自己的方向定义的，
            //    所以必须排在旋转前 —— 这样"左边"永远是画面自己的左边
            if entry.cropTop > 0.001 || entry.cropBottom > 0.001 ||
               entry.cropLeft > 0.001 || entry.cropRight > 0.001 {
                let cropRect = CGRect(
                    x: fullExtent.origin.x + effectiveSize.width * entry.cropLeft,
                    y: fullExtent.origin.y + effectiveSize.height * entry.cropBottom,
                    width:  max(1, effectiveSize.width * (1 - entry.cropLeft - entry.cropRight)),
                    height: max(1, effectiveSize.height * (1 - entry.cropTop  - entry.cropBottom)))
                ci = ci.cropped(to: cropRect)
            }

            // 3.5 圆角：裁剪之后、变换之前，跟预览的 clipShape、导出那条链同一个位置
            if entry.cornerRadius > 0.01 {
                let box = ci.extent
                if box.width > 1, box.height > 1,
                   let gen = CIFilter(name: "CIRoundedRectangleGenerator") {
                    let r = min(CGFloat(entry.cornerRadius), min(box.width, box.height) / 2)
                    gen.setValue(CIVector(cgRect: box), forKey: "inputExtent")
                    gen.setValue(r, forKey: "inputRadius")
                    gen.setValue(CIColor.white, forKey: "inputColor")
                    if let mask = gen.outputImage?.cropped(to: box) {
                        ci = ci.applyingFilter("CIBlendWithAlphaMask", parameters: [
                            kCIInputBackgroundImageKey: CIImage.empty(),
                            kCIInputMaskImageKey: mask
                        ]).cropped(to: box)
                    }
                }
            }

            // 4. 镜像 / 旋转，绕**整幅画面**的中心（不是裁剪后那块的中心，
            //    否则裁过的画面转起来会自己跑位）
            var rotT = CGAffineTransform.identity
            if entry.mirrorH || entry.mirrorV || entry.rotation != 0 {
                rotT = CGAffineTransform(translationX: -fullCX, y: -fullCY)
                if entry.mirrorH { rotT = rotT.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
                if entry.mirrorV { rotT = rotT.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
                let rad = CGFloat(entry.rotation) * .pi / 180
                if abs(rad) > 0.001 { rotT = rotT.concatenating(CGAffineTransform(rotationAngle: rad)) }
                rotT = rotT.concatenating(CGAffineTransform(translationX: fullCX, y: fullCY))
                ci = ci.transformed(by: rotT)
            }

            // 5. Fit 到渲染区域 —— 放在旋转**之后**，尺寸取"整幅画面转完之后"占的范围。
            //    90°/270° 时宽高已经互换，横视频转成竖的会按竖的重新适配画布，
            //    画面完整、不变形。反过来（先 fit 再转）是按旋转**前**的方向贴合画布，
            //    转完自然跟画布对不上，看着就是错位
            let rotFull = fullExtent.applying(rotT)
            ci = ci.transformed(by: CGAffineTransform(translationX: -rotFull.origin.x,
                                                      y: -rotFull.origin.y))
            let fitT = entry.fitTransform(
                srcSize: rotFull.size,
                renderSize: renderSize, at: t,
                scaleBasis: rotatedFitSize(fullExtent.size, rotation: entry.rotation))
            ci = ci.transformed(by: fitT)

            // 5. 不透明度（图层自己的 × 转场的）
            let op = entry.effectiveOpacity(at: t) * Float(entry.baseOpacity)
            if op < 0.999 {
                ci = ci.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(op))
                ])
            }

            // 6. 裁到 render 边界（擦除转场再裁成扫开的那一块）
            ci = ci.cropped(to: entry.wipeRect(at: t, bounds: bounds) ?? bounds)

            // 7. 叠加
            if let fx = data.frameBlend, entry.trackID == fx.trackA || entry.trackID == fx.trackB {
                if entry.trackID == fx.trackA { blendA = ci } else { blendB = ci }
                continue
            }
            result = ci.composited(over: result)
        }
        if let fx = data.frameBlend {
            let bg = result
            let a = (blendA ?? CIImage.empty()).composited(over: bg).cropped(to: bounds)
            let b = (blendB ?? CIImage.empty()).composited(over: bg).cropped(to: bounds)
            result = Self.blendTransition(fx.type, from: a, to: b,
                                          progress: (t - fx.start) / max(fx.end - fx.start, 1e-6),
                                          extent: bounds)
        }

        // 7.5 模糊转场：整帧模糊，切点处最糊，两头清楚
        if let br = data.blurRamp {
            result = Self.transitionBlur(result, at: t, ramp: br, bounds: bounds)
        }

        // 8. 叠加层 + 三类效果轨道，按图层顺序一次走完（见 drawOverlays）。
        //    导出时只有「除了视频只有效果轨」才在这儿套（这样还能走快速导出）；
        //    带字幕文字这些的，整套归导出的逐帧处理，这里不画
        if let live = data.live {
            result = live.drawOverlays(result, at: t, renderSize: bounds.size).cropped(to: bounds)
        }
        // 垫黑底。导出交给逐帧处理的那种例外：留着透明，等它套完效果再垫，
        // 不然黑边又会被那边的调节调灰（透明处写进编码器本来就是黑的）
        if !(data.forExport && data.live == nil) {
            result = result.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)))
                .cropped(to: bounds)
        }

        Self.sharedCtx.render(result, to: outBuf,
                              bounds: bounds,
                              colorSpace: CGColorSpaceCreateDeviceRGB())
        req.finish(withComposedVideoFrame: outBuf)
    }
}

// MARK: - Export CIContext

enum ExportCIContext {
    static let shared: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()
}
