import SwiftUI
import Combine
import AVKit
import AVFoundation

private let kPreviewInset: CGFloat = 8

struct PlayerView: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.windowID) private var windowID
    @StateObject private var ctrl = PlayerController()
    @State private var hoveringPlayer = false

    /// 时间轴上是否有任何可见的视频或图片片段
    private var hasAnyVisibleClips: Bool {
        let hasVideo = project.videoTracks.contains { $0.isVisible && !$0.clips.isEmpty }
        let hasImage = project.imageTracks.contains { $0.isVisible && !$0.clips.isEmpty }
        let hasCompoundVideo = project.compoundTracks.contains { $0.isVisible && !$0.clips.isEmpty && $0.clips.contains { !$0.videoTracks.flatMap(\.clips).isEmpty } }
        return hasVideo || hasImage || hasCompoundVideo
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.panelBg
                ZStack {
                    GeometryReader { geo in
                        let rs = project.previewRenderSize
                        let fitScale = min(geo.size.width / max(rs.width, 1),
                                           geo.size.height / max(rs.height, 1))
                        let fitW = rs.width * fitScale
                        let fitH = rs.height * fitScale
                        // 画布底：画面实际会落在这个框里
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black)
                            if project.playerItem == nil {
                                VStack(spacing: min(fitW, fitH) * 0.045) {
                                    Image(nsImage: SidebarSVGIcon.load("video",
                                                                       size: min(fitW, fitH) * 0.22))
                                        .renderingMode(.template)
                                    Text("安全边框")
                                        .font(.system(size: min(fitW, fitH) * 0.075, weight: .semibold))
                                }
                                .foregroundColor(Color.labelSecondary.opacity(0.22))
                            }
                        }
                        .frame(width: fitW, height: fitH)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    .allowsHitTesting(false)
                    AVPlayerNSView(
                        player: ctrl.player,
                        renderAspect: project.previewRenderSize.width / max(project.previewRenderSize.height, 1))
                    GeometryReader { geo in
                        let rs = project.previewRenderSize
                        let fitScale = min(geo.size.width / max(rs.width, 1),
                                           geo.size.height / max(rs.height, 1))
                        let fitW = rs.width * fitScale
                        let fitH = rs.height * fitScale
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture {
                                project.clearClipSelections(); project.selectedClipIDs.removeAll()
                                if project.editingTextClipID != nil { project.editingTextClipID = nil }
                            }
                        OverlayStack()
                            .frame(width: fitW, height: fitH)
                            .clipped()
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        ZStack {
                            VideoTransformOverlay()
                            ImageTransformOverlay()
                            TextTransformOverlay()
                            ShapeTransformOverlay()
                            PenDrawingOverlay()
                            PenEditOverlay()
                            // 特效的中心点。选中一段带中心点的特效才出现
                            if let fx = project.selectedEffectClip, fx.kind.usesCenter {
                                EffectCenterHandle(clip: fx,
                                                   canvas: CGSize(width: fitW, height: fitH),
                                                   onMove: { x, y in
                                    project.updateEffectClip(id: fx.id, live: true) {
                                        $0.centerX = x; $0.centerY = y
                                    }
                                }, onEnd: {
                                    project.pushUndoThrottled()
                                    project.rebuildTimelinePreview()
                                })
                                .frame(width: fitW, height: fitH)
                                .coordinateSpace(name: EffectCenterHandle.space)
                            }
                        }
                        .frame(width: fitW, height: fitH)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    // 裁剪/变换手柄是贴着**素材边界**画的，素材被拖出或放大超出画面时
                    // 手柄跟着跑到画面外 —— SwiftUI 默认不裁剪子视图的绘制，于是那些边框
                    // 会一路画到素材区、属性区、时间轴上去。这里按预览区裁掉。
                    //
                    // 裁在 GeometryReader 这层而不是上面那个 fitW/fitH 的 frame 上：
                    // 后者会把贴着画面边缘的手柄切掉一半，而黑边区域本来就该能显示手柄
                    .clipped()
                }
                .padding(EdgeInsets(top: kPreviewInset, leading: kPreviewInset, bottom: 0, trailing: kPreviewInset))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if hoveringPlayer {
                    Text(project.projectName + (project.isSaved ? "（已保存）" : ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                    .padding(.horizontal, 8)
                    // 往上提 12pt：原来是 8，负值让它探进预览区上边缘之外
                    .padding(.top, -4)
                    .transition(.opacity)
                }
            }
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.18)) {
                    hoveringPlayer = inside
                }
            }

            PreviewToolbar(ctrl: ctrl)
        }
        .onChange(of: project.playerItem) {
            let seekTo = clock.pendingSeekTime ?? clock.currentTime
            clock.pendingSeekTime = nil
            ctrl.setItem(project.playerItem, seekTo: seekTo)
        }
        // User-initiated seek (playhead/ruler drag) → tell AVPlayer to follow.
        .onChange(of: clock.seekRequest) {
            ctrl.seek(to: clock.currentTime)
        }
        .onChange(of: clock.refreshSeekRequest) {
            // AVPlayer seek 到**同一个** CMTime 不会触发 compositor 重绘，
            // 所以每次都得给个不一样的时刻。
            //
            // **不能正负交替**：那样连续拖滑块时画面会在两个相差 1/300 秒的时刻
            // 之间来回横跳，看着就是抖。改成始终朝同一个方向、在 1/600 秒内
            // 取四档循环 —— 相邻两次的差最多 1/2400 秒，远小于一帧，画面稳得住
            let step = (1.0 / 2400.0) * Double(clock.refreshSeekRequest % 4 + 1)
            ctrl.seek(to: clock.currentTime + step)
        }
        .onAppear {
            // 绑定回调：Timer 驱动 currentTime，不依赖 AVPlayer
            ctrl.onTime     = { t in clock.currentTime = t }
            ctrl.getTime    = { clock.currentTime }
            ctrl.getDuration = { clock.duration }
            // 关窗时由 WindowManager 显式停播。**不能挂 onDisappear**——
            // 那个在视图重建时也会触发，正播着会被误停
            WindowManager.shared.setStopPlayback({ [weak ctrl, weak project] in
                ctrl?.stopAndRelease()
                // 关窗时把这个项目起的 ffmpeg 一并收掉（倒放/变速/转码）——
                // 子进程不会跟着窗口走，不然关了窗它还在后台跑完
                project?.killMyFFmpeg()
            }, for: windowID)
        }
        // 走 clock 而不是通知：clock 是本窗口的，不会被别的窗口的空格触发
        .onChange(of: clock.togglePlaybackRequest) { _, _ in
            ctrl.toggle()
        }
    }
}

// MARK: - AVPlayerView

private class VideoLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    /// 画布比例，等于 previewRenderSize 的比例。合成层已按该尺寸输出，
    /// 这里只需如实显示：画布多大画面就多大，素材超出画布的部分在合成时就已被裁掉
    var renderAspect: CGFloat? {
        didSet {
            guard renderAspect != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        // 圆角跟安全边框一致，画面铺满画布时四角才对得上
        playerLayer.cornerRadius = 8
        playerLayer.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let aspect = renderAspect, aspect > 0, bounds.width > 0, bounds.height > 0 {
            // 与黑底框、选择框共用的内接矩形
            let cur = bounds.width / bounds.height
            var w = bounds.width, h = bounds.height
            if cur > aspect { w = bounds.height * aspect } else { h = bounds.width / aspect }
            playerLayer.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                                       width: w, height: h)
        } else {
            playerLayer.frame = bounds
        }
        playerLayer.videoGravity = .resizeAspect
        CATransaction.commit()
    }
}

private struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer
    var renderAspect: CGFloat? = nil

    func makeNSView(context: Context) -> VideoLayerView {
        let v = VideoLayerView()
        v.playerLayer.player = player
        v.renderAspect = renderAspect
        return v
    }
    func updateNSView(_ v: VideoLayerView, context: Context) {
        v.playerLayer.player = player
        v.renderAspect = renderAspect
    }
}

// MARK: - Overlay Stack（按 overlayTrackOrder 统一渲染字幕/文字/图形）

