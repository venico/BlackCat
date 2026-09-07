// PlusMenuOverlay.swift
//
// 输入区 ＋ 那颗按钮弹出的菜单。
//
// **挂在窗口最外层**（ContentView），不挂在按钮自己的 overlay 里 ——
// 根菜单 190 + Skill 二级菜单 260 = 450，比侧栏还宽，
// 挂在侧栏里溢出去的那半既收不到鼠标、又会被时间轴压在下面。

import SwiftUI

/// 菜单里点了什么。菜单在最外层渲染，动作靠这个回传给聊天面板
enum PlusPick: Equatable {
    case upload
    case library
    case mcp
    case command(String)
}

struct PlusMenuOverlay: View {
    /// ＋ 按钮在窗口里的位置，菜单贴着它右边摆
    let anchor: CGRect
    let onPick: (PlusPick) -> Void
    let onClose: () -> Void

    @State private var skillTab: SkillTab = .builtin
    /// 行和面板**各存一份 hover**：鼠标从行挪到面板上时行的 hover 会掉，
    /// 只认行的话二级菜单会当场消失
    @State private var skillRowHover = false
    @State private var skillPanelHover = false
    /// 移开就关有点急 —— 从行挪到面板要经过一小段空隙，
    /// 那一瞬间两边的 hover 都是 false。给 0.25s 宽限
    @State private var closeWork: DispatchWorkItem?
    private var submenuOpen: Bool { skillRowHover || skillPanelHover }

