import SwiftUI
import Combine
import AVFoundation
import CoreText

// MARK: - Export Job Manager (supports multiple concurrent exports)

final class ExportManager: ObservableObject {
    static let shared = ExportManager()

    struct Job: Identifiable {
        let id = UUID()
        let filename: String
        var progress: Double = 0
        var state: JobState = .running
        var outputURL: URL?
        var error: String?
    }

    enum JobState { case running, done, failed }

    @Published var jobs: [Job] = []

    /// 从列表移除已完成/失败的 job
    func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) {
            jobs.removeAll { $0.id == id }
        }
    }

    private var autoDismissTimers: [UUID: DispatchWorkItem] = [:]

    private func scheduleAutoDismiss(id: UUID) {
        autoDismissTimers[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.dismiss(id)
            self?.autoDismissTimers.removeValue(forKey: id)
        }
        autoDismissTimers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// 启动一个新的导出任务，立即返回
    func startExport(snapshot: ExportInput) {
        let job = Job(filename: snapshot.outputURL.lastPathComponent, outputURL: snapshot.outputURL)
        let jobID = job.id
        withAnimation(.easeOut(duration: 0.25)) { jobs.append(job) }

        Task.detached {
            let exporter = TimelineExporter()
            do {
                let url = try await exporter.export(snapshot) { p in
                    Task { @MainActor in
                        if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                            self.jobs[i].progress = p
                        }
                    }
                }
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                        self.jobs[i].progress = 1
                        self.jobs[i].state = .done
                        self.jobs[i].outputURL = url
                    }
                    self.scheduleAutoDismiss(id: jobID)
                }
            } catch {
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                        self.jobs[i].state = .failed
                        self.jobs[i].error = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Export Progress Overlay (bottom-right bubbles)

struct ExportProgressOverlay: View {
    @ObservedObject var manager: ExportManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(manager.jobs) { job in
                ExportJobBubble(job: job) {
                    if job.state == .done, let url = job.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    manager.dismiss(job.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: manager.jobs.count)
    }
}

private struct ExportJobBubble: View {
    let job: ExportManager.Job
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconBgColor)
                        .frame(width: 28, height: 28)
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconFgColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.filename)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1).truncationMode(.middle)

                    switch job.state {
                    case .running:
                        HStack(spacing: 6) {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .tint(Color.accent)
                                .frame(width: 100)
                            Text("\(Int(job.progress * 100))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color.labelSecondary)
                        }
                    case .done:
                        Text("导出完成 · 点击查看")
                            .font(.system(size: 10))
                            .foregroundColor(Color.accent)
                    case .failed:
                        Text("导出失败")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }

                if job.state != .running {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(hovering ? 0.15 : 0.08))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var iconName: String {
        switch job.state {
        case .running: return "square.and.arrow.up"
        case .done:    return "checkmark"
        case .failed:  return "exclamationmark.triangle"
        }
    }

    private var iconBgColor: Color {
        switch job.state {
        case .running: return Color.accent.opacity(0.2)
        case .done:    return Color.green.opacity(0.2)
        case .failed:  return Color.red.opacity(0.2)
        }
    }

    private var iconFgColor: Color {
        switch job.state {
        case .running: return Color.accent
        case .done:    return .green
        case .failed:  return .red.opacity(0.8)
        }
    }
}

// MARK: - Export Sheet

