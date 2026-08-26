// CoverDesignerSheet.swift
// 项目封面设计弹窗（v5.3.0）。
//
// 三栏：左边挑底图（素材库那份数据，只列视频/图片/文字/图形），
// 中间是封面预览 + 底下的选帧轨道，右边是选中图层的属性。
// 底部取消 / 确认，确认时把封面渲染成 PNG 存到项目旁边。
//
// **不用 `.sheet`**：系统 sheet 是独立窗口，`floatingPanelMaterial` 采样不到主界面，
// 材质会变成一块不透的灰板（交接文档第 43 条）。跟导出/设置弹窗一样挂在
// ContentView 的 overlay 上。
import SwiftUI
import AppKit
import AVFoundation

struct CoverDesignerSheet: View {
    @EnvironmentObject private var project: ProjectState

    /// 编辑中的草稿。取消就整份丢掉，确认才写回 `project.cover`
    @State private var draft = ProjectCover()
    /// 左边选中的那类素材
    @State private var category: Category = .video
    @State private var keyword = ""
    /// 底图预览。选帧、换素材都会重算，放 @State 里免得每帧读盘
    @State private var baseImage: NSImage?
    /// 底图是视频时它有多长 —— 选帧轨道按它铺
    @State private var sourceDuration: Double = 0
    /// 选中的是封面上哪个图层。属性栏跟着它变
    @State private var selection: LayerRef?
    /// 钢笔绘制态。非 nil 时封面上盖一层预览区的 `PenDrawingOverlay`
    @State private var penDraftID: UUID?
    /// 拖动图层时的起始位置（相对坐标）。跟裁剪框一个道理：
    /// `translation` 是累计值，基准必须是**起手那一刻**的位置，不能拿每帧变的当前值
    @State private var dragStart: CGPoint?

    enum LayerRef: Equatable {
        case text(UUID)
        case shape(UUID)
    }

    enum Category: String, CaseIterable {
        case video = "视频", image = "图片", text = "文字", shape = "图形"

        var assetType: AssetType? {
            switch self {
            case .video: return .video
            case .image: return .image
            case .text, .shape: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sourcePane
                previewPane
                // 属性栏**常驻** —— 选中文字/图形时是那一层的属性，
                // 没选中就是底图（图片）的属性。不做成条件显示：
                // 一出一收会让中间的预览区跟着变宽变窄，看着很跳
                layerInspector
            }
            footer
        }
        // 高度 700 不是随便定的：620 时预览区只剩约 290pt 高，
        // 16:9 的封面被高度卡住、宽度撑不满，左右白白空一大块。
        // 加到 700 之后高度不再是瓶颈，横版封面能吃满整条可用宽度
        .frame(width: 980, height: 700)
        .floatingPanelMaterial()
        .onAppear { loadDraft() }
    }

    // MARK: - 顶部 / 底部

