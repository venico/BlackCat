// WindowManager.swift
// 多窗口支持：一个项目一个窗口，像 Sketch / Xcode 那样。
//
// 架构上本来就走得通——ProjectState 是 ContentView 里的 @StateObject，
// 每个视图实例天然一份，多开几个窗口就是多份互不干扰的项目状态。
// 真正要解决的是**菜单命令的路由**：原来 7 个菜单项都是
// NotificationCenter 广播，多窗口下按一次「保存」会把所有打开的项目都存一遍。
// 现在通知一律带上目标窗口的 id，ContentView 只认自己那份。
import AppKit
import SwiftUI

/// 每个窗口一个 id，用来把菜单命令投递到正确的那个窗口
struct WindowID: Hashable {
    let raw = UUID()
}

private struct WindowIDKey: EnvironmentKey {
    static let defaultValue = WindowID()
}

extension EnvironmentValues {
    /// 当前视图属于哪个窗口。ContentView 靠它过滤菜单通知
    var windowID: WindowID {
        get { self[WindowIDKey.self] }
        set { self[WindowIDKey.self] = newValue }
    }
}

/// 系统 sheet 的圆角。**实测值**，不是估的：弹一个系统 sheet 之后读
/// SheetPresentationWindow 的 _cornerRadius，macOS 26 上是 26、cornerCurve 是 circular
/// （SwiftUI 的 RoundedRectangle 默认就是 circular，不用额外指定 style）。
/// 窗口内的新建走系统 sheet，这里自绘，圆角对不上一眼就能看出来
private let kSheetCornerRadius: CGFloat = 26

@MainActor
final class WindowManager: NSObject {
    static let shared = WindowManager()

    private var windows: [WindowID: NSWindow] = [:]
    /// 开窗顺序。Dictionary 无序，级联摆位要知道"上一个窗口"是哪个
    private var order: [WindowID] = []

    /// 当前接受菜单命令的窗口。取 keyWindow，没有 key 的（比如刚被
    /// 系统菜单夺走焦点）退回最后一个 main window
    var activeWindowID: WindowID? {
        if let key = NSApp.keyWindow, let id = id(of: key) { return id }
        if let main = NSApp.mainWindow, let id = id(of: main) { return id }
        return windows.keys.first
    }

    private func id(of window: NSWindow) -> WindowID? {
        windows.first(where: { $0.value === window })?.key
    }

    var windowCount: Int { windows.count }

    /// 开一个新窗口。openURL 非空时窗口起来后直接打开那个项目，
    /// 否则停在欢迎页
    @discardableResult
    func newWindow(_ action: ContentView.InitialAction? = nil) -> WindowID {
        let id = WindowID()
        let root = ContentView(initialAction: action)
            .environment(\.windowID, id)
        // GatedHostingView 见 WindowDragGate.swift：预览区铺到窗口顶端，
        // 落在那儿的裁剪手柄按下去会被当成拖窗口
        let hosting = GatedHostingView(rootView: root)
        // 宿主统一接收 Finder 拖进来的文件，按窗口找接收区（见 FileDropRouter）
        hosting.windowID = id

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 窗口属性全部先配好，**最后**才挂 contentView。
        // 挂 contentView 会立刻触发 SwiftUI 的 onAppear，欢迎页在那里调
        // WelcomeWindowSizer.shrink 把窗口缩到 900×560 并改 minSize；
        // 要是 setContentSize / minSize 排在它后面，就会把缩放结果覆盖掉
        window.setContentSize(NSSize(width: 1280, height: 780))
        window.minSize = NSSize(width: 1100, height: 680)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        // 底色交给系统材质（见 VisualEffectBackground.swift），窗口自身必须透明，
        // 否则会盖住材质对窗口后方内容的采样
        window.isOpaque = false
        window.backgroundColor = .clear
        // 锁死深色：材质和 Liquid Glass 都跟随 appearance，不锁的话
        // 系统切浅色整个界面会跟着变白
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false   // 我们自己管生命周期
        window.delegate = self

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }

