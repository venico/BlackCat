import SwiftUI
import AppKit
import CoreText

/// 文本卡片的输入框（v5.1.0，B5）
///
/// 不用 SwiftUI 的 `TextEditor` —— 它只吃字号、粗体、斜体、颜色，
/// **下划线和删除线给不了**，而文本卡片点一下就进编辑态，
/// 结果就是「按了 U / S 没反应」。换成 NSTextView 才能把这两个属性画出来。
struct CanvasTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let bold: Bool
    let italic: Bool
    let underline: Bool
    let strikethrough: Bool
    let colorHex: String
    var focused: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        tv.isRichText = false          // 样式整块统一，不做分段富文本
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = text
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        apply(to: tv)
        if focused, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
    }

    /// 样式一次性铺到整段。`typingAttributes` 也要设，
    /// 不然接着敲的新字会掉回默认样式
    private func apply(to tv: NSTextView) {
        // 粗体走 symbolic traits；**斜体必须用矩阵斜切** ——
        // 中文字体没有 italic face，symbolic traits 那条路会静默失败，
        // 表现就是「点了 I 一点变化没有」。跟字幕/文字图层那边用的是同一套做法
        var ctFont = CTFontCreateWithName(NSFont.systemFont(ofSize: fontSize).fontName as CFString,
                                          fontSize, nil)
        if bold, let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, fontSize, nil,
                                                            .boldTrait, .boldTrait) {
            ctFont = bf
        }
        if italic {
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            ctFont = CTFontCreateCopyWithAttributes(ctFont, fontSize, &skew, nil)
        }
        let font = ctFont as NSFont

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(Color(hex: colorHex)),
        ]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        tv.typingAttributes = attrs
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.setAttributes(attrs, range: all)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: CanvasTextEditor
        init(_ parent: CanvasTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
