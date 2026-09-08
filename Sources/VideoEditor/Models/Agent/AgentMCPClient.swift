// AgentMCPClient.swift
//
// 真正去连外部 MCP server，把对方的工具取回来、代为调用。
//
// 协议是 JSON-RPC 2.0，两种传输：
//   · stdio —— 拉起一个本地进程，一行一条 JSON 走 stdin / stdout
//   · http  —— POST 到一个地址，响应可能是纯 JSON，也可能是 SSE 流
//
// 握手三步：initialize → notifications/initialized → tools/list。
// 少发中间那条通知，多数 server 会一直卡在「没初始化完」，tools/list 直接报错。
//
// **stdio 必须走 login shell**：GUI 启动的 app 拿到的 PATH 只有
// /usr/bin:/bin:/usr/sbin:/sbin，npx / node / uvx 一个都找不着。
// 这跟 run_command 那边是同一个坑。

import Foundation

// MARK: - 数据

/// 对方给出的一个工具
struct MCPTool: Identifiable, Equatable {
    let serverID: UUID
    let serverName: String
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var id: String { serverID.uuidString + "/" + name }
    static func == (a: MCPTool, b: MCPTool) -> Bool { a.id == b.id }

    /// 喂给模型的名字。带上服务标识，两个服务有同名工具也不会撞；
    /// 模型那边只认 [A-Za-z0-9_-]，中文服务名要换掉
    var qualifiedName: String {
        let s = Self.slug(serverName, fallback: String(serverID.uuidString.prefix(6)))
        let t = Self.slug(name, fallback: "tool")
        return String("mcp__\(s)__\(t)".prefix(64))
    }

    private static func slug(_ s: String, fallback: String) -> String {
        let mapped = s.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || c == "-" ? c : "_"
        }
        let out = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? fallback : out
    }
}

enum MCPStatus: Equatable {
    case idle          // 还没连
    case connecting
    case ready(Int)    // 连上了，带回几个工具
    case failed(String)
}

enum MCPError: LocalizedError {
    case badURL
    case timeout
    case notRunning
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL:        return "地址填得不对"
        case .timeout:       return "等了 30 秒没回应"
        case .notRunning:    return "进程没起来"
        case .server(let m): return m
        }
    }
}

// MARK: - 一条连接

@MainActor
final class MCPConnection {

    let config: MCPServerConfig

    private var proc: Process?
    private var stdinHandle: FileHandle?
    /// stdout 的粘包缓冲。一次 read 可能带回半条、也可能带回三条
    private var buf = Data()
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextID = 1
    /// http 的会话号，server 在响应头里给，之后每次请求都要带
    private var httpSession: String?

    init(_ c: MCPServerConfig) { config = c }

    deinit { proc?.terminate() }

    // MARK: 连接

