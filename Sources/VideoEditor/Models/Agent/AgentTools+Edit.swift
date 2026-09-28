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
                name: "import_media",
                description: """
                把电脑上的一个文件导入**当前项目的素材库**（视频 / 音频 / 图片 / 字幕都行）。

                自己下载的、生成的、用户给了路径的文件，都用它送进来 ——                 **你就跑在这个剪辑软件里**，不用也不要去操作别的剪辑 app。
                导入后调 list_assets 拿到它的 id，再用 add_asset_to_timeline 放上时间线。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string",
                                 "description": "文件绝对路径，`~` 开头也认"]
                    ] as [String: Any],
                    "required": ["path"]
                ],
                risk: .mutating),

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
                description: "加一段滤镜。滤镜只作用于排在它下面的图层。可选的种类见参数说明。用户给了 .cube LUT 文件就传 lut_path，kind 不用给。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "enum": FilterKind.builtins.map(\.rawValue),
                                 "description": FilterKind.builtins.map { "\($0.rawValue)=\($0.label)" }.joined(separator: "，")],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "intensity": ["type": "number", "description": "0~1，默认 1"],
                        "lut_path": ["type": "string", "description": ".cube 格式 LUT 文件的绝对路径（导入外部 LUT）"]
                    ] as [String: Any],
                    "required": [] as [String]
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
                description: """
                把一条片段挪到别的时间位置，或者挪到**同类型的另一条轨道**上（视频到视频、字幕到字幕……）。
                start 和 track_id 至少给一个；只给 track_id 就保持原来的时间。
                目标轨道上那段时间已经有片段的话会失败，换个时间或换条轨道。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "list_tracks 给的片段 id"],
                        "start": ["type": "number", "description": "新的起始秒数。不传就不改时间"],
                        "track_id": ["type": "string",
                                     "description": "挪到哪条轨道（list_tracks 里轨道标题后面的 id）。不传就留在原轨道"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "move_track",
                description: """
                调整轨道的上下顺序。时间轴从上到下分三块：叠加层（图片、字幕、文字、图形、滤镜、调节、特效）、\
                视频、音频，**每块里各排各的**，不能把字幕轨挪进视频那块。
                同一块里**上面的轨道盖在下面的上面**：想让文字压在图片上，就把文字轨挪到图片轨上面。
                position：top＝本块最上，bottom＝本块最下，above / below＝挪到 relative_to 那条的上面 / 下面。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "track_id": ["type": "string", "description": "要挪的轨道（list_tracks 里轨道标题后面的 id）"],
                        "position": ["type": "string", "enum": ["top", "bottom", "above", "below"]],
                        "relative_to": ["type": "string",
                                        "description": "position 是 above / below 时必填：参照的那条轨道 id，须在同一块里"]
                    ] as [String: Any],
                    "required": ["track_id", "position"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "split_at",
                description: "在某个时刻把片段切开，跟界面上一样**只切选中的片段**。给 clip_id 就先选中那条再切；不给就切用户当前选中的；都没有就不切。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "number", "description": "秒"],
                        "clip_id": ["type": "string", "description": "要切的片段，会先选中它（id 前 8 位就行）。不给就切当前选中的"]
                    ] as [String: Any],
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
                name: "forget",
                description: """
                删掉一条已经记住的东西。用户说「改成…」「不是…是…」时，                **先用它把旧的那条删掉，再 remember 新的** —— 直接 remember 会变成两条并存，                下次它们会互相打架。系统提示词里列了现在记着哪些，照着写要删哪条。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "要删的那条，写开头几个字就行"],
                        "scope": ["type": "string", "enum": ["global", "project"],
                                  "description": "从长期习惯里删还是从本项目设定里删"]
                    ] as [String: Any],
                    "required": ["text"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "set_subtitle_default_size",
                description: """
                改**新建字幕的默认字号**，中英各一档。用户说「字幕默认中文 40、英文 32」                这类话时调它 —— 光 remember 只是记个备忘，不会真的改到软件设置，                下次加字幕还是老字号。已经在时间轴上的字幕不受影响。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "cjk": ["type": "number", "description": "中日韩文字的字号，比如 40"],
                        "latin": ["type": "number", "description": "纯西文字幕的字号，比如 32"]
                    ] as [String: Any]
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
        case "import_media":
            guard let raw = (args["path"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
            else { return .fail("缺 path") }
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return .fail("这个路径上没有文件：\(path)")
            }
            let fileURL = URL(fileURLWithPath: path)
            p.importFile(fileURL)
            return .ok("""
                已经把「\(fileURL.lastPathComponent)」导进素材库了（大文件可能还在转码，稍等一下）。
                接着调 list_assets 拿它的 id，再用 add_asset_to_timeline 放到时间线上。
                """)

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
            var lut: String?
            if let lp = (args["lut_path"] as? String)?.trimmingCharacters(in: .whitespaces), !lp.isEmpty {
                let path = (lp as NSString).expandingTildeInPath
                guard LUTCache.shared.cube(at: path) != nil else { return .fail("「\(lp)」不是有效的 .cube LUT 文件。") }
                if !AppSettings.shared.customLUTs.contains(path) { AppSettings.shared.customLUTs.append(path) }
                lut = path
            }
            let kind: FilterKind
            if lut != nil { kind = .lut }
            else if let raw = args["kind"] as? String, let k = FilterKind(rawValue: raw) { kind = k }
            else { return .fail("没有叫 \(args["kind"] ?? "") 的滤镜。") }
            let start = args["start"] as? Double ?? p.currentTime
            let id = p.addFilter(kind: kind, at: start, lutPath: lut)
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
            guard let key = args["clip_id"] as? String else { return .fail("缺 clip_id") }
            let start = (args["start"] as? Double) ?? (args["start"] as? Int).map(Double.init)
            let track = (args["track_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard start != nil || track != nil else { return .fail("start 和 track_id 至少给一个") }
            if let track { return moveClipToTrack(p, idPrefix: key, trackPrefix: track, start: start) }
            return moveClip(p, idPrefix: key, to: start!)

        case "move_track":
            guard let key = args["track_id"] as? String, !key.isEmpty,
                  let pos = args["position"] as? String else { return .fail("缺 track_id 或 position") }
            return moveTrack(p, trackPrefix: key, position: pos, relativeTo: args["relative_to"] as? String)

        case "split_at":
            let t: Double
            if let d = args["time"] as? Double { t = d }
            else if let i = args["time"] as? Int { t = Double(i) }
            else { return .fail("缺 time") }
            p.currentTime = t
            p.clock.currentTime = t
            // 跟界面一样只切「选中的」：点名了就先选中那条；没点名就切用户当前选中的。
            // splitAtPlayhead 只认「主选中」—— 多选（selectedClipIDs）里的要逐条设成主选中再切，
            // 以前直接调它，选中落在多选里时一刀没切却回了「已分割」
            var targets: [UUID] = []
            if let key = (args["clip_id"] as? String), !key.isEmpty {
                guard let id = resolveClipIDs(p, [key]).first else { return .fail("找不到 id 以 \(key) 开头的片段。") }
                targets = [id]
            } else {
                let primaries = [p.selectedVideoClipID, p.selectedAudioClipID, p.selectedImageClipID,
                                 p.selectedSubtitleClipID, p.selectedTextClipID, p.selectedShapeClipID,
                                 p.selectedCompoundClipID].compactMap { $0 }
                for id in primaries + Array(p.selectedClipIDs) where !targets.contains(id) { targets.append(id) }
            }
            guard !targets.isEmpty else {
                return .fail("现在没有选中的片段，不知道切哪条。用 clip_id 指定要切的片段（list_tracks 查 id）。")
            }
            let before = Self.clipCount(p)
            for id in targets where selectPrimary(p, id) { p.splitAtPlayhead() }
            // 切完还选中原来那条（左半段），跟界面上手动分割后的状态一样
            if let first = targets.first { selectPrimary(p, first) }
            let made = Self.clipCount(p) - before
            guard made > 0 else {
                return .fail("\(fmt(t)) 不在选中片段的中间（正好在头尾或者在片段外面），没切。先 list_tracks 看看时间对不对。")
            }
            return .ok("已在 \(fmt(t)) 处把选中的 \(made) 条片段切开。")

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

        case "forget":
            guard let text = args["text"] as? String, !text.isEmpty else { return .fail("缺 text") }
            let g = (args["scope"] as? String ?? "global") == "global"
            return AgentMemory.shared.forget(matching: text, isGlobal: g)

        case "set_subtitle_default_size":
            let cjk = args["cjk"] as? Double
            let latin = args["latin"] as? Double
            guard cjk != nil || latin != nil else { return .fail("cjk 和 latin 至少给一个") }
            if let c = cjk, c > 0 { AppSettings.shared.subtitleFontSizeCJK = c }
            if let l = latin, l > 0 { AppSettings.shared.subtitleFontSizeLatin = l }
            return .ok("以后新建字幕的默认字号：中文 \(Int(AppSettings.shared.subtitleFontSizeCJK))、"
                     + "英文 \(Int(AppSettings.shared.subtitleFontSizeLatin))。"
                     + "已经在时间轴上的字幕没动。")

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

    // MARK: 换轨 / 调轨道顺序

    /// 把片段挪到同类型的另一条轨道。每类轨道各试一遍，片段不在这一类就跳过
    @MainActor
    private static func moveClipToTrack(_ p: ProjectState, idPrefix: String,
                                        trackPrefix: String, start: Double?) -> AgentToolResult {
        p.pushUndo()
        var out: AgentToolResult?
        func attempt<C: AgentMovableClip>(_ tracks: inout [Track<C>], _ kind: String) {
            guard out == nil else { return }
            out = relocate(&tracks, kind: kind, clipPrefix: idPrefix, trackPrefix: trackPrefix, start: start)
        }
        attempt(&p.videoTracks, "视频"); attempt(&p.audioTracks, "音频")
        attempt(&p.imageTracks, "图片"); attempt(&p.subtitleTracks, "字幕")
        attempt(&p.textTracks, "文字"); attempt(&p.shapeTracks, "图形")
        attempt(&p.filterTracks, "滤镜"); attempt(&p.adjustTracks, "调节")
        attempt(&p.effectTracks, "特效")
        guard let out else { return .fail("找不到 id 以 \(idPrefix) 开头的片段，先调 list_tracks 确认。") }
        if !out.isError {
            p.refreshOverlayComposite()
            p.rebuildTimelinePreview()
        }
        return out
    }

    /// 在同一类轨道里把片段从原轨道搬到目标轨道。
    /// 片段不在这一类 → nil（让下一类去试）；在这一类但办不成 → failure
    private static func relocate<C: AgentMovableClip>(
        _ tracks: inout [Track<C>], kind: String,
        clipPrefix: String, trackPrefix: String, start: Double?
    ) -> AgentToolResult? {
        guard let si = tracks.firstIndex(where: { $0.clips.contains { "\($0.id)".hasPrefix(clipPrefix) } }),
              let ci = tracks[si].clips.firstIndex(where: { "\($0.id)".hasPrefix(clipPrefix) })
        else { return nil }
        guard let di = tracks.firstIndex(where: { "\($0.id)".hasPrefix(trackPrefix) }) else {
            return .fail("片段在\(kind)轨上，但没有 id 以 \(trackPrefix) 开头的\(kind)轨。"
                            + "片段只能挪到同类型的轨道，先调 list_tracks 看看有哪些\(kind)轨。")
        }
        var clip = tracks[si].clips[ci]
        let len = clip.endTime - clip.startTime
        let s = max(0, start ?? clip.startTime)
        // 目标轨道那段时间被占了就不挪，不替它挤开别人
        let clash = tracks[di].clips.contains { c in
            "\(c.id)" != "\(clip.id)" && c.startTime < s + len - 0.001 && c.endTime > s + 0.001
        }
        if clash {
            return .fail("目标\(kind)轨在 \(fmt(s))–\(fmt(s + len)) 已经有片段了，换个时间或换条轨道。")
        }
        tracks[si].clips.remove(at: ci)
        clip.startTime = s
        clip.endTime = s + len
        tracks[di].clips.append(clip)
        tracks[di].clips.sort { $0.startTime < $1.startTime }
        let where_ = si == di ? "" : "挪到「\(tracks[di].label)」轨"
        return .ok("已把这段\(kind)\(where_)，时间 \(fmt(s))–\(fmt(s + len))。")
    }

    /// 调轨道顺序。三块（叠加层 / 视频 / 音频）各有一张顺序表，表里第一个就是最上面那条，
    /// 画面叠放也是上面的盖住下面的
    @MainActor
    private static func moveTrack(_ p: ProjectState, trackPrefix: String,
                                  position: String, relativeTo: String?) -> AgentToolResult {
        func reorder<R>(_ list: inout [R], id: (R) -> UUID, block: String) -> AgentToolResult? {
            guard let from = list.firstIndex(where: { "\(id($0))".hasPrefix(trackPrefix) }) else { return nil }
            let item = list.remove(at: from)
            var to: Int
            switch position {
            case "top": to = 0
            case "bottom": to = list.count
            case "above", "below":
                guard let ref = relativeTo, !ref.isEmpty else {
                    list.insert(item, at: from)
                    return .fail("position 是 \(position) 时要给 relative_to")
                }
                guard let ri = list.firstIndex(where: { "\(id($0))".hasPrefix(ref) }) else {
                    list.insert(item, at: from)
                    return .fail("relative_to 那条轨道不在\(block)这一块里。轨道只能在自己那块里调顺序"
                                 + "（叠加层 / 视频 / 音频各排各的）。")
                }
                to = position == "above" ? ri : ri + 1
            default:
                list.insert(item, at: from)
                return .fail("position 只能是 top / bottom / above / below")
            }
            list.insert(item, at: min(max(0, to), list.count))
            return .ok("已调整\(block)轨道的顺序，现在是第 \(min(max(0, to), list.count - 1) + 1) 条（从上往下数）。"
                       + (block == "叠加层" ? "上面的盖在下面的上面。" : ""))
        }
        p.pushUndo()
        var ov = p.overlayTrackOrder
        if let r = reorder(&ov, id: { $0.trackID }, block: "叠加层") {
            if !r.isError { p.overlayTrackOrder = ov }
            p.refreshOverlayComposite(); p.rebuildTimelinePreview()
            return r
        }
        var vs = p.videoSectionOrder
        if let r = reorder(&vs, id: { $0.trackID }, block: "视频") {
            if !r.isError { p.videoSectionOrder = vs }
            p.rebuildTimelinePreview()
            return r
        }
        var au = p.audioSectionOrder
        if let r = reorder(&au, id: { $0.trackID }, block: "音频") {
            if !r.isError { p.audioSectionOrder = au }
            p.rebuildTimelinePreview()
            return r
        }
        return .fail("找不到 id 以 \(trackPrefix) 开头的轨道，先调 list_tracks 看轨道 id。")
    }

    @MainActor
    static func clipCount(_ p: ProjectState) -> Int {
        p.videoTracks.flatMap(\.clips).count + p.audioTracks.flatMap(\.clips).count
            + p.imageTracks.flatMap(\.clips).count + p.subtitleTracks.flatMap(\.clips).count
            + p.textTracks.flatMap(\.clips).count + p.shapeTracks.flatMap(\.clips).count
            + p.compoundTracks.flatMap(\.clips).count
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
