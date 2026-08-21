import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AI 画布的全屏弹层（v5.1.0，B2：只有容器和导航）
///
/// **为什么不用 `.sheet`**：`floatingPanelMaterial` 走 `.withinWindow` 混合，
/// 采样的是同窗口内下层的内容；系统 sheet 是独立窗口，采样不到主界面，
/// 材质会变成一块不透的灰板。导出、设置、识别方式那几个弹窗都是挂 ContentView 的
/// overlay，这里跟上。
///
/// 顶部留一条（`topGap`）露出底下的软件界面，点那条空白也能关。
struct CanvasOverlay: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    @Environment(\.windowID) private var windowID

    /// 拖动手柄那条的高度
    private static let handleHeight: CGFloat = 10

    @State private var dragStartGap: CGFloat?
    /// 拖动中的临时高度。每帧写 @Published 的 topGap 会让整个画布层重建 ——
    /// 表现就是弹窗闪。松手才写回
    @State private var liveGap: CGFloat?
    /// 画布主体的滑动偏移。关闭时先播完向下收起再摘掉视图
    @State private var slideY: CGFloat = 0
    @State private var closing = false
    /// 遮罩要等画布滑到位了才出现。先出现的话，画布还在半路上，
    /// 屏幕上就成了「顶上一条暗的、中间露着底层界面、画布在下面爬」
    @State private var maskVisible = false
    @State private var saveWork: DispatchWorkItem?

    private var effectiveGap: CGFloat { liveGap ?? canvas.topGap }

    var body: some View {
        GeometryReader { outer in
            ZStack(alignment: .top) {
                // 顶部让出来的那段遮罩：**不跟着滑**。
                // 它盖在底层界面上，跟着画布上下跑会让人以为底层界面在动。
                // 滑动是画布主体自己的 offset，遮罩不加，所以它只会直接出现/消失
                // closing 一置位就立刻撤掉遮罩：视图本体还要再播 0.2s 的收起动画，
                // 等它一起走的话遮罩会赖在那儿不动，看着像卡住
                if effectiveGap > 0 && maskVisible && !closing {
                    Color.black.opacity(0.25)
                        .frame(height: effectiveGap)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                }

                // 画布主体。别用 GeometryReader 的 geo.size 去减 topGap 算高度 ——
                // 那个尺寸不含 ignoresSafeArea 扩出来的部分，底部会漏出一条时间轴
                VStack(spacing: 0) {
                    if effectiveGap > 0 { Color.clear.frame(height: effectiveGap) }
                    GeometryReader { geo in
                        canvasBody(containerSize: geo.size)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
                    .overlay(alignment: .top) { heightHandle(outerHeight: outer.size.height) }
                }
                // 只有画布主体做滑动。用 offset 手动控制而不是 .transition ——
                // transition 作用在整个 overlay 上，遮罩会被一起带着跑
                .offset(y: slideY)
                .onAppear {
                    slideY = outer.size.height
                    withAnimation(.easeOut(duration: 0.24)) { slideY = 0 }
                    // 滑到位再让顶部暗下来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { maskVisible = true }
                }
                .onChange(of: closing) { _, isClosing in
                    guard isClosing else { return }
                    maskVisible = false
                    withAnimation(.easeIn(duration: 0.2)) { slideY = outer.size.height }
                    // 动画播完再真正摘掉；遮罩在上面那层，这时已经跟着 showCanvas 一起没了
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        project.showCanvas = false
                        closing = false
                        slideY = 0
                        maskVisible = false
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand { close() }
        // 改完 1.2 秒没再动就存一次 —— 不等关闭才存，万一崩了内容还在
        .onChange(of: canvas.nodes) { _, _ in scheduleSave() }
        .onChange(of: canvas.edges) { _, _ in scheduleSave() }
    }

    /// 画布顶端中间那三条横线：上下拖它调整画布高度
    private func heightHandle(outerHeight: CGFloat) -> some View {
        VStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 14, height: 1)
            }
        }
        .frame(width: 34, height: Self.handleHeight)
        .contentShape(Rectangle())
        // 这块区域自己处理拖拽 —— 不认领的话，顶部归窗口拖拽，
        // 在这儿拖会变成拖着整个软件窗口跑
        .claimsDragFromWindow()
        .padding(.top, 6)
        // 坐标系必须用 .global：手柄自己会跟着 topGap 上下移动，
        // 局部坐标系的参考点跟着漂，表现就是「不跟手 + 抖动」
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartGap == nil { dragStartGap = canvas.topGap }
                    let base = dragStartGap ?? 0
                    let maxGap = max(0, outerHeight - CanvasState.minCanvasHeight)
                    let delta = value.location.y - value.startLocation.y
                    liveGap = min(maxGap, max(0, base + delta))
                }
                .onEnded { _ in
                    if let g = liveGap { canvas.topGap = g }
                    liveGap = nil
                    dragStartGap = nil
                }
        )
        .onHover { canvas.claimCursor($0) }
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .help("上下拖动调整画布高度")
    }

    // MARK: - 画布主体

    private func canvasBody(containerSize: CGSize) -> some View {
        ZStack {
            CanvasSurface(canvas: canvas, containerSize: containerSize)

            // 左上角关闭，右上角撤销/重做/缩放
            VStack {
                HStack {
                    closeButton
                    Spacer()
                    topRightBar(containerSize: containerSize)
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("关闭画布（esc）")
    }

    /// 撤销、重做、缩放。撤销重做排在缩放前面
    private func topRightBar(containerSize: CGSize) -> some View {
        HStack(spacing: 6) {
            pillGroup {
                barButton(system: "arrow.uturn.backward", help: "撤销（⌘Z）", enabled: canvas.canUndo) {
                    canvas.undo()
                }
                barButton(system: "arrow.uturn.forward", help: "重做（⇧⌘Z）", enabled: canvas.canRedo) {
                    canvas.redo()
                }
            }

            pillGroup {
                barButton(system: "minus", help: "缩小", enabled: canvas.zoom > CanvasState.minZoom) {
                    canvas.zoomOut(containerSize: containerSize)
                }
                Button { canvas.resetView() } label: {
                    Text("\(canvas.zoomPercent)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 46, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点一下回到 100%")

                barButton(system: "plus", help: "放大", enabled: canvas.zoom < CanvasState.maxZoom) {
                    canvas.zoomIn(containerSize: containerSize)
                }
            }
        }
    }

    private func pillGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func barButton(system: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(enabled ? Color.labelSecondary : Color.labelSecondary.opacity(0.3))
                // 热区给大一点，11pt 的图标太难点
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func close() {
        guard !closing else { return }
        // 关画布先停播 —— 卡片上正播着的视频/音频，关掉窗口声音还在响
        // （关窗那次踩过一样的坑）
        AIInlinePlayer.shared.stop()
        saveCanvas()
        closing = true   // 触发 onChange 里的收起动画
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let item = DispatchWorkItem { saveCanvas() }
        saveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// 把画布存回它那条会话记录。标题取第一个有内容的节点，
    /// 全空就留「未命名画布」—— 历史列表里一排「未命名」认不出谁是谁
    private func saveCanvas() {
        guard let id = canvas.conversationID else { return }
        let title = canvas.nodes.compactMap { n -> String? in
            if n.kind == .text {
                let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : String(t.prefix(20))
            }
            let p = n.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { return String(p.prefix(20)) }
            return n.mediaURL?.lastPathComponent
        }.first ?? "未命名画布"
        AIVideoService.shared.saveCanvas(canvas.snapshot(), id: id, title: title)
    }
}

// MARK: - 画布表面（点阵背景 + 平移缩放）

/// 画布本体。平移缩放都作用在这一层，节点（B3）会画在这里面
private struct CanvasSurface: View {
    @ObservedObject var canvas: CanvasState
    @EnvironmentObject var project: ProjectState
    let containerSize: CGSize

    @State private var dragStartOffset: CGSize?
    /// 捏合开始时的缩放，手势结束才清空
    @State private var pinchBaseZoom: CGFloat?
    @State private var showAddMenu = false
    @State private var menuLocation: CGPoint = .zero
    @State private var menuContentPoint: CGPoint = .zero
    /// 从哪个节点的 + 拉出来的线（点 + 弹菜单时，新节点自动连上它）
    @State private var menuSourceNode: UUID?
    /// 从哪边的 + 点出来的。左边 = 新卡片当上游，右边 = 当下游
    @State private var menuSourceEdge: Edge = .trailing
    @State private var showAssetPicker = false
    /// 鼠标在内容坐标里的位置，连线层拿它判断悬没悬在某条线上
    @State private var hoverContentPoint: CGPoint?
    /// 节点上那两个按钮点的是哪个节点（填内容进去，不是新建）
    @State private var fillTargetNode: UUID?
    /// 框选的起止点（内容坐标）。**本地状态** —— 每帧写 @Published 会让整层重建
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?

    /// 左侧悬浮栏。抽成独立属性 —— 整段塞进 body 的话表达式太长，
    /// 编译器会直接报「无法在合理时间内完成类型检查」
    private var sideBar: some View {
        CanvasSideBar(
            canvas: canvas,
            onPickKind: { kind in
                menuSourceNode = nil
                menuContentPoint = viewportCenterContentPoint
                _ = addNode(kind: kind)
            },
            onUpload: {
                menuSourceNode = nil
                menuContentPoint = viewportCenterContentPoint
                uploadIntoNewNode()
            },
            onPickAssetFromLibrary: {
                menuSourceNode = nil
                menuContentPoint = viewportCenterContentPoint
                fillTargetNode = nil
                showAssetPicker = true
            },
            // 抽屉（素材库/资产库）里点一项：直接落成卡片
            onPickAsset: { url, kind in
                menuSourceNode = nil
                menuContentPoint = viewportCenterContentPoint
                let asset = project.mediaAssets.first { $0.url == url }
                _ = addNode(kind: kind, mediaURL: url, assetID: asset?.id)
            })
        .environmentObject(project)
        .padding(.leading, 12)
    }

    /// 侧栏 hover 出来的添加菜单。位置按侧栏宽度算，间距 16
    @ViewBuilder
    private var sideBarMenu: some View {
        if canvas.sideMenuVisible {
            CanvasAddMenu(
                onPick: { kind in
                    canvas.sideAddHovering = false; canvas.sideMenuHovering = false
                    menuSourceNode = nil
                    menuContentPoint = viewportCenterContentPoint
                    _ = addNode(kind: kind)
                },
                onUpload: {
                    canvas.sideAddHovering = false; canvas.sideMenuHovering = false
                    menuSourceNode = nil
                    menuContentPoint = viewportCenterContentPoint
                    uploadIntoNewNode()
                },
                onPickAsset: {
                    canvas.sideAddHovering = false; canvas.sideMenuHovering = false
                    menuSourceNode = nil
                    menuContentPoint = viewportCenterContentPoint
                    fillTargetNode = nil
                    showAssetPicker = true
                })
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .fixedSize()
            // 12 是侧栏自己的左边距
            .offset(x: 12 + CanvasSideBar.barWidth + 16)
            // 鼠标从按钮挪到菜单上时按钮的 hover 会掉，菜单自己也接一份
            .onHover { canvas.sideMenuHovering = $0 }
        }
    }

    /// 当前视口中心对应的内容坐标 —— 从侧栏加的卡片落在这儿
    private var viewportCenterContentPoint: CGPoint {
        contentPoint(from: CGPoint(x: containerSize.width / 2, y: containerSize.height / 2))
    }

    /// 菜单标题按来源变：从卡片右边的 + 出来是「拿它当参考生成什么」，
    /// 左边的 + 是「给它加什么上下文」，双击空白/侧栏就是普通的添加
    private var menuTitle: String {
        guard menuSourceNode != nil else { return "添加节点" }
        return menuSourceEdge == .trailing ? "引用该节点生成" : "添加上下文"
    }

    /// 菜单里列哪几种类型。规则挂在 `CanvasNode.Kind` 上：
    /// 右边看 canGenerate（这个节点能派生出什么），左边看 acceptsContext（它能接什么）
    private var menuKinds: [CanvasNode.Kind]? {
        guard let src = menuSourceNode, let kind = canvas.node(src)?.kind else { return nil }
        return menuSourceEdge == .trailing ? kind.canGenerate : kind.acceptsContext
    }

    /// 卡片左右那个 + 弹出的菜单该摆哪。
    ///
    /// 间距 16pt 是**视图坐标**里的 16 —— 菜单本身不随画布缩放，
    /// 所以不能拿内容坐标去算，缩到 50% 时那 16 会变成看着 8。
    /// 顶对齐 + 按钮
    private func plusMenuLocation(for node: CanvasNode, edge: Edge) -> CGPoint {
        let gap: CGFloat = 16
        let radius: CGFloat = 11 * canvas.zoom
        // + 按钮圆心的内容坐标（跟 CanvasNodeView 里摆它的位置一致）
        let centerContent = CGPoint(
            x: edge == .trailing
               ? node.position.x + node.size.width + CanvasNodeView.plusGutter / 2
               : node.position.x - CanvasNodeView.plusGutter / 2,
            y: node.position.y + node.size.height / 2)
        let center = viewPoint(from: centerContent)

        let x = edge == .trailing
            ? center.x + radius + gap
            : center.x - radius - gap - Self.menuWidth
        return CGPoint(x: x, y: center.y - radius)
    }

    /// 菜单宽度，定位时要用
    static let menuWidth: CGFloat = 160

    /// 菜单左上角该放哪。就摆在算好的位置上 —— **不做边界收拢**：
    /// 往回收会让菜单跟它的 + 按钮错开，反而看不出是从哪儿弹出来的。
    /// 允许超出画布
    private var menuOffset: CGPoint { menuLocation }

    /// 画布内容坐标 → 视图坐标。
    /// 内容层的原点在容器左上角（`.position()` 的坐标系），
    /// 而 `.scaleEffect` 绕容器中心缩放 —— 换算两头都要带上 center
    private func viewPoint(from contentPoint: CGPoint) -> CGPoint {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return CGPoint(x: (contentPoint.x - center.x) * canvas.zoom + center.x + canvas.offset.width,
                       y: (contentPoint.y - center.y) * canvas.zoom + center.y + canvas.offset.height)
    }

    /// 视图坐标 → 画布内容坐标
    private func contentPoint(from viewPoint: CGPoint) -> CGPoint {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return CGPoint(x: (viewPoint.x - canvas.offset.width - center.x) / canvas.zoom + center.x,
                       y: (viewPoint.y - canvas.offset.height - center.y) / canvas.zoom + center.y)
    }

    /// 连线 + 节点
    private var contentLayer: some View {
        ZStack {
            // 组的浅色底。画在最底下 —— 压在连线和卡片上面会挡住它们
            ForEach(canvas.groupFrames, id: \.id) { g in
                CanvasGroupBackdrop(canvas: canvas, gid: g.id, name: g.name, rect: g.rect)
            }

            CanvasEdgeLayer(canvas: canvas, hoverPoint: hoverContentPoint)

            ForEach(canvas.nodes) { node in
                CanvasNodeView(
                    canvas: canvas,
                    node: node,
                    onPlusTap: { edge in
                        menuSourceNode = node.id
                        // 让**这一侧**的 + 在菜单开着时保持显示
                        canvas.plusMenuSource = .init(nodeID: node.id, isTrailing: edge == .trailing)
                        menuSourceEdge = edge
                        // 新卡片落在 + 那一侧，留出一个卡片的间距
                        menuContentPoint = CGPoint(
                            x: edge == .trailing
                               ? node.position.x + node.size.width * 1.5 + 90
                               : node.position.x - node.size.width * 0.5 - 90,
                            y: node.position.y + node.size.height / 2)
                        menuLocation = plusMenuLocation(for: node, edge: edge)
                        showAddMenu = true
                    },
                    onPlusDragChanged: { point in
                        canvas.pendingEdgeTo = point
                        // 悬在谁身上就高亮谁，但**只高亮真连得上的** ——
                        // 高亮了却连不上，用户松手才发现，白高兴一趟
                        let hit = canvas.nodes.first { $0.id != node.id && $0.frame.contains(point) }
                        if let hit {
                            let toKind = canvas.pendingEdgeIsLeading ? node.kind : hit.kind
                            let fromKind = canvas.pendingEdgeIsLeading ? hit.kind : node.kind
                            canvas.hoveredDropTarget = toKind.acceptsContext.contains(fromKind) ? hit.id : nil
                        } else {
                            canvas.hoveredDropTarget = nil
                        }
                    },
                    onPlusDragEnded: { finishPendingEdge() })
                // 节点视图比卡片高出一个标签行（在卡片上方），所以中心要往上挪半行
                .position(x: node.position.x + node.size.width / 2,
                          y: node.position.y + node.size.height / 2 - CanvasNodeView.labelHeight / 2)
            }

            // 框选的那个框。线宽除以 zoom，缩到多小都是一样细的一根
            if let r = marqueeRect {
                Rectangle()
                    .fill(Color.accent.opacity(0.10))
                    .overlay(Rectangle().strokeBorder(Color.accent.opacity(0.85),
                                                      lineWidth: 1 / max(0.1, canvas.zoom)))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 框选矩形（内容坐标）
    private var marqueeRect: CGRect? {
        guard let s = marqueeStart, let e = marqueeEnd else { return nil }
        return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                      width: abs(e.x - s.x), height: abs(e.y - s.y))
    }

    /// 落一个节点。从某个节点的 + 点出来的，自动连上去
    @discardableResult
    private func addNode(kind: CanvasNode.Kind, mediaURL: URL? = nil, assetID: UUID? = nil) -> CanvasNode {
        // 卡片以点击点为中心落下。position 存的是左上角，所以要减掉半个卡片 ——
        // 直接把左上角对着点击点的话，卡片会整个跑到鼠标的右下方
        let ratio = kind == .image ? AppSettings.shared.aiImageRatio : AppSettings.shared.aiRatio
        let size = kind.defaultSize(ratio: ratio)
        let origin = CGPoint(x: menuContentPoint.x - size.width / 2,
                             y: menuContentPoint.y - size.height / 2)
        let node = canvas.addNode(kind: kind, at: origin, ratio: ratio)
        if mediaURL != nil || assetID != nil {
            let assetName = assetID.flatMap { id in
                project.mediaAssets.first { $0.id == id }?.name
            } ?? mediaURL?.lastPathComponent
            canvas.updateNode(id: node.id) {
                $0.mediaPath = mediaURL?.path
                $0.assetID = assetID
                if let assetName { $0.displayName = assetName }
            }
        }
        // 从 + 点出来的卡片，落下就跟源卡片连上。
        // 方向按点的是哪边：左边的 + 意味着「给它加个上游参考」，右边才是下游
        if let src = menuSourceNode {
            let from = menuSourceEdge == .leading ? node.id : src
            let to   = menuSourceEdge == .leading ? src : node.id
            // 类型校验要按**下游**节点的模型来 —— 参考上限是下游那个模型的能力，
            // 用全局 selectedProvider 会拿错矩阵（比如给图片卡片按视频模型放行音频）
            let r = canvas.connect(from: from, to: to, provider: providerFor(nodeID: to))
            if let msg = r.message { flashReject(msg) }
            menuSourceNode = nil
        }
        return node
    }

    /// 上传：选文件 → 进全局素材库 → 落一个对应类型的节点
    private func uploadIntoNewNode() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择素材"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        project.importFile(url)
        let asset = project.mediaAssets.first { $0.url == url }
        guard let kind = CanvasSurfaceKindResolver.nodeKind(for: url) else {
            flashReject("不支持这种文件")
            return
        }
        addNode(kind: kind, mediaURL: url, assetID: asset?.id)
    }

    /// 某个节点该按哪个模型判定 —— 每种类型各记各的（跟输入框里那套一致）
    private func providerFor(nodeID: UUID) -> AIVideoService.Provider {
        guard let kind = canvas.node(nodeID)?.kind else { return AIVideoService.shared.selectedProvider }
        let category: AIVideoService.ProviderCategory
        switch kind {
        case .image: category = .image
        case .video: category = .video
        case .audio: category = .audio
        case .text:  category = .text
        }
        let saved = AppSettings.shared.canvasProvider(for: category.rawValue)
        if let p = AIVideoService.Provider(rawValue: saved), p.category == category, !p.isHidden {
            return p
        }
        return AIVideoService.Provider.allCases.first { !$0.isHidden && $0.category == category }
            ?? AIVideoService.shared.selectedProvider
    }

    /// 各类节点能收哪些文件
    static func contentTypes(for kind: CanvasNode.Kind) -> [UTType] {
        switch kind {
        case .image: return [.image]
        case .video: return [.movie, .video]
        case .audio: return [.audio]
        case .text:  return [.plainText]
        }
    }

    private func flashReject(_ msg: String) {
        canvas.rejectMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if canvas.rejectMessage == msg { canvas.rejectMessage = nil }
        }
    }

    /// 松手：落点砸在哪个节点上就连哪个
    private func finishPendingEdge() {
        defer {
            canvas.pendingEdgeFrom = nil
            canvas.pendingEdgeTo = nil
            canvas.hoveredDropTarget = nil
            canvas.pendingEdgeIsLeading = false
        }
        guard let from = canvas.pendingEdgeFrom, let drop = canvas.pendingEdgeTo else { return }
        guard let target = canvas.nodes.first(where: { $0.frame.contains(drop) }) else { return }

        // 方向按拉线的那一侧定：左侧的 + 是「给我加上下文」，
        // 所以连成 目标→源；右侧才是 源→目标。
        // 不区分的话，从文字卡片左边拉到图片会连成「文字参考图片」，方向是反的
        let realFrom = canvas.pendingEdgeIsLeading ? target.id : from
        let realTo   = canvas.pendingEdgeIsLeading ? from : target.id
        // 按**目标**节点的类型取模型，跟 + 菜单那套判定保持一致
        let result = canvas.connect(from: realFrom, to: realTo,
                                    provider: providerFor(nodeID: realTo))
        if let msg = result.message {
            canvas.rejectMessage = msg
            // 提示两秒自己消失
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if canvas.rejectMessage == msg { canvas.rejectMessage = nil }
            }
        }
    }

    private func applyCursor() {
        // 子控件（节点边缘热区之类）认领了光标就别抢
        guard !canvas.cursorClaimedByChild else { return }
        if canvas.isPanning {
            NSCursor.closedHand.set()
        } else if canvas.isSpaceHeld {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.085, green: 0.085, blue: 0.095)

            DotGridBackground(zoom: canvas.zoom, offset: canvas.offset)

            if canvas.nodes.isEmpty && canvas.pendingEdgeFrom == nil {
                VStack(spacing: 10) {
                    Image(nsImage: SidebarSVGIcon.load("doubleClickAdd", size: 30))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .foregroundColor(Color.labelSecondary.opacity(0.28))
                    Text("双击空白处添加节点")
                        .font(.system(size: 12))
                        .foregroundColor(Color.labelSecondary.opacity(0.35))
                }
            }

            // 内容层：连线在下、节点在上，整层跟着缩放平移走
            contentLayer
                // 坐标空间要挂在变换**之前** —— 挂在 scaleEffect/offset 后面的话，
                // 拿到的是变换后的屏幕坐标，拉线时虚线末端跟节点位置对不上、不跟手
                .coordinateSpace(name: "canvasContent")
                // 选中卡片时操作栏浮在卡片正上方。它要贴着卡片，
                // 所以**留在内容层里**跟着缩放平移一起走
                .overlay {
                    if let sel = canvas.selectedNodeID, let n = canvas.node(sel) {
                        let f = canvas.displayFrame(of: n)
                        CanvasNodeActionBar(canvas: canvas, node: n)
                            .environmentObject(project)
                            .fixedSize()
                            .position(x: f.midX, y: f.minY - CanvasNodeView.labelHeight - 22)
                    }
                }
                .scaleEffect(canvas.zoom)
                .offset(x: canvas.offset.width, y: canvas.offset.height)
        }
        // 左侧悬浮栏。**挂在缩放平移之外** —— 挂进内容层的话它会跟着画布
        // 一起缩放漂移，位置全乱（截图里跑到画布中间和左下角就是这么来的）
        // 菜单层要排在侧栏**前面** —— 后加的 overlay 盖在上面，
        // 哪怕两者视觉上不重叠，上层那个容器也会先参与 hit test，
        // 把侧栏下面两个按钮的鼠标事件吃掉（表现是「菜单一出来就 hover 不到素材库」）。
        // 菜单不显示时整层也不拦事件
        .overlay(alignment: .leading) { sideBarMenu.allowsHitTesting(canvas.sideMenuVisible) }
        .overlay(alignment: .leading) { sideBar }
        .contentShape(Rectangle())
        // 菜单一关就把 + 的保持状态清掉。挂在这儿而不是逐个关闭路径里补 ——
        // 关菜单的入口有好几个（选类型、上传、素材库、点空白），漏一条就是
        // 「菜单没了 + 还赖着」
        .onChange(of: showAddMenu) { _, showing in
            if !showing { canvas.plusMenuSource = nil }
        }
        // 双击空白：在落点加节点
        .onTapGesture(count: 2) { location in
            let content = contentPoint(from: location)
            canvas.selectedNodeIDs = []
            canvas.selectedGroupID = nil
            menuLocation = location
            menuContentPoint = content
            showAddMenu = true
        }
        .onTapGesture {
            canvas.selectedNodeIDs = []
            canvas.selectedGroupID = nil
            canvas.editingTextNodeID = nil   // 点空白退出文本编辑，回到默认态
        }
        // 触控板双指捏合缩放。跟时间轴那边一个套路：
        // 手势给的是**累积倍率**，所以要记住捏之前的 zoom 当基准，
        // 每次拿 base × magnification 算，不能在当前值上反复乘（会越缩越快）
        .gesture(
            MagnifyGesture(minimumScaleDelta: 0.005)
                .onChanged { value in
                    if pinchBaseZoom == nil { pinchBaseZoom = canvas.zoom }
                    let base = pinchBaseZoom ?? canvas.zoom
                    canvas.setZoom(base * value.magnification,
                                   anchor: nil, containerSize: containerSize)
                }
                .onEnded { _ in pinchBaseZoom = nil }
        )
        // 空格 + 拖 = 平移（Figma 手感）。空格状态由 CanvasKeyMonitor 维护
        // 阈值 3pt：1pt 的话点空白时手一抖就成了框选，单击取消选中会失灵
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if canvas.isSpaceHeld {
                        if dragStartOffset == nil {
                            dragStartOffset = canvas.offset
                            canvas.isPanning = true
                        }
                        let base = dragStartOffset ?? .zero
                        canvas.offset = CGSize(width: base.width + value.translation.width,
                                               height: base.height + value.translation.height)
                        return
                    }
                    // 空白处拖 = 框选。在卡片上拖会被卡片自己的手势接走，到不了这儿
                    if marqueeStart == nil {
                        marqueeStart = contentPoint(from: value.startLocation)
                    }
                    marqueeEnd = contentPoint(from: value.location)
                }
                .onEnded { _ in
                    if canvas.isSpaceHeld {
                        dragStartOffset = nil
                        canvas.isPanning = false
                        return
                    }
                    if let r = marqueeRect, r.width > 3 || r.height > 3 {
                        canvas.selectInRect(r)
                    }
                    marqueeStart = nil
                    marqueeEnd = nil
                }
        )
        // 滚轮不走 NSView 的 scrollWheel —— SwiftUI 合并绘制，hitTest 命中的
        // 始终是最外层 NSHostingView，插进来的 NSView 根本收不到。
        // 跟时间轴一样用 local monitor 接（见 CanvasKeyMonitor）
        .onHover { inside in
            if !inside {
                canvas.isPanning = false
                NSCursor.arrow.set()
            }
        }
        // 按住空格是张开的手，拖起来是握紧的手（Figma/PS 手感）。
        // 光标要在移动时持续 set —— 系统会在鼠标移过不同视图时把它重置回箭头，
        // 只在状态变化时设一次，手一动就变回箭头了
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                applyCursor()
                hoverContentPoint = contentPoint(from: location)
            case .ended:
                hoverContentPoint = nil
            }
        }
        .onChange(of: canvas.isSpaceHeld) { _, _ in applyCursor() }
        .onChange(of: canvas.isPanning) { _, _ in applyCursor() }
        // 添加菜单：双击空白或点节点上的 + 都弹它
        // 菜单自绘并定位到点击处。用 .popover 的话锚点只能给一个固定的
        // UnitPoint（.topLeading 之类），菜单永远贴在画布左上角，跟点哪儿无关
        // 菜单开着时先盖一层背板。不用画布自己的 onTapGesture 关菜单 ——
        // 那一层还挂着双击手势，单击要等系统确认「不是双击」才触发，
        // 表现就是点一下菜单要过小半秒才消失
        .overlay {
            if showAddMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showAddMenu = false
                        menuSourceNode = nil
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if showAddMenu {
                CanvasAddMenu(
                    title: menuTitle,
                    kinds: menuKinds,
                    showsResourceGroup: menuSourceNode == nil,
                    onPick: { kind in
                        showAddMenu = false
                        addNode(kind: kind)
                    },
                    onUpload: {
                        showAddMenu = false
                        uploadIntoNewNode()
                    },
                    onPickAsset: {
                        showAddMenu = false
                        showAssetPicker = true
                    })
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .offset(x: menuOffset.x, y: menuOffset.y)
            }
        }
        // 点空白关菜单
        .onChange(of: canvas.selectedNodeID) { _, _ in showAddMenu = false }
        // 选中媒体节点时，底部升起输入框
        .overlay(alignment: .bottom) {
            // 文本节点也要出输入框（用文字模型生成正文），别再按类型挡了
            if let sel = canvas.selectedNodeID, let n = canvas.node(sel) {
                CanvasPromptBar(canvas: canvas, node: n)
                    .environmentObject(project)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // 动画只归输入框自己。挂在整层上的话，新建卡片会设选中，
                    // 卡片跟着一起做位移动画 —— 那就是「加卡片时有多余动画」的来源
                    .animation(.easeOut(duration: 0.2), value: canvas.selectedNodeID)
            }
        }
        // 连线被拒的提示
        .overlay(alignment: .bottom) {
            if let msg = canvas.rejectMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: canvas.rejectMessage)
        // 素材选择器挂 overlay，不用 .sheet —— 系统 sheet 是独立窗口，
        // floatingPanelMaterial 的 .withinWindow 混合采样不到主界面，材质会变成一块灰板
        .overlay {
            if showAssetPicker {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { showAssetPicker = false; fillTargetNode = nil }
                CanvasAssetPicker(limitTo: fillTargetNode.flatMap { canvas.node($0)?.kind }) { asset in
                    showAssetPicker = false
                    guard let asset else { fillTargetNode = nil; return }
                    if let target = fillTargetNode {
                        canvas.updateNode(id: target) {
                            $0.assetID = asset.id
                            $0.mediaPath = asset.url.path
                            $0.displayName = asset.name
                        }
                        fillTargetNode = nil
                    } else if let kind = CanvasSurfaceKindResolver.nodeKind(for: asset.url) {
                        addNode(kind: kind, mediaURL: asset.url, assetID: asset.id)
                    }
                }
                .environmentObject(project)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showAssetPicker)
        // 节点上的「上传」「素材」：填进那个节点，不新建
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeUpload)) { note in
            guard let id = note.object as? UUID, let n = canvas.node(id) else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            // 只让选这个节点吃得下的类型 —— 图片卡片里塞个 mp4 没有意义
            panel.allowedContentTypes = Self.contentTypes(for: n.kind)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard CanvasSurfaceKindResolver.nodeKind(for: url) == n.kind else {
                flashReject("这个卡片只能放\(n.kind.label)")
                return
            }
            project.importFile(url)
            let asset = project.mediaAssets.first { $0.url == url }
            canvas.updateNode(id: id) {
                $0.mediaPath = url.path
                $0.assetID = asset?.id
                // 用户自己传进来的素材用它本来的名字，比「音频 1」认得出
                $0.displayName = asset?.name ?? url.lastPathComponent
            }
        }
        // 生成完的产物自动进全局素材库（画布产物落地的规则）
        .onChange(of: canvas.nodes.compactMap(\.mediaPath)) { old, new in
            for path in new where !old.contains(path) {
                let url = URL(fileURLWithPath: path)
                guard project.mediaAssets.first(where: { $0.url == url }) == nil else { continue }
                project.importFile(url)
                // 回填 assetID，节点封面就能走素材库那份缩略图
                if let asset = project.mediaAssets.first(where: { $0.url == url }),
                   let nodeID = canvas.nodes.first(where: { $0.mediaPath == path && $0.assetID == nil })?.id {
                    canvas.updateNode(id: nodeID) { $0.assetID = asset.id }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeToTimeline)) { note in
            guard let id = note.object as? UUID, let n = canvas.node(id), let url = n.mediaURL else { return }
            project.importFile(url)
            guard let asset = project.mediaAssets.first(where: { $0.url == url }) else { return }
            project.addToTimelineAt(asset, time: project.currentTime)
            flashReject("已添加到时间轴")
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeToSubtitle)) { note in
            guard let id = note.object as? UUID, let n = canvas.node(id) else { return }
            project.insertSubtitleAtPlayhead(text: n.text)
            flashReject("已插入字幕")
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeToTitle)) { note in
            guard let id = note.object as? UUID, let n = canvas.node(id) else { return }
            project.addTextAtPlayhead(text: n.text)
            flashReject("已插入标题文字")
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeRetry)) { note in
            guard let id = note.object as? UUID else { return }
            canvas.submitGeneration(nodeID: id, provider: AIVideoService.shared.selectedProvider)
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeToReference)) { note in
            guard let id = note.object as? UUID, let n = canvas.node(id), let url = n.mediaURL else { return }
            let type: AIVideoService.RefContentType
            switch n.kind {
            case .image: type = .image
            case .video: type = .video
            case .audio: type = .audio
            case .text:  return
            }
            let thumb = n.assetID.flatMap { project.mediaThumbnails[$0] }
                ?? NSImage(contentsOf: url)
                ?? NSImage(size: NSSize(width: 1, height: 1))
            AIVideoService.shared.referenceContents.append(
                AIVideoService.RefContent(url: url, type: type, thumbnail: thumb))
            flashReject("已加入 AI 参考")
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodePickAsset)) { note in
            guard let id = note.object as? UUID else { return }
            fillTargetNode = id
            showAssetPicker = true
        }
    }
}

