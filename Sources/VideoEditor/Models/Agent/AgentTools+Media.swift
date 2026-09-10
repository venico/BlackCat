// AgentTools+Media.swift
//
// 成片相关的工具：导出、语音识别、改片段属性、裁剪、截帧认字。
//
// 这几样原来一个都没有，Agent 手上只有「加内容」的工具，加完改不了、
// 剪不了、也导不出去 —— 一条完整的活儿走不到头。实测它连「把下载好的视频
// 导进来」都做不到，最后跑去开剪映了。

import AVFoundation
import AppKit
import Foundation
import Vision

extension AgentToolbox {

    static var mediaTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "export_video",
                description: """
                把当前时间线导出成一个文件。**这是收尾动作** —— 用户说「导出」\
                「输出成片」「保存成 mp4」的时候用它。

                后台跑，提交完就返回；进度在右下角，不用在这儿等。
                导出用的画质、帧率、格式沿用「导出设置」里配好的那套。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "filename": ["type": "string",
                                     "description": "文件名，不用带后缀。不传就按项目名+时间"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "transcribe",
                description: """
                对视频/音频片段做语音识别，识别结果直接落成一条字幕轨。**离线跑，不花钱。**

                用户说「加字幕」「识别一下说了什么」「转文字」就用它。
                耗时大约是素材时长的几分之一，后台跑，进度在右下角。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string",
                                    "description": "要识别哪条片段（list_tracks 给的 id，前 8 位就够）。不传就识别第一条视频"],
                        "proofread": ["type": "boolean",
                                      "description": "识别完顺带让大模型校对一遍（修错别字、合并碎句）。默认 false"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "update_clip",
                description: """
                改一条已有片段的属性：位置、缩放、旋转、透明度、音量、速度。

                **加完之后想调整就用它**，别删了重加。只传要改的那几项，没传的不动。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "list_tracks 给的 id，前 8 位就够"],
                        "x": ["type": "number", "description": "水平位置，画面宽度的百分比，50 是居中"],
                        "y": ["type": "number", "description": "垂直位置，画面高度的百分比，50 是居中"],
                        "scale": ["type": "number", "description": "缩放，1 是原始大小"],
                        "rotation": ["type": "number", "description": "旋转角度"],
                        "opacity": ["type": "number", "description": "不透明度 0~1"],
                        "volume": ["type": "number", "description": "音量 0~2，视频和音频片段才有"],
                        "speed": ["type": "number", "description": "倍速 0.1~10，视频和音频片段才有"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "trim_clip",
                description: """
                改一条片段的起止时间（时间轴上占多长那一段）。

                跟 move_clip 的区别：move 是整条平移、长度不变；这个是拉伸/缩短两端。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string"],
                        "start": ["type": "number", "description": "新的起点（秒）"],
                        "end": ["type": "number", "description": "新的终点（秒）"]
                    ] as [String: Any],
                    "required": ["clip_id"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "scan_text",
                description: """
                **扫一段视频，把画面上出现过的文字整段认出来**（离线 OCR，中英文都行）。

                无声视频、字卡、演示录屏这类「话在画面上不在声音里」的，用它。
                有人声的用 `transcribe`（语音识别更准）。

                内部会自己按间隔取帧、跳过没变化的画面、把连续相同的文字合并成一个                时间段，**你只花一步**。别再用 read_frame_text 一帧一帧地扫 ——                 那样几百次调用，步数很快就没了。

                传 create_subtitles=true 就直接落成一条字幕轨，不用你再一条条 add_subtitle。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number", "description": "从第几秒开始，默认 0"],
                        "end": ["type": "number", "description": "到第几秒结束，默认到片尾"],
                        "interval": ["type": "number",
                                     "description": "每隔几秒取一帧。不传就按时长自己定（短片 1 秒、长片 3~5 秒）"],
                        "create_subtitles": ["type": "boolean",
                                             "description": "true = 认完直接生成一条字幕轨。用户说「生成字幕」就传 true"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "read_frame_text",
                description: """
                把某一时刻的画面截下来，**认出上面的文字**（离线 OCR，中英文都行）。

                **只看某一个时间点**用它。要扫一整段请用 `scan_text` —— 那个一步就能
                把整段的文字认完，用这个一帧帧扫几百次，步数很快就没了。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "time": ["type": "number", "description": "第几秒。不传就用播放头处"]
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .readOnly),
        ]
    }

    /// 这一轮 OCR 了几次。开跑前由 AgentRunner 清零
    @MainActor
    static var ocrCallsThisRound = 0

    @MainActor
    static func runMediaTool(_ name: String, args: [String: Any],
                             project p: ProjectState) async -> AgentToolResult? {
        switch name {
        case "export_video":
            return exportVideo(p, filename: args["filename"] as? String)

        case "transcribe":
            return transcribe(p, clipKey: args["clip_id"] as? String,
                              proofread: args["proofread"] as? Bool ?? false)

        case "update_clip":
            return updateClip(p, args: args)

        case "trim_clip":
            return trimClip(p, args: args)

        case "scan_text":
            return await scanText(p, args: args)

        case "read_frame_text":
            // 逐帧扫是正当用法（无声视频只能这么认字），给个宽松的上限防跑飞就行
            ocrCallsThisRound += 1
            if ocrCallsThisRound > 60 {
                return .fail("""
                    这一轮已经 OCR \(ocrCallsThisRound - 1) 次了，先停一下。
                    把已经认到的内容整理出来给用户，需要接着扫就让他说一声。
                    """)
            }
            return await readFrameText(p, time: args["time"] as? Double)

        default:
            return nil
        }
    }

    // MARK: - 导出

    @MainActor
    private static func exportVideo(_ p: ProjectState, filename: String?) -> AgentToolResult {
        guard p.contentEndTime > 0.01 else {
            return .fail("时间线上还什么都没有，没得导。")
        }
        let ext: String
        switch p.exportSettings.content {
        case .video:        ext = "mp4"
        case .audioOnly:    ext = "m4a"
        case .subtitleOnly: ext = "srt"
        }
        var base = (filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            base = "\(p.projectName)_\(f.string(from: Date()))"
        }
        // 用户可能自己带了后缀，别拼成 xxx.mp4.mp4
        if base.lowercased().hasSuffix("." + ext) { base = String(base.dropLast(ext.count + 1)) }
        let outputURL = AppSettings.shared.effectiveExportDir
            .appendingPathComponent("\(base).\(ext)")

        ExportManager.shared.startExport(snapshot: p.makeExportInput(outputURL: outputURL),
                                         owner: nil)
        return .ok("""
            已经开始导出「\(outputURL.lastPathComponent)」，放在\(outputURL.deletingLastPathComponent().path)。
            后台跑的，进度在右下角，不用在这儿等它。
            """)
    }

    // MARK: - 语音识别

    @MainActor
    private static func transcribe(_ p: ProjectState, clipKey: String?,
                                   proofread: Bool) -> AgentToolResult {
        guard !p.isTranscribing else { return .fail("已经有一个识别在跑了，等它完事。") }
        guard WhisperTranscriber.whisperReady else {
            return .fail("语音识别引擎没就绪（whisper-cli 缺失），去设置里看看。")
        }
        guard WhisperTranscriber.modelReady else {
            return .fail("语音识别模型还没下载。让用户到设置 → 语音识别里下一个，再来找我。")
        }
        // 点名了就先把它选中 —— 识别走的是「当前选中片段」那套
        if let key = clipKey, !key.isEmpty {
            var hit = false
            for t in p.videoTracks {
                if let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) {
                    p.selectedVideoClipID = c.id; p.selectedAudioClipID = nil; hit = true; break
                }
            }
            if !hit {
                for t in p.audioTracks {
                    if let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) {
                        p.selectedAudioClipID = c.id; p.selectedVideoClipID = nil; hit = true; break
                    }
                }
            }
            guard hit else { return .fail("找不到 id 以 \(key) 开头的视频或音频片段，先 list_tracks 看看。") }
        }
        p.autoTranscribeSelectedClip(useAI: proofread)
        return .ok("""
            开始识别了\(proofread ? "（识别完还会让大模型校对一遍）" : "")。
            后台跑，进度在右下角；完事会自己生成一条字幕轨。
            用户问进度就让他看右下角，别在这儿空等。
            """)
    }

    // MARK: - 改片段

    @MainActor
    private static func updateClip(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        guard let key = (args["clip_id"] as? String), !key.isEmpty else { return .fail("缺 clip_id") }
        func num(_ k: String) -> Double? { args[k] as? Double ?? (args[k] as? Int).map(Double.init) }
        let x = num("x"), y = num("y"), scale = num("scale"), rot = num("rotation")
        let opacity = num("opacity"), volume = num("volume"), speed = num("speed")
        guard x != nil || y != nil || scale != nil || rot != nil
                || opacity != nil || volume != nil || speed != nil else {
            return .fail("一个要改的属性都没传。")
        }
        var changed: [String] = []
        func note(_ s: String) { changed.append(s) }

        // 视频
        for t in p.videoTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateVideoClip(id: c.id) { v in
                if let x { v.offsetX = x / 100 - 0.5; note("水平位置 \(Int(x))%") }
                if let y { v.offsetY = y / 100 - 0.5; note("垂直位置 \(Int(y))%") }
                if let s = scale { v.scaleX = s; v.scaleY = s; note("缩放 \(s)") }
                // 视频这条的 rotation 是整数度、volume 是 Float
                if let r = rot { v.rotation = Int(r.rounded()); note("旋转 \(Int(r))°") }
                if let vol = volume { v.volume = Float(max(0, min(2, vol))); note("音量 \(vol)") }
                if let sp = speed { v.speed = max(0.1, min(10, sp)); note("速度 \(sp)x") }
            }
            p.rebuildTimelinePreview()
            return .ok("已经改了视频片段「\(c.name)」：\(changed.joined(separator: "、"))")
        }
        // 图片
        for t in p.imageTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateImageClip(id: c.id) { v in
                if let x { v.offsetX = x / 100 - 0.5; note("水平位置 \(Int(x))%") }
                if let y { v.offsetY = y / 100 - 0.5; note("垂直位置 \(Int(y))%") }
                if let s = scale { v.scaleX = s; v.scaleY = s; note("缩放 \(s)") }
                if let r = rot { v.rotation = r; note("旋转 \(Int(r))°") }
                if let o = opacity { v.opacity = max(0, min(1, o)); note("不透明度 \(o)") }
            }
            p.rebuildTimelinePreview()
            return .ok("已经改了图片片段「\(c.name)」：\(changed.joined(separator: "、"))")
        }
        // 文字
        for t in p.textTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateTextClip(id: c.id) { v in
                if let x { v.posX = x / 100; note("水平位置 \(Int(x))%") }
                if let y { v.posY = y / 100; note("垂直位置 \(Int(y))%") }
                if let r = rot { v.rotation = r; note("旋转 \(Int(r))°") }
                if let o = opacity { v.opacity = max(0, min(1, o)); note("不透明度 \(o)") }
            }
            p.rebuildTimelinePreview()
            return .ok("已经改了文字「\(c.text.prefix(10))」：\(changed.joined(separator: "、"))")
        }
        // 音频
        for ti in p.audioTracks.indices {
            guard let ci = p.audioTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let name = p.audioTracks[ti].clips[ci].name
            if let vol = volume {
                p.audioTracks[ti].clips[ci].volume = Float(max(0, min(2, vol))); note("音量 \(vol)")
            }
            if let sp = speed { p.audioTracks[ti].clips[ci].speed = max(0.1, min(10, sp)); note("速度 \(sp)x") }
            p.rebuildTimelinePreview()
            return .ok("已经改了音频片段「\(name)」：\(changed.joined(separator: "、"))")
        }
        return .fail("找不到 id 以 \(key) 开头的片段，先 list_tracks 看看。")
    }

    // MARK: - 裁剪

    @MainActor
    private static func trimClip(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        guard let key = (args["clip_id"] as? String), !key.isEmpty else { return .fail("缺 clip_id") }
        func num(_ k: String) -> Double? { args[k] as? Double ?? (args[k] as? Int).map(Double.init) }
        guard num("start") != nil || num("end") != nil else { return .fail("start 和 end 至少给一个。") }

        func apply(_ old: (s: Double, e: Double)) -> (Double, Double)? {
            let s = max(0, num("start") ?? old.s)
            let e = num("end") ?? old.e
            guard e - s > 0.05 else { return nil }
            return (s, e)
        }

        for ti in p.videoTracks.indices {
            guard let ci = p.videoTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.videoTracks[ti].clips[ci]
            guard let (s, e) = apply((c.startTime, c.endTime)) else { return .fail("裁完长度会变成 0。") }
            p.videoTracks[ti].clips[ci].startTime = s
            p.videoTracks[ti].clips[ci].endTime = e
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」现在是 \(fmt(s)) → \(fmt(e))。")
        }
        for ti in p.imageTracks.indices {
            guard let ci = p.imageTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.imageTracks[ti].clips[ci]
            guard let (s, e) = apply((c.startTime, c.endTime)) else { return .fail("裁完长度会变成 0。") }
            p.imageTracks[ti].clips[ci].startTime = s
            p.imageTracks[ti].clips[ci].endTime = e
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」现在是 \(fmt(s)) → \(fmt(e))。")
        }
        for ti in p.audioTracks.indices {
            guard let ci = p.audioTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.audioTracks[ti].clips[ci]
            guard let (s, e) = apply((c.startTime, c.endTime)) else { return .fail("裁完长度会变成 0。") }
            p.audioTracks[ti].clips[ci].startTime = s
            p.audioTracks[ti].clips[ci].endTime = e
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」现在是 \(fmt(s)) → \(fmt(e))。")
        }
        for ti in p.subtitleTracks.indices {
            guard let ci = p.subtitleTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.subtitleTracks[ti].clips[ci]
            guard let (s, e) = apply((c.startTime, c.endTime)) else { return .fail("裁完长度会变成 0。") }
            p.subtitleTracks[ti].clips[ci].startTime = s
            p.subtitleTracks[ti].clips[ci].endTime = e
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("字幕「\(c.text.prefix(10))」现在是 \(fmt(s)) → \(fmt(e))。")
        }
        for ti in p.textTracks.indices {
            guard let ci = p.textTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.textTracks[ti].clips[ci]
            guard let (s, e) = apply((c.startTime, c.endTime)) else { return .fail("裁完长度会变成 0。") }
            p.textTracks[ti].clips[ci].startTime = s
            p.textTracks[ti].clips[ci].endTime = e
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("文字「\(c.text.prefix(10))」现在是 \(fmt(s)) → \(fmt(e))。")
        }
        return .fail("找不到 id 以 \(key) 开头的片段，先 list_tracks 看看。")
    }

    // MARK: - 截帧认字

    /// 离线 OCR。**不需要装任何东西** —— 系统自带 Vision，中英文都认
    @MainActor
    private static func readFrameText(_ p: ProjectState, time: Double?) async -> AgentToolResult {
        let t = time ?? p.currentTime
        guard let item = p.playerItem else {
            return .fail("现在没有可预览的内容，时间轴大概是空的。")
        }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        // OCR 要看清小字，别缩太狠
        gen.maximumSize = CGSize(width: 2048, height: 2048)

        let cg: CGImage
        do {
            var actual = CMTime.zero
            cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600),
                                     actualTime: &actual)
        } catch {
            return .fail("截不到 \(fmt(t)) 的画面：\(error.localizedDescription)")
        }

        let lines: [String] = await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { request, _ in
                let obs = (request.results as? [VNRecognizedTextObservation]) ?? []
                // 按从上到下排，读出来才是人看的顺序（Vision 的 y 轴朝上）
                let sorted = obs.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                cont.resume(returning: sorted.compactMap { $0.topCandidates(1).first?.string })
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            } catch {
                cont.resume(returning: [])
            }
        }

        guard !lines.isEmpty else {
            return .ok("\(fmt(t)) 处的画面里没认出文字。")
        }
        return .ok("\(fmt(t)) 处画面上的文字（从上到下）：\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - 整段扫描画面文字

extension AgentToolbox {

    /// 单次最多取多少帧。实测抽帧+OCR 约 214ms/帧（串行），
    /// 1200 帧并发跑下来一两分钟；再多就该让用户缩范围或放大间隔了
    static let scanFrameCap = 1200

    /// 扫一段视频的画面文字。
    ///
    /// **循环放在这儿，不放在模型那边** —— 一小时的片子按 2 秒一帧是 1800 帧，
    /// 让模型一帧调一次工具就是 1800 次来回，步数和 token 都不可能撑住。
    /// 这里一次调用内部跑完，只把去重合并后的几十条结果回给它。
    @MainActor
    static func scanText(_ p: ProjectState, args: [String: Any]) async -> AgentToolResult {
        guard let item = p.playerItem else {
            return .fail("时间轴上没有可预览的内容。")
        }
        func num(_ k: String) -> Double? { args[k] as? Double ?? (args[k] as? Int).map(Double.init) }

        let total = p.contentEndTime
        let start = max(0, num("start") ?? 0)
        let end = min(total, num("end") ?? total)
        guard end - start > 0.1 else { return .fail("这个时间范围是空的（\(fmt(start))→\(fmt(end))）。") }

        // 间隔不传就按时长定：短片密一点，长片稀一点
        let span = end - start
        let interval: Double = num("interval") ?? {
            switch span {
            case ..<60:   return 1
            case ..<600:  return 2
            case ..<1800: return 3
            default:      return 5
            }
        }()
        var times: [Double] = []
        var t = start
        while t < end { times.append(t); t += max(0.2, interval) }
        guard !times.isEmpty else { return .fail("按这个间隔一帧都取不到。") }
        guard times.count <= scanFrameCap else {
            let need = (span / Double(scanFrameCap)).rounded(.up)
            return .fail("""
                这个范围按 \(interval) 秒一帧要取 \(times.count) 帧，超过单次上限 \(scanFrameCap) 帧了。
                把 interval 放大到 \(Int(need)) 秒以上，或者分几段扫（比如先 \(fmt(start))→\(fmt(start + span/2))）。
                """)
        }

        let asset = item.asset
        let videoComp = item.videoComposition
        let began = Date()
        let hits = await Self.ocrSweep(asset: asset, videoComposition: videoComp, times: times)
        let cost = Date().timeIntervalSince(began)

        // 连续相同的文字合并成一段 —— 出来的形状正好就是字幕
        var segs: [(start: Double, end: Double, text: String)] = []
        for (time, text) in hits where !text.isEmpty {
            if var last = segs.last, last.text == text, time - last.end <= interval * 1.5 {
                last.end = time + interval
                segs[segs.count - 1] = last
            } else {
                segs.append((time, time + interval, text))
            }
        }
        // 末尾别超出扫描范围
        for i in segs.indices { segs[i].end = min(segs[i].end, end) }

        guard !segs.isEmpty else {
            return .ok("\(fmt(start))→\(fmt(end)) 扫了 \(times.count) 帧（用时 \(Int(cost)) 秒），没认出文字。")
        }

        var head = "\(fmt(start))→\(fmt(end)) 扫了 \(times.count) 帧，用时 \(Int(cost)) 秒，"
            + "认出 \(segs.count) 段文字"

        if args["create_subtitles"] as? Bool == true {
            var track = Track<SubtitleClip>(label: "画面文字")
            track.subtitleStyle = p.newSubtitleStyle(for: segs.map(\.text))
            for s in segs {
                track.clips.append(SubtitleClip(text: s.text,
                                                startTime: s.start,
                                                endTime: max(s.start + 0.3, s.end)))
            }
            track.clips.sort { $0.startTime < $1.startTime }
            p.subtitleTracks.append(track)
            p.syncOverlayOrder()
            p.rebuildTimelinePreview()
            p.scheduleAutoSave()
            head += "，**已经生成一条字幕轨「画面文字」**"
        }

        // 回给模型的正文控制住长度：太多就只给前面一批，免得把上下文撑爆
        let shown = segs.prefix(80)
        var body = shown.map { "\(fmt($0.start))–\(fmt($0.end))  \($0.text)" }.joined(separator: "\n")
        if segs.count > shown.count {
            body += "\n…（还有 \(segs.count - shown.count) 段没列出来）"
        }
        return .ok(head + "：\n" + body)
    }

    /// 并发抽帧 + OCR。
    ///
    /// 串行是 214ms/帧（抽帧和 OCR 各占一半），并发能压到几分之一。
    /// 画面没变的帧直接跳过不认字 —— 字卡类视频大半都是静止帧，这一条省掉一大截
    private nonisolated static func ocrSweep(asset: AVAsset,
                                             videoComposition: AVVideoComposition?,
                                             times: [Double]) async -> [(Double, String)] {
        let lanes = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let chunks = stride(from: 0, to: times.count, by: max(1, times.count / lanes))
            .map { Array(times[$0..<min($0 + max(1, times.count / lanes), times.count)]) }

        return await withTaskGroup(of: [(Double, String)].self) { group in
            for chunk in chunks {
                group.addTask {
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.videoComposition = videoComposition
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = .zero
                    // OCR 要看清小字，别缩太狠
                    gen.maximumSize = CGSize(width: 1600, height: 1600)

                    var out: [(Double, String)] = []
                    var lastSignature: [UInt8] = []
                    var lastText = ""
                    for t in chunk {
                        guard let cg = try? gen.copyCGImage(
                            at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                        else { continue }
                        // 先比一张极小的缩略图，几乎没变就沿用上一帧的结果，省掉一次 OCR
                        let sig = Self.tinySignature(cg)
                        if !lastSignature.isEmpty, Self.similar(sig, lastSignature) {
                            if !lastText.isEmpty { out.append((t, lastText)) }
                            continue
                        }
                        lastSignature = sig
                        let text = Self.recognize(cg)
                        lastText = text
                        if !text.isEmpty { out.append((t, text)) }
                    }
                    return out
                }
            }
            var all: [(Double, String)] = []
            for await r in group { all += r }
            return all.sorted { $0.0 < $1.0 }
        }
    }

    /// 8×8 灰度指纹，用来判断两帧是不是几乎一样
    private nonisolated static func tinySignature(_ cg: CGImage) -> [UInt8] {
        let w = 8, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private nonisolated static func similar(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff = 0
        for i in a.indices { diff += abs(Int(a[i]) - Int(b[i])) }
        // 平均每格差 6 以内算没变（0~255）
        return diff / a.count < 6
    }

    private nonisolated static func recognize(_ cg: CGImage) -> String {
        var lines: [String] = []
        let req = VNRecognizeTextRequest { request, _ in
            let obs = (request.results as? [VNRecognizedTextObservation]) ?? []
            let sorted = obs.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return lines.joined(separator: " ")
    }
}
