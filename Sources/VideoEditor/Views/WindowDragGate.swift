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

/// 从 Finder 拖进来的文件，落在窗口哪个区域算数、交给谁处理。
///
/// **为什么要有这张表**：SwiftUI 的 `.onDrop` 在这个 app 里收不到 Finder 的拖拽，
/// 连用 NSViewRepresentable 插进去的**真实 NSView** 也收不到。实测（诊断日志）：
/// 拖拽经过素材区时只有最外层 `GatedHostingView` 的 `draggingEntered` 触发，
/// 挂在素材区上的 `.onDrop`、挂在整棵子树最外层的兜底 `.onDrop`、以及插进去的
/// NSView，三个一次都没进过，而那块的 frame 是正常的 `(52, 106, 176, 438)`。
///
/// 原因就是本文件顶部记过的那条：SwiftUI 合并绘制，hitTest 命中的**始终**是最外层
/// NSHostingView——当时是为 `mouseDownCanMoveWindow` 发现的，而 AppKit 找拖放目标
/// 走的正是 hitTest，所以内层无论 SwiftUI 还是 AppKit 视图都轮不到。
///
/// 于是反过来：宿主统一收，按落点坐标分发。
@MainActor
enum FileDropRouter {
    /// 拖进来的东西。Finder 拖的是文件，素材库拖到时间轴的是素材 id 或图形类型
    enum Payload {
        case files([URL])
        case asset(UUID)
        case shape(ShapeType)
    }

    /// 接收区。素材区收文件，时间轴收素材 id —— 两边收的载荷类型不同，
    /// 所以匹配时既要看落点在不在区里，也要看这个区收不收这种载荷
    enum Kind: Hashable { case mediaLibrary, timeline }

    private struct Zone {
        /// SwiftUI `.global` 坐标系（原点左上）里的接收区
        let rect: CGRect
        let accepts: (Payload) -> Bool
        /// 落点用 zone 的**本地坐标**给出（时间轴要拿 x 换算时间码）
        let onDrop: (Payload, CGPoint) -> Void
        /// 拖拽进出这块区域时的通知，用来点亮"松开以导入"
        let onTargetChange: (Bool) -> Void
    }

    /// 按窗口分开存。多窗口下不区分的话，A 窗口的素材区矩形会拿去匹配 B 窗口的拖拽
    private static var zones: [WindowID: [Kind: Zone]] = [:]

    static func register(_ id: WindowID, kind: Kind, rect: CGRect,
                         accepts: @escaping (Payload) -> Bool,
                         onDrop: @escaping (Payload, CGPoint) -> Void,
                         onTargetChange: @escaping (Bool) -> Void) {
        zones[id, default: [:]][kind] = Zone(rect: rect, accepts: accepts,
                                             onDrop: onDrop, onTargetChange: onTargetChange)
    }

    /// 只收 Finder 文件的区（素材库用），保持原来的调用形状
    static func register(_ id: WindowID, rect: CGRect,
                         onFiles: @escaping ([URL]) -> Void,
                         onTargetChange: @escaping (Bool) -> Void) {
        register(id, kind: .mediaLibrary, rect: rect,
                 accepts: { if case .files = $0 { return true } else { return false } },
                 onDrop: { payload, _ in
                     if case .files(let urls) = payload { onFiles(urls) }
                 },
                 onTargetChange: onTargetChange)
    }

    static func unregister(_ id: WindowID) { zones[id] = nil }
    static func unregister(_ id: WindowID, kind: Kind) { zones[id]?[kind] = nil }

    /// 图形卡片写进 pasteboard 的前缀。素材拖的是裸 UUID 字符串，
    /// 图形拖的是 "shape:rectangle"，靠这个前缀区分
    static let shapePrefix = "shape:"
    static func pasteboardString(for type: ShapeType) -> String { shapePrefix + type.rawValue }

    private static func zone(at point: CGPoint, for payload: Payload,
                             in id: WindowID) -> Zone? {
        zones[id]?.values.first { $0.rect.contains(point) && $0.accepts(payload) }
    }

    static func canAccept(_ point: CGPoint, payload: Payload, in id: WindowID) -> Bool {
        zone(at: point, for: payload, in: id) != nil
    }

    /// 只点亮命中的那个区，其余区一律熄灭 —— 否则拖过时间轴时素材区还亮着
    static func setTargeted(_ targeted: Bool, at point: CGPoint,
                            payload: Payload, in id: WindowID) {
        guard let all = zones[id] else { return }
        let hit = targeted ? zone(at: point, for: payload, in: id) : nil
        for z in all.values {
            z.onTargetChange(hit != nil && z.rect == hit!.rect)
        }
    }

