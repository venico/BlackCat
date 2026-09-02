// AgentTools+Shell.swift
//
// 通用的「跑一条命令」。
//
// Claude Code 生态里的 Skill 大多是这么写的：SKILL.md 里给一串命令，
// 让你照着敲。没有这个口子，那类 Skill 一条都跑不了。
//
// 代价也直白 —— 等于把 shell 交给模型。定成 mutating：计划模式禁用，
// 自动模式直接跑。**不是 dangerous** —— Skill 一次任务动辄十几条命令，
// 每条都弹一次确认，人就只剩点确认这一件事可干了。

import Foundation

extension AgentToolbox {

    static var shellTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "run_command",
                description: """
                在用户的 Mac 上跑一条命令，拿到标准输出。Skill 说明书里让你敲什么就敲什么，\
                别自己发明命令。装软件、改 shell 配置这类会动到环境的命令能跑，\
                但要看当前模式：自动模式先把要跑什么说清楚、问用户一句；全权模式直接做。\
                删文件和往外发东西这两类，任何模式下都先问。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string",
                                    "description": "完整的命令行，例如 agent-reach doctor --json"],
                        "purpose": ["type": "string",
                                    "description": "一句话说明这条命令要拿什么，会显示在执行步骤里"]
                    ] as [String: Any],
                    "required": ["command"]
                ],
                risk: .mutating),
        ]
    }

    static func runShellTool(_ name: String, args: [String: Any]) async -> AgentToolResult? {
        guard name == "run_command" else { return nil }
        guard let cmd = args["command"] as? String,
              !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("没给 command。")
        }
        return await runShell(cmd)
    }

    /// 超时 180 秒。搜索类命令比脚本慢，120 秒不够用
    private static func runShell(_ cmd: String) async -> AgentToolResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                // **login shell** —— Skill 依赖的 CLI 大多装在 ~/.local/bin
                // 或 nvm 目录下，非 login 的 PATH 里根本没有它们
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", cmd]
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe

                do { try p.run() } catch {
                    cont.resume(returning: .fail("命令起不来：\(error.localizedDescription)"))
                    return
                }
                var timedOut = false
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(180)) {
                    guard p.isRunning else { return }
                    timedOut = true
                    p.terminate()
                    // 有些进程不理 SIGTERM，再补一刀，不然管道那头一直不闭合
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                // 输出太长会把上下文顶掉，掐头留尾各一半 —— 报错信息通常在末尾
                let text: String
                if out.count > 8000 {
                    text = String(out.prefix(5000)) + "\n……（中间省略 \(out.count - 8000) 字）……\n"
                         + String(out.suffix(3000))
                } else {
                    text = out.isEmpty ? "（没有输出）" : out
                }
                if timedOut {
                    cont.resume(returning: .fail("命令跑了 180 秒还没完，已经掐断。已有输出：\n\(text)"))
                    return
                }
                cont.resume(returning: p.terminationStatus == 0
                    ? .ok(text)
                    : .fail("退出码 \(p.terminationStatus)：\n\(text)"))
            }
        }
    }
}
