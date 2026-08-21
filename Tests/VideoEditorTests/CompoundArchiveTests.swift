// 模块 26：复合片段存档与导出完整性（v4.5.5）
//
// v4.5.5 之前 ProjectDocument 里根本没有 compoundTracks 字段，复合片段存盘即丢，
// 而且不报任何错——保存、退出、重开，时间轴上就少了一块。
// 这组测试守的就是"存得进、读得回、旧文件还能开"。
import XCTest
@testable import VideoEditorLib

final class CompoundArchiveTests: XCTestCase {

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

    /// 造一个含视频 + 字幕的复合片段
    private func makeCompound(start: Double = 2, end: Double = 8) -> CompoundClip {
        var c = CompoundClip(startTime: start, endTime: end)
        c.name = "存档测试片段"
        var vt = Track<VideoClip>()
        vt.clips = [VideoClip(assetID: UUID(), name: "内部视频", startTime: 0, endTime: 6)]
        var st = Track<SubtitleClip>()
        st.clips = [SubtitleClip(text: "内部字幕", startTime: 0, endTime: 3)]
        c.videoTracks = [vt]
        c.subtitleTracks = [st]
        c.overlayTrackOrder = [.subtitle(st.id)]
        return c
    }

    // TC-CP-010: 复合片段存档往返 —— 保存、重开后仍在，位置时长内部内容一致
    func testCP010_CompoundSurvivesSaveReopen() {
        let dir = tempDir("cp010")
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "CompoundRoundTrip", directory: dir)

        let compound = makeCompound()
        var track = Track<CompoundClip>()
        track.label = "复合"
        track.clips = [compound]
        p.compoundTracks = [track]
        p.saveProject(silent: true)

        let reopened = ProjectState()
        reopened.openProject(url: p.projectFileURL!)

