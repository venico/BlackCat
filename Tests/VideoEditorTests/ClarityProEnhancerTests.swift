// 高质量本地超分（Real-ESRGAN 轻量分支 / Real-CUGAN）的接线与推理。
// 这三个模型跟 FSRCNN 的接口完全不同（RGB ImageType vs 单通道 Y MultiArray），
// 单独一组测试锁住：枚举接线不能错配、真跑一遍出来的尺寸和画面要对。
import XCTest
import CoreGraphics
@testable import VideoEditorLib

final class ClarityProEnhancerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    // MARK: - 接线（不需要模型文件）

    func testEngineMapsToRightModel() {
        XCTAssertEqual(AppSettings.ClarityEngine.generalX4V3.proModel(scale: 4), .generalX4V3)
        XCTAssertEqual(AppSettings.ClarityEngine.animeVideoV3.proModel(scale: 4), .animeVideoV3)
        // Real-CUGAN 两套权重，必须按用户点的倍数取——取错了输出尺寸会跟
        // 时间轴上的片段对不上
        XCTAssertEqual(AppSettings.ClarityEngine.realCUGAN.proModel(scale: 4), .realCUGAN)
        XCTAssertEqual(AppSettings.ClarityEngine.realCUGAN.proModel(scale: 2), .realCUGAN2x)
        // 只有 x4 权重的两个，传 2 也得给回 x4（右键菜单不会给它们 2 倍选项）
        XCTAssertEqual(AppSettings.ClarityEngine.generalX4V3.proModel(scale: 2), .generalX4V3)
        // 其余引擎不能误挂到本地高质量模型上，否则会去跑一个没下载的模型
        XCTAssertNil(AppSettings.ClarityEngine.system.proModel())
        XCTAssertNil(AppSettings.ClarityEngine.builtIn.proModel())
        XCTAssertNil(AppSettings.ClarityEngine.flashVSR.proModel())
        XCTAssertNil(AppSettings.ClarityEngine.seedVR2.proModel())
    }

    func testProEnginesAreLocal() {
        for engine in [AppSettings.ClarityEngine.generalX4V3, .animeVideoV3, .realCUGAN] {
            XCTAssertFalse(engine.isCloud, "\(engine.rawValue) 是本地模型，不该被当云端")
            XCTAssertNil(engine.falEndpoint, "\(engine.rawValue) 不该有 fal endpoint")
            XCTAssertEqual(engine.group, .local)
        }
        // 上游只发布了 x4 权重的两个不能给 2 倍选项，Real-CUGAN 两档都有
        XCTAssertFalse(AppSettings.ClarityEngine.generalX4V3.supportsX2)
        XCTAssertFalse(AppSettings.ClarityEngine.animeVideoV3.supportsX2)
        XCTAssertTrue(AppSettings.ClarityEngine.realCUGAN.supportsX2)
    }

    func testModelScaleMatchesItsWeights() {
        XCTAssertEqual(ClarityProModel.realCUGAN2x.scale, 2)
        XCTAssertEqual(ClarityProModel.realCUGAN.scale, 4)
        XCTAssertEqual(ClarityProModel.generalX4V3.scale, 4)
        XCTAssertEqual(ClarityProModel.animeVideoV3.scale, 4)
    }

    func testEachProModelHasDistinctFileAndURL() {
        let names = Set(ClarityProModel.allCases.map(\.fileName))
        XCTAssertEqual(names.count, ClarityProModel.allCases.count, "文件名撞了会互相覆盖")
        for m in ClarityProModel.allCases {
            XCTAssertFalse(m.sourceURLs.isEmpty, "\(m.rawValue) 没有下载源")
            XCTAssertTrue(m.sourceURLs[0].hasSuffix("\(m.fileName).zip"),
                          "下载地址和文件名对不上：\(m.sourceURLs[0])")
        }
    }

    // MARK: - 下载源可达

    func testDownloadURLsAreReachable() async throws {
        for m in ClarityProModel.allCases {
            var req = URLRequest(url: URL(string: m.sourceURLs[0])!)
            req.httpMethod = "HEAD"
            req.setValue("BlackCat/1.0", forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(resp as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200, "\(m.fileName) 下载地址不可达")
            // 体积要过得了 minFileSize 这道校验，否则下下来会被判成"不完整"
            let len = http.expectedContentLength
            XCTAssertGreaterThan(len, Int64(m.minFileSize),
                                 "\(m.fileName) 实际 \(len) 字节，比 minFileSize 还小")
        }
    }

    // MARK: - 真推理（需要模型已下载）

    /// 造一张有明确结构的测试图：斜向渐变 + 一个方块，
    /// 纯色图看不出超分是不是把画面搞坏了
    private func makeTestImage(_ w: Int, _ h: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let inBox = (x > w/3 && x < w*2/3 && y > h/3 && y < h*2/3)
                rgba[i]     = inBox ? 240 : UInt8(x * 255 / max(w - 1, 1))
                rgba[i + 1] = inBox ? 30  : UInt8(y * 255 / max(h - 1, 1))
                rgba[i + 2] = inBox ? 30  : 128
                rgba[i + 3] = 255
            }
        }
        return rgba
    }

    func testEnhanceProducesX4OutputWithRealContent() throws {
        for m in ClarityProModel.allCases {
            try XCTSkipUnless(m.isDownloaded, "\(m.displayName) 未下载，跳过")
            // 用 300x200：比 tileSize(256) 大，能走到真实的多 tile 拼接路径
            let w = 300, h = 200
            let out = try ClarityProEnhancer.enhanceRGBA(makeTestImage(w, h),
                                                         width: w, height: h, model: m)
            let k = m.scale
            XCTAssertEqual(out.count, w * k * h * k * 4,
                           "\(m.displayName) 输出字节数应为 \(k) 倍边长的 RGBA")

            // 输出不能是全黑/全白——转换时输出没乘到 [0,255] 就会整片发黑，
            // 这个坑在 Real-ESRGAN x4plus 转换时踩过
            let rgb = stride(from: 0, to: out.count, by: 4).map { Double(out[$0]) }
            let mean = rgb.reduce(0, +) / Double(rgb.count)
            XCTAssertGreaterThan(mean, 10, "\(m.displayName) 输出几乎全黑")
            XCTAssertLessThan(mean, 245, "\(m.displayName) 输出几乎全白")

            // alpha 必须填满，否则合成时整帧透明
            XCTAssertTrue(stride(from: 3, to: out.count, by: 4).allSatisfy { out[$0] == 255 },
                          "\(m.displayName) 有像素的 alpha 不是 255")
        }
    }

    func testTileSeamsAreContinuous() throws {
        let m = ClarityProModel.animeVideoV3
        try XCTSkipUnless(m.isDownloaded, "模型未下载，跳过")
        // 横向 600 宽会切成 3 个 tile，纵向 1 个。拼接错位会在 tile 边界
        // 留下一条突变的竖线——用相邻列的差值来抓
        let w = 600, h = 100
        let out = try ClarityProEnhancer.enhanceRGBA(makeTestImage(w, h),
                                                     width: w, height: h, model: m)
        let k = m.scale
        let outW = w * k
        let midRow = (h * k / 2) * outW * 4
        var maxJump = 0.0
        for x in 1..<outW {
            let a = Double(out[midRow + x * 4])
            let b = Double(out[midRow + (x - 1) * 4])
            maxJump = max(maxJump, abs(a - b))
        }
        // 测试图在中段有个方块，边界本身就有真实跳变（约 100+），
        // 这里只排除"接缝处出现远超内容的突变"
        XCTAssertLessThan(maxJump, 200, "疑似 tile 拼接错位，出现异常突变 \(maxJump)")
    }
}
