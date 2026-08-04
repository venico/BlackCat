// ProjectState+TextToSpeech.swift
// 字幕转语音：把选中的字幕逐条送去 TTS，生成的音频按字幕起点摆进新音频轨道。
// 支持跨字幕轨道多选 —— 收集时不看片段属于哪条轨，只按时间轴排序。
import Foundation
import AVFoundation

extension ProjectState {

    /// 选中的字幕（跨轨道），按时间轴先后排序
    var selectedSubtitleClipsForTTS: [SubtitleClip] {
        var ids = selectedClipIDs
        if let single = selectedSubtitleClipID { ids.insert(single) }
        guard !ids.isEmpty else { return [] }

        // 跨轨道收集：翻译那条链路只认单条源轨，这里不做这个限制
        return subtitleTracks
            .flatMap(\.clips)
            .filter { ids.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
    }

    var canConvertSubtitleToSpeech: Bool {
        !isGeneratingSpeech && !selectedSubtitleClipsForTTS.isEmpty
    }

    func convertSelectedSubtitlesToSpeech() {
        guard !isGeneratingSpeech else { return }

        let clips = selectedSubtitleClipsForTTS
        guard !clips.isEmpty else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                             title: "转换成语音", subtitle: "请先选中有内容的字幕片段")
            return
        }

