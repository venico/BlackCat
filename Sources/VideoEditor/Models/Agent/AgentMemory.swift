// AgentMemory.swift
//
// Agent 的记忆。分两层：
//   · **全局**：跟着人走的工作习惯 —— 字幕爱用什么字号、导出偏好、剪辑节奏。
//     存 Application Support，所有项目共享
//   · **项目**：这个片子自己的设定 —— 主角叫什么、基调是什么、素材命名规矩。
//     存进 .bcj，换个项目就不该再提
//
// 写入是 Agent 自己判断的（用户说「以后字幕都用 2 号黑体」它就记下来），
// 但用户在设置里能看到每一条、能改能删 —— 记错了不能只能干瞪眼。

import Foundation

struct MemoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var createdAt = Date()
    /// 用户手动改过的。Agent 更新同类记忆时不覆盖它
    var isPinned = false
}

@MainActor
final class AgentMemory: ObservableObject {
    static let shared = AgentMemory()

    /// 跟着人走
    @Published private(set) var global: [MemoryEntry] = []
    /// 跟着项目走。由 ProjectState 在打开/保存项目时灌进来
    @Published var project: [MemoryEntry] = [] {
        didSet { Self.projectSnapshot = project }
    }

    /// 项目层记忆的跨线程快照。
    /// ProjectState 不是 @MainActor，存盘那条路上取不到 @Published 的值，
    /// 每次改动同步一份到这里给它读
    nonisolated(unsafe) static var projectSnapshot: [MemoryEntry] = []

    /// 记忆文件所在的文件夹。设置里那个小文件夹图标点开的就是它
    static var folderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("黑猫剪辑", isDirectory: true)
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("黑猫剪辑", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-memory.json")
    }()

    private init() { loadGlobal() }

    // MARK: - 读写

    func addGlobal(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !global.contains(where: { $0.text == t }) else { return }
        global.append(MemoryEntry(text: t))
        // 别让它无限长下去：太多条会把上下文撑爆，也会互相矛盾
        if global.count > 60 { global.removeFirst(global.count - 60) }
        saveGlobal()
    }

    func addProject(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !project.contains(where: { $0.text == t }) else { return }
        project.append(MemoryEntry(text: t))
        if project.count > 60 { project.removeFirst(project.count - 60) }
    }

    /// 按内容删掉一条。给开头几个字就行，找不着就把现有的列出来让模型重挑
    func forget(matching text: String, isGlobal: Bool) -> AgentToolResult {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = isGlobal ? global : project
        guard let hit = list.first(where: { $0.text.contains(key) || key.contains($0.text) }) else {
            return .fail(list.isEmpty
                ? "这里本来就没记东西。"
                : "没找到「\(key)」。现在记着：" + list.map(\.text).joined(separator: " / "))
        }
        remove(id: hit.id, isGlobal: isGlobal)
        return .ok("忘掉了：\(hit.text)")
    }

    func update(id: UUID, text: String, isGlobal: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isGlobal {
            guard let i = global.firstIndex(where: { $0.id == id }) else { return }
            global[i].text = t
            global[i].isPinned = true   // 手动改过就钉住，Agent 不再动它
            saveGlobal()
        } else {
            guard let i = project.firstIndex(where: { $0.id == id }) else { return }
            project[i].text = t
            project[i].isPinned = true
        }
    }

    func remove(id: UUID, isGlobal: Bool) {
        if isGlobal { global.removeAll { $0.id == id }; saveGlobal() }
        else { project.removeAll { $0.id == id } }
    }

    func clear(isGlobal: Bool) {
        if isGlobal { global.removeAll(); saveGlobal() } else { project.removeAll() }
    }

    // MARK: - 喂给模型

    /// 拼进系统提示词的那一段。两层都没有就返回空串
    var promptSection: String {
        guard AppSettings.shared.agentMemoryEnabled else { return "" }
        var s = ""
        if !global.isEmpty {
            s += "\n\n关于这位用户（他的长期习惯，除非这次明说，否则照着来）：\n"
            s += global.map { "· \($0.text)" }.joined(separator: "\n")
        }
        if !project.isEmpty {
            s += "\n\n关于当前这个项目：\n"
            s += project.map { "· \($0.text)" }.joined(separator: "\n")
        }
        return s
    }

    // MARK: - 落盘

    private func loadGlobal() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        global = list
    }

    private func saveGlobal() {
        guard let data = try? JSONEncoder().encode(global) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
