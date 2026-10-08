// 三条平时碰不上的网络异常用例（TC-WH-023 / TC-WH-025 / TC-OA-011），
// 用 URLProtocol 拦下请求、按需回假数据，不发任何真实请求
import XCTest
@testable import VideoEditorLib

/// 拦截 URLSession.shared 的请求。按 host 决定怎么回
final class StubProtocol: URLProtocol {
    enum Mode { case emptyReply, dropFirstThenOK, rateLimited }
    nonisolated(unsafe) static var mode: Mode = .emptyReply
    nonisolated(unsafe) static var hits = 0

    override class func canInit(with request: URLRequest) -> Bool {
        let h = request.url?.host ?? ""
        return h.contains("deepseek.com") || h.contains("openverse.org")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.hits += 1
        let url = request.url!
        func reply(_ code: Int, _ body: String) {
            let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        switch Self.mode {
        case .emptyReply:
            reply(200, #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#)
        case .dropFirstThenOK:
            if Self.hits == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                reply(200, #"{"choices":[{"message":{"content":"好的"},"finish_reason":"stop"}]}"#)
            }
        case .rateLimited:
            reply(429, #"{"detail":"Request was throttled."}"#)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class NetworkFailureTests: XCTestCase {
    private let key = "settings.ai.providerKey.\(AIVideoService.Provider.deepseek_ai.rawValue)"
    private var savedKey: Any?

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.hits = 0
        // 测试进程的偏好设置跟 app 不是同一份，这里填的假 Key 不会碰到 app
        savedKey = UserDefaults.standard.object(forKey: key)
        AppSettings.shared.setProviderAPIKey("test-key", for: AIVideoService.Provider.deepseek_ai.rawValue)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        UserDefaults.standard.set(savedKey, forKey: key)
        super.tearDown()
    }

    // TC-WH-023：模型回空内容 → 报错，校对结果带上原因（界面据此显示「AI 校对未完成」）
    func testWH023_emptyReplyIsAnError() async {
        StubProtocol.mode = .emptyReply
        do {
            _ = try await AIVideoService.shared.generateText(provider: .deepseek_ai, prompt: "x")
            XCTFail("空内容应该报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("返回了空内容"), error.localizedDescription)
        }
        let segs = [(start: 0.0, end: 1.0, text: "你好"), (start: 1.0, end: 2.0, text: "世界")]
        let r = await LLMAnalyzer.proofreadSubtitles(segs, send: { p in
            try await AIVideoService.shared.generateText(provider: .deepseek_ai, prompt: p)
        }, progress: { _ in })
        XCTAssertNotNil(r.error, "校对应该带回失败原因，不能当成「未改动」")
        XCTAssertEqual(r.changed, 0)
        XCTAssertEqual(r.segs.map(\.text), ["你好", "世界"], "失败时原样保留识别结果")
    }

    // TC-WH-025：第一次断连 → 自动重试，第二次成功
    func testWH025_retriesAfterConnectionLost() async throws {
        StubProtocol.mode = .dropFirstThenOK
        let text = try await AIVideoService.shared.generateText(provider: .deepseek_ai, prompt: "x")
        XCTAssertEqual(text, "好的")
        XCTAssertEqual(StubProtocol.hits, 2, "应该是断一次、重试一次")
    }

    // TC-OA-011：在线库被限流 → 显示「请求太频繁」，不是空白
    func testOA011_rateLimitMessage() async throws {
        StubProtocol.mode = .rateLimited
        let store = OnlineAudioStore.shared
        store.section = .music("happy")
        store.searchText = "限流测试\(UUID().uuidString.prefix(6))"
        store.submitSearch()
        for _ in 0..<40 where store.error == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.error?.contains("请求太频繁"), true, store.error ?? "没有提示")
        XCTAssertTrue(store.results.isEmpty)
    }
}
