// CanvasChatCard.swift
//
// 画布右侧那张 Agent 会话卡片。
//
// 里头就是侧栏那份 AIChatPanel —— service 和 AgentRunner 都是单例，
// 会话、历史、跑着的后台任务两边完全共享，不存在「画布里另有一个 agent」。

import SwiftUI
import AppKit

struct CanvasChatCard: View {
    /// 画布可用区域。卡片尺寸的上限跟着它走，免得拖出画布外
    let containerSize: CGSize

    @EnvironmentObject private var project: ProjectState
    @ObservedObject private var service = AIVideoService.shared

    // 调过的尺寸和位置都记着，下次打开画布还是老样子
    @AppStorage("canvas.chatCard.width")  private var storedWidth: Double = 340
    @AppStorage("canvas.chatCard.height") private var storedHeight: Double = 560
    /// 吸在右边还是左边。松手时按卡片中心落在画布哪一半来定
    @AppStorage("canvas.chatCard.edgeRight") private var edgeRight = true
    /// 顶边距画布顶部多远。**负数表示贴着底边** —— 卡片高度会变，
    /// 存成「距顶」的话拉高之后就顶出画布了，贴底这个语义得单独留一个值
    @AppStorage("canvas.chatCard.top") private var storedTop: Double = -1

    /// 拖动起点的基准值。每帧拿 translation 累加会漂，必须记起点
    @State private var dragStartW: CGFloat?
    @State private var dragStartH: CGFloat?
    /// 拉尺寸前卡片左上角在哪。位置是按吸附算的，尺寸一变它跟着变，
    /// 要拿这个基准把差额补回去
    @State private var resizeBase: CGPoint?
    /// 挪位置时的临时位移，松手才算进 storedTop / edgeRight
    @State private var moveOffset: CGSize = .zero
    @State private var moving = false
    /// 收成一个圆球。画布地方本来就紧，摆节点的时候常常要把它挪开。
    /// 记着 —— 上次收起来的，下次进画布不该自己又弹开
    @AppStorage("canvas.chatCard.minimized") private var minimized = false
    /// 进画布前外边停在哪条会话。画布用的是它自己那条，
    /// 关掉画布得把外边那条还回去 —— 两边的聊天记录各存各的
    @State private var outsideConversationID: UUID?

    private static let minW: CGFloat = 260
    private static let minH: CGFloat = 240
    /// 手柄宽度。整条留在卡片**内侧** —— 越过父视图边界的部分收不到鼠标
    private static let grip: CGFloat = 8
    private static let radius: CGFloat = 14

    private var maxW: CGFloat { max(Self.minW, containerSize.width - 120) }
    private var maxH: CGFloat { max(Self.minH, containerSize.height - 90) }
    private var w: CGFloat { min(maxW, max(Self.minW, CGFloat(storedWidth))) }
    private var h: CGFloat { min(maxH, max(Self.minH, CGFloat(storedHeight))) }

    /// 吸附后留的边距。就是原来那个 12
    private static let margin: CGFloat = 12
    private static let bubbleSize: CGFloat = 44

    /// 停下来时该待的地方（不含拖动中的临时位移）
    private func restPosition(_ size: CGSize) -> CGPoint {
        let x = edgeRight ? containerSize.width - size.width - Self.margin : Self.margin
        let maxY = max(Self.margin, containerSize.height - size.height - Self.margin)
        let y = storedTop < 0 ? maxY : min(max(Self.margin, CGFloat(storedTop)), maxY)
        return CGPoint(x: x, y: y)
    }

    private func position(_ size: CGSize) -> CGPoint {
        let p = restPosition(size)
        guard moving else { return p }
        return CGPoint(x: p.x + moveOffset.width, y: p.y + moveOffset.height)
    }

    /// 松手：横着吸到近的那条边，竖着就停在放下的地方（钳进画布里）
    private func settle(_ size: CGSize) {
        let p = restPosition(size)
        let cx = p.x + moveOffset.width + size.width / 2
        edgeRight = cx > containerSize.width / 2
        let maxY = max(Self.margin, containerSize.height - size.height - Self.margin)
        storedTop = Double(min(max(Self.margin, p.y + moveOffset.height), maxY))
        moveOffset = .zero
        moving = false
    }

