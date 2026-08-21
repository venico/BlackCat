import SwiftUI

/// 画布上的右键菜单（v5.1.0）
///
/// 卡片、组、框选出来的一批共用这一套 —— 菜单项按 `targets` 的规模变：
/// 多张才有「成组」，已经成组的换成「解散组」。
/// 图标复用时间轴片段右键那套，同一件事在两处长一个样
struct CanvasContextMenuItems: View {
    @ObservedObject var canvas: CanvasState
    /// 这次操作作用在谁身上。右键一张没选中的卡片就只作用于它，不动选中集
    let targets: Set<UUID>
    /// 从组的浅色底右键出来的就带上组 id —— 菜单里那一项是「解散组」而不是「成组」
    var groupID: UUID?

    var body: some View {
        Group {
            if let gid = groupID {
                Button { canvas.ungroup(gid) } label: {
                    Image(nsImage: SidebarSVGIcon.load("dissolveCompound", size: 14))
                    Text("解散组")
                }
                Divider()
            } else if targets.count > 1 {
                Button {
                    canvas.selectedNodeIDs = targets
                    canvas.groupSelected()
                } label: {
                    Image(nsImage: SidebarSVGIcon.load("compound", size: 14))
                    Text("成组")
                }
                Divider()
            }

            Button { canvas.copy(ids: targets) } label: {
                Image(nsImage: SidebarSVGIcon.load("copy", size: 14))
                Text("复制")
            }
            Button { canvas.paste() } label: {
                Image(nsImage: SidebarSVGIcon.load("paste", size: 14))
                Text("粘贴")
            }
            .disabled(canvas.clipboard.isEmpty)
            Button { canvas.duplicate(ids: targets) } label: {
                Image(nsImage: SidebarSVGIcon.load("copy", size: 14))
                Text("创建副本")
            }

            Divider()
            Button(role: .destructive) { canvas.delete(ids: targets) } label: {
                Image(nsImage: TimelineSVGIcon.load("delete", size: 14))
                Text("删除")
            }
        }
    }
}