        XCTAssertEqual(reopened.compoundTracks.count, 1, "复合片段轨道整条丢了")
        guard let c = reopened.compoundTracks.first?.clips.first else {
            return XCTFail("复合片段没读回来")
        }
        XCTAssertEqual(c.id, compound.id)
        XCTAssertEqual(c.name, "存档测试片段")
        XCTAssertEqual(c.startTime, 2, accuracy: 0.0001)
        XCTAssertEqual(c.endTime, 8, accuracy: 0.0001)
        XCTAssertEqual(c.videoTracks.first?.clips.first?.name, "内部视频", "内部视频内容丢了")
        XCTAssertEqual(c.subtitleTracks.first?.clips.first?.text, "内部字幕", "内部字幕内容丢了")
        XCTAssertEqual(c.overlayTrackOrder.count, 1, "复合片段自己的图层顺序没存住")
    }

    // TC-CP-011: 轨道层级位置持久化 —— 复合片段按归属可能落在视频/音频区，
    // 只存 overlayTrackOrder 的话重开后位置会跑掉
    func testCP011_SectionOrderPersists() {
        let dir = tempDir("cp011")
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "SectionOrder", directory: dir)

        var ct = Track<CompoundClip>()
        ct.clips = [makeCompound()]
        p.compoundTracks = [ct]
        let videoTrackID = p.videoTracks[0].id
        // 复合轨排在视频轨上面
        p.videoSectionOrder = [.compound(ct.id), .video(videoTrackID)]
        // 新项目默认只有一条视频轨，音频轨要自己建
        let audioTrack = Track<AudioClip>(label: "音频")
        p.audioTracks = [audioTrack]
        p.audioSectionOrder = [.audio(audioTrack.id)]
        p.saveProject(silent: true)

        let reopened = ProjectState()
        reopened.openProject(url: p.projectFileURL!)

        XCTAssertEqual(reopened.videoSectionOrder,
                       [.compound(ct.id), .video(videoTrackID)],
                       "视频区顺序没存住，复合片段重开后会跑位")
        XCTAssertEqual(reopened.audioSectionOrder.count, 1)
    }

    // TC-CP-012: 旧版本 .bcj 兼容 —— 没有这三个新字段的文件要能正常打开
    func testCP012_OldProjectFileWithoutNewFieldsOpens() throws {
        let dir = tempDir("cp012")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 三个新字段为 nil：合成的 Codable 用 encodeIfPresent，nil 不会写进 JSON，
        // 得到的正是 v4.5.0 及更早版本的文件格式
        var vt = Track<VideoClip>()
        vt.clips = [VideoClip(assetID: UUID(), name: "老片段", startTime: 0, endTime: 4)]
        let doc = ProjectDocument(
            name: "OldProject",
            videoTracks: [vt],
            audioTracks: [Track<AudioClip>()],
            imageTracks: [],
            subtitleTracks: [],
            subtitleStyles: [],
            textTracks: nil, textTemplates: nil, shapeTracks: nil,
            mediaAssets: [],
            exportSettings: ExportSettings(),
            previewResolution: "1080p",
            previewAspectRatio: nil,
            customOutputWidth: nil, customOutputHeight: nil,
            projectFPS: nil, projectBitrate: nil,
            subtitleBottomMargin: nil, subtitleLineSpacing: nil,
            overlayTrackOrder: nil,
            compoundTracks: nil,
            videoSectionOrder: nil,
            audioSectionOrder: nil)

        let url = dir.appendingPathComponent("old.bcj")
        let data = try JSONEncoder().encode(doc)
        try data.write(to: url)

        // 确认写出来的确实是"旧格式"——不含新字段
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("compoundTracks"), "这条测试的前提是文件里没有新字段")

        let p = ProjectState()
        p.openProject(url: url)

        // 项目名取的是文件名，不是 doc.name（文件改名后项目名跟着走）
        XCTAssertEqual(p.projectName, "old", "旧文件打不开")
        XCTAssertFalse(p.showWelcome, "打开成功应该离开欢迎页")
        XCTAssertEqual(p.videoTracks.first?.clips.first?.name, "老片段", "旧文件的内容没读出来")
        XCTAssertTrue(p.compoundTracks.isEmpty, "无复合片段数据时该按空处理")
        // 缺 sectionOrder 的旧文件由 syncOverlayOrder() 按现有轨道补齐。
        // 时间轴是照这张表渲染的，补不上的话轨道会整条不显示
        XCTAssertEqual(p.videoSectionOrder, [.video(p.videoTracks[0].id)],
                       "旧文件缺 videoSectionOrder，加载时该按现有轨道补齐")
    }

    // TC-CP-014: 图层顺序里外一致 —— 预览和导出必须用同一份清单
    func testCP014_PreviewAndExportShareSameLayerList() {
        let p = ProjectState()
        var it = Track<ImageClip>()
        var st = Track<SubtitleClip>()
        var tt = Track<TextClip>()
        it.clips = []; st.clips = []; tt.clips = []
        p.imageTracks = [it]
        p.subtitleTracks = [st]
        p.textTracks = [tt]
        p.shapeTracks = []   // v5.0.0 起默认带一条空图形轨，留着会被兜底补进清单
        // 顶到底：文字、字幕、图片
        p.overlayTrackOrder = [.text(tt.id), .subtitle(st.id), .image(it.id)]

        // 预览侧走实例属性
        let preview = p.overlayLayersBottomUp
        // 导出侧走静态方法（导出在 nonisolated 上下文里只有数据快照）
        let export = ProjectState.overlayLayersBottomUp(
            overlayTrackOrder: p.overlayTrackOrder,
            imageTracks: p.imageTracks,
            subtitleTracks: p.subtitleTracks,
            textTracks: p.textTracks,
            shapeTracks: p.shapeTracks,
            compoundTracks: p.compoundTracks)

        XCTAssertEqual(preview, export, "预览和导出的图层顺序对不上，成片叠放就会跟预览不一样")
        // index 0 = 最底下。overlayTrackOrder 是从顶到底存的，所以要反过来
        XCTAssertEqual(preview, [.image(it.id), .subtitle(st.id), .text(tt.id)])
    }

    // 没登记进 overlayTrackOrder 的轨道要兜底补进来，压在最底下。
    // "渲染完全照表走"之后，漏一条的后果是整条内容消失，不是顺序不对
    func testUnlistedTracksAreStillRendered() {
        let p = ProjectState()
        var listed = Track<SubtitleClip>()
        var orphanImage = Track<ImageClip>()
        var orphanCompound = Track<CompoundClip>()
        listed.clips = []; orphanImage.clips = []; orphanCompound.clips = []
        p.subtitleTracks = [listed]
        p.imageTracks = [orphanImage]
        p.compoundTracks = [orphanCompound]
        p.textTracks = []; p.shapeTracks = []   // v5.0.0 的默认空轨会一起被兜底补进来
        p.overlayTrackOrder = [.subtitle(listed.id)]   // 只登记了字幕轨

        let layers = p.overlayLayersBottomUp

        XCTAssertEqual(layers.count, 3, "没登记的轨道被漏掉了，它们的内容会彻底不显示")
        XCTAssertEqual(layers.last, .subtitle(listed.id), "登记过的该在上面")
        XCTAssertTrue(layers.dropLast().contains(.image(orphanImage.id)))
        XCTAssertTrue(layers.dropLast().contains(.compound(orphanCompound.id)))
    }

    // 隐藏的轨道不进清单（TC-CP-016 的代码侧依据）
    func testHiddenTracksAreExcluded() {
        let p = ProjectState()
        var hidden = Track<ImageClip>()
        hidden.isVisible = false
        p.imageTracks = [hidden]
        p.subtitleTracks = []; p.textTracks = []; p.shapeTracks = []   // 只留这条隐藏轨
        p.overlayTrackOrder = []

        XCTAssertTrue(p.overlayLayersBottomUp.isEmpty, "隐藏轨道不该被兜底补进渲染清单")
    }

    // 复合片段内部的图层顺序走自己那份 overlayTrackOrder，规则跟外层一致
    func testCompoundInternalLayerOrderUsesItsOwnList() {
        var c = CompoundClip(startTime: 0, endTime: 5)
        var img = Track<ImageClip>()
        var sub = Track<SubtitleClip>()
        img.clips = []; sub.clips = []
        c.imageTracks = [img]
        c.subtitleTracks = [sub]
        c.overlayTrackOrder = [.subtitle(sub.id), .image(img.id)]   // 字幕在上

        XCTAssertEqual(c.overlayLayersBottomUp, [.image(img.id), .subtitle(sub.id)])
    }
}
