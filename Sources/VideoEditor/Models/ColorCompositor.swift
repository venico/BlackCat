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
    let userOffsetX: CGFloat
    let userOffsetY: CGFloat
    let cropTop:     CGFloat
    let cropBottom:  CGFloat
    let cropLeft:    CGFloat
    let cropRight:   CGFloat
    let colorAdjust: ColorAdjust
    var opacityRamp: (from: Float,  to: Float,  start: Double, end: Double)?
    var pushRamp:    (dx: CGFloat, dy: CGFloat, isA: Bool, start: Double, end: Double)?
    // 缩放转场：以画面中心为锚的整体缩放比例渐变（zoom）
    var zoomRamp:    (from: CGFloat, to: CGFloat, start: Double, end: Double)?

    func effectiveOpacity(at t: Double) -> Float {
        guard let r = opacityRamp else { return 1.0 }
        let frac = Float((t - r.start) / max(r.end - r.start, 1e-6))
        return r.from + (r.to - r.from) * Swift.max(0, Swift.min(1, frac))
    }

    /// 根据实际 source buffer 尺寸（裁剪后）在 render 空间中计算 CIImage 变换。
    func fitTransform(srcSize: CGSize, renderSize: CGSize, at t: Double) -> CGAffineTransform {
        guard srcSize.width > 0, srcSize.height > 0 else { return .identity }
        let baseScale = min(renderSize.width / srcSize.width, renderSize.height / srcSize.height)
        let sx = baseScale * userScaleX
        let sy = baseScale * userScaleY
        let tx = (renderSize.width  - srcSize.width  * sx) / 2 + userOffsetX * renderSize.width
        let ty = (renderSize.height - srcSize.height * sy) / 2 + userOffsetY * renderSize.height
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

    /// 注册一个 segment 的数据（在 rebuildTimelinePreview 主线程调用）
    static func setData(_ data: ColorCompositionData, forStartValue key: Int64) {
        lock.lock(); defer { lock.unlock() }
        store[key] = data
    }

    /// 重建前清空旧数据
    static func clearStore() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
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
                req.finish(with: NSError(domain: "ColorCompositor", code: 1, userInfo: nil))
            }
            return
        }

        guard let outBuf = req.renderContext.newPixelBuffer() else {
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

        for entry in data.entries {
            guard let srcBuf = req.sourceFrame(byTrackID: entry.trackID) else { continue }

            let srcW = CGFloat(CVPixelBufferGetWidth(srcBuf))
            let srcH = CGFloat(CVPixelBufferGetHeight(srcBuf))
            var ci = CIImage(cvPixelBuffer: srcBuf)

            // 1. 色调
            if !entry.colorAdjust.isIdentity {
                ci = ColorAdjust.apply(ci, entry.colorAdjust)
            }

            // 2. 裁剪
            var efW = srcW, efH = srcH
            if entry.cropTop > 0.001 || entry.cropBottom > 0.001 ||
               entry.cropLeft > 0.001 || entry.cropRight > 0.001 {
                let cx = srcW * entry.cropLeft
                let cy = srcH * entry.cropTop
                let cw = max(1, srcW * (1 - entry.cropLeft - entry.cropRight))
                let ch = max(1, srcH * (1 - entry.cropTop  - entry.cropBottom))
                ci = ci.cropped(to: CGRect(x: cx, y: cy, width: cw, height: ch))
                    .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
                efW = cw; efH = ch
            }

            // 3. Fit + push 转场偏移
            ci = ci.transformed(by: entry.fitTransform(
                srcSize: CGSize(width: efW, height: efH),
                renderSize: renderSize, at: t))

            // 4. 不透明度
            let op = entry.effectiveOpacity(at: t)
            if op < 0.999 {
                ci = ci.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(op))
                ])
            }

            // 5. 裁到 render 边界
            ci = ci.cropped(to: bounds)

            // 6. 叠加
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
