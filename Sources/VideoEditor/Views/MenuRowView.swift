// MenuRowView.swift
//
// NSMenu 的自定义行。
//
// 系统画的菜单项，高亮跟着系统强调色走 —— 这里主色是黄的，黄底配白字糊成一片。
// 塞进 NSMenuItem.view 自己画，就能定死白字灰底，跟聊天框里 `/` 那个自绘菜单对齐。
//
// 只换「怎么画一行」，菜单本身的定位、键盘操作、点外面关掉都还是系统的。

import AppKit

final class MenuRowView: NSView {

    private let titleText: String
    private let subtitleText: String?
    private let checked: Bool
    private let indented: Bool
    private let enabled: Bool
    private let submenu: NSMenu?
    private let isHeader: Bool
    private let onPick: () -> Void
    private var hovering = false

    /// 造一个用自定义视图渲染的菜单项
    static func item(title: String,
                     subtitle: String? = nil,
                     checked: Bool = false,
                     width: CGFloat = 260,
                     indent: Bool = false,
                     enabled: Bool = true,
                     submenu: NSMenu? = nil,
                     isHeader: Bool = false,
                     action: @escaping () -> Void = {}) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuRowView(title: title, subtitle: subtitle, checked: checked,
                                width: width, indent: indent, enabled: enabled,
                                submenu: submenu, isHeader: isHeader, action: action)
        // 点击交给菜单自己派发（视图 hitTest 是穿透的），系统的跟踪逻辑
        // 完整保留 —— 子菜单才会跟着鼠标自动展开
        if !isHeader && enabled && submenu == nil {
            item.target = MenuRowDispatcher.shared
            item.action = #selector(MenuRowDispatcher.fire(_:))
        }
        item.isEnabled = enabled && !isHeader
        item.submenu = submenu
        return item
    }

    /// 供菜单派发点击用
    func performPick() { onPick() }

    private init(title: String, subtitle: String?, checked: Bool,
                 width: CGFloat, indent: Bool, enabled: Bool,
                 submenu: NSMenu?, isHeader: Bool = false,
                 action: @escaping () -> Void) {
        self.titleText = title
        self.subtitleText = subtitle
        self.checked = checked
        self.indented = indent
        self.enabled = enabled
        self.submenu = submenu
        self.isHeader = isHeader
        self.onPick = action
        // 两行 36，单行 24 —— 跟系统菜单一个观感
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: subtitle == nil ? 24 : 36))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        hovering = true
        needsDisplay = true

    }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }


    /// **只有带子菜单的行让鼠标穿透**。
    ///
    /// 视图接走鼠标，菜单自己的跟踪逻辑就断了，子菜单不会跟着鼠标展开；
    /// 而全部穿透又不行 —— 菜单对 view-based 的项不走 target/action，
    /// 点击当成「交给视图处理」，视图却收不到事件，于是点了没反应。
    /// 带子菜单的行本来也不需要点击执行，正好让给系统。
    /// hover 高亮两种都不受影响 —— NSTrackingArea 按坐标判定，不走 hitTest
    override func hitTest(_ point: NSPoint) -> NSView? {
        submenu != nil ? nil : super.hitTest(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, !isHeader else { return }
        // 先收菜单再干活：动作里可能再弹别的东西，菜单还开着会打架
        enclosingMenuItem?.menu?.cancelTracking()
        onPick()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let left: CGFloat = indented ? 24 : 12
        // 分组标题：小一号、次级色，不参与 hover
        let fg: NSColor = isHeader ? .secondaryLabelColor
                                   : (enabled ? .labelColor : .tertiaryLabelColor)
        let title = NSMutableAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: isHeader ? 11 : 13,
                                     weight: isHeader ? .medium : .regular),
            .foregroundColor: fg
        ])
        if checked {
            title.append(NSAttributedString(string: "  ✓", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: fg
            ]))
        }
        if submenu != nil {
            NSAttributedString(string: "›", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: fg
            ]).draw(at: NSPoint(x: bounds.width - 18, y: (bounds.height - 17) / 2))
        }
        if let sub = subtitleText {
            title.draw(at: NSPoint(x: left, y: 3))
            NSAttributedString(string: sub, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]).draw(at: NSPoint(x: left, y: 19))
        } else {
            let h = title.size().height
            title.draw(at: NSPoint(x: left, y: (bounds.height - h) / 2))
        }
    }
}


extension NSMenu {
    /// 用自绘行装一个「选一项」的菜单
    static func picker(_ rows: [(label: String, checked: Bool, action: () -> Void)],
                       width: CGFloat = 200) -> NSMenu {
        let menu = NSMenu()
        menu.minimumWidth = width
        for r in rows {
            menu.addItem(MenuRowView.item(title: r.label, checked: r.checked,
                                          width: width, action: r.action))
        }
        return menu
    }

    /// 在当前鼠标位置弹出来。定位规则集中在这一处
    func popUpHere() {
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(self, with: event, for: view)
        } else {
            popUp(positioning: nil, at: .zero, in: view)
        }
    }
}


/// 菜单项点击的统一派发口。
/// 行视图的 hitTest 是穿透的，点击由菜单发到这里，再转回那一行
final class MenuRowDispatcher: NSObject {
    static let shared = MenuRowDispatcher()
    @objc func fire(_ sender: NSMenuItem) {
        (sender.view as? MenuRowView)?.performPick()
    }
}