/// 点阵背景。跟着缩放和平移走，用户才有「画布在动」的实感
private struct DotGridBackground: View {
    let zoom: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            let spacing = 24 * zoom
            guard spacing > 4 else { return }   // 缩太小就别画了，一片糊

            let dotSize = max(1, 1.2 * zoom)
            let color = Color.white.opacity(0.10)

            // 让点阵跟着 offset 走，取模避免每帧画整片
            let startX = offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = offset.height.truncatingRemainder(dividingBy: spacing)

            var y = startY - spacing
            while y < size.height + spacing {
                var x = startX - spacing
                while x < size.width + spacing {
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 空格键监听

/// 维护「空格是否按住」。
///
/// `addLocalMonitorForEvents` 是**进程级**的，不属于任何窗口：多窗口下每个窗口装一个，
/// 不按当前窗口过滤就会「在 A 窗口按空格，B 窗口的画布也进入拖拽模式」。
/// 生命周期也不能挂 `onDisappear` —— 那个在视图重建时会误触发，拆早了空格永久失效。
/// 句柄交给 `WindowManager` 保管，随窗口一起销毁（跟 esc 监听同一套路）。
struct CanvasKeyMonitor: ViewModifier {
    @ObservedObject var canvas: CanvasState
    let windowID: WindowID
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, active in
                if active { install() } else { remove() }
            }
            .onAppear { if isActive { install() } }
    }

    private func install() {
        remove()
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // 只认当前窗口的按键，否则别的窗口按空格这边也会跟着进拖拽模式
            guard let w = event.window,
                  WindowManager.shared.id(of: w) == windowID else { return event }
            // 正在输入文字时这些键都归输入框
            let editing = (w.firstResponder is NSTextView) || (w.firstResponder is NSTextField)

            // ⌘Z / ⇧⌘Z 撤的是画布自己的栈，不是时间轴的
            if event.type == .keyDown, !editing,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                if event.modifierFlags.contains(.shift) { canvas.redo() } else { canvas.undo() }
                return nil
            }

            // ⌘C / ⌘V。正在输入文字时不拦 —— 那时候归输入框自己复制粘贴
            if event.type == .keyDown, !editing,
               event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    let ids = canvas.selectedGroupID.map { canvas.nodeIDs(inGroup: $0) }
                              ?? canvas.selectedNodeIDs
                    guard !ids.isEmpty else { break }
                    canvas.copy(ids: ids)
                    return nil
                case "v":
                    guard !canvas.clipboard.isEmpty else { break }
                    canvas.paste()
                    return nil
                default: break
                }
            }

            // delete / backspace 删掉选中的节点（框选中的一批一起删）
            if event.type == .keyDown, !editing,
               event.keyCode == 51 || event.keyCode == 117 {
                let ids = canvas.selectedGroupID.map { canvas.nodeIDs(inGroup: $0) }
                          ?? canvas.selectedNodeIDs
                guard !ids.isEmpty else { return event }
                canvas.delete(ids: ids)
                return nil
            }

            // 49 = 空格
            guard event.keyCode == 49 else { return event }
            // 正在输入文字时空格是空格，不是拖拽
            if let responder = w.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // 选中了能播的卡片：空格管播放/暂停，不拖画布。
            // 没选中才是拖拽模式。按下时切一次，抬起不管（不然一次按键切两回）
            if let sel = canvas.selectedNodeID,
               let node = canvas.nodes.first(where: { $0.id == sel }),
               node.kind == .video || node.kind == .audio,
               node.hasContent, !node.isGenerating,
               let url = node.mediaURL {
                if event.type == .keyDown { AIInlinePlayer.shared.toggle(url) }
                canvas.isSpaceHeld = false
                return nil
            }
            canvas.isSpaceHeld = (event.type == .keyDown)
            return nil   // 吞掉，免得底下的时间轴拿去播放/暂停
        }

        let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let w = event.window,
                  WindowManager.shared.id(of: w) == windowID else { return event }

            if event.modifierFlags.contains(.command) {
                // 锚点：事件坐标是窗口坐标、y 轴朝上；画布容器从窗口顶部往下 topGap 开始
                let winH = w.contentView?.bounds.height ?? 0
                let containerH = max(1, winH - canvas.topGap)
                let anchor = CGPoint(x: event.locationInWindow.x,
                                     y: containerH - event.locationInWindow.y)
                let containerSize = CGSize(width: w.contentView?.bounds.width ?? 0,
                                           height: containerH)
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                let factor = 1 + delta * 0.01
                canvas.setZoom(canvas.zoom * factor, anchor: anchor, containerSize: containerSize)
            } else {
                canvas.offset = CGSize(width: canvas.offset.width + event.scrollingDeltaX,
                                       height: canvas.offset.height + event.scrollingDeltaY)
            }
            return nil   // 吞掉，否则时间轴的滚轮监听会跟着缩放
        }

        WindowManager.shared.setCanvasSpaceMonitor(keyMonitor, for: windowID)
        WindowManager.shared.setCanvasScrollMonitor(scrollMonitor, for: windowID)
    }

    private func remove() {
        canvas.isSpaceHeld = false
        WindowManager.shared.setCanvasSpaceMonitor(nil, for: windowID)
        WindowManager.shared.setCanvasScrollMonitor(nil, for: windowID)
    }
}