private struct OverlayStack: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @State private var editText: String = ""
    @State private var dragStart: [UUID: CGPoint] = [:]
    /// 叠加层实际画多大。**特效的尺寸参数要按它换算，不能按渲染分辨率** ——
    /// CALayer.filters 作用在这个显示尺寸的图层上，拿 1920 算出来的半径
    /// 套到 800 宽的画布上，糊的程度会差一倍多
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        // 图层清单跟导出共用（含未登记复合轨道的兜底，见 overlayLayersBottomUp）。
        // 那边是从底到顶依次合成，这边靠 zIndex 叠，所以序号越大越靠上
        let layersBottomUp = project.overlayLayersBottomUp

        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    if project.editingTextClipID != nil { commitTextEdit() }
                    project.clearClipSelections()
                    project.selectedClipIDs.removeAll()
                }
                .zIndex(-1)

            // 有效果轨道时，画面**整帧**由合成器出（叠加层也在里面），
            // 这层只留透明的命中区接鼠标 —— 再画一遍内容就会出现
            // 「合成器扭一套、SwiftUI 扭另一套」两份对不上的画面
            // **合成器只有在有视频垫底时才跑**。纯图片项目（时间轴上一条视频都没有）
            // 走这条就成了：叠加层这边把自己藏了交给合成器，合成器却根本没启动 ——
            // 画面全黑，看着像「滤镜对图片不生效」，其实是图片没了
            if hasEffectLayer(layersBottomUp), hasVideoAtPlayhead {
                ForEach(Array(layersBottomUp.enumerated()), id: \.element.trackID) { i, ref in
                    layerView(ref)
                        .opacity(0)          // 内容归合成器画，这里只要命中区
                        .zIndex(Double(i))
                }
            } else if hasEffectLayer(layersBottomUp) {
                // 没视频垫底、又有效果轨：自己跑一遍**合成器那套**渲染，出一张整帧图。
                //
                // 不走 overlayChain 了 —— 它靠把视图重塞进新的 NSHostingView 来挂
                // CALayer.filters，实测滤镜、调节、特效三种全是黑屏（内容整个没了）。
                // 直接拿 ColorCompositor.drawOverlays 出图，跟有视频时是同一份代码，
                // 效果也就天然一致
                ComposedOverlayFrame(renderSize: project.previewRenderSize,
                                     time: clock.currentTime,
                                     contentKey: project.overlayContentKey(at: clock.currentTime),
                                     effectKey: project.effectContentKey(at: clock.currentTime))
                // 内容归上面那张图，这里只留命中区接鼠标
                ForEach(Array(layersBottomUp.enumerated()), id: \.element.trackID) { i, ref in
                    layerView(ref)
                        .opacity(0)
                        .zIndex(Double(i))
                }
            } else if false {
                // 有滤镜：**从底往上一层层套**。滤镜只作用于排在它下面的图层，
                // 所以走到滤镜那层时，把「已经堆好的部分」整个套一层效果再往上叠
                overlayChain(layersBottomUp)
            } else {
                ForEach(Array(layersBottomUp.enumerated()), id: \.element.trackID) { i, ref in
                    layerView(ref).zIndex(Double(i))
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { canvasSize = g.size }
                .onChange(of: g.size) { _, v in canvasSize = v }
        })
    }

    @ViewBuilder
    private func imageTrackView(trackID: UUID) -> some View {
        GeometryReader { geo in
            if let track = project.imageTracks.first(where: { $0.id == trackID }),
               track.isVisible,
               let clip = track.clips.first(where: { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }) {
                let imgRect = imageRenderRect(clip: clip, viewSize: geo.size)
                ImageLayerView(clip: clip, viewSize: geo.size, videoSize: project.previewRenderSize)
                    .allowsHitTesting(false)
                if imgRect.width > 0, imgRect.height > 0 {
                    if project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id) {
                        Rectangle().stroke(Color.accent, lineWidth: 1.5)
                            .frame(width: imgRect.width, height: imgRect.height)
                            .rotationEffect(.degrees(Double(clip.rotation)))
                            .position(x: imgRect.midX, y: imgRect.midY)
                            .allowsHitTesting(false)
                    }
                    Color.clear
                        .frame(width: imgRect.width, height: imgRect.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if project.editingTextClipID != nil { commitTextEdit() }
                            if NSEvent.modifierFlags.contains(.shift) {
                                project.shiftCycleOverlapping(clip.id)
                            } else {
                                // 点重叠处按叠放顺序轮换，压在下面的也点得到
                                project.cycleSelectOverlapping(clip.id)
                            }
                        }
                        .position(x: imgRect.midX, y: imgRect.midY)
                }
            }
        }
    }

    /// 有没有效果类轨道。有的话整帧交给合成器出
    /// 这一刻有没有视频画面垫底。没有的话合成器不会跑，效果得自己在这层套
    private var hasVideoAtPlayhead: Bool {
        let t = clock.currentTime
        if project.videoTracks.contains(where: { tr in
            tr.isVisible && tr.clips.contains { $0.startTime <= t && $0.endTime > t }
        }) { return true }
        // 复合片段里可能包着视频，那种也是合成器出画面
        return project.compoundTracks.contains { tr in
            tr.isVisible && tr.clips.contains { $0.startTime <= t && $0.endTime > t }
        }
    }

    private func hasEffectLayer(_ layers: [ProjectState.OverlayTrackRef]) -> Bool {
        layers.contains {
            switch $0 {
            case .filter, .adjust, .effect: return true
            default: return false
            }
        }
    }

    /// 从底到顶把图层叠起来。遇到滤镜就把下面那坨整个套一层
    private func overlayChain(_ layers: [ProjectState.OverlayTrackRef]) -> AnyView {
        layers.reduce(AnyView(Color.clear)) { acc, ref in
            if case .adjust(let id) = ref {
                let clips = project.adjustTracks.first { $0.id == id }
                    .map { t in
                        t.isVisible
                        ? t.clips.filter { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }
                        : []
                    } ?? []
                let fs = clips.flatMap(\.adjust.ciFilters)
                guard !fs.isEmpty else { return acc }
                return AnyView(CILayerEffect(filters: fs) {
                    acc.environmentObject(project).environmentObject(clock)
                })
            }
            if case .effect(let id) = ref {
                let clips = project.effectTracks.first { $0.id == id }
                    .map { t in
                        t.isVisible
                        ? t.clips.filter { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }
                        : []
                    } ?? []
                guard !clips.isEmpty else { return acc }
                let disp = canvasSize == .zero ? project.previewRenderSize : canvasSize
                return AnyView(acc.modifier(OverlayEffectFilter(
                    clips: clips, displaySize: disp,
                    renderSize: project.previewRenderSize,
                    contentKey: project.overlayContentKey(at: clock.currentTime),
                    isPlaying: clock.isPlaying)))
            }
            if case .filter(let id) = ref {
                let clips = project.filterTracks.first { $0.id == id }
                    .map { t in
                        t.isVisible
                        ? t.clips.filter { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }
                        : []
                    } ?? []
                return AnyView(acc.modifier(OverlayFilterEffect(clips: clips)))
            }
            return AnyView(ZStack {
                acc
                layerView(ref)
            })
        }
    }

    @ViewBuilder
    private func layerView(_ ref: ProjectState.OverlayTrackRef) -> some View {
        // 有滤镜/调节/特效轨道时，叠加层已经由合成器画进画面了
        // （`overlayDrawnByCompositor`）—— 这儿再画一份就是两层字幕/文字叠在一起。
        // 没有效果轨道时合成器不管叠加层，仍旧走下面这条
        if project.overlayDrawnByCompositor {
            EmptyView()
        } else {
            switch ref {
            case .image(let id):    imageTrackView(trackID: id)
            case .subtitle(let id): subtitleTrackView(trackID: id)
            case .text(let id):     textTrackView(trackID: id)
            case .shape(let id):    shapeTrackView(trackID: id)
            case .compound(let id): compoundOverlayView(trackID: id)
            case .filter, .adjust, .effect:
                EmptyView()   // 滤镜/调节/特效在 overlayChain 里单独处理
            }
        }
    }

    @ViewBuilder
    private func textTrackView(trackID: UUID) -> some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            if let track = project.textTracks.first(where: { $0.id == trackID }),
               track.isVisible,
               let clip = track.clips.first(where: { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }) {
                if project.editingTextClipID == clip.id {
                    TextEditField(text: $editText, clip: clip, scale: scale, onCommit: { commitTextEdit() })
                        .fixedSize()
                        .background(GeometryReader { g in
                            Color.clear.onChange(of: g.size) { _ in project.textClipViewSizes[clip.id] = g.size }
                                .onAppear { project.textClipViewSizes[clip.id] = g.size }
                        })
                        .overlay(RoundedRectangle(cornerRadius: 4 * scale).strokeBorder(Color.accent, lineWidth: 1.5))
                        .onDisappear {
                            project.updateTextClip(id: clip.id) { $0.text = editText }
                        }
                        .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                } else {
                    TextLabel(clip: clip, scale: scale, selected: false)
                        .overlay(
                            project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id)
                            ? Rectangle().stroke(Color.accent, lineWidth: 1.5) : nil
                        )
                        .background(GeometryReader { g in
                            Color.clear.onChange(of: g.size) { _ in project.textClipViewSizes[clip.id] = g.size }
                                .onAppear { project.textClipViewSizes[clip.id] = g.size }
                        })
                        .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if dragStart.isEmpty {
                                let multi = project.selectedClipIDs.contains(clip.id) && project.selectedClipIDs.count > 1
                                if multi {
                                    for id in project.selectedClipIDs {
                                        if let c = shapeByID(id) { dragStart[id] = CGPoint(x: c.posX, y: c.posY) }
                                        else if let tc = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) { dragStart[id] = CGPoint(x: tc.posX, y: tc.posY) }
                                        else if let ic = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) { dragStart[id] = CGPoint(x: ic.offsetX, y: ic.offsetY) }
                                    }
                                } else {
                                    if project.selectedTextClipID != clip.id { selectTextExclusive(clip.id) }
                                    dragStart[clip.id] = CGPoint(x: clip.posX, y: clip.posY)
                                }
                            }
                            let dx = v.translation.width / geo.size.width
                            let dy = v.translation.height / geo.size.height
                            for (id, s) in dragStart {
                                if project.shapeTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                    project.updateShapeClip(id: id) { $0.posX = min(1, max(0, s.x + dx)); $0.posY = min(1, max(0, s.y + dy)) }
                                } else if project.textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                    project.updateTextClip(id: id) { $0.posX = min(1, max(0, s.x + dx)); $0.posY = min(1, max(0, s.y + dy)) }
                                } else if project.imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                    project.updateImageClip(id: id) { $0.offsetX = s.x + dx; $0.offsetY = s.y + dy }
                                }
                            }
                        }.onEnded { _ in dragStart = [:] })
                        .onTapGesture(count: 2) {
                            editText = clip.text
                            project.editingTextClipID = clip.id
                            selectTextExclusive(clip.id)
                        }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.shift) {
                                project.shiftCycleOverlapping(clip.id)
                            } else {
                                project.cycleSelectOverlapping(clip.id)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func shapeTrackView(trackID: UUID) -> some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            if let track = project.shapeTracks.first(where: { $0.id == trackID }),
               track.isVisible,
               let clip = track.clips.first(where: { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }) {
                ShapeClipView(clip: clip, scale: scale,
                              selected: project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id))
                    .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStart.isEmpty {
                                    let multi = project.selectedClipIDs.contains(clip.id) && project.selectedClipIDs.count > 1
                                    if multi {
                                        for id in project.selectedClipIDs {
                                            if let c = shapeByID(id) { dragStart[id] = CGPoint(x: c.posX, y: c.posY) }
                                            else if let tc = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) { dragStart[id] = CGPoint(x: tc.posX, y: tc.posY) }
                                            else if let ic = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) { dragStart[id] = CGPoint(x: ic.offsetX, y: ic.offsetY) }
                                        }
                                    } else {
                                        if project.selectedShapeClipID != clip.id { selectShapeExclusive(clip.id) }
                                        if let c = shapeByID(clip.id) { dragStart[clip.id] = CGPoint(x: c.posX, y: c.posY) }
                                    }
                                }
                                let dx = v.translation.width / geo.size.width
                                let dy = v.translation.height / geo.size.height
                                for (id, s) in dragStart {
                                    if project.shapeTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                        project.updateShapeClip(id: id) { $0.posX = min(1, max(0, s.x + dx)); $0.posY = min(1, max(0, s.y + dy)) }
                                    } else if project.textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                        project.updateTextClip(id: id) { $0.posX = min(1, max(0, s.x + dx)); $0.posY = min(1, max(0, s.y + dy)) }
                                    } else if project.imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                                        project.updateImageClip(id: id) { $0.offsetX = s.x + dx; $0.offsetY = s.y + dy }
                                    }
                                }
                            }
                            .onEnded { _ in dragStart = [:] }
                    )
                    .onTapGesture(count: 2) {
                        if clip.type == .pen { project.penEditingClipID = clip.id }
                    }
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.shift) {
                            project.shiftCycleOverlapping(clip.id)
                        } else {
                            project.cycleSelectOverlapping(clip.id)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func subtitleTrackView(trackID: UUID) -> some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            if let track = project.subtitleTracks.first(where: { $0.id == trackID }),
               track.isVisible,
               let clip = track.clips.first(where: { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }) {
                let style = track.subtitleStyle ?? SubtitleStyle()
                let text = style.mergeLineBreaks ? SubtitleOverlay.mergeBreaks(clip.text) : clip.text
                let bottomPad = subtitleBottomPad(trackID: trackID, geoW: geo.size.width,
                                                  geoH: geo.size.height, scale: scale,
                                                  time: clock.currentTime)
                SubtitleLabel(text: text, style: style, scale: scale)
                    .frame(maxWidth: geo.size.width * style.widthPercent / 100)
                    .multilineTextAlignment(subtitleAlign(style.alignment))
                    .padding(.bottom, bottomPad)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    /// 当前有字幕显示的可见字幕轨道（按 overlayTrackOrder 顺序，第一个=最上）
    private func activeSubtitleTrackIDs() -> [UUID] {
        let t = clock.currentTime
        var active: [UUID] = []
        for i in project.orderedSubtitleIndices {
            let track = project.subtitleTracks[i]
            guard track.isVisible else { continue }
            if track.clips.contains(where: { $0.startTime <= t && $0.endTime > t }) {
                active.append(track.id)
            }
        }
        return active
    }

    /// 本轨道底边距 = margin + 其下方各条(层高 + 行距)之和。
    ///
    /// 层高走 `SubtitleStyle.layerSize`（跟导出同一份 CoreText 计算），**同步算出来**。
    /// 原来这里读的是 SwiftUI 实测高度，那份值异步写回 @State，快速拖播放头时
    /// 跟不上字幕切换，会拿上一条的高度排版 → 间距忽大忽小
    private func subtitleBottomPad(trackID: UUID, geoW: CGFloat, geoH: CGFloat,
                                   scale: CGFloat, time: Double) -> CGFloat {
        let margin = geoH * project.subtitleBottomMargin / 100.0
        let spacing = CGFloat(project.subtitleLineSpacing) * scale
        let active = activeSubtitleTrackIDs()
        guard let level = active.firstIndex(of: trackID), active.count > 1 else { return margin }
        var pad = margin
        for k in (level + 1)..<active.count {
            guard let t = project.subtitleTracks.first(where: { $0.id == active[k] }),
                  let clip = t.clips.first(where: { $0.startTime <= time && $0.endTime > time })
            else { continue }
            let s = t.subtitleStyle ?? SubtitleStyle()
            let text = s.mergeLineBreaks ? SubtitleOverlay.mergeBreaks(clip.text) : clip.text
            pad += s.layerSize(text: text, scale: scale, renderWidth: geoW).height + spacing
        }
        return pad
    }

    private func subtitleAlign(_ a: String) -> TextAlignment {
        switch a { case "left": return .leading; case "right": return .trailing; default: return .center }
    }

    private func commitTextEdit() {
        guard let id = project.editingTextClipID else { return }
        project.updateTextClip(id: id) { $0.text = editText }
        project.editingTextClipID = nil
    }

    private func selectShapeExclusive(_ id: UUID) {
        if project.editingTextClipID != nil { commitTextEdit() }
        project.selectedShapeClipID = id
        project.selectedVideoClipID = nil; project.selectedImageClipID = nil
        project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil
        project.selectedTextClipID = nil
        project.selectedClipIDs = [id]
    }

    private func selectImageExclusive(_ id: UUID) {
        if project.editingTextClipID != nil { commitTextEdit() }
        project.selectedImageClipID = id
        project.selectedVideoClipID = nil; project.selectedShapeClipID = nil
        project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil
        project.selectedTextClipID = nil
        project.selectedClipIDs = [id]
    }

    private func selectTextExclusive(_ id: UUID) {
        if project.editingTextClipID != nil && project.editingTextClipID != id { commitTextEdit() }
        project.selectedTextClipID = id
        project.selectedVideoClipID = nil; project.selectedImageClipID = nil
        project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil
        project.selectedShapeClipID = nil
        project.selectedClipIDs = [id]
    }

    private func shapeByID(_ id: UUID) -> ShapeClip? {
        project.shapeTracks.flatMap { $0.clips }.first { $0.id == id }
    }

    private func imageRenderRect(clip: ImageClip, viewSize: CGSize) -> CGRect {
        let imgW = CGFloat(clip.imageWidth)
        let imgH = CGFloat(clip.imageHeight)
        guard imgW > 0, imgH > 0 else { return .zero }
        let videoSize = project.previewRenderSize
        let vs = viewSize.width / max(videoSize.width, 1)
        // 与 ImageOverlay 的渲染同一套：按旋转后的朝向 fit
        let fitSize = rotatedFitSize(CGSize(width: imgW, height: imgH),
                                          rotation: clip.rotation)
        let baseScale = min(videoSize.width / fitSize.width, videoSize.height / fitSize.height)
        let finalSX = baseScale * clip.scaleX
        let finalSY = baseScale * clip.scaleY
        let fullW = imgW * finalSX
        let fullH = imgH * finalSY
        let cx = videoSize.width / 2 + clip.offsetX * videoSize.width
        let cy = videoSize.height / 2 + clip.offsetY * videoSize.height
        let cropX = cx - fullW / 2 + imgW * clip.cropLeft * finalSX
        let cropY = cy - fullH / 2 + imgH * clip.cropTop * finalSY
        let cropW = imgW * (1 - clip.cropLeft - clip.cropRight) * finalSX
        let cropH = imgH * (1 - clip.cropTop - clip.cropBottom) * finalSY
        guard cropW > 0, cropH > 0 else { return .zero }
        return CGRect(x: cropX * vs, y: cropY * vs, width: cropW * vs, height: cropH * vs)
    }

    @ViewBuilder
    private func compoundOverlayView(trackID: UUID) -> some View {
        let t = clock.currentTime
        let found = compoundClipAt(trackID: trackID, time: t)
        GeometryReader { geo in
            if let (compound, it) = found {
                // 按复合片段**自己的** overlayTrackOrder 叠。
                // 原来是写死的类型顺序（图片→图形→文字→字幕），字幕永远画在最后=永远
                // 盖在最上面，跟它在复合片段里排第几层无关；进入复合片段编辑后走的是
                // 外层那条按 order 排的路径，于是"外面看字幕在最上、进去看在第二层"。
                // 导出侧那份写死的顺序还跟这边不一样（图片→字幕→文字→图形）
                let layers = compound.overlayLayersBottomUp
                ForEach(Array(layers.enumerated()), id: \.element.trackID) { i, ref in
                    compoundLayerView(ref: ref, isFirstSubtitle: firstSubtitleIndex(layers) == i,
                                      compound: compound, it: it, geo: geo)
                        .zIndex(Double(i))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 清单里第一条字幕轨的位置。多条字幕轨要作为一组一起排版（否则互相重叠），
    /// 所以只在第一条出现的那层整组画出来，其余跳过——跟导出侧 subtitleRendered 同一个思路
    private func firstSubtitleIndex(_ layers: [ProjectState.OverlayTrackRef]) -> Int? {
        layers.firstIndex { if case .subtitle = $0 { return true }; return false }
    }

    @ViewBuilder
    private func compoundLayerView(ref: ProjectState.OverlayTrackRef, isFirstSubtitle: Bool,
                                   compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        switch ref {
        case .image(let id):
            compoundImages(compound: compound, trackID: id, it: it, geo: geo)
        case .shape(let id):
            compoundShapes(compound: compound, trackID: id, it: it, geo: geo)
        case .text(let id):
            compoundTexts(compound: compound, trackID: id, it: it, geo: geo)
        case .subtitle:
            if isFirstSubtitle {
                compoundSubtitles(compound: compound, it: it, geo: geo)
            }
        case .filter, .adjust, .effect:
            EmptyView()   // 复合片段内部没有滤镜/调节/特效轨道
        case .compound(let id):
            nestedCompoundOverlay(compound: compound, trackID: id, it: it, geo: geo)
        }
    }

    /// 嵌套的复合片段。同样按嵌套那层自己的 overlayTrackOrder 叠
    private func nestedCompoundOverlay(compound: CompoundClip, trackID: UUID,
                                       it: Double, geo: GeometryProxy) -> AnyView {
        guard let track = compound.compoundTracks.first(where: { $0.id == trackID }),
              track.isVisible else { return AnyView(EmptyView()) }
        let active = track.clips.filter { $0.startTime <= it && $0.endTime > it }
        guard !active.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(ForEach(active) { nested in
            let nit = it - nested.startTime + nested.internalStart
            let layers = nested.overlayLayersBottomUp
            ForEach(Array(layers.enumerated()), id: \.element.trackID) { i, ref in
                self.compoundLayerView(ref: ref,
                                       isFirstSubtitle: self.firstSubtitleIndex(layers) == i,
                                       compound: nested, it: nit, geo: geo)
                    .zIndex(Double(i))
            }
        })
    }

    private func compoundClipAt(trackID: UUID, time: Double) -> (CompoundClip, Double)? {
        guard let track = project.compoundTracks.first(where: { $0.id == trackID }),
              track.isVisible,
              let compound = track.clips.first(where: { $0.startTime <= time && $0.endTime > time })
        else { return nil }
        let it = time - compound.startTime + compound.internalStart
        return (compound, it)
    }

    @ViewBuilder
    private func compoundImages(compound: CompoundClip, trackID: UUID,
                                it: Double, geo: GeometryProxy) -> some View {
        if let track = compound.imageTracks.first(where: { $0.id == trackID }), track.isVisible {
            let clips = track.clips.filter { $0.startTime <= it && $0.endTime > it }
            ForEach(clips) { clip in
                ImageLayerView(clip: clip, viewSize: geo.size, videoSize: project.previewRenderSize)
            }
        }
    }

    @ViewBuilder
    private func compoundShapes(compound: CompoundClip, trackID: UUID,
                                it: Double, geo: GeometryProxy) -> some View {
        if let track = compound.shapeTracks.first(where: { $0.id == trackID }), track.isVisible {
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            let clips = track.clips.filter { $0.startTime <= it && $0.endTime > it }
            ForEach(clips) { clip in
                ShapeClipView(clip: clip, scale: scale, selected: false)
                    .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
            }
        }
    }

    @ViewBuilder
    private func compoundTexts(compound: CompoundClip, trackID: UUID,
                               it: Double, geo: GeometryProxy) -> some View {
        if let track = compound.textTracks.first(where: { $0.id == trackID }), track.isVisible {
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            let clips = track.clips.filter { $0.startTime <= it && $0.endTime > it }
            ForEach(clips) { clip in
                TextLabel(clip: clip, scale: scale)
                    .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
            }
        }
    }

    @ViewBuilder
    private func compoundSubtitles(compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        let scale = geo.size.width / max(project.previewRenderSize.width, 1)
        // 多条字幕轨要**竖着摞**，跟外层 SubtitleOverlay 同一个排法。
        // 原来是 ForEach 里每条各自 `.frame(alignment: .bottom)` + 同一个
        // subtitleBottomMargin，等于每条都贴到底边同一位置——中英双语轨直接叠在一起。
        // 进入复合片段编辑时看着正常，是因为那时走的是外层那条路径
        let pairs: [(String, SubtitleStyle)] = compound.orderedSubtitleTracks.compactMap { subTrack in
            guard subTrack.isVisible else { return nil }
            let style = subTrack.subtitleStyle ?? SubtitleStyle()
            guard let clip = subTrack.clips.first(where: {
                $0.startTime <= it && $0.endTime > it
            }) else { return nil }
            let text = style.mergeLineBreaks ? SubtitleOverlay.mergeBreaks(clip.text) : clip.text
            return (text, style)
        }
        if !pairs.isEmpty {
            VStack(spacing: CGFloat(project.subtitleLineSpacing) * scale) {
                ForEach(pairs.indices, id: \.self) { i in
                    SubtitleLabel(text: pairs[i].0, style: pairs[i].1, scale: scale)
                        .frame(maxWidth: geo.size.width * pairs[i].1.widthPercent / 100)
                        .multilineTextAlignment(subtitleAlign(pairs[i].1.alignment))
                }
            }
            .padding(.bottom, geo.size.height * project.subtitleBottomMargin / 100.0)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}

// MARK: - Image Layer（SwiftUI 渲染图片图层，参与 overlayTrackOrder 统一叠放）

/// 图片缓存：避免每帧 NSImage(contentsOf:) 重复解码
fileprivate final class PreviewImageCache {
    static let shared = PreviewImageCache()
    private var cache: [URL: NSImage] = [:]
    func image(for url: URL) -> NSImage? {
        if let i = cache[url] { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        cache[url] = i
        return i
    }
}

extension View {
    /// 图片描边：八向阴影堆叠近似轮廓。四向在斜边上会露口子，所以补到八向。
    /// shadow 的 radius 天生是模糊的，硬边靠把 radius 压到极小、纯靠偏移堆出来；
    /// softness 才把 radius 放开，跟导出侧 ImageStroke 的高斯模糊对应
    @ViewBuilder
    func imageStroke(width: CGFloat, color: Color, softness: Double) -> some View {
        if width > 0.01 {
            let r = max(0.35, width * softness)
            let k = width * 0.707   // 斜向分量
            self
                .shadow(color: color, radius: r, x:  width, y:  0)
                .shadow(color: color, radius: r, x: -width, y:  0)
                .shadow(color: color, radius: r, x:  0, y:  width)
                .shadow(color: color, radius: r, x:  0, y: -width)
                .shadow(color: color, radius: r, x:  k, y:  k)
                .shadow(color: color, radius: r, x: -k, y:  k)
                .shadow(color: color, radius: r, x:  k, y: -k)
                .shadow(color: color, radius: r, x: -k, y: -k)
        } else {
            self
        }
    }
}

private struct ImageLayerView: View {
    let clip: ImageClip
    let viewSize: CGSize      // GeometryReader 给的整个预览区域尺寸
    let videoSize: CGSize     // previewRenderSize

    var body: some View {
        let imgW = CGFloat(clip.imageWidth)
        let imgH = CGFloat(clip.imageHeight)
        if imgW > 0, imgH > 0, let url = clip.imageURL,
           let nsImg = PreviewImageCache.shared.image(for: url) {
            let s = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
            let renderW = videoSize.width * s
            let renderH = videoSize.height * s
            let originX = (viewSize.width - renderW) / 2
            let originY = (viewSize.height - renderH) / 2
            let vs = renderW / videoSize.width   // 视频坐标 → 屏幕坐标

            // fit 按**旋转后**的朝向算：SwiftUI 的 rotationEffect 只做视觉旋转、
            // 不改布局尺寸，所以竖图转 90° 后画面横过来了、尺寸还按竖的适配，
            // 于是画面和选择框对不上（选择框停在旋转前的竖框位置）
            let fitSize = rotatedFitSize(CGSize(width: imgW, height: imgH),
                                              rotation: clip.rotation)
            let baseScale = min(videoSize.width / fitSize.width, videoSize.height / fitSize.height)
            let finalSX = baseScale * CGFloat(clip.scaleX)
            let finalSY = baseScale * CGFloat(clip.scaleY)
            let fullW = imgW * finalSX
            let fullH = imgH * finalSY
            let cx = videoSize.width / 2 + CGFloat(clip.offsetX) * videoSize.width
            let cy = videoSize.height / 2 + CGFloat(clip.offsetY) * videoSize.height
            let fullLeft = cx - fullW / 2
            let fullTop  = cy - fullH / 2

            let cropX = fullLeft + imgW * CGFloat(clip.cropLeft) * finalSX
            let cropY = fullTop  + imgH * CGFloat(clip.cropTop)  * finalSY
            let cropW = imgW * (1 - CGFloat(clip.cropLeft + clip.cropRight)) * finalSX
            let cropH = imgH * (1 - CGFloat(clip.cropTop  + clip.cropBottom)) * finalSY

            if cropW > 0, cropH > 0 {
                let adj = clip.colorAdjust
                ZStack(alignment: .topLeading) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fullW * vs, height: fullH * vs)
                        // 完整图左上角相对裁剪框左上角的偏移
                        .offset(x: -imgW * CGFloat(clip.cropLeft) * finalSX * vs,
                                y: -imgH * CGFloat(clip.cropTop)  * finalSY * vs)
                }
                // 调色走真的 CIFilter：曝光/伽马/高光阴影/色温这些
                // SwiftUI 的修饰器没有对应项，只用修饰器的话滑块拖了没反应
                .modifier(CIAdjustEffect(adjust: adj))
                .frame(width: cropW * vs, height: cropH * vs, alignment: .topLeading)
                .clipped()
                // 圆角切在描边之前，描边才会沿着圆角走
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(clip.corner) * vs))
                // 描边必须加在 clipped 之后，否则会连同描边一起被裁掉。
                // shadow 基于 alpha，所以去背图沿主体轮廓描边，不透明图沿裁剪框描边
                .imageStroke(width: clip.strokeW * vs, color: clip.strokeColor, softness: clip.strokeSoft)
                .scaleEffect(x: clip.mirrorH ? -1 : 1, y: clip.mirrorV ? -1 : 1)
                .rotationEffect(.degrees(Double(clip.rotation)))
                .opacity(clip.alpha)
                .position(x: originX + (cropX + cropW / 2) * vs,
                          y: originY + (cropY + cropH / 2) * vs)
            }
        }
    }
}

/// 把屏幕坐标下的拖动位移转回画面自身的坐标（抵消 rotationEffect）。
/// 视频和图片共用。
func unrotateTranslation(_ t: CGSize, rotation: Double) -> CGSize {
    guard abs(rotation) > 0.001 else { return t }
    let rad = -CGFloat(rotation) * .pi / 180
    return CGSize(width:  t.width * cos(rad) - t.height * sin(rad),
                  height: t.width * sin(rad) + t.height * cos(rad))
}

/// 旋转把画面的宽高换了个个儿：90°/270° 时用 (h, w) 去适配画布。
/// 合成层（ColorCompositor / 导出的 videoTransform）也是按旋转后的整幅尺寸 fit 的，
/// 预览这边必须同步，否则画面转了、框还停在旋转前的位置上。
/// 视频和图片共用一套。
func rotatedFitSize(_ size: CGSize, rotation: Double) -> CGSize {
    let rot = rotation.truncatingRemainder(dividingBy: 360)
    let norm = rot < 0 ? rot + 360 : rot
    // **只有正 90°/270° 才换宽高**。任意角度按外接矩形算的话，
    // 转的过程中画面会跟着一起缩放（转到 45° 最明显），旋转就不只是旋转了
    if abs(norm - 90) < 0.01 || abs(norm - 270) < 0.01 {
        return CGSize(width: size.height, height: size.width)
    }
    return size
}

// MARK: - Subtitle Overlay

private struct SubtitleOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / project.previewRenderSize.width
            let pairs: [(String, SubtitleStyle)] = project.orderedSubtitleIndices.compactMap { i in
                guard project.subtitleTracks[i].isVisible else { return nil }
                let style = project.subtitleTracks[i].subtitleStyle ?? SubtitleStyle()
                guard let clip = project.subtitleTracks[i].clips.first(where: {
                    $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime
                }) else { return nil }
                let text = style.mergeLineBreaks ? Self.mergeBreaks(clip.text) : clip.text
                return (text, style)
            }

            if !pairs.isEmpty {
                let spacing    = CGFloat(project.subtitleLineSpacing) * scale
                let bottomPad  = geo.size.height * project.subtitleBottomMargin / 100.0

                VStack(spacing: spacing) {
                    ForEach(pairs.indices, id: \.self) { i in
                        SubtitleLabel(text: pairs[i].0, style: pairs[i].1, scale: scale)
                            .frame(maxWidth: geo.size.width * pairs[i].1.widthPercent / 100)
                            .multilineTextAlignment(align(pairs[i].1.alignment))
                    }
                }
                .padding(.bottom, bottomPad)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private func align(_ a: String) -> TextAlignment {
        switch a { case "left": return .leading; case "right": return .trailing; default: return .center }
    }

    /// 合并手动换行：中文之间直接拼接，其他用空格连接
    static func mergeBreaks(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 1 else { return text }
        var result = lines[0]
        for i in 1..<lines.count {
            let prev = result.unicodeScalars.last
            let next = lines[i].unicodeScalars.first
            let prevIsCJK = prev.map { $0.value > 0x2E80 } ?? false
            let nextIsCJK = next.map { $0.value > 0x2E80 } ?? false
            result += (prevIsCJK && nextIsCJK) ? lines[i] : " " + lines[i]
        }
        return result
    }
}

/// 合成斜体：中文字体无 italic face，SwiftUI .italic() 不生效，统一用矩阵斜切（与导出端一致）。
/// SwiftUI 坐标 y 向下，c 取负 = 顶部右斜；tx 按单行高补偿一半偏移。
fileprivate func italicSkew(_ on: Bool, fontSize: CGFloat) -> CGAffineTransform {
    guard on else { return .identity }
    return CGAffineTransform(a: 1, b: 0, c: -0.21, d: 1, tx: 0.105 * fontSize * 1.2, ty: 0)
}

private struct SubtitleLabel: View {
    let text: String; let style: SubtitleStyle; var scale: CGFloat = 1.0
    var body: some View {
        Text(text)
            // 用 resolvedFontName：字体没装时跟测量那边回退到同一个，
            // 不然量出来的高度和画出来的高度对不上，多条字幕轨会叠在一起
            .font(.custom(style.resolvedFontName, size: style.fontSize * scale)
                    .weight(style.bold ? .bold : .regular))
            .transformEffect(italicSkew(style.italic, fontSize: style.fontSize * scale))
            .foregroundColor(style.textColor)
            .shadow(color: .black.opacity(0.8), radius: 1 * scale, x: 1 * scale, y: 1 * scale)
            .shadow(color: .black.opacity(0.8), radius: 1 * scale, x: -1 * scale, y: -1 * scale)
            .padding(.horizontal, 10 * scale).padding(.vertical, 3 * scale)
            .background(style.backgroundColor.opacity(style.backgroundOpacity))
            .cornerRadius(3 * scale)
    }
}

// MARK: - 文字/标题图层 Overlay

private struct TextOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @State private var editingID: UUID? = nil
    @State private var editText: String = ""

    private var activeClips: [TextClip] {
        project.textTracks
            .filter { $0.isVisible }
            .flatMap { $0.clips }
            .filter { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        project.updateTextClip(id: id) { $0.text = editText }
        editingID = nil
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)

            // 编辑模式时，点击空白处结束输入
            if editingID != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { commitEdit() }
            }

            ForEach(activeClips, id: \.id) { clip in
                if editingID == clip.id {
                    TextEditField(text: $editText, clip: clip, scale: scale,
                                  onCommit: { commitEdit() })
                        .fixedSize()
                        .overlay(RoundedRectangle(cornerRadius: 4 * scale)
                            .strokeBorder(Color.accent, lineWidth: 1.5))
                        .position(x: geo.size.width * clip.posX,
                                  y: geo.size.height * clip.posY)
                } else {
                    TextLabel(clip: clip, scale: scale,
                              selected: project.selectedTextClipID == clip.id)
                        .position(x: geo.size.width * clip.posX,
                                  y: geo.size.height * clip.posY)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    project.selectedTextClipID = clip.id
                                    project.updateTextClip(id: clip.id) {
                                        $0.posX = min(1, max(0, v.location.x / geo.size.width))
                                        $0.posY = min(1, max(0, v.location.y / geo.size.height))
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            editText = clip.text
                            editingID = clip.id
                            project.selectedTextClipID = clip.id
                        }
                        .onTapGesture { project.selectedTextClipID = clip.id }
                }
            }
        }
    }
}

/// 文字的输入框。预览区双击进编辑态用它，封面弹窗也用同一份
struct TextEditField: NSViewRepresentable {
    @Binding var text: String
    let clip: TextClip
    let scale: CGFloat
    let onCommit: () -> Void

    /// 输入框自己那个 NSTextView。**边缘一圈不设输入光标** ——
    /// 那一圈是外面拖框条的地盘，不让开的话鼠标一靠近边，
    /// 光标就被它抢成输入光标，看不出这里能拖
    /// 输入框自己那个 NSTextView。**边缘一圈是外面拖框条的地盘** ——
    /// 光标要跟裁剪条一样是拉伸的样子。
    ///
    /// 这一圈落在 NSTextView 身上，SwiftUI 的 onHover 收不到（真实 AppKit 视图
    /// 会先接走事件），只能由它自己来设。而且光走 `resetCursorRects` 不够：
    /// NSTextView 每次布局都会重铺自己的光标区，实测会把边缘那圈盖回输入光标，
    /// 所以还要接管 `cursorUpdate` 和 `mouseMoved`
    private final class EdgeAwareTextView: NSTextView {
        /// 边缘认定宽度，跟外面拖框条的热区对齐
        private let edge: CGFloat = 8
        private var edgeTracking: NSTrackingArea?

        private func edgeCursor(at p: CGPoint) -> NSCursor? {
            guard bounds.width > edge * 2, bounds.height > edge * 2 else { return nil }
            if p.y < edge || p.y > bounds.height - edge { return .resizeUpDown }
            if p.x < edge || p.x > bounds.width - edge { return .resizeLeftRight }
            return nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let a = edgeTracking { removeTrackingArea(a) }
            let a = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(a)
            edgeTracking = a
        }

        override func cursorUpdate(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let c = edgeCursor(at: p) { c.set() } else { super.cursorUpdate(with: event) }
        }

        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let c = edgeCursor(at: p) { c.set(); return }
            super.mouseMoved(with: event)
        }

        override func resetCursorRects() {
            let inner = bounds.insetBy(dx: edge, dy: edge)
            guard inner.width > 0, inner.height > 0 else {
                addCursorRect(bounds, cursor: .iBeam)
                return
            }
            addCursorRect(inner, cursor: .iBeam)
            addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: edge), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 0, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EdgeAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder
        tv.textContainerInset = NSSize(width: 4 * scale, height: 2 * scale)
        tv.maxSize = NSSize(width: 10000, height: 10000)
        tv.focusRingType = .none
        tv.string = text
        applyWrap(tv)
        applyStyle(tv)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        applyWrap(tv)
        applyStyle(tv)
    }

    /// 换行规则。拖过边定死了范围框，文字就得在框里换行，
    /// 不能像原来那样一直往右顶出去
    private func applyWrap(_ tv: NSTextView) {
        if let bw = clip.boxWidth {
            let w = max(CGFloat(bw) * scale, 20)
            tv.textContainer?.widthTracksTextView = true
            tv.textContainer?.size = NSSize(width: w, height: 10000)
            tv.isHorizontallyResizable = false
        } else {
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.size = NSSize(width: 10000, height: 10000)
            tv.isHorizontallyResizable = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let r = lm.usedRect(for: tc)
        let pad = tv.textContainerInset
        // 拖过边改了文本框大小就按它走，编辑框才会跟着变换框一起变；
        // 没拖过（boxWidth/boxHeight 是 nil）还是按文字自己撑开。
        // 留白用 TextLabel 那套口径（横 10、竖 5），两种状态框大小才对得上
        let w = clip.boxWidth.map { CGFloat($0) * scale + 20 * scale }
            ?? max(ceil(r.width) + pad.width * 2, 50 * scale)
        let h = clip.boxHeight.map { CGFloat($0) * scale + 10 * scale }
            ?? max(ceil(r.height) + pad.height * 2, clip.fontSize * scale * 1.5)
        return CGSize(width: w, height: h)
    }

    private func applyStyle(_ tv: NSTextView) {
        let sz = clip.fontSize * scale
        var font = NSFont(name: clip.fontName, size: sz) ?? NSFont.systemFont(ofSize: sz)
        if clip.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        let c = NSColor(clip.textColor)
        tv.font = font
        tv.textColor = c
        tv.insertionPointColor = c
        tv.alignment = clip.alignment == "left" ? .left : clip.alignment == "right" ? .right : .center
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextEditField
        init(_ parent: TextEditField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

/// 文字图层的渲染本体。预览区和封面弹窗共用 ——
/// 斜体的矩阵斜切、描边的四向阴影、背景色、对齐都在这儿，
/// 封面另写一套的话这些属性就会「调了没反应」
struct TextLabel: View {
    let clip: TextClip
    var scale: CGFloat = 1.0
    var selected: Bool = false
    /// 是否自己转。ImageRenderer 出图时按未旋转的尺寸裁切，
    /// 转过的部分会被切掉一角，所以渲染时关掉它、改由画布上下文旋转
    var applyRotation: Bool = true

    /// 描边模糊半径。**柔和度 0 时压到极小 = 硬边**，
    /// 以前写死成宽度的一半，所以怎么调都是糊的
    private var strokeRadius: CGFloat {
        max(0.35, clip.strokeWidth * clip.strokeSoftness) * scale
    }
    private var strokeOffset: CGFloat { max(0.6, clip.strokeWidth) * scale }

    var body: some View {
        Text(clip.text.isEmpty ? " " : clip.text)
            .font(.custom(clip.fontName, size: clip.fontSize * scale)
                    .weight(clip.bold ? .bold : .regular))
            .transformEffect(italicSkew(clip.italic, fontSize: clip.fontSize * scale))
            .foregroundColor(clip.textColor)
            // 描边近似：八向阴影堆出轮廓（四向在斜边上会露口子，跟图片描边一个做法）
            .modifier(TextStroke(color: clip.strokeColor.opacity(clip.strokeWidth > 0 ? 1 : 0.6),
                                 width: strokeOffset, radius: strokeRadius))
            .multilineTextAlignment(textAlign(clip.alignment))
            // 文本框尺寸：没设过就跟着文字自适应（老行为）
            .frame(width: clip.boxWidth.map { $0 * scale },
                   height: clip.boxHeight.map { $0 * scale },
                   alignment: boxAlign(clip.alignment))
            .padding(.horizontal, 10 * scale).padding(.vertical, 5 * scale)
            .background(clip.bgColor.opacity(clip.bgOpacity))
            .cornerRadius(4 * scale)
            // 裁剪排在旋转之前：裁完再转，裁剪边跟着一起转
            .modifier(TextCropMask(clip: clip))
            .scaleEffect(x: clip.mirrorH ? -1 : 1, y: clip.mirrorV ? -1 : 1)
            .rotationEffect(.degrees(applyRotation ? clip.rotation : 0))
            .opacity(clip.opacity)
            .overlay(
                selected
                ? RoundedRectangle(cornerRadius: 4 * scale)
                    .strokeBorder(Color.accent, lineWidth: 1.5)
                : nil
            )
    }
    private func textAlign(_ a: String) -> TextAlignment {
        switch a { case "left": return .leading; case "right": return .trailing; default: return .center }
    }
    private func boxAlign(_ a: String) -> Alignment {
        switch a { case "left": return .topLeading; case "right": return .topTrailing; default: return .top }
    }
}

/// 文字描边：八向阴影堆叠近似轮廓，跟图片那套 `imageStroke` 同源。
/// 硬边靠把 radius 压到极小、纯用偏移堆出来；柔和度才把 radius 放开
private struct TextStroke: ViewModifier {
    let color: Color
    let width: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        let k = width * 0.707   // 斜向分量
        content
            .shadow(color: color, radius: radius, x:  width, y: 0)
            .shadow(color: color, radius: radius, x: -width, y: 0)
            .shadow(color: color, radius: radius, x: 0, y:  width)
            .shadow(color: color, radius: radius, x: 0, y: -width)
            .shadow(color: color, radius: radius, x:  k, y:  k)
            .shadow(color: color, radius: radius, x: -k, y:  k)
            .shadow(color: color, radius: radius, x:  k, y: -k)
            .shadow(color: color, radius: radius, x: -k, y: -k)
    }
}

/// 文字裁剪：按 0~1 比例从四边往里裁，用来做「只露半个字」这类效果。
/// 没裁剪时原样返回 —— 每条文字都套一层 GeometryReader 太浪费
private struct TextCropMask: ViewModifier {
    let clip: TextClip

    func body(content: Content) -> some View {
        if clip.cropTop <= 0, clip.cropBottom <= 0, clip.cropLeft <= 0, clip.cropRight <= 0 {
            content
        } else {
            content.mask(
                GeometryReader { g in
                    Rectangle()
                        .padding(.top, g.size.height * clip.cropTop)
                        .padding(.bottom, g.size.height * clip.cropBottom)
                        .padding(.leading, g.size.width * clip.cropLeft)
                        .padding(.trailing, g.size.width * clip.cropRight)
                }
            )
        }
    }
}

// MARK: - Preview Aspect Picker

private struct PreviewAspectPicker: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        Menu {
            ForEach(ProjectState.previewAspectRatios, id: \.self) { ratio in
                Button {
                    if ratio == ExportSettings.customAspect {
                        // 切自定义时以当前尺寸为起点，并把光标送到项目设置的尺寸输入框
                        let s = project.previewRenderSize
                        project.customOutputWidth = Int(s.width)
                        project.customOutputHeight = Int(s.height)
                        project.previewAspectRatio = ratio
                        project.clearSelectionForProjectSettings()
                        project.focusCustomSizeField = true
                        project.rebuildTimelinePreview()
                        return
                    }
                    guard project.previewAspectRatio != ratio else { return }
                    project.previewAspectRatio = ratio
                    // 画布尺寸变了，合成必须按新 renderSize 重出，否则素材还是旧画布的摆放
                    project.rebuildTimelinePreview()
                } label: {
                    HStack {
                        Text(ratio)
                        if ratio == project.previewAspectRatio {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(project.previewAspectRatio)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("画面比例，按当前分辨率内接裁剪")
    }
}

// MARK: - Preview Resolution Picker

private struct PreviewResolutionPicker: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        Menu {
            ForEach(ProjectState.previewResolutions, id: \.self) { res in
                Button {
                    guard project.previewResolution != res else { return }
                    project.previewResolution = res
                    project.rebuildTimelinePreview()
                } label: {
                    HStack {
                        Text(shortLabel(res))
                        if res == project.previewResolution {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(shortLabel(project.previewResolution))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func shortLabel(_ res: String) -> String {
        if let spaceIdx = res.firstIndex(of: " ") {
            return String(res[res.startIndex..<spaceIdx])
        }
        return res
    }
}

// MARK: - Preview Toolbar

private struct PreviewToolbar: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var ctrl: PlayerController

    private var fps: Double { Double(project.exportSettings.fps) }

    var body: some View {
        VStack(spacing: 0) {
            // 传输控件绝对居中：用 Spacer 均分的话，右侧比例/分辨率文字一变宽就会把它挤偏
            ZStack {
                HStack(spacing: 12) {
                    toolBtn("seekStart") { seekToStart() }
                    toolBtn("prevFrame") { stepFrame(-1) }
                    toolBtn(ctrl.isPlaying ? "pause" : "play") { ctrl.toggle() }
                    toolBtn("nextFrame") { stepFrame(1) }
                    toolBtn("seekEnd") { seekToEnd() }
                }

                HStack(spacing: 0) {
                    Text(timecode(clock.currentTime))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(hex: "#E8A54B"))
                    Text(" / ")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary.opacity(0.5))
                    Text(timecode(clock.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)

                    Spacer(minLength: 12)

                    Button { captureFrame() } label: {
                        Image(nsImage: TimelineSVGIcon.load("capture"))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                            .foregroundColor(Color.labelSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("捕捉当前帧到素材库")

                    PreviewAspectPicker()
                        .padding(.leading, 4)

                    PreviewResolutionPicker()
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(Color.panelBg)
    }

    private func toolBtn(_ svgName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: TimelineSVGIcon.load(svgName))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
                .foregroundColor(Color.labelPrimary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timecode(_ t: Double) -> String {
        let total = max(t, 0)
        let h = Int(total) / 3600
        let m = Int(total) / 60 % 60
        let s = Int(total) % 60
        let f = Int((total - Double(Int(total))) * fps)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    private func seekToStart() {
        clock.currentTime = 0
        clock.seekRequest += 1
    }

    private func seekToEnd() {
        clock.currentTime = max(clock.duration - 1.0 / fps, 0)
        clock.seekRequest += 1
    }

    private func stepFrame(_ direction: Int) {
        if ctrl.isPlaying { ctrl.pause() }
        let step = 1.0 / fps * Double(direction)
        clock.currentTime = max(0, min(clock.currentTime + step, clock.duration))
        clock.seekRequest += 1
    }

    private func captureFrame() {
        guard let item = project.playerItem else { return }
        let asset = item.asset
        let gen = AVAssetImageGenerator(asset: asset)
        // 必须把 videoComposition 交给 generator —— 预览画面是 playerItem 走
        // ColorCompositor 渲染出来的，图片/文字/图形这些 overlay、色调、旋转、裁剪
        // 全在 videoComposition 里。不设的话 generator 只从 composition 的视频轨抽帧，
        // 播放头处若没有视频片段（画面全靠 overlay）截出来就是纯黑
        gen.videoComposition = item.videoComposition
        // 有 videoComposition 时 appliesPreferredTrackTransform 会被忽略，
        // 方向由 compositor 自己处理（见 ColorCompositor 的 sourceTransform）
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: clock.currentTime, preferredTimescale: 600)

        guard let cgImg = try? gen.copyCGImage(at: time, actualTime: nil) else {
            project.showSuccessToast(icon: "xmark.circle", iconColor: .red, title: "截图失败", subtitle: "无法捕捉当前帧")
            return
        }

        let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        let bmp = NSBitmapImageRep(cgImage: cgImg)
        guard let pngData = bmp.representation(using: .png, properties: [:]) else { return }

        let saveDir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("截图")
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let filename = "frame_\(Int(clock.currentTime * fps)).png"
        let fileURL = saveDir.appendingPathComponent(filename)
        try? pngData.write(to: fileURL)

        project.importFile(fileURL)
        guard let asset = project.mediaAssets.first(where: { $0.url == fileURL }) else { return }

        project.pushUndo()
        let playhead = clock.currentTime
        let hasImageAtPlayhead = project.imageTracks.contains { track in
            track.clips.contains { $0.startTime <= playhead && $0.endTime > playhead }
        }
        let trackIdx: Int
        if hasImageAtPlayhead {
            project.imageTracks.append(Track(label: "图片"))
            project.syncOverlayOrder()
            trackIdx = project.imageTracks.count - 1
        } else if let emptyIdx = project.imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
            trackIdx = emptyIdx
        } else {
            var foundTrack: Int?
            for (i, track) in project.imageTracks.enumerated() {
                let overlap = track.clips.contains { $0.startTime < playhead + 5 && $0.endTime > playhead }
                if !overlap { foundTrack = i; break }
            }
            if let idx = foundTrack {
                trackIdx = idx
            } else {
                project.imageTracks.append(Track(label: "图片"))
                project.syncOverlayOrder()
                trackIdx = project.imageTracks.count - 1
            }
        }
        let dur = 5.0
        var imgW = 0, imgH = 0
        if let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imgW = cg.width; imgH = cg.height
        }
        project.imageTracks[trackIdx].clips.append(
            ImageClip(assetID: asset.id, name: asset.name, imageURL: fileURL,
                      videoURL: nil, startTime: playhead, endTime: playhead + dur,
                      imageWidth: imgW, imageHeight: imgH))
        project.duration = max(project.duration, playhead + dur)
        project.rebuildTimelinePreview()
        project.showSuccessToast(icon: "camera.fill", iconColor: .blue, title: "截图", subtitle: "已插入图片轨道")
    }
}

// MARK: - Playback Bar

private struct PlaybackBar: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var ctrl: PlayerController

    var body: some View {
        HStack(spacing: 8) {
            // Play/Pause — icon is driven by the AVPlayer's rate via
            // PlayerController.isPlaying, so it updates no matter how playback
            // was toggled (button, space key, etc.)
            Button { ctrl.toggle() } label: {
                Image(nsImage: TimelineSVGIcon.load(ctrl.isPlaying ? "pause" : "play"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color.labelPrimary)
                    .frame(width: 26, height: 26)
            }.buttonStyle(.plain)

            // Time
            Text(fmtT(clock.currentTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color.labelSecondary)
                .frame(width: 72)

            // Scrubber
            Slider(value: $clock.currentTime, in: 0...max(clock.duration, 1)) { editing in
                if !editing { ctrl.seek(to: clock.currentTime) }
            }.accentColor(Color.accent)
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.55))
        )
    }

    private func fmtT(_ t: Double) -> String {
        let m = Int(t)/60%60; let s = Int(t)%60; let ms = Int((t - Double(Int(t)))*1000)
        return String(format: "%02d:%02d.%03d", m, s, ms)
    }
}

// MARK: - Image Transform Overlay

/// When an image clip is selected, shows a bounding box with corner handles
/// for scaling, edge bars for cropping, and allows drag-to-move.
/// Cropping one edge keeps the opposite edge fixed.
// MARK: - Video Transform Overlay (绿色)

private struct VideoTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    enum DragMode { case none, move, scale, crop }
    @State private var dragMode: DragMode = .none
    @State private var didPushUndo = false
    @State private var dragStartOffset: CGPoint = .zero
    @State private var scaleStartValues: (sx: Double, sy: Double) = (1, 1)
    @State private var cropEdge: Int = 0
    @State private var cropStartClip: VideoClip?
    @State private var isHovering = false

    private let accentColor = Color(hex: "#3DBFBA")

    var body: some View {
        GeometryReader { geo in
            if let clip = project.selectedVideoClip,
               clip.videoWidth > 0, clip.videoHeight > 0,
               clip.startTime <= clock.currentTime,
               clip.endTime > clock.currentTime {
                let info = computeRenderInfo(viewSize: geo.size)
                let vidRect = computeVideoRect(clip: clip, info: info)

                let isMulti = project.selectedClipIDs.count > 1
                ZStack {
                    // 移动区域
                    Color.clear
                        .frame(width: max(vidRect.width, 1), height: max(vidRect.height, 1))
                        .position(x: vidRect.midX, y: vidRect.midY)
                        .contentShape(Path { p in p.addRect(vidRect) })
                        .onHover { h in
                            isHovering = h
                            if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(moveDrag(clip: clip, info: info, rect: vidRect, viewSize: geo.size))

                    if !isMulti {
                        // 边框
                        Rectangle()
                            .stroke(accentColor, lineWidth: 1.5)
                            .frame(width: max(vidRect.width, 1), height: max(vidRect.height, 1))
                            .position(x: vidRect.midX, y: vidRect.midY)
                            .allowsHitTesting(false)

                        // 四边裁剪手柄 — 绿色长细条
                        ForEach(0..<4, id: \.self) { edge in
                            let pos = edgeMidPos(edge, vidRect)
                            let isH = edge < 2
                            let barLen = isH ? max(min(vidRect.width * 0.35, 50), 20) : max(min(vidRect.height * 0.35, 50), 20)
                            VideoCropEdgeBar(isHorizontal: isH, length: barLen, color: accentColor)
                                .claimsDragFromWindow()   // 必须在 .position() 之前
                                .position(x: pos.x, y: pos.y)
                                .gesture(cropDrag(clip: clip, info: info, edge: edge))
                        }

                        // 四角缩放手柄 — 白色圆点绿色边
                        ForEach(0..<4, id: \.self) { corner in
                            let pos = cornerPos(corner, vidRect)
                            VideoScaleHandleDot(color: accentColor)
                                .claimsDragFromWindow()   // 必须在 .position() 之前
                                .position(x: pos.x, y: pos.y)
                                .gesture(scaleDrag(clip: clip, info: info, corner: corner))
                        }
                    }
                }
                // 整个框跟着画面转，锚点用画面中心 —— 跟合成层的旋转锚点是同一个，
                // 这样框始终贴着画面边界，而不是停在旋转前的位置
                .rotationEffect(.degrees(Double(clip.rotation)),
                                anchor: rotationAnchor(clip: clip, info: info, in: geo.size))
            }
        }
        // 同图片：手势要在不参与旋转的这层里量，不然参考点跟着手柄转，画面抖
        .coordinateSpace(name: TransformBox.space)
    }

    /// 把画面中心换算成 rotationEffect 要的 UnitPoint
    private func rotationAnchor(clip: VideoClip, info: RenderInfo, in size: CGSize) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        let c = videoFrameCenter(clip: clip, info: info)
        return UnitPoint(x: c.x / size.width, y: c.y / size.height)
    }


    @State private var multiStart: [UUID: CGPoint] = [:]

    private func moveDrag(clip: VideoClip, info: RenderInfo, rect: CGRect, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if dragMode == .none && dist > 3 {
                    pushUndoOnce()
                    dragMode = .move
                    NSCursor.closedHand.set()
                    dragStartOffset = CGPoint(x: clip.offsetX, y: clip.offsetY)
                    multiStart.removeAll()
                    if project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id) {
                        for id in project.selectedClipIDs where id != clip.id {
                            if let sc = project.shapeTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: sc.posX, y: sc.posY)
                            } else if let tc = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: tc.posX, y: tc.posY)
                            } else if let ic = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: ic.offsetX, y: ic.offsetY)
                            }
                        }
                    }
                }
                guard dragMode == .move else { return }
                let dx = value.translation.width / info.renderArea.width
                let dy = value.translation.height / info.renderArea.height
                let newOffX = dragStartOffset.x + dx
                let newOffY = dragStartOffset.y + dy
                project.updateVideoClip(id: clip.id) {
                    $0.offsetX = newOffX
                    $0.offsetY = newOffY
                }
                if let trackID = project.videoClipTrackIDMap[clip.id] {
                    ColorCompositor.setDragOffset(trackID: trackID, offsetX: CGFloat(newOffX), offsetY: CGFloat(newOffY))
                    clock.refreshSeekRequest &+= 1
                }
                let ndx = value.translation.width / viewSize.width
                let ndy = value.translation.height / viewSize.height
                for (id, s) in multiStart {
                    if project.shapeTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateShapeClip(id: id) { $0.posX = min(1, max(0, s.x + ndx)); $0.posY = min(1, max(0, s.y + ndy)) }
                    } else if project.textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateTextClip(id: id) { $0.posX = min(1, max(0, s.x + ndx)); $0.posY = min(1, max(0, s.y + ndy)) }
                    } else if project.imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateImageClip(id: id) { $0.offsetX = s.x + dx; $0.offsetY = s.y + dy }
                    }
                }
            }
            .onEnded { value in
                if dragMode == .move {
                    dragMode = .none; didPushUndo = false; multiStart.removeAll()
                    NSCursor.openHand.set()
                } else {
                    project.tapThroughSelect(at: value.location, viewSize: viewSize,
                                             time: clock.currentTime, currentClipID: clip.id)
                }
            }
    }

    private func scaleDrag(clip: VideoClip, info: RenderInfo, corner: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .scale
                    scaleStartValues = (clip.scaleX, clip.scaleY)
                }
                guard dragMode == .scale else { return }
                let vidRect = computeVideoRect(clip: clip, info: info)
                let center = CGPoint(x: vidRect.midX, y: vidRect.midY)
                let startDist = hypot(value.startLocation.x - center.x,
                                      value.startLocation.y - center.y)
                let curDist = hypot(value.location.x - center.x,
                                    value.location.y - center.y)
                guard startDist > 1 else { return }
                let ratio = curDist / startDist
                project.updateVideoClip(id: clip.id) {
                    $0.scaleX = max(0.05, scaleStartValues.sx * ratio)
                    $0.scaleY = max(0.05, scaleStartValues.sy * ratio)
                }
                project.rebuildTimelinePreviewDebounced()
            }
            .onEnded { _ in
                dragMode = .none; didPushUndo = false
                project.rebuildTimelinePreview()
            }
    }

    private func cropDrag(clip: VideoClip, info: RenderInfo, edge: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .crop
                    cropEdge = edge
                    cropStartClip = clip
                }
                guard dragMode == .crop, let startClip = cropStartClip else { return }
                let vidRect = computeVideoRect(clip: startClip, info: info)
                // 手势给的是屏幕坐标的位移，而 cropTop/cropLeft 说的是画面**自己**的
                // 上下左右。画面转了 90° 之后两者差一个旋转，得先转回画面坐标，
                // 否则拖上边的手柄画面从侧面被裁
                let d = unrotateTranslation(value.translation, rotation: Double(startClip.rotation))
                var delta: Double = 0
                switch edge {
                case 0: delta =  d.height / vidRect.height
                case 1: delta = -d.height / vidRect.height
                case 2: delta =  d.width  / vidRect.width
                case 3: delta = -d.width  / vidRect.width
                default: break
                }
                let startVal: Double
                switch edge {
                case 0: startVal = startClip.cropTop
                case 1: startVal = startClip.cropBottom
                case 2: startVal = startClip.cropLeft
                case 3: startVal = startClip.cropRight
                default: startVal = 0
                }
                let newCrop = (startVal + delta).clamped(to: 0...0.99)
                project.updateVideoClip(id: clip.id) {
                    switch edge {
                    case 0: $0.cropTop    = newCrop
                    case 1: $0.cropBottom = newCrop
                    case 2: $0.cropLeft   = newCrop
                    case 3: $0.cropRight  = newCrop
                    default: break
                    }
                }
                project.rebuildTimelinePreviewDebounced()
            }
            .onEnded { _ in
                dragMode = .none; didPushUndo = false; cropStartClip = nil
                project.rebuildTimelinePreview()
            }
    }

    private func pushUndoOnce() {
        guard !didPushUndo else { return }
        project.pushUndo()
        didPushUndo = true
    }

    // MARK: - 手柄

    private struct VideoScaleHandleDot: View {
        let color: Color
        var body: some View {
            ZStack {
                Circle().fill(Color.white).frame(width: 10, height: 10)
                Circle().stroke(color, lineWidth: 1.5).frame(width: 10, height: 10)
            }
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onHover { h in
                if h { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    private struct VideoCropEdgeBar: View {
        let isHorizontal: Bool
        let length: CGFloat
        let color: Color
        var body: some View {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: isHorizontal ? length : 3,
                       height: isHorizontal ? 3 : length)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                // 跟图形边条同宽（10pt）。原来 28 等于向外各吃掉 12pt，
                // 压着下层图层时会把人家露出来的窄区抢掉
                .frame(width: isHorizontal ? length + 16 : 10,
                       height: isHorizontal ? 10 : length + 16)
                .contentShape(Rectangle())
                .onHover { h in
                    if h { (isHorizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
                    else { NSCursor.arrow.set() }
                }
        }
    }

    // MARK: - 位置计算

    private func cornerPos(_ corner: Int, _ r: CGRect) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.minX, y: r.maxY)
        case 3: return CGPoint(x: r.maxX, y: r.maxY)
        default: return r.origin
        }
    }

    private func edgeMidPos(_ edge: Int, _ r: CGRect) -> CGPoint {
        switch edge {
        case 0: return CGPoint(x: r.midX, y: r.minY)
        case 1: return CGPoint(x: r.midX, y: r.maxY)
        case 2: return CGPoint(x: r.minX, y: r.midY)
        case 3: return CGPoint(x: r.maxX, y: r.midY)
        default: return r.origin
        }
    }

    struct RenderInfo {
        var renderArea: CGRect
        var videoSize: CGSize
    }

    private func computeRenderInfo(viewSize: CGSize) -> RenderInfo {
        let videoW = project.previewRenderSize.width
        let videoH = project.previewRenderSize.height
        let s = min(viewSize.width / videoW, viewSize.height / videoH)
        let w = videoW * s; let h = videoH * s
        return RenderInfo(
            renderArea: CGRect(x: (viewSize.width - w)/2, y: (viewSize.height - h)/2, width: w, height: h),
            videoSize: CGSize(width: videoW, height: videoH))
    }

    /// 画面中心在视图坐标里的位置 —— 裁剪框绕它旋转（跟合成层的旋转锚点一致）
    private func videoFrameCenter(clip: VideoClip, info: RenderInfo) -> CGPoint {
        let vs = info.renderArea.width / info.videoSize.width
        let cx = info.videoSize.width / 2 + CGFloat(clip.offsetX) * info.videoSize.width
        let cy = info.videoSize.height / 2 + CGFloat(clip.offsetY) * info.videoSize.height
        return CGPoint(x: cx * vs + info.renderArea.origin.x,
                       y: cy * vs + info.renderArea.origin.y)
    }

    private func computeVideoRect(clip: VideoClip, info: RenderInfo) -> CGRect {
        // 用转正后的尺寸：clip.videoWidth 是文件里的 naturalSize，竖拍视频那是横的，
        // 而画面在预览里已经被 preferredTransform 转正了
        let oriented = project.orientedSize(for: clip)
        let natW = oriented?.width ?? CGFloat(clip.videoWidth)
        let natH = oriented?.height ?? CGFloat(clip.videoHeight)
        guard natW > 0, natH > 0 else { return .zero }

        // 素材在画布内等比摆放（合成层同样逻辑），裁剪框据此贴合素材边界。
        // 尺寸取旋转后的整幅画面，跟 ColorCompositor 第 5 步用的是同一个值
        let fit = rotatedFitSize(CGSize(width: natW, height: natH), rotation: Double(clip.rotation))
        let baseScale = min(info.videoSize.width / fit.width, info.videoSize.height / fit.height)
        let finalSX = baseScale * CGFloat(clip.scaleX)
        let finalSY = baseScale * CGFloat(clip.scaleY)

        let fullW = natW * finalSX
        let fullH = natH * finalSY
        let cx = info.videoSize.width / 2 + CGFloat(clip.offsetX) * info.videoSize.width
        let cy = info.videoSize.height / 2 + CGFloat(clip.offsetY) * info.videoSize.height
        let fullLeft = cx - fullW / 2
        let fullTop  = cy - fullH / 2

        let cropX = fullLeft + natW * CGFloat(clip.cropLeft) * finalSX
        let cropY = fullTop  + natH * CGFloat(clip.cropTop)  * finalSY
        let cropW = natW * (1 - CGFloat(clip.cropLeft + clip.cropRight))  * finalSX
        let cropH = natH * (1 - CGFloat(clip.cropTop  + clip.cropBottom)) * finalSY
        guard cropW > 0, cropH > 0 else { return .zero }

        let vs = info.renderArea.width / info.videoSize.width
        return CGRect(
            x: info.renderArea.minX + cropX * vs,
            y: info.renderArea.minY + cropY * vs,
            width: cropW * vs, height: cropH * vs)
    }
}

// MARK: - Image Transform Overlay

// MARK: - 变换手柄（图片片段和封面底图共用同一套）

/// 四角缩放手柄 — 白色圆点
struct TransformScaleDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 10, height: 10)
            Circle().stroke(Color.accent, lineWidth: 1.5).frame(width: 10, height: 10)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .onHover { h in
            if h { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        }
    }
}

