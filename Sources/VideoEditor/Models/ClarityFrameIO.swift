// ClarityFrameIO.swift
// 清晰度提升的解码/编码：两个 ffmpeg 进程对接 rawvideo 裸字节流，全程不落盘。
// 全程用内置 ffmpeg，不碰 AVAssetReader/AVAssetImageGenerator——
// 家用机实测这类 AVFoundation 调用会永久挂死并拖垮 Swift 协作池（详见
// home_machine_decode_issue.md），这个功能逐帧吞吐量大、耗时长，
// 踩中同样的坑影响面更大，没必要冒这个险。
import Foundation

enum ClarityFrameIO {

    enum FrameIOError: Error, LocalizedError {
        case ffmpegNotFound
        case extractFailed(String)
        case encodeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:       return "找不到内置 ffmpeg"
            case .extractFailed(let d): return "抽帧失败：\(d)"
            case .encodeFailed(let d):  return "编码失败：\(d)"
            case .cancelled:            return "已取消"
            }
        }
    }

    /// 当前在跑的 ffmpeg 进程，供取消时 terminate（同 AudioSeparator.currentProcess 的模式）。
    /// 用数组而不是单个：管道式流水线会同时挂着解码和编码两个进程，取消时要一起杀，
    /// 漏掉任何一个都会留下一个卡在管道上读不到/写不出的孤儿进程。
    private static let processLock = NSLock()
    private static var _activeProcesses: [Process] = []

    static func register(_ p: Process) {
        processLock.lock(); defer { processLock.unlock() }
        _activeProcesses.append(p)
    }
    static func unregister(_ p: Process) {
        processLock.lock(); defer { processLock.unlock() }
        _activeProcesses.removeAll { $0 === p }
    }
    /// 最近注册的那个进程。保留这个属性是为了兼容既有调用方和测试里
    /// "取消后应该没有残留进程句柄"的断言语义
    static var currentProcess: Process? {
        processLock.lock(); defer { processLock.unlock() }
        return _activeProcesses.last
    }
    static func killCurrentProcess() {
        processLock.lock()
        let procs = _activeProcesses
        _activeProcesses.removeAll()
        processLock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    // MARK: - 管道式（rawvideo，全程不落盘）

    /// 源视频的像素尺寸。管道传的是裸字节流、没有任何头信息，收发两端必须
    /// 预先就 width/height/pixfmt 达成一致，所以这一步是管道方案的前提。
    nonisolated static func probeVideoSize(_ url: URL) throws -> (width: Int, height: Int) {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        // 用 ffmpeg 而不是 ffprobe：项目内置的只有 ffmpeg，ffprobe 不一定跟着打包。
        // ffmpeg 对着不存在的输出会把流信息打在 stderr 上然后以非零码退出，这是
        // 惯用做法，退出码在这里不代表失败。
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-nostdin", "-i", url.path]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        register(p)
        defer { unregister(p) }
        do { try p.run() } catch { throw FrameIOError.extractFailed(error.localizedDescription) }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: errData, encoding: .utf8) ?? ""
        // 形如 "Stream #0:0 ... 1920x1080 [SAR ...]"，取视频流那一行里的第一个 WxH
        for line in text.split(separator: "\n") where line.contains("Video:") {
            if let m = line.range(of: "[0-9]{2,5}x[0-9]{2,5}", options: .regularExpression) {
                let parts = line[m].split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                    return (w, h)
                }
            }
        }
        throw FrameIOError.extractFailed("读不出视频尺寸")
    }

    /// 启动解码进程：把裁剪范围按 frameRate 解成 rawvideo RGBA 字节流写到 stdout。
    /// 调用方负责按 width*height*4 一帧一帧读，读完后 waitUntilExit + unregister。
    nonisolated static func startRawDecode(url: URL, trimStart: Double, duration: Double,
                                           frameRate: Double) throws -> (process: Process, stdout: FileHandle) {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", duration), "-i", url.path]
        args += ["-vf", "fps=\(frameRate)"]
        args += ["-f", "rawvideo", "-pix_fmt", "rgba", "-"]
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        // stderr 必须丢弃而不是接管道：没人排空的话它写满就会把整个进程卡死，
        // 而这条流水线的两端都在阻塞式读写，卡住一端就是死锁
        p.standardError = FileHandle.nullDevice
        // 子进程不继承调用线程的 QoS，得单独降——否则 Swift 侧退到后台了，
        // ffmpeg 还在用默认优先级满负荷解码，照样跟交互抢核
        p.qualityOfService = .utility
        register(p)
        do { try p.run() } catch {
            unregister(p)
            throw FrameIOError.extractFailed(error.localizedDescription)
        }
        return (p, outPipe.fileHandleForReading)
    }

    /// 启动编码进程：从 stdin 收 rawvideo RGBA 字节流，配上源素材同一裁剪范围的
    /// 音轨，编码成 mp4。调用方写完所有帧后必须 closeFile() 让它看到 EOF。
    nonisolated static func startRawEncode(width: Int, height: Int, frameRate: Double,
                                           audioSourceURL: URL, audioTrimStart: Double,
                                           audioDuration: Double, outputURL: URL) throws
        -> (process: Process, stdin: FileHandle) {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        args += ["-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                 "-r", "\(frameRate)", "-i", "-"]
        if audioTrimStart > 0.001 { args += ["-ss", String(format: "%.6f", audioTrimStart)] }
        args += ["-t", String(format: "%.6f", audioDuration), "-i", audioSourceURL.path]
        args += ["-map", "0:v:0", "-map", "1:a:0?"]
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"]
        args += ["-c:a", "aac", "-shortest"]
        args += [outputURL.path]
        p.arguments = args
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice   // 同上，不能留给没人读的管道
        p.qualityOfService = .utility             // 同 startRawDecode
        register(p)
        do { try p.run() } catch {
            unregister(p)
            throw FrameIOError.encodeFailed(error.localizedDescription)
        }
        return (p, inPipe.fileHandleForWriting)
    }

    /// 从管道读满 exactly `count` 字节。管道的 read 不保证一次读满（尤其一帧
    /// 几十 MB 时必然被拆成多次），必须循环补齐；读到 0 字节说明对端 EOF。
    /// 返回 nil 表示流已经正常结束（读到的字节数不足一帧）。
    nonisolated static func readExactly(_ handle: FileHandle, count: Int) -> Data? {
        var buf = Data()
        buf.reserveCapacity(count)
        while buf.count < count {
            let chunk = handle.readData(ofLength: count - buf.count)
            if chunk.isEmpty { return buf.count == count ? buf : nil }
            buf.append(chunk)
        }
        return buf
    }
}
