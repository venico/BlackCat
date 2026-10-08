// get_properties / set_properties：任何片段、轨道的全部字段都能读能改，
// 改完核对，类型不对被解码器悄悄换回默认值的要报出来
import XCTest
@testable import VideoEditorLib

@MainActor
final class PropsToolTests: XCTestCase {

    private func project() -> (ProjectState, TextClip, ShapeClip) {
        let p = ProjectState()
        let t = TextClip(text: "你好", startTime: 0, endTime: 3)
        let s = ShapeClip(type: .rectangle, startTime: 0, endTime: 3)
        p.textTracks[0].clips = [t]
        p.shapeTracks[0].clips = [s]
        return (p, t, s)
    }

    private func run(_ name: String, _ args: [String: Any], _ p: ProjectState) -> AgentToolResult {
        AgentToolbox.runPropsTool(name, args: args, project: p)!
    }

    func testReadAllFields() {
        let (p, t, _) = project()
        let r = run("get_properties", ["target": String("\(t.id)".prefix(8))], p)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("strokeSoftness"), r.text)
        XCTAssertTrue(r.text.contains("animation"), r.text)
    }

    func testWriteFieldsWithoutDedicatedParams() {
        let (p, t, s) = project()
        var r = run("set_properties", ["target": "\(t.id)", "changes": ["strokeSoftness": 0.5, "textColorHex": "#ff0000"]], p)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(p.textTracks[0].clips[0].strokeSoftness, 0.5)
        XCTAssertEqual(p.textTracks[0].clips[0].textColor.toHex(), "#FF0000")
        r = run("set_properties", ["target": "\(s.id)", "changes": ["cornerRadius": 20, "shadowEnabled": true]], p)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(p.shapeTracks[0].clips[0].cornerRadius, 20)
        XCTAssertTrue(p.shapeTracks[0].clips[0].shadowEnabled)
    }

    func testWrongTypeIsReported() {
        let (p, t, _) = project()
        let r = run("set_properties", ["target": "\(t.id)", "changes": ["fontSize": "很大"]], p)
        XCTAssertTrue(r.isError || r.text.contains("没生效"), r.text)
        XCTAssertEqual(p.textTracks[0].clips[0].fontSize, 64)
    }

    func testIdentityFieldsLocked() {
        let (p, t, _) = project()
        let r = run("set_properties", ["target": "\(t.id)", "changes": ["id": UUID().uuidString]], p)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(p.textTracks[0].clips[0].id, t.id)
    }

    func testTrackSettings() {
        let (p, _, _) = project()
        let tid = p.textTracks[0].id
        let r = run("set_properties", ["target": "track:\(tid)", "changes": ["label": "标题层", "isVisible": false]], p)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(p.textTracks[0].label, "标题层")
        XCTAssertFalse(p.textTracks[0].isVisible)
        XCTAssertEqual(p.textTracks[0].clips.count, 1)   // 片段原样保留
    }
}
