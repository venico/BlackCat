// 能力缺口记录：Agent 主动报，或者回了「做不了」却没报时自动兜底记一笔
import XCTest
@testable import VideoEditorLib

final class GapLogTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString).md")
        AgentToolbox.gapLogOverride = file
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        AgentToolbox.gapLogOverride = nil
        super.tearDown()
    }

    private var log: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    func testAgentReport() {
        let r = AgentToolbox.runGapTool(["request": "给视频加关键帧动画", "tried": "search_tools 关键帧",
                                         "missing": "没有关键帧工具", "suggestion": "add_keyframe"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue(log.contains("给视频加关键帧动画"))
        XCTAssertTrue(log.contains("add_keyframe"))
        XCTAssertTrue(log.contains("Agent 报告"))
    }

    func testAutoReportWhenItSaysCannot() {
        AgentToolbox.autoReportGapIfNeeded(prompt: "加个关键帧\n\n[系统说明]",
                                           reply: "抱歉，关键帧动画目前做不了。", calledTools: ["search_tools"])
        XCTAssertTrue(log.contains("自动判定"))
        XCTAssertTrue(log.contains("加个关键帧"))
        XCTAssertFalse(log.contains("系统说明"))
    }

    func testNoDoubleWhenAlreadyReported() {
        AgentToolbox.autoReportGapIfNeeded(prompt: "x", reply: "做不了", calledTools: ["report_gap"])
        XCTAssertEqual(log, "")
    }

    func testNormalReplyNotLogged() {
        AgentToolbox.autoReportGapIfNeeded(prompt: "切一刀", reply: "已经在 30 秒处切开了。", calledTools: ["split_at"])
        XCTAssertEqual(log, "")
    }
}
