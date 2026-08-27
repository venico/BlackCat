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
    /// 主选中的那个。属性区单选时显示它的属性
    @State private var selection: LayerRef?
    /// Shift 加选的其余项。**主选也算在选区里**，见 `allSelected`
    @State private var extraSel: Set<LayerRef> = []
    /// Shift 在重叠处是在循环加选还是循环减选
    @State private var shiftRemoving = false
    /// 一起拖动时各自的起手位置
    @State private var dragStartAll: [LayerRef: CGPoint] = [:]
    /// 正在改文字的那条。双击进来，点别处或回车提交
    @State private var editingTextID: UUID?
    /// Delete / Backspace 的键盘监听
    @State private var deleteMonitor: Any?
    @State private var editingText: String = ""

    /// 钢笔绘制态。非 nil 时封面上盖一层预览区的 `PenDrawingOverlay`
    @State private var penDraftID: UUID?
    /// 拖动图层时的起始位置（相对坐标）。跟裁剪框一个道理：
    /// `translation` 是累计值，基准必须是**起手那一刻**的位置，不能拿每帧变的当前值
    @State private var dragStart: CGPoint?

    enum LayerRef: Hashable {
        case text(UUID)
        case shape(UUID)

        var id: UUID {
            switch self { case .text(let i), .shape(let i): return i }
        }
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
        // 高度 660：620 时预览区只剩约 290pt 高，横版封面吃不满宽度；
        // 700 又偏高，在小屏上顶到边。660 是两头都够用的折中
        .frame(width: 980, height: 660)
        .floatingPanelMaterial()
        .onAppear { loadDraft(); installDeleteMonitor() }
        .onDisappear { removeDeleteMonitor() }
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

    /// 封面框、上传按钮、选帧轨道**是一组**，整体垂直居中。
    ///
    /// 按钮和轨道的高度先从可用高度里扣掉，剩下的才拿去算封面框 ——
    /// 这样封面比例一变（框跟着变大变小），三者之间的间距还是固定的
    private static let previewGap: CGFloat = 12       // 封面框 → 上传按钮
    private static let stripGap: CGFloat = 24        // 上传按钮 → 选帧轨道
    private static let uploadBarHeight: CGFloat = 26
    private static let stripHeight: CGFloat = 54
    private static var previewReserved: CGFloat {
        previewGap + uploadBarHeight + stripGap + stripHeight
    }

    private var previewPane: some View {
        GeometryReader { geo in
            let box = fitSize(in: CGSize(width: geo.size.width,
                                         height: geo.size.height - Self.previewReserved))
            VStack(spacing: 0) {
                coverBox(box: box)
                uploadBar
                    .padding(.top, Self.previewGap)
                frameStripView
                    .frame(width: box.width, height: Self.stripHeight)
                    .padding(.top, Self.stripGap)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 中间这栏自己一套边距：**16**，跟左右两栏的 24 区分开，让封面尽量大
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 上传按钮。跟封面框居中对齐，排在框正下方
    private var uploadBar: some View {
            HStack(spacing: 6) {
                Spacer()
                Button { uploadImage() } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: SidebarSVGIcon.load("importFile", size: 12))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                        Text("上传封面").font(.system(size: 11))
                    }
                    .foregroundColor(Color.labelPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("上传一张图片当封面，同时收进素材库")
                Spacer()
            }
            // 中间这栏自己一套边距：**16**，跟下面封面框、选帧轨道的留白一致。
            // 左右两栏用 24（跟弹窗标题对齐），中间窄一点让封面更大
        .frame(height: Self.uploadBarHeight)
    }

    /// 选帧轨道：底图是视频才有。**位置一直留着** ——
    /// 有没有轨道都占同样高度，否则选中视频前后预览框会一大一小
    private var frameStripView: some View {
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
    }

    /// 封面框本体
    private func coverBox(box: CGSize) -> some View {
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
                    // **裁剪排在缩放/旋转/位移之前** —— 排在后面的话裁剪线
                    // 是钉在封面框上的，画面一缩放一移动就跟裁剪框对不上了
                    .mask(
                        Rectangle()
                            .padding(.top, box.height * draft.cropTop)
                            .padding(.bottom, box.height * draft.cropBottom)
                            .padding(.leading, box.width * draft.cropLeft)
                            .padding(.trailing, box.width * draft.cropRight)
                    )
                    // 圆角切在描边之前，描边才会沿着圆角走。
                    // 圆角值是渲染坐标的像素，要换算到框的尺度上
                    .clipShape(RoundedRectangle(
                        cornerRadius: CGFloat(draft.cornerRadius)
                            * (box.width / max(project.previewRenderSize.width, 1))))
                    // 描边跟预览区图片片段共用同一个实现（八向阴影）。
                    // 少了这一层，描边就只有点确认渲染时才出现，
                    // 在弹窗里拖宽度滑块完全看不到反应
                    .imageStroke(width: (draft.strokeWidth ?? 0)
                                    * (box.width / max(project.previewRenderSize.width, 1)),
                                 color: Color(hex: draft.strokeColorHex ?? "#FFFFFF"),
                                 softness: draft.strokeSoftness ?? 0)
                    .scaleEffect(x: draft.baseScale * (draft.baseMirrorH ? -1 : 1),
                                 y: (draft.baseScaleY ?? draft.baseScale) * (draft.baseMirrorV ? -1 : 1))
                    .opacity(draft.baseOpacity)
                    .rotationEffect(.degrees(draft.baseRotation))
                    .offset(x: box.width * draft.baseOffsetX,
                            y: box.height * draft.baseOffsetY)
                    .brightness(draft.colorAdjust.brightness)
                    .contrast(1 + draft.colorAdjust.contrast)
                    .saturation(1 + draft.colorAdjust.saturation)
                    .hueRotation(.degrees(draft.colorAdjust.hue))
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
            } else {
                transformOverlay(box: box)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // 点空白处取消选中（顺便把正在改的文字提交掉）
        .onTapGesture { commitTextEdit(); clearSelection() }
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
    /// 字号按封面实际宽度换算 —— 预览缩小了字也要跟着缩小，否则所见非所得。
    ///
    /// 渲染**直接用预览区那份 `TextLabel`**，双击进的输入框也是那份 `TextEditField`：
    /// 自己另画一版的话，斜体、描边、背景色、对齐这些属性调了都没反应
    @ViewBuilder
    private func coverText(_ t: TextClip, box: CGSize) -> some View {
        let scale = box.width / max(project.previewRenderSize.width, 1)
        if editingTextID == t.id {
            // 输入框跟预览区双击进去的是同一个
            TextEditField(text: $editingText, clip: t, scale: scale,
                          onCommit: { commitTextEdit() })
                .fixedSize()
                .overlay(RoundedRectangle(cornerRadius: 4 * scale)
                    .strokeBorder(Color.accent, lineWidth: 1.5))
                .position(x: box.width * t.posX, y: box.height * t.posY)
        } else {
            TextLabel(clip: t, scale: scale)
                .overlay(allSelected.count > 1 && isSelected(.text(t.id))
                         ? Rectangle().stroke(Color.accent, lineWidth: 1.5) : nil)
                .position(x: box.width * t.posX, y: box.height * t.posY)
                .onTapGesture(count: 2) {
                    commitTextEdit()
                    editingText = t.text
                    editingTextID = t.id
                    selection = .text(t.id)
                    extraSel = []
                }
                .onTapGesture { pick(.text(t.id)) }
                .gesture(dragGesture(for: .text(t.id), box: box,
                                     current: CGPoint(x: t.posX, y: t.posY)))
        }
    }

    // MARK: - 选区

    /// 当前选中的全部图层（主选 + 加选）
    private var allSelected: [LayerRef] {
        guard let s = selection else { return Array(extraSel) }
        return [s] + extraSel.filter { $0 != s }
    }

    private func isSelected(_ ref: LayerRef) -> Bool {
        selection == ref || extraSel.contains(ref)
    }

    /// 点选。按住 Shift 或 ⌘ 是加选/取消选；
    /// 不按修饰键时，**点在重叠处会沿叠放顺序轮换**（跟预览区一个手感）
    private func pick(_ ref: LayerRef) {
        let additive = NSEvent.modifierFlags.contains(.shift)
            || NSEvent.modifierFlags.contains(.command)
        guard additive else {
            selection = nextOverlapping(from: ref)
            extraSel = []
            return
        }
        // 重叠处：先把叠在一起的挨个加进来，全加完了再点就挨个移出去；
        // 不重叠就是普通的加选 / 减选
        let stack = overlappingStack(ref)
        let target: LayerRef
        if stack.count > 1 {
            // 一个都没选中就从加选重新开始
            if !stack.contains(where: { isSelected($0) }) { shiftRemoving = false }
            if shiftRemoving {
                target = stack.first(where: { isSelected($0) }) ?? ref
            } else {
                target = stack.first(where: { !isSelected($0) }) ?? ref
                // 这一下加完就满了 → 下次开始往外减
                if stack.allSatisfy({ isSelected($0) || $0 == target }) { shiftRemoving = true }
            }
        } else {
            target = ref
            shiftRemoving = false
        }

        if isSelected(target) {
            extraSel.remove(target)
            if selection == target {
                selection = extraSel.first
                if let s = selection { extraSel.remove(s) }
            }
            if !stack.contains(where: { isSelected($0) }) { shiftRemoving = false }
        } else {
            if selection == nil { selection = target } else { extraSel.insert(target) }
        }
    }

    /// 跟这个图层外接框相交的所有图层，按叠放顺序（图形在下、文字在上）
    private func overlappingStack(_ ref: LayerRef) -> [LayerRef] {
        let all: [LayerRef] = draft.shapes.map { .shape($0.id) } + draft.texts.map { .text($0.id) }
        let hits = all.filter { overlaps($0, with: ref) }
        return hits.isEmpty ? [ref] : hits
    }

    /// 点到的这个位置上还压着谁。当前选中的那个的**下一个**，到底了绕回第一个
    private func nextOverlapping(from ref: LayerRef) -> LayerRef {
        let hits = overlappingStack(ref)
        guard hits.count > 1 else { return ref }
        guard let cur = selection, let i = hits.firstIndex(of: cur) else { return hits[0] }
        return hits[(i + 1) % hits.count]
    }

    /// 两个图层的外接框有没有交叠。判定用的是渲染坐标下的中心和尺寸
    private func overlaps(_ a: LayerRef, with b: LayerRef) -> Bool {
        guard let ra = layerRect(a), let rb = layerRect(b) else { return false }
        return ra.intersects(rb)
    }

    private func layerRect(_ ref: LayerRef) -> CGRect? {
        let rs = project.previewRenderSize
        switch ref {
        case .text(let id):
            guard let t = draft.texts.first(where: { $0.id == id }) else { return nil }
            let box = t.boxWidth.map {
                CGSize(width: $0, height: t.boxHeight ?? estimatedTextBox(t).height)
            } ?? estimatedTextBox(t)
            return CGRect(x: t.posX * Double(rs.width) - Double(box.width) / 2,
                          y: t.posY * Double(rs.height) - Double(box.height) / 2,
                          width: Double(box.width), height: Double(box.height))
        case .shape(let id):
            guard let sh = draft.shapes.first(where: { $0.id == id }) else { return nil }
            let w = sh.width * sh.scaleX, h = sh.height * sh.scaleY
            return CGRect(x: sh.posX * Double(rs.width) - w / 2,
                          y: sh.posY * Double(rs.height) - h / 2,
                          width: w, height: h)
        }
    }

    private func clearSelection() {
        selection = nil
        extraSel = []
    }

    /// 删掉选中的全部图层
    private func deleteSelected() {
        // 一个图层都没选中时，删除键的目标是底图本身
        guard !allSelected.isEmpty else { clearBase(); return }
        for ref in allSelected {
            switch ref {
            case .text(let id): draft.texts.removeAll { $0.id == id }
            case .shape(let id): draft.shapes.removeAll { $0.id == id }
            }
        }
        clearSelection()
    }

    // MARK: - 多选

    /// 交给多选面板的图层句柄。跟预览区那套一个结构，只是读写的是 draft
    private var coverMultiLayers: [MultiLayerHandle] {
        let rs = project.previewRenderSize
        let rw = Double(rs.width), rh = Double(rs.height)
        guard rw > 0, rh > 0 else { return [] }

        return allSelected.compactMap { ref -> MultiLayerHandle? in
            switch ref {
            case .text(let id):
                guard let t = draft.texts.first(where: { $0.id == id }) else { return nil }
                let box = t.boxWidth.map {
                    CGSize(width: $0, height: t.boxHeight ?? Double(t.fontSize) * 1.4)
                } ?? estimatedTextBox(t)
                return MultiLayerHandle(
                    id: id,
                    center: CGPoint(x: t.posX * rw, y: t.posY * rh),
                    size: box, opacity: t.opacity,
                    scaleBy: { k in self.withText(id) {
                        $0.fontSize = max(8, $0.fontSize * CGFloat(k))
                        if let w = $0.boxWidth { $0.boxWidth = w * k }
                        if let h = $0.boxHeight { $0.boxHeight = h * k }
                    } },
                    moveBy: { d in self.withText(id) {
                        $0.posX = min(1, max(0, $0.posX + Double(d.x) / rw))
                        $0.posY = min(1, max(0, $0.posY + Double(d.y) / rh))
                    } },
                    rotateBy: { d in self.withText(id) { $0.rotation += d } },
                    setOpacity: { v in self.withText(id) { $0.opacity = v } })
            case .shape(let id):
                guard let sh = draft.shapes.first(where: { $0.id == id }) else { return nil }
                return MultiLayerHandle(
                    id: id,
                    center: CGPoint(x: sh.posX * rw, y: sh.posY * rh),
                    size: CGSize(width: sh.width * sh.scaleX, height: sh.height * sh.scaleY),
                    opacity: sh.opacity,
                    scaleBy: { k in self.withShape(id) { $0.scaleX *= k; $0.scaleY *= k } },
                    moveBy: { d in self.withShape(id) {
                        $0.posX = min(1, max(0, $0.posX + Double(d.x) / rw))
                        $0.posY = min(1, max(0, $0.posY + Double(d.y) / rh))
                    } },
                    rotateBy: { d in self.withShape(id) { $0.rotation += d } },
                    setOpacity: { v in self.withShape(id) { $0.opacity = v } })
            }
        }
    }

    private func withText(_ id: UUID, _ f: (inout TextClip) -> Void) {
        if let i = draft.texts.firstIndex(where: { $0.id == id }) { f(&draft.texts[i]) }
    }
    private func withShape(_ id: UUID, _ f: (inout ShapeClip) -> Void) {
        if let i = draft.shapes.firstIndex(where: { $0.id == id }) { f(&draft.shapes[i]) }
    }

    /// 多选对齐：对齐选中那几个的包围盒；只选一个就还是对齐封面框
    private func alignSelected(_ mode: LayerAlignMode) {
        let items = coverMultiLayers
        guard items.count > 1 else {
            if let ref = selection { alignLayer(mode, ref: ref) }
            return
        }
        let left = items.map { Double($0.center.x) - Double($0.size.width) / 2 }.min()!
        let right = items.map { Double($0.center.x) + Double($0.size.width) / 2 }.max()!
        let top = items.map { Double($0.center.y) - Double($0.size.height) / 2 }.min()!
        let bottom = items.map { Double($0.center.y) + Double($0.size.height) / 2 }.max()!

        func moveTo(_ it: MultiLayerHandle, x: Double? = nil, y: Double? = nil) {
            it.moveBy(CGPoint(x: (x ?? Double(it.center.x)) - Double(it.center.x),
                              y: (y ?? Double(it.center.y)) - Double(it.center.y)))
        }
        switch mode {
        case .left:    for it in items { moveTo(it, x: left + Double(it.size.width) / 2) }
        case .hcenter: let c = (left + right) / 2; for it in items { moveTo(it, x: c) }
        case .right:   for it in items { moveTo(it, x: right - Double(it.size.width) / 2) }
        case .top:     for it in items { moveTo(it, y: top + Double(it.size.height) / 2) }
        case .vcenter: let c = (top + bottom) / 2; for it in items { moveTo(it, y: c) }
        case .bottom:  for it in items { moveTo(it, y: bottom - Double(it.size.height) / 2) }
        case .hdist:
            let sorted = items.sorted { $0.center.x < $1.center.x }
            guard sorted.count >= 3 else { return }
            let total = sorted.reduce(0.0) { $0 + Double($1.size.width) }
            let gap = (right - left - total) / Double(sorted.count - 1)
            var cur = left
            for it in sorted { moveTo(it, x: cur + Double(it.size.width) / 2); cur += Double(it.size.width) + gap }
        case .vdist:
            let sorted = items.sorted { $0.center.y < $1.center.y }
            guard sorted.count >= 3 else { return }
            let total = sorted.reduce(0.0) { $0 + Double($1.size.height) }
            let gap = (bottom - top - total) / Double(sorted.count - 1)
            var cur = top
            for it in sorted { moveTo(it, y: cur + Double(it.size.height) / 2); cur += Double(it.size.height) + gap }
        }
    }

    // MARK: - 快捷键

    /// Delete / Backspace 删掉选中的图层。
    ///
    /// **正在输入文字或画钢笔时不能删** —— 那两种状态下这两个键是给输入用的
    private func installDeleteMonitor() {
        removeDeleteMonitor()
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard project.showCoverDesigner else { return event }
            guard editingTextID == nil, penDraftID == nil else { return event }
            // 光标在输入框里时删除键归输入框（圆角、数值这些都是 TextField，
            // 编辑中的 firstResponder 是它的 field editor，也是个 NSTextView）
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            // 51 = Delete(退格)，117 = Fn+Delete(向前删)
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            // 没选中图层时删的是底图；底图也没有就把事件放行
            guard !allSelected.isEmpty || baseImage != nil else { return event }
            deleteSelected()
            return nil
        }
    }

    private func removeDeleteMonitor() {
        if let m = deleteMonitor { NSEvent.removeMonitor(m); deleteMonitor = nil }
    }

    // MARK: - 属性区小工具

    /// 0~1 的值挂到 0~100 的滑块上
    private func pctBinding(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = $0 / 100 })
    }

    /// 左旋 90°。屏幕坐标里正角度是顺时针，所以要减；结果规范化到 0~360
    private func leftRotate90(_ deg: Double) -> Double {
        (deg - 90 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 文字没设过范围框时，先按文字本身量一个尺寸给滑块当初值
    private func estimatedTextBox(_ t: TextClip) -> CGSize {
        var font = NSFont(name: t.fontName, size: t.fontSize) ?? NSFont.systemFont(ofSize: t.fontSize)
        if t.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        let str = t.text.isEmpty ? " " : t.text
        let sz = (str as NSString).size(withAttributes: [.font: font])
        return CGSize(width: max(sz.width, 20), height: max(sz.height, 20))
    }

    /// 底图对齐封面框。画面按 baseScale 缩放后可能比框小，这时靠边才有意义
    private func alignBase(_ mode: LayerAlignMode) {
        // 画面相对封面框的半宽/半高（1 = 正好铺满）
        let hw = draft.baseScale / 2
        let hh = (draft.baseScaleY ?? draft.baseScale) / 2
        switch mode {
        case .left:    draft.baseOffsetX = hw - 0.5
        case .hcenter: draft.baseOffsetX = 0
        case .right:   draft.baseOffsetX = 0.5 - hw
        case .top:     draft.baseOffsetY = hh - 0.5
        case .vcenter: draft.baseOffsetY = 0
        case .bottom:  draft.baseOffsetY = 0.5 - hh
        case .hdist, .vdist: break
        }
    }

    /// 把一个图层对齐到封面框。多选对齐留给后面那批
    private func alignLayer(_ mode: LayerAlignMode, ref: LayerRef) {
        let rs = project.previewRenderSize
        guard rs.width > 0, rs.height > 0 else { return }

        func apply(w: Double, h: Double, setX: (Double) -> Void, setY: (Double) -> Void) {
            let hw = w / 2 / Double(rs.width), hh = h / 2 / Double(rs.height)
            switch mode {
            case .left:    setX(hw)
            case .hcenter: setX(0.5)
            case .right:   setX(1 - hw)
            case .top:     setY(hh)
            case .vcenter: setY(0.5)
            case .bottom:  setY(1 - hh)
            case .hdist, .vdist: break      // 一个元素谈不上分布
            }
        }

        switch ref {
        case .text(let id):
            guard let i = draft.texts.firstIndex(where: { $0.id == id }) else { return }
            let box = draft.texts[i].boxWidth.map {
                CGSize(width: $0, height: draft.texts[i].boxHeight ?? estimatedTextBox(draft.texts[i]).height)
            } ?? estimatedTextBox(draft.texts[i])
            apply(w: Double(box.width), h: Double(box.height),
                  setX: { draft.texts[i].posX = $0 }, setY: { draft.texts[i].posY = $0 })
        case .shape(let id):
            guard let i = draft.shapes.firstIndex(where: { $0.id == id }) else { return }
            let sh = draft.shapes[i]
            apply(w: sh.width * sh.scaleX, h: sh.height * sh.scaleY,
                  setX: { draft.shapes[i].posX = $0 }, setY: { draft.shapes[i].posY = $0 })
        }
    }

    /// 收尾文字输入。点别处、双击另一条、关弹窗都要先走这里
    private func commitTextEdit() {
        guard let id = editingTextID,
              let i = draft.texts.firstIndex(where: { $0.id == id }) else { return }
        draft.texts[i].text = editingText
        editingTextID = nil
    }

    @ViewBuilder
    private func coverShape(_ sh: ShapeClip, box: CGSize) -> some View {
        let scale = box.width / max(project.previewRenderSize.width, 1)
        return ShapeClipView(clip: sh, scale: scale)
            // 多选时每个都画一圈框；只选一个时框由 TransformBox 画（带手柄）
            .overlay(allSelected.count > 1 && isSelected(.shape(sh.id))
                     ? Rectangle().stroke(Color.accent, lineWidth: 1.5) : nil)
            .position(x: box.width * sh.posX, y: box.height * sh.posY)
            .onTapGesture { pick(.shape(sh.id)) }
            .gesture(dragGesture(for: .shape(sh.id), box: box,
                                 current: CGPoint(x: sh.posX, y: sh.posY)))
    }

    /// 选中图层的变换框。**用的是预览区那两个 overlay** ——
    /// 四角圆点、四边缩放条、旋转手柄和那边一模一样，手感也一样。
    ///
    /// 抽成独立函数是因为直接塞进预览的 ZStack 里会让 body 太大，
    /// 编译器类型检查超时（`CanvasOverlay` 和 `ContentView` 都栽过）
    @ViewBuilder
    private func transformOverlay(box: CGSize) -> some View {
        // 多选时不画带手柄的框 —— 那时候各元素自己画了一圈边框
        if allSelected.count > 1 {
            EmptyView()
        } else {
        switch selection {
        case .shape(let id):
            if let sh = draft.shapes.first(where: { $0.id == id }) {
                ShapeTransformOverlay(clipOverride: sh) { sid, apply in
                    if let i = draft.shapes.firstIndex(where: { $0.id == sid }) {
                        apply(&draft.shapes[i])
                    }
                }
                .frame(width: box.width, height: box.height)
            }
        case .text(let id):
            if let t = draft.texts.first(where: { $0.id == id }) {
                TextTransformOverlay(
                    clipOverride: t,
                    onUpdate: { tid, apply in
                        if let i = draft.texts.firstIndex(where: { $0.id == tid }) {
                            apply(&draft.texts[i])
                        }
                    },
                    forceEditing: editingTextID == t.id
                )
                .frame(width: box.width, height: box.height)
            }
        case .none:
            // 没选图层时操作的是底图，跟预览区图片片段一套手柄
            if baseImage != nil {
                CoverBaseTransformOverlay(draft: $draft, box: box)
                    .frame(width: box.width, height: box.height)
            }
        }
        }
    }

    /// 拖动图层。基准记的是**起手那一刻**的位置 —— `translation` 是累计位移，
    /// 每帧拿当前位置再加一次会越拖越快（裁剪框踩过这个坑）
    private func dragGesture(for ref: LayerRef, box: CGSize, current: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = current
                    // 拖的是选区里的元素 → 整个选区一起走；否则改成只选它
                    if !isSelected(ref) { selection = ref; extraSel = [] }
                    dragStartAll = Dictionary(uniqueKeysWithValues:
                        allSelected.compactMap { r in position(of: r).map { (r, $0) } })
                }
                let dx = v.translation.width / box.width
                let dy = v.translation.height / box.height
                for (r, start) in dragStartAll {
                    move(r, to: CGPoint(x: (start.x + dx).clamped(to: 0...1),
                                        y: (start.y + dy).clamped(to: 0...1)))
                }
            }
            .onEnded { _ in dragStart = nil; dragStartAll = [:] }
    }

    /// 图层当前的中心位置（0~1）
    private func position(of ref: LayerRef) -> CGPoint? {
        switch ref {
        case .text(let id):
            guard let t = draft.texts.first(where: { $0.id == id }) else { return nil }
            return CGPoint(x: t.posX, y: t.posY)
        case .shape(let id):
            guard let sh = draft.shapes.first(where: { $0.id == id }) else { return nil }
            return CGPoint(x: sh.posX, y: sh.posY)
        }
    }

    private func move(_ ref: LayerRef, to p: CGPoint) {
        switch ref {
        case .text(let id):
            if let i = draft.texts.firstIndex(where: { $0.id == id }) {
                draft.texts[i].posX = Double(p.x); draft.texts[i].posY = Double(p.y)
            }
        case .shape(let id):
            if let i = draft.shapes.firstIndex(where: { $0.id == id }) {
                draft.shapes[i].posX = Double(p.x); draft.shapes[i].posY = Double(p.y)
            }
        }
    }

    // MARK: - 右栏：图层属性

    /// 照搬属性区那套控件，但**去掉时间相关的字段** ——
    /// 封面是一张静止的图，开始/持续/动画在这儿没有意义
    @ViewBuilder
    private var layerInspector: some View {
        ScrollView(showsIndicators: false) {
            // spacing 收到 2：ISection 自己带上下留白，再叠 10 就散得厉害
            VStack(alignment: .leading, spacing: 2) {
                if allSelected.count > 1 {
                    // 多选：跟预览区共用同一个面板
                    paneTitle("已选 \(allSelected.count) 个") { deleteSelected() }
                    MultiSelectInspector(
                        layers: coverMultiLayers,
                        canvasSize: project.previewRenderSize,
                        onAlign: { mode in alignSelected(mode) },
                        onDelete: { deleteSelected() }
                    )
                } else {
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
    /// 属性区宽度。跟预览区那侧一致 —— 对齐那排八个按钮要放得下
    static let inspectorWidth: CGFloat = 280

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
            // 六组共同属性，跟文字、图形、预览区那三个面板同一份
            LayerCommonSections(
                mirrorH: $draft.baseMirrorH,
                mirrorV: $draft.baseMirrorV,
                rotation: $draft.baseRotation,
                onRotate90: { draft.baseRotation = leftRotate90(draft.baseRotation) },
                // 底图的位置是相对画面的偏移（0 = 居中），换算成 0~100 的位置
                posX: Binding(get: { (draft.baseOffsetX + 0.5) * 100 },
                              set: { draft.baseOffsetX = $0 / 100 - 0.5 }),
                posY: Binding(get: { (draft.baseOffsetY + 0.5) * 100 },
                              set: { draft.baseOffsetY = $0 / 100 - 0.5 }),
                onCenter: { draft.baseOffsetX = 0; draft.baseOffsetY = 0 },
                scaleW: Binding(get: { draft.baseScale * 100 },
                                set: { draft.baseScale = $0 / 100 }),
                scaleH: Binding(get: { (draft.baseScaleY ?? draft.baseScale) * 100 },
                                set: { draft.baseScaleY = $0 / 100 }),
                lockAspect: $draft.baseLockAspect,
                cropTop: pctBinding($draft.cropTop),
                cropBottom: pctBinding($draft.cropBottom),
                cropLeft: pctBinding($draft.cropLeft),
                cropRight: pctBinding($draft.cropRight),
                opacity: pctBinding($draft.baseOpacity),
                cornerRadius: $draft.cornerRadius,
                onAlign: { alignBase($0) }
            )

            ISection(title: "色调") {
                ICapsuleSlider(label: "亮度", value: $draft.colorAdjust.brightness,
                               range: -1...1, decimals: 2)
                ICapsuleSlider(label: "对比", value: $draft.colorAdjust.contrast,
                               range: -1...1, decimals: 2)
                ICapsuleSlider(label: "饱和", value: $draft.colorAdjust.saturation,
                               range: -1...1, decimals: 2)
                ICapsuleSlider(label: "色相", value: $draft.colorAdjust.hue,
                               range: -180...180, unit: "°")
            }

            ISection(title: "描边") {
                colorRow("颜色", Binding(
                    get: { Color(hex: draft.strokeColorHex ?? "#FFFFFF") },
                    set: { draft.strokeColorHex = $0.toHex() }
                ))
                ICapsuleSlider(label: "宽度", value: Binding(
                    get: { draft.strokeWidth ?? 0 }, set: { draft.strokeWidth = $0 }
                ), range: 0...100, decimals: 1, unit: "px")
                ICapsuleSlider(label: "柔和", value: Binding(
                    get: { draft.strokeSoftness ?? 0 }, set: { draft.strokeSoftness = $0 }
                ), range: 0...1, decimals: 2)
            }

            ISection(title: nil) {
                Button {
                    draft.baseOffsetX = 0; draft.baseOffsetY = 0
                    draft.baseScale = 1; draft.baseScaleY = nil
                    draft.baseRotation = 0; draft.baseOpacity = 1
                    draft.cornerRadius = 0
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
                styleGlyph("B", isOn: draft.texts[i].bold, weight: .bold) { draft.texts[i].bold.toggle() }
                styleGlyph("I", isOn: draft.texts[i].italic, italic: true) { draft.texts[i].italic.toggle() }
                    // 文字自己的多行对齐，跟 B / I 排在同一行
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
                            .frame(width: 30, height: 26)
                            .background(draft.texts[i].alignment == val
                                        ? Color.accent.opacity(0.15) : Color.white.opacity(0.05))
                            .cornerRadius(5)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 6)
        }

        ISection(title: "颜色与描边") {
            colorRow("文字颜色", $draft.texts[i].textColor)
            colorRow("描边颜色", $draft.texts[i].strokeColor)
            ISlider(label: "描边宽度", value: $draft.texts[i].strokeWidth, range: 0...100, unit: "px")
            ISlider(label: "柔和", value: $draft.texts[i].strokeSoftness, range: 0...1, unit: "", decimals: 2)
            colorRow("背景颜色", $draft.texts[i].bgColor)
            ISlider(label: "不透明度", value: Binding(
                get: { draft.texts[i].bgOpacity * 100 }, set: { draft.texts[i].bgOpacity = $0 / 100 }
            ), range: 0...100, unit: "%")
        
        }

        // 六组共同属性，跟图片、图形、预览区那三个面板同一份
        LayerCommonSections(
            mirrorH: $draft.texts[i].mirrorH,
            mirrorV: $draft.texts[i].mirrorV,
            rotation: $draft.texts[i].rotation,
            onRotate90: { draft.texts[i].rotation = leftRotate90(draft.texts[i].rotation) },
            posX: pctBinding($draft.texts[i].posX),
            posY: pctBinding($draft.texts[i].posY),
            onCenter: { draft.texts[i].posX = 0.5; draft.texts[i].posY = 0.5 },
            // 文字量的是**范围框**的像素宽高，不是百分比
            scaleW: Binding(
                get: { draft.texts[i].boxWidth ?? estimatedTextBox(draft.texts[i]).width },
                set: { v in
                    let old = draft.texts[i].boxWidth ?? estimatedTextBox(draft.texts[i]).width
                    // 锁着比例时字号跟着一起放大，跟拖四角圆点的手感一致
                    if draft.texts[i].lockBoxAspect, old > 0.01 {
                        draft.texts[i].fontSize = max(8, draft.texts[i].fontSize * CGFloat(v / old))
                    }
                    draft.texts[i].boxWidth = v
                }
            ),
            scaleH: Binding(
                get: { draft.texts[i].boxHeight ?? estimatedTextBox(draft.texts[i]).height },
                set: { draft.texts[i].boxHeight = $0 }
            ),
            lockAspect: $draft.texts[i].lockBoxAspect,
            scaleRange: 20...2000,
            scaleUnit: "px",
            cropTop: pctBinding($draft.texts[i].cropTop),
            cropBottom: pctBinding($draft.texts[i].cropBottom),
            cropLeft: pctBinding($draft.texts[i].cropLeft),
            cropRight: pctBinding($draft.texts[i].cropRight),
            opacity: pctBinding($draft.texts[i].opacity),
            // 文字没有圆角（背景框的圆角跟着字号走）
            cornerRadius: nil,
            onAlign: { alignLayer($0, ref: .text(draft.texts[i].id)) }
        )
    }

    /// 图形属性。字段跟**图形片段**一致，按要求**去掉片段信息和时间**
    @ViewBuilder
    private func shapeInspector(_ i: Int) -> some View {
        // 六组共同属性，跟文字、图片、预览区那三个面板同一份
        LayerCommonSections(
            mirrorH: $draft.shapes[i].mirrorH,
            mirrorV: $draft.shapes[i].mirrorV,
            rotation: $draft.shapes[i].rotation,
            onRotate90: { draft.shapes[i].rotation = leftRotate90(draft.shapes[i].rotation) },
            posX: pctBinding($draft.shapes[i].posX),
            posY: pctBinding($draft.shapes[i].posY),
            onCenter: { draft.shapes[i].posX = 0.5; draft.shapes[i].posY = 0.5 },
            scaleW: Binding(get: { draft.shapes[i].scaleX * 100 },
                            set: { draft.shapes[i].scaleX = $0 / 100 }),
            scaleH: Binding(get: { draft.shapes[i].scaleY * 100 },
                            set: { draft.shapes[i].scaleY = $0 / 100 }),
            lockAspect: $draft.shapes[i].lockAspect,
            cropTop: pctBinding($draft.shapes[i].cropTop),
            cropBottom: pctBinding($draft.shapes[i].cropBottom),
            cropLeft: pctBinding($draft.shapes[i].cropLeft),
            cropRight: pctBinding($draft.shapes[i].cropRight),
            opacity: pctBinding($draft.shapes[i].opacity),
            cornerRadius: $draft.shapes[i].cornerRadius,
            // 圆角只有矩形、三角形、梯形、平行四边形有，其余灰掉
            cornerEnabled: ShapeGeometry.supportsCorner(draft.shapes[i].type),
            onAlign: { alignLayer($0, ref: .shape(draft.shapes[i].id)) }
        )

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
                ), range: 0...100, unit: "%")
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
                // 样式（直线/虚线），跟预览区图形属性一致
                IFieldRow(label: "样式") {
                    IPicker(selection: Binding(
                        get: { draft.shapes[i].strokeDashed ? "虚线" : "直线" },
                        set: { draft.shapes[i].strokeDashed = ($0 == "虚线") }
                    ), options: [("直线", "直线"), ("虚线", "虚线")])
                }
                colorRow("颜色", $draft.shapes[i].strokeColor)
                ISlider(label: "粗细", value: $draft.shapes[i].strokeWidth, range: 1...30, unit: "px")
                ISlider(label: "不透明度", value: Binding(
                    get: { draft.shapes[i].strokeOpacity * 100 },
                    set: { draft.shapes[i].strokeOpacity = $0 / 100 }
                ), range: 0...100, unit: "%")
            }
        }

    }

    // MARK: 属性区里的小控件（样式照 InspectorView 那套）

    private func colorRow(_ label: String, _ binding: Binding<Color>) -> some View {
        // 色块左边缘跟滑块的滑轨对齐；大小缩到和开关一个量级
        IFieldRow(label: label) {
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(0.6, anchor: .leading)
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
        commitTextEdit()
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
        commitTextEdit()
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

        // 圆角：跟预览那层 clipShape 同一个位置（描边之前），
        // 做法跟图片片段导出那条链一致 —— 生成一张圆角白图当遮罩把四角抠掉
        if draft.cornerRadius > 0.01 {
            let boxRect = ci.extent
            if boxRect.width > 1, boxRect.height > 1,
               let gen = CIFilter(name: "CIRoundedRectangleGenerator") {
                let r = min(CGFloat(draft.cornerRadius), min(boxRect.width, boxRect.height) / 2)
                gen.setValue(CIVector(cgRect: boxRect), forKey: "inputExtent")
                gen.setValue(r, forKey: "inputRadius")
                gen.setValue(CIColor.white, forKey: "inputColor")
                if let mask = gen.outputImage?.cropped(to: boxRect) {
                    ci = ci.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask
                    ]).cropped(to: boxRect)
                }
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
    /// **用的就是预览里那两个视图**（`ShapeClipView` / `TextLabel`）——
    /// 之前这里另用 NSBezierPath / NSAttributedString 画了一遍，
    /// 斜体、文字描边、背景色、对齐、图形阴影这些属性预览里有、出图里没有。
    /// 现在渲染和预览同一份视图，不会再对不上
    ///
    /// **坐标要翻**：`posY` 是 0=顶部（跟预览、时间轴一致），
    /// 而 `lockFocus` 的画布是 y 朝上、原点在左下 —— 不翻的话上下颠倒
    @MainActor
    private func drawLayers(in size: CGSize) {
        for sh in draft.shapes {
            // 旋转交给画布，出图时不带（带的话转出边界的部分会被裁掉）
            guard let img = layerImage(ShapeClipView(clip: sh, scale: 1, applyRotation: false)) else { continue }
            place(img, atX: sh.posX, y: sh.posY, rotation: sh.rotation, in: size)
        }
        for t in draft.texts {
            guard let img = layerImage(TextLabel(clip: t, scale: 1, applyRotation: false)) else { continue }
            place(img, atX: t.posX, y: t.posY, rotation: t.rotation, in: size)
        }
    }

    /// 把一个图层视图渲染成图。四周留白是给阴影和描边的 ——
    /// ImageRenderer 按视图自身尺寸裁，不留白的话描边会缺一圈
    @MainActor
    private func layerImage<V: View>(_ view: V) -> NSImage? {
        let r = ImageRenderer(content: view.padding(24))
        r.scale = 2
        return r.nsImage
    }

    /// 按中心点摆放一张图层图，顺带转角度
    private func place(_ img: NSImage, atX px: Double, y py: Double,
                       rotation: Double, in size: CGSize) {
        let cx = size.width * px
        let cy = size.height * (1 - py)          // 翻 y
        let w = img.size.width, h = img.size.height
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.translateBy(x: cx, y: cy)
        ctx?.rotate(by: -rotation * .pi / 180)   // 画布 y 朝上，转向要反
        img.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx?.restoreGState()
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
                let h = bs.height * fit * (draft.baseScaleY ?? draft.baseScale)
                let ctx = NSGraphicsContext.current?.cgContext
                ctx?.saveGState()
                ctx?.setAlpha(CGFloat(draft.baseOpacity))
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

// MARK: - 封面底图的变换框

/// 底图的选中框。**用的就是预览区那个 `TransformBox`** ——
/// 四角缩放、四边裁剪、上方旋转，跟图片片段一套手感。
///
/// 框贴着画面走：画面缩放、旋转、移动之后，裁剪框跟着一起动
private struct CoverBaseTransformOverlay: View {
    @Binding var draft: ProjectCover
    let box: CGSize

    @State private var startScale: Double = 1
    @State private var startScaleY: Double = 1
    @State private var startRotation: Double = 0
    @State private var startOffset: CGPoint? = nil

    var body: some View {
        // 没裁之前的画面矩形：底图铺满封面框，再套上缩放和位移
        // 高度得用 baseScaleY —— 属性区能把宽高分开调，
        // 这儿还按 baseScale 算的话框就跟画面对不上了
        let w = box.width * draft.baseScale
        let h = box.height * (draft.baseScaleY ?? draft.baseScale)
        let c = CGPoint(x: box.width / 2 + box.width * draft.baseOffsetX,
                        y: box.height / 2 + box.height * draft.baseOffsetY)
        ZStack {
        // 拖着画面走。压在手柄下面一层，手柄优先
        Color.white.opacity(0.001)
            .frame(width: max(w, 8), height: max(h, 8))
            .contentShape(Rectangle())
            .onHover { if $0 { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
            .claimsDragFromWindow()
            .rotationEffect(.degrees(draft.baseRotation))
            .position(c)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        // 基准记起手那一刻，translation 是累计值，
                        // 每帧拿当前位置再加一次会越拖越快
                        if startOffset == nil {
                            startOffset = CGPoint(x: draft.baseOffsetX, y: draft.baseOffsetY)
                            NSCursor.closedHand.set()
                        }
                        let s = startOffset ?? .zero
                        draft.baseOffsetX = Double(s.x + v.translation.width / max(box.width, 1))
                        draft.baseOffsetY = Double(s.y + v.translation.height / max(box.height, 1))
                    }
                    .onEnded { _ in startOffset = nil; NSCursor.openHand.set() }
            )

        TransformBox(
            center: c,
            size: CGSize(width: max(w, 8), height: max(h, 8)),
            rotation: draft.baseRotation,
            crop: TransformCrop(top: draft.cropTop, bottom: draft.cropBottom,
                                left: draft.cropLeft, right: draft.cropRight),
            onBegin: {
                startScale = draft.baseScale
                startScaleY = draft.baseScaleY ?? draft.baseScale
                startRotation = draft.baseRotation
            },
            onScale: { ratio in
                // 拖四角是**等比**缩放，宽高都得跟着走。
                // 只改 baseScale 的话，高度单独设过的图就只有宽度在变
                draft.baseScale = min(max(startScale * ratio, 0.05), 8)
                draft.baseScaleY = min(max(startScaleY * ratio, 0.05), 8)
            },
            onCrop: { e, value in
                switch e {
                case 0: draft.cropTop = value
                case 1: draft.cropBottom = value
                case 2: draft.cropLeft = value
                default: draft.cropRight = value
                }
            },
            onRotate: { delta in
                draft.baseRotation = startRotation + delta
            }
        )
        }
    }
}
