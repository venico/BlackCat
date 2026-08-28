// 调节参数（模块：调节轨道）
import XCTest
import CoreImage
@testable import VideoEditorLib

final class ColorAdjustTests: XCTestCase {

    private let ctx = CIContext()
    /// 中灰偏暖的一块，够看出各个方向
    private let src = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4))
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))

    private func px(_ img: CIImage) -> (r: Int, g: Int, b: Int) {
        var b = [UInt8](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &b, rowBytes: 4,
                   bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Int(b[0]), Int(b[1]), Int(b[2]))
    }

    func testEveryKnobActuallyMoves() {
        let base = px(ColorAdjust.apply(src, .identity))
        var knobs: [(String, ColorAdjust)] = [
            ("亮度", ColorAdjust(brightness: 0.3)),
            ("对比", ColorAdjust(contrast: 0.5)),
            ("饱和", ColorAdjust(saturation: 0.6)),
            ("自然饱和", ColorAdjust(vibrance: 0.8)),
            ("曝光", ColorAdjust(exposure: 1.0)),
            ("伽马", ColorAdjust(gamma: 2.0)),
            ("高光", ColorAdjust(highlight: 0.8)),
            ("阴影", ColorAdjust(shadow: 0.8)),
            ("色温", ColorAdjust(temperature: 0.8)),
            ("色调", ColorAdjust(tint: 0.8)),
            ("色相", ColorAdjust(hue: 90)),
        ]
        for (name, adj) in knobs {
            XCTAssertFalse(adj.isIdentity, "\(name)：不该被当成没调过")
            let got = px(ColorAdjust.apply(src, adj))
            XCTAssertNotEqual([got.r, got.g, got.b], [base.r, base.g, base.b],
                              "\(name) 调了却没变化 \(base) → \(got)")
        }
        knobs.removeAll()
    }

    /// 色温正值该变暖（红涨蓝落），符合滑块「左冷右暖」的直觉
    func testTemperatureDirection() {
        let warm = px(ColorAdjust.apply(src, ColorAdjust(temperature: 0.8)))
        let cold = px(ColorAdjust.apply(src, ColorAdjust(temperature: -0.8)))
        XCTAssertGreaterThan(warm.r - warm.b, cold.r - cold.b,
                             "正值该更暖：暖\(warm) 冷\(cold)")
    }

    /// 高光/阴影两个方向都要能调，正值提亮负值压暗。
    /// **各测各的区间**：高光看亮部像素、阴影看暗部像素 ——
    /// 拿中灰去量高光是量不出来的，那个点几乎不受高光控制点影响
    func testHighlightShadowBothWays() {
        func gray(_ v: Double) -> CIImage {
            CIImage(color: CIColor(red: v, green: v, blue: v))
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let bright = gray(0.8), dark = gray(0.2)

        let hUp = px(ColorAdjust.apply(bright, ColorAdjust(highlight: 0.8))).r
        let hDown = px(ColorAdjust.apply(bright, ColorAdjust(highlight: -0.8))).r
        XCTAssertGreaterThan(hUp, hDown, "高光正值该把亮部提亮：\(hUp) vs \(hDown)")

        let sUp = px(ColorAdjust.apply(dark, ColorAdjust(shadow: 0.8))).r
        let sDown = px(ColorAdjust.apply(dark, ColorAdjust(shadow: -0.8))).r
        XCTAssertGreaterThan(sUp, sDown, "阴影正值该把暗部提亮：\(sUp) vs \(sDown)")
    }

    /// 老项目文件里没有新增的那些键，必须还能读出来
    func testOldProjectFileDecodes() throws {
        let old = #"{"brightness":0.5,"contrast":0.2,"saturation":-0.1,"hue":30}"#
        let adj = try JSONDecoder().decode(ColorAdjust.self, from: Data(old.utf8))
        XCTAssertEqual(adj.brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(adj.hue, 30, accuracy: 0.001)
        XCTAssertEqual(adj.gamma, 1, accuracy: 0.001, "缺键的伽马要落在中性值 1，不是 0")
        XCTAssertEqual(adj.vibrance, 0, accuracy: 0.001)
    }

    func testIdentityIsNoOp() {
        XCTAssertTrue(ColorAdjust.identity.isIdentity)
        XCTAssertTrue(ColorAdjust(gamma: 1).isIdentity, "伽马 1 等于没调")
        XCTAssertFalse(ColorAdjust(gamma: 1.5).isIdentity)
    }
}
