// ClarityModel.swift
// FSRCNN 清晰度提升模型的下载与管理。跟 BiRefNet 同一套路子：
// 模型不打进安装包，用户用到时才下到 Application Support。
import Foundation

enum ClarityModel: String, CaseIterable, Identifiable {
    case x2
    case x4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .x2: return "FSRCNN x2"
        case .x4: return "FSRCNN x4"
        }
    }

    var sizeDesc: String {
        switch self {
        case .x2: return "约 20 KB · 放大 2 倍"
        case .x4: return "约 20 KB · 放大 4 倍"
        }
    }

    var fileName: String {
        switch self {
        case .x2: return "FSRCNN_x2.mlmodelc"
        case .x4: return "FSRCNN_x4.mlmodelc"
        }
    }

    var archiveName: String { "\(fileName).zip" }

    var sourceURLs: [String] {
        switch self {
        case .x2:
            return ["https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x2.mlmodelc.zip"]
        case .x4:
            return ["https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x4.mlmodelc.zip"]
        }
    }

    // FSRCNN 模型极小（~50KB 量级），跟 Real-ESRGAN/BiRefNet 那种几十上百 MB
    // 完全不是一个量级——minFileSize 只是用来防止下载到一个空文件/错误页面，
    // 不是防止"文件不完整"（那种检验对这么小的文件意义不大）。Task 4 打包后
    // 用实际 zip 体积的一半左右做阈值，具体数字在实现时对照 Task 4 的真实产出调整。
    var minFileSize: Int { 10_000 }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/clarity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localURL: URL { Self.supportDir.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    /// 下载相关的错误类型统一在 CoreMLModelDownloader 里。这个别名留着是因为
    /// 既有调用方和测试都在用 ClarityModel.DownloadError 这个名字
    typealias DownloadError = CoreMLModelDownloader.DownloadError

    func download(onProgress: @escaping (Double) -> Void) async throws {
        try await CoreMLModelDownloader.download(
            sourceURLs: sourceURLs, fileName: fileName, destDir: Self.supportDir,
            minFileSize: minFileSize, onProgress: onProgress)
    }

    func delete() throws {
        guard isDownloaded else { return }
        try FileManager.default.removeItem(at: localURL)
    }
}
