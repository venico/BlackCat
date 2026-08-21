// 模块 44：AI 工具入口（v4.6.8）—— TC-AT-001 的代码侧依据
//
// 时间轴工具栏的 AI 下拉按选中片段类型置灰。菜单本身在 View 层测不了，
// 但置灰读的是 ProjectState 上这几个计算属性，可以逐个类型钉死。
// 此前只判断 "!isTranscribing"，点下去要走到 startTranscribe 才弹
// 「请先选择一个视频或音频片段」，等于让人白点一次。
import XCTest
@testable import VideoEditorLib

final class AIToolsGatingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    /// 六种类型各放一个片段，返回它们的 id
    private func makeProject() -> (ProjectState, [String: UUID]) {
        let p = ProjectState()
        let v = VideoClip(assetID: UUID(), name: "v", startTime: 0, endTime: 5)
        let a = AudioClip(assetID: UUID(), name: "a", startTime: 0, endTime: 5)
        let i = ImageClip(assetID: UUID(), name: "i", startTime: 0, endTime: 5)
        let s = SubtitleClip(text: "有内容的字幕", startTime: 0, endTime: 2)
        let t = TextClip(text: "标题", startTime: 0, endTime: 2)
        p.videoTracks[0].clips = [v]
        p.audioTracks[0].clips = [a]
        p.imageTracks[0].clips = [i]
        p.subtitleTracks[0].clips = [s]
        p.textTracks[0].clips = [t]
        return (p, ["v": v.id, "a": a.id, "i": i.id, "s": s.id, "t": t.id])
    }

    private func clearSelection(_ p: ProjectState) {
        p.selectedVideoClipID = nil; p.selectedAudioClipID = nil
        p.selectedImageClipID = nil; p.selectedSubtitleClipID = nil
        p.selectedTextClipID = nil; p.selectedShapeClipID = nil
        p.selectedCompoundClipID = nil; p.selectedClipIDs.removeAll()
    }

    // TC-AT-001: 选中图片时，只有「去除背景」可用
    func testAT001_ImageOnlyEnablesRemoveBackground() {
        let (p, ids) = makeProject()
        clearSelection(p)
        p.selectedImageClipID = ids["i"]

        XCTAssertTrue(p.canRemoveImageBackground, "图片该能去背景")
        XCTAssertFalse(p.canRemoveBackgroundMusic, "图片没有音轨可分离")
        XCTAssertFalse(p.canConvertSubtitleToSpeech, "图片不是字幕")
        XCTAssertFalse(p.canEnhanceClarity, "清晰度提升只对视频")
    }

    // TC-AT-001: 选中视频时，分离音轨和清晰度提升可用，去背景不可用
    func testAT001_VideoEnablesSeparateAndClarity() {
        let (p, ids) = makeProject()
        clearSelection(p)
        p.selectedVideoClipID = ids["v"]

        XCTAssertTrue(p.canRemoveBackgroundMusic)
        XCTAssertTrue(p.canEnhanceClarity)
        XCTAssertFalse(p.canRemoveImageBackground, "去背景只对图片")
        XCTAssertFalse(p.canConvertSubtitleToSpeech)
    }

    // TC-AT-001: 选中音频时只有分离音轨可用（音频没有清晰度概念）
    func testAT001_AudioEnablesSeparateOnly() {
        let (p, ids) = makeProject()
        clearSelection(p)
        p.selectedAudioClipID = ids["a"]

        XCTAssertTrue(p.canRemoveBackgroundMusic)
        XCTAssertFalse(p.canEnhanceClarity, "音频没有清晰度概念")
        XCTAssertFalse(p.canRemoveImageBackground)
        XCTAssertFalse(p.canConvertSubtitleToSpeech)
    }

    // TC-AT-001: 选中字幕时只有「转换成语音」可用
    func testAT001_SubtitleEnablesTTSOnly() {
        let (p, ids) = makeProject()
        clearSelection(p)
        p.selectedSubtitleClipID = ids["s"]

        XCTAssertTrue(p.canConvertSubtitleToSpeech)
        XCTAssertFalse(p.canRemoveImageBackground)
        XCTAssertFalse(p.canRemoveBackgroundMusic)
        XCTAssertFalse(p.canEnhanceClarity)
    }

    // TC-AT-001: 选中标题文字时四项全灰
    func testAT001_TextClipEnablesNothing() {
        let (p, ids) = makeProject()
        clearSelection(p)
        p.selectedTextClipID = ids["t"]

        XCTAssertFalse(p.canRemoveImageBackground)
        XCTAssertFalse(p.canRemoveBackgroundMusic)
        XCTAssertFalse(p.canConvertSubtitleToSpeech)
        XCTAssertFalse(p.canEnhanceClarity)
    }

    // TC-AT-001: 空文本的字幕不算数 —— 转语音没内容可念
    func testAT001_EmptySubtitleDoesNotEnableTTS() {
        let p = ProjectState()
        let blank = SubtitleClip(text: "   ", startTime: 0, endTime: 2)
        p.subtitleTracks[0].clips = [blank]
        p.selectedSubtitleClipID = blank.id

        XCTAssertFalse(p.canConvertSubtitleToSpeech, "空字幕不该点得动转语音")
    }

    // TC-AT-001: 跨轨多选字幕都算进来（转语音不像翻译那样只认单条源轨）
    func testAT001_MultiTrackSubtitleSelectionCounts() {
        let p = ProjectState()
        let s1 = SubtitleClip(text: "第一条", startTime: 0, endTime: 2)
        let s2 = SubtitleClip(text: "第二条", startTime: 3, endTime: 5)
        p.subtitleTracks[0].clips = [s1]
        p.subtitleTracks.append(Track(clips: [s2], label: "字幕2"))
        p.selectedClipIDs = [s1.id, s2.id]

        XCTAssertEqual(p.selectedSubtitleClipsForTTS.count, 2, "跨轨选中的字幕都要算上")
        XCTAssertTrue(p.canConvertSubtitleToSpeech)
    }

}