/// 四边裁剪条 — 橙色长细条
struct TransformCropBar: View {
    let isHorizontal: Bool
    let length: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.orange)
            .frame(width: isHorizontal ? length : 3,
                   height: isHorizontal ? 3 : length)
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            // 跟图形边条同宽（10pt）。原来 28 等于向外各吃掉 12pt，
            // 压着下层图层时会把人家露出来的窄区抢掉
            .frame(width: isHorizontal ? length + 16 : 10,
                   height: isHorizontal ? 10 : length + 16)
            .contentShape(Rectangle())
            .onHover { h in
                if h { (isHorizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
                else { NSCursor.arrow.set() }
            }
    }
}

/// 旋转手柄 — 白底圆点加个转圈图标，跟图形/文字那两处一个样
struct TransformRotateDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 14, height: 14)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold)).foregroundColor(Color.accent)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
    }
}

private struct ImageTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    enum DragMode { case none, move, scale, crop, rotate }
    @State private var dragMode: DragMode = .none
    @State private var didPushUndo = false
    // Rotate — 起手时的角度快照，拖动只认「转了多少」
    @State private var rotStartValue: Double = 0
    @State private var rotStartAngle: Double = 0
    // Move
    @State private var dragStartOffset: CGPoint = .zero
    // Scale
    @State private var scaleStartValues: (sx: Double, sy: Double) = (1, 1)
    // Crop — 保存拖动开始时的完整clip快照，用于计算对面边补偿
    @State private var cropEdge: Int = 0
    @State private var cropStartClip: ImageClip?
    @State private var isHoveringImage = false

    var body: some View {
        GeometryReader { geo in
            if let clip = project.selectedImageClip,
               clip.startTime <= clock.currentTime,
               clip.endTime > clock.currentTime {
                let info = computeRenderInfo(viewSize: geo.size)
                let imgRect = computeImageRect(clip: clip, info: info)

                let isMulti = project.selectedClipIDs.count > 1
                ZStack {
                    // 最底层：移动区域
                    Color.clear
                        .frame(width: max(imgRect.width, 1), height: max(imgRect.height, 1))
                        .position(x: imgRect.midX, y: imgRect.midY)
                        .contentShape(Path { p in p.addRect(imgRect) })
                        .onHover { h in
                            isHoveringImage = h
                            if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(moveDrag(clip: clip, info: info, rect: imgRect, viewSize: geo.size))

                    if !isMulti {
                        // 跟文字、图形同一个框组件：四角缩放、四边裁剪、上方旋转。
                        // 它自己按 rotation 算几何，所以不能再包在外层 rotationEffect 里
                        let full = computeImageRect(clip: clip, info: info, applyCrop: false)
                        TransformBox(
                            center: CGPoint(x: full.midX, y: full.midY),
                            size: CGSize(width: max(full.width, 8), height: max(full.height, 8)),
                            // 旋转交给外层那一下，这里按没转来算 ——
                            // 移动区和手柄各转各的会对不上（拖着图片走的时候像在转）
                            rotation: 0,
                            crop: TransformCrop(top: clip.cropTop, bottom: clip.cropBottom,
                                                left: clip.cropLeft, right: clip.cropRight),
                            outerRotation: clip.rotation,
                            onBegin: {
                                pushUndoOnce()
                                scaleStartValues = (clip.scaleX, clip.scaleY)
                                rotStartValue = clip.rotation
                            },
                            onEnd: {
                                didPushUndo = false
                                project.rebuildTimelinePreview()
                            },
                            onScale: { ratio in
                                project.updateImageClip(id: clip.id) {
                                    $0.scaleX = max(0.05, scaleStartValues.sx * ratio)
                                    $0.scaleY = max(0.05, scaleStartValues.sy * ratio)
                                }
                                project.rebuildTimelinePreviewDebounced()
                            },
                            onCrop: { e, value in
                                project.updateImageClip(id: clip.id) {
                                    switch e {
                                    case 0: $0.cropTop = value
                                    case 1: $0.cropBottom = value
                                    case 2: $0.cropLeft = value
                                    default: $0.cropRight = value
                                    }
                                }
                                project.rebuildTimelinePreviewDebounced()
                            },
                            onRotate: { delta in
                                project.updateImageClip(id: clip.id) { $0.rotation = rotStartValue + delta }
                                project.rebuildTimelinePreviewDebounced()
                            }
                        )
                    }
                }
                // 整层一起转（移动区 + 手柄），锚点用画面中心，同视频那套
                .rotationEffect(.degrees(clip.rotation),
                                anchor: imageRotationAnchor(clip: clip, info: info, in: geo.size))
            }
        }
        // **坐标系声明在旋转外面**。旋转手柄自己就跟着角度在转，
        // 手势要是拿它所在那层的坐标去量，参考点每帧都在动 —— 画面就抖。
        // 挂在 GeometryReader 这层，量到的始终是预览区里那个不动的坐标
        .coordinateSpace(name: TransformBox.space)
    }

    /// 图片画面中心 → rotationEffect 的 UnitPoint
    private func imageRotationAnchor(clip: ImageClip, info: RenderInfo, in size: CGSize) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        let vs = info.renderArea.width / info.videoSize.width
        let cx = info.videoSize.width / 2 + clip.offsetX * info.videoSize.width
        let cy = info.videoSize.height / 2 + clip.offsetY * info.videoSize.height
        return UnitPoint(x: (cx * vs + info.renderArea.origin.x) / size.width,
                         y: (cy * vs + info.renderArea.origin.y) / size.height)
    }

    // MARK: - 移动手势（含 tap 穿透）
    @State private var multiStart: [UUID: CGPoint] = [:]

    private func moveDrag(clip: ImageClip, info: RenderInfo, rect: CGRect, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if dragMode == .none && dist > 3 {
                    pushUndoOnce()
                    dragMode = .move
                    NSCursor.closedHand.set()
                    dragStartOffset = CGPoint(x: clip.offsetX, y: clip.offsetY)
                    multiStart.removeAll()
                    if project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id) {
                        for id in project.selectedClipIDs where id != clip.id {
                            if let sc = project.shapeTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: sc.posX, y: sc.posY)
                            } else if let tc = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: tc.posX, y: tc.posY)
                            } else if let ic = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                                multiStart[id] = CGPoint(x: ic.offsetX, y: ic.offsetY)
                            }
                        }
                    }
                }
                guard dragMode == .move else { return }
                let dx = value.translation.width / info.renderArea.width
                let dy = value.translation.height / info.renderArea.height
                project.updateImageClip(id: clip.id) {
                    $0.offsetX = dragStartOffset.x + dx
                    $0.offsetY = dragStartOffset.y + dy
                }
                let ndx = value.translation.width / viewSize.width
                let ndy = value.translation.height / viewSize.height
                for (id, s) in multiStart {
                    if project.shapeTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateShapeClip(id: id) { $0.posX = min(1, max(0, s.x + ndx)); $0.posY = min(1, max(0, s.y + ndy)) }
                    } else if project.textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateTextClip(id: id) { $0.posX = min(1, max(0, s.x + ndx)); $0.posY = min(1, max(0, s.y + ndy)) }
                    } else if project.imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                        project.updateImageClip(id: id) { $0.offsetX = s.x + dx; $0.offsetY = s.y + dy }
                    }
                }
                project.rebuildTimelinePreviewDebounced()
            }
            .onEnded { value in
                if dragMode == .move {
                    dragMode = .none; didPushUndo = false; multiStart.removeAll()
                    NSCursor.openHand.set()
                    project.rebuildTimelinePreview()
                } else {
                    project.tapThroughSelect(at: value.location, viewSize: viewSize,
                                             time: clock.currentTime, currentClipID: clip.id)
                }
            }
    }

    // MARK: - 缩放手势
    // MARK: - 撤销
    private func pushUndoOnce() {
        guard !didPushUndo else { return }
        project.pushUndo()
        didPushUndo = true
    }

    // MARK: - 手柄


    /// 四边裁剪手柄 — 橙色长细条，加大点击区域

    // MARK: - 位置计算

    struct RenderInfo {
        var renderArea: CGRect
        var videoSize: CGSize
    }

    private func computeRenderInfo(viewSize: CGSize) -> RenderInfo {
        let videoW = project.previewRenderSize.width
        let videoH = project.previewRenderSize.height
        let s = min(viewSize.width / videoW, viewSize.height / videoH)
        let w = videoW * s; let h = videoH * s
        return RenderInfo(
            renderArea: CGRect(x: (viewSize.width - w)/2, y: (viewSize.height - h)/2, width: w, height: h),
            videoSize: CGSize(width: videoW, height: videoH))
    }

    /// - Parameter applyCrop: false 时返回**裁剪之前**的整幅矩形。
    ///   `TransformBox` 要的是完整框加裁剪比例，自己算露出来的那块
    private func computeImageRect(clip: ImageClip, info: RenderInfo,
                                  applyCrop: Bool = true) -> CGRect {
        let imgW = CGFloat(clip.imageWidth)
        let imgH = CGFloat(clip.imageHeight)
        guard imgW > 0, imgH > 0 else { return .zero }

        // Scale based on FULL image (crop does NOT affect scale)
        // 按旋转后的朝向 fit，跟 ImageLayerView 的渲染保持一致
        let fitSize = rotatedFitSize(CGSize(width: imgW, height: imgH), rotation: clip.rotation)
        let baseScale = min(info.videoSize.width / fitSize.width, info.videoSize.height / fitSize.height)
        let finalSX = baseScale * clip.scaleX
        let finalSY = baseScale * clip.scaleY

        // Full image position in video coords
        let fullW = imgW * finalSX
        let fullH = imgH * finalSY
        let cx = info.videoSize.width / 2 + clip.offsetX * info.videoSize.width
        let cy = info.videoSize.height / 2 + clip.offsetY * info.videoSize.height
        let fullLeft = cx - fullW / 2
        let fullTop  = cy - fullH / 2

        // Crop region within the full image (in video coords)
        let cropX = applyCrop ? fullLeft + imgW * CGFloat(clip.cropLeft) * finalSX : fullLeft
        let cropY = applyCrop ? fullTop  + imgH * CGFloat(clip.cropTop)  * finalSY : fullTop
        let cropW = applyCrop ? imgW * (1 - CGFloat(clip.cropLeft + clip.cropRight))  * finalSX : fullW
        let cropH = applyCrop ? imgH * (1 - CGFloat(clip.cropTop  + clip.cropBottom)) * finalSY : fullH
        guard cropW > 0, cropH > 0 else { return .zero }

        let vs = info.renderArea.width / info.videoSize.width
        return CGRect(
            x: info.renderArea.minX + cropX * vs,
            y: info.renderArea.minY + cropY * vs,
            width: cropW * vs, height: cropH * vs)
    }
}

