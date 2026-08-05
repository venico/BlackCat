// BiRefNetModel.swift
// BiRefNet 抠图模型的下载与管理。跟 whisper / demucs 同一套路子：
// 模型不打进安装包，用户选用时才下到 Application Support。
import Foundation

enum BiRefNetModel: String, CaseIterable, Identifiable {
    case lite
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lite: return "BiRefNet Lite"
        case .full: return "BiRefNet"
        }
    }

    /// 设置卡片上的功能名。不叫 BiRefNet Lite/BiRefNet ——用户要判断的是
    /// "我要快还是要细"，不是这俩模型叫什么。组件名进 infoText
    var featureName: String {
        switch self {
        case .lite: return "快速模式"
        case .full: return "精细模式"
        }
    }

    /// 卡片副标题：只说效果差别，不提模型名和体积
    var featureDetail: String {
        switch self {
        case .lite: return "速度快，细小饰品可能丢失"
        case .full: return "发钗流苏这类细节更完整"
        }
    }

    /// ⓘ 气泡：想深究的人才看的实现细节
    var infoText: String {
        switch self {
        case .lite: return "使用 BiRefNet Lite（Swin-Tiny），约 78 MB"
        case .full: return "使用 BiRefNet（Swin-Large），约 388 MB"
        }
    }

    var sizeDesc: String {
        switch self {
        case .lite: return "78 MB · Swin-Tiny，速度快，细小饰品可能丢失"
        case .full: return "388 MB · Swin-Large，发钗流苏这类细节更完整"
        }
    }

    /// 解压后的模型目录名
    var fileName: String {
        switch self {
        case .lite: return "BiRefNet_lite.mlmodelc"
        case .full: return "BiRefNet.mlmodelc"
        }
    }

    /// 下载的是压缩包 —— mlmodelc 是目录，没法单文件传
    var archiveName: String { "\(fileName).zip" }

    /// 下载源。模型托管在独立的公开仓库，主仓库是私有的，release 地址对外取不到
    var sourceURLs: [String] {
        switch self {
        case .lite:
            return ["https://github.com/venico/blackcat-models/releases/download/birefnet-v1/BiRefNet_lite.mlmodelc.zip"]
        case .full:
            return ["https://github.com/venico/blackcat-models/releases/download/birefnet-v1/BiRefNet.mlmodelc.zip"]
        }
    }

    /// 压缩包至少该有这么大，用来识别半截文件或错误页面
    var minFileSize: Int {
        switch self {
        case .lite: return 50_000_000
        case .full: return 250_000_000
        }
    }

    var isAvailableForDownload: Bool { !sourceURLs.isEmpty }

    // MARK: - 存放位置

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/birefnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localURL: URL { Self.supportDir.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    // MARK: - 下载

    enum DownloadError: Error, LocalizedError {
        case noSource
        case badResponse(Int)
        case tooSmall
        case unpackFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSource:             return "该模型暂无可用下载源"
            case .badResponse(let c):   return "下载失败（HTTP \(c)）"
            case .tooSmall:             return "下载的文件不完整，请重试"
            case .unpackFailed(let d):  return "解压失败：\(d)"
            }
        }
    }

    /// 逐个源尝试下载，任一成功即返回
    func download(onProgress: @escaping (Double) -> Void) async throws {
        guard !sourceURLs.isEmpty else { throw DownloadError.noSource }

        var lastError: Error = DownloadError.noSource
        for urlString in sourceURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                try await downloadOne(url, onProgress: onProgress)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func downloadOne(_ url: URL, onProgress: @escaping (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("BlackCat/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.badResponse(http.statusCode)
        }
        let total = response.expectedContentLength

        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 1 << 20)
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if total > 0 {
                let pct = Double(data.count) / Double(total)
                // 回调节流，别把主线程刷爆
                if pct - lastReported >= 0.01 {
                    lastReported = pct
                    onProgress(pct)
                }
            }
        }
        guard data.count >= minFileSize else { throw DownloadError.tooSmall }

        // 先落临时压缩包再解压，中途失败不会留下一个看着像下好了的残包
        let tmpZip = Self.supportDir.appendingPathComponent("\(archiveName).part")
        try? FileManager.default.removeItem(at: tmpZip)
        try data.write(to: tmpZip)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let staging = Self.supportDir.appendingPathComponent("unzip-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try unzip(tmpZip, to: staging)

        // 包里就是 .mlmodelc 目录本身
        let extracted = staging.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw DownloadError.unpackFailed("压缩包里没有 \(fileName)")
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: extracted, to: localURL)
        onProgress(1.0)
    }

    /// 用系统 ditto 解压。Foundation 没有现成的解压 API，ditto 比 unzip 更稳当地保留目录结构
    private func unzip(_ archive: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dest.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw DownloadError.unpackFailed(error.localizedDescription)
        }
        let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DownloadError.unpackFailed(detail.isEmpty ? "ditto 退出码 \(p.terminationStatus)" : detail)
        }
    }

    func delete() throws {
        guard isDownloaded else { return }
        try FileManager.default.removeItem(at: localURL)
    }
}
