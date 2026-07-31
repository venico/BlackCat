import XCTest
import Foundation
@testable import VideoEditorLib

// MARK: - 时间轴缩略图的重试
//
// 回归：某次生成中断后缓存里留下空数组，守卫把它当成「已有缓存」，
// 那条片段的缩略图从此空着且永不重试，只有重启 app 才恢复。

@MainActor
final class ThumbnailRetryTests: XCTestCase {

    /// 读不出时长的文件（这里用一个假 mp4）不能在缓存里留下空数组占位
    func testFailedGenerationDoesNotPoisonCache() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not_a_video_\(UUID().uuidString).mp4")
        try Data("这不是视频".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let p = ProjectState()
        let aid = UUID()
        p.loadTimelineThumbnails(assetID: aid, url: bogus)

        // 等生成流程走完（读时长会失败）
        let deadline = Date().addingTimeInterval(8)
        while p.thumbnailsGenerating.contains(aid), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertFalse(p.thumbnailsGenerating.contains(aid), "生成标记应被清掉")
        XCTAssertNil(p.assetThumbnails[aid],
                     "失败后不能留下空数组 —— 那会让守卫误判已有缓存，永不重试")
    }

    /// 缓存里是空数组时，再次调用必须真的重新生成，而不是被守卫挡回去
    func testEmptyCacheTriggersRegeneration() async throws {
        let p = ProjectState()
        let aid = UUID()
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry_\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        // 手工制造出问题时的状态：缓存里躺着空数组
        p.assetThumbnails[aid] = []
        p.loadTimelineThumbnails(assetID: aid, url: bogus)

        XCTAssertTrue(p.thumbnailsGenerating.contains(aid),
                      "空数组应触发重新生成，而不是被当成已有缓存")
    }

    /// 有真实缩略图时不该重复生成，白耗资源
    func testNonEmptyCacheSkipsRegeneration() {
        let p = ProjectState()
        let aid = UUID()
        p.assetThumbnails[aid] = [ThumbnailFrame(time: 0, image: NSImage())]

        p.loadTimelineThumbnails(assetID: aid, url: URL(fileURLWithPath: "/tmp/whatever.mp4"))
        XCTAssertFalse(p.thumbnailsGenerating.contains(aid), "已有缩略图就不该再生成")
    }

    /// 同一素材连点多次只能生成一轮
    func testConcurrentCallsGenerateOnce() throws {
        let p = ProjectState()
        let aid = UUID()
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("dedup_\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        p.loadTimelineThumbnails(assetID: aid, url: bogus)
        XCTAssertTrue(p.thumbnailsGenerating.contains(aid))

        // 第二次调用应被生成中标记挡住（缓存此时是空数组，光看缓存会重复触发）
        let before = p.thumbnailsGenerating.count
        p.loadTimelineThumbnails(assetID: aid, url: bogus)
        XCTAssertEqual(p.thumbnailsGenerating.count, before, "不该重复入队")
    }
}
