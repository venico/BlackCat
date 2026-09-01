// Agent 工具层
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentToolTests: XCTestCase {

    /// 每个工具的 schema 都得能序列化成 JSON —— 序列化不了模型那边直接报错
    func testAllToolSchemasAreValidJSON() {
        let all = AgentToolbox.readTools + AgentToolbox.editTools
        XCTAssertFalse(all.isEmpty)
        for spec in all {
            XCTAssertFalse(spec.name.isEmpty)
            XCTAssertFalse(spec.description.isEmpty, "\(spec.name) 没写说明，模型不知道什么时候该调它")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.parameters),
                          "\(spec.name) 的参数 schema 不是合法 JSON")
        }
    }

    func testToolNamesAreUnique() {
        let names = (AgentToolbox.readTools + AgentToolbox.editTools).map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "有重名的工具")
    }

    /// 删除必须标成危险，否则自动模式会不问自答地删东西
    func testDestructiveToolsAreMarkedDangerous() {
        let byName = Dictionary(uniqueKeysWithValues:
            (AgentToolbox.readTools + AgentToolbox.editTools).map { ($0.name, $0) })
        for n in ["delete_clip"] {
            XCTAssertEqual(byName[n]?.risk, .dangerous, "\(n) 该标成危险操作")
        }
        for n in ["get_project", "list_tracks", "list_assets", "capture_frame"] {
            XCTAssertEqual(byName[n]?.risk, .readOnly, "\(n) 是只读的")
        }
    }

    /// 计划模式只放行只读工具
    func testPlanModeBlocksWrites() {
        XCTAssertNil(AgentMode.plan.rejection(for: .readOnly))
        XCTAssertNotNil(AgentMode.plan.rejection(for: .mutating))
        XCTAssertNotNil(AgentMode.plan.rejection(for: .dangerous))
        // 自动和全权都放行，区别在要不要问
        XCTAssertNil(AgentMode.auto.rejection(for: .dangerous))
        XCTAssertTrue(AgentMode.auto.needsConfirm(for: .dangerous))
        XCTAssertFalse(AgentMode.auto.needsConfirm(for: .mutating))
        XCTAssertFalse(AgentMode.full.needsConfirm(for: .dangerous))
    }

    func testAddTextAndFilterActuallyChangeProject() {
        let p = ProjectState()
        _ = AgentToolbox.runEditTool("add_text", args: ["text": "标题", "start": 1.0, "end": 4.0], project: p)
        let texts = p.textTracks.flatMap(\.clips)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts[0].text, "标题")
        XCTAssertEqual(texts[0].startTime, 1.0, accuracy: 0.01)

        _ = AgentToolbox.runEditTool("add_filter", args: ["kind": "noir", "start": 0.0], project: p)
        XCTAssertEqual(p.filterTracks.flatMap(\.clips).first?.kind, .noir)

        _ = AgentToolbox.runEditTool("add_effect",
                                     args: ["kind": "gaussianBlur", "amount": 0.8], project: p)
        XCTAssertEqual(p.effectTracks.flatMap(\.clips).first?.amount ?? 0, 0.8, accuracy: 0.01)
    }

    /// 找不到东西要给出能自救的提示，不能只说「失败」
    func testMissingIdGivesActionableError() {
        let p = ProjectState()
        let r = AgentToolbox.runEditTool("move_clip", args: ["clip_id": "deadbeef", "start": 2.0], project: p)
        XCTAssertEqual(r?.isError, true)
        XCTAssertTrue(r?.text.contains("list_tracks") ?? false, "报错里该告诉模型下一步查什么")
    }

    func testDeleteRemovesTheClip() {
        let p = ProjectState()
        _ = AgentToolbox.runEditTool("add_text", args: ["text": "x"], project: p)
        guard let id = p.textTracks.flatMap(\.clips).first?.id else { return XCTFail() }
        let r = AgentToolbox.runEditTool("delete_clip",
                                         args: ["clip_id": String("\(id)".prefix(8))], project: p)
        XCTAssertEqual(r?.isError, false)
        XCTAssertTrue(p.textTracks.flatMap(\.clips).isEmpty)
    }

    func testReadToolsDescribeAnEmptyProject() async {
        let p = ProjectState()
        let overview = await AgentToolbox.runReadTool("get_project", args: [:], project: p)
        XCTAssertEqual(overview?.isError, false)
        XCTAssertTrue(overview?.text.contains("时间线") ?? false)

        let assets = await AgentToolbox.runReadTool("list_assets", args: [:], project: p)
        XCTAssertTrue(assets?.text.contains("没有") ?? false, "空素材库要说清楚是空的")
    }
}

/// 执行循环的规则（模式拦截、撤销粒度、系统提示词）
@MainActor
final class AgentRunnerTests: XCTestCase {

    /// 系统提示词要把三个模式的边界说清楚，模型才知道自己能干什么
    func testSystemPromptStatesTheMode() {
        XCTAssertTrue(AgentRunner.systemPrompt(mode: .plan).contains("计划模式"))
        XCTAssertTrue(AgentRunner.systemPrompt(mode: .plan).contains("只能看"))
        XCTAssertTrue(AgentRunner.systemPrompt(mode: .auto).contains("自动模式"))
        XCTAssertTrue(AgentRunner.systemPrompt(mode: .full).contains("全权模式"))
        // 三个模式都得交代「先看清楚再动手」，否则模型会瞎猜时间轴内容
        for m in AgentMode.allCases {
            XCTAssertTrue(AgentRunner.systemPrompt(mode: m).contains("list_tracks"))
        }
    }

    /// 计划模式下工具清单里不该出现写工具 —— 光靠拦截不够，
    /// 把写工具塞给模型看它就会想去调，白费一轮
    func testPlanModeGetsOnlyReadTools() {
        let planTools = AgentToolbox.readTools
        XCTAssertFalse(planTools.contains { $0.risk != .readOnly })
        let autoTools = AgentToolbox.readTools + AgentToolbox.editTools
        XCTAssertTrue(autoTools.contains { $0.risk == .mutating })
    }

    /// Agent 改了一堆东西，撤销要一次全回去
    func testWholeRunUndoesInOneStep() {
        let p = ProjectState()
        let before = p.textTracks.flatMap(\.clips).count

        // 模拟一轮：开跑前打一个快照，期间抑制内部的 pushUndo
        p.pushUndo()
        p.suppressUndoPush = true
        _ = AgentToolbox.runEditTool("add_text", args: ["text": "一"], project: p)
        _ = AgentToolbox.runEditTool("add_text", args: ["text": "二"], project: p)
        _ = AgentToolbox.runEditTool("add_filter", args: ["kind": "noir"], project: p)
        XCTAssertEqual(p.textTracks.flatMap(\.clips).count, before + 2)
        XCTAssertFalse(p.filterTracks.isEmpty)

        p.suppressUndoPush = false
        p.undo()
        XCTAssertEqual(p.textTracks.flatMap(\.clips).count, before, "撤销该一次回到 Agent 动手前")
        XCTAssertTrue(p.filterTracks.flatMap(\.clips).isEmpty)
    }
}
