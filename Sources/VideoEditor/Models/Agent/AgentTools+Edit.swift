// AgentTools+Edit.swift
//
// 会改动项目的那批工具。
//
// **一律走 ProjectState 现成的方法**，不自己去动数组 —— 那些方法里带着
// 重叠处理、顺序表同步、预览重建这些副作用，绕过去改出来的项目状态是坏的。
// 撤销由 AgentRunner 在一轮开始时统一打快照，这里的方法都不再各自 pushUndo。

import Foundation

extension AgentToolbox {

    static var editTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "add_asset_to_timeline",
                description: "把素材库里的一个素材加到时间轴。视频/音频/图片都走它，会自动落到对应类型的轨道上。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "asset_id": ["type": "string", "description": "list_assets 给的 id，前 8 位就够"],
                        "time": ["type": "number", "description": "落在第几秒，不传就放播放头处"]
                    ] as [String: Any],
                    "required": ["asset_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_subtitle",
                description: "加一条字幕。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "start": ["type": "number", "description": "秒"],
                        "end": ["type": "number", "description": "秒"]
                    ] as [String: Any],
                    "required": ["text"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_text",
                description: "加一条标题文字（跟字幕不是一回事，文字是独立图层，可以摆在画面任意位置）。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "x": ["type": "number", "description": "0~1，画面横向位置，0.5 是居中"],
                        "y": ["type": "number", "description": "0~1，画面纵向位置"]
                    ] as [String: Any],
                    "required": ["text"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_filter",
                description: "加一段滤镜。滤镜只作用于排在它下面的图层。可选的种类见参数说明。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "enum": FilterKind.builtins.map(\.rawValue),
                                 "description": FilterKind.builtins.map { "\($0.rawValue)=\($0.label)" }.joined(separator: "，")],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "intensity": ["type": "number", "description": "0~1，默认 1"]
                    ] as [String: Any],
                    "required": ["kind"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_effect",
                description: "加一段特效（模糊、像素化、扭曲这类）。同样只作用于排在它下面的图层。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "enum": EffectKind.allCases.map(\.rawValue),
                                 "description": EffectKind.allCases.map { "\($0.rawValue)=\($0.label)" }.joined(separator: "，")],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "intensity": ["type": "number", "description": "0~1，默认 1"],
                        "amount": ["type": "number", "description": "0~1，主参数（半径/颗粒/范围），不传用该特效的默认值"]
                    ] as [String: Any],
                    "required": ["kind"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_adjust",
                description: "加一段调节（亮度、对比、饱和、曝光、色温这些）。参数都是 -1~1，色温正值偏暖。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number"], "end": ["type": "number"],
                        "brightness": ["type": "number"], "contrast": ["type": "number"],
                        "saturation": ["type": "number"], "vibrance": ["type": "number"],
                        "exposure": ["type": "number", "description": "-2~2 EV"],
                        "highlight": ["type": "number"], "shadow": ["type": "number"],
                        "temperature": ["type": "number"], "tint": ["type": "number"],
                        "hue": ["type": "number", "description": "-180~180 度"]
                    ] as [String: Any]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "move_clip",
                description: "把一条片段挪到别的时间位置。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "list_tracks 给的 id"],
                        "start": ["type": "number", "description": "新的起始秒数"]
                    ] as [String: Any],
                    "required": ["clip_id", "start"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "split_at",
                description: "在某个时刻把片段切开。不传 clip_id 就切播放头处所有轨道上的片段。",
                parameters: [
                    "type": "object",
                    "properties": ["time": ["type": "number", "description": "秒"]] as [String: Any],
                    "required": ["time"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "delete_clip",
                description: "删掉一条片段。删了要靠撤销才能回来，所以确认清楚再调。",
                parameters: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string"]] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "remember",
                description: """
                把一件值得长期记住的事写进记忆。
                用户说「以后都…」「我习惯…」「记住…」这类话时调它。
                **只记会反复用到的偏好和设定**，别把一次性的指令记进去 —— \
                记满一堆临时的东西，下次它们会互相打架。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "一句话，写清楚是什么习惯或设定"],
                        "scope": ["type": "string", "enum": ["global", "project"],
                                  "description": "global=这个人的长期习惯（字幕字号、导出偏好），跟着人走；project=这个片子的设定（主角名字、基调），只在本项目有效"]
                    ] as [String: Any],
                    "required": ["text", "scope"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "seek",
                description: "把播放头移到某一秒。要看某处画面之前先移过去，再 capture_frame。",
                parameters: [
                    "type": "object",
                    "properties": ["time": ["type": "number"]] as [String: Any],
                    "required": ["time"]
                ],
                risk: .mutating),
        ]
    }

    @MainActor
    static func runEditTool(_ name: String, args: [String: Any], project p: ProjectState) -> AgentToolResult? {
        switch name {
        case "add_asset_to_timeline":
            guard let key = args["asset_id"] as? String,
                  let asset = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(key) })
            else { return .fail("素材库里找不到 id 以 \(args["asset_id"] ?? "") 开头的素材，先调 list_assets 看看。") }
            guard asset.fileExists else { return .fail("「\(asset.name)」的源文件已经不在了，加不进去。") }
            p.addToTimelineAt(asset, time: args["time"] as? Double ?? p.currentTime, skipUndo: true)
            return .ok("已把「\(asset.name)」加到时间轴。")

        case "add_subtitle":
            guard let text = args["text"] as? String else { return .fail("缺 text") }
            let start = args["start"] as? Double ?? p.currentTime
            p.insertSubtitleAtPlayhead(text: text)
            if let id = p.subtitleTracks.flatMap(\.clips).last?.id {
                let end = args["end"] as? Double ?? (start + 3)
                p.updateSubtitleTime(id: id, start: start, end: max(start + 0.3, end))
            }
            return .ok("字幕已加：\(text)")

        case "add_text":
            guard let text = args["text"] as? String else { return .fail("缺 text") }
            p.addTextAtPlayhead(text: text)
            guard let id = p.textTracks.flatMap(\.clips).last?.id else { return .ok("文字已加。") }
            let start = args["start"] as? Double ?? p.currentTime
            let end = args["end"] as? Double ?? (start + 3)
            p.updateTextClip(id: id) {
                $0.startTime = start; $0.endTime = max(start + 0.3, end)
                if let x = args["x"] as? Double { $0.posX = min(max(x, 0), 1) }
                if let y = args["y"] as? Double { $0.posY = min(max(y, 0), 1) }
            }
            return .ok("文字已加：\(text)")

        case "add_filter":
            guard let raw = args["kind"] as? String, let kind = FilterKind(rawValue: raw)
            else { return .fail("没有叫 \(args["kind"] ?? "") 的滤镜。") }
            let start = args["start"] as? Double ?? p.currentTime
            let id = p.addFilter(kind: kind, at: start)
            p.updateFilterClip(id: id) {
                if let e = args["end"] as? Double { $0.endTime = max(start + 0.3, e) }
                if let i = args["intensity"] as? Double { $0.intensity = min(max(i, 0), 1) }
            }
            return .ok("已加滤镜「\(kind.label)」。")

        case "add_effect":
            guard let raw = args["kind"] as? String, let kind = EffectKind(rawValue: raw)
            else { return .fail("没有叫 \(args["kind"] ?? "") 的特效。") }
            let start = args["start"] as? Double ?? p.currentTime
            let id = p.addEffect(kind: kind, at: start)
            p.updateEffectClip(id: id) {
                if let e = args["end"] as? Double { $0.endTime = max(start + 0.3, e) }
                if let i = args["intensity"] as? Double { $0.intensity = min(max(i, 0), 1) }
                if let a = args["amount"] as? Double { $0.amount = min(max(a, 0), 1) }
            }
            return .ok("已加特效「\(kind.label)」。")

        case "add_adjust":
            let start = args["start"] as? Double ?? p.currentTime
            let id = p.addAdjust(at: start)
            p.updateAdjustClip(id: id) { c in
                if let e = args["end"] as? Double { c.endTime = max(start + 0.3, e) }
                func v(_ k: String) -> Double? { args[k] as? Double }
                if let x = v("brightness")  { c.adjust.brightness = x }
                if let x = v("contrast")    { c.adjust.contrast = x }
                if let x = v("saturation")  { c.adjust.saturation = x }
                if let x = v("vibrance")    { c.adjust.vibrance = x }
                if let x = v("exposure")    { c.adjust.exposure = x }
                if let x = v("highlight")   { c.adjust.highlight = x }
                if let x = v("shadow")      { c.adjust.shadow = x }
                if let x = v("temperature") { c.adjust.temperature = x }
                if let x = v("tint")        { c.adjust.tint = x }
                if let x = v("hue")         { c.adjust.hue = x }
            }
            return .ok("已加一段调节。")

        case "move_clip":
            guard let key = args["clip_id"] as? String, let start = args["start"] as? Double
            else { return .fail("缺 clip_id 或 start") }
            return moveClip(p, idPrefix: key, to: start)

        case "split_at":
            guard let t = args["time"] as? Double else { return .fail("缺 time") }
            p.currentTime = t
            p.clock.currentTime = t
            p.splitAtPlayhead()
            return .ok("已在 \(fmt(t)) 处分割。")

        case "delete_clip":
            guard let key = args["clip_id"] as? String else { return .fail("缺 clip_id") }
            return deleteClip(p, idPrefix: key)

        case "remember":
            guard AppSettings.shared.agentMemoryEnabled else {
                return .fail("用户把记忆功能关了，这次别记，也别再尝试。")
            }
            guard let text = args["text"] as? String, !text.isEmpty else { return .fail("缺 text") }
            let isGlobal = (args["scope"] as? String ?? "global") == "global"
            if isGlobal { AgentMemory.shared.addGlobal(text) }
            else { AgentMemory.shared.addProject(text) }
            return .ok("记住了（\(isGlobal ? "长期习惯" : "本项目")）：\(text)")

        case "seek":
            guard let t = args["time"] as? Double else { return .fail("缺 time") }
            p.currentTime = t
            p.clock.currentTime = t
            p.clock.seekRequest &+= 1
            return .ok("播放头已移到 \(fmt(t))。")

        default: return nil
        }
    }

    // MARK: - 按 id 前缀找片段

    @MainActor
    private static func moveClip(_ p: ProjectState, idPrefix: String, to start: Double) -> AgentToolResult {
        let s = max(0, start)
        for t in p.videoTracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
            p.updateVideoClip(id: c.id) { $0.endTime = s + ($0.endTime - $0.startTime); $0.startTime = s }
            p.rebuildTimelinePreview(); return .ok("已把「\(c.name)」挪到 \(fmt(s))。") } }
        for t in p.audioTracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
            p.updateAudioClip(id: c.id) { $0.endTime = s + ($0.endTime - $0.startTime); $0.startTime = s }
            p.rebuildTimelinePreview(); return .ok("已把「\(c.name)」挪到 \(fmt(s))。") } }
        for t in p.imageTracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
            p.updateImageClip(id: c.id) { $0.endTime = s + ($0.endTime - $0.startTime); $0.startTime = s }
            p.rebuildTimelinePreview(); return .ok("已把「\(c.name)」挪到 \(fmt(s))。") } }
        for t in p.subtitleTracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
            p.updateSubtitleTime(id: c.id, start: s, end: s + c.duration); return .ok("字幕已挪到 \(fmt(s))。") } }
        for t in p.textTracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
            p.updateTextClip(id: c.id) { $0.endTime = s + ($0.endTime - $0.startTime); $0.startTime = s }
            return .ok("文字已挪到 \(fmt(s))。") } }
        return .fail("找不到 id 以 \(idPrefix) 开头的片段，先调 list_tracks 确认。")
    }

    @MainActor
    private static func deleteClip(_ p: ProjectState, idPrefix: String) -> AgentToolResult {
        func hit<C: Identifiable>(_ tracks: [Track<C>]) -> UUID? where C: Equatable & Codable {
            for t in tracks { if let c = t.clips.first(where: { "\($0.id)".hasPrefix(idPrefix) }) {
                return c.id as? UUID } }
            return nil
        }
        let id = hit(p.videoTracks) ?? hit(p.audioTracks) ?? hit(p.imageTracks)
              ?? hit(p.subtitleTracks) ?? hit(p.textTracks) ?? hit(p.shapeTracks)
              ?? hit(p.filterTracks) ?? hit(p.adjustTracks) ?? hit(p.effectTracks)
        guard let id else { return .fail("找不到 id 以 \(idPrefix) 开头的片段。") }
        p.clearClipSelections()
        p.selectedClipIDs = [id]
        p.deleteSelected()
        return .ok("已删除。")
    }
}
