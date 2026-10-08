// search_tools：按功能搜全部工具，搜到的组自动挂上。
// 守的是「明明有却说没有」—— 加图形、改圆角投影曾因不在模型要的那组里被回「没有这个功能」
import XCTest
@testable import VideoEditorLib

@MainActor
final class SearchToolsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentToolGate.shared.reset()
    }

    func testFindsShapeTools() {
        let r = AgentToolGate.shared.search("加矩形 圆角 投影")
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("add_shape"), r.text)
        XCTAssertTrue(r.text.contains("update_clip"), r.text)
    }

    func testFoundToolsBecomeAvailable() {
        let before = AgentToolGate.shared.tools(mode: .full, inCanvas: false).map(\.name)
        XCTAssertFalse(before.contains("add_shape"))
        _ = AgentToolGate.shared.search("图形")
        let after = AgentToolGate.shared.tools(mode: .full, inCanvas: false).map(\.name)
        XCTAssertTrue(after.contains("add_shape"))
    }

    func testNoMatchSaysSo() {
        let r = AgentToolGate.shared.search("zzqqxx")
        XCTAssertTrue(r.text.contains("没搜到"))
    }
}