        placeCascaded(window)

        // 登记必须早于挂 contentView：shrink 要靠 windows[id] 找到这个窗口，
        // 登记晚一步就查不到，缩放整个落空
        windows[id] = window
        order.append(id)
        window.contentView = hosting

        window.makeKeyAndOrderFront(nil)
        // 必须显式激活 app。关掉最后一个窗口后 app 会退到后台，那时再开窗，
        // makeKeyAndOrderFront 只是把窗口显示出来，键盘焦点仍在别的 app——
        // 窗口看着好好的，按 esc 却毫无反应（事件压根没分发到本进程，
        // 连 local monitor 都不会被调用）。showNewProjectPanel 一直带着这句，这里漏了
        NSApp.activate(ignoringOtherApps: true)
        DiagLog.log("[窗口] 新开一个，当前共 \(windows.count) 个")

        return id
    }

    /// 级联摆位：每个新窗口相对上一个偏移一点，但**不能一路偏出屏幕**。
    /// 之前是无脑 +26/-26，开到第三四个就跑到可见区外面或者被完全盖住，
    /// 看起来像"只能开两个"。这里在可见区内循环，排满一轮就回到起点重新来。
    private func placeCascaded(_ window: NSWindow) {
        guard let screen = NSScreen.main else { window.center(); return }
        let visible = screen.visibleFrame
        let size = window.frame.size

        guard let lastID = order.last, let last = windows[lastID] else {
            window.center()
            return
        }
        let step: CGFloat = 28
        var origin = NSPoint(x: last.frame.origin.x + step,
                             y: last.frame.origin.y - step)
        // 右边或下边越界就回到可见区左上角重新开始一轮
        if origin.x + size.width > visible.maxX || origin.y < visible.minY {
            origin = NSPoint(x: visible.minX + step, y: visible.maxY - size.height - step)
        }
        window.setFrameOrigin(origin)
    }

    /// 一个窗口都没有时的「新建项目」：弹一个独立面板，只有表单本身，
    /// 底下不杵着空的主界面。表单 View 跟窗口内那个 sheet 是同一个
    /// （NewProjectSheet），外观靠 kSheetCornerRadius 对齐
    private var newProjectPanel: NSWindow?

    func showNewProjectPanel() {
        if let existing = newProjectPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 不挂系统 sheet：sheet 必须有宿主窗口，而宿主在 sheet 弹出时会被系统
        // 盖一层暗色 scrim——宿主本身透明，那层 scrim 就变成 sheet 后面一个
        // 可见的深色块，把宿主压扁也只是把块变成一条线。
        // 所以这里自己画，圆角用实测的系统值 kSheetCornerRadius 对齐
        let panel = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                                  styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        // borderless + 透明背景：窗口自己不画任何东西，形状完全由内容的
        // clipShape 决定。用 .titled 的话系统会画自己的边框和圆角盖在上面
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false

        let form = NewProjectSheet(
            onCancel: { [weak self] in self?.dismissNewProjectPanel() },
            onCreate: { [weak self] name, dir in
                self?.dismissNewProjectPanel()
                self?.newWindow(.createProject(name: name, directory: dir))
            })
            .clipShape(RoundedRectangle(cornerRadius: kSheetCornerRadius))

        let hosting = NSHostingView(rootView: form)
        panel.contentView = hosting
        // 贴合表单实际高度，别留空白
        panel.setContentSize(hosting.fittingSize)
        panel.centerOnScreen()
        newProjectPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissNewProjectPanel() {
        newProjectPanel?.close()
        newProjectPanel = nil
    }

    /// 已经打开这个项目的窗口。用来避免同一个项目被开两遍——
    /// 两个窗口各自编辑同一份文件，最后保存的那个会覆盖另一个
    func existingWindow(for url: URL) -> (WindowID, NSWindow)? {
        for (id, w) in windows {
            if let opened = openedURLs[id], opened == url { return (id, w) }
        }
        return nil
    }

    /// 每个窗口当前打开的项目路径，由 ProjectState 打开/保存后回报
    private var openedURLs: [WindowID: URL] = [:]

    /// 关窗前要做的事（自动保存）。由 ContentView 注册
    private var willCloseHandlers: [WindowID: () -> Void] = [:]

    func setWillClose(_ handler: @escaping () -> Void, for id: WindowID) {
        willCloseHandlers[id] = handler
    }

    func setOpenedURL(_ url: URL?, for id: WindowID) {
        openedURLs[id] = url
    }

    /// 按 id 取窗口。欢迎页要缩放自己那个窗口，不能靠 NSApp.windows.first 猜
    func window(for id: WindowID) -> NSWindow? { windows[id] }

    /// 关掉某个窗口。「开窗即弹表单」那条路上用户点取消时用——
    /// 不关的话会留一个既没项目也没欢迎页的空壳窗口挂在那儿
    func close(_ id: WindowID) {
        guard let w = windows[id] else { return }
        // 延到下一个 runloop 再关。从 NSEvent 的 local monitor 回调里同步 close，
        // AppKit 正在分发这个事件，close 会被静默忽略——实测按 esc 时
        // 「→ 关掉欢迎页窗口」的日志出来了，windowWillClose 一次都没触发
        DispatchQueue.main.async { w.close() }
    }

    func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = id(of: w) else { return }
        // 关窗即保存。放在 willClose 而不是 shouldClose：这里已经确定要关了，
        // 不会出现"存了但用户又取消关闭"的错位
        willCloseHandlers[id]?()
        willCloseHandlers[id] = nil
        ExportManager.shared.unregisterHandlers(for: id)
        windows[id] = nil
        order.removeAll { $0 == id }
        openedURLs[id] = nil
        WelcomeWindowSizer.forget(id)
        DiagLog.log("[窗口] 关掉一个，剩 \(windows.count) 个")
        // 最后一个窗口关掉时不退出 app（保持 macOS 习惯：Dock 图标还在，
        // 点一下能重新开窗）。这个行为由 AppDelegate 的
        // applicationShouldTerminateAfterLastWindowClosed 决定
    }
}

