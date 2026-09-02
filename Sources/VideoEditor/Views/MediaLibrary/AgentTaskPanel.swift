// AgentTaskPanel.swift
//
// 聊天框左上角那个后台任务入口，点一下向上展开。
//
// 生成类任务不阻塞对话，进度就集中在这儿看 —— 不然它们要么把会话刷满，
// 要么干脆看不见，用户只能干等着猜好没好。

import SwiftUI

struct AgentTaskEntry: View {
    @ObservedObject private var tasks = AgentBackgroundTasks.shared
    @State private var expanded = false
    @State private var hover = false

    var body: some View {
        // 一个任务都没有就不占位置
        if !tasks.items.isEmpty {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    if tasks.runningCount > 0 {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 10))
                            .renderingMode(.template)
                    }
                    Text(tasks.runningCount > 0
                         ? "\(tasks.runningCount) 个任务进行中"
                         : "后台任务")
                        .font(.system(size: 10))
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundColor(hover ? Color.labelPrimary : Color.labelSecondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            // 向上展开：面板往上长，不去挤输入框
            .popover(isPresented: $expanded, arrowEdge: .top) {
                taskList
            }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("后台任务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                if tasks.items.contains(where: { !$0.isRunning }) {
                    Button("清除已完成") { tasks.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks.items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 260)
    }

    private func row(_ item: AgentBackgroundTasks.Item) -> some View {
        HStack(spacing: 6) {
            switch item.state {
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12)
            case .done:
                Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 12))
                    .renderingMode(.template).foregroundColor(Color(hex: "#5DB85D"))
            case .failed:
                Image(nsImage: SidebarSVGIcon.load("toastFail", size: 12))
                    .renderingMode(.template).foregroundColor(Color(hex: "#FF6B6B"))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.system(size: 9))
                    .foregroundColor(Color.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if item.isRunning {
                Button { tasks.cancel(id: item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("取消")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
    }

    private func subtitle(_ item: AgentBackgroundTasks.Item) -> String {
        switch item.state {
        case .running:
            return "\(item.kind.rawValue) · 已经 \(Int(Date().timeIntervalSince(item.startedAt))) 秒"
        case .done:
            return "\(item.kind.rawValue) · 已完成，素材已进库"
        case .failed(let m):
            return String(m.prefix(40))
        }
    }
}
