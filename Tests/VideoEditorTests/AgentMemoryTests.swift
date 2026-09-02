// Agent 记忆（模块：Agent）
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentMemoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentMemory.shared.clear(isGlobal: true)
        AgentMemory.shared.clear(isGlobal: false)
        AppSettings.shared.agentMemoryEnabled = true
    }

    /// 两层是分开的：全局跟着人，项目跟着片子
    func testTwoScopesAreSeparate() {
        AgentMemory.shared.addGlobal("字幕默认用 48 号")
        AgentMemory.shared.addProject("主角叫悟空")
        XCTAssertEqual(AgentMemory.shared.global.count, 1)
        XCTAssertEqual(AgentMemory.shared.project.count, 1)

        AgentMemory.shared.clear(isGlobal: false)
        XCTAssertEqual(AgentMemory.shared.global.count, 1, "清项目记忆不该动到全局的")
    }

    /// 同一条不重复记
    func testDuplicatesAreIgnored() {
        AgentMemory.shared.addGlobal("字幕默认用 48 号")
        AgentMemory.shared.addGlobal("字幕默认用 48 号")
        XCTAssertEqual(AgentMemory.shared.global.count, 1)
    }

    /// 手动改过的要钉住，免得 Agent 又给覆盖回去
    func testEditedEntryGetsPinned() {
        AgentMemory.shared.addGlobal("字幕用 48 号")
        guard let id = AgentMemory.shared.global.first?.id else { return XCTFail() }
        AgentMemory.shared.update(id: id, text: "字幕用 32 号", isGlobal: true)
        XCTAssertEqual(AgentMemory.shared.global.first?.text, "字幕用 32 号")
        XCTAssertTrue(AgentMemory.shared.global.first?.isPinned ?? false)
    }

    /// 关掉开关之后，记忆不该再进提示词
    func testDisabledMemoryIsNotFedToModel() {
        AgentMemory.shared.addGlobal("字幕默认用 48 号")
        XCTAssertTrue(AgentMemory.shared.promptSection.contains("48"))

        AppSettings.shared.agentMemoryEnabled = false
        XCTAssertTrue(AgentMemory.shared.promptSection.isEmpty,
                      "关了开关就不能再把记忆喂给模型")
        AppSettings.shared.agentMemoryEnabled = true
    }

    /// 关掉之后也不许写
    func testDisabledMemoryRejectsWrites() {
        AppSettings.shared.agentMemoryEnabled = false
        let p = ProjectState()
        let r = AgentToolbox.runEditTool("remember",
                                         args: ["text": "测试", "scope": "global"], project: p)
        XCTAssertEqual(r?.isError, true)
        XCTAssertTrue(AgentMemory.shared.global.isEmpty)
        AppSettings.shared.agentMemoryEnabled = true
    }

    /// 项目记忆要能跟着 .bcj 走 —— 存盘那条路不在主线程上，靠快照读
    func testProjectSnapshotStaysInSync() {
        AgentMemory.shared.addProject("基调偏冷")
        XCTAssertEqual(AgentMemory.projectSnapshot.count, 1)
        AgentMemory.shared.clear(isGlobal: false)
        XCTAssertTrue(AgentMemory.projectSnapshot.isEmpty)
    }

    /// 生成类工具必须标成危险 —— 每调一次都花钱
    func testGenerateToolsAreDangerous() {
        let byName = Dictionary(uniqueKeysWithValues: AgentToolbox.generateTools.map { ($0.name, $0) })
        for n in ["generate_image", "generate_video", "generate_audio"] {
            XCTAssertEqual(byName[n]?.risk, .dangerous, "\(n) 会花钱，该先问用户")
        }
        XCTAssertEqual(byName["list_background_tasks"]?.risk, .readOnly)
    }
}
