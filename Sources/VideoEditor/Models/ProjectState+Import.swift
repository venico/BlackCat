import SwiftUI
import AVFoundation

// MARK: - File Import + Transcode

extension ProjectState {

    /// 支持的素材扩展名
    static let supportedExtensions: Set<String> = [
        "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv",
        "mp3","wav","aac","m4a","flac","aiff","aif","caf","au",
        "ogg","wma","opus","ac3","ape","dts",
        "srt","ass","vtt",
        "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic",
        "avif","heif","jfif","svg","dng","cr2","nef","arw","raf","orf"
    ]

    /// AVFoundation 原生支持的视频容器，无需转码
    static let nativeVideoExtensions: Set<String> = ["mp4","mov","m4v"]

    /// 需要 FFmpeg 转码的视频格式
    static let needsTranscodeExtensions: Set<String> = [
        "avi","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv"
    ]

    /// 支持智能 remux 的容器（编码兼容时直接 copy，不兼容才转码）
    static let smartRemuxExtensions: Set<String> = ["mkv", "ts", "mts", "m2ts"]

    /// 需要 FFmpeg 转码的音频格式（转为 m4a）
    static let needsTranscodeAudioExtensions: Set<String> = [
        "ogg","wma","opus","ac3","ape","dts"
    ]

    static func assetType(for ext: String) -> AssetType? {
        switch ext {
        case "mp4","mov","mkv","avi","m4v","wmv","flv","ts","mts","m2ts","webm","3gp","mpg","mpeg","vob","rm","rmvb","f4v","ogv": return .video
        case "mp3","wav","aac","m4a","flac","aiff","aif","caf","au",
             "ogg","wma","opus","ac3","ape","dts": return .audio
        case "srt","ass","vtt": return .subtitle
        case "png","jpg","jpeg","gif","bmp","tiff","tif","webp","heic",
             "avif","heif","jfif","svg","dng","cr2","nef","arw","raf","orf": return .image
        default: return nil
        }
    }

    /// 导入文件或文件夹（文件夹会递归扫描）
    func importFile(_ url: URL) {
        // 确保沙盒环境下有访问权限
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }

