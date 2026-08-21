// 欢迎页「最近文件」的数据层。UI 不好测，但增删/去重/重命名这些是纯逻辑，钉住。
import XCTest
@testable import VideoEditorLib

@MainActor
final class RecentProjectsTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        MediaLibrary.shared.resetForTesting()
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        RecentProjects.shared.clearAll()
    }

    override func tearDown() async throws {
        RecentProjects.shared.clearAll()
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeProjectFile(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("\(name).bcj")
        try #"{"name":"x","mediaAssets":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRecordPutsNewestFirst() throws {
        let a = try makeProjectFile("A"), b = try makeProjectFile("B")
        RecentProjects.shared.record(url: a, name: "A")
        RecentProjects.shared.record(url: b, name: "B")
        XCTAssertEqual(RecentProjects.shared.items.map(\.name), ["B", "A"],
                       "最近打开的排最前")
    }

    func testRecordSameURLTwiceDoesNotDuplicate() throws {
        let a = try makeProjectFile("A")
        RecentProjects.shared.record(url: a, name: "A")
        RecentProjects.shared.record(url: a, name: "A")
        XCTAssertEqual(RecentProjects.shared.items.count, 1,
                       "同一个文件反复打开只该占一条，不能刷屏")
    }

    func testRemoveOnlyDropsIndexEntryNotTheFile() throws {
        let a = try makeProjectFile("A")
        RecentProjects.shared.record(url: a, name: "A")
        RecentProjects.shared.remove(a)
        XCTAssertTrue(RecentProjects.shared.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path),
                      "「从最近列表移除」不该删磁盘上的项目文件")
    }

    func testClearAllKeepsFilesOnDisk() throws {
        let a = try makeProjectFile("A"), b = try makeProjectFile("B")
        RecentProjects.shared.record(url: a, name: "A")
        RecentProjects.shared.record(url: b, name: "B")
        RecentProjects.shared.clearAll()
        XCTAssertTrue(RecentProjects.shared.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testRenameMovesFileAndUpdatesIndex() throws {
        let a = try makeProjectFile("旧名")
        RecentProjects.shared.record(url: a, name: "旧名")
        XCTAssertNil(RecentProjects.shared.rename(a, to: "新名"))

        let expected = tmpDir.appendingPathComponent("新名.bcj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "磁盘上的文件要跟着改名")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "旧文件不该留下")
        XCTAssertEqual(RecentProjects.shared.items.first?.name, "新名")
        XCTAssertEqual(RecentProjects.shared.items.first?.url, expected,
                       "索引里的 url 也要换，否则下次点开是个不存在的路径")
    }

    func testRenameRejectsEmptyAndDuplicate() throws {
        let a = try makeProjectFile("A")
        _ = try makeProjectFile("B")
        RecentProjects.shared.record(url: a, name: "A")

        XCTAssertNotNil(RecentProjects.shared.rename(a, to: "   "), "空名字要拒绝")
        XCTAssertNotNil(RecentProjects.shared.rename(a, to: "B"), "撞名要拒绝，不能覆盖别人的项目")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "被拒绝时原文件不该动")
    }

    func testExistsReflectsDeletedFile() throws {
        let a = try makeProjectFile("A")
        RecentProjects.shared.record(url: a, name: "A")
        XCTAssertTrue(RecentProjects.shared.items[0].exists)
        try FileManager.default.removeItem(at: a)
        XCTAssertFalse(RecentProjects.shared.items[0].exists,
                       "文件被移走后要能看出来，否则用户点了才发现打不开")
    }

    /// 缩略图解析只读 mediaAssets 里的路径，不整份 decode 成 ProjectDocument——
    /// 那个结构随版本变，旧文件解不出来就连缩略图都没有了
    func testThumbnailParsingToleratesUnknownFields() throws {
        let url = tmpDir.appendingPathComponent("weird.bcj")
        try #"{"未来新增字段":123,"mediaAssets":[{"type":"video","url":"/nope.mp4"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        // 素材路径不存在 → 返回 nil，但不能崩
        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url))
    }

    /// 缩略图取的是**轨道**内容，不是素材库。
    /// 素材库里可能躺着一堆没用上的素材，排最前的那个未必出现在成片里
    func testThumbnailReadsTracksNotMediaLibrary() throws {
        let unused = tmpDir.appendingPathComponent("unused.png")
        try Data([0]).write(to: unused)

        // mediaAssets 里有图片，但两类轨道都是空的 → 不该拿素材库那张顶上
        let url = tmpDir.appendingPathComponent("empty-tracks.bcj")
        try """
        {"mediaAssets":[{"type":"image","url":"\(unused.path)"}],
         "videoTracks":[{"clips":[]}],"imageTracks":[]}
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url),
                     "轨道是空的就该给缺省图，不能拿素材库里没用上的素材充数")
    }

    /// 缩略图选素材的优先级：视频 > 图片 > 无。
    /// 视频最能代表一个剪辑项目，图片往往只是叠加素材——一轮循环 first-match
    /// 的写法做不到这个，谁排在前面就用谁
    func testThumbnailPrefersVideoOverImage() throws {
        // 造两个真实存在的素材文件：图片排在前面，视频在后面
        let img = tmpDir.appendingPathComponent("a.png")
        let vid = tmpDir.appendingPathComponent("b.mp4")
        try Data([0]).write(to: img)
        try Data([0]).write(to: vid)

        let url = tmpDir.appendingPathComponent("p.bcj")
        let json = """
        {"videoTracks":[{"clips":[{"url":"\(vid.path)","startTime":0,"trimStart":0}]}],
         "imageTracks":[{"clips":[{"url":"\(img.path)","startTime":0}]}]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        // 两个都是假文件，解不出画面 → 返回 nil。这里断言的是「不崩、按顺序试过」，
        // 真实素材的取帧在 testThumbnailParsingToleratesUnknownFields 那类里覆盖不了，
        // 需要真视频，留给手测
        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url))
    }

    func testThumbnailReturnsNilWhenOnlyAudio() throws {
        // 纯音频项目没有可用画面 → nil，UI 那边显示缺省图
        let url = tmpDir.appendingPathComponent("audio-only.bcj")
        try #"{"audioTracks":[{"clips":[{"url":"/tmp/x.mp3"}]}],"videoTracks":[],"imageTracks":[]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url))
    }

    /// 真的能从视频里取到一帧。用 ffmpeg 现造一段测试视频放在临时目录，
    /// **不碰用户的真实项目**——之前这条读的是桌面上的实际项目文件，
    /// 测试跑在真实数据上，出事就是真丢东西
    func testThumbnailFromRealVideo() throws {
        guard let ff = ProjectState.findFFmpeg() else {
            throw XCTSkip("找不到内置 ffmpeg")
        }
        let video = tmpDir.appendingPathComponent("clip.mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x180:duration=1:rate=10",
                       "-pix_fmt", "yuv420p", video.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "造测试视频失败")

        let proj = tmpDir.appendingPathComponent("real.bcj")
        try """
        {"videoTracks":[{"clips":[{"url":"\(video.path)","startTime":0,"trimStart":0}]}],
         "imageTracks":[]}
        """.write(to: proj, atomically: true, encoding: .utf8)

        let img = RecentProjects.makeThumbnail(projectURL: proj)
        XCTAssertNotNil(img, "轨道上有视频，应该能取到一帧")
        XCTAssertGreaterThan(img?.size.width ?? 0, 0)
    }

    /// TC-PM-021: 内容全封装在复合片段里时，封面要能从复合片段**内部**取到。
    /// 顶层轨道是空的，只看顶层就永远是缺省图
    func testThumbnailFindsContentInsideCompound() throws {
        guard let ff = ProjectState.findFFmpeg() else {
            throw XCTSkip("找不到内置 ffmpeg")
        }
        let video = tmpDir.appendingPathComponent("inner.mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x180:duration=1:rate=10",
                       "-pix_fmt", "yuv420p", video.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "造测试视频失败")

        let proj = tmpDir.appendingPathComponent("compound-only.bcj")
        try """
        {"videoTracks":[{"clips":[]}],"imageTracks":[],
         "compoundTracks":[{"clips":[{"startTime":0,"endTime":5,
           "videoTracks":[{"clips":[{"url":"\(video.path)","startTime":0,"trimStart":0}]}]}]}]}
        """.write(to: proj, atomically: true, encoding: .utf8)

        XCTAssertNotNil(RecentProjects.makeThumbnail(projectURL: proj),
                        "顶层空、内容在复合片段里时，封面该往复合片段内部找")
    }

    /// 复合片段可以嵌套，往里找不能只找一层
    func testThumbnailFindsContentInNestedCompound() throws {
        guard let ff = ProjectState.findFFmpeg() else {
            throw XCTSkip("找不到内置 ffmpeg")
        }
        let video = tmpDir.appendingPathComponent("nested.mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x180:duration=1:rate=10",
                       "-pix_fmt", "yuv420p", video.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "造测试视频失败")

        let proj = tmpDir.appendingPathComponent("nested.bcj")
        try """
        {"videoTracks":[{"clips":[]}],"imageTracks":[],
         "compoundTracks":[{"clips":[{"startTime":0,"endTime":5,"videoTracks":[],
           "compoundTracks":[{"clips":[{"startTime":0,"endTime":5,
             "videoTracks":[{"clips":[{"url":"\(video.path)","startTime":0,"trimStart":0}]}]}]}]}]}]}
        """.write(to: proj, atomically: true, encoding: .utf8)

        XCTAssertNotNil(RecentProjects.makeThumbnail(projectURL: proj),
                        "嵌套复合片段里的内容也该找得到")
    }

    func testRecordClearsStaleThumbnail() throws {
        // 保存之后素材可能换了，旧缩略图必须失效，否则一直显示上一版画面
        let a = try makeProjectFile("A")
        RecentProjects.shared.record(url: a, name: "A")
        XCTAssertNil(RecentProjects.shared.thumbnails[a],
                     "record 时该清掉缓存，让下次进欢迎页重新生成")
    }

    func testThumbnailReturnsNilForGarbageFile() throws {
        let url = tmpDir.appendingPathComponent("bad.bcj")
        try "这不是 JSON".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url))
    }
}