    @discardableResult
    static func deliver(_ payload: Payload, at point: CGPoint, in id: WindowID) -> Bool {
        guard let z = zone(at: point, for: payload, in: id) else { return false }
        // 落点转成区内本地坐标：时间轴要用 x 算时间码
        z.onDrop(payload, CGPoint(x: point.x - z.rect.minX, y: point.y - z.rect.minY))
        return true
    }
}

/// 主窗口的宿主视图。把 mouseDownCanMoveWindow 接到上面那个开关上，
/// 并统一接收 Finder 拖进来的文件（见 FileDropRouter）。
final class GatedHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { WindowDragGate.allowsWindowDrag }

    /// 这个宿主属于哪个窗口。拖进来的文件要按窗口找对应的接收区
    var windowID: WindowID?

    /// 上一次 draggingUpdated 时鼠标在不在接收区内。只在变化时才回调，
    /// 不然拖动过程中每帧都会推一次 @Published，白白触发重绘
    private var wasInsideZone = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // .string 是素材库拖到时间轴时带的素材 id —— 应用内拖拽同样走 hitTest，
        // 内层的 .onDrop 一样收不到，也得由宿主统一接
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// AppKit 的窗口坐标 → SwiftUI 的 `.global` 坐标。
    /// NSHostingView 是 flipped 的（原点左上），跟 SwiftUI 一致；
    /// 万一哪个版本不是，按未翻转的算法兜一下
    private func swiftUIPoint(_ sender: NSDraggingInfo) -> CGPoint {
        let p = convert(sender.draggingLocation, from: nil)
        return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// 从 pasteboard 认出拖的是什么。
    ///
    /// **应用内载荷必须先认**：`"shape:rectangle"` 是个合法 URL 字符串（scheme = shape），
    /// 先问 `readObjects(forClasses: [NSURL.self])` 的话它会解析成功、被判成文件拖拽，
    /// 时间轴就收不到了 —— 而且是在 `draggingEntered` 阶段就被拒，
    /// 连 performDragOperation 的日志都不会打，现象是「能拖但落不下去」。
    /// 素材那边侥幸没事，只因为裸 UUID 不是合法的 URL scheme。
    private func payload(_ sender: NSDraggingInfo) -> FileDropRouter.Payload? {
        let pb = sender.draggingPasteboard
        if let s = pb.string(forType: .string) {
            if let uuid = UUID(uuidString: s) { return .asset(uuid) }
            if s.hasPrefix(FileDropRouter.shapePrefix),
               let t = ShapeType(rawValue: String(s.dropFirst(FileDropRouter.shapePrefix.count))) {
                return .shape(t)
            }
        }
        // Finder 拖进来的文件。只认 file:// —— 别把应用内那些串当成 URL
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        return nil
    }

    private func updateTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = windowID, let load = payload(sender) else { return [] }
        let pt = swiftUIPoint(sender)
        let inside = FileDropRouter.canAccept(pt, payload: load, in: id)
        // 位置一直在变，命中的区也可能从素材区切到时间轴，所以不能只在
        // inside 翻转时才更新——但也不必每帧都推：区没变时 setTargeted 是幂等的
        if inside != wasInsideZone {
            wasInsideZone = inside
        }
        FileDropRouter.setTargeted(inside, at: pt, payload: load, in: id)
        return inside ? .copy : []
    }

    private func clearTarget() {
        guard let id = windowID else { return }
        wasInsideZone = false
        FileDropRouter.setTargeted(false, at: .zero, payload: .files([]), in: id)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearTarget() }

    override func draggingEnded(_ sender: NSDraggingInfo) { clearTarget() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pt = swiftUIPoint(sender)
        let load = payload(sender)
        clearTarget()
        guard let id = windowID, let load else { return false }
        let accepted = FileDropRouter.deliver(load, at: pt, in: id)
        // 留一条：拖入这条链路排查过一整轮（SwiftUI onDrop / 内嵌 NSView 都收不到），
        // 万一以后又不灵，这一行能直接分清是「没触发」还是「落点没落进接收区」
        let what: String
        switch load {
        case .files(let urls): what = "文件=\(urls.count)"
        case .asset(let id):   what = "素材=\(id.uuidString.prefix(8))"
        case .shape(let t):    what = "图形=\(t.rawValue)"
        }
        DiagLog.log("[拖入] 落点=\(pt) \(what) 接收=\(accepted)")
        return accepted
    }
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
