import SwiftUI

/// AI 画布的视图状态（v5.1.0，B2 阶段先只有导航）
///
/// 节点和连线在 B3 加，生成在 B4 接。这里先把「画布怎么看」这件事定下来：
/// 缩放倍率、平移偏移，以及一个只管画布自己的撤销栈 —— 不跟时间轴那套混，
/// 在画布里按 ⌘Z 撤的应该是刚加的节点，不是时间轴上的操作
final class CanvasState: ObservableObject {

    /// 监听素材库的删除/恢复广播。
    ///
    /// **必须广播、不能由 `ProjectState` 直接调自己那个 canvas** —— 素材库是全 app
    /// 一份，画布却是**每个窗口一份**。在 A 窗口删素材只动 A 的画布，卡片在 B 窗口
    /// 的画布上就完全不受影响（实测日志：「命中卡片 0 张（画布共 0 张）」，
    /// 因为那个窗口的画布本来就是空的）。
    /// 注册在 init 里，画布开没开都收得到
    private var libraryObservers: [Any] = []

    /// 所有活着的画布，每个窗口一份（弱引用，窗口关了自动掉）。
    /// 删素材的确认框要报「**一共**多少张卡片会被删」，只数自己那份会报少
    private static let allCanvases = NSHashTable<CanvasState>.weakObjects()

    /// 全部窗口的画布上，一共有几张卡片在用这个素材
    static func totalNodeCount(usingAsset id: UUID, path: String?) -> Int {
        allCanvases.allObjects.reduce(0) { $0 + $1.nodeCount(usingAsset: id, path: path) }
    }

    init() {
        Self.allCanvases.add(self)
        let center = NotificationCenter.default
        libraryObservers.append(center.addObserver(
            forName: .assetRemovedFromLibrary, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["assetID"] as? UUID else { return }
            self.removeNodes(usingAsset: id, path: note.userInfo?["path"] as? String)
            // 本窗口发起的那次删除，在画布栈里记一步「转给项目撤」——
            // 画布开着时 ⌘Z 只走画布的栈，不记的话素材永远撤不回来
            if let origin = note.userInfo?["origin"] as? UUID,
               origin == self.project?.instanceID {
                self.pushProjectAssetRemoval()
            }
        })
        libraryObservers.append(center.addObserver(
            forName: .assetRestoredToLibrary, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["assetID"] as? UUID else { return }
            self?.restoreNodesAfterUndo(assetID: id)
        })
        // 素材改名 / 重新关联：卡片的路径和显示名跟着走。
        //
        // **这条也必须在这里听，不能挂在视图上** —— 画布关着的时候在侧边栏
        // 改名或重新关联，卡片就停在旧路径上，跟素材彻底失联：
        // 之后删这个素材会「命中 0 张」（实测日志里就是这样），
        // 因为卡片的 mediaPath 是旧的、又没有 assetID，谁也认不出谁
        libraryObservers.append(center.addObserver(
            forName: .mediaFileRelocated, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let info = note.userInfo else { return }
            var changed = false
            if let old = info["old"] as? String, let new = info["new"] as? String, old != new {
                self.repointNodes(from: old, to: new)
                changed = true
            }
            if let aid = info["assetID"] as? UUID, let newName = info["newName"] as? String {
                self.renameNodeLabels(assetID: aid, to: newName)
                changed = true
            }
            if changed { self.persist() }
        })
    }

    deinit {
        libraryObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 缩放倍率。上下限按小云雀那类画布的手感定，太小看不清、太大没意义
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 4.0

    @Published var zoom: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    /// 画布可视区域大小。NSEvent 层的右键监听靠它把窗口坐标换算成内容坐标，
    /// 判断「这次右键是不是点在正在编辑的文本卡片上」
    @Published var containerSize: CGSize = .zero

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

    /// 所在窗口的项目状态。
    ///
    /// 素材库合并之后（v5.3.0），画布产物要直接进全局素材库，模型层这边也得能调
    /// `importFile`。**弱引用**：`ProjectState` 是窗口的 `@StateObject`，
    /// 强持有会让窗口关不掉。挂载点在 `CanvasOverlay.onAppear`
    weak var project: ProjectState?

    /// 这张画布对应的会话 id。一张画布 = AI 历史里的一条记录
    @Published var conversationID: UUID?

    /// 右下角那张聊天卡片占的地方（SwiftUI `.global` 坐标）。
    /// 滚轮监听靠它放行 —— 鼠标在卡片上时滚的是会话，不是整个画布。
    /// **不用 @Published**：拖动调卡片尺寸时每帧都在变，发布出去等于每帧重绘画布。
    /// 也不用 onHover 判断，那个在快速移动时会漏掉 exit，漏一次画布就再也滚不动
    var chatCardRect: CGRect = .zero

    /// 最近一次点击落在会话卡片里没有。
    ///
    /// ⌘V 这类键盘事件没有位置，只能靠它分流。**不能只看 firstResponder** ——
    /// 卡片里那个 NSTextView 会一直占着，点了画布空白也不放手
    /// （`makeFirstResponder(nil)` 常常当场被还回去）
    var chatCardFocused = false
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
        /// 用户在元素库里改的名字。nil = 就用文件名。
        ///
        /// **只改这个显示名，不动磁盘文件**：产物文件是节点靠 `mediaPath` 找的，
        /// 改文件名就得同步改所有引用它的节点，撤销时还得把文件名改回去 ——
        /// 素材库那套 `renameAsset` 为此配了 `reconcileAssetFiles`，
        /// 这里没有对应机制，改文件名一旦和撤销撞上就是素材丢失
        var displayName: String?
        var url: URL { URL(fileURLWithPath: path) }
        /// 列表里显示的名字
        var name: String { displayName ?? url.lastPathComponent }
    }

