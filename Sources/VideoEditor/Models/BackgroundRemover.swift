// BackgroundRemover.swift
// 去除图片背景。两条路自动二选一：
//   · 纯色底（白底图、绿幕、AI 出图）→ 色键 + 边缘连通域
//   · 复杂背景 → 系统 Vision 语义分割
// 分开走是因为 Vision 做的是「找显著主体」：白底图里猫躺在手掌上，它只认猫，
// 手掌会被当背景抠掉。这种图靠颜色判断反而准得多。
// 两条路都用系统能力，不引第三方权重，没有 BiRefNet / RMBG 那类的商用授权问题。
import Foundation
import Vision
import AppKit
import CoreImage

enum BackgroundRemover {

    /// 抠图方式。由右键菜单直接指定 —— 自动判定在主体占满画面（边框几乎没有背景色）
    /// 或背景带渐变时会误判，与其猜不如让用户选
    enum Mode: String, CaseIterable {
        case auto
        case subject
        case solid

        var label: String {
            switch self {
            case .auto:    return "自动"
            case .subject: return "智能识别主体"
            case .solid:   return "纯色背景"
            }
        }
    }

    /// 抠图模型
    enum Engine: String, CaseIterable {
        case system
        case biRefNet

        var label: String {
            switch self {
            case .system:   return "系统内置"
            case .biRefNet: return "AI 抠图"
            }
        }

        var hint: String {
            switch self {
            case .system:   return "macOS 自带能力（Vision + 色键），不用下载模型"
            case .biRefNet: return "开源抠图模型，细节更好，需要先下载权重"
            }
        }

        /// 需要下载模型才能用
        var needsDownload: Bool { self == .biRefNet }
    }

