// AgentTools+Project.swift
//
// 管「结构」的工具：轨道增删、静音隐藏，时间线复制改名删除，标记，
// 复制粘贴，多选对齐，进出复合片段，文字模板。
//
// 这些以前只有界面上点得到。Agent 手上只有「加片段 / 改片段」，
// 用户说「把第二条字幕轨删了」「这条音轨静音」它只能回做不了。

import AVFoundation
import AppKit
import Foundation

extension AgentToolbox {

    static var projectTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "add_track",
                description: "新建一条空轨道。一般不用专门建 —— 往时间轴加东西时会自动找空轨或新建；要特意分开放时才用它。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["video", "audio", "image", "subtitle", "text", "shape"]],
                        "name": ["type": "string", "description": "轨道名，不传用默认"]
                    ] as [String: Any],
                    "required": ["kind"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "delete_track",
                description: "删掉一整条轨道，**上面的片段一起没了**。track_id 用 list_tracks 查。",
                parameters: [
                    "type": "object",
                    "properties": ["track_id": ["type": "string"]] as [String: Any],
                    "required": ["track_id"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "set_track",
                description: """
                改一条轨道的状态：静音 muted（视频、音频、复合轨才有）、隐藏 hidden（音频轨没有）、改名 name。
                只传要改的。隐藏 / 静音的轨道导出时也不出。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "track_id": ["type": "string"],
                        "muted": ["type": "boolean"],
                        "hidden": ["type": "boolean"],
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["track_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "edit_timeline",
                description: """
                管时间线标签页：duplicate 复制一份（连内容），rename 改名，close 关掉标签（时间线还在，只是收起来）。
                index 从 0 数，get_project 能看到有哪些。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["duplicate", "rename", "close"]],
                        "index": ["type": "integer"],
                        "name": ["type": "string", "description": "rename 时的新名字"]
                    ] as [String: Any],
                    "required": ["action", "index"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "delete_timeline",
                description: "彻底删掉一条时间线（标签页和里面的内容都没了）。index 从 0 数。",
                parameters: [
                    "type": "object",
                    "properties": ["index": ["type": "integer"]] as [String: Any],
                    "required": ["index"]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "marker",
                description: """
                时间轴上的标记（挂在片段上的小旗子）。
                list 列出全部；add 在某片段的某个时刻打一个（time 是时间轴上的绝对秒数，要落在片段范围里）；
                update 改标题 / 颜色；delete 删掉。颜色：cyan、pink、orange、green、purple。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["list", "add", "update", "delete"]],
                        "clip_id": ["type": "string", "description": "add 时打在哪条片段上"],
                        "time": ["type": "number", "description": "add 时的位置（秒）"],
                        "marker_id": ["type": "string", "description": "update / delete 时用，list 能查到"],
                        "title": ["type": "string"],
                        "color": ["type": "string", "enum": Marker.MarkerColor.allCases.map(\.rawValue)]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "copy_clips",
                description: """
                复制 / 剪切几条片段，再贴到别的时间。**一步到位**：给 clip_ids 和 time 就是「复制过去」，
                cut=true 就是「挪过去」（原处删掉）。贴过去各条之间的相对位置不变，轨道自动找空的。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_ids": ["type": "array", "items": ["type": "string"]],
                        "time": ["type": "number", "description": "贴到哪（秒），最早那条的开头落在这"],
                        "cut": ["type": "boolean", "description": "true = 剪切，默认复制"]
                    ] as [String: Any],
                    "required": ["clip_ids", "time"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "select_clips",
                description: """
                在界面上选中片段，给用户看「是哪几条」，或者为后续界面操作做准备。
                extend=left / right：把同轨道上这条左边 / 右边的全部一起选上（跟右键「向左全选」一样）。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_ids": ["type": "array", "items": ["type": "string"]],
                        "extend": ["type": "string", "enum": ["left", "right"]]
                    ] as [String: Any],
                    "required": ["clip_ids"]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "align_clips",
                description: """
                对齐画面上的图层（图片、文字、图形、视频）。只给一条就是对齐画面边缘，
                给多条就是对齐它们的包围盒。hdist / vdist 是等间距分布，要三条以上。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_ids": ["type": "array", "items": ["type": "string"]],
                        "mode": ["type": "string",
                                 "enum": ["left", "hcenter", "right", "top", "vcenter", "bottom", "hdist", "vdist"]]
                    ] as [String: Any],
                    "required": ["clip_ids", "mode"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "compound_edit",
                description: """
                进入复合片段内部编辑（enter，给 clip_id），或者退回上一层（exit）。
                进去以后 list_tracks 看到的就是它里面的轨道，改完记得 exit。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["enter", "exit"]],
                        "clip_id": ["type": "string"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "set_project",
                description: """
                改项目设置（属性区什么都没选中时显示的那块）。只传要改的。
                画面比例、分辨率改了预览和导出都跟着变；给 width + height 就是自定义尺寸。
                帧率、码率是导出的默认值。save_dir 是新项目默认保存到哪个文件夹。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "项目名"],
                        "aspect_ratio": ["type": "string", "enum": ExportSettings.aspectRatios.filter { $0 != ExportSettings.customAspect }],
                        "resolution": ["type": "string", "enum": ExportSettings.resolutions,
                                       "description": "分辨率定的是短边：1080p 竖屏就是 1080 宽"],
                        "width": ["type": "integer", "description": "自定义输出宽（要和 height 一起给）"],
                        "height": ["type": "integer", "description": "自定义输出高"],
                        "fps": ["type": "integer", "enum": ExportSettings.fpsOptions],
                        "bitrate": ["type": "integer", "description": "码率 kbps，1000~50000"],
                        "save_dir": ["type": "string", "description": "项目默认保存文件夹的绝对路径"]
                    ] as [String: Any]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "set_cover",
                description: """
                设项目封面（导出时写进视频的封面图）。source 给素材 id、图片文件绝对路径，
                或者写 frame 表示用时间轴 time 秒那一帧（画面上的字幕文字都在）。clear=true 清掉封面。
                想要带标题的封面：先在时间轴那一刻加好文字，再用 frame；或者生成一张图再设。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string"],
                        "time": ["type": "number", "description": "source=frame 时取第几秒；素材是视频时也用它"],
                        "clear": ["type": "boolean"]
                    ] as [String: Any]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "new_project",
                description: "新建一个项目，在**新窗口**里打开（当前项目不动，你这边的对话也还留在当前窗口）。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "directory": ["type": "string", "description": "存到哪个文件夹，不传用默认保存位置"]
                    ] as [String: Any],
                    "required": ["name"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "open_project",
                description: "在新窗口里打开一个 .bcj 项目文件。",
                parameters: [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": ".bcj 文件绝对路径"]] as [String: Any],
                    "required": ["path"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "save_frame",
                description: """
                把时间轴某一刻的画面存成图片放进素材库（跟预览区的「捕捉当前帧」一样）。
                place=true 顺带放到图片轨道上那个时刻。只是自己想看一眼画面用 capture_frame，别用这个。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "number", "description": "秒，不传就是播放头"],
                        "place": ["type": "boolean", "description": "顺带放上图片轨道，默认 false"]
                    ] as [String: Any]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "text_template",
                description: """
                文字样式模板。list 列出已有的；save 把一条文字片段的样式存成模板（name 可选）；
                apply 把模板套到一条文字片段上；delete 删模板。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["list", "save", "apply", "delete"]],
                        "clip_id": ["type": "string"],
                        "template": ["type": "string", "description": "模板名或 id 前几位"],
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating)
        ]
    }

    @MainActor
    static func runProjectTool(_ name: String, args: [String: Any],
                               project p: ProjectState) -> AgentToolResult? {
        func s(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func n(_ k: String) -> Double? {
            if let d = args[k] as? Double { return d }
            if let i = args[k] as? Int { return Double(i) }
            if let t = args[k] as? String { return Double(t) }
            return nil
        }
        func b(_ k: String) -> Bool? {
            if let v = args[k] as? Bool { return v }
            if let t = args[k] as? String { return t == "true" ? true : (t == "false" ? false : nil) }
            return nil
        }
        let ids = (args["clip_ids"] as? [Any])?.compactMap { $0 as? String } ?? []

        switch name {
        case "add_track":
            return addTrack(p, kind: s("kind") ?? "", name: s("name"))
        case "delete_track":
            return deleteTrack(p, prefix: s("track_id") ?? "")
        case "set_track":
            return setTrack(p, prefix: s("track_id") ?? "", muted: b("muted"), hidden: b("hidden"), name: s("name"))
        case "edit_timeline", "delete_timeline":
            guard let i = n("index").map({ Int($0) }), p.tabs.indices.contains(i) else {
                return .fail("没有第 \(args["index"] ?? "?") 条时间线（从 0 数），一共 \(p.tabs.count) 条。")
            }
            let tab = p.tabs[i]
            if name == "delete_timeline" {
                p.deleteTab(id: tab.id)
                return .ok("删掉了时间线「\(tab.name)」。")
            }
            switch s("action") {
            case "duplicate":
                p.duplicateTab(id: tab.id)
                return .ok("复制了一份「\(tab.name)」。")
            case "rename":
                guard let nm = s("name"), !nm.isEmpty else { return .fail("rename 要给 name") }
                p.renameTab(id: tab.id, to: nm)
                return .ok("「\(tab.name)」改名为「\(nm)」。")
            case "close":
                p.closeTab(id: tab.id)
                return .ok("关掉了标签「\(tab.name)」，时间线还在，想看再用 switch_timeline 打开。")
            default:
                return .fail("action 只能是 duplicate / rename / close")
            }
        case "marker":
            return marker(p, action: s("action") ?? "", clipKey: s("clip_id"), time: n("time"),
                          markerKey: s("marker_id"), title: s("title"), color: s("color"))
        case "copy_clips":
            guard let t = n("time") else { return .fail("缺 time") }
            let found = resolveClipIDs(p, ids)
            guard !found.isEmpty else { return .fail("一条片段都没找到，先 list_tracks 看 id。") }
            selectOnly(p, found)
            let cut = b("cut") ?? false
            if cut { p.cutSelected() } else { p.copySelected() }
            p.currentTime = max(0, t); p.seekRequest &+= 1
            p.pasteAtPlayhead()
            return .ok("\(cut ? "挪" : "复制")了 \(found.count) 条片段到 \(String(format: "%.2f", t)) 秒。")
        case "select_clips":
            let found = resolveClipIDs(p, ids)
            guard let first = found.first else { return .fail("一条片段都没找到，先 list_tracks 看 id。") }
            selectOnly(p, found)
            switch s("extend") {
            case "left": p.selectLeftOf(first)
            case "right": p.selectRightOf(first)
            default: break
            }
            return .ok("界面上选中了 \(p.selectedClipIDs.count) 条片段。")
        case "align_clips":
            let found = resolveClipIDs(p, ids)
            guard let first = found.first else { return .fail("一条片段都没找到，先 list_tracks 看 id。") }
            let modes: [String: LayerAlignMode] = ["left": .left, "hcenter": .hcenter, "right": .right,
                                                   "top": .top, "vcenter": .vcenter, "bottom": .bottom,
                                                   "hdist": .hdist, "vdist": .vdist]
            guard let m = modes[s("mode") ?? ""] else { return .fail("mode 不认识") }
            if m.needsThree && found.count < 3 { return .fail("等间距分布要三条以上。") }
            selectOnly(p, found)
            p.alignLayers(m, anchorID: first)
            p.refreshOverlayComposite(); p.rebuildTimelinePreview()
            return .ok(found.count == 1 ? "已按画面对齐。" : "已对齐 \(found.count) 条。")
        case "compound_edit":
            if s("action") == "exit" {
                guard p.isInsideCompound else { return .fail("现在不在复合片段里面。") }
                p.exitCompound()
                return .ok("退回上一层了。")
            }
            guard let key = s("clip_id"), !key.isEmpty else { return .fail("enter 要给 clip_id") }
            for ti in p.compoundTracks.indices {
                if let ci = p.compoundTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) }) {
                    let nm = p.compoundTracks[ti].clips[ci].name
                    p.enterCompound(trackIndex: ti, clipIndex: ci)
                    return .ok("进到复合片段「\(nm)」里面了。现在 list_tracks 看到的是它里面的轨道，改完用 action=exit 出来。")
                }
            }
            return .fail("找不到 id 以 \(key) 开头的复合片段。")
        case "set_project":
            return setProject(p, args: args)
        case "set_cover":
            return setCover(p, source: s("source"), time: n("time"), clear: b("clear") ?? false)
        case "new_project":
            guard let nm = s("name"), !nm.isEmpty else { return .fail("缺 name") }
            let dir = s("directory").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? AppSettings.shared.effectiveProjectDir
            _ = WindowManager.shared.newWindow(.createProject(name: nm, directory: dir))
            return .ok("新窗口里建好了项目「\(nm)」，存在 \(dir.path)。这边的对话还在当前项目。")
        case "open_project":
            guard let path = s("path"), !path.isEmpty else { return .fail("缺 path") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path), url.pathExtension.lowercased() == "bcj" else {
                return .fail("「\(url.lastPathComponent)」不存在或者不是 .bcj 项目文件。")
            }
            _ = WindowManager.shared.newWindow(.openProject(url))
            return .ok("在新窗口里打开了「\(url.lastPathComponent)」。")
        case "save_frame":
            let t = n("time") ?? p.currentTime
            guard let cg = try? renderTimelineFrame(p, at: t),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                return .fail("截不到 \(String(format: "%.2f", t)) 秒的画面，时间轴可能是空的。")
            }
            let dir = AppSettings.shared.effectiveProjectDir.appendingPathComponent("截图")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("frame_\(Int(t * 1000)).png")
            do { try png.write(to: url) } catch { return .fail("存图失败：\(error.localizedDescription)") }
            if !p.mediaAssets.contains(where: { $0.url == url }) { p.importFile(url) }
            guard let asset = p.mediaAssets.first(where: { $0.url == url }) else { return .fail("图存好了但没进素材库。") }
            if b("place") == true { p.addToTimelineAt(asset, time: t) }
            return .ok("存好了「\(url.lastPathComponent)」，素材 id \(asset.id.uuidString.prefix(8))"
                       + (b("place") == true ? "，已放到图片轨道 \(String(format: "%.2f", t)) 秒处。" : "。"))
        case "text_template":
            return textTemplate(p, action: s("action") ?? "", clipKey: s("clip_id"),
                                templateKey: s("template"), name: s("name"))
        default:
            return nil
        }
    }

    // MARK: - 轨道

    @MainActor
    private static func addTrack(_ p: ProjectState, kind: String, name: String?) -> AgentToolResult {
        p.pushUndo()
        let label: String
        switch kind {
        case "video":
            label = name ?? "视频"; p.videoTracks.append(Track(label: label)); p.syncVideoSectionOrder()
        case "audio":
            label = name ?? "音频"; p.audioTracks.append(Track(label: label)); p.syncAudioSectionOrder()
        case "image":
            label = name ?? "图片"; p.imageTracks.append(Track(label: label)); p.syncOverlayOrder()
        case "subtitle":
            label = name ?? "字幕"
            var t = Track<SubtitleClip>(label: label); t.subtitleStyle = SubtitleStyle()
            p.subtitleTracks.append(t); p.syncOverlayOrder()
        case "text":
            label = name ?? "文字"; p.textTracks.append(Track(label: label)); p.syncOverlayOrder()
        case "shape":
            label = name ?? "图形"; p.shapeTracks.append(Track(label: label)); p.syncOverlayOrder()
        default:
            return .fail("kind 只能是 video / audio / image / subtitle / text / shape")
        }
        p.rebuildTimelinePreview()
        return .ok("新建了一条空的「\(label)」轨道。")
    }

    /// 在所有轨道数组里按 id 前缀找，找到就对那个数组动手
    private enum TrackBlock { case video, audio, overlay }

    @MainActor
    private static func withTrack(_ p: ProjectState, prefix: String,
                                  _ body: (_ label: inout String, _ muted: inout Bool, _ visible: inout Bool,
                                           _ remove: inout Bool, _ kind: String, _ canMute: Bool, _ canHide: Bool) -> Void)
        -> (found: Bool, block: TrackBlock) {
        func run<C>(_ kp: ReferenceWritableKeyPath<ProjectState, [Track<C>]>, _ kind: String,
                    canMute: Bool, canHide: Bool) -> Bool {
            guard let i = p[keyPath: kp].firstIndex(where: { "\($0.id)".hasPrefix(prefix) }) else { return false }
            var t = p[keyPath: kp][i]
            var remove = false
            body(&t.label, &t.isMuted, &t.isVisible, &remove, kind, canMute, canHide)
            if remove { p[keyPath: kp].remove(at: i) } else { p[keyPath: kp][i] = t }
            return true
        }
        guard !prefix.isEmpty else { return (false, .overlay) }
        if run(\.videoTracks, "视频", canMute: true, canHide: true) { return (true, .video) }
        if run(\.audioTracks, "音频", canMute: true, canHide: false) { return (true, .audio) }
        if run(\.imageTracks, "图片", canMute: false, canHide: true)
            || run(\.subtitleTracks, "字幕", canMute: false, canHide: true)
            || run(\.textTracks, "文字", canMute: false, canHide: true)
            || run(\.shapeTracks, "图形", canMute: false, canHide: true)
            || run(\.filterTracks, "滤镜", canMute: false, canHide: true)
            || run(\.adjustTracks, "调节", canMute: false, canHide: true)
            || run(\.effectTracks, "特效", canMute: false, canHide: true)
            || run(\.compoundTracks, "复合", canMute: true, canHide: true) { return (true, .overlay) }
        return (false, .overlay)
    }

    @MainActor
    private static func afterTrackChange(_ p: ProjectState, _ block: TrackBlock) {
        switch block {
        case .video: p.syncVideoSectionOrder()
        case .audio: p.syncAudioSectionOrder()
        case .overlay: p.syncOverlayOrder()
        }
        p.refreshOverlayComposite()
        p.rebuildTimelinePreview()
    }

    @MainActor
    private static func deleteTrack(_ p: ProjectState, prefix: String) -> AgentToolResult {
        p.pushUndo()
        var what = ""
        let r = withTrack(p, prefix: prefix) { label, _, _, remove, kind, _, _ in
            what = label.isEmpty ? kind : label
            remove = true
        }
        guard r.found else { return .fail("找不到 id 以 \(prefix) 开头的轨道，先 list_tracks 看轨道 id。") }
        p.clearClipSelections()
        p.selectedClipIDs.removeAll()
        afterTrackChange(p, r.block)
        return .ok("删掉了「\(what)」轨道。")
    }

    @MainActor
    private static func setTrack(_ p: ProjectState, prefix: String, muted: Bool?, hidden: Bool?,
                                 name: String?) -> AgentToolResult {
        guard muted != nil || hidden != nil || name != nil else { return .fail("一个要改的都没传。") }
        p.pushUndo()
        var done: [String] = []
        var skipped: [String] = []
        let r = withTrack(p, prefix: prefix) { label, isMuted, isVisible, _, kind, canMute, canHide in
            if let m = muted {
                if canMute { isMuted = m; done.append(m ? "静音" : "取消静音") }
                else { skipped.append("\(kind)轨没有静音") }
            }
            if let h = hidden {
                if canHide { isVisible = !h; done.append(h ? "隐藏" : "显示") }
                else { skipped.append("\(kind)轨没有隐藏") }
            }
            if let nm = name, !nm.isEmpty { label = nm; done.append("改名「\(nm)」") }
        }
        guard r.found else { return .fail("找不到 id 以 \(prefix) 开头的轨道，先 list_tracks 看轨道 id。") }
        afterTrackChange(p, r.block)
        var msg = done.isEmpty ? "没改动。" : "轨道已\(done.joined(separator: "、"))。"
        if !skipped.isEmpty { msg += "（\(skipped.joined(separator: "，"))）" }
        return done.isEmpty ? .fail(msg) : .ok(msg)
    }

    // MARK: - 片段 id / 选中

    /// 各类片段里按前缀找完整 id
    @MainActor
    static func resolveClipIDs(_ p: ProjectState, _ keys: [String]) -> [UUID] {
        var all: [UUID] = []
        func add<C: Identifiable>(_ tracks: [Track<C>]) where C.ID == UUID {
            for t in tracks { all += t.clips.map(\.id) }
        }
        add(p.videoTracks); add(p.audioTracks); add(p.imageTracks); add(p.subtitleTracks)
        add(p.textTracks); add(p.shapeTracks); add(p.filterTracks); add(p.adjustTracks)
        add(p.effectTracks); add(p.compoundTracks)
        var out: [UUID] = []
        for k in keys where !k.isEmpty {
            if let id = all.first(where: { "\($0)".hasPrefix(k) }), !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// 设成界面上的「主选中」。分割、打标记这类按钮操作认的是它，
    /// 光往 selectedClipIDs 里塞不算数。滤镜 / 调节 / 特效没有这一路，返回 false
    @MainActor
    @discardableResult
    static func selectPrimary(_ p: ProjectState, _ id: UUID) -> Bool {
        p.clearClipSelections()
        if p.videoTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedVideoClipID = id }
        else if p.audioTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedAudioClipID = id }
        else if p.imageTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedImageClipID = id }
        else if p.subtitleTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedSubtitleClipID = id }
        else if p.textTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedTextClipID = id }
        else if p.shapeTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedShapeClipID = id }
        else if p.compoundTracks.contains(where: { $0.clips.contains { $0.id == id } }) { p.selectedCompoundClipID = id }
        else { return false }
        return true
    }

    @MainActor
    private static func selectOnly(_ p: ProjectState, _ ids: [UUID]) {
        p.clearClipSelections()
        p.selectedClipIDs = Set(ids)
    }

    // MARK: - 标记

    @MainActor
    private static func marker(_ p: ProjectState, action: String, clipKey: String?, time: Double?,
                               markerKey: String?, title: String?, color: String?) -> AgentToolResult {
        func fmt(_ t: Double) -> String { String(format: "%.2f", t) }
        switch action {
        case "list":
            let all = p.allMarkersAbsolute.sorted { $0.absoluteTime < $1.absoluteTime }
            guard !all.isEmpty else { return .ok("时间轴上还没有标记。") }
            return .ok(all.map { "- \($0.id.uuidString.prefix(8)) @ \(fmt($0.absoluteTime))s「\($0.marker.title)」\($0.marker.color.rawValue)" }
                .joined(separator: "\n"))
        case "add":
            guard let key = clipKey, let t = time else { return .fail("add 要给 clip_id 和 time") }
            guard let id = resolveClipIDs(p, [key]).first else { return .fail("找不到 id 以 \(key) 开头的片段。") }
            // 打标记走的是「当前选中的那条」，按类型把它设成主选中
            guard selectPrimary(p, id) else { return .fail("滤镜、调节、特效片段上不能打标记。") }
            let before = Set(p.allMarkersAbsolute.map(\.id))
            p.currentTime = max(0, t); p.seekRequest &+= 1
            p.addMarkerToSelectedClip()
            guard let m = p.allMarkersAbsolute.first(where: { !before.contains($0.id) }) else {
                return .fail("\(fmt(t)) 秒不在这条片段的范围里，打不上。")
            }
            p.updateMarker(id: m.id) { mk in
                if let title, !title.isEmpty { mk.title = title }
                if let c = color.flatMap(Marker.MarkerColor.init(rawValue:)) { mk.color = c }
            }
            return .ok("在 \(fmt(t)) 秒打了标记（id \(m.id.uuidString.prefix(8))）。")
        case "update", "delete":
            guard let key = markerKey, !key.isEmpty,
                  let m = p.allMarkersAbsolute.first(where: { "\($0.id)".hasPrefix(key) }) else {
                return .fail("找不到这个标记，先 action=list 看 id。")
            }
            if action == "delete" {
                p.removeMarker(id: m.id)
                return .ok("删掉了标记「\(m.marker.title)」。")
            }
            p.pushUndo()
            p.updateMarker(id: m.id) { mk in
                if let title, !title.isEmpty { mk.title = title }
                if let c = color.flatMap(Marker.MarkerColor.init(rawValue:)) { mk.color = c }
            }
            return .ok("改好了。")
        default:
            return .fail("action 只能是 list / add / update / delete")
        }
    }

    // MARK: - 项目设置

    @MainActor
    private static func setProject(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        func int(_ k: String) -> Int? {
            if let i = args[k] as? Int { return i }
            if let d = args[k] as? Double { return Int(d) }
            if let t = args[k] as? String { return Int(t) }
            return nil
        }
        var done: [String] = []
        var bad: [String] = []
        if let nm = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !nm.isEmpty {
            p.projectName = nm; done.append("项目名「\(nm)」")
        }
        if let w = int("width"), let h = int("height") {
            guard w >= 2, h >= 2 else { return .fail("宽高至少 2") }
            p.customOutputWidth = max(2, (w / 2) * 2)
            p.customOutputHeight = max(2, (h / 2) * 2)
            p.previewAspectRatio = ExportSettings.customAspect
            done.append("自定义尺寸 \(p.customOutputWidth)×\(p.customOutputHeight)")
        } else if let ar = args["aspect_ratio"] as? String {
            if ExportSettings.aspectRatios.contains(ar), ar != ExportSettings.customAspect {
                p.previewAspectRatio = ar; done.append("画面比例 \(ar)")
            } else { bad.append("比例 \(ar) 不认识") }
        }
        if let r = args["resolution"] as? String {
            if ExportSettings.resolutions.contains(r) { p.previewResolution = r; done.append("分辨率 \(r)") }
            else { bad.append("分辨率 \(r) 不认识") }
        }
        if let f = int("fps") {
            if ExportSettings.fpsOptions.contains(f) { p.projectFPS = f; done.append("帧率 \(f)") }
            else { bad.append("帧率只能是 \(ExportSettings.fpsOptions.map(String.init).joined(separator: "/"))") }
        }
        if let br = int("bitrate") {
            p.projectBitrate = max(1000, min(50000, (br / 500) * 500)); done.append("码率 \(p.projectBitrate) kbps")
        }
        if let d = args["save_dir"] as? String, !d.isEmpty {
            let url = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                AppSettings.shared.projectSaveDir = url; done.append("保存位置 \(url.path)")
            } else { bad.append("文件夹 \(d) 不存在") }
        }
        guard !done.isEmpty else { return .fail(bad.isEmpty ? "一个要改的都没传。" : bad.joined(separator: "；")) }
        p.isSaved = false
        p.scheduleAutoSave()
        p.rebuildTimelinePreview()
        let size = p.previewRenderSize
        var msg = "改好了：\(done.joined(separator: "、"))。现在画面 \(Int(size.width))×\(Int(size.height))。"
        if !bad.isEmpty { msg += "（没改：\(bad.joined(separator: "；"))）" }
        return .ok(msg)
    }

    @MainActor
    private static func setCover(_ p: ProjectState, source: String?, time: Double?, clear: Bool) -> AgentToolResult {
        if clear {
            p.cover = nil; p.isSaved = false; p.scheduleAutoSave()
            return .ok("封面清掉了。")
        }
        guard let src = source, !src.isEmpty else { return .fail("要给 source（素材 id / 图片路径 / frame），或者 clear=true") }
        var base: NSImage?
        var sourcePath: String?
        var frameTime: Double = time ?? 0
        if src == "frame" {
            let t = time ?? p.currentTime
            guard let cg = try? renderTimelineFrame(p, at: t) else { return .fail("截不到 \(t) 秒的画面。") }
            base = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            frameTime = 0
        } else {
            let url: URL
            if let a = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(src) }) { url = a.url }
            else { url = URL(fileURLWithPath: (src as NSString).expandingTildeInPath) }
            guard FileManager.default.fileExists(atPath: url.path) else { return .fail("找不到「\(src)」。") }
            sourcePath = url.path
            if AIVideoService.imageExts.contains(url.pathExtension.lowercased()) {
                base = NSImage(contentsOf: url)
            } else {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: frameTime, preferredTimescale: 600), actualTime: nil) {
                    base = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }
        guard let img = base, img.size.width > 0 else { return .fail("读不出画面。") }
        // 按封面编辑器的做法：画面尺寸的黑底，整张图 fit 进去
        let size = p.previewRenderSize
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        let k = min(size.width / img.size.width, size.height / img.size.height)
        let w = img.size.width * k, h = img.size.height * k
        img.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return .fail("封面编码失败。") }
        let dir = (p.projectFileURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(".封面", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cover-\(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: file) } catch { return .fail("封面写文件失败：\(error.localizedDescription)") }
        var cover = ProjectCover()
        cover.sourcePath = sourcePath ?? file.path
        cover.frameTime = frameTime
        cover.renderedPath = ".封面/" + file.lastPathComponent
        p.cover = cover
        p.isSaved = false
        p.scheduleAutoSave()
        return .ok("封面设好了，属性区项目设置里能看到，导出时会写进视频。")
    }

    // MARK: - 文字模板

    @MainActor
    private static func textTemplate(_ p: ProjectState, action: String, clipKey: String?,
                                     templateKey: String?, name: String?) -> AgentToolResult {
        func findTemplate() -> TextTemplate? {
            guard let k = templateKey, !k.isEmpty else { return nil }
            return p.textTemplates.first { $0.name == k } ?? p.textTemplates.first { "\($0.id)".hasPrefix(k) }
        }
        func findText() -> UUID? {
            guard let k = clipKey, !k.isEmpty else { return nil }
            return p.textTracks.flatMap(\.clips).first { "\($0.id)".hasPrefix(k) }?.id
        }
        switch action {
        case "list":
            guard !p.textTemplates.isEmpty else { return .ok("还没有文字模板。") }
            return .ok(p.textTemplates.map { "- \($0.id.uuidString.prefix(8))「\($0.name)」\($0.fontName) \(Int($0.fontSize))" }
                .joined(separator: "\n"))
        case "save":
            guard let id = findText() else { return .fail("save 要给一条文字片段的 clip_id") }
            if let name, !name.isEmpty { p.saveTextTemplate(from: id, name: name) } else { p.saveTextTemplateFromClip(id) }
            return .ok("存成模板「\(p.textTemplates.last?.name ?? "")」了。")
        case "apply":
            guard let t = findTemplate() else { return .fail("找不到这个模板，先 action=list 看看。") }
            guard let id = findText() else { return .fail("apply 要给一条文字片段的 clip_id") }
            p.applyTextTemplate(t, to: id)
            p.refreshOverlayComposite()
            return .ok("套上模板「\(t.name)」了。")
        case "delete":
            guard let t = findTemplate() else { return .fail("找不到这个模板，先 action=list 看看。") }
            p.deleteTextTemplate(id: t.id)
            return .ok("删掉了模板「\(t.name)」。")
        default:
            return .fail("action 只能是 list / save / apply / delete")
        }
    }
}
