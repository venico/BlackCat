// AgentTools+Library.swift
//
// 素材库那一侧的工具：虚拟文件夹、重新关联丢失文件、署名、加进 AI 参考，
// 以及在线音乐 / 音效库（Openverse）的搜索、试听、收藏、下载上时间轴。
//
// 在线库这里**自己发请求**，不动素材库面板上的分类和列表 ——
// Agent 搜一下就把用户正在看的那页换掉，体验很怪。收藏、下载目录、播放器
// 跟面板共用一份（OnlineAudioStore），所以两边看到的收藏是同一套。

import AppKit
import Foundation

extension AgentToolbox {

    static var libraryTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "library_folder",
                description: """
                素材库的虚拟文件夹（只是分组，不动磁盘文件）。
                list 列出全部文件夹和各自有几个素材；create 新建（type 必填，可以顺手用 asset_ids 收进去）；
                rename 改名；move_assets 把素材放进 folder_id（不给 folder_id 就放回根一层）；
                move_folder 把文件夹挪到 parent_id 下面；color 改颜色；delete 删文件夹（里面的素材退到上一层，文件不删）；
                collect 把文件夹里的素材**复制**到磁盘上的 directory。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string",
                                   "enum": ["list", "create", "rename", "move_assets", "move_folder", "color", "delete", "collect"]],
                        "type": ["type": "string", "enum": ["video", "audio", "image", "subtitle"]],
                        "folder_id": ["type": "string"],
                        "parent_id": ["type": "string", "description": "上一级文件夹，不给就是根一层"],
                        "name": ["type": "string"],
                        "asset_ids": ["type": "array", "items": ["type": "string"]],
                        "color": ["type": "string", "description": "#RRGGBB，传 none 恢复默认"],
                        "directory": ["type": "string", "description": "collect 时复制到哪个文件夹（绝对路径）"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "relink_asset",
                description: "素材文件被挪走了（素材库里显示丢失），把它重新指到新位置的文件上。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "asset_id": ["type": "string"],
                        "path": ["type": "string", "description": "新文件的绝对路径"]
                    ] as [String: Any],
                    "required": ["asset_id", "path"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "asset_attribution",
                description: "读一个素材的署名（CC BY 在线素材要求在成片里署名）。copy=true 顺带复制到剪贴板。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "asset_id": ["type": "string"],
                        "copy": ["type": "boolean"]
                    ] as [String: Any],
                    "required": ["asset_id"]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "add_to_ai_reference",
                description: "把素材库里的素材加进 AI 创作聊天框的参考内容（或首尾帧），用户接着用 AI 生成时会带上它。",
                parameters: [
                    "type": "object",
                    "properties": ["asset_id": ["type": "string"]] as [String: Any],
                    "required": ["asset_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "online_audio",
                description: """
                免费在线音乐 / 音效库（Openverse，只有可商用的 CC0、公共领域、CC BY）。**库是英文的，搜索词用英文**。
                search：kind=music 或 sfx，query 英文关键词，page 翻页；返回每条的 id。
                preview：试听（给用户听，你自己听不到）；stop：停止试听。
                favorite / unfavorite：收藏；favorites：列出收藏。
                add：下载并放到时间轴 time 秒处（CC BY 的会自动记下署名）；download：只下载进本地，不上时间轴。
                免登录额度每分钟 20 次、每天 200 次，别连着乱搜。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string",
                                   "enum": ["search", "preview", "stop", "favorite", "unfavorite", "favorites", "add", "download"]],
                        "kind": ["type": "string", "enum": ["music", "sfx"]],
                        "query": ["type": "string"],
                        "page": ["type": "integer"],
                        "id": ["type": "string", "description": "search 结果里的 id"],
                        "time": ["type": "number", "description": "add 时放到第几秒，不传就是播放头"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating)
        ]
    }

    /// 搜过的条目记在这，后面 preview / add 只给 id 就能找回来
    @MainActor private static var seenAudio: [String: OnlineAudioItem] = [:]

    @MainActor
    static func runLibraryTool(_ name: String, args: [String: Any],
                               project p: ProjectState) async -> AgentToolResult? {
        func s(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func asset(_ key: String?) -> MediaAsset? {
            guard let k = key, !k.isEmpty else { return nil }
            return p.mediaAssets.first { "\($0.id)".hasPrefix(k) }
        }
        switch name {
        case "library_folder":
            return libraryFolder(p, args: args)
        case "relink_asset":
            guard let a = asset(s("asset_id")) else { return .fail("找不到这个素材，先 list_assets 看 id。") }
            guard let path = s("path") else { return .fail("缺 path") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return .fail("「\(path)」不存在。") }
            p.relinkAsset(id: a.id, newURL: url)
            return .ok("「\(a.name)」重新指到了 \(url.path)。")
        case "asset_attribution":
            guard let a = asset(s("asset_id")) else { return .fail("找不到这个素材，先 list_assets 看 id。") }
            guard let text = a.attribution, !text.isEmpty else { return .ok("「\(a.name)」没有署名要求。") }
            if (args["copy"] as? Bool) == true {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return .ok("已复制到剪贴板：\(text)")
            }
            return .ok(text)
        case "add_to_ai_reference":
            guard let a = asset(s("asset_id")) else { return .fail("找不到这个素材，先 list_assets 看 id。") }
            switch AIVideoService.shared.acceptLibraryAsset(url: a.url) {
            case .reference: return .ok("「\(a.name)」加进 AI 参考内容了。")
            case .attachment: return .ok("「\(a.name)」加成 AI 附件了。")
            case .duplicate: return .ok("「\(a.name)」之前已经加过了。")
            case .unsupported: return .fail("这类文件 AI 聊天框收不了。")
            case .limitReached(let msg): return .fail(msg)
            }
        case "online_audio":
            return await onlineAudio(p, action: s("action") ?? "", kind: s("kind"), query: s("query"),
                                     page: (args["page"] as? Int) ?? 1, id: s("id"),
                                     time: (args["time"] as? Double) ?? (args["time"] as? Int).map(Double.init))
        default:
            return nil
        }
    }

    // MARK: - 文件夹

    @MainActor
    private static func libraryFolder(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let lib = MediaLibrary.shared
        func s(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func folder(_ key: String?) -> LibraryFolder? {
            guard let k = key, !k.isEmpty else { return nil }
            return lib.folders.first { $0.name == k } ?? lib.folders.first { "\($0.id)".hasPrefix(k) }
        }
        func subtree(_ id: UUID) -> Set<UUID> {
            var all: Set<UUID> = [id]
            var grew = true
            while grew {
                grew = false
                for f in lib.folders where !all.contains(f.id) {
                    if let par = f.parentID, all.contains(par) { all.insert(f.id); grew = true }
                }
            }
            return all
        }
        let assetKeys = (args["asset_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        let assetIDs = Set(assetKeys.compactMap { k in p.mediaAssets.first { "\($0.id)".hasPrefix(k) }?.id })

        switch s("action") ?? "" {
        case "list":
            guard !lib.folders.isEmpty else { return .ok("素材库里还没有文件夹。") }
            let lines = lib.folders.sorted { ($0.type.rawValue, $0.sortIndex) < ($1.type.rawValue, $1.sortIndex) }.map { f -> String in
                let n = p.mediaAssets.filter { $0.folderID == f.id }.count
                let par = f.parentID.flatMap { id in lib.folders.first { $0.id == id }?.name }
                return "- \(f.id.uuidString.prefix(8))「\(f.name)」\(f.type.label)，\(n) 个素材" + (par.map { "，在「\($0)」里" } ?? "")
            }
            return .ok(lines.joined(separator: "\n"))
        case "create":
            guard let t = s("type").flatMap(AssetType.init(rawValue:)) else { return .fail("create 要给 type") }
            let parent = folder(s("parent_id"))?.id
            let f = lib.makeFolder(type: t, parent: parent, collectingAssets: assetIDs)
            if let nm = s("name"), !nm.isEmpty, let i = lib.folders.firstIndex(where: { $0.id == f.id }) {
                lib.folders[i].name = nm
            }
            for i in p.mediaAssets.indices where assetIDs.contains(p.mediaAssets[i].id) {
                p.mediaAssets[i].folderID = f.id
            }
            return .ok("建好了文件夹「\(s("name") ?? f.name)」（id \(f.id.uuidString.prefix(8))）"
                       + (assetIDs.isEmpty ? "。" : "，收进去 \(assetIDs.count) 个素材。"))
        case "rename":
            guard let f = folder(s("folder_id")), let nm = s("name"), !nm.isEmpty,
                  let i = lib.folders.firstIndex(where: { $0.id == f.id }) else { return .fail("要给 folder_id 和 name") }
            lib.folders[i].name = nm
            return .ok("「\(f.name)」改名为「\(nm)」。")
        case "move_assets":
            guard !assetIDs.isEmpty else { return .fail("asset_ids 一个都没找到。") }
            let target = folder(s("folder_id"))
            if s("folder_id") != nil && target == nil { return .fail("找不到这个文件夹。") }
            for i in p.mediaAssets.indices where assetIDs.contains(p.mediaAssets[i].id) {
                p.mediaAssets[i].folderID = target?.id
            }
            return .ok("放了 \(assetIDs.count) 个素材到" + (target.map { "「\($0.name)」" } ?? "根一层") + "。")
        case "move_folder":
            guard let f = folder(s("folder_id")), let i = lib.folders.firstIndex(where: { $0.id == f.id }) else {
                return .fail("找不到这个文件夹。")
            }
            let target = folder(s("parent_id"))
            if let t = target, subtree(f.id).contains(t.id) { return .fail("不能把文件夹塞进它自己里面。") }
            lib.folders[i].parentID = target?.id
            let siblings = lib.folders.filter { $0.parentID == target?.id && $0.id != f.id }
            lib.folders[i].sortIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
            return .ok("「\(f.name)」挪到了" + (target.map { "「\($0.name)」里" } ?? "根一层") + "。")
        case "color":
            guard let f = folder(s("folder_id")), let i = lib.folders.firstIndex(where: { $0.id == f.id }) else {
                return .fail("找不到这个文件夹。")
            }
            let c = s("color")
            lib.folders[i].colorHex = (c == nil || c == "none") ? nil : (c!.hasPrefix("#") ? c! : "#" + c!)
            return .ok("改好了。")
        case "delete":
            guard let f = folder(s("folder_id")) else { return .fail("找不到这个文件夹。") }
            let doomed = subtree(f.id)
            for i in p.mediaAssets.indices {
                if let fid = p.mediaAssets[i].folderID, doomed.contains(fid) { p.mediaAssets[i].folderID = f.parentID }
            }
            lib.folders.removeAll { doomed.contains($0.id) }
            return .ok("删掉了文件夹「\(f.name)」，里面的素材退到了上一层，文件没动。")
        case "collect":
            guard let f = folder(s("folder_id")) else { return .fail("找不到这个文件夹。") }
            guard let d = s("directory"), !d.isEmpty else { return .fail("collect 要给 directory") }
            let scope = subtree(f.id)
            let items = p.mediaAssets.filter { $0.folderID.map(scope.contains) == true }
            guard !items.isEmpty else { return .fail("这个文件夹是空的。") }
            let fm = FileManager.default
            let root = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
                .appendingPathComponent(f.name, isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            var ok = 0, failed = 0
            for a in items {
                guard fm.fileExists(atPath: a.url.path) else { failed += 1; continue }
                var dest = root.appendingPathComponent(a.url.lastPathComponent)
                var n = 2
                let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
                while fm.fileExists(atPath: dest.path) {
                    dest = root.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
                }
                do { try fm.copyItem(at: a.url, to: dest); ok += 1 } catch { failed += 1 }
            }
            return .ok("复制了 \(ok) 个素材到 \(root.path)" + (failed > 0 ? "，\(failed) 个没找到文件。" : "。"))
        default:
            return .fail("action 不认识。")
        }
    }

    // MARK: - 在线音频

    private struct OVResponse: Decodable { let page_count: Int; let results: [OnlineAudioItem] }

    @MainActor
    private static func onlineAudio(_ p: ProjectState, action: String, kind: String?, query: String?,
                                    page: Int, id: String?, time: Double?) async -> AgentToolResult {
        let store = OnlineAudioStore.shared
        func item(_ key: String?) -> OnlineAudioItem? {
            guard let k = key, !k.isEmpty else { return nil }
            return seenAudio[k] ?? seenAudio.values.first { $0.id.hasPrefix(k) }
                ?? store.favorites.first { $0.id.hasPrefix(k) }
        }
        func line(_ it: OnlineAudioItem) -> String {
            "- \(it.id.prefix(12))「\(it.displayTitle)」\(it.creator.map { "by \($0)" } ?? "")，\(it.licenseLabel)"
                + (it.durationText.isEmpty ? "" : "，\(it.durationText)")
        }
        switch action {
        case "search":
            guard let q = query, !q.isEmpty else { return .fail("search 要给 query（英文）") }
            let music = kind != "sfx"
            var comps = URLComponents(string: "https://api.openverse.org/v1/audio/")!
            comps.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "license", value: "cc0,pdm,by"),
                URLQueryItem(name: "page_size", value: "10"),
                URLQueryItem(name: "page", value: String(max(1, page))),
                music ? URLQueryItem(name: "category", value: "music")
                      : URLQueryItem(name: "source", value: "freesound"),
            ]
            guard let url = comps.url else { return .fail("搜索词有问题。") }
            do {
                var req = URLRequest(url: url); req.timeoutInterval = 20
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 { return .fail("在线库限流了（每分钟 20 次、每天 200 次），过一会儿再搜。") }
                guard (200...299).contains(code) else { return .fail("搜索失败（HTTP \(code)）。") }
                let r = try JSONDecoder().decode(OVResponse.self, from: data)
                guard !r.results.isEmpty else { return .ok("「\(q)」没搜到，换个英文词试试。") }
                for it in r.results { seenAudio[it.id] = it }
                return .ok("第 \(page)/\(r.page_count) 页：\n" + r.results.map(line).joined(separator: "\n"))
            } catch {
                return .fail("搜索失败：\(error.localizedDescription)")
            }
        case "preview":
            guard let it = item(id) else { return .fail("找不到这条，先 search。") }
            if store.playingID != it.id { store.togglePreview(it) }
            return .ok("正在给用户试听「\(it.displayTitle)」。")
        case "stop":
            store.stopPreview()
            return .ok("停了。")
        case "favorite", "unfavorite":
            guard let it = item(id) else { return .fail("找不到这条，先 search。") }
            let on = store.isFavorite(it)
            if (action == "favorite") != on { store.toggleFavorite(it) }
            return .ok(action == "favorite" ? "收藏了「\(it.displayTitle)」。" : "取消收藏「\(it.displayTitle)」。")
        case "favorites":
            guard !store.favorites.isEmpty else { return .ok("还没有收藏。") }
            for it in store.favorites { seenAudio[it.id] = it }
            return .ok(store.favorites.map(line).joined(separator: "\n"))
        case "add", "download":
            guard let it = item(id) else { return .fail("找不到这条，先 search。") }
            let dest = store.localURL(for: it)
            if !FileManager.default.fileExists(atPath: dest.path) {
                guard let src = URL(string: it.url) else { return .fail("这条没有下载地址。") }
                do {
                    let (tmp, resp) = try await URLSession.shared.download(from: src)
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        return .fail("下载失败。")
                    }
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch {
                    return .fail("下载失败：\(error.localizedDescription)")
                }
            }
            if action == "download" { return .ok("下好了「\(it.displayTitle)」，在 \(dest.path)。") }
            let t = time ?? p.currentTime
            p.currentTime = max(0, t); p.seekRequest &+= 1
            store.addToTimeline(it, project: p)
            return .ok("「\(it.displayTitle)」放到了 \(String(format: "%.2f", t)) 秒处"
                       + (it.needsCredit ? "。这条是 \(it.licenseLabel)，要在成片里署名，署名已经记在素材上。" : "。"))
        default:
            return .fail("action 不认识。")
        }
    }
}
