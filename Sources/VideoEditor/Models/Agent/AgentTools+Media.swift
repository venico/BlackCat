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
import SwiftUI
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
                默认按项目设置里的分辨率、比例、帧率、码率导出；这里传了就只对这一次生效。
                content：video 成片（默认）、audio 只导声音（m4a）、subtitle 只导字幕（srt）。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "filename": ["type": "string",
                                     "description": "文件名，不用带后缀。不传就按项目名+时间"],
                        "content": ["type": "string", "enum": ["video", "audio", "subtitle"]],
                        "resolution": ["type": "string", "enum": ExportSettings.resolutions],
                        "fps": ["type": "integer", "enum": ExportSettings.fpsOptions],
                        "bitrate": ["type": "integer", "description": "码率 kbps。参考：2000 低、5000 标准、12000 高、30000 极高"],
                        "then": Self.followUpParam
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .dangerous),

            AgentToolSpec(
                name: "transcribe",
                description: """
                对视频/音频片段做语音识别，识别结果直接落成一条字幕轨。识别本身离线跑，不花钱。
                **识别模型、翻译方式、AI 模型都按用户在「语音识别字幕」弹窗里选的来**，别自己另定。

                用户说「加字幕」「识别一下说了什么」「转文字」就用它（只识别）。
                说「识别并翻译成 X」就 translate=true，**一步做完**（跟用户手动点「开始识别」一样：
                AI 翻译时整批带上下文翻、顺带合并碎句，出一条翻好的字幕轨），别拆成识别 + translate_subtitles 两步。
                用户选的识别模型没下载时会退回说明，那时用 ask_user 问他「先下载」还是「这次用已下载的」，再带 model_choice 重调。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string",
                                    "description": "要识别哪条片段（list_tracks 给的 id，前 8 位就够）。不传就识别第一条视频"],
                        "proofread": ["type": "boolean",
                                      "description": "识别完顺带让大模型校对一遍（修错别字、合并碎句）。默认 false"],
                        "translate": ["type": "boolean",
                                      "description": "识别完翻译。用户说「识别并翻译」时传 true。翻译方式按弹窗里的设置"],
                        "language": ["type": "string",
                                     "description": "翻译成哪种语言，比如「中文（简体）」「英语」。不传用项目的翻译目标语言"],
                        "model_choice": ["type": "string", "enum": ["download", "use_downloaded"],
                                         "description": "选中的识别模型没下载时，问过用户后再传：download = 先下载它；use_downloaded = 这次用已下载的"],
                        "then": Self.followUpParam
                    ] as [String: Any],
                    "required": [] as [String]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "update_clip",
                description: """
                改一条已有片段的属性，属性区里能调的这里基本都能调。**只传要改的那几项**，没传的不动。
                加完之后想调整就用它，别删了重加。各参数对哪类片段有效：

                · 位置 / 缩放 / 旋转 / 不透明度：视频、图片、文字
                · 音量、速度：视频、音频；左右声道、淡入淡出：音频
                · 调色（brightness 等十一项）：视频片段、调节片段
                · 转场时长 transition_duration：视频片段（它开头那个转场）
                · 文字内容 text：字幕、文字
                · 文字样式（字号、字体、粗斜体、颜色、背景、对齐）：文字片段；
                  **字幕的样式是整条字幕轨共用的**，改任意一条字幕等于改它那一整轨。
                  中英双语是两条轨时，各拿一条的 id 分别改（比如中文 46、英文 23）
                · 描边：文字、图片（图片还有 stroke_softness、corner_radius、调色）；行距、离底边距离、
                  subtitle_width、merge_line_breaks：字幕
                · 裁切 crop_*、镜像 mirror_*：视频、图片、文字、图形；倒放 reversed、选音轨 audio_track：视频
                · transition：换掉或删掉视频片段开头的转场（none = 删掉）
                · 文字还有：animation 入场动画、box_width / box_height 文本框、stroke_softness
                · 图形：x / y / scale / rotation / opacity / width / height，填充 fill_*、描边 stroke_*、
                  虚线、端点 cap_*、圆角（矩形）、投影 shadow_*、钢笔路径 pen_points / pen_closed
                · 强度 intensity：滤镜、特效；amount / angle / center：特效
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "list_tracks 给的 id，前 8 位就够"],
                        "clip_ids": ["type": "array", "items": ["type": "string"],
                                     "description": "多条一起改成同样的值（跟属性区多选「一起调整」一样），给了就不用 clip_id"],
                        "x": ["type": "number", "description": "水平位置，画面宽度的百分比，50 是居中"],
                        "y": ["type": "number", "description": "垂直位置，画面高度的百分比，50 是居中"],
                        "scale": ["type": "number", "description": "缩放，1 是原始大小"],
                        "rotation": ["type": "number", "description": "旋转角度"],
                        "opacity": ["type": "number", "description": "不透明度 0~1"],
                        "volume": ["type": "number", "description": "音量 0~4，1 是原始"],
                        "speed": ["type": "number", "description": "倍速 0.1~10"],
                        "left_channel": ["type": "number", "description": "左声道 0~1（音频）"],
                        "right_channel": ["type": "number", "description": "右声道 0~1（音频）"],
                        "fade_in": ["type": "number", "description": "淡入秒数，0 = 关掉淡入（音频）"],
                        "fade_out": ["type": "number", "description": "淡出秒数，0 = 关掉淡出（音频）"],
                        "brightness": ["type": "number", "description": "亮度 -1~1，0 不变"],
                        "contrast": ["type": "number", "description": "对比度 -1~1"],
                        "saturation": ["type": "number", "description": "饱和度 -1~1"],
                        "vibrance": ["type": "number", "description": "自然饱和度 -1~1"],
                        "exposure": ["type": "number", "description": "曝光 -2~2"],
                        "gamma": ["type": "number", "description": "伽马 0.25~4，**1 是不变**"],
                        "highlight": ["type": "number", "description": "高光 -1~1"],
                        "shadow": ["type": "number", "description": "阴影 -1~1"],
                        "temperature": ["type": "number", "description": "色温 -1~1，负冷正暖"],
                        "tint": ["type": "number", "description": "色调 -1~1，负绿正品红"],
                        "hue": ["type": "number", "description": "色相 -180~180 度"],
                        "transition_duration": ["type": "number", "description": "转场时长（秒），视频片段开头有转场时才有用"],
                        "text": ["type": "string", "description": "文字内容（字幕、文字）"],
                        "font_size": ["type": "number", "description": "字号（px）"],
                        "font_name": ["type": "string", "description": "字体名，比如 PingFang SC、Source Han Sans SC"],
                        "bold": ["type": "boolean"],
                        "italic": ["type": "boolean"],
                        "color": ["type": "string", "description": "文字颜色，#RRGGBB"],
                        "background_color": ["type": "string", "description": "背景颜色，#RRGGBB"],
                        "background_opacity": ["type": "number", "description": "背景不透明度 0~1，0 = 没有背景"],
                        "alignment": ["type": "string", "enum": ["left", "center", "right"]],
                        "stroke_color": ["type": "string", "description": "描边颜色 #RRGGBB（文字）"],
                        "stroke_width": ["type": "number", "description": "描边宽度 px，0 = 无描边（文字）"],
                        "line_spacing": ["type": "number", "description": "双语两行之间的间距 px（字幕）"],
                        "bottom_margin": ["type": "number", "description": "字幕离画面底边的距离，画面高度的百分比"],
                        "crop_top": ["type": "number", "description": "从上边裁掉多少，百分比 0~90"],
                        "crop_bottom": ["type": "number", "description": "从下边裁掉多少，百分比 0~90"],
                        "crop_left": ["type": "number", "description": "从左边裁掉多少，百分比 0~90"],
                        "crop_right": ["type": "number", "description": "从右边裁掉多少，百分比 0~90"],
                        "mirror_h": ["type": "boolean", "description": "水平镜像"],
                        "mirror_v": ["type": "boolean", "description": "垂直镜像"],
                        "reversed": ["type": "boolean", "description": "倒放（视频）"],
                        "audio_track": ["type": "integer", "description": "多音轨素材用第几条音轨，从 0 数（视频）"],
                        "transition": ["type": "string",
                                       "description": "换开头转场的种类，none = 删掉转场（视频）。种类：none、" + TransitionType.allCases.map(\.rawValue).joined(separator: "、")],
                        "corner_radius": ["type": "number", "description": "圆角 px（图片、矩形图形）"],
                        "stroke_softness": ["type": "number", "description": "描边柔和度 0~1（文字、图片）"],
                        "animation": ["type": "string", "enum": TextAnimation.allCases.map(\.rawValue),
                                      "description": "文字入场动画：" + TextAnimation.allCases.map { "\($0.rawValue)=\($0.label)" }.joined(separator: "，")],
                        "animation_duration": ["type": "number", "description": "文字入场动画时长，秒，0.1~3"],
                        "box_width": ["type": "number", "description": "文本框宽 px，0 = 跟着文字自适应（文字）"],
                        "box_height": ["type": "number", "description": "文本框高 px，0 = 自适应（文字）"],
                        "subtitle_width": ["type": "number", "description": "字幕最大宽度，画面宽度百分比 20~100（字幕，整轨）"],
                        "merge_line_breaks": ["type": "boolean", "description": "把字幕里的换行合成一行（字幕，整轨）"],
                        "width": ["type": "number", "description": "图形宽 px"],
                        "height": ["type": "number", "description": "图形高 px"],
                        "fill_enabled": ["type": "boolean", "description": "图形填充开关"],
                        "fill_color": ["type": "string", "description": "图形填充颜色 #RRGGBB"],
                        "fill_opacity": ["type": "number", "description": "图形填充不透明度 0~1"],
                        "stroke_enabled": ["type": "boolean", "description": "图形描边开关"],
                        "stroke_opacity": ["type": "number", "description": "图形描边不透明度 0~1"],
                        "stroke_dashed": ["type": "boolean", "description": "图形描边用虚线"],
                        "cap_start": ["type": "string", "enum": LineCapStyle.allCases.map(\.rawValue), "description": "线段/箭头起点样式"],
                        "cap_end": ["type": "string", "enum": LineCapStyle.allCases.map(\.rawValue), "description": "线段/箭头终点样式"],
                        "shadow_enabled": ["type": "boolean", "description": "图形投影开关"],
                        "shadow_color": ["type": "string", "description": "投影颜色 #RRGGBB"],
                        "shadow_opacity": ["type": "number", "description": "投影不透明度 0~1"],
                        "shadow_radius": ["type": "number", "description": "投影模糊半径 px"],
                        "shadow_offset_x": ["type": "number", "description": "投影水平偏移 px"],
                        "shadow_offset_y": ["type": "number", "description": "投影垂直偏移 px"],
                        "pen_points": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                       "description": "钢笔路径的锚点，[[x,y],…]，x/y 是图形框内的比例 0~1（钢笔图形）"],
                        "pen_closed": ["type": "boolean", "description": "钢笔路径闭合（钢笔图形）"],
                        "intensity": ["type": "number", "description": "强度 0~1（滤镜、特效）"],
                        "amount": ["type": "number", "description": "特效的程度参数 0~1"],
                        "angle": ["type": "number", "description": "特效的角度（度）"],
                        "center_x": ["type": "number", "description": "特效中心，画面宽度百分比 0~100"],
                        "center_y": ["type": "number", "description": "特效中心，画面高度百分比 0~100"]
                    ] as [String: Any],
                    "required": [] as [String]
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
    /// 这一轮 OCR 了几次。按会话分开数，两条会话同时在扫不会互相顶到上限
    private static var ocrCallsByConversation: [UUID: Int] = [:]
    @MainActor static var ocrCallsThisRound: Int {
        get { ocrCallsByConversation[AgentContext.key] ?? 0 }
        set { ocrCallsByConversation[AgentContext.key] = newValue }
    }

    @MainActor
    static func runMediaTool(_ name: String, args: [String: Any],
                             project p: ProjectState) async -> AgentToolResult? {
        switch name {
        case "export_video":
            return exportVideo(p, filename: args["filename"] as? String, args: args)

        case "transcribe":
            return transcribe(p, clipKey: args["clip_id"] as? String,
                              proofread: args["proofread"] as? Bool ?? false, args: args)

        case "update_clip":
            let many = (args["clip_ids"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
            guard !many.isEmpty else { return updateClip(p, args: args) }
            // 多条一起改：逐条套同一组参数，一条失败不影响别的
            var base = args; base.removeValue(forKey: "clip_ids")
            var okCount = 0
            var fails: [String] = []
            for k in many {
                base["clip_id"] = k
                let r = updateClip(p, args: base)
                if r.isError { fails.append("\(k.prefix(8))：\(r.text)") } else { okCount += 1 }
            }
            let msg = "改好了 \(okCount)/\(many.count) 条。" + (fails.isEmpty ? "" : "\n" + fails.joined(separator: "\n"))
            return okCount > 0 ? .ok(msg) : .fail(msg)

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
    private static func exportVideo(_ p: ProjectState, filename: String?, args: [String: Any]) -> AgentToolResult {
        guard p.contentEndTime > 0.01 else {
            return .fail("时间线上还什么都没有，没得导。")
        }
        // 跟导出面板打开时一样，先按项目设置反显一遍，再叠这次指定的
        let res = p.previewResolution
        for r in ExportSettings.resolutions where res.hasPrefix(r) { p.exportSettings.resolution = r }
        if ExportSettings.aspectRatios.contains(p.previewAspectRatio) {
            p.exportSettings.aspectRatio = p.previewAspectRatio
        }
        p.exportSettings.fps = p.projectFPS
        p.exportSettings.bitrate = p.projectBitrate
        func int(_ k: String) -> Int? { (args[k] as? Int) ?? (args[k] as? Double).map { Int($0) } }
        if let r = args["resolution"] as? String, ExportSettings.resolutions.contains(r) { p.exportSettings.resolution = r }
        if let f = int("fps"), ExportSettings.fpsOptions.contains(f) { p.exportSettings.fps = f }
        if let b = int("bitrate") { p.exportSettings.bitrate = max(1000, min(50000, b)) }
        switch args["content"] as? String {
        case "audio": p.exportSettings.content = .audioOnly
        case "subtitle": p.exportSettings.content = .subtitleOnly
        default: p.exportSettings.content = .video
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

        var jobID: UUID?
        let mgr = ExportManager.shared
        return Self.runInBackground(
            args, title: "导出「\(outputURL.lastPathComponent)」", label: "导出", project: p,
            busy: { jobID.map { mgr.isExporting($0) } ?? false },
            cancel: { if let j = jobID { mgr.cancelExport(j) } },
            outcome: {
                FileManager.default.fileExists(atPath: outputURL.path)
                    ? (true, "导出到了 \(outputURL.path)") : (false, "导出没成，右下角有提示")
            },
            start: { jobID = mgr.startExport(snapshot: p.makeExportInput(outputURL: outputURL), owner: nil) },
            started: "已经开始导出「\(outputURL.lastPathComponent)」，放在\(outputURL.deletingLastPathComponent().path)。进度在右下角。")
    }

    // MARK: - 语音识别

    @MainActor
    private static func transcribe(_ p: ProjectState, clipKey: String?,
                                   proofread: Bool, args: [String: Any]) -> AgentToolResult {
        guard !p.isTranscribing else { return .fail("已经有一个识别在跑了，等它完事。") }
        guard WhisperTranscriber.whisperReady else {
            return .fail("语音识别引擎没就绪（whisper-cli 缺失），去设置里看看。")
        }
        // 用户选的那档没下载：先问他，别悄悄换档（原来会退回用已下载的，选均衡跑出来是极速）
        let chosen = AppSettings.shared.selectedWhisperModel
        let choice = args["model_choice"] as? String
        var allowFallback = false
        if !WhisperTranscriber.isReady(chosen) {
            let size = chosen.sizeDesc.components(separatedBy: " · ").first ?? ""
            switch choice {
            case "download": break          // autoTranscribe 会先下载再识别
            case "use_downloaded":
                guard WhisperTranscriber.bestReadyModel != nil else {
                    return .fail("本机一个识别模型都没有，只能先下载「\(chosen.featureName)」（\(size)）。")
                }
                allowFallback = true
            default:
                let fallback = WhisperTranscriber.bestReadyModel.map { "这次先用已下载的「\($0.featureName)」" }
                // 不算出错，是要用户拿主意 —— 标成失败的话步骤条一片红，模型也容易当成故障去重试
                return .ok("用户选的识别模型「\(chosen.featureName)」还没下载（\(size)），这次没开始。"
                    + "用 ask_user 问他：先下载「\(chosen.featureName)」再识别"
                    + (fallback.map { "，还是\($0)" } ?? "")
                    + "。他选了再调 transcribe，带上 model_choice（download / use_downloaded），其余参数照旧。")
            }
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
        // 翻译方式、AI 模型都取弹窗里存的。只识别时两样都关掉，只要校对时只开 AI
        let translate = (args["translate"] as? Bool) ?? ((args["translate"] as? String) == "true")
        let lang = (args["language"] as? String)?.trimmingCharacters(in: .whitespaces)
        let aiModel = p.transcribeAIModel
        let aiReady = AIVideoService.Provider(rawValue: aiModel).map { !AIVideoService.apiKey(for: $0).isEmpty } ?? false
        var engine = ""
        if translate {
            engine = p.transcribeTranslateEngine
            // 弹窗里是「不翻译」、或者选了 AI 翻译但那家没配 Key：退到设置里的翻译引擎
            if engine.isEmpty || (engine == "ai" && !aiReady) {
                engine = AppSettings.shared.translateProvider.rawValue
            }
        }
        let useAI = (translate && engine == "ai") || proofread
        let modelName = allowFallback ? (WhisperTranscriber.bestReadyModel?.featureName ?? "") : chosen.featureName
        var how = "识别模型：\(modelName)"
        if !WhisperTranscriber.isReady(chosen) && !allowFallback { how += "（先下载）" }
        if translate {
            let target = (lang?.isEmpty == false ? lang! : p.translationTargetLang)
            how += engine == "ai"
                ? "；AI 翻译成\(target)（\(Self.aiModelLabel(aiModel))，整批带上下文、顺带合并碎句）"
                : "；用「\(AppSettings.TranslateProvider(rawValue: engine)?.displayName ?? engine)」翻译成\(target)"
        } else if proofread {
            how += "；识别完让 \(Self.aiModelLabel(aiModel)) 校对一遍"
        }
        return Self.runInBackground(
            args, title: translate ? "识别并翻译字幕" : "语音识别", label: "语音识别", project: p,
            busy: { p.isTranscribing }, cancel: { p.cancelTranscribe() },
            start: { p.autoTranscribeSelectedClip(engine: engine, aiModel: useAI ? aiModel : "",
                                                  targetLang: (lang?.isEmpty == false) ? lang : nil,
                                                  allowModelFallback: allowFallback) },
            started: "开始了（\(how)），完事会生成一条字幕轨。")
    }

    /// 「DeepSeek · Deepseek-V4-Flash」这样的说法，给回复和汇报用
    static func aiModelLabel(_ raw: String) -> String {
        guard let p = AIVideoService.Provider(rawValue: raw) else { return raw.isEmpty ? "未选模型" : raw }
        let sub = AppSettings.shared.providerModel(for: p.rawValue).trimmingCharacters(in: .whitespaces)
        let label = p.subModels.first { $0.id == sub || $0.label == sub }?.label
            ?? (sub.isEmpty ? p.subModels.first?.label : sub)
        return label.map { "\(p.displayName) · \($0)" } ?? p.displayName
    }

    // MARK: - 改片段

    @MainActor
    private static func updateClip(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        guard let key = (args["clip_id"] as? String), !key.isEmpty else { return .fail("缺 clip_id") }
        let a = ClipArgs(args)
        guard a.hasAny else { return .fail("一个要改的属性都没传。") }
        var changed: [String] = []
        func note(_ s: String) { changed.append(s) }
        /// 这类片段不认的参数也要说出来，不然模型以为改成了
        func done(_ what: String, _ supported: Set<String>) -> AgentToolResult {
            let ignored = a.given.subtracting(supported).subtracting(["clip_id"]).sorted()
            p.refreshOverlayComposite()
            p.rebuildTimelinePreview()
            var msg = changed.isEmpty ? "\(what)：没有可改的项。" : "已经改了\(what)：\(changed.joined(separator: "、"))"
            if !ignored.isEmpty { msg += "\n（这些参数对\(what)不适用，没改：\(ignored.joined(separator: "、"))）" }
            return changed.isEmpty ? .fail(msg) : .ok(msg)
        }
        let transform: Set<String> = ["x", "y", "scale", "rotation", "opacity"]
        let color: Set<String> = Set(ClipArgs.colorKeys)

        // 视频
        for t in p.videoTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateVideoClip(id: c.id) { v in
                if let x = a.num("x") { v.offsetX = x / 100 - 0.5; note("水平位置 \(Int(x))%") }
                if let y = a.num("y") { v.offsetY = y / 100 - 0.5; note("垂直位置 \(Int(y))%") }
                if let s = a.num("scale") { v.scaleX = s; v.scaleY = s; note("缩放 \(s)") }
                // 视频这条的 rotation 是整数度、volume 是 Float
                if let r = a.num("rotation") { v.rotation = Int(r.rounded()); note("旋转 \(Int(r))°") }
                if let vol = a.num("volume") { v.volume = Float(max(0, min(4, vol))); note("音量 \(vol)") }
                if let sp = a.num("speed") { v.speed = max(0.1, min(10, sp)); note("速度 \(sp)x") }
                a.applyColor(&v.colorAdjust, note)
                if let t = a.str("transition") {
                    if t == "none" {
                        if v.inTransition != nil { v.inTransition = nil; note("删掉开头转场") }
                    } else if let k = TransitionType(rawValue: t) {
                        if v.inTransition != nil { v.inTransition?.type = k; note("转场换成 \(k.rawValue)") }
                        else { v.inTransition = Transition(type: k, duration: 0.5); note("加转场 \(k.rawValue)") }
                    }
                }
                if let d = a.num("transition_duration") {
                    if v.inTransition != nil { v.inTransition?.duration = max(0.1, d); note("转场时长 \(d) 秒") }
                }
                a.applyCrop(&v.cropTop, &v.cropBottom, &v.cropLeft, &v.cropRight, note)
                a.applyMirror(&v.mirrorH, &v.mirrorV, note)
                if let r = a.bool("reversed") { v.reversed = r; note(r ? "倒放" : "取消倒放") }
                if let i = a.num("audio_track") { v.audioTrackIndex = max(0, Int(i)); note("用第 \(Int(i)) 条音轨") }
            }
            return done("视频片段「\(c.name)」",
                        transform.subtracting(["opacity"]).union(["volume", "speed", "transition_duration", "transition",
                                                                  "reversed", "audio_track"]).union(color).union(ClipArgs.cropMirrorKeys))
        }
        // 图片
        for t in p.imageTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateImageClip(id: c.id) { v in
                if let x = a.num("x") { v.offsetX = x / 100 - 0.5; note("水平位置 \(Int(x))%") }
                if let y = a.num("y") { v.offsetY = y / 100 - 0.5; note("垂直位置 \(Int(y))%") }
                if let s = a.num("scale") { v.scaleX = s; v.scaleY = s; note("缩放 \(s)") }
                if let r = a.num("rotation") { v.rotation = r; note("旋转 \(Int(r))°") }
                if let o = a.num("opacity") { v.opacity = max(0, min(1, o)); note("不透明度 \(o)") }
                a.applyCrop(&v.cropTop, &v.cropBottom, &v.cropLeft, &v.cropRight, note)
                a.applyMirror(&v.mirrorH, &v.mirrorV, note)
                a.applyColor(&v.colorAdjust, note)
                if let r = a.num("corner_radius") { v.cornerRadius = max(0, r); note("圆角 \(Int(r))") }
                if let h = a.hex("stroke_color") { v.strokeColorHex = h; note("描边颜色") }
                if let w = a.num("stroke_width") { v.strokeWidth = max(0, w); note("描边宽度 \(w)") }
                if let s = a.num("stroke_softness") { v.strokeSoftness = max(0, min(1, s)); note("描边柔和 \(s)") }
            }
            return done("图片片段「\(c.name)」", transform.union(color).union(ClipArgs.cropMirrorKeys)
                .union(["corner_radius", "stroke_color", "stroke_width", "stroke_softness"]))
        }
        // 文字
        for t in p.textTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateTextClip(id: c.id) { v in
                if let x = a.num("x") { v.posX = x / 100; note("水平位置 \(Int(x))%") }
                if let y = a.num("y") { v.posY = y / 100; note("垂直位置 \(Int(y))%") }
                if let r = a.num("rotation") { v.rotation = r; note("旋转 \(Int(r))°") }
                if let o = a.num("opacity") { v.opacity = max(0, min(1, o)); note("不透明度 \(o)") }
                if let s = a.str("text") { v.text = s; note("内容") }
                if let f = a.num("font_size") { v.fontSize = CGFloat(max(4, f)); note("字号 \(Int(f))") }
                if let f = a.str("font_name") { v.fontName = f; note("字体 \(f)") }
                if let b = a.bool("bold") { v.bold = b; note(b ? "加粗" : "取消加粗") }
                if let b = a.bool("italic") { v.italic = b; note(b ? "斜体" : "取消斜体") }
                if let c = a.color("color") { v.textColor = c; note("文字颜色") }
                if let c = a.color("background_color") { v.bgColor = c; note("背景颜色") }
                if let o = a.num("background_opacity") { v.bgOpacity = max(0, min(1, o)); note("背景不透明度 \(o)") }
                if let al = a.alignment { v.alignment = al; note("对齐 \(al)") }
                if let c = a.color("stroke_color") { v.strokeColor = c; note("描边颜色") }
                if let w = a.num("stroke_width") { v.strokeWidth = max(0, w); note("描边宽度 \(w)") }
                if let s = a.num("stroke_softness") { v.strokeSoftness = max(0, min(1, s)); note("描边柔和 \(s)") }
                if let an = a.str("animation"), let k = TextAnimation(rawValue: an) { v.animation = k; note("入场动画 \(k.label)") }
                if let d = a.num("animation_duration") { v.animationDuration = max(0.1, min(3, d)); note("动画时长 \(d) 秒") }
                if let w = a.num("box_width") { v.boxWidth = w > 0 ? w : nil; note(w > 0 ? "文本框宽 \(Int(w))" : "文本框宽自适应") }
                if let h = a.num("box_height") { v.boxHeight = h > 0 ? h : nil; note(h > 0 ? "文本框高 \(Int(h))" : "文本框高自适应") }
                a.applyCrop(&v.cropTop, &v.cropBottom, &v.cropLeft, &v.cropRight, note)
                a.applyMirror(&v.mirrorH, &v.mirrorV, note)
            }
            return done("文字「\(c.text.prefix(10))」", transform.subtracting(["scale"]).union(
                ["text", "font_size", "font_name", "bold", "italic", "color", "background_color",
                 "background_opacity", "alignment", "stroke_color", "stroke_width", "stroke_softness",
                 "animation", "animation_duration", "box_width", "box_height"]).union(ClipArgs.cropMirrorKeys))
        }
        // 图形
        for t in p.shapeTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            var bad: String?
            p.updateShapeClip(id: c.id) { v in
                if let x = a.num("x") { v.posX = x / 100; note("水平位置 \(Int(x))%") }
                if let y = a.num("y") { v.posY = y / 100; note("垂直位置 \(Int(y))%") }
                if let s = a.num("scale") { v.scaleX = s; v.scaleY = s; note("缩放 \(s)") }
                if let r = a.num("rotation") { v.rotation = r; note("旋转 \(Int(r))°") }
                if let o = a.num("opacity") { v.opacity = max(0, min(1, o)); note("不透明度 \(o)") }
                if let w = a.num("width") { v.width = max(1, w); note("宽 \(Int(w))") }
                if let h = a.num("height") { v.height = max(1, h); note("高 \(Int(h))") }
                if let b = a.bool("fill_enabled") { v.fillEnabled = b; note(b ? "开填充" : "关填充") }
                if let c = a.color("fill_color") { v.fillColor = c; v.fillEnabled = true; note("填充颜色") }
                if let o = a.num("fill_opacity") { v.fillOpacity = max(0, min(1, o)); note("填充不透明度 \(o)") }
                if let b = a.bool("stroke_enabled") { v.strokeEnabled = b; note(b ? "开描边" : "关描边") }
                if let c = a.color("stroke_color") { v.strokeColor = c; v.strokeEnabled = true; note("描边颜色") }
                if let w = a.num("stroke_width") { v.strokeWidth = max(0, w); v.strokeEnabled = w > 0; note("描边宽度 \(w)") }
                if let o = a.num("stroke_opacity") { v.strokeOpacity = max(0, min(1, o)); note("描边不透明度 \(o)") }
                if let b = a.bool("stroke_dashed") { v.strokeDashed = b; note(b ? "虚线" : "实线") }
                if let s = a.str("cap_start"), let k = LineCapStyle(rawValue: s) { v.capStart = k; note("起点 \(k.label)") }
                if let s = a.str("cap_end"), let k = LineCapStyle(rawValue: s) { v.capEnd = k; note("终点 \(k.label)") }
                if let r = a.num("corner_radius") {
                    if v.type == .rectangle { v.cornerRadius = max(0, r); note("圆角 \(Int(r))") }
                    else { bad = "只有矩形有圆角" }
                }
                if let b = a.bool("shadow_enabled") { v.shadowEnabled = b; note(b ? "开投影" : "关投影") }
                if let c = a.color("shadow_color") { v.shadowColor = c; v.shadowEnabled = true; note("投影颜色") }
                if let o = a.num("shadow_opacity") { v.shadowOpacity = max(0, min(1, o)); note("投影不透明度 \(o)") }
                if let r = a.num("shadow_radius") { v.shadowRadius = max(0, r); note("投影半径 \(r)") }
                if let x = a.num("shadow_offset_x") { v.shadowOffsetX = x; note("投影水平偏移 \(x)") }
                if let y = a.num("shadow_offset_y") { v.shadowOffsetY = y; note("投影垂直偏移 \(y)") }
                if let pts = a.raw["pen_points"] as? [[Any]] {
                    if v.type == .pen {
                        let ps = pts.compactMap { pr -> PenPoint? in
                            guard pr.count >= 2, let x = ClipArgs.anyNum(pr[0]), let y = ClipArgs.anyNum(pr[1]) else { return nil }
                            return PenPoint(x: x, y: y, smooth: false)
                        }
                        if ps.count >= 2 { v.penPoints = ps; note("钢笔路径 \(ps.count) 个点") } else { bad = "钢笔路径至少要两个点" }
                    } else { bad = "只有钢笔图形能改路径" }
                }
                if let b = a.bool("pen_closed") {
                    if v.type == .pen { v.penClosed = b; note(b ? "闭合路径" : "断开路径") } else { bad = "只有钢笔图形能闭合路径" }
                }
                a.applyCrop(&v.cropTop, &v.cropBottom, &v.cropLeft, &v.cropRight, note)
                a.applyMirror(&v.mirrorH, &v.mirrorV, note)
            }
            if let bad, changed.isEmpty { return .fail(bad) }
            return done("图形（\(c.type.label)）", transform.union(ClipArgs.cropMirrorKeys).union(
                ["width", "height", "fill_enabled", "fill_color", "fill_opacity", "stroke_enabled", "stroke_color",
                 "stroke_width", "stroke_opacity", "stroke_dashed", "cap_start", "cap_end", "corner_radius",
                 "shadow_enabled", "shadow_color", "shadow_opacity", "shadow_radius", "shadow_offset_x",
                 "shadow_offset_y", "pen_points", "pen_closed"]))
        }
        // 字幕：内容改这一条，样式改整条轨
        for ti in p.subtitleTracks.indices {
            guard let c = p.subtitleTracks[ti].clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            if let s = a.str("text") { p.updateSubtitleText(id: c.id, text: s); note("这一条的内容") }
            var st = p.subtitleTracks[ti].subtitleStyle ?? SubtitleStyle()
            let before = st
            if let f = a.num("font_size") { st.fontSize = CGFloat(max(4, f)); note("字号 \(Int(f))") }
            if let f = a.str("font_name") { st.fontName = f; note("字体 \(f)") }
            if let b = a.bool("bold") { st.bold = b; note(b ? "加粗" : "取消加粗") }
            if let b = a.bool("italic") { st.italic = b; note(b ? "斜体" : "取消斜体") }
            if let c = a.color("color") { st.textColor = c; note("文字颜色") }
            if let c = a.color("background_color") { st.backgroundColor = c; note("背景颜色") }
            if let o = a.num("background_opacity") { st.backgroundOpacity = max(0, min(1, o)); note("背景不透明度 \(o)") }
            if let al = a.alignment { st.alignment = al; note("对齐 \(al)") }
            if let l = a.num("line_spacing") { st.lineSpacing = max(0, l); note("行距 \(l)") }
            if let m = a.num("bottom_margin") { st.bottomMargin = max(0, min(90, m)); note("离底边 \(m)%") }
            if let w = a.num("subtitle_width") { st.widthPercent = max(20, min(100, w)); note("字幕宽度 \(Int(w))%") }
            if let b = a.bool("merge_line_breaks") { st.mergeLineBreaks = b; note(b ? "合并换行" : "保留换行") }
            if st != before { p.subtitleTracks[ti].subtitleStyle = st }
            let label = p.subtitleTracks[ti].label
            return done(st != before ? "字幕轨「\(label)」（样式对整轨生效）" : "字幕",
                        ["text", "font_size", "font_name", "bold", "italic", "color", "background_color",
                         "background_opacity", "alignment", "line_spacing", "bottom_margin",
                         "subtitle_width", "merge_line_breaks"])
        }
        // 音频
        for ti in p.audioTracks.indices {
            guard let c = p.audioTracks[ti].clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateAudioClip(id: c.id) { v in
                if let vol = a.num("volume") { v.volume = Float(max(0, min(4, vol))); note("音量 \(vol)") }
                if let sp = a.num("speed") { v.speed = max(0.1, min(10, sp)); note("速度 \(sp)x") }
                if let l = a.num("left_channel") { v.leftChannel = Float(max(0, min(1, l))); note("左声道 \(l)") }
                if let r = a.num("right_channel") { v.rightChannel = Float(max(0, min(1, r))); note("右声道 \(r)") }
                if let f = a.num("fade_in") {
                    v.fadeInEnabled = f > 0
                    if f > 0 { v.fadeInDuration = min(f, v.duration) }
                    note(f > 0 ? "淡入 \(f) 秒" : "关掉淡入")
                }
                if let f = a.num("fade_out") {
                    v.fadeOutEnabled = f > 0
                    if f > 0 { v.fadeOutDuration = min(f, v.duration) }
                    note(f > 0 ? "淡出 \(f) 秒" : "关掉淡出")
                }
            }
            return done("音频片段「\(c.name)」",
                        ["volume", "speed", "left_channel", "right_channel", "fade_in", "fade_out"])
        }
        // 调节片段
        for t in p.adjustTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateAdjustClip(id: c.id) { v in a.applyColor(&v.adjust, note) }
            return done("调节片段「\(c.name)」", color)
        }
        // 滤镜
        for t in p.filterTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateFilterClip(id: c.id) { v in
                if let i = a.num("intensity") { v.intensity = max(0, min(1, i)); note("强度 \(i)") }
            }
            return done("滤镜「\(c.name)」", ["intensity"])
        }
        // 特效
        for t in p.effectTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            p.updateEffectClip(id: c.id) { v in
                if let i = a.num("intensity") { v.intensity = max(0, min(1, i)); note("强度 \(i)") }
                if let m = a.num("amount") { v.amount = max(0, min(1, m)); note("程度 \(m)") }
                if let g = a.num("angle") { v.angle = g; note("角度 \(Int(g))°") }
                if let x = a.num("center_x") { v.centerX = max(0, min(1, x / 100)); note("中心水平 \(Int(x))%") }
                if let y = a.num("center_y") { v.centerY = max(0, min(1, y / 100)); note("中心垂直 \(Int(y))%") }
            }
            return done("特效「\(c.name)」", ["intensity", "amount", "angle", "center_x", "center_y"])
        }
        return .fail("找不到 id 以 \(key) 开头的片段，先 list_tracks 看看。")
    }

    /// update_clip 的参数。模型给数字有时是整数、有时是字符串，这里统一收
    private struct ClipArgs {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }

        static let colorKeys = ["brightness", "contrast", "saturation", "vibrance", "exposure",
                                "gamma", "highlight", "shadow", "temperature", "tint", "hue"]

        /// 这一次实际传了哪些键
        var given: Set<String> { Set(raw.keys) }
        var hasAny: Bool { !given.subtracting(["clip_id"]).isEmpty }

        func num(_ k: String) -> Double? {
            if let d = raw[k] as? Double { return d }
            if let i = raw[k] as? Int { return Double(i) }
            if let s = raw[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        func str(_ k: String) -> String? { raw[k] as? String }
        static let cropMirrorKeys: Set<String> = ["crop_top", "crop_bottom", "crop_left", "crop_right", "mirror_h", "mirror_v"]
        static func anyNum(_ v: Any) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        /// 裁切按百分比收，存成 0~1
        func applyCrop(_ t: inout Double, _ b: inout Double, _ l: inout Double, _ r: inout Double,
                       _ note: (String) -> Void) {
            func pct(_ k: String) -> Double? { num(k).map { max(0, min(0.9, $0 / 100)) } }
            if let v = pct("crop_top") { t = v; note("上裁 \(Int(v * 100))%") }
            if let v = pct("crop_bottom") { b = v; note("下裁 \(Int(v * 100))%") }
            if let v = pct("crop_left") { l = v; note("左裁 \(Int(v * 100))%") }
            if let v = pct("crop_right") { r = v; note("右裁 \(Int(v * 100))%") }
        }
        func applyMirror(_ h: inout Bool, _ v: inout Bool, _ note: (String) -> Void) {
            if let b = bool("mirror_h") { h = b; note(b ? "水平镜像" : "取消水平镜像") }
            if let b = bool("mirror_v") { v = b; note(b ? "垂直镜像" : "取消垂直镜像") }
        }
        /// #RRGGBB 原样收成字符串（图片描边存的是 hex）
        func hex(_ k: String) -> String? {
            guard var h = str(k)?.trimmingCharacters(in: .whitespaces) else { return nil }
            if !h.hasPrefix("#") { h = "#" + h }
            guard h.count == 7, UInt64(h.dropFirst(), radix: 16) != nil else { return nil }
            return h.uppercased()
        }
        func bool(_ k: String) -> Bool? {
            if let b = raw[k] as? Bool { return b }
            if let s = raw[k] as? String { return s == "true" ? true : (s == "false" ? false : nil) }
            return nil
        }
        /// #RRGGBB → Color。格式不对就当没传
        func color(_ k: String) -> Color? {
            guard var h = str(k)?.trimmingCharacters(in: .whitespaces) else { return nil }
            if !h.hasPrefix("#") { h = "#" + h }
            guard h.count == 7, UInt64(h.dropFirst(), radix: 16) != nil else { return nil }
            return Color(hex: h)
        }
        var alignment: String? {
            guard let s = str("alignment")?.lowercased(), ["left", "center", "right"].contains(s) else { return nil }
            return s
        }
        /// 调色参数写进 ColorAdjust，范围按属性区滑块夹住
        func applyColor(_ c: inout ColorAdjust, _ note: (String) -> Void) {
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
            if let v = num("brightness") { c.brightness = clamp(v, -1, 1); note("亮度 \(v)") }
            if let v = num("contrast") { c.contrast = clamp(v, -1, 1); note("对比度 \(v)") }
            if let v = num("saturation") { c.saturation = clamp(v, -1, 1); note("饱和度 \(v)") }
            if let v = num("vibrance") { c.vibrance = clamp(v, -1, 1); note("自然饱和度 \(v)") }
            if let v = num("exposure") { c.exposure = clamp(v, -2, 2); note("曝光 \(v)") }
            if let v = num("gamma") { c.gamma = clamp(v, 0.25, 4); note("伽马 \(v)") }
            if let v = num("highlight") { c.highlight = clamp(v, -1, 1); note("高光 \(v)") }
            if let v = num("shadow") { c.shadow = clamp(v, -1, 1); note("阴影 \(v)") }
            if let v = num("temperature") { c.temperature = clamp(v, -1, 1); note("色温 \(v)") }
            if let v = num("tint") { c.tint = clamp(v, -1, 1); note("色调 \(v)") }
            if let v = num("hue") { c.hue = clamp(v, -180, 180); note("色相 \(Int(v))°") }
        }
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

        /// 带素材的片段（视频 / 音频）：开头动了素材起点要跟着挪，两头都不能超出素材，
        /// 时间轴秒数和素材秒数之间按倍速换算。跟界面上拖边缘是同一套规则
        func bounded(start oldS: Double, end oldE: Double, trimStart: Double, speed rawSpeed: Double,
                     assetID: UUID) -> (s: Double, e: Double, trim: Double, note: String)? {
            let speed = max(0.01, rawSpeed)
            guard var (s, e) = apply((oldS, oldE)) else { return nil }
            var notes: [String] = []
            let minStart = oldS - trimStart / speed
            if s < minStart - 0.001 { s = minStart; notes.append("开头已经到素材起点") }
            let trim = max(0, trimStart + (s - oldS) * speed)
            let assetDur = p.mediaAssets.first { $0.id == assetID }?.duration ?? 0
            if assetDur > 0 {
                let maxEnd = s + (assetDur - trim) / speed
                if e > maxEnd + 0.001 { e = maxEnd; notes.append("结尾已经到素材末尾") }
            }
            guard e - s > 0.05 else { return nil }
            return (s, e, trim, notes.isEmpty ? "" : "（\(notes.joined(separator: "，"))，没法再往外拉）")
        }

        for ti in p.videoTracks.indices {
            guard let ci = p.videoTracks[ti].clips.firstIndex(where: { "\($0.id)".hasPrefix(key) })
            else { continue }
            let c = p.videoTracks[ti].clips[ci]
            guard let r = bounded(start: c.startTime, end: c.endTime, trimStart: c.trimStart,
                                  speed: c.speed, assetID: c.assetID) else { return .fail("裁完长度会变成 0。") }
            p.pushUndo()
            p.videoTracks[ti].clips[ci].startTime = r.s
            p.videoTracks[ti].clips[ci].endTime = r.e
            p.videoTracks[ti].clips[ci].trimStart = r.trim
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」现在是 \(fmt(r.s)) → \(fmt(r.e))。\(r.note)")
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
            guard let r = bounded(start: c.startTime, end: c.endTime, trimStart: c.trimStart,
                                  speed: c.speed, assetID: c.assetID) else { return .fail("裁完长度会变成 0。") }
            p.pushUndo()
            p.audioTracks[ti].clips[ci].startTime = r.s
            p.audioTracks[ti].clips[ci].endTime = r.e
            p.audioTracks[ti].clips[ci].trimStart = r.trim
            p.rebuildTimelinePreview(); p.scheduleAutoSave()
            return .ok("「\(c.name)」现在是 \(fmt(r.s)) → \(fmt(r.e))。\(r.note)")
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