    /// 给新卡片起名：同类型顺着数下去，「图片 1」「图片 2」……
    /// 卡片自己不显示文件名，靠这个名字认人
    func nextName(for kind: CanvasNode.Kind) -> String {
        let n = nodes.filter { $0.kind == kind }.count + 1
        return "\(kind.label) \(n)"
    }

    /// 打开老画布时把元素库并进全局素材库（v5.3.0 起元素库取消）。
    ///
    /// 老存档里的 `producedAssets` 是当年那套「产物只登记画布、不进素材库」留下的。
    /// 现在两边合并成一个素材库，这些产物要补进去，卡片也补上 `assetID` ——
    /// 补完它们才能享受改名/删除/重新关联的联动。文件已经不在的跳过。
    /// 并完清空清单，下次存档就不带了
    func migrateProducedAssetsIntoLibrary(_ project: ProjectState) {
        guard !producedAssets.isEmpty else { return }
        for item in producedAssets where FileManager.default.fileExists(atPath: item.path) {
            if project.mediaAssets.first(where: { $0.url.path == item.path }) == nil {
                project.importFile(item.url)
            }
            guard let asset = project.mediaAssets.first(where: { $0.url.path == item.path }) else { continue }
            for j in nodes.indices where nodes[j].mediaPath == item.path && nodes[j].assetID == nil {
                nodes[j].assetID = asset.id
            }
        }
        producedAssets = []
    }

    // MARK: - 跟素材库联动（删除 / 撤销 / 改名）

    /// 因为素材库删除而删掉的卡片备份，撤销时原样插回来。
    ///
    /// **不走画布自己的撤销栈**。走栈的话这一步会变成画布历史里的独立一步：
    /// 画布开着时 ⌘Z 先撤画布（卡片回来）、再撤项目（素材和片段回来），
    /// 两边各撤一半，撤哪个还取决于焦点在哪 —— 实测日志里就是
    /// 「素材恢复了，但画布撤销栈顶已不是当初那步」。
    /// 存一份备份、由项目那次撤销直接插回来，一次 ⌘Z 三样齐
    private var removedByAssetDeletion: [(assetID: UUID,
                                          nodes: [CanvasNode],
                                          edges: [CanvasEdge])] = []

    /// 这张卡片算不算在用这个素材。
    ///
    /// **不能只认 assetID**：中间几个版本产出的卡片没有 assetID
    /// （那时画布产物不进素材库），只有 `mediaPath`。只按 id 匹配的话
    /// 删素材时一张卡片都匹配不到 —— 表现就是「片段没了、卡片还在」。
    /// 没有 id 的按文件路径认
    private func node(_ n: CanvasNode, uses id: UUID, path: String?) -> Bool {
        if let aid = n.assetID { return aid == id }
        guard let path, let mine = n.mediaPath else { return false }
        return mine == path
    }

    /// 画布上有几张卡片在用这个素材。删素材前的确认框要报这个数 ——
    /// **判据必须跟 `removeNodes` 一致**，否则报的数跟实际删掉的对不上
    func nodeCount(usingAsset id: UUID, path: String? = nil) -> Int {
        nodes.filter { node($0, uses: id, path: path) }.count
    }

    /// 素材被移出素材库：引用它的卡片一并删掉（跟时间轴片段一个待遇），
    /// 删掉的卡片和它们的连线存一份备份，等项目那次撤销把它们插回来
    func removeNodes(usingAsset id: UUID, path: String? = nil) {
        let victims = nodes.filter { node($0, uses: id, path: path) }
        DiagLog.log("[画布] 素材移除 → 命中卡片 \(victims.count) 张"
                    + "（画布共 \(nodes.count) 张，path=\(path ?? "nil")）")
        guard !victims.isEmpty else { return }
        let ids = Set(victims.map(\.id))
        let deadEdges = edges.filter { ids.contains($0.from) || ids.contains($0.to) }
        removedByAssetDeletion.append((assetID: id, nodes: victims, edges: deadEdges))
        nodes.removeAll { ids.contains($0.id) }
        edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        selectedNodeIDs.subtract(ids)
        persist()
    }

    /// 素材被撤销恢复了：把当初跟着删掉的卡片原样插回来 ——
    /// 一次 ⌘Z 素材、片段、卡片一起回来。
    /// 已经在画布上的不重复插（用户可能自己手动撤过）
    func restoreNodesAfterUndo(assetID: UUID) {
        guard let i = removedByAssetDeletion.lastIndex(where: { $0.assetID == assetID }) else { return }
        let backup = removedByAssetDeletion.remove(at: i)
        let haveNodes = Set(nodes.map(\.id))
        nodes.append(contentsOf: backup.nodes.filter { !haveNodes.contains($0.id) })
        let haveEdges = Set(edges.map(\.id))
        edges.append(contentsOf: backup.edges.filter { !haveEdges.contains($0.id) })
        DiagLog.log("[画布] 素材撤销恢复 → 插回卡片 \(backup.nodes.count) 张")
        persist()
    }

    /// 把画布存回它那条会话记录。
    ///
    /// **不能只靠视图层那个防抖保存** —— 那个挂在 `CanvasOverlay` 上，
    /// 画布关着的时候（比如在侧边栏删素材）视图根本不在树里，没人触发保存。
    /// 结果是卡片当场删了、存档里还留着，下次打开画布从存档恢复，卡片又回来
    /// （实测：日志明明写着「命中卡片 1 张」，用户看到的却是卡片还在）
    func persist() {
        guard let id = conversationID else { return }
        AIVideoService.shared.saveCanvas(snapshot(), id: id, title: derivedTitle)
    }

    /// 画布标题：取第一个有内容的节点。全空就留「未命名画布」——
    /// 历史列表里一排「未命名」认不出谁是谁
    var derivedTitle: String {
        nodes.compactMap { n -> String? in
            if n.kind == .text {
                let t = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : String(t.prefix(20))
            }
            let p = n.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { return String(p.prefix(20)) }
            return n.mediaURL?.lastPathComponent
        }.first ?? "未命名画布"
    }

