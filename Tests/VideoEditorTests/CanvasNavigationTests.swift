// 模块 49：AI 画布导航（v5.1.0，B2）
//
// 画布的平移缩放。锚点缩放算错的话表现是「⌘+滚轮时鼠标底下的东西会跑」，
// 这种手感问题在界面上很难说清，用数值钉死。
import XCTest
@testable import VideoEditorLib

final class CanvasNavigationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    func testZoomClampedToRange() {
        let c = CanvasState()
        c.setZoom(99)
        XCTAssertEqual(c.zoom, CanvasState.maxZoom, "超上限要夹住")
        c.setZoom(0.0001)
        XCTAssertEqual(c.zoom, CanvasState.minZoom, "超下限要夹住")
    }

    // +/- 走固定档位，百分比读数才干净（不是乘系数乘出 137% 这种）
    func testZoomStepsLandOnCleanStops() {
        let c = CanvasState()
        XCTAssertEqual(c.zoomPercent, 100)
        c.zoomIn()
        XCTAssertEqual(c.zoomPercent, 150)
        c.zoomIn()
        XCTAssertEqual(c.zoomPercent, 200)
        c.zoomOut(); c.zoomOut()
        XCTAssertEqual(c.zoomPercent, 100)
        c.zoomOut()
        XCTAssertEqual(c.zoomPercent, 75)
    }

    func testZoomOutStopsAtMin() {
        let c = CanvasState()
        for _ in 0..<20 { c.zoomOut() }
        XCTAssertEqual(c.zoom, CanvasState.minZoom)
    }

    // 锚点缩放：锚点处的内容坐标缩放前后必须不变，否则鼠标底下的东西会跑
    func testAnchoredZoomKeepsPointUnderCursor() {
        let c = CanvasState()
        let container = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 200, y: 150)

        func contentPoint(at p: CGPoint) -> CGPoint {
            let center = CGPoint(x: container.width / 2, y: container.height / 2)
            return CGPoint(x: (p.x - c.offset.width - center.x) / c.zoom + center.x,
                           y: (p.y - c.offset.height - center.y) / c.zoom + center.y)
        }

        let before = contentPoint(at: anchor)
        c.setZoom(2.0, anchor: anchor, containerSize: container)
        let after = contentPoint(at: anchor)

        XCTAssertEqual(before.x, after.x, accuracy: 0.001, "锚点下的内容不该横向漂移")
        XCTAssertEqual(before.y, after.y, accuracy: 0.001, "锚点下的内容不该纵向漂移")
    }

    // 连续缩放也不该累积漂移
    func testRepeatedAnchoredZoomDoesNotDrift() {
        let c = CanvasState()
        let container = CGSize(width: 1000, height: 700)
        let anchor = CGPoint(x: 730, y: 120)

        func contentPoint() -> CGPoint {
            let center = CGPoint(x: container.width / 2, y: container.height / 2)
            return CGPoint(x: (anchor.x - c.offset.width - center.x) / c.zoom + center.x,
                           y: (anchor.y - c.offset.height - center.y) / c.zoom + center.y)
        }

        let before = contentPoint()
        for _ in 0..<10 { c.setZoom(c.zoom * 1.1, anchor: anchor, containerSize: container) }
        for _ in 0..<10 { c.setZoom(c.zoom / 1.1, anchor: anchor, containerSize: container) }
        let after = contentPoint()

        XCTAssertEqual(before.x, after.x, accuracy: 0.01, "来回缩放不该累积漂移")
        XCTAssertEqual(before.y, after.y, accuracy: 0.01)
    }

    func testResetViewRecenters() {
        let c = CanvasState()
        c.setZoom(3)
        c.offset = CGSize(width: 400, height: -250)
        c.resetView()
        XCTAssertEqual(c.zoom, 1.0)
        XCTAssertEqual(c.offset, .zero)
    }

    // 无锚点缩放（点 +/-）不动偏移
    func testUnanchoredZoomKeepsOffset() {
        let c = CanvasState()
        c.offset = CGSize(width: 120, height: 80)
        c.zoomIn()
        XCTAssertEqual(c.offset, CGSize(width: 120, height: 80), "点按钮缩放不该顺带平移画布")
    }
}
