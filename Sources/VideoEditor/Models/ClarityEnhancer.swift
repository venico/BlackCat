// ClarityEnhancer.swift
// FSRCNN 的 CoreML 推理。模型只处理 Y（亮度）通道，固定吃 256x256 单通道输入
// （转换时的 trace 尺寸）。更大的图需要切 tile 分块推理再拼接，Cb/Cr 通道走
// 双线性插值放大（不过模型），最后跟放大后的 Y 合并转回 RGB。
// tile 之间留 16px 重叠区域，取中心部分拼接，避免每块边缘因为缺乏上下文
// 导致的细节劣化在拼接处形成可见接缝。
import Foundation
import CoreML
import CoreImage
import AppKit
import Accelerate

enum ClarityEnhancer {

    static let tileSize = 256
    static let tileOverlap = 16

    enum EnhanceError: Error, LocalizedError {
        case modelMissing
        case loadFailed(String)
        case inferenceFailed(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing:          return "还没下载清晰度提升模型，请到设置 → 视频里下载"
            case .loadFailed(let d):     return "模型加载失败：\(d)"
            case .inferenceFailed(let d): return "超分辨率推理失败：\(d)"
            case .badOutput:             return "模型输出格式不符合预期"
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cached: (path: String, model: MLModel)?

    /// Task 3 实测（真实权重模型，非探索阶段随机权重）：x4 与 x2 均 .cpuAndGPU 更快
    /// （x4: 1.58ms vs .all 的 3.04ms；x2: 1.55ms vs .all 的 1.94ms）。
    /// 探索阶段曾用随机权重模型测出相反结论，但那个模型是 ImageType(RGB) 接口，
    /// 跟正式模型的 MultiArray(Y通道) 接口不是同一回事，数字不可比，已废弃。
    private static func computeUnits() -> MLComputeUnits {
        .cpuAndGPU
    }

    private static func model(at url: URL, modelKind: ClarityModel) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits()
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            cached = (url.path, m)
            return m
        } catch {
            throw EnhanceError.loadFailed(error.localizedDescription)
        }
    }

    /// 单张图片超分辨率放大。onTileProgress 在每个 tile 处理完后回调（0...1），交给上层显示进度
    static func enhance(cgImage: CGImage, model modelKind: ClarityModel,
                       onTileProgress: ((Double) -> Void)? = nil) throws -> CGImage {
        let w = cgImage.width, h = cgImage.height
        let scale = modelKind == .x2 ? 2 : 4
        let rgba = try readRGBA(from: cgImage)
        let out = try enhanceRGBA(rgba, width: w, height: h, model: modelKind,
                                  onTileProgress: onTileProgress)
        return try makeCGImage(rgba: out, width: w * scale, height: h * scale)
    }

    /// 跟 enhance(cgImage:) 同一条处理链路，但直接吃/吐紧密排列的 RGBA8888 字节
    /// （每像素 4 字节、行间无 padding）。给管道式流水线用：ffmpeg 那头本来就是
    /// rawvideo 裸字节，走这个接口可以完全不碰 CGImage / 图片编解码。
    static func enhanceRGBA(_ rgba: [UInt8], width w: Int, height h: Int,
                            model modelKind: ClarityModel,
                            onTileProgress: ((Double) -> Void)? = nil) throws -> [UInt8] {
        guard modelKind.isDownloaded else { throw EnhanceError.modelMissing }
        let mlModel = try model(at: modelKind.localURL, modelKind: modelKind)
        let scale = modelKind == .x2 ? 2 : 4

        let (yPlane, cbPlane, crPlane) = rgbaToYCbCr(rgba, width: w, height: h)
        let enhancedY = try enhanceYPlane(yPlane, width: w, height: h, scale: scale,
                                         mlModel: mlModel, onTileProgress: onTileProgress)
        let enhancedCb = upsampleBilinear(cbPlane, width: w, height: h, scale: scale)
        let enhancedCr = upsampleBilinear(crPlane, width: w, height: h, scale: scale)
        return yCbCrToRGBA(y: enhancedY, cb: enhancedCb, cr: enhancedCr,
                           width: w * scale, height: h * scale)
    }

    // MARK: - 色彩空间转换

