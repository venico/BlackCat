// CoreMLModelDownloader.swift
// 按需下载 CoreML 模型的共用实现：GitHub release 上的 .mlmodelc.zip
// → 下载 → 校验体积 → ditto 解压 → 落到 Application Support。
//
// 从 ClarityModel 里抽出来的，原样保留它的行为（含逐字节读取报进度、
// 多镜像依次重试、解压到临时目录再整体搬过去）。抽出来是因为
// ClarityProModel 要走完全相同的流程，没必要再抄一份两百行。
import Foundation

enum CoreMLModelDownloader {

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

    /// 依次尝试每个源，任一成功即返回；全失败则抛最后一个错误
    static func download(sourceURLs: [String], fileName: String, destDir: URL,
                         minFileSize: Int,
                         onProgress: @escaping (Double) -> Void) async throws {
        guard !sourceURLs.isEmpty else { throw DownloadError.noSource }
        var lastError: Error = DownloadError.noSource
        for urlString in sourceURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                try await downloadOne(url, fileName: fileName, destDir: destDir,
                                      minFileSize: minFileSize, onProgress: onProgress)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private static func downloadOne(_ url: URL, fileName: String, destDir: URL,
                                    minFileSize: Int,
                                    onProgress: @escaping (Double) -> Void) async throws {
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

        let archiveName = "\(fileName).zip"
        let tmpZip = destDir.appendingPathComponent("\(archiveName).part")
        try? FileManager.default.removeItem(at: tmpZip)
        try data.write(to: tmpZip)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        // 先解到临时目录，确认里面确实有要的东西再整体搬走——直接解到目标位置的话，
        // 半路失败会留下一个残缺的 .mlmodelc，之后 isDownloaded 判定为真但加载会崩
        let staging = destDir.appendingPathComponent("unzip-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try unzip(tmpZip, to: staging)

        let extracted = staging.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw DownloadError.unpackFailed("压缩包里没有 \(fileName)")
        }
        let localURL = destDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: extracted, to: localURL)
        onProgress(1.0)
    }

    private static func unzip(_ archive: URL, to dest: URL) throws {
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
}