/// Cursor modifier for macOS
private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Shape Overlay（图形渲染 + 拖动移动 + 选中）

private struct ShapeShadow: ViewModifier {
    let clip: ShapeClip
    let scale: CGFloat
    func body(content: Content) -> some View {
        if clip.shadowEnabled {
            content.compositingGroup()
                .shadow(color: clip.shadowColor.opacity(clip.shadowOpacity),
                        radius: clip.shadowRadius * scale,
                        x: clip.shadowOffsetX * scale,
                        y: clip.shadowOffsetY * scale)
        } else {
            content
        }
    }
}

/// 图形裁剪：按 0~1 比例从四边往里裁。没裁剪时原样返回，
/// 免得每个图形都白套一层 GeometryReader
private struct ShapeCropMask: ViewModifier {
    let clip: ShapeClip

    func body(content: Content) -> some View {
        if clip.cropTop <= 0, clip.cropBottom <= 0, clip.cropLeft <= 0, clip.cropRight <= 0 {
            content
        } else {
            content.mask(
                GeometryReader { g in
                    Rectangle()
                        .padding(.top, g.size.height * clip.cropTop)
                        .padding(.bottom, g.size.height * clip.cropBottom)
                        .padding(.leading, g.size.width * clip.cropLeft)
                        .padding(.trailing, g.size.width * clip.cropRight)
                }
            )
        }
    }
}

