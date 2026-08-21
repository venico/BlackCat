import XCTest
import Foundation
import AppKit
@testable import VideoEditorLib

// MARK: - BiRefNet 推理
//
// 模型没下载时整组跳过，不会因为缺模型报假失败。

final class BiRefNetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private func requireModel() throws -> BiRefNetModel {
        let m = BiRefNetModel.lite
        try XCTSkipUnless(m.isDownloaded, "BiRefNet Lite 未下载，跳过")
        return m
    }

    private func loadCG(_ path: String) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("素材读取失败 \(path)")
        }
        return cg
    }

    /// 没下模型就调用，必须给出明确的 modelMissing，而不是崩或者静默出错图
    func testMissingModelReportsClearly() throws {
        let m = BiRefNetModel.full   // full 版没转，正好当"未下载"用
        try XCTSkipIf(m.isDownloaded, "full 版已下载，此用例不适用")

        let dummy = try makeDummy()
        XCTAssertThrowsError(try BiRefNetSegmenter.removeBackground(cgImage: dummy, model: m)) { err in
            guard case BiRefNetSegmenter.SegmentError.modelMissing = err else {
                XCTFail("应报 modelMissing，实际 \(err)"); return
            }
        }
    }

    private func makeDummy() throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))),
              let _ = Optional(ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))),
              let img = ctx.makeImage() else {
            throw XCTSkip("无法生成测试图")
        }
        return img
    }

    /// 输出必须保持原尺寸、带 alpha，且确实抠掉了东西
    func testInferenceProducesAlphaAtOriginalSize() throws {
        let model = try requireModel()
        let path = "/Users/Venico/Downloads/jimeng-2026-06-13-6825-具有CG厚涂、超现实，以及动画风格与国风3D动画人物风格结合的视觉风格，呈现出一....png"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "素材不存在")

        let src = try loadCG(path)
        let out = try BiRefNetSegmenter.removeBackground(cgImage: src, model: model)

        XCTAssertEqual(out.width, src.width, "输出应保持原宽度")
        XCTAssertEqual(out.height, src.height, "输出应保持原高度")
        XCTAssertNotEqual(out.alphaInfo, .none, "输出必须带 alpha")

        // 统计透明比例：这张图主体占大半，背景该被抠掉一部分
        let rep = NSBitmapImageRep(cgImage: out)
        var clear = 0, opaque = 0
        let sx = max(1, out.width / 60), sy = max(1, out.height / 60)
        for y in stride(from: 0, to: out.height, by: sy) {
            for x in stride(from: 0, to: out.width, by: sx) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent < 0.02 { clear += 1 }
                else if c.alphaComponent > 0.98 { opaque += 1 }
            }
        }
        let total = clear + opaque
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(Double(clear) / Double(total), 0.05, "应该抠掉了背景")
        XCTAssertGreaterThan(Double(opaque) / Double(total), 0.2, "主体应大面积保留")

        // 上面两条在 alpha 反相时照样成立（主体透明、背景不透明也满足），
        // 所以必须再钉住方向：画面中心是人物，四角是背景
        let center = try XCTUnwrap(rep.colorAt(x: out.width / 2, y: out.height / 2))
        XCTAssertGreaterThan(center.alphaComponent, 0.9,
                             "画面中心是主体，必须保留 —— 若为 0 说明 alpha 反了")

        let corners = [(4, 4), (out.width - 5, 4)]
        for (x, y) in corners {
            let c = try XCTUnwrap(rep.colorAt(x: x, y: y))
            XCTAssertLessThan(c.alphaComponent, 0.1, "角落是背景，应被抠成透明")
        }

        // 主体不能只剩形状 —— 得保住原图颜色，不是一团纯黑剪影
        let srcRep = NSBitmapImageRep(cgImage: src)
        let srcCenter = try XCTUnwrap(srcRep.colorAt(x: src.width / 2, y: src.height / 2))
        let dr = abs(center.redComponent - srcCenter.redComponent)
        let dg = abs(center.greenComponent - srcCenter.greenComponent)
        let db = abs(center.blueComponent - srcCenter.blueComponent)
        XCTAssertLessThan(dr + dg + db, 0.15,
                          "主体像素应保留原图颜色，实际 \(center) vs 原图 \(srcCenter)")
    }

    /// 把抠图结果导出成文件肉眼确认。设 BLACKCAT_DUMP_DIR=<目录> 才跑
    func testDumpCutoutForVisualCheck() throws {
        guard let dir = ProcessInfo.processInfo.environment["BLACKCAT_DUMP_DIR"] else {
            throw XCTSkip("设 BLACKCAT_DUMP_DIR 才导出结果图")
        }
        let model = try requireModel()
        let path = "/Users/Venico/Downloads/jimeng-2026-06-13-6825-具有CG厚涂、超现实，以及动画风格与国风3D动画人物风格结合的视觉风格，呈现出一....png"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "素材不存在")

        let out = try BiRefNetSegmenter.removeBackground(cgImage: try loadCG(path), model: model)
        let rep = NSBitmapImageRep(cgImage: out)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift_cutout.png"))

        // 再垫一层品红，透明区一眼可辨
        let size = NSSize(width: out.width, height: out.height)
        let composed = NSImage(size: size)
        composed.lockFocus()
        NSColor.magenta.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: out, size: size).draw(in: NSRect(origin: .zero, size: size))
        composed.unlockFocus()
        if let tiff = composed.tiffRepresentation,
           let bmp = NSBitmapImageRep(data: tiff),
           let data = bmp.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift_cutout_magenta.png"))
        }
    }

    /// 量一下两个变体在真实素材上的耗时。设 BLACKCAT_PERF=1 才跑
    func testMeasureInferenceTime() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACKCAT_PERF"] == "1",
                          "设 BLACKCAT_PERF=1 才测耗时")
        let path = "/Users/Venico/Downloads/jimeng-2026-06-13-6825-具有CG厚涂、超现实，以及动画风格与国风3D动画人物风格结合的视觉风格，呈现出一....png"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "素材不存在")
        let src = try loadCG(path)
        print("素材 \(src.width)×\(src.height)")
        for m in BiRefNetModel.allCases where m.isDownloaded {
            // 先跑一次把模型加载进缓存，再量纯推理
            _ = try BiRefNetSegmenter.removeBackground(cgImage: src, model: m)
            let t = Date()
            _ = try BiRefNetSegmenter.removeBackground(cgImage: src, model: m)
            print(String(format: "  %@ 纯推理 %.2f 秒", m.displayName, Date().timeIntervalSince(t)))
        }
    }

    /// 连跑两次结果必须逐字节一致。
    /// 模型是进程内静态缓存的，复用同一个 MLModel 实例不能带出状态污染。
    /// （不拿耗时做断言 —— 模型可能已被同组其它用例加载过，两次都是纯推理，
    ///   时间差只是噪声，那样的断言会随执行顺序飘）
    func testRepeatedCallsAreStable() throws {
        let model = try requireModel()
        let dummy = try makeDummy()

        let a = try BiRefNetSegmenter.removeBackground(cgImage: dummy, model: model)
        let b = try BiRefNetSegmenter.removeBackground(cgImage: dummy, model: model)

        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)

        let da = try XCTUnwrap(a.dataProvider?.data as Data?)
        let db = try XCTUnwrap(b.dataProvider?.data as Data?)
        XCTAssertEqual(da, db, "同一输入连跑两次结果应完全一致")
    }
}
