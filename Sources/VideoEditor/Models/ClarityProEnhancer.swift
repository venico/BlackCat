// ClarityProEnhancer.swift
// 高质量本地超分（Real-ESRGAN 轻量分支 / Real-CUGAN）的推理。
//
// 跟 ClarityEnhancer（FSRCNN）分开写，因为模型接口根本不同：
//   FSRCNN  MultiArray 单通道 Y（只超分亮度，色度靠双线性放大）
//   这三个  ImageType RGB 三通道（整图进整图出）
// 硬合并会让每个函数都带一个 if kind 分支，两条路的中间表示还不一样
// （Float 平面 vs CVPixelBuffer），分开反而更短。
//
// tile 切分/拼接的策略照搬 ClarityEnhancer：256 见方、两侧各 16 重叠，
// 贴回时只取中心"贡献区间"，相邻 tile 的区间精确衔接不重叠。那套算法跟
// 通道数无关，这里只是把数据从单通道 Float 换成了 BGRA 字节。
import Foundation
import CoreML
import CoreVideo
import Accelerate

enum ClarityProEnhancer {

    static let tileSize = ClarityEnhancer.tileSize        // 256，跟转换时写死的输入尺寸一致
    static let tileOverlap = ClarityEnhancer.tileOverlap  // 16

