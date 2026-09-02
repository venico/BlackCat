// AgentChatViews.swift
//
// Agent 会话用到的几块界面：模式切换、工具调用过程、危险操作确认。

import SwiftUI

/// 输入框上方那个模式切换
struct AgentModePicker: View {
    @Binding var mode: AgentMode
    @State private var hover: AgentMode?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    Text(m.rawValue)
                        .font(.system(size: 10, weight: mode == m ? .semibold : .regular))
                        .foregroundColor(mode == m ? Color.labelPrimary : Color.labelSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(mode == m ? Color.white.opacity(0.14)
                                            : (hover == m ? Color.white.opacity(0.06) : Color.clear)))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? m : (hover == m ? nil : hover) }
                .help(m.help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
    }
}

/// Agent 这一轮调了哪些工具。**默认折叠** ——
/// 十来行工具调用铺开会把真正的回答挤下去，想看再展开
struct AgentStepsView: View {
    let steps: [AIVideoService.ConversationRecord.AgentStepRecord]
    let isRunning: Bool
    /// 这一轮跑了多久
    var elapsed: TimeInterval = 0
    /// 累计 token。中转站不回 usage 时是 0，这段就不显示
    var tokens: Int = 0
    /// 此刻在干什么。跑完是空的
    var phase: String = ""
    @State private var expanded = false

    /// 「12s」/「1m24s」
    private var timeText: String {
        let sec = Int(elapsed.rounded())
        return sec < 60 ? "\(sec)s" : "\(sec / 60)m\(sec % 60)s"
    }

    /// 「832 tokens」/「5.6k tokens」
    private var tokenText: String {
        tokens < 1000 ? "\(tokens) tokens"
            : String(format: "%.1fk tokens", Double(tokens) / 1000)
    }

    /// 时间和用量，有哪个显示哪个
    private var meta: String {
        var parts: [String] = []
        if elapsed >= 1 { parts.append(timeText) }
        if tokens > 0 { parts.append(tokenText) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private var headline: String {
        if isRunning {
            // 正在跑的时候，「在干什么」比「跑了几步」有用
            let what = phase.isEmpty ? "正在执行" : phase
            return steps.isEmpty ? what : "\(what)（\(steps.count) 步）"
        }
        return "执行了 \(steps.count) 步"
    }

    var body: some View {
        // 刚发出去还没调工具时 steps 是空的，但用户已经在等了，
        // 这时候更需要看到「正在思考 · 3s」
        if !steps.isEmpty || isRunning {
            VStack(alignment: .leading, spacing: 3) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(steps.isEmpty ? 0 : 1)
                        Text(headline + meta)
                            .font(.system(size: 10))
                            .monospacedDigit()
                        if steps.contains(where: \.isError) {
                            Text("有失败")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#FF9230"))
                        }
                    }
                    .foregroundColor(Color.labelSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(steps.isEmpty)

                if expanded {
                    // 十几步的时候整块能把输入框顶出屏幕，给个上限、超了自己滚。
                    // 用 maxHeight 不用 height：ScrollView 的理想高度就是内容高度，
                    // maxHeight 只封顶。先前拿 GeometryReader 量内容再钉 height，
                    // 首帧量到 0、高度被钳成 1pt，展开等于没展开
                    ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                    ForEach(steps) { s in
                        HStack(alignment: .top, spacing: 5) {
                            Circle()
                                .fill(s.isError ? Color(hex: "#FF6B6B") : Color.labelSecondary.opacity(0.5))
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text("\(s.tool) · \(s.summary)")
                                .font(.system(size: 10))
                                .foregroundColor(Color.labelSecondary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    }
                    }
                    .frame(maxHeight: 600)
                    .padding(.leading, 2)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        }
    }
}

/// 危险操作的确认条。**直接长在会话里**，不弹系统 alert ——
/// Agent 干活时用户的注意力就在这块，弹窗打断反而更烦
struct AgentConfirmBar: View {
    let toolName: String
    let detail: String
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 13))
                    .renderingMode(.template)
                    .foregroundColor(Color(hex: "#FF9230"))
                Text(toolName == "run_command" ? "要在你的电脑上跑一条命令" : "这一步会改动不好回头的东西")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
            }
            if toolName == "run_command" {
                // 命令原文是这里最要紧的东西：等宽 + 单独的底色，
                // 免得跟上面那句说明混成一片，看漏了才点确认
                let parts = detail.components(separatedBy: "\n\n")
                if parts.count > 1, !parts[0].isEmpty {
                    Text(parts[0])
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(parts.last ?? detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color.labelPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28)))
            } else {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("拒绝") { onAnswer(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                Button("允许") { onAnswer(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#E8A54B")))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#FF9230").opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color(hex: "#FF9230").opacity(0.30), lineWidth: 1))
    }
}
