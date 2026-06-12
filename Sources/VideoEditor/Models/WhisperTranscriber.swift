// WhisperTranscriber.swift
// 本地 Whisper 语音识别封装：ffmpeg 提取音频 → whisper-cli 识别 → 解析 SRT。
import Foundation
import AVFoundation

enum WhisperTranscriber {

    // 开发期固定路径（最终捆绑进 app bundle 后走 bundle 查找）
    private static let devDir = "/Users/Venico/claude/VideoEditor/Vendor/whisper"

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
                lastError = TranscribeError.downloadFailed
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
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    /// URLSession 下载进度代理（流式写盘 + 进度回调）
    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        init(dest: URL, progress: @escaping (Double) -> Void) {
            self.dest = dest; self.progress = progress
        }
        private var lastReported: Double = -1
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if p - lastReported >= 0.01 || p >= 1.0 {   // 每 1% 回调一次，避免 flood
                lastReported = p
                progress(p)
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
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
            if let error {
                continuation?.resume(throwing: error)
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
        case audioExtractFailed, recognizeFailed, noResult, downloadFailed
        var errorDescription: String? {
            switch self {
            case .whisperNotFound:    return "找不到 whisper-cli 可执行文件"
            case .modelNotFound:      return "找不到语音识别模型 (ggml-small.bin)"
            case .ffmpegNotFound:     return "找不到 ffmpeg"
            case .audioExtractFailed: return "音频提取失败"
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
        language: String, prompt: String? = nil
    ) async throws -> [(start: Double, end: Double, text: String)] {

        guard let whisper = findWhisper() else { throw TranscribeError.whisperNotFound }
        guard let model   = findModel()   else { throw TranscribeError.modelNotFound }
        guard let ffmpeg  = ProjectState.findFFmpeg() else { throw TranscribeError.ffmpegNotFound }

        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        let wavURL    = tmp.appendingPathComponent("bc_wsp_\(uid).wav")
        let outPrefix = tmp.appendingPathComponent("bc_wsp_\(uid)")
        let srtURL    = URL(fileURLWithPath: outPrefix.path + ".srt")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: srtURL)
        }

        // 1. ffmpeg 提取 16kHz 单声道 PCM wav（whisper 要求的格式）
        var ffArgs = ["-y"]
        if trimStart > 0.001 { ffArgs += ["-ss", String(format: "%.3f", trimStart)] }
        if duration  > 0.001 { ffArgs += ["-t",  String(format: "%.3f", duration)] }
        ffArgs += ["-i", mediaURL.path, "-vn",
                   "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
        let extractOK = await Task.detached(priority: .userInitiated) {
            runProcess(ffmpeg, ffArgs)
        }.value
        guard extractOK, FileManager.default.fileExists(atPath: wavURL.path) else {
            throw TranscribeError.audioExtractFailed
        }

        // 2. whisper-cli 识别 → SRT（prompt 引导输出语言/简繁，可为空）
        var wArgs = ["-m", model.path, "-f", wavURL.path,
                     "-l", language, "-osrt", "-of", outPrefix.path, "-np"]
        if let prompt, !prompt.isEmpty {
            wArgs += ["--prompt", prompt]
        }
        let recOK = await Task.detached(priority: .userInitiated) {
            runProcess(whisper, wArgs)
        }.value
        guard recOK, FileManager.default.fileExists(atPath: srtURL.path) else {
            throw TranscribeError.recognizeFailed
        }

        // 3. 解析 SRT，加时间轴偏移
        guard let srtText = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw TranscribeError.recognizeFailed
        }
        let segs = parseSRT(srtText)
        guard !segs.isEmpty else { throw TranscribeError.noResult }
        return segs
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

    private static func runProcess(_ exe: URL, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        currentProcess = p
        do {
            try p.run()
            p.waitUntilExit()
            currentProcess = nil
            return p.terminationStatus == 0
        } catch {
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