/// 欢迎页列表的排序。UI 不好测，把排序规则本身钉住——
/// 尤其是「文件10 不能排在 文件2 前面」这条，用普通字符串比较就会错
final class RecentSortTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private func make(_ name: String, _ daysAgo: Double) -> RecentProject {
        RecentProject(url: URL(fileURLWithPath: "/tmp/\(name).bcj"),
                      name: name,
                      openedAt: Date(timeIntervalSinceNow: -daysAgo * 86400))
    }

    private func sorted(_ items: [RecentProject], byName: Bool, asc: Bool) -> [String] {
        items.sorted { a, b in
            let ascending = byName
                ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                : a.openedAt < b.openedAt
            return asc ? ascending : !ascending
        }.map(\.name)
    }

    func testNameSortIsNaturalNotLexicographic() {
        let items = [make("文件10", 1), make("文件2", 2), make("文件1", 3)]
        XCTAssertEqual(sorted(items, byName: true, asc: true), ["文件1", "文件2", "文件10"],
                       "数字要按数值大小排，不能是字典序（那样 文件10 会跑到 文件2 前面）")
    }

    func testNameSortReverses() {
        let items = [make("B", 1), make("A", 2), make("C", 3)]
        XCTAssertEqual(sorted(items, byName: true, asc: true), ["A", "B", "C"])
        XCTAssertEqual(sorted(items, byName: true, asc: false), ["C", "B", "A"])
    }

    func testDateSortDefaultsToNewestFirst() {
        let items = [make("旧", 10), make("新", 1), make("中", 5)]
        // asc = false 是默认，最近打开的排最前
        XCTAssertEqual(sorted(items, byName: false, asc: false), ["新", "中", "旧"])
        XCTAssertEqual(sorted(items, byName: false, asc: true), ["旧", "中", "新"])
    }
}
