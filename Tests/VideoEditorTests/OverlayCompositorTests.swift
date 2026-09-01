// 合成器把叠加层画进帧里（预览和导出共用 OverlayRenderer）
import XCTest
import CoreImage
@testable import VideoEditorLib

final class OverlayCompositorTests: XCTestCase {

    private let ctx = CIContext()
    private let size = CGSize(width: 640, height: 360)

    private var blackFrame: CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 画面里有多少个采样点不是纯黑 —— 用来判断叠加层到底画上去没有
    private func inkCount(_ img: CIImage) -> Int {
        var n = 0
        for gx in stride(from: 0.05, through: 0.95, by: 0.05) {
            for gy in stride(from: 0.05, through: 0.95, by: 0.05) {
                var b = [UInt8](repeating: 0, count: 4)
                ctx.render(img, toBitmap: &b, rowBytes: 4,
                           bounds: CGRect(x: Int(gx * size.width), y: Int(gy * size.height),
                                          width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                if b[0] > 12 || b[1] > 12 || b[2] > 12 { n += 1 }
            }
        }
        return n
    }

    override func tearDown() {
        ColorCompositor.setOverlayInput(ColorCompositor.OverlayInput())
        super.tearDown()
    }

    /// 文字图层要能被合成器画到帧上
    func testTextLayerGetsDrawn() {
        var clip = TextClip(startTime: 0, endTime: 5)
        clip.text = "测试文字"
        clip.fontSize = 80
        clip.posX = 0.5; clip.posY = 0.5
        let track = Track(clips: [clip], label: "文字")

        ColorCompositor.setOverlayInput(ColorCompositor.OverlayInput(
            order: [.text(track.id)], textTracks: [track], fontScale: 1))

        let out = ColorCompositor.drawOverlays(blackFrame, at: 1, renderSize: size)
        XCTAssertGreaterThan(inkCount(out), 0, "文字没被画到帧上")
    }

    /// 图形图层同上
    func testShapeLayerGetsDrawn() {
        var clip = ShapeClip(type: .rectangle, startTime: 0, endTime: 5)
        clip.posX = 0.5; clip.posY = 0.5
        clip.width = 300; clip.height = 200
        let track = Track(clips: [clip], label: "图形")

        ColorCompositor.setOverlayInput(ColorCompositor.OverlayInput(
            order: [.shape(track.id)], shapeTracks: [track], fontScale: 1))

        let out = ColorCompositor.drawOverlays(blackFrame, at: 1, renderSize: size)
        XCTAssertGreaterThan(inkCount(out), 0, "图形没被画到帧上")
    }

    /// 效果轨道只作用于排在它下面的图层
    func testEffectAppliesToWhatIsBelow() {
        var text = TextClip(startTime: 0, endTime: 5)
        text.text = "ABC"; text.fontSize = 100
        let tTrack = Track(clips: [text], label: "文字")
        let fx = EffectClip(kind: .gaussianBlur, startTime: 0, endTime: 5)
        let fxTrack = Track(clips: [fx], label: "特效")

        ColorCompositor.setEffectTracks([fxTrack])
        defer { ColorCompositor.setEffectTracks([]) }
        // 顺序是从底到顶：文字在下，特效在上
        ColorCompositor.setOverlayInput(ColorCompositor.OverlayInput(
            order: [.text(tTrack.id), .effect(fxTrack.id)],
            textTracks: [tTrack], fontScale: 1))

        let withFx = ColorCompositor.drawOverlays(blackFrame, at: 1, renderSize: size)
        ColorCompositor.setOverlayInput(ColorCompositor.OverlayInput(
            order: [.text(tTrack.id)], textTracks: [tTrack], fontScale: 1))
        let plain = ColorCompositor.drawOverlays(blackFrame, at: 1, renderSize: size)

        XCTAssertGreaterThan(inkCount(plain), 0, "对照组的文字就没画出来")
        XCTAssertNotEqual(inkCount(withFx), inkCount(plain), "特效没作用到它下面的文字上")
    }
}