struct ExportSheetView: View {
    @EnvironmentObject private var project: ProjectState
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("导出视频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.divider)

            // Settings
            VStack(alignment: .leading, spacing: 12) {

                    // Output path
                    ESection(title: "输出位置") {
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundColor(Color.labelSecondary)
                                Text(project.exportSettings.outputPath?.path ?? "未选择")
                                    .font(.system(size: 11))
                                    .foregroundColor(project.exportSettings.outputPath == nil
                                                     ? Color.labelSecondary.opacity(0.5)
                                                     : Color.labelPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(7)

                            Button {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.prompt = "选择"
                                if panel.runModal() == .OK {
                                    project.exportSettings.outputPath = panel.url
                                }
                            } label: {
                                Text("选择")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color.labelPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(7)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // File name
                    ESection(title: "文件名") {
                        HStack(spacing: 6) {
                            TextField("", text: $project.exportSettings.filename,
                                      prompt: Text(defaultFilename())
                                        .foregroundColor(Color.labelSecondary.opacity(0.5)))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(Color.labelPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(7)
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.10)))
                            Text(extLabel)
                                .font(.system(size: 11))
                                .foregroundColor(Color.labelSecondary)
                        }
                    }

                    // Resolution
                    ESection(title: "分辨率") {
                        IPicker(selection: $project.exportSettings.resolution,
                                options: ExportSettings.resolutions.map { ($0, $0) })
                    }

                    // Frame rate
                    ESection(title: "帧率") {
                        HStack(spacing: 8) {
                            ForEach(ExportSettings.fpsOptions, id: \.self) { fps in
                                Button {
                                    project.exportSettings.fps = fps
                                } label: {
                                    Text("\(fps) fps")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(project.exportSettings.fps == fps ? .black : Color.labelPrimary)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .background(project.exportSettings.fps == fps ? Color.accent : Color.white.opacity(0.08))
                                        .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Bitrate
                    ESection(title: "码率") {
                        VStack(spacing: 8) {
                            HStack {
                                Text("视频码率")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.labelSecondary)
                                Spacer()
                                Text("\(project.exportSettings.bitrate) kbps")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(Color.labelPrimary)
                            }
                            Slider(value: Binding(
                                get: { Double(project.exportSettings.bitrate) },
                                set: { project.exportSettings.bitrate = Int(($0 / 500).rounded() * 500) }
                            ), in: 500...50000)
                            .frame(height: 20)
                            .accentColor(Color.accent)

                            HStack {
                                ForEach(BitratePreset.all, id: \.label) { preset in
                                    Button {
                                        project.exportSettings.bitrate = preset.value
                                    } label: {
                                        Text(preset.label)
                                            .font(.system(size: 10))
                                            .foregroundColor(Color.labelSecondary)
                                            .padding(.horizontal, 8).frame(height: 24)
                                            .background(Color.white.opacity(0.06))
                                            .cornerRadius(4)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Export type
                    ESection(title: "导出内容") {
                        HStack(spacing: 8) {
                            ForEach(ExportContent.allCases, id: \.self) { kind in
                                let selected = project.exportSettings.content == kind
                                Button { project.exportSettings.content = kind } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: contentIcon(kind))
                                            .font(.system(size: 11, weight: .light))
                                        Text(contentLabel(kind))
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundColor(selected ? .black : Color.labelPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .background(selected ? Color.accent : Color.white.opacity(0.08))
                                    .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)

            Divider().background(Color.divider)

            // Action row
            HStack(spacing: 16) {
                Group {
                    if let err = exportError {
                        Text(err)
                            .font(.system(size: 11)).foregroundColor(.red.opacity(0.85))
                            .lineLimit(2)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 13))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 80, height: 36)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    startExport()
                } label: {
                    Text("开始导出")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 120, height: 36)
                        .background(Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
    }

    private var extLabel: String {
        switch project.exportSettings.content {
        case .video:        return ".mp4"
        case .audioOnly:    return ".m4a"
        case .subtitleOnly: return ".srt"
        }
    }

    private func defaultFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return "VideoEditor_\(f.string(from: Date()))"
    }

    private func contentIcon(_ c: ExportContent) -> String {
        switch c {
        case .video:        return "film"
        case .audioOnly:    return "music.note"
        case .subtitleOnly: return "captions.bubble"
        }
    }

    private func contentLabel(_ c: ExportContent) -> String {
        switch c {
        case .video:        return "视频"
        case .audioOnly:    return "仅音频"
        case .subtitleOnly: return "仅字幕"
        }
    }

    private func startExport() {
        guard let outputDir = project.exportSettings.outputPath else {
            exportError = "请先选择输出位置"
            return
        }
        let raw = project.exportSettings.filename.trimmingCharacters(in: .whitespaces)
        let baseName = raw.isEmpty ? defaultFilename() : raw
        let ext: String
        switch project.exportSettings.content {
        case .video:        ext = ".mp4"
        case .audioOnly:    ext = ".m4a"
        case .subtitleOnly: ext = ".srt"
        }
        let cleanName = baseName.hasSuffix(ext) ? baseName : "\(baseName)\(ext)"
        let outputURL = outputDir.appendingPathComponent(cleanName)

        let snapshot = ExportInput(
            videoTracks: project.videoTracks,
            audioTracks: project.audioTracks,
            subtitleTracks: project.subtitleTracks,
            imageTracks: project.imageTracks,
            subtitleStyles: project.subtitleStyles,
            settings: project.exportSettings,
            outputURL: outputURL)

        // 立即关闭导出面板，进度在右下角气泡显示
        dismiss()
        ExportManager.shared.startExport(snapshot: snapshot)
    }
}

// MARK: - Export pipeline

struct ExportInput {
    let videoTracks:    [Track<VideoClip>]
    let audioTracks:    [Track<AudioClip>]
    let subtitleTracks: [Track<SubtitleClip>]
    let imageTracks:    [Track<ImageClip>]
    let subtitleStyles: [SubtitleStyle]
    let settings:       ExportSettings
    let outputURL:      URL
}

actor TimelineExporter {
    func export(_ input: ExportInput,
                progress: @escaping (Double) -> Void) async throws -> URL {
        let settings = input.settings

        // ── 仅字幕模式：导出 SRT 文件 ──
        if settings.content == .subtitleOnly {
            return try exportSRT(input: input, progress: progress)
        }

        let composition = AVMutableComposition()
        var audioMixParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float)] = []
        var sourceVideoSize: CGSize = CGSize(width: 1920, height: 1080)
        var sourceFrameDuration: CMTime = CMTime(value: 1, timescale: 30)
        let includeVideo = settings.content == .video
        let includeAudio = true  // video 和 audioOnly 都需要音频

        // ── 视频轨道 ──
        for track in input.videoTracks {
            for (idx, clip) in track.clips.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
                guard let url = clip.url else { continue }
                let asset = AVURLAsset(url: url)
                let assetDur = try await asset.load(.duration)
                let trimSt = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                let maxDur = assetDur - trimSt
                let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                let range  = CMTimeRange(start: trimSt, duration: useDur)
                let at     = CMTime(seconds: clip.startTime, preferredTimescale: 600)

                // 视频画面（可见 + video模式才加）
                if includeVideo && track.isVisible,
                   let vAsset = try? await asset.loadTracks(withMediaType: .video).first {
                    let vt = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
                    try vt?.insertTimeRange(range, of: vAsset, at: at)
                    if idx == 0 {
                        sourceVideoSize = try await vAsset.load(.naturalSize)
                        let mfd = try await vAsset.load(.minFrameDuration)
                        if mfd.isValid && mfd.seconds > 0 { sourceFrameDuration = mfd }
                    }
                }
                // 音频（未静音才加）
                if includeAudio && !track.isMuted,
                   let aAsset = try? await asset.loadTracks(withMediaType: .audio).first {
                    let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
                    if let at2 { try at2.insertTimeRange(range, of: aAsset, at: at) }
                    if let tid = at2?.trackID {
                        audioMixParams.append((tid, clip.volume, 1.0, 1.0))
                    }
                }
            }
        }

        // ── 音频轨道 ──
        for track in input.audioTracks {
            guard track.isVisible && !track.isMuted else { continue }
            for clip in track.clips {
                guard let url = clip.url else { continue }
                let asset = AVURLAsset(url: url)
                guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                let assetDur = try await asset.load(.duration)
                let trimSt = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                let maxDur = assetDur - trimSt
                let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxDur)
                let range = CMTimeRange(start: trimSt, duration: useDur)
                let at    = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                let extra = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
                if let extra { try extra.insertTimeRange(range, of: aAsset, at: at) }
                if let tid = extra?.trackID {
                    audioMixParams.append((tid, clip.volume, clip.leftChannel, clip.rightChannel))
                }
            }
        }

        // ── 图片轨道（上层）──
        var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []
        if includeVideo {
            let endTime = composition.duration.seconds
            for track in input.imageTracks {
                guard track.isVisible else { continue }
                for clip in track.clips {
                    guard let url = clip.videoURL else { continue }
                    let asset = AVURLAsset(url: url)
                    let assetDur = try await asset.load(.duration)
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), assetDur)
                    guard useDur.seconds > 0.01 else { continue }
                    if let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        // 先填充 clip 之前的空白区间
                        if clip.startTime > 0.01 {
                            var pos = CMTime.zero
                            let fillEnd = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        // 在 clip 的时间位置插入实际内容
                        let range = CMTimeRange(start: .zero, duration: useDur)
                        let at = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        // clip 之后也填充到 endTime
                        let afterEnd = clip.startTime + useDur.seconds
                        if endTime > afterEnd + 0.01 {
                            var pos = CMTime(seconds: afterEnd, preferredTimescale: 600)
                            let fillEnd = CMTime(seconds: endTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        imageCompTracks.append((track: vt, clip: clip))
                    }
                }
            }
        }

        // ── AudioMix（音量 + 声道）──
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParams.map { param in
            let p = AVMutableAudioMixInputParameters(track: composition.track(withTrackID: param.trackID))
            p.trackID = param.trackID
            p.setVolume(param.volume, at: .zero)
            if param.left != 1.0 || param.right != 1.0 {
                if let tap = makeChannelTap(left: param.left, right: param.right) {
                    p.audioTapProcessor = tap
                }
            }
            return p
        }

        // ── 字幕烧录 + 图片合成（仅 video 模式）──
        var videoComposition: AVMutableVideoComposition? = nil
        if includeVideo {
            // 应用导出设置的分辨率
            let renderSize = self.parseResolution(settings.resolution, fallback: sourceVideoSize)
            // 应用导出设置的帧率
            let fps = settings.fps
            let frameDuration = CMTime(value: 1, timescale: Int32(fps))

            let visibleSubs = input.subtitleTracks.enumerated().compactMap {
                $0.element.isVisible && !$0.element.clips.isEmpty
                    ? (idx: $0.offset, track: $0.element) : nil
            }

            let hasImageTracks = !imageCompTracks.isEmpty
            let videoTracksList = composition.tracks(withMediaType: .video).filter { ct in
                !imageCompTracks.contains(where: { $0.track.trackID == ct.trackID })
            }

            // Step 1: 图片合成 / 分辨率帧率变更
            if hasImageTracks {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = frameDuration

                let ts: CMTimeScale = 600
                let imageClipCMRanges = imageCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.clip.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.clip.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                var cmBoundaries: [CMTime] = [.zero, composition.duration]
                for r in imageClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                let sortedCM = Array(Set(cmBoundaries.map { $0.value })).sorted().map { CMTime(value: $0, timescale: ts) }

                var instructions: [AVMutableVideoCompositionInstruction] = []
                for i in 0..<(sortedCM.count - 1) {
                    let segStartCM = sortedCM[i]
                    let segEndCM   = sortedCM[i + 1]
                    let segDur = segEndCM - segStartCM
                    guard segDur.seconds > 0.001 else { continue }

                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: segStartCM, duration: segDur)
                    instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

                    var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                    for (idx, entry) in imageCompTracks.enumerated() {
                        let clipStartCM = imageClipCMRanges[idx].start
                        let clipEndCM   = imageClipCMRanges[idx].end
                        let clipActive = segStartCM >= clipStartCM && segStartCM < clipEndCM
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                        if clipActive {
                            if let natSize = try? await entry.track.load(.naturalSize), natSize.width > 0, natSize.height > 0 {
                                let t = ProjectState.imageTransform(clip: entry.clip, natSize: natSize, renderSize: renderSize)
                                li.setTransform(t, at: .zero)
                                let c = entry.clip
                                if c.cropTop > 0.001 || c.cropBottom > 0.001 || c.cropLeft > 0.001 || c.cropRight > 0.001 {
                                    li.setCropRectangle(ProjectState.imageCropRect(clip: c, natSize: natSize), at: .zero)
                                }
                            }
                        } else {
                            li.setOpacity(0, at: .zero)
                        }
                        layerInstructions.append(li)
                    }
                    for vt in videoTracksList {
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                        let scaleX = renderSize.width / sourceVideoSize.width
                        let scaleY = renderSize.height / sourceVideoSize.height
                        li.setTransform(CGAffineTransform(scaleX: scaleX, y: scaleY), at: .zero)
                        layerInstructions.append(li)
                    }
                    instruction.layerInstructions = layerInstructions
                    instructions.append(instruction)
                }
                if !instructions.isEmpty { vc.instructions = instructions }
                videoComposition = vc
            } else if renderSize != sourceVideoSize || fps != Int(1.0 / sourceFrameDuration.seconds) {
                if let sourceVTrack = composition.tracks(withMediaType: .video).first {
                    let vc = AVMutableVideoComposition()
                    vc.renderSize = renderSize
                    vc.frameDuration = frameDuration
                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVTrack)
                    let scaleX = renderSize.width / sourceVideoSize.width
                    let scaleY = renderSize.height / sourceVideoSize.height
                    li.setTransform(CGAffineTransform(scaleX: scaleX, y: scaleY), at: .zero)
                    instr.layerInstructions = [li]
                    vc.instructions = [instr]
                    videoComposition = vc
                }
            }

            // Step 2: 字幕烧录 — 独立于图片/分辨率，只要有可见字幕就叠加
            if !visibleSubs.isEmpty {
                // 如果还没有 videoComposition，先创建一个基础的
                if videoComposition == nil {
                    let vc = AVMutableVideoComposition()
                    vc.renderSize = renderSize
                    vc.frameDuration = frameDuration
                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                    instr.layerInstructions = composition.tracks(withMediaType: .video).map { vt in
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                        li.setOpacity(1.0, at: .zero)
                        return li
                    }
                    vc.instructions = [instr]
                    videoComposition = vc
                }

                if let vc = videoComposition {
                    // 所有 instruction 开启 enablePostProcessing
                    for case let instr as AVMutableVideoCompositionInstruction in vc.instructions {
                        instr.enablePostProcessing = true
                    }

                    let videoLayer = CALayer()
                    videoLayer.frame = CGRect(origin: .zero, size: renderSize)
                    let parentLayer = CALayer()
                    parentLayer.frame = CGRect(origin: .zero, size: renderSize)
                    parentLayer.isGeometryFlipped = true
                    parentLayer.addSublayer(videoLayer)

                    let visibleTrackData: [(track: Track<SubtitleClip>, style: SubtitleStyle, idx: Int)] =
                        input.subtitleTracks.enumerated().compactMap { i, t in
                            guard t.isVisible && !t.clips.isEmpty else { return nil }
                            let s = i < input.subtitleStyles.count ? input.subtitleStyles[i] : SubtitleStyle()
                            return (t, s, i)
                        }
                    let baseStyle = visibleTrackData.first?.style ?? SubtitleStyle()
                    let totalDuration = composition.duration.seconds

                    for td in visibleTrackData {
                        let trackOffset = CGFloat(td.idx) * (td.style.fontSize + CGFloat(baseStyle.lineSpacing) + 12)
                        for clip in td.track.clips {
                            let layer = self.makeSubtitleTextLayer(
                                text: clip.text, style: td.style, renderSize: renderSize,
                                startTime: clip.startTime, endTime: clip.endTime,
                                totalDuration: totalDuration, trackOffset: trackOffset)
                            parentLayer.addSublayer(layer)
                        }
                    }

                    vc.animationTool = AVVideoCompositionCoreAnimationTool(
                        postProcessingAsVideoLayer: videoLayer,
                        in: parentLayer)
                }
            }
        }

        // ── 配置导出器 ──
        let isAudioOnly = settings.content == .audioOnly
        let presetName = isAudioOnly
            ? AVAssetExportPresetAppleM4A
            : (videoComposition != nil ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName)
        else {
            throw NSError(domain: "Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        exporter.outputURL = input.outputURL
        exporter.outputFileType = isAudioOnly ? .m4a : .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.audioMix = audioMix
        if let vc = videoComposition { exporter.videoComposition = vc }

        try? FileManager.default.removeItem(at: input.outputURL)

        let progressTask = Task {
            while !Task.isCancelled {
                let st = exporter.status
                if st == .completed || st == .failed || st == .cancelled { break }
                progress(Double(exporter.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()

        switch exporter.status {
        case .completed:
            progress(1.0)
            return input.outputURL
        case .cancelled:
            throw NSError(domain: "Export", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "导出已取消"])
        default:
            throw exporter.error ?? NSError(domain: "Export", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "导出失败 (\(exporter.status.rawValue))"])
        }
    }

    // ── 导出 SRT 字幕文件 ──
    private func exportSRT(input: ExportInput,
                           progress: @escaping (Double) -> Void) throws -> URL {
        var srt = ""
        var idx = 1
        for track in input.subtitleTracks where track.isVisible {
            for clip in track.clips.sorted(by: { $0.startTime < $1.startTime }) {
                srt += "\(idx)\n"
                srt += "\(srtTime(clip.startTime)) --> \(srtTime(clip.endTime))\n"
                srt += "\(clip.text)\n\n"
                idx += 1
            }
        }
        try? FileManager.default.removeItem(at: input.outputURL)
        try srt.write(to: input.outputURL, atomically: true, encoding: .utf8)
        progress(1.0)
        return input.outputURL
    }

    private func srtTime(_ t: Double) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// 解析分辨率字符串，如 "1080p  1920×1080" → CGSize(1920, 1080)
    private func parseResolution(_ str: String, fallback: CGSize) -> CGSize {
        // 匹配 "数字×数字" 或 "数字x数字"
        let pattern = #"(\d{3,5})\s*[×xX]\s*(\d{3,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let wRange = Range(match.range(at: 1), in: str),
              let hRange = Range(match.range(at: 2), in: str),
              let w = Int(str[wRange]), let h = Int(str[hRange])
        else { return fallback }
        return CGSize(width: w, height: h)
    }

    // MARK: - Subtitle burn-in
    //
    // Build an AVVideoComposition with a CALayer-based animation tool so that
    // every subtitle clip becomes a CATextLayer whose opacity animates between
    // its `startTime` and `endTime`. AVAssetExportSession then renders the
    // composed CALayer hierarchy on top of every video frame.

    private func buildVideoCompositionWithSubtitles(
        composition: AVMutableComposition,
        videoTrack: AVCompositionTrack,
        renderSize: CGSize,
        frameDuration: CMTime,
        subtitleTracks: [Track<SubtitleClip>],
        subtitleStyles: [SubtitleStyle]
    ) -> AVMutableVideoComposition {

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = frameDuration

        // Single instruction covering the whole composition.
        // CRITICAL: enablePostProcessing must be true for the animationTool's
        // CALayer hierarchy to actually be composited on top of each frame.
        // Apple's default for manually-built AVMutableVideoCompositionInstruction
        // is NO; without this, the subtitle layers are silently ignored.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.enablePostProcessing = true
        instruction.layerInstructions = composition.tracks(withMediaType: .video).map { vt in
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
            li.setOpacity(1.0, at: .zero)
            return li
        }
        videoComp.instructions = [instruction]

        // Layer hierarchy:  parentLayer → [ videoLayer (where frames go) , textLayers… ]
        // Setting parentLayer.beginTime = AVCoreAnimationBeginTimeAtZero so child
        // animation beginTimes are interpreted in composition time (not "now").
        let videoLayer  = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true
        parentLayer.addSublayer(videoLayer)

        let visibleTrackData: [(track: Track<SubtitleClip>, style: SubtitleStyle, idx: Int)] =
            subtitleTracks.enumerated().compactMap { i, t in
                guard t.isVisible else { return nil }
                let s = i < subtitleStyles.count ? subtitleStyles[i] : SubtitleStyle()
                return (t, s, i)
            }

        let baseStyle = visibleTrackData.first?.style ?? SubtitleStyle()
        let spacing   = baseStyle.lineSpacing
        let totalDuration = composition.duration.seconds

        for td in visibleTrackData {
            let trackOffset = CGFloat(td.idx) * (td.style.fontSize + CGFloat(spacing) + 12)
            for clip in td.track.clips {
                let layer = self.makeSubtitleTextLayer(
                    text: clip.text, style: td.style, renderSize: renderSize,
                    startTime: clip.startTime, endTime: clip.endTime,
                    totalDuration: totalDuration, trackOffset: trackOffset)
                parentLayer.addSublayer(layer)
            }
        }

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer)

        return videoComp
    }

    private func makeSubtitleTextLayer(
        text: String, style: SubtitleStyle, renderSize: CGSize,
        startTime: Double, endTime: Double,
        totalDuration: Double, trackOffset: CGFloat
    ) -> CALayer {
        let maxWidth = renderSize.width * style.widthPercent / 100
        let padH: CGFloat = 16, padV: CGFloat = 8

        // 解析颜色
        let tc = NSColor(style.textColor).usingColorSpace(.sRGB) ?? .white
        var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
        tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

        let ctFont = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)

        var alignment: CTTextAlignment
        switch style.alignment {
        case "left":  alignment = .left
        case "right": alignment = .right
        default:      alignment = .center
        }
        let ctPS: CTParagraphStyle = withUnsafeBytes(of: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: ptr.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): ctFont,
            .init(kCTForegroundColorAttributeName as String): textCGColor,
            .init(kCTParagraphStyleAttributeName as String): ctPS
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: maxWidth - padH * 2, height: CGFloat.greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)

        let layerW = ceil(textSize.width) + padH * 2
        let layerH = ceil(textSize.height) + padV * 2
        let w = Int(layerW), h = Int(layerH)

        // 渲染背景+文字到 CGImage（y-down 坐标系，匹配 isGeometryFlipped=true）
        var cgImage: CGImage? = nil
        if w > 0 && h > 0 {
            let space = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                             | CGBitmapInfo.byteOrder32Little.rawValue) {
                // 翻转为 y-down，和 parentLayer 坐标系一致
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1.0, y: -1.0)

                // 背景
                if style.backgroundOpacity > 0 {
                    let nc = NSColor(style.backgroundColor).usingColorSpace(.sRGB) ?? .black
                    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                    nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                    ctx.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                             alpha: CGFloat(style.backgroundOpacity)))
                    ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: CGSize(width: layerW, height: layerH)),
                                       cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.fillPath()
                }

                // 文字（CoreText 需要 y-up，再翻回来）
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1.0, y: -1.0)
                let textRect = CGRect(x: padH, y: padV,
                                      width: CGFloat(w) - padH * 2,
                                      height: CGFloat(h) - padV * 2)
                let ctFrame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: textRect, transform: nil), nil)
                CTFrameDraw(ctFrame, ctx)
                ctx.restoreGState()

                cgImage = ctx.makeImage()
            }
        }

        let layer = CALayer()
        let xOrig = (renderSize.width - layerW) / 2
        let yOrig = renderSize.height - renderSize.height * CGFloat(style.bottomMargin) / 100
                    - layerH - trackOffset
        layer.frame = CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH)
        layer.contentsGravity = .resize
        layer.contentsScale = 1.0
        if let img = cgImage { layer.contents = img }

        layer.opacity = 0
        let t = max(totalDuration, endTime + 0.1)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = t
        anim.calculationMode = .discrete
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        anim.keyTimes = [0, NSNumber(value: max(0, startTime) / t),
                         NSNumber(value: endTime / t), 1]
        anim.values = [0, 1, 0, 0]
        layer.add(anim, forKey: "visibility")

        return layer
    }

    // Compute all unique time slots from subtitle tracks. Each slot is a
    // (start, end) interval defined by the union of all clip boundaries.
    private func allTimeSlots(tracks: [Track<SubtitleClip>]) -> [(start: Double, end: Double)] {
        var edges = Set<Double>()
        for track in tracks {
            for clip in track.clips {
                edges.insert(clip.startTime)
                edges.insert(clip.endTime)
            }
        }
        let sorted = edges.sorted()
        guard sorted.count >= 2 else { return [] }

        var slots: [(start: Double, end: Double)] = []
        for i in 0..<(sorted.count - 1) {
            let s = sorted[i], e = sorted[i + 1]
            // Only keep this slot if at least one track has a subtitle here
            let hasContent = tracks.contains { track in
                track.clips.contains { $0.startTime <= s && $0.endTime > s }
            }
            if hasContent {
                slots.append((s, e))
            }
        }
        return slots
    }

    // Pre-render text + background into a plain CALayer whose `contents` is a
    // CGImage drawn with CoreText. Background tightly wraps the text (not full width).
    private func makeSubtitleLayer(text: String,
                                   style: SubtitleStyle,
                                   renderSize: CGSize,
                                   startTime: Double,
                                   endTime: Double,
                                   totalDuration: Double,
                                   yOrigin: CGFloat? = nil) -> CALayer {
        let maxWidthPx = renderSize.width * style.widthPercent / 100
        let padH: CGFloat = 16   // horizontal padding around text
        let padV: CGFloat = 6    // vertical padding around text

        // Measure actual text size with CoreText
        let ctFont = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): ctFont
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let setter  = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: maxWidthPx - padH * 2, height: CGFloat.greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, constraint, nil)

        // Layer size = text + padding, not full video width
        let layerW = ceil(textSize.width) + padH * 2
        let layerH = ceil(textSize.height) + padV * 2
        let xOrig  = (renderSize.width - layerW) / 2
        let yOrig: CGFloat = yOrigin ?? (renderSize.height * CGFloat(style.bottomMargin) / 100)

        let layer = CALayer()
        layer.frame = CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH)
        layer.contentsGravity = .resize
        layer.contentsScale = 1.0

        if let img = renderSubtitleImage(text: text, style: style,
                                         size: CGSize(width: layerW, height: layerH),
                                         padH: padH, padV: padV) {
            layer.contents = img
        }

        layer.opacity = 0

        // AVVideoCompositionCoreAnimationTool samples each frame individually —
        // CABasicAnimation fill modes are not applied. A CAKeyframeAnimation that
        // spans the full composition is the reliable way to control per-frame opacity.
        let t = max(totalDuration, endTime + 0.1)
        let s0 = max(0.0, startTime)
        let e0 = min(t, endTime)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.beginTime       = AVCoreAnimationBeginTimeAtZero
        anim.duration        = t
        anim.calculationMode = .discrete
        anim.fillMode        = .both
        anim.isRemovedOnCompletion = false
        anim.keyTimes = [0,
                         NSNumber(value: s0 / t),
                         NSNumber(value: e0 / t),
                         1]
        anim.values   = [0, 1, 0, 0]
        layer.add(anim, forKey: "visibility")

        return layer
    }

    // Render subtitle text into a CGImage using CoreText. Background tightly
    // wraps text with the given padding.
    private func renderSubtitleImage(text: String,
                                     style: SubtitleStyle,
                                     size: CGSize,
                                     padH: CGFloat = 16,
                                     padV: CGFloat = 6) -> CGImage? {
        let w = Int(size.width); let h = Int(size.height)
        guard w > 0 && h > 0 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Background rounded rect — tightly wraps text
        if style.backgroundOpacity > 0 {
            let nc = NSColor(style.backgroundColor).usingColorSpace(.sRGB) ?? .black
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nc.getRed(&r, green: &g, blue: &b, alpha: &a)
            ctx.setFillColor(CGColor(red: r, green: g, blue: b,
                                     alpha: CGFloat(style.backgroundOpacity)))
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                               cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }

        ctx.saveGState()

        // Resolve text color
        let tc = NSColor(style.textColor).usingColorSpace(.sRGB) ?? .white
        var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
        tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let textCG = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

        let ctFont = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)

        var alignment: CTTextAlignment
        switch style.alignment {
        case "left":  alignment = .left
        case "right": alignment = .right
        default:      alignment = .center
        }
        let ctPS: CTParagraphStyle = withUnsafeBytes(of: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: ptr.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String):            ctFont,
            .init(kCTForegroundColorAttributeName as String): textCG,
            .init(kCTParagraphStyleAttributeName as String):  ctPS
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let setter  = CTFramesetterCreateWithAttributedString(attrStr)
        let textRect = CGRect(x: padH, y: padV,
                              width: size.width - padH * 2, height: size.height - padV * 2)
        let ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                               CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(ctFrame, ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

private struct BitratePreset {
    let label: String
    let value: Int
    static let all: [BitratePreset] = [
        .init(label: "低质量", value: 2000),
        .init(label: "标准",   value: 8000),
        .init(label: "高质量", value: 20000),
        .init(label: "无损",   value: 50000),
    ]
}

private struct ESection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary).tracking(0.4).textCase(.uppercase)
            content
        }
    }
}