    enum RemoveError: Error, LocalizedError {
        case loadFailed
        case noSubject
        case renderFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed:         return "无法读取图片文件"
            case .noSubject:          return "没有识别到主体，无法去除背景"
            case .renderFailed:       return "抠图结果渲染失败"
            case .writeFailed(let d): return d.isEmpty ? "写入文件失败" : "写入文件失败：\(d)"
            }
        }
    }

    /// 去背结果的存放目录，跟截图一样放在项目目录下
    static var outputDir: URL {
        AppSettings.shared.effectiveProjectDir.appendingPathComponent("去背", isDirectory: true)
    }

    // MARK: - 调参
    /// 图像边框上有多少比例的像素接近同一个颜色，就认定是纯色底。
    /// 实测：白底插画 82.7%，两张复杂背景插画 1.5% / 18.0%，中间余量很大
    private static let solidBorderRatio = 0.70
    /// 与背景色的曼哈顿距离：低于 tLow 全透明，高于 tHigh 全保留，中间是半透明过渡带。
    /// tHigh 同时是 flood fill 的停止阈值，往上调会让米色手掌那类浅色主体被当背景灌进去
    /// （实测 dist=95 的浅色块在 tHigh=140 下 alpha 掉到 197），所以只能压不能放。
    private static let tLow = 6
    private static let tHigh = 90
    /// 过渡带的 alpha 曲线。<1 抬高中间段，让贴近背景色的细毛保住可见的不透明度 ——
    /// 靠这条曲线而不是靠放宽 tHigh 来救发丝，才不会误伤浅色主体
    private static let alphaGamma = 0.5

    /// 抠出主体存成 PNG，返回新文件地址。推理和 flood fill 都在后台线程跑
    static func removeBackground(from url: URL, outputName: String,
                                 mode: Mode = .auto,
                                 onStage: (@Sendable (ProjectState.RemoveBackgroundState) -> Void)? = nil) async throws -> URL {
        let cgImage = try loadCGImage(url)
        let (engine, biRefNet) = await MainActor.run {
            (AppSettings.shared.bgRemovalEngine, AppSettings.shared.biRefNetModel)
        }

        let png = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            // 选了 BiRefNet 就一律走它 —— 右键那边也相应不再给方式选项，
            // 免得出现「选了 BiRefNet 却走色键、结果和内置一模一样」这种说不通的组合
            if engine == .biRefNet {
                return try biRefNetCutout(cgImage, model: biRefNet, onStage: onStage)
            }
            onStage?(.processing)
            switch mode {
            case .subject:
                return try visionCutout(cgImage)
            case .solid:
                // 用户指定了就不再判定，哪怕边框看着不像纯色底也照做
                guard let keyed = try solidColorCutout(cgImage, force: true) else {
                    throw RemoveError.renderFailed
                }
                return keyed
            case .auto:
                // 纯色底优先，判定不成立才交给 Vision
                if let keyed = try solidColorCutout(cgImage) { return keyed }
                return try visionCutout(cgImage)
            }
        }.value

        onStage?(.composing)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let dest = uniqueURL(for: outputName)
        do {
            try png.write(to: dest)
        } catch {
            throw RemoveError.writeFailed(error.localizedDescription)
        }
        return dest
    }

    // MARK: - 纯色底：色键 + 边缘连通域

    /// 判定为纯色底就返回抠好的 PNG，否则返回 nil 交给 Vision。force 为真时跳过判定直接抠。
    /// 只抠「与图像边框连通」的背景色区域 —— 主体内部的同色部分（猫眼高光、白色衣服）不会被穿孔
    private static func solidColorCutout(_ cg: CGImage, force: Bool = false) throws -> Data? {
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 1. 边框像素的颜色中位数当作背景色
        var border: [Int] = []
        border.reserveCapacity((w + h) * 2)
        for x in 0..<w { border.append(x * 4); border.append(((h - 1) * w + x) * 4) }
        for y in 0..<h { border.append((y * w) * 4); border.append((y * w + w - 1) * 4) }

        var rs = border.map { Int(px[$0]) }
        var gs = border.map { Int(px[$0 + 1]) }
        var bs = border.map { Int(px[$0 + 2]) }
        rs.sort(); gs.sort(); bs.sort()
        let bgR = rs[rs.count / 2], bgG = gs[gs.count / 2], bgB = bs[bs.count / 2]

        @inline(__always) func dist(_ i: Int) -> Int {
            abs(Int(px[i]) - bgR) + abs(Int(px[i + 1]) - bgG) + abs(Int(px[i + 2]) - bgB)
        }

        // 2. 边框上有多少像素就是这个背景色 —— 纯色底的决定性特征
        if !force {
            let near = border.reduce(0) { $0 + (dist($1) < tLow ? 1 : 0) }
            guard Double(near) / Double(border.count) >= solidBorderRatio else { return nil }
        }

        // 3. 从四边灌进去，只标记连通的背景
        var isBg = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(w * h / 4)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let p = stack.popLast() {
            if isBg[p] || dist(p * 4) > tHigh { continue }
            isBg[p] = true
            let x = p % w, y = p / w
            if x > 0     { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0     { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }

        // 4. 写 alpha：过渡带按距离软化，并把边缘像素里混进来的背景色反解掉
        for p in 0..<(w * h) where isBg[p] {
            let i = p * 4
            let d = dist(i)
            guard d > tLow else {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
                continue
            }
            let t = Double(d - tLow) / Double(tHigh - tLow)
            let a = min(255, Int(pow(t, alphaGamma) * 255))
            let alpha = Double(a) / 255.0
            let bg = [bgR, bgG, bgB]
            for k in 0..<3 {
                var fg = Double(px[i + k])
                // 观察色 = α·前景 + (1-α)·背景，反解出前景本色，
                // 否则半透明边缘会挂一层原背景色（白底上就是一圈白晕）
                if alpha > 0.02 {
                    fg = ((fg - (1 - alpha) * Double(bg[k])) / alpha).clamped(to: 0...255)
                }
                // premultipliedLast：存的必须是乘过 alpha 的值
                px[i + k] = UInt8(fg * alpha)
            }
            px[i + 3] = UInt8(a)
        }

        guard let outCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let outImg = outCtx.makeImage(),
              let data = NSBitmapImageRep(cgImage: outImg).representation(using: .png, properties: [:]) else {
            throw RemoveError.renderFailed
        }
        return data
    }

    // MARK: - BiRefNet

    private static func biRefNetCutout(_ cg: CGImage, model: BiRefNetModel,
                                       onStage: (@Sendable (ProjectState.RemoveBackgroundState) -> Void)?) throws -> Data {
        let out = try BiRefNetSegmenter.removeBackground(cgImage: cg, model: model, onStage: onStage)
        guard let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            throw RemoveError.renderFailed
        }
        return data
    }

    // MARK: - 复杂背景：Vision 语义分割

    private static func visionCutout(_ cg: CGImage) throws -> Data {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw RemoveError.noSubject
        }
        // croppedToInstancesExtent: false —— 保持原尺寸，时间轴上的位置/缩放属性才能直接沿用
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                    from: handler,
                                                    croppedToInstancesExtent: false)
        // PNG 才能保住 alpha，JPEG 会把透明区压成黑底
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let data = CIContext().pngRepresentation(of: ci, format: .RGBA8,
                                                       colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw RemoveError.renderFailed
        }
        return data
    }

    // MARK: - Helpers

    /// 读图并把 EXIF 方向真正应用到像素上。
    /// CGImageSourceCreateImageAtIndex 拿到的是未旋转的原始像素，手机照片常带 orientation tag，
    /// 直接送进 Vision 等于让它认一张躺倒的图，主体会识别不全
    private static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RemoveError.loadFailed
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard raw != 1, let orientation = CGImagePropertyOrientation(rawValue: raw) else {
            return img
        }
        let ci = CIImage(cgImage: img).oriented(orientation)
        guard let fixed = CIContext().createCGImage(ci, from: ci.extent) else { return img }
        return fixed
    }

    /// 同名文件已存在就往后排序号，避免重复去背时互相覆盖
    private static func uniqueURL(for name: String) -> URL {
        let base = "\(name)_去背"
        var candidate = outputDir.appendingPathComponent("\(base).png")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("\(base)\(i).png")
            i += 1
        }
        return candidate
    }
}
