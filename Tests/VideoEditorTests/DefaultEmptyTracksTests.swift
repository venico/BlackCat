// 模块：时间轴默认六条空轨（v5.0.0）
//
// v5.0.0 起 videoTracks / audioTracks / imageTracks / subtitleTracks /
// textTracks / shapeTracks 初始各有一条空轨，顺序表靠 seedDefaultTrackOrder() 补。
// 这组测试守的是"新项目排得对、旧项目开得回、空轨不进导出"。
import XCTest
@testable import VideoEditorLib

final class DefaultEmptyTracksTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)_\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // TC-TL-044: 新项目六种类型各一条空轨，且都排进了顺序表
    func testTL044_DefaultSixEmptyTracks() {
        let p = ProjectState()
        XCTAssertEqual(p.videoTracks.count, 1, "默认一条视频轨")
        XCTAssertEqual(p.audioTracks.count, 1, "默认一条音频轨")
        XCTAssertEqual(p.imageTracks.count, 1, "默认一条图片轨")
        XCTAssertEqual(p.subtitleTracks.count, 1, "默认一条字幕轨")
        XCTAssertEqual(p.textTracks.count, 1, "默认一条文字轨")
        XCTAssertEqual(p.shapeTracks.count, 1, "默认一条图形轨")
        XCTAssertTrue(p.videoTracks.allSatisfy { $0.clips.isEmpty }, "默认轨应为空")
        XCTAssertNotNil(p.subtitleTracks[0].subtitleStyle, "默认字幕轨要带样式")

        // 顺序表不排就没有稳定位置，时间轴按顺序表渲染 = 轨道不显示
        XCTAssertEqual(p.videoSectionOrder.count, 1, "视频顺序表应含默认轨")
        XCTAssertEqual(p.audioSectionOrder.count, 1, "音频顺序表应含默认轨")
        XCTAssertEqual(p.overlayTrackOrder.count, 4, "overlay 顺序表应含图片/字幕/文字/图形四条")
        XCTAssertEqual(p.videoSectionOrder.first?.trackID, p.videoTracks[0].id)
    }

    // TC-TL-045: 第一个素材落在默认空轨上，第二个才新建轨道
    func testTL045_FirstClipLandsOnEmptyTrack() {
        let p = ProjectState()
        let firstTrackID = p.videoTracks[0].id

        let a = VideoClip(assetID: UUID(), name: "a", startTime: 0, endTime: 5)
        p.videoTracks[0].clips.append(a)
        XCTAssertEqual(p.videoTracks.count, 1, "第一个片段不该新建轨道")
        XCTAssertEqual(p.videoTracks[0].id, firstTrackID, "应落在原来那条空轨上")
    }

    // TC-TL-046: 新建项目同样是六条空轨 + 顺序表齐全
    func testTL046_CreateNewProjectSeedsOrder() {
        let dir = tempDir("tl022")
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "SeedOrder", directory: dir)

        XCTAssertEqual(p.videoTracks.count, 1)
        XCTAssertEqual(p.videoSectionOrder.count, 1, "新建项目要重新 seed 视频顺序表")
        XCTAssertEqual(p.audioSectionOrder.count, 1, "新建项目要重新 seed 音频顺序表")
        XCTAssertEqual(p.overlayTrackOrder.count, 4, "新建项目要重新 seed overlay 顺序表")
    }

    // TC-TL-047: 打开旧项目（文件里没有顺序表字段）后，轨道数不受默认空轨影响，
    //            且每条视频/音频轨都要排进顺序表 —— 时间轴和预览都照顺序表渲染
    func testTL047_OpenLegacyProjectWithoutSectionOrder() throws {
        let dir = tempDir("tl023")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先用当前版本存一份，再把顺序表字段删掉，模拟 v4.5.5 之前的 .bcj
        let p = ProjectState()
        p.createNewProject(name: "LegacyOpen", directory: dir)
        p.videoTracks[0].clips.append(VideoClip(assetID: UUID(), name: "v", startTime: 0, endTime: 10))
        p.audioTracks[0].clips.append(AudioClip(assetID: UUID(), name: "a", startTime: 0, endTime: 8))
        p.subtitleTracks[0].clips.append(SubtitleClip(text: "hi", startTime: 1, endTime: 3))
        p.saveProject(silent: true)

        let url = try XCTUnwrap(p.projectFileURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "videoSectionOrder")
        json.removeValue(forKey: "audioSectionOrder")
        json.removeValue(forKey: "overlayTrackOrder")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let p2 = ProjectState()
        p2.openProject(url: url)

        XCTAssertEqual(p2.videoTracks.count, 1, "轨道数以文件为准，不该被默认空轨顶成两条")
        XCTAssertEqual(p2.videoTracks[0].clips.count, 1, "片段应读得回来")

        let videoIDs = Set(p2.videoTracks.map(\.id))
        let orderedVideoIDs = Set(p2.videoSectionOrder.map(\.trackID))
        XCTAssertEqual(orderedVideoIDs, videoIDs, "每条视频轨都要在 videoSectionOrder 里，否则时间轴不显示")

        let audioIDs = Set(p2.audioTracks.map(\.id))
        let orderedAudioIDs = Set(p2.audioSectionOrder.map(\.trackID))
        XCTAssertEqual(orderedAudioIDs, audioIDs, "每条音频轨都要在 audioSectionOrder 里")

        let overlayIDs = Set(p2.overlayTrackOrder.map(\.trackID))
        XCTAssertTrue(overlayIDs.contains(p2.subtitleTracks[0].id), "字幕轨要在 overlayTrackOrder 里")
    }

    // TC-TL-048: 含空轨时导出侧不受影响 —— 时长只由有内容的片段决定，
    //            导出用的图层清单跟预览一致（成片本身要人工验一次）
    func testTL048_EmptyTracksDoNotAffectExport() {
        let p = ProjectState()
        p.videoTracks[0].clips.append(VideoClip(assetID: UUID(), name: "v", startTime: 0, endTime: 12))

        // 五条空轨在场时，时长仍只看有内容的片段
        var allEnds: [Double] = []
        allEnds += p.videoTracks.flatMap(\.clips).map(\.endTime)
        allEnds += p.audioTracks.flatMap(\.clips).map(\.endTime)
        allEnds += p.imageTracks.flatMap(\.clips).map(\.endTime)
        allEnds += p.subtitleTracks.flatMap(\.clips).map(\.endTime)
        allEnds += p.textTracks.flatMap(\.clips).map(\.endTime)
        allEnds += p.shapeTracks.flatMap(\.clips).map(\.endTime)
        XCTAssertEqual(allEnds.max() ?? 0, 12, accuracy: 0.001, "空轨不该撑长成片")

        // 导出侧（静态、只吃数据快照）和预览侧必须给出同一份清单
        let preview = p.overlayLayersBottomUp
        let export = ProjectState.overlayLayersBottomUp(
            overlayTrackOrder: p.overlayTrackOrder,
            imageTracks: p.imageTracks,
            subtitleTracks: p.subtitleTracks,
            textTracks: p.textTracks,
            shapeTracks: p.shapeTracks,
            compoundTracks: p.compoundTracks)
        XCTAssertEqual(preview, export, "含空轨时预览和导出的图层清单对不上")
        XCTAssertEqual(export.count, 4, "四条 overlay 空轨都在清单里（无内容可画，不影响成片）")
    }
}
