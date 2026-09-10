// AgentTools+Studio.swift
//
// 把 app 里那些"重活"接给 Agent：转场、图形、翻译、字幕转语音、超分、
// 去背景音乐、场景切分、挑精彩片段、保存、撤销。
//
// 这些功能本来只有界面上点得到，Agent 干不了 —— 它能加内容却不能加工，
// 一条完整的活儿走到一半就断了。
//
// 大部分底层函数认的是「当前选中的片段」，所以这里统一先按 clip_id 选中再调。

import AVFoundation
import Foundation

extension AgentToolbox {

    static var studioTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "add_transition",
                description: """
                给一条视频片段的**开头**加转场（跟前一条片段之间的衔接）。
                两条片段得挨着，转场才有意义。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "转场加在这条片段的开头"],
                        "kind": ["type": "string",
                                 "description": "转场类型：" + TransitionType.allCases.map(\.rawValue).joined(separator: "、")],
                        "duration": ["type": "number", "description": "时长（秒），默认 0.5"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "add_shape",
                description: "在播放头处加一个图形（矩形、圆形、箭头这类），加完可以用 update_clip 调位置大小。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string",
                                 "description": "形状：" + ShapeType.allCases.map(\.rawValue).joined(separator: "、")],
                        "time": ["type": "number", "description": "放在第几秒，默认播放头处"]
                    ] as [String: Any],
                    "required": ["kind"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "translate_subtitles",
                description: """
                把一条字幕轨整轨翻译成另一种语言，**结果放进一条新字幕轨**，原文那条不动。
                用的是设置里选的翻译引擎。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "track_index": ["type": "integer",
                                        "description": "第几条字幕轨（list_tracks 里的顺序，从 0 起）。不传就翻第一条"],
                        "language": ["type": "string",
                                     "description": "目标语言，比如「英语」「日语」「中文（简体）」。不传用设置里的"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "subtitles_to_speech",
                description: """
                把选中的字幕**配音**成音频轨（AI 朗读）。要先有字幕。
                用的是设置里配好的 TTS 供应商，**花钱**。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "track_index": ["type": "integer", "description": "第几条字幕轨，不传就用第一条"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "enhance_clarity",
                description: """
                给一条视频片段做**清晰度提升**（AI 超分）。很慢 —— 按素材时长算，
                几分钟的片子可能要跑几十分钟，后台进行。
                做完会生成一条新素材和新轨道，原片不动。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string"],
                        "scale": ["type": "integer", "description": "放大倍数，2 或 4，默认 2"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "remove_background_music",
                description: """
                把一条片段的声音**拆成人声和伴奏**（音轨分离），拆出来的每一轨各成一条音频轨。
                想去掉背景音乐、只留人声就用它。耗时约素材时长的 3 倍，后台跑。
                """,
                parameters: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string"]] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "scene_split",
                description: """
                自动找出一条视频里的**镜头切换点**并按点切开。整理素材、去掉废镜头前先用它。
                """,
                parameters: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string"]] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "analyze_highlights",
                description: """
                **一键成片**：对一条视频做语音识别，再让大模型从内容里挑出精彩片段，
                挑完直接生成一条新轨道。用户说「剪个精华」「挑重点」就用它。
                用的是设置 → AI 剪辑里选的那家模型。
                """,
                parameters: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string"]] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "save_project",
                description: "保存当前项目。做完一批改动可以存一下；没保存过的新项目存不了，得用户先另存。",
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .mutating),

            AgentToolSpec(
                name: "undo",
                description: """
                撤销上一步。**你自己那一整轮算一步** —— 撤一次就把这轮改的全退回去。
                改错了、用户说「算了」就用它。
                """,
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .mutating),
        ]
    }

    @MainActor
    static func runStudioTool(_ name: String, args: [String: Any],
                              project p: ProjectState) -> AgentToolResult? {
        switch name {
        case "add_transition":   return addTransition(p, args: args)
        case "add_shape":        return addShape(p, args: args)
        case "translate_subtitles": return translateSubtitles(p, args: args)
        case "subtitles_to_speech": return subtitlesToSpeech(p, args: args)
        case "enhance_clarity":  return enhanceClarity(p, args: args)
        case "remove_background_music": return separateAudio(p, args: args)
        case "scene_split":      return sceneSplit(p, args: args)
        case "analyze_highlights": return analyzeHighlights(p, args: args)

        case "save_project":
            guard p.projectFileURL != nil else {
                return .fail("这个项目还没存过盘，得用户自己选个位置另存一次，我这儿存不了。")
            }
            p.saveProject(silent: true)
            return .ok("已保存。")

        case "undo":
            guard p.undoCount > 0 else { return .fail("没有可撤销的步骤了。") }
            p.undo()
            return .ok("已撤销上一步。")

        default:
            return nil
        }
    }

    // MARK: - 选中辅助

    /// 按 id 前缀把视频片段选中。底层那些功能认的都是「当前选中项」
    @MainActor
    private static func selectVideo(_ p: ProjectState, key: String?) -> (ok: Bool, name: String) {
        guard let key, !key.isEmpty else {
            // 没点名就用第一条视频
            for t in p.videoTracks {
                if let c = t.clips.first {
                    p.selectedVideoClipID = c.id; p.selectedAudioClipID = nil
                    return (true, c.name)
                }
            }
            return (false, "")
        }
        for t in p.videoTracks {
            if let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) {
                p.selectedVideoClipID = c.id; p.selectedAudioClipID = nil
                return (true, c.name)
            }
        }
        return (false, "")
    }

    // MARK: - 各工具

    @MainActor
    private static func addTransition(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        guard let key = args["clip_id"] as? String, !key.isEmpty else { return .fail("缺 clip_id") }
        let kindRaw = (args["kind"] as? String) ?? "dissolve"
        guard let type = TransitionType(rawValue: kindRaw) else {
            return .fail("没有叫 \(kindRaw) 的转场。能用的："
                         + TransitionType.allCases.map(\.rawValue).joined(separator: "、"))
        }
        let dur = max(0.1, min(3, (args["duration"] as? Double) ?? 0.5))
        for t in p.videoTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateVideoClip(id: c.id) { $0.inTransition = Transition(type: type, duration: dur) }
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」的开头加了 \(type.rawValue) 转场，\(dur) 秒。")
        }
        return .fail("找不到 id 以 \(key) 开头的视频片段。")
    }

    @MainActor
    private static func addShape(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        guard let raw = args["kind"] as? String, let type = ShapeType(rawValue: raw) else {
            return .fail("形状要是这几个之一：" + ShapeType.allCases.map(\.rawValue).joined(separator: "、"))
        }
        p.addShape(type: type, at: (args["time"] as? Double) ?? p.currentTime)
        return .ok("加了一个\(type.label)。想调位置大小就用 update_clip。")
    }

    @MainActor
    private static func translateSubtitles(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let idx = (args["track_index"] as? Int) ?? 0
        guard p.subtitleTracks.indices.contains(idx) else {
            return .fail("没有第 \(idx) 条字幕轨，现在一共 \(p.subtitleTracks.count) 条。")
        }
        let originals = p.subtitleTracks[idx].clips
        guard !originals.isEmpty else { return .fail("那条字幕轨是空的。") }
        let lang = (args["language"] as? String) ?? p.translationTargetLang

        var newTrack = Track<SubtitleClip>(label: "翻译·\(lang)")
        newTrack.subtitleStyle = p.subtitleTracks[idx].subtitleStyle
        // 先占位，翻完再逐条填回去 —— 不然界面上会先空一段
        newTrack.clips = originals.map {
            SubtitleClip(text: "…", startTime: $0.startTime, endTime: $0.endTime)
        }
        p.subtitleTracks.append(newTrack)
        p.syncOverlayOrder()
        let trackID = newTrack.id
        let texts = originals.map(\.text)

        Task { @MainActor in
            let out = await Translator.translateConcurrent(texts, to: lang)
            guard let ti = p.subtitleTracks.firstIndex(where: { $0.id == trackID }) else { return }
            for (i, s) in out.enumerated() where p.subtitleTracks[ti].clips.indices.contains(i) {
                p.subtitleTracks[ti].clips[i].text = s
            }
            p.rebuildTimelinePreview()
            p.scheduleAutoSave()
            p.showSuccessToast(icon: "checkmark.circle.fill", iconColor: .green,
                               title: "翻译完成", subtitle: "\(out.count) 条 → \(lang)", autoCountdown: true)
        }
        return .ok("""
            已经开始翻译 \(originals.count) 条字幕到\(lang)，结果放在新轨道「翻译·\(lang)」里。
            后台跑，完事会有提示，不用在这儿等。
            """)
    }

    @MainActor
    private static func subtitlesToSpeech(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let idx = (args["track_index"] as? Int) ?? 0
        guard p.subtitleTracks.indices.contains(idx) else {
            return .fail("没有第 \(idx) 条字幕轨。")
        }
        let clips = p.subtitleTracks[idx].clips
        guard !clips.isEmpty else { return .fail("那条字幕轨是空的。") }
        // 底层认的是「选中的字幕」，先全选上
        p.selectedClipIDs = Set(clips.map(\.id))
        p.selectedSubtitleClipID = clips.first?.id
        p.convertSelectedSubtitlesToSpeech()
        return .ok("""
            已经开始给 \(clips.count) 条字幕配音，做完会成为一条新的音频轨。
            后台跑的，进度在右下角。
            """)
    }

    @MainActor
    private static func enhanceClarity(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let sel = selectVideo(p, key: args["clip_id"] as? String)
        guard sel.ok else { return .fail("找不到那条视频片段，先 list_tracks 看看。") }
        let scale: ProjectState.ClarityScale = ((args["scale"] as? Int) ?? 2) >= 4 ? .x4 : .x2
        p.enhanceClaritySelection(scale: scale)
        return .ok("""
            已经开始给「\(sel.name)」做 \(scale.rawValue) 倍清晰度提升。
            **这个很慢**，按素材时长算可能要几十分钟，后台跑，进度在右下角。
            做完会多出一条新素材和新轨道，原片不动。
            """)
    }

    @MainActor
    private static func separateAudio(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let sel = selectVideo(p, key: args["clip_id"] as? String)
        guard sel.ok else { return .fail("找不到那条片段，先 list_tracks 看看。") }
        p.removeBackgroundMusicForSelection()
        return .ok("""
            已经开始分离「\(sel.name)」的声音，人声和伴奏会各成一条音频轨。
            耗时约素材时长的 3 倍，后台跑。
            """)
    }

    @MainActor
    private static func sceneSplit(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let sel = selectVideo(p, key: args["clip_id"] as? String)
        guard sel.ok else { return .fail("找不到那条视频片段，先 list_tracks 看看。") }
        guard SceneDetector.isInstalled else {
            return .fail("场景检测组件还没装。让用户到设置 → AI 剪辑里装一下，再来找我。")
        }
        p.sceneDetectSelectedClip()
        return .ok("已经开始检测「\(sel.name)」的镜头切换点，找完会按点切开。进度在右下角。")
    }

    @MainActor
    private static func analyzeHighlights(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        let sel = selectVideo(p, key: args["clip_id"] as? String)
        guard sel.ok else { return .fail("找不到那条视频片段，先 list_tracks 看看。") }
        guard !AppSettings.shared.llmAPIKey.isEmpty else {
            return .fail("「AI 剪辑」还没配 API Key，让用户去设置 → AI 设置里填一个。")
        }
        p.llmAnalyzeSelectedClip()
        return .ok("""
            已经开始分析「\(sel.name)」：先做语音识别，再让大模型挑精彩片段，
            挑完会生成一条「精彩片段」轨道。后台跑，进度在右下角。
            """)
    }
}

