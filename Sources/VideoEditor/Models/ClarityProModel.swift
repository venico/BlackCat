// ClarityProModel.swift
// 清晰度提升的高质量本地模型（Real-ESRGAN 轻量分支 / Real-CUGAN）。
//
// 跟 ClarityModel（FSRCNN）分开定义，因为两者的推理接口根本不同：
// FSRCNN 吃单通道 Y（只超分亮度，色度靠插值），这三个吃 RGB 三通道整图。
// 硬塞进同一个枚举会让推理侧到处 if-else，不如分成两类各自清晰。
//
// 下载/解压/删除的流程跟 ClarityModel 一致（GitHub release 上的 .mlmodelc.zip
// → Application Support），代码走 DownloadableCoreMLModel 协议的默认实现。
import Foundation

enum ClarityProModel: String, CaseIterable, Identifiable {
    case generalX4V3     // realesr-general-x4v3：实拍素材通用
    case animeVideoV3    // realesr-animevideov3：动漫视频，速度优先
    case realCUGAN2x     // Real-CUGAN up2x：动漫，质量优先，2 倍
    case realCUGAN       // Real-CUGAN up4x：动漫，质量优先，4 倍

    var id: String { rawValue }

    /// 这个模型放大几倍。Real-ESRGAN 的两个轻量分支上游只发布了 x4 权重，
    /// Real-CUGAN 官方有 up2x/up3x/up4x，这里取了 2 和 4 两档
    var scale: Int {
        switch self {
        case .realCUGAN2x: return 2
        case .generalX4V3, .animeVideoV3, .realCUGAN: return 4
        }
    }

    /// 卡片标题。按用户视角写场景，不写模型代号（组件名放 infoText 里）
    var displayName: String {
        switch self {
        case .generalX4V3:  return "实拍素材增强"
        case .animeVideoV3: return "动漫增强（快）"
        case .realCUGAN2x:  return "动漫增强（质量优先）· 2 倍"
        case .realCUGAN:    return "动漫增强（质量优先）· 4 倍"
        }
    }

    var detail: String {
        switch self {
        case .generalX4V3:  return "放大 4 倍，适合真人拍摄、纪录片、老录像"
        case .animeVideoV3: return "放大 4 倍，适合动画片、二次元视频，速度最快"
        case .realCUGAN2x:  return "放大 2 倍，线条更锐利、保留景深虚化，带轻度降噪"
        case .realCUGAN:    return "放大 4 倍，线条更锐利、保留景深虚化，带轻度降噪"
        }
    }

    /// ⓘ 气泡：组件名 + 体积 + 实测速度。给想深究的人看
    var infoText: String {
        switch self {
        case .generalX4V3:
            return "Real-ESRGAN general-x4v3 模型，约 2.2 MB。实测 21 ms/图块"
        case .animeVideoV3:
            return "Real-ESRGAN animevideov3 模型，约 1.1 MB。实测 13 ms/图块"
        case .realCUGAN2x:
            return "Real-CUGAN up2x denoise1x 模型，约 2.3 MB。实测 17 ms/图块"
        case .realCUGAN:
            return "Real-CUGAN up4x 模型，约 2.5 MB。实测 24 ms/图块"
        }
    }

    var fileName: String {
        switch self {
        case .generalX4V3:  return "RealESRGAN_general_x4v3.mlmodelc"
        case .animeVideoV3: return "RealESRGAN_animevideo_x4v3.mlmodelc"
        case .realCUGAN2x:  return "RealCUGAN_up2x.mlmodelc"
        case .realCUGAN:    return "RealCUGAN_up4x.mlmodelc"
        }
    }

    var sourceURLs: [String] {
        ["https://github.com/venico/blackcat-models/releases/download/clarity-pro-v1/\(fileName).zip"]
    }

    /// 最小的 zip 是 animevideo 的 1.1 MB。阈值取它的一半，够挡住下载到错误页
    /// 或空文件的情况，又不会误伤正常下载
    var minFileSize: Int { 500_000 }

    /// 跟 FSRCNN 放同一个目录下：都是清晰度提升用的模型，用户点"打开文件夹"
    /// 时看到的是一处而不是两处
    static var supportDir: URL { ClarityModel.supportDir }

    var localURL: URL { Self.supportDir.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

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
