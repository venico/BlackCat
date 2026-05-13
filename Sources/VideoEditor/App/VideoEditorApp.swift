import SwiftUI
import AppKit

struct VideoEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApplication.shared.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)

        // 立刻隐藏系统交通灯
        hideSystemButtons(window)

        // 下一个 run loop 再隐藏一次（减轻启动闪烁）
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window else { return }
            self?.hideSystemButtons(window)
        }

        // 监听所有可能导致系统按钮重新出现的事件
        let events: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        for event in events {
            let obs = NotificationCenter.default.addObserver(
                forName: event, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.hideSystemButtons(window)
            }
            observers.append(obs)
        }

        // 监听 close button 的 frame 变化
        if let btn = window.standardWindowButton(.closeButton) {
            btn.postsFrameChangedNotifications = true
            let obs = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: btn, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.hideSystemButtons(window)
            }
            observers.append(obs)
        }
    }

    private func hideSystemButtons(_ window: NSWindow) {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
