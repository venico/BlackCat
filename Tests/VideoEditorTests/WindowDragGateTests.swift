// 预览区顶部的手柄不该被当成"拖窗口"。
//
// 这个 bug 的根因反直觉，测试连同 WindowDragGate.swift 的注释一起把它钉住：
// 顶部 32pt 虽然盖着 NSTitlebarContainerView，但 hitTest 命中的是内容视图本身，
// 而内容视图的 mouseDownCanMoveWindow 默认为 true——所以裁剪手柄按下去拖的是窗口。
import XCTest
import SwiftUI
import AppKit
@testable import VideoEditorLib

final class WindowDragGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    override func tearDown() {
        WindowDragGate.resetForTesting()   // 别把状态漏给别的测试
        super.tearDown()
    }

    @MainActor
    func testHostingViewFollowsTheGate() {
        let host = GatedHostingView(rootView: Color.gray)

        WindowDragGate.resetForTesting()
        XCTAssertTrue(host.mouseDownCanMoveWindow,
                      "没悬停在手柄上时要能正常拖窗口，否则整个窗口就拖不动了")

        WindowDragGate.setClaimed(true)
        XCTAssertFalse(host.mouseDownCanMoveWindow,
                       "悬停在手柄上时必须关掉，否则按下去拖的是窗口不是手柄")
    }

    @MainActor
    func testPlainHostingViewIsTheBuggyBaseline() {
        // 对照组：原来用的 NSHostingView 恒为 true，这就是 bug 的直接来源
        let plain = NSHostingView(rootView: Color.gray)
        XCTAssertTrue(plain.mouseDownCanMoveWindow,
                      "基线行为：普通 NSHostingView 永远允许拖窗口")
    }

    @MainActor
    func testGateRecoversAfterHoverEnds() {
        // hover 进出要能来回切，卡在 false 会让窗口再也拖不动
        WindowDragGate.resetForTesting()
        for _ in 0..<3 {
            WindowDragGate.setClaimed(true)
            XCTAssertFalse(WindowDragGate.allowsWindowDrag)
            WindowDragGate.setClaimed(false)
            XCTAssertTrue(WindowDragGate.allowsWindowDrag)
        }
    }

    /// 用计数而不是布尔的理由：预览区有八个手柄，鼠标从 A 移到 B 时
    /// 两边 hover 回调的顺序不保证。布尔量下 A 的"离开"会压掉 B 的"进入"，
    /// 结果就是明明停在手柄上却仍然能拖走窗口——用户实测遇到的正是这个
    @MainActor
    func testOverlappingHoversDoNotCancelEachOther() {
        WindowDragGate.resetForTesting()
        WindowDragGate.setClaimed(true)    // 进入手柄 A
        WindowDragGate.setClaimed(true)    // 进入手柄 B（两个手柄的命中区挨着/重叠）
        WindowDragGate.setClaimed(false)   // 离开手柄 A —— 晚于 B 的进入
        XCTAssertFalse(WindowDragGate.allowsWindowDrag,
                       "还停在 B 上，不该因为 A 的离开就把窗口拖动放开")
        WindowDragGate.setClaimed(false)   // 真正离开 B
        XCTAssertTrue(WindowDragGate.allowsWindowDrag)
    }

    /// 计数不能被减成负数——多出来的"离开"会让后面的"进入"失效
    @MainActor
    func testExtraReleasesDoNotBreakTheGate() {
        WindowDragGate.resetForTesting()
        for _ in 0..<5 { WindowDragGate.setClaimed(false) }
        WindowDragGate.setClaimed(true)
        XCTAssertFalse(WindowDragGate.allowsWindowDrag,
                       "多余的离开事件不该把计数压到负数，否则之后进入手柄就不生效了")
    }

    /// 顶部区域的 hitTest 归属——这条是整个修法的前提，
    /// 万一以后 AppKit 改了行为（事件真被 titlebar 拿走），这条会先红
    @MainActor
    func testTopAreaHitTestLandsOnContentView() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        let host = GatedHostingView(rootView: Color.gray)
        w.contentView = host
        let themeFrame = try! XCTUnwrap(host.superview)

        // 距窗口顶端 16pt（标题栏范围内）
        let hit = themeFrame.hitTest(NSPoint(x: 300, y: 400 - 16))
        XCTAssertTrue(hit === host,
                      "顶部区域的 hitTest 应该命中内容视图——若命中 titlebar，"
                      + "说明事件被标题栏拿走了，这套开关就失效了，得换别的修法")
    }
}
