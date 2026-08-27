import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct AIChatPanel: View {
    @EnvironmentObject private var project: ProjectState
    @StateObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var inputText = ""
    /// 进面板默认就是历史列表 —— 用户过来多半是要找之前那条，
    /// 而不是从空白开始
    @State private var showHistory = true
    @State private var swapHovering = false
    /// 鼠标停在哪一条历史上。方法产出的行没法各自持 @State，只能记 id
    @State private var hoverHistoryID: UUID?

    /// 正在重命名的历史会话
    @State private var renamingConversationID: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool

    // 输入区状态存在 service 上，切 tab 重建 View 时不丢失
    private typealias RefContentType = AIVideoService.RefContentType
    private typealias RefContent = AIVideoService.RefContent
    private typealias ImageInputMode = AIVideoService.ImageInputMode

    private var referenceContents: [RefContent] {
        get { service.referenceContents }
        nonmutating set { service.referenceContents = newValue }
    }
    private var firstFrameImage: (url: URL, image: NSImage)? {
        get { service.firstFrameImage }
        nonmutating set { service.firstFrameImage = newValue }
    }
    private var lastFrameImage: (url: URL, image: NSImage)? {
        get { service.lastFrameImage }
        nonmutating set { service.lastFrameImage = newValue }
    }
    private var imageMode: ImageInputMode {
        get { service.imageMode }
        nonmutating set { service.imageMode = newValue }
    }

    /// 时长按供应商/子模型给 —— 各家上限差很多，列出人家不收的档位等于挖坑
    private var durations: [String] {
        switch service.selectedProvider {
        case .seedance:
            // 2.5 单次能出到 30s，2.0 上限 15s
            return currentSubModel == "2.5"
                ? ["5", "10", "15", "20", "25", "30"]
                : ["5", "10", "15"]
        case .minimax:
            return ["4", "6", "8", "10", "12", "15"]      // 官方 4~15s
        default:
            return ["4", "5", "6", "7", "8", "9", "10"]
        }
    }

    /// 当前时长；换供应商后原来的档位这家不收时，退回它支持的第一档
    private var currentDuration: String {
        durations.contains(settings.aiDuration) ? settings.aiDuration : (durations.first ?? "5")
    }
    private let ratios = ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]

    /// 分辨率按供应商给 —— 列出人家不认的档位，选了也是白选（会被静默换掉）
    private var resolutions: [String] {
        switch service.selectedProvider {
        case .minimax: return ["768P", "2K"]        // H3 只有这两档
        case .seedance:
            // 2.5 目前只开放到 720P，1080P/4K 还没上
            return currentSubModel == "2.5" ? ["480P", "720P"] : ["480P", "720P", "1080P"]
        default:       return ["480P", "720P", "1080P", "4K"]
        }
    }

    /// 当前分辨率；上一个供应商选的档位这家不认时，退回它支持的第一档
    private var currentResolution: String {
        let list = resolutions
        return list.contains(settings.aiResolution) ? settings.aiResolution : (list.first ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvasEntry
            // 历史会话展开时**替换**整个会话区。
            // 用 ZStack 盖一层的话得给它一个不透明底色才挡得住下面的消息，
            // 那块底色跟面板不搭；直接替换就没这问题
            if showHistory {
                historyOverlay
            } else {
                messageList
                inputArea
            }
        }
        .onChange(of: service.selectedProvider) { _ in
            pruneInputsForProvider()
        }
        // 试听播放器是单例，view 销毁不会带走它 —— 切会话和关面板都得手动停，否则声音继续响
        .onChange(of: service.currentConversationId) { _ in
            AIInlinePlayer.shared.stop()
        }
        .onDisappear { AIInlinePlayer.shared.stop() }
    }

    /// 切换模型后，裁掉新模型不支持的参考内容，避免带着旧模型的数据发出去被静默丢弃
    private func pruneInputsForProvider() {
        let provider = service.selectedProvider
        if !provider.supportsLastFrame { lastFrameImage = nil }
        if !provider.supportsFirstFrame { firstFrameImage = nil }

        var kept: [RefContent] = []
        var imgCount = 0, vidCount = 0, audCount = 0
        for item in referenceContents {
            guard kept.count < provider.maxReferenceTotal else { break }
            switch item.type {
            case .image where imgCount < provider.maxReferenceImages: imgCount += 1
            case .video where vidCount < provider.maxReferenceVideos: vidCount += 1
            case .audio where audCount < provider.maxReferenceAudios: audCount += 1
            default: continue
            }
            kept.append(item)
        }
        if kept.count != referenceContents.count { referenceContents = kept }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack {
            Text("AI 创作")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
                .textCase(.uppercase)
            Spacer()
            // 进面板默认就停在历史列表上，这时候再放个「历史会话」图标是多余的；
            // 进了某条会话（showHistory = false）才需要它退回列表。
            // 新建那两个入口挪到下面的卡片上了，这儿不再重复
            if !showHistory {
                HoverIconButton(icon: "clock", svgName: "chatHistory", tip: "历史会话") {
                    withAnimation(.easeInOut(duration: 0.18)) { showHistory = true }
                }
            }
        }
        // **高度按图标那 24pt 定死**：历史列表页不画右侧图标，
        // 不撑着的话这一行会矮一截，两页之间标题就上下跳
        .frame(height: 24)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        // 顶部留白跟素材库那栏对齐（那边也是 8）——
        // 两栏切换时标题行不该上下跳
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - 历史会话

    /// 两个新建入口，并排放在会话区最上面
    private var canvasEntry: some View {
        HStack(spacing: 8) {
            EntryCard(svgName: "freeCanvas", title: "新建画布") {
                let id = service.newCanvasConversation()
                project.canvas.reset(conversationID: id)
                project.showCanvas = true
            }
            EntryCard(svgName: "newChat", title: "新建会话") {
                service.newConversation()
                showHistory = false   // 建完直接进新会话，不留在列表里
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// 历史会话列表。展开时**铺满整个会话区** —— 之前限死 170pt，
    /// 会话一多就挤在上面一小条里，得在那点高度里滚
    private var historyOverlay: some View {
        VStack(spacing: 0) {
            if service.history.isEmpty {
                Spacer()
                Text("还没有历史会话")
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    // 间距走 VStack 的 spacing，不动每行自己的内边距 ——
                    // 那样 hover / 选中的底色块高度不会跟着变
                    VStack(spacing: 5) {
                        ForEach(service.history) { conv in
                            historyRow(conv)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                // 点列表空白处：正在重命名就提交。失焦本身也会提交（见 TextField
                // 那边的 onChange），这里是兜底 —— 万一点到的空白区域接不住焦点转移
                .contentShape(Rectangle())
                .onTapGesture { commitRename() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 提交重命名。标题为空就当取消，不写回
    private func commitRename() {
        guard let id = renamingConversationID else { return }
        service.renameConversation(id, title: renameDraft)
        if project.canvas.conversationID == id, !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.canvas.title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        renamingConversationID = nil
    }

    @ViewBuilder
    private func historyRow(_ conv: AIVideoService.ConversationRecord) -> some View {
        let isActive = conv.id == service.currentConversationId
        let isRenaming = renamingConversationID == conv.id
        Button {
            guard !isRenaming else { return }   // 重命名中点这一行不该跳转
            if conv.isCanvas {
                // 画布类记录：还原到画布里打开，不当聊天加载。
                // **不收起历史列表** —— 画布是全屏盖上去的，关掉它应该退回原来那个列表，
                // 而不是莫名其妙落到一个空对话界面
                if let snap = conv.canvas {
                    project.canvas.restore(from: snap, conversationID: conv.id, title: conv.title)
                }
                project.showCanvas = true
            } else {
                service.loadConversation(conv.id)
                showHistory = false
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if isRenaming {
                            // 原地把标题换成输入框，样式跟旁边的 Text 对齐 ——
                            // 不然行内一换成 TextField 高度/位置会跳一下
                            TextField("", text: $renameDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                                .focused($renameFieldFocused)
                                .onSubmit { commitRename() }
                                .onChange(of: renameFieldFocused) { _, focused in
                                    if !focused { commitRename() }
                                }
                                .onExitCommand { renamingConversationID = nil }
                        } else {
                            Text(conv.title)
                                .font(.system(size: 11))
                                .foregroundColor(isActive ? .white : Color.labelPrimary)
                                .lineLimit(1)
                        }
                        // 画布类挂个小标签区分；普通对话什么都不加
                        if conv.isCanvas {
                            Text("画布")
                                .font(.system(size: 9))
                                .foregroundColor(Color.labelSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                        }
                    }
                    Text(formatDate(conv.createdAt))
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isActive ? Color.white.opacity(0.1)
                                 : (hoverHistoryID == conv.id ? Color.white.opacity(0.06)
                                                              : Color.clear))
            .cornerRadius(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoverHistoryID = conv.id }
            else if hoverHistoryID == conv.id { hoverHistoryID = nil }
        }
        .contextMenu {
            Button { startRenaming(conv) } label: {
                Image(nsImage: SidebarSVGIcon.load("rename", size: 14))
                Text("重命名")
            }
            Button(role: .destructive) { service.deleteConversation(conv.id) } label: {
                Image(nsImage: TimelineSVGIcon.load("delete", size: 14))
                Text("删除")
            }
        }
    }

    private func startRenaming(_ conv: AIVideoService.ConversationRecord) {
        renameDraft = conv.title
        renamingConversationID = conv.id
        // 键盘焦点要等 TextField 真正出现在树上才能抢，同一帧抢不到
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            return "今天 " + fmt.string(from: date)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 消息列表

    @ViewBuilder
    private var messageList: some View {
        // 空状态放在 ScrollView **外面**：PositionedAtOneThird 靠 GeometryReader 读高度，
        // 而 ScrollView 内容高度是自适应的，塞进去会塌陷成 0，三分之一定位就失效了
        if service.messages.isEmpty {
            emptyHint
        } else {
            messageScrollView
        }
    }

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(service.messages) { msg in
                        MessageBubble(message: msg, onInsertToTimeline: { url in
                            insertMediaToTimeline(url)
                        }, onRestoreAttachment: { att in
                            restoreAttachment(att)
                        })
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: service.messages.count) { _ in scrollToLast(proxy) }
            // 生成完成时消息条数**没变**：同一条 assistant 消息的 status 从 .generating
            // 变成 .completed 并挂上视频卡片。只看 count 就不会滚，用户得自己往下拖
            .onChange(of: service.messages.last?.status) { _ in
                scrollToLast(proxy, waitForLayout: true)
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, waitForLayout: Bool = false) {
        guard let last = service.messages.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        // 视频卡片是状态变完成之后才挂上去的，挂上去气泡才变高 —— 这一下只能滚到
        // 旧高度，等布局稳定再补一次才真到底
        guard waitForLayout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyHint: some View {
        // 跟素材库空状态同一套：44pt 图标 0.30、11pt 文字 0.45、间距 10、
        // 摆在上方三分之一处。图标按当前选的生成类型走素材库对应的那张
        VStack(spacing: 10) {
            Image(nsImage: SidebarSVGIcon.load(emptyHintIcon, size: 44))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .foregroundColor(Color.labelSecondary.opacity(0.30))
            Text(emptyHintText)
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .modifier(PositionedAtOneThird())
    }

    /// 生成类型 → 素材库同款图标
    private var emptyHintIcon: String {
        switch service.selectedProvider.category {
        case .video: return "video"
        case .image: return "image"
        case .audio: return "audio"
        case .text:  return "ai"      // 文字对话用 AI 生成自己的图标
        }
    }

    // MARK: - 输入区域

    /// 输入框高度，可以拖上边缘调。30 是一行的高度，上限给到 300 够写长提示词了
    @State private var inputHeight: CGFloat = 50
    @State private var dragStartHeight: CGFloat? = nil
    @State private var isResizing = false

    /// 正文行距。目标是 1.4 倍行高（12pt 字 → 16.8pt 行高），
    /// 而 lineSpacing 加的是行间额外间距，默认单行已占约 14.3pt，所以补 2.5。
    /// 模型回复、用户气泡、输入框三处共用这一个值
    static let bodyLineSpacing: CGFloat = 2.5

    private var inputArea: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if service.selectedProvider.maxReferenceImages > 0 {
                        imagePreviewArea
                    }
                    Spacer()
                    // 子模型紧挨着供应商下拉左边：先选哪一家，再选它下面哪个型号，
                    // 从左往右读正好是「Seedance2.0 → Seedance」这个层级。
                    // 外层 HStack 是 .top 对齐（迁就参考图区），这两个下拉要单独居中对齐
                    HStack(alignment: .center, spacing: 0) {
                        if !service.selectedProvider.subModels.isEmpty {
                            capsuleMenu(label: currentSubModelLabel) {
                                ForEach(service.selectedProvider.subModels, id: \.id) { m in
                                    Button(m.label) {
                                        settings.setProviderModel(m.id, for: service.selectedProvider.rawValue)
                                    }
                                }
                            }
                        }
                        Button { showProviderMenu() } label: {
                            HStack(spacing: 3) {
                                Text(service.selectedProvider.displayName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                ChatInputTextView(
                    text: $inputText,
                    onAddSubtitle: { project.insertSubtitleAtPlayhead(text: $0) },
                    onAddTitle: { project.addTextAtPlayhead(text: $0) },
                    onSubmit: { sendMessage() }
                )
                    .frame(height: inputHeight)
                    .animation(nil, value: inputHeight)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .overlay(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text(inputPlaceholder)
                                .font(.system(size: 12))
                                .foregroundColor(Color.labelSecondary.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 4) {
                    if service.selectedProvider.category == .video {
                        capsuleMenu(label: imageMode == .reference ? refSlotLabel : imageMode.label) {
                            Button {
                                firstFrameImage = nil; lastFrameImage = nil
                                imageMode = .reference
                            } label: { Text(refSlotLabel) }
                            Button {
                                referenceContents.removeAll()
                                imageMode = .frames
                            } label: { Text("首尾帧") }
                        }
                        capsuleMenu(label: currentDuration + "s") {
                            ForEach(durations, id: \.self) { d in
                                Button(d + "s") { settings.aiDuration = d }
                            }
                        }
                        capsuleMenu(label: settings.aiRatio) {
                            ForEach(ratios, id: \.self) { r in
                                Button(r) { settings.aiRatio = r }
                            }
                        }
                        capsuleMenu(label: currentResolution) {
                            ForEach(resolutions, id: \.self) { r in
                                Button(r) { settings.aiResolution = r }
                            }
                        }
                    } else if service.selectedProvider.category == .image {
                        capsuleMenu(label: settings.aiImageRatio) {
                            ForEach(ratios, id: \.self) { r in
                                Button(r) { settings.aiImageRatio = r }
                            }
                        }
                    }

                    if service.selectedProvider.supportsWebSearch {
                        Button {
                            service.webSearchEnabled.toggle()
                        } label: {
                            HStack(spacing: 2) {
                                Image(nsImage: SidebarSVGIcon.load("webSearch", size: 11))
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 11, height: 11)
                                Text("联网")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(service.webSearchEnabled ? Color.accent : Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(service.webSearchEnabled ? Color.accent.opacity(0.15) : Color.white.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // 推理强度：挨着联网放。只有一档清单的时候没必要再套一层级联菜单
                    if !service.selectedProvider.reasoningLevels.isEmpty {
                        capsuleMenu(label: currentReasoningLabel) {
                            ForEach(service.selectedProvider.reasoningLevels, id: \.value) { lv in
                                Button(lv.label) {
                                    settings.setProviderReasoning(lv.value, for: service.selectedProvider.rawValue)
                                }
                            }
                        }
                    }

                    Spacer()

                    // 生成中也照常显示发送按钮 —— 多任务之后可以接着发下一条。
                    // 停止只在每条生成中的消息气泡上，不在这里做全局停止
                    Button { sendMessage() } label: {
                        Image(nsImage: SidebarSVGIcon.load("send", size: 16))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            // 跟素材区左侧那排图标同一个默认灰；不可发送时再压暗
                            .foregroundColor(canSend ? Color.labelSecondary
                                                     : Color.labelSecondary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .clipped()
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // 拖动热区：跨在输入框上边缘，上下各 8pt。
            //
            // 必须挂在这一层（气泡本体）而不是外层容器 —— 外层还有 8pt 的
            // top padding，挂那儿热区会落在气泡上方的空白里，跟看到的边缘错开，
            // 表现就是"有时能拖有时拖不动"。
            // 放在 clipShape 之后，超出边界的那一半才不会被裁掉
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .offset(y: -8)
                    .onHover { hovering in
                        // 拖动中鼠标会甩出热区，这时不能把光标改回箭头，否则一路闪
                        if hovering || isResizing { NSCursor.resizeUpDown.set() }
                        else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        // .global 坐标系：热区会随输入框变高而上移，
                        // 局部坐标系下参考点跟着漂，拖起来不跟手
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { v in
                                if !isResizing {
                                    isResizing = true
                                    dragStartHeight = inputHeight
                                    NSCursor.resizeUpDown.set()
                                }
                                let start = dragStartHeight ?? inputHeight
                                inputHeight = min(300, max(30, start - v.translation.height))
                            }
                            .onEnded { _ in
                                isResizing = false
                                dragStartHeight = nil
                            }
                    )
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func capsuleMenu<Content: View>(label: String, active: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        Menu { content() } label: {
            Text(label)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(active ? Color.accent : Color.labelSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(active ? Color.accent.opacity(0.15) : Color.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .tint(Color.labelSecondary)
    }

    // MARK: - 图片预览区

    private var imagePreviewArea: some View {
        HStack(spacing: 2) {
            if imageMode == .reference || service.selectedProvider.category != .video {
                refContentSlot
            } else {
                frameSlot(image: firstFrameImage, label: "首帧") {
                    pickSingleImage { u, i in firstFrameImage = (u, i) }
                }
                // 只有支持尾帧的模型才显示尾帧槽，否则用户设了会被 API 静默丢弃
                if service.selectedProvider.supportsLastFrame {
                    swapFramesButton
                    frameSlot(image: lastFrameImage, label: "尾帧") {
                        pickSingleImage { u, i in lastFrameImage = (u, i) }
                    }
                }
            }
        }
    }

    /// 首尾帧互换：两个槽位都空时不可点
    private var swapFramesButton: some View {
        let enabled = firstFrameImage != nil || lastFrameImage != nil
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                let tmp = firstFrameImage
                firstFrameImage = lastFrameImage
                lastFrameImage = tmp
            }
        } label: {
            Image(nsImage: SidebarSVGIcon.load("swapFrame", size: 14))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(Color.labelSecondary.opacity(enabled ? (swapHovering ? 0.9 : 0.55) : 0.25))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "交换首帧和尾帧" : "先添加首帧或尾帧")
        .onHover { swapHovering = $0 && enabled }
    }

    /// 只收图片的模型显示「参考图」，能收视频/音频的才叫「参考内容」
    private var refSlotLabel: String {
        let p = service.selectedProvider
        return (p.maxReferenceVideos == 0 && p.maxReferenceAudios == 0) ? "参考图" : "参考内容"
    }

    private var refContentSlot: some View {
        Group {
            if referenceContents.isEmpty {
                placeholderSlot(label: refSlotLabel, icon: "photo.badge.plus") { pickRefContents() }
            } else {
                ZStack {
                    fanThumbnails
                }
                .frame(width: refFanWidth, height: 48)
                .overlay(alignment: .topLeading) {
                    if referenceContents.count > 1 {
                        Text("\(referenceContents.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 14, height: 14)
                            .background(Color.accent)
                            .clipShape(Circle())
                            .offset(x: -3, y: -3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    deleteBadge { referenceContents.removeAll() }
                }
                .onTapGesture { pickRefContents() }
            }
        }
    }

    private var refFanWidth: CGFloat {
        let count = min(referenceContents.count, 3)
        return count <= 1 ? 48 : 48 + CGFloat(count - 1) * 8
    }

    private var fanThumbnails: some View {
        let items = Array(referenceContents.prefix(3))
        let count = items.count
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let angle = count == 1 ? 0.0 : Double(i - (count - 1)) * 8.0 + Double(count - 1) * 4.0
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .overlay(alignment: .bottomTrailing) {
                        if item.type == .video {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(2)
                        } else if item.type == .audio {
                            Image(systemName: "waveform")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(2)
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .rotationEffect(.degrees(angle))
            }
        }
    }

    private func frameSlot(image: (url: URL, image: NSImage)?, label: String, onPick: @escaping () -> Void) -> some View {
        Group {
            if let img = image {
                Image(nsImage: img.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        deleteBadge {
                            if label == "首帧" { firstFrameImage = nil } else { lastFrameImage = nil }
                        }
                    }
                    .onTapGesture(perform: onPick)
            } else {
                placeholderSlot(label: label, icon: "photo", action: onPick)
            }
        }
    }

    /// 统一的删除角标：白圈 + 深色叉，垫深色底保证压在浅色图片上时观感一致
    private func deleteBadge(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .background {
                    Circle()
                        .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
                        .frame(width: 10, height: 10)
                }
        }
        .buttonStyle(.plain)
        .offset(x: 2, y: -3)
    }

    private func placeholderSlot(label: String, icon: String = "photo", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 48, height: 48)
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.labelSecondary.opacity(0.45))
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundColor(Color.labelSecondary.opacity(0.4))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 参考内容选择

    private static let imageExts = AIVideoService.imageExts
    private static let videoExts = AIVideoService.videoExts
    private static let audioExts = AIVideoService.audioExts

    private func pickRefContents() {
        let provider = service.selectedProvider
        let maxImg = provider.maxReferenceImages
        let maxVid = provider.maxReferenceVideos
        let maxAud = provider.maxReferenceAudios
        let totalLimit = provider.maxReferenceTotal
        let remaining = totalLimit - referenceContents.count
        guard remaining > 0 else { return }

        var types: [UTType] = []
        if maxImg > 0 { types.append(.image) }
        if maxVid > 0 { types.append(.movie) }
        if maxAud > 0 { types.append(.audio) }
        guard !types.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = totalLimit > 1
        panel.canChooseDirectories = false
        var limitParts: [String] = []
        if maxImg > 0 { limitParts.append("图片≤\(maxImg)") }
        if maxVid > 0 { limitParts.append("视频≤\(maxVid)") }
        if maxAud > 0 { limitParts.append("音频≤\(maxAud)") }
        panel.message = limitParts.count == 1
            ? "选择\(refSlotLabel)（最多 \(maxImg) 张）"
            : "选择\(refSlotLabel)（\(limitParts.joined(separator: " ")) 总数≤\(totalLimit)）"
        panel.begin { [self] response in
            guard response == .OK else { return }
            let urls = Array(panel.urls.prefix(remaining))
            var imgCount = referenceContents.filter { $0.type == .image }.count
            var vidCount = referenceContents.filter { $0.type == .video }.count
            var audCount = referenceContents.filter { $0.type == .audio }.count
            var newItems: [RefContent] = []
            for u in urls {
                let ext = u.pathExtension.lowercased()
                if Self.imageExts.contains(ext), imgCount < maxImg {
                    if let img = NSImage(contentsOf: u) {
                        newItems.append(RefContent(url: u, type: .image, thumbnail: img.thumbnailImage(maxSize: 200)))
                        imgCount += 1
                    }
                } else if Self.videoExts.contains(ext), vidCount < maxVid {
                    let thumb = Self.videoThumbnail(url: u)
                    newItems.append(RefContent(url: u, type: .video, thumbnail: thumb))
                    vidCount += 1
                } else if Self.audioExts.contains(ext), audCount < maxAud {
                    let thumb = Self.audioThumbnail()
                    newItems.append(RefContent(url: u, type: .audio, thumbnail: thumb))
                    audCount += 1
                }
                if referenceContents.count + newItems.count >= totalLimit { break }
            }
            DispatchQueue.main.async { referenceContents.append(contentsOf: newItems) }
        }
    }

    /// 点击历史消息里的附件缩略图回填输入区。
    /// 去向只看当前处于哪个模式，不切模式；首尾帧按点击先后决定角色。
    private func restoreAttachment(_ att: AIVideoService.Attachment) {
        guard let url = att.resolvedURL() else {
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "文件已不存在", subtitle: att.url.lastPathComponent.truncatedFileName())
            return
        }
        switch service.addToReference(url: url) {
        case .added, .duplicate:
            break
        case .unsupportedType:
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "不支持当前素材类型", subtitle: "当前占位不接受该类型素材")
        case .limitReached(let msg):
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "无法添加", subtitle: msg)
        }
    }

    private static func videoThumbnail(url: URL) -> NSImage { AIVideoService.videoFrameThumbnail(url: url) }
    private static func audioThumbnail() -> NSImage { AIVideoService.audioPlaceholderThumbnail() }

    private func pickSingleImage(completion: @escaping (URL, NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
            let thumb = img.thumbnailImage(maxSize: 200)
            DispatchQueue.main.async { completion(url, thumb) }
        }
    }

    // MARK: - Actions

    private var inputPlaceholder: String {
        switch service.selectedProvider.category {
        case .video: return "描述你想生成的视频…"
        case .image: return "描述你想生成的图片…"
        case .audio: return "描述你想生成的声音…"
        case .text: return "输入你的问题…"
        }
    }

    /// 当前选中的子模型（发给 API 的那个名字）；没选过就用清单第一项
    private var currentSubModel: String {
        let saved = settings.providerModel(for: service.selectedProvider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty {
            // 旧配置存的是显示名，换算成 id（勾选状态才对得上）
            let list = service.selectedProvider.subModels
            return list.first { $0.label == saved }?.id ?? saved
        }
        return service.selectedProvider.subModels.first?.id ?? ""
    }

    /// 界面上显示的子模型名。
    /// 早期版本把显示名当 API 名存了（"Opus5"），这里按 label 兜一次底，
    /// 让旧配置也能对上，不至于显示成一串陌生的 id
    private var currentSubModelLabel: String {
        let v = currentSubModel
        let list = service.selectedProvider.subModels
        return list.first { $0.id == v }?.label
            ?? list.first { $0.label == v }?.label
            ?? v
    }

    /// 当前推理强度取值；没选过就用该家默认（清单第一项）
    private var currentReasoningValue: String {
        let saved = settings.providerReasoning(for: service.selectedProvider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return service.selectedProvider.reasoningLevels.first?.value ?? ""
    }

    private var currentReasoningLabel: String {
        let v = currentReasoningValue
        return service.selectedProvider.reasoningLevels.first { $0.value == v }?.label ?? v
    }

    private var emptyHintText: String {
        switch service.selectedProvider.category {
        case .video: return "描述你想生成的视频"
        case .image: return "描述你想生成的图片"
        case .audio: return "描述你想生成的声音"
        case .text: return "开始对话"
        }
    }

    private func showProviderMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 180
        IPickerItemHandler.shared.actions.removeAll()
        var tag = 0
        for cat in AIVideoService.ProviderCategory.allCases {
            let header = NSMenuItem(title: cat.rawValue, action: nil, keyEquivalent: "")
            header.isEnabled = false
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            header.attributedTitle = NSAttributedString(string: cat.rawValue, attributes: attrs)
            menu.addItem(header)

            for provider in AIVideoService.Provider.providers(for: cat) {
                let item = NSMenuItem(title: provider.displayName,
                                      action: #selector(IPickerItemHandler.pick(_:)),
                                      keyEquivalent: "")
                item.target = IPickerItemHandler.shared
                item.tag = tag
                item.indentationLevel = 1
                let isSelected = provider.rawValue == settings.aiProvider
                let svc = service
                let sets = settings
                IPickerItemHandler.shared.actions[tag] = {
                    svc.selectedProvider = provider
                    sets.aiProvider = provider.rawValue
                }

                let title = NSMutableAttributedString(string: provider.displayName, attributes: [
                    .font: NSFont.systemFont(ofSize: 13)
                ])
                if isSelected {
                    title.append(NSAttributedString(string: "  ✓", attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor.white
                    ]))
                }
                item.attributedTitle = title
                menu.addItem(item)
                tag += 1
            }
            menu.addItem(.separator())
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }

    /// 生成中也能继续发 —— 服务层是多任务的（v5.1.0），
    /// 一边等图片一边发视频没问题，各自转各自的圈
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        let refImageURLs = referenceContents.filter { $0.type == .image }.map(\.url)
        let refVideoURLs = referenceContents.filter { $0.type == .video }.map(\.url)
        let refAudioURLs = referenceContents.filter { $0.type == .audio }.map(\.url)
        let firstURL = firstFrameImage?.url
        let lastURL = lastFrameImage?.url
        // 发的是校正过的值：换供应商后旧档位这家可能不收，
        // 界面上已经退回到合法档，这里不能再把原始值发出去
        service.sendPrompt(text, duration: currentDuration, aspectRatio: settings.aiRatio, resolution: currentResolution, imageRatio: settings.aiImageRatio, referenceImages: refImageURLs, referenceVideos: refVideoURLs, referenceAudios: refAudioURLs, firstFrame: firstURL, lastFrame: lastURL)
        referenceContents.removeAll()
        firstFrameImage = nil
        lastFrameImage = nil
    }

    private func insertMediaToTimeline(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        project.importFile(url)
        guard let asset = project.mediaAssets.first(where: { $0.url == url }) else { return }
        let playhead = project.currentTime
        project.pushUndo()

        if ["mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "audio", iconColor: .accent, title: "AI 音频", subtitle: "已插入时间轨道并导入素材库")
        } else if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "image", iconColor: .accent, title: "AI 图片", subtitle: "已插入时间轨道并导入素材库")
        } else {
            let hasClipAtPlayhead = project.videoTracks.contains { track in
                track.clips.contains { $0.startTime <= playhead && $0.endTime > playhead }
            }
            if hasClipAtPlayhead {
                project.videoTracks.append(Track(label: "视频"))
            }
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "video", iconColor: .accent, title: "AI 视频", subtitle: "已插入时间轨道并导入素材库")
        }
    }
}

// MARK: - 消息气泡

private struct MessageBubble: View {
    @EnvironmentObject var project: ProjectState
    /// 取消按钮要跟着任务的存亡显隐，得观察 service
    @ObservedObject private var service = AIVideoService.shared
    let message: AIVideoService.ChatMessage
    var onInsertToTimeline: (URL) -> Void
    var onRestoreAttachment: (AIVideoService.Attachment) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                assistantBubble
                Spacer(minLength: 20)
            } else {
                Spacer(minLength: 20)
                userBubble
            }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 5) {
            // 跟回复区共用同一个 NSTextView，右键菜单才一致 ——
            // 用 SwiftUI 的 Text 弹出来的是系统全套（字体/拼写/朗读/共享…），改不了
            SelectableMarkdownView(
                attributed: userAttributed(),
                onAddSubtitle: { project.insertSubtitleAtPlayhead(text: $0) },
                onAddTitle: { project.addTextAtPlayhead(text: $0) }
            )
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !message.attachments.isEmpty {
                attachmentRow
            }
        }
    }

    /// 气泡底部的参考内容/首尾帧缩略图，点击回填输入区
    private var attachmentRow: some View {
        HStack(spacing: 4) {
            ForEach(message.attachments) { att in
                AttachmentThumb(attachment: att) { onRestoreAttachment(att) }
            }
        }
    }

    @ViewBuilder
    /// 用户发的那条：气泡是黄底，字用黑色
    private func userAttributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = AIChatPanel.bodyLineSpacing
        return NSAttributedString(string: message.content, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
            .paragraphStyle: para
        ])
    }

    /// 只停这一条。多任务之后输入区那个按钮停的是全部，
    /// 想单独停某一条得从它自己的气泡上停
    @ViewBuilder
    private var cancelThisTaskButton: some View {
        if service.runningTask(forMessage: message.id) != nil {
            Button {
                service.cancelTask(forMessage: message.id)
            } label: {
                Image(nsImage: SidebarSVGIcon.load("toastStop", size: 13))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundColor(Color.labelSecondary)
            }
            .buttonStyle(.plain)
            .help("停止这一条")
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.status {
            case .generating(let progress):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                    cancelThisTaskButton
                }

            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("下载中…")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                    cancelThisTaskButton
                }

            case .completed(let url):
                VStack(alignment: .leading, spacing: 6) {
                    VideoThumbnailView(url: message.resolvedVideoURL() ?? url)

                    HStack(spacing: 4) {
                        Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 14))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color(hex: "#30D158"))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "film.stack", svgName: "addToVideoTrack", tip: "插入视频轨道") {
                            onInsertToTimeline(message.resolvedVideoURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedVideoURL() ?? url])
                        }
                    }
                    .frame(width: AIMediaThumbSize.width)
                }

            case .completedImage(let url):
                VStack(alignment: .leading, spacing: 6) {
                    ImageThumbnailView(url: message.resolvedImageURL() ?? url)

                    HStack(spacing: 4) {
                        Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 14))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color(hex: "#30D158"))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "photo.on.rectangle", svgName: "addToImageTrack", tip: "插入图片轨道") {
                            onInsertToTimeline(message.resolvedImageURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedImageURL() ?? url])
                        }
                    }
                    .frame(width: AIMediaThumbSize.width)
                }

            case .completedAudio(let url):
                VStack(alignment: .leading, spacing: 6) {
                    AudioWaveformView(url: message.resolvedAudioURL() ?? url)

                    HStack(spacing: 4) {
                        Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 14))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color(hex: "#30D158"))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "waveform", svgName: "addToAudioTrack", tip: "插入音频轨道") {
                            onInsertToTimeline(message.resolvedAudioURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedAudioURL() ?? url])
                        }
                    }
                }

            case .failed(let error):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }

            case .idle:
                MarkdownContentView(text: message.content)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 视频封面

// MARK: - 消息附件缩略图

private struct AttachmentThumb: View {
    let attachment: AIVideoService.Attachment
    var onTap: () -> Void

    @State private var thumbnail: NSImage?
    @State private var missing = false
    @State private var hovering = false

    /// 只标内容类型，不标首/尾角色 —— 角色由点击顺序决定
    private var badge: (icon: String?, text: String?)? {
        switch attachment.kind {
        case .video: return ("video.fill", nil)
        case .audio: return ("waveform", nil)
        case .image, .firstFrame, .lastFrame: return nil
        }
    }

    private var tip: String {
        switch attachment.kind {
        case .video: return "视频 · 点击添加"
        case .audio: return "音频 · 点击添加"
        case .image, .firstFrame, .lastFrame: return "图片 · 点击添加"
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: missing ? "questionmark" : "photo")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(Color.labelSecondary.opacity(0.5))
                        }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(hovering ? 0.5 : 0.15), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if let b = badge {
                    Group {
                        if let t = b.text {
                            Text(t).font(.system(size: 7, weight: .bold))
                        } else if let icon = b.icon {
                            Image(systemName: icon).font(.system(size: 6))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(1.5)
                }
            }
            .opacity(missing ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(missing ? "文件已不存在" : tip)
        .onHover { hovering = $0 }
        .task { await load() }
    }

    private func load() async {
        guard let url = attachment.resolvedURL() else {
            await MainActor.run { missing = true }
            return
        }
        switch attachment.kind {
        case .audio:
            return  // 用占位图标即可
        case .video:
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 120, height: 120)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { thumbnail = ns }
            }
        case .image, .firstFrame, .lastFrame:
            if let img = NSImage(contentsOf: url) {
                let thumb = img.thumbnailImage(maxSize: 120)
                await MainActor.run { thumbnail = thumb }
            }
        }
    }
}

private struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var duration: String = ""
    @ObservedObject private var inline = AIInlinePlayer.shared

    /// 固定宽度，不再随聊天区宽度伸缩
    private var displaySize: CGSize {
        AIMediaThumbSize.fit(thumbnail?.size)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: displaySize.width, height: displaySize.height)
                        // 播放时画面盖在缩略图上，停了自动露回缩略图
                        .overlay {
                            if inline.isPlaying(url), let p = inline.player {
                                InlinePlayerLayer(player: p)
                                    .frame(width: displaySize.width, height: displaySize.height)
                            }
                        }
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .frame(width: AIMediaThumbSize.width, height: 90)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { if thumbnail != nil { InlinePlayButton(url: url) } }

            if !duration.isEmpty {
                Text(duration)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(6)
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)

        if let dur = try? await asset.load(.duration) {
            let s = Int(dur.seconds)
            let m = s / 60; let sec = s % 60
            await MainActor.run { duration = String(format: "%d:%02d", m, sec) }
        }

        if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            let ns = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            await MainActor.run { thumbnail = ns }
        }
    }
}