    /// RGB -> Y/Cb/Cr 三个 Float 平面（0...1 范围）。
    /// 系数跟 OpenCV cv2.COLOR_BGR2YCrCb 一致（full-range BT.601），
    /// 这是 Task 2 Python 验证阶段用的同一套系数，Swift 这边必须保持一致，
    /// 否则色彩空间转换本身的误差会跟"模型推理是否正确"混在一起没法区分。
    /// 把 CGImage 画进紧密排列的 RGBA8888 缓冲区（行间无 padding），供下面两条
    /// 路径共用：CGImage 入口先转成裸字节，管道入口本来就是裸字节
    private static func readRGBA(from cgImage: CGImage) throws -> [UInt8] {
        let w = cgImage.width, h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EnhanceError.inferenceFailed("RGB 读取上下文创建失败")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return rgba
    }

    private static func rgbaToYCbCr(_ rgba: [UInt8], width w: Int, height h: Int)
        -> (y: [Float], cb: [Float], cr: [Float]) {

        // 下面整段是原先那个逐像素 for 循环的 vDSP 向量化版本，公式和系数逐字未变。
        // 换掉的理由：实测这个函数在 640x480 单帧要 43ms，而同一帧里真正的 CoreML
        // 推理只要 18ms——纯标量循环的色彩空间转换比模型本身还贵。
        let n = w * h
        let count = vDSP_Length(n)

        // 从交错的 RGBA8888 里按 stride 4 直接抽出三个 float 平面（0...255 量纲），
        // 一步同时完成"拆通道"和"转 float"
        var r = [Float](repeating: 0, count: n)
        var g = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            vDSP_vfltu8(base,     4, &r, 1, count)
            vDSP_vfltu8(base + 1, 4, &g, 1, count)
            vDSP_vfltu8(base + 2, 4, &b, 1, count)
        }

        // Y = 0.299R + 0.587G + 0.114B
        var y = [Float](repeating: 0, count: n)
        var kR: Float = 0.299, kG: Float = 0.587, kB: Float = 0.114
        vDSP_vsmul(r, 1, &kR, &y, 1, count)
        vDSP_vsma(g, 1, &kG, y, 1, &y, 1, count)
        vDSP_vsma(b, 1, &kB, y, 1, &y, 1, count)

        // Cr = (R - Y) * 0.713 + 128 ；Cb = (B - Y) * 0.564 + 128
        // 注意 vDSP_vsub(A,_,B,_,C,_) 算的是 C = B - A，所以要算 R-Y 得把 y 放 A 位
        var cr = [Float](repeating: 0, count: n)
        var cb = [Float](repeating: 0, count: n)
        var kCr: Float = 0.713, kCb: Float = 0.564, bias: Float = 128
        vDSP_vsub(y, 1, r, 1, &cr, 1, count)
        vDSP_vsmsa(cr, 1, &kCr, &bias, &cr, 1, count)
        vDSP_vsub(y, 1, b, 1, &cb, 1, count)
        vDSP_vsmsa(cb, 1, &kCb, &bias, &cb, 1, count)

        // 三个平面统一归一化到 0...1。用 vsdiv（除以 255）而不是 vsmul（乘 1/255）：
        // 1/255 在 float32 里不能精确表示，乘倒数跟原先的 `/ 255.0` 会有最后一位的
        // 差异，除法则与原实现逐位一致
        var c255: Float = 255
        vDSP_vsdiv(y,  1, &c255, &y,  1, count)
        vDSP_vsdiv(cb, 1, &c255, &cb, 1, count)
        vDSP_vsdiv(cr, 1, &c255, &cr, 1, count)

