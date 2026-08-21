// 模块 50：AI 画布节点与连线（v5.1.0，B3）
//
// 连线的语义是「上游 = 下游的参考素材」。能不能连不是写死的规则，
// 是查目标模型收不收这种参考（Provider 上现成的 maxReferenceXxx 矩阵）。
import XCTest
@testable import VideoEditorLib

final class CanvasNodeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    private func makeCanvas() -> CanvasState { CanvasState() }

    // MARK: 节点增删

    func testAddNodeUsesKindDefaultSize() {
        let c = makeCanvas()
        let n = c.addNode(kind: .image, at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(c.nodes.count, 1)
        XCTAssertEqual(n.size, CanvasNode.Kind.image.defaultSize(ratio: "1:1"))
        XCTAssertEqual(c.selectedNodeID, n.id, "新建的节点该是选中态")
    }

    // 删节点必须连带删线，否则留下指向空节点的悬空连线
    func testRemoveNodeAlsoRemovesItsEdges() {
        let c = makeCanvas()
        let a = c.addNode(kind: .text, at: .zero)
        let b = c.addNode(kind: .image, at: CGPoint(x: 300, y: 0))
        XCTAssertTrue(c.connect(from: a.id, to: b.id, provider: .seedream).isAllowed)
        XCTAssertEqual(c.edges.count, 1)

        c.removeNode(id: a.id)
        XCTAssertEqual(c.nodes.count, 1)
        XCTAssertTrue(c.edges.isEmpty, "上游没了，线也该收掉")
    }

    // MARK: 连线校验

    // 图片不收音频当参考。提示统一成「不支持此类型素材」，不分类型细说
    func testImageCannotReferenceAudio() {
        let c = makeCanvas()
        let audio = c.addNode(kind: .audio, at: .zero)
        let image = c.addNode(kind: .image, at: CGPoint(x: 300, y: 0))

        let result = c.connect(from: audio.id, to: image.id, provider: .seedream)
        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.message, CanvasConnectionRule.unsupportedMessage)
        XCTAssertTrue(c.edges.isEmpty, "拒绝的连线不能落下")
    }

    // Seedance 视频收图片/视频/音频三种参考
    func testSeedanceVideoAcceptsAllMediaKinds() {
        let c = makeCanvas()
        let video = c.addNode(kind: .video, at: CGPoint(x: 400, y: 0))
        for kind in [CanvasNode.Kind.image, .video, .audio] {
            let src = c.addNode(kind: kind, at: .zero)
            XCTAssertTrue(c.connect(from: src.id, to: video.id, provider: .seedance).isAllowed,
                          "Seedance 该收 \(kind.label) 参考")
        }
        XCTAssertEqual(c.edges.count, 3)
    }

    // 文本节点当提示词，谁都能接；反过来文本节点不吃素材参考
    func testTextConnectsToAnythingButAcceptsNothing() {
        let c = makeCanvas()
        let text = c.addNode(kind: .text, at: .zero)
        let image = c.addNode(kind: .image, at: CGPoint(x: 300, y: 0))

        XCTAssertTrue(c.connect(from: text.id, to: image.id, provider: .seedream).isAllowed)

        let back = c.connect(from: image.id, to: text.id, provider: .seedream)
        XCTAssertFalse(back.isAllowed)
        XCTAssertEqual(back.message, CanvasConnectionRule.unsupportedMessage)
    }

    func testCannotConnectToSelfOrDuplicate() {
        let c = makeCanvas()
        let a = c.addNode(kind: .text, at: .zero)
        let b = c.addNode(kind: .video, at: CGPoint(x: 300, y: 0))

        XCTAssertFalse(c.connect(from: a.id, to: a.id, provider: .seedance).isAllowed)
        XCTAssertTrue(c.connect(from: a.id, to: b.id, provider: .seedance).isAllowed)
        XCTAssertEqual(c.connect(from: a.id, to: b.id, provider: .seedance).message, "已经连过了")
        XCTAssertEqual(c.edges.count, 1)
    }

    // 右边 + 的菜单：拿这个节点当参考能生成什么
    func testCanGenerateTable() {
        XCTAssertEqual(CanvasNode.Kind.text.canGenerate, [.text, .image, .video, .audio],
                       "文本能派生一切")
        XCTAssertEqual(CanvasNode.Kind.image.canGenerate, [.image, .video])
        XCTAssertEqual(CanvasNode.Kind.video.canGenerate, [.video], "视频只能再出视频")
        XCTAssertEqual(CanvasNode.Kind.audio.canGenerate, [.audio])
    }

    // 左边 + 的菜单：这个节点能接什么上下文。
    // 跟 canGenerate **不对称**，别想当然地互相反推
    func testAcceptsContextTable() {
        XCTAssertEqual(CanvasNode.Kind.text.acceptsContext, [.text])
        XCTAssertEqual(CanvasNode.Kind.image.acceptsContext, [.text, .image])
        XCTAssertEqual(CanvasNode.Kind.video.acceptsContext, [.text, .image, .video, .audio])
        XCTAssertEqual(CanvasNode.Kind.audio.acceptsContext, [.text])

        // 这一对就是不对称的地方：视频收音频当参考，但音频不能「生成视频」
        XCTAssertTrue(CanvasNode.Kind.video.acceptsContext.contains(.audio))
        XCTAssertFalse(CanvasNode.Kind.audio.canGenerate.contains(.video))
    }

    // 连线查的是**目标**能接什么，跟左边 + 菜单同一份表
    func testConnectionFollowsAcceptsContext() {
        let c = makeCanvas()
        let audio = c.addNode(kind: .audio, at: .zero)
        let video = c.addNode(kind: .video, at: CGPoint(x: 400, y: 0))
        let image = c.addNode(kind: .image, at: CGPoint(x: 800, y: 0))

        XCTAssertTrue(c.connect(from: audio.id, to: video.id, provider: .seedance).isAllowed,
                      "视频能拿音频当参考")
        let bad = c.connect(from: audio.id, to: image.id, provider: .seedream)
        XCTAssertFalse(bad.isAllowed, "图片不能参考音频")
        XCTAssertEqual(bad.message, CanvasConnectionRule.unsupportedMessage)
    }

    // 成环会让生成时互相等对方，永远开不了工
    func testCycleIsRejected() {
        let c = makeCanvas()
        // 三个都用视频：视频能接视频当上下文，类型这关过得去，
        // 才测得到成环那道。混类型的话会先被类型规则拦下，测的就不是环了
        let a = c.addNode(kind: .video, at: .zero)
        let b = c.addNode(kind: .video, at: CGPoint(x: 300, y: 0))
        let d = c.addNode(kind: .video, at: CGPoint(x: 600, y: 0))

        XCTAssertTrue(c.connect(from: a.id, to: b.id, provider: .seedance).isAllowed)
        XCTAssertTrue(c.connect(from: b.id, to: d.id, provider: .seedance).isAllowed)

        let cycle = c.connect(from: d.id, to: a.id, provider: .seedance)
        XCTAssertFalse(cycle.isAllowed, "A→B→D→A 会成环")
        XCTAssertEqual(cycle.message, "不能连成环")
    }

    // 上游按连线先后排序 —— 参考素材的顺序就是这么定的
    func testUpstreamKeepsConnectionOrder() {
        let c = makeCanvas()
        let target = c.addNode(kind: .video, at: CGPoint(x: 600, y: 0))
        let first = c.addNode(kind: .image, at: .zero)
        let second = c.addNode(kind: .image, at: CGPoint(x: 0, y: 200))

        XCTAssertTrue(c.connect(from: first.id, to: target.id, provider: .seedance).isAllowed)
        XCTAssertTrue(c.connect(from: second.id, to: target.id, provider: .seedance).isAllowed)

        let ups = c.upstreamNodes(of: target.id)
        XCTAssertEqual(ups.map(\.id), [first.id, second.id], "先连的排前面")
    }

    // 上传/选素材时按扩展名决定落哪种节点
    func testNodeKindFromFileExtension() {
        func kind(_ name: String) -> CanvasNode.Kind? {
            CanvasSurfaceKindResolver.nodeKind(for: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(kind("a.mp4"), .video)
        XCTAssertEqual(kind("a.mov"), .video)
        XCTAssertEqual(kind("a.mp3"), .audio)
        XCTAssertEqual(kind("a.wav"), .audio)
        XCTAssertEqual(kind("a.png"), .image)
        XCTAssertEqual(kind("a.jpg"), .image)
        XCTAssertNil(kind("a.srt"), "字幕没有对应的节点类型")
        XCTAssertNil(kind("a.zip"), "不认识的扩展名不该落节点")
    }

    // 移动节点不该改尺寸，位置就是内容坐标
    func testMoveNodeKeepsSize() {
        let c = makeCanvas()
        let n = c.addNode(kind: .audio, at: .zero)
        c.moveNode(id: n.id, to: CGPoint(x: 120, y: -40))
        XCTAssertEqual(c.node(n.id)?.position, CGPoint(x: 120, y: -40))
        XCTAssertEqual(c.node(n.id)?.size, CanvasNode.Kind.audio.defaultSize())
    }

    // MARK: 画布自己的撤销栈

    func testUndoRedoCoversNodesAndEdges() {
        let c = makeCanvas()
        let a = c.addNode(kind: .text, at: .zero)
        let b = c.addNode(kind: .image, at: CGPoint(x: 300, y: 0))
        _ = c.connect(from: a.id, to: b.id, provider: .seedream)
        XCTAssertEqual(c.nodes.count, 2)
        XCTAssertEqual(c.edges.count, 1)

        c.undo()
        XCTAssertEqual(c.edges.count, 0, "撤销该退掉连线")
        XCTAssertEqual(c.nodes.count, 2)

        c.undo()
        XCTAssertEqual(c.nodes.count, 1, "再撤退掉第二个节点")

        c.redo()
        XCTAssertEqual(c.nodes.count, 2)
        c.redo()
        XCTAssertEqual(c.edges.count, 1)
    }

    func testUndoStackIsCappedAndRedoClearedOnNewEdit() {
        let c = makeCanvas()
        for i in 0..<60 { c.addNode(kind: .text, at: CGPoint(x: i, y: 0)) }
        XCTAssertLessThanOrEqual(c.undoCount, 50, "撤销栈要有上限")

        c.undo()
        XCTAssertTrue(c.canRedo)
        c.addNode(kind: .image, at: .zero)
        XCTAssertFalse(c.canRedo, "新操作后重做栈要清空")
    }

    // 撤销掉的节点如果正被选中，选中状态要跟着清掉
    func testUndoClearsDanglingSelection() {
        let c = makeCanvas()
        let n = c.addNode(kind: .video, at: .zero)
        XCTAssertEqual(c.selectedNodeID, n.id)
        c.undo()
        XCTAssertNil(c.selectedNodeID, "节点没了，选中不该还指着它")
    }
}
