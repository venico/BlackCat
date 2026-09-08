// AgentMCP.swift
//
// 外部 MCP server 的配置。黑猫剪辑当客户端，把别人的工具接进来。
//
// 两种接法：
//   · stdio —— 本地拉一个进程（`npx xxx-mcp` 这类），配命令和参数
//   · http  —— 远程服务，配 URL 和请求头（放 token）
//
// 这里只管配置的存取；真正的连接和工具发现在 AgentMCPClient 里。

import Foundation

struct MCPServerConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var transport: Transport = .stdio
    /// stdio：可执行文件；http：完整 URL
    var command: String = ""
    /// stdio 才用
    var args: [String] = []
    var env: [String: String] = [:]
    /// http 才用，放 Authorization 这类
    var headers: [String: String] = [:]
    var isEnabled: Bool = true
    /// 一句话说明它能干什么。中英各一句，跟 Skill 那边一个约定 ——
    /// 列表里只露中文，鼠标停上去两句都给
    var descZh: String = ""
    var descEn: String = ""
    /// 触发词。用户话里出现其中之一，这个服务的工具才会挂给模型。
    /// 留空就拿服务名和工具名去碰
    var keywords: [String] = []

    enum Transport: String, Codable, CaseIterable {
        case stdio = "本地进程"
        case http = "远程 HTTP"
    }
}

@MainActor
final class AgentMCP: ObservableObject {
    static let shared = AgentMCP()

    @Published var servers: [MCPServerConfig] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("黑猫剪辑", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-servers.json")
    }()

    // MARK: 连接状态（设置页读这几个）

    /// 每个服务连没连上
    @Published private(set) var status: [UUID: MCPStatus] = [:]
    /// 每个服务带回来的工具
    @Published private(set) var tools: [UUID: [MCPTool]] = [:]

    private var connections: [UUID: MCPConnection] = [:]
    /// 这次开机连过一轮没有。Agent 每次开跑都调 ensureConnected，
    /// 不记一笔的话每轮都要重连一遍，慢且没必要
    private var didAutoConnect = false

    private init() { load() }

    func add() {
        servers.append(MCPServerConfig(name: "新服务"))
    }

    func remove(_ id: UUID) {
        connections[id]?.disconnect()
        connections[id] = nil
        status[id] = nil
        tools[id] = nil
        servers.removeAll { $0.id == id }
    }

    // MARK: 连接

    /// 连一个。已经连着的先断开重来（改完配置点「连接」就走这条）
    func connect(_ id: UUID) async {
        guard let cfg = servers.first(where: { $0.id == id }) else { return }
        connections[id]?.disconnect()
        connections[id] = nil
        tools[id] = []

        guard cfg.isEnabled else { status[id] = .idle; return }
        guard !cfg.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            status[id] = .failed("还没填命令或地址")
            return
        }

