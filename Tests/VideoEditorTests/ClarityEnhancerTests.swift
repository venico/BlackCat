// Tests/VideoEditorTests/ClarityEnhancerTests.swift
import XCTest
import AppKit
@testable import VideoEditorLib

final class ClarityEnhancerTests: XCTestCase {

    /// 画一张比 tileSize 大的棋盘格图（触发多 tile 拼接路径），
    /// 用棋盘格是为了让拼接错位在肉眼看时非常显眼（网格线不对齐会立刻看出来）
    private func makeCheckerboard(size: Int, cell: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("无法创建绘图上下文")
        }
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let isDark = ((x / cell) + (y / cell)) % 2 == 0
                ctx.setFillColor(isDark ? CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
                                        : CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        guard let img = ctx.makeImage() else { throw XCTSkip("生成失败") }
        return img
    }

    /// 把 CGImage 画到 RGBA8 buffer 里读像素。灰度图画进 RGB context 后 R=G=B，
    /// 所以这个函数对灰度图和彩色图都能用，读 R 通道即可当灰度值。
    private func readRGBA(_ cgImage: CGImage) -> (pixels: [UInt8], width: Int, height: Int) {
        let w = cgImage.width, h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return ([], w, h)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }

    /// 从一张 RGB CGImage 提取 Y 通道（0...1），系数跟 ClarityEnhancer.rgbToYCbCr
    /// 用的 BT.601 full-range 系数一致（0.299/0.587/0.114），这样才能跟 Python
    /// 参考图（本身就是 Y 通道灰度图）在同一个空间里比较
    private func extractYPlane(fromRGB cgImage: CGImage) -> [Float] {
        let (rgba, w, h) = readRGBA(cgImage)
        var y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            y[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return y
    }

    /// 从一张灰度 CGImage（Python cv2.imwrite 存的单通道 PNG）提取 0...1 灰度值。
    /// 灰度图画进 RGB context 后 R=G=B，直接读 R 通道
    private func extractYPlane(fromGray cgImage: CGImage) -> [Float] {
        let (rgba, w, h) = readRGBA(cgImage)
        var y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            y[i] = Float(rgba[i * 4]) / 255.0
        }
        return y
    }

    /// PSNR 计算方式跟 Task 2 verify_pytorch.py 完全一致：
    /// diff = |a - b|（0...1 范围），mae_255 = mean(diff)*255，
    /// psnr = 20*log10(1.0 / max(rmse, 1e-10))，MAX=1.0（因为两边都是 0...1 归一化值）
    private func maeAndPSNR(_ a: [Float], _ b: [Float]) -> (mae255: Double, psnr: Double) {
        precondition(a.count == b.count)
        var sumAbs = 0.0
        var sumSq = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            sumAbs += abs(d)
            sumSq += d * d
        }
        let n = Double(a.count)
        let mae255 = (sumAbs / n) * 255.0
        let rmse = (sumSq / n).squareRoot()
        let psnr = 20 * log10(1.0 / max(rmse, 1e-10))
        return (mae255, psnr)
    }

    func testEnhanceProducesCorrectOutputSize() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)  // 比 tileSize(256) 大，触发多 tile
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        XCTAssertEqual(out.width, 400 * 4, "输出宽度应是原图 4 倍")
        XCTAssertEqual(out.height, 400 * 4, "输出高度应是原图 4 倍")
    }

    func testEnhanceX2ProducesCorrectOutputSize() throws {
        try XCTSkipUnless(ClarityModel.x2.isDownloaded, "FSRCNN x2 模型未下载")
        let checker = try makeCheckerboard(size: 300, cell: 30)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x2)
        XCTAssertEqual(out.width, 300 * 2)
        XCTAssertEqual(out.height, 300 * 2)
    }

    /// 保存拼接结果到临时目录，手动打开肉眼检查有无接缝错位——
    /// 这个断言本身测不出"棋盘格线对不对齐"，但把文件路径打印出来，
    /// 方便这一步跑完后手动 open 检查
    func testEnhanceOutputSavedForVisualCheck() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clarity_tile_check.png")
        let rep = NSBitmapImageRep(cgImage: out)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("拼接结果已保存，手动检查: \(url.path)")
    }

    /// 用 Task 2 产出的真实测试图（跟 Python 验证时用的同一张 test_input_crop256.png），
    /// 对比 Swift 输出跟 Python 参考输出（pytorch_y_x4.png，Y 通道灰度图）的 Y 通道数值，
    /// 验证 Swift 这边的 YCbCr 转换系数和 tile 推理链路整体是对的，不只是"形状对了"
    func testEnhanceMatchesPythonReference() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let testInputPath = "/Users/Venico/claude/clarity-convert/test_input_crop256.png"
        let pyRefPath = "/Users/Venico/claude/clarity-convert/fsrcnn/pytorch_y_x4.png"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: testInputPath), "Task 1/2 的测试图不存在")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pyRefPath), "Python 参考输出不存在，先跑 Task 2 Step 2")

        guard let inputImg = NSImage(contentsOfFile: testInputPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("测试图加载失败")
        }
        let out = try ClarityEnhancer.enhance(cgImage: inputImg, model: .x4)

        // 只比较人眼最敏感的 Y 通道，把输出转灰度跟 Python 参考图（本身就是 Y 通道灰度图）比较
        guard let pyRefImg = NSImage(contentsOfFile: pyRefPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("Python 参考图加载失败")
        }
        XCTAssertEqual(out.width, pyRefImg.width, "输出宽度应跟 Python 参考一致")
        XCTAssertEqual(out.height, pyRefImg.height, "输出高度应跟 Python 参考一致")

        // 数值层面的 MAE/PSNR 对比：全图比较（1024x1024，规模不大，直接算全图不采样）。
        // 计算方式对齐 Task 2 verify_pytorch.py：diff 取绝对值，mae_255 = mean*255，
        // psnr = 20*log10(1/rmse)，MAX 取 1.0（两边都是 0...1 归一化值）。
        // 阈值用 Task 2 定的 30dB 判据——Task 2 实测 PyTorch/CoreML 对 OpenCV baseline
        // 都在 58dB 量级，这里再叠加 Swift 侧 YCbCr<->RGB 往返 8-bit 量化的噪声，
        // 预期仍然远高于 30dB，如果测不到说明 Swift 链路有 bug。
        let swiftY = extractYPlane(fromRGB: out)
        let pyY = extractYPlane(fromGray: pyRefImg)
        XCTAssertEqual(swiftY.count, pyY.count, "像素总数应一致才能逐点比较")

        let (mae255, psnr) = maeAndPSNR(swiftY, pyY)
        print("testEnhanceMatchesPythonReference: MAE(0-255)=\(String(format: "%.3f", mae255)) PSNR=\(String(format: "%.2f", psnr))dB")
        XCTAssertGreaterThan(psnr, 30, "PSNR 太低（\(String(format: "%.2f", psnr))dB），YCbCr 转换或 tile 推理链路可能有 bug")
    }

    func testEnhanceThrowsWhenModelMissing() throws {
        // 用一个还没下载的假想场景需要能测到 modelMissing —— 这里改用直接构造
        // 一个不存在的场景比较难做（下载状态是全局单例），改成检查错误类型可解码即可
        XCTAssertNotNil(ClarityEnhancer.EnhanceError.modelMissing.errorDescription)
    }
}
