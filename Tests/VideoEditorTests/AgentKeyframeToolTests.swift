// Agent 关键帧工具：list_keyframes / set_keyframes / delete_keyframes
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentKeyframeToolTests: XCTestCase {

    private func run(_ name: String, _ args: [String: Any], _ p: ProjectState) -> AgentToolResult {
        AgentToolbox.runKeyframeTool(name, args: args, project: p)!
    }

    func testSetKeyframesConvertsUIUnitsForVideo() {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), startTime: 0, endTime: 10)
        p.videoTracks[0].clips = [v]
        let id = String(v.id.uuidString.prefix(8))
        let r = run("set_keyframes", ["clip": id, "keyframes": [
            ["property": "position_x", "time": 1, "value": 50],
            ["property": "position_x", "time": 5, "value": 100, "easing": "ease_out"],
            ["property": "opacity", "time": 1, "value": 0],
            ["property": "opacity", "time": 3, "value": 100],
            ["property": "scale", "time": 1, "value": 200],
        ]], p)
        XCTAssertFalse(r.isError, r.text)
        let c = p.videoTracks[0].clips[0]
        XCTAssertEqual(c.animated(atTimeline: 1).offsetX, 0, accuracy: 1e-9, "50% = 居中 = 偏移 0")
        XCTAssertEqual(c.animated(atTimeline: 5).offsetX, 0.5, accuracy: 1e-9, "100% = 偏移 0.5")
        XCTAssertEqual(c.animated(atTimeline: 2).alpha, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.animated(atTimeline: 1).scaleX, 2, accuracy: 1e-9, "scale 宽高一起打")
        XCTAssertEqual(c.animated(atTimeline: 1).scaleY, 2, accuracy: 1e-9)
        XCTAssertNil(c.keyframes?.frames(.offsetX).first?.easing, "第一帧没写 easing = 线性")
        XCTAssertEqual(c.keyframes?.frames(.offsetX).last?.easing, .easeOut, "easing 记在写它的那一帧上")
        XCTAssertTrue(run("list_keyframes", ["clip": id], p).text.contains("position_x"))
    }

    func testEasingAndDelayAreStored() {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), startTime: 0, endTime: 10)
        p.videoTracks[0].clips = [v]
        let id = String(v.id.uuidString.prefix(8))
        _ = run("set_keyframes", ["clip": id, "keyframes": [
            ["property": "rotation", "time": 0, "value": 0, "easing": "ease_in", "delay": 1],
            ["property": "rotation", "time": 4, "value": 90],
        ]], p)
        let c = p.videoTracks[0].clips[0]
        let e = c.keyframes?.frames(.angle).first?.easing
        XCTAssertEqual(e?.x1 ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertEqual(e?.delay ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(c.animated(atTimeline: 0.9).angleDeg, 0, accuracy: 1e-9, "延时内不动")
    }

    func testTextFontSizeAndUnsupportedProperty() {
        let p = ProjectState()
        let t = TextClip(text: "标题", startTime: 0, endTime: 6)
        p.textTracks = [Track(clips: [t])]
        let id = String(t.id.uuidString.prefix(8))
        let r = run("set_keyframes", ["clip": id, "keyframes": [
            ["property": "font_size", "time": 0, "value": 40],
            ["property": "font_size", "time": 4, "value": 120],
            ["property": "volume", "time": 1, "value": 50],
        ]], p)
        XCTAssertFalse(r.isError, "能打的打上了，不能打的报出来")
        XCTAssertTrue(r.text.contains("volume"), r.text)
        XCTAssertEqual(Double(p.textTracks[0].clips[0].animated(atTimeline: 2).fontSize), 80, accuracy: 1e-9)
        XCTAssertEqual(p.textTracks[0].clips[0].animated(atTimeline: 2).posX, 0.5, accuracy: 1e-9, "位置没动")
    }

    func testAudioVolumeAndDelete() {
        let p = ProjectState()
        let a = AudioClip(assetID: UUID(), startTime: 0, endTime: 8)
        p.audioTracks[0].clips = [a]
        let id = String(a.id.uuidString.prefix(8))
        _ = run("set_keyframes", ["clip": id, "keyframes": [
            ["property": "volume", "time": 0, "value": 100],
            ["property": "volume", "time": 4, "value": 0],
        ]], p)
        XCTAssertEqual(Double(p.audioTracks[0].clips[0].animated(atTimeline: 2).volume), 0.5, accuracy: 1e-6)
        _ = run("delete_keyframes", ["clip": id, "property": "volume", "time": 4], p)
        XCTAssertEqual(p.audioTracks[0].clips[0].keyframeTimelineTimes(.volume), [0])
        _ = run("delete_keyframes", ["clip": id], p)
        XCTAssertNil(p.audioTracks[0].clips[0].keyframes, "全删")
        XCTAssertEqual(p.audioTracks[0].clips[0].volume, 1, "回到打关键帧之前的值")
    }

    func testBadInputs() {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), startTime: 0, endTime: 5)
        p.videoTracks[0].clips = [v]
        let id = String(v.id.uuidString.prefix(8))
        XCTAssertTrue(run("set_keyframes", ["clip": "zzzz", "keyframes": [["property": "opacity"]]], p).isError)
        XCTAssertTrue(run("set_keyframes", ["clip": id, "keyframes": [["property": "wobble", "time": 1]]], p).isError)
        XCTAssertTrue(run("set_keyframes", ["clip": id, "keyframes": [["property": "opacity", "time": 9, "value": 0]]], p).isError,
                      "时间不在片段里")
        XCTAssertNil(AgentToolbox.runKeyframeTool("not_mine", args: [:], project: p))
    }

    func testToolsAreRegistered() {
        let names = Set(AgentToolbox.allSpecs.map(\.name))
        for n in ["list_keyframes", "set_keyframes", "delete_keyframes"] { XCTAssertTrue(names.contains(n), n) }
    }
}
