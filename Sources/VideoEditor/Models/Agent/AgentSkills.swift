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
    /// 从哪个 git 仓库装来的。装的时候写进文件夹里的 .source，
    /// 设置页按它把同一个仓库的归成一组
    var source: String = ""
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
                version: meta["version"] ?? "",
                source: (try? String(contentsOf: dir.appendingPathComponent(".source"),
                                     encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
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

    /// 从 git 仓库装。支持三种情形：
    ///   · 仓库根目录就是一个 Skill（根下有 SKILL.md）
    ///   · 仓库里一堆 Skill，各占一个子目录
    ///   · 都放在 skills/ 之类的二级目录下
    ///
    /// **不让 Agent 自己去读网页再拼文件** —— 那样一整个 README 会灌进对话，
    /// 请求体撑大之后走中转站极容易半路断掉（用户遇到的「网络连接已中断」就是这么来的）
    /// `only` 点名只装哪几个，`all` = 用户明说了「全都装」。
    /// 两个都不给、仓库里又不止一个时，**不装**，把清单交回去让模型问用户
    func installFromGit(_ repo: String, only: [String] = [], all: Bool = false) async -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("skill-clone-" + UUID().uuidString)

        // 用户多半是从浏览器地址栏直接复制的，形如
        // https://github.com/owner/repo/tree/main/.claude/skills/xxx —— 那是**网页路径**，
        // git clone 不认。拆出真正的仓库地址，子目录留着待会儿只装那一块
        let (cloneURL, subPath) = Self.splitRepoURL(repo)
        let clone = await Self.run("git clone --depth 1 \(cloneURL) \(tmp.path)")
        guard clone.code == 0 else {
            return "克隆失败：" + (clone.out.isEmpty ? "git 没给出原因" : clone.out)
        }
        defer { try? fm.removeItem(at: tmp) }

        // 找出带说明书的文件夹。**别只认死 SKILL.md** —— 各家仓库摆法不一样：
        // 有的在根，有的在 skills/xxx/ 下，Claude Code 那套在 .claude/skills/ 里，
        // 大小写也不一定。往下翻四层，把这些都认了
        // 地址里点名了子目录就只在那儿找，没点名才翻整个仓库
        let scope = subPath.isEmpty ? tmp : tmp.appendingPathComponent(subPath)
        let root = fm.fileExists(atPath: scope.path) ? scope : tmp
        let found = Self.findSkillFolders(under: root, fm: fm)
        guard !found.isEmpty else {
            // 找不到就**把仓库长什么样告诉模型**，让它自己判断怎么装 ——
            // 它手上有 run_command，完全可以自己挑一个 md 改名、或者只取其中一部分。
            // 直接回一句「没找到 SKILL.md」等于把路堵死
            let tree = Self.fileTree(root, fm: fm, limit: 60)
            return """
            没找到 SKILL.md（认 SKILL.md / skill.md，根目录、子目录、\
            skills/、.claude/skills/ 都翻过了）。仓库结构如下，\
            你可以自己判断该怎么装 —— 比如用 run_command 把某个说明文件复制成
            \(Self.rootURL.path)/<名字>/SKILL.md，再让用户重开设置页看看：

            \(tree)
            """
        }

        // 点名了就只装点名的那几个
        var picked = found
        if !only.isEmpty {
            let want = Set(only.map { $0.lowercased() })
            picked = found.filter { want.contains($0.lastPathComponent.lowercased()) }
            if picked.isEmpty {
                return "仓库里没有叫「\(only.joined(separator: "、"))」的 Skill。这个仓库里有：\n"
                     + found.map { "\u{00B7} " + $0.lastPathComponent }.joined(separator: "\n")
            }
        } else if found.count > 1, !all {
            // **一个仓库里多个 Skill 时不许闷头全装**。26/9/8 出过事：用户说的是
            // 「装 .../tree/main/skills/skill-creator」，模型调工具时把地址删成了
            // 仓库根，这儿就把整仓库 20 个全拷进来了，用户根本没答应过。
            // 现在改成先把清单交回去，让模型拿着去问用户
            let list = found.map { "\u{00B7} " + $0.lastPathComponent }.joined(separator: "\n")
            return """
            先别急着装 \u{2014} 这个仓库里有 \(found.count) 个 Skill：

            \(list)

            **把这份清单告诉用户，问他要装哪几个**，等他回话再调一次 install_skill，
            用 only 点名（例如 only: ["skill-creator"]）。
            他明确说了「全都装」才传 all: true。
            另外：用户给的地址带 /tree/... 子路径的话原样传，那一段就是他要的那一个。
            """
        }

        var names: [String] = []
        for src in picked {
            // 仓库根本身就是 Skill 时，文件夹名取仓库名
            let name = src == tmp
                ? (URL(string: repo)?.deletingPathExtension().lastPathComponent ?? "skill")
                : src.lastPathComponent
            let dest = Self.rootURL.appendingPathComponent(name)
            try? fm.removeItem(at: dest)          // 同名按覆盖处理，等于更新
            do {
                try fm.copyItem(at: src, to: dest)
                // .git 跟着拷进来没用，还占地方
                try? fm.removeItem(at: dest.appendingPathComponent(".git"))
                // 记一笔来源：设置页靠它把同一个仓库来的归到一组
                try? repo.write(to: dest.appendingPathComponent(".source"),
                                atomically: true, encoding: .utf8)
                names.append(name)
            } catch {
                return "拷贝 \(name) 失败：" + error.localizedDescription
            }
        }
        reload()

        // 把描述统一成「一句中文 + 一句英文」。装进来的说明多半是长长一段英文，
        // 设置面板和提示词里都只露第一行，不改的话看着就是一堆英文长句
        let rewritten = await rewriteDescriptions(for: names)
        reload()

        return "装好了：" + names.joined(separator: "、")
             + (rewritten > 0 ? "。已把其中 \(rewritten) 个的说明改成中英各一句" : "")
    }

    /// 让模型把这些 Skill 的说明压成中英各一句，写回各自的 SKILL.md。
    ///
    /// **一次请求处理全部**，不是一个一个问 —— 装一个仓库动辄二十来个，
    /// 挨个发请求又慢又费。失败就保持原样，不影响装好这件事
    @discardableResult
    private func rewriteDescriptions(for names: [String]) async -> Int {
        let targets = skills.filter { names.contains($0.folderURL.lastPathComponent) }
        // 已经是两行的（多半是之前改过），不用再动
        let todo = targets.filter { sk in
            sk.description.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count < 2
        }
        guard !todo.isEmpty else { return 0 }

        let listing = todo.map { sk in
            let d = sk.description.replacingOccurrences(of: "\n", with: " ")
            return "- \(sk.folderURL.lastPathComponent)：\(d.prefix(400))"
        }.joined(separator: "\n")

        let prompt = """
        下面是一批 Skill 的原始说明。给每个写一句**简短的中文介绍**和一句**简短的英文介绍**，        各不超过 30 个字 / 12 个词，说清楚它是干什么的、什么时候用。

        只返回 JSON，形如：
        {"文件夹名": {"zh": "中文一句", "en": "English one line"}, ...}
        不要写 ``` 代码围栏，不要有别的话。

        \(listing)
        """

        guard let turn = try? await AgentLLM.send(messages: [.user(prompt, images: [])],
                                                  tools: [], systemPrompt: "你是个中英双语的技术编辑。"),
              let json = Self.extractJSON(turn.text) else { return 0 }

        var n = 0
        for sk in todo {
            let key = sk.folderURL.lastPathComponent
            guard let pair = json[key] as? [String: Any],
                  let zh = (pair["zh"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let en = (pair["en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !zh.isEmpty, !en.isEmpty else { continue }
            if Self.replaceDescription(at: sk.folderURL, zh: zh, en: en) { n += 1 }
        }
        return n
    }

    /// 模型偶尔会套一层 ``` 或者前后多两句话，把最外层那对花括号抠出来
    private static func extractJSON(_ text: String) -> [String: Any]? {
        guard let l = text.firstIndex(of: "{"), let r = text.lastIndex(of: "}"), l < r else { return nil }
        let slice = String(text[l...r])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    /// 改写 SKILL.md 里 frontmatter 的 description。
    /// 用 `|` 块保留换行 —— 用 `>` 的话中英会被折成一行
    private static func replaceDescription(at folder: URL, zh: String, en: String) -> Bool {
        let md = folder.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: md, encoding: .utf8) else { return false }
        let parts = raw.components(separatedBy: "---")
        guard raw.hasPrefix("---"), parts.count >= 3 else { return false }

        var out: [String] = []
        let lines = parts[1].components(separatedBy: "\n")
        var i = 0
        var replaced = false
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("description:") {
                i += 1
                // 这一块后面所有缩进行 / 空行都属于它
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                        || lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                    i += 1
                }
                out += ["description: |", "  " + zh, "  " + en]
                replaced = true
            } else {
                out.append(line)
                i += 1
            }
        }
        guard replaced else { return false }
        let rebuilt = "---" + out.joined(separator: "\n") + "---"
                    + parts[2...].joined(separator: "---")
        try? rebuilt.write(to: md, atomically: true, encoding: .utf8)
        return true
    }

    /// 把 GitHub / GitLab 的网页地址拆成「能 clone 的仓库地址」+「子目录」。
    /// `https://github.com/o/r/tree/main/a/b` → (`https://github.com/o/r.git`, `a/b`)
    private static func splitRepoURL(_ raw: String) -> (String, String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["/tree/", "/blob/"] {
            guard let r = s.range(of: marker) else { continue }
            let repo = String(s[s.startIndex..<r.lowerBound])
            // marker 后面是「分支名/子路径」，砍掉头一段分支名
            let rest = String(s[r.upperBound...]).split(separator: "/", maxSplits: 1)
            let sub = rest.count > 1 ? String(rest[1]) : ""
            return (repo + ".git", sub)
        }
        return (s, "")
    }

    /// 翻出所有带说明书的文件夹。往下最多四层，够覆盖 skills/xxx/ 和 .claude/skills/xxx/
    private static func findSkillFolders(under root: URL, fm: FileManager) -> [URL] {
        var out: [URL] = []
        func hasSkillMD(_ dir: URL) -> Bool {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            return names.contains { $0.lowercased() == "skill.md" }
        }
        func walk(_ dir: URL, depth: Int) {
            if hasSkillMD(dir) { out.append(dir); return }   // 命中就不再往里翻
            guard depth < 4 else { return }
            for sub in (try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                let n = sub.lastPathComponent
                // .git 之类跳过，但 .claude 要进 —— Claude Code 的 skill 就放那儿
                if n.hasPrefix("."), n != ".claude" { continue }
                if ["node_modules", "vendor", "dist", "build"].contains(n) { continue }
                walk(sub, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }

    /// 仓库长什么样，报给模型自己判断
    private static func fileTree(_ root: URL, fm: FileManager, limit: Int) -> String {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return "（读不出目录）"
        }
        var lines: [String] = []
        for case let u as URL in e {
            let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
            if rel.hasPrefix(".git/") { continue }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            lines.append(isDir ? rel + "/" : rel)
            if lines.count >= limit { lines.append("……（还有更多，没列完）"); break }
        }
        return lines.joined(separator: "\n")
    }

    /// 跑一条命令，拿退出码和合并输出
    private static func run(_ cmd: String) async -> (code: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", cmd]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (1, error.localizedDescription)); return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(120)) {
                    if p.isRunning { p.terminate() }
                }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus,
                                        String(data: d, encoding: .utf8) ?? ""))
            }
        }
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
