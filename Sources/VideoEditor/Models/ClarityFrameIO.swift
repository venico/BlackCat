// ClarityFrameIO.swift
// 清晰度提升的抽帧/编码，全程用内置 ffmpeg，不碰 AVAssetReader/AVAssetImageGenerator——
// 家用机实测这类 AVFoundation 调用会永久挂死并拖垮 Swift 协作池（详见
// home_machine_decode_issue.md），这个功能逐帧吞吐量大、耗时长，
// 踩中同样的坑影响面更大，没必要冒这个险。
import Foundation

enum ClarityFrameIO {

    enum FrameIOError: Error, LocalizedError {
        case ffmpegNotFound
        case extractFailed(String)
        case encodeFailed(String)
        case noFramesExtracted
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:       return "找不到内置 ffmpeg"
            case .extractFailed(let d): return "抽帧失败：\(d)"
            case .encodeFailed(let d):  return "编码失败：\(d)"
            case .noFramesExtracted:    return "没有抽出任何帧"
            case .cancelled:            return "已取消"
            }
        }
    }

    /// 当前运行的 ffmpeg 进程，供取消时 terminate（同 AudioSeparator.currentProcess 的模式）
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

    /// 把片段裁剪范围解码成 PNG 序列，按帧率抽满。文件名 frame_00001.png 起
    nonisolated static func extractFrames(url: URL, trimStart: Double, duration: Double,
                                          frameRate: Double, outputDir: URL) throws -> [URL] {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", duration), "-i", url.path]
        args += ["-vf", "fps=\(frameRate)"]
        args += [outputDir.appendingPathComponent("frame_%05d.png").path]
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        currentProcess = p
        defer { currentProcess = nil }
        do { try p.run() } catch {
            throw FrameIOError.extractFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal { throw FrameIOError.cancelled }
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            throw FrameIOError.extractFailed("ffmpeg 退出码 \(p.terminationStatus) \(msg)")
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
            .map { outputDir.appendingPathComponent($0) }
        guard !files.isEmpty else { throw FrameIOError.noFramesExtracted }
        return files
    }

    /// 把处理后的帧序列（跟 extractFrames 同样的命名规则 frame_%05d.png）编回视频，
    /// 音轨从原素材同一裁剪范围复制过来
    nonisolated static func encodeFrames(frameDir: URL, frameRate: Double,
                                        audioSourceURL: URL, audioTrimStart: Double, audioDuration: Double,
                                        outputURL: URL) throws {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        args += ["-framerate", "\(frameRate)", "-i", frameDir.appendingPathComponent("frame_%05d.png").path]
        if audioTrimStart > 0.001 { args += ["-ss", String(format: "%.6f", audioTrimStart)] }
        args += ["-t", String(format: "%.6f", audioDuration), "-i", audioSourceURL.path]
        args += ["-map", "0:v:0", "-map", "1:a:0?"]
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"]
        args += ["-c:a", "aac", "-shortest"]
        args += [outputURL.path]
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        currentProcess = p
        defer { currentProcess = nil }
        do { try p.run() } catch {
            throw FrameIOError.encodeFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal { throw FrameIOError.cancelled }
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            throw FrameIOError.encodeFailed("ffmpeg 退出码 \(p.terminationStatus) \(msg)")
        }
    }
}
