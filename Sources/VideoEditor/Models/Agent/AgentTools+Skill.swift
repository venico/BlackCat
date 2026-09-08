// AgentTools+Skill.swift
//
// Skill 的调用：列表在系统提示词里（只有名字和一句话），正文按需读。
//
// **不把所有 SKILL.md 的正文都塞进提示词** —— 十几个 Skill 的正文加起来
// 能把上下文吃掉一大半，而一次对话通常只用得上其中一个。

import Foundation

extension AgentToolbox {

    static var skillTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "read_skill",
                description: """
                读一个 Skill 的完整说明。系统提示词里只列了名字和一句话简介，\
                觉得某个 Skill 对眼下这件事有用，就先读它，再按里面写的步骤做。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Skill 的名字"]
                    ] as [String: Any],
                    "required": ["name"]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "run_skill_script",
                description: """
                跑 Skill 文件夹里的一个脚本。**只有 SKILL.md 明确要求时才用**，\
                用户会看到完整命令并决定放不放行。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "skill": ["type": "string", "description": "哪个 Skill"],
                        "script": ["type": "string", "description": "脚本文件名，例如 build.sh"],
                        "args": ["type": "array", "items": ["type": "string"],
                                 "description": "命令行参数"]
                    ] as [String: Any],
                    "required": ["skill", "script"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "install_skill",
                description: """
                装一个新 Skill 进来。给 GitHub（或任意 git）仓库地址就行，会克隆下来、
                找出里面带 SKILL.md 的文件夹装上，同名的按更新覆盖。
                **用户给的地址原样传，别删掉 /tree/… 那段子路径** —— 那段就是他要的那一个。
                仓库里不止一个 Skill 时，工具会把清单退回来让你问用户装哪几个，
                别自己替他决定；他答复之后用 only 点名，说了「全都装」才用 all。
                **别自己去读网页再拼文件** —— 用这个工具，一步到位。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "repo": ["type": "string",
                                 "description": "仓库地址，例如 https://github.com/someone/some-skill。用户给的原样传，别删子路径"],
                        "only": ["type": "array", "items": ["type": "string"],
                                 "description": "只装这几个（文件夹名）。仓库里有多个时用它点名"],
                        "all": ["type": "boolean",
                                "description": "整仓库全装。只有用户明确说了「全都装」才传 true"]
                    ] as [String: Any],
                    "required": ["repo"]
                ],
                risk: .mutating),
        ]
    }

    @MainActor
    static func runSkillTool(_ name: String, args: [String: Any]) async -> AgentToolResult? {
        switch name {
        case "install_skill":
            guard let repo = (args["repo"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty else {
                return .fail("缺 repo，给个 git 仓库地址")
            }
            let only = (args["only"] as? [String]) ?? []
            let all  = (args["all"] as? Bool) ?? false
            let msg = await AgentSkills.shared.installFromGit(repo, only: only, all: all)
            // 「先别急着装」是让模型回头问用户，不是出错 —— 标成 fail 的话
            // 会话里那一步会显示成红的，模型也容易当成失败去重试
            let okish = msg.hasPrefix("装好了") || msg.hasPrefix("先别急着装")
            return okish ? .ok(msg) : .fail(msg)

        case "read_skill":
            guard let want = args["name"] as? String else { return .fail("缺 name") }
            guard let sk = AgentSkills.shared.skills.first(where: {
                $0.isEnabled && ($0.name == want || $0.folderURL.lastPathComponent == want)
            }) else {
                let names = AgentSkills.shared.skills.filter(\.isEnabled).map(\.name)
                return .fail(names.isEmpty
                    ? "现在一个 Skill 都没装。"
                    : "没有叫「\(want)」的 Skill。现有这些：\(names.joined(separator: "、"))")
            }
            var s = "# \(sk.name)\n\(sk.body)"
            if sk.hasScripts,
               let files = try? FileManager.default.contentsOfDirectory(atPath: sk.folderURL.path) {
                let scripts = files.filter { ["sh", "py", "js", "command"].contains(($0 as NSString).pathExtension) }
                if !scripts.isEmpty {
                    s += "\n\n这个 Skill 带的脚本：\(scripts.joined(separator: "、"))"
                }
            }
            return .ok(s)

        case "run_skill_script":
            guard let skillName = args["skill"] as? String,
                  let script = args["script"] as? String else { return .fail("缺 skill 或 script") }
            guard let sk = AgentSkills.shared.skills.first(where: {
                $0.isEnabled && ($0.name == skillName || $0.folderURL.lastPathComponent == skillName)
            }) else { return .fail("没有叫「\(skillName)」的 Skill。") }

            // **只准跑这个 Skill 文件夹里的东西**。名字里带路径分隔符的一律拒绝，
            // 否则 ../../ 就能指到文件系统任意位置
            guard !script.contains("/"), !script.contains("..") else {
                return .fail("脚本名里不能带路径，只能是这个 Skill 文件夹里的文件名。")
            }
            let url = sk.folderURL.appendingPathComponent(script)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .fail("「\(sk.name)」里没有 \(script) 这个文件。")
            }
            let argv = (args["args"] as? [String]) ?? []
            return await runScript(at: url, args: argv, workDir: sk.folderURL)

        default: return nil
        }
    }

    /// 起个进程把脚本跑了。超时 120 秒 —— 卡死的话整轮对话就废在那儿了
    private static func runScript(at url: URL, args: [String], workDir: URL) async -> AgentToolResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "py": p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                           p.arguments = ["python3", url.path] + args
                case "js": p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                           p.arguments = ["node", url.path] + args
                default:   p.executableURL = URL(fileURLWithPath: "/bin/bash")
                           p.arguments = [url.path] + args
                }
                p.currentDirectoryURL = workDir
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe

                do { try p.run() } catch {
                    cont.resume(returning: .fail("起不来这个脚本：\(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchTime.now() + .seconds(120)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                let text = out.isEmpty ? "（没有输出）" : String(out.prefix(4000))
                cont.resume(returning: p.terminationStatus == 0
                    ? .ok("脚本跑完了，退出码 0。输出：\n\(text)")
                    : .fail("脚本退出码 \(p.terminationStatus)。输出：\n\(text)"))
            }
        }
    }
}
