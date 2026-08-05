// AudioSeparator.swift
// 本地音源分离封装：ffmpeg 提取音频 → demucs.cpp 分离 6 轨 → 勾选的每轨各导出成 m4a。
//
// 技术边界：模型分的是「乐器轨」而不是「音乐 vs 音效」，音效没有独立类别，会按声学特征
// 散落到各轨 —— 打击类音效（脚步/关门/撞击）和音乐鼓点一起进 drums，低频轰鸣和贝斯线
// 一起进 bass，持续环境音和弦乐/垫音一起进 other。所以不做自动取舍，
// 分出来的轨原样交给用户，在时间轴上自己删留调音量。
import Foundation
import AVFoundation

enum AudioSeparator {

    private static var devDir: String {
        Bundle.main.bundlePath
            .components(separatedBy: "/").dropLast().joined(separator: "/")
            + "/Vendor/demucs"
    }

    // MARK: - 分离出的轨道

    enum Stem: Int, CaseIterable {
        case drums = 0, bass, other, vocals, guitar, piano

        /// demucs.cpp 的输出文件名固定为 target_<index>_<name>.wav
        var fileName: String {
            switch self {
            case .drums:  return "target_0_drums.wav"
            case .bass:   return "target_1_bass.wav"
            case .other:  return "target_2_other.wav"
            case .vocals: return "target_3_vocals.wav"
            case .guitar: return "target_4_guitar.wav"
            case .piano:  return "target_5_piano.wav"
            }
        }

        var displayName: String {
            switch self {
            case .drums:  return "鼓"
            case .bass:   return "贝斯"
            case .other:  return "其他"
            case .vocals: return "人声"
            case .guitar: return "吉他"
            case .piano:  return "钢琴"
            }
        }

        /// 说明这一轨在「去音乐留音效」场景下实际装了什么
        var hint: String {
            switch self {
            case .vocals: return "对白、旁白、歌声"
            case .other:  return "环境音（风雨、嘈杂）+ 弦乐、合成器等残余音乐"
            case .drums:  return "打击类音效（脚步、关门、撞击）+ 音乐鼓点"
            case .bass:   return "低频轰鸣（爆炸尾音、车辆）+ 贝斯线"
            case .guitar: return "吉他，基本是纯音乐"
            case .piano:  return "钢琴，基本是纯音乐"
            }
        }
    }

    /// 用户在设置里选的保留轨，为空时回退到默认
    static var keepStemsForMusicRemoval: [Stem] {
        let raw = AppSettings.shared.separateKeepStems
        let stems = raw.compactMap { Stem(rawValue: $0) }
        return stems.isEmpty ? [.vocals, .other, .drums] : stems
    }

    // MARK: - 查找二进制与模型

    static func findDemucs() -> URL? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let p = dir.appendingPathComponent("demucs.cpp.main")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        let dev = URL(fileURLWithPath: devDir).appendingPathComponent("demucs.cpp.main")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/demucs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 分离产物输出目录。只增不删，靠设置页的清理入口回收
    static var separatedDir: URL {
        supportDir.appendingPathComponent("separated", isDirectory: true)
    }

