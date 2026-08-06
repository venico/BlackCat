// WindowDragGate.swift
// 让预览区顶部的控件（裁剪手柄、缩放手柄）能正常拖动，而不是被当成"拖窗口"。
//
// 起因：主窗口是 .titled + .fullSizeContentView，内容一直铺到窗口最顶端，
// 而预览区正好就在那儿——裁剪框的上边条和左上/右上两个圆点落在顶部 32pt 内，
// 按下去拖的是整个窗口，不是手柄。
//
// 实测过两件事，结论跟直觉相反，写下来免得后来者再试一遍：
//  1. 顶部那 32pt 虽然有 NSTitlebarContainerView 盖着，但 hitTest 命中的
//     **是内容视图本身**，不是 titlebar。事件根本没被标题栏拿走，
//     真正的原因是内容视图的 mouseDownCanMoveWindow 默认为 true。
//  2. 想靠 `.background(NSViewRepresentable{ mouseDownCanMoveWindow=false })`
//     局部关掉是没用的：SwiftUI 把内容合并绘制，hitTest 命中的始终是
//     最外层的 NSHostingView，插进去的那个 NSView 根本轮不到。
//
// 所以只能从 NSHostingView 这一层关。又不能一关了之——那样整个窗口都拖不动了
// （顶部区域的 hitTest 也归它），于是做成一个开关：鼠标悬停在需要自己吃掉
// 拖拽的控件上时关掉，移开就恢复。hover 一定发生在 mouseDown 之前，时序上够用。
import SwiftUI
import AppKit

enum WindowDragGate {
    /// 当前有几个控件声明"这拖拽归我"。用计数而不是布尔：预览区里有八个手柄，
    /// 鼠标从 A 移到 B 时两边的 hover 回调顺序不保证，用布尔的话 A 的
    /// "离开→恢复true" 可能压掉 B 的 "进入→设false"，开关就废了。
    /// 只在主线程的 hover 回调里读写，不需要额外同步。
    nonisolated(unsafe) private static var claimCount = 0

    static var allowsWindowDrag: Bool { claimCount == 0 }

    static func setClaimed(_ claimed: Bool) {
        claimCount = claimed ? claimCount + 1 : max(0, claimCount - 1)
        // 双保险：上面那个 mouseDownCanMoveWindow 是 view 层面的判断，
        // isMovable 是窗口层面的总闸。只靠前者时用户实测仍然会拖到窗口，
        // 加上这道之后无论 AppKit 走哪条路径都挡得住。
        // hover 一结束就恢复，不会让窗口长期拖不动。
        // NSApp 是隐式解包的 Optional，跑单元测试时没有 app 实例，得先解包
        guard let app = NSApp else { return }
        for window in app.windows where window.isVisible {
            window.isMovable = allowsWindowDrag
        }
    }

    /// 测试用：把计数清零
    static func resetForTesting() { claimCount = 0 }
}

/// 主窗口的宿主视图。把 mouseDownCanMoveWindow 接到上面那个开关上。
final class GatedHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { WindowDragGate.allowsWindowDrag }
}

extension View {
    /// 标记这个控件"自己处理拖拽"，悬停其上时窗口不跟着一起被拖走。
    ///
    /// **必须加在 `.position()` 之前**。`.position()` 返回的视图会占满父容器的
    /// 全部空间（视图本身只是被定位到那个点绘制），加在它后面的话 hover 区域
    /// 就是整个预览区，八个手柄互相盖来盖去，等于没做。
    func claimsDragFromWindow() -> some View {
        onHover { inside in
            WindowDragGate.setClaimed(inside)
        }
    }
}