        // 如果是文件夹，递归扫描
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            importFolder(url)
            return
        }

        guard !mediaAssets.contains(where: { $0.url == url }) else {
            showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
            return
        }
        let ext = url.pathExtension.lowercased()
        guard let type = Self.assetType(for: ext) else { return }

        // 需要转码的音频格式，先转为 M4A 再导入
        if type == .audio && Self.needsTranscodeAudioExtensions.contains(ext) {
            let fileName = url.deletingPathExtension().lastPathComponent
            let shortHash = String(url.path.hashValue, radix: 16, uppercase: false).suffix(8)
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BlackCatTranscode", isDirectory: true)
                .appendingPathComponent("\(fileName)_\(shortHash).m4a")
            if mediaAssets.contains(where: { $0.url == outputURL }) {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
                return
            }
            transcodeAudioAndImport(url: url, outputURL: outputURL, displayName: url.lastPathComponent)
            return
        }

        // 需要转码或智能 remux 的视频格式
        if type == .video && (Self.needsTranscodeExtensions.contains(ext) || Self.smartRemuxExtensions.contains(ext)) {
            // 检查转码后的文件是否已在素材库中（防止同一源文件重复导入）
            let fileName = url.deletingPathExtension().lastPathComponent
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BlackCatTranscode", isDirectory: true)
                .appendingPathComponent("\(fileName).mp4")
            if mediaAssets.contains(where: { $0.url == outputURL }) {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
                return
            }
            transcodeAndImport(url: url)
            return
        }

        importFileDirectly(url: url, type: type)
    }

    /// 直接导入（原生格式或转码完成后的文件）
    func importFileDirectly(url: URL, type: AssetType, displayName: String? = nil) {
        // 兜底去重：防止任何路径绕过前置检查
        guard !mediaAssets.contains(where: { $0.url == url }) else { return }
        let fSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        var asset = MediaAsset(url: url, name: displayName ?? url.lastPathComponent, type: type)
        asset.importDate = Date()
        asset.fileSize = fSize
        let aid = asset.id
        mediaAssets.append(asset)
        // Trigger thumbnail / waveform generation
        if type == .video {
            loadMediaThumbnail(assetID: aid, url: url)
            loadTimelineThumbnails(assetID: aid, url: url)
        } else if type == .audio {
            loadWaveform(assetID: aid, url: url)
        } else if type == .image {
            loadImageThumbnail(assetID: aid, url: url)
        }
        if type != .subtitle && type != .image {
            Task {
                let av = AVURLAsset(url: url)
                if let d = try? await av.load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where:{ $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        }
    }

    // MARK: - FFmpeg Transcode

    /// 取消所有转码
    func cancelTranscoding() {
        for task in activeTasks {
            task.process?.terminate()
            task.process = nil
            try? FileManager.default.removeItem(at: task.outputURL)
        }
        for task in pendingTasks {
            try? FileManager.default.removeItem(at: task.outputURL)
        }
        activeTasks.removeAll()
        pendingTasks.removeAll()
        isTranscoding = false
        transcodingProgress = 0
        transcodingFileName = ""
    }

    /// 取消单个转码任务
    func cancelTranscodeTask(_ taskID: UUID) {
        if let task = activeTasks.first(where: { $0.id == taskID }) {
            task.isCancelled = true
            task.process?.terminate()
            task.process = nil
            try? FileManager.default.removeItem(at: task.outputURL)
            showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: task.displayName, subtitle: "已停止", autoCountdown: false)
        }
        activeTasks.removeAll { $0.id == taskID }
        pendingTasks.removeAll { $0.id == taskID }
        drainPendingTasks()
        if activeTasks.isEmpty && pendingTasks.isEmpty {
            isTranscoding = false
            transcodingProgress = 0
            transcodingFileName = ""
        }
    }

    func enqueueTranscodeTask(_ task: TranscodeTask) {
        isTranscoding = true
        let runningCount = activeTasks.filter { $0.isRunning }.count
        if runningCount < Self.maxConcurrentTranscodes {
            activeTasks.append(task)
            task.isRunning = true
            if task.type == .audio {
                runAudioTranscode(task)
            } else {
                runVideoTranscode(task)
            }
        } else {
            pendingTasks.append(task)
            activeTasks.append(task)
        }
    }

    func finishTranscodeTask(_ taskID: UUID) {
        guard let task = activeTasks.first(where: { $0.id == taskID }) else {
            drainPendingTasks()
            if activeTasks.isEmpty && pendingTasks.isEmpty {
                isTranscoding = false; transcodingProgress = 0; transcodingFileName = ""
            }
            return
        }
        let name = task.displayName
        let wasCancelled = task.isCancelled
        activeTasks.removeAll { $0.id == taskID }
        drainPendingTasks()
        if !wasCancelled {
            showSuccessToast(icon: "checkmark", title: name, subtitle: "转码完成")
        }
        if activeTasks.isEmpty && pendingTasks.isEmpty {
            isTranscoding = false
            transcodingProgress = 0
            transcodingFileName = ""
        }
    }

    func drainPendingTasks() {
        while activeTasks.filter({ $0.isRunning }).count < Self.maxConcurrentTranscodes,
              !pendingTasks.isEmpty {
            let task = pendingTasks.removeFirst()
            guard activeTasks.contains(where: { $0.id == task.id }) else { continue }
            task.isRunning = true
            if task.type == .audio {
                runAudioTranscode(task)
            } else {
                runVideoTranscode(task)
            }
        }
    }

    func runAudioTranscode(_ task: TranscodeTask) {
        guard let ffmpeg = Self.findFFmpeg() else {
            showImportToast("未找到 FFmpeg，无法转码 \(task.displayName)")
            finishTranscodeTask(task.id)
            return
        }
        let outputDir = task.outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        Task.detached { [weak self] in
            let ok = Self.runFFmpegSync(ffmpeg: ffmpeg, arguments: [
                "-i", task.inputURL.path,
                "-c:a", "aac", "-b:a", "192k",
                "-y", task.outputURL.path
            ])
            await MainActor.run {
                guard !task.isCancelled else { return }
                if ok {
                    self?.importFileDirectly(url: task.outputURL, type: .audio, displayName: task.displayName)
                } else {
                    self?.showImportToast("「\(task.displayName)」转码失败")
                }
                self?.finishTranscodeTask(task.id)
            }
        }
    }

    func runVideoTranscode(_ task: TranscodeTask) {
        guard let ffmpeg = Self.findFFmpeg() else {
            showImportToast("未找到 FFmpeg，无法转码 \(task.displayName)")
            finishTranscodeTask(task.id)
            return
        }

        Task.detached { [weak self] in
            // 用 ffprobe 检测编解码器兼容性
            let ffmpegDir = ffmpeg.deletingLastPathComponent().path
            let codecs = Self.probeCodecs(ffmpegDir: ffmpegDir, inputPath: task.inputURL.path)
            let videoCompatible = ["h264", "hevc", "mpeg4"].contains(codecs.video)
            let audioCompatible = ["aac", "alac", "mp3", ""].contains(codecs.audio)

            let totalDuration = Self.probeVideoDuration(ffmpegDir: ffmpegDir, inputPath: task.inputURL.path)

            // 构建 ffmpeg 参数：智能选择 copy 或转码
            var args: [String] = []
            if videoCompatible && audioCompatible {
                args = ["-i", task.inputURL.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "copy", "-c:a", "copy",
                        "-movflags", "+faststart", "-y", task.outputURL.path]
            } else if videoCompatible {
                args = ["-i", task.inputURL.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                        "-movflags", "+faststart", "-y", task.outputURL.path]
            } else {
                args = ["-hwaccel", "videotoolbox",
                        "-i", task.inputURL.path,
                        "-c:v", "h264_videotoolbox", "-b:v", "8000k",
                        "-profile:v", "high", "-level:v", "4.2",
                        "-c:a", audioCompatible ? "copy" : "aac"]
                if !audioCompatible { args += ["-b:a", "192k"] }
                args += ["-movflags", "+faststart", "-y", task.outputURL.path]
            }

            let process = Process()
            await MainActor.run { task.process = process }
            process.executableURL = ffmpeg
            process.arguments = args

            let pipe = Pipe()
            process.standardError = pipe

            do { try process.run() } catch {
                await MainActor.run {
                    self?.showImportToast("转码失败")
                    self?.finishTranscodeTask(task.id)
                }
                return
            }

            let handle = pipe.fileHandleForReading
            var buffer = ""
            while process.isRunning {
                if let data = try? handle.availableData, !data.isEmpty,
                   let str = String(data: data, encoding: .utf8) {
                    buffer += str
                    if let range = buffer.range(of: "time=\\d{2}:\\d{2}:\\d{2}\\.\\d+", options: .regularExpression) {
                        let timeStr = String(buffer[range]).replacingOccurrences(of: "time=", with: "")
                        let currentSec = Self.parseFFmpegTime(timeStr)
                        if totalDuration > 0 {
                            let prog = min(currentSec / totalDuration, 1.0)
                            Task { @MainActor [weak self] in
                                task.progress = prog
                                self?.objectWillChange.send()
                            }
                        }
                        if let lastCR = buffer.lastIndex(of: "\r") {
                            buffer = String(buffer[buffer.index(after: lastCR)...])
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.waitUntilExit()

            await MainActor.run {
                task.process = nil
                guard !task.isCancelled else { return }
                if process.terminationStatus == 0 {
                    self?.importFileDirectly(url: task.outputURL, type: .video)
                } else {
                    self?.showImportToast("转码失败")
                }
                self?.finishTranscodeTask(task.id)
            }
        }
    }

    /// 将不兼容的音频格式转为 M4A（AAC）再导入
    func transcodeAudioAndImport(url: URL, outputURL: URL, displayName: String? = nil) {
        let name = displayName ?? url.lastPathComponent
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !mediaAssets.contains(where: { $0.url == outputURL }) {
                importFileDirectly(url: outputURL, type: .audio, displayName: name)
            } else {
                showImportToast("「\(name)」已在素材库中，已跳过")
            }
            return
        }
        enqueueTranscodeTask(TranscodeTask(inputURL: url, outputURL: outputURL, type: .audio, displayName: name))
    }

    /// 将非原生视频格式转为 MP4
    func transcodeAndImport(url: URL) {
        let fileName = url.deletingPathExtension().lastPathComponent
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlackCatTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let shortHash = String(url.path.hashValue, radix: 16, uppercase: false).suffix(8)
        let outputURL = outputDir.appendingPathComponent("\(fileName)_\(shortHash).mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !mediaAssets.contains(where: { $0.url == outputURL }) {
                importFileDirectly(url: outputURL, type: .video)
            } else {
                showImportToast("「\(url.lastPathComponent)」已在素材库中，已跳过")
            }
            return
        }
        enqueueTranscodeTask(TranscodeTask(inputURL: url, outputURL: outputURL, type: .video, displayName: url.lastPathComponent))
    }

    /// 同步执行 FFmpeg 命令，返回是否成功
    static func runFFmpegSync(ffmpeg: URL, arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 变速音频预处理（ffmpeg atempo）

    /// 构建 atempo filter 字符串（atempo 范围 0.5~2.0，超出则串联）
    static func buildAtempoFilter(speed: Double) -> String {
        var filters: [String] = []
        var r = speed
        while r > 2.0 + 1e-6 { filters.append("atempo=2.0"); r /= 2.0 }
        while r < 0.5 - 1e-6 { filters.append("atempo=0.5"); r /= 0.5 }
        if abs(r - 1.0) > 1e-6 { filters.append(String(format: "atempo=%.6f", r)) }
        if filters.isEmpty { filters.append("atempo=1.0") }
        return filters.joined(separator: ",")
    }

    /// 用 ffmpeg 生成变速音频临时文件，带缓存。
    /// - Returns: 临时 .m4a URL（正常速度，duration ≈ srcDurSec / speed）
    func generateSpeedAudio(inputURL: URL, trimStart: Double, srcDurSec: Double,
                             speed: Double, audioTrackIndex: Int) async -> URL? {
        let key = "\(inputURL.path)|\(trimStart)|\(srcDurSec)|\(speed)|\(audioTrackIndex)"
        if let cached = audioSpeedCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let ffmpeg = Self.findFFmpeg() else { return nil }
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bc_spd_\(UUID().uuidString).m4a")
        let filterStr = Self.buildAtempoFilter(speed: speed)
        var args = ["-y"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", srcDurSec), "-i", inputURL.path]
        args += ["-vn"]
        if audioTrackIndex > 0 { args += ["-map", "0:a:\(audioTrackIndex)"] }
        args += ["-af", filterStr, "-c:a", "aac", "-ar", "44100", "-ac", "2", tmpURL.path]
        let ok = await Task.detached(priority: .userInitiated) {
            Self.runFFmpegSync(ffmpeg: ffmpeg, arguments: args)
        }.value
        if ok {
            audioSpeedCache[key] = tmpURL
            return tmpURL
        }
        return nil
    }

    static func findFFmpeg() -> URL? {
        // 优先从 app bundle 内部查找（已内置）
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledFFmpeg = bundlePath.appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: bundledFFmpeg.path) {
                return bundledFFmpeg
            }
        }
        // 回退到系统安装的版本
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // 尝试通过 which 查找
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffmpeg"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 用 ffprobe 检测视频/音频编解码器名称
    static func probeCodecs(ffmpegDir: String, inputPath: String) -> (video: String, audio: String) {
        let probePath = ffmpegDir + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probePath) else { return ("", "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probePath)
        proc.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let vCodec = (try? pipe.fileHandleForReading.readDataToEndOfFile())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: probePath)
        proc2.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe2 = Pipe()
        proc2.standardOutput = pipe2
        proc2.standardError = Pipe()
        try? proc2.run()
        proc2.waitUntilExit()
        let aCodec = (try? pipe2.fileHandleForReading.readDataToEndOfFile())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (vCodec, aCodec)
    }

    /// 用 ffprobe 获取视频总时长（秒）
    static func probeVideoDuration(ffmpegDir: String, inputPath: String) -> Double {
        let probePath = ffmpegDir + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probePath) else { return 0 }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: probePath)
        proc.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", inputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
           let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let dur = Double(str) {
            return dur
        }
        return 0
    }

    /// 解析 FFmpeg 的 "HH:MM:SS.xx" 时间格式为秒数
    static func parseFFmpegTime(_ str: String) -> Double {
        let parts = str.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    /// 递归扫描文件夹，导入所有支持的素材
    func importFolder(_ folderURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                importFile(fileURL)
            }
        }
    }
}