        status[id] = .connecting
        let conn = MCPConnection(cfg)
        connections[id] = conn
        do {
            let list = try await conn.connect()
            tools[id] = list
            status[id] = .ready(list.count)
        } catch {
            conn.disconnect()
            connections[id] = nil
            status[id] = .failed(error.localizedDescription)
        }
    }

    /// 全部连一遍（设置页打开、或用户点「全部重连」）
    func connectAll() async {
        didAutoConnect = true
        for s in servers { await connect(s.id) }
    }

    /// Agent 开跑前调一下：只在这次开机的头一回真去连
    func ensureConnected() async {
        guard !didAutoConnect else { return }
        await connectAll()
    }

    /// 所有连上的服务给出的工具，拉平成一张表
    var readyTools: [MCPTool] {
        servers.filter(\.isEnabled).flatMap { tools[$0.id] ?? [] }
    }

    // MARK: 按需挂载

    /// 这轮对话里已经被点到的服务。
    ///
    /// **不能把所有服务的工具一股脑全给模型**：几个服务开着就是上百个工具，
    /// 每个还带一大段说明和 JSON Schema，请求被工具定义塞满之后模型就迷了 ——
    /// 实测表现是连内置的 remember 都不调，直接口头回一句「已记住」。
    /// 所以按用户这句话里的关键词挂，用得上哪个给哪个。
    ///
    /// 命中之后**留到这轮会话结束**：说完「打开这个网页」再说「点一下登录按钮」，
    /// 第二句不该突然没工具了
    @Published private(set) var activated: Set<UUID> = []

    /// 拿用户这句话去碰各个服务的触发词
    func activate(matching prompt: String) {
        let text = prompt.lowercased()
        for s in servers where s.isEnabled && !activated.contains(s.id) {
            guard let list = tools[s.id], !list.isEmpty else { continue }
            var keys = s.keywords
            if keys.isEmpty {
                // 没配触发词的（用户自己加的服务）：拿服务名和工具名去碰
                keys = [s.name] + list.map(\.name)
            }
            keys.append(s.name)     // 直接点名永远算数
            if keys.contains(where: { !$0.isEmpty && text.contains($0.lowercased()) }) {
                activated.insert(s.id)
            }
        }
    }

    /// 换会话时清一次，别把上一段对话点亮的服务带过来
    func resetActivation() { activated.removeAll() }

    /// 模型自己判断要用某个服务时调这个把工具挂进来。
    ///
    /// **光靠关键词不够**：用户甩个链接说「看看这上面写了啥」，
    /// 一个触发词都碰不上，但显然要用浏览器。所以两条路一起走 ——
    /// 话里点到就自动挂，没点到但模型觉得需要，它自己调这个
    func enable(named: String) -> AgentToolResult {
        let want = named.trimmingCharacters(in: .whitespaces).lowercased()
        let live = servers.filter { $0.isEnabled && !(tools[$0.id] ?? []).isEmpty }
        guard let s = live.first(where: { $0.name.lowercased() == want })
                   ?? live.first(where: { $0.name.lowercased().contains(want)
                                       || want.contains($0.name.lowercased()) }) else {
            return .fail(live.isEmpty
                ? "现在一个外部服务都没连上。"
                : "没有叫「\(named)」的服务。能用的有：" + live.map(\.name).joined(separator: "、"))
        }
        let list = tools[s.id] ?? []
        activated.insert(s.id)
        let names = list.prefix(12).map(\.name).joined(separator: "、")
        return .ok("已挂上「\(s.name)」的 \(list.count) 个工具：\(names)\(list.count > 12 ? " 等" : "")。"
                 + "接着往下做，这些工具现在就能调了。")
    }

    /// 拼进系统提示词的那一段：有哪些外部服务可以要
    var promptSection: String {
        let live = servers.filter { $0.isEnabled && !(tools[$0.id] ?? []).isEmpty }
        guard !live.isEmpty else { return "" }
        var s = "\n\n还接了这些外部服务。**默认不挂在你手上** —— "
              + "判断这件事要用到哪个，先调 enable_service 把它的工具要过来，下一步就能用：\n"
        s += live.map { srv in
            let n = (tools[srv.id] ?? []).count
            let d = srv.descZh.isEmpty ? "" : "：" + srv.descZh
            return "· \(srv.name)\(d)（\(n) 个工具）"
        }.joined(separator: "\n")
        return s
    }

    /// 这轮该挂给模型的外部工具
    var activeTools: [MCPTool] {
        servers.filter { $0.isEnabled && activated.contains($0.id) }
               .flatMap { tools[$0.id] ?? [] }
    }

    /// 按模型给的名字找到对应的工具并调用
    func call(qualified: String, args: [String: Any]) async -> AgentToolResult {
        guard let t = readyTools.first(where: { $0.qualifiedName == qualified }) else {
            return .fail("没有叫 \(qualified) 的外部工具，可能那个服务掉线了。")
        }
        guard let conn = connections[t.serverID] else {
            return .fail("「\(t.serverName)」还没连上。")
        }
        do {
            return .ok(try await conn.call(t.name, args: args))
        } catch {
            return .fail("「\(t.serverName)」的 \(t.name) 执行失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return }
        servers = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