    enum EnhanceError: Error, LocalizedError {
        case modelMissing
        case loadFailed(String)
        case bufferFailed
        case inferenceFailed(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing:          return "模型尚未下载"
            case .loadFailed(let d):     return "模型加载失败：\(d)"
            case .bufferFailed:          return "图像缓冲区创建失败"
            case .inferenceFailed(let d):return "推理失败：\(d)"
            case .badOutput:             return "模型输出尺寸不符合预期"
            }
        }
    }

    // MARK: - 模型缓存

    private static let cacheLock = NSLock()
    private static var cached: (path: String, model: MLModel)?

    /// 用 .all（允许 ANE）。这三个模型跟 FSRCNN 的取舍相反：FSRCNN 太小，
    /// 调度到 ANE 的固定开销盖过收益，所以那边用 .cpuAndGPU；这三个大一到两个
    /// 数量级，实测 ANE 明显更快（general-x4v3 21ms/tile、animevideov3 13ms、
    /// Real-CUGAN 24ms，都是 .all 下的数字）
    private static func model(at url: URL) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            cached = (url.path, m)
            return m
        } catch {
            throw EnhanceError.loadFailed(error.localizedDescription)
        }
    }

    // MARK: - 入口

    /// 吃/吐紧密排列的 RGBA8888 字节（每像素 4 字节、行间无 padding），
    /// 跟 ClarityEnhancer.enhanceRGBA 同一个接口形状，方便流水线那头无差别调用
    static func enhanceRGBA(_ rgba: [UInt8], width w: Int, height h: Int,
                            model kind: ClarityProModel,
                            onTileProgress: ((Double) -> Void)? = nil) throws -> [UInt8] {
        guard kind.isDownloaded else { throw EnhanceError.modelMissing }
        let mlModel = try model(at: kind.localURL)
        // 倍数跟着模型走：Real-CUGAN 有 2 倍和 4 倍两套权重，输出尺寸不同
        let scale = kind.scale

        let stride = tileSize - tileOverlap * 2
        var tilesX = max(1, Int(ceil(Double(w - tileOverlap * 2) / Double(stride))))
        var tilesY = max(1, Int(ceil(Double(h - tileOverlap * 2) / Double(stride))))
        if w <= tileSize { tilesX = 1 }
        if h <= tileSize { tilesY = 1 }
        let totalTiles = tilesX * tilesY

        // 这几个坐标函数跟 ClarityEnhancer.enhanceYPlane 里的同名逻辑一致，
        // 理由见那边的长注释：contribX1(tx) 必须等于 contribX0(tx+1)，
        // 相邻 tile 才能不重叠不留缝，不依赖"stride 整除图片宽高"
        func srcXFor(_ tx: Int) -> Int { min(tx * stride, max(0, w - tileSize)) }
        func srcYFor(_ ty: Int) -> Int { min(ty * stride, max(0, h - tileSize)) }
        func contribX0For(_ tx: Int) -> Int {
            let sx = srcXFor(tx)
            guard tx > 0 else { return sx }
            return min(sx + tileOverlap, sx + min(tileSize, w - sx))
        }
        func contribY0For(_ ty: Int) -> Int {
            let sy = srcYFor(ty)
            guard ty > 0 else { return sy }
            return min(sy + tileOverlap, sy + min(tileSize, h - sy))
        }

        let outW = w * scale, outH = h * scale
        var output = [UInt8](repeating: 255, count: outW * outH * 4)
        var done = 0

        // 输入/输出缓冲区各建一次，所有 tile 复用——1080p 一帧四十多个 tile，
        // 每个 tile 都新建 CVPixelBuffer 的话光分配就够呛
        guard let inBuf = makePixelBuffer(tileSize, tileSize) else {
            throw EnhanceError.bufferFailed
        }

        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                try autoreleasepool {
                    let srcX = srcXFor(tx), srcY = srcYFor(ty)
                    let cropW = min(tileSize, w - srcX), cropH = min(tileSize, h - srcY)

                    fillTile(into: inBuf, from: rgba, srcX: srcX, srcY: srcY,
                             fullWidth: w, fullHeight: h)
                    let outBuf = try runOneTile(inBuf, mlModel: mlModel, scale: scale)

                    let contribX0 = contribX0For(tx)
                    let contribX1 = tx == tilesX - 1 ? srcX + cropW : contribX0For(tx + 1)
                    let contribY0 = contribY0For(ty)
                    let contribY1 = ty == tilesY - 1 ? srcY + cropH : contribY0For(ty + 1)

                    blit(outBuf, into: &output, outWidth: outW, scale: scale,
                         srcX: srcX, srcY: srcY,
                         x0: contribX0, x1: contribX1, y0: contribY0, y1: contribY1)

                    done += 1
                    onTileProgress?(Double(done) / Double(totalTiles))
                }
            }
        }
        return output
    }

    // MARK: - 单 tile

    private static func makePixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    /// 从整张 RGBA 里裁一块填进 BGRA 缓冲区，越界的地方用边缘像素延伸补齐
    /// （模型输入尺寸是固定的 256×256，右下角残缺的 tile 必须补满）
    private static func fillTile(into buf: CVPixelBuffer, from rgba: [UInt8],
                                 srcX: Int, srcY: Int, fullWidth: Int, fullHeight: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buf)   // 可能大于 w*4，有行对齐 padding
        let dst = base.assumingMemoryBound(to: UInt8.self)

        rgba.withUnsafeBufferPointer { src in
            for row in 0..<tileSize {
                let sy = min(srcY + row, fullHeight - 1)
                let dstRow = dst + row * rowBytes
                for col in 0..<tileSize {
                    let sx = min(srcX + col, fullWidth - 1)
                    let s = (sy * fullWidth + sx) * 4
                    let d = col * 4
                    // RGBA → BGRA：CoreML 的 ImageType(RGB) 输入在 macOS 上收的是
                    // 32BGRA 缓冲区，通道顺序反过来
                    dstRow[d + 0] = src[s + 2]
                    dstRow[d + 1] = src[s + 1]
                    dstRow[d + 2] = src[s + 0]
                    dstRow[d + 3] = 255
                }
            }
        }
    }

    private static func runOneTile(_ input: CVPixelBuffer, mlModel: MLModel,
                                   scale: Int) throws -> CVPixelBuffer {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["input": MLFeatureValue(pixelBuffer: input)])
        let out: MLFeatureProvider
        do { out = try mlModel.prediction(from: provider) }
        catch { throw EnhanceError.inferenceFailed(error.localizedDescription) }
        guard let pb = out.featureValue(for: "output")?.imageBufferValue else {
            throw EnhanceError.badOutput
        }
        guard CVPixelBufferGetWidth(pb) == tileSize * scale,
              CVPixelBufferGetHeight(pb) == tileSize * scale else {
            throw EnhanceError.badOutput
        }
        return pb
    }

    /// 把一个 tile 的输出贴回整帧。只贴 [x0,x1)×[y0,y1)（原图坐标系）这段贡献区间，
    /// 两侧的 overlap 留给相邻 tile 的中心部分覆盖——tile 边缘缺乏上下文，
    /// 直接拼进去会有可见接缝
    private static func blit(_ tile: CVPixelBuffer, into output: inout [UInt8], outWidth: Int,
                             scale: Int,
                             srcX: Int, srcY: Int, x0: Int, x1: Int, y0: Int, y1: Int) {
        CVPixelBufferLockBaseAddress(tile, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(tile) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(tile)
        let src = base.assumingMemoryBound(to: UInt8.self)

        output.withUnsafeMutableBufferPointer { dst in
            for oy in (y0 * scale)..<(y1 * scale) {
                let localRow = oy - srcY * scale
                let srcRow = src + localRow * rowBytes
                let dstRowStart = oy * outWidth * 4
                for ox in (x0 * scale)..<(x1 * scale) {
                    let localCol = ox - srcX * scale
                    let s = localCol * 4
                    let d = dstRowStart + ox * 4
                    // BGRA → RGBA，跟 fillTile 那边反着来
                    dst[d + 0] = srcRow[s + 2]
                    dst[d + 1] = srcRow[s + 1]
                    dst[d + 2] = srcRow[s + 0]
                    dst[d + 3] = 255
                }
            }
        }
    }
}
