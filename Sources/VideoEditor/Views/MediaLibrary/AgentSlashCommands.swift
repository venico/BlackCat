import SwiftUI
import AppKit
// AgentSlashCommands.swift
//
// 输入框打 `/` 唤出的命令列表。
//
// 现在的来源只有 Skills，但结构留成「可扩展的命令」——以后加内置命令
// （/clear、/plan 这类）直接往 items 里塞就行，界面不用动。


struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    /// 不带斜杠
    let name: String
    let detail: String
    let kind: Kind

    enum Kind: Equatable {
        case skill
        case builtin
    }
}

enum SlashCommands {
    /// 当前能用的全部命令：装好的 Skill + 配好 Key 的生成模型
    @MainActor
    static func all() -> [SlashCommand] {
        let skills = AgentSkills.shared.skills
            .filter(\.isEnabled)
            .map { SlashCommand(name: slug($0.name), detail: $0.description, kind: .skill) }
        // 图片/音频/视频模型不在聊天框的下拉里了，改成打 `/` 点名。
        // 不按有没有配 Key 过滤 —— 滤掉的话用户只会觉得「这模型怎么没了」，
        // 点了没配的那个，Agent 会明说去设置里填
        let models = AIVideoService.Provider.allCases
            .filter { !$0.isHidden && $0.category != .text }
            .map { SlashCommand(name: slug($0.rawValue), detail: $0.category.rawValue, kind: .builtin) }
        return skills + models
    }

    /// 名字对应的是不是一个生成模型
    @MainActor
    static func isModel(_ name: String) -> Bool {
        all().first { $0.name == name }?.kind == .builtin
    }

    /// 名字里有空格的话当命令用不方便，压成一个词
    static func slug(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    /// 光标前那一段正在打的 `/xxx`。不在词首的斜杠不算（网址里的斜杠很常见）
    static func activeToken(in text: String, cursor: Int) -> (range: Range<String.Index>, query: String)? {
        guard cursor <= text.count else { return nil }
        let upTo = text.index(text.startIndex, offsetBy: cursor)
        let head = text[text.startIndex..<upTo]
        guard let slashIdx = head.lastIndex(of: "/") else { return nil }
        // 斜杠前面必须是行首或空白，否则 https:// 这种也会触发
        if slashIdx > head.startIndex {
            let prev = head[head.index(before: slashIdx)]
            guard prev == " " || prev == "\n" else { return nil }
        }
        let q = String(head[head.index(after: slashIdx)..<upTo])
        // 打到空格就算这一段结束了
        guard !q.contains(" "), !q.contains("\n") else { return nil }
        return (slashIdx..<upTo, q)
    }

    /// 文本里所有已经成形的 `/命令`，用来上色
    @MainActor
    static func matchedRanges(in text: String) -> [NSRange] {
        let names = Set(all().map(\.name))
        guard !names.isEmpty else { return [] }
        var out: [NSRange] = []
        let ns = text as NSString
        var i = 0
        while i < ns.length {
            guard ns.character(at: i) == unichar(UInt16(47)) else { i += 1; continue }  // '/'
            if i > 0 {
                let prev = ns.character(at: i - 1)
                if prev != 32 && prev != 10 { i += 1; continue }
            }
            var j = i + 1
            while j < ns.length {
                let c = ns.character(at: j)
                if c == 32 || c == 10 { break }
                j += 1
            }
            let word = ns.substring(with: NSRange(location: i + 1, length: j - i - 1))
            if names.contains(word) { out.append(NSRange(location: i, length: j - i)) }
            i = j
        }
        return out
    }
}

/// `/` 唤出的候选列表。贴着输入框上方，外观照系统菜单来
struct SlashCommandPopup: View {
    let commands: [SlashCommand]
    @Binding var selectedIndex: Int
    let onPick: (SlashCommand) -> Void