    private var header: some View {
        HStack {
            Text("项目封面")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    /// 按钮尺寸/圆角/字号和容器边距都照「导出」弹窗那套
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { close() } label: {
                Text("取消").font(.system(size: 13))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 80, height: 36)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button { confirm() } label: {
                Text("确认")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 120, height: 36)
                    .background(Color.accent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .opacity(draft.isEmpty ? 0.4 : 1)
            .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - 左：挑底图

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Category.allCases, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(category == c ? .white : Color.labelSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(category == c ? Color.white.opacity(0.15) : Color.clear)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 8)

            // 文字那一栏多一个「新建标题文字」——封面上的文字不一定来自模板
            if category == .text {
                Button { addText() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                        Text("新建标题文字").font(.system(size: 11))
                    }
                    .foregroundColor(Color.labelPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            // 搜索只给视频和图片 —— 文字是模板列表、图形就固定那八个，没什么可搜的
            if category.assetType != nil {
                searchField
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            switch category {
            case .video, .image:
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(assets) { asset in
                            sourceCell(asset)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            case .text:
                // 文字模板跟侧边栏同一份数据、同一个组件，点了往封面加
                TextLayerPanel(onPick: { tmpl in addText(from: tmpl) }, hPadding: 24)
            case .shape:
                // 八种图形也是同一个组件
                ShapePanel(onPick: { type in addShape(type) }, hPadding: 24)
            }
        }
        .frame(width: 220)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarSVGIcon.load("search"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundColor(Color.labelSecondary)
            TextField("搜索", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 列的就是素材库那份数据，只挑当前分类那几条
    private var assets: [MediaAsset] {
        guard let type = category.assetType else { return [] }
        var list = project.mediaAssets.filter { $0.type == type }
        let q = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        return list
    }

    /// 格子样式照侧边栏素材库那套来：4:3 封面 + 右上角时长 + 名字在下
    private func sourceCell(_ asset: MediaAsset) -> some View {
        let isPicked = draft.sourcePath == asset.url.path
        return Button { pick(asset) } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                        if let thumb = project.mediaThumbnails[asset.id] {
                            Color.clear.overlay(
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            )
                        } else {
                            Image(systemName: asset.type == .image ? "photo" : "film")
                                .font(.system(size: 22, weight: .ultraLight))
                                .foregroundColor(Color.labelSecondary.opacity(0.3))
                        }
                    }
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if asset.duration > 0 {
                        Text(String(format: "%02d:%02d", Int(asset.duration) / 60,
                                    Int(asset.duration) % 60))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accent.opacity(isPicked ? 1 : 0), lineWidth: 2))

                Text(asset.name)
                    .font(.system(size: 11))
                    .foregroundColor(asset.fileExists ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
            }
            .padding(4)
        }
        .buttonStyle(.plain)
        .help(asset.name)
    }

    // MARK: - 中：封面预览

    private var previewPane: some View {
        VStack(spacing: 0) {
            // 右上角：上传图片 + 缩放，跟画布卡片那排浮动按钮一个位置
            HStack(spacing: 6) {
                Spacer()
                Button { uploadImage() } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: SidebarSVGIcon.load("importFile", size: 12))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                        Text("上传图片").font(.system(size: 11))
                    }
                    .foregroundColor(Color.labelPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("上传一张图片当封面，同时收进素材库")
            }
            // 中间这栏自己一套边距：**16**，跟下面封面框、选帧轨道的留白一致。
            // 左右两栏用 24（跟弹窗标题对齐），中间窄一点让封面更大
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // 6pt 让预览框的上边缘跟左栏搜索框的上边缘齐平
            // （左栏：12 顶 + 24 标签 + 8 间距 = 44；这边：12 顶 + 26 工具栏 + 6 = 44）
            Spacer().frame(height: 6)

            GeometryReader { geo in
                let box = fitSize(in: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                    if let img = baseImage {
                        // **缩放只作用在画面上，不改框的大小** ——
                        // 乘进 frame 里的话放大就直接溢出到弹窗外面（实测盖住了左栏）
                        // 底图的位置/缩放/旋转/镜像/裁剪/色调，都跟外面图片片段那套属性对齐。
                        // 裁剪用 mask 掉四条边（值是 0~1 的比例，跟片段一致）；
                        // 色调直接用 SwiftUI 的滤镜，参数区间跟 ColorAdjust 对齐
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: box.width, height: box.height)
                            .scaleEffect(x: draft.baseScale * (draft.baseMirrorH ? -1 : 1),
                                         y: draft.baseScale * (draft.baseMirrorV ? -1 : 1))
                            .rotationEffect(.degrees(draft.baseRotation))
                            .offset(x: box.width * draft.baseOffsetX,
                                    y: box.height * draft.baseOffsetY)
                            .brightness(draft.colorAdjust.brightness)
                            .contrast(1 + draft.colorAdjust.contrast)
                            .saturation(1 + draft.colorAdjust.saturation)
                            .hueRotation(.degrees(draft.colorAdjust.hue))
                            .mask(
                                Rectangle()
                                    .padding(.top, box.height * draft.cropTop)
                                    .padding(.bottom, box.height * draft.cropBottom)
                                    .padding(.leading, box.width * draft.cropLeft)
                                    .padding(.trailing, box.width * draft.cropRight)
                            )
                            .clipped()
                    } else {
                        VStack(spacing: 12) {
                            Image(nsImage: SidebarSVGIcon.load("image", size: 48))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                                .foregroundColor(Color.labelSecondary.opacity(0.35))
                            Text("选择视频或图片素材截取图片或上传图片制作封面")
                                .font(.system(size: 12))
                                .foregroundColor(Color.labelSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }
                    // 叠在封面上的文字和图形。点选、拖动都在这一层
                    ForEach(draft.shapes) { shape in
                        coverShape(shape, box: box)
                    }
                    ForEach(draft.texts) { text in
                        coverText(text, box: box)
                    }

                    // 钢笔：**用的就是预览区那一层** PenDrawingOverlay，
                    // 点击落点、拖出控制柄、回到起点闭合、回车结束全都一样。
                    // 封面框和预览一样按项目比例走，所以它内部那套
                    // previewRenderSize 坐标换算原样能用
                    if let draftID = penDraftID {
                        PenDrawingOverlay(forcedClipID: draftID) { pts, closed in
                            finishPenDrawing(rawPoints: pts, closed: closed)
                        }
                        .frame(width: box.width, height: box.height)
                    }
                }
                .frame(width: box.width, height: box.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                // 点空白处取消选中
                .onTapGesture { selection = nil }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            Spacer(minLength: 8)

            // 选帧轨道：底图是视频才有。**位置一直留着** ——
            // 有没有轨道都占同样高度，否则选中视频前后预览框会一大一小
            Group {
                if sourceDuration > 0, let path = draft.sourcePath {
                    CoverFrameStrip(url: URL(fileURLWithPath: path),
                                    duration: sourceDuration,
                                    time: Binding(
                                        get: { draft.frameTime },
                                        set: { draft.frameTime = $0; reloadBaseImage() }
                                    ))
                } else {
                    Color.clear
                }
            }
            .frame(height: 54)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// 封面框：按项目比例塞进可用区域。**跟 zoom 无关** ——
    /// 框是固定的，放大只是把画面放大、超出部分裁掉
    private func fitSize(in container: CGSize) -> CGSize {
        let s = project.previewRenderSize
        let ratio = (s.width > 0 && s.height > 0) ? s.width / s.height : 16.0 / 9.0
        // 左右各 8、上下各 4：这栏就是给封面看的，留白压到最小让画面尽量大。
        // 真正决定封面多大的往往是**高度**（上有工具栏、下有选帧轨道），
        // 高度一到顶宽度就上不去，剩下的全变成左右留白
        let maxW = max(80, container.width - 16)
        let maxH = max(60, container.height - 8)
        let w = min(maxW, maxH * ratio)
        return CGSize(width: w, height: w / ratio)
    }

    private var frameStrip: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { draft.frameTime },
                set: { draft.frameTime = $0; reloadBaseImage() }
            ), in: 0...max(sourceDuration, 0.1))
            .controlSize(.small)
            Text(String(format: "%02d:%05.2f", Int(draft.frameTime) / 60,
                        draft.frameTime.truncatingRemainder(dividingBy: 60)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Color.labelSecondary)
        }
    }

    /// 纯图标按钮，**不加底色** —— 跟时间轴那排缩放按钮一样是裸图标
    // MARK: - 封面上的图层（文字 / 图形）

    /// 一条文字。位置是 0~1 的相对坐标，跟时间轴那套一致，
    /// 字号按封面实际宽度换算 —— 预览缩小了字也要跟着缩小，否则所见非所得
    @ViewBuilder
    private func coverText(_ t: TextClip, box: CGSize) -> some View {
        let picked = selection == .text(t.id)
        let scale = box.width / max(project.previewRenderSize.width, 1)
        Text(t.text)
            .font(.system(size: t.fontSize * scale,
                          weight: t.bold ? .bold : .regular))
            .italic(t.italic)
            .foregroundColor(t.textColor)
            .opacity(t.opacity)
            .rotationEffect(.degrees(t.rotation))
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accent.opacity(picked ? 0.9 : 0), lineWidth: 1))
            .position(x: box.width * t.posX, y: box.height * t.posY)
            .onTapGesture { selection = .text(t.id) }
            .gesture(dragGesture(for: .text(t.id), box: box,
                                 current: CGPoint(x: t.posX, y: t.posY)))
    }

    @ViewBuilder
    private func coverShape(_ sh: ShapeClip, box: CGSize) -> some View {
        let picked = selection == .shape(sh.id)
        let scale = box.width / max(project.previewRenderSize.width, 1)
        let w = sh.width * sh.scaleX * scale
        let h = sh.height * sh.scaleY * scale
        CoverShapeBody(shape: sh)
            .frame(width: max(4, w), height: max(4, h))
            .opacity(sh.opacity)
            .rotationEffect(.degrees(sh.rotation))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accent.opacity(picked ? 0.9 : 0), lineWidth: 1))
            .position(x: box.width * sh.posX, y: box.height * sh.posY)
            .onTapGesture { selection = .shape(sh.id) }
            .gesture(dragGesture(for: .shape(sh.id), box: box,
                                 current: CGPoint(x: sh.posX, y: sh.posY)))
    }

    /// 拖动图层。基准记的是**起手那一刻**的位置 —— `translation` 是累计位移，
    /// 每帧拿当前位置再加一次会越拖越快（裁剪框踩过这个坑）
    private func dragGesture(for ref: LayerRef, box: CGSize, current: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = current; selection = ref }
                let base = dragStart ?? current
                let nx = (base.x + v.translation.width / box.width).clamped(to: 0...1)
                let ny = (base.y + v.translation.height / box.height).clamped(to: 0...1)
                switch ref {
                case .text(let id):
                    if let i = draft.texts.firstIndex(where: { $0.id == id }) {
                        draft.texts[i].posX = nx
                        draft.texts[i].posY = ny
                    }
                case .shape(let id):
                    if let i = draft.shapes.firstIndex(where: { $0.id == id }) {
                        draft.shapes[i].posX = nx
                        draft.shapes[i].posY = ny
                    }
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - 右栏：图层属性

    /// 照搬属性区那套控件，但**去掉时间相关的字段** ——
    /// 封面是一张静止的图，开始/持续/动画在这儿没有意义
    @ViewBuilder
    private var layerInspector: some View {
        ScrollView(showsIndicators: false) {
            // spacing 收到 2：ISection 自己带上下留白，再叠 10 就散得厉害
            VStack(alignment: .leading, spacing: 2) {
                switch selection {
                case .text(let id):
                    if let i = draft.texts.firstIndex(where: { $0.id == id }) {
                        paneTitle("文字") { draft.texts.remove(at: i); selection = nil }
                        textInspector(i)
                    }
                case .shape(let id):
                    if let i = draft.shapes.firstIndex(where: { $0.id == id }) {
                        paneTitle("图形") { draft.shapes.remove(at: i); selection = nil }
                        shapeInspector(i)
                    }
                case .none:
                    paneTitle("图片") { clearBase() }
                    baseInspector
                }
            }
            // **内容宽度写死 220，右边留 10 给滚动条**。
            //
            // 图片那栏内容短不滚动、文字图形内容长要滚动，滚动条一占位就把内容
            // 挤窄，切换时整栏往左跳几个像素（实测 6px）。让内容宽度跟滚动条
            // 出没无关，位置才稳得住。
            //
            // 对齐关系：左 10 + ISection 自带的 14 = 24，跟弹窗标题同一条线；
            // 右边内容边缘 = 10 + 220 - 14 = 216，距整栏右缘也正好 24，
            // 删除图标就跟右上角 ✕、底部确认按钮对齐了
            .padding(.vertical, 10)
            .frame(width: Self.inspectorWidth - 20, alignment: .leading)
            .padding(.leading, 10)
        }
        .scrollIndicators(.hidden)
        .frame(width: Self.inspectorWidth)
    }

    /// 属性栏宽度。三种属性（图片/文字/图形）共用这一个数
    static let inspectorWidth: CGFloat = 240

    /// 属性栏顶部的标题行，**右边是删除**：文字/图形删自己，图片删的是底图
    private func paneTitle(_ title: String, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
            Spacer()
            Button(action: onDelete) {
                Image(nsImage: TimelineSVGIcon.load("delete"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundColor(Color.labelSecondary)
                    // 热区仍是 24，但**图标贴右** —— 居中的话图标右边缘会比
                    // 下面那些滑块行的右边缘往里缩 5pt，看着就是没对齐
                    .frame(width: 24, height: 24, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        // 补上 ISection 那份 14，标题就跟下面各段的内容左右对齐了
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// 清掉底图，回到「还没选素材」的状态
    private func clearBase() {
        draft.sourcePath = nil
        draft.frameTime = 0
        baseImage = nil
        sourceDuration = 0
    }

    /// 底图（图片）的属性。字段跟**图片片段**那套对齐：
    /// 变换（镜像/旋转，用同一套图标）、位置、缩放、裁剪、色调、描边
    @ViewBuilder
    private var baseInspector: some View {
        if draft.sourcePath == nil {
            Text("先选一张图片或视频")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.6))
        } else {
            ISection(title: "变换") {
                HStack(spacing: 8) {
                    canvasBtn("mirrorH", label: "水平镜像", active: draft.baseMirrorH) {
                        draft.baseMirrorH.toggle()
                    }
                    canvasBtn("mirrorV", label: "垂直镜像", active: draft.baseMirrorV) {
                        draft.baseMirrorV.toggle()
                    }
                    canvasBtn("rotate", label: "旋转90°", active: draft.baseRotation != 0) {
                        draft.baseRotation = (draft.baseRotation + 90).truncatingRemainder(dividingBy: 360)
                    }
                }
            }

            ISection(title: "位置") {
                ISlider(label: "水平位置", value: Binding(
                    get: { draft.baseOffsetX * 100 }, set: { draft.baseOffsetX = $0 / 100 }
                ), range: -100...100, unit: "%", labelWidth: 44)
                ISlider(label: "垂直位置", value: Binding(
                    get: { draft.baseOffsetY * 100 }, set: { draft.baseOffsetY = $0 / 100 }
                ), range: -100...100, unit: "%", labelWidth: 44)
            }

            ISection(title: "缩放与旋转") {
                ISlider(label: "缩放", value: Binding(
                    get: { draft.baseScale * 100 }, set: { draft.baseScale = $0 / 100 }
                ), range: 20...400, unit: "%", labelWidth: 44)
                ISlider(label: "旋转", value: $draft.baseRotation, range: -180...180, unit: "°", labelWidth: 44)
            }

            ISection(title: "裁剪") {
                ISlider(label: "上", value: Binding(
                    get: { draft.cropTop * 100 }, set: { draft.cropTop = $0 / 100 }
                ), range: 0...90, unit: "%", labelWidth: 44)
                ISlider(label: "下", value: Binding(
                    get: { draft.cropBottom * 100 }, set: { draft.cropBottom = $0 / 100 }
                ), range: 0...90, unit: "%", labelWidth: 44)
                ISlider(label: "左", value: Binding(
                    get: { draft.cropLeft * 100 }, set: { draft.cropLeft = $0 / 100 }
                ), range: 0...90, unit: "%", labelWidth: 44)
                ISlider(label: "右", value: Binding(
                    get: { draft.cropRight * 100 }, set: { draft.cropRight = $0 / 100 }
                ), range: 0...90, unit: "%", labelWidth: 44)
            }

            ISection(title: "色调") {
                ICapsuleSlider(label: "亮度", value: $draft.colorAdjust.brightness,
                               range: -1...1, decimals: 2, labelWidth: 44)
                ICapsuleSlider(label: "对比", value: $draft.colorAdjust.contrast,
                               range: -1...1, decimals: 2, labelWidth: 44)
                ICapsuleSlider(label: "饱和", value: $draft.colorAdjust.saturation,
                               range: -1...1, decimals: 2, labelWidth: 44)
                ICapsuleSlider(label: "色相", value: $draft.colorAdjust.hue,
                               range: -180...180, unit: "°", labelWidth: 44)
            }

            ISection(title: "描边") {
                colorRow("颜色", Binding(
                    get: { Color(hex: draft.strokeColorHex ?? "#FFFFFF") },
                    set: { draft.strokeColorHex = $0.toHex() }
                ))
                ICapsuleSlider(label: "宽度", value: Binding(
                    get: { draft.strokeWidth ?? 0 }, set: { draft.strokeWidth = $0 }
                ), range: 0...20, decimals: 1, unit: "px", labelWidth: 44)
                ICapsuleSlider(label: "柔和", value: Binding(
                    get: { draft.strokeSoftness ?? 0 }, set: { draft.strokeSoftness = $0 }
                ), range: 0...1, decimals: 2, labelWidth: 44)
            }

            ISection(title: nil) {
                Button {
                    draft.baseOffsetX = 0; draft.baseOffsetY = 0
                    draft.baseScale = 1; draft.baseRotation = 0
                    draft.baseMirrorH = false; draft.baseMirrorV = false
                    draft.cropTop = 0; draft.cropBottom = 0
                    draft.cropLeft = 0; draft.cropRight = 0
                    draft.colorAdjust = .identity
                    draft.strokeWidth = 0
                } label: {
                    HStack { Spacer(); Text("全部重置"); Spacer() }
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 变换那三个按钮，用属性区同一套时间轴图标
    private func canvasBtn(_ icon: String, label: String, active: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: TimelineSVGIcon.load(icon))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(label).font(.system(size: 9))
            }
            .foregroundColor(active ? .black : Color.labelSecondary)
            // 等分撑满，不写死 58 —— 三个 58 加两道间距是 190，
            // 内容区只有 192，余量 2px，字体或间距稍有变化就溢出、把整栏顶宽
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(active ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    /// 文字属性。字段跟**文字片段**一致，按要求**去掉时间和入场动画**
    @ViewBuilder
    private func textInspector(_ i: Int) -> some View {
        ISection(title: "文字内容") {
            TextEditor(text: $draft.texts[i].text)
                .font(.system(size: 13))
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
        }

        ISection(title: "字体") {
            HStack(alignment: .bottom, spacing: 8) {
                IField(label: "字体") {
                    IPicker(selection: $draft.texts[i].fontName, options: FontHelper.fontOptions)
                }
                IField(label: "字号") {
                    MiniStepper(value: Binding(
                        get: { Double(draft.texts[i].fontSize) },
                        set: { draft.texts[i].fontSize = CGFloat($0) }
                    ), step: 1, decimals: 0, minValue: 8, maxValue: 300)
                }.frame(width: 92)
            }
            HStack(spacing: 8) {
                styleToggle("粗体", isOn: draft.texts[i].bold) { draft.texts[i].bold.toggle() }
                styleToggle("斜体", isOn: draft.texts[i].italic) { draft.texts[i].italic.toggle() }
                Spacer()
            }
            .padding(.top, 6)
        }

        ISection(title: "颜色与描边") {
            colorRow("文字颜色", $draft.texts[i].textColor)
            colorRow("描边颜色", $draft.texts[i].strokeColor)
            ISlider(label: "描边宽度", value: $draft.texts[i].strokeWidth, range: 0...10, unit: "px", labelWidth: 44)
            colorRow("背景颜色", $draft.texts[i].bgColor)
            ISlider(label: "不透明度", value: Binding(
                get: { draft.texts[i].bgOpacity * 100 }, set: { draft.texts[i].bgOpacity = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
        }

        ISection(title: "位置与变换") {
            ISlider(label: "水平位置", value: Binding(
                get: { draft.texts[i].posX * 100 }, set: { draft.texts[i].posX = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
            ISlider(label: "垂直位置", value: Binding(
                get: { draft.texts[i].posY * 100 }, set: { draft.texts[i].posY = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
            ISlider(label: "旋转", value: $draft.texts[i].rotation, range: -180...180, unit: "°", labelWidth: 44)
            ISlider(label: "不透明度", value: Binding(
                get: { draft.texts[i].opacity * 100 }, set: { draft.texts[i].opacity = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
            HStack(spacing: 12) {
                Text("对齐方式").font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 44, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach([("alignLeft", "left"), ("alignVCenter", "center"),
                             ("alignRight", "right")], id: \.1) { svg, val in
                        Button { draft.texts[i].alignment = val } label: {
                            Image(nsImage: SidebarSVGIcon.load(svg))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                                .foregroundColor(draft.texts[i].alignment == val
                                                 ? Color.accent : Color.labelSecondary)
                                .frame(width: 34, height: 26)
                                .background(draft.texts[i].alignment == val
                                            ? Color.accent.opacity(0.15) : Color.white.opacity(0.05))
                                .cornerRadius(5)
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }

    }

    /// 图形属性。字段跟**图形片段**一致，按要求**去掉片段信息和时间**
    @ViewBuilder
    private func shapeInspector(_ i: Int) -> some View {
        ISection(title: "大小与位置") {
            HStack(spacing: 8) {
                Text("锁定比例").font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)
                Spacer(minLength: 0)
                Toggle("", isOn: $draft.shapes[i].lockAspect)
                    .inspectorSwitch()
            }
            if draft.shapes[i].lockAspect {
                ISlider(label: "缩放", value: Binding(
                    get: { draft.shapes[i].scaleX * 100 },
                    set: { draft.shapes[i].scaleX = $0 / 100; draft.shapes[i].scaleY = $0 / 100 }
                ), range: 5...400, unit: "%", labelWidth: 44)
            } else {
                ISlider(label: "宽度缩放", value: Binding(
                    get: { draft.shapes[i].scaleX * 100 }, set: { draft.shapes[i].scaleX = $0 / 100 }
                ), range: 5...400, unit: "%", labelWidth: 44)
                ISlider(label: "高度缩放", value: Binding(
                    get: { draft.shapes[i].scaleY * 100 }, set: { draft.shapes[i].scaleY = $0 / 100 }
                ), range: 5...400, unit: "%", labelWidth: 44)
            }
            ISlider(label: "水平位置", value: Binding(
                get: { draft.shapes[i].posX * 100 }, set: { draft.shapes[i].posX = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
            ISlider(label: "垂直位置", value: Binding(
                get: { draft.shapes[i].posY * 100 }, set: { draft.shapes[i].posY = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
            ISlider(label: "旋转", value: $draft.shapes[i].rotation, range: -180...180, unit: "°", labelWidth: 44)
            ISlider(label: "不透明度", value: Binding(
                get: { draft.shapes[i].opacity * 100 }, set: { draft.shapes[i].opacity = $0 / 100 }
            ), range: 0...100, unit: "%", labelWidth: 44)
        }

        ISection(title: "填充") {
            HStack(spacing: 8) {
                Text("启用填充").font(.system(size: 11)).foregroundColor(Color.labelSecondary)
                Spacer(minLength: 0)
                Toggle("", isOn: $draft.shapes[i].fillEnabled)
                    .inspectorSwitch()
            }
            if draft.shapes[i].fillEnabled {
                colorRow("颜色", $draft.shapes[i].fillColor)
                ISlider(label: "不透明度", value: Binding(
                    get: { draft.shapes[i].fillOpacity * 100 },
                    set: { draft.shapes[i].fillOpacity = $0 / 100 }
                ), range: 0...100, unit: "%", labelWidth: 44)
            }
        }

        ISection(title: "描边") {
            HStack(spacing: 8) {
                Text("启用描边").font(.system(size: 11)).foregroundColor(Color.labelSecondary)
                Spacer(minLength: 0)
                Toggle("", isOn: $draft.shapes[i].strokeEnabled)
                    .inspectorSwitch()
            }
            if draft.shapes[i].strokeEnabled {
                colorRow("颜色", $draft.shapes[i].strokeColor)
                ISlider(label: "粗细", value: $draft.shapes[i].strokeWidth, range: 1...30, unit: "px", labelWidth: 44)
                ISlider(label: "不透明度", value: Binding(
                    get: { draft.shapes[i].strokeOpacity * 100 },
                    set: { draft.shapes[i].strokeOpacity = $0 / 100 }
                ), range: 0...100, unit: "%", labelWidth: 44)
            }
        }

    }

    // MARK: 属性区里的小控件（样式照 InspectorView 那套）

    private func colorRow(_ label: String, _ binding: Binding<Color>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: 0)
            // 颜色块靠右，跟滑块那些行的右边缘对齐
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
        }
    }

    private func styleToggle(_ label: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .black : Color.labelSecondary)
                .padding(.horizontal, 14).frame(height: 26)
                .background(isOn ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func inspectorHeader(_ title: String, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
            Spacer()
            Button(action: onDelete) {
                Image(nsImage: TimelineSVGIcon.load("delete", size: 12))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从封面移除")
        }
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10))
            .foregroundColor(Color.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleChip(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 11, weight: on ? .bold : .regular))
                .foregroundColor(on ? .white : Color.labelSecondary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(on ? 0.18 : 0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, timeline: Bool = false,
                            tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: timeline ? TimelineSVGIcon.load(icon, size: 13)
                                    : SidebarSVGIcon.load(icon, size: 13))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .foregroundColor(Color.labelSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: - 动作

    private func loadDraft() {
        draft = project.cover ?? ProjectCover()
        reloadBaseImage()
    }

    private func pick(_ asset: MediaAsset) {
        draft.sourcePath = asset.url.path
        draft.frameTime = 0
        reloadBaseImage()
    }

    private func addText() {
        var t = TextClip(startTime: 0, endTime: 5)
        t.text = "标题文字"
        draft.texts.append(t)
    }

    /// 套模板往封面加一条文字
    private func addText(from tmpl: TextTemplate) {
        var t = TextClip(startTime: 0, endTime: 5)
        t.text = tmpl.name.isEmpty ? "标题文字" : tmpl.name
        draft.texts.append(t)
    }

    private func addShape(_ type: ShapeType) {
        guard type != .pen else { startPenDrawing(); return }
        draft.shapes.append(ShapeClip(type: type, startTime: 0, endTime: 5))
    }

    /// 钢笔：进绘制态，交给预览区那层 `PenDrawingOverlay` 去画。
    ///
    /// 这里**先不建图形** —— 画的过程中点都存在 `project.penRawPoints` 里，
    /// 画完了才按包围盒生成一条图形。半路取消就什么也不留
    private func startPenDrawing() {
        penDraftID = UUID()
        selection = nil
        project.penRawPoints = []
        project.penDrawingMode = true
    }

    /// 画完了。包围盒的算法跟时间轴那条钢笔完全一样
    /// （见 `ProjectState.finalizePenDrawing`），这样两边画出来的图形一致
    private func finishPenDrawing(rawPoints: [(x: Double, y: Double, cInDX: Double, cInDY: Double,
                                               cOutDX: Double, cOutDY: Double, smooth: Bool)],
                                  closed: Bool) {
        defer { penDraftID = nil }
        guard rawPoints.count >= 2 else { return }

        let allX = rawPoints.flatMap { p in [p.x, p.x + p.cInDX, p.x + p.cOutDX] }
        let allY = rawPoints.flatMap { p in [p.y, p.y + p.cInDY, p.y + p.cOutDY] }
        let pad = 4.0
        let bx = allX.min()! - pad, by = allY.min()! - pad
        let bw = max(allX.max()! - allX.min()! + pad * 2, 8)
        let bh = max(allY.max()! - allY.min()! + pad * 2, 8)

        var sh = ShapeClip(type: .pen, startTime: 0, endTime: 5)
        sh.width = bw
        sh.height = bh
        sh.posX = (bx + bw / 2) / max(Double(project.previewRenderSize.width), 1)
        sh.posY = (by + bh / 2) / max(Double(project.previewRenderSize.height), 1)
        sh.penPoints = rawPoints.map { p in
            PenPoint(x: (p.x - bx) / bw, y: (p.y - by) / bh,
                     ctrlInDX: p.cInDX / bw, ctrlInDY: p.cInDY / bh,
                     ctrlOutDX: p.cOutDX / bw, ctrlOutDY: p.cOutDY / bh,
                     smooth: p.smooth)
        }
        sh.penClosed = closed
        if closed { sh.fillEnabled = true; sh.fillColor = .white; sh.fillOpacity = 0.3 }
        draft.shapes.append(sh)
        selection = .shape(sh.id)
    }

    private func uploadImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选一张图片作为封面"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 顺手收进素材库（图片标签下），下次不用再从硬盘里翻
        project.importFile(url)
        draft.sourcePath = url.path
        draft.frameTime = 0
        reloadBaseImage()
    }

    /// 重算底图。视频按 `frameTime` 抽帧，图片直接读
    private func reloadBaseImage() {
        guard let path = draft.sourcePath else {
            baseImage = nil
            sourceDuration = 0
            return
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"].contains(ext)
        if isImage {
            sourceDuration = 0
            baseImage = NSImage(contentsOf: url)
            return
        }
        let at = draft.frameTime
        Task.detached {
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 1280)
            let time = CMTime(seconds: max(0, at), preferredTimescale: 600)
            let cg = try? gen.copyCGImage(at: time, actualTime: nil)
            let img = cg.map { NSImage(cgImage: $0, size: .zero) }
            await MainActor.run {
                if dur.isFinite, dur > 0 { sourceDuration = dur }
                if let img { baseImage = img }
            }
        }
    }

    private func close() {
        // 画到一半就关弹窗：绘制态是挂在 project 上的，不复位的话
        // 回到主界面预览区会莫名其妙进钢笔态
        if penDraftID != nil {
            penDraftID = nil
            project.penRawPoints = []
            project.penDrawingMode = false
        }
        project.showCoverDesigner = false
    }

    /// 确认：把预览渲染成 PNG 存到项目旁边，路径记进项目文件
    private func confirm() {
        draft.renderedPath = renderCover()
        project.cover = draft
        project.isSaved = false
        project.scheduleAutoSave()
        close()
    }

    /// 底图按属性处理一遍：裁剪 → 色调 → 描边。
    ///
    /// 走 CIImage，跟片段导出那条路一致（描边直接复用 `ImageStroke`），
    /// 这样确认出来的图和预览看到的是一套参数
    private func processedBase() -> NSImage? {
        guard let base = baseImage else { return nil }
        guard let tiff = base.tiffRepresentation,
              var ci = CIImage(data: tiff) else { return base }

        // 裁剪：按比例裁掉四条边
        let ext = ci.extent
        if draft.cropTop > 0 || draft.cropBottom > 0 || draft.cropLeft > 0 || draft.cropRight > 0 {
            // CIImage 是 y-up，`cropTop` 裁的是画面上方 → 对应 maxY 那侧
            let rect = CGRect(x: ext.minX + ext.width * draft.cropLeft,
                              y: ext.minY + ext.height * draft.cropBottom,
                              width: ext.width * (1 - draft.cropLeft - draft.cropRight),
                              height: ext.height * (1 - draft.cropTop - draft.cropBottom))
            if rect.width > 1, rect.height > 1 { ci = ci.cropped(to: rect) }
        }

        // 色调：参数区间跟 ColorAdjust 一致
        let ca = draft.colorAdjust
        if ca != .identity {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: ca.brightness,
                kCIInputContrastKey: 1 + ca.contrast,
                kCIInputSaturationKey: 1 + ca.saturation
            ])
            if abs(ca.hue) > 0.01 {
                ci = ci.applyingFilter("CIHueAdjust",
                                       parameters: [kCIInputAngleKey: ca.hue * .pi / 180])
            }
        }

        // 描边：跟图片片段共用 ImageStroke，预览/导出一套实现
        if let w = draft.strokeWidth, w > 0.01 {
            ci = ImageStroke.apply(to: ci, width: w,
                                   color: Color(hex: draft.strokeColorHex ?? "#FFFFFF"),
                                   softness: draft.strokeSoftness ?? 0)
        }

        let rep = NSCIImageRep(ciImage: ci)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    /// 把叠在上面的图形和文字画进去。
    ///
    /// **坐标要翻**：`posY` 是 0=顶部（跟预览、时间轴一致），
    /// 而 `lockFocus` 的画布是 y 朝上、原点在左下 —— 不翻的话上下颠倒
    private func drawLayers(in size: CGSize) {
        for sh in draft.shapes {
            let w = sh.width * sh.scaleX
            let h = sh.height * sh.scaleY
            let cx = size.width * sh.posX
            let cy = size.height * (1 - sh.posY)      // 翻 y
            let rect = NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            // 钢笔按锚点连线画，其余按外接矩形。
            // 不分开的话钢笔图形导出来会变成一个方块
            let path: NSBezierPath
            if sh.type == .pen, let pts = sh.penPoints, pts.count >= 2 {
                let bp = NSBezierPath()
                // 锚点的 y 是 0=上，AppKit 画布 y 朝上，所以要翻过来
                func point(_ p: PenPoint) -> NSPoint {
                    NSPoint(x: rect.minX + p.x * rect.width,
                            y: rect.maxY - p.y * rect.height)
                }
                bp.move(to: point(pts[0]))
                for i in 1..<pts.count { bp.line(to: point(pts[i])) }
                if sh.penClosed { bp.close() }
                path = bp
            } else {
                path = NSBezierPath(rect: rect)
            }
            if sh.fillEnabled {
                NSColor(sh.fillColor).withAlphaComponent(sh.fillOpacity * sh.opacity).setFill()
                path.fill()
            }
            if sh.strokeEnabled {
                NSColor(sh.strokeColor).withAlphaComponent(sh.strokeOpacity * sh.opacity).setStroke()
                path.lineWidth = max(1, sh.strokeWidth)
                path.stroke()
            }
        }

        for t in draft.texts {
            let font = NSFont.systemFont(ofSize: t.fontSize, weight: t.bold ? .bold : .regular)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(t.textColor).withAlphaComponent(t.opacity)
            ]
            if t.strokeWidth > 0 {
                attrs[.strokeColor] = NSColor(t.strokeColor)
                // 负值 = 描边同时保留填充，正值只描边不填
                attrs[.strokeWidth] = -t.strokeWidth
            }
            let str = NSAttributedString(string: t.text, attributes: attrs)
            let bounds = str.size()
            let cx = size.width * t.posX
            let cy = size.height * (1 - t.posY)       // 翻 y
            str.draw(at: NSPoint(x: cx - bounds.width / 2, y: cy - bounds.height / 2))
        }
    }

    /// 把当前封面画成 PNG。存在项目文件旁边的 `.封面` 目录里，
    /// 记的是相对路径 —— 项目整个拷到别的机器也还找得到
    private func renderCover() -> String? {
        let size = project.previewRenderSize
        guard size.width > 0, size.height > 0 else { return nil }
        // 底图可以没有 —— 纯文字/图形做的封面也算数，那就画在黑底上
        guard baseImage != nil || !draft.texts.isEmpty || !draft.shapes.isEmpty else { return nil }

        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        // 按 fill 的方式铺满，跟预览里看到的一致
        if let base = processedBase() {
            let bs = base.size
            if bs.width > 0, bs.height > 0 {
                // 先按 fill 铺满，再套上属性区那几个变换 —— 顺序要跟预览一致，
                // 否则确认出来的图跟看到的不是一回事
                let fit = max(size.width / bs.width, size.height / bs.height)
                let w = bs.width * fit * draft.baseScale
                let h = bs.height * fit * draft.baseScale
                let ctx = NSGraphicsContext.current?.cgContext
                ctx?.saveGState()
                // 画布是 y 朝上，偏移的 y 要反号才跟预览一个方向
                ctx?.translateBy(x: size.width / 2 + size.width * draft.baseOffsetX,
                                 y: size.height / 2 - size.height * draft.baseOffsetY)
                ctx?.rotate(by: -draft.baseRotation * .pi / 180)
                ctx?.scaleBy(x: draft.baseMirrorH ? -1 : 1, y: draft.baseMirrorV ? -1 : 1)
                base.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx?.restoreGState()
            }
        }
        drawLayers(in: size)
        out.unlockFocus()

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dir = (project.projectFileURL?.deletingLastPathComponent()
                   ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(".封面", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cover-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: file)
        } catch {
            DiagLog.log("[封面] 写文件失败 \(error.localizedDescription)")
            return nil
        }
        return ".封面/" + file.lastPathComponent
    }
}

// MARK: - 选帧轨道

/// 底图是视频时，底下那条缩略图轨道。点哪儿、拖到哪儿，封面就取那一帧。
///
/// 帧数按可用宽度算，**只抽一次**（`loadedFor` 记着为哪个 url/宽度抽的），
/// 拖动过程中不重抽 —— 每拖一像素抽一轮的话会把解码器打满
private struct CoverFrameStrip: View {
    let url: URL
    let duration: Double
    @Binding var time: Double

    @State private var frames: [NSImage] = []
    @State private var loadedFor: String = ""

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = geo.size.height
            let count = max(4, Int(w / (h * 16.0 / 9.0)))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))

                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        ZStack {
                            Color.black.opacity(0.25)
                            if i < frames.count {
                                Image(nsImage: frames[i])
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: w / CGFloat(count), height: h)
                        .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // 播放头：一条竖线 + 顶部把手，跟时间轴那根一个意思
                let x = w * CGFloat(duration > 0 ? time / duration : 0)
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: 2, height: h)
                    .offset(x: min(max(0, x - 1), w - 2))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                // 点哪儿跳哪儿、拖着连续走。**用落点算**不用累计位移，
                // 所以不需要记起始值
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let ratio = (v.location.x / w).clamped(to: 0...1)
                        time = duration * Double(ratio)
                    }
            )
            .task(id: "\(url.path)|\(count)") {
                let key = "\(url.path)|\(count)"
                guard loadedFor != key else { return }
                loadedFor = key
                frames = await Self.extract(url: url, duration: duration, count: count)
            }
        }
    }

    /// 均匀抽 `count` 帧。宽度限死 240，够铺一条 54pt 高的轨道了
    private static func extract(url: URL, duration: Double, count: Int) async -> [NSImage] {
        await Task.detached(priority: .userInitiated) { () -> [NSImage] in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 240)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var out: [NSImage] = []
            for i in 0..<count {
                let t = duration * Double(i) / Double(max(1, count - 1))
                let time = CMTime(seconds: max(0, min(t, duration - 0.05)), preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                    out.append(NSImage(cgImage: cg, size: .zero))
                }
            }
            return out
        }.value
    }
}

// MARK: - 图形的画法

/// 把 `ShapeClip` 画出来。只画封面用得到的那几种，
/// 钢笔那种自由路径封面里用不上（它靠时间轴上画出来的点）
private struct CoverShapeBody: View {
    let shape: ShapeClip

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let path = outline(w: w, h: h)
            ZStack {
                if shape.fillEnabled {
                    path.fill(shape.fillColor.opacity(shape.fillOpacity))
                }
                if shape.strokeEnabled {
                    path.stroke(shape.strokeColor.opacity(shape.strokeOpacity),
                                lineWidth: max(1, shape.strokeWidth))
                }
            }
        }
    }

    private func outline(w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        switch shape.type {
        case .pen:
            // 钢笔：按锚点连线。点存的是相对包围盒的归一化坐标，
            // 有控制柄就走三次贝塞尔，没有就直线相连
            let pts = shape.penPoints ?? []
            guard let first = pts.first else { return p }
            p.move(to: CGPoint(x: first.x * w, y: first.y * h))
            for (i, pt) in pts.enumerated() where i > 0 {
                let prev = pts[i - 1]
                let to = CGPoint(x: pt.x * w, y: pt.y * h)
                let c1 = CGPoint(x: (prev.x + prev.ctrlOutDX) * w, y: (prev.y + prev.ctrlOutDY) * h)
                let c2 = CGPoint(x: (pt.x + pt.ctrlInDX) * w, y: (pt.y + pt.ctrlInDY) * h)
                if prev.ctrlOutDX == 0, prev.ctrlOutDY == 0, pt.ctrlInDX == 0, pt.ctrlInDY == 0 {
                    p.addLine(to: to)
                } else {
                    p.addCurve(to: to, control1: c1, control2: c2)
                }
            }
            if shape.penClosed { p.closeSubpath() }
        case .ellipse:
            p.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
        case .triangle:
            p.move(to: CGPoint(x: w / 2, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        case .parallelogram:
            p.move(to: CGPoint(x: w * 0.25, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w * 0.75, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        case .trapezoid:
            p.move(to: CGPoint(x: w * 0.2, y: 0))
            p.addLine(to: CGPoint(x: w * 0.8, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        case .line:
            p.move(to: CGPoint(x: 0, y: h / 2))
            p.addLine(to: CGPoint(x: w, y: h / 2))
        case .arrow:
            p.move(to: CGPoint(x: 0, y: h * 0.4))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.4))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.15))
            p.addLine(to: CGPoint(x: w, y: h / 2))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.85))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.6))
            p.addLine(to: CGPoint(x: 0, y: h * 0.6))
            p.closeSubpath()
        default:
            p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return p
    }
}
