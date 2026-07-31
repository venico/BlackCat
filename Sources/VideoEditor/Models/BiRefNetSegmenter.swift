// BiRefNetSegmenter.swift
// BiRefNet 的 CoreML 推理。模型固定吃 1024×1024 RGB，
// 归一化（ImageNet mean/std）已经烘进模型的输入层，这边只管缩放送图。
// 输出是单通道 0~1 的 mask，需要缩回原尺寸当 alpha 用。
import Foundation
import CoreML
import CoreImage
import AppKit

enum BiRefNetSegmenter {

    /// 模型的固定输入边长
    static let inputSize = 1024

    enum SegmentError: Error, LocalizedError {
        case modelMissing
        case loadFailed(String)
        case inferenceFailed(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing:          return "还没下载 BiRefNet 模型，请到设置 → 图片里下载"
            case .loadFailed(let d):     return "模型加载失败：\(d)"
            case .inferenceFailed(let d): return "抠图推理失败：\(d)"
            case .badOutput:             return "模型输出格式不符合预期"
            }
        }
    }

    // 加载一次留着复用，每次去背都重新读 93MB 太浪费
    private static let cacheLock = NSLock()
    private static var cached: (path: String, model: MLModel)?

    private static func model(at url: URL) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }

        let config = MLModelConfiguration()
        // 这个模型编不进 ANE（转换时 ANECCompile 就失败了），限定 CPU+GPU 免得白试一遍
        config.computeUnits = .cpuAndGPU
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            cached = (url.path, m)
            return m
        } catch {
            throw SegmentError.loadFailed(error.localizedDescription)
        }
    }

    /// 该模型是否已在内存里 —— 用来判断这次调用要不要经历加载耗时
    static func isLoaded(_ modelKind: BiRefNetModel) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cached?.path == modelKind.localURL.path
    }

    /// 跑一遍抠图，返回带 alpha 的图片。
    /// onStage 在耗时阶段切换时回调，交给上层显示进度
    static func removeBackground(cgImage: CGImage, model modelKind: BiRefNetModel,
                                 onStage: ((ProjectState.RemoveBackgroundState) -> Void)? = nil) throws -> CGImage {
        guard modelKind.isDownloaded else { throw SegmentError.modelMissing }

        if !isLoaded(modelKind) { onStage?(.loadingModel) }
        let mlModel = try model(at: modelKind.localURL)
        onStage?(.processing)

        let resized = try scaled(cgImage, to: inputSize)
        guard let buffer = pixelBuffer(from: resized, size: inputSize) else {
            throw SegmentError.inferenceFailed("输入缓冲区创建失败")
        }

        let inputName = mlModel.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        } catch {
            throw SegmentError.inferenceFailed(error.localizedDescription)
        }

        let result: MLFeatureProvider
        do {
            result = try mlModel.prediction(from: provider)
        } catch {
            throw SegmentError.inferenceFailed(error.localizedDescription)
        }

        guard let outName = mlModel.modelDescription.outputDescriptionsByName.keys.first,
              let array = result.featureValue(for: outName)?.multiArrayValue else {
            throw SegmentError.badOutput
        }

        let mask = try maskImage(from: array)
        return try composite(original: cgImage, mask: mask)
    }

    // MARK: - 图像处理

    private static func scaled(_ image: CGImage, to side: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SegmentError.inferenceFailed("缩放上下文创建失败")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else {
            throw SegmentError.inferenceFailed("缩放失败")
        }
        return out
    }

    private static func pixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    /// MultiArray (1,1,H,W) 的 0~1 概率图 → 8 位灰度图
    private static func maskImage(from array: MLMultiArray) throws -> CGImage {
        let shape = array.shape.map(\.intValue)
        guard let h = shape.dropLast().last, let w = shape.last, h > 0, w > 0 else {
            throw SegmentError.badOutput
        }
        var bytes = [UInt8](repeating: 0, count: w * h)
        let count = w * h

        // 用指针读，逐个下标访问 MLMultiArray 在百万像素级别慢得离谱
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                bytes[i] = UInt8(max(0, min(255, p[i] * 255)))
            }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count {
                bytes[i] = UInt8(max(0, min(255, p[i] * 255)))
            }
        case .float16:
            // float16 没有直接的 Swift 类型可绑，借 MLMultiArray 转成 float32 再读
            guard let converted = try? MLMultiArray(shape: array.shape, dataType: .float32) else {
                throw SegmentError.badOutput
            }
            for i in 0..<count { converted[i] = array[i] }
            let p = converted.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                bytes[i] = UInt8(max(0, min(255, p[i] * 255)))
            }
        default:
            throw SegmentError.badOutput
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent) else {
            throw SegmentError.badOutput
        }
        return img
    }

    /// 把 mask 缩回原尺寸当 alpha 贴到原图上。
    /// 注意别用 CGImage.masking(_:) —— 那个是 image mask，语义是「值越大越遮蔽」，
    /// 跟 alpha 正好相反，套上去会把主体抠没、背景留下。
    /// CIBlendWithMask 才是「白=前景、黑=背景」，匹配模型输出
    private static func composite(original: CGImage, mask: CGImage) throws -> CGImage {
        let w = original.width, h = original.height
        let image = CIImage(cgImage: original)
        let scaleX = CGFloat(w) / CGFloat(mask.width)
        let scaleY = CGFloat(h) / CGFloat(mask.height)
        let maskCI = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let transparent = CIImage(color: .clear).cropped(to: image.extent)
        let blended = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: maskCI
        ])

        guard let final = CIContext().createCGImage(
            blended, from: image.extent,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw SegmentError.inferenceFailed("alpha 合成失败")
        }
        return final
    }
}
