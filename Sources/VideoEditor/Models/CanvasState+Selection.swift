import SwiftUI

// MARK: - 框选 / 成组 / 复制粘贴（v5.1.0）

extension CanvasState {

    /// 卡片上方类型标签占的高度（跟 CanvasNodeView.labelHeight 对齐）
    static let groupLabelInset: CGFloat = 18
    /// 组的浅色底比卡片往外扩多少
    static let groupPadding: CGFloat = 14

    // MARK: 选中

    /// 点中某张卡片。**组里的卡片也是单选** —— 整组要操作就去点组的浅色底。
    /// `additive`（⌘/⇧ 点）是往选中集里加减，不是替换
    func select(_ id: UUID, additive: Bool = false) {
        selectedGroupID = nil
        guard additive else {
            selectedNodeIDs = [id]
            return
        }
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
        } else {
            selectedNodeIDs.insert(id)
        }
    }

    /// 点组的浅色底：选中整个组
    func selectGroup(_ gid: UUID) {
        selectedNodeIDs = []
        selectedGroupID = gid
    }

    func nodeIDs(inGroup gid: UUID) -> Set<UUID> {
        Set(nodes.filter { $0.groupID == gid }.map(\.id))
    }

    /// 框选：跟框相交就算选中（不要求整张卡片框进去 —— 那样得框得非常准）
    func selectInRect(_ rect: CGRect) {
        selectedGroupID = nil
        selectedNodeIDs = Set(nodes.filter { $0.frame.intersects(rect) }.map(\.id))
    }

    /// 拖这张卡片时跟着一起走的都有谁。
    /// 拖的是多选里的一张就整批走，否则**只有它自己** —— 组里的卡片也能单独拖出来
    func dragCompanions(of id: UUID) -> Set<UUID> {
        if selectedNodeIDs.contains(id), selectedNodeIDs.count > 1 { return selectedNodeIDs }
        return [id]
    }

    // MARK: 分组

    /// 组名那一条占的高度。名字画在框**外**的上方，跟卡片的标签一样，
    /// 所以框本身不为它留位置
    static let groupTitleHeight: CGFloat = 18

    /// 卡片连同上方标签行占的矩形 —— 组的底要把标签也罩进去。
    /// 用**静态** frame，不算拖动中的临时位移：拖单张卡片时组框跟着变形看着乱，
    /// 而且卡片正被拖出去时框还追着它跑，就看不出「已经出组了」
    func frameWithLabel(_ node: CanvasNode) -> CGRect {
        var r = node.frame
        r.origin.y -= Self.groupLabelInset
        r.size.height += Self.groupLabelInset
        return r
    }

    /// 一个组的框：成员包围盒 + 留白 + 顶上组名那一条，再并上用户手动拉过的框
    func frame(ofGroup gid: UUID) -> CGRect? {
        let frames = nodes.filter { $0.groupID == gid }.map { frameWithLabel($0) }
        guard var r = frames.first else { return nil }
        for f in frames.dropFirst() { r = r.union(f) }
        r = r.insetBy(dx: -Self.groupPadding, dy: -Self.groupPadding)
        if let explicit = group(gid)?.rect { r = r.union(explicit) }
        return r
    }

    /// 每个组的名字和框（内容坐标）
    var groupFrames: [(id: UUID, name: String, rect: CGRect)] {
        groups.compactMap { g in
            guard let r = frame(ofGroup: g.id) else { return nil }
            return (g.id, g.name, r)
        }
    }

    /// 组的背景色。传 nil 回到默认的浅灰白
    func setGroupColor(_ gid: UUID, _ hex: String?) {
        guard let i = groups.firstIndex(where: { $0.id == gid }) else { return }
        pushUndo()
        groups[i].colorHex = hex
    }

    /// 组背景可选的几个颜色。半透明画出来只剩一点色调，不抢卡片
    static let groupColors: [(name: String, hex: String)] = [
        ("红", "#FF6B6B"), ("橙", "#FFA94D"), ("黄", "#FFD43B"), ("绿", "#69DB7C"),
        ("蓝", "#4DABF7"), ("紫", "#DA77F2"), ("灰", "#ADB5BD")
    ]

    /// 用户拖组边缘拉出来的框，松手提交
    func setGroupRect(_ gid: UUID, _ rect: CGRect) {
        guard let i = groups.firstIndex(where: { $0.id == gid }) else { return }
        pushUndo()
        groups[i].rect = rect
    }

    func group(_ id: UUID) -> CanvasGroup? { groups.first { $0.id == id } }

    /// 把选中的卡片并成一组
    func groupSelected() {
        guard selectedNodeIDs.count > 1 else { return }
        pushUndo()
        let g = CanvasGroup(name: "组 \(groups.count + 1)")
        for i in nodes.indices where selectedNodeIDs.contains(nodes[i].id) {
            nodes[i].groupID = g.id
        }
        groups.append(g)
        // 成完组直接选中这个组，接着就能整组拖走
        selectedNodeIDs = []
        selectedGroupID = g.id
    }

    /// 解散一个组：卡片留着，只是不再绑在一起
    func disband(_ gid: UUID) {
        for i in nodes.indices where nodes[i].groupID == gid {
            nodes[i].groupID = nil
        }
        groups.removeAll { $0.id == gid }
        if selectedGroupID == gid { selectedGroupID = nil }
    }

    func ungroup(_ gid: UUID) {
        pushUndo()
        disband(gid)
    }

    /// 整组移动
    func moveGroup(_ gid: UUID, by delta: CGSize) {
        pushUndo()
        for i in nodes.indices where nodes[i].groupID == gid {
            nodes[i].position = CGPoint(x: nodes[i].position.x + delta.width,
                                        y: nodes[i].position.y + delta.height)
        }
        // 手动拉过的框跟着一起走，不然拉大的那块会留在原地
        if let i = groups.firstIndex(where: { $0.id == gid }), let r = groups[i].rect {
            groups[i].rect = r.offsetBy(dx: delta.width, dy: delta.height)
        }
    }

    /// 卡片拖完之后看看还算不算在组里。
    ///
    /// 判据是**其他组员**围出来的那块底：拿全体算的话，盒子会跟着被拖的卡片一起
    /// 膨胀，永远框得住它，就再也脱不了组。只要碰到边缘或出界就脱组 ——
    /// 完全罩在里面才算还在
    func detachIfOutside(_ id: UUID) {
        guard let n = node(id), let gid = n.groupID else { return }
        let mates = nodes.filter { $0.groupID == gid && $0.id != id }
        guard let first = mates.first else { disband(gid); return }

        var r = frameWithLabel(first)
        for m in mates.dropFirst() { r = r.union(frameWithLabel(m)) }
        r = r.insetBy(dx: -Self.groupPadding, dy: -Self.groupPadding)
        // 用户把框拉大过的话，那块也算组的地盘
        if let explicit = group(gid)?.rect { r = r.union(explicit) }

        guard !r.contains(frameWithLabel(n)) else { return }
        updateNode(id: id) { $0.groupID = nil }
        // 剩一张卡片的组没有意义，自动解散
        if nodes.filter({ $0.groupID == gid }).count < 2 { disband(gid) }
    }

    // MARK: 复制 / 粘贴 / 副本 / 删除

    func copy(ids: Set<UUID>) {
        let picked = nodes.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        // 只带**两端都在选中集里**的线；连到集合外的线粘出来会指向别人的卡片
        clipboard = Clipboard(nodes: picked,
                              edges: edges.filter { ids.contains($0.from) && ids.contains($0.to) })
    }

    func paste() {
        guard !clipboard.isEmpty else { return }
        pushUndo()
        insert(nodes: clipboard.nodes, edges: clipboard.edges, keepExternal: false)
    }

    /// 创建副本：连线一起复制。
    /// 内部的线用新 id 重连，连到外面的线接回原来的邻居 —— 菜单里那句「带连接线」
    func duplicate(ids: Set<UUID>) {
        let picked = nodes.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        pushUndo()
        insert(nodes: picked,
               edges: edges.filter { ids.contains($0.from) || ids.contains($0.to) },
               keepExternal: true)
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pushUndo()
        let touchedGroups = Set(nodes.filter { ids.contains($0.id) }.compactMap(\.groupID))
        nodes.removeAll { ids.contains($0.id) }
        edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        selectedNodeIDs.subtract(ids)
        // 删到只剩一张（或一张不剩）的组自动散掉
        for gid in touchedGroups where nodes.filter({ $0.groupID == gid }).count < 2 {
            disband(gid)
        }
    }

    /// 落一批卡片进来，整批往右下挪一点，好看出来是新的一份。
    /// 落完直接选中它们 —— 用户接着就想把这批拖走
    private func insert(nodes ns: [CanvasNode], edges es: [CanvasEdge], keepExternal: Bool) {
        let shift: CGFloat = 40
        var idMap: [UUID: UUID] = [:]
        var groupMap: [UUID: UUID] = [:]
        var fresh: Set<UUID> = []

        for var n in ns {
            let newID = UUID()
            idMap[n.id] = newID
            n.id = newID
            n.position = CGPoint(x: n.position.x + shift, y: n.position.y + shift)
            // 组也复制成新的一组：不换的话副本会跟原来那组黏在一起，一拖全动
            if let g = n.groupID {
                if let mapped = groupMap[g] {
                    n.groupID = mapped
                } else {
                    let ng = CanvasGroup(name: "组 \(groups.count + 1)")
                    groupMap[g] = ng.id
                    groups.append(ng)
                    n.groupID = ng.id
                }
            }
            // 在跑的任务不跟着复制 —— 副本不是那次生成
            n.isGenerating = false
            n.isWaiting = false
            nodes.append(n)
            fresh.insert(newID)
        }

        let alive = Set(nodes.map(\.id))
        for e in es {
            let from = idMap[e.from] ?? (keepExternal ? e.from : nil)
            let to = idMap[e.to] ?? (keepExternal ? e.to : nil)
            guard let from, let to, alive.contains(from), alive.contains(to) else { continue }
            guard !edges.contains(where: { $0.from == from && $0.to == to }) else { continue }
            edges.append(CanvasEdge(from: from, to: to))
        }
        selectedGroupID = nil
        selectedNodeIDs = fresh
    }
}

