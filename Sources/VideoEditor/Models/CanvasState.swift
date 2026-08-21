import SwiftUI

/// AI 画布的视图状态（v5.1.0，B2 阶段先只有导航）
///
/// 节点和连线在 B3 加，生成在 B4 接。这里先把「画布怎么看」这件事定下来：
/// 缩放倍率、平移偏移，以及一个只管画布自己的撤销栈 —— 不跟时间轴那套混，
/// 在画布里按 ⌘Z 撤的应该是刚加的节点，不是时间轴上的操作
final class CanvasState: ObservableObject {

    /// 缩放倍率。上下限按小云雀那类画布的手感定，太小看不清、太大没意义
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 4.0

    @Published var zoom: CGFloat = 1.0
    @Published var offset: CGSize = .zero

    /// 画布顶部露出底层界面的高度。默认 0 = 整个盖住，
    /// 用户可以拖顶部那个手柄把画布往下收，露出底下的预览和时间轴
    @Published var topGap: CGFloat = 0
    /// 画布本身至少留这么高，再拖就没意义了
    static let minCanvasHeight: CGFloat = 100

    /// 有几个控件认领了光标（节点边缘的调整热区之类）。
    /// 画布自己在 onContinuousHover 里每次鼠标移动都会 set 一次光标，
    /// 不让路的话热区刚设成双向箭头就被它改回箭头 —— 表现就是光标疯狂闪。
    /// 用计数不用布尔：多个热区进出的回调顺序不保证，布尔会被互相冲掉
    private var cursorClaims = 0
    var cursorClaimedByChild: Bool { cursorClaims > 0 }

    func claimCursor(_ claimed: Bool) {
        cursorClaims = claimed ? cursorClaims + 1 : max(0, cursorClaims - 1)
    }

    /// 空格按住时进入拖拽模式（跟 Figma/PS 一个手感）
    @Published var isSpaceHeld = false
    /// 正在用空格拖画布
    @Published var isPanning = false

    // MARK: - 节点与连线

    @Published var nodes: [CanvasNode] = []
    @Published var edges: [CanvasEdge] = []
    /// 选中的卡片。框选、⌘点、成组都会一次选中好几张
    @Published var selectedNodeIDs: Set<UUID> = []

    /// 单选的那张。多选时是 nil —— 操作栏这类「只对一张卡片」的东西据此自动让位。
    /// 老代码里 `selectedNodeID = x` 的写法照旧能用，写进去就是把选中集换成这一张
    var selectedNodeID: UUID? {
        get { selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil }
        set { selectedNodeIDs = newValue.map { [$0] } ?? [] }
    }

    /// 分组。卡片身上记 groupID，这里存组自己的信息（名字）
    @Published var groups: [CanvasGroup] = []
    /// 选中的组 —— 点组的浅色底选中它，边框变黄，可以整组拖动。
    /// 跟卡片选中互斥：点卡片就取消选组，反过来也一样
    @Published var selectedGroupID: UUID?

    /// 复制/剪切下来的一批卡片。跟时间轴那份剪贴板各管各的
    @Published var clipboard = Clipboard()

    struct Clipboard {
        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []
        var isEmpty: Bool { nodes.isEmpty }
    }

    /// 正在从某个节点拉线（记住起点和当前落点，画那条跟手的线）
    @Published var pendingEdgeFrom: UUID?
    @Published var pendingEdgeTo: CGPoint?

    /// 拉线时鼠标悬着的那个节点 —— 松手就连它。节点据此高亮
    @Published var hoveredDropTarget: UUID?

    /// 正在拖的那批卡片和它们的临时位移。拖动只改这个、不改 model（改了整层会重建），
    /// 但连线得知道卡片现在实际画在哪，否则拖动时线还钉在原位。
    /// 用集合是因为拖组里任意一张，整组都得跟着走
    @Published var draggingNodeIDs: Set<UUID> = []
    @Published var draggingOffset: CGSize = .zero

    /// 节点当前**画在哪** —— 拖动中的那批要算上临时位移
    func displayFrame(of node: CanvasNode) -> CGRect {
        guard draggingNodeIDs.contains(node.id) else { return node.frame }
        return node.frame.offsetBy(dx: draggingOffset.width, dy: draggingOffset.height)
    }

    /// 这张画布对应的会话 id。一张画布 = AI 历史里的一条记录
    @Published var conversationID: UUID?
    /// 画布标题，历史列表里显示
    @Published var title: String = "未命名画布"

