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
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

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
                        .foregroundColor(project.exportSettings.outputPath == nil ? .gray : .black)
                        .frame(width: 120, height: 36)
                        .background(project.exportSettings.outputPath == nil ? Color.white.opacity(0.08) : Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(project.exportSettings.outputPath == nil)
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

        let orderedSubs = project.orderedSubtitleIndices.map { project.subtitleTracks[$0] }
        let snapshot = ExportInput(
            videoTracks: project.videoTracks,
            audioTracks: project.audioTracks,
            subtitleTracks: orderedSubs,
            imageTracks: project.imageTracks,
            textTracks: project.textTracks,
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
        let globalEndTime = max(vEnd, max(iEnd, max(aEnd, max(sEnd, tEnd))))

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
                if includeVideo && track.isVisible,
                   let vAsset = try? await asset.loadTracks(withMediaType: .video).first {
                    let vt = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
                    try vt?.insertTimeRange(actualRange, of: vAsset, at: at)
                    if let vt {
                        if abs(speed - 1.0) > 0.001 {
                            let compRange = CMTimeRange(start: at, duration: actualSrcDur)
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
                        // 变速：用 ffmpeg atempo 预处理，避免 scaleTimeRange 音频失真
                        if let url = clip.url,
                           let speedURL = await self.generateSpeedAudio(
                               inputURL: url, trimStart: clip.trimStart,
                               srcDurSec: srcContentDurSec, speed: speed,
                               audioTrackIndex: clip.audioTrackIndex),
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
                    } else {
                        // 正常速度：直接插入
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

        // ── 图片轨道（上层）──
        var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []
        if includeVideo {
            let endTime = globalEndTime
            for track in input.imageTracks {
                guard track.isVisible else { continue }
                for clip in track.clips {
                    var url = clip.videoURL
                    // videoURL 不存在时（临时文件被清理），从 imageURL 重新生成
                    if url == nil || !FileManager.default.fileExists(atPath: url!.path),
                       let imgURL = clip.imageURL {
                        url = await ProjectState.createVideoFromImage(imageURL: imgURL, duration: clip.duration)
                    }
                    guard let url else { continue }
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

        // 如果字幕/图片超出音视频长度，扩展 composition 到 globalEndTime
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

            let hasImageTracks = !imageCompTracks.isEmpty
            let hasVideoClipTransforms = !videoCompTracks.isEmpty

            // Step 1: 图片/视频合成 / 分辨率帧率变更
            if hasImageTracks || hasVideoClipTransforms {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = frameDuration
                vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

                let ts: CMTimeScale = 600
                let imageClipCMRanges = imageCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.clip.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.clip.endTime, preferredTimescale: ts)
                    return (s, e)
                }
                let videoClipCMRanges = videoCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                var cmBoundaries: [CMTime] = [.zero, composition.duration]
                for r in imageClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
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
                    let visualEnd = max(vEnd, iEnd)
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
            let visualEnd = max(vEnd, iEnd)
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

            // ── 色调范围表（视频 clip），导出时逐帧应用 CIFilter ──
            let colorRanges: [(start: Double, end: Double, adj: ColorAdjust)] =
                input.videoTracks.flatMap { track -> [(Double, Double, ColorAdjust)] in
                    guard track.isVisible else { return [] }
                    return track.clips.compactMap { clip in
                        clip.colorAdjust.isIdentity ? nil : (clip.startTime, clip.endTime, clip.colorAdjust)
                    }
                } + input.imageTracks.flatMap { track -> [(Double, Double, ColorAdjust)] in
                    guard track.isVisible else { return [] }
                    return track.clips.compactMap { clip in
                        clip.colorAdjust.isIdentity ? nil : (clip.startTime, clip.endTime, clip.colorAdjust)
                    }
                }

            // 收集文字图层数据
            let visibleTextClips = input.textTracks
                .filter { $0.isVisible }
                .flatMap { $0.clips }

            // ── 快速路径：无 overlay 时用 AVAssetExportSession（5-10x 加速）──
            let needsPerFrameProcessing = subRenderInfo.hasSubtitles || !visibleTextClips.isEmpty || !colorRanges.isEmpty
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

            // ── 用 AVAssetWriter 导出（逐帧处理：字幕/文字/色调）──
            try? FileManager.default.removeItem(at: input.outputURL)
            try await writerExport(
                composition: composition,
                videoComposition: videoComposition!,
                audioMix: audioMix,
                subtitleInfo: subRenderInfo,
                textClips: visibleTextClips,
                colorRanges: colorRanges,
                fps: fps,
                bitrate: settings.bitrate,
                outputURL: input.outputURL,
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
        subtitleInfo: SubtitleRenderInfo,
        textClips: [TextClip],
        colorRanges: [(start: Double, end: Double, adj: ColorAdjust)],
        fps: Int, bitrate: Int,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let renderSize = videoComposition.renderSize
        let totalDuration = composition.duration.seconds

        // ── Reader ──
        let reader = try AVAssetReader(asset: composition)

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput? = nil
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            ao.audioMix = audioMix
            reader.add(ao)
            audioOutput = ao
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
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,  // High Profile 压缩率更高
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,        // CABAC 比 CAVLC 压缩率高 ~15%
                AVVideoAllowFrameReorderingKey: true                            // 允许 B 帧，进一步提高压缩率
            ] as [String: Any],
            // 优先使用硬件编码器（VideoToolbox），失败时自动回退软件编码
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
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]  // GPU 直接访问，避免 CPU 拷贝
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
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "Export", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "无法启动读取: \(reader.error?.localizedDescription ?? "unknown")"])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Export", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法启动写入: \(writer.error?.localizedDescription ?? "unknown")"])
        }
        writer.startSession(atSourceTime: .zero)

        let hasSubtitles = subtitleInfo.hasSubtitles
        let hasTextOverlays = !textClips.isEmpty
        let videoQueue = DispatchQueue(label: "export.video")
        let audioQueue = DispatchQueue(label: "export.audio")
        let targetFps = fps
        let ciCtx = ExportCIContext.shared

        // 音视频必须并行消费，否则 AVAssetReader 内部缓冲区满会死锁
        await withTaskGroup(of: Void.self) { group in
            // 视频帧处理：按目标帧率重采样 + CIImage GPU 管线
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var frameIndex: Int64 = 0
                    var currentPB: CVPixelBuffer? = nil
                    var currentReaderTime: Double = 0
                    var nextSB: CMSampleBuffer? = videoOutput.copyNextSampleBuffer()

                    // 字幕缓存：同一字幕段内复用 overlay CIImage
                    var cachedSubOverlay: CIImage? = nil
                    var cachedSubKey: String = ""

                    let cancelRef = self._cancelFlag
                    videoInput.requestMediaDataWhenReady(on: videoQueue) {
                        while videoInput.isReadyForMoreMediaData {
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

                            // 推进 reader 直到找到覆盖 targetTime 的帧
                            while let sb = nextSB {
                                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                                if pts <= targetTime {
                                    currentPB = CMSampleBufferGetImageBuffer(sb)
                                    currentReaderTime = pts
                                    nextSB = videoOutput.copyNextSampleBuffer()
                                } else {
                                    break
                                }
                            }

                            // reader 耗尽且没有当前帧
                            if currentPB == nil && nextSB == nil {
                                videoInput.markAsFinished()
                                cont.resume()
                                return
                            }

                            let outputPTS = CMTime(value: frameIndex, timescale: Int32(targetFps))
                            if let pb = currentPB {
                                // 查找当前帧的色调调节
                                let activeAdj = colorRanges.first {
                                    targetTime >= $0.start && targetTime < $0.end
                                }?.adj

                                let needsExtra = hasSubtitles || hasTextOverlays || (activeAdj != nil && activeAdj?.isIdentity == false)
                                if needsExtra {
                                    // GPU 管线：CIImage 零拷贝包装 → CIFilter 链 → 一次 render
                                    var image = CIImage(cvPixelBuffer: pb)

                                    // 1. 色调调节（CIFilter GPU）
                                    if let adj = activeAdj, !adj.isIdentity {
                                        image = ColorAdjust.apply(image, adj)
                                    }

                                    // 2. 文字图层 overlay（CPU 渲染透明 CGImage → GPU 合成）
                                    if hasTextOverlays,
                                       let textOverlay = self.renderTextOverlay(
                                           atTime: targetTime, clips: textClips,
                                           fontScale: subtitleInfo.fontScale, renderSize: renderSize) {
                                        image = textOverlay.composited(over: image)
                                    }

                                    // 3. 字幕 overlay（带缓存：同一字幕段内只渲染 1 次）
                                    if hasSubtitles {
                                        // 构建缓存 key：用活跃字幕文本拼接
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
                                    }

                                    // 4. 从 adaptor pool 取 buffer，一次 GPU render
                                    if let pool = adaptor.pixelBufferPool {
                                        var outBuf: CVPixelBuffer?
                                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                                        if let outBuf = outBuf {
                                            ciCtx.render(image, to: outBuf)
                                            adaptor.append(outBuf, withPresentationTime: outputPTS)
                                        }
                                    }
                                } else {
                                    adaptor.append(pb, withPresentationTime: outputPTS)
                                }
                            }
                            frameIndex += 1
                            let pct = min(targetTime / max(totalDuration, 0.01), 0.99)
                            progress(pct)
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

    /// 渲染字幕为透明背景 CIImage overlay（用于 CISourceOverCompositing GPU 合成）
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