// MARK: - 菜单命令

/// 菜单命令。每条都要指明投递给哪个窗口——广播的话多窗口下
/// 按一次「保存」会把所有打开的项目都存一遍
enum MenuCommand: String {
    case newProject, openProject, openProjectFile, saveProject
    case importFiles, exportVideo

    var notificationName: Notification.Name { .init("menu.\(rawValue)") }

    /// 投给指定窗口
    func post(to id: WindowID, object: Any? = nil) {
        NotificationCenter.default.post(name: notificationName, object: object,
                                        userInfo: ["windowID": id])
    }

    /// 投给当前活动窗口。没有窗口时先开一个
    @MainActor
    func postToActive(object: Any? = nil) {
        guard let id = WindowManager.shared.activeWindowID else {
            // 没有窗口可投递就开一个空白工作窗口（不是欢迎页）
            WindowManager.shared.newWindow()
            return
        }
        post(to: id, object: object)
    }
}

extension Notification {
    /// 这条通知是不是发给我的。ContentView 在每个 onReceive 里先过这一关
    func isFor(_ id: WindowID) -> Bool {
        (userInfo?["windowID"] as? WindowID) == id
    }
}


/// 无边框面板默认不能当 key window，输入框就没法打字。
/// 覆写这两个属性把键盘焦点要回来
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 同上，NSWindow 版。borderless 的 NSWindow 一样默认拿不到键盘焦点，
/// 而 sheet 的宿主必须能成为 key window，否则表单里的输入框敲不进字
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension NSWindow {
    /// 真正摆到屏幕正中。NSWindow.center() 只做了水平居中——垂直方向它把窗口
    /// 上方留出剩余空间的 1/3，看起来明显偏上
    func centerOnScreen() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let f = frame
        setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2))
    }
}
