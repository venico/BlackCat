import AppKit
import SwiftUI

/// 文本卡片的极简 markdown 渲染（v5.1.0）。
///
/// 只做够用的这几种：行首 `#`/`##`/`###` 是标题，`**text**` 粗体，
/// `*text*` / `_text_` 斜体，`~~text~~` 删除线，`<u>text</u>` 下划线
/// （markdown 标准没有原生下划线语法，这是常见的 HTML 扩展写法）。
/// 列表、链接、引用这些没做 —— 先把最常用的这几种做稳，够用再说。
///
/// **只用于默认态（未编辑）的展示**：把源文本解析成「去掉标记符号 + 套上对应
/// 样式」的富文本。编辑态给用户看的、能改的还是原始 markdown 源码（含 `#` `**`
/// 这些符号）—— 不做「打字过程中逐字符消失」那种实时转换，那个需要一整套
/// 光标/输入法安全的编辑器状态机，风险和工作量都远超这次要做的范围
enum CanvasMarkdown {

    enum StyleKind: Hashable, CaseIterable {
        case bold, italic, underline, strikethrough
    }

    struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false

        mutating func set(_ kind: StyleKind) {
            switch kind {
            case .bold: bold = true
            case .italic: italic = true
            case .underline: underline = true
            case .strikethrough: strikethrough = true
            }
        }
    }

    /// 行内符号表。**顺序要紧**，长的必须排在短的前面：
    /// `***` 在 `**` 前、`**` 在 `*` 前，否则三连星会被拆错、
    /// 粗体会被当成两个空的斜体。
    ///
    /// `***text***` 单独列一条：它是「粗体 + 斜体」的标准写法，但按 `**` 去找
    /// 闭合会停在倒数第三个星号上，切出来的内容是 `*text`（少一个星，不平衡），
    /// 后面整段就全乱了 —— 用户手写这种写法时必须认得
    private static let inlineRules: [(open: String, close: String, kinds: [StyleKind])] = [
        ("***", "***", [.bold, .italic]),
        ("**", "**", [.bold]),
        ("~~", "~~", [.strikethrough]),
        ("<u>", "</u>", [.underline]),
        ("*", "*", [.italic]),
        ("_", "_", [.italic]),
    ]

    // MARK: - 渲染

    /// 解析成富文本。baseFontSize 是正文字号，标题在此基础上放大
    /// （级别越高字号越大，跟 CanvasNode.fontSize 那张表保持同一套比例）
    /// - Parameter scalesHeadings: 标题要不要放大。缩略图那种巴掌大的地方传 false ——
    ///   正文才六七点，标题按 1.83 倍放出来一个字就占半格，反而看不清内容；
    ///   标题该有的加粗仍然保留
    static func render(_ source: String, baseFontSize: CGFloat, colorHex: String,
                       scalesHeadings: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            result.append(renderSegment(rawLine, fontSize: baseFontSize,
                                        style: Style(), colorHex: colorHex,
                                        scalesHeadings: scalesHeadings))
            if i < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    /// 解析一段（可能被层层包裹的）内容。
    ///
    /// **标题前缀在每一层都要再查一次**：用户先点 H3 再点 S，文字会变成
    /// `~~### 标题~~`，`###` 就不在整段开头了。只在最外层查的话，
    /// 标题会被漏掉 —— 那正是「效果不能叠加」的一半原因
    private static func renderSegment(_ text: String, fontSize: CGFloat,
                                      style: Style, colorHex: String,
                                      scalesHeadings: Bool) -> NSAttributedString {
        var fontSize = fontSize
        var style = style
        var body = text
        let (level, stripped) = stripHeadingPrefix(text)
        if level > 0 {
            if scalesHeadings { fontSize = headingFontSize(level, base: fontSize) ?? fontSize }
            style.bold = true
            body = stripped
        }
        return renderInline(body, fontSize: fontSize, style: style, colorHex: colorHex,
                            scalesHeadings: scalesHeadings)
    }

    /// 扫一遍，遇到成对的标记就把**里面的内容递归解析**（带上这一层的样式），
    /// 符号本身不写进输出。
    ///
    /// 早前这里是直接把内层内容原样输出、不递归，所以 `~~<u>*### 文字*</u>~~`
    /// 只有最外层的删除线生效，里面的 `<u>` `*` `###` 全当普通字符显示出来了
    private static func renderInline(_ line: String, fontSize: CGFloat,
                                     style: Style, colorHex: String,
                                     scalesHeadings: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(line)
        var plain = ""
        var i = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(NSAttributedString(
                string: plain,
                attributes: attrs(fontSize: fontSize, style: style, colorHex: colorHex)))
            plain = ""
        }

        while i < chars.count {
            var matched = false
            for rule in inlineRules {
                guard matches(chars, at: i, rule.open) else { continue }
                let contentStart = i + rule.open.count
                guard let close = findClose(chars, from: contentStart, marker: rule.close) else { continue }
                flushPlain()
                var inner = style
                for kind in rule.kinds { inner.set(kind) }
                let innerText = String(chars[contentStart..<close])
                result.append(renderSegment(innerText, fontSize: fontSize,
                                            style: inner, colorHex: colorHex,
                                            scalesHeadings: scalesHeadings))
                i = close + rule.close.count
                matched = true
                break
            }
            if !matched {
                plain.append(chars[i])
                i += 1
            }
        }
        flushPlain()
        return result
    }

    /// 标题字号。**按正文字号的倍数算**，不写死绝对值 ——
    /// 缩略图里正文只有六七点，标题再用 22pt 会把整块撑爆。
    /// 倍数取自原来那张表（正文 12 → 22/18/15）
    private static func headingFontSize(_ level: Int, base: CGFloat) -> CGFloat? {
        switch level {
        case 1: return base * 22 / 12
        case 2: return base * 18 / 12
        case 3: return base * 15 / 12
        default: return nil
        }
    }

    /// 行首 `# ` `## ` `### ` 前缀，返回级别（0 = 不是标题）和去掉前缀后的正文
    private static func stripHeadingPrefix(_ line: String) -> (level: Int, body: String) {
        var hashes = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", hashes < 3 {
            hashes += 1
            idx = line.index(after: idx)
        }
        guard hashes > 0, idx < line.endIndex, line[idx] == " " else { return (0, line) }
        return (hashes, String(line[line.index(after: idx)...]))
    }

    /// 从 from 开始找下一个 marker 出现的位置。找不到就返回 nil ——
    /// 这段符号当普通文本处理，比如只打了一个 `*` 没配对，不该整段消失
    private static func findClose(_ chars: [Character], from: Int, marker: String) -> Int? {
        let m = Array(marker)
        guard !m.isEmpty else { return nil }
        var i = from
        while i + m.count <= chars.count {
            if Array(chars[i..<(i + m.count)]) == m { return i }
            i += 1
        }
        return nil
    }

    private static func matches(_ chars: [Character], at i: Int, _ s: String) -> Bool {
        let m = Array(s)
        guard i + m.count <= chars.count else { return false }
        return Array(chars[i..<(i + m.count)]) == m
    }

    private static func attrs(fontSize: CGFloat, style: Style, colorHex: String) -> [NSAttributedString.Key: Any] {
        var ctFont = CTFontCreateWithName(NSFont.systemFont(ofSize: fontSize).fontName as CFString,
                                          fontSize, nil)
        if style.bold, let bf = CTFontCreateCopyWithSymbolicTraits(ctFont, fontSize, nil,
                                                                    .boldTrait, .boldTrait) {
            ctFont = bf
        }
        if style.italic {
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            ctFont = CTFontCreateCopyWithAttributes(ctFont, fontSize, &skew, nil)
        }
        var a: [NSAttributedString.Key: Any] = [
            .font: ctFont as NSFont,
            .foregroundColor: NSColor(Color(hex: colorHex)),
        ]
        if style.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    // MARK: - 光标所在行

    /// 光标（UTF-16 偏移）落在第几行。
    /// 用 NSString 的长度算，跟 NSTextView 的 selectedRange 是同一套口径 ——
    /// Swift 的 `String.count` 按字素簇算，中文没问题但 emoji 会差，对不上
    static func lineIndex(in text: String, caret: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        var start = 0
        for (i, line) in lines.enumerated() {
            let end = start + (line as NSString).length
            if caret <= end { return i }
            start = end + 1        // +1 是换行符本身
        }
        return max(0, lines.count - 1)
    }

    /// 光标所在的那一行内容
    static func line(of text: String, caret: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        let i = lineIndex(in: text, caret: caret)
        return i < lines.count ? lines[i] : ""
    }

    /// 只改光标所在那一行，其余原样留着
    static func replacingLine(in text: String, caret: Int, _ transform: (String) -> String) -> String {
        var lines = text.components(separatedBy: "\n")
        let i = lineIndex(in: text, caret: caret)
        guard i < lines.count else { return text }
        lines[i] = transform(lines[i])
        return lines.joined(separator: "\n")
    }

    // MARK: - 工具栏：拆开 → 改一个开关 → 装回去

    /// 整段被哪些符号层层包着、标题是几级、最里面的正文是什么。
    ///
    /// 工具栏产出的就是「一层套一层，每层都包住整段」这种结构，所以能一层层剥。
    /// 用户手写的复杂 markdown（比如只有半句加粗）剥不动，会在第一层就停下，
    /// 那整段当正文处理 —— 这时候点工具栏相当于在外面再包一层，不会把原文改坏
    static func decompose(_ text: String) -> (heading: Int, styles: Set<StyleKind>, body: String) {
        var heading = 0
        var styles: Set<StyleKind> = []
        var body = text

        var peeled = true
        while peeled {
            peeled = false

            let (level, stripped) = stripHeadingPrefix(body)
            if level > 0 {
                heading = level
                body = stripped
                peeled = true
                continue
            }

            for rule in inlineRules {
                guard body.hasPrefix(rule.open), body.hasSuffix(rule.close),
                      body.count >= rule.open.count + rule.close.count else { continue }
                let inner = String(body.dropFirst(rule.open.count).dropLast(rule.close.count))
                // 这层得**真的包住整段**：`*a* 和 *b*` 首尾都是 `*`，但中间就闭合了，
                // 直接剥会把它错当成一整段斜体
                let chars = Array(inner)
                if findClose(chars, from: 0, marker: rule.close) != nil { continue }
                for kind in rule.kinds { styles.insert(kind) }
                body = inner
                peeled = true
                break
            }
        }
        return (heading, styles, body)
    }

    /// 按固定顺序装回去 —— 顺序固定才能保证「点两次回到原样」。
    ///
    /// 斜体用 `_` 不用 `*`（markdown 里两者等价）：粗体已经占了 `*`，
    /// 斜体再用 `*` 一叠加就是 `***text***`，星号连成一串谁都数不清哪个配哪个。
    /// 写成 `**_text_**` 就没有任何歧义
    static func compose(heading: Int, styles: Set<StyleKind>, body: String) -> String {
        var s = body
        if heading > 0 { s = String(repeating: "#", count: heading) + " " + s }
        if styles.contains(.italic) { s = "_" + s + "_" }
        if styles.contains(.bold) { s = "**" + s + "**" }
        if styles.contains(.underline) { s = "<u>" + s + "</u>" }
        if styles.contains(.strikethrough) { s = "~~" + s + "~~" }
        return s
    }

    /// B / I / U / S：拆开、改这一个开关、装回去。
    /// 不管当前套了几层、顺序如何，结果都是干净的
    static func toggle(_ text: String, style: StyleKind) -> String {
        var (heading, styles, body) = decompose(text)
        if styles.contains(style) { styles.remove(style) } else { styles.insert(style) }
        return compose(heading: heading, styles: styles, body: body)
    }

    /// H1/H2/H3：同级再点一次回到正文，不同级就换过去
    static func toggleHeading(_ text: String, level: Int) -> String {
        let (heading, styles, body) = decompose(text)
        return compose(heading: heading == level ? 0 : level, styles: styles, body: body)
    }
}
