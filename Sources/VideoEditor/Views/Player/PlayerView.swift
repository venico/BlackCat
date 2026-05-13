import SwiftUI
import AVKit
import AVFoundation

struct PlayerView: View {
    @EnvironmentObject private var project: ProjectState
    @StateObject private var ctrl = PlayerController()
    @State private var hoveringPlayer = false
    @State private var keyMonitor: Any? = nil

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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 49 else { return event }
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                ctrl.toggle()
                return nil
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
                let spacing    = CGFloat(baseStyle.lineSpacing)
                let bottomPad  = geo.size.height * baseStyle.bottomMargin / 100.0

                VStack(spacing: spacing) {
                    ForEach(pairs.indices, id: \.self) { i in
                        SubtitleLabel(text: pairs[i].0, style: pairs[i].1)
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
    let text: String; let style: SubtitleStyle
    var body: some View {
        Text(text)
            .font(.custom(style.fontName, size: style.fontSize).weight(style.bold ? .bold : .regular))
            .italic(style.italic)
            .foregroundColor(style.textColor)
            .shadow(color: .black.opacity(0.8), radius: 1, x: 1, y: 1)
            .shadow(color: .black.opacity(0.8), radius: 1, x: -1, y: -1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(style.backgroundColor.opacity(style.backgroundOpacity))
            .cornerRadius(3)
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