    /// 打开画布时跟素材库对一次账：有 assetID 的卡片，**名字和文件路径**都取素材当前的值。
    ///
    /// **光靠通知不够** —— `MediaRelocationSync` 挂在 `CanvasOverlay` 上，
    /// 画布没打开时视图不在树里，通知没人接。在**侧边栏**改名或重新关联过的，
    /// 卡片就停在改动前的状态。
    ///
    /// **路径必须一起对**：改名会连磁盘文件一起改，只同步名字不同步路径的话，
    /// 卡片名字是新的、`mediaPath` 还指着已经不存在的旧文件 ——
    /// 表现就是「名字改好了，卡片却显示素材丢失」。
    /// 路径走 `repointNodes` 换，撤销栈里的旧路径一并换掉，撤销回去也不会又丢
    func syncNodesFromLibrary(_ project: ProjectState) {
        var changed = false
        for j in nodes.indices {
            // 老卡片可能没有 assetID（产物不进素材库那几个版本留下的）：
            // 按文件路径去素材库认领一次，认上了才能享受改名/删除/关联的联动
            if nodes[j].assetID == nil, let path = nodes[j].mediaPath {
                if let owner = project.mediaAssets.first(where: { $0.url.path == path }) {
                    nodes[j].assetID = owner.id
                    changed = true
                } else if !FileManager.default.fileExists(atPath: path) {
                    // 路径对不上、文件也不在了 —— 素材很可能是在画布关着的时候
                    // 被挪过位置或改过名，卡片停在旧路径上跟素材彻底失联了。
                    // **按文件名兜一次**：卡片反正已经指着一个不存在的文件，
                    // 认错的代价小于一直失联（文件还在的卡片不动，避免同名误配）
                    let name = (path as NSString).lastPathComponent
                    if let owner = project.mediaAssets.first(where: { $0.url.lastPathComponent == name }) {
                        nodes[j].assetID = owner.id
                        nodes[j].mediaPath = owner.url.path
                        changed = true
                        DiagLog.log("[画布] 卡片按文件名认回素材 \(name)")
                    }
                }
            }
            guard let aid = nodes[j].assetID,
                  let asset = project.mediaAssets.first(where: { $0.id == aid }) else { continue }
            if nodes[j].displayName != asset.name {
                nodes[j].displayName = asset.name
                changed = true
            }
            if let old = nodes[j].mediaPath, old != asset.url.path {
                repointNodes(from: old, to: asset.url.path)
                changed = true
            }
        }
        // 对账动过东西就落盘，否则下次打开又从存档读回错的
        if changed { persist() }
    }

    /// 素材改名后，画布上引用它的卡片显示名一起改。
    ///
    /// **按 `assetID` 认卡片，不能按名字匹配** —— 产物卡片的显示名是
    /// `nextName(for:)` 给的「图片 1」「视频 2」这种自动编号，跟文件名对不上，
    /// 按名字匹配一条都改不到（这就是「素材库改名卡片没跟着变」的原因）
    func renameNodeLabels(assetID: UUID, to newName: String) {
        for j in nodes.indices where nodes[j].assetID == assetID {
            nodes[j].displayName = newName
        }
    }

    /// 没有 assetID 的卡片（镜像/旋转那类）按文件路径认
    func renameNodeLabels(path: String, to newName: String) {
        for j in nodes.indices where nodes[j].mediaPath == path {
            nodes[j].displayName = newName
        }
    }

    /// 把所有指向 `oldPath` 的引用改到 `newPath` —— 当前画布 + 撤销/重做栈
    func repointNodes(from oldPath: String, to newPath: String) {
        for j in nodes.indices where nodes[j].mediaPath == oldPath {
            nodes[j].mediaPath = newPath
        }
        repointStack(&undoStack, from: oldPath, to: newPath)
        repointStack(&redoStack, from: oldPath, to: newPath)
    }

    /// 撤销栈里的历史快照也要跟着换路径，否则撤销回去卡片又指着旧文件。
    /// 「转给项目撤」那种条目不含节点，跳过
    private func repointStack(_ stack: inout [UndoEntry], from oldPath: String, to newPath: String) {
        for s in stack.indices {
            guard case .canvas(var snap) = stack[s] else { continue }
            var touched = false
            for j in snap.nodes.indices where snap.nodes[j].mediaPath == oldPath {
                snap.nodes[j].mediaPath = newPath
                touched = true
            }
            if touched { stack[s] = .canvas(snap) }
        }
    }

