import SwiftUI
import Combine
import AVKit
import AVFoundation

private let kPreviewInset: CGFloat = 8

struct PlayerView: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
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
                        Color.black
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
                                project.selectedShapeClipID = nil; project.selectedImageClipID = nil
                                project.selectedTextClipID = nil; project.selectedVideoClipID = nil
                                project.selectedSubtitleClipID = nil; project.selectedClipIDs.removeAll()
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
                        }
                        .frame(width: fitW, height: fitH)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
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
                    .padding(.top, 8)
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
            let jitter = (1.0 / 600.0) * (clock.refreshSeekRequest % 2 == 0 ? 1.0 : -1.0)
            ctrl.seek(to: clock.currentTime + jitter)
        }
        .onAppear {
            // 绑定回调：Timer 驱动 currentTime，不依赖 AVPlayer
            ctrl.onTime     = { t in clock.currentTime = t }
            ctrl.getTime    = { clock.currentTime }
            ctrl.getDuration = { clock.duration }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in
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
    @State private var subtitleHeights: [UUID: CGFloat] = [:]   // 每条字幕实测高度，用于精确堆叠

    var body: some View {
        let count = project.overlayTrackOrder.count

        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    if project.editingTextClipID != nil { commitTextEdit() }
                    project.selectedShapeClipID = nil
                    project.selectedImageClipID = nil
                    project.selectedTextClipID = nil
                    project.selectedVideoClipID = nil
                    project.selectedSubtitleClipID = nil
                    project.selectedClipIDs.removeAll()
                }
                .zIndex(-1)

            ForEach(Array(project.overlayTrackOrder.enumerated()), id: \.element.trackID) { i, ref in
                let z = Double(count - i)
                switch ref {
                case .image(let id):
                    imageTrackView(trackID: id).zIndex(z)
                case .subtitle(let id):
                    subtitleTrackView(trackID: id).zIndex(z)
                case .text(let id):
                    textTrackView(trackID: id).zIndex(z)
                case .shape(let id):
                    shapeTrackView(trackID: id).zIndex(z)
                case .compound(let id):
                    compoundOverlayView(trackID: id).zIndex(z)
                }
            }
            ForEach(nonOverlayCompoundTrackIDs, id: \.self) { trackID in
                compoundOverlayView(trackID: trackID).zIndex(-0.5)
            }
        }
    }

    private var nonOverlayCompoundTrackIDs: [UUID] {
        let overlayIDs = Set(project.overlayTrackOrder.compactMap { ref -> UUID? in
            if case .compound(let id) = ref { return id }; return nil
        })
        return project.compoundTracks.map(\.id).filter { !overlayIDs.contains($0) }
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
                                project.shiftToggleClip(clip.id)
                            } else {
                                selectImageExclusive(clip.id)
                            }
                        }
                        .position(x: imgRect.midX, y: imgRect.midY)
                }
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
                                project.shiftToggleClip(clip.id)
                            } else {
                                selectTextExclusive(clip.id)
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
                            project.shiftToggleClip(clip.id)
                        } else {
                            selectShapeExclusive(clip.id)
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
                let bottomPad = subtitleBottomPad(trackID: trackID, geoH: geo.size.height, scale: scale, style: style)
                SubtitleLabel(text: text, style: style, scale: scale)
                    .frame(maxWidth: geo.size.width * style.widthPercent / 100)
                    .multilineTextAlignment(subtitleAlign(style.alignment))
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { setSubHeight(trackID, g.size.height) }
                            .onChange(of: g.size.height) { _ in setSubHeight(trackID, g.size.height) }
                    })
                    .padding(.bottom, bottomPad)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private func setSubHeight(_ id: UUID, _ h: CGFloat) {
        guard h > 0, abs((subtitleHeights[id] ?? -1) - h) > 0.5 else { return }
        DispatchQueue.main.async { subtitleHeights[id] = h }
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

    /// 用实测高度精确累加堆叠偏移：本轨道底边距 = margin + 其下方各条(高度+间距)之和
    private func subtitleBottomPad(trackID: UUID, geoH: CGFloat, scale: CGFloat, style: SubtitleStyle) -> CGFloat {
        let margin = geoH * project.subtitleBottomMargin / 100.0
        let spacing = CGFloat(project.subtitleLineSpacing) * scale
        let active = activeSubtitleTrackIDs()
        guard let level = active.firstIndex(of: trackID), active.count > 1 else { return margin }
        let fallback = style.fontSize * scale * 1.3 + 6 * scale
        var pad = margin
        for k in (level + 1)..<active.count {
            pad += (subtitleHeights[active[k]] ?? fallback) + spacing
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
        let baseScale = min(videoSize.width / imgW, videoSize.height / imgH)
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
                compoundImages(compound: compound, it: it, geo: geo)
                compoundShapes(compound: compound, it: it, geo: geo)
                compoundTexts(compound: compound, it: it, geo: geo)
                compoundSubtitles(compound: compound, it: it, geo: geo)
                nestedCompoundOverlays(compound: compound, it: it, geo: geo)
            }
        }
        .allowsHitTesting(false)
    }

    private func nestedCompoundOverlays(compound: CompoundClip, it: Double, geo: GeometryProxy) -> AnyView {
        let active = compound.compoundTracks
            .filter { $0.isVisible }
            .flatMap(\.clips)
            .filter { $0.startTime <= it && $0.endTime > it }
        guard !active.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(ForEach(active) { nested in
            let nit = it - nested.startTime + nested.internalStart
            self.compoundImages(compound: nested, it: nit, geo: geo)
            self.compoundShapes(compound: nested, it: nit, geo: geo)
            self.compoundTexts(compound: nested, it: nit, geo: geo)
            self.compoundSubtitles(compound: nested, it: nit, geo: geo)
            self.nestedCompoundOverlays(compound: nested, it: nit, geo: geo)
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
    private func compoundImages(compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        let clips = compound.imageTracks.flatMap(\.clips).filter { $0.startTime <= it && $0.endTime > it }
        ForEach(clips) { clip in
            ImageLayerView(clip: clip, viewSize: geo.size, videoSize: project.previewRenderSize)
        }
    }

    @ViewBuilder
    private func compoundShapes(compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        let scale = geo.size.width / max(project.previewRenderSize.width, 1)
        let clips = compound.shapeTracks.flatMap(\.clips).filter { $0.startTime <= it && $0.endTime > it }
        ForEach(clips) { clip in
            ShapeClipView(clip: clip, scale: scale, selected: false)
                .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
        }
    }

    @ViewBuilder
    private func compoundTexts(compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        let scale = geo.size.width / max(project.previewRenderSize.width, 1)
        let clips = compound.textTracks.flatMap(\.clips).filter { $0.startTime <= it && $0.endTime > it }
        ForEach(clips) { clip in
            TextLabel(clip: clip, scale: scale)
                .position(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
        }
    }

    @ViewBuilder
    private func compoundSubtitles(compound: CompoundClip, it: Double, geo: GeometryProxy) -> some View {
        let scale = geo.size.width / max(project.previewRenderSize.width, 1)
        ForEach(compound.subtitleTracks) { subTrack in
            if let clip = subTrack.clips.first(where: { $0.startTime <= it && $0.endTime > it }) {
                let style = subTrack.subtitleStyle ?? SubtitleStyle()
                let text = style.mergeLineBreaks ? SubtitleOverlay.mergeBreaks(clip.text) : clip.text
                SubtitleLabel(text: text, style: style, scale: scale)
                    .frame(maxWidth: geo.size.width * style.widthPercent / 100)
                    .multilineTextAlignment(subtitleAlign(style.alignment))
                    .padding(.bottom, geo.size.height * project.subtitleBottomMargin / 100.0)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
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

private extension View {
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

            let baseScale = min(videoSize.width / imgW, videoSize.height / imgH)
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
                        .brightness(adj.brightness)
                        .contrast(1 + adj.contrast)
                        .saturation(1 + adj.saturation)
                        .hueRotation(.degrees(adj.hue))
                }
                .frame(width: cropW * vs, height: cropH * vs, alignment: .topLeading)
                .clipped()
                // 描边必须加在 clipped 之后，否则会连同描边一起被裁掉。
                // shadow 基于 alpha，所以去背图沿主体轮廓描边，不透明图沿裁剪框描边
                .imageStroke(width: clip.strokeW * vs, color: clip.strokeColor, softness: clip.strokeSoft)
                .scaleEffect(x: clip.mirrorH ? -1 : 1, y: clip.mirrorV ? -1 : 1)
                .rotationEffect(.degrees(Double(clip.rotation)))
                .position(x: originX + (cropX + cropW / 2) * vs,
                          y: originY + (cropY + cropH / 2) * vs)
            }
        }
    }
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
            .font(.custom(style.fontName, size: style.fontSize * scale).weight(style.bold ? .bold : .regular))
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

private struct TextEditField: NSViewRepresentable {
    @Binding var text: String
    let clip: TextClip
    let scale: CGFloat
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
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
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: 10000, height: 10000)
        tv.maxSize = NSSize(width: 10000, height: 10000)
        tv.isHorizontallyResizable = true
        tv.focusRingType = .none
        tv.string = text
        applyStyle(tv)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        applyStyle(tv)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let r = lm.usedRect(for: tc)
        let pad = tv.textContainerInset
        let w = max(ceil(r.width) + pad.width * 2, 50 * scale)
        let h = max(ceil(r.height) + pad.height * 2, clip.fontSize * scale * 1.5)
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

private struct TextLabel: View {
    let clip: TextClip
    var scale: CGFloat = 1.0
    var selected: Bool = false

    private var strokeRadius: CGFloat { max(0.6, clip.strokeWidth * 0.5) * scale }
    private var strokeOffset: CGFloat { max(0.6, clip.strokeWidth * 0.4) * scale }

    var body: some View {
        Text(clip.text.isEmpty ? " " : clip.text)
            .font(.custom(clip.fontName, size: clip.fontSize * scale)
                    .weight(clip.bold ? .bold : .regular))
            .transformEffect(italicSkew(clip.italic, fontSize: clip.fontSize * scale))
            .foregroundColor(clip.textColor)
            // 描边近似：四向阴影（strokeWidth>0 时不透明，否则淡阴影提升可读性）
            .shadow(color: clip.strokeColor.opacity(clip.strokeWidth > 0 ? 1 : 0.6),
                    radius: strokeRadius, x: strokeOffset, y: strokeOffset)
            .shadow(color: clip.strokeColor.opacity(clip.strokeWidth > 0 ? 1 : 0.6),
                    radius: strokeRadius, x: -strokeOffset, y: -strokeOffset)
            .multilineTextAlignment(textAlign(clip.alignment))
            .padding(.horizontal, 10 * scale).padding(.vertical, 5 * scale)
            .background(clip.bgColor.opacity(clip.bgOpacity))
            .cornerRadius(4 * scale)
            .rotationEffect(.degrees(clip.rotation))
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
            }
        }
    }

    private func tapThrough(at pt: CGPoint, viewSize: CGSize) {
        let t = clock.currentTime
        let scale = viewSize.width / max(project.previewRenderSize.width, 1)
        let shift = NSEvent.modifierFlags.contains(.shift)
        for ref in project.overlayTrackOrder {
            switch ref {
            case .shape(let trackID):
                guard let track = project.shapeTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let sc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * sc.posX, cy = viewSize.height * sc.posY
                let w = sc.width * sc.scaleX * scale, h = sc.height * sc.scaleY * scale
                guard CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h).contains(pt) else { continue }
                if shift { project.shiftToggleClip(sc.id) } else {
                    project.editingTextClipID = nil
                    project.selectedShapeClipID = sc.id
                    project.selectedImageClipID = nil; project.selectedTextClipID = nil
                    project.selectedVideoClipID = nil; project.selectedClipIDs = [sc.id]
                }
                return
            case .text(let trackID):
                guard let track = project.textTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let tc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * tc.posX, cy = viewSize.height * tc.posY
                let sz = project.textClipViewSizes[tc.id] ?? CGSize(width: 100, height: 30)
                guard CGRect(x: cx - sz.width/2, y: cy - sz.height/2, width: sz.width, height: sz.height).contains(pt) else { continue }
                if shift { project.shiftToggleClip(tc.id) } else {
                    project.editingTextClipID = nil
                    project.selectedTextClipID = tc.id
                    project.selectedImageClipID = nil; project.selectedShapeClipID = nil
                    project.selectedVideoClipID = nil; project.selectedClipIDs = [tc.id]
                }
                return
            case .image(let trackID):
                guard let track = project.imageTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let ic = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                if shift { project.shiftToggleClip(ic.id) } else {
                    project.editingTextClipID = nil
                    project.selectedImageClipID = ic.id
                    project.selectedShapeClipID = nil; project.selectedTextClipID = nil
                    project.selectedVideoClipID = nil; project.selectedClipIDs = [ic.id]
                }
                return
            default: continue
            }
        }
        project.selectedImageClipID = nil; project.selectedShapeClipID = nil
        project.selectedTextClipID = nil; project.selectedVideoClipID = nil
        project.selectedClipIDs.removeAll()
        project.editingTextClipID = nil
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
                    tapThrough(at: value.location, viewSize: viewSize)
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
                var delta: Double = 0
                switch edge {
                case 0: delta =  value.translation.height / vidRect.height
                case 1: delta = -value.translation.height / vidRect.height
                case 2: delta =  value.translation.width  / vidRect.width
                case 3: delta = -value.translation.width  / vidRect.width
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
                .frame(width: isHorizontal ? length + 16 : 28,
                       height: isHorizontal ? 28 : length + 16)
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

    private func computeVideoRect(clip: VideoClip, info: RenderInfo) -> CGRect {
        let natW = CGFloat(clip.videoWidth)
        let natH = CGFloat(clip.videoHeight)
        guard natW > 0, natH > 0 else { return .zero }

        // 素材在画布内等比摆放（合成层同样逻辑），裁剪框据此贴合素材边界
        let baseScale = min(info.videoSize.width / natW, info.videoSize.height / natH)
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

private struct ImageTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    enum DragMode { case none, move, scale, crop }
    @State private var dragMode: DragMode = .none
    @State private var didPushUndo = false
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
                        // 边框（不接受事件）
                        Rectangle()
                            .stroke(Color.accent, lineWidth: 1.5)
                            .frame(width: max(imgRect.width, 1), height: max(imgRect.height, 1))
                            .position(x: imgRect.midX, y: imgRect.midY)
                            .allowsHitTesting(false)

                        // 四边裁剪手柄 — 橙色长细条
                        ForEach(0..<4, id: \.self) { edge in
                            let pos = edgeMidPos(edge, imgRect)
                            let isH = edge < 2
                            let barLen = isH ? max(min(imgRect.width * 0.35, 50), 20) : max(min(imgRect.height * 0.35, 50), 20)
                            CropEdgeBar(isHorizontal: isH, length: barLen)
                                .claimsDragFromWindow()   // 必须在 .position() 之前
                                .position(x: pos.x, y: pos.y)
                                .gesture(cropDrag(clip: clip, info: info, edge: edge))
                        }

                        // 四角缩放手柄 — 白色圆点
                        ForEach(0..<4, id: \.self) { corner in
                            let pos = cornerPos(corner, imgRect)
                            ScaleHandleDot()
                                .claimsDragFromWindow()   // 必须在 .position() 之前
                                .position(x: pos.x, y: pos.y)
                                .gesture(scaleDrag(clip: clip, info: info, corner: corner))
                        }
                    }
                }
            }
        }
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
                    tapThrough(at: value.location, viewSize: viewSize, currentClipID: clip.id)
                }
            }
    }

    // MARK: - 缩放手势
    private func scaleDrag(clip: ImageClip, info: RenderInfo, corner: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .scale
                    scaleStartValues = (clip.scaleX, clip.scaleY)
                }
                guard dragMode == .scale else { return }
                let imgRect = computeImageRect(clip: clip, info: info)
                let center = CGPoint(x: imgRect.midX, y: imgRect.midY)
                let startDist = hypot(value.startLocation.x - center.x,
                                      value.startLocation.y - center.y)
                let curDist = hypot(value.location.x - center.x,
                                    value.location.y - center.y)
                guard startDist > 1 else { return }
                let ratio = curDist / startDist
                project.updateImageClip(id: clip.id) {
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

    // MARK: - 裁剪手势（对面边自然不动，因为 scale 不随 crop 变化）
    private func cropDrag(clip: ImageClip, info: RenderInfo, edge: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .crop
                    cropEdge = edge
                    cropStartClip = clip
                }
                guard dragMode == .crop, let startClip = cropStartClip else { return }

                // 计算拖动的裁剪量：基于当前图片的实际渲染尺寸
                let imgRect = computeImageRect(clip: startClip, info: info)
                var delta: Double = 0
                switch edge {
                case 0: delta =  value.translation.height / imgRect.height  // 拖上
                case 1: delta = -value.translation.height / imgRect.height  // 拖下
                case 2: delta =  value.translation.width  / imgRect.width   // 拖左
                case 3: delta = -value.translation.width  / imgRect.width   // 拖右
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

                project.updateImageClip(id: clip.id) {
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

    // MARK: - 撤销
    private func pushUndoOnce() {
        guard !didPushUndo else { return }
        project.pushUndo()
        didPushUndo = true
    }

    // MARK: - Tap 穿透选择
    private func tapThrough(at pt: CGPoint, viewSize: CGSize, currentClipID: UUID) {
        let t = clock.currentTime
        let scale = viewSize.width / max(project.previewRenderSize.width, 1)
        let shift = NSEvent.modifierFlags.contains(.shift)
        for ref in project.overlayTrackOrder {
            switch ref {
            case .shape(let trackID):
                guard let track = project.shapeTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let sc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * sc.posX, cy = viewSize.height * sc.posY
                let w = sc.width * sc.scaleX * scale, h = sc.height * sc.scaleY * scale
                guard CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h).contains(pt) else { continue }
                if shift { project.shiftToggleClip(sc.id) } else {
                    project.editingTextClipID = nil
                    project.selectedShapeClipID = sc.id
                    project.selectedImageClipID = nil; project.selectedTextClipID = nil
                    project.selectedVideoClipID = nil; project.selectedClipIDs = [sc.id]
                }
                return
            case .text(let trackID):
                guard let track = project.textTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let tc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * tc.posX, cy = viewSize.height * tc.posY
                let sz = project.textClipViewSizes[tc.id] ?? CGSize(width: 100, height: 30)
                guard CGRect(x: cx - sz.width/2, y: cy - sz.height/2, width: sz.width, height: sz.height).contains(pt) else { continue }
                if shift { project.shiftToggleClip(tc.id) } else {
                    project.editingTextClipID = nil
                    project.selectedTextClipID = tc.id
                    project.selectedImageClipID = nil; project.selectedShapeClipID = nil
                    project.selectedVideoClipID = nil; project.selectedClipIDs = [tc.id]
                }
                return
            default: continue
            }
        }
        project.selectedImageClipID = nil; project.selectedShapeClipID = nil
        project.selectedTextClipID = nil; project.selectedVideoClipID = nil
        project.selectedClipIDs.removeAll()
        project.editingTextClipID = nil
    }

    // MARK: - 手柄

    /// 四角缩放手柄 — 白色圆点
    private struct ScaleHandleDot: View {
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

    /// 四边裁剪手柄 — 橙色长细条，加大点击区域
    private struct CropEdgeBar: View {
        let isHorizontal: Bool
        let length: CGFloat
        var body: some View {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.orange)
                .frame(width: isHorizontal ? length : 3,
                       height: isHorizontal ? 3 : length)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .frame(width: isHorizontal ? length + 16 : 28,
                       height: isHorizontal ? 28 : length + 16)
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

    private func computeImageRect(clip: ImageClip, info: RenderInfo) -> CGRect {
        let imgW = CGFloat(clip.imageWidth)
        let imgH = CGFloat(clip.imageHeight)
        guard imgW > 0, imgH > 0 else { return .zero }

        // Scale based on FULL image (crop does NOT affect scale)
        let baseScale = min(info.videoSize.width / imgW, info.videoSize.height / imgH)
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
        let cropX = fullLeft + imgW * CGFloat(clip.cropLeft) * finalSX
        let cropY = fullTop  + imgH * CGFloat(clip.cropTop)  * finalSY
        let cropW = imgW * (1 - CGFloat(clip.cropLeft + clip.cropRight))  * finalSX
        let cropH = imgH * (1 - CGFloat(clip.cropTop  + clip.cropBottom)) * finalSY
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

struct ShapeClipView: View {
    let clip: ShapeClip
    let scale: CGFloat
    var selected: Bool = false

    var body: some View {
        let w = max(clip.width * clip.scaleX * scale, 2)
        let h = max(clip.height * clip.scaleY * scale, 2)
        shapeBody(w: w, h: h)
            .frame(width: w, height: h)
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accent.opacity(0.9), lineWidth: 1.5)
                }
            }
            .modifier(ShapeShadow(clip: clip, scale: scale))
            .frame(width: max(w, 28), height: max(h, 28))   // 扩大点击热区（线段等细图形好点）
            .contentShape(Rectangle())
            .scaleEffect(x: clip.mirrorH ? -1 : 1, y: clip.mirrorV ? -1 : 1)
            .rotationEffect(.degrees(clip.rotation))
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
                                project.shiftToggleClip(clip.id)
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

private struct TextTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    @State private var dragMode = 0   // 0=none 1=scale 2=rotate
    @State private var didPushUndo = false
    @State private var startFontSize: CGFloat = 64
    @State private var startRotation = 0.0
    @State private var startAngle = 0.0

    private let accent = Color.accent

    var body: some View {
        GeometryReader { geo in
            if let clip = project.selectedTextClip,
               clip.startTime <= clock.currentTime, clip.endTime > clock.currentTime,
               project.selectedClipIDs.count <= 1 {
                let scale = geo.size.width / max(project.previewRenderSize.width, 1)
                let center = CGPoint(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                let sz = project.textClipViewSizes[clip.id] ?? textBoundsSize(clip: clip, scale: scale)
                let w = max(sz.width, 8)
                let h = max(sz.height, 8)

                ZStack {
                    if project.editingTextClipID != clip.id {
                        Rectangle().stroke(accent, lineWidth: 1.5)
                            .frame(width: w, height: h)
                            .rotationEffect(.degrees(clip.rotation))
                            .position(center)
                            .allowsHitTesting(false)
                    }

                    ForEach(0..<4, id: \.self) { i in
                        handleDot()
                            .position(rotatedCorner(i, center: center, w: w, h: h, rot: clip.rotation))
                            .gesture(scaleGesture(clip: clip, center: center))
                    }

                    rotHandleView()
                        .position(rotationHandlePos(center: center, h: h, rot: clip.rotation))
                        .gesture(rotateGesture(clip: clip, center: center))
                }
            }
        }
    }

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

    private func rotationHandlePos(center: CGPoint, h: CGFloat, rot: Double) -> CGPoint {
        let p = rotate(0, -h / 2 - 26, rot)
        return CGPoint(x: center.x + p.x, y: center.y + p.y)
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
        return CGSize(width: size.width + 20 * scale, height: size.height + 10 * scale)
    }

    private func pushUndoOnce() {
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

    private func scaleGesture(clip: TextClip, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 1 { pushUndoOnce(); dragMode = 1; startFontSize = clip.fontSize }
                let d0 = hypot(v.startLocation.x - center.x, v.startLocation.y - center.y)
                let d1 = hypot(v.location.x - center.x, v.location.y - center.y)
                guard d0 > 1 else { return }
                project.updateTextClip(id: clip.id) {
                    $0.fontSize = max(8, startFontSize * (d1 / d0))
                }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false }
    }

    private func rotateGesture(clip: TextClip, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 2 {
                    pushUndoOnce(); dragMode = 2
                    startRotation = clip.rotation
                    startAngle = atan2(Double(v.startLocation.y - center.y),
                                       Double(v.startLocation.x - center.x)) * 180 / .pi
                }
                let cur = atan2(Double(v.location.y - center.y),
                                Double(v.location.x - center.x)) * 180 / .pi
                project.updateTextClip(id: clip.id) { $0.rotation = startRotation + (cur - startAngle) }
            }
            .onEnded { _ in dragMode = 0; didPushUndo = false }
    }
}

// MARK: - Shape Transform Overlay（选中边框；缩放/旋转手柄见 2b）

private struct ShapeTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock

    @State private var dragMode = 0   // 0=none 1=scale 2=rotate 3=endpoint
    @State private var didPushUndo = false
    @State private var startClip: ShapeClip? = nil
    @State private var startRotation = 0.0
    @State private var startAngle = 0.0
    @State private var penKeyMon: Any? = nil

    private let accent = Color.accent

    var body: some View {
        GeometryReader { geo in
            if let clip = project.selectedShapeClip,
               clip.startTime <= clock.currentTime, clip.endTime > clock.currentTime,
               !project.penDrawingMode, project.penEditingClipID != clip.id,
               project.selectedClipIDs.count <= 1 {
                let scale = geo.size.width / max(project.previewRenderSize.width, 1)
                let center = CGPoint(x: geo.size.width * clip.posX, y: geo.size.height * clip.posY)
                let w = max(clip.width * clip.scaleX * scale, 8)
                let h = max(clip.height * clip.scaleY * scale, 8)
                ZStack {
                    // 边框
                    Rectangle().stroke(accent, lineWidth: 1.5)
                        .frame(width: w, height: h)
                        .rotationEffect(.degrees(clip.rotation))
                        .position(center)
                        .allowsHitTesting(false)

                    if clip.effectiveIsClosed || clip.type == .pen {
                        // 四边单向缩放条（橙色，和图片一致）
                        ForEach(0..<4, id: \.self) { e in
                            let horiz = e < 2
                            let len = horiz ? min(w * 0.4, 44) : min(h * 0.4, 44)
                            edgeBar(horizontal: horiz, length: len, rot: clip.rotation)
                                .position(edgeMid(e, center: center, w: w, h: h, rot: clip.rotation))
                                .gesture(edgeScaleGesture(clip: clip, center: center, scale: scale, edge: e, geo: geo.size))
                        }
                        // 四角缩放手柄
                        ForEach(0..<4, id: \.self) { i in
                            handleDot()
                                .position(rotatedCorner(i, center: center, w: w, h: h, rot: clip.rotation))
                                .gesture(scaleGesture(clip: clip, center: center, scale: scale))
                        }
                    } else {
                        // 线段/箭头：两端控制点（拖动改长度/方向/位置）
                        let pL = endpoint(center: center, w: w, rot: clip.rotation, right: false)
                        let pR = endpoint(center: center, w: w, rot: clip.rotation, right: true)
                        handleDot().position(pL)
                            .gesture(endpointGesture(clip: clip, fixed: pR, draggingRight: false, scale: scale, geo: geo.size))
                        handleDot().position(pR)
                            .gesture(endpointGesture(clip: clip, fixed: pL, draggingRight: true, scale: scale, geo: geo.size))
                    }

                    // 旋转手柄
                    rotHandleView()
                        .position(rotationHandlePos(center: center, h: h, rot: clip.rotation))
                        .gesture(rotateGesture(clip: clip, center: center))
                }
                .onAppear { installPenEnterMonitor() }
                .onDisappear { removePenEnterMonitor() }
            }
        }
    }

    private func installPenEnterMonitor() {
        removePenEnterMonitor()
        penKeyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            .frame(width: horizontal ? length + 16 : 28, height: horizontal ? 28 : length + 16)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(rot))
    }

    private func pushUndoOnce() {
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

    private func edgeNormal(_ e: Int, _ rot: Double) -> CGPoint {
        let base = [(CGFloat(0), CGFloat(-1)), (0, 1), (-1, 0), (1, 0)][e]
        return rotate(base.0, base.1, rot)
    }

    // 四边单向缩放：对边固定，只拖动的那条边移动（和图片裁剪条一致的手感）
    private func edgeScaleGesture(clip: ShapeClip, center: CGPoint, scale: CGFloat, edge: Int, geo: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragMode != 1 { pushUndoOnce(); dragMode = 1; startClip = clip }
                let vertical = edge < 2
                let n = edgeNormal(edge, Double(clip.rotation))
                let dimView = vertical ? clip.height * clip.scaleY * scale : clip.width * clip.scaleX * scale
                let opp = CGPoint(x: center.x - dimView / 2 * n.x, y: center.y - dimView / 2 * n.y)
                let t = (v.location.x - opp.x) * n.x + (v.location.y - opp.y) * n.y
                let tt = max(t, 8)
                let newCenter = CGPoint(x: opp.x + tt / 2 * n.x, y: opp.y + tt / 2 * n.y)
                let baseDim = vertical ? clip.height : clip.width
                let newScale = max(0.05, Double(tt) / (Double(max(baseDim, 1)) * Double(scale)))
                project.updateShapeClip(id: clip.id) {
                    if vertical { $0.scaleY = newScale } else { $0.scaleX = newScale }
                    $0.posX = min(1, max(0, Double(newCenter.x) / Double(max(geo.width, 1))))
                    $0.posY = min(1, max(0, Double(newCenter.y) / Double(max(geo.height, 1))))
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
                project.updateShapeClip(id: clip.id) {
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
                project.updateShapeClip(id: clip.id) { $0.rotation = startRotation + (cur - startAngle) }
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
                project.updateShapeClip(id: clip.id) {
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

private struct PenDrawingOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @State private var draggingHandle = false
    @State private var dragStartPos: CGPoint? = nil
    @State private var dragCurrentPos: CGPoint? = nil
    @State private var hoverPos: CGPoint? = nil
    @State private var keyMonitor: Any? = nil

    var body: some View {
        GeometryReader { geo in
            if project.penDrawingMode, let clipID = project.selectedShapeClipID {
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
                        project.finalizePenDrawing(clipID: clipID, rawPoints: project.penRawPoints, closed: true)
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
            if event.keyCode == 53 || event.keyCode == 36 {
                if project.penRawPoints.count >= 2 {
                    project.finalizePenDrawing(clipID: clipID, rawPoints: project.penRawPoints, closed: false)
                } else { project.cancelPenDrawing(clipID: clipID) }
                project.penRawPoints = []
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Pen Edit Overlay（钢笔路径编辑模式）

private struct PenEditOverlay: View {
    @EnvironmentObject private var project: ProjectState
    @State private var didPushUndo = false

    var body: some View {
        GeometryReader { geo in
            if let editID = project.penEditingClipID,
               let clip = project.shapeTracks.flatMap({ $0.clips }).first(where: { $0.id == editID }),
               let pts = clip.penPoints, pts.count >= 2 {
                let vs = geo.size
                let scale = vs.width / max(project.previewRenderSize.width, 1)
                let cx = vs.width * clip.posX
                let cy = vs.height * clip.posY
                let fw = clip.width * clip.scaleX * scale
                let fh = clip.height * clip.scaleY * scale

                ZStack {
                    Color.black.opacity(0.01).contentShape(Rectangle())
                        .onTapGesture { project.penEditingClipID = nil }

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
                                .gesture(handleDrag(clipID: editID, pointIndex: i, isOut: true, fw: fw, fh: fh, pt: pt))

                            handleCircle(color: .orange)
                                .position(x: hInX, y: hInY)
                                .gesture(handleDrag(clipID: editID, pointIndex: i, isOut: false, fw: fw, fh: fh, pt: pt))
                        }

                        anchorSquare()
                            .position(x: px, y: py)
                            .gesture(anchorDrag(clipID: editID, pointIndex: i, fw: fw, fh: fh, pt: pt))
                    }
                }
                .onAppear { installEscMonitor() }
                .onDisappear { removeEscMonitor() }
            }
        }
    }

    private func anchorSquare() -> some View {
        Rectangle().fill(Color.white).frame(width: 9, height: 9)
            .overlay(Rectangle().stroke(Color.accent, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: 24, height: 24).contentShape(Rectangle())
    }

    private func handleCircle(color: Color) -> some View {
        Circle().fill(Color.white).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color, lineWidth: 1.5))
            .frame(width: 22, height: 22).contentShape(Circle())
    }

    private func pushUndoOnce() {
        if !didPushUndo { project.pushUndo(); didPushUndo = true }
    }

    private func anchorDrag(clipID: UUID, pointIndex i: Int, fw: CGFloat, fh: CGFloat, pt: PenPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                pushUndoOnce()
                let dx = v.translation.width / fw
                let dy = v.translation.height / fh
                project.updateShapeClip(id: clipID) { c in
                    guard var pts = c.penPoints, i < pts.count else { return }
                    pts[i].x = pt.x + dx; pts[i].y = pt.y + dy
                    c.penPoints = pts
                }
            }
            .onEnded { _ in didPushUndo = false }
    }

    private func handleDrag(clipID: UUID, pointIndex i: Int, isOut: Bool, fw: CGFloat, fh: CGFloat, pt: PenPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                pushUndoOnce()
                let dx = v.translation.width / fw
                let dy = v.translation.height / fh
                project.updateShapeClip(id: clipID) { c in
                    guard var pts = c.penPoints, i < pts.count else { return }
                    if isOut {
                        pts[i].ctrlOutDX = pt.ctrlOutDX + dx
                        pts[i].ctrlOutDY = pt.ctrlOutDY + dy
                        if pts[i].smooth { pts[i].ctrlInDX = -(pts[i].ctrlOutDX); pts[i].ctrlInDY = -(pts[i].ctrlOutDY) }
                    } else {
                        pts[i].ctrlInDX = pt.ctrlInDX + dx
                        pts[i].ctrlInDY = pt.ctrlInDY + dy
                        if pts[i].smooth { pts[i].ctrlOutDX = -(pts[i].ctrlInDX); pts[i].ctrlOutDY = -(pts[i].ctrlInDY) }
                    }
                    c.penPoints = pts
                }
            }
            .onEnded { _ in didPushUndo = false }
    }

    @State private var escMonitor: Any? = nil

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
