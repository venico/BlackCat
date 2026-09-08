// AgentTools+MCP.swift
//
// 把外接 MCP server 的工具塞进 Agent 的工具表。
//
// 风险一律按 mutating 算：对方的工具会干什么我们无从判断，
// 保守起见当成「会改东西」—— 计划模式下不给，自动模式直接跑。
// 定成 dangerous 的话每调一次都要弹确认，外部工具往往一轮要调好几次，
// 人就只剩点确认这一件事可干了（跟 run_command 那边同一个取舍）。

import Foundation

extension AgentToolbox {

    /// 这轮挂给模型的外部工具：**只给用户这句话点到的那几个服务**。
    /// 全给的话上百个工具会把请求撑爆，模型连内置工具都找不着了
    @MainActor
    static var mcpTools: [AgentToolSpec] {
        AgentMCP.shared.activeTools.map { t in
            AgentToolSpec(
                name: t.qualifiedName,
                // 描述前面挂上服务名，模型才知道这是哪家的工具
                description: "【\(t.serverName)】" + (t.description.isEmpty ? t.name : t.description),
                parameters: t.inputSchema,
                risk: .mutating)
        }
    }

    /// 「把某个外部服务的工具要过来」。这条永远挂着，
    /// 服务本身的那一堆工具则要它先要过来才出现
    @MainActor
    static var mcpGateTool: [AgentToolSpec] {
        guard !AgentMCP.shared.promptSection.isEmpty else { return [] }
        return [AgentToolSpec(
            name: "enable_service",
            description: """
            把某个外部服务的工具挂进来。系统提示词末尾列了现在接了哪些服务、各能干什么。            判断这件事要用到其中某个（哪怕用户没点它的名），就先调这个，下一步那些工具就能用了。            用不上的别挂 —— 挂太多会把你自己淹掉。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "服务名，照提示词里列的写"]
                ] as [String: Any],
                "required": ["name"]
            ],
            risk: .readOnly)]
    }

    @MainActor
    static func runMCPTool(_ name: String, args: [String: Any]) async -> AgentToolResult? {
        if name == "enable_service" {
            guard let n = args["name"] as? String else { return .fail("缺 name") }
            return AgentMCP.shared.enable(named: n)
        }
        guard name.hasPrefix("mcp__") else { return nil }
        return await AgentMCP.shared.call(qualified: name, args: args)
    }
}