    private func submenuHover(_ inside: Bool, isRow: Bool) {
        closeWork?.cancel()
        if inside {
            if isRow { skillRowHover = true } else { skillPanelHover = true }
            return
        }
        let w = DispatchWorkItem {
            if isRow { skillRowHover = false } else { skillPanelHover = false }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    enum SkillTab: String, CaseIterable { case builtin = "内置", custom = "自定义" }

    private static let rootW: CGFloat = 190
    private static let subW: CGFloat = 260
    private static let rootH: CGFloat = 4 * 30 + 10
    /// 标签页那行 36 + 分隔线 1
    private static let subHeaderH: CGFloat = 37
    /// 列表最高多少，超了才滚
    private static let listMaxH: CGFloat = 300

    /// 列表多高：**两个标签页里高的那个说了算**，封顶 300。
    /// 各算各的话来回切标签面板会一跳一跳的
    private var listH: CGFloat {
        let all = SlashCommands.all()
        let builtin = all.count { $0.kind == .builtin }
        let custom = all.count { $0.kind == .skill }
        // 空态那段提示按 120 算；内置行 30，自定义带描述是 42
        let bh: CGFloat = builtin == 0 ? 120 : CGFloat(builtin) * 30 + 10
        let ch: CGFloat = custom == 0 ? 120 : CGFloat(custom) * 42 + 10
        return min(max(bh, ch), Self.listMaxH)
    }

    private var subH: CGFloat { Self.subHeaderH + listH }
    private static let gap: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 点空白收起
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }

                // 两块**各自定位**：整块一起算的话，二级菜单一开
                // 总高度从 130 跳到 290，根菜单会跟着往上蹿
                root
                    .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.systemSeparator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .offset(x: rootX(in: geo.size), y: rootY(in: geo.size))

                if submenuOpen {
                    submenu
                        .offset(x: subX(in: geo.size), y: subY(in: geo.size))
                }
            }
        }
        .ignoresSafeArea()
    }

    /// 根菜单摆在 ＋ 右边，右边放不下就翻到左边
    private func rootX(in size: CGSize) -> CGFloat {
        let right = anchor.maxX + Self.gap
        return right + Self.rootW + 12 <= size.width
            ? right
            : max(12, anchor.minX - Self.rootW - Self.gap)
    }

    /// 底边跟 ＋ 齐，往上长；顶到窗口边就压回来。**不看二级菜单开没开**
    private func rootY(in size: CGSize) -> CGFloat {
        min(max(12, anchor.maxY - Self.rootH), max(12, size.height - Self.rootH - 12))
    }

    /// 二级菜单默认在根菜单右边，放不下翻到左边
    private func subX(in size: CGSize) -> CGFloat {
        let rx = rootX(in: size)
        let right = rx + Self.rootW + 4
        return right + Self.subW + 12 <= size.width ? right : max(12, rx - Self.subW - 4)
    }

    /// 底边跟根菜单齐
    private func subY(in size: CGSize) -> CGFloat {
        let bottom = rootY(in: size) + Self.rootH
        return min(max(12, bottom - subH), max(12, size.height - subH - 12))
    }

    private var root: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlusMenuRow(svg: "importFile", title: "上传附件") { onPick(.upload) }
            PlusMenuRow(svg: "folder", title: "从素材库选择") { onPick(.library) }
            // 二级菜单靠 hover 出，点这行本身不做事
            PlusMenuRow(svg: "agent", title: "Skill", hasSubmenu: true) {}
                .onHover { submenuHover($0, isRow: true) }
            PlusMenuRow(svg: "relink", title: "MCP") { onPick(.mcp) }
        }
        .padding(.vertical, 5)
        .frame(width: Self.rootW)
    }

    /// 内置 = `/` 里那些生成模型；自定义 = Skills 目录里自己放的那些
    private var rows: [SlashCommand] {
        SlashCommands.all().filter {
            skillTab == .builtin ? $0.kind == .builtin : $0.kind == .skill
        }
    }

    private var submenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SkillTab.allCases, id: \.self) { t in
                    Button { skillTab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 11, weight: skillTab == t ? .semibold : .regular))
                            .foregroundColor(skillTab == t ? Color.labelPrimary : Color.labelSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(skillTab == t ? 0.12 : 0)))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider().opacity(0.12)

            ScrollView(showsIndicators: false) {
                if rows.isEmpty {
                    Text(skillTab == .custom
                         ? "还没装 Skill。放一个文件夹到\n设置 → 智能体 → Skills 里指的那个目录就行"
                         : "没有可用的生成模型")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { cmd in
                            SkillRow(command: cmd, svg: Self.icon(cmd)) {
                                onPick(.command(cmd.name))
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .frame(height: listH)
        }
        .frame(width: Self.subW)
        .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.systemSeparator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .onHover { submenuHover($0, isRow: false) }
    }

    /// 行首图标：内置的按生成类别走，自定义 Skill 统一一个。
    /// **名字必须在 SidebarSVGIcon.svgs 里有**，写错了画出来是空的
    static func icon(_ cmd: SlashCommand) -> String {
        guard cmd.kind == .builtin else { return "agent" }
        switch cmd.detail {
        case "视频生成": return "video"
        case "图片生成": return "image"
        case "声音生成": return "audio"
        default:      return "ai"
        }
    }
}

struct PlusMenuRow: View {
    let svg: String
    let title: String
    var hasSubmenu = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: SidebarSVGIcon.load(svg, size: 13))
                    .renderingMode(.template)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                Spacer(minLength: 0)
                if hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering ? 0.10 : 0))
                .padding(.horizontal, 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Skill / 生成模型的一行。列表比宫格好扫 —— 名字长短不一，宫格里换行很乱
struct SkillRow: View {
    let command: SlashCommand
    let svg: String
    let action: () -> Void
    @State private var hovering = false

    /// 生成模型只有一个类别名，摆右边；Skill 的描述是中英两行，摆名字下面
    private var isSkill: Bool { command.kind == .skill }

    var body: some View {
        let lines = command.descLines
        Button(action: action) {
            HStack(alignment: isSkill ? .top : .center, spacing: 8) {
                Image(nsImage: SidebarSVGIcon.load(svg, size: 13))
                    .renderingMode(.template)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 16, height: 16)
                    .padding(.top, isSkill ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name)
                        .font(.system(size: 12))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    // 只露一行（中文那句），英文和后面的全文都在 hover 气泡里
                    if isSkill, !lines.zh.isEmpty {
                        Text(lines.zh)
                            .font(.system(size: 9))
                            .foregroundColor(Color.labelSecondary.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if !isSkill, !command.detail.isEmpty {
                    Text(command.detail)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: isSkill && !lines.zh.isEmpty ? 42 : 30)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering ? 0.10 : 0))
                .padding(.horizontal, 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 一行装不下就靠气泡看全的。自绘按钮上 .help 时灵时不灵，走 ChatTooltip
        .overlay { if !command.detail.isEmpty { ChatTooltip(text: command.detail) } }
    }
}