// MARK: - 拖动吸附（v5.1.0）

extension CanvasState {

    /// 一条对齐辅助线。拖动时画出来，告诉用户「贴上了谁」
    struct SnapGuide: Identifiable {
        let id = UUID()
        /// true = 竖线（左右方向对齐），false = 横线
        let isVertical: Bool
        /// 线所在的位置（内容坐标：竖线是 x，横线是 y）
        let position: CGFloat
        /// 线画多长 —— 只覆盖参与对齐的那两张卡片，画满整屏反而看不出在跟谁对
        let start: CGFloat
        let end: CGFloat
    }

    /// 吸附判定的距离（**屏幕像素**）。缩小画布时内容坐标里的容差要相应放大，
    /// 不然缩到 50% 时手感会变成「要凑到一半的距离才吸得上」
    private static let snapThresholdOnScreen: CGFloat = 8

    /// 拖动中算一次吸附。
    ///
    /// 拿被拖的那批卡片的整体外框，去跟其它卡片的左/中/右、上/中/下对齐，
    /// 每个方向各取最近的一条。返回修正后的位移和要画的辅助线
    func snapOffset(draggingIDs: Set<UUID>, rawOffset: CGSize) -> (offset: CGSize, guides: [SnapGuide]) {
        guard snapEnabled, !draggingIDs.isEmpty else { return (rawOffset, []) }

        let moving = nodes.filter { draggingIDs.contains($0.id) }
        let others = nodes.filter { !draggingIDs.contains($0.id) }
        guard var box = moving.first?.frame, !others.isEmpty else { return (rawOffset, []) }
        for n in moving.dropFirst() { box = box.union(n.frame) }
        box = box.offsetBy(dx: rawOffset.width, dy: rawOffset.height)

        let threshold = Self.snapThresholdOnScreen / max(0.1, zoom)

        // 竖直方向的三条候选：自己的左边/中线/右边，各去找最近的目标
        var bestX: (delta: CGFloat, line: CGFloat, dist: CGFloat)?
        var bestY: (delta: CGFloat, line: CGFloat, dist: CGFloat)?

        for other in others {
            let f = other.frame
            for mine in [box.minX, box.midX, box.maxX] {
                for target in [f.minX, f.midX, f.maxX] {
                    let d = abs(target - mine)
                    if d <= threshold, d < (bestX?.dist ?? .greatestFiniteMagnitude) {
                        bestX = (target - mine, target, d)
                    }
                }
            }
            for mine in [box.minY, box.midY, box.maxY] {
                for target in [f.minY, f.midY, f.maxY] {
                    let d = abs(target - mine)
                    if d <= threshold, d < (bestY?.dist ?? .greatestFiniteMagnitude) {
                        bestY = (target - mine, target, d)
                    }
                }
            }
        }

        let snapped = CGSize(width: rawOffset.width + (bestX?.delta ?? 0),
                             height: rawOffset.height + (bestY?.delta ?? 0))
        let finalBox = box.offsetBy(dx: bestX?.delta ?? 0, dy: bestY?.delta ?? 0)

        var guides: [SnapGuide] = []
        if let x = bestX?.line {
            // 辅助线纵向只画到「参与对齐的卡片」的范围，看得出是在跟谁对齐
            let related = others.filter { abs($0.frame.minX - x) < 0.5 || abs($0.frame.midX - x) < 0.5
                                       || abs($0.frame.maxX - x) < 0.5 }
            let lo = min(finalBox.minY, related.map(\.frame.minY).min() ?? finalBox.minY)
            let hi = max(finalBox.maxY, related.map(\.frame.maxY).max() ?? finalBox.maxY)
            guides.append(SnapGuide(isVertical: true, position: x, start: lo, end: hi))
        }
        if let y = bestY?.line {
            let related = others.filter { abs($0.frame.minY - y) < 0.5 || abs($0.frame.midY - y) < 0.5
                                       || abs($0.frame.maxY - y) < 0.5 }
            let lo = min(finalBox.minX, related.map(\.frame.minX).min() ?? finalBox.minX)
            let hi = max(finalBox.maxX, related.map(\.frame.maxX).max() ?? finalBox.maxX)
            guides.append(SnapGuide(isVertical: false, position: y, start: lo, end: hi))
        }
        return (snapped, guides)
    }
}

