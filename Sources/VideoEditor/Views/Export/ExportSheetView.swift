import SwiftUI
import AVFoundation
import CoreText

struct ExportSheetView: View {
    @EnvironmentObject private var project: ProjectState
    @Environment(\.dismiss) private var dismiss

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

            // Settings — no ScrollView; content is measured at natural height
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
                                panel.prompt = "选择"
                                panel.begin { r in
                                    if r == .OK { project.exportSettings.outputPath = panel.url }
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
                            Text(".mp4")
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

                    // Export type — selectable like the fps row
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

            // Action row — [progress / error / success status]  ...  取消 [16px] 开始导出
            HStack(spacing: 16) {
                // Inline status occupies the flexible left area, left-aligned
                // with the section content above (same horizontal padding 24).
                Group {
                    if project.isExporting {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在导出… \(Int(project.exportProgress * 100))%")
                                .font(.system(size: 11)).foregroundColor(Color.labelSecondary)
                            ProgressView(value: project.exportProgress)
                                .progressViewStyle(.linear).tint(Color.accent)
                        }
                    } else if let err = project.exportError {
                        Text("导出失败:\(err)")
                            .font(.system(size: 11)).foregroundColor(.red.opacity(0.85))
                            .lineLimit(2)
                    } else if let url = project.exportFinishedAt {
                        HStack(spacing: 8) {
                            Text("已导出到 \(url.lastPathComponent)")
                                .font(.system(size: 11)).foregroundColor(Color.accent)
                                .lineLimit(1).truncationMode(.middle)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .buttonStyle(.link).font(.system(size: 11))
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { dismiss() } label: {
                    Text(project.isExporting ? "关闭" : "取消").font(.system(size: 13))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 80, height: 36)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    startExport()
                } label: {
                    Text(project.isExporting ? "导出中…" : "开始导出")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 120, height: 36)
                        .background(project.isExporting
                                    ? Color.accent.opacity(0.55) : Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(project.isExporting)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
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
            project.exportError = "请先选择输出位置"
            project.exportFinishedAt = nil
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

        // Reset state
        project.exportError = nil
        project.exportFinishedAt = nil
        project.isExporting = true
        project.exportProgress = 0

        let snapshot = ExportInput(
            videoTracks: project.videoTracks,
            audioTracks: project.audioTracks,
            subtitleTracks: project.subtitleTracks,
            subtitleStyles: project.subtitleStyles,
            settings: project.exportSettings,
            outputURL: outputURL)

        Task.detached {
            let exporter = TimelineExporter()
            do {
                let url = try await exporter.export(snapshot) { p in
                    Task { @MainActor in project.exportProgress = p }
                }
                await MainActor.run {
                    project.isExporting = false
                    project.exportProgress = 1
                    project.exportFinishedAt = url
                }
            } catch {
                await MainActor.run {
                    project.isExporting = false
                    project.exportError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Export pipeline

struct ExportInput {
    let videoTracks:    [Track<VideoClip>]
    let audioTracks:    [Track<AudioClip>]
    let subtitleTracks: [Track<SubtitleClip>]
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

        // ── 字幕烧录（仅 video 模式）──
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
            if !visibleSubs.isEmpty, let sourceVTrack = composition.tracks(withMediaType: .video).first {
                videoComposition = self.buildVideoCompositionWithSubtitles(
                    composition: composition,
                    videoTrack: sourceVTrack,
                    renderSize: renderSize,
                    frameDuration: frameDuration,
                    subtitleTracks: input.subtitleTracks,
                    subtitleStyles: input.subtitleStyles)
            } else if renderSize != sourceVideoSize || fps != Int(1.0 / sourceFrameDuration.seconds) {
                // 即使没字幕，分辨率或帧率变了也需要 videoComposition
                if let sourceVTrack = composition.tracks(withMediaType: .video).first {
                    let vc = AVMutableVideoComposition()
                    vc.renderSize = renderSize
                    vc.frameDuration = frameDuration
                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVTrack)
                    // 缩放视频到目标分辨率
                    let scaleX = renderSize.width / sourceVideoSize.width
                    let scaleY = renderSize.height / sourceVideoSize.height
                    li.setTransform(CGAffineTransform(scaleX: scaleX, y: scaleY), at: .zero)
                    instr.layerInstructions = [li]
                    vc.instructions = [instr]
                    videoComposition = vc
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
            while !Task.isCancelled,
                  exporter.status == .waiting || exporter.status == .exporting {
                progress(Double(exporter.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await exporter.export()
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
        let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstr.setOpacity(1.0, at: .zero)
        instruction.layerInstructions = [layerInstr]
        videoComp.instructions = [instruction]

        // Layer hierarchy:  parentLayer → [ videoLayer (where frames go) , textLayers… ]
        // Setting parentLayer.beginTime = AVCoreAnimationBeginTimeAtZero so child
        // animation beginTimes are interpreted in composition time (not "now").
        let videoLayer  = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false      // y-up: matches CGContext and our yOrig calculation
        parentLayer.beginTime = AVCoreAnimationBeginTimeAtZero
        parentLayer.addSublayer(videoLayer)

        // 收集可见轨道，计算每个轨道的 Y 偏移（track 0 在最下，track 1 在上面）
        let visibleTrackData: [(track: Track<SubtitleClip>, style: SubtitleStyle, idx: Int)] =
            subtitleTracks.enumerated().compactMap { i, t in
                guard t.isVisible else { return nil }
                let s = i < subtitleStyles.count ? subtitleStyles[i] : SubtitleStyle()
                return (t, s, i)
            }

        let baseStyle = visibleTrackData.first?.style ?? SubtitleStyle()
        let spacing   = baseStyle.lineSpacing

        for clip in self.allTimeSlots(tracks: visibleTrackData.map(\.track)) {
            // 对于每个时间段，找出各轨道在这个时间段有字幕的
            var layersForSlot: [(text: String, style: SubtitleStyle)] = []
            for td in visibleTrackData {
                if let c = td.track.clips.first(where: {
                    $0.startTime <= clip.start && $0.endTime > clip.start
                }) {
                    layersForSlot.append((c.text, td.style))
                }
            }

            // 从下往上堆叠
            var yAccum = renderSize.height * baseStyle.bottomMargin / 100
            for (text, style) in layersForSlot {
                let layer = makeSubtitleLayer(text: text,
                                              style: style,
                                              renderSize: renderSize,
                                              startTime: clip.start,
                                              endTime:   clip.end,
                                              yOrigin: yAccum)
                parentLayer.addSublayer(layer)
                yAccum += layer.frame.height + spacing
            }
        }

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer)

        return videoComp
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

        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = NSNumber(value: 0.0)
        show.toValue   = NSNumber(value: 1.0)
        show.beginTime = startTime > 0 ? startTime : AVCoreAnimationBeginTimeAtZero
        show.duration  = 0.001
        show.fillMode  = .forwards
        show.isRemovedOnCompletion = false
        layer.add(show, forKey: "show")

        let hide = CABasicAnimation(keyPath: "opacity")
        hide.fromValue = NSNumber(value: 1.0)
        hide.toValue   = NSNumber(value: 0.0)
        hide.beginTime = endTime > 0 ? endTime : AVCoreAnimationBeginTimeAtZero
        hide.duration  = 0.001
        hide.fillMode  = .forwards
        hide.isRemovedOnCompletion = false
        layer.add(hide, forKey: "hide")

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
