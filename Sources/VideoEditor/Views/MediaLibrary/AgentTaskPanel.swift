// AgentTaskPanel.swift
//
// 聊天框左上角那个后台任务入口，点一下向上展开。
//
// 生成类任务不阻塞对话，进度就集中在这儿看 —— 不然它们要么把会话刷满，
// 要么干脆看不见，用户只能干等着猜好没好。

import SwiftUI
import AppKit

struct AgentTaskEntry: View {
    @ObservedObject private var tasks = AgentBackgroundTasks.shared
    /// 会话一换，这份清单跟着换 —— 得观察它才会重算
    @ObservedObject private var service = AIVideoService.shared
    @State private var expanded = false
    @State private var hover = false
    /// 卡片和标签各自占的地方。**不能量外面那个 VStack** ——
    /// 它的宽度被 260 的卡片撑满了，标签右边那截空白也算在里头，
    /// 点上去不收起
    @State private var cardRect: CGRect = .zero
    @State private var labelRect: CGRect = .zero
    /// 点外面收起用的鼠标监听。展开时装，收起时拆
    @State private var clickMonitor: Any?

    var body: some View {
        // 一个任务都没有就不占位置
        Group {
        if !tasks.currentItems.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
            // 展开的卡片长在标签上方 —— 往下长会把输入框顶出去，
            // 往上长挤的是可以滚的会话区
            if expanded { taskCard.trackFrame { cardRect = $0 } }
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    if tasks.needsConfirmCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#FFB020"))
                    } else if tasks.runningCount > 0 {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 10))
                            .renderingMode(.template)
                    }
                    // 待确认排在最前面报 —— 它是唯一需要用户动手的状态，
                    // 被「3 个任务进行中」盖住的话就白问了
                    Text(tasks.needsConfirmCount > 0
                         ? "\(tasks.needsConfirmCount) 个任务待确认"
                         : (tasks.runningCount > 0
                            ? "\(tasks.runningCount) 个任务进行中"
                            : "后台任务"))
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
            .trackFrame { labelRect = $0 }
            }
            .onChange(of: expanded) { _, open in
                open ? startWatchingOutsideClick() : stopWatchingOutsideClick()
            }
            .onDisappear { stopWatchingOutsideClick() }
        }
        }
        // 任务清空后入口整个消失，但 expanded 是 @State，会一直留着 ——
        // 下次有新任务入口重新冒出来就是展开的，看着像它自己弹开了
        .onChange(of: tasks.currentItems.isEmpty) { _, empty in
            if empty { expanded = false }
        }
    }

    /// 点面板外面就收起。
    ///
    /// 用 NSEvent 监听而不是铺一层透明的「点击遮罩」—— 卡片是就地展开在
    /// 输入区上方的，铺遮罩得挂到整个窗口那层去，还会把底下的会话挡住点不动
    private func startWatchingOutsideClick() {
        stopWatchingOutsideClick()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { ev in
            // 坐标换算照 GatedHostingView 那套：窗口坐标 → 内容视图坐标，
            // 不是 flipped 的再翻一次，才跟 SwiftUI 的 .global 对得上
            guard let content = ev.window?.contentView else { return ev }
            let inContent = content.convert(ev.locationInWindow, from: nil)
            let pt = content.isFlipped
                ? inContent
                : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
            // 卡片里的取消 / 清除已完成，以及标签自己，都不算点外面
            // （标签留给 Button 自己 toggle，不然点一下一开一关等于没反应）
            if !cardRect.contains(pt) && !labelRect.contains(pt) { expanded = false }
            return ev
        }
    }

    private func stopWatchingOutsideClick() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    /// 就地展开的卡片。原来用 .popover，那是系统气泡、带箭头，
    /// 跟面板里其它东西不是一套
    private var taskCard: some View {
        taskList
            .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.systemSeparator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("后台任务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                if tasks.currentItems.contains(where: { !$0.isRunning }) {
                    Button("清除已完成") { tasks.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks.currentItems) { item in
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
            case .needsConfirm:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#FFB020"))
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.system(size: 9))
                    .foregroundColor(Color.labelSecondary)
                    .lineLimit(2)
                // 换一家要花一次钱，所以摆两个按钮让用户自己点，不替他决定
                if case .needsConfirm(_, let nextName) = item.state {
                    HStack(spacing: 5) {
                        confirmButton("改用 \(nextName)", primary: true) {
                            tasks.confirmRetry(id: item.id)
                        }
                        confirmButton("取消", primary: false) {
                            tasks.declineRetry(id: item.id)
                        }
                    }
                    .padding(.top, 3)
                }
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

    /// 卡片里那两个小按钮。走 Capsule，跟设置面板上的小按钮一套样式
    private func confirmButton(_ title: String, primary: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: primary ? .semibold : .regular))
                .foregroundColor(primary ? Color.black : Color.labelSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(primary ? Color.accent : Color.white.opacity(0.10))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ item: AgentBackgroundTasks.Item) -> String {
        switch item.state {
        case .running:
            return "\(item.kind.rawValue) · 已经 \(Int(Date().timeIntervalSince(item.startedAt))) 秒"
        case .done:
            return "\(item.kind.rawValue) · 已完成，素材已进库"
        case .failed(let m):
            return String(m.prefix(40))
        case .needsConfirm(let reason, _):
            return String(reason.prefix(60))
        }
    }
}

private extension View {
    /// 把自己在窗口里的位置报出来
    func trackFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { report(g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { _, r in report(r) }
        })
    }
}
