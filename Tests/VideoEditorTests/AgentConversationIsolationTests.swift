// 两条会话同时让 Agent 干活，每轮的参考图、生成名额、张数各管各的，不能串
import XCTest
@testable import VideoEditorLib

@MainActor
final class AgentConversationIsolationTests: XCTestCase {

    func testRoundStateIsPerConversation() {
        let svc = AIVideoService.shared
        let a = UUID(), b = UUID()
        let ref = AIVideoService.RefContent(url: URL(fileURLWithPath: "/tmp/a_ref.png"),
                                            type: .image, thumbnail: NSImage())
        AgentContext.$conversationID.withValue(a) {
            svc.agentRoundGenerated = [.image]
            svc.agentRoundImageCount = 6
            svc.agentRoundReferences = [ref]
        }
        AgentContext.$conversationID.withValue(b) {
            XCTAssertTrue(svc.agentRoundGenerated.isEmpty, "B 被 A 的生成名额拦了")
            XCTAssertNil(svc.agentRoundImageCount, "B 拿到了 A 的张数")
            XCTAssertTrue(svc.agentRoundReferences.isEmpty, "B 带上了 A 的参考图")
            svc.agentRoundGenerated = [.video]
        }
        AgentContext.$conversationID.withValue(a) {
            XCTAssertEqual(svc.agentRoundGenerated, [.image], "A 的名额被 B 改了")
            XCTAssertEqual(svc.agentRoundImageCount, 6)
            XCTAssertEqual(svc.agentRoundReferences.first?.url, ref.url)
        }
    }

    /// 一条会话要来的工具组，别的会话手上不该有
    func testToolGroupsArePerConversation() {
        let a = UUID(), b = UUID()
        AgentContext.$conversationID.withValue(a) {
            _ = AgentToolGate.shared.search("图形")
            XCTAssertTrue(AgentToolGate.shared.tools(mode: .full, inCanvas: false)
                .contains { $0.name == "add_shape" })
        }
        AgentContext.$conversationID.withValue(b) {
            XCTAssertFalse(AgentToolGate.shared.tools(mode: .full, inCanvas: false)
                .contains { $0.name == "add_shape" }, "A 要来的工具组跑到 B 手上了")
        }
    }

    /// OCR 次数各数各的
    func testOCRCountIsPerConversation() {
        let a = UUID(), b = UUID()
        AgentContext.$conversationID.withValue(a) { AgentToolbox.ocrCallsThisRound = 50 }
        AgentContext.$conversationID.withValue(b) {
            XCTAssertEqual(AgentToolbox.ocrCallsThisRound, 0, "B 的 OCR 计数被 A 占了")
        }
    }
}
