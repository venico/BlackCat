import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct AIChatPanel: View {
    /// 画布右侧那张悬浮卡片。跟侧栏那份**是同一套东西** ——
    /// service / AgentRunner 都是单例，会话、历史、正在跑的任务全共享，
    /// 差别只有：画布里不再给「新建画布」入口，拖入区也各登记各的
    var inCanvas = false

    @Environment(\.windowID) private var windowID
    @EnvironmentObject private var project: ProjectState
    @StateObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared
    /// 草稿和附件都存在 service 上，切标签页回来还在（见那边的说明）
    private var inputText: String {
        get { service.agentInputText }
        nonmutating set { service.agentInputText = newValue }
    }
    /// 程序自己改输入框内容的次数（选命令、发送后清空这些）。
    /// 只有它变了才把文本回写进 NSTextView —— Agent 跑起来时每秒都在刷新，
    /// 重绘拿到的 text 可能比用户刚敲进去的那个字慢一拍，无条件回写就是「打不上字」
    @State private var inputRevision = 0
    /// 光标前正在打的 `/xxx`（不带斜杠）；nil = 没在打命令
    @State private var slashQuery: String?
    @State private var slashIndex = 0
    /// 打命令时的光标位置（按字符数）。插入时得知道换哪一段，不能拿末尾去猜
    @State private var slashCaret = 0
    /// Agent 那条链：执行器、模式、这一轮的对话上下文
    @ObservedObject private var agent = AgentRunner.shared
    @State private var agentHistory: [AgentMessage] = []
    /// agentHistory 是这一次运行期间的内存状态。记下它对应哪个会话，
    /// 换了会话（或重启后压根没有）就得从落盘的聊天记录重建
    @State private var historyConvID: UUID?
    /// 进面板默认就是历史列表 —— 用户过来多半是要找之前那条，
    /// 而不是从空白开始
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
        switch uiProvider {
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
        switch uiProvider {
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
            if !inCanvas { canvasEntry }
            // 历史会话展开时**替换**整个会话区。
            // 用 ZStack 盖一层的话得给它一个不透明底色才挡得住下面的消息，
            // 那块底色跟面板不搭；直接替换就没这问题
            // 画布那张卡片只做聊天，历史列表留在侧栏那份里
            if service.showChatHistory && !inCanvas {
                historyOverlay
            } else {
                // 收附件的范围就是会话 + 输入区这一块，不含上面的标题栏和
                // 新建画布 / 新建会话那排 —— 拖到那两个按钮上不该算。
                //
                // **不能用 SwiftUI 的 `.onDrop`**，也不能往里插 NSView —— 这个 app 的
                // 拖放全被最外层的 GatedHostingView 截走（hitTest 到不了内层，
                // 原委见 FileDropRouter 的注释）。登记一块接收区，宿主按落点分发过来
                VStack(spacing: 0) {
                    messageList
                    inputArea
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { registerChatDropZone(g.frame(in: .global)) }
                        // 侧栏能拖宽、窗口能缩放，位置得跟着更新
                        .onChange(of: g.frame(in: .global)) { _, r in registerChatDropZone(r) }
                })
                .overlay {
                    if isDropTargeted {
                        // 跟素材区拖入一个样式：整块染色，不加描边和文字
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accent.opacity(0.06))
                            .allowsHitTesting(false)
                    }
                }
                // 翻去历史列表时这块就不在了，登记得跟着撤
                .onDisappear { FileDropRouter.unregister(windowID, kind: dropZoneKind) }
            }
        }
        // 切去素材库标签页后这块就不在了，登记必须撤掉 ——
        // 留着的话它排在素材区前面，拖文件进素材库会被这儿吃掉
        .onDisappear { FileDropRouter.unregister(windowID, kind: dropZoneKind) }
        // 从素材库挑参考内容 / 首尾帧。复用画布那套弹窗，能选的类型按模型给
        .sheet(item: $libraryPick) { target in
            // 参考内容能收好几个就让多选；首尾帧一次只认一张
            CanvasAssetPicker(canvas: project.canvas,
                              limitKinds: libraryPickKinds,
                              // 没点名生成模型时也让多选 —— 那会儿
                              // maxReferenceTotal 是 0，卡着这条就只能一个个点
                              multiSelect: target == .reference
                                           && (namedModel == nil
                                               || uiProvider.maxReferenceTotal > 1)) { picks in
                libraryPick = nil
                guard let first = picks.first else { return }
                switch target {
                case .reference:
                    // 跟拖入 / ＋ 走同一条：先进参考区，收不下的落附件，还带提示。
                    // 原来直接调 addToReference 且不看返回值 —— 当时要是还没打
                    // `/命令`（当前是文字模型、参考区收不了），图就被静默丢掉了
                    addAgentAttachments(picks.map(\.url))
                case .firstFrame:
                    if let img = NSImage(contentsOf: first.url) { firstFrameImage = (first.url, img) }
                case .lastFrame:
                    if let img = NSImage(contentsOf: first.url) { lastFrameImage = (first.url, img) }
                }
            }
            .environmentObject(project)
        }
        // 面板宽度：参考区/附件区的列数都按它算（见 panelWidth 的说明）
        .background(GeometryReader { g in
            Color.clear
                .onAppear { panelWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in panelWidth = w }
        })
        // ＋ 菜单在最外层画，点了什么从这儿回来执行
        .onChange(of: project.plusMenuPick) { _, pick in
            // 不是自己开的菜单就别接 —— 也别清掉，留给正主
            guard let pick, project.plusMenuFromCanvas == inCanvas else { return }
            project.plusMenuPick = nil
            switch pick {
            case .upload:  pickAgentAttachments()
            case .library: libraryPick = .reference
            case .mcp:
                // 设置左边那列：前 6 个是「设置」组，智能体组从 6 起，MCP 是第 3 个
                NotificationCenter.default.post(name: .showSettings, object: 8)
            case .command(let name): insertCommand(name)
            }
        }
        .onChange(of: namedModel) { _, now in
            if now == nil {
                // 命令没了，参考区跟着不显示 —— 里头的东西转成普通附件留着
                demoteReferencesToAttachments()
            } else {
                // 顺序要紧：先把附件里的图收进参考区，再按新模型裁掉多余的
                promoteAttachmentsToReference()
            }
            pruneInputsForProvider()
        }
        .onChange(of: service.selectedProvider) { _ in
            pruneInputsForProvider()
            ensureAgentProvider()
        }
        // 把「此刻真正生效的模型」同步出去。素材库右键「添加到 AI 参考」在别的视图里，
        // 拿不到这儿的 `/` 命令状态 —— 不同步的话它只能看面板全局选的那个，
        // 于是用户 `/` 点了视频模型、右键加视频素材，被判成「不支持当前素材类型」
        // **只有打了 `/` 命令才有值**。没命令时留空，让外面知道该按附件规则收
        .onChange(of: namedModel) { p in service.activeUIProvider = p }
        .onAppear { service.activeUIProvider = namedModel }
        // 试听播放器是单例，view 销毁不会带走它 —— 切会话和关面板都得手动停，否则声音继续响
        .onChange(of: service.currentConversationId) { _ in
            AIInlinePlayer.shared.stop()
        }
        .onDisappear { AIInlinePlayer.shared.stop() }
    }

    /// 切换模型后，裁掉新模型不支持的参考内容，避免带着旧模型的数据发出去被静默丢弃
    private func pruneInputsForProvider() {
        let provider = uiProvider
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
            Text(inCanvas ? conversationTitle : "AI 创作")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
                // 会话名可能是英文，别给它全大写
                .textCase(inCanvas ? nil : .uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            // 进面板默认就停在历史列表上，这时候再放个「历史会话」图标是多余的；
            // 进了某条会话（service.showChatHistory = false）才需要它退回列表。
            // 新建那两个入口挪到下面的卡片上了，这儿不再重复
            if !service.showChatHistory && !inCanvas {
                HoverIconButton(icon: "clock", svgName: "chatHistory", tip: "历史会话") {
                    withAnimation(.easeInOut(duration: 0.18)) { service.showChatHistory = true }
                }
            }
        }
        // **高度按图标那 24pt 定死**：历史列表页不画右侧图标，
        // 不撑着的话这一行会矮一截，两页之间标题就上下跳
        .frame(height: 24)
        // 画布卡片右上角那颗最小化按钮压在这一行上，标题得让开
        .padding(.leading, leadPad).padding(.trailing, inCanvas ? 32 : 10)
        // 顶部留白跟素材库那栏对齐（那边也是 8）——
        // 两栏切换时标题行不该上下跳
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - 历史会话

    /// 两个新建入口，并排放在会话区最上面
    private var canvasEntry: some View {
        HStack(spacing: 8) {
            // 已经在画布里了，再给个「新建画布」没意义
            if !inCanvas {
                EntryCard(svgName: "freeCanvas", title: "新建画布") {
                    let id = service.newCanvasConversation()
                    project.canvas.reset(conversationID: id)
                    project.showCanvas = true
                }
            }
            EntryCard(svgName: "newChat", title: "新建会话") {
                service.newConversation()
                service.showChatHistory = false   // 建完直接进新会话，不留在列表里
            }
        }
        .padding(.leading, leadPad).padding(.trailing, 10)
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
                    VStack(spacing: 8) {
                        ForEach(service.history) { conv in
                            historyRow(conv)
                        }
                    }
                    .padding(.leading, leadPad).padding(.trailing, 10)
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
                // 走 loadConversation 而不是直接赋 id —— 裸赋值只换了「当前是哪条」，
                // messages 还留着上一条会话的内容，画布里那张卡片会把它照原样显示出来
                service.loadConversation(conv.id)
                project.showCanvas = true
            } else {
                service.loadConversation(conv.id)
                service.showChatHistory = false
            }
        } label: {
            HStack(spacing: 6) {
                HistoryStatusDot(state: dotState(conv))
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
                }
                Spacer(minLength: 6)
                // 时间挪到行尾，hover 才露出来 —— 平时那一行只留标题，干净些
                Text(formatDate(conv.createdAt))
                    .font(.system(size: 9))
                    .foregroundColor(Color.labelSecondary)
                    .lineLimit(1)
                    .opacity(hoverHistoryID == conv.id ? 1 : 0)
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .padding(.vertical, 8)
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

    /// 这条记录的圆点该显示成什么状态。
    /// 正在跑的任务从 runningTasks 认（实时），成功/失败从画布快照里认（存过盘的）
    private func dotState(_ conv: AIVideoService.ConversationRecord) -> HistoryDotState {
        if service.runningTasks.values.contains(where: { $0.convId == conv.id }) { return .running }
        guard let canvas = conv.canvas else { return .idle }
        if canvas.nodes.contains(where: { $0.failure != nil }) { return .failed }
        if !canvas.producedAssets.isEmpty { return .done }
        return .idle
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

    /// 输入框里用 `/` 点名的生成模型。
    ///
    /// 供应商下拉只剩 Agent 模型之后，参考图区、时长比例这些控件不能再跟着
    /// selectedProvider 走 —— 改成跟着命令：打了 /seedance 就按视频那套显示
    private var namedModel: AIVideoService.Provider? { namedModel(in: inputText) }

    /// 从一段文本里认出 `/` 点名的生成模型。
    /// **发送时必须传 text**：sendMessage 会先把输入框清空再调 runAgent，
    /// 那时候再读 inputText 只会读到空串，界面上选的参数就带不过去了
    private func namedModel(in text: String) -> AIVideoService.Provider? {
        let names = SlashCommands.matchedRanges(in: text)
            .map { (text as NSString).substring(with: $0).dropFirst() }
            .map(String.init)
        for n in names {
            if let p = AIVideoService.Provider.allCases.first(where: {
                !$0.isHidden && $0.category != .text && SlashCommands.slug($0.rawValue) == n
            }) { return p }
        }
        return nil
    }

    /// 这一轮实际按哪家的规则摆控件
    private var uiProvider: AIVideoService.Provider {
        namedModel ?? service.selectedProvider
    }

    /// 下拉里只剩 Agent 模型了，旧配置可能还存着图片/视频模型 —— 那样发消息会
    /// 走老的生成链路而不是 Agent，开面板时先纠正回来
    private func ensureAgentProvider() {
        guard service.selectedProvider.category != .text,
              let first = AIVideoService.Provider.providers(for: .text).first else { return }
        service.selectedProvider = first
        settings.aiProvider = first.rawValue
    }

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
        // 宽度从 GeometryReader 直接给，不走 preference + @State 那条路：
        // 那条要绕一帧才回来，拖动侧边栏时气泡永远按上一帧的宽度排版，
        // 得滚一下让 cell 重建才追上
        GeometryReader { geo in
            scrollBody.environment(\.chatListWidth, geo.size.width)
        }
    }

    /// 会话是不是已经拉到底。没贴底说明用户正翻旧消息，
    /// 这时候 Agent 那边刷新不该把人拽回去
    @State private var atBottom = true
    /// 会话区可视高度，判断贴底要用
    @State private var viewportH: CGFloat = 0
    /// 最后一次内容变高的时刻。内容长高时探针也会被顶出可视区，
    /// 跟「用户自己往上翻」在探针那儿长得一模一样，只能靠时间窗分开
    @State private var lastGrow = Date.distantPast

    private var scrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // 每条气泡自己还带 4pt 上下内边距，两条之间实际是 12+8=20pt，太空
                LazyVStack(spacing: 6) {
                    ForEach(service.messages) { msg in
                        MessageBubble(message: msg, onInsertToTimeline: { url in
                            insertMediaToTimeline(url)
                        }, onRestoreAttachment: { att in
                            restoreAttachment(att)
                        })
                        .id(msg.id)
                    }
                }
                // 左边缘跟标题「AI 创作」对齐（标题是 leading 3）
                .padding(.leading, leadPad).padding(.trailing, 10)
                .padding(.vertical, 10)

                // 贴底探针。跟在内容最后，它进了可视区就说明人在最底下。
                // ScrollView 没有现成的偏移量可读，只能这么量
                Color.clear.frame(height: 1)
                    .background(GeometryReader { g in
                        Color.clear.onChange(of: g.frame(in: .named("chatScroll")).minY) { y in
                            // 高度还没量到就别判，viewportH 是 0 时算出来永远
                            // 是「没贴底」，之后探针不动，自动滚就再也不触发了
                            guard viewportH > 0 else { return }
                            // 刚长高那一下不算用户上翻
                            guard Date().timeIntervalSince(lastGrow) > 0.4 else { return }
                            atBottom = y - viewportH < 40
                        }
                    })
            }
            .coordinateSpace(name: "chatScroll")
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewportH = g.size.height }
                    .onChange(of: g.size.height) { viewportH = $0 }
            })
            // 切到素材库再切回来，面板是重建的 —— 不补这一下会停在顶部
            .onAppear { scrollToLast(proxy, waitForLayout: true) }
            .onChange(of: service.messages.count) { _ in
                lastGrow = Date()
                scrollToLast(proxy, waitForLayout: true)
            }
            // 生成完成时消息条数**没变**：同一条 assistant 消息的 status 从 .generating
            // 变成 .completed 并挂上视频卡片。只看 count 就不会滚，用户得自己往下拖
            .onChange(of: service.messages.last?.status) { _ in
                lastGrow = Date()
                scrollToLast(proxy, waitForLayout: true)
            }
            // Agent 跑的时候最后那条一直在长高：步骤一条条往里加、跑完再把
            // 正文写进去 —— 条数和 status 全程不变，只盯那两个就一路被顶在上面
            // 回复正文冒出来那一下必须到底 —— 那正是用户要看的东西
            .onChange(of: service.messages.last?.content) { _ in
                lastGrow = Date()
                scrollToLast(proxy, waitForLayout: true)
            }
            // 过程中的高频刷新才看贴底：人正翻旧消息时不该被拽回来
            .onChange(of: agent.steps.count) { _ in
                lastGrow = Date()
                scrollToLast(proxy, onlyIfAtBottom: true)
            }
            .onChange(of: agent.phase) { _ in
                lastGrow = Date()
                scrollToLast(proxy, onlyIfAtBottom: true)
            }
        }
    }

    /// `onlyIfAtBottom`：人正翻着旧消息就别动。
    /// 自己发的新消息不受这条限制 —— 发完看不到自己那条会以为没发出去
    private func scrollToLast(_ proxy: ScrollViewProxy, waitForLayout: Bool = false,
                              onlyIfAtBottom: Bool = false) {
        if onlyIfAtBottom && !atBottom { return }
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
        switch uiProvider.category {
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
    @State private var webHover = false
    @State private var plusHover = false
    /// Agent 对话的附件（图片给模型看，文本读成文字塞进提示词）
    private var agentAttachments: [AgentAttachment] {
        get { service.agentAttachments }
        nonmutating set { service.agentAttachments = newValue }
    }
    /// 有文件正拖在聊天区上方
    @State private var isDropTargeted = false
    /// 正从素材库挑东西，挑完放哪儿
    @State private var libraryPick: LibraryPickTarget?
    /// ＋ 弹出来那个菜单开在哪一页。nil = 没开
    /// ＋ 按钮在窗口里的位置，报给最外层那个菜单用
    @State private var plusButtonRect: CGRect = .zero
    /// Skill 面板停在哪个标签页

    /// 根菜单固定 4 行 × 30pt + 上下各 5 的留白
    static let plusMenuHeight: CGFloat = 4 * 30 + 10
    static let plusMenuWidth: CGFloat = 190

    /// 参考内容是不是摊开成平铺了
    @State private var refExpanded = false
    /// **整个面板**有多宽。参考区、附件区一行放几个都按它算。
    ///
    /// 不能量那两块自己：气泡的宽度是「子视图里最宽的那个」，网格一撑气泡就变宽，
    /// 量到的又是撑大后的值 —— 正反馈，拉窄侧栏时列数永远减不回去。
    /// 面板这一层的宽度由侧栏的 `frame(width:)` 钉死，不受内容影响
    @State private var panelWidth: CGFloat = 0
    /// 气泡内外的边距加起来，算可用宽度时扣掉
    private static let refGridInset: CGFloat = 40
    /// 摊开最多铺这么多张，再多就只能在里头滚 —— 也是给渲染兜个底
    private static let maxExpandedRefs = 50
    private static let expandedRefMaxHeight: CGFloat = 220

    enum LibraryPickTarget: Identifiable {
        case reference, firstFrame, lastFrame
        var id: Int { hashValue }
    }

    /// 素材库弹窗里能选哪几类 —— 按当前模型收得下的来。
    /// 首尾帧只认图片
    private var libraryPickKinds: Set<CanvasNode.Kind> {
        guard libraryPick == .reference else { return [.image] }
        // 还没点名生成模型时不设限，跟「上传附件」一个待遇 ——
        // 先收进来，之后打了命令再按那家支持的类型分流
        guard namedModel != nil else { return [.image, .video, .audio] }
        var s: Set<CanvasNode.Kind> = []
        if uiProvider.maxReferenceImages > 0 { s.insert(.image) }
        if uiProvider.maxReferenceVideos > 0 { s.insert(.video) }
        if uiProvider.maxReferenceAudios > 0 { s.insert(.audio) }
        return s
    }
    /// 侧栏那份和画布那份同时在，登记同一个名字会互相覆盖 ——
    /// 画布的排在前面，它开着的时候就该它收
    private var dropZoneKind: FileDropRouter.Kind { inCanvas ? .canvasChat : .aiChat }
    /// 侧栏那份左边只留 3 是为了跟外面「AI 创作」那行标题对齐；
    /// 画布上是一张独立卡片，左右得一样宽
    private var leadPad: CGFloat { inCanvas ? 10 : 3 }
    /// 卡片标题用会话名，跟侧栏历史列表里显示的是同一个
    private var conversationTitle: String {
        guard let id = service.currentConversationId,
              let c = service.history.first(where: { $0.id == id }) else { return "新会话" }
        return c.title
    }

    /// 正文行距。目标是 1.4 倍行高（12pt 字 → 16.8pt 行高），
    /// 而 lineSpacing 加的是行间额外间距，默认单行已占约 14.3pt，所以补 2.5。
    /// 模型回复、用户气泡、输入框三处共用这一个值
    static let bodyLineSpacing: CGFloat = 2.5
    /// 聊天正文的字号。气泡、回答、输入框都读它 ——
    /// 散在各处写死 13 的话，设置里调一下只有一半地方跟着变
    static var bodyFontSize: CGFloat { CGFloat(AppSettings.shared.chatFontSize) }

    private var inputArea: some View {
        VStack(spacing: 0) {
            // 危险操作的确认长在会话里，就在输入框上方，不弹系统窗
            if let c = agent.pendingConfirm {
                AgentConfirmBar(toolName: c.toolName, detail: c.detail, onAnswer: c.onAnswer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, leadPad).padding(.trailing, 10)
                    .padding(.bottom, 6)
            }

            // 后台任务入口在输入区正上方，占正常的位置 —— 浮起来的话会压到
            // 会话最后一条上。没有任务时它自己不显示
            AgentTaskEntry()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, leadPad)
                // 气泡自己带 8pt 的 top padding，这儿再给 6 就是双份，收到 2
                .padding(.bottom, 2)

            VStack(spacing: 0) {
                // 上下排，不并排 —— 两块都要按自己那行的宽度换行，
                // 并排时它们互相挤宽度，谁也算不准一行放几个
                VStack(alignment: .leading, spacing: 6) {
                    if uiProvider.maxReferenceImages > 0 {
                        imagePreviewArea
                    }
                    if !agentAttachments.isEmpty {
                        AgentAttachmentBar(items: agentAttachments,
                                           availableWidth: max(0, panelWidth - Self.refGridInset),
                                           onRemove: { it in
                                               agentAttachments.removeAll { $0.id == it.id }
                                           },
                                           onClear: { agentAttachments.removeAll() })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 跟输入框左边缘对齐，上面也留一样的空
                .padding(.leading, 8)
                .padding(.top, 8)

                ChatInputTextView(
                    // 草稿存在 service 上，binding 直接取它的投影
                    text: $service.agentInputText,
                    onAddSubtitle: { project.insertSubtitleAtPlayhead(text: $0) },
                    onAddTitle: { project.addTextAtPlayhead(text: $0) },
                    onSubmit: { sendMessage() },
                    onSlashQuery: { q, caret in
                        slashQuery = q
                        slashCaret = caret
                        slashIndex = 0
                    },
                    slashOpen: !slashMatches.isEmpty,
                    onSlashKey: { key in
                        let n = slashMatches.count
                        guard n > 0 else { return }
                        switch key {
                        case .up:      slashIndex = (slashIndex - 1 + n) % n
                        case .down:    slashIndex = (slashIndex + 1) % n
                        case .confirm: pickSlash(slashMatches[min(slashIndex, n - 1)])
                        case .cancel:  slashQuery = nil
                        }
                    },
                    // 只打了命令、还没写正文时也要提示 —— 那正是用户
                    // 等着看「这个模型能塞几张参考图」的时候
                    placeholder: inputPlaceholder,
                    showsPlaceholder: placeholderVisible,
                    externalRevision: inputRevision,
                    onDropFiles: { addAgentAttachments($0) }
                )
                    .frame(height: inputHeight)
                    .animation(nil, value: inputHeight)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)

                HStack(spacing: 2) {
                    // 子模型跟生成参数是一组：先定用哪家的哪个型号，再定时长比例。
                    // 只在 `/` 点名了生成模型时出现 —— 没点名时 uiProvider 就是
                    // Agent 模型，它的子模型属于框外那排，不该跑到这儿来
                    if namedModel != nil, !uiProvider.subModels.isEmpty {
                        capsuleMenu(label: currentSubModelLabel) {
                            uiProvider.subModels.map { m in
                                MenuChoice(label: m.label,
                                           checked: m.label == currentSubModelLabel) {
                                    settings.setProviderModel(m.id, for: uiProvider.rawValue)
                                }
                            }
                        }
                    }
                    if uiProvider.category == .video {
                        capsuleMenu(label: imageMode == .reference ? refSlotLabel : imageMode.label) {
                            [MenuChoice(label: refSlotLabel, checked: imageMode == .reference) {
                                firstFrameImage = nil; lastFrameImage = nil
                                imageMode = .reference
                             },
                             MenuChoice(label: "首尾帧", checked: imageMode == .frames) {
                                referenceContents.removeAll()
                                imageMode = .frames
                             }]
                        }
                        capsuleMenu(label: currentDuration + "s") {
                            durations.map { d in
                                MenuChoice(label: d + "s", checked: d == currentDuration) {
                                    settings.aiDuration = d
                                }
                            }
                        }
                        capsuleMenu(label: settings.aiRatio) {
                            ratios.map { r in
                                MenuChoice(label: r, checked: r == settings.aiRatio) {
                                    settings.aiRatio = r
                                }
                            }
                        }
                        capsuleMenu(label: currentResolution) {
                            resolutions.map { r in
                                MenuChoice(label: r, checked: r == currentResolution) {
                                    settings.aiResolution = r
                                }
                            }
                        }
                    } else if uiProvider.category == .image {
                        capsuleMenu(label: settings.aiImageRatio) {
                            ratios.map { r in
                                MenuChoice(label: r, checked: r == settings.aiImageRatio) {
                                    settings.aiImageRatio = r
                                }
                            }
                        }
                        // 张数。上限跟着当前模型走 —— Seedream 5.0 Pro 官方只有单图能力，
                        // 就只列「1 张」。**只有一档也照样显示** ——
                        // 藏起来的话切模型时这个控件忽有忽无，用户还以为出了毛病
                        let maxN = AIVideoService.maxImages(for: uiProvider)
                        capsuleMenu(label: "\(min(settings.aiImageCount, maxN)) 张") {
                            (1...maxN).map { n in
                                MenuChoice(label: "\(n) 张",
                                           checked: n == min(settings.aiImageCount, maxN)) {
                                    settings.aiImageCount = n
                                }
                            }
                        }
                    }

                    Spacer()

                    // 生成中也照常显示发送按钮 —— 多任务之后可以接着发下一条。
                    // 停止只在每条生成中的消息气泡上，不在这里做全局停止
                    // Agent 跑着的时候这个位置就是停止 —— 发出去之后要停，
                    // 手会自然回到刚才点的地方，不该再去别处找一个按钮
                    Button {
                        if agent.isRunning { agent.cancel(project: project) } else { sendMessage() }
                    } label: {
                        Image(nsImage: SidebarSVGIcon.load(agent.isRunning ? "toastStop" : "send",
                                                           size: 16))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            // 跟素材区左侧那排图标同一个默认灰；不可发送时再压暗
                            .foregroundColor(agent.isRunning || canSend
                                             ? Color.labelSecondary
                                             : Color.labelSecondary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!agent.isRunning && !canSend)
                    .help(agent.isRunning ? "停止" : "发送")

                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .clipped()
            }
            // 拖动热区：贴着输入区上边缘的内侧 12pt。
            //
            // 必须挂在这一层（气泡本体）而不是外层容器 —— 外层还有 8pt 的
            // top padding，挂那儿热区会落在气泡上方的空白里，跟看到的边缘错开，
            // 表现就是"有时能拖有时拖不动"。
            // **整条留在边界内**：越过父视图边界的部分收不到鼠标（命中测试不出
            // bounds），原来靠 offset 推出去一半，那一半是白给的。
            //
            // 用 `.background` 而不是 `.overlay`，位置也排在气泡底色**之前** ——
            // 这样它夹在底色和内容之间：顶上那排缩略图和删除角标先接到鼠标，
            // 只有真正的空白处才落到热区。搁在 overlay 里是最上层，
            // 鼠标一挨到角标就变成上下拖动的箭头，那一层的 DragGesture
            // 还会把点击一并吃掉
            .background(alignment: .top) {
                Color.clear
                    .frame(height: 12)
                    .contentShape(Rectangle())
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
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // `/` 候选浮在输入区上方。**必须挂在 clipShape 之后** ——
            // 挂里面的话向上溢出的部分全被那个圆角裁掉，只剩贴着边的最后一项
            .overlay(alignment: .topLeading) {
                if !slashMatches.isEmpty {
                    SlashCommandPopup(commands: slashMatches,
                                      selectedIndex: $slashIndex,
                                      onPick: { pickSlash($0) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: -(SlashCommandPopup.height(for: slashMatches.count) + 6))
                }
            }
            .padding(.leading, leadPad).padding(.trailing, 10)
            .padding(.top, 8)

            // Agent 自己的那套（模式、附件、推理、联网、模型）在输入框**外面**。
            // 原来用 overlay + offset 顶出去，越过父视图边界的部分收不到鼠标 ——
            // 气泡还在（toolTip 走 AppKit 那条路），但点不动、hover 也没反馈
HStack(spacing: 2) {
            // Agent 只在文字模型下才有意义 —— 图片/视频/音频那几个
            // 供应商压根不支持工具调用，摆个模式切换出来只会让人以为能用
            if service.selectedProvider.category == .text {
                // 自己弹 NSMenu：SwiftUI 的 Menu 会把 label 里的换行压平，
                // 标题和那句解释挤成一行，读起来分不清哪句管哪个模式
                Button { showModeMenu() } label: {
                    HStack(spacing: 3) {
                        Text(settings.agentMode.rawValue)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundColor(Color.labelSecondary)
                    .padding(.leading, leadPad).padding(.trailing, 10)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.agentMode.help)
            }

            // 添加入口。点开是一张菜单：上传 / 素材库 / Skill / MCP
            Button {
                // 菜单挂在窗口最外层画（PlusMenuOverlay），这里只报按钮位置。
                // 顺手记下是谁开的 —— 画布和侧栏两份面板同时在，回调得认人
                project.plusMenuFromCanvas = inCanvas
                project.plusMenuAnchor = project.plusMenuAnchor == nil ? plusButtonRect : nil
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(
                            plusHover || project.plusMenuAnchor != nil ? 0.10 : 0)))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { plusHover = $0 }
            .overlay { ChatTooltip(text: "添加内容") }
            // 量自己在窗口里的位置，菜单按它定位
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { plusButtonRect = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, r in plusButtonRect = r }
            })

            Spacer()

            if service.selectedProvider.supportsWebSearch {
                Button {
                    service.webSearchEnabled.toggle()
                } label: {
                    Image(nsImage: SidebarSVGIcon.load("webSearch", size: 13))
                        .renderingMode(.template)
                        .foregroundColor(service.webSearchEnabled
                                         ? Color.accent : Color.labelSecondary)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(webHover ? 0.10 : 0)))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { webHover = $0 }
                // .help 挂在 Button 上不弹，挂到 label 那层才认
                .overlay { ChatTooltip(text: service.webSearchEnabled ? "联网：已开启" : "联网：已关闭") }
            }

            if !service.selectedProvider.reasoningLevels.isEmpty {
                capsuleMenu(label: currentReasoningLabel) {
                    service.selectedProvider.reasoningLevels.map { lv in
                        MenuChoice(label: lv.label, checked: lv.label == currentReasoningLabel) {
                            settings.setProviderReasoning(lv.value, for: service.selectedProvider.rawValue)
                        }
                    }
                }
            }
                if !service.selectedProvider.subModels.isEmpty {
                    capsuleMenu(label: agentSubModelLabel) {
                        service.selectedProvider.subModels.map { m in
                            MenuChoice(label: m.label, checked: m.label == agentSubModelLabel) {
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
                    .padding(.leading, leadPad)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.horizontal, 7)
            .padding(.top, 5)
            .padding(.bottom, 8)
        }
    }

    /// 一项下拉选项
    struct MenuChoice {
        let label: String
        let checked: Bool
        let action: () -> Void
    }

    /// 胶囊下拉。外观照旧，弹的换成自绘行的 NSMenu ——
    /// SwiftUI 的 Menu 由系统画项，高亮跟着系统强调色走，跟这里的黄主色打架
    private func capsuleMenu(label: String, active: Bool = false,
                             choices: @escaping () -> [MenuChoice]) -> some View {
        Button {
            let menu = NSMenu()
            menu.minimumWidth = 160
            for c in choices() {
                menu.addItem(MenuRowView.item(title: c.label, checked: c.checked,
                                              width: 160, action: c.action))
            }
            popUp(menu)
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(active ? Color.accent : Color.labelSecondary)
            .padding(.leading, 2).padding(.trailing, 5)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    // MARK: - 图片预览区

    private var imagePreviewArea: some View {
        HStack(spacing: 2) {
            if imageMode == .reference || uiProvider.category != .video {
                refContentSlot
            } else {
                frameSlot(image: firstFrameImage, label: "首帧") {
                    pickSingleImage { u, i in firstFrameImage = (u, i) }
                }
                // 只有支持尾帧的模型才显示尾帧槽，否则用户设了会被 API 静默丢弃。
                // 认 uiProvider —— 这一栏是给命令点名的那个生成模型用的，
                // 拿 Agent 模型去问支不支持尾帧，答案永远是不支持
                if uiProvider.supportsLastFrame {
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

    /// 视频模型跟「首尾帧」二选一，那一档叫「智能参考」；
    /// 其余只收图片的叫「参考图」，能收视频/音频的叫「参考内容」
    private var refSlotLabel: String {
        let p = uiProvider
        if p.category == .video { return "智能参考" }
        return (p.maxReferenceVideos == 0 && p.maxReferenceAudios == 0) ? "参考图" : "参考内容"
    }

    @ViewBuilder
    private var refContentSlot: some View {
        if refExpanded {
            expandedRefGrid
        } else {
            // 还没装满就把空槽留在缩略图**后面**，接着加下一个；
            // 满了（比如 10 张收齐）才收起来。间距照画布卡片那排来
            HStack(spacing: 6) {
                if !referenceContents.isEmpty { pickedFan }
                if referenceContents.count < uiProvider.maxReferenceTotal {
                    placeholderSlot(label: refSlotLabel, icon: "photo.badge.plus",
                                    onUpload: { pickRefContents() },
                                    onLibrary: { libraryPick = .reference })
                }
            }
        }
    }

    /// 摊开的那一片。**长在原位**，把输入区自己撑高，不是浮一层卡片在上面。
    /// 一行铺满就换行；超过上限高度才在里头滚
    private var expandedRefGrid: some View {
        let shown = Array(referenceContents.prefix(Self.maxExpandedRefs))
        let canAdd = referenceContents.count < uiProvider.maxReferenceTotal
        // 列数**自己按量到的宽度算**，不交给 .adaptive ——
        // 那个配上 fixedSize 会拿到「无限宽」的提案，图一多就排成横着一长条，
        // 直接顶出聊天框外面
        let cols = max(1, Int((max(0, panelWidth - Self.refGridInset) + 6) / 54))
        let rows = max(1, (shown.count + (canAdd ? 1 : 0) + cols - 1) / cols)
        let height = min(CGFloat(rows) * 54 - 6, Self.expandedRefMaxHeight)
        return VStack(alignment: .leading, spacing: 0) {
            // 收起按钮单占一行，不压在图上
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { refExpanded = false }
                } label: {
                    // 两个尖括号对着、转 45° —— 就是「收起来」那个意思
                    // 尖对尖的两个尖括号，转 45° —— 「收起来」那个意思。
                    // SF Symbol 里没有现成的，自己拼：上面那个尖朝下、下面那个尖朝上
                    VStack(spacing: -1) {
                        Image(systemName: "chevron.down")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 6, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .foregroundColor(Color.labelSecondary.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay { ChatTooltip(text: "收起") }
                .padding(.trailing, 8)
            }
            .padding(.bottom, 2)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: cols),
                          alignment: .leading, spacing: 6) {
                    ForEach(shown) { refThumb($0) }
                    // 加更多的入口跟在最后一张后面
                    if canAdd {
                        placeholderSlot(label: refSlotLabel, icon: "photo.badge.plus",
                                        onUpload: { pickRefContents() },
                                        onLibrary: { libraryPick = .reference })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height)
            // **必须裁**：列数是按上一次量到的宽度定死的，侧栏一拉窄，
            // 那一整行会把容器撑大，探针跟着量到撑大后的宽度 —— 列数于是永远
            // 减不回去（拉宽正常，就是因为拉宽时本来就更宽）
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// 平铺里的一张：缩略图 + 单独删除
    private func refThumb(_ item: RefContent) -> some View {
        Image(nsImage: item.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // 图片是 .fill 的，实际内容比 48×48 大。裁了显示还得锁死命中范围，
            // 不然溢出的那部分可能压到旁边格子的删除按钮上
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                ThumbCloseButton(size: 16) {
                    referenceContents.removeAll { $0.id == item.id }
                    if referenceContents.isEmpty { refExpanded = false }
                }
                .padding(1)
                .zIndex(1)
            }
    }

    /// 已经选好的那几个，叠成一小摞
    private var pickedFan: some View {
        ZStack { fanThumbnails }
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
            // 点一下摊开看全部；再点收起。加新的走后面那个空槽
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { refExpanded.toggle() }
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
                            Image(nsImage: SidebarSVGIcon.load("video", size: 9))
                                .renderingMode(.template)
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(2)
                        } else if item.type == .audio {
                            Image(nsImage: SidebarSVGIcon.load("audio", size: 9))
                                .renderingMode(.template)
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
                    // 标出这张是首帧还是尾帧，跟画布上那份一个样式
                    // （CanvasPromptBar 的 refThumbImage badge）
                    .overlay(alignment: .topLeading) {
                        Text(label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accent))
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                    .onTapGesture(perform: onPick)
            } else {
                placeholderSlot(label: label, onUpload: onPick,
                                onLibrary: { libraryPick = label == "首帧" ? .firstFrame : .lastFrame })
            }
        }
    }

    /// 统一的删除角标。跟附件条上那颗、画布参考图上那颗是同一个样子：
    /// 细叉 + 黑底圆。**整颗留在框内**（原来靠 offset 顶出去一半，
    /// 越过父视图边界的那半收不到鼠标）
    private func deleteBadge(action: @escaping () -> Void) -> some View {
        // 样式和热区都在 ThumbCloseButton 里，别在这儿另起一套
        ThumbCloseButton(size: 16, opacity: 0.7, action: action)
            .padding(2)
    }

    private func placeholderSlot(label: String, icon: String = "photo",
                                 onUpload: @escaping () -> Void,
                                 onLibrary: @escaping () -> Void) -> some View {
        RefPlaceholderSlot(label: label, icon: icon, onUpload: onUpload, onLibrary: onLibrary)
    }

    /// 把 `/名字 ` 插到输入框末尾，跟从候选列表里选是一回事
    private func insertCommand(_ name: String) {
        inputText += (inputText.isEmpty || inputText.hasSuffix(" ") ? "" : " ") + "/" + name + " "
        inputRevision += 1
        // 命令点名了生成模型，手上那些附件立刻收进参考区。
        // 不等 onChange(namedModel) —— 那条要多绕一拍；
        // 有了这一下，「先选模型再加附件」和「先加附件再选模型」两条路一样
        promoteAttachmentsToReference()
    }

    // MARK: - 参考内容选择

    private static let imageExts = AIVideoService.imageExts
    private static let videoExts = AIVideoService.videoExts
    private static let audioExts = AIVideoService.audioExts

    /// 选图片/文本文件当附件
    private func pickAgentAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { resp in
            guard resp == .OK else { return }
            addAgentAttachments(panel.urls)
        }
    }

    /// 把聊天区登记成文件接收区。只收 Finder 文件 ——
    /// 素材库拖出来的那些载荷（素材 id / 图形 / 滤镜）归时间轴，不该落这儿
    private func registerChatDropZone(_ rect: CGRect) {
        FileDropRouter.register(windowID, kind: dropZoneKind, rect: rect,
                                accepts: { if case .files = $0 { return true } else { return false } },
                                onDrop: { payload, _ in
                                    if case .files(let urls) = payload { addAgentAttachments(urls) }
                                },
                                onTargetChange: { isDropTargeted = $0 })
    }

    /// 收下这些文件。
    ///
    /// **参考内容和附件是同一个入口**：当前这条命令点名的模型能收参考素材时，
    /// 拖进来的媒体先按它的上限当参考内容（首尾帧模式下按上传顺序进首帧、尾帧），
    /// 装不下的、或者这家压根不收的，才落回附件。
    ///
    /// 落回附件的只认图片和能读成文字的 —— 视频音频塞给模型没意义。
    /// 但**不能静默丢掉**：拖进来什么都不发生，用户只会以为功能坏了
    /// 点名生成模型之后，把之前当附件收着的图挪进参考区。
    ///
    /// 加图那会儿当前还是文字模型（`maxReferenceTotal` 为 0），参考区收不了，
    /// 只能先躺在附件里 —— 用户的顺序常常是「先拖图、再打 /命令」，
    /// 不补这一下，图就一直是附件，生成时也带不上
    /// 命令被删掉之后，参考区里的东西转成普通附件。
    ///
    /// 没有生成模型点名，参考区整块就不显示了 —— 直接丢的话，
    /// 用户挑了半天的图一声不响就没了
    private func demoteReferencesToAttachments() {
        var urls = referenceContents.map(\.url)
        if let f = firstFrameImage { urls.append(f.url) }
        if let l = lastFrameImage { urls.append(l.url) }
        guard !urls.isEmpty else { return }
        referenceContents.removeAll()
        firstFrameImage = nil
        lastFrameImage = nil
        for u in urls {
            guard AgentAttachmentIO.accepts(u),
                  !agentAttachments.contains(where: { $0.url == u }),
                  let a = AgentAttachmentIO.make(u) else { continue }
            agentAttachments.append(a)
        }
    }

    private func promoteAttachmentsToReference() {
        guard !agentAttachments.isEmpty else { return }
        let p = uiProvider
        guard p.maxReferenceTotal > 0
                || (p.category == .video && imageMode == .frames && p.supportsFirstFrame) else { return }
        var kept: [AgentAttachment] = []
        for a in agentAttachments {
            switch service.addToReference(url: a.url, provider: p) {
            case .added, .duplicate: continue
            case .limitReached, .unsupportedType: kept.append(a)
            }
        }
        if kept.count != agentAttachments.count { agentAttachments = kept }
    }

    private func addAgentAttachments(_ urls: [URL]) {
        let p = uiProvider
        let takesReference = p.maxReferenceTotal > 0
            || (p.category == .video && imageMode == .frames && p.supportsFirstFrame)

        var rejected: [URL] = []
        var limitHit: String?
        for u in urls {
            if takesReference {
                switch service.addToReference(url: u, provider: p) {
                case .added, .duplicate: continue
                case .limitReached(let msg): limitHit = msg      // 满了，试试当附件收
                case .unsupportedType: break                     // 这家不收这类，同上
                }
            }
            guard AgentAttachmentIO.accepts(u) else { rejected.append(u); continue }
            guard !agentAttachments.contains(where: { $0.url == u }),
                  let a = AgentAttachmentIO.make(u) else { continue }
            agentAttachments.append(a)
        }

        if !rejected.isEmpty {
            let names = rejected.prefix(3).map(\.lastPathComponent).joined(separator: "、")
            // icon 要传 **SF Symbol 名**，SuccessToastBubble 那张表会映射成自绘 SVG。
            // 直接传 SVG key（toastFail）表里查不到，会拿去当 SF Symbol 画 —— 画出来是个空圆
            project.showSuccessToast(
                icon: "exclamationmark.triangle.fill", iconColor: Color(hex: "#FF9230"),
                title: limitHit ?? "暂不支持此类素材",
                subtitle: rejected.count > 3 ? "\(names) 等 \(rejected.count) 个" : names)
        } else if let msg = limitHit {
            // 没被拒但确实满了：说一声，不然用户不知道后面那几张去哪了
            project.showSuccessToast(
                icon: "exclamationmark.triangle.fill", iconColor: Color(hex: "#FF9230"),
                title: msg, subtitle: "多出来的那几个当普通附件收下了")
        }
    }

    private func pickRefContents() {
        // 认命令点名的那个模型 —— 拿 Agent 模型问「能塞几张参考图」，
        // 答案是 0，remaining 直接为负，点了槽位没任何反应
        let provider = uiProvider
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
        switch service.addToReference(url: url, provider: uiProvider) {
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

    /// 去掉 `/命令` 之后还剩不剩东西。只剩命令时照样给提示
    private var placeholderVisible: Bool {
        var rest = inputText
        for r in SlashCommands.matchedRanges(in: inputText).reversed() {
            rest = (rest as NSString).replacingCharacters(in: r, with: "")
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputPlaceholder: String {
        // 跟着命令走：打了 /seedance 就该提示写视频描述，而不是「输入你的问题」
        let p = uiProvider
        let head: String
        switch p.category {
        case .video: head = "描述你想生成的视频…"
        case .image: head = "描述你想生成的图片…"
        case .audio: head = "描述你想生成的声音…"
        case .text:  return "请输入或 / 命令"
        }
        // 首尾帧模式下只认两张图，不用报那一串上限
        if p.category == .video, imageMode == .frames {
            return head + "（第一张是首帧，第二张是尾帧）"
        }
        guard p.maxReferenceTotal > 0 else { return head }
        // 图片模型只能挂参考图，报那一串「视频 ≤0，音频 ≤0」纯属噪音
        if p.category == .image {
            return head + "（参考图数量 ≤\(p.maxReferenceImages)）"
        }
        return head + "（参考内容 图片 ≤\(p.maxReferenceImages)，视频 ≤\(p.maxReferenceVideos)，"
             + "音频 ≤\(p.maxReferenceAudios)，总数 ≤\(p.maxReferenceTotal)）"
    }

    /// 当前选中的子模型（发给 API 的那个名字）；没选过就用清单第一项
    private var currentSubModel: String {
        let saved = settings.providerModel(for: uiProvider.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty {
            // 旧配置存的是显示名，换算成 id（勾选状态才对得上）
            let list = uiProvider.subModels
            return list.first { $0.label == saved }?.id ?? saved
        }
        return uiProvider.subModels.first?.id ?? ""
    }

    /// 界面上显示的子模型名。
    /// 早期版本把显示名当 API 名存了（"Opus5"），这里按 label 兜一次底，
    /// 让旧配置也能对上，不至于显示成一串陌生的 id
    private var currentSubModelLabel: String {
        let v = currentSubModel
        let list = uiProvider.subModels
        return list.first { $0.id == v }?.label
            ?? list.first { $0.label == v }?.label
            ?? v
    }

    /// Agent 模型自己的子模型（框外那排用）。跟生成模型那套分开记
    private var agentSubModel: String {
        let p = service.selectedProvider
        let saved = settings.providerModel(for: p.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty {
            return p.subModels.first { $0.label == saved }?.id ?? saved
        }
        return p.subModels.first?.id ?? ""
    }

    private var agentSubModelLabel: String {
        let v = agentSubModel
        let list = service.selectedProvider.subModels
        return list.first { $0.id == v }?.label ?? list.first { $0.label == v }?.label ?? v
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
        let full = service.selectedProvider.reasoningLevels.first { $0.value == v }?.label ?? v
        // 档位写成「很高 xhigh」，菜单里两半都要（对得上各家文档），
        // 但收起来时只显示中文那半，省得挤
        return full.components(separatedBy: " ").first ?? full
    }

    private var emptyHintText: String {
        switch uiProvider.category {
        case .video: return "描述你想生成的视频"
        case .image: return "描述你想生成的图片"
        case .audio: return "描述你想生成的声音"
        case .text: return "开始对话"
        }
    }

    /// 模式菜单。三档对应 Claude Code 的 plan / auto / bypass，
    /// 标题一行、解释一行。用自定义行画，高亮才不会跟着系统强调色变成黄底
    private func showModeMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 300
        for m in AgentMode.allCases {
            let sets = settings
            menu.addItem(MenuRowView.item(title: "\(m.rawValue)模式",
                                          subtitle: m.help,
                                          checked: m == settings.agentMode,
                                          width: 300) { sets.agentMode = m })
        }
        popUp(menu)
    }

    /// 菜单统一从这儿弹，定位规则一处改
    private func popUp(_ menu: NSMenu) {
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }

    private func showProviderMenu() {
        // 只列 Agent 模型。图片/音频/视频交给 Agent 自己挑 —— 说「用 image2 画一张」
        // 或打 /image2 就行，不必先来这儿切一次
        let menu = NSMenu()
        menu.minimumWidth = 200
        for provider in AIVideoService.Provider.providers(for: .text) {
            let svc = service
            let sets = settings
            menu.addItem(MenuRowView.item(title: provider.displayName,
                                          checked: provider.rawValue == settings.aiProvider,
                                          width: 200) {
                svc.selectedProvider = provider
                sets.aiProvider = provider.rawValue
            })
        }
        popUp(menu)
    }

    /// 生成中也能继续发 —— 服务层是多任务的（v5.1.0），
    /// 一边等图片一边发视频没问题，各自转各自的圈
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前该显示的候选。只在纯文字模型（Agent）下给 —— 图片/视频模型没有 Skill 这回事
    private var slashMatches: [SlashCommand] {
        guard service.selectedProvider.category == .text, let q = slashQuery else { return [] }
        let all = SlashCommands.all()
        guard !q.isEmpty else { return all }
        let key = q.lowercased()
        return all.filter { $0.name.lowercased().contains(key) || $0.detail.lowercased().contains(key) }
    }

    /// 选中一条：把正在打的那半截换成完整命令，后面补个空格接着说需求
    private func pickSlash(_ cmd: SlashCommand) {
        if let tok = SlashCommands.activeToken(in: inputText, cursor: min(slashCaret, inputText.count)) {
            inputText.replaceSubrange(tok.range, with: "/" + cmd.name + " ")
            inputRevision += 1
        } else {
            inputText += (inputText.isEmpty || inputText.hasSuffix(" ") ? "" : " ") + "/" + cmd.name + " "
            inputRevision += 1
        }
        slashQuery = nil
        slashIndex = 0
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        inputRevision += 1
        slashQuery = nil

        // **一律交给 Agent**。挂没挂参考素材都一样 —— 生成走它的
        // generate_* 工具，界面上才有步骤条。
        // 以前挂了参考图会绕开 Agent 直接调生成接口：那条路没有步骤条，
        // 显示的是「正在生成回复」，而且模型按下拉里选的那家发，
        // 跟 `/命令` 点名的对不上
        runAgent(text)
    }

    /// 界面上挂着上一轮的对话，Agent 却说「没有上文」—— agentHistory 是
    /// @State，重启就空了，切会话也不会跟着换。这里拿落盘的聊天记录补上。
    ///
    /// 工具调用那些中间步骤不按协议还原：Claude 要求每个 tool_use 都得配上
    /// tool_result，缺一个就是 400。它需要的话重新查一遍就是了。
    ///
    /// **但调过哪些工具要写进文本里**。只留纯文字问答的话，模型会照着学 ——
    /// 实测一个 31 条全是 `user:text / assistant:text` 的历史，
    /// 足以让它把「这个对话里我都是用文字回答的」当成规矩，
    /// 之后连 remember、install_skill 这种明确该调的也不调了，直接编一句话回你
    private func rebuildAgentHistory() {
        // 最后一条是本轮刚 append 进去的用户消息，交给 prompt 参数带，别重复
        let past = service.messages.dropLast().suffix(30)
        var out: [AgentMessage] = []
        // 上一条 assistant 干过哪些活，攒着挂到**下一条 user 消息**前面。
        //
        // 这些记录以前是拼进 assistant 正文的，两种写法都试过、都被模型学去演了：
        // 写成「（这一轮我做了这些）」它照抄那句措辞；改成 `<tool_log>` 标签块，
        // 它连标签一起抄，还顺手编出「已提交生成任务」「图片生成完成」——
        // 那一轮日志里明明白白是「工具调用 0 个」。
        // 只要记录还长在 assistant 那边，它就当成自己的说话范例。
        // 挂到 user 那边就没这问题：模型不会模仿用户说话
        var pendingLog: String?
        for m in past {
            var t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            // 失败**不能**从历史里剔掉。原来一律跳过，模型于是不知道上一次
            // 生成砸了 —— 用户再说一遍同样的需求，它当没做过，又提交一个。
            // 接口原文动辄几百字符，截一截再进去，别拿 JSON 撑爆上下文
            if case .failed = m.status {
                // 用户主动取消的**不进历史**。界面上那条橙色「已取消」照常显示，
                // 但让模型看见它就会当成一件没办成的事去补做 —— 实测用户取消完
                // 再要 3 张，它交「1 张（补的）+ 3 张」，在提示里写「别补」也没用
                if t.hasPrefix("已取消") || t.contains("已被用户取消") { continue }
                t = "（上一次没成：" + String(t.prefix(160)) + "）"
            }
            switch m.role {
            case .user:
                // 攒着的执行记录挂在用户这句话前面，讲明是系统写的、不是他说的
                var body = t
                if let log = pendingLog {
                    body = "[系统记录·你上一轮实际执行过的工具]\n\(log)\n[记录结束]\n\n" + t
                    pendingLog = nil
                }
                // 得交替着来。连着两条同一边的，并成一条
                if case .user(let prev, _)? = out.last {
                    out[out.count - 1] = .user(prev + "\n\n" + body)
                } else {
                    out.append(.user(body))
                }
            case .assistant:
                // 开头必须是 user，前面没有就丢掉这条
                guard !out.isEmpty else { continue }
                if let steps = m.agentSteps, !steps.isEmpty {
                    // 把每步的工具、参数和结果摘要都带上 —— 模型回头要接着干活，
                    // 光知道「调过 list_tracks」没用，得知道当时查出来的是什么
                    pendingLog = steps.map { st -> String in
                        let a = (st.args?.isEmpty == false) ? "（\(st.args!)）" : ""
                        let r = st.summary.isEmpty ? "" : " → " + st.summary
                        return "· \(st.tool)\(a)\(r)"
                    }.joined(separator: "\n")
                }
                if case .assistant(let prev, _)? = out.last {
                    out[out.count - 1] = .assistant(text: prev + "\n\n" + t, calls: [])
                } else {
                    out.append(.assistant(text: t, calls: []))
                }
            }
        }
        // 最后一条要是 assistant，它那份记录没地方挂 —— 单独补一条 user 带上，
        // 丢掉的话模型又看不见自己调过工具，绕回「不调工具」那个老毛病
        if let log = pendingLog {
            out.append(.user("[系统记录·你上一轮实际执行过的工具]\n\(log)\n[记录结束]"))
        }
        agentHistory = out
        historyConvID = service.currentConversationId
    }

    /// 交给 Agent 跑一轮
    /// 这一轮挂在输入区的东西，原样记进用户气泡里
    private func currentRoundAttachments() -> [AIVideoService.Attachment] {
        var out: [AIVideoService.Attachment] = []
        for r in referenceContents {
            let kind: AIVideoService.AttachmentKind
            switch r.type {
            case .image: kind = .image
            case .video: kind = .video
            case .audio: kind = .audio
            }
            out.append(service.makeAttachment(url: r.url, kind: kind))
        }
        if let f = firstFrameImage {
            out.append(service.makeAttachment(url: f.url, kind: .firstFrame))
        }
        if let l = lastFrameImage {
            out.append(service.makeAttachment(url: l.url, kind: .lastFrame))
        }
        // 普通附件里只有图能显缩略图，文本那些没有对应的 kind，跳过
        for a in agentAttachments where a.isImage {
            out.append(service.makeAttachment(url: a.url, kind: .image))
        }
        return out
    }

    private func runAgent(_ text: String) {
        // 会话里先落一条用户消息（把这轮挂的图一起带上，气泡里才回显），
        // 回答回来再补 assistant 那条
        _ = service.appendUserEntry(text, attachments: currentRoundAttachments())
        if historyConvID != service.currentConversationId { rebuildAgentHistory() }
        // 点名了 Skill 就把这话挑明。光把 `/名字` 混在句子里发过去，
        // 模型未必看得出这是「必须走这条」而不是随口提了一句
        var prompt = text
        let named = SlashCommands.matchedRanges(in: text)
            .map { (text as NSString).substring(with: $0).dropFirst() }
            .map(String.init)
        let namedSkills = named.filter { !SlashCommands.isModel($0) }
        let namedModels = named.filter { SlashCommands.isModel($0) }
        if !namedSkills.isEmpty {
            prompt += "\n\n[用户点名了 Skill：" + namedSkills.map { "「\($0)」" }.joined()
                    + "。先用 read_skill 读它的完整说明，再照着里面写的做。]"
        }
        if !namedModels.isEmpty {
            prompt += "\n\n[用户点名了模型：" + namedModels.map { "「\($0)」" }.joined()
                    + "。调生成工具时把它填进 model 参数。]"
        }
        // 界面上那排下拉是用户明确选过的，不带上的话模型会自己填一套默认值 ——
        // 选了 9:16 结果出 1:1 就是这么来的
        if let m = namedModel(in: text) {
            var picked: [String] = []
            switch m.category {
            case .video:
                picked.append("比例 \(settings.aiRatio)")
                picked.append("时长 \(currentDuration) 秒")
                picked.append("分辨率 \(currentResolution)")
            case .image:
                picked.append("比例 \(settings.aiImageRatio)")
            default: break
            }
            if !picked.isEmpty {
                prompt += "\n\n[用户在界面上选好了：" + picked.joined(separator: "、")
                        + "。调生成工具时按这些填，别自己另定。]"
            }
        }
        // 先占一条空回复，步骤就长在这条气泡里，跑完再把正文填进去
        let replyID = service.beginAgentReply()
        agent.setRunningMessage(replyID, in: service.currentConversationId)
        // 附件：图片压成 JPEG 直接给模型看，文本读出来贴在提示词后面
        var images: [Data] = []
        var docs: [String] = []
        for a in agentAttachments {
            if let img = a.thumb {
                if let d = AgentAttachmentIO.jpegData(img) { images.append(d) }
            } else if AgentAttachmentIO.isTextDoc(a.url),
                      let text = AgentAttachmentIO.readText(a.url) {
                docs.append("<文件 name=\"\(a.name)\">\n\(text)\n</文件>")
            }
        }
        if !docs.isEmpty {
            prompt += "\n\n" + docs.joined(separator: "\n\n")
        }
        if !images.isEmpty {
            prompt += "\n\n[用户带了 \(images.count) 张图，就在这条消息里。]"
        }
        agentAttachments.removeAll()

        // 挂着的参考素材：留一份快照给生成工具（它是异步跑的，等执行时
        // 界面上那份早清空了）。
        //
        // **参考图不发给 Agent 模型**：它只要知道「挂了图、调工具时会自动带上」
        // 就够了，真正看图的是生成模型。而带图的请求在中转站上极慢 ——
        // 实测 1KB 的小图也要 58 秒、53KB 要 97 秒（不带图几秒就回，
        // 跟图大小几乎无关），撑过 180 秒超时就报「网络连接已中断」。
        // 要让模型看图，走 ＋ 上传附件那条，那才是给它看的
        service.agentRoundReferences = referenceContents
        service.agentRoundFirstFrame = firstFrameImage?.url
        service.agentRoundLastFrame = lastFrameImage?.url
        // 新一轮开工，生成名额重新算
        service.agentRoundGenerated = []
        // 从这轮原话里认张数，不等模型传 count
        service.agentRoundImageCount = AIVideoService.parseImageCount(from: prompt)
        if !referenceContents.isEmpty || firstFrameImage != nil {
            prompt += "\n\n[用户挂了参考素材，调生成工具时会自动带上，不用再问他要。]"
        }
        referenceContents.removeAll()
        firstFrameImage = nil
        lastFrameImage = nil
        refExpanded = false

        agent.run(prompt: prompt, images: images, history: &agentHistory,
                  mode: settings.agentMode, project: project,
                  webSearch: service.webSearchEnabled) { reply in
            service.finishAgentReply(id: replyID, text: reply,
                                     steps: agent.steps.map {
                                         .init(tool: $0.toolName, summary: $0.summary,
                                               isError: $0.isError,
                                               args: $0.args.isEmpty ? nil : $0.args,
                                               detail: $0.detail.isEmpty ? nil : $0.detail,
                                               thinking: $0.thinking.isEmpty ? nil : $0.thinking)
                                     },
                                     elapsed: agent.elapsed, tokens: agent.totalTokens)
            agent.setRunningMessage(nil, in: service.currentConversationId)
        }
    }

    private func insertMediaToTimeline(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // 生成的时候就已经进过素材库了，这儿再导一次会被判成重复、
        // 右下角冒一条「已跳过重复素材」。库里有就直接拿，没有才导
        if !project.mediaAssets.contains(where: { $0.url == url }) {
            project.importFile(url)
        }
        guard let asset = project.mediaAssets.first(where: { $0.url == url }) else { return }
        let playhead = project.currentTime
        project.pushUndo()

        if ["mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "audio", iconColor: .accent, title: "AI 音频", subtitle: "已插入时间轨道")
        } else if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "image", iconColor: .accent, title: "AI 图片", subtitle: "已插入时间轨道")
        } else {
            let hasClipAtPlayhead = project.videoTracks.contains { track in
                track.clips.contains { $0.startTime <= playhead && $0.endTime > playhead }
            }
            if hasClipAtPlayhead {
                project.videoTracks.append(Track(label: "视频"))
            }
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "video", iconColor: .accent, title: "AI 视频", subtitle: "已插入时间轨道")
        }
    }
}

// MARK: - 消息气泡

private struct MessageBubble: View {
    @EnvironmentObject var project: ProjectState
    /// 正在跑的那条回复要实时长步骤，所以每条气泡都盯着 Agent
    @ObservedObject private var agent = AgentRunner.shared
    /// 正文字号在设置里能调。不观察的话改完要重启才看得到
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.chatListWidth) private var listWidth: CGFloat

    /// 用户气泡里文字的可用宽度：列表左右 3+10、跟 Spacer 之间 8、
    /// Spacer 至少 20、气泡自己 padding 10×2
    private var userTextWidth: CGFloat { listWidth - 61 }
    /// 取消按钮要跟着任务的存亡显隐，得观察 service
    @ObservedObject private var service = AIVideoService.shared
    let message: AIVideoService.ChatMessage
    var onInsertToTimeline: (URL) -> Void
    var onRestoreAttachment: (AIVideoService.Attachment) -> Void = { _ in }
    @State private var copied = false
    /// 报错默认只给一行。接口原文动辄几百字符（那串 Request id 尤其占地方），
    /// 摊开来能把整屏聊天挤没
    @State private var errorExpanded = false

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
                onAddTitle: { project.addTextAtPlayhead(text: $0) },
                layoutWidth: userTextWidth
            )
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !message.attachments.isEmpty {
                attachmentRow
            }
        }
    }

    /// 气泡底部的参考内容/首尾帧缩略图，点击回填输入区
    /// 「把这个产物放过去」。图标按素材类型走，不跟着场景变 ——
    /// 变的只有提示文字和落点：画布开着就加到画布上，否则插进对应的轨道
    private func addButton(kind: CanvasNode.Kind, url: URL,
                           icon: String, svg: String, tip: String) -> some View {
        let inCanvas = project.showCanvas
        return HoverIconButton(icon: icon, svgName: svg,
                               tip: inCanvas ? "添加到画布" : tip) {
            if inCanvas {
                project.canvas.dropGeneratedMedia(url: url, kind: kind)
            } else {
                onInsertToTimeline(url)
            }
        }
    }

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
        let out = NSMutableAttributedString(string: message.content, attributes: [
            .font: NSFont.systemFont(ofSize: AIChatPanel.bodyFontSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .paragraphStyle: para
        ])
        // `/命令` 画成标签，跟输入框里打的时候一个样
        out.applyCommandChips(fontSize: 11)
        return out
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

                        addButton(kind: .video, url: message.resolvedVideoURL() ?? url,
                                  icon: "film.stack", svg: "addToVideoTrack", tip: "插入视频轨道")
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

                        addButton(kind: .image, url: message.resolvedImageURL() ?? url,
                                  icon: "photo.on.rectangle", svg: "addToImageTrack", tip: "插入图片轨道")
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

                        addButton(kind: .audio, url: message.resolvedAudioURL() ?? url,
                                  icon: "waveform", svg: "addToAudioTrack", tip: "插入音频轨道")
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedAudioURL() ?? url])
                        }
                    }
                }

            case .failed(let error):
                // 短的一行就够，长的收起来给个箭头。阈值粗估：11 号字一行
                // 装得下三十来个字，超了基本就是被截断的
                let canExpand = error.count > 30 || error.contains("\n")
                HStack(alignment: .top, spacing: 4) {
                    Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 12))
                        .renderingMode(.template)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                        .lineLimit(errorExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if canExpand {
                        Button { errorExpanded.toggle() } label: {
                            Image(systemName: errorExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.orange.opacity(0.85))
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(errorExpanded ? "收起" : "展开完整报错")
                    }
                }

            case .idle:
                agentStepsSection
                if !message.content.isEmpty {
                    MarkdownContentView(text: message.content)
                }
                bubbleFooter
            }
        }
        .padding(.vertical, 4)
    }

    /// 这一轮跑到哪了。正在跑的那条读实时状态，其余读落盘的那份
    private var isLiveAgentReply: Bool {
        agent.isRunning && agent.runningMessageID == message.id
    }

    @ViewBuilder
    private var agentStepsSection: some View {
        let steps: [AIVideoService.ConversationRecord.AgentStepRecord] = isLiveAgentReply
            // **id 必须原样带过来**。不传的话每次 map 都生成新 UUID，而计时器
            // 0.5 秒推一次 elapsed 就会重算一遍 body —— ForEach 认出来的全是新元素，
            // 展开状态下整个步骤列表（含 thinking / detail 那些长文本）每半秒
            // 销毁重建一次，越跑越卡
            ? agent.steps.map { .init(id: $0.id, tool: $0.toolName, summary: $0.summary, isError: $0.isError,
                                      args: $0.args.isEmpty ? nil : $0.args,
                                      detail: $0.detail.isEmpty ? nil : $0.detail,
                                      thinking: $0.thinking.isEmpty ? nil : $0.thinking) }
            : (message.agentSteps ?? [])
        if !steps.isEmpty || isLiveAgentReply {
            AgentStepsView(steps: steps,
                           isRunning: isLiveAgentReply,
                           elapsed: isLiveAgentReply ? agent.elapsed : (message.agentElapsed ?? 0),
                           tokens: isLiveAgentReply ? agent.totalTokens : (message.agentTokens ?? 0),
                           phase: isLiveAgentReply ? agent.phase : "")
        }
    }

    /// 回复末尾那行：复制 + 时间。还在跑的时候不出现
    @ViewBuilder
    private var bubbleFooter: some View {
        if !isLiveAgentReply, !message.content.isEmpty {
            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Group {
                        if copied {
                            Image(nsImage: SidebarSVGIcon.load("toastSuccess", size: 13))
                                .renderingMode(.template)
                        } else {
                            Image(nsImage: SidebarSVGIcon.load("copy", size: 13))
                                .renderingMode(.template)
                        }
                    }
                    .foregroundColor(Color.labelSecondary.opacity(copied ? 0.9 : 0.55))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制这条回复")
                Text(Self.clockFormatter.string(from: message.timestamp))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color.labelSecondary.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
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
                            Image(nsImage: SidebarSVGIcon.load("image", size: 11))
                                .renderingMode(.template)
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
    @EnvironmentObject private var project: ProjectState
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
            // 中间那颗播放按钮管行内播放，点画面其它地方是全屏看
            .onTapGesture { project.mediaPreview = MediaPreviewItem(url: url, isVideo: true) }
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
    @EnvironmentObject private var project: ProjectState
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
        .onTapGesture { project.mediaPreview = MediaPreviewItem(url: url, isVideo: false) }
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
    /// 回复正文的字号在设置里能调。不观察的话滑块拖了这儿不重算
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.chatListWidth) private var listWidth: CGFloat

    /// 从列表宽度到这段文字的可用宽度之间，被固定占掉的部分：
    /// 列表左右 3 + 10、气泡跟 Spacer 之间 8、Spacer 至少 20。
    /// 回复气泡去掉底色时水平内边距也一并去了，这里不能再算那 20
    private static let chrome: CGFloat = 3 + 10 + 8 + 20

    private var textWidth: CGFloat { listWidth - Self.chrome }

    var body: some View {
        // 整段用一个 NSTextView 渲染。
        //
        // 两个原因不能用 SwiftUI 的 Text：它的 textSelection 只能在单个 Text
        // 内部选（每段一个 Text 就成了"一次只能选一段"），而且右键弹的是系统
        // 那套菜单，一项都改不了、也拿不到选中范围
        //
        // 宽度显式传下去，高度由它按这个宽度自己算。之前是「SwiftUI 按 proposal
        // 问一次高度就记住」，侧边栏一拉高度还是旧的：拉宽了框太高、文字缩在下半截
        // 顶上空一片，拉窄了框不够高第一行被裁半个字
        // 表格得用真控件画，画不进 NSTextView，所以按「表格 / 非表格」切成几段：
        // 连着的普通块还是合成一个 NSTextView（整段能一次选中），表格块单独出来。
        // 代价是有表格的回复选中会在表格处断开 —— 换表格的观感，这个值
        let groups = Self.groupBlocks(parseBlocks())
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case .text(let blocks):
                    SelectableMarkdownView(
                        attributed: nsAttributed(blocks),
                        onAddSubtitle: { project.insertSubtitleAtPlayhead(text: $0) },
                        onAddTitle: { project.addTextAtPlayhead(text: $0) },
                        layoutWidth: textWidth
                    )
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                        .frame(maxWidth: textWidth, alignment: .leading)
                }
            }
        }
    }

    /// 相邻的普通块并成一组，表格各自单独一组
    enum BlockGroup {
        case text([Block])
        case table([String], [[String]])
    }

    static func groupBlocks(_ blocks: [Block]) -> [BlockGroup] {
        var out: [BlockGroup] = []
        var buf: [Block] = []
        for b in blocks {
            if case .table(let h, let r) = b {
                if !buf.isEmpty { out.append(.text(buf)); buf = [] }
                out.append(.table(h, r))
            } else {
                buf.append(b)
            }
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }

    /// 把解析出的块拼成 NSAttributedString。
    /// 行距按 1.4 倍行高走段落样式，比逐段设 lineSpacing 更准
    private func nsAttributed(_ blocks: [Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = AIChatPanel.bodyLineSpacing

        // 代码块的段落左右各缩 8pt：底是照着行矩形画的，行矩形本来贴着容器
        // 左右边缘，框再向外扩 4 就压到边界上，看着像被截掉一截。
        // 缩 8 之后框落在 4…宽度-4，两边还各留 4pt
        let codePara = NSMutableParagraphStyle()
        codePara.lineSpacing = AIChatPanel.bodyLineSpacing
        codePara.firstLineHeadIndent = 8
        codePara.headIndent = 8
        codePara.tailIndent = -8

        func append(_ str: String, size: CGFloat, weight: NSFont.Weight = .regular,
                    alpha: CGFloat = 0.7, mono: Bool = false, bg: Bool = false) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                            : NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                .paragraphStyle: bg ? codePara : para
            ]
            // 代码底交给 ChipLayoutManager 画 —— .backgroundColor 是方角、
            // 贴着字、也没有内边距
            if bg { attrs[.codeBlock] = true }
            out.append(NSAttributedString(string: str, attributes: attrs))
        }

        /// 行内 markdown（粗体/斜体/链接）交给系统解析，再补上字号和颜色
        // 各档字号都从正文字号推：设置里调一档，标题、代码、项目符号一起跟着走
        let base = AIChatPanel.bodyFontSize
        func appendInline(_ text: String, size: CGFloat = 0, alpha: CGFloat = 0.8) {
            let size = size > 0 ? size : base
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
            // 加粗/斜体是记在 .inlinePresentationIntent 上的，不是 .font 的
            // bold trait —— 只改 font 没用，渲染时 TextKit 照着 intent 又加回去。
            // 摘掉它，行内加粗才真的按正文走
            m.removeAttribute(.inlinePresentationIntent, range: full)
            // 逐段铺色，跳过链接 —— 整段无脑上色会把链接的蓝色盖掉
            m.enumerateAttributes(in: full) { attrs, range, _ in
                // 行内加粗不作数：模型爱拿它当小标题，满屏粗字反而更难读，
                // 一律按正文渲染
                m.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: range)
                if attrs[.link] == nil {
                    m.addAttribute(.foregroundColor,
                                   value: NSColor.white.withAlphaComponent(alpha), range: range)
                }
            }
            out.append(m)
        }

        for (i, block) in blocks.enumerated() {
            if i > 0 { append("\n\n", size: base) }
            switch block {
            case .heading(let level, let t):
                appendInline(t, size: level == 1 ? base + 3 : level == 2 ? base + 1.5 : base + 0.5,
                             alpha: 0.7)
            case .code(let code, _):
                append(code, size: base - 2, mono: true, bg: true)
            case .bullet(let t):
                append("•  ", size: base, alpha: 0.5)
                appendInline(t)
            case .numbered(let n, let t):
                append("\(n).  ", size: base, alpha: 0.5)
                appendInline(t)
            case .paragraph(let t):
                appendInline(t)
            case .table(let header, let rows):
                if Self.tableFits(header, rows) {
                    // 等宽字体按列宽补空格对齐，不画边框
                    append(Self.tableAsAligned(header, rows), size: base - 1.5, alpha: 0.85, mono: true)
                } else {
                    appendInline(Self.tableAsList(header, rows))
                }
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
            case .table(let header, let rows):
                if Self.tableFits(header, rows) {
                    var a = AttributedString(Self.tableAsAligned(header, rows))
                    a.font = .system(size: 11, design: .monospaced)
                    a.foregroundColor = .white.opacity(0.85)
                    out += a
                } else {
                    out += inlineAttr(Self.tableAsList(header, rows))
                }
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

    enum Block {
        case heading(Int, String)
        case code(String, String?)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        /// markdown 表格。第一行是表头，后面是数据行
        case table([String], [[String]])
    }

    /// `|---|:--:|---:|` 这种分隔行
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let body = t.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        guard !body.isEmpty else { return false }
        return body.allSatisfy { "-:| ".contains($0) } && body.contains("-")
    }

    private static func splitRow(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 表格能不能按格子排。**聊天面板就四百来点宽**，列一多、格子一长就挤成一团，
    /// 那种情况退回「字段: 值」的列表，比硬排好读
    private static func tableFits(_ header: [String], _ rows: [[String]]) -> Bool {
        // 有了真表格控件，格子里的长文本会自己换行，不用再按长度卡。
        // 只挡列数：聊天区四百来点宽，超过四列每列就窄得没法读了
        header.count <= 4
    }

    /// 排不下时的退化形式：一行一条，格子写成「表头: 值」
    private static func tableAsList(_ header: [String], _ rows: [[String]]) -> String {
        rows.map { r in
            r.enumerated().map { i, cell in
                let key = i < header.count ? header[i] : ""
                return key.isEmpty ? cell : "\(key): \(cell)"
            }.joined(separator: "　·　")
        }.joined(separator: "\n")
    }

    /// 等宽对齐成文本表格。中文按两个字宽算，不然列对不齐
    private static func tableAsAligned(_ header: [String], _ rows: [[String]]) -> String {
        func width(_ s: String) -> Int {
            s.unicodeScalars.reduce(0) { $0 + (($1.value > 0x2E80) ? 2 : 1) }
        }
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        var w = [Int](repeating: 0, count: cols)
        for r in [header] + rows {
            for (i, c) in r.enumerated() where i < cols { w[i] = max(w[i], width(c)) }
        }
        func pad(_ r: [String]) -> String {
            (0..<cols).map { i -> String in
                let c = i < r.count ? r[i] : ""
                return c + String(repeating: " ", count: max(0, w[i] - width(c)))
            }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }
        var out = [pad(header)]
        out.append(w.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        out += rows.map(pad)
        return out.joined(separator: "\n")
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

            // 表格：`| a | b |` 开头，第二行是 `|---|---|` 那种分隔行
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               Self.isTableSeparator(lines[i + 1]) {
                let header = Self.splitRow(trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(Self.splitRow(t))
                    j += 1
                }
                blocks.append(.table(header, rows))
                i = j
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

        case .table(let header, let rows):
            if Self.tableFits(header, rows) {
                Text(Self.tableAsAligned(header, rows))
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                inlineMarkdown(Self.tableAsList(header, rows))
                    .font(.system(size: 12))
                    .lineSpacing(AIChatPanel.bodyLineSpacing)
                    .foregroundColor(Color.white.opacity(0.7))
            }
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

/// 会话列表的宽度。
///
/// 从**列表**这一层往下传，不从气泡自己身上量 —— 气泡宽度本身要等内容布局完
/// 才知道，拿它反过来算高度就成了循环，SwiftUI 会给出上一帧的旧值：
/// 拉宽了框还是高的，文字缩在下半截、顶上空一片。列表宽度只跟侧边栏有关，
/// 一拉就是定值
private struct ChatListWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var chatListWidth: CGFloat {
        get { self[ChatListWidthKey.self] }
        set { self[ChatListWidthKey.self] = newValue }
    }
}

/// 量会话列表宽度用的。放 background 里，不参与尺寸协商，不影响布局
private struct ChatWidthPref: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

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
    /// 按哪个宽度排版。**普通存储属性**，不是 @Environment ——
    /// 它一变 SwiftUI 就认为这个 view 变了，`sizeThatFits` 必定重跑；
    /// 挂在 environment 上不参与相等性判断，宽度变了也可能不重测
    var layoutWidth: CGFloat = 0

    // 只读，不需要滚动，直接放 NSTextView。
    // 套 NSScrollView 反而量不准尺寸（滚动视图的固有尺寸是不确定的）
    func makeNSView(context: Context) -> ChatTextView {
        let tv = ChatTextView()
        // 命令要画成圆角标签，得换掉排版器 —— 纯属性只能画方角、没有内边距
        tv.textContainer?.replaceLayoutManager(ChipLayoutManager())
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        // 纵向留 2：命令标签比行高略高，要往行外顶一点，不留这 2pt 第一行会被切掉
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticLinkDetectionEnabled = true
        tv.textStorage?.setAttributedString(attributed)
        tv.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: ChatTextView, context: Context) {
        // **不能只比纯文本**：在设置里调正文字号时文字一个没变、属性全变了，
        // 只比 string 的话这里认为「没更新」，字号就永远停在旧值上
        if tv.textStorage?.isEqual(to: attributed) != true {
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
        // 优先用外面给的宽度。proposal 那个在侧边栏拉动后不一定重新问过来，
        // 用它算出的高度会停在上一次的宽度上
        // SwiftUI 会拿 0 和 .infinity 来探这个视图的最小/最大尺寸。
        // 照单全收的话：宽度 0 → 每个字一行 → 高度算成天文数字，框撑得老高、
        // 文字缩在下面，顶上就是那一大片空白。这两种都不是真实布局宽度，一律用外面
        // 给的那个
        var maxWidth = layoutWidth > 1 ? layoutWidth : (proposal.width ?? 300)
        if !maxWidth.isFinite || maxWidth < 1 { maxWidth = layoutWidth > 1 ? layoutWidth : 300 }
        // 高度问 NSTextView **自己的** 排版引擎，别另起一套。
        //
        // 同一段文字、同一个宽度，`boundingRect` 算出 977.5、NSTextView 自己排出来
        // 只有 775 —— 差 203。SwiftUI 按 977.5 给了高度，NSTextView 只占 775，
        // 而它的父视图不是 flipped，origin.y=0 在那套坐标里是**底部**，
        // 于是它贴着底，顶上空出 203：这就是那片空白
        // 宽度还是用 NSAttributedString 量 —— textContainer 那边设了
        // widthTracksTextView，usedRect 的宽度永远等于容器宽度，
        // 拿它量「阿斯达」也是满宽，气泡就撑满整行了
        let rect = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let w = min(maxWidth, ceil(rect.width) + 1)
        // **高度**换成问 NSTextView 自己的排版引擎。同一段文字同一个宽度，
        // boundingRect 算 977.5、它自己排出来 775 —— 差 203。SwiftUI 按 977.5 给高度，
        // 它只占 775，而父视图不是 flipped，origin.y=0 在那套坐标里是底部，
        // 于是贴着底、顶上空出 203：那片空白就是这么来的
        if let tc = nsView.textContainer, let lm = nsView.layoutManager {
            tc.size = NSSize(width: w, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            // +4：textContainerInset 上下各 2
            if h > 0 { return CGSize(width: w, height: ceil(h) + 4) }
        }
        return CGSize(width: w, height: ceil(rect.height) + 4)
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

    /// 点回复里的链接。
    ///
    /// 模型给的多是**相对路径**（`./shot.png`）—— 它的 shell cwd 是 home
    /// （见 `AgentTools+Shell`），路径本身没错，但 `AttributedString(markdown:)`
    /// 把它解析成没有 scheme 的相对 URL，交给 `NSWorkspace.open` 只会弹一个
    /// 「应用程序无法打开。-50」（paramErr），用户完全看不出是怎么回事。
    ///
    /// 所以这里自己认一遍：http/https 照旧；其余当本地路径，按 agent 的工作目录
    /// 补成绝对路径；文件不在就说清楚是哪个路径不在
    override func clicked(onLink link: Any, at charIndex: Int) {
        let raw: String
        if let u = link as? URL { raw = u.scheme == nil ? u.relativeString : u.absoluteString }
        else if let s = link as? String { raw = s }
        else { super.clicked(onLink: link, at: charIndex); return }

        // 网址、邮件这些有 scheme 的交回系统
        if let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
           scheme != "file" {
            NSWorkspace.shared.open(u)
            return
        }

        // 余下按本地路径处理。file:// 先剥掉，~ 展开，相对路径接到 agent 的 cwd 上
        var path = raw
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
        path = path.removingPercentEncoding ?? path
        path = (path as NSString).expandingTildeInPath

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            // agent 的 shell 就在 home 里跑，相对路径以它为基准
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(path).standardizedFileURL
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "找不到这个文件"
            alert.informativeText = url.path
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
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
    /// 光标前正在打的 `/xxx`（不带斜杠）；不在打命令时给 nil
    var onSlashQuery: (String?, Int) -> Void = { _, _ in }
    /// 候选列表开着的时候，上下键/回车/Esc 归它管，不能走进文本框
    var slashOpen: Bool = false
    var onSlashKey: (SlashKey) -> Void = { _ in }
    /// 空输入时的提示。交给文本框自己画，才跟命令标签一条基线
    var placeholder: String = ""
    var showsPlaceholder: Bool = false
    /// 外部改动计数。只有它变了才回写文本，见 AIChatPanel.inputRevision
    var externalRevision: Int = 0
    /// 拖文件进输入框
    var onDropFiles: ([URL]) -> Void = { _ in }

    enum SlashKey { case up, down, confirm, cancel }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ChatInputInner()
        let lm = ChipLayoutManager()
        lm.showsClose = true          // 只有能编辑的输入框才给关闭按钮
        tv.textContainer?.replaceLayoutManager(lm)
        tv.keepCut = true
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.onSubmit = onSubmit
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: ChatInputInner.inputFontSize)
        tv.textColor = .labelColor
        // 横向留 0：外层已经有 8pt 了，这里再加一份会叠成 16
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
            .font: NSFont.systemFont(ofSize: ChatInputInner.inputFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]

        tv.onSlashKey = onSlashKey
        tv.slashOpen = slashOpen
        tv.onDropFiles = onDropFiles
        tv.placeholder = placeholder
        tv.showsPlaceholder = showsPlaceholder
        // 草稿现在是带着走的（存在 service 上），切标签页回来这个视图会重建 ——
        // 不在这儿补一次染色，已经成形的 /命令 会退回成一串纯文本
        Self.highlight(tv)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    /// 已经成形的 `/命令` 画成标签 —— 看到它变成一枚标签就知道这条 Skill 认出来了
    @MainActor
    static func highlight(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        // 字重也要一并还原，不然删掉命令后那几个字还留着加粗
        storage.addAttribute(.font,
                             value: NSFont.systemFont(ofSize: ChatInputInner.inputFontSize),
                             range: full)
        storage.removeAttribute(.chipTag, range: full)
        storage.removeAttribute(.chipSlash, range: full)
        storage.removeAttribute(.kern, range: full)
        // 撑杆的下沉量也要清 —— 删到不成命令了，斜杠会重新显出来，
        // 还带着 baselineOffset 就沉在基线下面，跟后面的字对不齐
        storage.removeAttribute(.baselineOffset, range: full)
        (tv.layoutManager as? ChipLayoutManager)?.resetCloseRects()
        storage.applyCommandChips(fontSize: 11, reserveClose: true)
        storage.endEditing()
        // 标签位置变了，× 的光标区跟着重建
        tv.window?.invalidateCursorRects(for: tv)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ChatInputInner else { return }
        // **只在程序自己改过内容时回写**。这里原来是「值不一样就回写」，
        // 而 Agent 一跑，计时器每秒、每一步、每次 phase 变都会重绘一遍，
        // 重绘时手里的 text 可能还是用户敲这个字之前的值 —— 回写等于把字吞掉
        if context.coordinator.lastRevision != externalRevision {
            context.coordinator.lastRevision = externalRevision
            if tv.string != text {
                tv.string = text
                // 外部塞进来的文本（选中候选项那一下）也要染色
                Self.highlight(tv)
                tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        tv.onAddSubtitle = onAddSubtitle
        tv.onAddTitle = onAddTitle
        tv.onSubmit = onSubmit
        tv.onSlashKey = onSlashKey
        tv.slashOpen = slashOpen
        tv.onDropFiles = onDropFiles
        tv.placeholder = placeholder
        tv.showsPlaceholder = showsPlaceholder
        // 标签宽度一变提示就得挪位置。NSTextView 只重绘脏行，
        // 不强制一次的话上一处的提示会留在原地成重影
        if tv.showsPlaceholder { tv.needsDisplay = true }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSlashQuery: onSlashQuery) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// 上次回写时的外部改动计数
        var lastRevision = 0
        let text: Binding<String>
        let onSlashQuery: (String?, Int) -> Void
        init(text: Binding<String>, onSlashQuery: @escaping (String?, Int) -> Void) {
            self.text = text
            self.onSlashQuery = onSlashQuery
        }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            ChatInputTextView.highlight(tv)
            report(tv)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            report(tv)
        }
        /// 光标停在哪一段 `/xxx` 上就报哪一段，移开就报 nil
        private func report(_ tv: NSTextView) {
            let caret = tv.selectedRange().location
            let utf16 = (tv.string as NSString)
            guard caret <= utf16.length else { onSlashQuery(nil, 0); return }
            let prefix = utf16.substring(to: caret)
            onSlashQuery(SlashCommands.activeToken(in: prefix, cursor: prefix.count)?.query, prefix.count)
        }
    }
}

private final class ChatInputInner: ChatTextView {
    private var closeTracking: NSTrackingArea?
    var onSubmit: (() -> Void)?
    var onSlashKey: ((ChatInputTextView.SlashKey) -> Void)?
    var slashOpen = false
    /// 拖文件进输入框，交给外面收成附件
    var onDropFiles: (([URL]) -> Void)?

    // MARK: 拖文件进来
    //
    // **这一层必须自己接**：NSTextView 本身就注册了 fileURL，拖进来默认是
    // 「把路径当文字插进去」，于是输入框里多出一串 file:///Users/...。
    // SwiftUI 的 `.onDrop` 包在外面轮不到（那条路见 FileDropRouter 的注释），
    // 但 NSTextView 是**真实 NSView**，AppKit 的拖放目标查找找得到它

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        // 收不收得下由外面判断 —— 不认的类型也要在那儿提示，
        // 这里一律拦下，免得又变成往输入框里插路径
        onDropFiles?(urls)
        return true
    }
    /// 空输入时的提示。自己画而不是拿 SwiftUI 的 Text 盖在上面 ——
    /// 打了命令之后它得跟在标签后面、和标签一条基线，
    /// 那个位置只有 layoutManager 知道，外面靠 padding 只能凑
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var showsPlaceholder = false { didSet { if showsPlaceholder != oldValue { needsDisplay = true } } }

    /// 正文字号。提示文字和插入点都按它算，跟真正输入的字对齐
    /// 输入框自己的字号，**固定不跟设置走** —— 那个滑块管的是
    /// 「提问和回复」的字号，输入框跟着变会把布局和光标高度一起带乱
    static let inputFontSize: CGFloat = 13
    private static var bodyFont: NSFont { .systemFont(ofSize: inputFontSize) }

    /// 插入点不跟着行高走。
    ///
    /// 命令标签靠一根放大的「撑杆」把行撑高（见 `applyCommandChips`），
    /// 而插入点默认就是整行那么高 —— 打完命令光标会突然长一截。
    /// 撑杆已经把行的几何中心对到文字视觉中心上了，这里按正文高度居中即可
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let f = Self.bodyFont
        let h = ceil(f.ascender - f.descender)
        guard rect.height > h else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        var r = rect
        r.origin.y = rect.midY - h / 2
        r.size.height = h
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder, !placeholder.isEmpty,
              let lm = layoutManager, let tc = textContainer else { return }

        let f = Self.bodyFont
        let origin = textContainerOrigin
        var x = origin.x
        var baseline = origin.y + f.ascender

        // 有内容时只可能是一枚命令标签（`placeholderVisible` 保证了这点），
        // 提示就接在它后面。基线取**名字**那个字形的 —— 斜杠是撑杆，
        // 带着下沉量，拿它对齐会矮一截
        let len = (string as NSString).length
        if len > 0 {
            lm.ensureLayout(for: tc)
            let ci = min(1, len - 1)
            let gi = lm.glyphIndexForCharacter(at: ci)
            let line = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            baseline = origin.y + line.minY + lm.location(forGlyphAt: gi).y
            x = origin.x + lm.usedRect(for: tc).maxX
        }

        (placeholder as NSString).draw(
            at: NSPoint(x: x, y: baseline - f.ascender),
            withAttributes: [.font: f,
                             .foregroundColor: NSColor.labelColor.withAlphaComponent(0.28)])
    }

    /// 剪贴板里是文件或图片就当附件收下，纯文字照旧粘进输入框
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDropFiles?(urls)
            return
        }
        // 截图这类是内存位图，先落成文件才能进素材库 / 参考区
        if let img = NSImage(pasteboard: pb),
           let url = AgentAttachmentIO.savePastedImage(img) {
            onDropFiles?([url])
            return
        }
        super.paste(sender)
    }

    /// × 上面用箭头，别用文本的 I 形 —— 那是「这儿能点」的信号。
    ///
    /// NSTextView 的 I 形光标走的是 `cursorUpdate`，光靠 cursor rects 压不住它，
    /// 两条都设上
    override func cursorUpdate(with event: NSEvent) {
        if setArrowIfOnClose(event) { return }
        super.cursorUpdate(with: event)
    }

    /// NSTextView 是在 mouseMoved 里把光标设成 I 形的 —— 在 × 上不调 super，
    /// 不然设完箭头马上又被它改回去
    override func mouseMoved(with event: NSEvent) {
        if setArrowIfOnClose(event) { return }
        super.mouseMoved(with: event)
    }

    /// 自己挂一块 tracking area 收 mouseMoved：光靠 NSTextView 内部那块，
    /// 子类不一定收得到
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = closeTracking { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                               owner: self)
        addTrackingArea(a)
        closeTracking = a
    }

    private func setArrowIfOnClose(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        guard let lm = layoutManager as? ChipLayoutManager,
              lm.chipCloseRange(at: p) != nil else { return false }
        NSCursor.arrow.set()
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager as? ChipLayoutManager else { return }
        for item in lm.closeRects.values {
            addCursorRect(item.rect, cursor: .arrow)
        }
    }

    /// 点标签右边那颗 × ：删掉整段命令（连同后面的空格），回到没选模型的状态
    override func mouseDown(with event: NSEvent) {
        if let lm = layoutManager as? ChipLayoutManager, let storage = textStorage {
            // closeRects 存的就是视图坐标：画的时候那个 origin 参数
            // 本身已经是 textContainerOrigin，不用再减 inset
            let p = convert(event.locationInWindow, from: nil)
            if let r = lm.chipCloseRange(at: p) {
                // range 是**名字**那段，前面还有一个斜杠，后面常跟一个空格
                var full = NSRange(location: max(0, r.location - 1), length: r.length + 1)
                let ns = storage.string as NSString
                if NSMaxRange(full) < ns.length,
                   ns.substring(with: NSRange(location: NSMaxRange(full), length: 1)) == " " {
                    full.length += 1
                }
                storage.replaceCharacters(in: full, with: "")
                didChangeText()
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// 回车发送，⌘+回车换行。
    /// 候选列表开着的时候这几个键归列表用：回车是「选中这条」，不是发送
    override func keyDown(with event: NSEvent) {
        if slashOpen {
            switch event.keyCode {
            case 126: onSlashKey?(.up); return
            case 125: onSlashKey?(.down); return
            case 36, 48: onSlashKey?(.confirm); return   // 回车 / Tab
            case 53: onSlashKey?(.cancel); return        // Esc
            default: break
            }
        }
        // 36 是主键盘回车，76 是小键盘那颗 —— 两个都得认
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }
}


/// 参考内容的空槽位。默认是图标 + 文字，**hover 才浮出两个入口** ——
/// 跟画布空卡片上那两颗按钮一个交互。
///
/// 单独一个 struct 是为了各存各的 hover：方法产出的视图没法持 @State，
/// 而共用一份状态时 onHover 在相邻槽位之间快速划过会漏掉 exit
private struct RefPlaceholderSlot: View {
    let label: String
    let icon: String
    let onUpload: () -> Void
    let onLibrary: () -> Void
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(hovering ? 0.10 : 0.06))
            .frame(width: 48, height: 48)
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(Color.labelSecondary.opacity(0.45))
                    Text(label)
                        .font(.system(size: 8))
                        .foregroundColor(Color.labelSecondary.opacity(0.4))
                        .lineLimit(1)
                }
                .opacity(hovering ? 0 : 1)
            }
            .overlay {
                if hovering {
                    HStack(spacing: 5) {
                        button(icon: "importFile", tip: "从本地上传", action: onUpload)
                        button(icon: "folder", tip: "从素材库选择", action: onLibrary)
                    }
                }
            }
            .onHover { hovering = $0 }
    }

    private func button(icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: SidebarSVGIcon.load(icon, size: 11))
                .renderingMode(.template)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 自绘按钮上 .help 时灵时不灵，走 ChatTooltip
        .overlay { ChatTooltip(text: tip) }
    }
}

