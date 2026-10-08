// AgentTools+Gap.swift
//
// 能力缺口记录。Agent 真做不了的事，记进一个文件，开发时读它就知道该补什么。
//
// 两条路进来：
//   · Agent 自己报（report_gap）—— 它最清楚卡在哪、试过什么
//   · 兜底：它回了「做不了」却没报，这一轮结束时按回复里的说法自动记一笔（可能误报，标出来）

import Foundation

extension AgentToolbox {

    static let reportGapTool = AgentToolSpec(
        name: "report_gap",
        description: """
        记录一个你做不了的需求，开发者会照着补能力。
        **只在先用 search_tools 换说法搜过、确实没有能做这件事的工具时用**，报完再如实告诉用户这个暂时做不到。
        写清楚：用户要做什么、你试了什么、卡在哪、需要一个什么样的能力才能做成。
        """,
        parameters: [
            "type": "object",
            "properties": [
                "request": ["type": "string", "description": "用户想做的事，用他的原话或简单转述"],
                "tried": ["type": "string", "description": "你试过哪些工具、搜过哪些词"],
                "missing": ["type": "string", "description": "缺的是什么：哪个参数没开放、哪类操作没有工具"],
                "suggestion": ["type": "string", "description": "建议补一个什么能力（工具名、参数）"]
            ] as [String: Any],
            "required": ["request", "missing"]
        ],
        risk: .readOnly)

    /// 测试里换到临时文件，别往用户真的缺口记录里写
    nonisolated(unsafe) static var gapLogOverride: URL?

    static var gapLogURL: URL {
        gapLogOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("黑猫剪辑/logs/能力缺口.md")
    }

    static func runGapTool(_ args: [String: Any]) -> AgentToolResult {
        let request = (args["request"] as? String) ?? ""
        let missing = (args["missing"] as? String) ?? ""
        guard !request.isEmpty, !missing.isEmpty else { return .fail("request 和 missing 都要写。") }
        appendGap(request: request, tried: args["tried"] as? String, missing: missing,
                  suggestion: args["suggestion"] as? String, source: "Agent 报告")
        return .ok("记下了。现在如实告诉用户这个暂时做不到，已经记录给开发者。")
    }

    static func appendGap(request: String, tried: String?, missing: String,
                          suggestion: String?, source: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var entry = "\n## \(f.string(from: Date())) · v\(ver) · \(source)\n"
        entry += "- 用户要做：\(request.replacingOccurrences(of: "\n", with: " "))\n"
        if let t = tried, !t.isEmpty { entry += "- 试过：\(t.replacingOccurrences(of: "\n", with: " "))\n" }
        entry += "- 卡在哪：\(missing.replacingOccurrences(of: "\n", with: " "))\n"
        if let s = suggestion, !s.isEmpty { entry += "- 建议补：\(s.replacingOccurrences(of: "\n", with: " "))\n" }

        let url = gapLogURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try? "# 黑猫剪辑 · Agent 能力缺口\n\nAgent 做不了的需求记在这里，开发时照着补。\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        }
    }

    /// 兜底：回复里说了做不了、这一轮又没报过，自动记一笔
    static func autoReportGapIfNeeded(prompt: String, reply: String, calledTools: [String]) {
        guard !calledTools.contains("report_gap") else { return }
        let phrases = ["做不了", "没有这个功能", "没有这个能力", "没有对应的工具", "没有能", "暂时不能",
                       "目前不能", "不支持", "没法做", "办不到", "无法完成", "无法实现"]
        guard let hit = phrases.first(where: { reply.contains($0) }) else { return }
        // 提示词后面拼着的 [系统说明] 不算用户原话
        let ask = prompt.components(separatedBy: "\n\n[").first ?? prompt
        let around: String = {
            guard let r = reply.range(of: hit) else { return String(reply.prefix(160)) }
            let start = reply.index(r.lowerBound, offsetBy: -60, limitedBy: reply.startIndex) ?? reply.startIndex
            let end = reply.index(r.upperBound, offsetBy: 100, limitedBy: reply.endIndex) ?? reply.endIndex
            return String(reply[start..<end])
        }()
        appendGap(request: String(ask.prefix(300)), tried: calledTools.joined(separator: "、"),
                  missing: "Agent 回复：…\(around)…", suggestion: nil, source: "自动判定（可能误报）")
    }
}
