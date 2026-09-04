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
    /// 文本卡片调整热区骑在边线上：一半探出卡片外、一半留在卡片内，
    /// 鼠标不用精确停在轮廓线上也能抓到。跟 plusGutter 一个道理 ——
    /// 上/左/右三边探出去有 labelHeight/plusGutter 现成的余量兜着，
    /// 只有底边没有任何余量，body 最外层的 frame 要单独为它多留这么高，
    /// 不然探出去的那部分会被最外层 contentShape 裁在可交互区域之外
    static let edgeStraddle: CGFloat = 8

    @ObservedObject private var player = AIInlinePlayer.shared
    @State private var isHovering = false
    /// 拖动中的临时位移。拖的时候只改这个本地值，松手才写回 model ——
    /// 每动一下就改 canvas.nodes 会让整层 ForEach 跟着重建，表现就是闪烁 + 不跟手
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isResizing = false
    /// 名字正在改。Finder 式「点、停、再点」进入
    @State private var isRenaming = false
    @State private var editName = ""
    @FocusState private var nameFieldFocused: Bool

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
    /// 是否该把键盘焦点给文本卡片的输入框。
    ///
    /// **是 `@State` 不是 `@FocusState`** —— 换成 NSTextView（CanvasTextEditor）
    /// 之后，这个值再没有 `.focused($textFocused)` 绑定到任何真正的 SwiftUI
    /// 可聚焦控件上，纯粹是传给 `CanvasTextEditor.focused` 参数的一个普通开关。
    /// 顶着 `@FocusState` 这个名不副实的类型，会被 SwiftUI 的焦点系统当成
    /// 真·焦点状态去管理，在没有关联视图的情况下行为不可控 —— 表现就是
    /// 「打一个字，输入框自己就失焦了，得再点一次才能接着打」
    @State private var textFocused: Bool = false
    /// 上次点击这张卡片的时间，用来自己判双击（见 onTapGesture 的注释）
    @State private var lastTapTime: Date = .distantPast

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
    /// 只有文本卡片有 resize 热区，只有它需要这份底部余量
    private var bottomResizeMargin: CGFloat { node.kind == .text ? Self.edgeStraddle : 0 }
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
                    nameLabel
                    Spacer(minLength: 4)
                }
                .foregroundColor(Color.labelSecondary.opacity(0.7))
                .frame(width: effectiveSize.width, height: Self.labelHeight - 4, alignment: .bottom)

                card
                // 底部热区要探出卡片边界，占位撑开 VStack 的声明高度，
                // 这样 ZStack 居中对齐不会因为外层 frame 变高而把内容一起下移
                // ——「透明」是因为这里本来就不该看得见任何东西
                if node.kind == .text {
                    Color.clear.frame(height: Self.edgeStraddle)
                }
            }
            .frame(width: effectiveSize.width)

            plusButton(.leading)
            plusButton(.trailing)
            // 连接点排在 + 后面 —— 它贴着卡片边框，要压在文本卡片的
            // resize 热区上面，不然拖它会变成调整卡片大小
            connectorDot(.leading)
            connectorDot(.trailing)
        }
        // 把两侧空当算进 frame，+ 才收得到鼠标；底部再加一份给 resize 热区
        .frame(width: effectiveSize.width + Self.plusGutter * 2,
               height: effectiveSize.height + Self.labelHeight + bottomResizeMargin)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            autoPlayOnHover(inside)
            // 文本卡片：告诉画布「滚轮现在归这张卡片」，见 CanvasState.hoveredTextNodeID
            if node.kind == .text {
                if inside {
                    canvas.hoveredTextNodeID = node.id
                } else if canvas.hoveredTextNodeID == node.id {
                    canvas.hoveredTextNodeID = nil
                }
            }
        }
        .offset(x: dragOffset.width + livePosDelta.width + carriedOffset.width,
                y: dragOffset.height + livePosDelta.height + carriedOffset.height)
        .gesture(dragGesture)
        // **自己判连击**，不挂 `.onTapGesture(count: 2)`。
        // 同时挂单击和双击手势的话，SwiftUI 要等约 0.3 秒确认「不是双击」
        // 才触发单击，选中卡片会明显延迟（画布空白处那次踩过同样的坑）
        .onTapGesture {
            let now = Date()
            let isDouble = now.timeIntervalSince(lastTapTime) < 0.35
            lastTapTime = isDouble ? .distantPast : now

            // SwiftUI 的 tap 不给修饰键，只能问 NSEvent 当前按着什么
            let flags = NSEvent.modifierFlags
            canvas.select(node.id, additive: flags.contains(.command) || flags.contains(.shift))
            // 视频在放：点一下卡片就停下，播放图标跟着回来
            if node.kind == .video, player.isPlaying(node.id) {
                player.togglePause()
            }
            // 文本卡片：**双击**才进编辑出光标。单击只选中 ——
            // 单击就进编辑的话，「正在输入文字」一直成立，
            // 画布的 delete / ⌘Z 会被一路放行给输入框，卡片就删不掉了
            if node.kind == .text, isDouble {
                canvas.editingTextNodeID = node.id
                textFocused = true
            } else {
                // 其它情况一律把键盘焦点收回画布。不收的话焦点赖在
                // 底部聊天框那个 NSTextView 上，快捷键会被当成「在输入框里」
                canvas.editingTextNodeID = nil
                canvas.promptBarFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: canvas.editingTextNodeID) { _, editing in
            textFocused = (editing == node.id)
            // 进出编辑态各算一轮，下一轮改动会重新压撤销点
            canvas.endTextEditUndoGroup()
            // 换一张卡片编辑，光标位置得清零 —— 留着上一张的偏移，
            // 工具栏会照着一个跟当前文字无关的位置去找行
            if editing == node.id { canvas.textCaretLocation = 0 }
        }
        // 波形/时长/封面都得主动要一次。以前只读缓存不请求 ——
        // 进画布时音频卡片是空的，得等用户去点播放（那会儿别处顺带生成了）才冒出来
        .onAppear { prepareMedia() }
        .onChange(of: node.mediaPath) { _, _ in
            cachedDuration = 0
            localCover = nil
            prepareMedia()
        }


    }

    /// 文本卡片四条边的调整热区。
    ///
    /// 不画把手 —— 鼠标挪到边上光标自己变成双向箭头，直接拖就改大小。
    /// 热区**骑在边线上**：一半探出卡片外、一半留在卡片内（各 edgeStraddle），
    /// 不用把鼠标精确停在轮廓线上才能抓到。纯内嵌的话，鼠标稍微出去一点点
    /// 就摸不到了，边缘本身又很细，很难一次就点中
    @ViewBuilder
    private var resizeEdges: some View {
        let straddle = Self.edgeStraddle
        let thickness = straddle * 2
        ZStack {
            edgeHandle(.top).frame(width: max(0, effectiveSize.width - thickness), height: thickness)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: -straddle)
            edgeHandle(.bottom).frame(width: max(0, effectiveSize.width - thickness), height: thickness)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: straddle)
            edgeHandle(.leading).frame(width: thickness, height: max(0, effectiveSize.height - thickness))
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: -straddle)
            edgeHandle(.trailing).frame(width: thickness, height: max(0, effectiveSize.height - thickness))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: straddle)
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
                // 按住空格时光标归画布管（一直是手），这儿别抢
                guard !canvas.isSpaceHeld else { return }
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

    /// 卡片上沿那个名字。**已选中时再点一下就能改名**（Finder 那种「点、停、再点」），
    /// 不是双击 —— 双击在画布上是别的操作，而且同一个视图上单击和双击并存会
    /// 让单击等 0.3 秒判连击（交接文档第 34 条）。
    ///
    /// 改完连磁盘文件名、素材名、时间轴上引用同一素材的片段一起变（素材是唯一真相源）。
    /// 镜像/旋转那类不进素材库的产物没有 assetID，只改卡片自己显示的名字
    @ViewBuilder
    private var nameLabel: some View {
        if isRenaming {
            TextField("", text: $editName)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .focused($nameFieldFocused)
                .onAppear { nameFieldFocused = true }
                .onSubmit { commitRename() }
                .onExitCommand { isRenaming = false }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.14)))
                .frame(maxWidth: effectiveSize.width - 24)
        } else {
            Text(node.displayName.isEmpty ? node.kind.label : node.displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                // 命中区按标签行的整块给，只按文字宽度的话得精确点在字上才有反应
                .frame(height: Self.labelHeight - 4)
                .contentShape(Rectangle())
                // highPriority：这一行压在卡片的拖拽手势上，普通 tap 会被它抢走，
                // 表现就是「有时候能触发」
                .highPriorityGesture(TapGesture().onEnded {
                    if isSelected {
                        editName = node.displayName.isEmpty ? node.kind.label : node.displayName
                        isRenaming = true
                    } else {
                        // Finder 那套「点、停、再点」：第一下先选中卡片
                        canvas.selectedNodeID = node.id
                    }
                })
                .help(isSelected ? "点一下改名" : "")
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.displayName else { return }
        if let aid = node.assetID {
            // 一改全改：磁盘文件、素材名、所有引用它的片段和卡片
            project.renameAsset(id: aid, to: name)
        } else {
            // 没进素材库的产物（老画布里可能还有）：只改这张卡片自己显示的名字
            canvas.updateNode(id: node.id) { $0.displayName = name }
        }
    }

    /// 卡片出现时把要用的素材准备好：音频波形、时长、封面。
    /// 都是**读盘的活**，一律挪出主线程 —— 波形那套本身就是后台线程 + 超时兜底
    private func prepareMedia() {
        guard let url = node.mediaURL else { return }

        // 素材库里已经有这个文件、但卡片没记住它的 id：补上。
        // 波形和缩略图都按 assetID 存，认不上 id 就等于没缓存
        if node.assetID == nil, let a = project.mediaAssets.first(where: { $0.url == url }) {
            canvas.updateNode(id: node.id) { $0.assetID = a.id }
        }

        if node.kind == .audio {
            project.loadWaveform(assetID: waveformKey, url: url)
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

        if node.kind == .image, localCover == nil, project.mediaThumbnails[thumbKey] == nil {
            Task.detached {
                let img = NSImage(contentsOf: url)
                await MainActor.run { localCover = img }
            }
        }

        // 视频封面：产物不进素材库，没人替它抽帧了，这里按同一个 key 自己抽一帧。
        // `loadMediaThumbnail` 只往 `mediaThumbnails` 这个内存缓存里写，不碰素材库清单
        if node.kind == .video, project.mediaThumbnails[thumbKey] == nil {
            project.loadMediaThumbnail(assetID: thumbKey, url: url)
        }

        // 比例选了「原始」：读素材真实尺寸把卡片摆正。读盘所以是异步的，
        // `applyOriginalRatio` 里有 `originalSizeApplied` 挡着，只摆一次
        if node.ratio == CanvasNode.originalRatio, !node.originalSizeApplied {
            let kind = node.kind, nodeID = node.id
            Task {
                guard let natural = await CanvasNode.naturalSize(of: url, kind: kind) else { return }
                await MainActor.run { canvas.applyOriginalRatio(nodeID: nodeID, natural: natural) }
            }
        }
    }

    /// 视频卡片：鼠标进来自动播，出去就暂停（不是停止 —— 再进来接着放）。
    /// 只对视频，音频还是点中间那个按钮播
    private func autoPlayOnHover(_ inside: Bool) {
        guard node.kind == .video, node.hasContent, !node.isGenerating,
              let url = node.mediaURL else { return }
        if inside {
            // toggle 认 node.id：这张已经暂停在半路就接着放，别的卡片在放就换成这张。
            // 不能认 url —— 两张卡片完全可能指向同一个文件，纯按 url 判断的话
            // hover 一张会连带把另一张也标记成「正在播」
            if !player.isPlaying(node.id) { player.toggle(url, key: node.id) }
        } else if player.isPlaying(node.id) {
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
                let raw = CGSize(width: (value.location.x - value.startLocation.x) / canvas.zoom,
                                 height: (value.location.y - value.startLocation.y) / canvas.zoom)
                // 吸附：贴到别的卡片的边或中线上，同时给出要画的辅助线
                let snapped = canvas.snapOffset(draggingIDs: canvas.draggingNodeIDs, rawOffset: raw)
                dragOffset = snapped.offset
                canvas.snapGuides = snapped.guides
                canvas.draggingOffset = dragOffset   // 连线跟着卡片走
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                canvas.pushUndo()
                // 提交时要用**吸附后**的位移，不然松手会弹回没对齐的位置
                let raw = CGSize(width: (value.location.x - value.startLocation.x) / canvas.zoom,
                                 height: (value.location.y - value.startLocation.y) / canvas.zoom)
                let final = canvas.snapOffset(draggingIDs: canvas.draggingNodeIDs, rawOffset: raw).offset
                let dx = final.width
                let dy = final.height
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
                canvas.snapGuides = []
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
        // 裁剪产物进全局素材库，卡片挂上新素材的 id
        project.importFile(url)
        let asset = project.mediaAssets.first { $0.url == url }
        canvas.updateNode(id: node.id) {
            $0.mediaPath = url.path
            $0.assetID = asset?.id
            $0.size = size
        }
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
        // 源文件没了：盖一层提示 + 一颗重新关联按钮，跟素材库那边一个样。
        // 卡片本身不动 —— 文件找回来关联一下就恢复
        .overlay {
            if mediaMissing {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 18))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .foregroundColor(Color(hex: "#FF9230"))
                            Text("素材丢失")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#FF9230"))
                            Button { relinkMedia() } label: {
                                Text("重新关联…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                        }
                    )
                    .allowsHitTesting(true)
            }
        }
        .overlay {
            // 文本卡片的四边可以拖着改大小。
            // 热区**常驻**，不跟 hover 联动 —— 条件显示的话，热区是在鼠标到边缘、
            // 卡片 onHover 触发之后才出现的，等它出来鼠标早过去了，就是「一闪而过」
            if node.kind == .text { resizeEdges }
        }
        // hover 抬起来：投影要看得出来，才提示「这会儿可以直接拖」
        .shadow(color: .black.opacity(lifted ? 0.4 : 0),
                radius: lifted ? 24 : 0,
                y: lifted ? 12 : 0)
        // 悬浮按钮统一放卡片上方（文本没有底部控制栏，之前留在底部，
        // 现在跟图片/视频/音频统一到顶部）
        .overlay(alignment: .top) { floatingActions }
        // 播放控制栏：暂停、时间码、可拖进度条、静音，hover 才出，贴卡片底部
        .overlay(alignment: .bottom) { mediaControlBar }
    }

    /// 播放控制栏。只有视频/音频、有内容、算得出时长才有意义
    @ViewBuilder
    private var mediaControlBar: some View {
        if (isHovering || isDragging), node.kind == .video || node.kind == .audio,
           node.hasContent, !node.isGenerating, assetDuration > 0, let url = node.mediaURL {
            CanvasMediaControlBar(player: player, url: url, nodeID: node.id, duration: assetDuration,
                                  showsSeekBar: node.kind == .video)
        }
    }

    /// 卡片上的悬浮按钮。有内容且 hover 时才出 ——
    /// 空卡片中间已经有「上传 / 素材」两个入口了，再叠一层是重复
    /// 卡片底部的悬浮按钮：左下 +，右下换素材。
    /// 文本卡片没有素材可换，只留左下那个 +（下拉是字幕/标题文字）
    @ViewBuilder
    private var floatingActions: some View {
        if showsFloatingActions {
            HStack {
                // 上传 / 换素材统一挪左上角，+ 号挪右上角 —— 跟改动前左右对调
                if node.kind != .text {
                    HStack(spacing: 4) {
                        floatingButton(icon: "importFile", help: "从本地上传") {
                            NotificationCenter.default.post(name: .canvasNodeUpload, object: node.id)
                        }
                        floatingButton(icon: "folder", help: "从素材库选择") {
                            NotificationCenter.default.post(name: .canvasNodePickAsset, object: node.id)
                        }
                    }
                }

                Spacer()

                // 图片/视频/音频：@ 把这张卡片挂到当前打开的聊天框上
                // （连成参考 + 在提示词里插一个「@图1」这样的称呼）
                if node.kind != .text {
                    floatingButton(system: "at", help: "加到提示词里") {
                        NotificationCenter.default.post(name: .canvasNodeMention, object: node.id)
                    }
                }
                if node.kind == .text {
                    FloatingPlusButton(
                        items: [("添加到字幕", { NotificationCenter.default.post(name: .canvasNodeToSubtitle, object: node.id) }),
                                ("添加到标题文字", { NotificationCenter.default.post(name: .canvasNodeToTitle, object: node.id) })])
                } else {
                    FloatingPlusButton(
                        items: [("添加到 AI 参考", { NotificationCenter.default.post(name: .canvasNodeToReference, object: node.id) }),
                                ("添加到时间轴", { NotificationCenter.default.post(name: .canvasNodeToTimeline, object: node.id) })])
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

    /// SF Symbol 版的悬浮按钮（@ 这种项目图标里没有的）
    private func floatingButton(system: String, help: String,
                                action: @escaping () -> Void) -> some View {
        FloatingIconButton(systemIcon: system, help: help, action: action)
    }

    /// 文本卡片，编辑态和默认态**统一用 NSTextView 渲染**，不分两条路径。
    ///
    /// 之前默认态用 SwiftUI 的 `Text`、编辑态用 NSTextView，内边距对齐了之后
    /// 还是会「选中前后行数不一样」——两套排版引擎对同一字号的行高计算有细微
    /// 差异，卡片高度刚好卡在「能放下 8 整行 + 半行」时，`Text` 会为了不露出
    /// 裁一半的行，主动舍弃这半行并截断成省略号，NSTextView 配合滚动却能把
    /// 这半行画出来。只有统一成同一套引擎才能保证像素级一致
    private var textCard: some View {
        ZStack {
            // 生成中 / 失败：跟图片视频音频三种卡片同一套状态展示，只是之前漏了这一种
            if node.isGenerating || node.isWaiting {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(node.progressText ?? (node.isWaiting ? "等上游生成完" : "生成中…"))
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
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
                    retryButton
                }
            } else {
                CanvasTextEditor(
                    text: isEditingText
                        ? Binding(
                            get: { node.text },
                            set: { newValue in
                                // 一轮编辑压一个撤销点（不是每个字一个）
                                canvas.noteTextEdit(node.id)
                                canvas.updateNode(id: node.id) { $0.text = newValue }
                            })
                        // 默认态不接文字改动，空文本时顶一句提示语上去；
                        // 用独立的 .constant 绑定，不碰真实的 node.text
                        : .constant(node.text.isEmpty ? "文本" : node.text),
                    fontSize: node.fontSize,
                    // 粗体/斜体/下划线/删除线现在完全由 markdown 语法决定（工具栏
                    // 点 B/I/U/S 写的是 **/*/<u>/~~ 符号，不再写这几个字段了）。
                    // 编辑态显示的是纯源码，不该再叠一层整段样式 —— 这几个字段是
                    // markdown 改造前的遗留物，节点如果在改造前被点过对应按钮，
                    // 值会一直留在数据里，读出来就会在编辑态凭空多出下划线/加粗，
                    // 跟改动颜色这个操作本身毫无关系，只是同一次 setAttributes
                    // 顺带把它们也画出来了
                    bold: false,
                    italic: false,
                    underline: false,
                    strikethrough: false,
                    colorHex: node.text.isEmpty && !isEditingText ? "#FFFFFF" : node.textColorHex,
                    focused: isEditingText && textFocused,
                    isEditable: isEditingText,
                    // 提示语要比正文淡：labelSecondary(white 0.45) × 0.4 ≈ 0.18
                    textOpacity: node.text.isEmpty && !isEditingText ? 0.18 : 1.0,
                    // 默认态按 markdown 渲染（## 变标题字号、**text** 变粗体，符号
                    // 本身不显示）；编辑态给的是原始源码，用户要能看见、能改 # 和 **
                    renderMarkdown: !isEditingText,
                    // hover 才出滚动条、才能滚 —— 文字比卡片高时能看完整段内容
                    isHovering: isHovering,
                    // 工具栏（H1/B/I/U/S）改文字时靠它通知编辑器同步，
                    // 见 CanvasState.textEditRevision
                    syncRevision: canvas.textEditRevision,
                    // 工具栏靠光标位置决定改哪一行
                    onCaretMove: { canvas.textCaretLocation = $0 })
                    .padding(14)
                    // 默认态平时不接手势 —— 点击/拖动要穿透给卡片本体的 tap/drag
                    // 处理，不能被这层 NSTextView 截胡（不然点文本卡片会变成
                    // 「点了但没反应」）。hover 时放行，滚轮/拖滚动条才有地方接
                    .allowsHitTesting(isEditingText || isHovering)
            }
        }
    }

    /// 图片/视频卡片。有内容时画面**铺满整张卡**，不留边距
    private func mediaCard(placeholder: String) -> some View {
        ZStack {
            if node.kind == .video, node.hasContent,
               player.isCurrent(node.id), let p = player.player {
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
                            retryButton
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

    private var assetDuration: Double {
        if let id = node.assetID,
           let a = project.mediaAssets.first(where: { $0.id == id }), a.duration > 0 {
            return a.duration
        }
        return cachedDuration
    }



    /// 视频/音频卡片中央的播放按钮。播放器是单例，同时只响一个。
    /// 视频正在放的时候不显示 —— 那会儿画面自己在动，压个按钮在中间挡事
    @ViewBuilder
    private var playButton: some View {
        if node.hasContent, !node.isGenerating, let url = node.mediaURL,
           node.kind == .video || node.kind == .audio,
           // 播放中不显示 —— 视频是画面自己在动，音频有底部控制栏的暂停按钮，
           // 中间再压一个纯属重复
           !player.isPlaying(node.id) {
            Button { player.toggle(url, key: node.id) } label: {
                Image(nsImage: TimelineSVGIcon.load(player.isPlaying(node.id) ? "pause" : "play"))
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
            .help(player.isPlaying(node.id) ? "暂停" : "播放")
        }
    }

    /// 缩略图 / 波形缓存的 key。
    ///
    /// **不能只认 assetID** —— 画布产物（AI 生成、去背景、超分、分离音轨、裁剪、
    /// 镜像旋转）一律不进全局素材库，assetID 是 nil，只认它的话波形永远画不出来、
    /// 视频封面也是空的。`thumbKey` 会退到元素库那条记录的 id，
    /// 让卡片、元素库、聊天框参考区共用同一份缓存
    private var thumbKey: UUID {
        canvas.thumbKey(assetID: node.assetID, path: node.mediaPath, fallback: node.id)
    }

    /// 卡片算不算「素材丢失」：指着的文件不在了。
    /// 生成中不算 —— 那会儿本来就还没有文件
    private var mediaMissing: Bool {
        guard !node.isGenerating, !node.isWaiting, let path = node.mediaPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func relinkMedia() {
        canvasRelinkNode(node, canvas: canvas, project: project)
        localCover = nil
        // 关联完要**主动**把封面重新抽一遍。
        //
        // `prepareMedia` 只在卡片上屏时跑一次，这会儿早过去了 —— 缓存刚被清掉、
        // 又没人去生成，卡片就一直空着，非得重进画布或者 hover 播放才有画面。
        // 视图里的 `node` 还是关联前那份，得从画布取最新的
        guard let fresh = canvas.node(node.id), let url = fresh.mediaURL else { return }
        let key = canvas.thumbKey(assetID: fresh.assetID, path: fresh.mediaPath, fallback: fresh.id)
        project.mediaThumbnails.removeValue(forKey: key)
        switch fresh.kind {
        case .video:
            project.loadMediaThumbnail(assetID: key, url: url)
        case .image:
            Task.detached {
                let img = NSImage(contentsOf: url)
                await MainActor.run { localCover = img }
            }
        case .audio:
            project.waveformCache.removeValue(forKey: key)
            project.loadWaveform(assetID: key, url: url)
        case .text:
            break
        }
    }

    private var waveformKey: UUID { thumbKey }

    private var coverImage: NSImage? {
        guard !node.isGenerating else { return nil }
        if let thumb = project.mediaThumbnails[thumbKey] { return thumb }
        return localCover
    }

    /// 音频卡片。布局跟图片/视频一致：内容在上、按钮在下。
    /// 有素材时画波形 —— 复用时间轴那套 `AudioWaveformCanvas` 和同一份波形缓存
    /// 音频卡片。播放按钮在正中间，波形用时间轴音频轨那个绿色，
    /// 播放时叠一条黄色指示线跟着走
    private var audioCard: some View {
        ZStack {
            if node.isGenerating || node.isWaiting {
                // 音频卡片是矮横条，竖着摞「转圈 + 文字 + 停止」挤得放不下，
                // 改成横排一行
                HStack(spacing: 10) {
                    if let p = node.progress {
                        ProgressView(value: p).frame(width: 90)
                        Text("\(node.progressText ?? "处理中…")  \(Int(p * 100))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                            .lineLimit(1)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(node.progressText ?? "生成中…")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                            .lineLimit(1)
                    }
                    stopButton
                }
                .padding(.horizontal, 12)
            } else if let failure = node.failure {
                VStack(spacing: 6) {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                    retryButton
                }
            } else if node.hasContent {
                // 波形铺满卡片，播放按钮压在中间
                if let wave = project.waveformCache[waveformKey] {
                    // 时长优先用素材库那份；没有就用波形自己带的 ——
                    // 传 0.1 进去等于只画开头那一瞬，画面上什么都看不见
                    AudioWaveformCanvas(waveData: wave, trimStart: 0,
                                        clipDuration: assetDuration > 0 ? assetDuration
                                                                        : wave.totalDuration,
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
        if player.isCurrent(node.id), player.duration > 0, assetDuration > 0 {
            CanvasPlayhead(clock: player.clock, duration: assetDuration) { player.seek(to: $0) }
        }
    }

    /// 失败后的「重试」。三种卡片共用一个 —— 之前各写各的纯文字，
    /// 混在同样是橙色的失败原因下面，看着像第二行说明而不是能点的东西
    private var retryButton: some View {
        HStack(spacing: 8) {
            // 只有「重试」的话，这个失败态就退不出去了 —— 提示词写不对、
            // 或者压根不想再生成时，卡片会一直卡在红字上。取消 = 清掉失败状态，
            // 回到空卡片，该上传上传、该重写提示词重写
            CanvasRetryButton(title: "取消", filled: false) {
                canvas.updateNode(id: node.id) { $0.failure = nil }
            }
            CanvasRetryButton(title: "重试") {
                NotificationCenter.default.post(name: .canvasNodeRetry, object: node.id)
            }
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
                // 用 effectiveSize 不用 node.size —— 拖左右边缘调整大小时，
                // model 要等松手才更新，这里若读 node.size，+ 号在整个拖拽
                // 过程里都不会挪窝，等松手才「唰」地跳到新位置
                .offset(x: edge == .leading
                        ? -(effectiveSize.width / 2 + Self.plusGutter / 2)
                        : (effectiveSize.width / 2 + Self.plusGutter / 2),
                        // 文本卡片底部多留了 edgeStraddle 高度，VStack 跟着变高，
                        // ZStack 的几何中心被往下拉了半份 —— 减掉这一半才能让
                        // + 号继续落在卡片纵向中点，不随这份余量往下漂
                        y: Self.labelHeight / 2 - bottomResizeMargin / 2)
                // 只管点击弹菜单。拉线交给卡片边缘上的连接点 ——
                // 同一个控件既接 tap 又接 drag，轻点会被判成微小拖拽，
                // 两种意图老打架
                .onTapGesture { onPlusTap(edge) }
        }
    }

    /// 这一侧接着线没有。右边看出边（这张卡片是谁的上游），左边看入边
    private func isConnected(_ edge: Edge) -> Bool {
        edge == .trailing ? canvas.edges.contains { $0.from == node.id }
                          : canvas.edges.contains { $0.to == node.id }
    }

    /// 卡片左右边缘线上的连接点：**拖它拉线**。
    ///
    /// 跟 + 号分工明确：+ 在卡片外的空当里，点它弹菜单；圆点贴在卡片边框上，
    /// 拖它连到别的卡片。位置贴边也是在说明「线是从这儿出去的」
    @ViewBuilder
    private func connectorDot(_ edge: Edge) -> some View {
        if isHovering || canvas.pendingEdgeFrom == node.id {
            // 这一侧连着线才实心，空着就是个空心圈 —— 一眼看出哪边已经接上了
            let connected = isConnected(edge)
            Circle()
                .fill(connected ? Color.accent : Color(red: 0.19, green: 0.19, blue: 0.20))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(connected ? Color.black.opacity(0.35) : Color.accent,
                                               lineWidth: 1.5))
                // 视觉 9pt、热区 20pt —— 只按视觉大小做热区根本抓不住
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                // 贴在卡片左右边框的中点上。y 的补偿跟 + 号同理（见上面）
                .offset(x: edge == .leading ? -effectiveSize.width / 2 : effectiveSize.width / 2,
                        y: Self.labelHeight / 2 - bottomResizeMargin / 2)
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
    /// 把这张卡片加到当前聊天框：连成参考并在提示词里插一个「@图1」
    static let canvasNodeMention = Notification.Name("canvasNodeMention")
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
    /// 素材被移出素材库。`userInfo`：`assetID` + `path`（素材当时的文件路径）。
    /// **每个窗口的画布各自监听** —— 素材库全 app 一份，画布是每窗口一份
    static let assetRemovedFromLibrary = Notification.Name("assetRemovedFromLibrary")
    /// 素材被撤销恢复了，跟着删掉的卡片要插回来。`userInfo`：`assetID`
    static let assetRestoredToLibrary = Notification.Name("assetRestoredToLibrary")
    /// 某个素材文件改了名或换了位置。`userInfo`：`old` / `new` 两个路径字符串。
    /// 画布上引用它的卡片要跟着换路径和显示名，否则会显示成素材丢失
    static let mediaFileRelocated = Notification.Name("mediaFileRelocated")
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
        // 自绘按钮上 .help 时灵时不灵，走 ChatTooltip 那条（它自己不抢鼠标）
        .overlay { ChatTooltip(text: help) }
    }
}


/// 卡片上的圆形悬浮按钮。hover 变亮，配气泡提示
private struct FloatingIconButton: View {
    var icon: String = ""
    /// 项目图标库里没有的（比如 @）走 SF Symbol
    var systemIcon: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Image(nsImage: SidebarSVGIcon.load(icon, size: 12))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                }
            }
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.8 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.35 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 自绘按钮上 .help 时灵时不灵，走 ChatTooltip 那条（它自己不抢鼠标）
        .overlay { ChatTooltip(text: help) }
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


/// 时间码格式化。文件级函数 —— 下面两个小视图和卡片本体都要用
func canvasTimeText(_ d: Double) -> String {
    guard d.isFinite, d >= 0 else { return "--:--" }
    return String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
}

/// 播放位置指示线。
///
/// **单独一个视图订阅时钟**：位置每 30ms 变一次，让整张卡片跟着重算的话，
/// 画布上卡片一多就是持续掉帧（每秒 33 次 × 卡片数）
private struct CanvasPlayhead: View {
    @ObservedObject var clock: PlayheadClock
    let duration: Double
    var onSeek: (Double) -> Void

    /// 线两侧各留这么宽的拖拽热区。**不能整卡片宽度都能拖** —— 那样会跟
    /// 「拖动整张卡片挪位置」抢手势，音频卡片就没法正常拖动了。
    /// 只在线本身附近才响应，用户说的是「拖动黄线」，不是「点哪都能跳转」
    /// （点哪都能跳转是底部新加的进度条负责的）
    private static let hit: CGFloat = 10

    /// 手势按下那一刻的线位置，整个拖动过程用它做基准。
    ///
    /// **不能每帧都拿「当前重新算出来的 x」当基准** —— x 是跟着 clock.time 走的，
    /// 而 clock.time 正是被 onSeek 改掉的那个值：上一次 onChanged 调了 onSeek，
    /// 这一帧重新渲染出的 x 已经把那次结果算进去了，这时候再加上
    /// 「从按下那一刻算起的累积 translation」，等于把同一段位移重复计了一次，
    /// 拖一点点线就飞出去，跟手感完全对不上
    @State private var dragBaseX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let ratio = min(1, max(0, clock.time / duration))
            let x = geo.size.width * ratio
            ZStack {
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: 1)
                    .position(x: x, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                Color.white.opacity(0.001)
                    .frame(width: Self.hit * 2)
                    .position(x: x, y: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if dragBaseX == nil { dragBaseX = x }
                                let base = dragBaseX ?? x
                                let newX = min(geo.size.width, max(0, base + v.translation.width))
                                onSeek(newX / geo.size.width * duration)
                            }
                            .onEnded { _ in dragBaseX = nil }
                    )
            }
        }
    }
}

/// 播放时右上角走字的时间码。同样只有它自己订阅时钟
private struct CanvasPlayTime: View {
    @ObservedObject var clock: PlayheadClock
    let total: Double

    var body: some View {
        Text("\(canvasTimeText(clock.time)) / \(canvasTimeText(total))")
    }
}

/// 视频/音频卡片底部的播放控制栏。
/// 图标复用预览区/时间轴那套（play/pause、audioSpeaker/mute），
/// 不新画一套，跟软件其它地方长一个样
///
/// 视频：暂停 + 时间码 + 可拖进度条 + 静音。
/// 音频：**没有进度条** —— 波形图上已经有条可拖的黄线担着 seek 这件事，
/// 控制栏里再放一条是重复；时间码改居中显示在暂停和静音中间，就是「卡片下边中间」
private struct CanvasMediaControlBar: View {
    @ObservedObject var player: AIInlinePlayer
    let url: URL
    let nodeID: UUID
    let duration: Double
    var showsSeekBar: Bool = true

    private var isCurrent: Bool { player.isCurrent(nodeID) }

    private var timeText: some View {
        Group {
            if isCurrent {
                CanvasPlayTime(clock: player.clock, total: duration)
            } else {
                Text("\(canvasTimeText(0)) / \(canvasTimeText(duration))")
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundColor(.white)
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { player.toggle(url, key: nodeID) } label: {
                Image(nsImage: TimelineSVGIcon.load(player.isPlaying(nodeID) ? "pause" : "play"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 10, height: 10)
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying(nodeID) ? "暂停" : "播放")

            if showsSeekBar {
                timeText
                CanvasSeekBar(isCurrent: isCurrent, clock: player.clock, duration: duration) {
                    if !isCurrent { player.toggle(url, key: nodeID) }
                    player.seek(to: $0)
                }
            } else {
                Spacer(minLength: 0)
                timeText
                Spacer(minLength: 0)
            }

            Button { player.toggleMute() } label: {
                Image(nsImage: SidebarSVGIcon.load(player.isMuted ? "mute" : "audioSpeaker", size: 12))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(player.isMuted ? "取消静音" : "静音")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
        // 只裁**下面**两个角，跟卡片圆角同半径。
        //
        // 这条是 `.overlay(alignment: .bottom)` 挂在卡片的 clipShape **之后**的，
        // 不受卡片裁剪管 —— 那层黑色渐变是直角矩形，卡片圆角处就露出两个黑角。
        // 上面两角必须保持直角：它在卡片中间，切圆了会跟画面之间裂开一道缝
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Self.cardCornerRadius,
                                          bottomTrailingRadius: Self.cardCornerRadius))
    }

    /// 跟卡片的圆角保持一致（`CanvasNodeView.card` 里那个 24）
    private static let cardCornerRadius: CGFloat = 24
}

/// 可拖动进度条。点哪就跳到哪，跟拖播放线那种「只在线附近」不同 ——
/// 这条整条宽度都是热区，这是控制栏里主要的 seek 入口
private struct CanvasSeekBar: View {
    let isCurrent: Bool
    @ObservedObject var clock: PlayheadClock
    let duration: Double
    var onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragRatio: Double = 0

    private var ratio: Double {
        if isDragging { return dragRatio }
        guard isCurrent, duration > 0 else { return 0 }
        return min(1, max(0, clock.time / duration))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Color.white.opacity(0.95))
                    .frame(width: geo.size.width * ratio)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)   // 视觉细一条，热区撑满纵向好点中
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        let r = min(1, max(0, v.location.x / geo.size.width))
                        dragRatio = r
                        onSeek(r * duration)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 14)
    }
}

/// 失败卡片上的「重试」。有底色的实心小按钮 —— 纯文字版跟上面橙色的
/// 失败原因混在一起，看着像第二行说明文字，不像能点的
private struct CanvasRetryButton: View {
    var title: String = "重试"
    /// 实心（主操作）还是描边（次要操作）
    var filled: Bool = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(filled ? .black : Color.labelPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background {
                    if filled {
                        Capsule().fill(Color.accent.opacity(hovering ? 1 : 0.9))
                    } else {
                        Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.10))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 重新关联（卡片上的按钮 / 卡片右键菜单 共用）

/// 给一张卡片重新指定素材文件。
///
/// **跟元素库那个入口走同一条路，效果完全一样**：素材库来的素材走 `ProjectState`
/// 那套（时间轴片段一起换），画布产物走 `CanvasState`（元素库记录 + 所有引用它的
/// 卡片 + 撤销栈一起重指）。两边都要清掉旧缩略图缓存，否则显示的还是关联前那张
@MainActor
func canvasRelinkNode(_ node: CanvasNode, canvas: CanvasState, project: ProjectState) {
    guard let oldURL = node.mediaURL else { return }
    let shownName = node.displayName.isEmpty ? oldURL.lastPathComponent : node.displayName
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "请选择「\(shownName)」的新位置"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let key = canvas.thumbKey(assetID: node.assetID, path: node.mediaPath, fallback: node.id)
    if let aid = node.assetID {
        // 素材是唯一真相源：这里一改，素材库、时间轴片段、其它画布卡片都跟着好
        project.relinkAsset(id: aid, newURL: url)
        canvas.repointNodes(from: oldURL.path, to: url.path)
    } else {
        // 镜像/旋转那类不进素材库的产物：只能改这张卡片自己指向哪儿
        canvas.repointNodes(from: oldURL.path, to: url.path)
        canvas.renameNodeLabels(path: url.path, to: url.lastPathComponent)
    }
    project.mediaThumbnails.removeValue(forKey: key)
}
