import Foundation
import AVFoundation

/// 画布上的视频处理：裁剪 / 镜像 / 旋转（v5.1.0，B5）
///
/// 图片那三个是逐像素改，视频得**整段重编码**，所以走 ffmpeg 滤镜。
/// 用的是 app 自带那个 ffmpeg（`ProjectState.findFFmpeg()`），跟导入转码同一个。
enum CanvasVideoOps {

    enum OpError: LocalizedError {
        case ffmpegMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "找不到 ffmpeg"
            case .failed(let s): return s
            }
        }
    }

    /// 按相对矩形（0~1，原点左上）裁剪
    static func crop(_ url: URL, to rel: CGRect) async throws -> URL {
        // crop 的参数要整数像素，且必须是偶数 —— 编码器不收奇数边长
        let filter = "crop=trunc(iw*\(fmt(rel.width))/2)*2:trunc(ih*\(fmt(rel.height))/2)*2"
            + ":trunc(iw*\(fmt(rel.minX))/2)*2:trunc(ih*\(fmt(rel.minY))/2)*2"
        return try await run(url, filter: filter, suffix: "_裁剪")
    }

    static func mirror(_ url: URL, vertical: Bool) async throws -> URL {
        try await run(url, filter: vertical ? "vflip" : "hflip",
                      suffix: vertical ? "_垂直镜像" : "_水平镜像")
    }

    /// 顺时针 90°。`transpose=1` 就是顺时针转
    static func rotate90(_ url: URL) async throws -> URL {
        try await run(url, filter: "transpose=1", suffix: "_旋转")
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.4f", v) }

    private static func run(_ url: URL, filter: String, suffix: String) async throws -> URL {
        guard let ffmpeg = ProjectState.findFFmpeg() else { throw OpError.ffmpegMissing }
        let dest = CanvasImageOps.outputURL(basedOn: url, suffix: suffix,
                                            ext: url.pathExtension.isEmpty ? "mp4" : url.pathExtension)

        return try await withCheckedThrowingContinuation { cont in
            // 放后台线程跑：ffmpeg 是阻塞等待，占着主线程整个界面就卡住了
            Thread.detachNewThread {
                let p = Process()
                p.executableURL = ffmpeg
                p.arguments = [
                    "-y", "-i", url.path,
                    "-vf", filter,
                    // 音频直接拷贝，只重编码画面
                    "-c:a", "copy",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                    "-pix_fmt", "yuv420p",
                    dest.path,
                ]
                // stderr 必须排空或丢掉 —— 留给没人读的管道，写满 ffmpeg 就卡死
                p.standardError = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    if p.terminationStatus == 0,
                       FileManager.default.fileExists(atPath: dest.path) {
                        cont.resume(returning: dest)
                    } else {
                        cont.resume(throwing: OpError.failed("ffmpeg 退出码 \(p.terminationStatus)"))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