extension View {
    /// 画布打开时接管空格键
    func canvasKeyMonitor(canvas: CanvasState, windowID: WindowID, isActive: Bool) -> some View {
        modifier(CanvasKeyMonitor(canvas: canvas, windowID: windowID, isActive: isActive))
    }
}


// MARK: - 连线层

/// 连线。哪条被 hover **不能用 `.onHover`** —— 它认的是视图 bounds，
/// 不认 `contentShape`，一条线的视图铺满整层，结果就是鼠标在画布任何地方
/// 都算悬在线上。改成拿鼠标点算到曲线的最近距离。
private struct CanvasEdgeLayer: View {
    @ObservedObject var canvas: CanvasState
    /// 鼠标在内容坐标里的位置（由画布层换算好传进来），nil 表示鼠标不在画布上
    let hoverPoint: CGPoint?

    @State private var selectedEdge: UUID?
    /// 蚂蚁线的相位。一直往负方向跑，线看着就在往前爬
    @State private var dashPhase: CGFloat = 0

    /// 距离小于这个就算悬在线上。线本身 1.5pt，太严了根本悬不中
    private static let hitTolerance: CGFloat = 8

    private var hoveringEdge: UUID? {
        guard let hoverPoint else { return nil }
        var best: (id: UUID, dist: CGFloat)?
        for edge in canvas.edges {
            guard let from = canvas.node(edge.from), let to = canvas.node(edge.to) else { continue }
            let f = canvas.displayFrame(of: from), t = canvas.displayFrame(of: to)
            let d = EdgeGeometry.distance(from: hoverPoint,
                                          start: CGPoint(x: f.maxX, y: f.midY),
                                          end: CGPoint(x: t.minX, y: t.midY))
            if d <= Self.hitTolerance, best == nil || d < best!.dist {
                best = (edge.id, d)
            }
        }
        return best?.id
    }

