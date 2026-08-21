import SwiftUI
import AppKit
import AVFoundation

/// 画布上的一个节点（v5.1.0，B3）
///
/// 四种类型形状不同：文本是宽输入框、图片/视频是竖卡片、音频是横条 ——
/// 不用看标签，形状本身就说明了这是什么。
struct CanvasNodeView: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    let node: CanvasNode
    /// hover 时左右两个 + 的回调：点它弹菜单，拖它拉线
    var onPlusTap: (Edge) -> Void
    var onPlusDragChanged: (CGPoint) -> Void
    var onPlusDragEnded: () -> Void

    /// 左右给 + 留的空当。**必须算进 frame** —— overlay 超出父视图 frame 的部分
    /// 收不到 hit test，+ 画在外面就是「看得见摸不着」：鼠标一够过去，
    /// 节点判定为离开、+ 立刻消失
    static let plusGutter: CGFloat = 40
    /// 卡片上方类型标签占的高度
    static let labelHeight: CGFloat = 18

    @ObservedObject private var player = AIInlinePlayer.shared
    @State private var isHovering = false
    /// 拖动中的临时位移。拖的时候只改这个本地值，松手才写回 model ——
    /// 每动一下就改 canvas.nodes 会让整层 ForEach 跟着重建，表现就是闪烁 + 不跟手
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isResizing = false
    @State private var resizeStart: CGSize?
    @State private var resizeStartPos: CGPoint?
    /// 调整中的临时尺寸和位置补偿。每帧写 canvas.nodes 会让整层 ForEach 重建 ——
    /// 跟拖动节点是同一个病根，表现就是闪。松手才提交
    /// 裁剪框（0~1 相对坐标）。**本地状态** —— 拖动每帧写 canvas 会让整层重建
    @State private var cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var liveSize: CGSize?
    @State private var livePosDelta: CGSize = .zero
    /// 素材库里查不到时长时自己算一次的结果。
    /// **必须缓存** —— AVURLAsset 的 duration 是同步读盘，放在 body 里等于
    /// 每次重算都读一次文件；播放中 body 每 30ms 重算一次，直接卡住
    @State private var cachedDuration: Double = 0
    /// 同理：没进素材库缩略图缓存的图片，自己读一次留着
    @State private var localCover: NSImage?

    /// 画的时候用这个尺寸：调整中是临时值，平时就是 model 里的
    private var effectiveSize: CGSize { liveSize ?? node.renderSize }
    /// 输入框的焦点。TextEditor 冒出来不会自动带光标，
    /// 不主动聚焦的话用户得再点一次 —— 表现就是「要双击才能输入」
    @FocusState private var textFocused: Bool

    private var isSelected: Bool { canvas.selectedNodeIDs.contains(node.id) }

    /// 右键菜单作用于谁：已选中就管整批，没选中就只管它自己
    private var contextTargets: Set<UUID> {
        canvas.selectedNodeIDs.contains(node.id) ? canvas.selectedNodeIDs : [node.id]
    }

    /// 别人在拖、我被捎带着走时的位移。自己拖的时候用本地 dragOffset，
    /// 不然会跟 canvas.draggingOffset 叠一次，跑成两倍
    private var carriedOffset: CGSize {
        guard !isDragging, canvas.draggingNodeIDs.contains(node.id) else { return .zero }
        return canvas.draggingOffset
    }
    private var isEditingText: Bool { canvas.editingTextNodeID == node.id }
    /// 正在拉的线悬在这个节点上 —— 松手就会连上它
    private var isDropTarget: Bool { canvas.hoveredDropTarget == node.id }
    private var lifted: Bool { isHovering || isDragging || isDropTarget }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                // 卡片上沿这一行：类型图标 + 名字，右边是时长。
                // 文件名不再画在卡片里 —— 盖着画面看着乱
                HStack(spacing: 4) {
                    svgIcon(Self.iconKey(for: node.kind), size: 11)
                    Text(node.displayName.isEmpty ? node.kind.label : node.displayName)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .foregroundColor(Color.labelSecondary.opacity(0.7))
                .frame(width: effectiveSize.width, height: Self.labelHeight - 4, alignment: .bottom)

                card
            }
            .frame(width: effectiveSize.width)

            plusButton(.leading)
            plusButton(.trailing)
        }
        // 把两侧空当算进 frame，+ 才收得到鼠标
        .frame(width: effectiveSize.width + Self.plusGutter * 2,
               height: effectiveSize.height + Self.labelHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            autoPlayOnHover(inside)
        }
        .offset(x: dragOffset.width + livePosDelta.width + carriedOffset.width,
                y: dragOffset.height + livePosDelta.height + carriedOffset.height)
        .gesture(dragGesture)
        .onTapGesture {
            // SwiftUI 的 tap 不给修饰键，只能问 NSEvent 当前按着什么
            let flags = NSEvent.modifierFlags
            canvas.select(node.id, additive: flags.contains(.command) || flags.contains(.shift))
            // 视频在放：点一下卡片就停下，播放图标跟着回来
            if node.kind == .video, let url = node.mediaURL, player.isPlaying(url) {
                player.togglePause()
            }
            // 文本节点：点一下直接进编辑并聚焦
            if node.kind == .text {
                canvas.editingTextNodeID = node.id
                textFocused = true
            }
        }
        .onChange(of: canvas.editingTextNodeID) { _, editing in
            textFocused = (editing == node.id)
        }
        // 波形/时长/封面都得主动要一次。以前只读缓存不请求 ——
        // 进画布时音频卡片是空的，得等用户去点播放（那会儿别处顺带生成了）才冒出来
        .onAppear { prepareMedia() }
        .onChange(of: node.mediaPath) { _, _ in
            cachedDuration = 0
            localCover = nil
            prepareMedia()
        }
        // 右键一张**已选中**的卡片 → 菜单管整批；右键没选中的 → 只管它自己（和它同组的）
        .contextMenu {
            CanvasContextMenuItems(canvas: canvas, targets: contextTargets)
        }

    }

    /// 文本卡片四条边的调整热区。
    ///
    /// 不画把手 —— 鼠标挪到边上光标自己变成双向箭头，直接拖就改大小。
    /// 热区 10pt（跟预览区控制框那边统一）：太宽会把卡片内容的点击也吃掉
    @ViewBuilder
    private var resizeEdges: some View {
        let hit: CGFloat = 10
        ZStack {
            edgeHandle(.top).frame(width: effectiveSize.width - hit * 2, height: hit)
                .frame(maxHeight: .infinity, alignment: .top)
            edgeHandle(.bottom).frame(width: effectiveSize.width - hit * 2, height: hit)
                .frame(maxHeight: .infinity, alignment: .bottom)
            edgeHandle(.leading).frame(width: hit, height: effectiveSize.height - hit * 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            edgeHandle(.trailing).frame(width: hit, height: effectiveSize.height - hit * 2)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: effectiveSize.width, height: effectiveSize.height)
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
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if resizeStart == nil {
                            resizeStart = node.size
                            resizeStartPos = node.position
                            isResizing = true
                        }
                        applyResize(edge: edge,
                                    translation: CGSize(width: value.location.x - value.startLocation.x,
                                                        height: value.location.y - value.startLocation.y))
                    }
                    .onEnded { _ in commitResize() }
            )
    }

    /// 拖上边和左边时要同时挪位置，不然卡片会往反方向长。
    /// 过程中只改本地临时值，父视图的 .position() 不动 —— 位置差用 offset 顶回去
    private func applyResize(edge: Edge, translation: CGSize) {
        guard let baseSize = resizeStart, let basePos = resizeStartPos else { return }
        let dx = translation.width / canvas.zoom
        let dy = translation.height / canvas.zoom
        let minW: CGFloat = 180, minH: CGFloat = 90

        var size = baseSize
        var pos = basePos

        switch edge {
        case .top:
            size.height = max(minH, baseSize.height - dy)
            pos.y = basePos.y + (baseSize.height - size.height)
        case .bottom:
            size.height = max(minH, baseSize.height + dy)
        case .leading:
            size.width = max(minW, baseSize.width - dx)
            pos.x = basePos.x + (baseSize.width - size.width)
        case .trailing:
            size.width = max(minW, baseSize.width + dx)
        }

        liveSize = size
        // 卡片中心的位移 = 位置变化 + 尺寸变化的一半（frame 是按中心定位的）
        livePosDelta = CGSize(width: (pos.x - basePos.x) + (size.width - baseSize.width) / 2,
                              height: (pos.y - basePos.y) + (size.height - baseSize.height) / 2)
    }

    /// 松手一次性提交
    private func commitResize() {
        defer {
            resizeStart = nil
            resizeStartPos = nil
            liveSize = nil
            livePosDelta = .zero
            isResizing = false
        }
        guard let size = liveSize, let basePos = resizeStartPos, let baseSize = resizeStart else { return }
        // 位置从本地补偿反推回来
        let pos = CGPoint(x: basePos.x + livePosDelta.width - (size.width - baseSize.width) / 2,
                          y: basePos.y + livePosDelta.height - (size.height - baseSize.height) / 2)
        canvas.pushUndo()
        canvas.updateNode(id: node.id) { $0.size = size; $0.position = pos }
    }

    /// 卡片出现时把要用的素材准备好：音频波形、时长、封面。
    /// 都是**读盘的活**，一律挪出主线程 —— 波形那套本身就是后台线程 + 超时兜底
    private func prepareMedia() {
        guard let url = node.mediaURL else { return }

        // 素材库里已经有这个文件、但卡片没记住它的 id：补上。
        // 波形和缩略图都按 assetID 存，认不上 id 就等于没缓存
        if node.assetID == nil, let a = project.mediaAssets.first(where: { $0.url == url }) {
            canvas.updateNode(id: node.id) { $0.assetID = a.id }
            project.loadWaveform(assetID: a.id, url: url)
        }

        if node.kind == .audio, let id = node.assetID {
            project.loadWaveform(assetID: id, url: url)
        }

        // 素材库里有现成时长就不用自己算
        let known = node.assetID.flatMap { id in
            project.mediaAssets.first { $0.id == id }?.duration
        } ?? 0
        if (node.kind == .video || node.kind == .audio), known <= 0, cachedDuration == 0 {
            Task.detached {
                let d = AVURLAsset(url: url).duration.seconds
                guard d.isFinite, d > 0 else { return }
                await MainActor.run { cachedDuration = d }
            }
        }

        if node.kind == .image, localCover == nil,
           node.assetID.flatMap({ project.mediaThumbnails[$0] }) == nil {
            Task.detached {
                let img = NSImage(contentsOf: url)
                await MainActor.run { localCover = img }
            }
        }
    }

    /// 视频卡片：鼠标进来自动播，出去就暂停（不是停止 —— 再进来接着放）。
    /// 只对视频，音频还是点中间那个按钮播
    private func autoPlayOnHover(_ inside: Bool) {
        guard node.kind == .video, node.hasContent, !node.isGenerating,
              let url = node.mediaURL else { return }
        if inside {
            // toggle 认 URL：这张已经暂停在半路就接着放，别的卡片在放就换成这张
            if !player.isPlaying(url) { player.toggle(url) }
        } else if player.isPlaying(url) {
            player.togglePause()
        }
    }

    /// 拖动：过程中只动本地 offset，松手一次性提交。
    ///
    /// **坐标系必须是 `.global`**。节点视图在 `scaleEffect` 里面，默认（local）
    /// 坐标系给的 translation 已经是逆变换过的逻辑位移，再除一次 zoom 就成了
    /// 除两遍 —— 表现是「缩小之后随便动一下卡片就跑很远」（缩到 50% 跑两倍，
    /// 25% 跑四倍）。`.global` 拿到的是实打实的窗口位移，除一次 zoom 才对，
    /// 跟组的拖动、边缘拉伸那几处统一
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard !canvas.isSpaceHeld else { return }   // 空格是拖画布，不是拖节点
                // 拖动不代表选中：黄色描边是「点击选中」的反馈，
                // 拖一下就描边会让选中态失去意义
                isDragging = true
                // 组里的卡片、框选中的一批：拖一张，其余的跟着走
                canvas.draggingNodeIDs = canvas.dragCompanions(of: node.id)
                dragOffset = CGSize(width: (value.location.x - value.startLocation.x) / canvas.zoom,
                                    height: (value.location.y - value.startLocation.y) / canvas.zoom)
                canvas.draggingOffset = dragOffset   // 连线跟着卡片走
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                canvas.pushUndo()
                let dx = (value.location.x - value.startLocation.x) / canvas.zoom
                let dy = (value.location.y - value.startLocation.y) / canvas.zoom
                for id in canvas.draggingNodeIDs {
                    guard let n = canvas.node(id) else { continue }
                    canvas.moveNode(id: id, to: CGPoint(x: n.position.x + dx, y: n.position.y + dy))
                }
                // 拖出组的地盘就脱组 —— 位置写完之后再判，判据是新位置
                for id in canvas.draggingNodeIDs { canvas.detachIfOutside(id) }
                // 位置写完再清偏移：反过来的话中间会有一帧是「旧位置 + 零偏移」，看着就是跳一下
                dragOffset = .zero
                canvas.draggingNodeIDs = []
                canvas.draggingOffset = .zero
            }
    }

    /// 确认裁剪：按框裁出新文件，就地换掉这张卡片的内容。
    /// 图片本地裁（瞬时），视频走 ffmpeg 重编码（要等，卡片上转圈）
    private func confirmCrop() {
        let rect = cropRect
        canvas.croppingNodeID = nil
        cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        guard let url = node.mediaURL else { return }
        // 卡片按裁剪后的比例变形，不然画面会被拉伸
        let newSize = CGSize(width: node.size.width * rect.width,
                             height: node.size.height * rect.height)
        let nodeID = node.id
        let kind = node.kind

        if kind == .image {
            do {
                applyCropped(url: try CanvasImageOps.crop(url, to: rect), size: newSize, kind: kind)
            } catch {
                canvas.updateNode(id: nodeID) { $0.failure = error.localizedDescription }
            }
        } else {
            canvas.updateNode(id: nodeID) {
                $0.isGenerating = true; $0.failure = nil; $0.progressText = "裁剪中…"
            }
            Task { @MainActor in
                do {
                    let out = try await CanvasVideoOps.crop(url, to: rect)
                    canvas.updateNode(id: nodeID) { $0.isGenerating = false; $0.progressText = nil }
                    applyCropped(url: out, size: newSize, kind: kind)
                } catch {
                    canvas.updateNode(id: nodeID) {
                        $0.isGenerating = false; $0.progressText = nil
                        $0.failure = error.localizedDescription
                    }
                }
            }
        }
    }

    private func applyCropped(url: URL, size: CGSize, kind: CanvasNode.Kind) {
        canvas.pushUndo()
        project.importFile(url)
        let asset = project.mediaAssets.first { $0.url == url }
        canvas.updateNode(id: node.id) {
            $0.mediaPath = url.path
            $0.assetID = asset?.id
            $0.size = size
        }
        canvas.recordProducedAsset(url: url, kind: kind)
    }

    /// 用素材库那套自己的图标，别混 SF Symbols
    static func iconKey(for kind: CanvasNode.Kind) -> String {
        switch kind {
        case .text:  return "text"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        }
    }

    private func svgIcon(_ key: String, size: CGFloat) -> some View {
        Image(nsImage: SidebarSVGIcon.load(key, size: size))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    // MARK: 卡片本体

    private var card: some View {
        Group {
            switch node.kind {
            case .text:  textCard
            case .image: mediaCard(placeholder: "image")
            case .video: mediaCard(placeholder: "video")
            case .audio: audioCard
            }
        }
        .frame(width: effectiveSize.width, height: effectiveSize.height)
        .scaleEffect(isDropTarget ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        // 实色底：半透明的话画布点阵会透上来，卡片看着发灰
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.19, green: 0.19, blue: 0.20)))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isDropTarget ? Color.accent
                              : (isSelected ? Color.accent : Color.white.opacity(0.10)),
                              lineWidth: (isDropTarget || isSelected) ? 2 : 1)
        )
        // 裁剪模式：卡片上直接拉框
        .overlay {
            if canvas.croppingNodeID == node.id {
                CanvasCropOverlay(canvas: canvas, node: node, rect: $cropRect,
                                  onConfirm: { confirmCrop() },
                                  onCancel: { canvas.croppingNodeID = nil })
                    .frame(width: effectiveSize.width, height: effectiveSize.height)
                    .offset(y: Self.labelHeight / 2)
            }
        }
        .overlay {
            // 文本卡片的四边可以拖着改大小。
            // 热区**常驻**，不跟 hover 联动 —— 条件显示的话，热区是在鼠标到边缘、
            // 卡片 onHover 触发之后才出现的，等它出来鼠标早过去了，就是「一闪而过」
            if node.kind == .text { resizeEdges }
        }
        // 时长贴在卡片内右上角，hover 才出 —— 平时别占着画面
        .overlay(alignment: .topTrailing) {
            if (isHovering || isDragging), let d = durationText {
                Text(d)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(8)
            }
        }
        // hover 抬起来：投影要看得出来，才提示「这会儿可以直接拖」
        .shadow(color: .black.opacity(lifted ? 0.4 : 0),
                radius: lifted ? 24 : 0,
                y: lifted ? 12 : 0)
        .overlay(alignment: .bottom) { floatingActions }
    }

    /// 卡片上的悬浮按钮。有内容且 hover 时才出 ——
    /// 空卡片中间已经有「上传 / 素材」两个入口了，再叠一层是重复
    /// 卡片底部的悬浮按钮：左下 +，右下换素材。
    /// 文本卡片没有素材可换，只留左下那个 +（下拉是字幕/标题文字）
    @ViewBuilder
    private var floatingActions: some View {
        if showsFloatingActions {
            HStack {
                if node.kind == .text {
                    FloatingPlusButton(
                        items: [("添加到字幕", { NotificationCenter.default.post(name: .canvasNodeToSubtitle, object: node.id) }),
                                ("添加到标题文字", { NotificationCenter.default.post(name: .canvasNodeToTitle, object: node.id) })])
                } else {
                    FloatingPlusButton(
                        items: [("添加到 AI 参考", { NotificationCenter.default.post(name: .canvasNodeToReference, object: node.id) }),
                                ("添加到时间轴", { NotificationCenter.default.post(name: .canvasNodeToTimeline, object: node.id) })])
                }

                Spacer()

                if node.kind != .text {
                    HStack(spacing: 4) {
                        floatingButton(icon: "importFile", help: "换成上传的文件") {
                            NotificationCenter.default.post(name: .canvasNodeUpload, object: node.id)
                        }
                        floatingButton(icon: "folder", help: "从素材库换一个") {
                            NotificationCenter.default.post(name: .canvasNodePickAsset, object: node.id)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private var showsFloatingActions: Bool {
        guard isHovering || isDragging else { return false }
        return node.kind == .text ? !node.text.isEmpty : node.hasContent
    }

    private func floatingButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        FloatingIconButton(icon: icon, help: help, action: action)
    }

    @ViewBuilder
    private var textCard: some View {
        if isEditingText {
            // 点过之后才是真输入框。一上来就放 TextEditor 的话，
            // 想拖动节点会变成在文字里划选
            // 用 NSTextView：SwiftUI 的 TextEditor 画不出下划线和删除线，
            // 而文本卡片点一下就进编辑态，按 U / S 会看着像没反应
            CanvasTextEditor(
                text: Binding(
                    get: { node.text },
                    set: { newValue in canvas.updateNode(id: node.id) { $0.text = newValue } }),
                fontSize: node.fontSize,
                bold: node.bold,
                italic: node.italic,
                underline: node.underline,
                strikethrough: node.strikethrough,
                colorHex: node.textColorHex,
                focused: textFocused)
                .padding(6)
        } else {
            VStack {
                HStack {
                    // 样式（颜色/标题级别/粗斜体/下划线/删除线）在这层生效。
                    // TextEditor 那层只吃字号、粗体、斜体、颜色 ——
                    // 下划线和删除线 SwiftUI 的 TextEditor 给不了，编辑态先不显示
                    Text(node.text.isEmpty ? "文本" : node.text)
                        .font(.system(size: node.fontSize, weight: node.bold ? .bold : .regular))
                        .italic(node.italic)
                        .underline(node.underline)
                        .strikethrough(node.strikethrough)
                        .foregroundColor(node.text.isEmpty
                                         ? Color.labelSecondary.opacity(0.4)
                                         : Color(hex: node.textColorHex))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
    }

    /// 图片/视频卡片。有内容时画面**铺满整张卡**，不留边距
    private func mediaCard(placeholder: String) -> some View {
        ZStack {
            if node.kind == .video, node.hasContent,
               let url = node.mediaURL, player.isCurrent(url), let p = player.player {
                // 播放中就直接画画面
                InlinePlayerLayer(player: p)
                    .frame(width: effectiveSize.width, height: effectiveSize.height)
                    .clipped()
            } else if let cover = coverImage {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: effectiveSize.width, height: effectiveSize.height)
                    .clipped()
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    if node.isGenerating || node.isWaiting {
                        // 长任务（超分/分离音轨）带阶段和百分比 —— 时间轴那边显示在
                        // 通知卡片里，画布上直接显示在卡片中央，同一套状态
                        VStack(spacing: 8) {
                            if let p = node.progress {
                                ProgressView(value: p)
                                    .frame(width: max(80, node.size.width * 0.6))
                                Text("\(node.progressText ?? "处理中…")  \(Int(p * 100))%")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color.labelSecondary)
                            } else {
                                ProgressView().controlSize(.small)
                                Text(node.progressText
                                     ?? (node.isWaiting ? "等上游生成完" : "生成中…"))
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.labelSecondary)
                            }
                            stopButton
                        }
                    } else if let failure = node.failure {
                        VStack(spacing: 6) {
                            Text(failure)
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                            Button("重试") {
                                NotificationCenter.default.post(name: .canvasNodeRetry, object: node.id)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(Color.accent)
                        }
                    } else {
                        svgIcon(placeholder, size: 34)
                            .foregroundColor(Color.labelSecondary.opacity(0.35))
                    }
                    Spacer()
                    if !node.isGenerating && !node.isWaiting && node.failure == nil {
                        HStack(spacing: 16) {
                            smallAction(icon: "importFile", title: "上传", help: "从电脑里选一个文件") {
                                NotificationCenter.default.post(name: .canvasNodeUpload, object: node.id)
                            }
                            smallAction(icon: "folder", title: "素材库", help: "从素材库里挑一个") {
                                NotificationCenter.default.post(name: .canvasNodePickAsset, object: node.id)
                            }
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
        .overlay { playButton }
    }

    /// 右上角时长。播放时跟着走（当前 / 总长），没播就只显示总长
    private var durationText: String? {
        guard node.kind == .video || node.kind == .audio, node.hasContent else { return nil }
        let total = assetDuration
        guard total > 0 else { return nil }
        if let url = node.mediaURL, player.isCurrent(url), player.duration > 0 {
            return "\(fmt(player.currentTime)) / \(fmt(total))"
        }
        return fmt(total)
    }

    private var assetDuration: Double {
        if let id = node.assetID,
           let a = project.mediaAssets.first(where: { $0.id == id }), a.duration > 0 {
            return a.duration
        }
        return cachedDuration
    }

    private func fmt(_ d: Double) -> String {
        guard d.isFinite, d >= 0 else { return "--:--" }
        return String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
    }

    /// 视频/音频卡片中央的播放按钮。播放器是单例，同时只响一个。
    /// 视频正在放的时候不显示 —— 那会儿画面自己在动，压个按钮在中间挡事
    @ViewBuilder
    private var playButton: some View {
        if node.hasContent, !node.isGenerating, let url = node.mediaURL,
           node.kind == .video || node.kind == .audio,
           !(node.kind == .video && player.isPlaying(url)) {
            Button { player.toggle(url) } label: {
                Image(nsImage: TimelineSVGIcon.load(player.isPlaying(url) ? "pause" : "play"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying(url) ? "暂停" : "播放")
        }
    }

    /// 封面。视频读素材库那份缩略图（跟素材库/时间轴共用一套缓存，不重复抽帧），
    /// 图片没进素材库时直接读文件
    private var coverImage: NSImage? {
        guard !node.isGenerating else { return nil }
        if let assetID = node.assetID, let thumb = project.mediaThumbnails[assetID] {
            return thumb
        }
        return localCover
    }

    /// 音频卡片。布局跟图片/视频一致：内容在上、按钮在下。
    /// 有素材时画波形 —— 复用时间轴那套 `AudioWaveformCanvas` 和同一份波形缓存
    /// 音频卡片。播放按钮在正中间，波形用时间轴音频轨那个绿色，
    /// 播放时叠一条黄色指示线跟着走
    private var audioCard: some View {
        ZStack {
            if node.isGenerating || node.isWaiting {
                VStack(spacing: 8) {
                    if let p = node.progress {
                        ProgressView(value: p).frame(width: 140)
                        Text("\(node.progressText ?? "处理中…")  \(Int(p * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(node.progressText ?? "生成中…")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    stopButton
                }
            } else if let failure = node.failure {
                VStack(spacing: 6) {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                    Button("重试") {
                        NotificationCenter.default.post(name: .canvasNodeRetry, object: node.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color.accent)
                }
            } else if node.hasContent {
                // 波形铺满卡片，播放按钮压在中间
                if let assetID = node.assetID, let wave = project.waveformCache[assetID] {
                    AudioWaveformCanvas(waveData: wave, trimStart: 0,
                                        clipDuration: max(0.1, assetDuration),
                                        fullHeight: true,
                                        barColor: Color(hex: "#5DB85D").opacity(0.5))
                } else {
                    svgIcon("audio", size: 22)
                        .foregroundColor(Color.labelSecondary.opacity(0.35))
                }
                playheadLine
                playButton
            } else {
                HStack(spacing: 16) {
                    smallAction(icon: "importFile", title: "上传", help: "从电脑里选一个文件") {
                        NotificationCenter.default.post(name: .canvasNodeUpload, object: node.id)
                    }
                    smallAction(icon: "folder", title: "素材库", help: "从素材库里挑一个") {
                        NotificationCenter.default.post(name: .canvasNodePickAsset, object: node.id)
                    }
                }
            }
        }
    }

    /// 播放位置指示线。黄色竖线，跟着播放走
    @ViewBuilder
    private var playheadLine: some View {
        // 用 isCurrent 不是 isPlaying —— 暂停时线要停在原处，不能消失
        if let url = node.mediaURL, player.isCurrent(url),
           player.duration > 0, assetDuration > 0 {
            GeometryReader { geo in
                let ratio = min(1, max(0, player.currentTime / assetDuration))
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: 1)
                    .position(x: geo.size.width * ratio, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }

    /// 生成中的停止按钮
    @ViewBuilder
    private var stopButton: some View {
        if node.isGenerating {
            Button { canvas.cancelGeneration(nodeID: node.id) } label: {
                Image(nsImage: SidebarSVGIcon.load("toastStop", size: 14))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .help("停止")
        }
    }

    private func smallAction(icon: String, title: String, help: String,
                            action: @escaping () -> Void) -> some View {
        SmallCardAction(icon: icon, title: title, help: help, action: action)
    }

    // MARK: 左右两个 +

    /// hover 才出现。点它弹添加菜单，拖它拉线到别的节点。
    /// 摆在卡片两侧的空当里 —— 那块空当已经算进 frame，所以点得中也拖得动
    @ViewBuilder
    private func plusButton(_ edge: Edge) -> some View {
        // 菜单是从这一侧弹出来的时候也要留着 —— 鼠标移到菜单上，
        // 节点自己的 hover 就掉了，+ 跟着消失的话看不出菜单是哪儿来的。
        // 只留点的那一侧，另一侧照常跟着 hover 走
        let keptForMenu = canvas.plusMenuSource == .init(nodeID: node.id,
                                                         isTrailing: edge == .trailing)
        if isHovering || canvas.pendingEdgeFrom == node.id || keptForMenu {
            Circle()
                .fill(Color(red: 0.26, green: 0.26, blue: 0.28))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary))
                .offset(x: edge == .leading
                        ? -(node.size.width / 2 + Self.plusGutter / 2)
                        : (node.size.width / 2 + Self.plusGutter / 2),
                        y: Self.labelHeight / 2)
                .onTapGesture { onPlusTap(edge) }
                .gesture(
                    DragGesture(coordinateSpace: .named("canvasContent"))
                        .onChanged { value in
                            canvas.pendingEdgeFrom = node.id
                            canvas.pendingEdgeIsLeading = (edge == .leading)
                            onPlusDragChanged(value.location)
                        }
                        .onEnded { _ in onPlusDragEnded() }
                )
        }
    }
}

extension Notification.Name {
    /// 节点上的「上传」/「素材」按钮 —— 文件面板得在 overlay 那层弹，
    /// 节点视图本身在缩放变换里，直接弹面板位置会乱
    static let canvasNodeUpload = Notification.Name("canvasNodeUpload")
    static let canvasNodePickAsset = Notification.Name("canvasNodePickAsset")
    /// 把节点的素材挂到 AI 面板的参考区
    static let canvasNodeToReference = Notification.Name("canvasNodeToReference")
    /// 把节点的素材插到时间轴播放头处
    static let canvasNodeToTimeline = Notification.Name("canvasNodeToTimeline")
    /// 生成失败后重试
    static let canvasNodeRetry = Notification.Name("canvasNodeRetry")
    /// 文本节点的内容插成字幕 / 标题文字
    static let canvasNodeToSubtitle = Notification.Name("canvasNodeToSubtitle")
    static let canvasNodeToTitle = Notification.Name("canvasNodeToTitle")
}


/// 空卡片中间那两个入口。hover 要有底色，光靠文字变色在深色卡上看不出来
private struct SmallCardAction: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(nsImage: SidebarSVGIcon.load(icon, size: 12))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                Text(title).font(.system(size: 11))
            }
            .foregroundColor(hovering ? Color.labelPrimary : Color.labelSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}


/// 卡片上的圆形悬浮按钮。hover 变亮，配气泡提示
private struct FloatingIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: SidebarSVGIcon.load(icon, size: 12))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.8 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.35 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 卡片左下角那个 +。
///
/// 不用 `Menu`（macOS 上它会接管 label 绘制，自定义圆底画不出来），
/// 也不用 `.popover`（带箭头的气泡，太重）—— 自绘一个贴着按钮的下拉
private struct FloatingPlusButton: View {
    /// 下拉里的条目，标题 + 动作
    let items: [(String, () -> Void)]

    @State private var hovering = false
    @State private var showMenu = false

    var body: some View {
        Button { showMenu.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.8 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.35 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("把这个内容用到别处")
        .overlay(alignment: .bottomLeading) {
            if showMenu {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        MenuItemRow(title: item.0) { showMenu = false; item.1() }
                    }
                }
                .padding(.vertical, 4)
                .frame(width: 140)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 5)
                // 按钮在卡片底部，菜单往上弹才不会被卡片边缘切掉
                .offset(y: -28)
                .zIndex(10)
            }
        }
    }
}

/// 下拉里的一行，hover 有底色
private struct MenuItemRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundColor(Color.labelPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovering ? 0.10 : 0))
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
