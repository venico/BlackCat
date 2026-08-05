// AppleSuperResolution.swift
// 系统自带的视频超分（VTFrameProcessor + VTSuperResolutionScalerConfiguration，macOS 26+）。
//
// 相比自带的 FSRCNN：模型由系统下载和维护、走硬件加速，而且**能吃上一帧**
// （previousFrame / previousOutputFrame）来保持时序稳定——逐帧独立跑的模型
// 做不到这点，视频放大最容易露馅的闪烁就出在这里。
//
// 代价是三条硬约束，调用方必须照顾到：
//   1. 只支持 4 倍，没有 2 倍档
//   2. 输入不能超过 1920x1080（4K 素材进不来）
//   3. 要 macOS 26.0+
import Foundation
import VideoToolbox
import CoreVideo

@available(macOS 26.0, *)
final class AppleSuperResolution {

    enum SRError: LocalizedError {
        case unsupportedSize(Int, Int)
        case modelNotReady
        case sessionFailed(String)
        case processFailed(String)
        case bufferFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedSize(let w, let h):
                return "系统超分不支持 \(w)x\(h)（输入需在 1920x1080 以内）"
            case .modelNotReady:    return "系统超分模型尚未下载完成"
            case .sessionFailed(let d): return "系统超分启动失败：\(d)"
            case .processFailed(let d): return "系统超分处理失败：\(d)"
            case .bufferFailed:     return "图像缓冲区创建失败"
            }
        }
    }

    static let scaleFactor = 4
    static let maxInputWidth = 1920
    static let maxInputHeight = 1080

    /// 这台机器能不能用（除了系统版本，还要看芯片支不支持）
    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    static func makeConfiguration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height,
            scaleFactor: scaleFactor,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    /// 模型是否已就绪。系统模型不随 app 分发，第一次用要先下
    static func modelReady(width: Int = 1920, height: Int = 1080) -> Bool {
        guard let cfg = makeConfiguration(width: width, height: height) else { return false }
        return cfg.configurationModelStatus == .ready
    }

    /// 触发系统下载模型。进度由系统掌握，这里只能等它回调
    static func downloadModel(completion: @escaping (Error?) -> Void) {
        guard let cfg = makeConfiguration(width: 1920, height: 1080) else {
            completion(SRError.unsupportedSize(1920, 1080)); return
        }
        if cfg.configurationModelStatus == .ready { completion(nil); return }
        cfg.downloadConfigurationModel { completion($0) }
    }

    // MARK: - 会话

    private let processor = VTFrameProcessor()
    private let width: Int
    private let height: Int
    /// 上一帧的输入和输出，喂给下一帧做时序参考。这是这个引擎相对逐帧模型的关键优势，
    /// 所以调用方必须**按顺序**送帧，不能并发乱序
    private var prevSource: VTFrameProcessorFrame?
    private var prevOutput: VTFrameProcessorFrame?
    private var frameIndex: Int64 = 0

    init(width: Int, height: Int) throws {
        guard width <= Self.maxInputWidth, height <= Self.maxInputHeight,
              let cfg = Self.makeConfiguration(width: width, height: height) else {
            throw SRError.unsupportedSize(width, height)
        }
        guard cfg.configurationModelStatus == .ready else { throw SRError.modelNotReady }
        self.width = width
        self.height = height
        do { try processor.startSession(configuration: cfg) }
        catch { throw SRError.sessionFailed(error.localizedDescription) }
    }

    deinit { processor.endSession() }

    /// 处理一帧。输入输出都是紧密排列的 RGBA8888 字节，跟 ClarityEnhancer 的
    /// enhanceRGBA 对齐，方便流水线两种引擎共用同一条数据通路。
    func process(rgba: [UInt8]) throws -> [UInt8] {
        guard let src = Self.makeBuffer(width, height),
              let dst = Self.makeBuffer(width * Self.scaleFactor, height * Self.scaleFactor) else {
            throw SRError.bufferFailed
        }
        try Self.write(rgba: rgba, to: src, width: width, height: height)

        let pts = CMTime(value: frameIndex, timescale: 600)
        frameIndex += 1
        guard let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
              let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts),
              let params = VTSuperResolutionScalerParameters(
                    sourceFrame: sf,
                    previousFrame: prevSource,
                    previousOutputFrame: prevOutput,
                    opticalFlow: nil,
                    submissionMode: .sequential,
                    destinationFrame: df) else {
            throw SRError.bufferFailed
        }

        // 处理器是异步接口，这里同步等——整条流水线本来就跑在专属线程上
        let sem = DispatchSemaphore(value: 0)
        var perr: Error?
        processor.process(parameters: params) { _, e in perr = e; sem.signal() }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            throw SRError.processFailed("超时(120s)")
        }
        if let e = perr { throw SRError.processFailed(e.localizedDescription) }

        prevSource = sf
        prevOutput = df
        return try Self.read(from: dst)
    }

    // MARK: - 像素缓冲区读写

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    /// RGBA(我们的顺序) → BGRA(CVPixelBuffer 的顺序)，同时处理逐行 padding：
    /// CVPixelBuffer 的 bytesPerRow 常常大于 width*4，不能整块 memcpy
    private static func write(rgba: [UInt8], to pb: CVPixelBuffer, width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw SRError.bufferFailed }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let srcRow = y * width * 4
            let dstRow = y * stride
            for x in 0..<width {
                let s = srcRow + x * 4, d = dstRow + x * 4
                dst[d]     = rgba[s + 2]   // B
                dst[d + 1] = rgba[s + 1]   // G
                dst[d + 2] = rgba[s]       // R
                dst[d + 3] = rgba[s + 3]   // A
            }
        }
    }

    private static func read(from pb: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw SRError.bufferFailed }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let srcRow = y * stride
            let dstRow = y * w * 4
            for x in 0..<w {
                let s = srcRow + x * 4, d = dstRow + x * 4
                out[d]     = src[s + 2]    // R
                out[d + 1] = src[s + 1]    // G
                out[d + 2] = src[s]        // B
                out[d + 3] = src[s + 3]    // A
            }
        }
        return out
    }
}
let AppleSuperResolutionScale = 4