    var body: some View {
        let hovering = hoveringEdge
        return ZStack {
            ForEach(canvas.edges) { edge in
                if let from = canvas.node(edge.from), let to = canvas.node(edge.to) {
                    // 用 displayFrame 而不是 node.frame：拖动中的卡片位置在临时偏移里，
                    // 读 model 的话线会钉在原地不跟卡片走
                    let fromF = canvas.displayFrame(of: from)
                    let toF = canvas.displayFrame(of: to)
                    let start = CGPoint(x: fromF.maxX, y: fromF.midY)
                    let end = CGPoint(x: toF.minX, y: toF.midY)
                    let isActive = (hovering == edge.id || selectedEdge == edge.id)
                    // 连着选中卡片的线走「蚂蚁线」：黄色虚线一直往前爬，
                    // 一眼看出这张卡片跟谁有关系
                    let linked = canvas.selectedNodeID != nil
                        && (edge.from == canvas.selectedNodeID || edge.to == canvas.selectedNodeID)

                    EdgeShape(start: start, end: end)
                        .stroke(isActive || linked ? Color.accent : Color.white.opacity(0.35),
                                style: linked
                                    ? StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: dashPhase)
                                    : StrokeStyle(lineWidth: isActive ? 2 : 1.5))
                        .allowsHitTesting(false)

                    // 悬上去就出删除，不用先点一下
                    if isActive {
                        Button {
                            canvas.removeEdge(id: edge.id)
                            selectedEdge = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.black.opacity(0.75)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                        .help("删除这条连线")
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    }
                }
            }

            // 正在拉的那条，虚线跟手
            if let fromID = canvas.pendingEdgeFrom,
               let from = canvas.node(fromID),
               let to = canvas.pendingEdgeTo {
                let f = canvas.displayFrame(of: from)
                EdgeShape(start: CGPoint(x: f.maxX, y: f.midY), end: to)
                    .stroke(Color.accent,
                            style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        // 蚂蚁线的驱动。不用 withAnimation(repeatForever) 改 @State ——
        // 连线层每帧都在跟着节点位置重算，那个隐式动画会被不断打断，线就不动了。
        // 用 SwiftUI.TimelineView 按时间算相位，稳定
        // （得写全限定名：项目里的时间轴视图也叫 TimelineView，会撞）
        .background(
            SwiftUI.TimelineView(.animation) { context in
                Color.clear
                    .onChange(of: context.date) { _, date in
                        // dash 周期 6+4=10，0.6 秒爬完一个周期
                        let t = date.timeIntervalSinceReferenceDate
                        dashPhase = -CGFloat(t.truncatingRemainder(dividingBy: 0.6) / 0.6 * 10)
                    }
            }
            .allowsHitTesting(false)
        )
    }
}

/// 曲线的几何计算
enum EdgeGeometry {
    /// 控制点按水平距离取，短距离也不会打死结
    static func controlPoints(start: CGPoint, end: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(40, abs(end.x - start.x) * 0.5)
        return (CGPoint(x: start.x + dx, y: start.y), CGPoint(x: end.x - dx, y: end.y))
    }

    /// 点到这条三次贝塞尔的近似最短距离。采样 24 段够用了 ——
    /// 判的是「鼠标悬没悬在线上」，不需要解析精度
    static func distance(from point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let (c1, c2) = controlPoints(start: start, end: end)
        var best = CGFloat.greatestFiniteMagnitude
        var prev = start
        for i in 1...24 {
            let t = CGFloat(i) / 24
            let p = bezier(t, start, c1, c2, end)
            best = min(best, distanceToSegment(point, prev, p))
            prev = p
        }
        return best
    }

    private static func bezier(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = min(1, max(0, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// 横向出入的三次贝塞尔，控制点按水平距离取，短距离也不会打死结
private struct EdgeShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: start)
        let (c1, c2) = EdgeGeometry.controlPoints(start: start, end: end)
        p.addCurve(to: end, control1: c1, control2: c2)
        return p
    }
}

// MARK: - 添加节点菜单

/// 添加节点的菜单。三种场景共用：
/// 双击空白/侧栏（全类型 + 上传 + 素材库）、卡片右边的 +（引用该节点生成）、
/// 卡片左边的 +（给它加上下文）
struct CanvasAddMenu: View {
    /// 菜单标题
    var title: String = "添加节点"
    /// 只列这些类型；nil 就是全都列
    var kinds: [CanvasNode.Kind]? = nil
    /// 要不要「上传 / 从素材库选择」那一组
    var showsResourceGroup: Bool = true

    var onPick: (CanvasNode.Kind) -> Void
    var onUpload: () -> Void
    var onPickAsset: () -> Void

    private var listed: [CanvasNode.Kind] {
        kinds ?? CanvasNode.Kind.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title)
            ForEach(listed, id: \.self) { kind in
                MenuRow(icon: CanvasNodeView.iconKey(for: kind),
                              title: kind.label) { onPick(kind) }
            }
            if showsResourceGroup {
                Divider().opacity(0.12).padding(.vertical, 4)
                sectionTitle("添加资源")
                MenuRow(icon: "importFile", title: "上传", action: onUpload)
                MenuRow(icon: "folder", title: "从素材库选择", action: onPickAsset)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 160)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(Color.labelSecondary.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }
}

/// 添加菜单里的一行。图标用软件自己那套 SVG，不混 SF Symbols
private struct MenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: SidebarSVGIcon.load(icon, size: 13))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundColor(Color.labelPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering ? 0.10 : 0))
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


/// 按扩展名决定该落哪种节点。抽出来是为了能单独测 ——
/// 判定错的话表现是「拖个 mp3 进来落了个图片节点」
enum CanvasSurfaceKindResolver {
    static func nodeKind(for url: URL) -> CanvasNode.Kind? {
        guard let type = ProjectState.assetType(for: url.pathExtension.lowercased()) else { return nil }
        switch type {
        case .video: return .video
        case .audio: return .audio
        case .image: return .image
        case .subtitle: return nil   // 字幕没有对应的节点类型
        }
    }
}