// MARK: - 图片缩略图

/// AI 生成结果缩略图的固定尺寸。宽度写死，高度按素材比例算。
/// 宽度必须始终等于 width，否则竖图会比下方状态行窄，右边留出空档
enum AIMediaThumbSize {
    static let width: CGFloat = 140

    static func fit(_ source: CGSize?) -> CGSize {
        guard let s = source, s.width > 0, s.height > 0 else {
            return CGSize(width: width, height: 90)
        }
        return CGSize(width: width, height: width * s.height / s.width)
    }
}

private struct ImageThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    private var displaySize: CGSize {
        AIMediaThumbSize.fit(image?.size)
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displaySize.width, height: displaySize.height)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: AIMediaThumbSize.width, height: 90)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            if let img = NSImage(contentsOf: url) {
                await MainActor.run { image = img }
            }
        }
    }
}

// MARK: - 行内试听

/// 只装播放位置的小对象。见 AIInlinePlayer.clock 的注释
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var time: Double = 0
}

/// AI 面板里缩略图上的试听播放器。全局单例，同一时刻只播一条，
/// 点第二条会自动停掉上一条，避免多条一起响
@MainActor
final class AIInlinePlayer: ObservableObject {
    static let shared = AIInlinePlayer()

    /// 谁在播。**不是 URL** —— 两张卡片完全可能指向同一个文件（同一个素材
    /// 拖了两次、或创建副本），这时候纯按 URL 判断会把两张卡片都当成「正在播」，
    /// 表现就是「hover 一个，另一个也跟着显示播放画面」。
    /// 画布卡片传 node.id 做 key，素材库列表没有节点概念就传 url 自己
    @Published private(set) var playingKey: AnyHashable?
    @Published private(set) var playingURL: URL?
    @Published private(set) var player: AVPlayer?
    /// 播放位置。**单独一个对象**：它每 30ms 变一次，挂在这里的话
    /// 每张画布卡片（都订阅了播放器）每秒要重算三十多次 body，
    /// 卡片一多就是持续掉帧。只有真正画进度线、显示走字时间的那两个小视图订阅它
    let clock = PlayheadClock()