    /// 缩略图 / 波形缓存的 key。
    ///
    /// 素材库里有就用素材 id（跟时间轴/素材库共用那份缓存，不重复抽帧）。
    /// 镜像/旋转的产物按约定不进素材库，没有 `assetID`，退回节点自己的 id ——
    /// 缓存是内存里的字典，用谁的 id 都行，只要前后一致
    func thumbKey(assetID: UUID?, path: String?, fallback: UUID) -> UUID {
        assetID ?? fallback
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

    /// 拖卡片时吸附到别的卡片的边和中线。跟着 AppSettings 走 —— 这是用户偏好，
    /// 换个画布、重开 app 都该记着
    var snapEnabled: Bool {
        get { AppSettings.shared.canvasSnapEnabled }
        set { AppSettings.shared.canvasSnapEnabled = newValue; objectWillChange.send() }
    }

    /// 显示连接线
    var edgesVisible: Bool {
        get { AppSettings.shared.canvasEdgesVisible }
        set { AppSettings.shared.canvasEdgesVisible = newValue; objectWillChange.send() }
    }

    /// 当前要画的对齐辅助线。拖动中实时更新，松手清空
    @Published var snapGuides: [SnapGuide] = []

    /// 鼠标正悬在哪张文本卡片上。
    ///
    /// 画布的滚轮监听默认把**所有**滚轮事件都吞掉去平移画布，文本卡片里的
    /// NSTextView 一个都收不到 —— 文字超出卡片也滚不动。有了这个，
    /// 滚轮落在文本卡片上时就放行给它自己滚
    @Published var hoveredTextNodeID: UUID?

    /// 鼠标是不是悬在素材库/元素库那个面板上。
    ///
    /// 跟 `hoveredTextNodeID` 同一个道理：滚轮监听默认全吞去平移画布，
    /// 面板里的列表一格都滚不动。悬在面板上时滚轮改成滚这个列表
    @Published var assetPanelHovered = false

    /// 素材库/元素库面板底下那个 NSScrollView。
    ///
    /// 滚轮和自绘滚动条都要直接驱动它 —— SwiftUI 的 ScrollView 既拿不到滚动位置、
    /// 也没法程序化滚到某个偏移，只能顺着视图链把底层的 NSScrollView 找出来
    /// （跟时间轴那条横向滚动条同一套路）。**弱引用**，面板关掉就自动断
    weak var assetPanelScroller: NSScrollView?

    /// 把面板滚到某个位置（0~1）。拖自绘滚动条时调
    func scrollAssetPanel(toFraction frac: Double) {
        guard let sv = assetPanelScroller, let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        guard maxY > 0 else { return }
        var origin = sv.contentView.bounds.origin
        origin.y = maxY * CGFloat(frac.clamped(to: 0...1))
        sv.contentView.scroll(to: origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// 滚轮落在面板上：滚这个列表。返回 true = 事件已消化，别再拿去平移画布。
    ///
    /// 不靠「放行给系统去分发」那条路 —— SwiftUI 合并绘制，hitTest 命中的是最外层
    /// NSHostingView，能不能落到 ScrollView 上没准。直接改 clipView 的 bounds 最稳
    @discardableResult
    func scrollAssetPanelByWheel(_ event: NSEvent) -> Bool {
        guard assetPanelHovered, let sv = assetPanelScroller, let doc = sv.documentView else { return false }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        // 内容不足一屏也要吞掉：指针在面板上，画布不该跟着动
        guard maxY > 0 else { return true }
        // 触控板给的是像素、鼠标滚轮给的是行数，后者不放大一格挪不动
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        var origin = sv.contentView.bounds.origin
        origin.y = (origin.y - event.scrollingDeltaY * step).clamped(to: 0...maxY)
        sv.contentView.scroll(to: origin)
        sv.reflectScrolledClipView(sv.contentView)
        return true
    }

    /// 编辑中的文本卡片，光标在文字里的位置（UTF-16 偏移）。
    /// 工具栏按它决定「H1/B/I/U/S 作用在哪一行」—— 光标在第二段就改第二段，
    /// 不能一律往第一行加
    @Published var textCaretLocation: Int = 0

    /// 「文字被程序改了，不是用户敲进去的」的信号，每改一次加一。
    ///
    /// 编辑中的 NSTextView 平时**不接受**外部内容覆盖 —— 用户打字时绑定值会
    /// 短暂滞后一拍，那会儿拿绑定去盖 tv.string 会把刚敲的字冲掉。但工具栏点
    /// H1/B/I/U/S 改的正是同一份文字，属于「确实该盖进去」的外部修改。
    /// 靠这个计数把两者区分开：只有它变了，编辑器才强制同步一次
    @Published var textEditRevision: Int = 0

    /// 鼠标在内容坐标里的位置。
    ///
    /// **单独一个对象、而且是 let 不是 @Published**：只有连线层需要它（判断鼠标
    /// 有没有悬在某条线上）。挂在 CanvasState 上的话，鼠标每动一下所有卡片、
    /// 所有连线都得重算一次 body —— 卡片一多就是持续的掉帧，而鼠标移动是
    /// 整个画布里最高频的事件
    let hoverProbe = CanvasHoverProbe()

    /// 最近一次右键的位置（画布容器坐标）。
    /// 事件在 CanvasKeyMonitor 里捕获（挂在 ContentView 上），画布层收到后
    /// 做命中判定并弹自绘菜单 —— 两边不在一个视图里，靠这个字段传话
    @Published var rightClickAt: CGPoint?

    /// 底部聊天框是不是真的在被输入。
    ///
    /// **不能靠 NSWindow.firstResponder 判断**：聊天框那个 NSTextView 一挂上
    /// 视图层级就会自动成为第一响应者，哪怕用户从没点过它、界面上也没有光标。
    /// 靠它判断「是不是在输入文字」的话，画布的 delete / ⌘Z / ⇧⌘Z 会被永久
    /// 误判成「归输入框」而全部失效（实测日志：editing=true 但用户只是选中了卡片）。
    /// 改成由用户的实际动作来置位：点进输入框才算在输入，点卡片/空白就收回
    @Published var promptBarFocused = false

    /// 待插入聊天框的提及文字（「@图1」这样）。
    ///
    /// 卡片上的 @ 按钮在画布层，输入框的内容是聊天框自己的本地状态，
    /// 两边不在一个视图里，靠这个字段传话。插完由聊天框清空。
    /// **只是往提示词里插一段文字，不建立任何连线**
    @Published var pendingMention: String?

    /// 连线被拒时的提示，比如「图片不能参考音频」
    @Published var rejectMessage: String?

    /// 节点 → 在跑的任务 id，取消时用
    private var runningTaskIDs: [UUID: UUID] = [:]

    /// 这一轮文字编辑有没有记过撤销点。见 noteTextEdit
    private var textUndoRecordedFor: UUID?

    // MARK: - 撤销/重做

    /// 画布自己的撤销栈，跟时间轴那套完全分开 ——
    /// 在画布里按 ⌘Z 撤的该是刚加的节点，不是时间轴上的操作
    private struct Snapshot: Equatable {
        var nodes: [CanvasNode]
        var edges: [CanvasEdge]
        /// **组也要存**。只存节点和连线的话，删掉一个组再撤销，卡片会回来、
        /// 卡片身上的 groupID 也回来了，但 `groups` 里那条记录没恢复 ——
        /// 组名和那块浅色底就永远找不回来了
        var groups: [CanvasGroup]
    }

    /// 撤销栈里的一步。
    ///
    /// 大部分是画布自己的快照，但**在画布里删素材**这种操作动的是项目那边
    /// （素材、时间轴片段），得记成一步「转给项目撤」——
    /// 画布开着时 ⌘Z 被画布的监听吞掉、只走 `canvas.undo()`，
    /// 项目那次撤销永远轮不到，表现就是「⌘Z 只恢复卡片、不恢复素材」。
    /// 记成栈里的一条，顺序才对：删素材之后又拖了张卡片，⌘Z 先撤拖动、再撤删除
    private enum UndoEntry {
        case canvas(Snapshot)
        /// 本窗口发起的素材删除。撤销时转交 `ProjectState.undo()`，
        /// 素材、片段、卡片由那条链一起恢复
        case projectAssetRemoval
    }

    private var undoStack: [UndoEntry] = []

    /// 换画布时清掉撤销历史 —— 在新画布上撤销回上一张画布的内容毫无意义
    private var redoStack: [UndoEntry] = []
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
        push(.canvas(Snapshot(nodes: nodes, edges: edges, groups: groups)))
    }

    /// 记一步「这次删素材是本窗口在画布里发起的」，⌘Z 时转给项目撤
    func pushProjectAssetRemoval() {
        push(.projectAssetRemoval)
    }

    private func push(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoCounts()
    }

    func undo() {
        endTextEditUndoGroup()
        guard let entry = undoStack.popLast() else { return }
        switch entry {
        case .canvas(let snap):
            redoStack.append(.canvas(Snapshot(nodes: nodes, edges: edges, groups: groups)))
            apply(snap)
        case .projectAssetRemoval:
            // 交给项目撤：素材和时间轴片段在那边，卡片由恢复广播插回来
            redoStack.append(.projectAssetRemoval)
            project?.undo()
        }
        syncUndoCounts()
    }

    func redo() {
        endTextEditUndoGroup()
        guard let entry = redoStack.popLast() else { return }
        switch entry {
        case .canvas(let snap):
            undoStack.append(.canvas(Snapshot(nodes: nodes, edges: edges, groups: groups)))
            apply(snap)
        case .projectAssetRemoval:
            undoStack.append(.projectAssetRemoval)
            project?.redo()
        }
        syncUndoCounts()
    }

    private func apply(_ snap: Snapshot) {
        nodes = snap.nodes
        edges = snap.edges
        groups = snap.groups
        // 选中的组可能已经不在了
        if let g = selectedGroupID, !groups.contains(where: { $0.id == g }) {
            selectedGroupID = nil
        }
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
        pushUndo()
        let old = nodes[i].size
        let new = nodes[i].kind.defaultSize(ratio: ratio)
        nodes[i].ratio = ratio
        nodes[i].size = new
        nodes[i].position = CGPoint(x: nodes[i].position.x + (old.width - new.width) / 2,
                                    y: nodes[i].position.y + (old.height - new.height) / 2)
        // 选回「原始」要重新按素材尺寸摆一次，所以把标记清掉
        nodes[i].originalSizeApplied = (ratio != CanvasNode.originalRatio)
    }

    /// 「原始」比例的卡片按素材真实尺寸摆正。素材尺寸要读盘，所以是
    /// 先摆个默认形状、读出来再调 —— `CanvasNodeView` 拿到尺寸后调这里。
    ///
    /// **只摆一次**（`originalSizeApplied`）：卡片每次重新上屏都摆的话，
    /// 用户后来手动拖出来的尺寸会被冲掉。中心保持不动，跟 `setRatio` 一致
    func applyOriginalRatio(nodeID: UUID, natural: CGSize) {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }),
              nodes[i].ratio == CanvasNode.originalRatio,
              !nodes[i].originalSizeApplied,
              natural.width > 0, natural.height > 0 else { return }
        let r = natural.width / natural.height
        let long: CGFloat = 300
        let new = r >= 1 ? CGSize(width: long, height: long / r)
                         : CGSize(width: long * r, height: long)
        let old = nodes[i].size
        nodes[i].originalSizeApplied = true
        nodes[i].size = new
        nodes[i].position = CGPoint(x: nodes[i].position.x + (old.width - new.width) / 2,
                                    y: nodes[i].position.y + (old.height - new.height) / 2)
        // 顺手把「发给 API 用哪个档位」算好存下来，省得生成时再读一次盘
        nodes[i].snappedRatio = CanvasNode.snapRatio(
            natural, options: CanvasNode.ratioOptions(for: nodes[i].kind))
    }

