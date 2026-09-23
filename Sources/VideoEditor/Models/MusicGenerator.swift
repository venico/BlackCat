// MusicGenerator.swift
// 本地配乐生成：ACE-Step 1.5（acestep.cpp，GGML + Metal）。
//
// 两段流水线，都是随包带的命令行程序：
//   ace-lm    —— 0.6B 小模型：把一句描述扩写成完整的风格说明 + 元数据（bpm/调式/拍号），
//                需要人声时顺带写歌词，最后产出 DiT 要用的音频码
//   ace-synth —— DiT（turbo，8 步）+ VAE：把音频码渲染成 48kHz 立体声 wav
//
// 模型四个文件共 4.4 GB，按需下载，托管在公开的 venico/blackcat-models（tag acestep-v1）。
// GitHub 单个资产上限 2 GB，DiT 那个 2.55 GB 的切成两半传，下载后按顺序拼回去。
import Foundation

enum MusicGenerator {

    // MARK: - 模型文件

    struct ModelFile {
        let name: String
        /// 精确字节数。下载完按它核对，对不上就当没下完
        let bytes: Int64
        /// 切成几块上传的。1 = 没切
        let parts: Int
    }

    /// acestep.cpp 按文件名在 --models 目录里找模型。
    /// **请求 JSON 里要写带 .gguf 的完整文件名** —— 它的文档说不带后缀，
    /// 实测不带就报 `lm_model '…' not found in registry`
    static let lmModel    = "acestep-5Hz-lm-0.6B-Q8_0.gguf"
    static let synthModel = "acestep-v15-turbo-Q8_0.gguf"

