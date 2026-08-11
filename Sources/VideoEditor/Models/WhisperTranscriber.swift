// WhisperTranscriber.swift
// 本地 Whisper 语音识别封装：ffmpeg 提取音频 → whisper-cli 识别 → 解析 SRT。
import Foundation
import AVFoundation

enum WhisperTranscriber {

    private static var devDir: String {
        Bundle.main.bundlePath
            .components(separatedBy: "/").dropLast().joined(separator: "/")
            + "/Vendor/whisper"
    }

    // MARK: - 查找二进制与模型

    static func findWhisper() -> URL? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let p = dir.appendingPathComponent("whisper-cli")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        let dev = URL(fileURLWithPath: devDir).appendingPathComponent("whisper-cli")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    /// VAD 工具。跟 whisper-cli 同目录
    static func findVadTool() -> URL? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let p = dir.appendingPathComponent("whisper-vad-speech-segments")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        let dev = URL(fileURLWithPath: devDir).appendingPathComponent("whisper-vad-speech-segments")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    /// Silero VAD 模型。只有 864 KB，直接打包进 Resources，不走按需下载
    static func findVadModel() -> URL? {
        if let u = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") { return u }
        let dev = URL(fileURLWithPath: devDir)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ggml-silero-v5.1.2.bin")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// 用 VAD 找出音频里**真正在说话**的区间。
    ///
    /// 为什么必须单独跑这一趟：whisper 自己输出的段落是首尾相接填满整条音频的，
    /// 静音也算在段落里，所以每条字幕的起止都比实际语音宽。给 whisper-cli 加 `--vad`
    /// 也只修正整条音频的首尾，段落之间照样 0 间隙（实测各种 -vsd/-vt 组合都一样）。
    /// 词级时间戳同理不可用——token 间隔几乎全是 0，时间是均匀摊给 token 的。
    /// 只有 VAD 的语音区间才带真实停顿（实测同一段音频里找出了 1.83 秒的静音）。
    ///
    /// - Returns: 秒为单位的语音区间，按时间升序；VAD 不可用时返回空数组（调用方退回原行为）
    static func detectSpeechSegments(wavURL: URL) -> [(start: Double, end: Double)] {
        guard let tool = findVadTool(), let model = findVadModel() else { return [] }
        let out = runProcessCapturing(tool, ["-vm", model.path, "-f", wavURL.path])
        var result: [(Double, Double)] = []
        // 工具把结果打在 stdout：`Speech segment 0: start = 138.00, end = 179.00`
        // 数值单位是**厘秒**（1/100 秒），不是毫秒——同一行的 VAD 调试输出
        // 写作 start = 1.38 秒，正好差 100 倍
        let re = try? NSRegularExpression(
            pattern: #"Speech segment\s+\d+:\s*start\s*=\s*([0-9.]+),\s*end\s*=\s*([0-9.]+)"#)
        for line in out.components(separatedBy: .newlines) {
            let r = NSRange(line.startIndex..., in: line)
            guard let m = re?.firstMatch(in: line, range: r), m.numberOfRanges == 3,
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let a = Double(line[r1]), let b = Double(line[r2]), b > a else { continue }
            result.append((a / 100.0, b / 100.0))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// 用语音区间收紧每条字幕的起止，让静音处不再挂着字幕。
    ///
    /// 参数是拿真实素材调出来的，别随手改：
    /// - `minOverlap 0.15s`：重叠短于这个当噪声，不算数
    /// - `mergeGap 0.6s`：短于这个的停顿属于句内换气，不拆句
    /// - `minSeg 0.5s`：过短的语音块（呼吸声、语气词）并进相邻块，
    ///   不然会单独顶出一条只有一两个词的字幕
    ///
    /// 一条字幕跨越长静音时才拆，且**按词边界**分配文本——按字符比例硬切会
    /// 切出 "At ove" / "r 600 grams" 这种劈开单词的碎片。
    /// whisper 没给可用的词级对齐（token 时间是均匀摊的），所以拆分点只能按
    /// 时长比例估，这也是「能不拆就不拆」的原因
    static func alignToSpeech(_ segs: [(start: Double, end: Double, text: String)],
                              speech: [(start: Double, end: Double)])
    -> [(start: Double, end: Double, text: String)] {
        guard !speech.isEmpty else { return segs }
        let minOverlap = 0.15, mergeGap = 0.6, minSeg = 0.5

        var out: [(start: Double, end: Double, text: String)] = []
        for s in segs {
            let hits = speech.compactMap { sp -> (Double, Double)? in
                let a = max(s.start, sp.start), b = min(s.end, sp.end)
                return b - a > minOverlap ? (a, b) : nil
            }
            if hits.isEmpty { continue }        // 整条落在静音里 → 丢掉

            // 句内换气合并
            var blocks: [[Double]] = [[hits[0].0, hits[0].1]]
            for h in hits.dropFirst() {
                if h.0 - blocks[blocks.count - 1][1] < mergeGap {
                    blocks[blocks.count - 1][1] = h.1
                } else {
                    blocks.append([h.0, h.1])
                }
            }
            // 过短的块并进相邻块
            var i = 0
            while blocks.count > 1 && i < blocks.count {
                if blocks[i][1] - blocks[i][0] < minSeg {
                    if i + 1 < blocks.count { blocks[i + 1][0] = blocks[i][0] }
                    else { blocks[i - 1][1] = blocks[i][1] }
                    blocks.remove(at: i)
                } else {
                    i += 1
                }
            }

            if blocks.count == 1 {
                out.append((blocks[0][0], blocks[0][1], s.text))
                continue
            }

            // 跨长静音：按词切
            let hasSpace = s.text.contains(" ")
            let units: [String] = hasSpace
                ? s.text.split(separator: " ").map(String.init)
                : s.text.map(String.init)
            guard !units.isEmpty else { continue }
            let total = blocks.reduce(0.0) { $0 + ($1[1] - $1[0]) }
            var used = 0
            for (bi, b) in blocks.enumerated() {
                let take = bi == blocks.count - 1
                    ? units.count - used
                    : max(1, Int((Double(units.count) * (b[1] - b[0]) / total).rounded()))
                guard take > 0, used < units.count else { continue }
                let slice = units[used..<min(used + take, units.count)]
                used += take
                let piece = slice.joined(separator: hasSpace ? " " : "")
                    .trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append((b[0], b[1], piece)) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// 模型下载存放目录（沙盒安全的 Application Support）
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    // MARK: - 模型规格

    enum ModelSize: String, CaseIterable {
        case tiny, base, small, medium, large = "large-v3-turbo"
        var fileName: String { "ggml-\(rawValue).bin" }
        var displayName: String {
            switch self {
            case .tiny:   return "Tiny"
            case .base:   return "Base"
            case .small:  return "Small"
            case .medium: return "Medium"
            case .large:  return "Large v3 Turbo"
            }
        }
        var sizeDesc: String {
            switch self {
            case .tiny:   return "75 MB · 最快速度，适合短句/简单内容"
            case .base:   return "142 MB · 较快，日常够用"
            case .small:  return "466 MB · 均衡之选，推荐大多数场景"
            case .medium: return "1.5 GB · 高精度，适合复杂/多语言内容"
            case .large:  return "1.6 GB · 最高精度，速度优化版"
            }
        }
        /// 设置卡片上的功能名。不用 Tiny/Base/Small 这些模型规格名——用户要挑的是
        /// "多快 vs 多准"，规格名对这个判断没帮助，收进 infoText 就好
        var featureName: String {
            switch self {
            case .tiny:   return "极速识别"
            case .base:   return "快速识别"
            case .small:  return "均衡识别"
            case .medium: return "高精度识别"
            case .large:  return "最高精度识别"
            }
        }

        /// 卡片副标题：只说取舍，不提规格和体积
        var featureDetail: String {
            switch self {
            case .tiny:   return "最快，适合短句和简单内容"
            case .base:   return "较快，日常够用"
            case .small:  return "速度与准确度均衡，推荐大多数场景"
            case .medium: return "更准，适合复杂或多语言内容"
            case .large:  return "最准，速度优化版"
            }
        }

        /// ⓘ 气泡：模型规格 + 体积
        var infoText: String {
            switch self {
            case .tiny:   return "使用 Whisper Tiny 模型，约 75 MB"
            case .base:   return "使用 Whisper Base 模型，约 142 MB"
            case .small:  return "使用 Whisper Small 模型，约 466 MB"
            case .medium: return "使用 Whisper Medium 模型，约 1.5 GB"
            case .large:  return "使用 Whisper Large v3 Turbo 模型，约 1.6 GB"
            }
        }

        var minFileSize: Int {
            switch self {
            case .tiny: return 30_000_000
            case .base: return 100_000_000
            case .small: return 300_000_000
            case .medium: return 1_000_000_000
            case .large: return 1_000_000_000
            }
        }
        var sourceURLs: [String] {
            [
                "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(fileName)",
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
            ]
        }
    }

    static func downloadedModelURL(_ size: ModelSize) -> URL {
        supportDir.appendingPathComponent(size.fileName)
    }

    static func findModel() -> URL? {
        let preferred = AppSettings.shared.selectedWhisperModel
        let preferredURL = downloadedModelURL(preferred)
        if FileManager.default.fileExists(atPath: preferredURL.path) { return preferredURL }

        for size in ModelSize.allCases.reversed() {
            let dl = downloadedModelURL(size)
            if FileManager.default.fileExists(atPath: dl.path) { return dl }
        }
        let names = ModelSize.allCases.reversed().map(\.fileName)
        for name in names {
            if let r = Bundle.main.resourceURL?.appendingPathComponent(name),
               FileManager.default.fileExists(atPath: r.path) { return r }
            if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
                let p = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: p.path) { return p }
            }
            let dev = URL(fileURLWithPath: devDir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dev.path) { return dev }
        }
        return nil
    }

    static var whisperReady: Bool { findWhisper() != nil }
    static var modelReady: Bool { findModel() != nil }
    static var isAvailable: Bool { findWhisper() != nil }

    // MARK: - 模型按需下载

    static func downloadModel(_ size: ModelSize, progress: @escaping (Double) -> Void) async throws {
        let dest = downloadedModelURL(size)
        var lastError: Error?
        for src in size.sourceURLs {
            guard let url = URL(string: src) else { continue }
            do {
                try await downloadFile(url, to: dest, progress: progress)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let fileSize = (attrs?[.size] as? Int) ?? 0
                if fileSize > size.minFileSize { return }
                try? FileManager.default.removeItem(at: dest)
                lastError = NSError(domain: "Whisper", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "下载文件不完整（\(fileSize/1_000_000)MB），请检查网络后重试"])
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
            }
        }
        throw lastError ?? TranscribeError.downloadFailed
    }

    @available(*, deprecated, message: "Use downloadModel(_:progress:) with ModelSize")
    static func downloadModel(progress: @escaping (Double) -> Void) async throws {
        try await downloadModel(.small, progress: progress)
    }

    private static func downloadFile(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let delegate = DownloadProgressDelegate(dest: dest, progress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) BlackCat/3.5", forHTTPHeaderField: "User-Agent")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var httpError: Error?
        init(dest: URL, progress: @escaping (Double) -> Void) {
            self.dest = dest; self.progress = progress
        }
        private var lastReported: Double = -1

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didReceive response: URLResponse) {
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                httpError = NSError(domain: "Whisper", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)，请检查网络或更换镜像"])
                downloadTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if p - lastReported >= 0.01 || p >= 1.0 {
                lastReported = p
                progress(p)
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let httpErr = httpError {
                continuation?.resume(throwing: httpErr)
                continuation = nil
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                progress(1.0)
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let err = httpError ?? error {
                continuation?.resume(throwing: err)
                continuation = nil
            }
        }
    }

    /// 翻译目标语言显示名 → whisper ISO 639-1 代码
    static func langCode(forDisplayName name: String) -> String {
        switch name {
        case "中文（简体）", "中文（繁体）": return "zh"
        case "English":   return "en"
        case "日本語":     return "ja"
        case "한국어":     return "ko"
        case "Français":  return "fr"
        case "Deutsch":   return "de"
        case "Español":   return "es"
        case "Русский":   return "ru"
        case "العربية":   return "ar"
        case "Português": return "pt"
        case "Italiano":  return "it"
        default:          return "auto"
        }
    }

    /// 中文简繁的 initial prompt（whisper 默认偏繁体，用 prompt 引导简繁；其他语言无需）
    static func prompt(forDisplayName name: String) -> String? {
        switch name {
        case "中文（简体）": return "以下是简体中文普通话的内容。"
        case "中文（繁体）": return "以下是繁體中文的內容。"
        default:           return nil
        }
    }

    // MARK: - 错误

    enum TranscribeError: Error, LocalizedError {
        case whisperNotFound, modelNotFound, ffmpegNotFound
        case audioExtractFailed(String), recognizeFailed, noResult, downloadFailed
        var errorDescription: String? {
            switch self {
            case .whisperNotFound:    return "找不到 whisper-cli 可执行文件"
            case .modelNotFound:      return "找不到语音识别模型"
            case .ffmpegNotFound:     return "找不到 ffmpeg"
            case .audioExtractFailed(let detail):
                return detail.isEmpty ? "音频提取失败" : "音频提取失败: \(detail)"
            case .recognizeFailed:    return "语音识别失败"
            case .noResult:           return "未识别到任何语音内容"
            case .downloadFailed:     return "模型下载失败，请检查网络后重试"
            }
        }
    }

    // MARK: - 识别

    /// 识别一段媒体并返回字幕段（时间已加上 timelineOffset，单位秒）。
    /// - Parameters:
    ///   - mediaURL: 源文件 URL
    ///   - trimStart: 源内起点（秒）
    ///   - duration: 截取时长（秒，<=0 表示到结尾）
    ///   - language: "zh" / "en" / "auto"
    ///   - timelineOffset: 时间轴起始位置（秒），加到每段时间戳上
    static func transcribe(
        mediaURL: URL, trimStart: Double, duration: Double,
        language: String, prompt: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [(start: Double, end: Double, text: String)] {

        guard let whisper = findWhisper() else { throw TranscribeError.whisperNotFound }
        guard let model   = findModel()   else { throw TranscribeError.modelNotFound }
        guard let ffmpeg  = ProjectState.findFFmpeg() else { throw TranscribeError.ffmpegNotFound }
        NSLog("[Whisper] 使用模型: %@", model.lastPathComponent)

        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        let wavURL    = tmp.appendingPathComponent("bc_wsp_\(uid).wav")
        let outPrefix = tmp.appendingPathComponent("bc_wsp_\(uid)")
        let srtURL    = URL(fileURLWithPath: outPrefix.path + ".srt")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: srtURL)
        }

        // 1. ffmpeg 提取音频（0% ~ 5%）
        onProgress?(0)
        var ffArgs = ["-y"]
        if trimStart > 0.001 { ffArgs += ["-ss", String(format: "%.3f", trimStart)] }
        if duration  > 0.001 { ffArgs += ["-t",  String(format: "%.3f", duration)] }
        ffArgs += ["-i", mediaURL.path, "-vn",
                   "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
        let extractOK = await Task.detached(priority: .userInitiated) {
            runProcess(ffmpeg, ffArgs)
        }.value
        guard extractOK, FileManager.default.fileExists(atPath: wavURL.path) else {
            let lines = (lastProcessError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            let detail = lines.last(where: { !$0.isEmpty }) ?? ""
            NSLog("[Whisper] ffmpeg failed: \(detail)")
            throw TranscribeError.audioExtractFailed(detail)
        }
        onProgress?(0.05)

        // 2. whisper-cli 识别（5% ~ 90%），解析实时进度
        var wArgs = ["-m", model.path, "-f", wavURL.path,
                     "-l", language, "-pp",
                     "-osrt", "-of", outPrefix.path, "-np"]
        if let prompt, !prompt.isEmpty {
            wArgs += ["--prompt", prompt]
        }
        let recOK = await Task.detached(priority: .userInitiated) {
            runProcessWithProgress(whisper, wArgs) { whisperPct in
                onProgress?(0.05 + whisperPct * 0.85)
            }
        }.value
        guard recOK, FileManager.default.fileExists(atPath: srtURL.path) else {
            throw TranscribeError.recognizeFailed
        }
        onProgress?(0.90)

        // 3. 解析 SRT（90% ~ 95%）
        guard let srtText = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw TranscribeError.recognizeFailed
        }
        let segs = parseSRT(srtText)
        guard !segs.isEmpty else { throw TranscribeError.noResult }

        // 4. 用 VAD 的语音区间收紧字幕边界，静音处不再挂着字幕
        let speech = detectSpeechSegments(wavURL: wavURL)
        let aligned = alignToSpeech(segs, speech: speech)
        onProgress?(0.95)
        return aligned.isEmpty ? segs : aligned
    }

    // MARK: - Process helper

    private static let processLock = NSLock()
    private static var _currentProcess: Process?
    static var currentProcess: Process? {
        get { processLock.withLock { _currentProcess } }
        set { processLock.withLock { _currentProcess = newValue } }
    }

    static func killCurrentProcess() {
        if let p = currentProcess, p.isRunning { p.terminate() }
        currentProcess = nil
    }

    static var lastProcessError: String?

    /// 跑一个进程并把 stdout + stderr 一起收回来。
    /// VAD 工具把结果和调试信息混在两个流里输出，只读一个会漏
    private static func runProcessCapturing(_ exe: URL, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        currentProcess = p
        var data = Data()
        do {
            try p.run()
            // 先读完再 wait：管道缓冲区满了子进程会卡住写不动
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        } catch {
            lastProcessError = error.localizedDescription
        }
        currentProcess = nil
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runProcess(_ exe: URL, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        currentProcess = p
        do {
            try p.run()
            p.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            lastProcessError = String(data: errData, encoding: .utf8)
            currentProcess = nil
            return p.terminationStatus == 0
        } catch {
            lastProcessError = error.localizedDescription
            currentProcess = nil
            return false
        }
    }

    private static func runProcessWithProgress(_ exe: URL, _ args: [String],
                                                onProgress: @escaping (Double) -> Void) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardError = pipe
        currentProcess = p

        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                // whisper-cli 输出: "whisper_print_progress_callback: progress =  42%"
                if line.contains("progress") {
                    let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    if let last = digits.last, let pct = Double(last), pct >= 0, pct <= 100 {
                        onProgress(pct / 100.0)
                    }
                }
            }
        }

        do {
            try p.run()
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            return p.terminationStatus == 0
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            return false
        }
    }

    // MARK: - SRT 解析

    /// 解析 SRT 文本为 (start, end, text)（时间相对文件起点，秒）。
    static func parseSRT(_ srt: String) -> [(start: Double, end: Double, text: String)] {
        var result: [(Double, Double, String)] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 2,
                  let tIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[tIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = parseSRTTime(parts[0]),
                  let e = parseSRTTime(parts[1]) else { continue }
            let text = lines[(tIdx + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append((s, e, text))
        }
        return result
    }

    /// "00:00:01,234" → 1.234
    private static func parseSRTTime(_ str: String) -> Double? {
        let t = str.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let c = t.components(separatedBy: ":")
        guard c.count == 3, let h = Double(c[0]), let m = Double(c[1]), let s = Double(c[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