    /// 非响应式地读当前位置。要跟着走的视图请订阅 `clock`
    var currentTime: Double { clock.time }

    @Published private(set) var duration: Double = 0

    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    private init() {}

    /// 这个 key 是当前这条（播放中或暂停中）
    func isCurrent(_ key: AnyHashable) -> Bool { playingKey == key }
    /// 真正在响
    func isPlaying(_ key: AnyHashable) -> Bool { playingKey == key && !isPaused }

    @Published private(set) var isPaused = false
    /// 静音。**不随切换视频重置** —— 静音是用户对播放器的偏好，
    /// 不是某一条素材自己的属性，切下一条也该保持
    @Published private(set) var isMuted = false

    /// 暂停 / 继续。**不销毁 player** —— 销毁的话进度回到 0，
    /// 用户要的是「黄线停在当前位置，再点继续」
    func togglePause() {
        guard let p = player else { return }
        if isPaused { p.play(); isPaused = false } else { p.pause(); isPaused = true }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// 拖进度条 / 拖播放线 都走这个。**手动把 clock.time 顶到位**，
    /// 不等 seek 完成后 periodic observer 的下一次回调 —— 那个隔 30ms 才报一次，
    /// 拖动中不立刻更新的话，手柄会跟鼠标脱节，看着一卡一卡的
    func seek(to seconds: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(duration, seconds))
        clock.time = clamped
        p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
              toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// `key` 缺省用 url 自己 —— 素材库列表没有节点概念，url 就是身份；
    /// 画布卡片会显式传 node.id，避免两张卡片撞同一个文件时互相认串
    func toggle(_ url: URL, key: AnyHashable? = nil) {
        let key: AnyHashable = key ?? AnyHashable(url)
        if playingKey == key { togglePause(); return }
        stop()
        let p = AVPlayer(url: url)
        p.isMuted = isMuted   // 静音是播放器偏好，跨切换视频保持
        isPaused = false
        duration = AVURLAsset(url: url).duration.seconds
        clock.time = 0
        // 每 0.1 秒报一次位置，够画指示线了；再密只是白烧 CPU
        timeObserver = p.addPeriodicTimeObserver(
            // 0.1 秒一次线是一跳一跳的，30ms 才跟得上眼睛
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600),
            queue: .main) { [weak self] t in
                self?.clock.time = t.seconds
            }
        // 播完自动复位成播放态图标
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: p.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in AIInlinePlayer.shared.stop() }
        }
        player = p
        playingURL = url
        playingKey = key
        p.play()
    }

    func stop() {
        player?.pause()
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        // 时间观察器挂在 player 上，不摘就跟着 player 一起泄漏
        if let t = timeObserver {
            player?.removeTimeObserver(t)
            timeObserver = nil
        }
        player = nil
        playingURL = nil
        playingKey = nil
        isPaused = false
        clock.time = 0
        duration = 0
    }
}

