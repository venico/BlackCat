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
    /// 当前能用的全部命令
    @MainActor
    static func all() -> [SlashCommand] {
        AgentSkills.shared.skills
            .filter(\.isEnabled)
            .map { SlashCommand(name: slug($0.name), detail: $0.description, kind: .skill) }
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { i, cmd in
                Button { onPick(cmd) } label: {
                    HStack(spacing: 7) {
                        Text("/" + cmd.name)
                            .font(.system(size: 13))
                            .foregroundColor(Color.labelPrimary)
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
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        // 跟 AI 下拉那种系统菜单同一套材质：.menu + 同窗口内混合
        .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.systemSeparator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .frame(maxWidth: 340, alignment: .leading)
    }
}


// MARK: - 命令标签

extension NSAttributedString.Key {
    /// 标了这个的字符会被画成一枚圆角标签
    static let chipTag = NSAttributedString.Key("blackcat.chipTag")
}

/// 给 `.chipTag` 那几段画圆角底。
///
/// 纯属性做不出标签：`.backgroundColor` 是方角、贴着字、也没有内边距。
/// 底色只能自己在这一层画。
final class ChipLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.chipTag, in: charRange) { value, range, _ in
            guard let fontSize = value as? CGFloat else { return }
            // 高度按字体本身算，不跟着整行走 —— 行高取的是该行最高的那个字体，
            // 中英混排的行比纯 ASCII 的行高出一截，同一个标签在气泡里和
            // 输入框里就会一大一小
            let f = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let wanted = ceil(f.ascender - f.descender) + 4   // 上下各 2pt
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: gr,
                                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                // 左右 4pt、上下 2pt 内边距。
                // base.width 里含名字末尾那 6pt 字距 —— 拿掉它、左右各补 4pt，
                // 剩的 2pt 就是标签跟后文的间距。
                // 纵向 base 是整行的高（含行距），本身就比字高出约 2pt，直接用
                let base = rect.offsetBy(dx: origin.x, dy: origin.y)
                // 高度不能超过这一行 —— 超出去的部分会被 textView 裁掉，
                // 表现就是第一行的标签顶上被削平
                let chipH = min(wanted, base.height)
                let r = NSRect(x: base.minX - 4,
                               y: base.minY + (base.height - chipH) / 2,
                               width: base.width + 2, height: chipH)
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
        let slashFont = NSFont.systemFont(ofSize: fontSize)
        let slashWidth = ("/" as NSString).size(withAttributes: [.font: slashFont]).width
        for r in SlashCommands.matchedRanges(in: string) {
            // 斜杠留在文本里（发送时要靠它认命令），但设成透明 + 负字距。
            // 留 6pt：其中 4pt 是标签内边距，另 2pt 是标签跟前文的间距
            addAttributes([.foregroundColor: NSColor.clear,
                           .kern: -slashWidth + 6],
                          range: NSRange(location: r.location, length: 1))
            let name = NSRange(location: r.location + 1, length: r.length - 1)
            addAttributes([.foregroundColor: NSColor(Color(hex: "#E8A54B")),
                           .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                           .chipTag: fontSize],
                          range: name)
            // 末字加 6pt 字距，同样是 4pt 内边距 + 2pt 间距
            addAttribute(.kern, value: 6,
                         range: NSRange(location: name.location + name.length - 1, length: 1))
        }
    }
}
