// AgentTools+Keyframes.swift
//
// 关键帧：让 Agent 也能做「从 A 动到 B」的动画 —— 位置、缩放、旋转、不透明度、裁剪、
// 调色、文字字号、音量，跟属性区每个滑块后面的 `< ◇ >` 是同一套数据。
//
// 值一律用**界面上看到的单位**（位置 / 缩放 / 不透明度 / 裁剪 / 音量是百分比，旋转是度，字号是像素），
// 换算成各类片段内部的存法在这里做 —— 模型不用知道视频位置存的是 -0.5~0.5 的偏移。
// 时间一律是**时间轴上的秒**，不是片段内的偏移。

import Foundation

extension AgentToolbox {

    /// 属性名（给模型看的）→ 内部属性
    private static let kfPropNames: [String: KeyframeProp] = [
        "position_x": .offsetX, "position_y": .offsetY,
        "scale_x": .scaleX, "scale_y": .scaleY,
        "rotation": .angle, "opacity": .opacity,
        "crop_top": .cropTop, "crop_bottom": .cropBottom, "crop_left": .cropLeft, "crop_right": .cropRight,
        "font_size": .fontSize, "volume": .volume,
        "brightness": .brightness, "contrast": .contrast, "saturation": .saturation, "vibrance": .vibrance,
        "exposure": .exposure, "gamma": .gamma, "highlight": .highlight, "shadow": .shadow,
        "temperature": .temperature, "tint": .tint, "hue": .hue,
    ]

    private static func kfName(_ p: KeyframeProp) -> String {
        kfPropNames.first { $0.value == p }?.key ?? p.rawValue
    }