/// 缩略图上的播放/暂停按钮：半透明黑底圆形 + 白色图标
private struct InlinePlayButton: View {
    let url: URL
    var size: CGFloat = 28
    @ObservedObject private var inline = AIInlinePlayer.shared

    var body: some View {
        Button { inline.toggle(url) } label: {
            Image(nsImage: TimelineSVGIcon.load(inline.isPlaying(url) ? "pause" : "play"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.43, height: size * 0.43)
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 播放视频时盖在缩略图上的画面层
/// 内嵌播放的画面层。AI 面板和画布卡片共用
struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

// MARK: - 音频波形

private struct AudioWaveformView: View {
    let url: URL
    @State private var samples: [Float] = []
    @State private var duration: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let barCount = max(Int(w / 3), 1)
                let displaySamples = resample(samples, to: barCount)
                HStack(spacing: 1) {
                    ForEach(0..<displaySamples.count, id: \.self) { i in
                        let barH = max(CGFloat(displaySamples[i]) * h, 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accent.opacity(0.8))
                            .frame(width: 2, height: barH)
                    }
                }
                .frame(height: h, alignment: .center)
            }
            .frame(height: 40)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { InlinePlayButton(url: url, size: 24) }

            if !duration.isEmpty {
                Text(duration)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color.labelSecondary)
            }
        }
        .task { await loadWaveform() }
    }

