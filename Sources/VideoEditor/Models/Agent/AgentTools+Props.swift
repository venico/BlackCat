// AgentTools+Props.swift
//
// 通用读写属性：任何片段、任何轨道的全部字段原样读出来，也能改其中任意一项。
//
// 为什么要它：界面上能调的东西，Agent 往往调不了 —— 不是做不到，是没人给它开那个参数。
// update_clip 那种一个参数一个参数手写的工具永远追不上界面（新加一个属性就得再补一遍）。
// 这里直接走数据模型的 Codable：读 = 编码成 JSON 给它看，改 = 改 JSON 再解码回去。
// 以后模型里加了新字段，它自动就能读能改。
//
// 两道保险：
//   · 身份字段（id、素材关联、文件地址）不让改，改了片段就跟素材脱钩了
//   · 改完再编码一遍核对：手写解码器很多是 `try?` 兜底的，类型给错会**静默变回默认值**，
//     不核对的话它以为改成了、其实没生效

import Foundation

extension AgentToolbox {

    static var propsTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "get_properties",
                description: """
                读一个片段或一条轨道的**全部**属性（原样的数据字段，比 get_clip 全）。
                界面上能调、但别的工具里找不到对应参数的东西，先用它看看字段叫什么，再用 set_properties 改。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string",
                                   "description": "片段 id（list_tracks 给的，前 8 位就行），或者 track:轨道 id 读整条轨道的设置"]
                    ] as [String: Any],
                    "required": ["target"]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "set_properties",
                description: """
                改一个片段或一条轨道的任意属性。字段名照 get_properties 读出来的写，嵌套的用点连起来
                （比如 colorAdjust.brightness、subtitleStyle.fontSize）。颜色写 #RRGGBB，带透明度写 #RRGGBBAA。
                有专门工具的（分割、移动、换轨、加转场）还是用专门的；这个管「改数值、开关、颜色」这类。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "同 get_properties"],
                        "changes": ["type": "object",
                                    "description": "要改的字段和新值，比如 {\"opacity\": 0.5, \"textColorHex\": \"#FF0000\"}"]
                    ] as [String: Any],
                    "required": ["target", "changes"]
                ],
                risk: .mutating)
        ]
    }

    /// 改不得的身份字段
    private static let lockedKeys: Set<String> = ["id", "assetID", "url", "clips", "bookmark"]

    @MainActor
    static func runPropsTool(_ name: String, args: [String: Any], project p: ProjectState) -> AgentToolResult? {
        guard name == "get_properties" || name == "set_properties" else { return nil }
        guard let raw = (args["target"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .fail("缺 target。")
        }
        guard let hit = PropsTarget.find(raw, in: p) else {
            return .fail("找不到「\(raw)」。片段写 list_tracks 给的 id，轨道写 track:轨道id。")
        }
        if name == "get_properties" {
            var shown = hit.json
            shown.removeValue(forKey: "clips")
            guard let d = try? JSONSerialization.data(withJSONObject: shown, options: [.prettyPrinted, .sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return .fail("读不出来。") }
            return .ok("\(hit.label)的属性：\n\(s)")
        }

        guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else {
            return .fail("changes 要写成 {字段: 新值}。")
        }
        if let bad = changes.keys.first(where: { lockedKeys.contains($0.components(separatedBy: ".")[0]) }) {
            return .fail("「\(bad)」是身份字段，不能改（改了片段会跟素材脱钩）。")
        }
        var json = hit.json
        for (path, value) in changes { setValue(&json, path: path.components(separatedBy: "."), value: value) }
        let after: [String: Any]
        do { after = try hit.apply(json) } catch {
            return .fail("改不进去：\(error.localizedDescription)。字段类型可能不对，先 get_properties 看看原来是什么样的值。")
        }
        // 逐项核对：解码器兜底时会悄悄换回默认值
        var failed: [String] = []
        for (path, value) in changes where !sameValue(getValue(after, path: path.components(separatedBy: ".")), value) {
            failed.append(path)
        }
        p.isSaved = false
        p.scheduleAutoSave()
        hit.refresh()
        if failed.count == changes.count {
            return .fail("都没生效：\(failed.joined(separator: "、"))。字段名或值的类型不对，先 get_properties 核对。")
        }
        let okKeys = changes.keys.filter { !failed.contains($0) }.sorted()
        return .ok("改好了：\(okKeys.joined(separator: "、"))"
                   + (failed.isEmpty ? "。" : "。没生效的：\(failed.joined(separator: "、"))（字段名或类型不对）。"))
    }

    // MARK: - JSON 小工具

    private static func setValue(_ obj: inout [String: Any], path: [String], value: Any) {
        guard let k = path.first else { return }
        if path.count == 1 { obj[k] = value; return }
        var child = obj[k] as? [String: Any] ?? [:]
        setValue(&child, path: Array(path.dropFirst()), value: value)
        obj[k] = child
    }

    private static func getValue(_ obj: [String: Any], path: [String]) -> Any? {
        var cur: Any? = obj
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur
    }

    /// 数字按数值比（1 和 1.0 算一样），字符串忽略大小写（颜色 #ff0000 / #FF0000）
    private static func sameValue(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) < 1e-6 }
        if let x = a as? String, let y = b as? String { return x.caseInsensitiveCompare(y) == .orderedSame }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return y.allSatisfy { k, v in sameValue(x[k], v) }
        }
        return (a as AnyObject).isEqual(b)
    }
}

