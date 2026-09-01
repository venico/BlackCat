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
    @State private var expanded = false

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(isRunning ? "正在执行…（\(steps.count) 步）" : "执行了 \(steps.count) 步")
                            .font(.system(size: 10))
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

                if expanded {
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
                Text("这一步会改动不好回头的东西")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
