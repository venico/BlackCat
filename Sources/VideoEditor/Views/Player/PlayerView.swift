import SwiftUI
import Combine
import AVKit
import AVFoundation

struct PlayerView: View {
    @EnvironmentObject private var project: ProjectState
    @StateObject private var ctrl = PlayerController()
    @State private var hoveringPlayer = false

    var body: some View {
        // Playback bar OVERLAID on the video, only visible while hovering.
        ZStack(alignment: .bottom) {
            ZStack {
                Color.previewBg
                AVPlayerNSView(player: ctrl.player)
                // Black out the preview when playhead is past all video content.
                if project.lastVideoEndTime > 0 && project.currentTime >= project.lastVideoEndTime {
                    Color.black
                }
                SubtitleOverlay()
                ImageTransformOverlay()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if hoveringPlayer {
                    PreviewResolutionPicker()
                        .padding(8)
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
            let seekTo = project.pendingSeekTime ?? project.currentTime
            project.pendingSeekTime = nil
            ctrl.setItem(project.playerItem, seekTo: seekTo)
        }
        // User-initiated seek (playhead/ruler drag) → tell AVPlayer to follow.
        .onChange(of: project.seekRequest) {
            ctrl.seek(to: project.currentTime)
        }
        .onAppear {
            // 绑定回调：Timer 驱动 currentTime，不依赖 AVPlayer
            ctrl.onTime     = { t in project.currentTime = t }
            ctrl.getTime    = { project.currentTime }
            ctrl.getDuration = { project.duration }
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

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / project.previewRenderSize.width
            let pairs: [(String, SubtitleStyle)] = project.subtitleTracks.indices.compactMap { i in
                guard project.subtitleTracks[i].isVisible else { return nil }
                let style = project.subtitleStyles.indices.contains(i)
                    ? project.subtitleStyles[i] : SubtitleStyle()
                guard let clip = project.subtitleTracks[i].clips.first(where: {
                    $0.startTime <= project.currentTime && $0.endTime > project.currentTime
                }) else { return nil }
                return (clip.text, style)
            }

            if !pairs.isEmpty {
                let baseStyle  = pairs[0].1
                let spacing    = CGFloat(baseStyle.lineSpacing) * scale
                let bottomPad  = geo.size.height * baseStyle.bottomMargin / 100.0

                VStack(spacing: spacing) {
                    ForEach(pairs.indices, id: \.self) { i in
                        SubtitleLabel(text: pairs[i].0, style: pairs[i].1, scale: scale)
                    }
                }
                .frame(maxWidth: geo.size.width * baseStyle.widthPercent / 100)
                .multilineTextAlignment(align(baseStyle.alignment))
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
}

private struct SubtitleLabel: View {
    let text: String; let style: SubtitleStyle; var scale: CGFloat = 1.0
    var body: some View {
        Text(text)
            .font(.custom(style.fontName, size: style.fontSize * scale).weight(style.bold ? .bold : .regular))
            .italic(style.italic)
            .foregroundColor(style.textColor)
            .shadow(color: .black.opacity(0.8), radius: 1 * scale, x: 1 * scale, y: 1 * scale)
            .shadow(color: .black.opacity(0.8), radius: 1 * scale, x: -1 * scale, y: -1 * scale)
            .padding(.horizontal, 10 * scale).padding(.vertical, 3 * scale)
            .background(style.backgroundColor.opacity(style.backgroundOpacity))
            .cornerRadius(3 * scale)
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
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
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
            Text(fmtT(project.currentTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color.labelSecondary)
                .frame(width: 72)

            // Scrubber
            Slider(value: $project.currentTime, in: 0...max(project.duration, 1)) { editing in
                if !editing { ctrl.seek(to: project.currentTime) }
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
private struct ImageTransformOverlay: View {
    @EnvironmentObject private var project: ProjectState

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
               clip.startTime <= project.currentTime,
               clip.endTime > project.currentTime {
                let info = computeRenderInfo(viewSize: geo.size)
                let imgRect = computeImageRect(clip: clip, info: info)

                ZStack {
                    // 最底层：移动区域
                    Color.clear
                        .frame(width: max(imgRect.width, 1), height: max(imgRect.height, 1))
                        .position(x: imgRect.midX, y: imgRect.midY)
                        .contentShape(Rectangle())
                        .onHover { isHoveringImage = $0 }
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
                .cursor(cursorForState)
            }
        }
    }

    // MARK: - 鼠标样式
    private var cursorForState: NSCursor {
        switch dragMode {
        case .move:  return .closedHand
        case .scale: return .crosshair
        case .crop:  return cropEdge < 2 ? .resizeUpDown : .resizeLeftRight
        case .none:  return isHoveringImage ? .openHand : .arrow
        }
    }

    // MARK: - 移动手势
    private func moveDrag(clip: ImageClip, info: RenderInfo) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == .none {
                    pushUndoOnce()
                    dragMode = .move
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
                // 点击区域比视觉大很多，防止误触到移动或缩放
                .frame(width: isHorizontal ? length + 16 : 28,
                       height: isHorizontal ? 28 : length + 16)
                .contentShape(Rectangle())
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
        let videoW: CGFloat = 1920; let videoH: CGFloat = 1080
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
