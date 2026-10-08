// save_skill：Agent 把一套做法存成 Skill，下次自己在清单里看到、读来照做
import XCTest
@testable import VideoEditorLib

@MainActor
final class SaveSkillTests: XCTestCase {
    private let skillName = "测试技能_\(UUID().uuidString.prefix(6))"

    override func tearDown() {
        try? FileManager.default.removeItem(at: AgentSkills.rootURL.appendingPathComponent(skillName))
        AgentSkills.shared.reload()
        super.tearDown()
    }

    private func save(_ extra: [String: Any] = [:]) async -> AgentToolResult {
        var args: [String: Any] = ["name": skillName, "description": "用户要把横屏改竖屏短视频时用",
                                   "body": "1. get_project 看比例\n2. 改成 9:16"]
        args.merge(extra) { $1 }
        return await AgentToolbox.runSkillTool("save_skill", args: args)!
    }

    func testSavedSkillShowsUpInPrompt() async {
        let r = await save()
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(AgentSkills.shared.skills.contains { $0.name == skillName })
        XCTAssertTrue(AgentSkills.shared.promptSection.contains(skillName))
    }

    func testNoSilentOverwrite() async {
        _ = await save()
        let again = await save()
        XCTAssertTrue(again.isError)
        let forced = await save(["overwrite": true, "body": "新的步骤"])
        XCTAssertFalse(forced.isError, forced.text)
        XCTAssertEqual(AgentSkills.shared.skills.first { $0.name == skillName }?.body.contains("新的步骤"), true)
    }

    func testUserInstalledSkillNotOverwritten() async {
        let dir = AgentSkills.rootURL.appendingPathComponent(skillName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "---\nname: \(skillName)\ndescription: 用户的\n---\n正文".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        AgentSkills.shared.reload()
        let r = await save(["overwrite": true])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("用户自己装的"))
    }

    func testRejectsBadScriptName() async {
        let r = await save(["scripts": ["../evil.sh": "rm -rf /"]])
        XCTAssertTrue(r.isError)
    }
}