struct ShapeClipView: View {
    let clip: ShapeClip
    let scale: CGFloat
    var selected: Bool = false
    /// 同 `TextLabel.applyRotation`：渲染出图时关掉，交给画布上下文转
    var applyRotation: Bool = true

    var body: some View {
        let w = max(clip.width * clip.scaleX * scale, 2)
        let h = max(clip.height * clip.scaleY * scale, 2)
        shapeBody(w: w, h: h)
            .frame(width: w, height: h)
            .modifier(ShapeCropMask(clip: clip))
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accent.opacity(0.9), lineWidth: 1.5)
                }
            }
            .modifier(ShapeShadow(clip: clip, scale: scale))
            .frame(width: max(w, 28), height: max(h, 28))   // 扩大点击热区（线段等细图形好点）
            .contentShape(Rectangle())
            .scaleEffect(x: clip.mirrorH ? -1 : 1, y: clip.mirrorV ? -1 : 1)
            .rotationEffect(.degrees(applyRotation ? clip.rotation : 0))
            .opacity(clip.opacity)
    }

    @ViewBuilder
    private func shapeBody(w: CGFloat, h: CGFloat) -> some View {
        if clip.type == .pen {
            penBody(w: w, h: h)
        } else if !clip.type.isClosed {
            lineBody(w: w, h: h)
        } else if clip.type == .rectangle && clip.cornerRadius > 0 {
            let rr = RoundedRectangle(cornerRadius: min(clip.cornerRadius * scale, min(w, h) / 2))
            ZStack {
                if clip.fillEnabled { rr.fill(clip.fillColor.opacity(clip.fillOpacity)) }
                if clip.strokeEnabled {
                    rr.stroke(clip.strokeColor.opacity(clip.strokeOpacity),
                              style: StrokeStyle(lineWidth: clip.strokeWidth * scale,
                                                 dash: clip.strokeDashed ? [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale] : []))
                }
            }
        } else {
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path: Path = (clip.cornerRadius > 0 ? ShapeGeometry.polygonPoints(for: clip.type, in: rect) : nil)
                .map { ShapeGeometry.roundedPolygon($0, radius: clip.cornerRadius * scale) }
                ?? ShapeGeometry.path(for: clip.type, in: rect)
            ZStack {
                if clip.fillEnabled && clip.type.isClosed {
                    path.fill(clip.fillColor.opacity(clip.fillOpacity))
                }
                if clip.strokeEnabled || !clip.type.isClosed {
                    path.stroke(clip.strokeColor.opacity(clip.strokeOpacity),
                                style: StrokeStyle(lineWidth: max(clip.strokeWidth * scale, 1),
                                                   lineCap: .round, lineJoin: .round,
                                                   dash: clip.strokeDashed ? [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale] : []))
                }
            }
        }
    }

    @ViewBuilder
    private func penBody(w: CGFloat, h: CGFloat) -> some View {
        if let pts = clip.penPoints, pts.count >= 2 {
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path = ShapeGeometry.penPath(points: pts, closed: clip.penClosed, in: rect)
            ZStack {
                if clip.fillEnabled && clip.effectiveIsClosed {
                    path.fill(clip.fillColor.opacity(clip.fillOpacity))
                }
                if clip.strokeEnabled {
                    path.stroke(clip.strokeColor.opacity(clip.strokeOpacity),
                                style: StrokeStyle(lineWidth: max(clip.strokeWidth * scale, 1),
                                                   lineCap: .round, lineJoin: .round,
                                                   dash: clip.strokeDashed ? [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale] : []))
                }
            }
        }
    }

    // 线段/箭头：主干 + 两端端点样式（无端点/箭头/圆头/方头）
    @ViewBuilder
    private func lineBody(w: CGFloat, h: CGFloat) -> some View {
        let y = h / 2
        let sw = max(clip.strokeWidth * scale, 1)
        let col = clip.strokeColor.opacity(clip.strokeOpacity)
        let headLen = min(max(w * 0.42, sw * 3), h * 1.6) * 0.5
        let startInset = clip.capStart == .arrow ? headLen : 0
        let endInset = clip.capEnd == .arrow ? headLen : 0
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: startInset, y: y))
                p.addLine(to: CGPoint(x: max(w - endInset, startInset), y: y))
            }
            .stroke(col, style: StrokeStyle(lineWidth: sw, lineCap: .butt,
                                            dash: clip.strokeDashed ? [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale] : []))
            capShape(clip.capStart, at: CGPoint(x: 0, y: y), dir: -1, sw: sw, headLen: headLen, col: col)
            capShape(clip.capEnd, at: CGPoint(x: w, y: y), dir: 1, sw: sw, headLen: headLen, col: col)
        }
    }

    @ViewBuilder
    private func capShape(_ cap: LineCapStyle, at pt: CGPoint, dir: CGFloat, sw: CGFloat, headLen: CGFloat, col: Color) -> some View {
        switch cap {
        case .none:
            EmptyView()
        case .round:
            Circle().fill(col).frame(width: headLen, height: headLen).position(pt)
        case .square:
            Rectangle().fill(col).frame(width: headLen, height: headLen).position(pt)
        case .arrow:
            let wing = headLen * 0.5
            Path { p in
                p.move(to: CGPoint(x: pt.x - dir * headLen, y: pt.y - wing))
                p.addLine(to: pt)
                p.addLine(to: CGPoint(x: pt.x - dir * headLen, y: pt.y + wing))
                p.closeSubpath()
            }.fill(col)
        }
    }
}