    /// 这个节点发起生成时该用哪个比例。
    ///
    /// 「原始」不能直接发出去 —— 各家 API 只认固定档位，所以用摆正时算好的吸附值；
    /// 还没摆正过（素材尺寸没读出来）就退回全局记住的那个
    func generationRatio(for node: CanvasNode, settings: AppSettings) -> String {
        let remembered = node.kind == .image ? settings.aiImageRatio : settings.aiRatio
        guard node.ratio == CanvasNode.originalRatio else {
            return node.ratio.contains(":") ? node.ratio : remembered
        }
        return node.snappedRatio ?? remembered
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

    /// 文字被用户改动时调一下：**一轮编辑只压一个撤销点**。
    ///
    /// 每敲一个字压一次的话，50 步的撤销栈会被单个字符塞满，
    /// 按 ⌘Z 只能一个字一个字往回退，而且几下就把之前的操作挤没了。
    /// 「一轮」由 `endTextEditUndoGroup()` 划断（进出编辑态、工具栏改样式时）
    func noteTextEdit(_ nodeID: UUID) {
        guard textUndoRecordedFor != nodeID else { return }
        textUndoRecordedFor = nodeID
        pushUndo()
    }

    /// 结束当前这轮文字编辑：下次改动会重新压一个撤销点
    func endTextEditUndoGroup() {
        textUndoRecordedFor = nil
    }

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

        // 首尾帧模式：上游的头两张图分别当首帧、尾帧，不再走参考图那条路。
        // 顺序就是连线顺序 —— 界面上拖动重排，改的其实是连线的先后
        var firstFrame: URL?
        var lastFrame: URL?
        if node.kind == .video, node.usesFrameMode {
            firstFrame = images.first
            lastFrame = images.dropFirst().first
            images = []
        }

        // 空卡片是「就地填进去」，已经有素材的则**另起一张新卡片** ——
        // 直接覆盖等于把上一次的结果冲掉，没法对比也退不回去。
        // 要在发起时就记下来：等结果回来时卡片状态可能已经变了
        let hadContent = node.hasContent
        updateNode(id: nodeID) { $0.isGenerating = true; $0.isWaiting = false }

        // 比例按**这张卡片**自己的来（选「原始」时用吸附好的档位），
        // 不再一律用全局那个 —— 素材卡片和空卡片本来就该不一样
        let ratio = generationRatio(for: node, settings: settings)

        // 这活儿是**哪张画布**派的。用户随时可能切到别的画布去，
        // 结果回来时得认得出「这不是当前这张」，好把结果写回它自己的存档
        let ownerConv = conversationID
        let taskID = AIVideoService.shared.generateForCanvas(
            prompt: prompt,
            provider: provider,
            duration: settings.aiDuration,
            aspectRatio: node.kind == .image ? settings.aiRatio : ratio,
            resolution: settings.aiResolution,
            imageRatio: node.kind == .image ? ratio : settings.aiImageRatio,
            referenceImages: images,
            referenceVideos: videos,
            referenceAudios: audios,
            firstFrame: firstFrame,
            lastFrame: lastFrame) { [weak self] result in
                guard let self else { return }
                // 画布已经切走了：当前内存里的 nodes 是别人的，改它毫无意义。
                // 把结果落到那张画布**自己的存档**上，用户切回去就能看到成品
                if let owner = ownerConv, owner != self.conversationID {
                    self.applyResultToStoredCanvas(owner: owner, nodeID: nodeID,
                                                   hadContent: hadContent, result: result)
                    self.runningTaskIDs.removeValue(forKey: nodeID)
                    switch result {
                    case .success(let url):
                        Task { @MainActor in AgentBackgroundTasks.shared.finish(id: nodeID, url: url) }
                    case .failure(let e):
                        Task { @MainActor in
                            AgentBackgroundTasks.shared.fail(id: nodeID,
                                (e is CancellationError) ? "已取消" : e.localizedDescription)
                        }
                    }
                    return
                }
                let kind = self.node(nodeID)?.kind
                self.updateNode(id: nodeID) {
                    $0.isGenerating = false
                    switch result {
                    case .success(let url):
                        // 原卡片已经有素材了就别动它，产物落到旁边的新卡片上
                        if !hadContent { $0.mediaPath = url.path }
                        $0.failure = nil
                    case .failure(let error):
                        $0.failure = (error is CancellationError) ? "已取消" : error.localizedDescription
                    }
                }
                if case .success(let url) = result {
                    // 产物进全局素材库（v5.3.0 合并了元素库），卡片挂上 assetID ——
                    // 之后改名/删除/重新关联才跟着素材联动
                    var landed = nodeID
                    if hadContent, let spawned = self.spawnResultNode(from: nodeID, mediaURL: url) {
                        landed = spawned
                    }
                    project?.importFile(url)
                    if let asset = project?.mediaAssets.first(where: { $0.url == url }) {
                        self.updateNode(id: landed) { $0.assetID = asset.id }
                    }
                }
                // 后台任务清单里登记过的（Agent 派的）要了结掉，这样会话里才会
                // 报一声「生成好了 / 失败了」。用户自己点生成的没登记过，
                // finish/fail 找不到 id 会直接忽略
                // 这个回调不在主 actor 上，后台任务清单是 @MainActor 的，切过去再动
                let outcome: Result<URL, Error> = result
                Task { @MainActor in
                    switch outcome {
                    case .success(let url): AgentBackgroundTasks.shared.finish(id: nodeID, url: url)
                    case .failure(let e):
                        AgentBackgroundTasks.shared.fail(id: nodeID,
                            (e is CancellationError) ? "已取消" : e.localizedDescription)
                    }
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

        // 跟素材卡片一个规矩：卡片里已经有字了就另起一张，别把原文冲掉
        let hadContent = node.hasContent
        updateNode(id: nodeID) { $0.isGenerating = true; $0.isWaiting = false }
        let taskID = AIVideoService.shared.generateTextForCanvas(prompt: prompt, provider: provider) { [weak self] result in
            guard let self else { return }
            self.updateNode(id: nodeID) {
                $0.isGenerating = false
                switch result {
                case .success(let text):
                    if !hadContent { $0.text = text }
                    $0.failure = nil
                case .failure(let error):
                    $0.failure = (error is CancellationError) ? "已取消" : error.localizedDescription
                }
            }
            if case .success(let text) = result, hadContent {
                self.spawnResultNode(from: nodeID, text: text)
            }
            self.runningTaskIDs.removeValue(forKey: nodeID)
            self.resumeWaitingNodes(provider: provider, settings: .shared)
        }
        runningTaskIDs[nodeID] = taskID
    }

    /// 生成结果落一张新卡片，摆在源卡片右边。
    ///
    /// 只在「源卡片本来就有内容」时走这条 —— 空卡片直接填进去更自然，
    /// 生成一次冒出两张（一空一满）反而奇怪
    /// - Returns: 新卡片的 id，调用方拿去把元素库依赖挂上
    @discardableResult
    private func spawnResultNode(from sourceID: UUID, mediaURL: URL? = nil, text: String? = nil) -> UUID? {
        guard let src = node(sourceID) else { return nil }
        let pos = CGPoint(x: src.position.x + src.size.width + 90, y: src.position.y)
        let new = addNode(kind: src.kind, at: pos, ratio: src.ratio)
        updateNode(id: new.id) {
            $0.size = src.size
            // 提示词一并带过去：接着再生成一版时不用重新写
            $0.prompt = src.prompt
            if let mediaURL { $0.mediaPath = mediaURL.path }
            if let text { $0.text = text }
        }
        return new.id
    }

    /// Agent 在画布里生成出来的东西，落成一张新卡片。
    ///
    /// 画布里的 agent 干的是画布的活，产物就该出现在画布上；
    /// 只塞进素材库的话用户还得自己去拖回来。素材库那份照旧也进（统一走
    /// 全局素材库，改名/删除才联动）
    @discardableResult
    func dropGeneratedMedia(url: URL, kind: CanvasNode.Kind, at point: CGPoint? = nil) -> UUID {
        let pos = freeSpot(near: point ?? viewportCenterInContent())
        // 用「原始」比例：卡片随后按素材真实尺寸摆正（`applyOriginalRatio`）。
        // 走默认的 1:1 会把 16:9 的视频塞进方卡片里
        let new = addNode(kind: kind, at: pos, ratio: CanvasNode.originalRatio)
        updateNode(id: new.id) { $0.mediaPath = url.path }
        // 已经在库里就别再导 —— 生成产物落卡片时早进过一次，
        // 重复导入会冒一条「已跳过重复素材」
        if project?.mediaAssets.contains(where: { $0.url == url }) != true {
            project?.importFile(url)
        }
        if let asset = project?.mediaAssets.first(where: { $0.url == url }) {
            updateNode(id: new.id) { $0.assetID = asset.id }
        }
        return new.id
    }

    /// 视口中心对应的内容坐标。换算跟 CanvasOverlay.contentPoint 一致
    func viewportCenterInContent() -> CGPoint {
        let c = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return contentPoint(fromViewPoint: c)
    }

    /// 画布容器里的点 → 内容坐标
    func contentPoint(fromViewPoint p: CGPoint) -> CGPoint {
        let c = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return CGPoint(x: (p.x - offset.width - c.x) / zoom + c.x,
                       y: (p.y - offset.height - c.y) / zoom + c.y)
    }

    /// 目标位置上已经压着卡片就往右下错开，别正好摞上去
    private func freeSpot(near point: CGPoint) -> CGPoint {
        var pos = point
        var guardCount = 0
        while nodes.contains(where: { hypot($0.position.x - pos.x, $0.position.y - pos.y) < 40 }),
              guardCount < 40 {
            pos = CGPoint(x: pos.x + 40, y: pos.y + 40)
            guardCount += 1
        }
        return pos
    }

    /// 能读成文字卡片的后缀。二进制不收 —— 一屏乱码没有意义
    static let textFileExts: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "yml", "yaml", "xml",
        "html", "css", "js", "ts", "swift", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "sh", "toml", "ini", "conf", "srt", "vtt"
    ]

    /// 拖进来 / 粘贴进来的文件，按后缀落成对应的卡片。
    /// 媒体一律同时进全局素材库（`dropGeneratedMedia` 里做），
    /// 之后改名删除才跟卡片联动
    @discardableResult
    func dropFiles(_ urls: [URL], at point: CGPoint? = nil) -> Int {
        var pos = point ?? viewportCenterInContent()
        var landed = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: CanvasNode.Kind
            if AIVideoService.imageExts.contains(ext) { kind = .image }
            else if AIVideoService.videoExts.contains(ext) { kind = .video }
            else if AIVideoService.audioExts.contains(ext) { kind = .audio }
            else if Self.textFileExts.contains(ext) { kind = .text }
            else { continue }

            if kind == .text {
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let n = addNode(kind: .text, at: freeSpot(near: pos))
                updateNode(id: n.id) { $0.text = body }
            } else {
                dropGeneratedMedia(url: url, kind: kind, at: pos)
            }
            landed += 1
            pos = CGPoint(x: pos.x + 40, y: pos.y + 40)
        }
        return landed
    }

