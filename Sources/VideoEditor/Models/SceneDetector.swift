import Foundation

enum SceneDetector {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/scenedetect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var pythonURL: URL { supportDir.appendingPathComponent("python/bin/python3") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: pythonURL.path) }

    static let componentSize = "~80 MB"
    static let minFileSize = 10_000_000

    static let downloadURLs: [String] = [
        "https://github.com/venico/BlackCat/releases/download/scenedetect/scenedetect-macos.zip"
    ]

    static func download(progress: @escaping (Double) -> Void) async throws {
        let zipDest = supportDir.appendingPathComponent("scenedetect-macos.zip")
        var lastError: Error?
        for src in downloadURLs {
            guard let url = URL(string: src) else { continue }
            do {
                try await downloadFile(url, to: zipDest, progress: { p in progress(p * 0.8) })
                let attrs = try? FileManager.default.attributesOfItem(atPath: zipDest.path)
                let size = (attrs?[.size] as? Int) ?? 0
                guard size > minFileSize else {
                    try? FileManager.default.removeItem(at: zipDest)
                    lastError = NSError(domain: "SceneDetect", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "下载文件不完整"])
                    continue
                }
                progress(0.85)
                try unzip(zipDest, to: supportDir)
                try? FileManager.default.removeItem(at: zipDest)
                progress(1.0)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: zipDest)
            }
        }
        throw lastError ?? NSError(domain: "SceneDetect", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    static func detect(videoURL: URL, threshold: Double = 27.0,
                        progress: @escaping (Double) -> Void = { _ in }) async throws -> [Double] {
        guard isInstalled else { throw NSError(domain: "SceneDetect", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "未安装视频分析组件，请在设置中下载"]) }

        let csvDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenedetect_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: csvDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: csvDir) }

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [
            "-m", "scenedetect",
            "-i", videoURL.path,
            "detect-content", "-t", String(format: "%.1f", threshold),
            "list-scenes", "-o", csvDir.path, "-f", "scenes.csv"
        ]
        proc.environment = [
            "PATH": supportDir.appendingPathComponent("python/bin").path + ":/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "PYTHONUNBUFFERED": "1"
        ]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()

        let errHandle = errPipe.fileHandleForReading
        var errData = Data()
        let readQueue = DispatchQueue(label: "scenedetect.stderr")
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            readQueue.async {
                errData.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) {
                    let pattern = #"(\d+)%\|"#
                    if let range = text.range(of: pattern, options: .regularExpression),
                       let pct = Int(text[range].dropLast(2)) {
                        DispatchQueue.main.async { progress(min(Double(pct) / 100.0, 0.99)) }
                    }
                }
            }
        }

        proc.waitUntilExit()
        errHandle.readabilityHandler = nil

        guard proc.terminationStatus == 0 else {
            let output = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "SceneDetect", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "分析失败: \(output.prefix(200))"])
        }

        progress(1.0)

        let csvFile = csvDir.appendingPathComponent("scenes.csv")
        guard let csvData = try? String(contentsOf: csvFile, encoding: .utf8) else { return [] }

        var cutPoints: [Double] = []
        let lines = csvData.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i < 2 { continue }
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 4 else { continue }
            let startTimeSec = cols[3].trimmingCharacters(in: .whitespaces)
            if let t = Double(startTimeSec), t > 0.01 {
                cutPoints.append(t)
            }
        }
        return cutPoints
    }

    private static func unzip(_ zipURL: URL, to destDir: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", zipURL.path, "-d", destDir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "SceneDetect", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "解压失败"])
        }
    }

    private static func downloadFile(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let delegate = DownloadDelegate(dest: dest, progress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            task.resume()
        }
    }

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?

        init(dest: URL, progress: @escaping (Double) -> Void) {
            self.dest = dest
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 {
                DispatchQueue.main.async { self.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }
}
