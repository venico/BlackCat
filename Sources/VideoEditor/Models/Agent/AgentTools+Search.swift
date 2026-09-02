// AgentTools+Search.swift
//
// 外挂联网搜索。
//
// 只在**这家没有原生联网**（或者走了中转站，原生发不过去）时才挂上来。
// 能用原生就用原生：搜索在服务端跑，模型自己决定搜什么词、能多轮搜，
// 比这边拼提示词准。

import Foundation

extension AgentToolbox {

    static var searchTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "web_search",
                description: """
                上网搜一段内容，拿回若干条结果和链接。需要最新消息、\
                或者拿不准的事实，先搜再答，别凭记忆编。\
                一次搜不到就换个说法再搜，最多三次。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "搜索词"]
                    ] as [String: Any],
                    "required": ["query"]
                ],
                risk: .readOnly),
        ]
    }

    static func runSearchTool(_ name: String, args: [String: Any]) async -> AgentToolResult? {
        guard name == "web_search" else { return nil }
        guard let q = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            return .fail("没给 query。")
        }
        do {
            let r = try await AIVideoService.shared.agentWebSearch(q)
            return r.isEmpty ? .fail("没搜到东西，换个说法再试。") : .ok(r)
        } catch {
            // Key 没填是最常见的一种，把话说明白，别让模型以为是网络问题一直重试
            return .fail("搜索失败：\(error.localizedDescription)")
        }
    }
}
