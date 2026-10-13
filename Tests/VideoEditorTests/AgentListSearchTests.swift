// Agent 列表类工具：先搜、搜不到放宽、结果分页；每轮带上选中 / 播放头下的片段
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentListSearchTests: XCTestCase {

    /// 素材库是全局单例，塞进去的不清掉会串到后面的用例（「空素材库」那条）
    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    override func tearDown() {
        MediaLibrary.shared.resetForTesting()
        super.tearDown()
    }

    private func listAssets(_ p: ProjectState, _ args: [String: Any]) async -> String {
        await AgentToolbox.runReadTool("list_assets", args: args, project: p)!.text
    }

    private func addImages(_ p: ProjectState, _ names: [String]) {
        for n in names {
            p.mediaAssets.append(MediaAsset(url: URL(fileURLWithPath: "/tmp/\(n).png"), name: n + ".png", type: .image))
        }
    }

    /// 搜出来的不再只给前 40 个：分页，每个都翻得到
    func testAssetSearchPagesInsteadOfCutting() async {
        let p = ProjectState()
        addImages(p, (0..<60).map { "cat_\($0)" } + (0..<30).map { "dog_\($0)" })
        let p1 = await listAssets(p, ["name": "cat"])
        XCTAssertTrue(p1.contains("60 个") && p1.contains("第 1/2 页"), p1)
        XCTAssertTrue(p1.contains("page=2"))
        let p2 = await listAssets(p, ["name": "cat", "page": 2])
        XCTAssertTrue(p2.contains("cat_0.png"), "最早加入的在第 2 页能翻到")
        XCTAssertFalse(p2.contains("dog_"))
    }

    /// 几个词都要有；没有再放宽（任意一个词 / 忽略空格下划线），并说明是放宽的
    func testAssetSearchExactThenRelaxed() async {
        let p = ProjectState()
        addImages(p, ["gpt_image_AB12", "watercolor_cat", "photo_dog"])
        let exact = await listAssets(p, ["name": "watercolor cat"])
        XCTAssertTrue(exact.contains("watercolor_cat") && !exact.contains("放宽"))
        let loose = await listAssets(p, ["name": "gpt image"])
        XCTAssertTrue(loose.contains("gpt_image_AB12"))
        let anyWord = await listAssets(p, ["name": "cat horse"])
        XCTAssertTrue(anyWord.contains("放宽") && anyWord.contains("watercolor_cat"))
        let none = await listAssets(p, ["name": "zebra"])
        XCTAssertTrue(none.contains("没搜到") && none.contains("image"), "搜不到给目录")
    }

    /// 每轮带上选中的、播放头下的片段（带 id）
    func testEditorStateNoteHasSelectionAndPlayhead() {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), startTime: 0, endTime: 100)
        p.videoTracks[0].clips = [v]
        p.subtitleTracks = [Track(clips: [SubtitleClip(text: "第一句", startTime: 4, endTime: 6),
                                           SubtitleClip(text: "第二句", startTime: 6, endTime: 8)])]
        p.currentTime = 5
        p.selectedClipIDs = [v.id]
        let note = AgentToolbox.editorStateNote(p)
        let vid = String(v.id.uuidString.prefix(8))
        XCTAssertTrue(note.contains("选中（1 个）") && note.contains(vid), note)
        XCTAssertTrue(note.contains("第一句") && !note.contains("第二句"), "播放头下只列这一刻的")
    }

    /// 标记列表也分页、可按标题搜
    func testMarkerListSearchAndPage() {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), startTime: 0, endTime: 200)
        p.videoTracks[0].clips = [v]
        for i in 0..<50 {
            _ = AgentToolbox.runProjectTool("marker", args: ["action": "add", "clip_id": String(v.id.uuidString.prefix(8)),
                                                          "time": Double(i) + 0.5, "title": i % 2 == 0 ? "高潮\(i)" : "转场\(i)"],
                                         project: p)
        }
        let all = AgentToolbox.runProjectTool("marker", args: ["action": "list"], project: p)!.text
        XCTAssertTrue(all.contains("50 个") && all.contains("第 1/2 页"), all)
        let hits = AgentToolbox.runProjectTool("marker", args: ["action": "list", "query": "高潮"], project: p)!.text
        XCTAssertTrue(hits.contains("25 个") && !hits.contains("转场"), hits)
    }
}
