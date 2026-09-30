// AgentTools+ClipInfo.swift
//
// 读一条片段的全部属性。
//
// 以前 Agent 只能改（update_clip）不能读：用户问「字幕现在多大」「这张图转了多少度」
// 它只能瞎猜，或者截图估。参数名跟 update_clip **一一对应**，读出来的值原样改个数
// 传回去就能用，不用它自己换算单位。

import Foundation
import SwiftUI

extension AgentToolbox {

    static var clipInfoSpec: AgentToolSpec {
        AgentToolSpec(
            name: "get_clip",
            description: """
            读一条片段现在的全部属性（位置、缩放、字号、颜色、调色、音量、转场……）。
            参数名跟 update_clip 一样，读到的值改一下就能直接传回 update_clip。
            字幕会同时给出它那条轨的样式（字幕样式按整轨算）。可以一次给多条 clip_ids。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "clip_id": ["type": "string"],
                    "clip_ids": ["type": "array", "items": ["type": "string"]]
                ] as [String: Any]
            ],
            risk: .readOnly)
    }

    @MainActor
    static func clipInfo(_ p: ProjectState, args: [String: Any]) -> AgentToolResult {
        var keys = (args["clip_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let k = args["clip_id"] as? String { keys.insert(k, at: 0) }
        keys = keys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return .fail("缺 clip_id") }
        var out: [String] = []
        for k in keys.prefix(20) {
            out.append(describeClip(p, key: k) ?? "- \(k)：找不到这条片段")
        }
        return .ok(out.joined(separator: "\n\n"))
    }

    // MARK: - 各类片段

    private static func n(_ v: Double, _ digits: Int = 2) -> String {
        let s = String(format: "%.\(digits)f", v)
        // 去掉多余的 0：1.50 → 1.5，2.00 → 2
        var t = s
        if t.contains(".") { while t.hasSuffix("0") { t.removeLast() }; if t.hasSuffix(".") { t.removeLast() } }
        return t
    }
    private static func pct(_ v: Double) -> String { n(v * 100, 1) }

    private static func colorLines(_ c: ColorAdjust) -> String {
        if c.isIdentity { return "调色：未调" }
        return "调色：brightness \(n(c.brightness))、contrast \(n(c.contrast))、saturation \(n(c.saturation))、"
            + "vibrance \(n(c.vibrance))、exposure \(n(c.exposure))、gamma \(n(c.gamma))、highlight \(n(c.highlight))、"
            + "shadow \(n(c.shadow))、temperature \(n(c.temperature))、tint \(n(c.tint))、hue \(n(c.hue, 0))"
    }

    private static func cropLine(_ t: Double, _ b: Double, _ l: Double, _ r: Double) -> String? {
        guard t + b + l + r > 0 else { return nil }
        return "裁切：crop_top \(pct(t))%、crop_bottom \(pct(b))%、crop_left \(pct(l))%、crop_right \(pct(r))%"
    }

    private static func mirrorLine(_ h: Bool, _ v: Bool) -> String? {
        guard h || v else { return nil }
        return "镜像：mirror_h \(h)、mirror_v \(v)"
    }

    @MainActor
    private static func describeClip(_ p: ProjectState, key: String) -> String? {
        func head(_ kind: String, _ id: UUID, _ name: String, _ s: Double, _ e: Double) -> String {
            "**\(kind)「\(name)」** id \(id.uuidString.prefix(8))，\(n(s))–\(n(e)) 秒（\(n(e - s)) 秒）"
        }
        func lines(_ h: String, _ items: [String?]) -> String {
            ([h] + items.compactMap { $0 }.map { "· " + $0 }).joined(separator: "\n")
        }

        for t in p.videoTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            var trans: String? = nil
            if let tr = c.inTransition { trans = "开头转场：transition \(tr.type.rawValue)，transition_duration \(n(tr.duration))" }
            return lines(head("视频", c.id, c.name, c.startTime, c.endTime), [
                "位置：x \(pct(c.offsetX + 0.5))%、y \(pct(c.offsetY + 0.5))%",
                "缩放：scale \(n(c.scaleX))" + (c.scaleX != c.scaleY ? "（纵向 \(n(c.scaleY))）" : ""),
                "旋转：rotation \(c.rotation)°",
                "音量：volume \(n(Double(c.volume)))，速度：speed \(n(c.speed))x，倒放：reversed \(c.reversed)",
                c.audioTrackIndex > 0 ? "音轨：audio_track \(c.audioTrackIndex)" : nil,
                "素材内起点 \(n(c.trimStart)) 秒",
                cropLine(c.cropTop, c.cropBottom, c.cropLeft, c.cropRight),
                mirrorLine(c.mirrorH, c.mirrorV),
                colorLines(c.colorAdjust),
                trans ?? "开头转场：无",
                (c.markers?.isEmpty == false) ? "标记 \(c.markers!.count) 个" : nil
            ])
        }
        for t in p.audioTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("音频", c.id, c.name, c.startTime, c.endTime), [
                "音量：volume \(n(Double(c.volume)))，速度：speed \(n(c.speed))x",
                "声道：left_channel \(n(Double(c.leftChannel)))、right_channel \(n(Double(c.rightChannel)))",
                "淡入：fade_in " + (c.fadeInEnabled ? n(c.fadeInDuration) : "0（关）")
                    + "，淡出：fade_out " + (c.fadeOutEnabled ? n(c.fadeOutDuration) : "0（关）"),
                "素材内起点 \(n(c.trimStart)) 秒",
                (c.markers?.isEmpty == false) ? "标记 \(c.markers!.count) 个" : nil
            ])
        }
        for t in p.imageTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            let stroke = (c.strokeWidth ?? 0) > 0
                ? "描边：stroke_color \(c.strokeColorHex ?? "#000000")、stroke_width \(n(c.strokeWidth ?? 0))、stroke_softness \(n(c.strokeSoftness ?? 0))"
                : "描边：无"
            return lines(head("图片", c.id, c.name, c.startTime, c.endTime), [
                "位置：x \(pct(c.offsetX + 0.5))%、y \(pct(c.offsetY + 0.5))%",
                "缩放：scale \(n(c.scaleX))" + (c.scaleX != c.scaleY ? "（纵向 \(n(c.scaleY))）" : ""),
                "旋转：rotation \(n(c.rotation))°，不透明度：opacity \(n(c.opacity ?? 1))",
                "圆角：corner_radius \(n(c.cornerRadius ?? 0))",
                stroke,
                cropLine(c.cropTop, c.cropBottom, c.cropLeft, c.cropRight),
                mirrorLine(c.mirrorH, c.mirrorV),
                colorLines(c.colorAdjust),
                "原图 \(c.imageWidth)×\(c.imageHeight)"
            ])
        }
        for t in p.textTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("文字", c.id, String(c.text.prefix(20)), c.startTime, c.endTime), [
                "内容：text「\(c.text)」",
                "字体：font_name \(c.fontName)、font_size \(n(Double(c.fontSize), 0))、bold \(c.bold)、italic \(c.italic)",
                "颜色：color \(c.textColor.toHex())，对齐：alignment \(c.alignment)",
                "背景：background_color \(c.bgColor.toHex())、background_opacity \(n(c.bgOpacity))",
                c.strokeWidth > 0 ? "描边：stroke_color \(c.strokeColor.toHex())、stroke_width \(n(c.strokeWidth))、stroke_softness \(n(c.strokeSoftness))" : "描边：无",
                "位置：x \(pct(c.posX))%、y \(pct(c.posY))%，旋转：rotation \(n(c.rotation))°，不透明度：opacity \(n(c.opacity))",
                "入场动画：animation \(c.animation.rawValue)（\(c.animation.label)）"
                    + (c.animation == .none ? "" : "，animation_duration \(n(c.entranceLength)) 秒"),
                "文本框：" + (c.boxWidth.map { "box_width \(n($0, 0))" } ?? "宽自适应") + "、"
                    + (c.boxHeight.map { "box_height \(n($0, 0))" } ?? "高自适应"),
                cropLine(c.cropTop, c.cropBottom, c.cropLeft, c.cropRight),
                mirrorLine(c.mirrorH, c.mirrorV)
            ])
        }
        for t in p.subtitleTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            let st = t.subtitleStyle ?? SubtitleStyle()
            return lines(head("字幕", c.id, String(c.text.prefix(20)), c.startTime, c.endTime), [
                "内容：text「\(c.text.replacingOccurrences(of: "\n", with: "⏎"))」",
                "所在轨「\(t.label)」id \(t.id.uuidString.prefix(8))，**下面的样式整条轨共用**：",
                "字体：font_name \(st.fontName)、font_size \(n(Double(st.fontSize), 0))、bold \(st.bold)、italic \(st.italic)",
                "颜色：color \(st.textColor.toHex())，对齐：alignment \(st.alignment)",
                "背景：background_color \(st.backgroundColor.toHex())、background_opacity \(n(st.backgroundOpacity))",
                "离底边：bottom_margin \(n(st.bottomMargin))%，行距：line_spacing \(n(st.lineSpacing))",
                "字幕宽度：subtitle_width \(n(st.widthPercent, 0))%，合并换行：merge_line_breaks \(st.mergeLineBreaks)"
            ])
        }
        for t in p.shapeTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("图形", c.id, c.type.label, c.startTime, c.endTime), [
                "位置：x \(pct(c.posX))%、y \(pct(c.posY))%，大小：width \(n(c.width, 0))、height \(n(c.height, 0))",
                "缩放：scale \(n(c.scaleX))" + (c.scaleX != c.scaleY ? "（纵向 \(n(c.scaleY))）" : "")
                    + "，旋转：rotation \(n(c.rotation))°，不透明度：opacity \(n(c.opacity))",
                "填充：fill_enabled \(c.fillEnabled)、fill_color \(c.fillColor.toHex())、fill_opacity \(n(c.fillOpacity))",
                "描边：stroke_enabled \(c.strokeEnabled)、stroke_color \(c.strokeColor.toHex())、stroke_width \(n(c.strokeWidth))、"
                    + "stroke_opacity \(n(c.strokeOpacity))、stroke_dashed \(c.strokeDashed)",
                (c.type == .line || c.type == .arrow || c.type == .pen)
                    ? "端点：cap_start \(c.capStart.rawValue)、cap_end \(c.capEnd.rawValue)" : nil,
                c.type == .rectangle ? "圆角：corner_radius \(n(c.cornerRadius))" : nil,
                "投影：shadow_enabled \(c.shadowEnabled)" + (c.shadowEnabled
                    ? "、shadow_color \(c.shadowColor.toHex())、shadow_opacity \(n(c.shadowOpacity))、shadow_radius \(n(c.shadowRadius))、shadow_offset_x \(n(c.shadowOffsetX))、shadow_offset_y \(n(c.shadowOffsetY))"
                    : ""),
                c.type == .pen ? "钢笔：\(c.penPoints?.count ?? 0) 个点，pen_closed \(c.penClosed)" : nil,
                cropLine(c.cropTop, c.cropBottom, c.cropLeft, c.cropRight),
                mirrorLine(c.mirrorH, c.mirrorV)
            ])
        }
        for t in p.filterTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("滤镜", c.id, c.name, c.startTime, c.endTime), [
                "种类：\(c.kind.rawValue)（\(c.kind.label)）" + (c.lutPath.map { "，LUT 文件 \($0)" } ?? ""),
                "强度：intensity \(n(c.intensity))"
            ])
        }
        for t in p.adjustTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("调节", c.id, c.name, c.startTime, c.endTime), [colorLines(c.adjust)])
        }
        for t in p.effectTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            return lines(head("特效", c.id, c.name, c.startTime, c.endTime), [
                "种类：\(c.kind.rawValue)（\(c.kind.label)）",
                "intensity \(n(c.intensity))、amount \(n(c.amount))、angle \(n(c.angle, 0))、"
                    + "center_x \(pct(c.centerX))%、center_y \(pct(c.centerY))%"
            ])
        }
        for t in p.compoundTracks {
            guard let c = t.clips.first(where: { "\($0.id)".hasPrefix(key) }) else { continue }
            let inner = c.videoTracks.count + c.audioTracks.count + c.imageTracks.count
                + c.subtitleTracks.count + c.textTracks.count + c.shapeTracks.count
            return lines(head("复合片段", c.id, c.name, c.startTime, c.endTime), [
                "里面有 \(inner) 条轨道，要看里面的片段用 compound_edit 进去再 list_tracks"
            ])
        }
        return nil
    }
}