    var body: some View {
        // 命令一多就滚，别把整个面板顶穿
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { i, cmd in
                    Button { onPick(cmd) } label: {
                        HStack(spacing: 7) {
                            Text(cmd.name)
                                .font(.system(size: 13))
                                .foregroundColor(Color.labelPrimary)
                            // 只给模型标类别。Skill 的 description 是写给模型看的
                            // 触发词，一长串英文，摆这儿是噪音
                            if cmd.kind == .builtin, !cmd.detail.isEmpty {
                                Text(cmd.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.labelSecondary.opacity(0.6))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.10)))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        // 白字灰底，跟其他下拉一致。不用主色打底 —— 主色是黄的，
                        // 铺上去再配白字对比度不够，字直接糊在底上
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(i == selectedIndex ? Color.white.opacity(0.12) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 必须给确定高度：overlay 里 ScrollView 会去取被覆盖那个视图的提案，
        // 只写 maxHeight 的话它塌成输入框那么高，菜单等于不见了
        .frame(height: min(CGFloat(commands.count) * 24, Self.maxListHeight))
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        // 跟 AI 下拉那种系统菜单同一套材质：.menu + 同窗口内混合
        .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.systemSeparator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    /// 列表区最高多少。外面算浮起高度要用同一个值，所以摆在这儿
    static let maxListHeight: CGFloat = 264

    /// 整块菜单的高度：列表 + 上下各 5 的内边距
    static func height(for count: Int) -> CGFloat {
        min(CGFloat(count) * 24, maxListHeight) + 10
    }
}

// MARK: - 命令标签

extension NSAttributedString.Key {
    /// 标了这个的字符会被画成一枚圆角标签
    static let chipTag = NSAttributedString.Key("blackcat.chipTag")
    /// 标了这个的字符一律不画（命令前面那根斜杠）
    static let chipSlash = NSAttributedString.Key("blackcat.chipSlash")
    /// 标了这个的整段会被画成一块圆角代码底
    static let codeBlock = NSAttributedString.Key("blackcat.codeBlock")
}

/// 给 `.chipTag` 那几段画圆角底。
///
/// 纯属性做不出标签：`.backgroundColor` 是方角、贴着字、也没有内边距。
/// 底色只能自己在这一层画。
final class ChipLayoutManager: NSLayoutManager {
    /// 斜杠一个像素都不画。
    ///
    /// 原来靠 `.foregroundColor = .clear` 藏它，**选中时会露出来** ——
    /// 选中态的前景色来自 `selectedTextAttributes`，把这条属性盖掉了；
    /// 而斜杠的字距是负的，露出来正好压在命令名上。
    /// 字符本身要留在文本里（发送时靠它认命令，复制出去也得带着），
    /// 所以只能从绘制这层断：把它那段从绘制范围里挖掉，两边分开画
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var skip: [NSRange] = []
        storage.enumerateAttribute(.chipSlash, in: charRange) { value, range, _ in
            guard value != nil else { return }
            skip.append(glyphRange(forCharacterRange: range, actualCharacterRange: nil))
        }
        guard !skip.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for s in skip.sorted(by: { $0.location < $1.location }) {
            if s.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor,
                                                        length: s.location - cursor),
                                 at: origin)
            }
            cursor = max(cursor, NSMaxRange(s))
        }
        if cursor < end {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor),
                             at: origin)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // 代码块：把这一段所有行的矩形并成一块，画一个圆角底。
        // 逐行画的话会变成一行一个小块，中间还带缝
        storage.enumerateAttribute(.codeBlock, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = CGRect.null
            enumerateEnclosingRects(forGlyphRange: gr,
                                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                box = box.union(rect)
            }
            guard !box.isNull else { return }
            // 四周各 4pt 内边距，再钳进容器里 —— 万一段落缩进没跟上，
            // 也不至于把框画到边界外被裁掉
            var r = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4)
            let maxRight = origin.x + container.size.width
            r.origin.x = max(r.minX, origin.x)
            r.size.width = min(r.width, maxRight - r.minX)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSColor.white.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        storage.enumerateAttribute(.chipTag, in: charRange) { value, range, _ in
            guard let fontSize = value as? CGFloat else { return }
            // 尺寸按字体本身算，不跟着整行走 —— 行高取的是该行最高的那个字体，
            // 中英混排的行比纯 ASCII 的行高出一截，同一个标签在气泡里和
            // 输入框里就会一大一小
            let f = NSFont.systemFont(ofSize: fontSize)
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: gr,
                                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let base = rect.offsetBy(dx: origin.x, dy: origin.y)
                // 框贴着**文字**放，字才在框里居中。框相对气泡正不正是另一回事 ——
                // 那个靠撑杆把行的上下空间撑对称（见 applyCommandChips），
                // 两边各管一头，不冲突
                let baselineY = base.minY + self.location(forGlyphAt: gr.location).y
                let top = baselineY - f.ascender
                let textH = f.ascender - f.descender
                // 左右各 4pt、上下各 2pt 内边距。base.width 里含名字末尾那 6pt
                // 字距 —— 拿掉它、左右各补 4pt，剩的 2pt 是标签跟后文的间距
                let r = NSRect(x: base.minX - 4, y: top - 2,
                               width: base.width + 2, height: ceil(textH) + 4)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                NSColor.white.withAlphaComponent(0.10).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.10).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

extension NSMutableAttributedString {
    /// 把文本里成形的 `/命令` 变成标签：斜杠收掉不显示，名字上主色黄 + 圆角底
    @MainActor
    func applyCommandChips(fontSize: CGFloat = 12) {
        // 行高取的是这一行里最高的那个字体。斜杠本来就画不出来（透明 + 负字距），
        // 正好拿它当撑杆：给它一个更大的字号，整行就高出来，标签在行内居中放得下，
        // 既不用顶出行外挨裁，也不会压到上下行
        // +6 而不是 +4：单行文本的行高不含 lineSpacing（那是加在行之间的），
        // 撑杆只抬到刚好装下标签，上下就没有余量匀
        let liftFont = NSFont.systemFont(ofSize: fontSize + 6)
        let cmdFont = NSFont.systemFont(ofSize: fontSize)
        let slashWidth = ("/" as NSString).size(withAttributes: [.font: liftFont]).width
        // 撑杆光加字号只往**上**顶（字体的 ascender 远大于 descender），
        // 行的几何中心就落在文字视觉中心的上方，标签跟着偏上。
        // 让撑杆再往下沉一截，把行底也撑开，两个中心才重合：
        //   行底需要的深度 = 撑杆 ascender −（文字 ascender + descender）
        let neededDescent = liftFont.ascender - (cmdFont.ascender + cmdFont.descender)
        let sink = max(0, neededDescent + liftFont.descender)   // descender 是负值
        for r in SlashCommands.matchedRanges(in: string) {
            // 斜杠留在文本里（发送时要靠它认命令），但设成透明 + 负字距。
            // 留 6pt：其中 4pt 是标签内边距，另 2pt 是标签跟前文的间距
            addAttributes([.foregroundColor: NSColor.clear,
                           .chipSlash: true,
                           .font: liftFont,
                           .baselineOffset: -sink,
                           .kern: -slashWidth + 6],
                          range: NSRange(location: r.location, length: 1))
            let name = NSRange(location: r.location + 1, length: r.length - 1)
            addAttributes([.foregroundColor: NSColor(Color(hex: "#E8A54B")),
                           .font: NSFont.systemFont(ofSize: fontSize),
                           .chipTag: fontSize],
                          range: name)
            // 末字加 6pt 字距，同样是 4pt 内边距 + 2pt 间距
            addAttribute(.kern, value: 6,
                         range: NSRange(location: name.location + name.length - 1, length: 1))
        }
    }
}
