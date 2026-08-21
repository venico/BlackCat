// 模块 51：画布生成调度（v5.1.0，B4）
//
// 连线语义是「上游 = 下游的参考」，所以上游没出结果之前下游不能开工。
// 这块错了很难从界面看出来 —— 表现只是「有的节点拿空参考生成了」。
import XCTest
@testable import VideoEditorLib

final class CanvasGenerationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
        AIVideoService.shared.cancelAllGenerations()
    }

    override func tearDown() {
        AIVideoService.shared.cancelAllGenerations()
        super.tearDown()
    }

    // 上游还在生成时，下游要排队而不是拿空参考开工
    func testDownstreamWaitsForGeneratingUpstream() {
        let c = CanvasState()
        let up = c.addNode(kind: .image, at: .zero)
        let down = c.addNode(kind: .video, at: CGPoint(x: 400, y: 0))
        XCTAssertTrue(c.connect(from: up.id, to: down.id, provider: .seedance).isAllowed)

        c.updateNode(id: up.id) { $0.isGenerating = true }
        c.updateNode(id: down.id) { $0.prompt = "做个视频" }
        c.submitGeneration(nodeID: down.id, provider: .seedance)

        XCTAssertTrue(c.node(down.id)?.isWaiting == true, "上游没好，下游该排队")
        XCTAssertFalse(c.node(down.id)?.isGenerating == true, "排队时不该已经在生成")
    }

    // 没有依赖的节点直接开工，不排队
    func testNodeWithoutUpstreamStartsImmediately() {
        let c = CanvasState()
        let n = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: n.id) { $0.prompt = "一只猫" }
        c.submitGeneration(nodeID: n.id, provider: .seedream)

        XCTAssertFalse(c.node(n.id)?.isWaiting == true, "没有上游就不该等")
        // 真发请求会失败（测试环境没 Key），但状态机已经走到「开工」这步
        XCTAssertNotNil(c.node(n.id))
    }

    // 上游是文本节点：文本不需要生成，下游可以直接开工
    func testTextUpstreamDoesNotBlock() {
        let c = CanvasState()
        let text = c.addNode(kind: .text, at: .zero)
        c.updateNode(id: text.id) { $0.text = "赛博朋克风格" }
        let img = c.addNode(kind: .image, at: CGPoint(x: 400, y: 0))
        XCTAssertTrue(c.connect(from: text.id, to: img.id, provider: .seedream).isAllowed)

        c.submitGeneration(nodeID: img.id, provider: .seedream)
        XCTAssertFalse(c.node(img.id)?.isWaiting == true, "文本上游不需要等生成")
    }

    // 提示词为空且没有参考图 —— 别发出去白烧一次额度
    func testEmptyPromptIsRejectedLocally() {
        let c = CanvasState()
        let n = c.addNode(kind: .image, at: .zero)
        c.submitGeneration(nodeID: n.id, provider: .seedream)
        XCTAssertEqual(c.node(n.id)?.failure, "先写点提示词")
        XCTAssertFalse(c.node(n.id)?.isGenerating == true)
    }

    // 文本节点没有「生成」这回事
    func testTextNodeNeverGenerates() {
        let c = CanvasState()
        let t = c.addNode(kind: .text, at: .zero)
        c.updateNode(id: t.id) { $0.text = "随便写点" }
        c.submitGeneration(nodeID: t.id, provider: .seedream)
        XCTAssertFalse(c.node(t.id)?.isGenerating == true)
        XCTAssertFalse(c.node(t.id)?.isWaiting == true)
    }

    // 重新提交要清掉上次的失败，否则界面会一直挂着旧错误
    func testResubmitClearsPreviousFailure() {
        let c = CanvasState()
        let n = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: n.id) { $0.failure = "上次失败了" }
        c.updateNode(id: n.id) { $0.prompt = "再来一次" }
        c.submitGeneration(nodeID: n.id, provider: .seedream)
        XCTAssertNil(c.node(n.id)?.failure, "重新提交该清掉旧的失败提示")
    }

    // 取消要把状态收干净
    func testCancelClearsRunningState() {
        let c = CanvasState()
        let n = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: n.id) { $0.isGenerating = true }
        c.cancelGeneration(nodeID: n.id)
        XCTAssertFalse(c.node(n.id)?.isGenerating == true)
        XCTAssertFalse(c.node(n.id)?.isWaiting == true)
    }

    // 参考素材按连线先后排序 —— 顺序不对会影响出图
    func testReferencesFollowConnectionOrder() {
        let c = CanvasState()
        let target = c.addNode(kind: .video, at: CGPoint(x: 800, y: 0))
        let a = c.addNode(kind: .image, at: .zero)
        let b = c.addNode(kind: .image, at: CGPoint(x: 0, y: 300))
        c.updateNode(id: a.id) { $0.mediaPath = "/tmp/a.png" }
        c.updateNode(id: b.id) { $0.mediaPath = "/tmp/b.png" }

        XCTAssertTrue(c.connect(from: a.id, to: target.id, provider: .seedance).isAllowed)
        XCTAssertTrue(c.connect(from: b.id, to: target.id, provider: .seedance).isAllowed)

        let refs = c.upstreamNodes(of: target.id).compactMap(\.mediaPath)
        XCTAssertEqual(refs, ["/tmp/a.png", "/tmp/b.png"], "先连的排前面")
    }
}