    /// 目录下的全部产物文件（含早期「替换片段音频」方案遗留的 mp4）
    static func separatedFiles() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: separatedDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// 走废纸篓而不是直接删：判断失误时用户还能自己捡回来
    @discardableResult
    static func trashFiles(_ urls: [URL]) -> (moved: Int, failed: Int) {
        var moved = 0, failed = 0
        for u in urls {
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                moved += 1
            } catch {
                NSLog("[Demucs] 清理失败 %@: %@", u.lastPathComponent, error.localizedDescription)
                failed += 1
            }
        }
        return (moved, failed)
    }

    /// 6 轨模型，比 4 轨多切走 guitar / piano 两类音乐成分
    static let modelFileName = "ggml-model-htdemucs-6s-f16.bin"
    static let modelMinFileSize = 40_000_000

    /// 卸载分离模型。只删模型本身，分离出来的音频产物不动——那些可能正被
    /// 项目引用着，清理它们是设置里另一个独立的入口
    static func uninstallModel() throws {
        guard FileManager.default.fileExists(atPath: supportDir.path) else { return }
        try FileManager.default.removeItem(at: supportDir)
    }

    static var modelSourceURLs: [String] {
        [
            "https://hf-mirror.com/datasets/Retrobear/demucs.cpp/resolve/main/\(modelFileName)",
            "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/\(modelFileName)"
        ]
    }

    static func downloadedModelURL() -> URL {
        supportDir.appendingPathComponent(modelFileName)
    }

    static func findModel() -> URL? {
        let dl = downloadedModelURL()
        if FileManager.default.fileExists(atPath: dl.path) { return dl }
        if let r = Bundle.main.resourceURL?.appendingPathComponent(modelFileName),
           FileManager.default.fileExists(atPath: r.path) { return r }
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let p = dir.appendingPathComponent(modelFileName)
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        let dev = URL(fileURLWithPath: devDir).appendingPathComponent(modelFileName)
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    static var demucsReady: Bool { findDemucs() != nil }
    static var modelReady: Bool { findModel() != nil }

    // MARK: - 模型按需下载

    static func downloadModel(progress: @escaping (Double) -> Void) async throws {
        let dest = downloadedModelURL()
        var lastError: Error?
        for src in modelSourceURLs {
            guard let url = URL(string: src) else { continue }
            do {
                try await downloadFile(url, to: dest, progress: progress)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let fileSize = (attrs?[.size] as? Int) ?? 0
                if fileSize > modelMinFileSize { return }
                try? FileManager.default.removeItem(at: dest)
                lastError = NSError(domain: "Demucs", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "下载文件不完整（\(fileSize / 1_000_000)MB），请检查网络后重试"
                ])
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
            }
        }
        throw lastError ?? SeparateError.downloadFailed
    }

    private static func downloadFile(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SeparateError.downloadFailed
        }
        let total = http.expectedContentLength
        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 1 << 22)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            data.append(byte)
            if total > 0, Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                progress(Double(data.count) / Double(total))
            }
        }
        try data.write(to: dest)
        progress(1.0)
    }

    // MARK: - 错误

    enum SeparateError: Error, LocalizedError {
        case demucsNotFound, modelNotFound, ffmpegNotFound
        case audioExtractFailed(String), separateFailed, exportFailed
        case cancelled, downloadFailed, noAudioTrack

        var errorDescription: String? {
            switch self {
            case .demucsNotFound:  return "找不到 demucs.cpp.main 可执行文件"
            case .modelNotFound:   return "找不到音源分离模型"
            case .ffmpegNotFound:  return "找不到 ffmpeg"
            case .audioExtractFailed(let d):
                return d.isEmpty ? "音频提取失败" : "音频提取失败: \(d)"
            case .separateFailed:  return "音源分离失败"
            case .exportFailed:    return "音轨导出失败"
            case .cancelled:       return "已取消"
            case .downloadFailed:  return "模型下载失败，请检查网络后重试"
            case .noAudioTrack:    return "该素材没有音频轨道"
            }
        }
    }

    // MARK: - 主流程

    /// 分离音轨，勾选的每一轨各自导出成独立音频文件。
    /// - Parameters:
    ///   - mediaURL: 源文件（视频或音频）
    ///   - trimStart: 源内起点（秒）
    ///   - duration: 截取时长（秒，<=0 表示到结尾）
    ///   - keepStems: 要导出的轨
    /// - Returns: 每条轨对应的文件，顺序与 keepStems 一致
    static func separateStems(
        mediaURL: URL,
        trimStart: Double = 0,
        duration: Double = 0,
        keepStems: [Stem] = keepStemsForMusicRemoval,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [(stem: Stem, url: URL)] {

        guard let demucs = findDemucs() else { throw SeparateError.demucsNotFound }
        guard let model  = findModel()  else { throw SeparateError.modelNotFound }
        guard let ffmpeg = ProjectState.findFFmpeg() else { throw SeparateError.ffmpegNotFound }
        guard !keepStems.isEmpty else { throw SeparateError.exportFailed }

        let hasAudio = await mediaHasAudio(mediaURL)
        guard hasAudio else { throw SeparateError.noAudioTrack }

        let tmp = FileManager.default.temporaryDirectory
        let uid = String(UUID().uuidString.prefix(8))
        let wavURL   = tmp.appendingPathComponent("bc_sep_\(uid).wav")
        let stemDir  = tmp.appendingPathComponent("bc_sep_\(uid)_stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: stemDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: stemDir)
        }

        // 1. 提取音频（0% ~ 5%）。demucs 要求 44.1kHz 立体声
        onProgress?(0, "提取音频…")
        var ffArgs = ["-y"]
        if trimStart > 0.001 { ffArgs += ["-ss", String(format: "%.3f", trimStart)] }
        if duration  > 0.001 { ffArgs += ["-t",  String(format: "%.3f", duration)] }
        ffArgs += ["-i", mediaURL.path, "-vn",
                   "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", wavURL.path]
        let extractOK = await Task.detached(priority: .userInitiated) {
            runProcess(ffmpeg, ffArgs)
        }.value
        guard extractOK, FileManager.default.fileExists(atPath: wavURL.path) else {
            let detail = (lastProcessError ?? "")
                .components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? ""
            throw SeparateError.audioExtractFailed(detail)
        }
        try Task.checkCancellation()
        onProgress?(0.05, "分离中…")

        // 2. demucs 分离（5% ~ 85%）。神经网络推理，长素材会跑几分钟
        let sepOK = await Task.detached(priority: .userInitiated) {
            runProcessWithProgress(demucs, [model.path, wavURL.path, stemDir.path]) { pct in
                onProgress?(0.05 + pct * 0.80, "分离中…")
            }
        }.value
        guard sepOK else {
            if Task.isCancelled { throw SeparateError.cancelled }
            throw SeparateError.separateFailed
        }
        try Task.checkCancellation()
        onProgress?(0.85, "导出音轨…")

        // 3. 每条勾选的轨各自转成 m4a（85% ~ 100%）
        let outDir = separatedDir
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let baseName = mediaURL.deletingPathExtension().lastPathComponent

        var results: [(stem: Stem, url: URL)] = []
        for (i, stem) in keepStems.enumerated() {
            try Task.checkCancellation()
            let src = stemDir.appendingPathComponent(stem.fileName)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }

            let dest = outDir.appendingPathComponent("\(baseName)_\(stem.displayName)_\(uid).m4a")
            let ok = await Task.detached(priority: .userInitiated) {
                runProcess(ffmpeg, ["-y", "-i", src.path, "-c:a", "aac", "-b:a", "192k", dest.path])
            }.value
            if ok, FileManager.default.fileExists(atPath: dest.path) {
                results.append((stem, dest))
            } else {
                NSLog("[Demucs] 导出 %@ 失败: %@", stem.displayName, lastProcessError ?? "")
            }
            onProgress?(0.85 + Double(i + 1) / Double(keepStems.count) * 0.15, "导出音轨…")
        }

        guard !results.isEmpty else { throw SeparateError.exportFailed }
        onProgress?(1.0, "完成")
        return results
    }

    // MARK: - 媒体探测

    private static func mediaHasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
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

    /// 逐行缓冲。readabilityHandler 在后台线程回调，必须加锁保护
    private final class LineBuffer {
        private let lock = NSLock()
        private var text = ""

        func append(_ chunk: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            text += chunk
            var lines: [String] = []
            while let idx = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                lines.append(String(text[text.startIndex..<idx]))
                text = String(text[text.index(after: idx)...])
            }
            return lines
        }
    }

    /// demucs.cpp 把进度打到 stdout，形如 "(50.000%)"。
    /// stderr 只收错误信息，两个流各自独立缓冲 —— 共用一个缓冲会数据竞争导致崩溃。
    private static func runProcessWithProgress(_ exe: URL, _ args: [String],
                                               onProgress: @escaping (Double) -> Void) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        currentProcess = p

        let outBuffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in outBuffer.append(chunk) {
                if let pct = parsePercent(line) { onProgress(pct) }
            }
        }

        let errLock = NSLock()
        var errText = ""
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            errLock.lock()
            errText += chunk
            errLock.unlock()
        }

        func teardown() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            errLock.lock()
            lastProcessError = errText
            errLock.unlock()
        }

        do {
            try p.run()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            teardown()
            if !ok {
                NSLog("[Demucs] exit=%d err=%@", p.terminationStatus, lastProcessError ?? "")
            }
            currentProcess = nil
            return ok
        } catch {
            teardown()
            lastProcessError = error.localizedDescription
            NSLog("[Demucs] launch failed: %@", error.localizedDescription)
            currentProcess = nil
            return false
        }
    }

    private static func parsePercent(_ line: String) -> Double? {
        guard let range = line.range(of: "%") else { return nil }
        let head = line[line.startIndex..<range.lowerBound]
        let token = head.reversed().prefix(while: { $0.isNumber || $0 == "." })
        let num = String(token.reversed())
        guard !num.isEmpty, let v = Double(num), v >= 0, v <= 100 else { return nil }
        return v / 100.0
    }
}
