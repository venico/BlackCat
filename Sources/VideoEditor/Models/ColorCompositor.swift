// ColorCompositor.swift
import AVFoundation
import CoreImage
import ObjectiveC

// MARK: - ColorAdjust

struct ColorAdjust: Codable, Equatable {
    var brightness: Double = 0   // -1 ~ 1
    var contrast:   Double = 0   // -1 ~ 1
    var saturation: Double = 0   // -1 ~ 1
    var hue:        Double = 0   // degrees -180 ~ 180

    var isIdentity: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && abs(hue) < 0.01
    }
    static let identity = ColorAdjust()

    static func apply(_ img: CIImage, _ adj: ColorAdjust) -> CIImage {
        guard !adj.isIdentity else { return img }
        var out = img
        if adj.brightness != 0 || adj.contrast != 0 || adj.saturation != 0 {
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(out,                                    forKey: kCIInputImageKey)
                f.setValue(NSNumber(value: adj.brightness),        forKey: kCIInputBrightnessKey)
                f.setValue(NSNumber(value: 1.0 + adj.contrast),    forKey: kCIInputContrastKey)
                f.setValue(NSNumber(value: 1.0 + adj.saturation),  forKey: kCIInputSaturationKey)
                if let o = f.outputImage { out = o }
            }
        }
        if abs(adj.hue) > 0.01 {
            if let f = CIFilter(name: "CIHueAdjust") {
                f.setValue(out, forKey: kCIInputImageKey)
                f.setValue(NSNumber(value: Float(adj.hue * .pi / 180.0)), forKey: kCIInputAngleKey)
                if let o = f.outputImage { out = o }
            }
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
    var rotation: Int = 0
    var naturalSize: CGSize?
    /// 素材自带的方向（手机竖拍视频 naturalSize 是横的，靠它转正）。
    /// AVFoundation 只在**没有**自定义 compositor 时才自动应用 preferredTransform，
    /// 我们用了 ColorCompositor，就得自己来 —— 不然画布按转正后的竖尺寸算、
    /// 画面却还是横着铺，就是「画布竖的、视频横的」
    var sourceTransform: CGAffineTransform = .identity
    var opacityRamp: (from: Float,  to: Float,  start: Double, end: Double)?
    var pushRamp:    (dx: CGFloat, dy: CGFloat, isA: Bool, start: Double, end: Double)?
    var zoomRamp:    (from: CGFloat, to: CGFloat, start: Double, end: Double)?

    func effectiveOpacity(at t: Double) -> Float {
        guard let r = opacityRamp else { return 1.0 }
        let frac = Float((t - r.start) / max(r.end - r.start, 1e-6))
        return r.from + (r.to - r.from) * Swift.max(0, Swift.min(1, frac))
    }

    /// 根据实际 source buffer 尺寸在 render 空间中计算 CIImage 变换。
    /// 公式和导出 videoTransform 一致（y-down 语义），由 ColorCompositor 统一做 y 翻转。
    func fitTransform(srcSize: CGSize, renderSize: CGSize, at t: Double) -> CGAffineTransform {
        guard srcSize.width > 0, srcSize.height > 0 else { return .identity }
        let baseScale = min(renderSize.width / srcSize.width, renderSize.height / srcSize.height)
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
        return result
    }
}

// MARK: - ColorCompositionData

final class ColorCompositionData: NSObject {
    var entries:    [CompositorTrackEntry] = []
    var renderSize: CGSize = .zero
}

// AVMutableVideoCompositionInstruction extension（仅用于其他代码兼容）
private var colorCompositionDataKey: UInt8 = 0
extension AVMutableVideoCompositionInstruction {
    var colorData: ColorCompositionData? {
        get { objc_getAssociatedObject(self, &colorCompositionDataKey) as? ColorCompositionData }
        set { objc_setAssociatedObject(self, &colorCompositionDataKey, newValue,
                                       .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - ColorCompositor
// 用静态字典存 composition data，以 segment 起始 CMTime value（timescale=600）为 key。
// 不依赖 associated object，避免 AVFoundation 内部 copy instruction 时丢失数据。

final class ColorCompositor: NSObject, AVVideoCompositing {

    // 静态数据存储（线程安全）
    private static let lock = NSLock()
    private static var store: [Int64: ColorCompositionData] = [:]
    private static var dragOffsets: [CMPersistentTrackID: (x: CGFloat, y: CGFloat)] = [:]
    /// 拖色调滑块时的实时覆盖值。走这条就不用重建整个 composition ——
    /// 重建要重新 load playerItem，代价大到只能防抖，表现就是"松手才变"
    private static var liveColorAdjusts: [CMPersistentTrackID: ColorAdjust] = [:]

    /// 注册一个 segment 的数据（在 rebuildTimelinePreview 主线程调用）
    static func setData(_ data: ColorCompositionData, forStartValue key: Int64) {
        lock.lock(); defer { lock.unlock() }
        store[key] = data
    }

    /// 重建前清空旧数据
    static func clearStore() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
        dragOffsets.removeAll()
        liveColorAdjusts.removeAll()
    }

    static func setDragOffset(trackID: CMPersistentTrackID, offsetX: CGFloat, offsetY: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        dragOffsets[trackID] = (offsetX, offsetY)
    }

    static func clearDragOffsets() {
        lock.lock(); defer { lock.unlock() }
        dragOffsets.removeAll()
    }

    /// 色调滑块拖动中的实时值。配合 `clock.refreshSeekRequest` 的 jitter seek
    /// 逼播放器重绘当前帧，滑块就跟图片一样即时响应
    static func setLiveColorAdjust(trackID: CMPersistentTrackID, _ adj: ColorAdjust) {
        lock.lock(); defer { lock.unlock() }
        liveColorAdjusts[trackID] = adj
    }

    static func clearLiveColorAdjusts() {
        lock.lock(); defer { lock.unlock() }
        liveColorAdjusts.removeAll()
    }

    private static func getLiveColorAdjust(trackID: CMPersistentTrackID) -> ColorAdjust? {
        lock.lock(); defer { lock.unlock() }
        return liveColorAdjusts[trackID]
    }

    private static func getDragOffset(trackID: CMPersistentTrackID) -> (x: CGFloat, y: CGFloat)? {
        lock.lock(); defer { lock.unlock() }
        return dragOffsets[trackID]
    }

    private static func getData(for timeRange: CMTimeRange) -> ColorCompositionData? {
        // 以 timescale=600 的 start.value 为 key
        let key = CMTimeConvertScale(timeRange.start, timescale: 600, method: .default).value
        lock.lock(); defer { lock.unlock() }
        return store[key]
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

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        let instrRange = req.videoCompositionInstruction.timeRange
        guard let data = Self.getData(for: instrRange) else {
            // 无自定义数据：透传第一个 source frame（自动 fit-to-output）
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

        var result: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: bounds)

        for var entry in data.entries {
            guard let srcBuf = req.sourceFrame(byTrackID: entry.trackID) else { continue }

            if let drag = Self.getDragOffset(trackID: entry.trackID) {
                entry.userOffsetX = drag.x
                entry.userOffsetY = drag.y
            }
            if let live = Self.getLiveColorAdjust(trackID: entry.trackID) {
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
                renderSize: renderSize, at: t)
            ci = ci.transformed(by: fitT)

            // 5. 不透明度
            let op = entry.effectiveOpacity(at: t)
            if op < 0.999 {
                ci = ci.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(op))
                ])
            }

            // 6. 裁到 render 边界
            ci = ci.cropped(to: bounds)

            // 7. 叠加
            result = ci.composited(over: result)
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