    static var keyframeTools: [AgentToolSpec] {
        let propList = "position_x / position_y（位置 %，50 = 居中）、scale（宽高一起，%）/ scale_x / scale_y、"
            + "rotation（度，顺时针为正）、opacity（%）、crop_top / crop_bottom / crop_left / crop_right（%）、"
            + "font_size（文字字号 px）、volume（音量 %，100 = 原音量）、"
            + "brightness / contrast / saturation / vibrance / highlight / shadow / temperature / tint（-1~1）、"
            + "exposure（-2~2）、gamma（0.25~4，1 = 原样）、hue（-180~180）"
        return [
            AgentToolSpec(
                name: "list_keyframes",
                description: """
                看一个片段打了哪些关键帧（关键帧动画 / 音量曲线）：每个属性在时间轴上哪几秒、什么值、往后那段怎么过渡。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip": ["type": "string", "description": "片段 id（list_tracks 给的，前 8 位就行）"]
                    ] as [String: Any],
                    "required": ["clip"]
                ],
                risk: .readOnly),

            AgentToolSpec(
                name: "set_keyframes",
                description: """
                给片段打关键帧，做动画（移动、缩放、旋转、淡入淡出、裁剪、调色、字号变化）或音量曲线。
                一次可以打好几帧；同一时刻已有的帧会改值。两帧之间自动过渡。
                视频、图片能打全部画面属性；文字能打位置、旋转、不透明度、裁剪、字号；图形能打位置、缩放、旋转、不透明度、裁剪；
                视频、音频能打音量。可用属性：\(propList)。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip": ["type": "string", "description": "片段 id"],
                        "keyframes": [
                            "type": "array",
                            "description": "要打的帧",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "property": ["type": "string", "description": "属性名，见上"],
                                    "time": ["type": "number", "description": "时间轴上的秒（不是片段内偏移）。不写 = 当前播放头"],
                                    "value": ["type": "number", "description": "这一刻的值，单位见上。不写 = 用这一刻原本的值"],
                                    "easing": ["type": "string",
                                               "enum": ["linear", "ease_in", "ease_out", "ease_in_out", "elastic", "bounce"],
                                               "description": "从这一帧到下一帧怎么过渡，默认 linear"],
                                    "delay": ["type": "number", "description": "这一段先停多少秒再动，默认 0"]
                                ] as [String: Any],
                                "required": ["property"]
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["clip", "keyframes"]
                ],
                risk: .mutating),

            AgentToolSpec(
                name: "delete_keyframes",
                description: """
                删片段的关键帧。只写 clip = 全删；写 property = 删这个属性的全部；再写 time = 只删那一帧。
                删光之后属性回到打关键帧之前的值。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "clip": ["type": "string", "description": "片段 id"],
                        "property": ["type": "string", "description": "属性名（可选），同 set_keyframes"],
                        "time": ["type": "number", "description": "时间轴上的秒（可选）"]
                    ] as [String: Any],
                    "required": ["clip"]
                ],
                risk: .mutating),
        ]
    }

    @MainActor
    static func runKeyframeTool(_ name: String, args: [String: Any], project p: ProjectState) -> AgentToolResult? {
        guard ["list_keyframes", "set_keyframes", "delete_keyframes"].contains(name) else { return nil }
        guard let raw = (args["clip"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty
        else { return .fail("缺 clip（片段 id）。") }
        let all: [any KeyframeAnimatable] = p.videoTracks.flatMap(\.clips) + p.imageTracks.flatMap(\.clips)
            + p.textTracks.flatMap(\.clips) + p.shapeTracks.flatMap(\.clips) + p.audioTracks.flatMap(\.clips)
        let hits = all.filter { $0.id.uuidString.lowercased().hasPrefix(raw) }
        guard hits.count == 1, let clip = hits.first else {
            return .fail(hits.isEmpty ? "找不到片段「\(raw)」。先 list_tracks 拿 id；字幕、滤镜这类片段不能打关键帧。"
                                      : "「\(raw)」对上了好几个片段，多写几位 id。")
        }

        switch name {
        case "list_keyframes":
            return .ok(describe(clip))

        case "set_keyframes":
            guard let items = args["keyframes"] as? [[String: Any]], !items.isEmpty else {
                return .fail("keyframes 要写成数组，每项至少有 property。")
            }
            var errors: [String] = []
            var done = 0
            p.pushUndo()
            for it in items {
                guard let pname = (it["property"] as? String)?.lowercased() else { errors.append("有一项缺 property"); continue }
                let props: [KeyframeProp]
                if pname == "scale" { props = [.scaleX, .scaleY] }
                else if let kp = kfPropNames[pname] { props = [kp] }
                else { errors.append("不认识的属性「\(pname)」"); continue }
                let supported = props.filter { clip.propValue($0) != nil }
                guard !supported.isEmpty else { errors.append("这类片段不能给「\(pname)」打关键帧"); continue }
                let t = (it["time"] as? NSNumber)?.doubleValue ?? p.currentTime
                guard t >= clip.startTime - 0.001, t <= clip.endTime + 0.001 else {
                    errors.append(String(format: "「%@」的时间 %.2f 秒不在片段里（%.2f~%.2f）", pname, t, clip.startTime, clip.endTime))
                    continue
                }
                var easing: KeyframeEasing? = nil
                if let e = it["easing"] as? String {
                    switch e {
                    case "ease_in":     easing = .easeIn
                    case "ease_out":    easing = .easeOut
                    case "ease_in_out": easing = .easeInOut
                    case "elastic":     easing = .elastic(0.25)
                    case "bounce":      easing = .bounce
                    default:            easing = .linear
                    }
                }
                if let d = (it["delay"] as? NSNumber)?.doubleValue, d > 0 {
                    var e = easing ?? .linear
                    e.delay = d * clip.keyframeTimeScale
                    easing = e
                }
                let uiValue = (it["value"] as? NSNumber)?.doubleValue
                for prop in supported {
                    let v = uiValue.map { toInternal($0, prop, clip) }
                    p.updateKeyframedClip(clip.id) { c in c.putKeyframe(prop, atTimeline: t, value: v, easing: easing) }
                }
                done += 1
            }
            if done > 0 {
                p.isSaved = false
                p.scheduleAutoSave()
                p.rebuildTimelinePreviewDebounced()
            }
            let now = p.keyframedClip(clip.id).map(describe) ?? ""
            if done == 0 { return .fail("一帧都没打上：\(errors.joined(separator: "；"))。") }
            return .ok("打好了 \(done) 帧" + (errors.isEmpty ? "。" : "；没打上的：\(errors.joined(separator: "；"))。") + "\n" + now)

        default: // delete_keyframes
            guard clip.hasKeyframes else { return .ok("这个片段本来就没有关键帧。") }
            var props = KeyframeProp.allCases
            if let pname = (args["property"] as? String)?.lowercased() {
                if pname == "scale" { props = [.scaleX, .scaleY] }
                else if let kp = kfPropNames[pname] { props = [kp] }
                else { return .fail("不认识的属性「\(pname)」。") }
            }
            let t = (args["time"] as? NSNumber)?.doubleValue
            p.pushUndo()
            p.updateKeyframedClip(clip.id) { c in
                for prop in props {
                    if let t {
                        c.setKeyframe(prop, atTimeline: t, on: false)
                    } else {
                        // 整条删：逐帧删，删光自动回到打关键帧之前的值
                        for kt in c.keyframeTimelineTimes(prop) { c.setKeyframe(prop, atTimeline: kt, on: false) }
                    }
                }
            }
            p.isSaved = false
            p.scheduleAutoSave()
            p.rebuildTimelinePreviewDebounced()
            let now = p.keyframedClip(clip.id).map(describe) ?? ""
            return .ok("删好了。\n" + now)
        }
    }

    // MARK: - 单位换算（界面单位 ↔ 内部存法）

    /// 位置：视频 / 图片内部存 -0.5~0.5 的偏移，文字 / 图形存 0~1 的中心点；界面上都是 0~100%
    private static func posIsOffset(_ c: any KeyframeAnimatable) -> Bool { c is VideoClip || c is ImageClip }

    private static func toInternal(_ v: Double, _ p: KeyframeProp, _ c: any KeyframeAnimatable) -> Double {
        switch p {
        case .offsetX, .offsetY: return posIsOffset(c) ? v / 100 - 0.5 : v / 100
        case .scaleX, .scaleY, .opacity, .volume,
             .cropTop, .cropBottom, .cropLeft, .cropRight: return v / 100
        default: return v   // 旋转（度）、字号（px）、调色（原值）
        }
    }

    private static func toUI(_ v: Double, _ p: KeyframeProp, _ c: any KeyframeAnimatable) -> Double {
        switch p {
        case .offsetX, .offsetY: return posIsOffset(c) ? (v + 0.5) * 100 : v * 100
        case .scaleX, .scaleY, .opacity, .volume,
             .cropTop, .cropBottom, .cropLeft, .cropRight: return v * 100
        default: return v
        }
    }

    private static func easingName(_ e: KeyframeEasing?) -> String {
        guard let e else { return "linear" }
        var s: String
        switch e.kind {
        case .elastic: s = String(format: "elastic(%.2f)", e.amount)
        case .bounce:  s = "bounce"
        case .curve:
            if e.isCustom == true { s = String(format: "curve(%.2f,%.2f,%.2f,%.2f)", e.x1, e.y1, e.x2, e.y2) }
            else if abs(e.x1 - 0.42) < 0.01 && abs(e.x2 - 1) < 0.01 { s = "ease_in" }
            else if abs(e.x1) < 0.01 && abs(e.x2 - 0.58) < 0.01 { s = "ease_out" }
            else if abs(e.x1 - 0.42) < 0.01 && abs(e.x2 - 0.58) < 0.01 { s = "ease_in_out" }
            else if abs(e.x1) < 0.01 && abs(e.x2 - 1) < 0.01 { s = "linear" }
            else { s = String(format: "curve(%.2f,%.2f,%.2f,%.2f)", e.x1, e.y1, e.x2, e.y2) }
        }
        if let d = e.delay, d > 0 { s += String(format: " 延时%.2f", d) }
        return s
    }

    private static func describe(_ c: any KeyframeAnimatable) -> String {
        guard let kf = c.keyframes, !kf.isEmpty else {
            return String(format: "片段 %@（%.2f~%.2f 秒）没有关键帧。", String(c.id.uuidString.prefix(8)), c.startTime, c.endTime)
        }
        var lines = [String(format: "片段 %@（%.2f~%.2f 秒）的关键帧：", String(c.id.uuidString.prefix(8)), c.startTime, c.endTime)]
        for p in KeyframeProp.allCases where kf.has(p) {
            let frames = kf.frames(p).map { f in
                String(format: "%.2fs=%.4g", c.timelineTime(ofKeyframe: f.time), toUI(f.value, p, c))
                    + (f == kf.frames(p).last ? "" : "（\(easingName(f.easing))）")
            }
            lines.append("· \(kfName(p))：" + frames.joined(separator: " → "))
        }
        return lines.joined(separator: "\n")
    }
}
