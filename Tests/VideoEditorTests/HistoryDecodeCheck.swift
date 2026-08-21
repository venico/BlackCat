import XCTest
@testable import VideoEditorLib

/// 拿用户真实的会话文件验解码。加字段最容易在这儿翻车：
/// Swift 的 Codable 对「有默认值但 JSON 里缺这个键」的属性**不会**放过，
/// 一条解不出来整个数组就没了，而 loadHistory 用的是 try?，失败还静默
final class HistoryDecodeCheck: XCTestCase {
    func testRealHistoryFileDecodes() throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackCat/ai_conversations.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("本机没有会话文件")
        }
        let data = try Data(contentsOf: url)
        do {
            let list = try JSONDecoder().decode([AIVideoService.ConversationRecord].self, from: data)
            print("[解码成功] \(list.count) 条，其中画布 \(list.filter(\.isCanvas).count) 条")
            XCTAssertFalse(list.isEmpty)
        } catch {
            XCTFail("解码失败：\(error)")
        }
    }
}
