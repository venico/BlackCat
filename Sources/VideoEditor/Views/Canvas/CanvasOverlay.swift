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
    /// 有文件正拖在画布上。素材区和聊天区都有这个反馈，画布不该缺
    @State private var dropTargeted = false
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
                            // NSEvent 层的右键监听要判断「点击位置是否落在正在编辑的
                            // 卡片上」，得知道这个容器多大才能做同一套坐标换算 ——
                            // 见 CanvasKeyMonitor 里 rightMonitor 的注释
                            .onAppear { canvas.containerSize = geo.size }
                            .onChange(of: geo.size) { _, s in canvas.containerSize = s }
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
                    // 模型层要往全局素材库里加产物，得先认识 project（弱引用）
                    canvas.project = project
                    // 老画布带着元素库数据：并进素材库，卡片补上 assetID
                    canvas.migrateProducedAssetsIntoLibrary(project)
                    // 画布关着的时候在侧边栏改的素材名，这会儿补上
                    canvas.syncNodesFromLibrary(project)
                }
                .onChange(of: closing) { _, isClosing in
                    guard isClosing else { return }
                    maskVisible = false
                    withAnimation(.easeIn(duration: 0.2)) { slideY = outer.size.height }
                    // 动画播完再真正摘掉；遮罩在上面那层，这时已经跟着 showCanvas 一起没了
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        FileDropRouter.unregister(windowID, kind: .canvas)
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
            guard !canvas.isSpaceHeld else { return }   // 空格模式下光标归画布管
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .help("上下拖动调整画布高度")
    }

    // MARK: - 画布主体

    private func canvasBody(containerSize: CGSize) -> some View {
        ZStack {
            CanvasSurface(canvas: canvas, containerSize: containerSize)
                // 从访达拖文件进来落成卡片。跟素材库一样得走 FileDropRouter ——
                // SwiftUI 的 .onDrop 在这个 app 里收不到（见 FileDropRouter 注释）
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { registerCanvasDropZone(g.frame(in: .global)) }
                        .onChange(of: g.frame(in: .global)) { _, r in registerCanvasDropZone(r) }
                })

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
        // 拖文件进来时的反馈。跟素材区一个样式：整块染色，不加描边和文字。
        // 排在聊天卡片**前面** —— 这层染色不该盖住卡片
        .overlay {
            if dropTargeted {
                Color.accent.opacity(0.06).allowsHitTesting(false)
            }
        }
        // Agent 会话卡片。位置由它自己按吸附结果算，这儿只给它整块画布
        .overlay(alignment: .topLeading) {
            CanvasChatCard(containerSize: containerSize)
        }
    }

    private func registerCanvasDropZone(_ rect: CGRect) {
        FileDropRouter.register(windowID, kind: .canvas, rect: rect,
                                accepts: { if case .files = $0 { return true } else { return false } },
                                onDrop: { payload, local in
                                    guard case .files(let urls) = payload else { return }
                                    // local 是画布容器里的坐标，换算成内容坐标才知道落哪张卡片
                                    canvas.dropFiles(urls, at: canvas.contentPoint(fromViewPoint: local))
                                },
                                onTargetChange: { dropTargeted = $0 })
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
                toggleButton(timeline: "snap", help: "吸附对齐", on: canvas.snapEnabled) {
                    canvas.snapEnabled.toggle()
                }
                toggleButton(svg: "relink", help: "显示连接线", on: canvas.edgesVisible) {
                    canvas.edgesVisible.toggle()
                }
            }

            pillGroup {
                // 图标复用时间轴那两个，同一件事在两处长一个样
                barButton(timeline: "undo", help: "撤销（⌘Z）", enabled: canvas.canUndo) {
                    canvas.undo()
                }
                barButton(timeline: "redo", help: "重做（⇧⌘Z）", enabled: canvas.canRedo) {
                    canvas.redo()
                }
            }

            pillGroup {
                barButton(system: "minus", help: "缩小", enabled: canvas.zoom > CanvasState.minZoom) {
                    canvas.zoomOut(containerSize: containerSize)
                }
                Button {
                    // 已经在 100% 上了就切到「刚好装下全部内容」，否则先回 100%。
                    // 一个按钮来回切这两档，不用再多摆一个「适应画布」的按钮
                    if abs(canvas.zoom - 1) < 0.001 {
                        canvas.zoomToFit(containerSize: containerSize)
                    } else {
                        canvas.resetView()
                    }
                } label: {
                    Text("\(canvas.zoomPercent)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 46, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(abs(canvas.zoom - 1) < 0.001 ? "点一下缩放到全部内容" : "点一下回到 100%")

                barButton(system: "plus", help: "放大", enabled: canvas.zoom < CanvasState.maxZoom) {
                    canvas.zoomIn(containerSize: containerSize)
                }
            }
        }
    }

    private func pillGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            // 高度跟左上角关闭按钮那个圆一致（28）。上下再留 padding 的话
            // 这两条胶囊会比关闭按钮高出一截，顶栏看着不齐
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// 开关型按钮：开着高亮、关着变暗，一眼看出当前状态。
    /// 图标复用现成的两套（时间轴的 snap、素材库的 relink），不新画
    private func toggleButton(timeline: String? = nil, svg: String? = nil,
                              help: String, on: Bool, action: @escaping () -> Void) -> some View {
        let image = timeline.map { TimelineSVGIcon.load($0, size: 13) }
            ?? SidebarSVGIcon.load(svg ?? "", size: 13)
        return Button(action: action) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .foregroundColor(on ? Color.accent : Color.labelSecondary.opacity(0.55))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func barButton(system: String? = nil, timeline: String? = nil,
                           help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let timeline {
                    Image(nsImage: TimelineSVGIcon.load(timeline, size: 13))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: system ?? "")
                        .font(.system(size: 11, weight: .medium))
                }
            }
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
        canvas.editingTextNodeID = nil
        // 正在编辑文字卡片时关画布，那个 NSTextView 可能还占着第一响应者 ——
        // 关闭动画播放期间这个 view 不一定还会再触发 updateNSView，
        // 「focused=false 就交还」那条逻辑未必来得及跑，第一响应者会一直
        // 「赖」在这个即将销毁的 NSTextView 上。表现是回到主界面之后，
        // AI 聊天框怎么点都抢不到键盘焦点。主动交还，不依赖那条逻辑
        WindowManager.shared.window(for: windowID)?.makeFirstResponder(nil)
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
    private func saveCanvas() { canvas.persist() }
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

    /// 右键菜单里要不要出「重新关联文件…」：只选中一张、且它指的文件已经不在了。
    /// 多选时不给 —— 一次只能挑一个新文件，批量关联没有意义
    private var missingMediaTarget: UUID? {
        guard ctxTargets.count == 1, let id = ctxTargets.first,
              let n = canvas.node(id), let path = n.mediaPath,
              !FileManager.default.fileExists(atPath: path) else { return nil }
        return id
    }
    /// 从哪个节点的 + 拉出来的线（点 + 弹菜单时，新节点自动连上它）
    /// 添加菜单是从哪张卡片的哪一侧 + 弹出来的。nil = 从空白/侧栏弹的。
    ///
    /// **id 和 edge 必须绑在一个可选值里一起设、一起清**：早前是两个独立
    /// @State，双击空白弹菜单那条路径只顾着弹、忘了清 id，菜单就照着上一次
    /// 点过的那张卡片算「能生成什么」—— 表现是「明明在音频卡片/空白处弹的菜单，
    /// 列出来的却是上一张视频卡片的选项」
    @State private var menuSource: MenuSource?

    struct MenuSource {
        let nodeID: UUID
        let kind: CanvasNode.Kind
        let edge: Edge
    }
    /// 从哪边的 + 点出来的。左边 = 新卡片当上游，右边 = 当下游
    @State private var showAssetPicker = false
    /// 鼠标在内容坐标里的位置，连线层拿它判断悬没悬在某条线上
    // 鼠标位置放在 canvas.hoverProbe 上（单独对象），不放这层的 @State ——
    // 放这儿的话鼠标每动一下整个画布层都要重算，卡片越多越卡
    /// 节点上那两个按钮点的是哪个节点（填内容进去，不是新建）
    @State private var fillTargetNode: UUID?
    /// 框选的起止点（内容坐标）。**本地状态** —— 每帧写 @Published 会让整层重建
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    /// 空白处上一次点击的时间，自己判连击用（见下面 onTapGesture 的注释）
    @State private var lastBlankTapTime: Date = .distantPast
    /// 自绘右键菜单：弹在哪、作用于谁
    @State private var ctxLocation: CGPoint?
    @State private var ctxTargets: Set<UUID> = []
    @State private var ctxGroupID: UUID?

    /// 左侧悬浮栏。抽成独立属性 —— 整段塞进 body 的话表达式太长，
    /// 编译器会直接报「无法在合理时间内完成类型检查」
    private var sideBar: some View {
        CanvasSideBar(
            canvas: canvas,
            onPickKind: { kind in
                menuSource = nil
                menuContentPoint = viewportCenterContentPoint
                _ = addNode(kind: kind)
            },
            onUpload: {
                menuSource = nil
                menuContentPoint = viewportCenterContentPoint
                uploadIntoNewNode()
            },
            onPickAssetFromLibrary: {
                menuSource = nil
                menuContentPoint = viewportCenterContentPoint
                fillTargetNode = nil
                showAssetPicker = true
            },
            // 抽屉（素材库/资产库）里点一项：直接落成卡片
            onPickAsset: { url, kind in
                menuSource = nil
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
                    menuSource = nil
                    menuContentPoint = viewportCenterContentPoint
                    _ = addNode(kind: kind)
                },
                onUpload: {
                    canvas.sideAddHovering = false; canvas.sideMenuHovering = false
                    menuSource = nil
                    menuContentPoint = viewportCenterContentPoint
                    uploadIntoNewNode()
                },
                onPickAsset: {
                    canvas.sideAddHovering = false; canvas.sideMenuHovering = false
                    menuSource = nil
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
        guard let src = menuSource else { return "添加节点" }
        return src.edge == .trailing ? "引用该节点生成" : "添加上下文"
    }

    /// 菜单里列哪几种类型。规则挂在 `CanvasNode.Kind` 上：
    /// 右边看 canGenerate（这个节点能派生出什么），左边看 acceptsContext（它能接什么）
    private var menuKinds: [CanvasNode.Kind]? {
        guard let src = menuSource else { return nil }
        return src.edge == .trailing ? src.kind.canGenerate : src.kind.acceptsContext
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

    /// 输入框自己的宽度（`CanvasPromptBar` 里写死 720），钳位置要用
    static let promptBarWidth: CGFloat = 720
    /// 给输入框留的最小高度，贴到画布底边时按这个钳住
    static let promptBarMinRoom: CGFloat = 150

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
                CanvasGroupBackdrop(canvas: canvas, gid: g.id, name: g.name,
                                    colorHex: canvas.group(g.id)?.colorHex, rect: g.rect)
            }

            if canvas.edgesVisible {
                CanvasEdgeLayer(canvas: canvas, probe: canvas.hoverProbe)
            }

            ForEach(visibleNodes) { node in
                CanvasNodeView(
                    canvas: canvas,
                    node: node,
                    onPlusTap: { edge in
                        menuSource = MenuSource(nodeID: node.id, kind: node.kind, edge: edge)
                        // 让**这一侧**的 + 在菜单开着时保持显示
                        canvas.plusMenuSource = .init(nodeID: node.id, isTrailing: edge == .trailing)
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
                // 节点视图比卡片高出一个标签行（在卡片上方），所以中心要往上挪半行。
                //
                // 尺寸一律用 `renderSize`，跟连线端点（`node.frame`）同一个口径 ——
                // 用 `node.size` 的话音频卡片会差一大截（它的显示高度是写死的 80）。
                // 文本卡片底部还多留了一份 resize 热区的余量，把视图重心往下拽了
                // 半份，这里补回来：不补的话卡片边上的连接圆点会比连线的端点
                // 高出 4pt，看着就是「线不从圆点中间出去，从下边出去」
                .position(x: node.position.x + node.renderSize.width / 2,
                          y: node.position.y + node.renderSize.height / 2
                             - CanvasNodeView.labelHeight / 2
                             + (node.kind == .text ? CanvasNodeView.edgeStraddle / 2 : 0))
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

            // 吸附对齐的辅助线。线宽除以 zoom，缩到多小都是细细一根
            ForEach(canvas.snapGuides) { g in
                let thickness = 1 / max(0.1, canvas.zoom)
                let length = max(1, g.end - g.start)
                Rectangle()
                    .fill(Color(hex: "#FF3B7F"))
                    .frame(width: g.isVertical ? thickness : length,
                           height: g.isVertical ? length : thickness)
                    .position(x: g.isVertical ? g.position : (g.start + g.end) / 2,
                              y: g.isVertical ? (g.start + g.end) / 2 : g.position)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 当前看得见的那块内容区域，四周各放一屏三分之一的余量 ——
    /// 边上正要滑进来的卡片得先画好，不然平移时会看见它「凭空冒出来」
    private var visibleContentRect: CGRect {
        let topLeft = contentPoint(from: .zero)
        let bottomRight = contentPoint(from: CGPoint(x: containerSize.width,
                                                     y: containerSize.height))
        return CGRect(x: topLeft.x, y: topLeft.y,
                      width: bottomRight.x - topLeft.x,
                      height: bottomRight.y - topLeft.y)
            .insetBy(dx: -containerSize.width / 3, dy: -containerSize.height / 3)
    }

    /// 真正要画的卡片。
    ///
    /// 视口外的卡片照样要参与布局和 diff，卡片一多就是纯浪费。
    /// 少于这个数就全画 —— 过滤自己也有开销，而且视图增删会丢掉本地状态
    /// （hover、拖动偏移），能不折腾就不折腾
    private var visibleNodes: [CanvasNode] {
        guard canvas.nodes.count > 24 else { return canvas.nodes }
        let rect = visibleContentRect
        return canvas.nodes.filter { rect.intersects($0.frame) }
    }

    /// 框选矩形（内容坐标）
    private var marqueeRect: CGRect? {
        guard let s = marqueeStart, let e = marqueeEnd else { return nil }
        return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                      width: abs(e.x - s.x), height: abs(e.y - s.y))
    }

    /// 右键命中判定。卡片画在组的上面，所以先查卡片；
    /// 同类里后加的画在上层，倒着找才对得上眼睛看到的层次
    private func openContextMenu(at viewPoint: CGPoint) {
        let content = contentPoint(from: viewPoint)
        if let node = canvas.nodes.last(where: { $0.frame.contains(content) }) {
            // 右键已选中的卡片就管整批，右键没选中的只管它自己
            ctxTargets = canvas.selectedNodeIDs.contains(node.id) ? canvas.selectedNodeIDs
                                                                 : [node.id]
            ctxGroupID = nil
            ctxLocation = viewPoint
            return
        }
        if let g = canvas.groupFrames.last(where: { $0.rect.contains(content) }) {
            ctxTargets = canvas.nodeIDs(inGroup: g.id)
            ctxGroupID = g.id
            ctxLocation = viewPoint
            return
        }
        // 点在空白处也弹，只是菜单里只剩「粘贴」这类不依赖选中目标的项 ——
        // 空白右键正是要往这儿粘东西的时候
        ctxTargets = []
        ctxGroupID = nil
        ctxLocation = viewPoint
    }

    /// 落一个节点。从某个节点的 + 点出来的，自动连上去
    @discardableResult
    private func addNode(kind: CanvasNode.Kind, mediaURL: URL? = nil, assetID: UUID? = nil) -> CanvasNode {
        // 卡片以点击点为中心落下。position 存的是左上角，所以要减掉半个卡片 ——
        // 直接把左上角对着点击点的话，卡片会整个跑到鼠标的右下方
        // 带素材落地的卡片（上传、从素材库/元素库选）默认「原始」，跟随素材本身；
        // 空卡片是等着生成的，用上次记住的档位
        let hasMedia = mediaURL != nil || assetID != nil
        let remembered = kind == .image ? AppSettings.shared.aiImageRatio : AppSettings.shared.aiRatio
        let ratio = (hasMedia && (kind == .image || kind == .video))
            ? CanvasNode.originalRatio : remembered
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
        if let src = menuSource {
            let from = src.edge == .leading ? node.id : src.nodeID
            let to   = src.edge == .leading ? src.nodeID : node.id
            // 类型校验要按**下游**节点的模型来 —— 参考上限是下游那个模型的能力，
            // 用全局 selectedProvider 会拿错矩阵（比如给图片卡片按视频模型放行音频）
            let r = canvas.connect(from: from, to: to, provider: providerFor(nodeID: to))
            if let msg = r.message { flashReject(msg) }
            menuSource = nil
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
        // 空格模式优先级最高，**盖过子控件的认领**：按住空格就是「要拖画布」，
        // 这时候鼠标扫过卡片边缘、组边缘那些热区，不该变成调整大小的双向箭头
        if canvas.isPanning { NSCursor.closedHand.set(); return }
        if canvas.isSpaceHeld { NSCursor.openHand.set(); return }
        // 子控件（节点边缘热区之类）认领了光标就别抢
        guard !canvas.cursorClaimedByChild else { return }
        NSCursor.arrow.set()
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
        // 空白处点击：退出编辑/取消选中要立刻生效，不能等 SwiftUI 判断完
        // 「这是不是双击」再触发 —— `.onTapGesture(count: 2)` 和 `.onTapGesture(count: 1)`
        // 同时挂在同一个 view 上时，SwiftUI 会等约 0.3~0.4s 确认没有第二次点击
        // 才触发单击回调，表现就是「点一下没反应，得点第二下才生效」。
        // 改成自己判连击：单击该做的事立刻做，够快的第二下再追加「弹添加菜单」
        .onTapGesture { location in
            canvas.selectedNodeIDs = []
            canvas.selectedGroupID = nil
            canvas.editingTextNodeID = nil   // 点空白退出文本编辑，回到默认态
            // 焦点也一并收回，否则快捷键会一直被当成「在输入框里」而放行
            canvas.promptBarFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)

            let now = Date()
            if now.timeIntervalSince(lastBlankTapTime) < 0.35 {
                let content = contentPoint(from: location)
                menuLocation = location
                menuContentPoint = content
                // 从空白弹的菜单没有源卡片，这里必须清 —— 不清的话菜单会照着
                // 上一次点过的那张卡片算「能生成什么」，列出一堆不相干的类型
                menuSource = nil
                showAddMenu = true
                lastBlankTapTime = .distantPast   // 避免紧接着的第三下又被当成双击
            } else {
                lastBlankTapTime = now
            }
        }
        // 触控板双指捏合缩放。跟时间轴那边一个套路：
        // 手势给的是**累积倍率**，所以要记住捏之前的 zoom 当基准，
        // 每次拿 base × magnification 算，不能在当前值上反复乘（会越缩越快）。
        //
        // 锚点用手势**起手那一下**的位置，不是容器中心 —— 光标底下的东西
        // 缩放前后钉在原地，跟 ⌘+滚轮那条一致。整个手势期间锚点不变，
        // 逐帧取当前位置的话，手指在触控板上微动画面就会跟着漂
        .gesture(
            MagnifyGesture(minimumScaleDelta: 0.005)
                .onChanged { value in
                    if pinchBaseZoom == nil { pinchBaseZoom = canvas.zoom }
                    let base = pinchBaseZoom ?? canvas.zoom
                    canvas.setZoom(base * value.magnification,
                                   anchor: value.startLocation, containerSize: containerSize)
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
                        // 框选完焦点归画布，delete 才能直接删这一批
                        canvas.editingTextNodeID = nil
                        canvas.promptBarFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
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
                if !canvas.isSpaceHeld { NSCursor.arrow.set() }
            }
        }
        // 按住空格是张开的手，拖起来是握紧的手（Figma/PS 手感）。
        // 光标要在移动时持续 set —— 系统会在鼠标移过不同视图时把它重置回箭头，
        // 只在状态变化时设一次，手一动就变回箭头了
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                applyCursor()
                canvas.hoverProbe.point = contentPoint(from: location)
            case .ended:
                canvas.hoverProbe.point = nil
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
                        menuSource = nil
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if showAddMenu {
                CanvasAddMenu(
                    title: menuTitle,
                    kinds: menuKinds,
                    showsResourceGroup: menuSource == nil,
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
        // 右键：命中卡片或组就弹自绘菜单
        .onChange(of: canvas.rightClickAt) { _, point in
            guard let point else { return }
            canvas.rightClickAt = nil          // 消费掉，下次右键才能再触发
            openContextMenu(at: point)
        }
        // 点空白关菜单
        .onChange(of: canvas.selectedNodeID) { _, _ in showAddMenu = false }
        // 选中卡片时贴在它下方 20pt 出输入框。
        //
        // **挂在内容层外面**：里头有 scaleEffect，放进去输入框会跟着画布一起
        // 缩放，缩小时字都看不清。所以位置自己按 viewPoint 换算，
        // 尺寸保持不变
        .overlay(alignment: .topLeading) {
            // 文本节点也要出输入框（用文字模型生成正文），别再按类型挡了
            if let sel = canvas.selectedNodeID, let n = canvas.node(sel) {
                let anchor = viewPoint(from: CGPoint(
                    x: n.position.x + n.renderSize.width / 2,
                    // 底边跟节点视图的定位口径保持一致（见 contentLayer 里那段注释）
                    y: n.position.y + n.renderSize.height
                       - CanvasNodeView.labelHeight / 2
                       + (n.kind == .text ? CanvasNodeView.edgeStraddle / 2 : 0)))
                CanvasPromptBar(canvas: canvas, node: n)
                    .environmentObject(project)
                    .fixedSize()
                    // 卡片贴边时输入框会被画布的圆角裁掉，钳回可视区里
                    .offset(x: min(max(12, anchor.x - Self.promptBarWidth / 2),
                                   max(12, containerSize.width - Self.promptBarWidth - 12)),
                            y: min(anchor.y + 20,
                                   max(12, containerSize.height - Self.promptBarMinRoom)))
                    .transition(.opacity)
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
                CanvasAssetPicker(canvas: canvas,
                                  limitKinds: fillTargetNode.flatMap { canvas.node($0)?.kind }
                                                             .map { Set([$0]) }) { picks in
                    let asset = picks.first
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
        // 右键菜单排在**所有** overlay 最后：越靠后越上层。
        // 排在提示词栏前面的话，跟着卡片走的那条栏会把菜单下半截盖住
        .overlay {
            if ctxLocation != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { ctxLocation = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if let at = ctxLocation {
                CanvasContextPanel(canvas: canvas, targets: ctxTargets,
                                   groupID: ctxGroupID,
                                   pastePoint: contentPoint(from: at),
                                   relinkTarget: missingMediaTarget,
                                   onRelink: { id in
                                       guard let n = canvas.node(id) else { return }
                                       canvasRelinkNode(n, canvas: canvas, project: project)
                                   }) { ctxLocation = nil }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .offset(x: at.x, y: at.y)
            }
        }

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
        // 产物**不**自动进全局素材库（用户 2026-08-25 要求）：画布里生成/处理出来的东西
        // 只登记进元素库（`canvas.producedAssets`），素材库保持干净。
        // 要进素材库只有两条明路：卡片操作栏的「保存到素材库」、「添加到时间轴」。
        // 因此这些卡片没有 assetID，缩略图/波形一律走 `canvas.thumbKey(...)` 取缓存 key
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
        // 卡片上的 @：在聊天框光标处插一句「@图1」。
        // **纯粹是提示词里的一段文字，不建立连线** —— 要不要真当参考，
        // 由用户自己拉线决定
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeMention)) { note in
            guard let id = note.object as? UUID, let src = canvas.node(id) else { return }
            guard let targetID = canvas.selectedNodeID, targetID != id else {
                flashReject("先选中要写提示词的那张卡片")
                return
            }
            // 已经是上游的话用参考编号（图1/视频2…），跟聊天框里缩略图上的 @ 一致；
            // 还没连线就用卡片自己的名字
            let ups = canvas.upstreamNodes(of: targetID)
            let sameKind = ups.filter { $0.kind == src.kind }
            if let idx = sameKind.firstIndex(where: { $0.id == id }) {
                let prefix: String
                switch src.kind {
                case .image: prefix = "图"
                case .video: prefix = "视频"
                case .audio: prefix = "音频"
                case .text:  prefix = "文本"
                }
                canvas.pendingMention = "@\(prefix)\(idx + 1)"
            } else {
                let name = src.displayName.isEmpty ? src.kind.label : src.displayName
                canvas.pendingMention = "@" + name.replacingOccurrences(of: " ", with: "")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasNodeRetry)) { note in
            guard let id = note.object as? UUID, let node = canvas.node(id) else { return }
            // 按这张卡片的类型选对应的模型，不能用全局 selectedProvider ——
            // 那个可能是任何类型，用错了会报「XX 不支持 XX 生成」
            let provider = AIVideoService.provider(for: node.kind.providerCategory)
            canvas.submitGeneration(nodeID: id, provider: provider)
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
            // 产物没进素材库、assetID 是 nil，缓存要按 thumbKey 取，否则视频这里
            // 拿不到帧，只能退化成 1×1 的空图
            let key = canvas.thumbKey(assetID: n.assetID, path: n.mediaPath, fallback: n.id)
            let thumb = project.mediaThumbnails[key]
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
            // 正在输入文字时这些键都归输入框。
            //
            // **判据是我们自己维护的两个状态，不是 NSWindow.firstResponder** ——
            // 聊天框那个 NSTextView 一挂上视图层级就自动成了第一响应者，
            // 哪怕用户没点过它、界面上也没有光标。按 firstResponder 判断的话
            // editing 会永远为真，delete / ⌘Z / ⇧⌘Z 全被放行给输入框，
            // 表现就是「选中卡片按 delete 没反应」（诊断日志实测到的）
            let editing = canvas.promptBarFocused || canvas.editingTextNodeID != nil
            if event.type == .keyDown, event.keyCode == 51 || event.keyCode == 117 {
                let a = "editing=\(editing) promptFocus=\(canvas.promptBarFocused)"
                let b = "editingText=\(canvas.editingTextNodeID != nil)"
                let c = "选中=\(canvas.selectedNodeIDs.count) 组=\(canvas.selectedGroupID != nil)"
                DiagLog.log("[画布] delete " + a + " " + b + " " + c)
            }

            // ⌘Z / ⇧⌘Z 撤的是画布自己的栈，不是时间轴的
            if event.type == .keyDown,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                // 撤销没反应时靠这条判断卡在哪：被输入状态挡了，还是栈本来就是空的
                DiagLog.log("[画布] ⌘Z editing=\(editing) "
                            + "promptFocus=\(canvas.promptBarFocused) "
                            + "editingText=\(canvas.editingTextNodeID != nil) "
                            + "undo=\(canvas.undoCount) redo=\(canvas.redoCount)")
                guard !editing else { return event }
                if event.modifierFlags.contains(.shift) { canvas.redo() } else { canvas.undo() }
                return nil
            }

            // ⌘C / ⌘V。正在输入文字时不拦 —— 那时候归输入框自己复制粘贴
            if event.type == .keyDown, !editing,
               event.modifierFlags.contains(.command) {
                // 焦点在**聊天卡片的输入框**里才让给它。
                //
                // 原来只判断「是不是可编辑文本框」，而那个 NSTextView 会长期
                // 占着 firstResponder（卡片收起了也占着）—— 结果画布再也粘不了东西。
                // 现在还要求它确实落在卡片那块地方上，卡片收起时 rect 是 zero，
                // 一律归画布
                // 焦点在能编辑的文本框里就让给它，但**会话卡片要单独判断**：
                // 它那个 NSTextView 会长期霸着 firstResponder，点了画布空白
                // 也不放手，只认焦点的话画布就再也粘不了东西。
                // 节点的提示词栏、文本卡片没这毛病，焦点在就是在
                if let tv = w.firstResponder as? NSTextView, tv.isEditable,
                   let content = w.contentView {
                    let inWindow = tv.convert(tv.bounds, to: nil)
                    let inContent = content.convert(inWindow, from: nil)
                    let r = content.isFlipped
                        ? inContent
                        : CGRect(x: inContent.minX,
                                 y: content.bounds.height - inContent.maxY,
                                 width: inContent.width, height: inContent.height)
                    let isChatCard = !canvas.chatCardRect.isEmpty
                                  && canvas.chatCardRect.intersects(r)
                    if isChatCard ? canvas.chatCardFocused : true { return event }
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    let ids = canvas.selectedGroupID.map { canvas.nodeIDs(inGroup: $0) }
                              ?? canvas.selectedNodeIDs
                    guard !ids.isEmpty else { break }
                    canvas.copy(ids: ids)
                    return nil
                case "v":
                    // 画布自己复制过卡片就粘卡片；没有的话看系统剪贴板 ——
                    // 截图、访达里复制的文件、一段文字，都能直接落成卡片
                    return canvas.pasteHere() ? nil : event
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
                if event.type == .keyDown { AIInlinePlayer.shared.toggle(url, key: node.id) }
                canvas.isSpaceHeld = false
                return nil
            }
            let held = (event.type == .keyDown)
            if held != canvas.isSpaceHeld {
                canvas.isSpaceHeld = held
                // **必须禁掉窗口的 cursor rect**，光靠自己反复 set 抢不过系统：
                // 每个 AppKit/SwiftUI 控件都在自己的区域注册了光标（按钮的箭头、
                // 文本的 I 形…），鼠标一移动系统就按 cursor rect 重设一次，
                // 我们再设回手 —— 一来一回就是「手和箭头之间闪」。
                // 禁用之后这套自动重设整个停掉，光标才真正听我们的
                if held {
                    w.disableCursorRects()
                    NSCursor.openHand.set()
                    // 在键盘事件的处理周期里 set 光标，屏幕上往往要等到下一次
                    // 鼠标事件才反映出来 —— 表现就是「按下空格没反应，
                    // 鼠标动一下才变手」。补一次异步的，当场就变
                    DispatchQueue.main.async { NSCursor.openHand.set() }
                } else {
                    w.enableCursorRects()
                    NSCursor.arrow.set()
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }
            return nil   // 吞掉，免得底下的时间轴拿去播放/暂停
        }

        // 点在画布上（不是聊天卡片）就把键盘焦点从输入框收回来。
        // 不收的话它一直是 firstResponder，⌘V / delete 这些永远轮不到画布
        let focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let w = event.window,
                  WindowManager.shared.id(of: w) == windowID,
                  let content = w.contentView
            else { return event }
            let inContent = content.convert(event.locationInWindow, from: nil)
            let pt = content.isFlipped
                ? inContent
                : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
            canvas.chatCardFocused = !canvas.chatCardRect.isEmpty
                                   && canvas.chatCardRect.contains(pt)
            return event
        }

        let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let w = event.window,
                  WindowManager.shared.id(of: w) == windowID else { return event }

            // 鼠标停在文本卡片上：滚轮归那张卡片自己滚（文字可能比卡片高）。
            // 不放行的话这里会把每一个滚轮事件都吞去平移画布，
            // 卡片里的 NSTextView 一个都收不到，文字再长也滚不动。
            // ⌘+滚轮是缩放画布，那个优先级更高，不让
            if !event.modifierFlags.contains(.command), canvas.hoveredTextNodeID != nil {
                return event
            }

            // 鼠标停在右下角那张聊天卡片上：滚轮归会话自己滚。
            // 坐标换算照 GatedHostingView 那套，跟卡片报上来的 .global 对齐
            if let content = w.contentView {
                let inContent = content.convert(event.locationInWindow, from: nil)
                let pt = content.isFlipped
                    ? inContent
                    : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
                if canvas.chatCardRect.contains(pt) { return event }
            }

            // 鼠标停在素材库/元素库面板上：滚轮滚那个列表，别平移画布。
            // 这里直接驱动底层 NSScrollView，不指望把事件放行给 SwiftUI 去分发
            if !event.modifierFlags.contains(.command), canvas.scrollAssetPanelByWheel(event) {
                return nil
            }

            if event.modifierFlags.contains(.command) {
                // 锚点：事件坐标是窗口坐标、y 轴朝上；画布容器从窗口顶部往下 topGap 开始
                let winH = w.contentView?.bounds.height ?? 0
                let containerH = max(1, winH - canvas.topGap)
                let anchor = CGPoint(x: event.locationInWindow.x,
                                     y: containerH - event.locationInWindow.y)
                let containerSize = CGSize(width: w.contentView?.bounds.width ?? 0,
                                           height: containerH)
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                let factor = 1 + delta * 0.08
                canvas.setZoom(canvas.zoom * factor, anchor: anchor, containerSize: containerSize)
            } else {
                // 两种设备的滚动量根本不是一个尺度，一个系数套不住：
                // 触控板给的是**像素级**位移（hasPreciseScrollingDeltas），
                // 1:1 用就跟手；鼠标滚轮给的是行数，一格挪不了多远，得放大。
                // 原来一律乘 10，触控板上双指一滑画布就飞出去
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                canvas.offset = CGSize(width: canvas.offset.width + event.scrollingDeltaX * step,
                                       height: canvas.offset.height + event.scrollingDeltaY * step)
            }
            return nil   // 吞掉，否则时间轴的滚轮监听会跟着缩放
        }

        // 右键：自绘菜单（系统 contextMenu 排不出横着一排色点）。
        // 这里只把位置换算成画布容器坐标传出去，命中判定在画布层做
        let rightMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let w = event.window,
                  WindowManager.shared.id(of: w) == windowID else { return event }
            // 指针在素材库/元素库面板上：右键归面板自己那份菜单（重命名/移除等）。
            // 不放行的话这条 monitor 会一律吞掉，面板上的 .contextMenu 永远弹不出来
            if canvas.assetPanelHovered { return event }

            // 指针在 Agent 会话卡片上：右键归卡片里的输入框 / 消息自己。
            // 这条 monitor 是一律吞的，不放行的话会话里右键完全没反应
            if !canvas.chatCardRect.isEmpty, let content = w.contentView {
                let inContent = content.convert(event.locationInWindow, from: nil)
                let pt = content.isFlipped
                    ? inContent
                    : CGPoint(x: inContent.x, y: content.bounds.height - inContent.y)
                if canvas.chatCardRect.contains(pt) { return event }
            }

            let winH = w.contentView?.bounds.height ?? 0
            let containerH = max(1, winH - canvas.topGap)
            let viewPoint = CGPoint(x: event.locationInWindow.x, y: containerH - event.locationInWindow.y)

            // 文本卡片编辑时右键要的是系统那套拷贝/粘贴/拼写，别抢 ——
            // 但**只看 firstResponder 是不是 NSTextView 不够**：退出编辑后如果没
            // 正确交还第一响应者（曾经就踩过），或者编辑中的卡片其实在别处，
            // 右键随便点哪张卡片都会被这条一刀切放行，表现是「右键全变成系统菜单，
            // 其它卡片也右键不了」。加一道位置校验：点击处真落在正在编辑的那张
            // 卡片范围内，才放行
            if w.firstResponder is NSTextView, let editingID = canvas.editingTextNodeID,
               let node = canvas.node(editingID) {
                let cs = canvas.containerSize
                let center = CGPoint(x: cs.width / 2, y: cs.height / 2)
                let content = CGPoint(
                    x: (viewPoint.x - canvas.offset.width - center.x) / canvas.zoom + center.x,
                    y: (viewPoint.y - canvas.offset.height - center.y) / canvas.zoom + center.y)
                if node.frame.contains(content) { return event }
            }

            canvas.rightClickAt = viewPoint
            return nil
        }

        WindowManager.shared.setCanvasSpaceMonitor(keyMonitor, for: windowID)
        WindowManager.shared.setCanvasScrollMonitor(scrollMonitor, for: windowID)
        WindowManager.shared.setCanvasFocusMonitor(focusMonitor, for: windowID)
        WindowManager.shared.setCanvasRightClickMonitor(rightMonitor, for: windowID)
    }

    private func remove() {
        // 空格期间禁掉过窗口的 cursor rect，走之前一定要恢复 ——
        // 留着禁用状态，整个 app 的光标都不会再自动变了
        if canvas.isSpaceHeld {
            WindowManager.shared.window(for: windowID)?.enableCursorRects()
            NSCursor.arrow.set()
        }
        canvas.isSpaceHeld = false
        WindowManager.shared.setCanvasSpaceMonitor(nil, for: windowID)
        WindowManager.shared.setCanvasScrollMonitor(nil, for: windowID)
        WindowManager.shared.setCanvasFocusMonitor(nil, for: windowID)
        WindowManager.shared.setCanvasRightClickMonitor(nil, for: windowID)
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
    /// 鼠标位置。**只有这一层订阅它** —— 鼠标移动很频繁，
    /// 让画布层去订阅的话所有卡片会跟着一起重算
    @ObservedObject var probe: CanvasHoverProbe

    private var hoverPoint: CGPoint? { probe.point }

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
                                    ? StrokeStyle(lineWidth: 1, dash: [6, 4], dashPhase: dashPhase)
                                    : StrokeStyle(lineWidth: 1))
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
                // 从哪一侧的圆点拖出来的，线就从哪一侧起 ——
                // 写死 maxX 的话，从左边拉线会看到虚线绕到右边去起头
                let startX = canvas.pendingEdgeIsLeading ? f.minX : f.maxX
                EdgeShape(start: CGPoint(x: startX, y: f.midY), end: to)
                    .stroke(Color.accent,
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
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