        let provider = AppSettings.shared.ttsProvider
        guard !AppSettings.shared.providerAPIKey(for: provider.rawValue).isEmpty else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "转换成语音",
                             subtitle: "请先在设置 → 字幕里填写 \(provider.displayName) 的 API Key",
                             autoCountdown: false)
            return
        }

        speechTotal = clips.count
        speechDone = 0
        speechTask = Task { @MainActor in
            var results: [(clip: SubtitleClip, url: URL)] = []
            var failures = 0

            // 并发压到 3 —— TTS 接口普遍比翻译接口更容易触发限流
            let maxConcurrent = 3
            await withTaskGroup(of: (Int, URL?).self) { group in
                var next = 0
                func submit(_ idx: Int) {
                    let text = clips[idx].text
                    group.addTask {
                        do {
                            let url = try await AIVideoService.shared.synthesizeSpeech(
                                text: text, provider: provider)
                            return (idx, url)
                        } catch {
                            NSLog("[TTS] 第 %d 条失败: %@", idx, error.localizedDescription)
                            return (idx, nil)
                        }
                    }
                }
                for _ in 0..<min(maxConcurrent, clips.count) { submit(next); next += 1 }

                for await (idx, url) in group {
                    if Task.isCancelled { break }
                    if let url { results.append((clips[idx], url)) } else { failures += 1 }
                    speechDone += 1
                    if next < clips.count { submit(next); next += 1 }
                }
            }

            guard !Task.isCancelled else {
                speechTotal = 0; speechDone = 0; speechTask = nil
                return
            }

            let overlong = await addSpeechClips(results)
            speechTotal = 0
            speechDone = 0
            speechTask = nil

            if results.isEmpty {
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "转换成语音", subtitle: "全部失败，请检查 API Key 和网络",
                                 autoCountdown: false)
                return
            }

            var parts = ["已生成 \(results.count) 条语音"]
            if failures > 0 { parts.append("\(failures) 条失败") }
            // 语速由文本决定，生成时长对不齐是常态。这里数的是「连到下一条字幕
            // 之前的空档都塞不下」的条数——这些会跟后一条重叠、被分到另一条音轨，
            // 要讲出来让用户自己决定怎么调
            if overlong > 0 { parts.append("\(overlong) 条超出可用空档") }
            showSuccessToast(icon: "waveform", iconColor: failures > 0 ? .orange : .green,
                             title: "转换成语音",
                             subtitle: parts.joined(separator: "，"),
                             autoCountdown: failures == 0 && overlong == 0,
                             revealURL: results.first?.url)
        }
    }

    func cancelSpeechGeneration() {
        speechTask?.cancel()
        speechTask = nil
        speechTotal = 0
        speechDone = 0
        showSuccessToast(icon: "stop.fill", iconColor: .yellow,
                         title: "转换成语音", subtitle: "已停止", autoCountdown: false)
    }

    /// 把生成好的音频摆进轨道，返回时长超过原字幕的条数。
    ///
    /// 两处必须避开主线程，否则界面会整个卡死：
    ///   · 量时长：mp3 得扫码流才能定时长，几十条串行量能堵很久 → 挪到后台并发做
    ///   · 写轨道：逐条改 mediaAssets / audioTracks，每次都触发素材库和时间轴全量重绘 → 攒够一次性提交
    @discardableResult
    private func addSpeechClips(_ items: [(clip: SubtitleClip, url: URL)]) async -> Int {
        guard !items.isEmpty else { return 0 }

        let sorted = items.sorted { $0.clip.startTime < $1.clip.startTime }
        let measured = await Self.measureDurations(sorted.map(\.url))
        // 开了自动对齐就先把超长的压到字幕时长，压不动的原样留着并计数
        let fitted = AppSettings.shared.ttsAutoFit
            ? await Self.fitDurations(sorted, durations: measured)
            : zip(sorted, measured).map { (url: $0.url, duration: $1,
                                           stillLong: $1 > $0.clip.duration + 0.05) }

        pushUndoSavingAssets()

        var newAssets: [MediaAsset] = []
        var pending: [(clip: AudioClip, end: Double)] = []
        var overlong = 0

        for (i, item) in sorted.enumerated() {
            let dur = fitted[i].duration
            let url = fitted[i].url
            if fitted[i].stillLong { overlong += 1 }

            let name = uniqueSpeechName(base: "配音_\(shortLabel(item.clip.text))",
                                        taken: newAssets.map(\.name))
            var asset = MediaAsset(url: url, name: name, type: .audio)
            asset.importDate = Date()
            asset.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            asset.duration = dur
            newAssets.append(asset)

            // 起点对齐字幕，长度按音频实际时长走
            let clip = AudioClip(assetID: asset.id, name: name, url: url,
                                 startTime: item.clip.startTime,
                                 endTime: item.clip.startTime + dur,
                                 trimStart: 0)
            pending.append((clip, clip.endTime))
        }

        // 先在本地分配好轨道，再整体并进 audioTracks
        var lanes: [[AudioClip]] = []
        for p in pending {
            if let idx = lanes.firstIndex(where: { lane in
                !lane.contains { $0.startTime < p.end && $0.endTime > p.clip.startTime }
            }) {
                lanes[idx].append(p.clip)
            } else {
                lanes.append([p.clip])
            }
        }

        let existing = audioTracks.filter { $0.label.hasPrefix("配音") }.count
        let newTracks = lanes.enumerated().map { i, clips -> Track<AudioClip> in
            let n = existing + i + 1
            return Track(clips: clips, label: n == 1 ? "配音" : "配音\(n)")
        }

        // 到这里才动 @Published，全程只触发一次刷新
        mediaAssets.append(contentsOf: newAssets)
        audioTracks.append(contentsOf: newTracks)
        syncAudioSectionOrder()

        // 波形自己在后台算，不挡这次提交
        for a in newAssets { loadWaveform(assetID: a.id, url: a.url) }

        rebuildTimelinePreview()
        return overlong
    }

    /// 变速对齐的上限。压过头语速太快听不清，宁可保持原速让用户自己处理
    static let maxFitRatio = 1.6

    /// 两条配音之间留出的呼吸间隙：语音正好顶到下一条起点会显得太赶，
    /// 留一点空让听感自然，也避免浮点边界上刚好判成重叠
    static let speechGap = 0.15

    /// 把超长的音频用 atempo 压到**可用槽位**（不是字幕自己的时长）。
    ///
    /// 槽位 = 到下一条字幕起点的距离 − 一点呼吸间隙，最后一条不设限。字幕之间
    /// 几乎总有停顿，只按字幕自身时长压是白白浪费那段空档：字幕 0~2s、下一条
    /// 5s 才开始、语音 3s，按旧算法要压到 2s（1.5 倍语速），实际上 3s 完全放得下、
    /// 根本不用压。这直接减少两件事——被迫压缩导致的语速偏快，以及压不动
    /// （超过 maxFitRatio）时顶到下一条、被迫另开一条音轨。
    ///
    /// 槽位比字幕本身还短时（字幕互相重叠这种少见情况）取字幕时长兜底，
    /// 保证这个改动在任何情况下都不会比旧行为压得更狠。
    ///
    /// atempo 是变速不变调，1.0~1.5 倍听感自然；超过上限的原样留着，返回时报给用户。
    /// - Returns: (最终用的音频地址, 实际时长, 是否仍然超长)
    private nonisolated static func fitDurations(
        _ items: [(clip: SubtitleClip, url: URL)], durations: [Double]
    ) async -> [(url: URL, duration: Double, stillLong: Bool)] {
        guard let ffmpeg = ProjectState.findFFmpeg() else {
            // 没有 ffmpeg 就退回原样，不算失败
            return zip(items, durations).map { ($0.url, $1, $1 > $0.clip.duration + 0.05) }
        }

        // items 调用方已按 startTime 排好序，直接取后一条起点即可
        let slots: [Double] = items.indices.map { i in
            guard i + 1 < items.count else { return .greatestFiniteMagnitude }
            let gap = items[i + 1].clip.startTime - items[i].clip.startTime - speechGap
            return max(items[i].clip.duration, gap)
        }

        return await withTaskGroup(of: (Int, URL, Double, Bool).self) { group in
            for (i, item) in items.enumerated() {
                let dur = durations[i]
                let target = slots[i]
                group.addTask {
                    guard dur > target + 0.05, target > 0.05 else {
                        return (i, item.url, dur, false)
                    }
                    let ratio = dur / target
                    guard ratio <= maxFitRatio else {
                        // 压过头会听不清，保持原速并如实报出来
                        return (i, item.url, dur, true)
                    }
                    if let fitted = await runATempo(ffmpeg: ffmpeg, input: item.url, ratio: ratio) {
                        return (i, fitted, target, false)
                    }
                    return (i, item.url, dur, true)
                }
            }
            var result = zip(items, durations).map { ($0.url, $1, false) }
            for await (i, url, d, long) in group { result[i] = (url, d, long) }
            return result.map { (url: $0.0, duration: $0.1, stillLong: $0.2) }
        }
    }

    private nonisolated static func runATempo(ffmpeg: URL, input: URL, ratio: Double) async -> URL? {
        let out = input.deletingPathExtension().appendingPathExtension("fit.m4a")
        try? FileManager.default.removeItem(at: out)

        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-i", input.path,
                       "-filter:a", String(format: "atempo=%.4f", ratio),
                       "-c:a", "aac", "-b:a", "192k", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }

    /// 并发量时长。nonisolated 保证不在主线程上跑
    private nonisolated static func measureDurations(_ urls: [URL]) async -> [Double] {
        await withTaskGroup(of: (Int, Double).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let d = (try? await AVURLAsset(url: url).load(.duration))?.seconds
                    let ok = (d?.isFinite == true) && (d ?? 0) > 0
                    return (i, ok ? d! : 1.0)
                }
            }
            var result = [Double](repeating: 1.0, count: urls.count)
            for await (i, d) in group { result[i] = d }
            return result
        }
    }

    /// 同名往后排序号，避免素材库里一堆重名
    private func uniqueSpeechName(base: String, taken: [String]) -> String {
        var used = Set(mediaAssets.map(\.name))
        used.formUnion(taken)
        guard used.contains(base) else { return base }
        var i = 2
        while used.contains("\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    /// 给测试用的入口 —— 批量插入是卡死过的地方，得能单独量
    @discardableResult
    func testHook_addSpeechClips(_ items: [(clip: SubtitleClip, url: URL)]) async -> Int {
        await addSpeechClips(items)
    }

    /// 拿字幕开头几个字当名字，太长的截断
    private func shortLabel(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > 8 ? String(one.prefix(8)) : one
    }
}
