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
    /// false = 默认态（只展示，不接收点击/编辑）。
    ///
    /// **默认态也用这个组件渲染，不再用 SwiftUI 的 `Text`**——两套排版引擎对同一
    /// 字号的行高计算有细微差异：卡片高度刚好卡在「能放下 8 整行 + 半行」时，
    /// `Text` 会为了不露出裁一半的行，主动舍弃这半行并在上一行末尾补省略号；
    /// NSTextView 配合滚动却能把这半行也画出来。结果就是同样的文字、同样的卡片，
    /// 选中前后看到的行数会差一行。内边距、字体、颜色再怎么对齐都消不掉这个差异，
    /// 只有统一成同一套引擎才能保证像素级一致
    var isEditable: Bool = true
    /// 占位符（空文本时的提示语「文本」）要用比正文更淡的颜色。
    /// 不新开一条「占位符」渲染路径 —— 那样又会绕回 Text/NSTextView 两条
    /// 排版路径不一致的老问题，直接给同一段文字调透明度更省事
    var textOpacity: Double = 1.0
    /// 默认态按 markdown 渲染：`##` 变标题字号、`**text**` 变粗体……符号本身
    /// 不显示。**只在 `isEditable == false` 时生效** —— 编辑态给用户看、能改的
    /// 必须是原始 markdown 源码（含符号），不然没法编辑；调用方要保证两者不同时开
    var renderMarkdown: Bool = false
    /// 默认态下鼠标是不是正悬在卡片上。文字比卡片高时，hover 才出滚动条、
    /// 才能滚——平时不 hover 就把这块地方让给「点击/拖动卡片」，
    /// hover 上去才表示「我要看这段文字」，滚轮和拖滚动条才应该归它管
    var isHovering: Bool = false
    /// 这个输入框拿到键盘焦点时回调。底部聊天框用它通知画布
    /// 「退出文字卡片的编辑态」—— 光标进了聊天框，卡片那边的编辑态和黄框
    /// 就该收掉，不然看着像两个地方同时在编辑
    var onFocus: (() -> Void)?
    /// 「这次的 text 是程序改的，别当成用户打字」的信号，见 CanvasState.textEditRevision。
    /// 值一变，编辑器就强制把 text 同步进来一次（正常打字时它不变，
    /// 编辑器照旧不覆盖 —— 那是为了不冲掉用户刚敲的字）
    var syncRevision: Int = 0
    /// 光标挪动时上报它在文本里的位置（UTF-16 偏移，跟 NSTextView 自己那套一致）。
    /// 工具栏靠它知道「用户想改的是哪一行」
    var onCaretMove: ((Int) -> Void)?
    /// 把「@图1」这种提及标成高亮色。聊天框用，文本卡片不用
    var highlightsMentions: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        // 用系统的工厂方法，**别手工装配** —— 手工接
        // textStorage → layoutManager → textContainer 那套很容易漏掉所有权：
        // NSTextContainer 对 layoutManager 是弱引用、layoutManager 只被
        // textStorage 持有，一放局部变量整条链就断，textView 失去布局引擎，
        // 表现是「输入框没光标、打字没反应」。这条路走过一次，不值当
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        tv.isRichText = false          // 样式整块统一，不做分段富文本
        // 内边距清零，外层 SwiftUI padding 统一负责留白 —— 两处都留的话
        // 编辑态和默认态的文字可用宽度不一样，换行位置就对不上，
        // 表现是「选中态和默认态显示的行数不一致」。
        // lineFragmentPadding 也是隐藏的一份内边距（NSTextContainer 默认给 5pt），
        // 不清零的话换行宽度还是会跟 Text 视图差一点
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        applyMode(to: tv, scroll: scroll)
        applyContent(to: tv, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Coordinator 缓存的 parent 必须每次都刷新到最新的 self，否则
        // textDidChange 回调用的永远是 makeNSView 那一刻的旧快照。
        // 这次加了「默认态用 .constant」的分支后暴露得特别明显：新卡片
        // 一开始都是默认态（.constant，setter 是空操作），点进编辑态后
        // 如果不刷新这里，敲的字会一直没写进 text 绑定 —— 退出编辑时用
        // 的还是编辑前的旧值，会把刚打的字整段冲刷掉
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        applyMode(to: tv, scroll: scroll)
        applyContent(to: tv, coordinator: context.coordinator)

        if focused {
            // **只在刚变成 focused 的那一刻抢一次**，抢完就记账。
            //
            // 无条件抢的话，只要这张卡片还在编辑态，每次 updateNSView 都会把
            // 焦点夺回来 —— 而 SwiftUI 里任何一点状态变化都会触发 updateNSView。
            // 用户点底部聊天框：那个输入框拿到焦点 → 状态变化 → 这里 updateNSView
            // → 发现自己 focused 但不是第一响应者 → 又抢回来。表现就是
            // 「不管点哪儿，光标都跳回文字卡片」。
            // 点哪儿光标就该在哪儿，抢焦点只能是「刚进入编辑态」这一下
            if !context.coordinator.hasGrabbedFocus {
                context.coordinator.hasGrabbedFocus = true
                if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
            }
        } else if context.coordinator.hasGrabbedFocus {
            // **只有「之前是被程序化聚焦的」才需要交还**（hasGrabbedFocus 为真）。
            //
            // 底部聊天框的 focused 恒为 false —— 它不需要程序化抢焦点，用户点一下
            // 就行。如果这里不加这道判断，聊天框每次 updateNSView 都会走到交还
            // 分支，而打字本身就会触发 updateNSView（文字变化 → 状态更新），
            // 于是「敲一个字 → 焦点被自己交还 → 光标没了、打不进第二个字」。
            // 这个交还逻辑是为文字卡片退出编辑态写的，不该殃及从不参与
            // 程序化焦点管理的输入框
            context.coordinator.hasGrabbedFocus = false
            if tv.window?.firstResponder === tv {
                // 退出编辑要主动交还第一响应者，不然它会一直「赖」在这个 NSTextView 上——
                // 画布的右键监听靠 `firstResponder is NSTextView` 判断「是不是在编辑文字，
                // 该放行给系统右键菜单」，不交还的话，编辑过一次之后，不管右键点哪张卡片，
                // 这个判断永远是 true，表现就是「右键都变成系统菜单，其它卡片也右键不了」
                tv.window?.makeFirstResponder(nil)
            }
        }
    }

    fileprivate struct StyleSignature: Equatable {
        let fontSize: CGFloat
        let bold, italic, underline, strikethrough: Bool
        let colorHex: String
        let textOpacity: Double
    }

    /// 默认态：不可编辑、不可选中、不可滚动 —— 纯展示，鼠标事件一律穿透给
    /// 上层卡片，交由 SwiftUI 的 tap/drag 手势处理（点它要能选中/拖动卡片，
    /// 不能被这层 NSTextView 截胡）。
    /// 编辑态给可见滚动条 —— 文字比卡片高时要能看出「还有更多，能往下滚」
    private func applyMode(to tv: NSTextView, scroll: NSScrollView) {
        tv.isEditable = isEditable
        tv.isSelectable = isEditable
        // 编辑态本来就要能滚；默认态平时不接手势（穿透给卡片拖动/选中），
        // 只有 hover 时才临时开一下滚动能力，让文字比卡片高时能滚轮/拖滚动条看完
        let scrollable = isEditable || isHovering
        scroll.hasVerticalScroller = scrollable
        // 内容没超出时自己藏起来 —— 短文字的卡片不该挂一条没用的滚动条
        scroll.autohidesScrollers = true
        // overlay 样式：平时是很细的一条，鼠标靠近才变粗 —— 跟时间轴底下那条
        // 一个手感。legacy 是固定宽度的占位条，粗细不会变，还会挤占文字宽度
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = scrollable ? .automatic : .none
        scroll.horizontalScrollElasticity = .none
    }

    /// 按当前模式把内容画到 tv 上。
    ///
    /// markdown 模式：只读展示，没有光标/输入法要顾，内容变了就整段重渲染，
    /// 不需要「只在真变化时才动」那套增量小心思。
    /// 普通模式：沿用原来的增量逻辑（string 不同才替换、样式不同才重刷 attributes）——
    /// 这段是专门为了不打断中文输入法组字过程写的，不能碰
    private func applyContent(to tv: NSTextView, coordinator: Coordinator) {
        if renderMarkdown {
            // **模式切换也要重渲染**：从编辑态回默认态时，text 常常一个字没变，
            // 光比 lastMarkdownSource 会直接判定「没变化」跳过，
            // 于是屏幕上留着编辑态那份纯源码 —— 表现就是「默认态还带着 #」
            let modeJustSwitched = !coordinator.wasRenderingMarkdown
            guard coordinator.lastMarkdownSource != text || modeJustSwitched else { return }
            let rendered = CanvasMarkdown.render(text, baseFontSize: fontSize, colorHex: colorHex)
            tv.textStorage?.setAttributedString(rendered)
            coordinator.lastMarkdownSource = text
            coordinator.wasRenderingMarkdown = true
            // 渲染 markdown 是**整段属性全改写**（标题那行变成了 22pt 粗体）。
            // 编辑态那份样式缓存到这儿就不作数了，作废掉，
            // 否则下次切回编辑态时它以为「样式没变」而跳过重铺，
            // 屏幕上留着标题的大字号 —— 表现正是「第一次进编辑态正常，
            // 退出去再进来整段都变成大号字」
            coordinator.lastStyle = nil
            return
        }
        // 刚从 markdown 模式回来：不管样式签名变没变，都得重新铺一遍正文样式
        let justLeftMarkdown = coordinator.wasRenderingMarkdown
        coordinator.wasRenderingMarkdown = false

        // 正在编辑中的 tv，它自己的 string 才是权威内容，不能拿 text 绑定去覆盖。
        // textDidChange 把新内容写回 text 绑定不是同步生效的——绑定要经过
        // SwiftUI 一轮状态更新才能反映出来，这一次 updateNSView 读到的可能还是
        // 「差一个字符」的旧值，这时候拿它覆盖 tv.string 就等于把刚打的字冲掉了。
        // 表现是「打一个字母，松手后光标把这个字母删了」。只有它不是当前编辑
        // 焦点时（刚打开、切换节点、程序化改内容）才需要用绑定同步过去
        let isActivelyEditing = isEditable && tv.window?.firstResponder === tv
        // 工具栏改的那次例外：revision 变了说明这次确实是程序在改同一份文字，
        // 就算正在编辑也得同步进来（否则点 H1 要退出编辑再进来才看得见 #）。
        // 覆盖会把光标顶到开头，所以要按「前面插了几个字符」把它挪回原处
        let forced = coordinator.lastSyncRevision != syncRevision
        coordinator.lastSyncRevision = syncRevision
        if forced, tv.string != text {
            let oldLength = (tv.string as NSString).length
            let caret = tv.selectedRange()
            tv.string = text
            let delta = (text as NSString).length - oldLength
            let newLocation = max(0, min((text as NSString).length, caret.location + delta))
            tv.setSelectedRange(NSRange(location: newLocation, length: 0))
        } else if !isActivelyEditing, tv.string != text {
            tv.string = text
        }
        let sig = StyleSignature(fontSize: fontSize, bold: bold, italic: italic,
                                 underline: underline, strikethrough: strikethrough,
                                 colorHex: colorHex, textOpacity: textOpacity)
        if coordinator.lastStyle != sig || justLeftMarkdown {
            apply(to: tv)
            coordinator.lastStyle = sig
        }
        if highlightsMentions { highlightMentions(in: tv) }
    }

    /// 把 `@图1`、`@视频2` 这类提及涂成主题色。
    ///
    /// **只改颜色属性、不碰文字本身**，也不动 typingAttributes —— 那两样一动
    /// 就会打断中文输入法的组字过程（这个坑踩过）。
    /// 每次内容变化后重涂一遍：范围很小，开销可以忽略
    fileprivate func highlightMentionsPublic(in tv: NSTextView) { highlightMentions(in: tv) }

    private func highlightMentions(in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let text = tv.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        let base = NSColor(Color(hex: colorHex)).withAlphaComponent(textOpacity)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: base, range: full)
        // @ 后面跟着连续的非空白字符就算一个提及
        let pattern = "@[^\\s@]+"
        if let re = try? NSRegularExpression(pattern: pattern) {
            for m in re.matches(in: tv.string, range: full) {
                storage.addAttribute(.foregroundColor, value: NSColor(Color.accent), range: m.range)
            }
        }
        storage.endEditing()
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
            .foregroundColor: NSColor(Color(hex: colorHex)).withAlphaComponent(textOpacity),
        ]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        tv.typingAttributes = attrs
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.setAttributes(attrs, range: all)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        // var 不是 let —— updateNSView 每次都要把它刷新到最新的 self，
        // 见 updateNSView 里的注释
        var parent: CanvasTextEditor
        /// 上次真正应用过的样式，没变就跳过 setAttributes（见 updateNSView）
        fileprivate var lastStyle: StyleSignature?
        /// markdown 模式：上次渲染用的源文本，没变就跳过重渲染
        fileprivate var lastMarkdownSource: String?
        /// 上一轮是不是 markdown 模式。模式切换时必须重渲染，见 applyContent
        fileprivate var wasRenderingMarkdown = false
        /// 上次同步过的外部修改序号，见 CanvasState.textEditRevision
        fileprivate var lastSyncRevision = 0
        /// 这一轮编辑态里已经抢过焦点了吗。见 updateNSView 里的注释 ——
        /// 抢焦点只能是「刚进入编辑态」这一下，之后点哪儿光标就归哪儿
        fileprivate var hasGrabbedFocus = false
        init(_ parent: CanvasTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // 边打边涂。异步一拍，避开输入法正在组字的时刻
            if parent.highlightsMentions {
                DispatchQueue.main.async { [weak tv] in
                    guard let tv else { return }
                    self.parent.highlightMentionsPublic(in: tv)
                }
            }
        }

        /// 拿这个当「输入框拿到键盘焦点」的信号。
        ///
        /// 点击落在 NSTextView 内部，外面的 SwiftUI 手势收不到，只能从 AppKit
        /// 这层报出来。选区变化在程序化改内容时也会触发，所以要卡一道
        /// 「确实是当前第一响应者」，避免误报
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  tv.window?.firstResponder === tv else { return }
            // **只有窗口真的在前台、而且这个 view 能编辑时**才算「用户在这儿输入」。
            // 程序化改内容（插 @提及、同步草稿）也会走到这个回调，
            // 不卡这一道的话画布的 delete / ⌘Z 会被误判成「归输入框」
            if tv.isEditable, tv.window?.isKeyWindow == true {
                parent.onFocus?()
            }
            parent.onCaretMove?(tv.selectedRange().location)
        }
    }
}
