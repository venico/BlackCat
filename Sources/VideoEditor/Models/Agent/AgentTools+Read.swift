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
                description: "列出当前时间线的所有轨道和里面的片段（含 id、名字、起止时间）。要改某条片段必须先从这里拿到它的 id。",
                parameters: ["type": "object", "properties": [:] as [String: Any]],
                risk: .readOnly),

            AgentToolSpec(
                name: "list_assets",
                description: "列出素材库里的素材（含 id、名字、类型、时长）。往时间轴加东西之前先看这里有什么。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["all", "video", "audio", "image", "subtitle"],
                                 "description": "只看某一类，默认全部"]
                    ] as [String: Any]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "capture_frame",
                description: "截取某个时刻的预览画面看一眼。判断画面明暗、主体位置、有没有穿帮这类事情必须靠它，光看数据看不出来。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "number", "description": "秒。不传就截当前播放头那一帧"]
                    ] as [String: Any]
                ],
                risk: .readOnly),
        ]
    }

    @MainActor
    static func runReadTool(_ name: String, args: [String: Any], project: ProjectState) async -> AgentToolResult? {
        switch name {
        case "get_project":   return .ok(projectOverview(project))
        case "list_tracks":   return .ok(trackDump(project))
        case "list_assets":   return .ok(assetDump(project, type: args["type"] as? String))
        case "capture_frame": return await captureFrame(project, time: args["time"] as? Double)
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

    @MainActor
    private static func trackDump(_ p: ProjectState) -> String {
        var s = "当前时间线「\(p.tab.name)」的轨道，从上到下：\n"
        for ref in p.overlayTrackOrder {
            switch ref {
            case .image(let id):
                s += dumpTrack("图片", p.imageTracks.first { $0.id == id }) { "\($0.name)" }
            case .subtitle(let id):
                s += dumpTrack("字幕", p.subtitleTracks.first { $0.id == id }) { $0.text.replacingOccurrences(of: "\n", with: " ") }
            case .text(let id):
                s += dumpTrack("文字", p.textTracks.first { $0.id == id }) { $0.text }
            case .shape(let id):
                s += dumpTrack("图形", p.shapeTracks.first { $0.id == id }) { $0.type.label }
            case .filter(let id):
                s += dumpTrack("滤镜", p.filterTracks.first { $0.id == id }) { $0.name }
            case .adjust(let id):
                s += dumpTrack("调节", p.adjustTracks.first { $0.id == id }) { $0.name }
            case .effect(let id):
                s += dumpTrack("特效", p.effectTracks.first { $0.id == id }) { $0.name }
            case .compound(let id):
                s += dumpTrack("复合", p.compoundTracks.first { $0.id == id }) { $0.name }
            }
        }
        for t in p.videoTracks { s += dumpTrack("视频", t) { $0.name } }
        for t in p.audioTracks { s += dumpTrack("音频", t) { $0.name } }
        if s.hasSuffix("：\n") { s += "（还是空的）\n" }
        return s
    }

    private static func dumpTrack<C: Identifiable>(
        _ kind: String, _ track: Track<C>?, label: (C) -> String
    ) -> String where C: Equatable & Codable {
        guard let t = track else { return "" }
        var s = "\n**\(kind)轨「\(t.label)」**\(t.isVisible ? "" : "（已隐藏）")　\(t.clips.count) 段\n"
        guard !t.clips.isEmpty else { return s }
        // 片段列成表格，模型转述时可以直接用
        s += "\n| id | 时间 | 内容 |\n|---|---|---|\n"
        for c in t.clips {
            let time = (c as? any AgentTimedClip).map { "\(fmt($0.startTime))–\(fmt($0.endTime))" } ?? "—"
            // 竖线会把表格切错列，先转义掉
            let text = label(c).replacingOccurrences(of: "|", with: "／")
            s += "| \(String("\(c.id)".prefix(8))) | \(time) | \(text) |\n"
        }
        return s
    }

    @MainActor
    private static func assetDump(_ p: ProjectState, type: String?) -> String {
        let want = (type ?? "all").lowercased()
        let list = p.mediaAssets.filter { a in
            want == "all" || a.type.rawValue.lowercased() == want
        }
        guard !list.isEmpty else { return "素材库里没有\(want == "all" ? "" : want)素材。" }
        // 表格形式给回去，模型可以原样贴出来 —— 省得它自己组织，界面上也整齐。
        // 列压在三列以内：聊天面板窄，再多就排不下了
        // 素材可以有好几百个，全量吐回去光这一条就上万字，而且历史每轮重发。
        // 超过这个数就只给前面一批，剩下的让它按 type 缩小范围再问
        let cap = 40
        var s = "素材库（\(list.count) 个\(list.count > cap ? "，下面只列前 \(cap) 个" : "")）：\n\n"
        s += "| id | 类型 | 名称 |\n|---|---|---|\n"
        for a in list.prefix(cap) {
            let dur = a.duration > 0 ? " \(fmt(a.duration))" : ""
            // 这里原来写反了：文件在的反而标「源文件丢失」
            let missing = a.fileExists ? "" : "（源文件丢失）"
            s += "| \(String("\(a.id)".prefix(8))) | \(a.type.rawValue)\(dur) | \(a.name)\(missing) |\n"
        }
        if list.count > cap {
            s += "\n还有 \(list.count - cap) 个没列出来。要找特定的东西就加 type 参数"
                + "（video / audio / image）缩小范围。\n"
        }
        return s
    }

    @MainActor
    private static func captureFrame(_ p: ProjectState, time: Double?) async -> AgentToolResult {
        let t = time ?? p.currentTime
        guard let item = p.playerItem else {
            return .fail("现在没有可预览的内容，时间轴大概是空的。")
        }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = CMTime.zero
        gen.requestedTimeToleranceAfter = CMTime.zero
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        do {
            var actual = CMTime.zero
            let cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: &actual)
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                return .fail("画面截出来了但编码失败。")
            }
            return AgentToolResult(text: "这是 \(fmt(t)) 处的画面。", imageData: data)
        } catch {
            return .fail("截不到 \(fmt(t)) 的画面：\(error.localizedDescription)")
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

/// 工具的总入口
enum AgentToolbox {}
