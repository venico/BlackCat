import SwiftUI
import Combine
import AVKit
import AVFoundation

struct PlayerView: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @StateObject private var ctrl = PlayerController()
    @State private var hoveringPlayer = false

    /// 时间轴上是否有任何可见的视频或图片片段
    private var hasAnyVisibleClips: Bool {
        let hasVideo = project.videoTracks.contains { $0.isVisible && !$0.clips.isEmpty }
        let hasImage = project.imageTracks.contains { $0.isVisible && !$0.clips.isEmpty }
        return hasVideo || hasImage
    }

    var body: some View {
        // Playback bar OVERLAID on the video, only visible while hovering.
        ZStack(alignment: .bottom) {
            ZStack {
                Color.previewBg
                AVPlayerNSView(player: ctrl.player)
                // Black out the preview when no content or playhead is past all video content.
                if !hasAnyVisibleClips
                    || (clock.lastVideoEndTime > 0 && clock.currentTime >= clock.lastVideoEndTime) {
                    Color.black
                }
                SubtitleOverlay()
                TextOverlay()
                VideoTransformOverlay()
                ImageTransformOverlay()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if hoveringPlayer {
                    ZStack {
                        // 标题居中
                        Text(project.projectName + (project.isSaved ? "（已保存）" : ""))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                        // 分辨率选择器靠右
                        HStack {
                            Spacer()
                            PreviewResolutionPicker()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }

            if hoveringPlayer {
                PlaybackBar(ctrl: ctrl)
                    .frame(height: 36)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.18)) {
                hoveringPlayer = inside
            }
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

private struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player; v.controlsStyle = .none; v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
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
        let w = max(ceil(r.width) + pad.width * 2 + 4, 50 * scale)
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

// MARK: - Preview Resolution Picker

private struct PreviewResolutionPicker: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        Menu {
            ForEach(ProjectState.previewResolutions, id: \.self) { res in
                Button {
                    project.previewResolution = res
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
                Image(systemName: ctrl.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .light))
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

                ZStack {
                    // 移动区域
                    Color.clear
                        .frame(width: max(vidRect.width, 1), height: max(vidRect.height, 1))
                        .position(x: vidRect.midX, y: vidRect.midY)
                        .contentShape(Rectangle())
                        .onHover { h in
                            isHovering = h
                            if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(moveDrag(clip: clip, info: info))

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
                            .position(x: pos.x, y: pos.y)
                            .gesture(cropDrag(clip: clip, info: info, edge: edge))
                    }

                    // 四角缩放手柄 — 白色圆点绿色边
                    ForEach(0..<4, id: \.self) { corner in
                        let pos = cornerPos(corner, vidRect)
                        VideoScaleHandleDot(color: accentColor)
                            .position(x: pos.x, y: pos.y)
                            .gesture(scaleDrag(clip: clip, info: info, corner: corner))
                    }
                }
            }
        }
    }

    private func moveDrag(clip: VideoClip, info: RenderInfo) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .move
                    NSCursor.closedHand.set()
                    dragStartOffset = CGPoint(x: clip.offsetX, y: clip.offsetY)
                }
                guard dragMode == .move else { return }
                let dx = value.translation.width / info.renderArea.width
                let dy = value.translation.height / info.renderArea.height
                project.updateVideoClip(id: clip.id) {
                    $0.offsetX = dragStartOffset.x + dx
                    $0.offsetY = dragStartOffset.y + dy
                }
                project.rebuildTimelinePreviewDebounced()
            }
            .onEnded { _ in
                dragMode = .none; didPushUndo = false
                NSCursor.openHand.set()
                project.rebuildTimelinePreview()
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

                ZStack {
                    // 最底层：移动区域
                    Color.clear
                        .frame(width: max(imgRect.width, 1), height: max(imgRect.height, 1))
                        .position(x: imgRect.midX, y: imgRect.midY)
                        .contentShape(Rectangle())
                        .onHover { h in
                            isHoveringImage = h
                            if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(moveDrag(clip: clip, info: info))

                    // 边框（不接受事件）
                    Rectangle()
                        .stroke(Color.accent, lineWidth: 1.5)
                        .frame(width: max(imgRect.width, 1), height: max(imgRect.height, 1))
                        .position(x: imgRect.midX, y: imgRect.midY)
                        .allowsHitTesting(false)

                    // 四边裁剪手柄 — 橙色长细条（在缩放角下面渲染，但角和边不重叠）
                    ForEach(0..<4, id: \.self) { edge in
                        let pos = edgeMidPos(edge, imgRect)
                        let isH = edge < 2
                        let barLen = isH ? max(min(imgRect.width * 0.35, 50), 20) : max(min(imgRect.height * 0.35, 50), 20)
                        CropEdgeBar(isHorizontal: isH, length: barLen)
                            .position(x: pos.x, y: pos.y)
                            .gesture(cropDrag(clip: clip, info: info, edge: edge))
                    }

                    // 四角缩放手柄 — 白色圆点（最上层，优先接收角落事件）
                    ForEach(0..<4, id: \.self) { corner in
                        let pos = cornerPos(corner, imgRect)
                        ScaleHandleDot()
                            .position(x: pos.x, y: pos.y)
                            .gesture(scaleDrag(clip: clip, info: info, corner: corner))
                    }
                }
            }
        }
    }

    // MARK: - 移动手势
    private func moveDrag(clip: ImageClip, info: RenderInfo) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .move
                    NSCursor.closedHand.set()
                    dragStartOffset = CGPoint(x: clip.offsetX, y: clip.offsetY)
                }
                guard dragMode == .move else { return }
                let dx = value.translation.width / info.renderArea.width
                let dy = value.translation.height / info.renderArea.height
                project.updateImageClip(id: clip.id) {
                    $0.offsetX = dragStartOffset.x + dx
                    $0.offsetY = dragStartOffset.y + dy
                }
                project.rebuildTimelinePreviewDebounced()
            }
            .onEnded { _ in
                dragMode = .none; didPushUndo = false
                NSCursor.openHand.set()
                project.rebuildTimelinePreview()
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

        // item ready 后 seek 到目标位置
        if let item = item {
            var obs: NSKeyValueObservation?
            obs = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
                if it.status == .failed {
                    NSLog("[Player] AVPlayerItem FAILED: %@", it.error?.localizedDescription ?? "unknown")
                    obs?.invalidate(); obs = nil
                    return
                }
                guard it.status == .readyToPlay else { return }
                obs?.invalidate(); obs = nil
                self?.player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
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
