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
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var exporters: [UUID: TimelineExporter] = [:]
    var onSuccess: ((String, URL?) -> Void)?
    var onCancel: ((String) -> Void)?

    func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) {
            jobs.removeAll { $0.id == id }
        }
    }

    func cancelExport(_ id: UUID) {
        exportTasks[id]?.cancel()
        exportTasks.removeValue(forKey: id)
        if let exp = exporters.removeValue(forKey: id) {
            Task { await exp.cancel() }
        }
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            let filename = jobs[i].filename
            let url = jobs[i].outputURL
            withAnimation(.easeOut(duration: 0.25)) { jobs.remove(at: i) }
            if let url { try? FileManager.default.removeItem(at: url) }
            onCancel?(filename)
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

    func startExport(snapshot: ExportInput) {
        let job = Job(filename: snapshot.outputURL.lastPathComponent, outputURL: snapshot.outputURL)
        let jobID = job.id
        let filename = job.filename
        withAnimation(.easeOut(duration: 0.25)) { jobs.append(job) }

        let exporter = TimelineExporter()
        exporters[jobID] = exporter

        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let url = try await exporter.export(snapshot) { p in
                    Task { @MainActor in
                        if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                            self.jobs[i].progress = p
                        }
                    }
                }
                await MainActor.run {
                    self.dismiss(jobID)
                    self.exportTasks.removeValue(forKey: jobID)
                    self.exporters.removeValue(forKey: jobID)
                    self.onSuccess?(filename, url)
                }
            } catch {
                await MainActor.run {
                    if let i = self.jobs.firstIndex(where: { $0.id == jobID }) {
                        self.jobs[i].state = .failed
                        self.jobs[i].error = error.localizedDescription
                    }
                    self.exportTasks.removeValue(forKey: jobID)
                    self.exporters.removeValue(forKey: jobID)
                    self.scheduleAutoDismiss(id: jobID)
                }
            }
        }
        exportTasks[jobID] = task
    }
}

// MARK: - Export Progress Overlay (bottom-right bubbles)

struct ExportProgressOverlay: View {
    @ObservedObject var manager: ExportManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(manager.jobs) { job in
                ExportJobBubble(job: job, onCancel: { manager.cancelExport(job.id) }, onDismiss: { manager.dismiss(job.id) })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: manager.jobs.count)
    }
}

