// 模块 47：全局素材库（v5.1.0）
//
// 素材从「每个项目一份」改成「全 app 一份」。这组守两件事：
// 打开项目不能把别的项目的素材冲掉；同一个文件在全局库里只留一条，
// 项目里引用旧 id 的片段要被重映射过去（改全局那条的 id 会让别的项目失效）。
import XCTest
@testable import VideoEditorLib

final class MediaLibraryGlobalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    private func asset(_ path: String, id: UUID = UUID()) -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, type: .video)
    }

    // 两个 ProjectState 看到同一份素材库
    func testTwoProjectsShareOneLibrary() {
        let a = ProjectState()
        let b = ProjectState()
        a.mediaAssets.append(asset("/tmp/shared.mp4"))
        XCTAssertEqual(b.mediaAssets.count, 1, "另一个项目应立刻看到同一条素材")
        XCTAssertEqual(a.mediaAssets.first?.id, b.mediaAssets.first?.id)
    }

    // merge：新文件进库，已有文件不重复进
    func testMergeAddsNewAndSkipsExisting() {
        let lib = MediaLibrary.shared
        lib.assets = [asset("/tmp/one.mp4")]
        _ = lib.merge([asset("/tmp/one.mp4"), asset("/tmp/two.mp4")])
        XCTAssertEqual(lib.assets.count, 2, "同一个文件不该进两条")
        XCTAssertEqual(Set(lib.assets.map(\.url.path)), ["/tmp/one.mp4", "/tmp/two.mp4"])
    }

    // merge：同一个文件的不同 id，返回 旧→全局 的映射，且不动全局那条的 id
    func testMergeReturnsRemapAndKeepsGlobalID() {
        let lib = MediaLibrary.shared
        let globalID = UUID()
        lib.assets = [asset("/tmp/same.mp4", id: globalID)]

        let projectID = UUID()
        let remap = lib.merge([asset("/tmp/same.mp4", id: projectID)])

        XCTAssertEqual(remap[projectID], globalID, "项目里的旧 id 应映射到全局 id")
        XCTAssertEqual(lib.assets.first?.id, globalID, "全局那条的 id 不能被改，别的项目还在引用它")
        XCTAssertEqual(lib.assets.count, 1)
    }

    // 重映射要覆盖所有片段类型
    func testRemapCoversAllClipTypes() {
        let p = ProjectState()
        let oldID = UUID(), newID = UUID()
        p.videoTracks[0].clips = [VideoClip(assetID: oldID, name: "v", startTime: 0, endTime: 5)]
        p.audioTracks[0].clips = [AudioClip(assetID: oldID, name: "a", startTime: 0, endTime: 5)]
        p.imageTracks[0].clips = [ImageClip(assetID: oldID, name: "i", startTime: 0, endTime: 5)]

        p.remapAssetIDs([oldID: newID])

        XCTAssertEqual(p.videoTracks[0].clips[0].assetID, newID)
        XCTAssertEqual(p.audioTracks[0].clips[0].assetID, newID)
        XCTAssertEqual(p.imageTracks[0].clips[0].assetID, newID)
    }

    // 复合片段内部的片段也要重映射，漏了会静默丢内容
    func testRemapCoversCompoundInternals() {
        let p = ProjectState()
        let oldID = UUID(), newID = UUID()
        var compound = CompoundClip(startTime: 0, endTime: 5)
        var vt = Track<VideoClip>()
        vt.clips = [VideoClip(assetID: oldID, name: "inner", startTime: 0, endTime: 5)]
        compound.videoTracks = [vt]
        var ct = Track<CompoundClip>()
        ct.clips = [compound]
        p.compoundTracks = [ct]

        p.remapAssetIDs([oldID: newID])

        XCTAssertEqual(p.compoundTracks[0].clips[0].videoTracks[0].clips[0].assetID, newID,
                       "复合片段内部漏了重映射，内容会找不到源且不报错")
    }

    // A2：项目文件不再存素材清单，但字段还在（写空数组）——
    // 改成 optional 省掉键的话，老版本 app 那边它是必需字段，会直接解析失败
    func testSavedProjectCarriesNoAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlg_a2_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "NoAssets", directory: dir)
        p.mediaAssets.append(asset("/tmp/in_library.mp4"))
        p.saveProject(silent: true)

        let url = try XCTUnwrap(p.projectFileURL)
        let doc = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
        XCTAssertTrue(doc.mediaAssets.isEmpty, "项目文件不该再带素材清单")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(json["mediaAssets"], "字段本身要留着，老版本解码缺键会失败")
    }

    // 素材不在项目文件里了，但全局库还在 —— 重开项目片段照样对得上
    func testClipsStillResolveAfterReopenWithoutAssetsInFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlg_a2b_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "Roundtrip", directory: dir)
        let a = asset("/tmp/rt.mp4")
        p.mediaAssets.append(a)
        p.videoTracks[0].clips = [VideoClip(assetID: a.id, name: "rt", startTime: 0, endTime: 5)]
        p.saveProject(silent: true)
        let url = try XCTUnwrap(p.projectFileURL)

        let reopened = ProjectState()
        reopened.openProject(url: url)

        let clipAssetID = try XCTUnwrap(reopened.videoTracks.first?.clips.first?.assetID)
        XCTAssertEqual(clipAssetID, a.id, "片段引用应保持不变")
        XCTAssertTrue(reopened.mediaAssets.contains { $0.id == a.id },
                      "素材来自全局库，重开后仍应找得到")
    }

    // 全局库被清空后重开，片段引用就悬空了 —— 要清点得出来，不能不吭声
    func testMissingReferencesAreReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlg_a2c_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = ProjectState()
        p.createNewProject(name: "Missing", directory: dir)
        let a = asset("/tmp/gone.mp4")
        p.mediaAssets.append(a)
        p.videoTracks[0].clips = [VideoClip(assetID: a.id, name: "gone", startTime: 0, endTime: 5)]
        p.saveProject(silent: true)
        let url = try XCTUnwrap(p.projectFileURL)

        MediaLibrary.shared.resetForTesting()   // 模拟换台机器 / 全局库被清

        let reopened = ProjectState()
        reopened.openProject(url: url)
        XCTAssertTrue(reopened.mediaAssets.isEmpty, "全局库是空的")
        XCTAssertEqual(reopened.videoTracks.first?.clips.count, 1, "片段本身还在，只是源找不到")
        // 清点逻辑本身不该崩，且能识别出这一条悬空引用
        reopened.reportMissingAssetReferences()
    }

    // 打开项目不能清空全局库 —— 那会端掉别的项目的素材
    func testOpenProjectMergesInsteadOfReplacing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlg_\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 项目 A：存一条自己的素材
        let a = ProjectState()
        a.createNewProject(name: "ProjA", directory: dir)
        a.mediaAssets.append(asset("/tmp/from_a.mp4"))
        a.saveProject(silent: true)
        let aURL = try XCTUnwrap(a.projectFileURL)

        // 另一条素材是别的项目留在全局库里的
        MediaLibrary.shared.assets.append(asset("/tmp/from_elsewhere.mp4"))

        let b = ProjectState()
        b.openProject(url: aURL)

        let paths = Set(b.mediaAssets.map(\.url.path))
        XCTAssertTrue(paths.contains("/tmp/from_a.mp4"), "项目自带的素材应并进来")
        XCTAssertTrue(paths.contains("/tmp/from_elsewhere.mp4"), "打开项目不能把全局库里别的素材冲掉")
    }
}