/// 找到的那个对象：当前的 JSON、怎么写回去、写完刷新哪儿
@MainActor
struct PropsTarget {
    let label: String
    let json: [String: Any]
    /// 写回去，返回写完之后的 JSON（核对用）
    let apply: ([String: Any]) throws -> [String: Any]
    let refresh: () -> Void

    static func find(_ raw: String, in p: ProjectState) -> PropsTarget? {
        let isTrack = raw.lowercased().hasPrefix("track:")
        let key = (isTrack ? String(raw.dropFirst(6)) : raw).trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return nil }
        let overlay: () -> Void = { p.refreshOverlayComposite() }
        let rebuild: () -> Void = { p.rebuildTimelinePreview() }

        func probe<C>(_ kp: ReferenceWritableKeyPath<ProjectState, [Track<C>]>, _ kind: String,
                      _ refresh: @escaping () -> Void) -> PropsTarget? {
            let tracks = p[keyPath: kp]
            if isTrack {
                guard let ti = tracks.firstIndex(where: { "\($0.id)".uppercased().hasPrefix(key) }),
                      let j = encode(tracks[ti]) else { return nil }
                return PropsTarget(label: "\(kind)轨「\(tracks[ti].label)」", json: j, apply: { newJSON in
                    var full = newJSON
                    full["clips"] = j["clips"]          // 片段不经这条路改，原样放回
                    var t: Track<C> = try decode(full)
                    t.clips = p[keyPath: kp][ti].clips
                    p[keyPath: kp][ti] = t
                    return encode(t) ?? [:]
                }, refresh: refresh)
            }
            for ti in tracks.indices {
                guard let ci = tracks[ti].clips.firstIndex(where: { "\($0.id)".uppercased().hasPrefix(key) }),
                      let j = encode(tracks[ti].clips[ci]) else { continue }
                return PropsTarget(label: "\(kind)片段", json: j, apply: { newJSON in
                    let c: C = try decode(newJSON)
                    p[keyPath: kp][ti].clips[ci] = c
                    return encode(c) ?? [:]
                }, refresh: refresh)
            }
            return nil
        }

        return probe(\.videoTracks, "视频", rebuild) ?? probe(\.audioTracks, "音频", rebuild)
            ?? probe(\.imageTracks, "图片", overlay) ?? probe(\.subtitleTracks, "字幕", overlay)
            ?? probe(\.textTracks, "文字", overlay) ?? probe(\.shapeTracks, "图形", overlay)
            ?? probe(\.filterTracks, "滤镜", rebuild) ?? probe(\.adjustTracks, "调节", rebuild)
            ?? probe(\.effectTracks, "特效", rebuild) ?? probe(\.compoundTracks, "复合", rebuild)
    }

    private static func encode<T: Encodable>(_ v: T) -> [String: Any]? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func decode<T: Decodable>(_ j: [String: Any]) throws -> T {
        let d = try JSONSerialization.data(withJSONObject: j)
        return try JSONDecoder().decode(T.self, from: d)
    }
}
