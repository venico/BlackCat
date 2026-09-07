import SwiftUI
import AppKit

/// 画布的右键菜单（v5.1.0，自绘）
///
/// **不用系统 `.contextMenu`**：系统菜单只能一行一项竖着排，
/// 组的颜色要横着摆成一排色点、还要 hover 反馈和气泡提示，只能自己画。
/// 右键的捕获在 `CanvasKeyMonitor` 里（NSEvent 本地监听），这里只管长什么样
struct CanvasContextPanel: View {
    @ObservedObject var canvas: CanvasState
    /// 这次操作作用在谁身上。右键一张没选中的卡片就只作用于它，不动选中集
    let targets: Set<UUID>
    /// 右键的是组的底就带上组 id
    var groupID: UUID?
    /// 右键点在哪（内容坐标）。粘贴出来的卡片落在这儿
    var pastePoint: CGPoint?
    /// 右键的那张卡片素材丢了，就多一项「重新关联文件…」。
    /// nil = 没丢或者选了多张，不显示
    var relinkTarget: UUID?
    var onRelink: ((UUID) -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rid = relinkTarget, let onRelink {
                row(SidebarSVGIcon.load("relink", size: 13), "重新关联文件…") { onRelink(rid) }
                Divider().opacity(0.12).padding(.vertical, 4)
            }
            if let gid = groupID {
                row(SidebarSVGIcon.load("dissolveCompound", size: 13), "解散组") {
                    canvas.ungroup(gid)
                }
            } else if targets.count > 1 {
                row(SidebarSVGIcon.load("compound", size: 13), "成组") {
                    canvas.selectedNodeIDs = targets
                    canvas.groupSelected()
                }
            }

            // 空白处右键时 targets 是空的：复制 / 创建副本 / 删除都无从谈起，
            // 只留粘贴
            if !targets.isEmpty {
                row(SidebarSVGIcon.load("copy", size: 13), "复制") { canvas.copy(ids: targets) }
            }
            // 画布里没复制过卡片时看系统剪贴板 —— 截图、访达里复制的文件、
            // 一段文字，都能直接落成卡片
            row(SidebarSVGIcon.load("paste", size: 13), "粘贴",
                enabled: canvas.canPaste) { canvas.pasteHere(at: pastePoint) }
            if !targets.isEmpty {
                row(SidebarSVGIcon.load("copy", size: 13), "创建副本") { canvas.duplicate(ids: targets) }
                Divider().opacity(0.12).padding(.vertical, 4)
                row(TimelineSVGIcon.load("delete", size: 13), "删除") { canvas.delete(ids: targets) }
            }

            // 色板摆在最后一行
            if let gid = groupID {
                Divider().opacity(0.12).padding(.vertical, 4)
                colorRow(gid)
            }
        }
        .padding(.vertical, 6)
        // 有色板时面板要够宽装下那一排点（8 × 18 + 7 × 8 间距 + 左右 12 的留白 = 224）。
        // 写死 168 的话色板会溢出到背景板外面 —— frame 小于内容时 SwiftUI 不裁，
        // 只是背景按 frame 画，看着就是「背景错位」
        .frame(width: groupID == nil ? 168 : 228)
    }

    /// 一排色点。横着摆 —— 这是自绘菜单的意义所在
    private func colorRow(_ gid: UUID) -> some View {
        HStack(spacing: 8) {
            ColorDot(hex: nil, isCurrent: canvas.group(gid)?.colorHex == nil, name: "默认") {
                canvas.setGroupColor(gid, nil)
                onClose()
            }
            ForEach(CanvasState.groupColors, id: \.hex) { c in
                ColorDot(hex: c.hex,
                         isCurrent: canvas.group(gid)?.colorHex == c.hex,
                         name: c.name) {
                    canvas.setGroupColor(gid, c.hex)
                    onClose()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func row(_ icon: NSImage, _ title: String,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        CanvasMenuRow(icon: icon, title: title, enabled: enabled) {
            action()
            onClose()
        }
    }
}

/// 一个色点。hover 放大并描一圈白边，气泡提示是颜色名
private struct ColorDot: View {
    let hex: String?
    let isCurrent: Bool
    let name: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(hex.map { Color(hex: $0) } ?? Color.white.opacity(0.30))
                .frame(width: 15, height: 15)
                // 当前用着的那个常驻一圈白边，hover 的那个更亮
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(hovering ? 0.95 : (isCurrent ? 0.65 : 0)),
                                          lineWidth: 1.5))
                .scaleEffect(hovering ? 1.18 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }
}

/// 菜单行。图标直接收 NSImage —— 侧栏那套和时间轴那套图标不在一个枚举里
private struct CanvasMenuRow: View {
    let icon: NSImage
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundColor(Color.labelPrimary.opacity(enabled ? 1 : 0.35))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering && enabled ? 0.10 : 0))
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
