// AgentTools+Read.swift
//
// 只读工具：让 Agent 看清楚项目现在长什么样。
//
// 输出**一律带上 id**：Agent 后面要靠 id 去改某一条片段，
// 只给名字和时间的话它没法精确定位，只能瞎猜。

import AppKit
import AVFoundation
import CoreMedia
import Foundation

extension AgentToolbox {

    static var readTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "get_project",
                description: "看项目概况：名字、画面比例、分辨率、总时长、有哪些时间线标签页、当前在哪个、播放头位置。开工前先调它。",
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .readOnly),

            AgentToolSpec(
                name: "list_tracks",
                description: "列出当前时间线的所有轨道和里面的片段（含 id、名字、起止时间，字幕轨带字号）。要改某条片段必须先从这里拿到它的 id；要看它的具体属性用 get_clip。"
                    + "片段多的轨道（比如几百句字幕）每条只列前 \(trackListCap) 段，其余给段数；"
                    + "要看某条轨的全部片段加 track（轨道 id），只看某段时间加 from / to（秒）。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "track": ["type": "string", "description": "只看这条轨道（轨道 id，前 8 位就行），列出它的全部片段"],
                        "from": ["type": "number", "description": "只列跟这段时间有交集的片段：起点（时间轴秒）"],
                        "to": ["type": "number", "description": "只列跟这段时间有交集的片段：终点（时间轴秒）"],
                    ] as [String: Any]
                ],
                risk: .readOnly),

            clipInfoSpec,

            AgentToolSpec(
                name: "list_assets",
                description: "列出素材库里的素材（含 id、名字、类型、时长），**最近加入的排在最前**。往时间轴加东西之前先看这里有什么。"
                    + "**找特定素材先用 name 搜**（文件名、文件夹名都搜，空格分开的几个词都要命中；搜不到会自动放宽）；"
                    + "结果多时分页，用 page 翻，每个素材都能翻到。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["all", "video", "audio", "image", "subtitle"],
                                 "description": "只看某一类，默认全部"],
                        "name": ["type": "string",
                                 "description": "搜索词：文件名或所在文件夹名里有它就算，不分大小写；空格分开写几个词 = 都要有。比如 gpt_image_C6C1CB68、猫 水彩"],
                        "page": ["type": "integer", "description": "第几页（从 1 开始），默认 1"]
                    ] as [String: Any]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "capture_frame",
                description: """
                **亲眼看一眼画面**。判断明暗、颜色、主体位置、有没有穿帮这类事，
                光看文件名和数据是看不出来的，必须靠它。
                不给参数就截时间轴当前播放头那一帧；
                给 source 就看那个东西：画布卡片 id、素材 id、或者文件绝对路径都认
                （图片直接看，视频抽一帧）。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "number", "description": "秒。不传就截播放头处；看视频文件时是抽第几秒"],
                        "source": ["type": "string",
                                   "description": "要看哪个：画布卡片 id / 素材 id（前 8 位）/ 文件绝对路径。"
                                                + "不传就看时间轴预览"]
                    ] as [String: Any]
                ],
                risk: .readOnly),
        ]
    }

    @MainActor
    static func runReadTool(_ name: String, args: [String: Any], project: ProjectState) async -> AgentToolResult? {
        switch name {
        case "get_project":   return .ok(projectOverview(project))
        case "list_tracks":
            let f = TrackDumpFilter(
                track: (args["track"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
                from: args["from"] as? Double, to: args["to"] as? Double,
                selected: project.selectedClipIDs, now: project.currentTime)
            return .ok(trackDump(project, f))
        case "get_clip":      return clipInfo(project, args: args)
        case "list_assets":   return .ok(assetDump(project, type: args["type"] as? String,
                                                   name: args["name"] as? String,
                                                   page: (args["page"] as? Int) ?? (args["page"] as? Double).map { Int($0) } ?? 1))
        case "capture_frame": return await captureFrame(project, time: args["time"] as? Double,
                                                        source: args["source"] as? String)
        default: return nil
        }
    }

    // MARK: - 各工具实现

    @MainActor
    private static func projectOverview(_ p: ProjectState) -> String {
        var s = "项目：\(p.projectName)\n"
        s += "画面比例 \(p.previewAspectRatio)，渲染尺寸 \(Int(p.previewRenderSize.width))×\(Int(p.previewRenderSize.height))\n"
        s += "内容总长 \(fmt(p.contentEndTime))，播放头在 \(fmt(p.currentTime))\n"
        s += "时间线标签页（\(p.tabs.count) 个）：\n"
        for (i, t) in p.tabs.enumerated() {
            let mark = i == p.activeTab ? "← 当前" : (t.isTabOpen ? "" : "（已关闭）")
            s += "  [\(i)] \(t.name) \(mark)\n"
        }
        return s
    }

    /// 默认每条轨最多列这么多段。字幕轨动辄几百句，全列出来工具结果会被截断，
    /// 排在后面的视频 / 音频轨整条看不到（模型拿不到视频片段 id，关键帧打不了 —— 实测栽过）
    static let trackListCap = 20

    /// list_tracks 的筛选：只看某条轨（全列）/ 只看某段时间
    struct TrackDumpFilter {
        var track: String?
        var from: Double?
        var to: Double?
        /// 选中的片段、播放头所在时刻：这些片段哪怕排在前 trackListCap 段之后也一定列出来，并标出来
        var selected: Set<UUID> = []
        var now: Double? = nil
    }

    @MainActor
    private static func trackDump(_ p: ProjectState, _ f: TrackDumpFilter = TrackDumpFilter()) -> String {
        var s = "当前时间线「\(p.tab.name)」的轨道，从上到下（分三块：叠加层 → 视频 → 音频，"
            + "每块里上面的盖住下面的；调顺序用 move_track）：\n"
        for ref in p.overlayTrackOrder {
            switch ref {
            case .image(let id):
                s += dumpTrack("图片", p.imageTracks.first { $0.id == id }, f) { "\($0.name)" }
            case .subtitle(let id):
                let t = p.subtitleTracks.first { $0.id == id }
                s += dumpTrack("字幕", t, f) { $0.text.replacingOccurrences(of: "\n", with: " ") }
                if let t, !t.clips.isEmpty {
                    let st = t.subtitleStyle ?? SubtitleStyle()
                    s += "（这条轨的样式：\(st.fontName) \(Int(st.fontSize)) 号\(st.bold ? " 粗体" : "")，"
                        + "颜色 \(st.textColor.toHex())，离底边 \(Int(st.bottomMargin))%；详细用 get_clip）\n"
                }
            case .text(let id):
                s += dumpTrack("文字", p.textTracks.first { $0.id == id }, f) { $0.text }
            case .shape(let id):
                s += dumpTrack("图形", p.shapeTracks.first { $0.id == id }, f) { $0.type.label }
            case .filter(let id):
                s += dumpTrack("滤镜", p.filterTracks.first { $0.id == id }, f) { $0.name }
            case .adjust(let id):
                s += dumpTrack("调节", p.adjustTracks.first { $0.id == id }, f) { $0.name }
            case .effect(let id):
                s += dumpTrack("特效", p.effectTracks.first { $0.id == id }, f) { $0.name }
            case .compound(let id):
                s += dumpTrack("复合", p.compoundTracks.first { $0.id == id }, f) { $0.name }
            }
        }
        // 视频、音频两块也按界面上的顺序列（跟时间轴看到的一致，调顺序时才对得上号）
        for ref in p.videoSectionOrder {
            switch ref {
            case .video(let id): s += dumpTrack("视频", p.videoTracks.first { $0.id == id }, f) { $0.name }
            case .compound(let id): s += dumpTrack("复合", p.compoundTracks.first { $0.id == id }, f) { $0.name }
            }
        }
        for ref in p.audioSectionOrder {
            switch ref {
            case .audio(let id): s += dumpTrack("音频", p.audioTracks.first { $0.id == id }, f) { $0.name }
            case .compound(let id): s += dumpTrack("复合", p.compoundTracks.first { $0.id == id }, f) { $0.name }
            }
        }
        if let t = f.track, !t.isEmpty, !s.contains("轨「") {
            return "当前时间线里找不到 id 以「\(t)」开头的轨道。不带 track 再调一次 list_tracks 看全部轨道。"
        }
        if s.hasSuffix("：\n") { s += "（还是空的）\n" }
        return s
    }

    private static func dumpTrack<C: Identifiable>(
        _ kind: String, _ track: Track<C>?, _ f: TrackDumpFilter, label: (C) -> String
    ) -> String where C: Equatable & Codable {
        guard let t = track else { return "" }
        let only = (f.track ?? "").isEmpty ? nil : f.track
        if let only, !"\(t.id)".lowercased().hasPrefix(only) { return "" }
        // 轨道 id 要给出来：move_track / move_clip 换轨都得点名是哪条轨道
        var s = "\n**\(kind)轨「\(t.label)」** id \(String("\(t.id)".prefix(8)))"
            + "\(t.isVisible ? "" : "（已隐藏）")　\(t.clips.count) 段\n"
        guard !t.clips.isEmpty else { return s }
        // 按时间窗筛（跟 from~to 有交集的）
        var clips = t.clips
        if f.from != nil || f.to != nil {
            let lo = f.from ?? -.infinity, hi = f.to ?? .infinity
            clips = clips.filter { c in
                guard let tc = c as? any AgentTimedClip else { return true }
                return tc.endTime > lo && tc.startTime < hi
            }
            if clips.isEmpty { return s + "（这段时间里没有片段）\n" }
        }
        // 点名看这条轨就全列；否则每条最多列前 trackListCap 段，
        // 再补上选中的、播放头下的（用户说「这段」多半指它们，不能因为排在后面就看不到）
        func isHead(_ c: C) -> Bool {
            guard let n = f.now, let tc = c as? any AgentTimedClip else { return false }
            return tc.startTime <= n && tc.endTime > n
        }
        let cap = only == nil ? trackListCap : Int.max
        let shown = clips.enumerated().filter { i, c in
            i < cap || f.selected.contains(c.id as? UUID ?? UUID()) || isHead(c)
        }.map(\.element)
        // 片段列成表格，模型转述时可以直接用
        s += "\n| id | 时间 | 内容 |\n|---|---|---|\n"
        for c in shown {
            let time = (c as? any AgentTimedClip).map { "\(fmt($0.startTime))–\(fmt($0.endTime))" } ?? "—"
            // 竖线会把表格切错列，先转义掉
            var text = label(c).replacingOccurrences(of: "|", with: "／")
            if let id = c.id as? UUID, f.selected.contains(id) { text += "（选中）" }
            if isHead(c) { text += "（播放头下）" }
            s += "| \(String("\(c.id)".prefix(8))) | \(time) | \(text) |\n"
        }
        if clips.count > shown.count {
            s += "（还有 \(clips.count - shown.count) 段没列出。看全部：list_tracks track=\(String("\(t.id)".prefix(8)))；"
                + "或加 from / to 只看某段时间）\n"
        }
        return s
    }

    @MainActor
    private static func assetDump(_ p: ProjectState, type: String?, name: String? = nil, page: Int = 1) -> String {
        let want = (type ?? "all").lowercased()
        let key = (name ?? "").trimmingCharacters(in: .whitespaces)
        let folders = MediaLibrary.shared.folders
        // **最近加入的排前面**。新素材是追加在库尾的，原来按库里顺序只给前 40 个，
        // 库一大，刚生成、刚导入的那几个永远排不进来 —— 后台助手「生成完放进时间轴」
        // 就是这么栽的：查不到新图的 id，反复导入、翻文件，步数用光也没放进去
        let pool = p.mediaAssets.reversed().filter { want == "all" || $0.type.rawValue.lowercased() == want }
        let kindName = want == "all" ? "" : want
        guard !pool.isEmpty else { return "素材库里没有\(kindName)素材。" }

        func line(_ a: MediaAsset) -> String {
            let dur = a.duration > 0 ? " \(fmt(a.duration))" : ""
            // 这里原来写反了：文件在的反而标「源文件丢失」
            let missing = a.fileExists ? "" : "（源文件丢失）"
            return "| \(String("\(a.id)".prefix(8))) | \(a.type.rawValue)\(dur) | \(a.name)\(missing) |"
        }
        func table(_ list: [MediaAsset], title: String, more: String) -> String {
            // 表格形式给回去，模型可以原样贴出来；列压在三列以内（聊天面板窄）。
            // 素材可以有好几百个，全量吐回去光这一条就上万字、而且历史每轮重发 —— 分页给
            let pg = AgentSearch.page(list, page: page)
            var s = "\(title)（\(list.count) 个\(pg.pages > 1 ? "，第 \(pg.page)/\(pg.pages) 页" : "")）：\n\n"
            s += "| id | 类型 | 名称 |\n|---|---|---|\n" + pg.items.map(line).joined(separator: "\n") + "\n"
            if pg.page < pg.pages { s += "\n下一页：同样的条件加 page=\(pg.page + 1)。\(more)\n" }
            return s
        }

        guard !key.isEmpty else {
            return table(Array(pool), title: "素材库\(kindName.isEmpty ? "" : "里的 \(kindName)")，最近加入的在前",
                         more: "要找特定的东西用 name 搜更快。")
        }
        // 搜：文件名 + 显示名 + 所在文件夹名。先精确（几个词都要有），没有再放宽
        func hay(_ a: MediaAsset) -> String {
            let folder = a.folderID.flatMap { id in folders.first { $0.id == id }?.name } ?? ""
            return a.name + " " + a.url.lastPathComponent + " " + folder
        }
        let r = AgentSearch.find(Array(pool), key, text: hay)
        guard !r.items.isEmpty else {
            // 还没有：给个目录，让它缩到某一类 / 某个文件夹里再翻
            var s = "素材库里没搜到「\(key)」（放宽成任意一个词、忽略空格下划线也没有）。\n素材库目录：\n"
            let byType = Dictionary(grouping: pool, by: { $0.type.rawValue })
            s += byType.keys.sorted().map { "- \($0)：\(byType[$0]!.count) 个" }.joined(separator: "\n") + "\n"
            let inFolder = Dictionary(grouping: pool.compactMap(\.folderID), by: { $0 })
            let named = folders.filter { inFolder[$0.id] != nil }
            if !named.isEmpty {
                s += "文件夹：\n" + named.map { "- 「\($0.name)」\(inFolder[$0.id]!.count) 个" }.joined(separator: "\n") + "\n"
            }
            s += "可以换个词搜、按 type 缩小，或者不带 name 用 page 一页页翻（最近加入的在前）。"
            return s
        }
        let title = r.relaxed
            ? "精确搜「\(key)」没找到，下面是放宽后的结果（命中任意一个词 / 忽略空格下划线，可能不准）"
            : "搜「\(key)」的结果"
        return table(r.items, title: title, more: "")
    }

    @MainActor
    private static func captureFrame(_ p: ProjectState, time: Double?,
                                     source: String? = nil) async -> AgentToolResult {
        // 指名了就看那个文件 —— 画布上的卡片、素材库里的素材，都是普通文件。
        // 只能截时间轴预览的话，在画布上聊天时它什么都看不见，
        // 只能回一句「我这边没有截帧工具」（实测）
        if let key = source?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            return await captureFile(p, key: key, time: time)
        }
        let t = time ?? p.currentTime
        guard p.playerItem != nil else {
            return .fail("现在没有可预览的内容，时间轴大概是空的。")
        }
        do {
            var cg = try renderTimelineFrame(p, at: t)
            // 给模型的图长边压到 1024，省 token
            let longSide = CGFloat(max(cg.width, cg.height))
            if longSide > 1024 {
                let k = 1024 / longSide
                let small = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: k, y: k))
                if let out = CIContext().createCGImage(small, from: small.extent) { cg = out }
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                return .fail("画面截出来了但编码失败。")
            }
            return AgentToolResult(text: "这是 \(fmt(t)) 处的画面。", imageData: data)
        } catch {
            return .fail("截不到 \(fmt(t)) 的画面：\(error.localizedDescription)")
        }
    }

    /// 时间轴某一刻的整帧，原始渲染尺寸，叠加层也画上，跟导出一致
    @MainActor
    static func renderTimelineFrame(_ p: ProjectState, at t: Double) throws -> CGImage {
        guard let item = p.playerItem else {
            throw NSError(domain: "Agent", code: 1, userInfo: [NSLocalizedDescriptionKey: "时间轴是空的"])
        }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = CMTime.zero
        gen.requestedTimeToleranceAfter = CMTime.zero
        // 按原始渲染尺寸抽，叠加层才能按跟导出同一套坐标画上去；最后再缩给模型
        let renderSize = item.videoComposition?.renderSize ?? p.previewRenderSize
        var actual = CMTime.zero
        let box = CGRect(origin: .zero, size: renderSize)
        let cg0: CGImage
        do {
            cg0 = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: &actual)
        } catch {
            // 这一刻底下**没有视频**（视频之后、片段之间的空档，只有图片/文字这些叠加层）：
            // 视频合成里这段一帧都没有，抽帧直接报「无法打开」。可预览里这时是黑底 + 叠加层，
            // 照样有画面 —— 按预览的样子自己画：黑底，叠加层和效果轨全画上
            DiagLog.log("[Agent] 时间轴 \(String(format: "%.2f", t))s 抽不到视频帧（\(error.localizedDescription)），按黑底 + 叠加层出图")
            // 透明底上画、最后垫黑：跟预览一样，黑底不被调节调灰
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: box)
            let composed = p.previewCompositor.drawOverlays(clear, at: t, renderSize: renderSize,
                                                             input: p.makeOverlayInput())
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)))
                .cropped(to: box)
            guard let out = CIContext().createCGImage(composed, from: box) else { throw error }
            return out
        }
        var cg = cg0
        // 字幕 / 文字 / 图形 / 图片这些叠加层**不在视频合成里**：没有效果轨时它们是
        // 预览界面上另画的，抽出来的帧里没有。这种情况自己按导出那套画上去，
        // 截到的才跟用户看到的、导出的成片一致。有效果轨时合成器已经画过了，不再画一遍
        if !p.overlayDrawnByCompositor {
            let base = CIImage(cgImage: cg)
            let composed = p.previewCompositor.drawOverlays(base, at: t, renderSize: renderSize,
                                                             input: p.makeOverlayInput())
                .cropped(to: CGRect(origin: .zero, size: renderSize))
            if let out = CIContext().createCGImage(composed, from: composed.extent) { cg = out }
        }
        return cg
    }

    /// 看一个具体文件：画布卡片 / 素材 / 路径都认
    @MainActor
    private static func captureFile(_ p: ProjectState, key: String, time: Double?) async -> AgentToolResult {
        var url: URL?
        var what = ""
        if let n = p.canvas.nodes.first(where: { "\($0.id)".hasPrefix(key) }), let u = n.mediaURL {
            url = u; what = "画布卡片"
        } else if let a = p.mediaAssets.first(where: { "\($0.id)".hasPrefix(key) }) {
            url = a.url; what = "素材"
        } else if key.hasPrefix("/") || key.hasPrefix("~") {
            url = URL(fileURLWithPath: (key as NSString).expandingTildeInPath)
            what = "文件"
        }
        guard let url else {
            return .fail("找不到「\(key)」。画布卡片 id 用 read_canvas 查，素材 id 用 list_assets 查，或者直接给文件绝对路径。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("「\(url.lastPathComponent)」这个文件不在了。")
        }
        let ext = url.pathExtension.lowercased()
        // 图片：直接读，压一下再给模型，省 token
        if AIVideoService.imageExts.contains(ext) {
            guard let img = NSImage(contentsOf: url),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return .fail("「\(url.lastPathComponent)」读不出画面。") }
            return AgentToolResult(text: "这是\(what)「\(url.lastPathComponent)」的画面。", imageData: data)
        }
        // 视频：抽一帧
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        let at = time ?? 0
        do {
            var actual = CMTime.zero
            let cg = try gen.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: &actual)
            guard let data = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return .fail("画面截出来了但编码失败。") }
            return AgentToolResult(text: "这是\(what)「\(url.lastPathComponent)」\(fmt(at)) 处的画面。",
                                   imageData: data)
        } catch {
            return .fail("截不到「\(url.lastPathComponent)」的画面：\(error.localizedDescription)")
        }
    }

    static func fmt(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// 有起止时间的片段。只为了让 dump 能统一取时间
protocol AgentTimedClip {
    var startTime: Double { get }
    var endTime: Double { get }
}

extension VideoClip: AgentTimedClip {}
extension AudioClip: AgentTimedClip {}
extension ImageClip: AgentTimedClip {}
extension SubtitleClip: AgentTimedClip {}
extension TextClip: AgentTimedClip {}
extension ShapeClip: AgentTimedClip {}
extension FilterClip: AgentTimedClip {}
extension AdjustClip: AgentTimedClip {}
extension EffectClip: AgentTimedClip {}
extension CompoundClip: AgentTimedClip {}

// MARK: - 编辑器当前状态（每轮带给模型）

/// 时间轴上的一个片段，摘要信息（给「选中了什么、播放头下有什么」用）
struct AgentClipRef {
    let kind: String
    let track: String
    let id: UUID
    let start: Double
    let end: Double
    let text: String
}

extension AgentToolbox {
    /// 当前时间线所有片段的摘要
    @MainActor
    static func allClipRefs(_ p: ProjectState) -> [AgentClipRef] {
        var out: [AgentClipRef] = []
        func add<C: Identifiable & Equatable & Codable>(_ kind: String, _ tracks: [Track<C>], _ label: (C) -> String) {
            for t in tracks {
                for c in t.clips {
                    guard let id = c.id as? UUID, let tc = c as? any AgentTimedClip else { continue }
                    out.append(AgentClipRef(kind: kind, track: t.label, id: id,
                                            start: tc.startTime, end: tc.endTime, text: label(c)))
                }
            }
        }
        add("视频", p.videoTracks) { $0.name }
        add("音频", p.audioTracks) { $0.name }
        add("图片", p.imageTracks) { $0.name }
        add("字幕", p.subtitleTracks) { $0.text.replacingOccurrences(of: "\n", with: " ") }
        add("文字", p.textTracks) { $0.text.replacingOccurrences(of: "\n", with: " ") }
        add("图形", p.shapeTracks) { $0.type.label }
        add("滤镜", p.filterTracks) { $0.name }
        add("调节", p.adjustTracks) { $0.name }
        add("特效", p.effectTracks) { $0.name }
        add("复合", p.compoundTracks) { $0.name }
        return out
    }

    /// 用户发这句话时编辑器的样子：选中了哪些片段、播放头在哪、播放头下各轨是什么（都带 id）。
    /// 每轮拼在用户这句话前面 —— 用户说「这段 / 这里 / 选中的」时模型直接就有 id，
    /// 不用先 list_tracks 翻一遍（项目一大，翻轨道又慢又可能被截断）
    @MainActor
    static func editorStateNote(_ p: ProjectState) -> String {
        let refs = allClipRefs(p)
        let now = p.currentTime
        func line(_ r: AgentClipRef) -> String {
            let t = r.text.count > 30 ? String(r.text.prefix(30)) + "…" : r.text
            return "- \(r.kind)轨「\(r.track)」 \(String(r.id.uuidString.prefix(8))) \(fmt(r.start))–\(fmt(r.end)) \(t)"
        }
        var s = "[编辑器状态·用户发这句话时。用户说「这段 / 这里 / 选中的」多半指下面这些，片段 id 可以直接用]\n"
        s += "时间线「\(p.tab.name)」，播放头 \(fmt(now))\n"
        let sel = refs.filter { p.selectedClipIDs.contains($0.id) }
        if sel.isEmpty {
            s += "选中：无\n"
        } else {
            s += "选中（\(sel.count) 个）：\n" + sel.prefix(10).map(line).joined(separator: "\n") + "\n"
            if sel.count > 10 { s += "（还有 \(sel.count - 10) 个选中的没列）\n" }
        }
        let under = refs.filter { $0.start <= now && $0.end > now }
        if under.isEmpty {
            s += "播放头下：没有片段\n"
        } else {
            s += "播放头下：\n" + under.prefix(15).map(line).joined(separator: "\n") + "\n"
        }
        return s + "[状态完]\n"
    }
}

/// 能改起止时间的片段：move_clip 换轨时要改它们的时间再放进目标轨
protocol AgentMovableClip: Identifiable, Equatable, Codable {
    var startTime: Double { get set }
    var endTime: Double { get set }
}
extension VideoClip: AgentMovableClip {}
extension AudioClip: AgentMovableClip {}
extension ImageClip: AgentMovableClip {}
extension SubtitleClip: AgentMovableClip {}
extension TextClip: AgentMovableClip {}
extension ShapeClip: AgentMovableClip {}
extension FilterClip: AgentMovableClip {}
extension AdjustClip: AgentMovableClip {}
extension EffectClip: AgentMovableClip {}

/// 工具的总入口
enum AgentToolbox {}

// MARK: - 搜索与分页（列表类工具共用：先精确搜，没有再放宽；结果分页，保证每一条都翻得到）

enum AgentSearch {
    static let pageSize = 40

    /// 小写、去掉空格下划线连字符点，放宽比对用（「gpt image」能对上 gpt_image_xxx）
    static func loose(_ s: String) -> String {
        s.lowercased().filter { !" _-.·".contains($0) }
    }

    /// 精确：空格分开的每个词都出现在文本里（不分大小写）。
    /// 没有一条命中时放宽：任意一个词命中，或去掉分隔符后整串包含。relaxed 标明是放宽的结果
    static func find<T>(_ list: [T], _ query: String, text: (T) -> String) -> (items: [T], relaxed: Bool) {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return (list, false) }
        let exact = list.filter { item in
            let t = text(item).lowercased()
            return words.allSatisfy { t.contains($0) }
        }
        if !exact.isEmpty { return (exact, false) }
        let lq = loose(query)
        let relaxed = list.filter { item in
            let t = text(item).lowercased(), lt = loose(t)
            return words.contains { t.contains($0) || lt.contains(loose($0)) } || (!lq.isEmpty && lt.contains(lq))
        }
        return (relaxed, true)
    }

    /// 第几页（从 1 开始，越界夹回最后一页）
    static func page<T>(_ list: [T], page: Int, size: Int = pageSize) -> (items: [T], page: Int, pages: Int) {
        let pages = max(1, (list.count + size - 1) / size)
        let pg = min(max(1, page), pages)
        let lo = (pg - 1) * size
        return (Array(list[lo..<min(lo + size, list.count)]), pg, pages)
    }
}
