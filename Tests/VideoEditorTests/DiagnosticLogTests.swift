import XCTest
import Foundation
@testable import VideoEditorLib

// MARK: - 诊断日志本身是否有效
//
// 排查线上问题时靠这些 NSLog 拿证据。如果日志压根没打出来，
// 「日志为空」就不能当成「代码没执行」的依据 —— 先把工具本身验一遍。

@MainActor
final class DiagnosticLogTests: XCTestCase {

    /// 造一个读不出时长的假 mp4，逼失败路径执行
    func testThumbnailFailureEmitsLog() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("diaglog_\(UUID().uuidString).mp4")
        try Data("这不是视频".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let p = ProjectState()
        let aid = UUID()

        // 两条独立路径都走一遍
        p.loadMediaThumbnail(assetID: aid, url: bogus)
        p.loadTimelineThumbnails(assetID: aid, url: bogus)

        // 等异步生成走完
        let deadline = Date().addingTimeInterval(10)
        while p.thumbnailsGenerating.contains(aid), Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 失败路径必须把占位清掉（这条已经在别处测过，这里顺带确认流程真的走到了）
        XCTAssertNil(p.assetThumbnails[aid], "失败路径应已执行")
        XCTAssertNil(p.mediaThumbnails[aid], "素材库封面不该生成出来")

        print("已触发失败路径，接下来用 log show 检查是否有日志输出")
    }
}