    private func resample(_ input: [Float], to count: Int) -> [Float] {
        guard !input.isEmpty, count > 0 else { return Array(repeating: 0.3, count: max(count, 20)) }
        let step = Float(input.count) / Float(count)
        return (0..<count).map { i in
            let idx = min(Int(Float(i) * step), input.count - 1)
            return input[idx]
        }
    }

    /// 家用机实证：坏掉的音频读取服务会让 copyNextSampleBuffer 永久挂死并占满 Swift 协作池
    /// （详见 ProjectState.loadWaveform）。这里复用同一套专属线程+超时+ffmpeg 兜底的静态方法，
    /// 不直接在 Task 里做同步 AVAssetReader 调用。
    private func loadWaveform() async {
        let u = url
        let (durText, wfSamples): (String?, [Float]) = await withCheckedContinuation { cont in
            Thread.detachNewThread {
                var durText: String? = nil
                if case .success(let d) = ProjectState.durationSyncWithTimeout(url: u, seconds: 10) {
                    let s = Int(d)
                    durText = String(format: "%d:%02d", s / 60, s % 60)
                }
                var wf = Array(repeating: Float(0.3), count: 60)
                if let data = ProjectState.waveformSyncWithTimeout(url: u, timeout: 15) {
                    wf = data.samples
                } else if let data = ProjectState.ffmpegWaveform(url: u) {
                    wf = data.samples
                }
                cont.resume(returning: (durText, wf))
            }
        }
        await MainActor.run {
            if let durText { duration = durText }
            samples = wfSamples
        }
    }
}

