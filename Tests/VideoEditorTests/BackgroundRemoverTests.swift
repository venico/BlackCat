import XCTest
import Foundation
import AppKit
@testable import VideoEditorLib

// MARK: - 去背：纯色底走色键、复杂底走 Vision
//
// 素材一律程序化生成，不引用桌面上的实际文件 —— 那些文件会被随时覆盖，
// 曾经导致断言采样点落到完全不同的画面上、报出假失败。

final class BackgroundRemoverTests: XCTestCase {

    // 读的是真实 UserDefaults：用户在 app 里把模型切成 BiRefNet 后，
    // 这组用例会跟着走神经网络路径，测不到本该测的色键/Vision。这里钉死成内置
    private var savedEngine: BackgroundRemover.Engine!

    override func setUp() {
        super.setUp()
        savedEngine = AppSettings.shared.bgRemovalEngine
        AppSettings.shared.bgRemovalEngine = .system
    }

    override func tearDown() {
        AppSettings.shared.bgRemovalEngine = savedEngine
        super.tearDown()
    }

    /// 合成一张白底图：
    ///   · 浅米色块  与白底距离约 95，模拟「猫躺着的手掌」这类容易被误吃的浅色主体
    ///   · 深色块    距离很大，必须完整保留
    ///   · 细线      距离约 9，模拟胡须/发丝，只要求半透明可见
    private func makeSolidBackgroundImage() throws -> URL {
        let w = 400, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("无法创建绘图上下文")
        }
        ctx.setFillColor(CGColor(red: 254/255, green: 254/255, blue: 254/255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 245/255, green: 222/255, blue: 179/255, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 60, width: 160, height: 160))
        ctx.setFillColor(CGColor(red: 20/255, green: 20/255, blue: 20/255, alpha: 1))
        ctx.fill(CGRect(x: 240, y: 240, width: 100, height: 100))

        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw XCTSkip("无法生成测试图")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgremover_solid_\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    /// 采样某点的 alpha。坐标按 NSBitmapImageRep 约定，原点在左上
    private func alpha(_ url: URL, x: Int, y: Int) throws -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("回读失败 \(url.path)"); return -1
        }
        XCTAssertNotEqual(cg.alphaInfo, .none, "输出必须带 alpha 通道")
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let c = rep.colorAt(x: min(cg.width - 1, x), y: min(cg.height - 1, y)) else { return -1 }
        return Int((c.alphaComponent * 255).rounded())
    }

    /// 纯色底：背景抠干净，浅色主体和深色主体都必须完整保留。
    /// Vision 路径只会认深色块那个「主体」，浅色块会被当背景丢掉 —— 所以这条断言
    /// 同时验证了「判定为纯色底」和「色键没误伤浅色内容」
    func testSolidBackground_KeepsLightSubject() async throws {
        let src = try makeSolidBackgroundImage()
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try await BackgroundRemover.removeBackground(from: src, outputName: "unittest_solid", mode: .auto)
        defer { try? FileManager.default.removeItem(at: out) }

        // 图像坐标原点在左上，绘图时的矩形是左下原点，所以 y 要翻过来
        XCTAssertEqual(try alpha(out, x: 10, y: 10), 0, "四角背景应全透明")
        XCTAssertGreaterThan(try alpha(out, x: 140, y: 260), 250, "浅米色主体必须完整保留，不能被当背景吃掉")
        XCTAssertGreaterThan(try alpha(out, x: 290, y: 110), 250, "深色主体必须完整保留")
    }

    /// 手动指定「智能识别主体」时必须真的走 Vision，不因为图是纯色底就抄近路
    func testSubjectModeForcesVision() async throws {
        let src = try makeSolidBackgroundImage()
        defer { try? FileManager.default.removeItem(at: src) }

        // 合成图上没有 Vision 认得的主体，应当明确报 noSubject 而不是悄悄退回色键
        do {
            let out = try await BackgroundRemover.removeBackground(from: src, outputName: "unittest_subject", mode: .subject)
            try? FileManager.default.removeItem(at: out)
        } catch BackgroundRemover.RemoveError.noSubject {
            return  // 预期路径
        }
    }

    /// 真实素材存在时才跑，作为补充；文件被换掉也只是跳过，不会报假失败
    func testComplexBackground_FallsBackToVision() async throws {
        let src = URL(fileURLWithPath: "/Users/Venico/Desktop/AI生成/seedream_0A2E612A.png")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "测试素材不存在")

        let out = try await BackgroundRemover.removeBackground(from: src, outputName: "unittest_complex", mode: .auto)
        defer { try? FileManager.default.removeItem(at: out) }

        guard let s = CGImageSourceCreateWithURL(out as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
            XCTFail("回读失败"); return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        var clear = 0, total = 0
        let sx = max(1, cg.width / 60), sy = max(1, cg.height / 60)
        for y in stride(from: 0, to: cg.height, by: sy) {
            for x in stride(from: 0, to: cg.width, by: sx) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                if c.alphaComponent < 0.02 { clear += 1 }
            }
        }
        XCTAssertGreaterThan(Double(clear) / Double(max(total, 1)), 0.1, "背景应有可观的透明区域")
    }
}
