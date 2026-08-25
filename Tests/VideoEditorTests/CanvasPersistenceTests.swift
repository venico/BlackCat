// 模块 52：画布存档（v5.1.0，B5）
//
// 一张画布 = AI 历史里的一条会话记录。这块错了等于用户的画布内容丢了，
// 而且往往是关掉才发现，所以往返必须钉死。
import XCTest
@testable import VideoEditorLib

final class CanvasPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaLibrary.shared.resetForTesting()
    }

    private func makeCanvas() -> CanvasState {
        let c = CanvasState()
        let text = c.addNode(kind: .text, at: CGPoint(x: 100, y: 100))
        c.updateNode(id: text.id) { $0.text = "赛博朋克城市" }
        let img = c.addNode(kind: .image, at: CGPoint(x: 500, y: 100))
        c.updateNode(id: img.id) { $0.prompt = "出一张图"; $0.mediaPath = "/tmp/out.png" }
        _ = c.connect(from: text.id, to: img.id, provider: .seedream)
        c.zoom = 1.5
        c.offset = CGSize(width: 30, height: -40)
        // 老存档里可能还带着元素库清单（v5.3.0 已并入素材库），
        // 存档格式仍要能原样往返，迁移才有东西可读
        c.producedAssets = [
            CanvasState.ProducedAsset(path: "/tmp/out.png", kind: .image)
        ]
        return c
    }

    // 节点、连线、产物、视口都要能原样回来
    func testSnapshotRoundTrip() {
        let c = makeCanvas()
        let snap = c.snapshot()

        let restored = CanvasState()
        let convID = UUID()
        restored.restore(from: snap, conversationID: convID, title: "测试画布")

        XCTAssertEqual(restored.nodes.count, c.nodes.count)
        XCTAssertEqual(restored.edges.count, 1, "连线要还原")
        XCTAssertEqual(restored.producedAssets.count, 1, "资产库要还原")
        XCTAssertEqual(restored.zoom, 1.5)
        XCTAssertEqual(restored.offset, CGSize(width: 30, height: -40))
        XCTAssertEqual(restored.conversationID, convID)
        XCTAssertEqual(restored.title, "测试画布")
        XCTAssertEqual(restored.nodes.first { $0.kind == .text }?.text, "赛博朋克城市")
    }

    // 存档要能过 JSON 编解码 —— 会话文件就是 JSON
    func testSnapshotSurvivesJSONCoding() throws {
        let snap = makeCanvas().snapshot()
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(AIVideoService.ConversationRecord.CanvasSnapshot.self, from: data)

        XCTAssertEqual(back.nodes.count, snap.nodes.count)
        XCTAssertEqual(back.edges.count, snap.edges.count)
        XCTAssertEqual(back.producedAssets.count, snap.producedAssets.count)
        XCTAssertEqual(back.zoom, snap.zoom)
    }

    // 聊天记录没有 canvas 字段，isCanvas 得判得出来（历史列表靠它分两类）
    func testChatRecordIsNotCanvas() {
        let chat = AIVideoService.ConversationRecord(
            id: UUID(), title: "普通对话", createdAt: Date(), entries: [], canvas: nil)
        XCTAssertFalse(chat.isCanvas)

        let canvas = AIVideoService.ConversationRecord(
            id: UUID(), title: "画布", createdAt: Date(), entries: [], canvas: .init())
        XCTAssertTrue(canvas.isCanvas)
    }

    // 旧的会话文件没有 canvas 这个键，解码不能失败
    func testOldRecordWithoutCanvasKeyStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"老会话","createdAt":0,"entries":[]}
        """.data(using: .utf8)!
        let rec = try JSONDecoder().decode(AIVideoService.ConversationRecord.self, from: json)
        XCTAssertFalse(rec.isCanvas, "老记录当聊天处理")
        XCTAssertEqual(rec.title, "老会话")
    }

    // 加字段之后，**旧数据缺这些键也必须解得出来**。
    // 2026-08-21 就是在这翻的车：CanvasNode 加了几个文字样式字段，
    // 旧记录缺键 → 整个 [CanvasNode] 解不出来 → 整条会话记录废掉 →
    // 整个历史文件解码失败 → loadHistory 静默返回空 → 一存盘把 29 条覆盖成 1 条
    func testNodeDecodesWhenNewFieldsMissing() throws {
        // 一个「老版本」节点：只有当初有的那几个键
        // CGPoint / CGSize 的 Codable 编出来是**数组**不是字典（[x,y] / [w,h]）
        let json = """
        {"id":"\(UUID().uuidString)","kind":"text","text":"老节点",
         "position":[10,20],"size":[260,150]}
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(CanvasNode.self, from: json)
        XCTAssertEqual(node.text, "老节点")
        XCTAssertEqual(node.textColorHex, "#FFFFFF", "缺的字段要落到默认值")
        XCTAssertEqual(node.headingLevel, 0)
        XCTAssertFalse(node.bold)
        XCTAssertEqual(node.ratio, "1:1")
    }

    // 一条坏记录不能连累整个历史
    func testHistorySurvivesOneBrokenRecord() throws {
        let good = AIVideoService.ConversationRecord(
            id: UUID(), title: "好的", createdAt: Date(), entries: [], canvas: nil)
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let mixed = "[\(goodJSON), {\"完全不是记录\":1}]".data(using: .utf8)!

        // 整体解码会失败
        XCTAssertThrowsError(try JSONDecoder().decode([AIVideoService.ConversationRecord].self, from: mixed))

        // 逐条解就能捞回好的那条（loadHistory 的兜底走的就是这条路）
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: mixed) as? [Any])
        var salvaged: [AIVideoService.ConversationRecord] = []
        for item in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let rec = try? JSONDecoder().decode(AIVideoService.ConversationRecord.self, from: d)
            else { continue }
            salvaged.append(rec)
        }
        XCTAssertEqual(salvaged.count, 1, "坏的跳过，好的要留下")
        XCTAssertEqual(salvaged.first?.title, "好的")
    }

    // 换画布要清撤销栈：在新画布上撤销回上一张画布的内容是灾难
    func testRestoreClearsUndoHistory() {
        let c = makeCanvas()
        c.pushUndo()
        XCTAssertTrue(c.canUndo)

        c.restore(from: CanvasState().snapshot(), conversationID: UUID(), title: "另一张")
        XCTAssertFalse(c.canUndo, "换画布后不该还能撤销回上一张的内容")
    }

    // 新建画布是干净的
    func testResetGivesEmptyCanvas() {
        let c = makeCanvas()
        let id = UUID()
        c.reset(conversationID: id)
        XCTAssertTrue(c.nodes.isEmpty)
        XCTAssertTrue(c.edges.isEmpty)
        XCTAssertTrue(c.producedAssets.isEmpty)
        XCTAssertEqual(c.zoom, 1)
        XCTAssertEqual(c.conversationID, id)
    }

    // 画布关着的时候在侧边栏改了素材名，打开画布要能对上账 ——
    // 通知挂在 CanvasOverlay 上，画布没开就没人接，只能靠这次对账补
    func testSyncNodesFromLibrary() {
        let project = ProjectState()
        let url = URL(fileURLWithPath: "/tmp/canvas-sync-\(UUID().uuidString).png")
        var asset = MediaAsset(url: url, name: "改过的名字.png", type: .image)
        asset.importDate = Date()
        project.mediaAssets = [asset]

        let c = CanvasState()
        let node = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: node.id) {
            $0.assetID = asset.id
            $0.mediaPath = "/tmp/old-name-before-rename.png"   // 改名前的旧路径
            $0.displayName = "图片 1"     // 产物卡片那种自动编号
        }

        c.syncNodesFromLibrary(project)
        XCTAssertEqual(c.node(node.id)?.displayName, "改过的名字.png")
        // 路径也要跟着素材走，只对名字不对路径的话卡片会显示「素材丢失」
        XCTAssertEqual(c.node(node.id)?.mediaPath, url.path)
    }

    // 删素材：画布上引用它的卡片一并删掉（跟时间轴片段一个待遇）
    func testRemoveAssetDropsCards() {
        let c = CanvasState()
        let aid = UUID()
        let n1 = c.addNode(kind: .image, at: .zero)
        let n2 = c.addNode(kind: .image, at: CGPoint(x: 400, y: 0))
        c.updateNode(id: n1.id) { $0.assetID = aid }
        c.updateNode(id: n2.id) { $0.assetID = UUID() }   // 别的素材，不该被误删

        XCTAssertEqual(c.nodeCount(usingAsset: aid), 1)
        c.removeNodes(usingAsset: aid)
        XCTAssertNil(c.node(n1.id), "引用被删素材的卡片要没掉")
        XCTAssertNotNil(c.node(n2.id), "别的卡片不能受影响")
    }

    // 一次 ⌘Z 三样一起回来：素材恢复时，画布那步也跟着撤
    func testUndoRestoresCards() {
        let c = CanvasState()
        let aid = UUID()
        let n = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: n.id) { $0.assetID = aid }

        c.removeNodes(usingAsset: aid)
        XCTAssertNil(c.node(n.id))
        c.restoreNodesAfterUndo(assetID: aid)
        XCTAssertNotNil(c.node(n.id), "素材撤销恢复后，卡片要跟着回来")
    }

    // 删完之后画布上又干了别的：栈顶已经不是那步，宁可不撤也不能撤错
    func testUndoSkipsWhenCanvasMovedOn() {
        let c = CanvasState()
        let aid = UUID()
        let n = c.addNode(kind: .image, at: .zero)
        c.updateNode(id: n.id) { $0.assetID = aid }

        c.removeNodes(usingAsset: aid)
        let later = c.addNode(kind: .text, at: CGPoint(x: 100, y: 100))   // 又加了一张
        c.restoreNodesAfterUndo(assetID: aid)
        XCTAssertNotNil(c.node(later.id), "后来加的卡片不能被误撤掉")
    }

    // v5.3.0 元素库并进素材库：老存档里的清单迁移完要清空，
    // 否则下次存档还带着它，界面上又没有入口能看到
    func testMigrateClearsProducedAssets() {
        let c = CanvasState()
        c.producedAssets = [
            CanvasState.ProducedAsset(path: "/tmp/gone-\(UUID().uuidString).png", kind: .image)
        ]
        c.migrateProducedAssetsIntoLibrary(ProjectState())
        XCTAssertTrue(c.producedAssets.isEmpty)
    }
}