    /// 握手 + 取工具清单
    func connect() async throws -> [MCPTool] {
        if config.transport == .stdio { try startProcess() }

        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "BlackCat", "version": "5.8.5"],
        ])
        notify("notifications/initialized")

        let listed = try await request("tools/list", params: [:])
        guard let dict = listed as? [String: Any],
              let arr = dict["tools"] as? [[String: Any]] else { return [] }

        return arr.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return MCPTool(serverID: config.id,
                           serverName: config.name,
                           name: name,
                           description: t["description"] as? String ?? "",
                           inputSchema: t["inputSchema"] as? [String: Any]
                                     ?? ["type": "object", "properties": [:] as [String: Any]])
        }
    }

    func disconnect() {
        for (_, c) in pending { c.resume(throwing: MCPError.notRunning) }
        pending.removeAll()
        proc?.terminate()
        proc = nil
        stdinHandle = nil
        buf.removeAll()
        httpSession = nil
    }

    /// 调对方一个工具，把结果拼成一段文本
    func call(_ tool: String, args: [String: Any]) async throws -> String {
        let r = try await request("tools/call", params: ["name": tool, "arguments": args])
        guard let dict = r as? [String: Any] else { return "（没有返回内容）" }

        var parts: [String] = []
        for c in (dict["content"] as? [[String: Any]] ?? []) {
            switch c["type"] as? String {
            case "text":     parts.append(c["text"] as? String ?? "")
            case "image":    parts.append("（对方返回了一张图片，这里显示不了）")
            case "resource": parts.append("（对方返回了一个资源）")
            default:         break
            }
        }
        let text = parts.joined(separator: "\n")
        if dict["isError"] as? Bool == true {
            throw MCPError.server(text.isEmpty ? "工具执行出错" : text)
        }
        return text.isEmpty ? "（执行完毕，没有输出）" : text
    }

    // MARK: stdio

    private func startProcess() throws {
        let p = Process()
        // login shell：MCP server 大多是 npx / uvx 起的，那些命令只在
        // 用户自己的 PATH 里，GUI 进程的环境变量里没有
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", config.command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        for (k, v) in config.env { env[k] = v }
        p.environment = env

        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP
        p.standardOutput = outP
        p.standardError = errP

        outP.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.feed(d) }
        }
        // stderr 一定要读走。MCP server 普遍往这儿打日志，
        // 不读的话管道写满 64KB，对方就整个卡死了
        errP.fileHandleForReading.readabilityHandler = { _ = $0.availableData }

        try p.run()
        proc = p
        stdinHandle = inP.fileHandleForWriting
    }

    /// 按换行切出一条条完整的 JSON
    private func feed(_ d: Data) {
        buf.append(d)
        while let i = buf.firstIndex(of: 0x0A) {
            let line = Data(buf[buf.startIndex..<i])
            buf = Data(buf[buf.index(after: i)...])
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = obj["id"] as? Int,
              let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            cont.resume(throwing: MCPError.server(err["message"] as? String ?? "对方报错了"))
        } else {
            cont.resume(returning: obj["result"])
        }
    }

    // MARK: 收发

    private func request(_ method: String, params: [String: Any]) async throws -> Any? {
        if config.transport == .http { return try await requestHTTP(method, params: params) }

        guard let stdinHandle else { throw MCPError.notRunning }
        let id = nextID; nextID += 1
        var data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params])
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
                return
            }
            // 对方要是不回，continuation 就永远悬着，整个 Agent 也跟着卡住
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let c = self?.pending.removeValue(forKey: id) {
                    c.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    private func notify(_ method: String) {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method,
                                  "params": [:] as [String: Any]]
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        if config.transport == .stdio {
            d.append(0x0A)
            try? stdinHandle?.write(contentsOf: d)
        } else if let url = URL(string: config.command) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
            if let s = httpSession { req.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = d
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    private func requestHTTP(_ method: String, params: [String: Any]) async throws -> Any? {
        guard let url = URL(string: config.command), url.scheme != nil else { throw MCPError.badURL }
        let id = nextID; nextID += 1

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 两种都收：新版 server 走 SSE，老版直接给 JSON
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let s = httpSession { req.setValue(s, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params])

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { httpSession = s }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw MCPError.server("HTTP \(http.statusCode)"
                                      + (body.isEmpty ? "" : "：" + body.prefix(200)))
            }
        }
        return try parseResponse(data)
    }

    /// 响应可能是一坨 JSON，也可能是 SSE 的 `data: {...}` 行
    private func parseResponse(_ data: Data) throws -> Any? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any] {
                throw MCPError.server(err["message"] as? String ?? "对方报错了")
            }
            return obj["result"]
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        for raw in text.split(separator: "\n") {
            guard raw.hasPrefix("data:") else { continue }
            let json = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["id"] != nil else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw MCPError.server(err["message"] as? String ?? "对方报错了")
            }
            return obj["result"]
        }
        throw MCPError.server("响应格式看不懂")
    }
}
