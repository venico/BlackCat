// AgentTools+Ask.swift
//
// 给用户出选项。原来 Agent 碰到歧义只能把 A/B/C 写成一段话、等用户打字回一个字母，
// 而且这一轮就此结束，回完要重新开一轮。现在输入框上方弹一条选项栏：
// 2～4 个按钮 + 一个「自己写」的输入框，用户答完这一轮接着往下做。

import AppKit

extension AgentToolbox {

    static let askTool = AgentToolSpec(
        name: "ask_user",
        description: """
        有真正的歧义、猜错了代价大时，给用户出 2～4 个选项（界面上是按钮，另带一个输入框可以自己写）。
        用户答完你**接着往下做**，不用另起一轮，也不要再把选项写一遍在回复里。
        **没歧义就别问**：只有一种合理理解、或者只有一个对象可选的，直接做。
        不要拿它问「要不要继续」「确认吗」这种话 —— 花钱、删除的操作软件自己会弹确认。
        选项写成能直接照着做的说法（「切上层 Telstra 那条」），不要只写「A」「B」。
        """,
        parameters: [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "问什么，一句话"],
                "options": ["type": "array", "items": ["type": "string"] as [String: Any],
                            "description": "2～4 个选项，每个是一句能直接执行的说法"]
            ] as [String: Any],
            "required": ["question", "options"]
        ],
        risk: .readOnly)

    static let viewAttachmentsTool = AgentToolSpec(
        name: "view_attachments",
        description: """
        看用户在这个会话里发过的图（最近 12 张，按发的先后编号，从 1 起）。图默认不发给你 ——
        用户问图里是什么、要你根据图的内容判断时才调；只是要拿图当参考去生成的，不用看，直接调生成工具。
        不传 index：看这一轮新挂的那几张（这轮没挂就看最近的几张），多张会拼成一张；传 index 只看那一张，更清楚。
        """,
        parameters: [
            "type": "object",
            "properties": [
                "index": ["type": "integer", "description": "看第几张（从 1 起）。不传就全部拼在一起看"]
            ] as [String: Any]
        ],
        risk: .readOnly)

    @MainActor
    static func viewAttachments(_ args: [String: Any]) -> AgentToolResult {
        let svc = AIVideoService.shared
        let urls = svc.conversationImageURLs()
        guard !urls.isEmpty else { return .fail("这个会话里用户还没发过图。让他用 ＋ 上传或者粘贴一张。") }
        let idx = (args["index"] as? Int) ?? (args["index"] as? Double).map { Int($0) }
        if let i = idx {
            guard urls.indices.contains(i - 1) else { return .fail("只有 \(urls.count) 张图，index 从 1 到 \(urls.count)。") }
            guard let img = NSImage(contentsOf: urls[i - 1]),
                  let d = AgentAttachmentIO.jpegData(img, maxSide: 1600) else {
                return .fail("第 \(i) 张读不出来（\(urls[i - 1].lastPathComponent)）。")
            }
            return AgentToolResult(text: "第 \(i) 张：\(urls[i - 1].lastPathComponent)", imageData: d)
        }
        // 默认看这一轮新挂的；这轮没挂就看最近的 4 张
        let first = svc.agentRoundViewStart ?? max(1, urls.count - 3)
        let picked = Array(urls.enumerated().dropFirst(first - 1).prefix(6))
        let imgs = picked.compactMap { NSImage(contentsOf: $0.element) }
        guard !imgs.isEmpty else { return .fail("图都读不出来。") }
        guard let d = imgs.count == 1 ? AgentAttachmentIO.jpegData(imgs[0], maxSide: 1600)
                                      : contactSheet(imgs) else { return .fail("拼图失败。") }
        let names = picked.map { "第 \($0.offset + 1) 张 \($0.element.lastPathComponent)" }
        return AgentToolResult(text: "会话里一共 \(urls.count) 张，这里是"
                                   + (imgs.count > 1 ? "（从左到右、从上到下）" : "")
                                   + names.joined(separator: "；")
                                   + (urls.count > picked.count ? "。要看别的就传 index。" : ""),
                               imageData: d)
    }

    /// 几张图拼成一张（每行两张，每格 640），一次工具结果只能带一张图
    private static func contactSheet(_ imgs: [NSImage]) -> Data? {
        let cell: CGFloat = 640, gap: CGFloat = 8
        let cols = 2, rows = (imgs.count + 1) / 2
        let w = Int(CGFloat(cols) * cell + CGFloat(cols - 1) * gap)
        let h = Int(CGFloat(rows) * cell + CGFloat(rows - 1) * gap)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (i, img) in imgs.enumerated() {
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let s = min(cell / iw, cell / ih)
            let dw = iw * s, dh = ih * s
            let col = i % cols, row = i / cols
            // CGContext 原点在左下，第一行要画在最上面
            let x = CGFloat(col) * (cell + gap) + (cell - dw) / 2
            let y = CGFloat(h) - CGFloat(row + 1) * cell - CGFloat(row) * gap + (cell - dh) / 2
            ctx.draw(cg, in: CGRect(x: x, y: y, width: dw, height: dh))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// 解析模型传来的选项：数组、或者用换行 / 顿号隔开的一串都认
    static func askOptions(_ args: [String: Any]) -> [String] {
        let raw: [String]
        if let arr = args["options"] as? [Any] {
            raw = arr.compactMap { $0 as? String }
        } else if let s = args["options"] as? String {
            raw = s.split(whereSeparator: { "\n、".contains($0) }).map(String.init)
        } else {
            raw = []
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
