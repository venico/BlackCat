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

    private init() { load() }

    func add() {
        servers.append(MCPServerConfig(name: "新服务"))
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
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