    static let files: [ModelFile] = [
        ModelFile(name: "vae-BF16.gguf",                    bytes: 337_420_928,   parts: 1),
        ModelFile(name: "Qwen3-Embedding-0.6B-Q8_0.gguf",   bytes: 784_144_960,   parts: 1),
        ModelFile(name: lmModel,                            bytes: 709_846_656,   parts: 1),
        ModelFile(name: synthModel,                         bytes: 2_549_528_000, parts: 2),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    private static let releaseBase =
        "https://github.com/venico/blackcat-models/releases/download/acestep-v1/"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/acestep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 模型单独一个子目录：--models 会扫整个目录，生成出来的音频不能混在里面
    static var modelDir: URL {
        let dir = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 生成的配乐放这儿。只增不删 —— 可能正被项目引用着
    static var generatedDir: URL {
        let dir = supportDir.appendingPathComponent("generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isComplete(_ f: ModelFile) -> Bool {
        let url = modelDir.appendingPathComponent(f.name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return size == f.bytes
    }

    static var modelReady: Bool { files.allSatisfy(isComplete) }

    // MARK: - 命令行程序

    private static var devDir: URL {
        URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/acestep")
    }

    static func findBinary(_ name: String) -> URL? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let p = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        let dev = devDir.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    static var binariesReady: Bool { findBinary("ace-lm") != nil && findBinary("ace-synth") != nil }

    /// 能不能直接用：程序在、模型齐
    static var isReady: Bool { binariesReady && modelReady }

    // MARK: - 下载 / 卸载

    /// 按顺序下。已经下完的文件跳过（中途失败再点下载不用从头来）。
    /// 进度按字节加权，0…1，后台线程回调
    static func downloadModel(progress: @escaping (Double) -> Void) async throws {
        let total = Double(totalBytes)
        var done: Int64 = 0
        for f in files {
            if isComplete(f) { done += f.bytes; progress(Double(done) / total); continue }
            let dest = modelDir.appendingPathComponent(f.name)
            try? FileManager.default.removeItem(at: dest)
            let partBytes = f.bytes / Int64(f.parts)
            var pieces: [URL] = []
            defer { pieces.forEach { try? FileManager.default.removeItem(at: $0) } }
            for i in 1...f.parts {
                try Task.checkCancellation()
                let remote = f.parts == 1 ? f.name : "\(f.name).part\(i)"
                guard let url = URL(string: releaseBase + remote) else { throw GenError.downloadFailed }
                let base = done + partBytes * Int64(i - 1)
                let (tmp, resp) = try await DownloadProgress.download(URLRequest(url: url)) { pct in
                    progress((Double(base) + pct * Double(partBytes)) / total)
                }
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw GenError.downloadFailed
                }
                pieces.append(tmp)
            }
            try join(pieces, into: dest)
            guard isComplete(f) else {
                try? FileManager.default.removeItem(at: dest)
                throw GenError.incomplete(f.name)
            }
            done += f.bytes
            progress(Double(done) / total)
        }
    }

    /// 分块按顺序接起来。单块就直接搬过去，不复制一遍 2 GB
    private static func join(_ pieces: [URL], into dest: URL) throws {
        if pieces.count == 1 {
            try FileManager.default.moveItem(at: pieces[0], to: dest)
            return
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        for p in pieces {
            let inp = try FileHandle(forReadingFrom: p)
            defer { try? inp.close() }
            // 分段读写，别一口气把 1.2 GB 读进内存
            while let chunk = try inp.read(upToCount: 16 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
        }
    }

    /// 只删模型，生成过的配乐不动
    static func uninstallModel() throws {
        let dir = supportDir.appendingPathComponent("models", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - 生成

    enum GenError: Error, LocalizedError {
        case notInstalled, binaryMissing, downloadFailed, incomplete(String)
        case lmFailed(String), synthFailed(String), noOutput, cancelled

        var errorDescription: String? {
            switch self {
            case .notInstalled:       return "配乐模型还没下载，请到 设置 → 音频 里下载"
            case .binaryMissing:      return "找不到配乐生成程序 ace-lm / ace-synth"
            case .downloadFailed:     return "模型下载失败，请检查网络后重试"
            case .incomplete(let n):  return "\(n) 下载不完整，请重试"
            case .lmFailed(let d):    return "编排阶段失败" + (d.isEmpty ? "" : "：\(d)")
            case .synthFailed(let d): return "合成阶段失败" + (d.isEmpty ? "" : "：\(d)")
            case .noOutput:           return "没有生成出音频文件"
            case .cancelled:          return "已取消"
            }
        }
    }

    /// 生成一段配乐。
    /// - Parameters:
    ///   - caption: 风格描述（中英文都行，模型会自己扩写）
    ///   - lyrics: nil = 纯音乐；"" = 让模型自己写词；其余 = 用这段词
    ///   - duration: 秒，10…600
    ///   - onProgress: 0…1 + 阶段说明
    /// - Returns: 生成好的 wav
    static func generate(caption: String,
                         lyrics: String? = nil,
                         duration: Double,
                         onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws -> URL {
        guard let lm = findBinary("ace-lm"), let synth = findBinary("ace-synth") else {
            throw GenError.binaryMissing
        }
        guard modelReady else { throw GenError.notInstalled }

        let uid = String(UUID().uuidString.prefix(8))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc_ace_\(uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // turbo DiT 的推荐参数（官方示例同款）：8 步、不做 CFG、shift 3
        let req: [String: Any] = [
            "caption": caption,
            "lyrics": lyrics ?? "[Instrumental]",
            "duration": min(600, max(10, duration)),
            "lm_model": lmModel,
            "synth_model": synthModel,
            "inference_steps": 8,
            "guidance_scale": 1.0,
            "shift": 3.0,
            "output_format": "wav16",
        ]
        let reqURL = work.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted]).write(to: reqURL)

        // 1. 编排：描述 → 元数据 + 音频码（→ request0.json）
        onProgress?(0.02, "编排中…")
        let lmOut = await Task.detached(priority: .userInitiated) {
            run(lm, ["--models", modelDir.path, "--request", reqURL.path], cwd: work)
        }.value
        if Task.isCancelled { throw GenError.cancelled }
        let codesURL = work.appendingPathComponent("request0.json")
        guard lmOut.ok, FileManager.default.fileExists(atPath: codesURL.path) else {
            throw GenError.lmFailed(lastLine(lmOut.err))
        }

        // 2. 合成：音频码 → wav（→ request00.wav）
        // 本机（M3 Pro）实测 30 秒纯音乐：编排 24s（大半是加载模型）、合成 18s
        onProgress?(0.55, "合成中…")
        let synthOut = await Task.detached(priority: .userInitiated) {
            run(synth, ["--models", modelDir.path, "--request", codesURL.path], cwd: work)
        }.value
        if Task.isCancelled { throw GenError.cancelled }
        guard synthOut.ok else { throw GenError.synthFailed(lastLine(synthOut.err)) }
        guard let wav = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension.lowercased() == "wav" }) else { throw GenError.noOutput }

        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let dest = generatedDir.appendingPathComponent("配乐_\(f.string(from: Date()))_\(uid).wav")
        try FileManager.default.moveItem(at: wav, to: dest)
        onProgress?(1.0, "完成")
        return dest
    }

    private static func lastLine(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }

    // MARK: - 进程

    private static let processLock = NSLock()
    private static var _current: Process?
    private static var current: Process? {
        get { processLock.withLock { _current } }
        set { processLock.withLock { _current = newValue } }
    }

    /// 取消正在跑的那一步
    static func cancel() {
        if let p = current, p.isRunning { p.terminate() }
        current = nil
    }

    /// 同步跑一个程序，须在后台线程调用。stderr 收着报错用
    private static func run(_ exe: URL, _ args: [String], cwd: URL) -> (ok: Bool, err: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        // stderr 边跑边读：日志多的时候管道缓冲（64 KB）写满会把子进程卡住
        let lock = NSLock()
        var errData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.withLock { errData.append(d) }
        }
        current = p
        defer { current = nil; errPipe.fileHandleForReading.readabilityHandler = nil }
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        let text = lock.withLock { String(data: errData, encoding: .utf8) ?? "" }
        if p.terminationStatus != 0 {
            DiagLog.log("[配乐] \(exe.lastPathComponent) 退出码 \(p.terminationStatus)：\(lastLine(text))")
        }
        return (p.terminationStatus == 0, text)
    }
}