    /// 这张画布产出过的素材（AI 生成的 + 操作栏处理出来的）。
    /// 节点删了产物还在，所以单独记一份 —— 左侧栏的「资产库」列的就是它
    @Published var producedAssets: [ProducedAsset] = []

    struct ProducedAsset: Identifiable, Codable, Equatable {
        var id = UUID()
        var path: String
        var kind: CanvasNode.Kind
        var createdAt: Date = Date()
        var url: URL { URL(fileURLWithPath: path) }
    }

    /// 给新卡片起名：同类型顺着数下去，「图片 1」「图片 2」……
    /// 卡片自己不显示文件名，靠这个名字认人
    func nextName(for kind: CanvasNode.Kind) -> String {
        let n = nodes.filter { $0.kind == kind }.count + 1
        return "\(kind.label) \(n)"
    }

    func recordProducedAsset(url: URL, kind: CanvasNode.Kind) {
        guard !producedAssets.contains(where: { $0.path == url.path }) else { return }
        producedAssets.insert(ProducedAsset(path: url.path, kind: kind), at: 0)
    }

    /// 正在拉的这条线是从卡片哪一侧的 + 出来的。
    /// 左侧 = 「给我加上下文」，方向是 目标→源；右侧才是 源→目标。
    /// 不记这个的话，从文字卡片左边拉到图片会连成「文字参考图片」—— 反了
    @Published var pendingEdgeIsLeading = false

    /// 侧栏「添加」的 hover 状态。放画布上是因为菜单不画在侧栏内部 ——
    /// 挂在侧栏 overlay 里的话，菜单 offset 出去了、hit 区域还压在侧栏上，
    /// 会把下面两个按钮的鼠标事件也吃掉
    @Published var sideAddHovering = false
    @Published var sideMenuHovering = false

    var sideMenuVisible: Bool { sideAddHovering || sideMenuHovering }

    /// 添加菜单是从哪个节点、哪一侧的 + 弹出来的。
    ///
    /// 放在画布上而不是视图本地 —— 节点得知道「菜单是我弹的」，
    /// 好在鼠标移到菜单上、自己 hover 掉了之后仍然把那个 + 显示着。
    /// 记 side 是因为**只该留点的那一侧**，两个都留就分不清菜单是哪边弹的了
    @Published var plusMenuSource: PlusMenuSource?

    struct PlusMenuSource: Equatable {
        let nodeID: UUID
        let isTrailing: Bool
    }

    /// 哪个节点正在裁剪。裁剪框画在卡片上，拖动过程的矩形是**节点视图的本地状态** ——
    /// 每帧写 @Published 会让整层重建（拖节点、改尺寸那两次都栽在这上面）
    @Published var croppingNodeID: UUID?

    /// 哪个文本节点正在编辑。放在画布上而不是节点视图的本地 @State：
    /// 点画布空白要退出编辑，本地状态收不到这个信号
    @Published var editingTextNodeID: UUID?

    /// 连线被拒时的提示，比如「图片不能参考音频」
    @Published var rejectMessage: String?

    /// 节点 → 在跑的任务 id，取消时用
    private var runningTaskIDs: [UUID: UUID] = [:]

    // MARK: - 撤销/重做

    /// 画布自己的撤销栈，跟时间轴那套完全分开 ——
    /// 在画布里按 ⌘Z 撤的该是刚加的节点，不是时间轴上的操作
    private struct Snapshot: Equatable {
        var nodes: [CanvasNode]
        var edges: [CanvasEdge]
    }

    private var undoStack: [Snapshot] = []

    /// 换画布时清掉撤销历史 —— 在新画布上撤销回上一张画布的内容毫无意义
    private var redoStack: [Snapshot] = []
    private static let maxUndo = 50

    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0

    var canUndo: Bool { undoCount > 0 }
    var canRedo: Bool { redoCount > 0 }

