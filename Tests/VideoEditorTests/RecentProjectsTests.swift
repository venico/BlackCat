// 欢迎页「最近文件」的数据层。UI 不好测，但增删/去重/重命名这些是纯逻辑，钉住。
import XCTest
@testable import VideoEditorLib

@MainActor
final class RecentProjectsTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
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

    func testThumbnailReturnsNilForGarbageFile() throws {
        let url = tmpDir.appendingPathComponent("bad.bcj")
        try "这不是 JSON".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(RecentProjects.makeThumbnail(projectURL: url))
    }
}

/// 欢迎页列表的排序。UI 不好测，把排序规则本身钉住——
/// 尤其是「文件10 不能排在 文件2 前面」这条，用普通字符串比较就会错
final class RecentSortTests: XCTestCase {

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
