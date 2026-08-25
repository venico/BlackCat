import SwiftUI
import AVFoundation

/// 选中图片/视频/音频节点时，从画布底部升起的输入框（v5.1.0，B4）
///
/// 模型、子模型、比例这些下拉直接复用「设置 → AI 设置」那套配置，
/// 不另起一份 —— app 里已经有两套大模型配置了，再多一套只会更乱。
struct CanvasPromptBar: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    @ObservedObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared

    let node: CanvasNode

    @State private var draftPrompt: String = ""
    /// 输入框高度。拖面板上边缘可以拉高，好一次看到更多提示词
    @State private var inputHeight: CGFloat = Self.defaultInputHeight
    @State private var dragStartHeight: CGFloat?
    @State private var swapHovering = false
    /// 鼠标悬在哪个参考素材上 —— 决定显示编号还是 ×/@ 两个操作
    /// 输入框里光标的位置。@ 提及要插在这儿，不能一律怼到末尾
    @State private var promptCaret: Int = 0
    /// 提示词回写的防抖任务
    @State private var promptSaveWork: DispatchWorkItem?

    private static let defaultInputHeight: CGFloat = 56
    /// 上边缘热区骑在轮廓线上，内外各这么宽
    private static let edgeStraddle: CGFloat = 8

    /// 拉到最高时，**整个面板**约占画布高度的三分之二 ——
    /// 减掉的是面板里除输入框以外的部分（参考行、模型下拉那行、上下留白）
    private var maxInputHeight: CGFloat {
        let panelChrome: CGFloat = upstream.isEmpty ? 110 : 190
        return max(Self.defaultInputHeight, canvas.containerSize.height * 2 / 3 - panelChrome)
    }

    /// 这个节点连进来的上游 —— 它们是这次生成的参考
    private var upstream: [CanvasNode] { canvas.upstreamNodes(of: node.id) }

    private var category: AIVideoService.ProviderCategory { node.kind.providerCategory }

    /// 这类节点该用哪个模型。每种类型各记各的 —— 选中图片卡片就该是图片模型。
    /// 跟「重试」按钮共用同一份判断，见 AIVideoService.provider(for:) 的注释
    private var provider: AIVideoService.Provider {
        AIVideoService.provider(for: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 图片/视频卡片就算还没连上游也要显示这一行 —— 空的参考位本身
            // 就是在告诉用户「这儿能连素材进来，能连几个」
            if !upstream.isEmpty || node.kind == .image || node.kind == .video {
                referenceRow
            }

            // 换成 CanvasTextEditor（NSTextView）不用原生 TextEditor —— 原生 TextEditor
            // 的内边距是系统写死的、拿不到具体数值，占位符只能拿 padding 硬凑近似位置，
            // 凑出来的结果就是光标和占位文字对不齐（占位文字比光标低了几像素）。
            // 换成同一套渲染引擎，占位符和正文用的是同一个组件、同样的内边距参数，
            // 天然贴着同一条基线，不用再猜数字
            ZStack(alignment: .topLeading) {
                // 真正的输入框：text 绑定**永远是 $draftPrompt，不按是否为空切换**。
                // 早前改文本卡片时踩过这个坑：绑定一旦按条件切到 .constant（setter
                // 是空操作），如果那一刻 isEditable 还是 true，用户直接在这个状态下
                // 打字，第一个字符就会因为写不进去而丢失，且没有外部信号能把绑定切
                // 回正确类型，会一直卡住。占位符必须用单独一层来做，不能碰这层的绑定
                CanvasTextEditor(
                    text: $draftPrompt,
                    fontSize: 12,
                    bold: false, italic: false, underline: false, strikethrough: false,
                    colorHex: "#FFFFFF",
                    focused: false,
                    isEditable: true,
                    // 光标进了聊天框，就把文字卡片的编辑态收掉 —— 不然卡片那边
                    // 黄框还亮着，看着像两处同时在编辑。
                    // **值没变就别写** —— 这个回调每次选区变化（含每敲一个字）都会
                    // 来一趟，无脑写 nil 会让 @Published 每次都发布一次变化，
                    // 整个画布层跟着重绘一轮，白烧性能
                    onFocus: {
                        // 用户真的在这儿打字/点击了才算「在输入」——
                        // 画布的 delete / ⌘Z 据此让路
                        if !canvas.promptBarFocused { canvas.promptBarFocused = true }
                        if canvas.editingTextNodeID != nil { canvas.editingTextNodeID = nil }
                    },
                    syncRevision: canvas.textEditRevision,
                    onCaretMove: { promptCaret = $0 },
                    highlightsMentions: true)
                    .frame(height: inputHeight)

                // 占位符：独立一层，isEditable=false，不接手势 —— 点击要穿透
                // 到下面真正的输入框，不能被这层截胡。
                //
                // **用 opacity 藏，不能用 if 条件把它从视图树里摘掉**：ZStack 的
                // 子视图一增一减会改变结构标识，SwiftUI 会顺手重建兄弟节点，
                // 而 NSViewRepresentable 一重建就是新建一个 NSTextView，
                // 焦点当场丢掉 —— 表现就是「聊天框敲第一个字母，光标就没了」
                // （第一个字母正好让 draftPrompt 由空变非空，占位符层消失）
                CanvasTextEditor(
                    text: .constant(promptPlaceholder),
                    fontSize: 12,
                    bold: false, italic: false, underline: false, strikethrough: false,
                    colorHex: "#FFFFFF",
                    focused: false,
                    isEditable: false,
                    textOpacity: 0.45)
                    .frame(height: inputHeight)
                    .opacity(draftPrompt.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)
            }

            bottomRow
        }
        .padding(14)
        // 一排放得下十个缩略图（48 + 6 间距）× 10 + 左右留白，但也不能没边 ——
        // 上游多到一定程度改成缩小缩略图（见 thumbSide），面板宽度封在 720
        .frame(width: 720)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        // 调整高度的热区**骑在面板上边缘**：一半在面板内、一半在面板外，
        // 鼠标不用精确停在轮廓线上也能抓到。跟文本卡片那套一个做法
        .overlay(alignment: .top) {
            resizeHandle.offset(y: -Self.edgeStraddle)
        }
        .onAppear { draftPrompt = node.prompt }
        // 打字要**存回节点**，不然切走再回来就白写了 ——
        // 原来只有点发送时才写，草稿等于没保存。
        // 防抖 0.4 秒：每敲一个字都写的话，@Published 一变整个画布层跟着重绘
        .onChange(of: draftPrompt) { _, newValue in
            let id = node.id
            promptSaveWork?.cancel()
            let item = DispatchWorkItem { canvas.updateNode(id: id) { $0.prompt = newValue } }
            promptSaveWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }
        // 切走之前把还没落盘的那一下补上（防抖窗口里的输入）
        .onChange(of: node.id) { oldID, _ in
            flushPrompt(to: oldID)
            draftPrompt = node.prompt
            promptCaret = 0
        }
        .onDisappear { flushPrompt(to: node.id) }
        // 画布上卡片的 @ 按钮点过来的
        .onChange(of: canvas.pendingMention) { _, token in
            guard let token else { return }
            insertMention(token)
            canvas.pendingMention = nil
        }
    }

    /// 面板上边缘的拖拽条：往上拖把输入框拉高，一次能看到更多提示词。
    /// 面板挂在画布层（不在缩放变换里），所以位移不用除 zoom
    private var resizeHandle: some View {
        // 不画任何东西，就是一条骑在面板上边缘的隐形热区（上下各 8pt），
        // 鼠标一挪过去光标变成上下箭头就能拖 —— 跟文本卡片调整大小一个手感
        Color.white.opacity(0.001)
            .frame(height: Self.edgeStraddle * 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                canvas.claimCursor(inside)
                guard !canvas.isSpaceHeld else { return }   // 空格模式下光标归画布管
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                // 用 .global：手柄自己会跟着面板长高而上移，局部坐标系的参考点
                // 跟着漂，表现就是「不跟手 + 抖」
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = inputHeight }
                        let base = dragStartHeight ?? inputHeight
                        // 往上拖是变高，所以减
                        let delta = value.location.y - value.startLocation.y
                        inputHeight = min(maxInputHeight,
                                          max(Self.defaultInputHeight, base - delta))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }

    /// 上游素材区。**平铺**成一排方形缩略图（不是叠起来 + 数量角标）：
    /// 图片直接显示画面，视频显示封面 + 时长，音频显示波形 + 时长
    private var referenceRow: some View {
        // 上对齐 —— 缩略图比右边那个下拉高得多，居中的话下拉会浮在半空
        HStack(alignment: .top, spacing: 6) {
            // 素材多到一排放不下就横向滚（Seedance 2.5 有 50 个额度），
            // 右边的模式下拉留在原位不跟着滚
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { refSlots }
            }

            if node.kind == .video {
                capsule(node.usesFrameMode ? "首尾帧" : "智能参考") { showImageModeMenu() }
            } else if !upstream.isEmpty {
                // 一个参考都没连的时候不必说这句
                Text("已作为参考")
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }
        }
    }

    /// 一排素材槽位（已连上的 + 还空着的）
    @ViewBuilder
    private var refSlots: some View {
        if node.kind == .video, node.usesFrameMode {
            // 首尾帧：第一条连线是首帧、第二条是尾帧
            frameThumb(shownUpstream.first { $0.kind == .image }, label: "首帧")
            swapFramesButton
            frameThumb(shownUpstream.filter { $0.kind == .image }.dropFirst().first, label: "尾帧")
            // 非图片的上游（音频/视频/文字）照常平铺在后面
            ForEach(shownUpstream.filter { $0.kind != .image }) { up in
                refThumb(up)
            }
        } else {
            ForEach(shownUpstream) { up in refThumb(up) }
            // 把还空着的参考位也摆出来，一眼看出这个模型还能接几个
            ForEach(0..<emptyRefSlots, id: \.self) { _ in emptyRefSlot }
        }
    }

    /// 输入框的提示语。**限制数字都从模型读**，不写死 ——
    /// 各家能收的参考数量差很多（seedream 10 张、image-2 16 张），
    /// 写死的话换个模型就是错的
    private var promptPlaceholder: String {
        switch node.kind {
        case .text:
            return "描述你想生成的文字内容…"
        case .audio:
            return "描述你想生成的音频…"
        case .image:
            return "描述你想生成的图片…（参考图片最多 \(provider.maxReferenceImages) 张）"
        case .video:
            if node.usesFrameMode {
                return "描述你想生成的视频…（第一条连线是首帧，第二条是尾帧）"
            }
            let i = provider.maxReferenceImages
            let v = provider.maxReferenceVideos
            let a = provider.maxReferenceAudios
            return "描述你想生成的视频…（图片 ≤\(i)，视频 ≤\(v)，音频 ≤\(a)，总数 ≤\(provider.maxReferenceTotal)）"
        }
    }

    /// 首尾帧模式下只认头两张图，多出来的不参与生成，界面上也就别列了
    private var shownUpstream: [CanvasNode] {
        guard node.kind == .video, node.usesFrameMode else { return upstream }
        var images: [CanvasNode] = [], others: [CanvasNode] = []
        for up in upstream {
            if up.kind == .image { images.append(up) } else { others.append(up) }
        }
        return Array(images.prefix(2)) + others
    }

    /// 缩略图边长。默认 48，上游多了就缩，保证一排能摆下十个还不至于把面板撑太宽
    private var thumbSide: CGFloat {
        switch shownUpstream.count + emptyRefSlots {
        case ...6:  return 48
        case ...10: return 36
        default:    return 26      // image-2 能收 16 张，不缩一排放不下
        }
    }

    /// 还空着几个参考位。**上限跟着模型走** —— 各家能收的张数不一样
    /// （seedream 10 张、image-2 16 张），摆多了等于画饼，连上去 API 也会丢掉。
    /// 视频卡片按「总数上限」算，因为它的图/视频/音频是共用一个总额度的
    private var emptyRefSlots: Int {
        let remaining: Int
        switch node.kind {
        case .image:
            // 跟视频一样：已经连上素材就不用再摆空位了
            guard shownUpstream.isEmpty else { return 0 }
            remaining = provider.maxReferenceImages
        case .video:
            guard !node.usesFrameMode else { return 0 }   // 首尾帧有自己的两个槽
            // 已经连上素材了就不用再摆空位 —— 那会儿用户已经知道怎么加了
            guard shownUpstream.isEmpty else { return 0 }
            remaining = provider.maxReferenceTotal
        default:
            return 0
        }
        // **只留一个空位**当「还能再连」的提示，不把剩余额度全摆出来 ——
        // Seedance 2.5 有 50 个额度，摆满就是一整排空框，能连几个看提示语就行
        return remaining > 0 ? 1 : 0
    }

    /// 空的参考位。跟首尾帧的占位一样**不可点** —— 图是连线连进来的
    private var emptyRefSlot: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.06))
            .frame(width: thumbSide, height: thumbSide)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(Color.labelSecondary.opacity(0.35))
            }
            .help("把图片卡片连到这张卡片上就是参考图")
    }

    /// 首尾帧的槽位：有图显示图，没图是个占位框
    @ViewBuilder
    private func frameThumb(_ up: CanvasNode?, label: String) -> some View {
        if let up {
            refThumb(up, badge: label)
        } else {
            // 只是个占位，**不可点** —— 画布里的图是连线连进来的，
            // 不像 AI 聊天框那样点一下弹文件选择
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: thumbSide, height: thumbSide)
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.labelSecondary.opacity(0.45))
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundColor(Color.labelSecondary.opacity(0.4))
                    }
                }
                .help("把图片卡片连到这张视频卡片上，第一条连线是首帧、第二条是尾帧")
        }
    }

    /// 交换首尾帧。首尾是**按连线先后**定的，所以交换 = 把那两条连线的先后对调
    private var swapFramesButton: some View {
        // 取两张图在**入边数组里的真实下标** —— 上游可能还夹着音频/文字，
        // 直接写死 1↔0 换的就不是这两张图了，表现是「点了没反应」
        let imageSlots = upstream.enumerated()
            .filter { $0.element.kind == .image }
            .map(\.offset)
        let enabled = imageSlots.count >= 2
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                canvas.swapUpstream(of: node.id, imageSlots[0], imageSlots[1])
            }
        } label: {
            Image(nsImage: SidebarSVGIcon.load("swapFrame", size: 14))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(Color.labelSecondary.opacity(enabled ? (swapHovering ? 0.9 : 0.55) : 0.25))
                // 正方形热区，整块都能点（原来 20×20，图标周围一圈是空的，
                // 容易点进缝里）。但也不能跟缩略图一样宽 —— 那样两张图之间
                // 会空出一大截
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "交换首帧和尾帧" : "连两张图片进来才能交换")
        .onHover { swapHovering = $0 && enabled }
    }

    /// 素材在提示词里的称呼：「图1」「图2」「视频1」「音频1」。
    ///
    /// 编号**跟传给模型的顺序一致**（都是连线先后），所以用户在提示词里写
    /// 「图1 的人物」时，指的和模型收到的第一张参考图是同一张。
    /// 首尾帧模式不编号 —— 那两张有自己的「首帧/尾帧」标签
    private func refIndexLabel(_ up: CanvasNode) -> String? {
        guard !(node.kind == .video && node.usesFrameMode) else { return nil }
        let sameKind = shownUpstream.filter { $0.kind == up.kind }
        guard let idx = sameKind.firstIndex(where: { $0.id == up.id }) else { return nil }
        switch up.kind {
        case .image: return "图\(idx + 1)"
        case .video: return "视频\(idx + 1)"
        case .audio: return "音频\(idx + 1)"
        case .text:  return nil
        }
    }

    /// 一张上游素材的方形缩略图。
    ///
    /// 平时下沿标着它在提示词里的称呼（图1/视频2…）；鼠标悬上去换成两个操作：
    /// × 断开这条参考连线、@ 把它插进提示词。双击图本身把画布定位到那张卡片
    private func refThumb(_ up: CanvasNode, badge: String? = nil) -> some View {
        // **每个缩略图自己存 hover 状态**，不共用一个 hoveredRefID ——
        // SwiftUI 的 onHover 在相邻视图之间快速切换时会漏掉 exit 那一次回调，
        // 共享状态就会出现「鼠标明明在音频上，视频那张却还亮着操作按钮」
        HoverBox { hovering in
            refThumbImage(up, badge: badge)
            .overlay(alignment: .bottom) {
                // hover 时让位给操作图标，不然小小一块里挤三样东西
                if let index = refIndexLabel(up), !hovering {
                    Text(index)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        // 投影兜底：图片本身可能是浅色的，白字直接压上去会看不清
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 0.5)
                        .lineLimit(1)
                        .padding(.bottom, 2)
                }
            }
            // 双击定位**挂在图片这一层**，按钮的 overlay 加在它上面。
            // 双击手势放在最外层的话，SwiftUI 为了判断「是不是双击」会把落在
            // ×/@ 上的单击也一起等着，表现就是「按钮点不动」
            .onTapGesture(count: 2) {
                canvas.focus(on: up.id, containerSize: canvas.containerSize)
            }
            // 两个操作贴右上角竖排，× 在上
            .overlay(alignment: .topTrailing) {
                if hovering {
                    VStack(spacing: 3) {
                        thumbActionButton(system: "xmark", help: "移除这个参考") {
                            canvas.disconnect(from: up.id, to: node.id)
                        }
                        // 文字素材没有「图1」这样的称呼，@ 无从谈起，只留 ×
                        if up.kind != .text {
                            thumbActionButton(system: "at", help: "加到提示词里") {
                                mention(up)
                            }
                        }
                    }
                    .padding(2)
                }
            }
        }
    }

    /// 缩略图上的小圆按钮（×、@）
    private func thumbActionButton(system: String, help: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 把这个素材插进提示词，写成「@图1」
    private func mention(_ up: CanvasNode) {
        guard let label = refIndexLabel(up) else { return }
        insertMention("@\(label)")
    }

    /// 把当前草稿立刻写回节点，取消还在等的防抖任务
    private func flushPrompt(to nodeID: UUID) {
        promptSaveWork?.cancel()
        promptSaveWork = nil
        let text = draftPrompt
        canvas.updateNode(id: nodeID) { $0.prompt = text }
    }

    /// 在**光标处**插入一段提及文字。
    ///
    /// 不是追加到末尾、更不是替换整段 —— 用户可能正写到一半，
    /// 想在句子中间指一下「@图1」
    private func insertMention(_ token: String) {
        let ns = draftPrompt as NSString
        let loc = min(max(0, promptCaret), ns.length)
        // 前后各补一个空格，免得跟旁边的字黏成一团（已经有空格就不重复补）
        var piece = token
        if loc > 0, !ns.substring(with: NSRange(location: loc - 1, length: 1)).hasSuffix(" ") {
            piece = " " + piece
        }
        if loc >= ns.length || !ns.substring(with: NSRange(location: loc, length: 1)).hasPrefix(" ") {
            piece += " "
        }
        draftPrompt = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: piece)
        promptCaret = loc + (piece as NSString).length
        canvas.updateNode(id: node.id) { $0.prompt = draftPrompt }
        // 走「程序改的文字」那条通道，编辑中的输入框才会把新内容同步进去
        canvas.textEditRevision += 1
    }

    private func refThumbImage(_ up: CanvasNode, badge: String? = nil) -> some View {
        let side = thumbSide
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))

            switch up.kind {
            case .image, .video:
                if let cover = thumbImage(for: up) {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    typeIcon(up)
                }
            case .audio:
                // 音频画波形，跟卡片上那条同一份缓存、同一个绿色
                if let id = up.assetID, let wave = project.waveformCache[id] {
                    AudioWaveformCanvas(waveData: wave, trimStart: 0,
                                        clipDuration: max(0.1, refDuration(up)),
                                        fullHeight: true,
                                        barColor: Color(hex: "#5DB85D").opacity(0.5))
                } else {
                    typeIcon(up)
                }
            case .text:
                // 把正文缩排进去 —— 只放一个 T 图标的话，这张看着像是空的，
                // 认不出引用的是哪段文字
                let body = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    typeIcon(up)
                } else {
                    // 按 markdown 渲染后再缩排，跟卡片默认态看到的是同一个样子 ——
                    // 直接显示源码的话缩略图里全是 # 和 **，反而看不清写了啥。
                    // 字号跟着缩略图大小走：缩到 26/18pt 时还用固定字号
                    // 就只能塞下两三个字
                    Text(AttributedString(CanvasMarkdown.render(
                        body, baseFontSize: max(4.5, side * 0.12), colorHex: "#FFFFFF",
                        scalesHeadings: false)))
                        .lineSpacing(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(3)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // 把 hover / 点击的判定范围锁死在这块方图上 —— 不锁的话
        // overlay 里的按钮、投影这些会把可命中的范围往外撑，
        // 鼠标还在这张图里，旁边那张就先亮了
        .contentShape(RoundedRectangle(cornerRadius: 6))
        // 时长贴左上角。不垫底色，靠投影跟画面拉开 ——
        // 缩略图就这么大，再加个胶囊底会显得很挤
        .overlay(alignment: .topLeading) {
            if up.kind == .video || up.kind == .audio, refDuration(up) > 0 {
                Text(canvasTimeText(refDuration(up)))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, y: 0.5)
                    .padding(3)
            }
        }
        // 首帧/尾帧标签压在左上角
        .overlay(alignment: .topLeading) {
            if let badge {
                Text(badge)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accent))
                    .padding(2)
            }
        }
        .help(refLabel(up))
    }

    private func showImageModeMenu() {
        let menu = NSMenu()
        for (title, isFrame) in [("智能参考", false), ("首尾帧", true)] {
            let item = NSMenuItem(title: title, action: #selector(MenuBridge.pickImageMode(_:)),
                                  keyEquivalent: "")
            item.state = (node.usesFrameMode == isFrame) ? .on : .off
            item.representedObject = isFrame
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        let nodeID = node.id
        MenuBridge.shared.onPickImageMode = { isFrame in
            canvas.updateNode(id: nodeID) { $0.usesFrameMode = isFrame }
        }
        popUp(menu)
    }

    private func typeIcon(_ up: CanvasNode) -> some View {
        Image(nsImage: SidebarSVGIcon.load(CanvasNodeView.iconKey(for: up.kind), size: 16))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .foregroundColor(Color.labelSecondary.opacity(0.45))
    }

    /// 缩略图：优先用素材库那份缓存（跟时间轴/素材库共用，不重复抽帧）
    private func thumbImage(for up: CanvasNode) -> NSImage? {
        if let id = up.assetID, let t = project.mediaThumbnails[id] { return t }
        guard up.kind == .image, let url = up.mediaURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private func refDuration(_ up: CanvasNode) -> Double {
        if let id = up.assetID,
           let a = project.mediaAssets.first(where: { $0.id == id }), a.duration > 0 {
            return a.duration
        }
        guard let url = up.mediaURL else { return 0 }
        return AVURLAsset(url: url).duration.seconds
    }

    private func refLabel(_ up: CanvasNode) -> String {
        switch up.kind {
        case .text:
            let t = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "文本" : String(t.prefix(10))
        default:
            return up.mediaURL?.lastPathComponent ?? up.kind.label
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            // 供应商 + 子模型，跟 AI 面板一样按类型过滤
            capsule(currentProviderLabel) { showProviderMenu() }
            if !provider.subModels.isEmpty {
                capsule(currentSubModelLabel) { showSubModelMenu() }
            }
            if node.kind != .text && node.kind != .audio {
                capsule(ratioLabel) { showRatioMenu() }
            }
            // 视频还要选时长和清晰度
            if node.kind == .video {
                capsule("\(settings.aiDuration)s") { showDurationMenu() }
                capsule(settings.aiResolution) { showResolutionMenu() }
            }
            // 文字模型：推理强度在前，联网在后
            if node.kind == .text {
                if !provider.reasoningLevels.isEmpty {
                    capsule(reasoningLabel) { showReasoningMenu() }
                }
                if provider.supportsWebSearch || !settings.braveSearchKey.isEmpty || !settings.tavilySearchKey.isEmpty {
                    Button { service.webSearchEnabled.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: SidebarSVGIcon.load("webSearch", size: 11))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                            Text("联网").font(.system(size: 10))
                        }
                        .foregroundColor(service.webSearchEnabled ? Color.accent : Color.labelSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(service.webSearchEnabled ? 0.14 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("让模型联网查资料")
                }
            }

            Spacer()

            if node.isGenerating || node.isWaiting {
                Button { canvas.cancelGeneration(nodeID: node.id) } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(node.isWaiting ? "等上游" : "生成中")
                            .font(.system(size: 11))
                            .foregroundColor(Color.labelSecondary)
                    }
                }
                .buttonStyle(.plain)
                .help("点一下取消")
            } else {
                Button { submit() } label: {
                    Image(nsImage: SidebarSVGIcon.load("send", size: 16))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var currentProviderLabel: String { provider.displayName }

    private var currentSubModelLabel: String {
        let saved = settings.providerModel(for: provider.rawValue)
        return provider.subModels.first { $0.id == saved }?.label
            ?? provider.subModels.first?.label ?? ""
    }

    private var ratioLabel: String {
        node.kind == .image ? settings.aiImageRatio : settings.aiRatio
    }

    /// 下拉。**不加背景**，只有文字 + 一个小箭头
    private func capsule(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundColor(Color.labelSecondary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 下拉

    /// 只列跟这个节点类型对得上的供应商 —— 图片节点没必要列视频模型
    private var matchingProviders: [AIVideoService.Provider] {
        AIVideoService.Provider.allCases.filter { !$0.isHidden && $0.category == category }
    }

    private func showProviderMenu() {
        let menu = NSMenu()
        for p in matchingProviders {
            let item = NSMenuItem(title: p.displayName, action: nil, keyEquivalent: "")
            item.representedObject = p.rawValue
            item.target = MenuBridge.shared
            item.action = #selector(MenuBridge.pickProvider(_:))
            menu.addItem(item)
        }
        let cat = category.rawValue
        MenuBridge.shared.onPickProvider = { raw in
            settings.setCanvasProvider(raw, for: cat)
        }
        popUp(menu)
    }

    private func showSubModelMenu() {
        let menu = NSMenu()
        let provider = self.provider
        for m in provider.subModels {
            let item = NSMenuItem(title: m.label, action: #selector(MenuBridge.pickSubModel(_:)), keyEquivalent: "")
            item.representedObject = m.id
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickSubModel = { id in
            settings.setProviderModel(id, for: provider.rawValue)
        }
        popUp(menu)
    }

    private func showRatioMenu() {
        let menu = NSMenu()
        let options = node.kind == .image
            ? ["1:1", "16:9", "9:16", "4:3", "3:4", "21:9"]
            : ["16:9", "9:16", "1:1", "4:3"]
        for r in options {
            let item = NSMenuItem(title: r, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = r
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        let isImage = node.kind == .image
        let nodeID = node.id
        MenuBridge.shared.onPickRatio = { [weak canvas] r in
            if isImage { settings.aiImageRatio = r } else { settings.aiRatio = r }
            canvas?.setRatio(r, for: nodeID)   // 卡片跟着变形
        }
        popUp(menu)
    }

    private var reasoningLabel: String {
        let saved = settings.providerReasoning(for: provider.rawValue)
        return provider.reasoningLevels.first { $0.value == saved }?.label
            ?? provider.reasoningLevels.first?.label ?? "推理"
    }

    private func showDurationMenu() {
        let menu = NSMenu()
        for d in ["4", "5", "6", "8", "10"] {
            let item = NSMenuItem(title: "\(d) 秒", action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = d
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.aiDuration = $0 }
        popUp(menu)
    }

    private func showResolutionMenu() {
        let menu = NSMenu()
        for r in ["480P", "720P", "1080P"] {
            let item = NSMenuItem(title: r, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = r
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.aiResolution = $0 }
        popUp(menu)
    }

    private func showReasoningMenu() {
        let menu = NSMenu()
        let p = provider
        for level in p.reasoningLevels {
            let item = NSMenuItem(title: level.label, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = level.value
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.setProviderReasoning($0, for: p.rawValue) }
        popUp(menu)
    }

    private func popUp(_ menu: NSMenu) {
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    private func submit() {
        canvas.updateNode(id: node.id) { $0.prompt = draftPrompt }
        canvas.submitGeneration(nodeID: node.id, provider: provider)
    }
}

/// NSMenu 的 target 得是 NSObject。SwiftUI 结构体当不了 target，
/// 拿一个常驻的桥接对象转发
final class MenuBridge: NSObject {
    static let shared = MenuBridge()
    var onPickProvider: ((String) -> Void)?
    var onPickSubModel: ((String) -> Void)?
    var onPickRatio: ((String) -> Void)?
    var onPickImageMode: ((Bool) -> Void)?

    @objc func pickProvider(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String { onPickProvider?(raw) }
    }
    @objc func pickSubModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onPickSubModel?(id) }
    }
    @objc func pickRatio(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? String { onPickRatio?(r) }
    }
    @objc func pickImageMode(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? Bool { onPickImageMode?(f) }
    }
}

/// 自带 hover 状态的小容器。
///
/// 一排里有好几个元素时，**别用一个共享的 hoveredID 去区分谁在 hover** ——
/// SwiftUI 的 onHover 在相邻视图之间快速划过时会漏掉 exit 回调，
/// 共享状态就会留在上一个元素身上，表现是「鼠标在这个上面，那个却亮着」。
/// 各存各的就不会串
struct HoverBox<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovering)
            // 用 onContinuousHover 而不是 onHover：
            // onHover 只在进、出各报一次，鼠标在相邻元素之间快速划过时那次「出」
            // 很容易丢，状态就卡在 true 上（表现是「鼠标明明在音频上，
            // 旁边那张却还亮着操作按钮」）。
            // onContinuousHover 只要指针还在里面就一直报 active，
            // 离开立刻报 ended，不依赖单次事件送达
            .onContinuousHover { phase in
                switch phase {
                case .active: if !hovering { hovering = true }
                case .ended:  if hovering { hovering = false }
                }
            }
    }
}
