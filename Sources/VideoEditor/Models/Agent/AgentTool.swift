// AgentTool.swift
//
// Agent 能调的工具的统一描述。
//
// 每个工具三件事：给模型看的 JSON Schema、危不危险、怎么执行。
// **危险与否是工具自己声明的**，不是调用处判断 —— 判断散在各处迟早会漏，
// 漏一个就意味着「自动模式」里某个删除操作不问自答地执行了。

import Foundation

/// 工具改动项目的程度。三个模式据此决定放行、询问还是拒绝
enum AgentToolRisk {
    /// 只读，什么都不改
    case readOnly
    /// 常规改动：加片段、挂特效、改属性。自动模式直接做
    case mutating
    /// 不好回头的：删轨道、覆盖文件、导出、跑脚本。自动模式要先问
    case dangerous
}

struct AgentToolSpec {
    let name: String
    let description: String
    /// JSON Schema，直接喂给模型的 tools 参数
    let parameters: [String: Any]
    let risk: AgentToolRisk
}

/// 工具执行结果。文本回模型，图片走多模态那条
struct AgentToolResult {
    var text: String
    var imageData: Data? = nil
    var isError: Bool = false

    static func ok(_ t: String) -> AgentToolResult { .init(text: t) }
    static func fail(_ t: String) -> AgentToolResult { .init(text: t, isError: true) }
}

/// Agent 的运行模式
enum AgentMode: String, CaseIterable, Codable {
    case plan = "计划"
    case auto = "自动"
    case full = "全权"

    var help: String {
        switch self {
        case .plan: return "只读项目、只给方案，不动任何东西"
        case .auto: return "加片段、挂特效这类直接做；删除、导出、跑脚本会先问你"
        case .full: return "所有操作都不再询问"
        }
    }

    /// 这个模式让不让跑某个风险级别的工具。
    /// nil = 放行；返回的字符串是拒绝理由，原样回给模型
    func rejection(for risk: AgentToolRisk) -> String? {
        switch (self, risk) {
        case (.plan, .readOnly): return nil
        case (.plan, _):
            return "当前是计划模式，不能改动项目。请把要做的步骤列出来，等用户确认后切到自动模式再执行。"
        default: return nil
        }
    }

    /// 要不要弹窗问一下
    func needsConfirm(for risk: AgentToolRisk) -> Bool {
        self == .auto && risk == .dangerous
    }
}
