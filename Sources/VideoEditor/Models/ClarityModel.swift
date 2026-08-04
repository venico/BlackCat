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
                if pct - lastReported >= 0.01 {
                    lastReported = pct
                    onProgress(pct)
                }
            }
        }
        guard data.count >= minFileSize else { throw DownloadError.tooSmall }

        let tmpZip = Self.supportDir.appendingPathComponent("\(archiveName).part")
        try? FileManager.default.removeItem(at: tmpZip)
        try data.write(to: tmpZip)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let staging = Self.supportDir.appendingPathComponent("unzip-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try unzip(tmpZip, to: staging)

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
