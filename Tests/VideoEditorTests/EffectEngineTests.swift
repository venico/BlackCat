// 特效引擎（模块：效果 → 特效）
import XCTest
import CoreImage
@testable import VideoEditorLib

final class EffectEngineTests: XCTestCase {

    private let ctx = CIContext()
    private let size = CGSize(width: 200, height: 200)

    /// 棋盘格：高频细节，模糊/像素化/锐化在这种图上才量得出来
    private var src: CIImage {
        CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputWidth": 6.0,
            "inputColor0": CIColor(red: 0.95, green: 0.9, blue: 0.2),
            "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.7)
        ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func samples(_ img: CIImage) -> [[UInt8]] {
        [(31, 31), (64, 64), (97, 33), (120, 150), (160, 80)].map { p in
            var b = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &b, rowBytes: 4,
                       bounds: CGRect(x: p.0, y: p.1, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return b
        }
    }

    private func maxDiff(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        zip(a, b).flatMap { zip($0, $1).map { abs(Int($0) - Int($1)) } }.max() ?? 0
    }

    /// 26 个特效每个都得真的改变画面 —— 参数名写错、单位换算错都会静默变成没效果
    func testEveryEffectChangesTheImage() {
        let base = samples(src)
        var dead: [String] = []
        for kind in EffectKind.allCases {
            var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
            clip.intensity = 1
            let out = EffectEngine.apply(clip, to: src, renderSize: size)
            if maxDiff(base, samples(out)) < 4 { dead.append("\(kind.label)(\(kind.rawValue))") }
        }
        XCTAssertTrue(dead.isEmpty, "这些特效调了却没变化：\(dead.joined(separator: "、"))")
    }

    /// 强度 0 等于没套
    func testZeroIntensityIsNoOp() {
        let base = samples(src)
        for kind in EffectKind.allCases {
            var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
            clip.intensity = 0
            XCTAssertEqual(maxDiff(base, samples(EffectEngine.apply(clip, to: src, renderSize: size))), 0,
                           "\(kind.label)：强度 0 还是改了画面")
        }
    }

    /// 输出不能比原图大 —— 模糊和扭曲会把画面撑出边框，不裁回去会越叠越大
    func testOutputKeepsOriginalExtent() {
        for kind in EffectKind.allCases {
            var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
            clip.amount = 1
            let out = EffectEngine.apply(clip, to: src, renderSize: size)
            XCTAssertEqual(out.extent, src.extent, "\(kind.label) 把画面撑大了：\(out.extent)")
        }
    }

    /// 尺寸参数按画面宽度换算：同样的 amount，画面越大模糊得越多（像素上）
    func testAmountScalesWithRenderSize() {
        var clip = EffectClip(kind: .gaussianBlur, startTime: 0, endTime: 1)
        clip.amount = 0.5
        let small = EffectEngine.apply(clip, to: src, renderSize: CGSize(width: 200, height: 200))
        let large = EffectEngine.apply(clip, to: src, renderSize: CGSize(width: 2000, height: 2000))
        XCTAssertGreaterThan(maxDiff(samples(small), samples(large)), 4,
                             "换了画面尺寸模糊程度该跟着变，说明参数没按分辨率换算")
    }

    /// 老项目文件里没有特效字段，加进来之后仍要能解开
    func testClipDecodesWithMissingFields() throws {
        let old = #"{"id":"\#(UUID().uuidString)","startTime":1,"endTime":4}"#
        let clip = try JSONDecoder().decode(EffectClip.self, from: Data(old.utf8))
        XCTAssertEqual(clip.kind, .gaussianBlur)
        XCTAssertEqual(clip.intensity, 1, accuracy: 0.001)
        XCTAssertEqual(clip.centerX, 0.5, accuracy: 0.001)
    }

    /// 换分辨率导出，效果的**相对强度**不能变。
    ///
    /// 这是「视频 / 图片 / 导出三边一致」的数学前提：参数存的是占画面宽度的比例，
    /// 1080p 和 4K 上算出来的像素半径不同，但相对画面的比例必须相同
    func testRelativeStrengthIsResolutionIndependent() {
        func checker(_ w: Int) -> CIImage {
            // 格子数固定，所以两张图内容比例完全一样，只是分辨率不同
            CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputWidth": Double(w) / 20.0,
                "inputColor0": CIColor(red: 0.95, green: 0.9, blue: 0.2),
                "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.7)
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: w))
        }
        /// 按相对坐标取样，跟分辨率无关
        func sample(_ img: CIImage, _ w: Int) -> [[UInt8]] {
            [(0.2, 0.2), (0.35, 0.5), (0.5, 0.5), (0.7, 0.3), (0.85, 0.75)].map { p in
                var b = [UInt8](repeating: 0, count: 4)
                ctx.render(img, toBitmap: &b, rowBytes: 4,
                           bounds: CGRect(x: Int(p.0 * Double(w)), y: Int(p.1 * Double(w)),
                                          width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                return b
            }
        }

        for kind in [EffectKind.gaussianBlur, .pixellate, .twirl, .bloom] {
            var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
            clip.amount = 0.4
            let small = EffectEngine.apply(clip, to: checker(400),
                                           renderSize: CGSize(width: 400, height: 400))
            let large = EffectEngine.apply(clip, to: checker(1600),
                                           renderSize: CGSize(width: 1600, height: 1600))
            let d = maxDiff(sample(small, 400), sample(large, 1600))
            // 重采样和边界处理有误差，但同一相对位置的颜色应该接近
            XCTAssertLessThan(d, 90,
                "\(kind.label)：400 和 1600 上的相对强度差太多（\(d)），说明参数没按画面比例换算")
        }
    }
}

/// 特效在视频帧那条链上的实际强度。
/// 视频画面走 ColorCompositor，参数按渲染分辨率换算——这里量的就是那条路
final class EffectOnVideoFrameTests: XCTestCase {
    private let ctx = CIContext()

    /// 1920x1080，接近真实素材的尺度
    private func frame() -> CIImage {
        CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputWidth": 60.0,
            "inputColor0": CIColor(red: 0.9, green: 0.85, blue: 0.3),
            "inputColor1": CIColor(red: 0.15, green: 0.4, blue: 0.55)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    private func changedRatio(_ a: CIImage, _ b: CIImage) -> Double {
        // 在画面上撒一圈点，数有多少个被改动了
        var changed = 0, total = 0
        for gx in stride(from: 0.1, through: 0.9, by: 0.1) {
            for gy in stride(from: 0.15, through: 0.85, by: 0.1) {
                total += 1
                let r = CGRect(x: Int(gx * 1920), y: Int(gy * 1080), width: 1, height: 1)
                var p1 = [UInt8](repeating: 0, count: 4), p2 = p1
                ctx.render(a, toBitmap: &p1, rowBytes: 4, bounds: r, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
                ctx.render(b, toBitmap: &p2, rowBytes: 4, bounds: r, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
                if zip(p1, p2).contains(where: { abs(Int($0) - Int($1)) > 8 }) { changed += 1 }
            }
        }
        return Double(changed) / Double(total)
    }

    /// 强度拉满时，画面上大部分地方都该被改动 —— 只动几个点说明参数量程不够
    func testStrongEffectsCoverMostOfTheFrame() {
        let src = frame()
        // 这几类只该改动一部分画面：像素化/晶格是量化，大量采样点会落回原色；
        // 降噪在没有噪点的测试图上本来就几乎不动；线条类只留边缘
        let partial: Set<EffectKind> = [.pixellate, .crystallize, .pointillize,
                                        .noiseReduction,
                                        .edges, .edgeWork, .lineOverlay,
                                        .bump, .hole, .circleSplash, .lightTunnel]
        // 漩涡是纯旋转，采样点转过去常常落回同色，覆盖率天然偏低；
        // 它的量程另有 testVortexNeedsBigAngle 盯着
        var weak: [String] = []
        for kind in EffectKind.allCases where !partial.contains(kind) && kind != .vortex {
            var clip = EffectClip(kind: kind, startTime: 0, endTime: 1)
            clip.intensity = 1
            clip.amount = 1
            let out = EffectEngine.apply(clip, to: src, renderSize: CGSize(width: 1920, height: 1080))
            let ratio = changedRatio(src, out)
            if ratio < 0.5 { weak.append("\(kind.label) \(Int(ratio * 100))%") }
        }
        XCTAssertTrue(weak.isEmpty,
                      "这些特效开到最大也只改动了小部分画面：\(weak.joined(separator: "、"))")
    }

    /// 漩涡的默认角度得够大。
    /// 实测 720° 在 1920 宽的画面上只改动 14%，用户拉满强度也看不出变化
    func testVortexNeedsBigAngle() {
        let src = frame()
        let clip = EffectClip(kind: .vortex, startTime: 0, endTime: 1)
        XCTAssertGreaterThanOrEqual(clip.angle, 1800, "漩涡默认角度太小，效果看不出来")
        XCTAssertGreaterThanOrEqual(EffectKind.vortex.angleRange.upperBound, 5000,
                                    "漩涡的角度量程要留到 5000 以上才够用")
        let out = EffectEngine.apply(clip, to: src, renderSize: CGSize(width: 1920, height: 1080))
        XCTAssertGreaterThan(changedRatio(src, out), 0.3, "漩涡按默认参数改动的画面太少")
    }
}
