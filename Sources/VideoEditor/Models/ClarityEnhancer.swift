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
    private static func computeUnits(for modelKind: ClarityModel) -> MLComputeUnits {
        .cpuAndGPU
    }

    private static func model(at url: URL, modelKind: ClarityModel) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits(for: modelKind)
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
        guard modelKind.isDownloaded else { throw EnhanceError.modelMissing }
        let mlModel = try model(at: modelKind.localURL, modelKind: modelKind)
        let scale = modelKind == .x2 ? 2 : 4

        let w = cgImage.width, h = cgImage.height
        let (yPlane, cbPlane, crPlane) = try rgbToYCbCr(cgImage)

        let enhancedY = try enhanceYPlane(yPlane, width: w, height: h, scale: scale,
                                         mlModel: mlModel, onTileProgress: onTileProgress)
        let enhancedCb = upsampleBilinear(cbPlane, width: w, height: h, scale: scale)
        let enhancedCr = upsampleBilinear(crPlane, width: w, height: h, scale: scale)

        return try yCbCrToRGB(y: enhancedY, cb: enhancedCb, cr: enhancedCr,
                              width: w * scale, height: h * scale)
    }

    // MARK: - 色彩空间转换

    /// RGB -> Y/Cb/Cr 三个 Float 平面（0...1 范围）。
    /// 系数跟 OpenCV cv2.COLOR_BGR2YCrCb 一致（full-range BT.601），
    /// 这是 Task 2 Python 验证阶段用的同一套系数，Swift 这边必须保持一致，
    /// 否则色彩空间转换本身的误差会跟"模型推理是否正确"混在一起没法区分。
    private static func rgbToYCbCr(_ cgImage: CGImage) throws -> (y: [Float], cb: [Float], cr: [Float]) {
        let w = cgImage.width, h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EnhanceError.inferenceFailed("RGB 读取上下文创建失败")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var y = [Float](repeating: 0, count: w * h)
        var cb = [Float](repeating: 0, count: w * h)
        var cr = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            let yy = 0.299 * r + 0.587 * g + 0.114 * b
            y[i] = yy / 255.0
            cr[i] = ((r - yy) * 0.713 + 128) / 255.0
            cb[i] = ((b - yy) * 0.564 + 128) / 255.0
        }
        return (y, cb, cr)
    }

    /// Y/Cb/Cr 平面（0...1 范围，已是目标尺寸）合并转回 RGB CGImage
    private static func yCbCrToRGB(y: [Float], cb: [Float], cr: [Float], width: Int, height: Int) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let yy = y[i] * 255.0
            let cbb = cb[i] * 255.0 - 128
            let crr = cr[i] * 255.0 - 128
            let r = yy + crr / 0.713
            let b = yy + cbb / 0.564
            let g = (yy - 0.299 * r - 0.114 * b) / 0.587
            rgba[i * 4]     = UInt8(max(0, min(255, r.rounded())))
            rgba[i * 4 + 1] = UInt8(max(0, min(255, g.rounded())))
            rgba[i * 4 + 2] = UInt8(max(0, min(255, b.rounded())))
            rgba[i * 4 + 3] = 255
        }
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

    /// Cb/Cr 通道用双线性插值放大（不过模型，人眼对色度细节不敏感，这是 FSRCNN
    /// 原论文和 OpenCV dnn_superres 的标准做法）。用 CGContext 的高质量插值，
    /// 不手写插值算法。
    private static func upsampleBilinear(_ plane: [Float], width: Int, height: Int, scale: Int) -> [Float] {
        var srcBytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            srcBytes[i] = UInt8(max(0, min(255, (plane[i] * 255).rounded())))
        }
        guard let provider = CGDataProvider(data: Data(srcBytes) as CFData),
              let srcImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                     decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: width * scale, height: height * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            return Array(repeating: 0.5, count: width * scale * height * scale)
        }
        ctx.interpolationQuality = .high
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        guard let outData = ctx.data else {
            return Array(repeating: 0.5, count: width * scale * height * scale)
        }
        let outPtr = outData.bindMemory(to: UInt8.self, capacity: width * scale * height * scale)
        var result = [Float](repeating: 0, count: width * scale * height * scale)
        for i in 0..<result.count { result[i] = Float(outPtr[i]) / 255.0 }
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
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
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
    /// 类型化指针（见 runOneTile 顶部注释）。
    ///
    /// **float16 是 FSRCNN 的常态路径，不是兜底分支**：coremltools 转出的
    /// mlprogram 默认用 FP16 存权重和中间结果，输出的 MLMultiArray dataType
    /// 实测就是 `.float16`（rawValue 65552），哪怕 `ct.TensorType` 没有显式
    /// 指定精度。Swift 的 `Float16` 跟它二进制布局一致，可以直接 bindMemory
    /// 后原生转换，不需要先造一个 float32 的 MLMultiArray 中转。
    ///
    /// 早先这里写的是"借 MLMultiArray(shape:dataType:) 转成 float32 再读"，
    /// 那条路径每个元素都要过一次 subscript 装箱，x2 单 tile 实测 122ms；
    /// 换成下面的 bindMemory 后是 24ms（5 倍提速），两种读法的输出数值逐元素
    /// 比对完全一致（最大差异 0），确认只是读取方式变快、不影响数值。
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
            let p = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count { out[i] = Float(p[i]) }
        default:
            throw EnhanceError.badOutput
        }
        return out
    }
}