    /// 挪位置的手势。卡片是拖标题那条，圆球是整个球
    private func moveGesture(_ size: CGSize) -> some Gesture {
        // .global：卡片自己会跟着位置变，局部坐标系的参考点跟着漂
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                moving = true
                moveOffset = CGSize(width: v.location.x - v.startLocation.x,
                                    height: v.location.y - v.startLocation.y)
            }
            .onEnded { _ in settle(size) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 收起时**不能把卡片摘掉** —— 里头的 @State 会一起没，
            // 没发出去的草稿就丢了。留在层级里，只是看不见也不接鼠标
            card
                .offset(x: position(CGSize(width: w, height: h)).x,
                        y: position(CGSize(width: w, height: h)).y)
                // 量的必须是**卡片本体**。挂到最外层去测的话，
                // 报上来的是整块画布 —— 滚轮判断就永远命中，
                // 连 ⌘+滚轮缩放都被当成「在卡片上」放行掉了。
                // 挂在 offset 之后，测到的才是挪动后的真实位置
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { reportRect(g.frame(in: .global)) }
                        .onChange(of: g.frame(in: .global)) { _, r in reportRect(r) }
                        .onChange(of: minimized) { _, _ in reportRect(g.frame(in: .global)) }
                })
                .opacity(minimized ? 0 : 1)
                .allowsHitTesting(!minimized)
            if minimized {
                let s = CGSize(width: Self.bubbleSize, height: Self.bubbleSize)
                bubble
                    .offset(x: position(s).x, y: position(s).y)
                    .gesture(moveGesture(s))
            }
        }
        // 占满画布，位置全靠上面的 offset 算
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onDisappear { project.canvas.chatCardRect = .zero }
        .onAppear { enterCanvasConversation() }
        .onDisappear { leaveCanvasConversation() }
    }

    /// 收起时报 .zero：卡片还在层级里（留着不丢草稿），
    /// 但那片地方已经看不见，不该再把滚轮从画布那儿截走
    private func reportRect(_ r: CGRect) {
        project.canvas.chatCardRect = minimized ? .zero : r
    }

    /// 画布聊天记录存在这张画布自己的会话里，跟侧栏那条分开
    private func enterCanvasConversation() {
        outsideConversationID = service.currentConversationId
        if let id = project.canvas.conversationID {
            if service.currentConversationId != id { service.loadConversation(id) }
        } else {
            // 老画布可能还没有配套会话，补一条（它内部会设成当前会话）
            project.canvas.conversationID = service.newCanvasConversation()
        }
    }

    private func leaveCanvasConversation() {
        guard let back = outsideConversationID,
              back != service.currentConversationId else { return }
        service.loadConversation(back)
    }

    /// 收起后的圆球。点一下展开，按住能拖着走。
    ///
    /// **不能用 Button** —— Button 会把拖拽手势整个吃掉，球就拖不动了。
    /// 摊开成普通视图，tap 和 drag 各挂各的：drag 有 2pt 的起步距离，
    /// 没超过就算点击
    private var bubble: some View {
        Image(nsImage: SidebarSVGIcon.load("ai", size: 20))
            .renderingMode(.template)
            .foregroundColor(Color.labelPrimary)
            .frame(width: Self.bubbleSize, height: Self.bubbleSize)
            .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.systemSeparator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
            .contentShape(Circle())
            .onHover { inside in
                if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { minimized = false }
            }
            .help("展开 AI 会话")
    }

    private var card: some View {
        AIChatPanel(inCanvas: true)
            .frame(width: w, height: h)
            .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .overlay(RoundedRectangle(cornerRadius: Self.radius)
                .stroke(Color.systemSeparator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.38), radius: 18, y: 6)
            // 四条边 + 四个角都能拉。手柄全贴在卡片**里侧** ——
            // 越过父视图边界的部分收不到鼠标
            .overlay(alignment: .leading)  { grip(.left) }
            .overlay(alignment: .trailing) { grip(.right) }
            .overlay(alignment: .top)      { grip(.top) }
            .overlay(alignment: .bottom)   { grip(.bottom) }
            .overlay(alignment: .topLeading)     { grip(.topLeft) }
            .overlay(alignment: .topTrailing)    { grip(.topRight) }
            .overlay(alignment: .bottomLeading)  { grip(.bottomLeft) }
            .overlay(alignment: .bottomTrailing) { grip(.bottomRight) }
            // 最小化按钮压在标题行右侧。画布里那份不画历史图标，这块正好空着；
            // 它在上边那条拖拽手柄（8pt）下面，两者不打架
            .overlay(alignment: .topTrailing) { minimizeButton }
            // 标题那一行当把手。让开上面 8pt 的 resize 手柄，
            // 右边留 34 给最小化按钮，中间这段拖着走
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(height: 26)
                    // contentShape 必须在 padding **之前** —— 加在后面的话
                    // 命中区连那 34pt 和顶上 8pt 一起算进来，正好盖住
                    // 最小化按钮和 resize 手柄，两个都点不动
                    .contentShape(Rectangle())
                    .padding(.top, Self.grip)
                    .padding(.trailing, 34)
                    .claimsDragFromWindow()
                    .onHover { inside in
                        if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(moveGesture(CGSize(width: w, height: h)))
            }
    }

    private var minimizeButton: some View {
        Button {
            withAnimation(.easeIn(duration: 0.16)) { minimized = true }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 从旁边的标题把手挪过来时光标还是手型，明确设回箭头 —— 这儿是点的不是拖的
        .onHover { inside in
            if inside { NSCursor.arrow.set() }
        }
        .padding(.top, 10)
        .padding(.trailing, 8)
        .help("收起")
    }

    /// 拉哪条边 / 哪个角
    private enum Grip {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var pullsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var pullsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var pullsTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var pullsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
        var isCorner: Bool { (pullsLeft || pullsRight) && (pullsTop || pullsBottom) }

        var cursor: NSCursor {
            if isCorner { return .resizeLeftRight }   // 斜向没有公开光标，用左右的凑合
            return (pullsLeft || pullsRight) ? .resizeLeftRight : .resizeUpDown
        }
    }

    @ViewBuilder
    private func grip(_ g: Grip) -> some View {
        let long: CGFloat? = nil
        Color.clear
            .frame(width: g.isCorner ? Self.grip * 2 : ((g.pullsLeft || g.pullsRight) ? Self.grip : long),
                   height: g.isCorner ? Self.grip * 2 : ((g.pullsTop || g.pullsBottom) ? Self.grip : long))
            .contentShape(Rectangle())
            // 卡片可能贴在窗口顶部那 32pt 里，不认领的话拖的是整个软件窗口
            .claimsDragFromWindow()
            .onHover { inside in
                if inside { g.cursor.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                // 必须 .global：手柄自己会随卡片移动，局部坐标系的参考点跟着漂
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in resize(g, v) }
                    .onEnded { _ in endResize() }
            )
    }

    /// 拉动时：被拖的那条边跟手，对面那条**不动**。
    ///
    /// 位置是按吸附算出来的（`restPosition`），尺寸一变它就跟着变，
    /// 所以这里得把「本来该在哪」记下来，再用 moveOffset 把差额补回去，
    /// 否则拉右边会看见左边在动
    private func resize(_ g: Grip, _ v: DragGesture.Value) {
        if resizeBase == nil {
            resizeBase = restPosition(CGSize(width: w, height: h))
            dragStartW = w
            dragStartH = h
        }
        guard let base = resizeBase, let baseW = dragStartW, let baseH = dragStartH else { return }

        let dx = v.location.x - v.startLocation.x
        let dy = v.location.y - v.startLocation.y

        var newW = baseW
        if g.pullsLeft  { newW = min(maxW, max(Self.minW, baseW - dx)) }
        if g.pullsRight { newW = min(maxW, max(Self.minW, baseW + dx)) }

        var newH = baseH
        if g.pullsTop    { newH = min(maxH, max(Self.minH, baseH - dy)) }
        if g.pullsBottom { newH = min(maxH, max(Self.minH, baseH + dy)) }

        // 钳到上下限之后再反推位置，不然到了极限边还会继续跑
        let targetX = base.x + (g.pullsLeft ? baseW - newW : 0)
        let targetY = base.y + (g.pullsTop ? baseH - newH : 0)

        storedWidth = Double(newW)
        storedHeight = Double(newH)

        let rest = restPosition(CGSize(width: newW, height: newH))
        moving = true
        moveOffset = CGSize(width: targetX - rest.x, height: targetY - rest.y)
    }

    private func endResize() {
        settle(CGSize(width: w, height: h))
        resizeBase = nil
        dragStartW = nil
        dragStartH = nil
    }
}
