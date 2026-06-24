import SwiftUI
import AVFoundation
import NaturalLanguage

// MARK: - Subtitle Parsing + Whisper Transcription

extension ProjectState {

    // MARK: - 字幕文件读取（编码检测 + 换行符统一）

    /// 尝试多种编码读取字幕文件，统一换行符为 \n，去除 BOM
    func readSubtitleFile(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var content: String?

        // ── 第一步：用 macOS 内置引擎自动检测编码 ──
        // NSString.stringEncoding(for:) 能准确区分 Big5 / GBK / UTF-8 等
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        var convertedNS: NSString?
        var usedLossy: ObjCBool = false
        let detected = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding.utf16.rawValue,
                    big5,
                    gb18030
                ] as [UInt],
                .useOnlySuggestedEncodingsKey: false as NSNumber,
                .allowLossyKey: false as NSNumber
            ],
            convertedString: &convertedNS,
            usedLossyConversion: &usedLossy)
        if detected != 0, !usedLossy.boolValue, let ns = convertedNS {
            content = ns as String
        }

        // ── 第二步：自动检测失败则手动逐个尝试 ──
        if content == nil {
            let encodings: [String.Encoding] = [
                .utf8,
                .utf16,
                String.Encoding(rawValue: big5),
                String.Encoding(rawValue: gb18030)
            ]
            for enc in encodings {
                if let s = String(data: data, encoding: enc), !s.isEmpty {
                    content = s; break
                }
            }
        }

        guard var text = content else { return nil }

        // 去除 BOM
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst())
        }

        // 统一换行符：\r\n → \n，单独 \r → \n
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        return text
    }

    // MARK: - SRT Parser

    func parseSRT(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        // 用正则切分空行块（兼容 \n\n、\r\n\r\n、混合换行）
        let blocks = raw.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 2, let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = srtTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = srtTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let idx = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let text = lines.dropFirst(idx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }
    func srtTime(_ s: String) -> Double? {
        let c = s.replacingOccurrences(of: ",", with: ".")
        let p = c.components(separatedBy: ":"); guard p.count == 3 else { return nil }
        guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    // MARK: - ASS 解析

    func parseASS(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        var inEvents = false
        var formatFields: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("[events]") { inEvents = true; continue }
            if trimmed.hasPrefix("[") && !trimmed.lowercased().hasPrefix("[events]") { inEvents = false; continue }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                let fields = trimmed.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                formatFields = fields
                continue
            }
            guard trimmed.hasPrefix("Dialogue:") || trimmed.hasPrefix("dialogue:") else { continue }
            let content = String(trimmed.drop(while: { $0 != ":" }).dropFirst())
                .trimmingCharacters(in: .whitespaces)
            // ASS Dialogue 字段用逗号分隔，但 Text 字段可能包含逗号
            let parts = content.components(separatedBy: ",")
            // 使用实际 Format 行定义的字段数（不强制最小值）
            let fieldCount = formatFields.isEmpty ? 10 : formatFields.count
            guard parts.count >= fieldCount else { continue }
            let startIdx = formatFields.firstIndex(of: "start") ?? 1
            let endIdx = formatFields.firstIndex(of: "end") ?? 2
            let textIdx = formatFields.firstIndex(of: "text") ?? (fieldCount - 1)
            guard startIdx < parts.count, endIdx < parts.count, textIdx < parts.count else { continue }
            guard let s = assTime(parts[startIdx].trimmingCharacters(in: .whitespaces)),
                  let e = assTime(parts[endIdx].trimmingCharacters(in: .whitespaces)) else { continue }
            // Text 是最后一个字段，可能包含逗号，所以取 textIdx 之后的所有内容
            let text = parts[textIdx...].joined(separator: ",")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // 去除 ASS 样式标签 {\xxx}
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                // \N 换行符
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }

    func assTime(_ s: String) -> Double? {
        // ASS 时间格式: H:MM:SS.cc (百分之一秒)
        let p = s.components(separatedBy: ":"); guard p.count == 3 else { return nil }
        guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    // MARK: - VTT 解析

    func parseVTT(url: URL) -> [SubtitleClip] {
        guard let raw = readSubtitleFile(url: url) else { return [] }
        var clips: [SubtitleClip] = []
        let blocks = raw.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            // VTT 时间戳可能有位置信息在 --> 后面，去掉
            let endPart = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? parts[1]
            guard let s = vttTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let e = vttTime(endPart.trimmingCharacters(in: .whitespaces)) else { continue }
            let idx = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let text = lines.dropFirst(idx + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // 去除 VTT 标签 <b> <i> 等
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            if !text.isEmpty { clips.append(SubtitleClip(text: text, startTime: s, endTime: e)) }
        }
        return clips
    }

    func vttTime(_ s: String) -> Double? {
        // VTT 时间格式: HH:MM:SS.mmm 或 MM:SS.mmm
        let p = s.components(separatedBy: ":")
        if p.count == 3 {
            guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        } else if p.count == 2 {
            guard let m = Double(p[0]), let sec = Double(p[1]) else { return nil }
            return m * 60 + sec
        }
        return nil
    }

    // MARK: - 自动语音识别（Whisper）

    func downloadModelAndTranscribe() {
        guard !isTranscribing else { return }
        let model = selectedWhisperModel
        transcribeState = .downloading(0)
        transcribeTask = Task {
            do {
                try await WhisperTranscriber.downloadModel(model) { p in
                    DispatchQueue.main.async { self.transcribeState = .downloading(p) }
                }
                await MainActor.run {
                    self.transcribeState = .idle
                    self.autoTranscribeSelectedClip()
                }
            } catch is CancellationError {
                await MainActor.run { self.transcribeState = .idle }
            } catch {
                await MainActor.run {
                    self.transcribeState = .failed("模型下载失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 对选中的视频/音频片段做语音识别并生成字幕轨道。
    /// 未选中片段时，识别时间轴上第一个视频片段。
    func autoTranscribeSelectedClip() {
        guard !isTranscribing else { return }

        // 解析识别目标：选中视频 > 选中音频 > 第一个视频片段
        var url: URL?
        var trimStart = 0.0, srcDur = 0.0, offset = 0.0, speed = 1.0
        if let vid = selectedVideoClipID,
           let c = videoTracks.flatMap(\.clips).first(where: { $0.id == vid }) {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        } else if let aid = selectedAudioClipID,
                  let c = audioTracks.flatMap(\.clips).first(where: { $0.id == aid }) {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        } else if let c = videoTracks.flatMap(\.clips).sorted(by: { $0.startTime < $1.startTime }).first {
            url = c.url; trimStart = c.trimStart; speed = max(0.01, c.speed)
            srcDur = c.duration * speed; offset = c.startTime
        }

        guard let mediaURL = url else {
            transcribeState = .failed("请先选择一个视频或音频片段")
            return
        }
        if !WhisperTranscriber.modelReady {
            showWhisperModelPicker = true
            return
        }

        guard WhisperTranscriber.whisperReady else {
            transcribeState = .failed("语音识别引擎未就绪（whisper-cli 缺失）")
            return
        }

        transcribeState = .running(0)

        // 识别用自动检测原声，再按需翻译到「翻译目标语言」
        let displayName = translationTargetLang
        let isTargetSimplified = (displayName == "中文（简体）")
        let targetBase = WhisperTranscriber.langCode(forDisplayName: displayName)  // zh/en/it...

        let capSpeed = speed, capOffset = offset
        transcribeTask = Task {
            do {
                try Task.checkCancellation()
                let segs = try await WhisperTranscriber.transcribe(
                    mediaURL: mediaURL, trimStart: trimStart,
                    duration: srcDur, language: "auto", prompt: nil
                ) { pct in
                    DispatchQueue.main.async { self.transcribeState = .running(pct) }
                }
                try Task.checkCancellation()

                await MainActor.run { self.transcribeState = .running(0.95) }
                let sample = segs.prefix(12).map(\.text).joined(separator: " ")
                let recog = NLLanguageRecognizer()
                recog.processString(sample)
                let detected = recog.dominantLanguage?.rawValue ?? ""
                let detectedBase = String(detected.split(separator: "-").first ?? "")
                let sameLang = (detectedBase == targetBase)
                    || (detectedBase.hasPrefix("zh") && targetBase == "zh")

                var finalSegs: [(start: Double, end: Double, text: String)] = []
                if sameLang {
                    for s in segs {
                        try Task.checkCancellation()
                        let text = isTargetSimplified ? OpenCC.toSimplified(s.text) : s.text
                        finalSegs.append((s.start, s.end, text))
                    }
                } else {
                    let texts = segs.map(\.text)
                    let translated = await Translator.translateConcurrent(
                        texts, to: displayName, batchSize: 15, concurrency: 6
                    ) { done in
                        let p = 0.95 + 0.04 * Double(min(done, segs.count)) / Double(max(segs.count, 1))
                        await MainActor.run { self.transcribeState = .running(p) }
                    }
                    for (i, s) in segs.enumerated() {
                        try Task.checkCancellation()
                        finalSegs.append((s.start, s.end, translated[i]))
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self.pushUndo()
                    var track = Track<SubtitleClip>(label: "识别字幕")
                    track.subtitleStyle = self.newSubtitleStyle()
                    for s in finalSegs {
                        let st = capOffset + s.start / capSpeed
                        let en = capOffset + s.end   / capSpeed
                        track.clips.append(SubtitleClip(text: s.text, startTime: st, endTime: en))
                    }
                    track.clips.sort { $0.startTime < $1.startTime }
                    self.subtitleTracks.append(track)
                    self.syncOverlayOrder()
                    self.transcribeState = .idle
                    self.transcribeTask = nil
                    self.showSuccessToast(icon: "checkmark", title: "语音识别", subtitle: "完成，生成 \(finalSegs.count) 条字幕")
                }
            } catch is CancellationError {
                await MainActor.run {
                    WhisperTranscriber.killCurrentProcess()
                    self.transcribeState = .idle
                    self.transcribeTask = nil
                }
            } catch {
                await MainActor.run {
                    if self.transcribeState != .idle {
                        self.transcribeState = .failed(error.localizedDescription)
                    }
                    self.transcribeTask = nil
                }
            }
        }
    }
}