private struct ShapeOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @State private var dragStart: [UUID: CGPoint] = [:]

    private var activeClips: [ShapeClip] {
        project.shapeTracks
            .filter { $0.isVisible }
            .flatMap { $0.clips }
            .filter { $0.startTime <= clock.currentTime && $0.endTime > clock.currentTime }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(project.previewRenderSize.width, 1)
            ZStack {
                // 有选中图形时，点击空白处取消选择
                if project.selectedShapeClipID != nil {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture {
                            project.selectedShapeClipID = nil
                            project.selectedClipIDs.removeAll()
                        }
                }
                ForEach(activeClips, id: \.id) { clip in
                    ShapeClipView(clip: clip, scale: scale,
                                  selected: project.selectedClipIDs.count > 1 && project.selectedClipIDs.contains(clip.id))
                        .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { v in
                                    if dragStart.isEmpty {
                                        let multi = project.selectedClipIDs.contains(clip.id) && project.selectedClipIDs.count > 1
                                        if multi {
                                            for id in project.selectedClipIDs {
                                                if let c = shapeByID(id) { dragStart[id] = CGPoint(x: c.posX, y: c.posY) }
                                            }
                                        } else {
                                            if project.selectedShapeClipID != clip.id { selectExclusive(clip.id) }
                                            if let c = shapeByID(clip.id) { dragStart[clip.id] = CGPoint(x: c.posX, y: c.posY) }
                                        }
                                    }
                                    let dx = v.translation.width / geo.size.width
                                    let dy = v.translation.height / geo.size.height
                                    for (id, s) in dragStart {
                                        project.updateShapeClip(id: id) {
                                            $0.posX = min(1, max(0, Double(s.x) + Double(dx)))
                                            $0.posY = min(1, max(0, Double(s.y) + Double(dy)))
                                        }
                                    }
                                }
                                .onEnded { _ in dragStart = [:] }
                        )
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.shift) {
                                project.shiftCycleOverlapping(clip.id)
                            } else {
                                selectExclusive(clip.id)
                            }
                        }
                }
            }
        }
    }

    private func selectExclusive(_ id: UUID) {
        project.selectedShapeClipID = id
        project.selectedVideoClipID = nil; project.selectedImageClipID = nil
        project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil
        project.selectedTextClipID = nil
    }

    private func shapeByID(_ id: UUID) -> ShapeClip? {
        project.shapeTracks.flatMap { $0.clips }.first { $0.id == id }
    }
}

// MARK: - Text Transform Overlay

/// 文字的选中框（四角圆点 + 四边横条 + 旋转手柄）。预览区和封面弹窗共用。
///
/// 横条**两种状态两种含义**：
/// - 没进编辑态（无光标）：裁剪，可以只露出半个字，裁掉的不显示
/// - 双击进编辑态（有光标）：拖文本框大小，字号不变
///
/// 四角圆点两种状态下都在（改字号）
///
/// 两个可选参数同 `PenDrawingOverlay`：画谁（`clipOverride`）、改动写给谁
/// （`onUpdate`）。都不传就是预览区那条老路
struct TextTransformOverlay: View {
    var clipOverride: TextClip? = nil
    var onUpdate: ((UUID, @escaping (inout TextClip) -> Void) -> Void)? = nil
    /// 外部指定的编辑态。封面弹窗自己管输入框，走不了 `project.editingTextClipID`
    var forceEditing = false

    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    @State private var didPushUndo = false
    @State private var startFontSize: CGFloat = 64
    @State private var startRotation = 0.0
    // 起手时的文本框尺寸。拖过边之后框是定死的，四角缩放要连框一起放大，
    // 否则字变大了框还在原地，跟图片、图形不是一个手感
    @State private var startBoxW: Double? = nil
    @State private var startBoxH: Double? = nil

    private let accent = Color.accent

    var body: some View {
        GeometryReader { geo in
            if let clip = resolvedClip {
                let scale = geo.size.width / max(project.previewRenderSize.width, 1)
                let center = CGPoint(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                // 拖过边就**以范围框为准**，裁剪框跟着它走；
                // 没拖过才用实测尺寸（文字自适应，测出来的才准）
                let measured = (clip.boxWidth == nil && clip.boxHeight == nil && clipOverride == nil)
                    ? project.textClipViewSizes[clip.id] : nil
                let sz = measured ?? textBoundsSize(clip: clip, scale: scale)
                let w = max(sz.width, 8)
                let h = max(sz.height, 8)

                let editing = forceEditing || (clipOverride == nil && project.editingTextClipID == clip.id)
                // 跟图片、图形同一个框组件。文字多的那个编辑态：
                // 裁剪条收起来，四条边改成拖文本框大小
                TransformBox(
                    center: center,
                    size: CGSize(width: w, height: h),
                    rotation: clip.rotation,
                    crop: TransformCrop(top: clip.cropTop, bottom: clip.cropBottom,
                                        left: clip.cropLeft, right: clip.cropRight),
                    editing: editing,
                    showBorder: !editing,
                    onBegin: {
                        pushUndoOnce()
                        startFontSize = clip.fontSize
                        startRotation = clip.rotation
                        startBoxW = clip.boxWidth
                        startBoxH = clip.boxHeight
                    },
                    onEnd: { didPushUndo = false; startBoxW = nil; startBoxH = nil },
                    onScale: { ratio in
                        update(clip.id) {
                            $0.fontSize = max(8, startFontSize * CGFloat(ratio))
                            // 拖过边的文本框是定死尺寸的，得跟着一起放大
                            if let bw = startBoxW { $0.boxWidth = max(8, bw * ratio) }
                            if let bh = startBoxH { $0.boxHeight = max(8, bh * ratio) }
                        }
                    },
                    onCrop: { e, value in
                        update(clip.id) {
                            switch e {
                            case 0: $0.cropTop = value
                            case 1: $0.cropBottom = value
                            case 2: $0.cropLeft = value
                            default: $0.cropRight = value
                            }
                        }
                    },
                    onRotate: { delta in
                        update(clip.id) { $0.rotation = startRotation + delta }
                    },
                    onEdgeResize: { e, d in
                        // 对边不动，只有拖的这条边跟着走，中心补到两边中点。
                        // padding 是框比文字多出来的一圈，扣掉再写回 boxWidth/boxHeight
                        let padH = 20 * scale, padV = 10 * scale
                        let vertical = e < 2
                        let half = vertical ? h / 2 : w / 2
                        let fixed = (e == 0 || e == 2) ? half : -half
                        let moving = min(max(vertical ? d.y : d.x, -half * 8), half * 8)
                        let newLen = max(abs(moving - fixed), 16)
                        let midLocal = (moving + fixed) / 2
                        let back = rotate(vertical ? 0 : midLocal,
                                          vertical ? midLocal : 0, clip.rotation)
                        update(clip.id) {
                            if vertical { $0.boxHeight = Double(max(newLen - padV, 8) / scale) }
                            else { $0.boxWidth = Double(max(newLen - padH, 8) / scale) }
                            $0.posX = min(1, max(0, Double((center.x + back.x) / max(geo.size.width, 1))))
                            $0.posY = min(1, max(0, Double((center.y + back.y) / max(geo.size.height, 1))))
                        }
                    }
                )
            }
        }
    }

    /// 画谁：外部指定优先，否则是时间轴上选中且当前时刻可见的那条
    private var resolvedClip: TextClip? {
        if let c = clipOverride { return c }
        guard let c = project.selectedTextClip,
              c.startTime <= clock.currentTime, c.endTime > clock.currentTime,
              project.selectedClipIDs.count <= 1 else { return nil }
        return c
    }

    /// 改动写给谁：外部接管就交出去，否则写时间轴
    private func update(_ id: UUID, _ f: @escaping (inout TextClip) -> Void) {
        if let onUpdate { onUpdate(id, f) } else { project.updateTextClip(id: id, f) }
    }

    private func rotate(_ dx: CGFloat, _ dy: CGFloat, _ deg: Double) -> CGPoint {
        let r = CGFloat(deg * .pi / 180)
        return CGPoint(x: dx * cos(r) - dy * sin(r), y: dx * sin(r) + dy * cos(r))
    }

    private func textBoundsSize(clip: TextClip, scale: CGFloat) -> CGSize {
        let fs = clip.fontSize * scale
        var font = NSFont(name: clip.fontName, size: fs)
        if font == nil { font = NSFont.systemFont(ofSize: fs) }
        if clip.bold, let f = font {
            font = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        }
        let text = clip.text.isEmpty ? " " : clip.text
        let size = (text as NSString).size(withAttributes: [.font: font!])
        // 拖过边就以文本框尺寸为准，裁剪和手柄都跟着它走
        return CGSize(width: clip.boxWidth.map { CGFloat($0) * scale + 20 * scale } ?? size.width + 20 * scale,
                      height: clip.boxHeight.map { CGFloat($0) * scale + 10 * scale } ?? size.height + 10 * scale)
    }

    private func pushUndoOnce() {
        // 外部接管时撤销由外部管（封面弹窗是取消/确认，没有撤销栈）
        guard clipOverride == nil else { return }
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

}

// MARK: - Shape Transform Overlay（选中边框；缩放/旋转手柄见 2b）

/// 图形的选中框（四角圆点 + 四边缩放条 + 旋转手柄）。预览区和封面弹窗共用。
///
/// 两个可选参数同 `TextTransformOverlay`：画谁、改动写给谁
struct ShapeTransformOverlay: View {
    var clipOverride: ShapeClip? = nil
    var onUpdate: ((UUID, @escaping (inout ShapeClip) -> Void) -> Void)? = nil

    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.windowID) private var windowID

    @State private var dragMode = 0   // 0=none 1=scale 2=rotate 3=endpoint
    @State private var didPushUndo = false
    @State private var startClip: ShapeClip? = nil
    @State private var startRotation = 0.0
    @State private var startAngle = 0.0
    @State private var penKeyMon: Any? = nil

    private let accent = Color.accent

    var body: some View {
        GeometryReader { geo in
            if let clip = resolvedClip {
                let scale = geo.size.width / max(project.previewRenderSize.width, 1)
                let center = CGPoint(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                let w = max(clip.width * clip.scaleX * scale, 8)
                let h = max(clip.height * clip.scaleY * scale, 8)
                // 框贴**裁剪后露出来的那块**，跟图片、文字一致
                let vw = max(w * (1 - clip.cropLeft - clip.cropRight), 8)
                let vh = max(h * (1 - clip.cropTop - clip.cropBottom), 8)
                let coff = rotate(w * (clip.cropLeft - clip.cropRight) / 2,
                                  h * (clip.cropTop - clip.cropBottom) / 2,
                                  clip.rotation)
                let vc = CGPoint(x: center.x + coff.x, y: center.y + coff.y)
                ZStack {
                    if clip.effectiveIsClosed || clip.type == .pen {
                        // 跟图片、文字同一个框组件：四角缩放、四边裁剪、上方旋转
                        TransformBox(
                            center: center,
                            size: CGSize(width: w, height: h),
                            rotation: clip.rotation,
                            crop: TransformCrop(top: clip.cropTop, bottom: clip.cropBottom,
                                                left: clip.cropLeft, right: clip.cropRight),
                            onBegin: {
                                pushUndoOnce()
                                startClip = clip
                                startRotation = clip.rotation
                            },
                            onEnd: { didPushUndo = false; startClip = nil },
                            onScale: { ratio in
                                guard let sc = startClip else { return }
                                update(clip.id) {
                                    $0.scaleX = max(0.05, sc.scaleX * ratio)
                                    $0.scaleY = max(0.05, sc.scaleY * ratio)
                                }
                            },
                            onCrop: { e, value in
                                update(clip.id) {
                                    switch e {
                                    case 0: $0.cropTop = value
                                    case 1: $0.cropBottom = value
                                    case 2: $0.cropLeft = value
                                    default: $0.cropRight = value
                                    }
                                }
                            },
                            onRotate: { delta in
                                update(clip.id) { $0.rotation = startRotation + delta }
                            }
                        )
                    } else {
                        // 线段、箭头没有面积，给的是两端控制点（拖动改长度/方向/位置）
                        Rectangle().stroke(accent, lineWidth: 1.5)
                            .frame(width: vw, height: vh)
                            .rotationEffect(.degrees(clip.rotation))
                            .position(vc)
                            .allowsHitTesting(false)
                        let pL = endpoint(center: vc, w: vw, rot: clip.rotation, right: false)
                        let pR = endpoint(center: vc, w: vw, rot: clip.rotation, right: true)
                        handleDot().position(pL)
                            .gesture(endpointGesture(clip: clip, fixed: pR, draggingRight: false, scale: scale, geo: geo.size))
                        handleDot().position(pR)
                            .gesture(endpointGesture(clip: clip, fixed: pL, draggingRight: true, scale: scale, geo: geo.size))

                        rotHandleView()
                            .position(rotationHandlePos(center: vc, h: vh, rot: clip.rotation))
                            .gesture(rotateGesture(clip: clip, center: center))
                    }
                }
                // 回车进钢笔编辑是时间轴那条路的事，封面弹窗不装这个监听
                .onAppear { if clipOverride == nil { installPenEnterMonitor() } }
                .onDisappear { removePenEnterMonitor() }
            }
        }
    }

    private func installPenEnterMonitor() {
        removePenEnterMonitor()
        penKeyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // local monitor 是进程级的，每个窗口都装一个。不按当前窗口过滤的话，
            // 两个窗口都选中钢笔片段时按一次回车，两边会一起进编辑态
            guard WindowManager.shared.window(for: windowID)?.isKeyWindow == true else {
                return event
            }
            guard event.keyCode == 36,  // Enter
                  project.penEditingClipID == nil,
                  !project.penDrawingMode,
                  let clip = project.selectedShapeClip,
                  clip.type == .pen else { return event }
            project.penEditingClipID = clip.id
            return nil
        }
    }
    private func removePenEnterMonitor() {
        if let m = penKeyMon { NSEvent.removeMonitor(m); penKeyMon = nil }
    }

    // MARK: 手柄视图

    private func handleDot() -> some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 11, height: 11)
            Circle().stroke(accent, lineWidth: 1.5).frame(width: 11, height: 11)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }

    private func rotHandleView() -> some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 14, height: 14)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold)).foregroundColor(accent)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
    }

    // MARK: 位置计算

    private func rotate(_ dx: CGFloat, _ dy: CGFloat, _ deg: Double) -> CGPoint {
        let r = CGFloat(deg * .pi / 180)
        return CGPoint(x: dx * cos(r) - dy * sin(r), y: dx * sin(r) + dy * cos(r))
    }
    private func rotatedCorner(_ i: Int, center: CGPoint, w: CGFloat, h: CGFloat, rot: Double) -> CGPoint {
        let hw = w / 2, hh = h / 2
        let offs = [(-hw, -hh), (hw, -hh), (-hw, hh), (hw, hh)][i]
        let p = rotate(offs.0, offs.1, rot)
        return CGPoint(x: center.x + p.x, y: center.y + p.y)
    }
    private func endpoint(center: CGPoint, w: CGFloat, rot: Double, right: Bool) -> CGPoint {
        let p = rotate(right ? w / 2 : -w / 2, 0, rot)
        return CGPoint(x: center.x + p.x, y: center.y + p.y)
    }
    private func rotationHandlePos(center: CGPoint, h: CGFloat, rot: Double) -> CGPoint {
        let p = rotate(0, -h / 2 - 26, rot)
        return CGPoint(x: center.x + p.x, y: center.y + p.y)
    }
    private func edgeMid(_ e: Int, center: CGPoint, w: CGFloat, h: CGFloat, rot: Double) -> CGPoint {
        let offs = [(0, -h / 2), (0, h / 2), (-w / 2, 0), (w / 2, 0)][e]
        let p = rotate(offs.0, offs.1, rot)
        return CGPoint(x: center.x + p.x, y: center.y + p.y)
    }
    private func edgeBar(horizontal: Bool, length: CGFloat, rot: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color.orange)
            .frame(width: horizontal ? length : 3, height: horizontal ? 3 : length)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            // 热区比视觉宽是为了好抓，但别宽过头：边条盖在别的图层上时，会把
            // 露在外面那一溜窄区也吃掉，导致点不中下层（图形压着文字最明显）
            .frame(width: horizontal ? length + 8 : 10, height: horizontal ? 10 : length + 8)
            .contentShape(Rectangle())
            .onHover { h in
                guard h else { NSCursor.arrow.set(); return }
                // 转了 90°/270° 之后，横条实际是在左右拉，光标要跟着换
                let quarter = Int((rot / 90).rounded()) % 2 != 0
                let vertical = horizontal != quarter
                (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            }
            .rotationEffect(.degrees(rot))
    }

    /// 画谁：外部指定优先，否则是时间轴上选中且当前时刻可见的那条
    private var resolvedClip: ShapeClip? {
        if let c = clipOverride { return c }
        guard let c = project.selectedShapeClip,
              c.startTime <= clock.currentTime, c.endTime > clock.currentTime,
              !project.penDrawingMode, project.penEditingClipID != c.id,
              project.selectedClipIDs.count <= 1 else { return nil }
        return c
    }

    /// 改动写给谁：外部接管就交出去，否则写时间轴
    private func update(_ id: UUID, _ f: @escaping (inout ShapeClip) -> Void) {
        if let onUpdate { onUpdate(id, f) } else { project.updateShapeClip(id: id, f) }
    }

    private func pushUndoOnce() {
        // 外部接管时撤销由外部管（封面弹窗是取消/确认，没有撤销栈）
        guard clipOverride == nil else { return }
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

    private func edgeNormal(_ e: Int, _ rot: Double) -> CGPoint {
        let base = [(CGFloat(0), CGFloat(-1)), (0, 1), (-1, 0), (1, 0)][e]
        return rotate(base.0, base.1, rot)
    }

    /// 拖四边横条 = 裁剪。比例相对**没裁之前**的完整框算，留 5% 免得裁没了。
    ///
    /// 以前这里是单向缩放（改 scaleX/scaleY），现在不等比缩放统一走属性区那两个滑块
    private func edgeCropGesture(clip: ShapeClip, center: CGPoint,
                                 edge: Int, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 1 { pushUndoOnce(); dragMode = 1; startClip = clip }
                guard let sc = startClip else { return }
                // 转回图形自己的坐标系，转过角度之后拖边才跟手
                let d = rotate(v.location.x - center.x, v.location.y - center.y, -clip.rotation)
                update(clip.id) {
                    switch edge {
                    case 0: $0.cropTop = min(max(Double((d.y + h / 2) / h), 0), 1 - sc.cropBottom - 0.05)
                    case 1: $0.cropBottom = min(max(Double((h / 2 - d.y) / h), 0), 1 - sc.cropTop - 0.05)
                    case 2: $0.cropLeft = min(max(Double((d.x + w / 2) / w), 0), 1 - sc.cropRight - 0.05)
                    default: $0.cropRight = min(max(Double((w / 2 - d.x) / w), 0), 1 - sc.cropLeft - 0.05)
                    }
                }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false; startClip = nil }
    }

    // MARK: 手势

    private func scaleGesture(clip: ShapeClip, center: CGPoint, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 1 { pushUndoOnce(); dragMode = 1; startClip = clip }
                guard let sc = startClip else { return }
                let d0 = hypot(v.startLocation.x - center.x, v.startLocation.y - center.y)
                let d1 = hypot(v.location.x - center.x, v.location.y - center.y)
                guard d0 > 1 else { return }
                let ratio = d1 / d0
                update(clip.id) {
                    $0.scaleX = max(0.05, sc.scaleX * ratio)
                    $0.scaleY = max(0.05, sc.scaleY * ratio)
                }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false; startClip = nil }
    }

    private func rotateGesture(clip: ShapeClip, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 2 {
                    pushUndoOnce(); dragMode = 2
                    startRotation = clip.rotation
                    startAngle = atan2(Double(v.startLocation.y - center.y), Double(v.startLocation.x - center.x)) * 180 / .pi
                }
                let cur = atan2(Double(v.location.y - center.y), Double(v.location.x - center.x)) * 180 / .pi
                update(clip.id) { $0.rotation = startRotation + (cur - startAngle) }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false }
    }

    private func endpointGesture(clip: ShapeClip, fixed: CGPoint, draggingRight: Bool,
                                 scale: CGFloat, geo: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 3 { pushUndoOnce(); dragMode = 3; startClip = clip }
                guard let sc = startClip else { return }
                let drag = v.location
                let viewLen = hypot(drag.x - fixed.x, drag.y - fixed.y)
                // 方向：从左端指向右端
                let dir = draggingRight
                    ? atan2(Double(drag.y - fixed.y), Double(drag.x - fixed.x))
                    : atan2(Double(fixed.y - drag.y), Double(fixed.x - drag.x))
                let newCenter = CGPoint(x: (fixed.x + drag.x) / 2, y: (fixed.y + drag.y) / 2)
                let newWidth = max(viewLen / (sc.scaleX * scale), 10)
                update(clip.id) {
                    $0.width = newWidth
                    $0.rotation = dir * 180 / .pi
                    $0.posX = min(1, max(0, newCenter.x / geo.width))
                    $0.posY = min(1, max(0, newCenter.y / geo.height))
                }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false; startClip = nil }
    }
}