private struct ExportJobBubble: View {
    let job: ExportManager.Job
    let onCancel: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var xHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconBgColor)
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconFgColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.truncatedFilename(job.filename))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)

                switch job.state {
                case .running:
                    GeometryReader { geo in
                        HStack(spacing: 6) {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .tint(Color.accent)
                            Text("\(Int(job.progress * 100))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(Color.labelSecondary)
                                .fixedSize()
                        }
                        .frame(width: geo.size.width)
                    }
                    .frame(height: 14)
                case .failed:
                    Text(job.error ?? "导出失败")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                default: EmptyView()
                }
            }

            Button(action: job.state == .running ? onCancel : onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(xHovering ? Color.labelPrimary : Color.labelSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(xHovering ? 0.15 : 0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHovering = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
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

    private static func truncatedFilename(_ name: String, maxVisualWidth: Int = 28) -> String {
        guard visualWidth(of: name) > maxVisualWidth else { return name }
        let ext: String
        let base: String
        if let dotIdx = name.lastIndex(of: ".") {
            ext = String(name[dotIdx...])
            base = String(name[..<dotIdx])
        } else {
            ext = ""
            base = name
        }
        let tailLen = 6
        guard tailLen < base.count else { return name }
        let tail = String(base.suffix(tailLen))
        let dotsWidth = 3
        let tailWidth = visualWidth(of: tail)
        let extWidth = visualWidth(of: ext)
        let budget = maxVisualWidth - dotsWidth - tailWidth - extWidth
        guard budget > 0 else { return name }
        var head = ""
        var used = 0
        for ch in base {
            let w = ch.isCJK ? 2 : 1
            if used + w > budget { break }
            head.append(ch)
            used += w
        }
        guard !head.isEmpty else { return name }
        return "\(head)...\(tail)\(ext)"
    }

    private static func visualWidth(of str: String) -> Int {
        str.reduce(0) { $0 + ($1.isCJK ? 2 : 1) }
    }
}

// MARK: - Export Sheet

struct ExportSheetView: View {
    @EnvironmentObject private var project: ProjectState
    private func dismiss() { project.showExportSheet = false }
    @State private var exportError: String?

    private var effectiveOutputPath: URL {
        project.exportSettings.outputPath ?? AppSettings.shared.effectiveExportDir
    }

    /// 预估导出文件大小
    private var estimatedFileSize: String {
        let dur = project.duration
        guard dur > 0 else { return "—" }
        let videoBits = Double(project.exportSettings.bitrate) * 1000.0 * dur
        let audioBits = 192_000.0 * dur  // AAC 192kbps
        let totalBytes = (videoBits + audioBits) / 8.0
        if totalBytes >= 1_073_741_824 {
            return String(format: "≈ %.1f GB", totalBytes / 1_073_741_824)
        } else {
            return String(format: "≈ %.0f MB", totalBytes / 1_048_576)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("导出视频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
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
                                Image(nsImage: SidebarSVGIcon.load("folder"))
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(Color.labelSecondary)
                                Text(effectiveOutputPath.path)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.labelPrimary)
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
                                panel.directoryURL = effectiveOutputPath
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
                            FocusTextField(text: $project.exportSettings.filename, placeholder: defaultFilename())
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
                            CustomSlider(value: Binding(
                                get: { Double(project.exportSettings.bitrate) },
                                set: { project.exportSettings.bitrate = Int(($0 / 500).rounded() * 500) }
                            ), range: 500...50000)

                            HStack {
                                ForEach(BitratePreset.all, id: \.label) { preset in
                                    Button {
                                        project.exportSettings.bitrate = preset.value
                                    } label: {
                                        Text(preset.label)
                                            .font(.system(size: 10))
                                            .foregroundColor(project.exportSettings.bitrate == preset.value ? .black : Color.labelSecondary)
                                            .padding(.horizontal, 8).frame(height: 24)
                                            .background(project.exportSettings.bitrate == preset.value ? Color(hex: "#E8A54B") : Color.white.opacity(0.06))
                                            .cornerRadius(4)
                                    }.buttonStyle(.plain)
                                }
                            }

                            // 预估文件大小
                            HStack {
                                Text("预估大小")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.labelSecondary.opacity(0.6))
                                Spacer()
                                Text(estimatedFileSize)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color.labelSecondary.opacity(0.6))
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
                                        Image(nsImage: contentIcon(kind))
                                            .renderingMode(.template)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 12, height: 12)
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
                if let err = exportError {
                    Text(err)
                        .font(.system(size: 11)).foregroundColor(.red.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()

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
        return "BlackCat_\(f.string(from: Date()))"
    }

    private func contentIcon(_ c: ExportContent) -> NSImage {
        switch c {
        case .video:        return SidebarSVGIcon.load("video")
        case .audioOnly:    return SidebarSVGIcon.load("audio")
        case .subtitleOnly: return SidebarSVGIcon.load("subtitle")
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
        let outputDir = effectiveOutputPath
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

        let orderedSubs = project.orderedSubtitleIndices.map { project.subtitleTracks[$0] }
        let snapshot = ExportInput(
            videoTracks: project.videoTracks,
            audioTracks: project.audioTracks,
            subtitleTracks: orderedSubs,
            imageTracks: project.imageTracks,
            textTracks: project.textTracks,
            shapeTracks: project.shapeTracks,
            compoundTracks: project.compoundTracks,
            overlayTrackOrder: project.overlayTrackOrder,
            subtitleBottomMargin: project.subtitleBottomMargin,
            subtitleLineSpacing: project.subtitleLineSpacing,
            previewRenderSize: project.previewRenderSize,
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
    let textTracks:     [Track<TextClip>]
    let shapeTracks:    [Track<ShapeClip>]
    let compoundTracks: [Track<CompoundClip>]
    let overlayTrackOrder: [ProjectState.OverlayTrackRef]
    let subtitleBottomMargin: Double
    let subtitleLineSpacing:  Double
    let previewRenderSize: CGSize          // 预览分辨率，用于字幕缩放基准
    let settings:       ExportSettings
    let outputURL:      URL
}

private final class CancelFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

actor TimelineExporter {

    private let _cancelFlag = CancelFlag()
    nonisolated var isCancelled: Bool { _cancelFlag.value }
    func cancel() { _cancelFlag.set() }

    // ── ffmpeg 变速音频预处理（与 ProjectState.generateSpeedAudio 逻辑相同，独立缓存）──
    private var speedAudioCache: [String: URL] = [:]

    private func generateSpeedAudio(inputURL: URL, trimStart: Double, srcDurSec: Double,
                                    speed: Double, audioTrackIndex: Int) async -> URL? {
        let key = "\(inputURL.path)|\(trimStart)|\(srcDurSec)|\(speed)|\(audioTrackIndex)"
        if let cached = speedAudioCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let ffmpeg = ProjectState.findFFmpeg() else { return nil }
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc_exp_\(UUID().uuidString).m4a")
        let filterStr = ProjectState.buildAtempoFilter(speed: speed)
        var args = ["-y"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", srcDurSec), "-i", inputURL.path]
        args += ["-vn"]
        if audioTrackIndex > 0 { args += ["-map", "0:a:\(audioTrackIndex)"] }
        args += ["-af", filterStr, "-c:a", "aac", "-ar", "44100", "-ac", "2", tmpURL.path]
        let ok = await Task.detached(priority: .userInitiated) {
            ProjectState.runFFmpegSync(ffmpeg: ffmpeg, arguments: args)
        }.value
        if ok {
            speedAudioCache[key] = tmpURL
            return tmpURL
        }
        return nil
    }

    // ── ffmpeg 倒放视频预处理 ──
    private var reversedVideoCache: [String: URL] = [:]

    private func generateReversedVideo(inputURL: URL, trimStart: Double, srcDurSec: Double) async -> URL? {
        let key = "\(inputURL.path)|\(trimStart)|\(srcDurSec)"
        if let cached = reversedVideoCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let ffmpeg = ProjectState.findFFmpeg() else { return nil }
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc_rev_\(UUID().uuidString).mp4")
        let ss = max(0, trimStart)
        var args = ["-y"]
        if ss > 0.001 { args += ["-ss", String(format: "%.6f", ss)] }
        args += ["-t", String(format: "%.6f", srcDurSec), "-i", inputURL.path]
        args += ["-vf", "reverse", "-af", "areverse"]
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "18"]
        args += ["-c:a", "aac", "-ar", "44100", "-ac", "2"]
        args += [tmpURL.path]
        var ok = await Task.detached(priority: .userInitiated) {
            ProjectState.runFFmpegSync(ffmpeg: ffmpeg, arguments: args)
        }.value
        if !ok {
            let argsNoAudio = ["-y"] +
                (ss > 0.001 ? ["-ss", String(format: "%.6f", ss)] : []) +
                ["-t", String(format: "%.6f", srcDurSec), "-i", inputURL.path,
                 "-vf", "reverse", "-an",
                 "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18",
                 tmpURL.path]
            ok = await Task.detached(priority: .userInitiated) {
                ProjectState.runFFmpegSync(ffmpeg: ffmpeg, arguments: argsNoAudio)
            }.value
        }
        if ok {
            reversedVideoCache[key] = tmpURL
            return tmpURL
        }
        return nil
    }

    func export(_ input: ExportInput,
                progress: @escaping (Double) -> Void) async throws -> URL {
        let settings = input.settings

        // ── 仅字幕模式：导出 SRT 文件 ──
        if settings.content == .subtitleOnly {
            return try exportSRT(input: input, progress: progress)
        }

        // 计算所有轨道的最大结束时间（包括字幕）
        let vEnd = input.videoTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let iEnd = input.imageTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let aEnd = input.audioTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let sEnd = input.subtitleTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let tEnd = input.textTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let shEnd = input.shapeTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let cEnd = input.compoundTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let globalEndTime = max(vEnd, max(iEnd, max(aEnd, max(sEnd, max(tEnd, max(shEnd, cEnd))))))

        let composition = AVMutableComposition()
        var audioMixParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float, startTime: Double, duration: Double, fadeIn: Double, fadeOut: Double)] = []
        var sourceVideoSize: CGSize = CGSize(width: 1920, height: 1080)
        var sourceFrameDuration: CMTime = CMTime(value: 1, timescale: 30)
        let includeVideo = settings.content == .video
        let includeAudio = true  // video 和 audioOnly 都需要音频

        var videoCompTracks: [(track: AVMutableCompositionTrack, clip: VideoClip, startTime: Double, endTime: Double)] = []

        // ── 视频轨道 — 第一遍：预加载 assetDur，计算平均分配 half ──
        struct ExportTransAdj { let clipAID: UUID; let clipBID: UUID; let half: Double; let type: TransitionType }
        var exportTransAdjusts: [ExportTransAdj] = []
        var exportClipAssetDurSec: [UUID: Double] = [:]
        var firstVideoClipID: UUID? = nil
        for track in input.videoTracks {
            let sortedClips = track.clips.sorted { $0.startTime < $1.startTime }
            for clip in sortedClips {
                guard let url = clip.url else { continue }
                let dur = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
                exportClipAssetDurSec[clip.id] = dur
                if firstVideoClipID == nil && track.isVisible { firstVideoClipID = clip.id }
            }
            guard sortedClips.count >= 2 else { continue }
            for i in 1..<sortedClips.count {
                let cA = sortedClips[i-1], cB = sortedClips[i]
                guard let trans = cB.inTransition, abs(cA.endTime - cB.startTime) < 0.05 else { continue }
                let wantedHalf = trans.duration / 2
                let half: Double
                if trans.type == .fadeToBlack {
                    half = wantedHalf
                } else {
                    let availA = max(0, (exportClipAssetDurSec[cA.id] ?? 0) - (cA.trimStart + cA.duration * cA.speed))
                    let availB = cB.trimStart
                    half = max(0, min(wantedHalf, min(availA, availB)))
                }
                if half > 0.005 {
                    exportTransAdjusts.append(ExportTransAdj(clipAID: cA.id, clipBID: cB.id, half: half, type: trans.type))
                }
            }
        }

        // ── 视频轨道 — 第二遍：按 transAdjusts 插入（A 延伸 + B 提前）──
        for track in input.videoTracks {
            let sortedClips = track.clips.sorted(by: { $0.startTime < $1.startTime })
            for (clipIdx, clip) in sortedClips.enumerated() {
                guard let url = clip.url else { continue }
                let asset = AVURLAsset(url: url)
                let assetDurSec = exportClipAssetDurSec[clip.id] ?? 0
                let assetDur = CMTime(seconds: assetDurSec, preferredTimescale: 600)
                let trimSt = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                let maxSrcDur = assetDur - trimSt
                let speed = max(0.01, clip.speed)
                let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / speed, preferredTimescale: 600)
                let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxTimelineDur)
                guard useDur.seconds > 0.01 else { continue }
                let srcContentDurSec = useDur.seconds * speed  // 源素材实际消耗量（秒）

                let aExtend  = exportTransAdjusts.first(where: { $0.clipAID == clip.id && $0.type != .fadeToBlack })?.half ?? 0
                let bAdvance = exportTransAdjusts.first(where: { $0.clipBID == clip.id && $0.type != .fadeToBlack })?.half ?? 0

                let actualTrimSt  = CMTime(seconds: clip.trimStart - bAdvance, preferredTimescale: 600)
                let actualSrcDur  = CMTime(seconds: srcContentDurSec + bAdvance + aExtend, preferredTimescale: 600)
                let actualRange   = CMTimeRange(start: actualTrimSt, duration: actualSrcDur)
                let at            = CMTime(seconds: clip.startTime - bAdvance, preferredTimescale: 600)
                let targetDurSec  = useDur.seconds + bAdvance + aExtend
                // 倒放：预生成反转视频
                var exEffAsset: AVURLAsset = asset
                var exEffTrimSt = actualTrimSt
                var exEffSrcDur = actualSrcDur
                var exEffAudioURL = url
                var exEffAudioTrim: Double = clip.trimStart
                if clip.reversed {
                    let revStart = max(0, actualTrimSt.seconds)
                    if let revURL = await self.generateReversedVideo(
                        inputURL: url, trimStart: revStart, srcDurSec: actualSrcDur.seconds) {
                        exEffAsset = AVURLAsset(url: revURL)
                        exEffTrimSt = .zero
                        exEffSrcDur = (try? await exEffAsset.load(.duration)) ?? actualSrcDur
                        exEffAudioURL = revURL
                        exEffAudioTrim = 0
                    }
                }
                if includeVideo && track.isVisible,
                   let vAsset = try? await exEffAsset.loadTracks(withMediaType: .video).first {
                    let vt = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
                    try vt?.insertTimeRange(CMTimeRange(start: exEffTrimSt, duration: exEffSrcDur),
                                            of: vAsset, at: at)
                    if let vt {
                        if abs(speed - 1.0) > 0.001 {
                            let compRange = CMTimeRange(start: at, duration: exEffSrcDur)
                            vt.scaleTimeRange(compRange, toDuration: CMTime(seconds: targetDurSec, preferredTimescale: 600))
                        }
                        videoCompTracks.append((track: vt, clip: clip,
                                                startTime: clip.startTime - bAdvance,
                                                endTime: clip.endTime + aExtend))
                    }
                    if clip.id == firstVideoClipID {
                        sourceVideoSize = try await vAsset.load(.naturalSize)
                        let mfd = try await vAsset.load(.minFrameDuration)
                        if mfd.isValid && mfd.seconds > 0 { sourceFrameDuration = mfd }
                    }
                }
                if includeAudio && !track.isMuted {
                    let aAt = CMTime(seconds: clip.startTime, preferredTimescale: 44100)
                    if abs(speed - 1.0) > 0.001 {
                        if let speedURL = await self.generateSpeedAudio(
                               inputURL: exEffAudioURL, trimStart: exEffAudioTrim,
                               srcDurSec: srcContentDurSec, speed: speed,
                               audioTrackIndex: clip.reversed ? 0 : clip.audioTrackIndex),
                           let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) {
                            let sAsset = AVURLAsset(url: speedURL)
                            if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                let ins  = CMTimeMinimum(sDur, CMTime(seconds: useDur.seconds, preferredTimescale: 44100))
                                try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: aAt)
                                audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, ins.seconds, 0, 0))
                            }
                        }
                    } else if clip.reversed {
                        let revAudioTracks = (try? await exEffAsset.loadTracks(withMediaType: .audio)) ?? []
                        if let aTrack = revAudioTracks.first,
                           let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) {
                            let revDur = (try? await exEffAsset.load(.duration)) ?? .zero
                            let useDurC = CMTimeMinimum(revDur, CMTime(seconds: useDur.seconds, preferredTimescale: 44100))
                            try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: useDurC), of: aTrack, at: aAt)
                            audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, useDurC.seconds, 0, 0))
                        }
                    } else {
                        let allAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                        let aIdx = min(clip.audioTrackIndex, max(allAudioTracks.count - 1, 0))
                        if let aAsset = allAudioTracks.isEmpty ? nil : allAudioTracks[aIdx],
                           let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) {
                            let ats: CMTimeScale = 44100
                            let aStart  = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                            let aSrcDur = CMTime(seconds: srcContentDurSec, preferredTimescale: ats)
                            try? at2.insertTimeRange(CMTimeRange(start: aStart, duration: aSrcDur), of: aAsset, at: aAt)
                            audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, useDur.seconds, 0, 0))
                        }
                    }
                }
            }
        }

        // ── 复合片段视频子轨道 ──
        for compTrack in input.compoundTracks {
            guard compTrack.isVisible else { continue }
            for rawCompound in compTrack.clips {
                let compound = rawCompound.flattened()
                let cIntStart = compound.internalStart
                let cIntEnd   = compound.internalStart + compound.duration
                for subTrack in compound.videoTracks {
                    let sortedClips = subTrack.clips.sorted { $0.startTime < $1.startTime }
                    for clip in sortedClips {
                        guard let url = clip.url else { continue }
                        let visStart = max(clip.startTime, cIntStart)
                        let visEnd   = min(clip.endTime,   cIntEnd)
                        guard visEnd - visStart > 0.01 else { continue }
                        let visDur   = visEnd - visStart
                        let mainAt   = compound.startTime + (visStart - cIntStart)
                        let speed    = max(0.01, clip.speed)
                        let adjTrim  = clip.trimStart + (visStart - clip.startTime) * speed
                        let srcDur   = visDur * speed

                        let asset = AVURLAsset(url: url)
                        let assetDurSec = (try? await asset.load(.duration))?.seconds ?? 0
                        let trimCM  = CMTime(seconds: adjTrim, preferredTimescale: 600)
                        let maxSrc  = CMTime(seconds: assetDurSec, preferredTimescale: 600) - trimCM
                        let srcCM   = CMTimeMinimum(CMTime(seconds: srcDur, preferredTimescale: 600), maxSrc)
                        guard srcCM.seconds > 0.01 else { continue }

                        var exAsset: AVURLAsset = asset
                        var exTrim  = trimCM
                        var exSrc   = srcCM
                        var exAudioURL  = url
                        var exAudioTrim = adjTrim
                        if clip.reversed {
                            if let revURL = await self.generateReversedVideo(
                                inputURL: url, trimStart: max(0, trimCM.seconds), srcDurSec: srcCM.seconds) {
                                exAsset = AVURLAsset(url: revURL)
                                exTrim  = .zero
                                exSrc   = (try? await exAsset.load(.duration)) ?? srcCM
                                exAudioURL  = revURL
                                exAudioTrim = 0
                            }
                        }

                        let atCM = CMTime(seconds: mainAt, preferredTimescale: 600)
                        if includeVideo && subTrack.isVisible,
                           let vTrack = try? await exAsset.loadTracks(withMediaType: .video).first {
                            let vt = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid)
                            try vt?.insertTimeRange(CMTimeRange(start: exTrim, duration: exSrc), of: vTrack, at: atCM)
                            if let vt {
                                if abs(speed - 1.0) > 0.001 {
                                    vt.scaleTimeRange(CMTimeRange(start: atCM, duration: exSrc),
                                                       toDuration: CMTime(seconds: visDur, preferredTimescale: 600))
                                }
                                videoCompTracks.append((track: vt, clip: clip, startTime: mainAt, endTime: mainAt + visDur))
                            }
                            if firstVideoClipID == nil {
                                firstVideoClipID = clip.id
                                sourceVideoSize = try await vTrack.load(.naturalSize)
                                let mfd = try await vTrack.load(.minFrameDuration)
                                if mfd.isValid && mfd.seconds > 0 { sourceFrameDuration = mfd }
                            }
                        }
                        if includeAudio && !compTrack.isMuted && !subTrack.isMuted {
                            let aAt = CMTime(seconds: mainAt, preferredTimescale: 44100)
                            if abs(speed - 1.0) > 0.001 {
                                if let speedURL = await self.generateSpeedAudio(
                                       inputURL: exAudioURL, trimStart: exAudioTrim,
                                       srcDurSec: srcDur, speed: speed,
                                       audioTrackIndex: clip.reversed ? 0 : clip.audioTrackIndex),
                                   let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
                                    let sAsset = AVURLAsset(url: speedURL)
                                    if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                        let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                        let ins  = CMTimeMinimum(sDur, CMTime(seconds: visDur, preferredTimescale: 44100))
                                        try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: aAt)
                                        audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, mainAt, ins.seconds, 0, 0))
                                    }
                                }
                            } else if clip.reversed {
                                if let aTrack = (try? await exAsset.loadTracks(withMediaType: .audio))?.first,
                                   let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
                                    let revDur = (try? await exAsset.load(.duration)) ?? .zero
                                    let useDurC = CMTimeMinimum(revDur, CMTime(seconds: visDur, preferredTimescale: 44100))
                                    try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: useDurC), of: aTrack, at: aAt)
                                    audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, mainAt, useDurC.seconds, 0, 0))
                                }
                            } else {
                                let allAudio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                                let aIdx = min(clip.audioTrackIndex, max(allAudio.count - 1, 0))
                                if let aTrack = allAudio.isEmpty ? nil : allAudio[aIdx],
                                   let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
                                    let ats: CMTimeScale = 44100
                                    let aStart  = CMTime(seconds: adjTrim, preferredTimescale: ats)
                                    let aSrcDur = CMTime(seconds: srcDur, preferredTimescale: ats)
                                    try? at2.insertTimeRange(CMTimeRange(start: aStart, duration: aSrcDur), of: aTrack, at: aAt)
                                    audioMixParams.append((at2.trackID, clip.volume, 1.0, 1.0, mainAt, visDur, 0, 0))
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── 收集转场信息 ──
        var transitionInfos: [TransitionCompInfo] = []
        if includeVideo {
            for adj in exportTransAdjusts {
                guard let entryA = videoCompTracks.first(where: { $0.clip.id == adj.clipAID }),
                      let entryB = videoCompTracks.first(where: { $0.clip.id == adj.clipBID }) else { continue }
                let ts: CMTimeScale = 600
                let cutT         = CMTime(seconds: entryB.clip.startTime, preferredTimescale: ts)
                let overlapStart = CMTime(seconds: entryB.clip.startTime - adj.half, preferredTimescale: ts)
                let overlapEnd   = CMTime(seconds: entryB.clip.startTime + adj.half, preferredTimescale: ts)
                let natSizeA = (try? await entryA.track.load(.naturalSize)) ?? .zero
                let natSizeB = (try? await entryB.track.load(.naturalSize)) ?? .zero
                transitionInfos.append(TransitionCompInfo(
                    trackA: entryA.track, trackB: entryB.track,
                    clipA: entryA.clip, clipB: entryB.clip, type: adj.type,
                    overlapStart: overlapStart, overlapEnd: overlapEnd, cutT: cutT,
                    half: adj.half, renderSize: .zero,
                    natSizeA: natSizeA, natSizeB: natSizeB
                ))
            }
        }

        // ── 音频轨道 ──
        for track in input.audioTracks {
            guard track.isVisible && !track.isMuted else { continue }
            for clip in track.clips {
                guard let url = clip.url else { continue }
                let asset = AVURLAsset(url: url)
                let assetDur = try await asset.load(.duration)
                let aspeed   = max(0.01, clip.speed)
                let ats: CMTimeScale = 44100
                let trimSt   = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                let maxSrcDur = assetDur - trimSt
                let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / aspeed, preferredTimescale: ats)
                let useDur   = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: ats), maxTimelineDur)
                guard useDur.seconds > 0.01 else { continue }
                let srcDurSec = useDur.seconds * aspeed
                let at        = CMTime(seconds: clip.startTime, preferredTimescale: ats)

                var addedTrackID: CMPersistentTrackID? = nil

                if abs(aspeed - 1.0) > 0.001 {
                    // 变速：ffmpeg atempo 预处理
                    if let speedURL = await self.generateSpeedAudio(
                        inputURL: url, trimStart: clip.trimStart,
                        srcDurSec: srcDurSec, speed: aspeed, audioTrackIndex: 0),
                       let extra = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
                        let sAsset = AVURLAsset(url: speedURL)
                        if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                            let sDur = (try? await sAsset.load(.duration)) ?? .zero
                            let ins  = CMTimeMinimum(sDur, CMTime(seconds: useDur.seconds, preferredTimescale: ats))
                            try? extra.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: at)
                            addedTrackID = extra.trackID
                        }
                    }
                } else {
                    // 正常速度：直接插入
                    guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                    if let extra = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                        let srcDur = CMTime(seconds: srcDurSec, preferredTimescale: ats)
                        try? extra.insertTimeRange(CMTimeRange(start: trimSt, duration: srcDur), of: aAsset, at: at)
                        addedTrackID = extra.trackID
                    }
                }

                if let tid = addedTrackID {
                    let effDur  = useDur.seconds
                    let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  effDur) : 0
                    let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, effDur - fadeIn)) : 0
                    audioMixParams.append((tid, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, effDur, fadeIn, fadeOut))
                }
            }
        }

        // ── 复合片段音频子轨道 ──
        for compTrack in input.compoundTracks {
            guard compTrack.isVisible && !compTrack.isMuted else { continue }
            for rawCompound in compTrack.clips {
                let compound = rawCompound.flattened()
                let cIntStart = compound.internalStart
                let cIntEnd   = compound.internalStart + compound.duration
                for subTrack in compound.audioTracks {
                    guard subTrack.isVisible && !subTrack.isMuted else { continue }
                    for clip in subTrack.clips {
                        guard let url = clip.url else { continue }
                        let visStart = max(clip.startTime, cIntStart)
                        let visEnd   = min(clip.endTime,   cIntEnd)
                        guard visEnd - visStart > 0.01 else { continue }
                        let visDur   = visEnd - visStart
                        let mainAt   = compound.startTime + (visStart - cIntStart)
                        let aspeed   = max(0.01, clip.speed)
                        let adjTrim  = clip.trimStart + (visStart - clip.startTime) * aspeed
                        let srcDurSec = visDur * aspeed

                        let asset = AVURLAsset(url: url)
                        let ats: CMTimeScale = 44100
                        let at = CMTime(seconds: mainAt, preferredTimescale: ats)
                        var addedTrackID: CMPersistentTrackID? = nil

                        if abs(aspeed - 1.0) > 0.001 {
                            if let speedURL = await self.generateSpeedAudio(
                                inputURL: url, trimStart: adjTrim,
                                srcDurSec: srcDurSec, speed: aspeed, audioTrackIndex: 0),
                               let extra = composition.addMutableTrack(withMediaType: .audio,
                                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let sAsset = AVURLAsset(url: speedURL)
                                if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                    let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                    let ins  = CMTimeMinimum(sDur, CMTime(seconds: visDur, preferredTimescale: ats))
                                    try? extra.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: at)
                                    addedTrackID = extra.trackID
                                }
                            }
                        } else {
                            guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                            if let extra = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let trimSt  = CMTime(seconds: adjTrim, preferredTimescale: ats)
                                let srcDur  = CMTime(seconds: srcDurSec, preferredTimescale: ats)
                                try? extra.insertTimeRange(CMTimeRange(start: trimSt, duration: srcDur), of: aAsset, at: at)
                                addedTrackID = extra.trackID
                            }
                        }

                        if let tid = addedTrackID {
                            let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  visDur) : 0
                            let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, visDur - fadeIn)) : 0
                            audioMixParams.append((tid, clip.volume, clip.leftChannel, clip.rightChannel, mainAt, visDur, fadeIn, fadeOut))
                        }
                    }
                }
            }
        }

        // 图片不再通过 AVCompositionTrack 合成，改为逐帧 CIImage overlay（与预览 OverlayStack 一致）

        // 如果字幕/图片/文字/图形超出音视频长度，扩展 composition 到 globalEndTime
        // 用循环复制源视频首帧来填充（videoComposition 会遮黑，内容不可见，但需要真实帧才能延长导出时长）
        let globalEndCM = CMTime(seconds: globalEndTime, preferredTimescale: 600)
        if globalEndCM > composition.duration {
            let firstVideoURL = input.videoTracks.flatMap(\.clips).compactMap(\.url).first
            if let vt = composition.tracks(withMediaType: .video).first as? AVMutableCompositionTrack,
               let url = firstVideoURL {
                let fillAsset = AVURLAsset(url: url)
                if let srcTrack = try? await fillAsset.loadTracks(withMediaType: .video).first {
                    let oneFrame = CMTime(value: 1, timescale: 30)
                    var pos = composition.duration
                    while pos < globalEndCM {
                        let remaining = globalEndCM - pos
                        let dur = CMTimeMinimum(oneFrame, remaining)
                        try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: srcTrack, at: pos)
                        pos = pos + dur
                    }
                }
            } else if let vt = composition.tracks(withMediaType: .video).first as? AVMutableCompositionTrack {
                vt.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: globalEndCM - composition.duration))
            } else {
                let empty = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                empty?.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: globalEndCM))
            }
        }

        // ── AudioMix（音量 + 淡入淡出 + 声道）──
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParams.map { param in
            let p = AVMutableAudioMixInputParameters(track: composition.track(withTrackID: param.trackID))
            p.trackID = param.trackID
            let ts: CMTimeScale = 600
            let clipStart = CMTime(seconds: param.startTime, preferredTimescale: ts)
            if param.fadeIn > 0 || param.fadeOut > 0 {
                // volume ramp 必须按时间递增顺序添加：淡入 → 中间 → 淡出，否则 AVFoundation 抛异常崩溃
                if param.fadeIn > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: param.volume,
                                    timeRange: CMTimeRange(start: clipStart,
                                                           duration: CMTime(seconds: param.fadeIn, preferredTimescale: ts)))
                }
                let midStartSec = param.startTime + param.fadeIn
                let midDurSec   = param.duration - param.fadeIn - param.fadeOut
                if midDurSec > 0.001 {
                    p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: param.volume,
                                    timeRange: CMTimeRange(start: CMTime(seconds: midStartSec, preferredTimescale: ts),
                                                           duration: CMTime(seconds: midDurSec, preferredTimescale: ts)))
                }
                if param.fadeOut > 0 {
                    let fadeOutStart = CMTime(seconds: param.startTime + param.duration - param.fadeOut, preferredTimescale: ts)
                    p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: fadeOutStart,
                                                           duration: CMTime(seconds: param.fadeOut, preferredTimescale: ts)))
                }
            } else {
                p.setVolume(param.volume, at: .zero)
            }
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
            // renderSize 确定后，更新 transitionInfos 里的占位 renderSize
            transitionInfos = transitionInfos.map {
                TransitionCompInfo(trackA: $0.trackA, trackB: $0.trackB,
                                   clipA: $0.clipA, clipB: $0.clipB, type: $0.type,
                                   overlapStart: $0.overlapStart, overlapEnd: $0.overlapEnd, cutT: $0.cutT,
                                   half: $0.half, renderSize: renderSize,
                                   natSizeA: $0.natSizeA, natSizeB: $0.natSizeB)
            }
            // 应用导出设置的帧率
            let fps = settings.fps
            let frameDuration = CMTime(value: 1, timescale: Int32(fps))

            let visibleSubs = input.subtitleTracks.enumerated().compactMap {
                $0.element.isVisible && !$0.element.clips.isEmpty
                    ? (idx: $0.offset, track: $0.element) : nil
            }

            let hasVideoClipTransforms = !videoCompTracks.isEmpty

            // 视频合成 / 分辨率帧率变更（图片不再参与 AVVideoComposition，改由 CIImage overlay）
            if hasVideoClipTransforms {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = frameDuration
                vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

                let ts: CMTimeScale = 600
                let videoClipCMRanges = videoCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                var cmBoundaries: [CMTime] = [.zero, composition.duration]
                for r in videoClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                for ti in transitionInfos {
                    cmBoundaries.append(ti.overlapStart)
                    cmBoundaries.append(ti.overlapEnd)
                    if ti.type == .fadeToBlack { cmBoundaries.append(ti.cutT) }
                }
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
                    for (idx, entry) in videoCompTracks.enumerated() {
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                        let clipStart = videoClipCMRanges[idx].start
                        let clipEnd   = videoClipCMRanges[idx].end
                        let active = segStartCM >= clipStart && segStartCM < clipEnd
                        if active {
                            let natSize = (try? await entry.track.load(.naturalSize)) ?? .zero
                            if natSize.width > 0, natSize.height > 0 {
                                let t = ProjectState.videoTransform(clip: entry.clip, natSize: natSize, renderSize: renderSize)
                                li.setTransform(t, at: .zero)
                                let c = entry.clip
                                if c.cropTop > 0.001 || c.cropBottom > 0.001 || c.cropLeft > 0.001 || c.cropRight > 0.001 {
                                    li.setCropRectangle(ProjectState.videoCropRect(clip: c, natSize: natSize), at: .zero)
                                }
                                ProjectState.applyTransitionRamp(
                                    li: li, track: entry.track, clip: entry.clip,
                                    transform: t, natSize: natSize, renderSize: renderSize,
                                    segStart: segStartCM, transitions: transitionInfos
                                )
                            }
                        } else {
                            li.setOpacity(0, at: .zero)
                        }
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
                    vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                    let visualEnd = vEnd
                    let visualEndCM = CMTime(seconds: visualEnd, preferredTimescale: 600)

                    let instr = AVMutableVideoCompositionInstruction()
                    instr.backgroundColor = CGColor(gray: 0, alpha: 1)
                    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVTrack)
                    let scaleX = renderSize.width / sourceVideoSize.width
                    let scaleY = renderSize.height / sourceVideoSize.height
                    li.setTransform(CGAffineTransform(scaleX: scaleX, y: scaleY), at: .zero)
                    instr.layerInstructions = [li]

                    if visualEnd < globalEndTime - 0.01 {
                        instr.timeRange = CMTimeRange(start: .zero, duration: visualEndCM)
                        let blackInstr = AVMutableVideoCompositionInstruction()
                        blackInstr.timeRange = CMTimeRange(start: visualEndCM, duration: composition.duration - visualEndCM)
                        blackInstr.backgroundColor = CGColor(gray: 0, alpha: 1)
                        let blackLi = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVTrack)
                        blackLi.setOpacity(0, at: .zero)
                        blackInstr.layerInstructions = [blackLi]
                        vc.instructions = [instr, blackInstr]
                    } else {
                        instr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                        vc.instructions = [instr]
                    }
                    videoComposition = vc
                }
            }

            // 如果还没有 videoComposition，创建一个基础的（确保帧率/分辨率可控）
            let visualEnd = vEnd
            if videoComposition == nil {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = frameDuration
                vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                let visualEndCM = CMTime(seconds: visualEnd, preferredTimescale: 600)

                var instrs: [AVMutableVideoCompositionInstruction] = []
                let mainInstr = AVMutableVideoCompositionInstruction()
                mainInstr.backgroundColor = CGColor(gray: 0, alpha: 1)
                mainInstr.layerInstructions = composition.tracks(withMediaType: .video).map { vt in
                    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                    let scaleX = renderSize.width / sourceVideoSize.width
                    let scaleY = renderSize.height / sourceVideoSize.height
                    if abs(scaleX - 1.0) > 0.001 || abs(scaleY - 1.0) > 0.001 {
                        li.setTransform(CGAffineTransform(scaleX: scaleX, y: scaleY), at: .zero)
                    }
                    return li
                }
                if visualEnd < globalEndTime - 0.01 {
                    mainInstr.timeRange = CMTimeRange(start: .zero, duration: visualEndCM)
                    instrs.append(mainInstr)
                    let blackInstr = AVMutableVideoCompositionInstruction()
                    blackInstr.timeRange = CMTimeRange(start: visualEndCM, duration: composition.duration - visualEndCM)
                    blackInstr.backgroundColor = CGColor(gray: 0, alpha: 1)
                    blackInstr.layerInstructions = composition.tracks(withMediaType: .video).map { vt in
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                        li.setOpacity(0, at: .zero)
                        return li
                    }
                    instrs.append(blackInstr)
                } else {
                    mainInstr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                    instrs.append(mainInstr)
                }
                vc.instructions = instrs
                videoComposition = vc
            }

            // 收集字幕渲染数据（用于逐帧绘制）
            let fontScale = input.previewRenderSize.width > 0
                ? renderSize.width / input.previewRenderSize.width : 1.0
            let subRenderInfo = SubtitleRenderInfo(
                tracks: input.subtitleTracks.compactMap { t in
                    guard t.isVisible && !t.clips.isEmpty else { return nil }
                    return (t, t.subtitleStyle ?? SubtitleStyle())
                },
                fontScale: fontScale,
                bottomMargin: input.subtitleBottomMargin,
                lineSpacing: CGFloat(input.subtitleLineSpacing) * fontScale,
                renderSize: renderSize
            )

            // ── 色调范围表（仅视频 clip），图片色调在 renderImageOverlay 中处理 ──
            let colorRanges: [(start: Double, end: Double, adj: ColorAdjust)] =
                input.videoTracks.flatMap { track -> [(Double, Double, ColorAdjust)] in
                    guard track.isVisible else { return [] }
                    return track.clips.compactMap { clip in
                        clip.colorAdjust.isIdentity ? nil : (clip.startTime, clip.endTime, clip.colorAdjust)
                    }
                }

            // 收集文字图层数据
            let visibleTextClips = input.textTracks
                .filter { $0.isVisible }
                .flatMap { $0.clips }
            let visibleShapeClips = input.shapeTracks
                .filter { $0.isVisible }
                .flatMap { $0.clips }
            let visibleImageClips = input.imageTracks
                .filter { $0.isVisible }
                .flatMap { $0.clips }

            // ── 快速路径：无 overlay 时用 AVAssetExportSession（5-10x 加速）──
            let needsPerFrameProcessing = subRenderInfo.hasSubtitles || !visibleTextClips.isEmpty || !visibleShapeClips.isEmpty || !visibleImageClips.isEmpty || !colorRanges.isEmpty
            if !needsPerFrameProcessing {
                try? FileManager.default.removeItem(at: input.outputURL)
                try await fastExportSession(
                    composition: composition,
                    videoComposition: videoComposition!,
                    audioMix: audioMix,
                    outputURL: input.outputURL,
                    progress: progress
                )
                progress(1.0)
                return input.outputURL
            }

            // ── 用 AVAssetWriter 导出（逐帧处理：按 overlayTrackOrder 合成）──
            try? FileManager.default.removeItem(at: input.outputURL)
            try await writerExport(
                composition: composition,
                videoComposition: videoComposition!,
                audioMix: audioMix,
                overlayTrackOrder: input.overlayTrackOrder,
                subtitleInfo: subRenderInfo,
                imageTracks: input.imageTracks,
                textTracks: input.textTracks,
                shapeTracks: input.shapeTracks,
                compoundTracks: input.compoundTracks,
                colorRanges: colorRanges,
                fps: fps,
                bitrate: settings.bitrate,
                outputURL: input.outputURL,
                globalEndTime: globalEndTime,
                progress: progress
            )
            progress(1.0)
            return input.outputURL
        }

        // ── 仅音频模式：用 AVAssetExportSession ──
        let presetName = AVAssetExportPresetAppleM4A
        guard let exporter = AVAssetExportSession(asset: composition, presetName: presetName)
        else {
            throw NSError(domain: "Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        exporter.outputURL = input.outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true
        exporter.audioMix = audioMix

        try? FileManager.default.removeItem(at: input.outputURL)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }

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

    // ── 快速导出：AVAssetExportSession（无需逐帧处理时使用）──
    private func fastExportSession(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let exporter = AVAssetExportSession(asset: composition,
                                                   presetName: AVAssetExportPresetHighestQuality)
        else {
            throw NSError(domain: "Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建视频快速导出会话"])
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix

        // 进度轮询 + 取消检测
        let cancelRef = self._cancelFlag
        let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        progressTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        progressTimer.setEventHandler {
            if cancelRef.value {
                exporter.cancelExport()
            } else {
                let p = Double(exporter.progress)
                progress(min(p, 0.99))
            }
        }
        progressTimer.resume()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }

        progressTimer.cancel()

        switch exporter.status {
        case .completed:
            break
        case .cancelled:
            throw NSError(domain: "Export", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "导出已取消"])
        default:
            throw exporter.error ?? NSError(domain: "Export", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "快速导出失败 (\(exporter.status.rawValue))"])
        }
    }

    // ── 导出 SRT 字幕文件（合并多轨） ──
    private func exportSRT(input: ExportInput,
                           progress: @escaping (Double) -> Void) throws -> URL {
        // 收集所有可见轨道的字幕片段
        var allClips: [(start: Double, end: Double, text: String)] = []
        for track in input.subtitleTracks where track.isVisible {
            for clip in track.clips {
                allClips.append((clip.startTime, clip.endTime, clip.text))
            }
        }
        // 按开始时间排序，同一时间点按文本排序保持稳定
        allClips.sort { $0.start != $1.start ? $0.start < $1.start : $0.text < $1.text }

        // 合并时间重叠的字幕（多轨同时显示的字幕合并为一条，用换行分隔）
        var merged: [(start: Double, end: Double, text: String)] = []
        for clip in allClips {
            if let lastIdx = merged.indices.last,
               abs(merged[lastIdx].start - clip.start) < 0.05 &&
               abs(merged[lastIdx].end - clip.end) < 0.05 {
                // 时间几乎相同，合并文本
                merged[lastIdx].text += "\n" + clip.text
            } else {
                merged.append(clip)
            }
        }

        var srt = ""
        for (i, clip) in merged.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(srtTime(clip.start)) --> \(srtTime(clip.end))\n"
            srt += "\(clip.text)\n\n"
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

    // MARK: - AVAssetWriter 导出引擎

    /// 字幕渲染数据
    struct SubtitleRenderInfo {
        let tracks: [(track: Track<SubtitleClip>, style: SubtitleStyle)]
        let fontScale: CGFloat
        let bottomMargin: Double
        let lineSpacing: CGFloat
        let renderSize: CGSize

        var hasSubtitles: Bool { !tracks.isEmpty }
    }

    /// 用 AVAssetReader + AVAssetWriter 导出，精确控制帧率
    private func writerExport(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix,
        overlayTrackOrder: [ProjectState.OverlayTrackRef],
        subtitleInfo: SubtitleRenderInfo,
        imageTracks: [Track<ImageClip>],
        textTracks: [Track<TextClip>],
        shapeTracks: [Track<ShapeClip>],
        compoundTracks: [Track<CompoundClip>],
        colorRanges: [(start: Double, end: Double, adj: ColorAdjust)],
        fps: Int, bitrate: Int,
        outputURL: URL,
        globalEndTime: Double,
        progress: @escaping (Double) -> Void
    ) async throws {
        let renderSize = videoComposition.renderSize
        let totalDuration = max(composition.duration.seconds, globalEndTime)

        // 检测是否有真实视频数据（非 empty time range）
        let hasRealVideoData = composition.tracks(withMediaType: .video).contains { t in
            t.segments.contains { !$0.isEmpty }
        }

        // ── Reader（仅当有真实视频时创建）──
        var reader: AVAssetReader? = nil
        var videoOutput: AVAssetReaderVideoCompositionOutput? = nil
        var audioOutput: AVAssetReaderAudioMixOutput? = nil

        if hasRealVideoData {
            let r = try AVAssetReader(asset: composition)
            let vo = AVAssetReaderVideoCompositionOutput(
                videoTracks: composition.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            vo.videoComposition = videoComposition
            r.add(vo)
            videoOutput = vo

            let audioTracks = composition.tracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
                ao.audioMix = audioMix
                r.add(ao)
                audioOutput = ao
            }
            reader = r
        }

        // ── Writer ──
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate * 1000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any],
            AVVideoEncoderSpecificationKey: [
                "EnableHardwareAcceleratedVideoEncoder": true,
                "RequireHardwareAcceleratedVideoEncoder": false
            ] as [String: Any]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: pbAttrs)
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ] as [String: Any])
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioInput = ai
        }

        // ── 开始读写 ──
        if let reader = reader {
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "Export", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "无法启动读取: \(reader.error?.localizedDescription ?? "unknown")"])
            }
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Export", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法启动写入: \(writer.error?.localizedDescription ?? "unknown")"])
        }
        writer.startSession(atSourceTime: .zero)

        let hasSubtitles = subtitleInfo.hasSubtitles
        let imageClipsByTrack: [UUID: [ImageClip]] = Dictionary(
            uniqueKeysWithValues: imageTracks.filter { $0.isVisible }.map { ($0.id, $0.clips) })
        let textClipsByTrack: [UUID: [TextClip]] = Dictionary(
            uniqueKeysWithValues: textTracks.filter { $0.isVisible }.map { ($0.id, $0.clips) })
        let shapeClipsByTrack: [UUID: [ShapeClip]] = Dictionary(
            uniqueKeysWithValues: shapeTracks.filter { $0.isVisible }.map { ($0.id, $0.clips) })
        let compoundClips = compoundTracks.filter { $0.isVisible }.flatMap(\.clips)
        let hasOverlays = hasSubtitles || !imageClipsByTrack.isEmpty || !textClipsByTrack.isEmpty || !shapeClipsByTrack.isEmpty || !compoundClips.isEmpty
        let videoQueue = DispatchQueue(label: "export.video")
        let audioQueue = DispatchQueue(label: "export.audio")
        let targetFps = fps
        let ciCtx = ExportCIContext.shared

        // 预加载图片 CIImage 缓存
        var imageCICache: [URL: CIImage] = [:]
        for track in imageTracks where track.isVisible {
            for clip in track.clips {
                if let url = clip.imageURL, imageCICache[url] == nil {
                    imageCICache[url] = CIImage(contentsOf: url)
                }
            }
        }

        // 音视频必须并行消费，否则 AVAssetReader 内部缓冲区满会死锁
        await withTaskGroup(of: Void.self) { group in
            // 视频帧处理：按目标帧率重采样 + CIImage GPU 管线
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var frameIndex: Int64 = 0
                    var currentPB: CVPixelBuffer? = nil
                    var currentReaderTime: Double = 0
                    var nextSB: CMSampleBuffer? = videoOutput?.copyNextSampleBuffer()

                    var cachedSubOverlay: CIImage? = nil
                    var cachedSubKey: String = ""

                    let cancelRef = self._cancelFlag
                    videoInput.requestMediaDataWhenReady(on: videoQueue) {
                        while videoInput.isReadyForMoreMediaData {
                            autoreleasepool {
                                if cancelRef.value {
                                    videoInput.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                let targetTime = Double(frameIndex) / Double(targetFps)
                                guard targetTime < totalDuration + 0.1 else {
                                    videoInput.markAsFinished()
                                    cont.resume()
                                    return
                                }

                                while let sb = nextSB {
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                                    if pts <= targetTime {
                                        currentPB = CMSampleBufferGetImageBuffer(sb)
                                        currentReaderTime = pts
                                        nextSB = videoOutput?.copyNextSampleBuffer()
                                    } else {
                                        break
                                    }
                                }

                                if currentPB == nil && nextSB == nil && !hasOverlays {
                                    videoInput.markAsFinished()
                                    cont.resume()
                                    return
                                }

                                let outputPTS = CMTime(value: frameIndex, timescale: Int32(targetFps))
                                let effectivePB: CVPixelBuffer
                                if let pb = currentPB {
                                    effectivePB = pb
                                } else if let pool = adaptor.pixelBufferPool {
                                    var blackBuf: CVPixelBuffer?
                                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &blackBuf)
                                    if let bb = blackBuf {
                                        CVPixelBufferLockBaseAddress(bb, [])
                                        let addr = CVPixelBufferGetBaseAddress(bb)
                                        let size = CVPixelBufferGetDataSize(bb)
                                        memset(addr, 0, size)
                                        CVPixelBufferUnlockBaseAddress(bb, [])
                                        effectivePB = bb
                                    } else {
                                        videoInput.markAsFinished(); cont.resume(); return
                                    }
                                } else {
                                    videoInput.markAsFinished(); cont.resume(); return
                                }
                                if true {
                                    let activeAdj = colorRanges.first {
                                        targetTime >= $0.start && targetTime < $0.end
                                    }?.adj

                                    let needsExtra = hasOverlays || (activeAdj != nil && activeAdj?.isIdentity == false)
                                    if needsExtra {
                                        var image = CIImage(cvPixelBuffer: effectivePB)

                                        if let adj = activeAdj, !adj.isIdentity {
                                            image = ColorAdjust.apply(image, adj)
                                        }

                                        // 按 overlayTrackOrder 从底到顶合成（reversed: 最后元素=最底层，最先合成）
                                        var subtitleRendered = false
                                        for ref in overlayTrackOrder.reversed() {
                                            switch ref {
                                            case .image(let trackID):
                                                if let clips = imageClipsByTrack[trackID],
                                                   let clip = clips.first(where: { $0.startTime <= targetTime && $0.endTime > targetTime }),
                                                   let overlay = self.renderImageOverlay(
                                                       clip: clip, renderSize: renderSize, ciCache: imageCICache) {
                                                    image = overlay.composited(over: image)
                                                }
                                            case .subtitle(_):
                                                if !subtitleRendered && hasSubtitles {
                                                    var subKey = ""
                                                    for (track, _) in subtitleInfo.tracks {
                                                        if let clip = track.clips.first(where: { $0.startTime <= targetTime && $0.endTime > targetTime }) {
                                                            subKey += "\(clip.id)|\(clip.text)|"
                                                        }
                                                    }
                                                    if subKey != cachedSubKey {
                                                        cachedSubOverlay = self.renderSubtitleOverlay(atTime: targetTime, info: subtitleInfo)
                                                        cachedSubKey = subKey
                                                    }
                                                    if let subOverlay = cachedSubOverlay {
                                                        image = subOverlay.composited(over: image)
                                                    }
                                                    subtitleRendered = true
                                                }
                                            case .text(let trackID):
                                                if let clips = textClipsByTrack[trackID],
                                                   let overlay = self.renderTextOverlay(
                                                       atTime: targetTime, clips: clips,
                                                       fontScale: subtitleInfo.fontScale, renderSize: renderSize) {
                                                    image = overlay.composited(over: image)
                                                }
                                            case .shape(let trackID):
                                                if let clips = shapeClipsByTrack[trackID],
                                                   let overlay = self.renderShapeOverlay(
                                                       atTime: targetTime, clips: clips,
                                                       scale: subtitleInfo.fontScale, renderSize: renderSize) {
                                                    image = overlay.composited(over: image)
                                                }
                                            case .compound(let trackID):
                                                if let track = compoundTracks.first(where: { $0.id == trackID && $0.isVisible }),
                                                   let rawCompound = track.clips.first(where: { $0.startTime <= targetTime && $0.endTime > targetTime }) {
                                                    let compound = rawCompound.flattened()
                                                    let it = targetTime - compound.startTime + compound.internalStart
                                                    for imgTrack in compound.imageTracks {
                                                        if let clip = imgTrack.clips.first(where: { $0.startTime <= it && $0.endTime > it }),
                                                           let overlay = self.renderImageOverlay(clip: clip, renderSize: renderSize, ciCache: imageCICache) {
                                                            image = overlay.composited(over: image)
                                                        }
                                                    }
                                                    let cSubTracks = compound.subtitleTracks.map { t in
                                                        (track: t, style: t.subtitleStyle ?? SubtitleStyle())
                                                    }
                                                    if !cSubTracks.isEmpty {
                                                        let cSubInfo = SubtitleRenderInfo(
                                                            tracks: cSubTracks, fontScale: subtitleInfo.fontScale,
                                                            bottomMargin: subtitleInfo.bottomMargin,
                                                            lineSpacing: subtitleInfo.lineSpacing, renderSize: renderSize)
                                                        if let overlay = self.renderSubtitleOverlay(atTime: it, info: cSubInfo) {
                                                            image = overlay.composited(over: image)
                                                        }
                                                    }
                                                    let cTextClips = compound.textTracks.flatMap(\.clips)
                                                    if let overlay = self.renderTextOverlay(atTime: it, clips: cTextClips,
                                                                                            fontScale: subtitleInfo.fontScale, renderSize: renderSize) {
                                                        image = overlay.composited(over: image)
                                                    }
                                                    let cShapeClips = compound.shapeTracks.flatMap(\.clips)
                                                    if let overlay = self.renderShapeOverlay(atTime: it, clips: cShapeClips,
                                                                                             scale: subtitleInfo.fontScale, renderSize: renderSize) {
                                                        image = overlay.composited(over: image)
                                                    }
                                                }
                                            }
                                        }

                                        if let pool = adaptor.pixelBufferPool {
                                            var outBuf: CVPixelBuffer?
                                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                                            if let outBuf = outBuf {
                                                ciCtx.render(image, to: outBuf)
                                                adaptor.append(outBuf, withPresentationTime: outputPTS)
                                            }
                                        }
                                    } else {
                                        adaptor.append(effectivePB, withPresentationTime: outputPTS)
                                    }
                                }
                                frameIndex += 1
                                let pct = min(targetTime / max(totalDuration, 0.01), 0.99)
                                progress(pct)
                            }
                        }
                    }
                }
            }

            // 音频处理（并行）
            if let audioOutput = audioOutput, let audioInput = audioInput {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        audioInput.requestMediaDataWhenReady(on: audioQueue) {
                            while audioInput.isReadyForMoreMediaData {
                                guard let sb = audioOutput.copyNextSampleBuffer() else {
                                    audioInput.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                audioInput.append(sb)
                            }
                        }
                    }
                }
            }
        }

        if _cancelFlag.value {
            writer.cancelWriting()
            throw CancellationError()
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Export", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "写入失败 (\(writer.status.rawValue))"])
        }
    }

    // MARK: - GPU overlay 渲染（CIImage 管线）

    // MARK: - 图片 overlay 渲染（CIImage 管线，与预览 ImageLayerView 一致）

    private nonisolated func renderImageOverlay(
        clip: ImageClip, renderSize: CGSize, ciCache: [URL: CIImage]
    ) -> CIImage? {
        guard let url = clip.imageURL,
              var ciImg = ciCache[url] else { return nil }
        let natW = ciImg.extent.width
        let natH = ciImg.extent.height
        guard natW > 0, natH > 0 else { return nil }
        let rw = renderSize.width
        let rh = renderSize.height

        // 裁剪（归一化比例，先对原始图片裁剪）
        let cropL = CGFloat(clip.cropLeft)
        let cropR = CGFloat(clip.cropRight)
        let cropT = CGFloat(clip.cropTop)
        let cropB = CGFloat(clip.cropBottom)
        if cropL > 0.001 || cropR > 0.001 || cropT > 0.001 || cropB > 0.001 {
            let cx = natW * cropL
            let cy = natH * cropB   // CIImage y-up: cropBottom 从底部裁
            let cw = natW * (1 - cropL - cropR)
            let ch = natH * (1 - cropT - cropB)
            guard cw > 0, ch > 0 else { return nil }
            ciImg = ciImg.cropped(to: CGRect(x: cx, y: cy, width: cw, height: ch))
        }

        let croppedW = ciImg.extent.width
        let croppedH = ciImg.extent.height

        // 缩放：baseScale 使图片 fit 画布，再乘用户 scaleX/scaleY
        let baseScale = min(rw / natW, rh / natH)
        let sx = baseScale * CGFloat(clip.scaleX)
        let sy = baseScale * CGFloat(clip.scaleY)

        // 位移：offsetX/offsetY 是归一化值（-1...1），0 = 居中
        let centerX = rw / 2 + CGFloat(clip.offsetX) * rw
        let centerY = rh / 2 + CGFloat(clip.offsetY) * rh

        // CIImage 变换：先移到原点 → 缩放 → 移到目标中心
        // CIImage 是 y-up 坐标系
        let originX = ciImg.extent.origin.x
        let originY = ciImg.extent.origin.y
        var t = CGAffineTransform(translationX: -originX, y: -originY)   // 归零
        t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let scaledW = croppedW * sx
        let scaledH = croppedH * sy
        // CIImage y-up: centerY 需要翻转（renderSize 的 y 轴是 y-down）
        let destX = centerX - scaledW / 2
        let destY = (rh - centerY) - scaledH / 2
        t = t.concatenating(CGAffineTransform(translationX: destX, y: destY))

        ciImg = ciImg.transformed(by: t)

        // 镜像 / 旋转（以画布中心为锚）
        if clip.mirrorH || clip.mirrorV || clip.rotation != 0 {
            let mcx = rw / 2, mcy = rh / 2
            var mt = CGAffineTransform(translationX: -mcx, y: -mcy)
            if clip.mirrorH { mt = mt.scaledBy(x: -1, y: 1) }
            if clip.mirrorV { mt = mt.scaledBy(x: 1, y: -1) }
            let rad = CGFloat(clip.rotation) * .pi / 180
            if abs(rad) > 0.001 { mt = mt.rotated(by: rad) }
            mt = mt.translatedBy(x: mcx, y: mcy)
            ciImg = ciImg.transformed(by: mt)
        }

        // 色调调节
        let adj = clip.colorAdjust
        if !adj.isIdentity {
            ciImg = ColorAdjust.apply(ciImg, adj)
        }

        // 裁剪到画布范围
        ciImg = ciImg.cropped(to: CGRect(origin: .zero, size: renderSize))

        return ciImg
    }

    private nonisolated func renderSubtitleOverlay(
        atTime time: Double, info: SubtitleRenderInfo
    ) -> CIImage? {
        // 找出当前时间活跃的字幕
        var activeItems: [(text: String, style: SubtitleStyle)] = []
        for (track, style) in info.tracks {
            if let clip = track.clips.first(where: { $0.startTime <= time && $0.endTime > time }) {
                let text = style.mergeLineBreaks ? Self.mergeBreaks(clip.text) : clip.text
                activeItems.append((text, style))
            }
        }
        guard !activeItems.isEmpty else { return nil }

        let w = Int(info.renderSize.width)
        let h = Int(info.renderSize.height)
        guard w > 0, h > 0 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 透明背景（默认就是全 0）
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        // CGContext 默认 y-up → 翻转为 y-down
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let scale = info.fontScale
        let padH: CGFloat = 10 * scale, padV: CGFloat = 3 * scale
        let bottomPad = CGFloat(h) * CGFloat(info.bottomMargin) / 100.0

        struct SubLayout {
            let text: String; let style: SubtitleStyle; let ctFont: CTFont
            let layerW: CGFloat; let layerH: CGFloat
            let setter: CTFramesetter
        }

        var layouts: [SubLayout] = []
        for item in activeItems {
            let scaledSize = item.style.fontSize * scale
            var ctFont = CTFontCreateWithName(item.style.fontName as CFString, scaledSize, nil)
            if item.style.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if item.style.italic {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(item.style.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch item.style.alignment {
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

            let maxW = CGFloat(w) * item.style.widthPercent / 100
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: item.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            let constraint = CGSize(width: maxW - padH * 2, height: CGFloat.greatestFiniteMagnitude)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)
            let layerW = ceil(textSize.width) + padH * 2
            let layerH = ceil(textSize.height) + padV * 2
            layouts.append(SubLayout(text: item.text, style: item.style, ctFont: ctFont,
                                     layerW: layerW, layerH: layerH, setter: setter))
        }

        var yPos = CGFloat(h) - bottomPad
        for layout in layouts.reversed() {
            yPos -= layout.layerH
            let xOrig = (CGFloat(w) - layout.layerW) / 2

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                          blur: 1 * scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))

            if layout.style.backgroundOpacity > 0 {
                let nc = NSColor(layout.style.backgroundColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                         alpha: CGFloat(layout.style.backgroundOpacity)))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yPos, width: layout.layerW, height: layout.layerH),
                                     cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            let textRectYUp = CGFloat(h) - yPos - layout.layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layout.layerW - padH * 2, height: layout.layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(layout.setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            yPos -= info.lineSpacing
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// 渲染文字图层为透明背景 CIImage overlay（用于 CISourceOverCompositing GPU 合成）
    private nonisolated func renderTextOverlay(
        atTime time: Double, clips: [TextClip], fontScale: CGFloat, renderSize: CGSize
    ) -> CIImage? {
        let active = clips.filter { $0.startTime <= time && $0.endTime > time }
        guard !active.isEmpty else { return nil }

        let w = Int(renderSize.width)
        let h = Int(renderSize.height)
        guard w > 0, h > 0 else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let scale = fontScale

        for clip in active {
            let scaledSize = clip.fontSize * scale
            var ctFont = CTFontCreateWithName(clip.fontName as CFString, scaledSize, nil)
            if clip.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if clip.italic {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(clip.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch clip.alignment {
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

            let padH: CGFloat = 10 * scale, padV: CGFloat = 5 * scale
            let maxW = CGFloat(w) * 0.9
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: clip.text.isEmpty ? " " : clip.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            let constraint = CGSize(width: maxW - padH * 2, height: CGFloat.greatestFiniteMagnitude)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)
            let layerW = ceil(textSize.width) + padH * 2
            let layerH = ceil(textSize.height) + padV * 2

            let centerX = CGFloat(w) * clip.posX
            let centerY = CGFloat(h) * clip.posY
            let xOrig = centerX - layerW / 2
            let yOrig = centerY - layerH / 2

            ctx.saveGState()
            ctx.setAlpha(clip.opacity)

            if clip.rotation != 0 {
                ctx.translateBy(x: centerX, y: centerY)
                ctx.rotate(by: -clip.rotation * .pi / 180)
                ctx.translateBy(x: -centerX, y: -centerY)
            }

            if clip.strokeWidth > 0 {
                let sc = NSColor(clip.strokeColor).usingColorSpace(.sRGB) ?? .black
                var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
                sc.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
                let strokeCG = CGColor(red: sr, green: sg, blue: sb, alpha: sa)
                let r = max(0.6, clip.strokeWidth * 0.5) * scale
                let off = max(0.6, clip.strokeWidth * 0.4) * scale
                ctx.setShadow(offset: CGSize(width: off, height: off), blur: r, color: strokeCG)
            } else {
                ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                              blur: 1 * scale,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            }

            if clip.bgOpacity > 0 {
                let nc = NSColor(clip.bgColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb, alpha: clip.bgOpacity))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH),
                                     cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            let textRectYUp = CGFloat(h) - yOrig - layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layerW - padH * 2, height: layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            ctx.restoreGState()
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - 图形 overlay 逐帧绘制（导出用，与预览 ShapeOverlay 一致）

    private nonisolated func renderShapeOverlay(atTime time: Double, clips: [ShapeClip],
                                                scale: CGFloat, renderSize: CGSize) -> CIImage? {
        let active = clips.filter { $0.startTime <= time && $0.endTime > time }
        guard !active.isEmpty else { return nil }
        let w = Int(renderSize.width), h = Int(renderSize.height)
        guard w > 0, h > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // 翻转成左上原点，与 posX/posY(0~1) 一致
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        func cgc(_ c: Color, _ op: Double) -> CGColor {
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getRed(&r, green: &g, blue: &b, alpha: &a)
            return CGColor(red: r, green: g, blue: b, alpha: a * CGFloat(op))
        }

        let s = Double(scale)
        for clip in active {
            let cx = clip.posX * Double(w)
            let cy = clip.posY * Double(h)
            let sw = max(clip.width * clip.scaleX * s, 1)
            let sh = max(clip.height * clip.scaleY * s, 1)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(clip.opacity))
            if clip.rotation != 0 || clip.mirrorH || clip.mirrorV {
                ctx.translateBy(x: cx, y: cy)
                if clip.mirrorH { ctx.scaleBy(x: -1, y: 1) }
                if clip.mirrorV { ctx.scaleBy(x: 1, y: -1) }
                if clip.rotation != 0 { ctx.rotate(by: CGFloat(clip.rotation * .pi / 180)) }
                ctx.translateBy(x: -cx, y: -cy)
            }
            if clip.shadowEnabled {
                ctx.setShadow(offset: CGSize(width: clip.shadowOffsetX * s, height: clip.shadowOffsetY * s),
                              blur: CGFloat(clip.shadowRadius * s),
                              color: cgc(clip.shadowColor, clip.shadowOpacity))
            }
            let rect = CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh)
            if clip.type == .pen {
                if let pts = clip.penPoints, pts.count >= 2 {
                    let penPath = ShapeGeometry.penPath(points: pts, closed: clip.penClosed, in: rect).cgPath
                    if clip.fillEnabled && clip.effectiveIsClosed {
                        ctx.addPath(penPath); ctx.setFillColor(cgc(clip.fillColor, clip.fillOpacity)); ctx.fillPath()
                    }
                    if clip.strokeEnabled {
                        ctx.addPath(penPath)
                        ctx.setStrokeColor(cgc(clip.strokeColor, clip.strokeOpacity))
                        ctx.setLineWidth(CGFloat(clip.strokeWidth * s))
                        ctx.setLineCap(.round); ctx.setLineJoin(.round)
                        if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * s, clip.strokeWidth * 1.6 * s]) }
                        ctx.strokePath()
                        ctx.setLineDash(phase: 0, lengths: [])
                    }
                }
            } else if !clip.type.isClosed {
                drawShapeLine(ctx: ctx, clip: clip, rect: rect, scale: s, cgc: cgc)
            } else {
                let path: CGPath
                if clip.cornerRadius > 0, let pts = ShapeGeometry.polygonPoints(for: clip.type, in: rect) {
                    path = ShapeGeometry.roundedPolygon(pts, radius: CGFloat(clip.cornerRadius * s)).cgPath
                } else if clip.type == .rectangle && clip.cornerRadius > 0 {
                    let r = CGFloat(min(clip.cornerRadius * s, Double(min(sw, sh)) / 2))
                    path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                } else {
                    path = ShapeGeometry.path(for: clip.type, in: rect).cgPath
                }
                if clip.fillEnabled {
                    ctx.addPath(path); ctx.setFillColor(cgc(clip.fillColor, clip.fillOpacity)); ctx.fillPath()
                }
                if clip.strokeEnabled {
                    ctx.addPath(path)
                    ctx.setStrokeColor(cgc(clip.strokeColor, clip.strokeOpacity))
                    ctx.setLineWidth(CGFloat(clip.strokeWidth * s))
                    ctx.setLineJoin(.round)
                    if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * s, clip.strokeWidth * 1.6 * s]) }
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            }
            ctx.restoreGState()
        }
        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private nonisolated func drawShapeLine(ctx: CGContext, clip: ShapeClip, rect: CGRect,
                                           scale: Double, cgc: (Color, Double) -> CGColor) {
        let y = rect.midY
        let sw = max(clip.strokeWidth * scale, 1)
        let col = cgc(clip.strokeColor, clip.strokeOpacity)
        let headLen = min(max(rect.width * 0.42, sw * 3), rect.height * 1.6) * 0.5
        let startInset = clip.capStart == .arrow ? headLen : 0
        let endInset = clip.capEnd == .arrow ? headLen : 0
        ctx.setStrokeColor(col); ctx.setLineWidth(sw); ctx.setLineCap(.butt)
        if clip.strokeDashed { ctx.setLineDash(phase: 0, lengths: [clip.strokeWidth * 2.5 * scale, clip.strokeWidth * 1.6 * scale]) }
        ctx.move(to: CGPoint(x: rect.minX + startInset, y: y))
        ctx.addLine(to: CGPoint(x: rect.maxX - endInset, y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawCap(ctx: ctx, cap: clip.capStart, at: CGPoint(x: rect.minX, y: y), dir: -1, headLen: headLen, col: col)
        drawCap(ctx: ctx, cap: clip.capEnd,   at: CGPoint(x: rect.maxX, y: y), dir: 1,  headLen: headLen, col: col)
    }

    private nonisolated func drawCap(ctx: CGContext, cap: LineCapStyle, at pt: CGPoint,
                                     dir: Double, headLen: Double, col: CGColor) {
        switch cap {
        case .none: break
        case .round:
            ctx.setFillColor(col)
            ctx.fillEllipse(in: CGRect(x: pt.x - headLen / 2, y: pt.y - headLen / 2, width: headLen, height: headLen))
        case .square:
            ctx.setFillColor(col)
            ctx.fill(CGRect(x: pt.x - headLen / 2, y: pt.y - headLen / 2, width: headLen, height: headLen))
        case .arrow:
            let wing = headLen * 0.5
            ctx.setFillColor(col)
            ctx.move(to: CGPoint(x: pt.x - dir * headLen, y: pt.y - wing))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x - dir * headLen, y: pt.y + wing))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: - 逐帧字幕绘制（旧版 CPU 方法，保留兼容）

    /// 复制 pixel buffer（32BGRA），用于在副本上绘制字幕，不污染原始帧
    private static nonisolated func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w   = CVPixelBufferGetWidth(src)
        let h   = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        var dst: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, nil, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        if let srcAddr = CVPixelBufferGetBaseAddress(src),
           let dstAddr = CVPixelBufferGetBaseAddress(dst) {
            memcpy(dstAddr, srcAddr, CVPixelBufferGetBytesPerRow(src) * h)
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
        return dst
    }

    /// 在 pixel buffer 上直接绘制字幕（CoreGraphics）
    private nonisolated func drawSubtitlesOnPixelBuffer(
        _ pixelBuffer: CVPixelBuffer, atTime time: Double, info: SubtitleRenderInfo
    ) {
        // 找出当前时间活跃的字幕
        var activeItems: [(text: String, style: SubtitleStyle)] = []
        for (track, style) in info.tracks {
            if let clip = track.clips.first(where: { $0.startTime <= time && $0.endTime > time }) {
                let text = style.mergeLineBreaks ? Self.mergeBreaks(clip.text) : clip.text
                activeItems.append((text, style))
            }
        }
        guard !activeItems.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: baseAddr, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // CGContext 默认 y-up（原点左下），视频像素是 y-down → 翻转
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)
        // 现在 (0,0) = 左上角，y 向下

        let scale = info.fontScale
        let padH: CGFloat = 10 * scale, padV: CGFloat = 3 * scale
        let bottomPad = CGFloat(h) * CGFloat(info.bottomMargin) / 100.0

        // 计算每条字幕的尺寸
        struct SubLayout {
            let text: String; let style: SubtitleStyle; let ctFont: CTFont
            let layerW: CGFloat; let layerH: CGFloat
            let setter: CTFramesetter
        }

        var layouts: [SubLayout] = []
        for item in activeItems {
            let scaledSize = item.style.fontSize * scale
            var ctFont = CTFontCreateWithName(item.style.fontName as CFString, scaledSize, nil)
            if item.style.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if item.style.italic {
                // 矩阵斜切合成斜体（中文字体无 italic face，symbolic traits 会失败）
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(item.style.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch item.style.alignment {
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

            let maxW = CGFloat(w) * item.style.widthPercent / 100
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: item.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            let constraint = CGSize(width: maxW - padH * 2, height: CGFloat.greatestFiniteMagnitude)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)
            let layerW = ceil(textSize.width) + padH * 2
            let layerH = ceil(textSize.height) + padV * 2
            layouts.append(SubLayout(text: item.text, style: item.style, ctFont: ctFont,
                                     layerW: layerW, layerH: layerH, setter: setter))
        }

        // 从底部往上堆叠绘制（y-down 坐标系）
        // reversed() 使最后一条轨道在最底部，与预览 VStack 顺序一致
        var yPos = CGFloat(h) - bottomPad  // 底部起始 y
        for layout in layouts.reversed() {
            yPos -= layout.layerH
            let xOrig = (CGFloat(w) - layout.layerW) / 2

            // 阴影（先画，在背景之前）
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                          blur: 1 * scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))

            // 背景
            if layout.style.backgroundOpacity > 0 {
                let nc = NSColor(layout.style.backgroundColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                         alpha: CGFloat(layout.style.backgroundOpacity)))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yPos, width: layout.layerW, height: layout.layerH),
                                     cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }
            ctx.restoreGState()

            // 文字（CoreText 需要 y-up，翻转后绘制再翻回来）
            ctx.saveGState()
            // 当前是 y-down，CoreText 需要 y-up
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            // 现在是 y-up，原来的 yPos（y-down）需要转换
            let textRectYUp = CGFloat(h) - yPos - layout.layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layout.layerW - padH * 2, height: layout.layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(layout.setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            yPos -= info.lineSpacing
        }
    }

    private nonisolated func drawTextOverlaysOnPixelBuffer(
        _ pixelBuffer: CVPixelBuffer, atTime time: Double,
        clips: [TextClip], fontScale: CGFloat
    ) {
        let active = clips.filter { $0.startTime <= time && $0.endTime > time }
        guard !active.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: baseAddr, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let scale = fontScale

        for clip in active {
            let scaledSize = clip.fontSize * scale
            var ctFont = CTFontCreateWithName(clip.fontName as CFString, scaledSize, nil)
            if clip.bold,
               let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledSize, nil, .boldTrait, .boldTrait) { ctFont = bf }
            if clip.italic {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledSize, &skew, nil)
            }

            let tc = NSColor(clip.textColor).usingColorSpace(.sRGB) ?? .white
            var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

            var alignment: CTTextAlignment
            switch clip.alignment {
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

            let padH: CGFloat = 10 * scale, padV: CGFloat = 5 * scale
            let maxW = CGFloat(w) * 0.9
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): ctFont,
                .init(kCTForegroundColorAttributeName as String): textCGColor,
                .init(kCTParagraphStyleAttributeName as String): ctPS
            ]
            let attrStr = NSAttributedString(string: clip.text.isEmpty ? " " : clip.text, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(attrStr)
            let constraint = CGSize(width: maxW - padH * 2, height: CGFloat.greatestFiniteMagnitude)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraint, nil)
            let layerW = ceil(textSize.width) + padH * 2
            let layerH = ceil(textSize.height) + padV * 2

            let centerX = CGFloat(w) * clip.posX
            let centerY = CGFloat(h) * clip.posY
            let xOrig = centerX - layerW / 2
            let yOrig = centerY - layerH / 2

            ctx.saveGState()
            ctx.setAlpha(clip.opacity)

            if clip.rotation != 0 {
                ctx.translateBy(x: centerX, y: centerY)
                ctx.rotate(by: -clip.rotation * .pi / 180)
                ctx.translateBy(x: -centerX, y: -centerY)
            }

            // 描边阴影
            if clip.strokeWidth > 0 {
                let sc = NSColor(clip.strokeColor).usingColorSpace(.sRGB) ?? .black
                var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
                sc.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
                let strokeCG = CGColor(red: sr, green: sg, blue: sb, alpha: sa)
                let r = max(0.6, clip.strokeWidth * 0.5) * scale
                let off = max(0.6, clip.strokeWidth * 0.4) * scale
                ctx.setShadow(offset: CGSize(width: off, height: off), blur: r, color: strokeCG)
            } else {
                ctx.setShadow(offset: CGSize(width: 1 * scale, height: 1 * scale),
                              blur: 1 * scale,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            }

            // 背景
            if clip.bgOpacity > 0 {
                let nc = NSColor(clip.bgColor).usingColorSpace(.sRGB) ?? .black
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                nc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                ctx.setFillColor(CGColor(red: br, green: bg, blue: bb, alpha: clip.bgOpacity))
                let bgPath = CGPath(roundedRect: CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH),
                                     cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
                ctx.addPath(bgPath)
                ctx.fillPath()
            }

            // 文字
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1.0, y: -1.0)
            let textRectYUp = CGFloat(h) - yOrig - layerH + padV
            let textRect = CGRect(x: xOrig + padH, y: textRectYUp,
                                  width: layerW - padH * 2, height: layerH - padV * 2)
            let ctFrame = CTFramesetterCreateFrame(setter, CFRange(),
                                                    CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(ctFrame, ctx)
            ctx.restoreGState()

            ctx.restoreGState()
        }
    }

    /// 解析分辨率字符串，如 "1080p  1920×1080" → CGSize(1920, 1080)
    /// 合并手动换行：中文之间直接拼接，其他用空格连接
    private static func mergeBreaks(_ text: String) -> String {
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

    private func makeSubtitleTextLayer(
        text: String, style: SubtitleStyle, renderSize: CGSize,
        fontScale: CGFloat = 1.0,
        startTime: Double, endTime: Double,
        totalDuration: Double,
        baseBottomMargin: Double = 5,
        trackOffset: CGFloat = 0
    ) -> CALayer {
        // fontScale = renderSize.width / previewRenderSize.width
        // 确保导出字幕与预览比例一致
        let scaledFontSize = style.fontSize * fontScale
        let maxWidth = renderSize.width * style.widthPercent / 100
        // 与预览 SubtitleLabel 一致: .padding(.horizontal, 10).padding(.vertical, 3)
        let padH: CGFloat = 10 * fontScale, padV: CGFloat = 3 * fontScale

        // 解析颜色
        let tc = NSColor(style.textColor).usingColorSpace(.sRGB) ?? .white
        var tr: CGFloat = 1, tg: CGFloat = 1, tb: CGFloat = 1, ta: CGFloat = 1
        tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let textCGColor = CGColor(red: tr, green: tg, blue: tb, alpha: ta)

        // 创建字体（支持 bold/italic，与预览 SubtitleLabel 一致）
        var ctFont = CTFontCreateWithName(style.fontName as CFString, scaledFontSize, nil)
        if style.bold {
            if let boldFont = CTFontCreateCopyWithSymbolicTraits(ctFont, scaledFontSize, nil, .boldTrait, .boldTrait) {
                ctFont = boldFont
            }
        }
        if style.italic {
            // 矩阵斜切合成斜体（中文字体无 italic face，symbolic traits 会失败）
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            ctFont = CTFontCreateCopyWithAttributes(ctFont, scaledFontSize, &skew, nil)
        }

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
                                       cornerWidth: 3 * fontScale, cornerHeight: 3 * fontScale, transform: nil))
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
        let yOrig = renderSize.height - renderSize.height * CGFloat(baseBottomMargin) / 100
                    - layerH - trackOffset
        layer.frame = CGRect(x: xOrig, y: yOrig, width: layerW, height: layerH)
        layer.contentsGravity = .resize
        layer.contentsScale = 1.0
        if let img = cgImage { layer.contents = img }
        // 与预览 SubtitleLabel 一致的文字阴影（缩放）
        layer.shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.8)
        layer.shadowOffset = CGSize(width: 1 * fontScale, height: 1 * fontScale)
        layer.shadowRadius = 1 * fontScale
        layer.shadowOpacity = 1

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

}

private struct BitratePreset {
    let label: String
    let value: Int
    static let all: [BitratePreset] = [
        .init(label: "低质量", value: 2000),
        .init(label: "标准",   value: 5000),
        .init(label: "高质量", value: 12000),
        .init(label: "极高",   value: 30000),
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

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v)
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
    }
}