    /// 系统剪贴板里有没有能落成卡片的东西
    var systemPasteboardHasContent: Bool {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) { return true }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return !(pb.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 画布自己复制过卡片就粘卡片，否则看系统剪贴板
    var canPaste: Bool { !clipboard.isEmpty || systemPasteboardHasContent }

    /// 画布内部复制那份的时间戳（对应系统剪贴板的 changeCount）
    var clipboardStamp: Int = -1

    /// 粘贴。**谁新用谁** —— 内部复制过卡片之后又在别处复制了文字，
    /// 无脑优先内部那份的话，粘出来的是上次那张卡片，跟手里复制的东西对不上
    @discardableResult
    func pasteHere(at point: CGPoint? = nil) -> Bool {
        let systemIsNewer = NSPasteboard.general.changeCount > clipboardStamp
        if !clipboard.isEmpty, !systemIsNewer { paste(); return true }
        if pasteFromPasteboard(at: point) { return true }
        // 系统剪贴板里没有能落成卡片的东西，退回内部那份
        if !clipboard.isEmpty { paste(); return true }
        return false
    }

    /// 系统剪贴板里的东西落成卡片：文件、图片位图、纯文字都收
    @discardableResult
    func pasteFromPasteboard(at point: CGPoint? = nil) -> Bool {
        let pb = NSPasteboard.general
        // ① 先看文件 —— 从访达复制过来的是 fileURL
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return dropFiles(urls, at: point) > 0
        }
        // ② 截图这类是内存里的位图，得先落成文件才能进素材库
        if let img = NSImage(pasteboard: pb),
           let url = AgentAttachmentIO.savePastedImage(img) {
            dropGeneratedMedia(url: url, kind: .image, at: point)
            return true
        }
        // ③ 纯文字 → 文本卡片
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let n = addNode(kind: .text, at: freeSpot(near: point ?? viewportCenterInContent()))
            updateNode(id: n.id) { $0.text = text }
            return true
        }
        return false
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