        return (y, cb, cr)
    }

    /// Y/Cb/Cr 平面（0...1 范围，已是目标尺寸）合并成紧密排列的 RGBA8888 字节
    private static func yCbCrToRGBA(y: [Float], cb: [Float], cr: [Float], width: Int, height: Int) -> [UInt8] {
        // 同样是原逐像素循环的 vDSP 向量化版本，公式和系数未变（原实现见 git 历史）。
        // 唯一的数值差异来源：下面用乘倒数（* 1/0.713）代替原来的除法（/ 0.713），
        // 1/0.713 在 float32 里有约 1e-7 的相对误差，作用在最大 127 的色差分量上是
        // 约 1e-5 的绝对误差，远小于最后 uint8 量化的 0.5 步长，实测输出逐字节一致。
        let n = width * height
        let count = vDSP_Length(n)

        // 还原量纲：yy ∈ 0...255，cbb/crr ∈ -128...127
        var yy = [Float](repeating: 0, count: n)
        var cbb = [Float](repeating: 0, count: n)
        var crr = [Float](repeating: 0, count: n)
        var c255: Float = 255, zero: Float = 0, negBias: Float = -128
        vDSP_vsmsa(y,  1, &c255, &zero,    &yy,  1, count)
        vDSP_vsmsa(cb, 1, &c255, &negBias, &cbb, 1, count)
        vDSP_vsmsa(cr, 1, &c255, &negBias, &crr, 1, count)

        // r = Y + Cr/0.713 ；b = Y + Cb/0.564 ；g = (Y - 0.299r - 0.114b)/0.587
        var r = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        var g = [Float](repeating: 0, count: n)
        var kCrInv: Float = 1.0 / 0.713, kCbInv: Float = 1.0 / 0.564
        vDSP_vsma(crr, 1, &kCrInv, yy, 1, &r, 1, count)
        vDSP_vsma(cbb, 1, &kCbInv, yy, 1, &b, 1, count)
        var kNegR: Float = -0.299, kNegB: Float = -0.114, kG: Float = 0.587
        vDSP_vsma(r, 1, &kNegR, yy, 1, &g, 1, count)
        vDSP_vsma(b, 1, &kNegB, g,  1, &g, 1, count)
        vDSP_vsdiv(g, 1, &kG, &g, 1, count)

        // clamp 到 0...255，再 round 成 uint8 直接写进交错 RGBA 的对应字节位。
        // vDSP_vfixru8 的 'r' 就是 round（vDSP_vfixu8 才是截断），与原来的 .rounded() 对应
        var lo: Float = 0, hi: Float = 255
        vDSP_vclip(r, 1, &lo, &hi, &r, 1, count)
        vDSP_vclip(g, 1, &lo, &hi, &g, 1, count)
        vDSP_vclip(b, 1, &lo, &hi, &b, 1, count)

        // 初值 255 铺满，stride 4 只写 byte0/1/2，alpha（byte3）保持 255 不动
        var rgba = [UInt8](repeating: 255, count: n * 4)
        rgba.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            vDSP_vfixru8(r, 1, base,     4, count)
            vDSP_vfixru8(g, 1, base + 1, 4, count)
            vDSP_vfixru8(b, 1, base + 2, 4, count)
        }
        return rgba
    }

    /// 把紧密排列的 RGBA8888 字节包成 CGImage（只给 enhance(cgImage:) 这条入口用；
    /// 管道路径全程不需要走这一步）
    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else {
            throw EnhanceError.badOutput
        }
        return img
    }

    /// Cb/Cr 通道用高质量重采样放大（不过模型，人眼对色度细节不敏感，这是 FSRCNN
    /// 原论文和 OpenCV dnn_superres 的标准做法）。
    ///
    /// 原实现走的是 float → uint8 → CGImage → CGContext.draw(插值) → uint8 → float
    /// 一整圈，两次 8bit 量化 + 两次逐像素标量循环，实测 640x480 单帧两次调用共
    /// 310ms（比 CoreML 推理本身还贵 17 倍）。vImageScale_PlanarF 直接在 float 域
    /// 上重采样，既省掉那一圈往返，也不再有中间的 8bit 精度损失（对最终画质是
    /// 只增不减）。函数名保留 Bilinear 是为了不动调用方，实际重采样质量由
    /// kvImageHighQualityResampling 决定，与原先 CGContext 的 .high 同档。
    private static func upsampleBilinear(_ plane: [Float], width: Int, height: Int, scale: Int) -> [Float] {
        let dstW = width * scale, dstH = height * scale
        let fallback = Array(repeating: Float(0.5), count: dstW * dstH)
        guard width > 0, height > 0 else { return fallback }

        var src = plane
        var result = [Float](repeating: 0, count: dstW * dstH)
        let status: vImage_Error = src.withUnsafeMutableBufferPointer { s in
            guard let sBase = s.baseAddress else { return kvImageNullPointerArgument }
            var srcBuf = vImage_Buffer(data: sBase,
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: width * MemoryLayout<Float>.stride)
            return result.withUnsafeMutableBufferPointer { d in
                guard let dBase = d.baseAddress else { return kvImageNullPointerArgument }
                var dstBuf = vImage_Buffer(data: dBase,
                                           height: vImagePixelCount(dstH),
                                           width: vImagePixelCount(dstW),
                                           rowBytes: dstW * MemoryLayout<Float>.stride)
                return vImageScale_PlanarF(&srcBuf, &dstBuf, nil,
                                           vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard status == kvImageNoError else { return fallback }

        // 必须 clamp 回 [0,1]：高质量重采样是 Lanczos 类的，在锐利边缘会 overshoot。
        // 实测一张 [0.05,0.95] 的硬边棋盘格放大后跑到 [-0.178,1.178]，18.6% 的像素
        // 越界。原实现经 uint8 中转天然被截断，这里在 float 域必须显式补回来——
        // 否则越界的色度值传到 yCbCrToRGB 会把 R/B 推出 0...255 触发 clamp，
        // 破坏"反推 Y 恒等于原 Y"的关系（实测会让 PSNR 从 52.66 掉到 52.43dB）。
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(result, 1, &lo, &hi, &result, 1, vDSP_Length(result.count))
        return result
    }

    // MARK: - Y 通道 tile 拆分 + 推理 + 拼接

    private static func enhanceYPlane(_ yPlane: [Float], width w: Int, height h: Int, scale: Int,
                                      mlModel: MLModel, onTileProgress: ((Double) -> Void)?) throws -> [Float] {
        let stride = tileSize - tileOverlap * 2
        var tilesX = max(1, Int(ceil(Double(w - tileOverlap * 2) / Double(stride))))
        var tilesY = max(1, Int(ceil(Double(h - tileOverlap * 2) / Double(stride))))
        if w <= tileSize { tilesX = 1 }
        if h <= tileSize { tilesY = 1 }
        let totalTiles = tilesX * tilesY

        // tile 序号 -> 原图坐标系裁剪起点。提取成函数（而不是在循环体里内联算），
        // 是因为下面算贡献区间右/下边界时，需要查询"下一个 tile"实际会用的起点——
        // 如果各自独立算，当图片尺寸不能被 stride 整除、下一个 tile 的起点被
        // clamp 到比"整齐排列"时更靠前的位置时，当前 tile 的贡献区间终点不会
        // 跟着变，会跟下一个 tile 的贡献区间起点重叠（冗余双写：不产生 gap 或
        // 可见接缝，但违背"精确裁剪、不重叠"的设计意图，且这个隐藏依赖容易被
        // 后来者踩坑）。srcXFor/srcYFor 对 tx/ty 是非递减的（clamp 只会让它提前
        // 变平，不会倒退），这保证了下面依赖它算出的贡献区间前后能精确衔接。
        func srcXFor(_ tx: Int) -> Int { min(tx * stride, max(0, w - tileSize)) }
        func srcYFor(_ ty: Int) -> Int { min(ty * stride, max(0, h - tileSize)) }

        // tile tx/ty 的贡献区间左/上边界（原图坐标系）。tx==0（或 ty==0）时不裁剪
        // ——没有前一个 tile 接管这一侧；否则裁掉靠前一侧的 overlap，只留中心可信
        // 部分。用 min(...) 兜底：cropW/cropH 比 tileOverlap 还小时（极端小图），
        // 避免算出的边界超出这个 tile 自己实际裁到的范围。
        func contribX0For(_ tx: Int) -> Int {
            let sx = srcXFor(tx)
            guard tx > 0 else { return sx }
            let cw = min(tileSize, w - sx)
            return min(sx + tileOverlap, sx + cw)
        }
        func contribY0For(_ ty: Int) -> Int {
            let sy = srcYFor(ty)
            guard ty > 0 else { return sy }
            let ch = min(tileSize, h - sy)
            return min(sy + tileOverlap, sy + ch)
        }

        var output = [Float](repeating: 0, count: w * scale * h * scale)
        var done = 0
        // 每个 tile 的 runOneTile 都会分配两个 MLMultiArray（输入+输出），1080p
        // 一帧约 45 个 tile；跟逐帧循环那层的 autoreleasepool（见
        // ProjectState+ClarityEnhance.swift runClarityEnhancePipeline）是同一个
        // 问题的两层，这里按 tile 排空能降低单帧内的峰值，不用等到整帧处理完
        // 才释放这一帧所有 tile 的临时对象
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                try autoreleasepool {
                    let srcX = srcXFor(tx)
                    let srcY = srcYFor(ty)
                    let cropW = min(tileSize, w - srcX)
                    let cropH = min(tileSize, h - srcY)

                    let padded = padTile(yPlane, srcX: srcX, srcY: srcY, cropW: cropW, cropH: cropH,
                                         fullWidth: w, fullHeight: h)
                    let outTile = try runOneTile(padded, mlModel: mlModel)  // tileSize*scale 见方

                    // 贴回输出平面：只贴这个 tile 的"贡献区间"（原图坐标系），非首个
                    // tile 丢弃靠前一侧的 overlap、非末个 tile 丢弃靠后一侧的 overlap，
                    // 只取中心可信部分——两侧都留给相邻 tile 的中心部分去覆盖，避免
                    // 每块边缘因为缺乏完整上下文导致的输出劣化被拼接进最终图像形成
                    // 可见接缝。首/尾 tile 因为没有相邻 tile 接管边界，对应那一侧不裁剪。
                    // 关键点：非末个 tile 时，contribX1/contribY1 直接复用下一个 tile
                    // 的 contribX0For/contribY0For 算出来的值，而不是从自己的
                    // srcX+cropW-overlap 独立算——这样 contribX1(tx) 恒等于
                    // contribX0(tx+1)，无论下一个 tile 的 srcX 有没有被 clamp，两个
                    // 相邻 tile 的贡献区间永远精确衔接：不重叠、不留缝，不依赖"stride
                    // 刚好整除图片宽高"这种巧合。
                    let contribX0 = contribX0For(tx)
                    let contribX1 = tx == tilesX - 1 ? srcX + cropW : contribX0For(tx + 1)
                    let contribY0 = contribY0For(ty)
                    let contribY1 = ty == tilesY - 1 ? srcY + cropH : contribY0For(ty + 1)

                    for oy in (contribY0 * scale)..<(contribY1 * scale) {
                        let localRow = oy - srcY * scale
                        let destRowStart = oy * (w * scale)
                        let srcRowStart = localRow * (tileSize * scale)
                        for ox in (contribX0 * scale)..<(contribX1 * scale) {
                            let localCol = ox - srcX * scale
                            output[destRowStart + ox] = outTile[srcRowStart + localCol]
                        }
                    }
                    done += 1
                    onTileProgress?(Double(done) / Double(totalTiles))
                }
            }
        }
        return output
    }

    /// 从整张 Y 平面裁一个 tileSize x tileSize 的块，不足的地方用边缘像素延伸补齐
    private static func padTile(_ plane: [Float], srcX: Int, srcY: Int, cropW: Int, cropH: Int,
                                fullWidth: Int, fullHeight: Int) -> [Float] {
        var tile = [Float](repeating: 0, count: tileSize * tileSize)
        for row in 0..<tileSize {
            let srcRow = min(srcY + row, fullHeight - 1)
            for col in 0..<tileSize {
                let srcCol = min(srcX + col, fullWidth - 1)
                tile[row * tileSize + col] = plane[srcRow * fullWidth + srcCol]
            }
        }
        return tile
    }

    /// 单 tile 推理：输入 tileSize x tileSize 的 Float 数组（0...1），
    /// 输出 (tileSize*scale) x (tileSize*scale) 的 Float 数组（0...1，未裁剪 clamp）
    ///
    /// 读写 MLMultiArray 一律走 dataPointer 类型化指针，不用逐元素下标访问——
    /// BiRefNetSegmenter.maskImage 早就踩过这个坑（注释原话："逐个下标访问
    /// MLMultiArray 在百万像素级别慢得离谱"）：MLMultiArray 的 subscript 每次
    /// 都要过一遍 Objective-C bridging 装箱/拆箱，x2 单 tile 输出有
    /// 512x512=262144 个元素、x4 有 1024x1024=1048576 个，逐元素访问的开销
    /// 会盖过模型推理本身。实测 `mlModel.prediction(from:)` 只要 1.5~3ms/tile
    /// （跟 Task 3 benchmark 吻合），而一次逐元素读输出就要 ~120ms。
    private static func runOneTile(_ tile: [Float], mlModel: MLModel) throws -> [Float] {
        guard let inputArray = try? MLMultiArray(shape: [1, 1, NSNumber(value: tileSize), NSNumber(value: tileSize)],
                                                 dataType: .float32) else {
            throw EnhanceError.inferenceFailed("输入 MLMultiArray 创建失败")
        }
        let inPtr = inputArray.dataPointer.bindMemory(to: Float32.self, capacity: tile.count)
        for i in 0..<tile.count { inPtr[i] = tile[i] }

        let inputName = mlModel.modelDescription.inputDescriptionsByName.keys.first ?? "input_y"
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
        } catch {
            throw EnhanceError.inferenceFailed(error.localizedDescription)
        }
        let result: MLFeatureProvider
        do {
            result = try mlModel.prediction(from: provider)
        } catch {
            throw EnhanceError.inferenceFailed(error.localizedDescription)
        }
        guard let outName = mlModel.modelDescription.outputDescriptionsByName.keys.first,
              let outArray = result.featureValue(for: outName)?.multiArrayValue else {
            throw EnhanceError.badOutput
        }
        return try readMultiArrayFast(outArray)
    }

    /// 把模型输出的 MLMultiArray 批量读成 [Float]，三个分支都走 dataPointer
    /// 类型化指针/批量转换（见 runOneTile 顶部注释），不逐元素 subscript 装箱。
    ///
    /// **float16 是 FSRCNN 的常态路径，不是兜底分支**：coremltools 转出的
    /// mlprogram 默认用 FP16 存权重和中间结果，输出的 MLMultiArray dataType
    /// 实测就是 `.float16`（rawValue 65552），哪怕 `ct.TensorType` 没有显式
    /// 指定精度。这个二进制布局是 IEEE 754 半精度标准，可以直接用 vImage 批量
    /// 转换到 Float32，不需要先造一个 float32 的 MLMultiArray 中转。
    ///
    /// 早先这里写的是"借 MLMultiArray(shape:dataType:) 转成 float32 再读"，
    /// 那条路径每个元素都要过一次 subscript 装箱，x2 单 tile 实测 122ms；
    /// 换成 bindMemory 后是 24ms（5 倍提速），两种读法的输出数值逐元素比对
    /// 完全一致（最大差异 0），确认只是读取方式变快、不影响数值。
    ///
    /// bindMemory 当时用的是 Swift 的 `Float16` 标量类型逐元素转换——这个类型
    /// 在 x86_64 macOS 上不可用（`error: 'Float16' is unavailable in macOS`，
    /// 只在 arm64 编译通过）。当前两个部署 bundle 都是 arm64，不影响出货，但
    /// App Store 的 Xcode 工程用默认 ARCHS_STANDARD（含 x86_64 的 Universal
    /// Binary），一旦这个文件被那边引用就是硬编译错误。改用下面的
    /// vImageConvert_Planar16FtoPlanarF：跨架构可用，且是向量化的批量转换，不再
    /// 是逐元素标量循环。half-precision 的二进制布局是标准的 IEEE 754（vImage
    /// 头文件原话："identical to OpenEXR"），跟 Swift Float16 位布局完全一致，
    /// 转换结果数值上没有差异——回归探针见
    /// ClarityEnhancerTests.testEnhanceMatchesPythonReference，换成 vImage
    /// 前后 PSNR/MAE 必须分毫不差。
    private static func readMultiArrayFast(_ array: MLMultiArray) throws -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count { out[i] = p[i] }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { out[i] = Float(p[i]) }
        case .float16:
            var src = vImage_Buffer(data: array.dataPointer, height: 1,
                                    width: vImagePixelCount(count), rowBytes: count * 2)
            var converted: vImage_Error = kvImageNoError
            out.withUnsafeMutableBufferPointer { buf in
                var dst = vImage_Buffer(data: UnsafeMutableRawPointer(buf.baseAddress!), height: 1,
                                        width: vImagePixelCount(count), rowBytes: count * 4)
                converted = vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
            guard converted == kvImageNoError else { throw EnhanceError.badOutput }
        default:
            throw EnhanceError.badOutput
        }
        return out
    }
}