// MARK: - Markdown 渲染

private struct MarkdownContentView: View {
    let text: String
    @EnvironmentObject var project: ProjectState

    var body: some View {
        // 整段用一个 NSTextView 渲染。
        //
        // 两个原因不能用 SwiftUI 的 Text：它的 textSelection 只能在单个 Text
        // 内部选（每段一个 Text 就成了"一次只能选一段"），而且右键弹的是系统
        // 那套菜单，一项都改不了、也拿不到选中范围
        SelectableMarkdownView(
            attributed: nsAttributed(),
            onAddSubtitle: { project.insertSubtitleAtPlayhead(text: $0) },
            onAddTitle: { project.addTextAtPlayhead(text: $0) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 把解析出的块拼成 NSAttributedString。
    /// 行距按 1.4 倍行高走段落样式，比逐段设 lineSpacing 更准
    private func nsAttributed() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = AIChatPanel.bodyLineSpacing

        func append(_ str: String, size: CGFloat, weight: NSFont.Weight = .regular,
                    alpha: CGFloat = 0.7, mono: Bool = false, bg: Bool = false) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                            : NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                .paragraphStyle: para
            ]
            if bg { attrs[.backgroundColor] = NSColor.white.withAlphaComponent(0.08) }
            out.append(NSAttributedString(string: str, attributes: attrs))
        }

        /// 行内 markdown（粗体/斜体/链接）交给系统解析，再补上字号和颜色
        func appendInline(_ text: String, size: CGFloat = 12, alpha: CGFloat = 0.7) {
            guard let a = try? NSAttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) else {
                append(text, size: size, alpha: alpha)
                return
            }
            let m = NSMutableAttributedString(attributedString: a)
            let full = NSRange(location: 0, length: m.length)
            m.addAttribute(.paragraphStyle, value: para, range: full)
            // 逐段铺色，跳过链接 —— 整段无脑上色会把链接的蓝色盖掉
            m.enumerateAttributes(in: full) { attrs, range, _ in
                let isBold = (attrs[.font] as? NSFont)?.fontDescriptor
                    .symbolicTraits.contains(.bold) ?? false
                m.addAttribute(.font,
                               value: NSFont.systemFont(ofSize: size, weight: isBold ? .semibold : .regular),
                               range: range)
                if attrs[.link] == nil {
                    m.addAttribute(.foregroundColor,
                                   value: NSColor.white.withAlphaComponent(alpha), range: range)
                }
            }
            out.append(m)
        }