// MARK: - Pen Drawing Overlay（钢笔绘制模式）

/// 钢笔绘制层。预览区和封面弹窗**共用这一份** —— 手感、控制柄、闭合判定、
/// 键盘监听全都一样，不另写一套。
///
/// 两个可选参数是给封面弹窗留的口子：
/// 画哪条图形（`forcedClipID`），以及画完之后把点交给谁（`onFinalize`）。
/// 都不传就是预览区那条老路：画时间轴上选中的图形、写进 `shapeTracks`
struct PenDrawingOverlay: View {
    var forcedClipID: UUID? = nil
    var onFinalize: ((_ rawPoints: [(x: Double, y: Double, cInDX: Double, cInDY: Double,
                                     cOutDX: Double, cOutDY: Double, smooth: Bool)],
                      _ closed: Bool) -> Void)? = nil

    @EnvironmentObject private var project: ProjectState
    @Environment(\.windowID) private var windowID
    @State private var draggingHandle = false
    @State private var dragStartPos: CGPoint? = nil
    @State private var dragCurrentPos: CGPoint? = nil
    @State private var hoverPos: CGPoint? = nil
    @State private var keyMonitor: Any? = nil

    var body: some View {
        GeometryReader { geo in
            // 封面弹窗在画钢笔时，**预览区这层必须让开** —— 绘制中的点存在
            // 共享的 `project.penRawPoints` 里，两层同时活着会各画各的，
            // 回车还会把时间轴上选中的那条图形一起改掉
            if project.penDrawingMode,
               !(forcedClipID == nil && project.showCoverDesigner),
               let clipID = forcedClipID ?? project.selectedShapeClipID {
                let vs = geo.size
                ZStack {
                    Color.black.opacity(0.01).contentShape(Rectangle())
                        .gesture(penGesture(vs: vs, clipID: clipID))
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                hoverPos = pt
                                Self.penCursor.set()
                            case .ended:
                                hoverPos = nil
                                NSCursor.arrow.set()
                            @unknown default: break
                            }
                        }
                    drawingPath(vs: vs)
                    anchorDots(vs: vs, clipID: clipID)
                }
                .onAppear { installKeyMonitor(clipID: clipID) }
                .onDisappear { NSCursor.arrow.set(); removeKeyMonitor() }
            }
        }
    }

    private func penGesture(vs: CGSize, clipID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dist = hypot(v.translation.width, v.translation.height)
                if dist > 3 {
                    draggingHandle = true
                    dragStartPos = v.startLocation
                    dragCurrentPos = v.location
                }
            }
            .onEnded { v in
                let scaleX = max(project.previewRenderSize.width, 1) / vs.width
                let scaleY = max(project.previewRenderSize.height, 1) / vs.height
                let cx = Double(v.startLocation.x) * scaleX
                let cy = Double(v.startLocation.y) * scaleY
                let dist = hypot(v.translation.width, v.translation.height)

                if !project.penRawPoints.isEmpty {
                    let first = project.penRawPoints[0]
                    let dx = cx - first.x, dy = cy - first.y
                    if hypot(dx, dy) < 12 * max(scaleX, scaleY) {
                        finalize(clipID: clipID, closed: true)
                        project.penRawPoints = []; draggingHandle = false; dragStartPos = nil; dragCurrentPos = nil
                        return
                    }
                }

                if dist > 3 {
                    let hdx = Double(v.translation.width) * scaleX
                    let hdy = Double(v.translation.height) * scaleY
                    project.penRawPoints.append((x: cx, y: cy, cInDX: -hdx, cInDY: -hdy, cOutDX: hdx, cOutDY: hdy, smooth: true))
                } else {
                    project.penRawPoints.append((x: cx, y: cy, cInDX: 0, cInDY: 0, cOutDX: 0, cOutDY: 0, smooth: true))
                }
                project.objectWillChange.send()
                draggingHandle = false; dragStartPos = nil; dragCurrentPos = nil
            }
    }

    @ViewBuilder
    private func drawingPath(vs: CGSize) -> some View {
        let canvasW = max(Double(project.previewRenderSize.width), 1)
        let canvasH = max(Double(project.previewRenderSize.height), 1)
        let sx = vs.width / canvasW, sy = vs.height / canvasH
        Canvas { ctx, size in
            let col = Color.white
            // 已提交的路径段
            if !project.penRawPoints.isEmpty {
                var path = Path()
                for (i, pt) in project.penRawPoints.enumerated() {
                    let p = CGPoint(x: pt.x * sx, y: pt.y * sy)
                    if i == 0 { path.move(to: p) }
                    else {
                        let prev = project.penRawPoints[i - 1]
                        let pp = CGPoint(x: prev.x * sx, y: prev.y * sy)
                        let hasC = abs(prev.cOutDX) > 0.5 || abs(prev.cOutDY) > 0.5 || abs(pt.cInDX) > 0.5 || abs(pt.cInDY) > 0.5
                        if hasC {
                            path.addCurve(to: p,
                                          control1: CGPoint(x: pp.x + prev.cOutDX * sx, y: pp.y + prev.cOutDY * sy),
                                          control2: CGPoint(x: p.x + pt.cInDX * sx, y: p.y + pt.cInDY * sy))
                        } else { path.addLine(to: p) }
                    }
                }

                // 拖拽中：预览新点的曲线段
                if draggingHandle, let sp = dragStartPos, let cp = dragCurrentPos, let last = project.penRawPoints.last {
                    let lp = CGPoint(x: last.x * sx, y: last.y * sy)
                    let mirror = CGPoint(x: 2 * sp.x - cp.x, y: 2 * sp.y - cp.y)
                    let cp1 = CGPoint(x: lp.x + last.cOutDX * sx, y: lp.y + last.cOutDY * sy)
                    let hasLastOut = abs(last.cOutDX) > 0.5 || abs(last.cOutDY) > 0.5
                    if hasLastOut {
                        path.addCurve(to: sp, control1: cp1, control2: mirror)
                    } else {
                        path.addCurve(to: sp, control1: lp, control2: mirror)
                    }
                } else if let hp = hoverPos {
                    // 悬浮预览线
                    let last = project.penRawPoints.last!
                    let lp = CGPoint(x: last.x * sx, y: last.y * sy)
                    let hasOut = abs(last.cOutDX) > 0.5 || abs(last.cOutDY) > 0.5
                    if hasOut {
                        path.addCurve(to: hp,
                                      control1: CGPoint(x: lp.x + last.cOutDX * sx, y: lp.y + last.cOutDY * sy),
                                      control2: hp)
                    } else { path.addLine(to: hp) }
                }
                ctx.stroke(path, with: .color(col), lineWidth: 2)
            }

            // 已提交点的控制柄
            for pt in project.penRawPoints {
                let pp = CGPoint(x: pt.x * sx, y: pt.y * sy)
                if abs(pt.cOutDX) > 0.5 || abs(pt.cOutDY) > 0.5 {
                    let h1 = CGPoint(x: pp.x + pt.cOutDX * sx, y: pp.y + pt.cOutDY * sy)
                    let h2 = CGPoint(x: pp.x + pt.cInDX * sx, y: pp.y + pt.cInDY * sy)
                    var lp = Path(); lp.move(to: h2); lp.addLine(to: pp); lp.addLine(to: h1)
                    ctx.stroke(lp, with: .color(Color.orange.opacity(0.6)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: h1.x - 3.5, y: h1.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                    ctx.fill(Path(ellipseIn: CGRect(x: h2.x - 3.5, y: h2.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                }
            }

            // 拖拽中：实时显示新点的控制柄
            if draggingHandle, let sp = dragStartPos, let cp = dragCurrentPos {
                let mirror = CGPoint(x: 2 * sp.x - cp.x, y: 2 * sp.y - cp.y)
                var hl = Path(); hl.move(to: mirror); hl.addLine(to: sp); hl.addLine(to: cp)
                ctx.stroke(hl, with: .color(Color.orange.opacity(0.7)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: cp.x - 3.5, y: cp.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                ctx.fill(Path(ellipseIn: CGRect(x: mirror.x - 3.5, y: mirror.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x - 4.5, y: sp.y - 4.5, width: 9, height: 9)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: sp.x - 4.5, y: sp.y - 4.5, width: 9, height: 9)),
                           with: .color(Color.accentColor), lineWidth: 1.5)
            }

            // 闭合提示
            if project.penRawPoints.count >= 2 {
                let fp = CGPoint(x: project.penRawPoints[0].x * sx, y: project.penRawPoints[0].y * sy)
                let checkPos = draggingHandle ? dragStartPos : hoverPos
                if let cp = checkPos, hypot(cp.x - fp.x, cp.y - fp.y) < 12 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: fp.x - 8, y: fp.y - 8, width: 16, height: 16)),
                               with: .color(.green), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func anchorDots(vs: CGSize, clipID: UUID) -> some View {
        let sx = vs.width / max(Double(project.previewRenderSize.width), 1)
        let sy = vs.height / max(Double(project.previewRenderSize.height), 1)
        ForEach(Array(project.penRawPoints.enumerated()), id: \.offset) { i, pt in
            Circle().fill(Color.white).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.accent, lineWidth: 1.5))
                .position(x: pt.x * sx, y: pt.y * sy)
                .allowsHitTesting(false)
        }
    }

    private static let penSVGPath = "M517.888 193.664c29.44-11.776 62.72-6.208 86.656 13.952l5.376 4.928 201.6 201.6c22.4 22.4 30.4 55.168 21.248 85.12l-2.368 6.848-100.928 252.288c-11.52 28.8-37.696 49.024-68.48 52.928l-216.704 27.072c-5.568 0.64-11.456 1.472-17.536 2.368l-18.88 3.072-9.92 1.792-30.848 6.016-21.12 4.48-31.808 7.104-40.768 9.728-66.176 16.896-27.52 7.488a43.072 43.072 0 0 1-54.016-48.448l1.472-6.208 12.608-47.424 11.264-44.672 9.728-40.768 7.104-31.808 4.48-21.12 6.016-30.848 3.392-19.52 2.752-18.24 28.16-225.28c3.584-28.416 21.12-52.928 46.464-65.536l6.464-2.944 252.288-100.928z m31.68 79.168L297.28 373.76l-24.896 199.296-2.048 16.896c-3.328 27.2-9.344 60.096-16.384 93.568l-7.36 33.536 140.288-140.288a85.312 85.312 0 1 1 60.352 60.352l-140.288 140.288 16.704-3.712 33.472-7.04c22.144-4.48 43.52-8.32 62.848-11.136l230.272-28.8 100.864-252.288-201.536-201.6z m100.8-140.544a42.688 42.688 0 0 1 56.32-3.52l4.032 3.52 180.992 180.992a42.688 42.688 0 0 1-56.32 63.936l-4.032-3.584-180.992-180.992a42.688 42.688 0 0 1 0-60.352z"

    private static let penCursor: NSCursor = {
        let svg = """
        <svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="16" height="16">
        <g transform="rotate(90 512 512)">
        <path fill="rgba(0,0,0,0.5)" stroke="rgba(0,0,0,0.5)" stroke-width="60" stroke-linejoin="round" d="\(penSVGPath)"/>
        <path fill="white" d="\(penSVGPath)"/>
        </g>
        </svg>
        """
        guard let data = svg.data(using: .utf8),
              let img = NSImage(data: data) else { return .crosshair }
        img.isTemplate = false
        return NSCursor(image: img, hotSpot: NSPoint(x: 0, y: 0))
    }()

    private func installKeyMonitor(clipID: UUID) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 必须判状态，不能只靠"这个 monitor 只在绘制时安装"：local monitor 是
            // 进程级的，SwiftUI 的 onDisappear 漏触发一次它就永久留着，之后
            // 全 app 的 esc 和回车都会被这里吃掉（欢迎页 esc 关不掉窗口就是这么来的）
            //
            // 状态守卫挡不住多窗口：两个窗口可以同时处于绘制态，所以还要按窗口过滤
            guard WindowManager.shared.window(for: windowID)?.isKeyWindow == true else {
                return event
            }
            guard project.penDrawingMode else { return event }
            if event.keyCode == 53 || event.keyCode == 36 {
                if project.penRawPoints.count >= 2 {
                    finalize(clipID: clipID, closed: false)
                } else if onFinalize != nil {
                    // 外部接管时点数不够 = 放弃这次绘制，由外部自己收拾
                    onFinalize?([], false)
                    project.penDrawingMode = false
                } else {
                    project.cancelPenDrawing(clipID: clipID)
                }
                project.penRawPoints = []
                return nil
            }
            return event
        }
    }

    /// 收尾：外部接管就把原始点交出去，否则走时间轴那条老路
    private func finalize(clipID: UUID, closed: Bool) {
        if let onFinalize {
            onFinalize(project.penRawPoints, closed)
            project.penDrawingMode = false
        } else {
            project.finalizePenDrawing(clipID: clipID, rawPoints: project.penRawPoints, closed: closed)
        }
        project.penRawPoints = []
        draggingHandle = false
        dragStartPos = nil
        dragCurrentPos = nil
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Pen Edit Overlay（钢笔路径编辑模式）

/// 钢笔图形的锚点编辑层。
///
/// 两个可选参数跟 `ShapeTransformOverlay` 一样：改谁（`clipOverride`）、
/// 改动写给谁（`onUpdate`）。封面设计弹窗里的图形存在自己的 draft 里，
/// 不在 `project.shapeTracks` 上，靠这两个参数接进来
struct PenEditOverlay: View {
    var clipOverride: ShapeClip? = nil
    var onUpdate: ((UUID, @escaping (inout ShapeClip) -> Void) -> Void)? = nil
    /// 退出编辑态。不给就走 project.penEditingClipID
    var onExit: (() -> Void)? = nil

    @EnvironmentObject private var project: ProjectState
    @Environment(\.windowID) private var windowID
    @State private var didPushUndo = false
    /// 按下那一刻的锚点位置。**拖动全程锁住不刷新** ——
    /// 每帧都拿「当前最新的点」再加上完整位移的话，位移会被一遍遍累加上去，
    /// 表现就是控制点甩飞或者干脆不跟手
    @State private var dragOrigin: PenPoint?

    var body: some View {
        GeometryReader { geo in
            if let clip = clipOverride
                    ?? project.penEditingClipID.flatMap({ id in
                        project.shapeTracks.flatMap { $0.clips }.first { $0.id == id }
                    }),
               let pts = clip.penPoints, pts.count >= 2 {
                let vs = geo.size
                let scale = vs.width / max(project.previewRenderSize.width, 1)
                let cx = vs.width * clip.posX
                let cy = vs.height * clip.posY
                let fw = clip.width * clip.scaleX * scale
                let fh = clip.height * clip.scaleY * scale

                ZStack {
                    Color.black.opacity(0.01).contentShape(Rectangle())
                        .onTapGesture {
                            if let exit = onExit { exit() } else { project.penEditingClipID = nil }
                        }

                    ForEach(Array(pts.enumerated()), id: \.element.id) { i, pt in
                        let px = cx - fw / 2 + pt.x * fw
                        let py = cy - fh / 2 + pt.y * fh
                        let hOutX = px + pt.ctrlOutDX * fw
                        let hOutY = py + pt.ctrlOutDY * fh
                        let hInX = px + pt.ctrlInDX * fw
                        let hInY = py + pt.ctrlInDY * fh
                        let hasHandle = abs(pt.ctrlOutDX) > 1e-6 || abs(pt.ctrlOutDY) > 1e-6
                                     || abs(pt.ctrlInDX) > 1e-6 || abs(pt.ctrlInDY) > 1e-6

                        if hasHandle {
                            Path { p in p.move(to: CGPoint(x: hInX, y: hInY)); p.addLine(to: CGPoint(x: px, y: py)); p.addLine(to: CGPoint(x: hOutX, y: hOutY)) }
                                .stroke(Color.orange.opacity(0.5), lineWidth: 1).allowsHitTesting(false)

                            handleCircle(color: .orange)
                                .position(x: hOutX, y: hOutY)
                                .gesture(handleDrag(clipID: clip.id, pointIndex: i, isOut: true, fw: fw, fh: fh, pt: pt))

                            handleCircle(color: .orange)
                                .position(x: hInX, y: hInY)
                                .gesture(handleDrag(clipID: clip.id, pointIndex: i, isOut: false, fw: fw, fh: fh, pt: pt))
                        }

                        anchorSquare()
                            .position(x: px, y: py)
                            .gesture(anchorDrag(clipID: clip.id, pointIndex: i, fw: fw, fh: fh, pt: pt))
                    }
                }
                .onAppear { installEscMonitor() }
                .onDisappear { removeEscMonitor() }
            }
        }
    }

    /// 锚点。跟控制柄一样是圆的，只是大一圈、描边用主题色
    private func anchorSquare() -> some View {
        Circle().fill(Color.white).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.accent, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: 24, height: 24).contentShape(Circle())
    }

    private func handleCircle(color: Color) -> some View {
        Circle().fill(Color.white).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color, lineWidth: 1.5))
            .frame(width: 22, height: 22).contentShape(Circle())
    }

    private func pushUndoOnce() {
        // 外面给了写回口子（封面弹窗）时，撤销由那边自己管
        guard onUpdate == nil else { return }
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

    /// 改一条钢笔图形。给了 onUpdate 就交给它，否则走项目的图形轨道
    private func writeBack(_ id: UUID, _ apply: @escaping (inout ShapeClip) -> Void) {
        if let up = onUpdate { up(id, apply) } else { project.updateShapeClip(id: id, apply) }
    }

    private func anchorDrag(clipID: UUID, pointIndex i: Int, fw: CGFloat, fh: CGFloat, pt: PenPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                pushUndoOnce()
                if dragOrigin == nil { dragOrigin = pt }
                let origin = dragOrigin ?? pt
                let dx = v.translation.width / fw
                let dy = v.translation.height / fh
                writeBack(clipID) { c in
                    guard var pts = c.penPoints, i < pts.count else { return }
                    pts[i].x = origin.x + dx; pts[i].y = origin.y + dy
                    c.penPoints = pts
                }
            }
            .onEnded { _ in didPushUndo = false; dragOrigin = nil }
    }

    private func handleDrag(clipID: UUID, pointIndex i: Int, isOut: Bool, fw: CGFloat, fh: CGFloat, pt: PenPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                pushUndoOnce()
                if dragOrigin == nil { dragOrigin = pt }
                let origin = dragOrigin ?? pt
                let dx = v.translation.width / fw
                let dy = v.translation.height / fh
                writeBack(clipID) { c in
                    guard var pts = c.penPoints, i < pts.count else { return }
                    if isOut {
                        pts[i].ctrlOutDX = origin.ctrlOutDX + dx
                        pts[i].ctrlOutDY = origin.ctrlOutDY + dy
                        if pts[i].smooth { pts[i].ctrlInDX = -(pts[i].ctrlOutDX); pts[i].ctrlInDY = -(pts[i].ctrlOutDY) }
                    } else {
                        pts[i].ctrlInDX = origin.ctrlInDX + dx
                        pts[i].ctrlInDY = origin.ctrlInDY + dy
                        if pts[i].smooth { pts[i].ctrlOutDX = -(pts[i].ctrlInDX); pts[i].ctrlOutDY = -(pts[i].ctrlInDY) }
                    }
                    c.penPoints = pts
                }
            }
            .onEnded { _ in didPushUndo = false; dragOrigin = nil }
    }

    @State private var escMonitor: Any? = nil

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 同上：没在钢笔编辑就别碰事件，残留的 monitor 不能吞掉别处的 esc/回车。
            // 另外两个窗口可以同时处于钢笔编辑态，状态守卫挡不住，还要按窗口过滤
            guard WindowManager.shared.window(for: windowID)?.isKeyWindow == true else {
                return event
            }
            guard project.penEditingClipID != nil else { return event }
            if event.keyCode == 53 || event.keyCode == 36 { // Escape or Enter → exit edit
                project.penEditingClipID = nil; return nil
            }
            if event.keyCode == 51, let editID = project.penEditingClipID { // Delete key
                project.pushUndo()
                project.updateShapeClip(id: editID) { c in
                    guard var pts = c.penPoints, pts.count > 2 else { return }
                    // 删暂不实现（需要选中某个点的状态），后续可扩展
                }
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

// MARK: - Controller

final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying: Bool = false
    // 独立 Timer 驱动时间轴（不依赖 AVPlayer 时间观察器）
    private var timer: Timer?
    private var lastTick: Date?

    // 由 PlayerView 设置的回调
    var onTime:  ((Double) -> Void)?
    var getTime: (() -> Double)?
    var getDuration: (() -> Double)?

    func setItem(_ item: AVPlayerItem?, seekTo: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        player.replaceCurrentItem(with: item)

        if let item = item {
            var obs: NSKeyValueObservation?
            obs = item.observe(\.status, options: [.new]) { it, _ in
                if it.status == .failed {
                    DiagLog.log("[预览] AVPlayerItem 失败：\(it.error?.localizedDescription ?? "未知")（\((it.error as NSError?)?.code ?? 0)）")
                }
                if it.status != .unknown { obs?.invalidate(); obs = nil }
            }
            player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                ColorCompositor.clearDragOffsets()
                if wasPlaying { DispatchQueue.main.async { self?.play() } }
            }
        }
    }

    func play() {
        // 播放头已经停在末尾了，这次按播放就是"重播"：先回到开头。
        // 不这么做的话 AVPlayer 在结尾原地起播，画面不动，看着像按了没反应
        let dur = getDuration?() ?? 0
        if dur > 0, (getTime?() ?? 0) >= dur - 0.001 {
            onTime?(0)
            seek(to: 0)
        }
        isPlaying = true
        lastTick = Date()
        player.play()
        startTimer()
    }

    func pause() {
        isPlaying = false
        player.pause()
        stopTimer()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// 彻底停下并交出播放资源。关窗时必须调 —— 只靠视图销毁不够：
    /// 窗口关了、项目关了，AVPlayer 还在后台继续出声。
    /// 光 pause() 也不保险，得把 item 摘掉，让 AVFoundation 释放解码链路
    func stopAndRelease() {
        stopTimer()
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        onTime = nil
        getTime = nil
        getDuration = nil
    }

    deinit {
        // 正常释放路径的兜底。SwiftUI 不保证 @StateObject 何时销毁，
        // 所以关窗那条路走的是显式 stopAndRelease()，这里只管收尾
        timer?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func seek(to t: Double) {
        lastTick = Date()   // 重置 timer 基准
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
    }

    private func tick() {
        guard let last = lastTick else { return }
        let now = Date()
        let dt  = now.timeIntervalSince(last)
        lastTick = now

        let cur = (getTime?() ?? 0) + dt
        let dur = getDuration?() ?? 0

        if cur >= dur && dur > 0 {
            onTime?(dur)
            pause()
        } else {
            onTime?(cur)
        }
    }
}

// MARK: - 叠加层的滤镜

/// 给预览区的叠加层（图片 / 文字 / 图形）套滤镜。
///
/// **是近似不是精确**：合成器那边用的是 CIFilter，这里只有 SwiftUI 的几个
/// 颜色修饰器可用。导出走的是 CIFilter 那条链，所以成片是准的 ——
/// 这一层只为了让预览里叠加的内容跟着一起变，不至于「视频黑白了、字还是彩的」
/// 给叠加层（图片/文字/图形都是 SwiftUI 画的，不经过合成器）套滤镜。
///
/// 走 CALayer.filters 挂**真的 CIFilter**，跟视频画面用的是同一份 FilterEngine ——
/// 之前用 grayscale/saturation 这些修饰器近似，漫画、色阶、LUT 根本近似不出来。
///
/// 强度靠上下两层叠加：底下一层原样、上面一层套滤镜按强度调透明度，
/// 效果等同于线性混合。**交互留给下面那层**，否则强度拉满时预览区就点不动了
struct OverlayFilterEffect: ViewModifier {
    let clips: [FilterClip]
    // **必须显式往下传**。CILayerEffect 会把内容重新塞进一个新的 NSHostingView，
    // 那是一棵新的视图树，拿不到外面注入的环境对象 —— 里面的图片/文字层
    // 读 @EnvironmentObject 时就渲染不出来，画面整个是空的
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    func body(content: Content) -> some View {
        clips.reduce(AnyView(content)) { view, clip in
            let k = min(max(clip.intensity, 0), 1)
            let fs = FilterEngine.ciFilters(for: clip)
            guard k > 0.001, !fs.isEmpty else { return view }
            return AnyView(ZStack {
                view
                CILayerEffect(filters: fs) {
                    view.environmentObject(project).environmentObject(clock)
                }
                .opacity(k)
                .allowsHitTesting(false)
            })
        }
    }
}

/// macOS 上给任意视图挂 CIFilter 的唯一现成通道：CALayer.filters
struct CILayerEffect<Content: View>: NSViewRepresentable {
    let filters: [CIFilter]
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let v = NSHostingView(rootView: content())
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        return v
    }

    func updateNSView(_ v: NSHostingView<Content>, context: Context) {
        v.rootView = content()
        v.layer?.filters = filters
    }
}


/// 给 SwiftUI 视图套一份 ColorAdjust。跟导出用的是同一条 CIFilter 链
struct CIAdjustEffect: ViewModifier {
    let adjust: ColorAdjust

    func body(content: Content) -> some View {
        let fs = adjust.ciFilters
        if fs.isEmpty {
            content
        } else {
            CILayerEffect(filters: fs) { content }
        }
    }
}


/// 给叠加层套特效。跟调节那条一样走 CALayer.filters，
/// 用的是同一份 EffectEngine 的参数换算，所以跟视频画面、导出三边一致
/// 给叠加层套特效。
///
/// **先把这一层内容光栅化到渲染分辨率，在那个尺度上套特效，再缩回显示尺寸** ——
/// 视频帧走的就是这条路（合成器在 1920 上算完，预览再整体缩小显示）。
/// 直接拿 CALayer.filters 在显示尺寸上算的话，同样的相对半径，
/// 「1920 上扭曲完缩到 900」和「直接在 900 上扭曲」出来的锐利度差一截，
/// 用户照着预览调好的强度，导出就不是那个味道了。
///
/// 代价是每次内容变化都要重新光栅化，所以结果按内容指纹缓存住
struct OverlayEffectFilter: ViewModifier {
    let clips: [EffectClip]
    /// 预览里这一层实际画多大
    let displaySize: CGSize
    /// 导出用的渲染分辨率。特效在这个尺度上算，才跟视频帧和导出对得齐
    let renderSize: CGSize
    /// 叠加层内容的指纹，变了就重画
    let contentKey: String
    /// 播放中。光栅化一次要几十毫秒，逐帧做会直接卡死，
    /// 播放时退回 CALayer.filters 那条近似的路，停下来再走精确的
    let isPlaying: Bool

    func body(content: Content) -> some View {
        let live = clips.filter { $0.intensity > 0.001 }
        if live.isEmpty || displaySize.width < 1 || renderSize.width < 1 {
            content
        } else if isPlaying {
            // 播放中走近似：直接在显示尺寸上挂滤镜，快但跟视频帧的锐利度对不齐
            ZStack {
                content.opacity(0)
                CILayerEffect(filters: live.flatMap {
                    EffectEngine.ciFilters(for: $0, renderSize: displaySize)
                }) { content }
                    .allowsHitTesting(false)
            }
        } else {
            RasterizedEffect(clips: live, displaySize: displaySize,
                             renderSize: renderSize, contentKey: contentKey,
                             fallback: { AnyView(content) }) { content }
        }
    }
}

/// 把一段 SwiftUI 内容按渲染分辨率光栅化，套上特效，再按显示尺寸画出来
private struct RasterizedEffect<Content: View>: View {
    let clips: [EffectClip]
    let displaySize: CGSize
    let renderSize: CGSize
    let contentKey: String
    /// 还没光栅化出结果时拿它顶着。**不能什么都不画** ——
    /// 第一帧、或者光栅化失败时，那一层会整个消失
    let fallback: () -> AnyView
    @ViewBuilder let content: () -> Content

    @State private var rendered: NSImage?

    /// 内容和参数都没变就不用重新光栅化
    private var key: String {
        clips.map { "\($0.id)\($0.kind.rawValue)\($0.intensity)\($0.amount)\($0.angle)\($0.centerX)\($0.centerY)" }
            .joined() + "|\(Int(displaySize.width))x\(Int(displaySize.height))|" + contentKey
    }

    var body: some View {
        ZStack {
            // 底层始终画着原内容：一来接鼠标，二来光栅化没出结果时顶着
            fallback().opacity(rendered == nil ? 1 : 0)
            if let img = rendered {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .onAppear { rasterize() }
        .onChange(of: key) { _, _ in rasterize() }
    }

    @MainActor
    private func rasterize() {
        // 光栅化按渲染分辨率来：内容按显示尺寸布局，scale 补足到渲染分辨率
        let scale = max(renderSize.width / max(displaySize.width, 1), 1)
        let r = ImageRenderer(content: content()
            .frame(width: displaySize.width, height: displaySize.height))
        r.scale = scale
        guard let ns = r.nsImage,
              let tiff = ns.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return }

        var out = ci
        for clip in clips {
            out = EffectEngine.apply(clip, to: out, renderSize: ci.extent.size)
        }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { return }
        rendered = NSImage(cgImage: cg, size: displaySize)
    }
}

/// 特效的中心点。选中一段带中心点的特效时出现，可以直接拖
struct EffectCenterHandle: View {
    let clip: EffectClip
    let canvas: CGSize
    let onMove: (Double, Double) -> Void
    var onEnd: () -> Void = {}

    /// 画布的坐标空间名。手势读**这个空间里的绝对位置**，不用起点加位移 ——
    /// 拖动中视图会因为数据变化不断重建，累加那套很容易错位或者干脆不跟手
    static let space = "effectCenterCanvas"

    var body: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 18, height: 18)
            Circle().stroke(Color.black.opacity(0.4), lineWidth: 3).frame(width: 21, height: 21)
            Circle().fill(Color.white).frame(width: 5, height: 5)
        }
        .contentShape(Circle().inset(by: -8))
        .claimsDragFromWindow()
        .onHover { $0 ? NSCursor.openHand.set() : NSCursor.arrow.set() }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in
                    guard canvas.width > 0, canvas.height > 0 else { return }
                    onMove(Double(min(max(v.location.x / canvas.width, 0), 1)),
                           Double(min(max(v.location.y / canvas.height, 0), 1)))
                }
                .onEnded { _ in onEnd() }
        )
        .position(x: canvas.width * clip.centerX, y: canvas.height * clip.centerY)
    }
}