/// ＋ 菜单里的一行。单独一个 struct 是为了各存各的 hover

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

// MARK: - 历史列表的状态圆点

enum HistoryDotState { case idle, running, done, failed }

/// 历史会话每行标题前的圆点。**不区分画布和普通会话**，只表示状态：
/// 正在生成时呼吸，画布还带上次生成的结果 —— 绿=有产物，红=有节点失败了
struct HistoryStatusDot: View {
    let state: HistoryDotState
    @State private var dim = false

    private var color: Color {
        switch state {
        case .done:   return .green
        case .failed: return .red
        case .idle, .running: return Color.labelSecondary
        }
    }

    var body: some View {
        Circle().strokeBorder(color, lineWidth: 1.2)
            .frame(width: 7, height: 7)
        .opacity(dim ? 0.25 : 1)
        .animation(state == .running
                   ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                   : .linear(duration: 0.15),
                   value: dim)
        .onAppear { dim = (state == .running) }
        .onChange(of: state) { _, s in dim = (s == .running) }
    }
}

/// Agent 回复里的表格。
///
/// 画不进 NSTextView，所以单独拿出来用 Grid 画：表头带底色、行间细分隔线、
/// 整体圆角描边。列宽由内容自己撑，长文本在格子里换行
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { c in
                    cell(c < header.count ? header[c] : "", bold: true)
                }
            }
            .background(Color.white.opacity(0.07))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().opacity(0.25)
                    .gridCellColumns(columnCount)
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(c < row.count ? row[c] : "")
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }

    private func cell(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: bold ? .semibold : .regular))
            .foregroundColor(Color.white.opacity(bold ? 0.9 : 0.72))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
    }
}