        for (i, block) in parseBlocks().enumerated() {
            if i > 0 { append("\n\n", size: 12) }
            switch block {
            case .heading(let level, let t):
                appendInline(t, size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5, alpha: 0.9)
            case .code(let code, _):
                append(code, size: 11, mono: true, bg: true)
            case .bullet(let t):
                append("•  ", size: 12, alpha: 0.5)
                appendInline(t)
            case .numbered(let n, let t):
                append("\(n).  ", size: 12, alpha: 0.5)
                appendInline(t)
            case .paragraph(let t):
                appendInline(t)
            }
        }
        return out
    }

    private func combinedText() -> AttributedString {
        var out = AttributedString()
        for (i, block) in parseBlocks().enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            switch block {
            case .heading(let level, let t):
                var a = inlineAttr(t)
                a.font = .system(size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold)
                a.foregroundColor = .white.opacity(0.9)
                out += a
            case .code(let code, _):
                var a = AttributedString(code)
                a.font = .system(size: 11, design: .monospaced)
                a.foregroundColor = .white.opacity(0.7)
                a.backgroundColor = .white.opacity(0.08)
                out += a
            case .bullet(let t):
                var dot = AttributedString("•  ")
                dot.font = .system(size: 12)
                dot.foregroundColor = .white.opacity(0.5)
                out += dot + inlineAttr(t)
            case .numbered(let n, let t):
                var num = AttributedString("\(n).  ")
                num.font = .system(size: 12)
                num.foregroundColor = .white.opacity(0.5)
                out += num + inlineAttr(t)
            case .paragraph(let t):
                out += inlineAttr(t)
            }
        }
        return out
    }

    /// 行内 markdown（粗体、斜体、链接）交给系统解析，再统一铺一层基础字号和颜色
    private func inlineAttr(_ s: String) -> AttributedString {
        var a = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        a.font = .system(size: 12)
        // 逐段上色，跳过链接：整段无脑铺颜色会把链接的蓝色盖掉，
        // 看着就跟普通文字一样，用户会以为链接失效了
        for run in a.runs where a[run.range].link == nil {
            a[run.range].foregroundColor = .white.opacity(0.7)
        }
        return a
    }

    private enum Block {
        case heading(Int, String)
        case code(String, String?)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                i += 1
                continue
            }

            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let matched = trimmed[m]
                let num = Int(matched.prefix(while: { $0.isNumber })) ?? 1
                blocks.append(.numbered(num, String(trimmed[m.upperBound...])))
            } else if !trimmed.isEmpty {
                blocks.append(.paragraph(trimmed))
            }
            i += 1
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 15 : level == 2 ? 13.5 : 12.5
            inlineMarkdown(text)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.top, 2)

        case .code(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(8)
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .bullet(let text):
            HStack(alignment: .top, spacing: 0) {
                Text("•")
                    .font(.system(size: 12))
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.5))
                inlineMarkdown(text)
                    .font(.system(size: 12))
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(.leading, 12)

        case .numbered(let n, let text):
            HStack(alignment: .top, spacing: 2) {
                Text("\(n).")
                    .font(.system(size: 12).monospacedDigit())
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.5))
                inlineMarkdown(text)
                    .font(.system(size: 12))
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(.leading, 8)

        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.system(size: 12))
                .lineSpacing(AIChatPanel.bodyLineSpacing)
                .foregroundColor(Color.white.opacity(0.7))
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(text)
    }
}

// MARK: - Hover 图标按钮

