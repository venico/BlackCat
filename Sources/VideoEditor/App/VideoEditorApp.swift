import SwiftUI
import AppKit
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var isCleaningMenus = false
    private var cleanupTimer: Timer?
    /// Finder 双击 bcj 文件时暂存 URL，等 view 就绪后再打开
    public static var pendingOpenURL: URL?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        createWindow()

        // 系统会在启动后异步注入菜单项，用定时器持续清理
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            self?.cleanupSystemItems()
        }
        // 10 秒后停止定时器（系统注入早已完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.cleanupTimer?.invalidate()
            self?.cleanupTimer = nil
        }
    }

    // MARK: - 窗口

    private func createWindow() {
        let contentView = ContentView()
        let hostingView = NSHostingView(rootView: contentView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 1280, height: 780))
        window.minSize = NSSize(width: 1100, height: 680)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        window.tabbingMode = .disallowed
        window.center()

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 菜单栏

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // ── 黑猫剪辑 ──
        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 黑猫剪辑", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 黑猫剪辑", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 黑猫剪辑", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)

        // ── 文件 ──
        let fileMenu = NSMenu(title: "文件")
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "新建项目…", action: #selector(newProject), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "打开项目…", action: #selector(openProjectFile), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "保存", action: #selector(saveProject), keyEquivalent: "s"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "导入素材…", action: #selector(importMedia), keyEquivalent: "i"))
        fileMenu.addItem(NSMenuItem(title: "导出…", action: #selector(exportMedia), keyEquivalent: "e"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(fileItem)

        // ── 编辑 ──
        let editMenu = NSMenu(title: "编辑")
        editMenu.delegate = self  // 每次打开前清理
        let editItem = NSMenuItem(); editItem.submenu = editMenu
        let undoItem = NSMenuItem(title: "撤销", action: #selector(doUndo), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "重做", action: #selector(doRedo), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)

        // ── 显示 ──
        let viewMenu = NSMenu(title: "显示")
        viewMenu.delegate = self  // 每次打开前清理
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu
        let fullScreen = NSMenuItem(title: "进入全屏幕", action: #selector(doToggleFullScreen), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        mainMenu.addItem(viewItem)

        // ── 窗口 ──
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.delegate = self
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - NSMenuDelegate — 菜单打开前清理

    public func menuNeedsUpdate(_ menu: NSMenu) {
        cleanupMenu(menu)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        cleanupMenu(menu)
    }

    // MARK: - 清理系统注入项

    /// 清理所有菜单中系统注入的英文项
    private func cleanupSystemItems() {
        guard !isCleaningMenus else { return }
        isCleaningMenus = true
        defer { isCleaningMenus = false }

        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let menu = item.submenu {
                cleanupMenu(menu)
            }
        }
    }

    /// 清理单个菜单
    private func cleanupMenu(_ menu: NSMenu) {
        // 需要删除的系统项
        let removeSet: Set<String> = [
            "AutoFill", "自动填充",
            "Start Dictation…", "Start Dictation...", "开始听写…",
            "Emoji & Symbols", "表情与符号",
            "Transformations", "转换",
            "Speech", "语音",
            "Substitutions", "替换",
            "Spelling and Grammar", "拼写和语法",
        ]

        // 翻译表
        let translate: [String: String] = [
            "Undo": "撤销", "Redo": "重做",
            "Cut": "剪切", "Copy": "拷贝", "Paste": "粘贴",
            "Delete": "删除", "Select All": "全选",
            "Enter Full Screen": "进入全屏幕", "Exit Full Screen": "退出全屏幕",
            "Show Tab Bar": "显示标签栏", "Hide Tab Bar": "隐藏标签栏",
            "Show All Tabs": "显示所有标签页",
            "Minimize": "最小化", "Zoom": "缩放",
            "Fill": "填充", "Center": "居中",
            "Move & Resize": "移动和调整大小",
            "Full Screen Tile": "全屏幕拼贴",
            "Remove Window from Set": "从集合中移除窗口",
            "Bring All to Front": "前置全部窗口",
        ]

        // 1) 删除不需要的项
        menu.items.removeAll { removeSet.contains($0.title) }

        // 2) 翻译
        for item in menu.items {
            if let cn = translate[item.title] { item.title = cn }
            // 按 action selector 强制翻译系统注入项
            let sel = item.action?.description ?? ""
            if sel == "undo:" && item.title != "撤销" { item.title = "撤销" }
            if sel == "redo:" && item.title != "重做" { item.title = "重做" }
            if sel == "toggleFullScreen:" && !item.title.hasSuffix("全屏幕") {
                item.title = "进入全屏幕"
            }
            // 前缀匹配兜底
            if item.title.hasPrefix("Undo") { item.title = "撤销" }
            if item.title.hasPrefix("Redo") { item.title = "重做" }
            if item.title.hasPrefix("Enter Full Screen") { item.title = "进入全屏幕" }
            if item.title.hasPrefix("Exit Full Screen") { item.title = "退出全屏幕" }
            if item.title.hasPrefix("Move to ") {
                item.title = "移动到 " + item.title.dropFirst(8)
            }
            if let sub = item.submenu { cleanupMenu(sub) }
        }

        // 3) 去重
        var seen: Set<String> = []
        menu.items.removeAll { item in
            let key: String?
            switch item.title {
            case "撤销": key = "undo"
            case "重做": key = "redo"
            case "进入全屏幕", "退出全屏幕": key = "fullscreen"
            case "最小化": key = "minimize"
            case "缩放": key = "zoom"
            case "前置全部窗口": key = "bringToFront"
            default: key = nil
            }
            if let k = key {
                if seen.contains(k) { return true }
                seen.insert(k)
            }
            return false
        }

        // 4) 清理多余分隔线
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    // MARK: - 菜单动作

    @objc private func doUndo() {
        NSApp.keyWindow?.undoManager?.undo()
    }

    @objc private func doRedo() {
        NSApp.keyWindow?.undoManager?.redo()
    }

    @objc private func doToggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    @objc private func newProject() {
        NotificationCenter.default.post(name: .menuNewProject, object: nil)
    }

    @objc private func openProjectFile() {
        NotificationCenter.default.post(name: .menuOpenProject, object: nil)
    }

    @objc private func saveProject() {
        NotificationCenter.default.post(name: .menuSaveProject, object: nil)
    }

    @objc private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []  // 不限制，由 importFile 做格式过滤
        panel.begin { r in
            guard r == .OK else { return }
            NotificationCenter.default.post(name: .menuImportFiles, object: panel.urls)
        }
    }

    @objc private func exportMedia() {
        NotificationCenter.default.post(name: .menuExportVideo, object: nil)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "黑猫剪辑",
            .applicationVersion: "3.5.1",
            .version: "",
            .credits: NSAttributedString(string: "")
        ])
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 处理 Finder 双击 .bcj 文件打开
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "bcj" {
                AppDelegate.pendingOpenURL = url
                NotificationCenter.default.post(name: .menuOpenProjectFile, object: url)
                break
            }
        }
    }
}

extension Notification.Name {
    static let menuImportFiles = Notification.Name("menuImportFiles")
    static let menuExportVideo = Notification.Name("menuExportVideo")
    static let menuNewProject  = Notification.Name("menuNewProject")
    static let menuOpenProject = Notification.Name("menuOpenProject")
    static let menuSaveProject   = Notification.Name("menuSaveProject")
    static let menuOpenProjectFile = Notification.Name("menuOpenProjectFile")
    static let togglePlayback    = Notification.Name("togglePlayback")
}
