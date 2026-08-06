// AppUpdater.swift
// 应用内更新：查 GitHub Releases → 下载 zip → 解压 → 替换自身 → 重启。
//
// 替换"正在运行的自己"是这件事最微妙的地方：进程占着 .app 目录时不能直接删。
// 做法是写一条 shell，用 detach 出去的独立进程执行，app 随即退出——脚本先等
// 进程真的没了，再做替换和重启。这样替换发生时已经没人占着那个目录了。
import Foundation
import AppKit

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// 版本清单来源。**必须是公开仓库**——app 里不能内嵌 token，而未认证访问
    /// 私有仓库 GitHub 会返回 404（故意不返回 403，避免泄露仓库是否存在）。
    /// 代码仓库 venico/BlackCat 是私有的，所以安装包发到公开的 blackcat-models，
    /// 那里本来就在托管模型，未认证访问实测 200。
    ///
    /// 用 /releases 列表而**不是** /releases/latest：那个接口返回的是「创建时间
    /// 最新的正式 release」，不管它是 app 还是模型包。同一个仓库里既有
    /// clarity-pro-v1 这类模型包又有 app 版本，发布顺序一变 latest 就指到模型包上，
    /// 更新检查直接失效而且不报任何错。改成拉列表、只认版本号形式的 tag，
    /// 两类 release 就能随便交替发，互不干扰
    private static let releasesAPI =
        "https://api.github.com/repos/venico/blackcat-models/releases?per_page=30"

    enum Phase: Equatable {
        case idle
        case checking
        case available(version: String)      // 有新版，等用户点
        case downloading(progress: Double)
        case installing
        case upToDate(String)   // 「已是最新」，几秒后自动消失
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 最新版本号和它的下载地址，检查通过后填上
    private var latestVersion: String?
    private var downloadURL: URL?
    private var downloadTask: Task<Void, Never>?

    /// 当前版本，从 Info.plist 读——不硬编码，免得跟打包版本对不上
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableVersion: String? {
        if case .available(let v) = phase { return v }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing, .checking: return true
        default: return false
        }
    }

    // MARK: - 版本比较

    /// 语义化版本比较。"v4.3.5" / "4.3.5" 都能吃，位数不同按缺位补 0
    /// （"4.4" 视为 "4.4.0"，所以 4.4 > 4.3.5）
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 这个 tag 是不是 app 版本号。只认纯版本号形式（v4.3.6 / 4.3.6），
    /// 模型包的 clarity-pro-v1 / fsrcnn-v1 这类一律排除——它们中间带连字符，
    /// 不符合「只由数字和点组成」
    nonisolated static func isAppVersionTag(_ tag: String) -> Bool {
        let t = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return t.range(of: "^[0-9]+(\\.[0-9]+)+$", options: .regularExpression) != nil
    }

    // MARK: - 检查

    /// 查一次最新版。silent = true 时不把「已是最新」当结果暴露出去
    /// （启动时的自动检查用，没更新就安安静静的）
    func check(silent: Bool = true) async {
        guard !isBusy else { return }
        phase = .checking
        do {
            var req = URLRequest(url: URL(string: Self.releasesAPI)!)
            req.setValue("BlackCat/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20

            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "AppUpdater", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "检查更新失败（HTTP \(http.statusCode)）"])
            }
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw NSError(domain: "AppUpdater", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "版本信息解析失败"])
            }
            // 过滤：草稿/预发布不推给用户；非版本号 tag（模型包）跳过。
            // 剩下的按版本号取最大的一个，不依赖发布时间顺序
            let candidates = list.filter { r in
                (r["draft"] as? Bool) != true
                    && (r["prerelease"] as? Bool) != true
                    && Self.isAppVersionTag((r["tag_name"] as? String) ?? "")
            }
            guard let newest = candidates.max(by: { a, b in
                Self.isNewer((b["tag_name"] as? String) ?? "", than: (a["tag_name"] as? String) ?? "")
            }), let tag = newest["tag_name"] as? String else {
                phase = .idle      // 仓库里还没有 app 版本，不算错
                return
            }
            let obj = newest
            guard Self.isNewer(tag, than: Self.currentVersion) else {
                phase = .idle
                return
            }
            // 找 .zip 资产。发布流程里资产名是 BlackCat-vX.Y.Z.zip
            let assets = obj["assets"] as? [[String: Any]] ?? []
            guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let urlString = zip["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                throw NSError(domain: "AppUpdater", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "这个版本没有可下载的安装包"])
            }
            latestVersion = tag
            downloadURL = url
            phase = .available(version: tag)
        } catch {
            phase = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: - 下载 + 安装

    func startUpdate() {
        guard case .available = phase, let url = downloadURL else { return }
        downloadTask = Task { await runUpdate(from: url) }
    }

    /// 关掉失败/已是最新的提示
    func dismissFailure() {
        switch phase {
        case .failed, .upToDate: phase = .idle
        default: break
        }
    }

    /// 菜单栏「检查更新」：主动查一次，没更新也要给回应，
    /// 否则用户点了没任何反馈，不知道是没更新还是坏了。
    /// 结果一律走 phase，不走通知——欢迎页在场时主界面是 opacity(0)，
    /// 挂在主界面上的 toast 会跟着被隐藏，用户就看不到任何反馈
    func checkFromMenu() {
        guard !isBusy else { return }
        Task {
            await check(silent: false)
            if case .idle = phase {
                phase = .upToDate("当前已是最新版本 V \(Self.currentVersion)")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .upToDate = phase { phase = .idle }
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        // 回到「有可用更新」，用户还能再点一次
        if let v = latestVersion {
            phase = .available(version: v)
        } else {
            phase = .idle
        }
    }

    private func runUpdate(from url: URL) async {
        phase = .downloading(progress: 0)
        do {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blackcat-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let zipURL = workDir.appendingPathComponent("update.zip")
            try await download(url, to: zipURL) { [weak self] p in
                Task { @MainActor in
                    guard let self, !Task.isCancelled else { return }
                    if case .downloading = self.phase { self.phase = .downloading(progress: p) }
                }
            }
            try Task.checkCancellation()

            phase = .installing
            let unpacked = workDir.appendingPathComponent("unpacked")
            try unzip(zipURL, to: unpacked)

            guard let newApp = try findApp(in: unpacked) else {
                throw NSError(domain: "AppUpdater", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "安装包里没有找到应用"])
            }
            try Task.checkCancellation()
            try installAndRelaunch(newApp: newApp)
            // 到这一步脚本已经接管，进程即将退出
        } catch is CancellationError {
            cancel()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to dest: URL,
                          onProgress: @escaping (Double) -> Void) async throws {
        var req = URLRequest(url: url)
        req.setValue("BlackCat/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 600

        // 用 download(for:delegate:) 而不是 bytes(for:) 逐字节遍历。
        // AsyncBytes 是**一个字节一个字节**吐的，65MB 的包就是 6800 万次
        // 循环迭代加 Data.append，慢到没法用；download 走的是系统的分块写盘路径，
        // 进度由 delegate 回调给出。
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (tmp, resp) = try await URLSession.shared.download(for: req, delegate: delegate)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "AppUpdater", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \(http.statusCode)）"])
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onProgress(1)
    }

    private func unzip(_ archive: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dest.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "AppUpdater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "解压失败：\(detail)"])
        }
    }

    private func findApp(in dir: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // zip 里可能多包了一层目录
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let found = try findApp(in: sub) { return found }
        }
        return nil
    }

    /// 替换自身并重启。
    /// 关键点：占着 .app 目录的是**当前进程**，自己删自己会失败。所以把替换动作
    /// 交给一条 detach 出去的 shell——它先自旋等这个 pid 消失，再动文件。
    private func installAndRelaunch(newApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        // 先验一下能不能写，不能写就别退出 app，直接报错让用户知道
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw NSError(domain: "AppUpdater", code: -4, userInfo: [
                NSLocalizedDescriptionKey:
                    "没有写入权限，无法自动更新。请手动把新版本拖到 \(parent.path)"
            ])
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # 等当前进程真的退出，最多等 30 秒——不等就删会失败（目录还被占着）
        for _ in $(seq 1 300); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.1
        done
        rm -rf "\(currentApp.path)"
        mv "\(newApp.path)" "\(currentApp.path)"
        xattr -dr com.apple.quarantine "\(currentApp.path)" 2>/dev/null
        open "\(currentApp.path)"
        """
        let scriptURL = newApp.deletingLastPathComponent()
            .appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()   // 不 wait：它要活到本进程退出之后

        NSApp.terminate(nil)
    }
}

/// 下载进度回调。URLSession 的 async download 只有加 delegate 才拿得到进度
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// 协议要求实现。文件的落地由 download(for:delegate:) 自己接管，这里不用做事
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