    /// 改动前先压一份。所有会改 nodes/edges 的操作都要先调它
    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        undoCount = 0
        redoCount = 0
    }

    func pushUndo() {
        undoStack.append(Snapshot(nodes: nodes, edges: edges))
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoCounts()
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(Snapshot(nodes: nodes, edges: edges))
        apply(snap)
        syncUndoCounts()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(Snapshot(nodes: nodes, edges: edges))
        apply(snap)
        syncUndoCounts()
    }

    private func apply(_ snap: Snapshot) {
        nodes = snap.nodes
        edges = snap.edges
        // 选中的节点可能已经不在了
        let alive = Set(nodes.map(\.id))
        selectedNodeIDs.formIntersection(alive)
    }

    private func syncUndoCounts() {
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    // MARK: - 节点操作

    @discardableResult
    func addNode(kind: CanvasNode.Kind, at position: CGPoint, ratio: String = "1:1") -> CanvasNode {
        pushUndo()
        var node = CanvasNode(kind: kind, position: position, size: kind.defaultSize(ratio: ratio))
        node.ratio = ratio
        node.displayName = nextName(for: kind)
        nodes.append(node)
        selectedNodeID = node.id
        return node
    }

    /// 改比例：卡片跟着变形，中心保持不动（不然改一次比例卡片就往右下跑）
    func setRatio(_ ratio: String, for nodeID: UUID) {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let old = nodes[i].size
        let new = nodes[i].kind.defaultSize(ratio: ratio)
        nodes[i].ratio = ratio
        nodes[i].size = new
        nodes[i].position = CGPoint(x: nodes[i].position.x + (old.width - new.width) / 2,
                                    y: nodes[i].position.y + (old.height - new.height) / 2)
    }

    func removeNode(id: UUID) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        pushUndo()
        nodes.removeAll { $0.id == id }
        // 连着的线一起收掉，否则会留下指向空节点的悬空连线
        edges.removeAll { $0.from == id || $0.to == id }
        selectedNodeIDs.remove(id)
    }

    func moveNode(id: UUID, to position: CGPoint) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].position = position
    }

    func updateNode(id: UUID, _ modify: (inout CanvasNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        modify(&nodes[i])
    }

    func node(_ id: UUID) -> CanvasNode? { nodes.first { $0.id == id } }

    // MARK: - 连线操作

    /// 连一条线。类型不合就返回拒绝原因，界面上弹提示
    @discardableResult
    func connect(from: UUID, to: UUID, provider: AIVideoService.Provider) -> CanvasConnectionRule.Result {
        guard from != to else { return .rejected("不能连到自己") }
        guard let f = node(from), let t = node(to) else { return .rejected("节点不存在") }

        if edges.contains(where: { $0.from == from && $0.to == to }) {
            return .rejected("已经连过了")
        }
        // 先查类型再查环：两条都不满足时，「文本节点不能参考图片」比
        // 「不能连成环」更能告诉用户为什么连不上
        let rule = CanvasConnectionRule.check(from: f.kind, to: t.kind, provider: provider)
        guard rule.isAllowed else { return rule }

        // 挡住成环：A→B 之后再 B→A，生成时会互相等对方，永远开不了工
        if wouldFormCycle(from: from, to: to) {
            return .rejected("不能连成环")
        }

        pushUndo()
        edges.append(CanvasEdge(from: from, to: to))
        return .allowed
    }

    func removeEdge(id: UUID) {
        guard edges.contains(where: { $0.id == id }) else { return }
        pushUndo()
        edges.removeAll { $0.id == id }
    }

    /// 某个节点的上游（按连线先后排序，就是参考素材的顺序）
    func upstreamNodes(of id: UUID) -> [CanvasNode] {
        edges.filter { $0.to == id }.compactMap { node($0.from) }
    }

    // MARK: - 生成调度

    /// 提交一个节点去生成。
    ///
    /// 连线的语义是「上游 = 下游的参考素材」，所以**上游没出结果之前下游不能开工**。
    /// 有这种上游就先挂 `isWaiting`，等上游完成再由 `resumeWaitingNodes()` 拉起来；
    /// 没有依赖的直接发 —— 并发数不设限，用户点几个就同时跑几个。
    func submitGeneration(nodeID: UUID, provider: AIVideoService.Provider,
                          settings: AppSettings = .shared) {
        guard let node = self.node(nodeID) else { return }

        updateNode(id: nodeID) {
            $0.failure = nil
            $0.isWaiting = false
            $0.isGenerating = false
        }

        // 上游里还有没出结果的，就先排队
        if upstreamNodes(of: nodeID).contains(where: { $0.isGenerating || $0.isWaiting }) {
            updateNode(id: nodeID) { $0.isWaiting = true }
            return
        }
        startGeneration(nodeID: nodeID, provider: provider, settings: settings)
    }

    /// 真正开工。参考素材按**连线先后**排序，这就是参考的顺序
    private func startGeneration(nodeID: UUID, provider: AIVideoService.Provider,
                                 settings: AppSettings) {
        guard let node = self.node(nodeID) else { return }
        if node.kind == .text {
            startTextGeneration(nodeID: nodeID, provider: provider)
            return
        }

        var promptParts: [String] = []
        var images: [URL] = [], videos: [URL] = [], audios: [URL] = []

        for up in upstreamNodes(of: nodeID) {
            switch up.kind {
            case .text:
                let t = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { promptParts.append(t) }
            case .image: if let u = up.mediaURL { images.append(u) }
            case .video: if let u = up.mediaURL { videos.append(u) }
            case .audio: if let u = up.mediaURL { audios.append(u) }
            }
        }
        let own = node.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { promptParts.append(own) }

        let prompt = promptParts.joined(separator: "\n")
        guard !prompt.isEmpty || !images.isEmpty else {
            updateNode(id: nodeID) { $0.failure = "先写点提示词" }
            return
        }

        updateNode(id: nodeID) { $0.isGenerating = true; $0.isWaiting = false }

        let taskID = AIVideoService.shared.generateForCanvas(
            prompt: prompt,
            provider: provider,
            duration: settings.aiDuration,
            aspectRatio: settings.aiRatio,
            resolution: settings.aiResolution,
            imageRatio: settings.aiImageRatio,
            referenceImages: images,
            referenceVideos: videos,
            referenceAudios: audios) { [weak self] result in
                guard let self else { return }
                self.updateNode(id: nodeID) {
                    $0.isGenerating = false
                    switch result {
                    case .success(let url):
                        $0.mediaPath = url.path
                        $0.failure = nil
                    case .failure(let error):
                        $0.failure = (error is CancellationError) ? "已取消" : error.localizedDescription
                    }
                }
                if case .success(let url) = result,
                   let kind = self.node(nodeID)?.kind {
                    self.recordProducedAsset(url: url, kind: kind)
                }
                self.runningTaskIDs.removeValue(forKey: nodeID)
                // 等着这个节点的下游可以开工了
                self.resumeWaitingNodes(provider: provider, settings: settings)
            }
        runningTaskIDs[nodeID] = taskID
    }

    /// 文本节点的生成：出的是文字，直接填回节点自己的正文
    private func startTextGeneration(nodeID: UUID, provider: AIVideoService.Provider) {
        guard let node = self.node(nodeID) else { return }
        var parts: [String] = []
        for up in upstreamNodes(of: nodeID) where up.kind == .text {
            let t = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
        }
        let own = node.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { parts.append(own) }
        let prompt = parts.joined(separator: "\n")
        guard !prompt.isEmpty else {
            updateNode(id: nodeID) { $0.failure = "先写点提示词" }
            return
        }

        updateNode(id: nodeID) { $0.isGenerating = true; $0.isWaiting = false }
        let taskID = AIVideoService.shared.generateTextForCanvas(prompt: prompt, provider: provider) { [weak self] result in
            guard let self else { return }
            self.updateNode(id: nodeID) {
                $0.isGenerating = false
                switch result {
                case .success(let text): $0.text = text; $0.failure = nil
                case .failure(let error):
                    $0.failure = (error is CancellationError) ? "已取消" : error.localizedDescription
                }
            }
            self.runningTaskIDs.removeValue(forKey: nodeID)
            self.resumeWaitingNodes(provider: provider, settings: .shared)
        }
        runningTaskIDs[nodeID] = taskID
    }

    /// 上游完成后，把等着它的下游拉起来
    private func resumeWaitingNodes(provider: AIVideoService.Provider, settings: AppSettings) {
        for node in nodes where node.isWaiting {
            let ups = upstreamNodes(of: node.id)
            // 上游全出结果了才开工；有失败的就跟着失败，别拿空参考去生成
            if ups.contains(where: { $0.isGenerating || $0.isWaiting }) { continue }
            if ups.contains(where: { $0.failure != nil }) {
                updateNode(id: node.id) { $0.isWaiting = false; $0.failure = "上游没生成成功" }
                continue
            }
            startGeneration(nodeID: node.id, provider: provider, settings: settings)
        }
    }

    /// 取消某个节点的生成
    func cancelGeneration(nodeID: UUID) {
        if let taskID = runningTaskIDs[nodeID] {
            AIVideoService.shared.cancel(taskID: taskID)
            runningTaskIDs.removeValue(forKey: nodeID)
        }
        updateNode(id: nodeID) { $0.isGenerating = false; $0.isWaiting = false }
    }

    /// 从 to 出发能不能走回 from —— 能的话这条新线就成环了
    private func wouldFormCycle(from: UUID, to: UUID) -> Bool {
        var visited: Set<UUID> = []
        var stack = [to]
        while let current = stack.popLast() {
            if current == from { return true }
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: edges.filter { $0.from == current }.map(\.to))
        }
        return false
    }

    // MARK: - 缩放

    /// 以画布中的某个锚点为中心缩放。锚点是视图坐标（相对画布容器左上角），
    /// 不带锚点就是以容器中心缩放（点右上角 +/- 时用）
    func setZoom(_ newValue: CGFloat, anchor: CGPoint? = nil, containerSize: CGSize = .zero) {
        let clamped = min(Self.maxZoom, max(Self.minZoom, newValue))
        guard clamped != zoom else { return }

        guard let anchor, containerSize != .zero else {
            zoom = clamped
            return
        }

        // 锚点在内容坐标里的位置缩放前后要保持不动，否则鼠标底下的东西会跑。
        //
        // 坐标约定：内容层用 `.position()` 摆节点，原点在容器**左上角**；
        // `.scaleEffect` 的锚点是容器**中心**。两者原点不同，换算必须带上 center，
        // 少一项就会「双击加的卡片落在别处、连线末端不跟手」
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let anchorInContent = CGPoint(
            x: (anchor.x - offset.width - center.x) / zoom + center.x,
            y: (anchor.y - offset.height - center.y) / zoom + center.y)

        zoom = clamped
        offset = CGSize(
            width: anchor.x - center.x - (anchorInContent.x - center.x) * clamped,
            height: anchor.y - center.y - (anchorInContent.y - center.y) * clamped)
    }

    /// 右上角的 + / −：按固定比例走，落在整十档上好读
    func zoomIn(containerSize: CGSize = .zero) {
        setZoom(niceStep(from: zoom, up: true), anchor: nil, containerSize: containerSize)
    }

    func zoomOut(containerSize: CGSize = .zero) {
        setZoom(niceStep(from: zoom, up: false), anchor: nil, containerSize: containerSize)
    }

    /// 回到 100% 并居中
    func resetView() {
        zoom = 1.0
        offset = .zero
    }

    /// 下一档缩放值。用固定档位而不是乘系数，是为了让百分比读数干净
    private func niceStep(from current: CGFloat, up: Bool) -> CGFloat {
        let stops: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
        if up {
            return stops.first { $0 > current + 0.001 } ?? Self.maxZoom
        } else {
            return stops.last { $0 < current - 0.001 } ?? Self.minZoom
        }
    }

    /// 显示用的百分比
    var zoomPercent: Int { Int((zoom * 100).rounded()) }
}


