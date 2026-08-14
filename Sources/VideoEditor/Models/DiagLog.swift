import Foundation

/// 诊断日志：NSLog 之外同时写文件。
/// SPM debug 构建的 NSLog 走 stderr，用 `open` 启动的 app 拿不到输出（见交接文档注意事项 13），
/// 家用机排查只能靠日志文件：~/Library/Application Support/黑猫剪辑/logs/诊断日志.txt
/// 同步写 + NSLock：不依赖 GCD —— 挂起机器上 GCD 全局池会被挂死的 AVFoundation 调用占满，
/// 排进池里的日志任务永远不执行
enum DiagLog {
    private static let lock = NSLock()
    private static var headerWritten = false

    /// 是否跑在单元测试进程里。
    ///
    /// 测试环境没有人去点弹框的「确定」，`NSAlert.runModal()` / `NSSavePanel.runModal()`
    /// 会**永久阻塞主线程**，整套测试从此跑不完。而且现象极具迷惑性——卡住的位置显示为
    /// 前一条用例，实际元凶是按字母序排在后面的那条（`testPM005_OpenNonExistentProject`
    /// 曾被误记为「卡在 testIN008_ImagePosition 附近」，白排查了很久）。
    ///
    /// 所以模型层凡是会弹模态的地方都要过一道这个判断：测试环境下改为写诊断日志，
    /// 确认类弹框一律按「取消」处理（宁可不执行，也不能在无人值守时做破坏性操作）。
    /// 生产环境行为完全不变。
    static let isUnitTesting = NSClassFromString("XCTestCase") != nil

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("诊断日志.txt")
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        NSLog("%@", message)
        lock.lock()
        defer { lock.unlock() }
        var text = ""
        if !headerWritten {
            headerWritten = true
            text += "\n===== 启动 " + startupInfo() + " =====\n"
        }
        text += timeFormatter.string(from: Date()) + " " + message + "\n"
        append(text)
    }

    /// 版本 + 系统 + 二进制修改时间，用于确认日志出自哪个构建
    private static func startupInfo() -> String {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var build = "未知构建时间"
        if let exe = Bundle.main.executablePath,
           let date = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date {
            build = "构建于 " + timeFormatter.string(from: date)
        }
        return "v\(ver) macOS \(os) \(build) \(timeFormatter.string(from: Date()))"
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        // 超过 2MB 从头再来，避免无限膨胀
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(at: fileURL)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
