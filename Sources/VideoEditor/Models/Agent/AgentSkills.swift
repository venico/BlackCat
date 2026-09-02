// AgentSkills.swift
//
// Skills：一个文件夹 + 一份 SKILL.md 说明书，可以带脚本和素材。
//
// 存在 ~/Library/Application Support/黑猫剪辑/Skills/<名字>/ 下，
// 每次打开设置扫一遍目录 —— 用户自己往里拖一个文件夹就能生效，
// 不需要经过什么导入流程。
//
// **说明书本身不带能力**：它写的是「这件事按什么步骤、用哪几个内置工具去做」。
// 带脚本的那种执行前要弹窗把命令原文给用户看。

import Foundation

struct AgentSkill: Identifiable, Equatable {
    var id: String { folderURL.path }
    var name: String
    var description: String
    var folderURL: URL
    /// SKILL.md 正文（去掉 frontmatter）
    var body: String
    /// 带不带可执行脚本。带的话执行前要确认
    var hasScripts: Bool
    var isEnabled: Bool = true
    /// frontmatter 里的 author，没写就显示「本地」
    var author: String = "本地"
    /// 文件夹的最后修改时间
    var updatedAt: Date = .distantPast
    var version: String = ""
}

@MainActor
final class AgentSkills: ObservableObject {
    static let shared = AgentSkills()

    @Published private(set) var skills: [AgentSkill] = []

    static var rootURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("黑猫剪辑/Skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let disabledKey = "settings.agent.skills.disabled"
    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: disabledKey) }
    }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: Self.rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        else { skills = []; return }

        var out: [AgentSkill] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let md = dir.appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: md, encoding: .utf8) else { continue }

            let (meta, body) = Self.parseFrontmatter(raw)
            let scripts = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .contains { ["sh", "py", "js", "command"].contains(($0 as NSString).pathExtension) } ?? false

            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            out.append(AgentSkill(
                name: meta["name"] ?? dir.lastPathComponent,
                description: meta["description"] ?? "",
                folderURL: dir,
                body: body,
                hasScripts: scripts,
                isEnabled: !disabled.contains(dir.lastPathComponent),
                author: meta["author"] ?? "本地",
                updatedAt: modified,
                version: meta["version"] ?? ""))
        }
        skills = out.sorted { $0.name < $1.name }
    }

    func setEnabled(_ on: Bool, for skill: AgentSkill) {
        var d = disabled
        let key = skill.folderURL.lastPathComponent
        if on { d.remove(key) } else { d.insert(key) }
        disabled = d
        reload()
    }

    /// 从别处拷一个 Skill 文件夹进来。**要求里面有 SKILL.md** ——
    /// 没有的话它对 Agent 就是一堆看不懂的文件
    @discardableResult
    func install(from source: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            return "请选一个文件夹"
        }
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            return "这个文件夹里没有 SKILL.md，装进来 Agent 也不知道拿它做什么"
        }
        let dest = Self.rootURL.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)   // 同名的按覆盖处理，等于更新
        }
        do { try fm.copyItem(at: source, to: dest) } catch { return error.localizedDescription }
        reload()
        return nil
    }

    func delete(_ skill: AgentSkill) {
        try? FileManager.default.removeItem(at: skill.folderURL)
        reload()
    }

    /// 拼进系统提示词的那一段。
    /// **只放名字和一句话说明**，正文按需再读 —— 十几个 Skill 的正文全塞进去，
    /// 光提示词就能把上下文吃掉一大半
    var promptSection: String {
        let on = skills.filter(\.isEnabled)
        guard !on.isEmpty else { return "" }
        var s = "\n\n可以用的 Skill（需要时用 read_skill 读它的完整说明再照着做）：\n"
        // 描述可能是长长一整段，提示词里只留头一句 —— 详情让它自己调 read_skill
        s += on.map { sk in
            let d = sk.description.components(separatedBy: "\n").first ?? sk.description
            return "· \(sk.name)：\(d.count > 160 ? String(d.prefix(160)) + "…" : d)"
        }.joined(separator: "\n")
        return s
    }

    /// 从 SKILL.md 里拆出 YAML frontmatter
    static func parseFrontmatter(_ raw: String) -> ([String: String], String) {
        guard raw.hasPrefix("---") else { return ([:], raw) }
        let parts = raw.components(separatedBy: "---")
        guard parts.count >= 3 else { return ([:], raw) }
        var meta: [String: String] = [:]
        let lines = parts[1].components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            // 只认顶格的键。缩进行和列表项是上一个键的内容，不是新键 ——
            // 不挡的话 `- research: 调研` 会被当成一个叫「- research」的键
            guard !line.isEmpty, line.first != " ", line.first != "\t", line.first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // YAML 折叠块：`description: >` 后面缩进的才是正文。
            // 不处理的话取到的值就是字面的一个「>」
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(v) {
                let folded = v.hasPrefix(">")
                var buf: [String] = []
                while i < lines.count {
                    let next = lines[i]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    // 空行还属于这一块；顶格的行说明块结束了
                    if !trimmed.isEmpty, next.first != " ", next.first != "\t" { break }
                    buf.append(trimmed)
                    i += 1
                }
                // `>` 把连续的行折成一段，空行才断段；`|` 原样保留换行
                v = folded
                    ? buf.reduce(into: [String]()) { acc, l in
                        if l.isEmpty { acc.append("") }
                        else if let last = acc.last, !last.isEmpty { acc[acc.count - 1] = last + " " + l }
                        else { acc.append(l) }
                      }.joined(separator: "\n")
                    : buf.joined(separator: "\n")
                v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !k.isEmpty { meta[k] = v }
        }
        return (meta, parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
