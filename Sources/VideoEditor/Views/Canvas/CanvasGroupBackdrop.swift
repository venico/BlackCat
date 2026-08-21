import SwiftUI
import AppKit

/// 组的浅色底（v5.1.0）
///
/// 点它选中整组（边框变黄），拖它整组一起走；四周 10pt 是调整大小的热区 ——
/// 跟文本卡片一个手感：不画把手，光标变成双向箭头就能拖。
///
/// 组里的卡片仍然可以单独点、单独拖，拖出这块底就自动脱组
struct CanvasGroupBackdrop: View {
    @ObservedObject var canvas: CanvasState
    let gid: UUID
    let name: String
    /// 内容坐标里的框（成员包围盒 ∪ 用户拉过的框）
    let rect: CGRect

    /// 拖动/调整中的临时值。**本地状态** —— 每帧写 @Published 会让整层重建，闪
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var liveRect: CGRect?
    @State private var resizeBase: CGRect?

    private static let hit: CGFloat = 10
    private var shown: CGRect { liveRect ?? rect }
    private var isSelected: Bool { canvas.selectedGroupID == gid }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(isSelected ? Color.accent : Color.white.opacity(0.10),
                                      lineWidth: isSelected ? 1.5 : 1))

            resizeEdges
        }
        .frame(width: shown.width, height: shown.height)
        // 组名画在框**外**的上方，跟卡片的标签一个位置一个样式。
        // 只是块标牌，不参与点击 —— 挡住的话框上边那条拉伸热区就点不着了
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Image(nsImage: SidebarSVGIcon.load("compound", size: 11))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                Text(name)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundColor(Color.labelSecondary.opacity(0.7))
            .fixedSize()
            .offset(y: -CanvasState.groupTitleHeight)
            .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .position(x: shown.midX, y: shown.midY)
        .offset(dragOffset)
        .onTapGesture { canvas.selectGroup(gid) }
        .gesture(moveGesture)
        .contextMenu {
            CanvasContextMenuItems(canvas: canvas,
                                   targets: canvas.nodeIDs(inGroup: gid),
                                   groupID: gid)
        }
    }

    // MARK: 整组移动

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard !canvas.isSpaceHeld else { return }   // 空格是拖画布
                if !isDragging {
                    isDragging = true
                    canvas.selectGroup(gid)
                    // 组员跟着走：卡片自己会读 draggingOffset
                    canvas.draggingNodeIDs = canvas.nodeIDs(inGroup: gid)
                }
                // offset 在 scaleEffect 里面，位移会被放大 zoom 倍，得先除回去
                let d = CGSize(width: (value.location.x - value.startLocation.x) / canvas.zoom,
                               height: (value.location.y - value.startLocation.y) / canvas.zoom)
                dragOffset = d
                canvas.draggingOffset = d
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                canvas.moveGroup(gid, by: dragOffset)
                dragOffset = .zero
                canvas.draggingNodeIDs = []
                canvas.draggingOffset = .zero
            }
    }

    // MARK: 四周拉伸

    private var resizeEdges: some View {
        let hit = Self.hit
        return ZStack {
            edgeHandle(.top).frame(width: max(1, shown.width - hit * 2), height: hit)
                .frame(maxHeight: .infinity, alignment: .top)
            edgeHandle(.bottom).frame(width: max(1, shown.width - hit * 2), height: hit)
                .frame(maxHeight: .infinity, alignment: .bottom)
            edgeHandle(.leading).frame(width: hit, height: max(1, shown.height - hit * 2))
                .frame(maxWidth: .infinity, alignment: .leading)
            edgeHandle(.trailing).frame(width: hit, height: max(1, shown.height - hit * 2))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: shown.width, height: shown.height)
    }

    private func edgeHandle(_ edge: Edge) -> some View {
        let vertical = (edge == .top || edge == .bottom)
        return Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .onHover { inside in
                // 认领光标：画布层每次鼠标移动都会 set 一次箭头，
                // 不认领的话这里刚设成双向箭头就被它改回去，看着就是狂闪
                canvas.claimCursor(inside)
                if inside {
                    (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // 手柄自己会跟着框一起动，局部坐标系的参考点跟着漂 —— 必须用 .global
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if resizeBase == nil { resizeBase = rect }
                        guard let base = resizeBase else { return }
                        let dx = (value.location.x - value.startLocation.x) / canvas.zoom
                        let dy = (value.location.y - value.startLocation.y) / canvas.zoom
                        let minSide: CGFloat = 80
                        var r = base
                        switch edge {
                        case .top:
                            let h = max(minSide, base.height - dy)
                            r.origin.y = base.maxY - h
                            r.size.height = h
                        case .bottom:
                            r.size.height = max(minSide, base.height + dy)
                        case .leading:
                            let w = max(minSide, base.width - dx)
                            r.origin.x = base.maxX - w
                            r.size.width = w
                        case .trailing:
                            r.size.width = max(minSide, base.width + dx)
                        }
                        liveRect = r
                    }
                    .onEnded { _ in
                        if let r = liveRect { canvas.setGroupRect(gid, r) }
                        liveRect = nil
                        resizeBase = nil
                    }
            )
    }
}