// MARK: - 批 B：素材管理、复合片段、时间线标签、抠图、重做

extension AgentToolbox {

    static var studioTools2: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "redo",
                description: "重做刚撤销的那一步。",
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .mutating),

            AgentToolSpec(
                name: "rename",
                description: """
                给素材或片段改名字。**改素材会连磁盘上的文件一起改名**，改片段只改时间轴上的显示。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "asset_id": ["type": "string", "description": "改素材（list_assets 的 id）"],
                        "clip_id": ["type": "string", "description": "改片段（list_tracks 的 id）。跟 asset_id 二选一"],
                        "name": ["type": "string", "description": "新名字"]
                    ] as [String: Any],
                    "required": ["name"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "delete_asset",
                description: """
                从素材库删掉一个素材。**时间轴上用到它的片段会一起消失**，
                所以删之前先跟用户确认清楚。磁盘上的原文件不动。
                """,
                parameters: [
                    "type": "object",
                    "properties": ["asset_id": ["type": "string"]] as [String: Any],
                    "required": ["asset_id"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "group_clips",
                description: """
                把几条片段打包成一个**复合片段**（像文件夹一样收起来，可以整体挪动）。
                整理复杂时间轴时好用。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_ids": ["type": "array", "items": ["type": "string"] as [String: Any],
                                     "description": "要打包的片段 id 们，至少两个"]
                    ] as [String: Any],
                    "required": ["clip_ids"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "ungroup_clip",
                description: "把一个复合片段拆开，里面的内容原位散回各自的轨道。",
                parameters: [
                    "type": "object",
                    "properties": ["clip_id": ["type": "string", "description": "复合片段的 id"]] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "new_timeline",
                description: """
                新建一条时间线（标签页），并切过去。
                想在同一个项目里做另一个版本、试试别的剪法时用它，互不影响。
                """,
                parameters: [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "名字，不传就用默认"]] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "switch_timeline",
                description: "切到第几条时间线（get_project 里能看到都有哪些，从 0 起）。",
                parameters: [
                    "type": "object",
                    "properties": ["index": ["type": "integer"]] as [String: Any],
                    "required": ["index"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "remove_image_background",
                description: """
                给图片片段**抠图去背景**，做完生成一张透明背景的新图并替换原片段。
                本地跑，不花钱；BiRefNet 引擎第一次用要先下模型。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "图片片段的 id"],
                        "mode": ["type": "string",
                                 "description": "auto（自动，默认）/ subject（保主体）/ solid（纯色背景）"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),
        ]
    }

    @MainActor
    static func runStudioTool2(_ name: String, args: [String: Any],
                               project p: ProjectState) -> AgentToolResult? {
        switch name {
        case "redo":
            guard p.redoCount > 0 else { return .fail("没有可重做的步骤。") }
            p.redo()
            return .ok("已重做。")

        case "rename":
            guard let newName = (args["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty
            else { return .fail("缺 name") }
            if let key = args["asset_id"] as? String, !key.isEmpty {
                guard let a = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(key) }) else {
                    return .fail("素材库里找不到 id 以 \(key) 开头的素材。")
                }
                let old = a.name
                p.renameAsset(id: a.id, to: newName)
                return .ok("素材「\(old)」改成了「\(newName)」（磁盘上的文件也跟着改了）。")
            }
            if let key = args["clip_id"] as? String, !key.isEmpty {
                var all: [UUID] = []
                all += p.videoTracks.flatMap(\.clips).map(\.id)
                all += p.audioTracks.flatMap(\.clips).map(\.id)
                all += p.imageTracks.flatMap(\.clips).map(\.id)
                guard let id = all.first(where: { "\($0)".hasPrefix(key) }) else {
                    return .fail("找不到 id 以 \(key) 开头的片段。")
                }
                p.renameClip(id: id, to: newName)
                return .ok("片段改名为「\(newName)」。")
            }
            return .fail("asset_id 和 clip_id 得给一个。")

        case "delete_asset":
            guard let key = args["asset_id"] as? String,
                  let a = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(key) })
            else { return .fail("素材库里找不到那个素材，先 list_assets 看看。") }
            let name = a.name
            p.removeAssetAndClips(assetID: a.id)
            return .ok("已经把「\(name)」从素材库删掉了，时间轴上用到它的片段也一并没了。")

        case "group_clips":
            let keys = (args["clip_ids"] as? [String]) ?? []
            guard keys.count >= 2 else { return .fail("至少给两条片段才能打包。") }
            var ids = Set<UUID>()
            // 一条条 append，别写成一长串 + —— 那样 Swift 的类型检查会直接超时
            var pool: [UUID] = []
            pool += p.videoTracks.flatMap(\.clips).map(\.id)
            pool += p.audioTracks.flatMap(\.clips).map(\.id)
            pool += p.imageTracks.flatMap(\.clips).map(\.id)
            pool += p.subtitleTracks.flatMap(\.clips).map(\.id)
            pool += p.textTracks.flatMap(\.clips).map(\.id)
            pool += p.shapeTracks.flatMap(\.clips).map(\.id)
            for k in keys {
                guard let hit = pool.first(where: { "\($0)".hasPrefix(k) }) else {
                    return .fail("找不到 id 以 \(k) 开头的片段。")
                }
                ids.insert(hit)
            }
            p.selectedClipIDs = ids
            p.createCompoundFromSelected()
            return .ok("已经把这 \(ids.count) 条打包成一个复合片段。")

        case "ungroup_clip":
            guard let key = args["clip_id"] as? String,
                  let c = p.compoundTracks.flatMap(\.clips).first(where: { "\($0.id)".hasPrefix(key) })
            else { return .fail("找不到那个复合片段，先 list_tracks 看看。") }
            p.dissolveCompound(c.id)
            return .ok("已经把「\(c.name)」拆开了。")

        case "new_timeline":
            _ = p.addTimelineTab()
            if let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty, let last = p.tabs.last {
                p.renameTab(id: last.id, to: name)
            }
            return .ok("新建了一条时间线，已经切过去了。现在是第 \(p.activeTab) 条。")

        case "switch_timeline":
            guard let i = args["index"] as? Int, p.tabs.indices.contains(i) else {
                return .fail("没有第 \(args["index"] ?? "?") 条时间线，一共 \(p.tabs.count) 条。")
            }
            p.switchToTab(i)
            return .ok("切到第 \(i) 条时间线「\(p.tabs[i].name)」了。")

        case "remove_image_background":
            guard let key = args["clip_id"] as? String, !key.isEmpty else { return .fail("缺 clip_id") }
            var hit: ImageClip?
            for t in p.imageTracks {
                if let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) { hit = c; break }
            }
            guard let clip = hit else { return .fail("找不到 id 以 \(key) 开头的图片片段。") }
            let mode = BackgroundRemover.Mode(rawValue: (args["mode"] as? String) ?? "auto") ?? .auto
            p.selectedImageClipID = clip.id
            p.removeBackgroundForSelection(mode: mode)
            return .ok("已经开始给「\(clip.name)」去背景，做完会替换成透明背景的新图。进度在右下角。")

        default:
            return nil
        }
    }
}