// MARK: - 存档

extension CanvasState {

    /// 打包成会话里存的那份
    func snapshot() -> AIVideoService.ConversationRecord.CanvasSnapshot {
        AIVideoService.ConversationRecord.CanvasSnapshot(
            nodes: nodes, edges: edges, groups: groups, producedAssets: producedAssets,
            zoom: zoom, offsetX: offset.width, offsetY: offset.height)
    }

    /// 从存档还原。撤销栈不还原 —— 上次的撤销历史跨会话没有意义
    func restore(from snap: AIVideoService.ConversationRecord.CanvasSnapshot,
                 conversationID: UUID, title: String) {
        nodes = snap.nodes
        edges = snap.edges
        groups = snap.groups
        producedAssets = snap.producedAssets
        zoom = snap.zoom
        offset = CGSize(width: snap.offsetX, height: snap.offsetY)
        self.conversationID = conversationID
        self.title = title
        selectedNodeIDs = []
        selectedGroupID = nil
        editingTextNodeID = nil
        clearUndoHistory()
    }

    /// 开一张新画布
    func reset(conversationID: UUID) {
        nodes = []
        edges = []
        groups = []
        producedAssets = []
        zoom = 1
        offset = .zero
        topGap = 0
        selectedNodeIDs = []
        selectedGroupID = nil
        editingTextNodeID = nil
        self.conversationID = conversationID
        title = "未命名画布"
        clearUndoHistory()
    }
}