private struct HoverIconButton: View {
    let icon: String
    var svgName: String? = nil
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let svgName, SidebarSVGIcon.svgs[svgName] != nil {
                    Image(nsImage: SidebarSVGIcon.load(svgName))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(Color.labelSecondary)
            .frame(width: 24, height: 24)
            .background(hovering ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tip)
    }
}

private extension NSImage {
    func thumbnailImage(maxSize: CGFloat) -> NSImage { aiThumbnail(maxSize: maxSize) }
}

// MARK: - 可选中文本视图（自定义右键菜单）

/// 用 NSTextView 渲染模型回复。
///
/// 换掉 SwiftUI 的 `Text` 是为了两件 `Text` 做不到的事：
/// ① 右键菜单可控 —— `Text` 弹的是系统那套（查字典、翻译、字体、拼写、朗读…），
///    一项都改不了；
/// ② 拿得到选中范围 —— 「添加到字幕」这类操作必须知道用户选了哪一段。
struct SelectableMarkdownView: NSViewRepresentable {
    let attributed: NSAttributedString
    /// 右键菜单里两个自定义项的回调，参数是当前选中的文字
    var onAddSubtitle: (String) -> Void
    var onAddTitle: (String) -> Void

    // 只读，不需要滚动，直接放 NSTextView。
    // 套 NSScrollView 反而量不准尺寸（滚动视图的固有尺寸是不确定的）
    func makeNSView(context: Context) -> ChatTextView {
        let tv = ChatTextView()
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticLinkDetectionEnabled = true
        tv.textStorage?.setAttributedString(attributed)
        tv.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: ChatTextView, context: Context) {
        if tv.textStorage?.string != attributed.string {
            tv.textStorage?.setAttributedString(attributed)
        }
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
    }

    /// 报真实尺寸给 SwiftUI。
    ///
    /// 直接用 NSAttributedString 量，不问 textContainer —— 那边设了
    /// widthTracksTextView，usedRect 的宽度永远等于容器宽度，
    /// 量出来「阿斯达」也是满宽，气泡就撑满整行了
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatTextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? 300
        let rect = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: min(maxWidth, ceil(rect.width) + 1), height: ceil(rect.height))
    }
}

/// 只为了改右键菜单而存在的子类。
/// 回复区（只读）和输入框（可编辑）共用同一套菜单规则，区别只在剪切要不要留
class ChatTextView: NSTextView, NSMenuDelegate {
    var onAddSubtitle: ((String) -> Void)?
    var onAddTitle: ((String) -> Void)?
    /// 输入框要留着剪切，只读的回复区不留
    var keepCut = false

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }

        // ① 粘贴之后的全砍掉。
        //    那后面除了「共享…」，还会混进响应链上别处的菜单
        //    （打开 / 在访达中显示 / 作为语音轨道添加到"音乐"…），
        //    它们的 action 五花八门，逐个认不现实；而系统文本菜单里
        //    「粘贴」永远是最后一个标准项，以它为界最省事。
        //    paste: 是公开 selector，不像查字典、翻译那些是私有的
        if let pasteIdx = menu.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) }) {
            while menu.items.count > pasteIdx + 1 { menu.removeItem(at: pasteIdx + 1) }
        }
        // ② 粘贴之前还剩的带子菜单项（字体/拼写/替换/朗读）一并清掉
        for item in menu.items.reversed() where item.hasSubmenu {
            menu.removeItem(item)
        }
        // ③ 只读文本里剪切永远是灰的，占位置；可编辑的输入框留着
        if !keepCut {
            for item in menu.items.reversed() where item.action == #selector(NSText.cut(_:)) {
                menu.removeItem(item)
            }
        }
        // 图标去不掉：macOS 26 是按 action 自动画的，不走 item.image，
        // 置空无效。想彻底去掉只能不用系统项、全部自己重建，
        // 但「翻译」那项自己实现代价太大，就这样了
        // 清掉筛完后可能留在头尾的多余分隔线
        while let f = menu.items.first, f.isSeparatorItem { menu.removeItem(f) }
        while let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }

        let picked = (string as NSString).substring(with: selectedRange())
            .trimmingCharacters(in: .whitespacesAndNewlines)

        menu.addItem(.separator())
        for (title, sel) in [("添加到字幕", #selector(addToSubtitle)),
                             ("添加到标题文字", #selector(addToTitle))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = !picked.isEmpty      // 没选中就置灰
            menu.addItem(item)
        }

        // 「自动填充」「服务」这类项，以及标准项左边的图标，都是系统在菜单
        // 即将弹出时才补上的 —— 在这里清完它们随后又会加回来。
        // 挂个 delegate，等真正要显示的那一刻再清一次才拦得住
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { prune(menu) }

    /// AppKit 专门留的定制点，比 delegate 的 menuWillOpen 更靠后 ——
    /// 「自动填充」就是在 menuWillOpen 跑完之后才被系统塞进来的，
    /// 只有在这里才拦得住
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        prune(menu)
    }

    /// 系统后补的项（自动填充、服务）都带子菜单，按这个筛
    private func prune(_ menu: NSMenu) {
        for item in menu.items.reversed() where item.hasSubmenu {
            menu.removeItem(item)
        }
        while let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }
    }

    /// 关掉「服务」子菜单。
    ///
    /// 它不是 menu(for:) 里的项 —— 系统是在菜单即将弹出时才追加的，
    /// 所以在 menu(for:) 里怎么删都删不掉。服务菜单的入口就是这个方法，
    /// 返回 nil 等于告诉系统「本控件不参与服务」，那一项自然就不出现了
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        nil
    }

    /// 菜单项的 target 是自己，得自己决定启用状态，否则系统会按响应链判断而变灰
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(addToSubtitle) || item.action == #selector(addToTitle) {
            return selectedRange().length > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    private var selectedText: String {
        (string as NSString).substring(with: selectedRange())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func addToSubtitle() {
        let t = selectedText
        guard !t.isEmpty else { return }
        onAddSubtitle?(t)
    }

    @objc private func addToTitle() {
        let t = selectedText
        guard !t.isEmpty else { return }
        onAddTitle?(t)
    }
}

/// 聊天输入框。换掉 SwiftUI 的 TextEditor 只为一件事：
/// 右键菜单要跟回复区一致（去掉字体/拼写/朗读/共享那堆，加上添加到字幕/标题文字）
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var onAddSubtitle: (String) -> Void
    var onAddTitle: (String) -> Void
    /// 回车发送（Shift+回车换行）
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ChatInputInner()
        tv.keepCut = true
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.onSubmit = onSubmit
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isRichText = false
        // 「自动填充」那一项跟着这些自动化功能走，一并关掉
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = text
        // 行距对齐回复区的 1.4 倍行高
        let para = NSMutableParagraphStyle()
        para.lineSpacing = AIChatPanel.bodyLineSpacing
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ChatInputInner else { return }
        if tv.string != text { tv.string = text }
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

private final class ChatInputInner: ChatTextView {
    var onSubmit: (() -> Void)?

    /// 回车发送，Shift+回车换行 —— 跟原来 TextEditor 上挂的 onKeyPress 行为一致
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}


/// 新建入口的小卡片。两个并排放在会话区最上面，可点的东西一律给 hover 反馈
private struct EntryCard: View {
    let svgName: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(nsImage: SidebarSVGIcon.load(svgName, size: 13))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(hovering ? .white : Color.labelPrimary)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.10 : 0.03)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