// MARK: - 上游顺序

extension CanvasState {

    /// 调整某个节点的上游顺序。
    ///
    /// 上游的先后就是 `edges` 里那几条入边的先后（`upstreamNodes` 直接按数组序取），
    /// 所以重排 = 把这几条边按新顺序写回去，其它边的位置不动
    func moveUpstream(of nodeID: UUID, from source: Int, to destination: Int) {
        let incomingIdx = edges.indices.filter { edges[$0].to == nodeID }
        guard source >= 0, source < incomingIdx.count,
              destination >= 0, destination <= incomingIdx.count else { return }

        var incoming = incomingIdx.map { edges[$0] }
        let moved = incoming.remove(at: source)
        // 往后拖时，移除那一项会让目标下标前移一位
        let target = destination > source ? destination - 1 : destination
        incoming.insert(moved, at: min(target, incoming.count))

        pushUndo()
        for (slot, edgeIndex) in incomingIdx.enumerated() {
            edges[edgeIndex] = incoming[slot]
        }
    }
}

extension CanvasState {

    /// 对调两条入边的先后。
    ///
    /// 交换首尾帧走这个，而不是 `moveUpstream` —— 那个是「移动」语义，
    /// 上游里夹着非图片素材时，移动会把不相干的东西也挤走位；
    /// 这里要的就是干脆利落地把两张图的位置换过来，反复点也能来回换
    func swapUpstream(of nodeID: UUID, _ a: Int, _ b: Int) {
        let incoming = edges.indices.filter { edges[$0].to == nodeID }
        guard a >= 0, b >= 0, a < incoming.count, b < incoming.count, a != b else { return }
        pushUndo()
        edges.swapAt(incoming[a], incoming[b])
    }
}
