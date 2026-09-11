// AgentTools+Canvas.swift
//
// 把 AI 画布接给 Agent。
//
// 在这之前画布对 Agent 是**完全隐形**的：它看不见画布上有什么卡片、
// 谁连着谁，更别说往上加东西 —— 用户在画布上摆了半天，问一句
// 「这几张图接下来怎么办」，Agent 只能干瞪眼。
//
// 卡片和素材一样用 **id 前 8 位**指认（read_canvas 会把 id 列出来），
// 跟 list_assets / add_asset_to_timeline 那套是同一个习惯，不另发明一套编号。
//
// 看图看视频**不做专门的工具**：画布上的素材就是普通文件，
// 该抽帧用 capture_frame、该认字用 read_frame_text / scan_text，
// 跟处理时间轴上的素材一模一样。

import Foundation

extension AgentToolbox {

    static var canvasTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "read_canvas",
                description: """
                看 AI 画布上有什么：每张卡片的类型、内容、提示词、生成状态，
                以及卡片之间的连线（上游卡片是下游的参考素材）和分组。
                想知道某张图片/视频卡片**画面里**是什么，拿它的文件路径去调
                capture_frame 或 read_frame_text，跟时间轴上的素材一个办法。
                """,
                parameters: ["type": "object", "properties": [:] as [String: Any],
                             "required": [] as [String]],
                risk: .readOnly),

            AgentToolSpec(
                name: "add_canvas_node",
                description: """
                在画布上加一张卡片。
                文本卡片填 text；要生成图片/视频/音频就填 prompt，
                加完再调 generate_canvas_node 才会真的开跑（那步花钱）。
                想把素材库里现成的东西摆上画布就填 asset_id。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "description": "卡片类型：text / image / video / audio"],
                        "text": ["type": "string", "description": "文本卡片的内容"],
                        "prompt": ["type": "string", "description": "生成用的提示词"],
                        "asset_id": ["type": "string",
                                     "description": "素材库里某个素材的 id 前 8 位，填了就把它摆上卡片"],
                        "ratio": ["type": "string", "description": "画面比例，比如 16:9、9:16、1:1"],
                        "x": ["type": "number", "description": "位置，不传就自动摆在现有卡片右边"],
                        "y": ["type": "number"]
                    ] as [String: Any],
                    "required": ["kind"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "update_canvas_node",
                description: "改一张卡片：文字、提示词、比例、位置。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "node_id": ["type": "string", "description": "卡片 id 前 8 位（read_canvas 里有）"],
                        "text": ["type": "string"],
                        "prompt": ["type": "string"],
                        "ratio": ["type": "string"],
                        "x": ["type": "number"],
                        "y": ["type": "number"]
                    ] as [String: Any],
                    "required": ["node_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "connect_canvas_nodes",
                description: """
                把两张卡片连起来：**上游卡片会成为下游卡片的参考素材**。
                类型不合的连不上（比如图片模型不收音频当参考），会直接告诉你原因。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "上游卡片 id（当参考的那张）"],
                        "to": ["type": "string", "description": "下游卡片 id（要生成的那张）"]
                    ] as [String: Any],
                    "required": ["from", "to"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "disconnect_canvas_nodes",
                description: "断开两张卡片之间的连线。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string"],
                        "to": ["type": "string"]
                    ] as [String: Any],
                    "required": ["from", "to"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "generate_canvas_node",
                description: """
                让一张卡片开始生成。**花钱**，后台跑，不会当场出结果 ——
                过一会儿用 read_canvas 看状态。

                **画面从哪来**：只有这张卡片自己的提示词，加上**连到它的上游卡片**。
                没有上游就是纯文字生图，跟画布上现有的图一点关系都没有。
                所以用户说「把这张图改成竖版 / 换个风格 / 照这张再来一版」时，
                **必须把原图当参考**：要么先 connect_canvas_nodes 连上，
                要么直接在这里写 reference —— 只改提示词让它重跑，出来的是另一张
                毫不相干的图，等于把用户原来那张弄丢了。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "node_id": ["type": "string", "description": "要生成的卡片 id"],
                        "reference": ["type": "array", "items": ["type": "string"] as [String: Any],
                                      "description": "拿这些卡片当参考素材（写 id），"
                                                   + "会自动连好线再开跑。「照着某张图改」就填它"],
                        "model": ["type": "string",
                                  "description": "用哪家模型生成，比如 seedream、image2、nanobanana。"
                                               + "不填就用设置里选的那家"]
                    ] as [String: Any],
                    "required": ["node_id"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "delete_canvas_node",
                description: "从画布上删掉一张卡片（连着它的线一起没）。素材库里的东西不动。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "node_id": ["type": "string"]
                    ] as [String: Any],
                    "required": ["node_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "canvas_to_timeline",
                description: """
                把画布卡片上的成品放到时间轴上。卡片得有内容（生成完了或者本来就有素材）。
                文本卡片没东西可放。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "node_id": ["type": "string"],
                        "time": ["type": "number", "description": "落在第几秒，不传就放播放头处"]
                    ] as [String: Any],
                    "required": ["node_id"]
                ],
                risk: .mutating)
        ]
    }

    // MARK: - 执行

    @MainActor
    static func runCanvasTool(_ name: String, args: [String: Any],
                              project p: ProjectState) -> AgentToolResult? {
        let canvas = p.canvas
        switch name {

        case "read_canvas":
            return .ok(canvasReport(p))

        case "add_canvas_node":
            guard let kindRaw = args["kind"] as? String,
                  let kind = CanvasNode.Kind(rawValue: kindRaw.lowercased())
            else { return .fail("kind 只能是 text / image / video / audio。") }

            // 不给位置就摆在最右边那张的右侧，别糊在一起
            let pos: CGPoint
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                pos = CGPoint(x: x, y: y)
            } else if let rightmost = canvas.nodes.max(by: { $0.position.x < $1.position.x }) {
                pos = CGPoint(x: rightmost.position.x + rightmost.size.width + 60,
                              y: rightmost.position.y)
            } else {
                pos = CGPoint(x: 200, y: 200)
            }

            let ratio = args["ratio"] as? String ?? "1:1"
            let node = canvas.addNode(kind: kind, at: pos, ratio: ratio)
            canvas.updateNode(id: node.id) {
                if let t = args["text"] as? String { $0.text = t }
                if let pr = args["prompt"] as? String { $0.prompt = pr }
            }
            if let key = args["asset_id"] as? String {
                guard let asset = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(key) }) else {
                    return .fail("素材库里找不到 id 以 \(key) 开头的素材，先调 list_assets 看看。")
                }
                canvas.updateNode(id: node.id) {
                    $0.assetID = asset.id
                    $0.mediaPath = asset.url.path
                }
            }
            canvas.persist()
            return .ok("画布上加了一张\(kind.label)卡片，id \(shortID(node.id))。")

        case "update_canvas_node":
            guard let node = resolveNode(args["node_id"], canvas) else { return nodeNotFound(args["node_id"]) }
            canvas.updateNode(id: node.id) {
                if let t = args["text"] as? String { $0.text = t }
                if let pr = args["prompt"] as? String { $0.prompt = pr }
                if let x = args["x"] as? Double { $0.position.x = x }
                if let y = args["y"] as? Double { $0.position.y = y }
            }
            if let r = args["ratio"] as? String { canvas.setRatio(r, for: node.id) }
            canvas.persist()
            return .ok("改好了。")

        case "connect_canvas_nodes":
            guard let from = resolveNode(args["from"], canvas) else { return nodeNotFound(args["from"]) }
            guard let to = resolveNode(args["to"], canvas) else { return nodeNotFound(args["to"]) }
            guard from.id != to.id else { return .fail("不能自己连自己。") }
            let provider = AIVideoService.provider(for: to.kind.providerCategory)
            let r = canvas.connect(from: from.id, to: to.id, provider: provider)
            if let why = r.message { return .fail(why) }
            canvas.persist()
            return .ok("连上了：\(from.kind.label) → \(to.kind.label)。")

        case "disconnect_canvas_nodes":
            guard let from = resolveNode(args["from"], canvas) else { return nodeNotFound(args["from"]) }
            guard let to = resolveNode(args["to"], canvas) else { return nodeNotFound(args["to"]) }
            canvas.disconnect(from: from.id, to: to.id)
            canvas.persist()
            return .ok("断开了。")

        case "generate_canvas_node":
            guard let node = resolveNode(args["node_id"], canvas) else { return nodeNotFound(args["node_id"]) }
            // 顺手把参考卡片连上。模型最容易犯的错就是「只改提示词直接重跑」，
            // 出来一张跟原图毫不相干的东西，用户以为「改」结果是「换」
            var linked: [String] = []
            // 模型传数组、传逗号分隔的一串、传单个 id 的都有，一律认
            var refIDs: [String] = []
            if let arr = args["reference"] as? [Any] {
                refIDs = arr.compactMap { $0 as? String }
            } else if let one = args["reference"] as? String {
                refIDs = one.split(whereSeparator: { ",，、 ".contains($0) }).map(String.init)
            }
            if !refIDs.isEmpty {
                for r in refIDs {
                    // 写了参考却找不到那张卡片，必须报错 —— 静默跳过的话
                    // 它照样开跑，出来一张没参考过任何东西的图，用户还以为参考上了
                    guard let up = resolveNode(r, canvas) else { return nodeNotFound(r) }
                    guard up.id != node.id else { continue }
                    guard !canvas.edges.contains(where: { $0.from == up.id && $0.to == node.id }) else {
                        linked.append(shortID(up.id)); continue
                    }
                    let p = AIVideoService.provider(for: node.kind.providerCategory)
                    let r2 = canvas.connect(from: up.id, to: node.id, provider: p)
                    if let why = r2.message { return .fail("连不上参考卡片：" + why) }
                    linked.append(shortID(up.id))
                }
            }
            guard node.kind != .text || !node.prompt.isEmpty else {
                return .fail("这张卡片没有提示词，先用 update_canvas_node 填上 prompt。")
            }
            guard !node.isGenerating else { return .fail("这张卡片正在生成，等它跑完。") }
            // 点名了就用它那家。画布卡片本来就能换模型（界面上卡片底下那排下拉），
            // 工具不暴露的话只能一直用默认那家
            let category = node.kind.providerCategory
            var provider = AIVideoService.provider(for: category)
            if let want = (args["model"] as? String)?.trimmingCharacters(in: .whitespaces),
               !want.isEmpty {
                guard let picked = AgentToolbox.matchProvider(want, category) else {
                    let names = AIVideoService.Provider.allCases
                        .filter { !$0.isHidden && $0.category == category }
                        .map(\.displayName).joined(separator: "、")
                    return .fail("没有叫「\(want)」的\(category.rawValue)模型。能用的是：\(names)")
                }
                guard !AIVideoService.apiKey(for: picked).isEmpty else {
                    return .fail("「\(picked.displayName)」还没配 API Key，去设置 → AI 设置里填上再试。")
                }
                provider = picked
            }
            // 登记进后台任务清单，**用卡片 id 当任务 id** —— 画布那边出结果时
            // 手上只有 nodeID。不登记的话这活儿跑完没人吭声，
            // 用户等半天不知道成没成（实测就是这样：提交完就没下文了）
            AgentBackgroundTasks.shared.add(id: node.id,
                                            title: "画布上生成\(node.kind.label)",
                                            kind: node.kind.providerCategory,
                                            cancelAction: { [weak canvas] in
                                                canvas?.cancelGeneration(nodeID: node.id)
                                            })
            canvas.submitGeneration(nodeID: node.id, provider: provider)
            let refNote = linked.isEmpty
                ? (canvas.upstreamNodes(of: node.id).isEmpty
                   ? "（没有参考素材，这是纯文字生图）" : "")
                : "（参考：\(linked.joined(separator: "、"))）"
            return .ok("已经让它开跑了\(refNote)，用的是 \(provider.displayName)，后台生成。跑完我会在这儿说一声。")

        case "delete_canvas_node":
            guard let node = resolveNode(args["node_id"], canvas) else { return nodeNotFound(args["node_id"]) }
            canvas.removeNode(id: node.id)
            canvas.persist()
            return .ok("删掉了那张\(node.kind.label)卡片。")

        case "canvas_to_timeline":
            guard let node = resolveNode(args["node_id"], canvas) else { return nodeNotFound(args["node_id"]) }
            guard let url = node.mediaURL else {
                return .fail("这张卡片上还没有成品，放不上时间轴。")
            }
            // 卡片上的东西未必进过素材库（画布生成的成品是先落在卡片上的），
            // 素材库里没有就先导入一份，不然时间轴引用不到
            let asset: MediaAsset
            if let id = node.assetID, let a = p.mediaAssets.first(where: { $0.id == id }) {
                asset = a
            } else if let a = p.mediaAssets.first(where: { $0.url.path == url.path }) {
                asset = a
            } else {
                p.importFile(url)
                guard let imported = p.mediaAssets.first(where: { $0.url.path == url.path }) else {
                    return .fail("「\(url.lastPathComponent)」导不进素材库，放不上时间轴。")
                }
                asset = imported
            }
            guard asset.fileExists else { return .fail("「\(asset.name)」的源文件已经不在了。") }
            p.addToTimelineAt(asset, time: args["time"] as? Double ?? p.currentTime, skipUndo: true)
            return .ok("已把「\(asset.name)」放到时间轴。")

        default:
            return nil
        }
    }

    // MARK: - 辅助

    /// 卡片 id 前 8 位，跟素材那套指认方式保持一致
    private static func shortID(_ id: UUID) -> String {
        String("\(id)".prefix(8))
    }

    @MainActor
    private static func resolveNode(_ key: Any?, _ canvas: CanvasState) -> CanvasNode? {
        guard let k = (key as? String)?.trimmingCharacters(in: .whitespaces), !k.isEmpty else { return nil }
        return canvas.nodes.first { "\($0.id)".hasPrefix(k) }
    }

    private static func nodeNotFound(_ key: Any?) -> AgentToolResult {
        .fail("画布上找不到 id 以 \(key as? String ?? "") 开头的卡片，先调 read_canvas 看看有哪些。")
    }

    /// 画布现状。直接给表格 —— 卡片是并列的多条同构记录，本来就该这么看
    @MainActor
    private static func canvasReport(_ p: ProjectState) -> String {
        let canvas = p.canvas
        guard !canvas.nodes.isEmpty else { return "画布上还是空的，一张卡片都没有。" }

        var out = "画布上有 \(canvas.nodes.count) 张卡片：\n\n"
        out += "| id | 类型 | 内容 | 提示词 | 状态 |\n|---|---|---|---|---|\n"
        for n in canvas.nodes {
            let content: String
            switch n.kind {
            case .text:
                let t = n.text.replacingOccurrences(of: "\n", with: " ")
                content = t.isEmpty ? "（空）" : String(t.prefix(40))
            default:
                content = n.mediaURL?.lastPathComponent ?? "（还没有素材）"
            }
            let state: String
            if n.isGenerating { state = n.progressText ?? "生成中" }
            else if n.isWaiting { state = "排队等上游" }
            else if let f = n.failure { state = "失败：" + String(f.prefix(30)) }
            else if n.hasContent { state = "已完成" }
            else { state = "空着" }
            let prompt = n.prompt.isEmpty ? "—" : String(n.prompt.prefix(30))
            out += "| \(shortID(n.id)) | \(n.kind.label) | \(content) | \(prompt) | \(state) |\n"
        }

        if !canvas.edges.isEmpty {
            out += "\n连线（上游 → 下游，上游是下游的参考素材）：\n"
            for e in canvas.edges {
                guard let f = canvas.node(e.from), let t = canvas.node(e.to) else { continue }
                out += "- \(shortID(f.id)) \(f.kind.label) → \(shortID(t.id)) \(t.kind.label)\n"
            }
        }

        if !canvas.groups.isEmpty {
            out += "\n分组：\n"
            for g in canvas.groups {
                let members = canvas.nodes.filter { $0.groupID == g.id }.count
                out += "- \(g.name.isEmpty ? "未命名" : g.name)：\(members) 张卡片\n"
            }
        }

        out += "\n卡片里的画面要看清楚的话，拿上面那个文件名对应的素材去调 capture_frame 或 read_frame_text。"
        return out
    }
}
