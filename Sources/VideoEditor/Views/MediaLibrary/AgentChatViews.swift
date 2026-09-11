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
    /// 跑着的时候那个呼吸圆点
    @State private var pulsing = false

    /// 「12s」/「1m24s」
    private var timeText: String {
        let sec = Int(elapsed.rounded())
        return sec < 60 ? "\(sec)s" : "\(sec / 60)m\(sec % 60)s"
    }

    /// 「832 tokens」/「5.6k tokens」。这里的数是**折算后的计费量** ——
    /// 命中缓存的部分只按一成算，报原始读入量会虚高一倍多
    private var tokenText: String {
        tokens < 1000 ? "\(tokens) tokens"
            : String(format: "%.1fk tokens", Double(tokens) / 1000)
    }

    /// 时间和用量，有哪个显示哪个
    private var meta: String {
        var parts: [String] = []
        if isRunning && !steps.isEmpty { parts.append("\(steps.count) 步") }
        if elapsed >= 1 { parts.append(timeText) }
        if tokens > 0 { parts.append(tokenText) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private var headline: String {
        // 跑着的时候，标题就是**此刻这一步**（跟展开后每行的写法一样：动作 + 对象），
        // 一步步换过去，不展开也看得出它在干嘛。步数挪到后面那截统计里。
        //
        // 等模型回话的那段时间 phase 是「正在思考」，整轮下来大半时间都卡在这四个字上，
        // 用户看不出它干到哪了 —— 这时候改显示**刚做完的那件事**
        if isRunning {
            if !phase.isEmpty && phase != "正在思考" { return phase }
            if let last = steps.last { return AgentPhaseText.label(for: last.tool) }
            return "正在思考"
        }
        return "执行了 \(steps.count) 步"
    }

    var body: some View {
        // 刚发出去还没调工具时 steps 是空的，但用户已经在等了，
        // 这时候更需要看到「正在思考 · 3s」
        if !steps.isEmpty || isRunning {
            VStack(alignment: .leading, spacing: 3) {
                // 没步骤可展开时点了不动，但**不能用 `.disabled`** ——
                // 那会把整个 label 压暗，「正在思考 · 1s」就糊得看不清，
                // 跟跑完之后的「执行了 N 步」明显两个颜色
                Button { if !steps.isEmpty { expanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        if isRunning {
                            Circle()
                                .fill(Color.accent)
                                .frame(width: 6, height: 6)
                                .opacity(pulsing ? 1 : 0.25)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                           value: pulsing)
                                // 把这个点的几何变化跟外面隔开。
                                // **不隔的话呼吸动画会把「位置」也一起接管**：
                                // 拖侧栏宽度时整行要重新排版，这个点的新位置被
                                // repeatForever 那条动画慢慢补间，看着就是上下乱跳
                                .geometryGroup()
                                .onAppear { pulsing = true }
                                .onDisappear { pulsing = false }
                        }
                        Text(headline + meta)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .help(tokens > 0 ? "按各家公开的缓存折扣估算的计费量，不是账单" : "")
                        if steps.contains(where: \.isError) {
                            Text("有失败")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#FF9230"))
                        }
                        // 展开箭头摆在末尾。没步骤可展开时整个不占位
                        if !steps.isEmpty {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.leading, 1)
                        }
                    }
                    .foregroundColor(Color.labelSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    // 十几步的时候整块能把输入框顶出屏幕，给个上限、超了自己滚。
                    // 用 maxHeight 不用 height：ScrollView 的理想高度就是内容高度，
                    // maxHeight 只封顶。先前拿 GeometryReader 量内容再钉 height，
                    // 首帧量到 0、高度被钳成 1pt，展开等于没展开
                    ScrollView(showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(steps) { AgentStepRow(step: $0) }
                        }
                    }
                    .frame(maxHeight: 600)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        }
    }
}

/// 步骤列表里的一行。**自己也能再展开** ——
/// 原先一展开就把每一步的思路、参数、完整结果全铺出来，十几步下来是一屏乱码，
/// 想找「它到底把哪条片段改了」得在里面翻半天。
/// 现在收起时一行一件事，要细节再点开那一行
private struct AgentStepRow: View {
    let step: AIVideoService.ConversationRecord.AgentStepRecord
    @State private var open = false
    @State private var hover = false

    private var title: String { AgentPhaseText.label(for: step.tool) }

    /// 收起时右边跟着的那句。优先显示参数——「它对什么动的手」比结果更能认出这一步
    private var subtitle: String {
        let raw = step.args?.isEmpty == false ? step.args! : step.summary
        return raw.replacingOccurrences(of: "\n", with: " ")
    }

    private var hasDetail: Bool {
        (step.detail?.isEmpty == false) || (step.thinking?.isEmpty == false)
            || (step.args?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if hasDetail { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(step.isError ? Color(hex: "#FF6B6B") : Color.labelSecondary.opacity(0.45))
                        .frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { _ in 3 }
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(step.isError ? Color(hex: "#FF9230") : Color.labelSecondary)
                        .fixedSize()
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 2)
                    if hasDetail {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(Color.labelSecondary.opacity(hover ? 0.9 : 0.45))
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(hover && hasDetail ? Color.white.opacity(0.05) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }

            if open {
                VStack(alignment: .leading, spacing: 4) {
                    // 动手前它说的那段话就是思路，摆在最前面
                    if let think = step.thinking, !think.isEmpty {
                        Text(think)
                            .font(.system(size: 9.5))
                            .italic()
                            .lineSpacing(2)
                            .foregroundColor(Color.labelSecondary.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let a = step.args, !a.isEmpty {
                        Text(a)
                            .font(.system(size: 9.5).monospaced())
                            .foregroundColor(Color.labelSecondary.opacity(0.7))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 有完整结果就显示完整的，没有才退回那 120 字的摘要
                    Text(step.detail?.isEmpty == false ? step.detail! : step.summary)
                        .font(.system(size: 10))
                        .lineSpacing(2.5)
                        .foregroundColor(Color.labelSecondary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 11)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                // 左边那条竖线是「这是上一行的下级」的唯一提示，别去掉
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.labelSecondary.opacity(0.18))
                        .frame(width: 1)
                        .padding(.leading, 5)
                }
            }
        }
    }
}

/// 危险操作的确认条。**直接长在会话里**，不弹系统 alert ——
/// Agent 干活时用户的注意力就在这块，弹窗打断反而更烦
struct AgentConfirmBar: View {
    let toolName: String
    let detail: String
    let onAnswer: (Bool) -> Void
    @State private var expanded = false

    /// 详情默认最多三行，长了给个箭头。
    /// **命令原文不走这个** —— 那是要用户逐字看过才点允许的东西，
    /// 默认折叠等于诱导人草率放行
    @ViewBuilder
    private func clampedDetail(_ text: String) -> some View {
        // 10 号字三行大概九十来个字符，超了基本就被截了
        let canExpand = text.count > 90 || text.components(separatedBy: "\n").count > 3
        HStack(alignment: .top, spacing: 4) {
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canExpand {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "收起" : "展开完整内容")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 13))
                    .renderingMode(.template)
                    .foregroundColor(Color(hex: "#FF9230"))
                Text(toolName == "run_command" ? "需要在你的电脑上运行以下命令"
                                               : "这一步改动需要你的确认")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
            }
            if toolName == "run_command" {
                // 命令原文是这里最要紧的东西：等宽 + 单独的底色，
                // 免得跟上面那句说明混成一片，看漏了才点确认
                let parts = detail.components(separatedBy: "\n\n")
                if parts.count > 1, !parts[0].isEmpty {
                    clampedDetail(parts[0])
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
                clampedDetail(detail)
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

/// 悬停提示。
///
/// SwiftUI 的 `.help()` 在自绘 Button 上时灵时不灵，索性自己画一个：
/// 一个透明的 NSView，靠 AppKit 的 toolTip 机制出气泡。
struct ChatTooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let v = PassthroughTipView()
        v.toolTip = text
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        v.toolTip = text
    }
}

/// 这层只为出气泡，不该抢鼠标。
///
/// 它盖在按钮上（`.overlay`），而 AppKit 的命中测试认 NSView 不认 SwiftUI ——
/// 事件停在这儿，下面的 Button 既点不动、`.onHover` 也不触发。
/// 气泡照弹是因为 toolTip 走的是 NSToolTipManager 的 tracking rect，
/// 那条路不经 hitTest，所以看着「像是能用」，最容易误判。
private final class PassthroughTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 缩略图角上的那个删除按钮。**凡是图片角上的 × 都走这个，别各写各的。**
///
/// 原来参考区、附件区、一摞的总删除各写了一份，写法都是
/// `Image(xmark).frame(16).background(Circle())` —— 全都少了 `contentShape`。
/// SwiftUI 默认拿**内容的可见形状**当热区，那个 × 只有几笔笔画，背景圆压根不算数，
/// 于是要正好戳中笔画才有反应；叠着写 background 和 contentShape 还会让热区
/// 跟看到的圆错位（实测「圆的左上能点、右下点不动」）。
/// 摊成 ZStack、尺寸和热区都定在最外层一次，就不会歪
struct ThumbCloseButton: View {
    var size: CGFloat = 16
    var opacity: Double = 0.65
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(opacity))
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