/// 没有视频垫底时的整帧画面。
///
/// 合成器（ColorCompositor）只在有视频轨的时候才跑，纯图片项目一旦加了
/// 滤镜/调节/特效轨，叠加层这边把自己藏起来交给合成器，合成器却没启动 ——
/// 画面就全黑了。这里直接调合成器那份 `drawOverlays` 自己出图：
/// 图层顺序、效果串接、强度混合全是同一份代码，不会出现两套画面对不上
struct ComposedOverlayFrame: View {
    let renderSize: CGSize
    let time: Double
    /// 叠加层内容指纹：图片位置、文字这些变了要重画
    let contentKey: String
    /// 效果参数指纹：**强度这类改动全靠它** —— 不带的话时间和尺寸都没变，
    /// SwiftUI 认为这个视图没变化，画面就停在旧的上，非得挪一下片段才刷新
    let effectKey: String

    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        if let img = Self.render(renderSize: renderSize, at: time) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .allowsHitTesting(false)
        }
    }

    static func render(renderSize: CGSize, at t: Double) -> NSImage? {
        guard renderSize.width > 1, renderSize.height > 1 else { return nil }
        let box = CGRect(origin: .zero, size: renderSize)
        // 透明底：预览区自己的黑底透上来，不用在这儿铺一层黑
        let base = CIImage(color: CIColor.clear).cropped(to: box)
        let out = ColorCompositor.drawOverlays(base, at: t, renderSize: renderSize)
            .cropped(to: box)
        guard let cg = ctx.createCGImage(out, from: box) else { return nil }
        return NSImage(cgImage: cg, size: renderSize)
    }
}