    /// 结果落到一张**不在眼前**的画布存档里：填素材、停掉转圈、记进产物清单。
    /// 原卡片已经有内容的，照界面上的规矩另起一张新卡片摆在旁边
    private func applyResultToStoredCanvas(owner: UUID, nodeID: UUID,
                                           hadContent: Bool, result: Result<URL, Error>) {
        let svc = AIVideoService.shared
        svc.editCanvasSnapshot(id: owner) { snap in
            guard let i = snap.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            snap.nodes[i].isGenerating = false
            snap.nodes[i].isWaiting = false
            switch result {
            case .failure(let e):
                snap.nodes[i].failure = (e is CancellationError) ? "已取消" : e.localizedDescription
            case .success(let url):
                snap.nodes[i].failure = nil
                if hadContent {
                    // 原卡片留着，产物摆到它右边 —— 跟在画布上时的行为一致
                    var fresh = snap.nodes[i]
                    fresh.id = UUID()
                    fresh.position = CGPoint(x: fresh.position.x + fresh.size.width + 40,
                                             y: fresh.position.y)
                    fresh.mediaPath = url.path
                    fresh.assetID = nil
                    fresh.prompt = snap.nodes[i].prompt
                    snap.nodes.append(fresh)
                } else {
                    snap.nodes[i].mediaPath = url.path
                }
            }
        }
        // 产物照样进素材库，跟在画布上时一样
        if case .success(let url) = result { project?.importFile(url) }
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

    /// 把画布挪到让某张卡片居中，**同时放大到看得清**。
    /// 聊天框里双击一张参考素材就用这个 —— 参考的是画布上哪张卡片，一眼看到
    func focus(on nodeID: UUID, containerSize: CGSize) {
        guard let n = node(nodeID), containerSize.width > 1, containerSize.height > 1 else { return }
        let box = n.frame
        // 让这张卡片占到视口的六成左右：太满会看不到它跟周围的关系，
        // 太小又等于没放大。已经比这更大就不动缩放，免得反而缩小
        let fit = min(containerSize.width * 0.6 / max(1, box.width),
                      containerSize.height * 0.6 / max(1, box.height))
        let target = min(Self.maxZoom, max(zoom, min(fit, 1.5)))

        // 换算关系跟 setZoom / zoomToFit 一致：
        // 屏幕位置 = (内容坐标 - center) × zoom + center + offset
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        withAnimation(.easeOut(duration: 0.25)) {
            zoom = target
            offset = CGSize(width: -(box.midX - center.x) * target,
                            height: -(box.midY - center.y) * target)
            selectedGroupID = nil
            selectedNodeIDs = [nodeID]
        }
    }

    /// 断开一条参考连线（聊天框里点素材上的 × 走这儿）
    func disconnect(from: UUID, to: UUID) {
        guard edges.contains(where: { $0.from == from && $0.to == to }) else { return }
        pushUndo()
        edges.removeAll { $0.from == from && $0.to == to }
    }

    /// 缩放到刚好装下画布上所有东西，并居中。
    ///
    /// 包围盒算的是**卡片连同上方标签行**，再并上组的浅色底 —— 组框可能比
    /// 成员的包围盒还大（用户手动拉过），只算卡片会把组的边缘切在视口外
    func zoomToFit(containerSize: CGSize) {
        guard !nodes.isEmpty, containerSize.width > 1, containerSize.height > 1 else {
            resetView()
            return
        }
        var box = frameWithLabel(nodes[0])
        for n in nodes.dropFirst() { box = box.union(frameWithLabel(n)) }
        for g in groupFrames { box = box.union(g.rect) }
        guard box.width > 1, box.height > 1 else { resetView(); return }

        // 四周留一圈，不然卡片正好贴着边看着憋屈
        let margin: CGFloat = 60
        let usableW = max(1, containerSize.width - margin * 2)
        let usableH = max(1, containerSize.height - margin * 2)
        let fit = min(usableW / box.width, usableH / box.height)
        let newZoom = min(Self.maxZoom, max(Self.minZoom, fit))

        // 让包围盒中心落在视口中心。换算关系跟 setZoom 那边一致：
        // 屏幕位置 = (内容坐标 - center) × zoom + center + offset
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        zoom = newZoom
        offset = CGSize(width: -(box.midX - center.x) * newZoom,
                        height: -(box.midY - center.y) * newZoom)
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
        // 存档里残留的「生成中」要清掉：那是上次关掉 app 时的状态，
        // 任务早随进程没了，留着就是永远转圈。这一轮真在跑的不受影响 ——
        // 它们的结果会直接写回存档
        for i in nodes.indices where nodes[i].isGenerating || nodes[i].isWaiting {
            if runningTaskIDs[nodes[i].id] == nil {
                nodes[i].isGenerating = false
                nodes[i].isWaiting = false
            }
        }
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

/// 只装一个鼠标位置的小对象。见 CanvasState.hoverProbe 的注释
final class CanvasHoverProbe: ObservableObject {
    @Published var point: CGPoint?
}
