import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import NaturalLanguage

// MARK: - Root

struct InspectorView: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                if let transID = project.selectedTransitionClipID {
                    TransitionInspector(clipID: transID)
                } else if let clip = project.selectedSubtitleClip {
                    SubtitleInspector(clip: clip).id(clip.id)
                } else if let clip = project.selectedImageClip {
                    ImageInspector(clip: clip).id(clip.id)
                } else if let clip = project.selectedVideoClip {
                    VideoInspector(clip: clip).id(clip.id)
                } else if let clip = project.selectedAudioClip {
                    AudioInspector(clip: clip).id(clip.id)
                } else if let clip = defaultClip {
                    // 未选择时，默认显示第一个视频片段；无视频则显示第一个片段
                    switch clip {
                    case .video(let c):    VideoInspector(clip: c).id(c.id)
                    case .image(let c):    ImageInspector(clip: c).id(c.id)
                    case .audio(let c):    AudioInspector(clip: c).id(c.id)
                    case .subtitle(let c): SubtitleInspector(clip: c).id(c.id)
                    }
                } else {
                    EmptyInspector()
                }
            }
        }
    }

    /// 未选择任何片段时的默认显示：优先第一个视频片段，否则第一个任意片段
    private var defaultClip: DefaultClipRef? {
        // 优先视频
        if let c = project.videoTracks.flatMap(\.clips).first { return .video(c) }
        // 其次图片
        if let c = project.imageTracks.flatMap(\.clips).first { return .image(c) }
        // 其次音频
        if let c = project.audioTracks.flatMap(\.clips).first { return .audio(c) }
        // 最后字幕
        if let c = project.subtitleTracks.flatMap(\.clips).first { return .subtitle(c) }
        return nil
    }

    private enum DefaultClipRef {
        case video(VideoClip)
        case image(ImageClip)
        case audio(AudioClip)
        case subtitle(SubtitleClip)
    }

    private var header: some View {
        HStack {
            Text("属性")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
            Spacer()
            Text(tag)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var tag: String {
        if project.selectedTransitionClipID != nil { return "转场" }
        if project.selectedSubtitleClipID   != nil { return "字幕片段" }
        if project.selectedImageClipID      != nil { return "图片片段" }
        if project.selectedVideoClipID      != nil { return "视频片段" }
        if project.selectedAudioClipID      != nil { return "音频片段" }
        // 默认片段的标签
        if let clip = defaultClip {
            switch clip {
            case .video:    return "视频片段"
            case .image:    return "图片片段"
            case .audio:    return "音频片段"
            case .subtitle: return "字幕片段"
            }
        }
        return ""
    }
}

// MARK: - Empty

private struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.3))
            Text("点击时间轴片段\n查看和编辑属性")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

// MARK: - Subtitle Inspector

private struct SubtitleInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: SubtitleClip

    @State private var text: String = ""
    @State private var startTime: Double = 0
    @State private var endTime: Double   = 0
    @State private var ls = SubtitleStyle()   // local copy — ColorPicker needs @State binding
    @State private var isSyncing = false   // 外部（撤销/重做）同步 ls 时为 true，避免回写触发 writeStyle

    // 返回 nil 表示 clip 已从轨道中移除（不能写入样式）
    private var trackIndex: Int? {
        for (i, t) in project.subtitleTracks.enumerated() {
            if t.clips.contains(where: { $0.id == clip.id }) { return i }
        }
        return nil
    }

    /// 当前轨道的字幕样式（撤销/重做等外部操作会改变它）
    private var currentStyle: SubtitleStyle {
        guard let i = trackIndex else { return SubtitleStyle() }
        return project.subtitleTracks[i].subtitleStyle ?? SubtitleStyle()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 时间 ──────────────────────────────────────
            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: $startTime, step: 0.1, decimals: 2)
                            .onChange(of: startTime) { _ in project.updateSubtitleTime(id: clip.id, start: startTime) }
                    }
                    IField(label: "持续") {
                        MiniStepper(
                            value: Binding(
                                get: { max(endTime - startTime, 0) },
                                set: { endTime = startTime + max($0, 0.05) }
                            ),
                            step: 0.1, decimals: 2
                        )
                        .onChange(of: endTime) { _ in project.updateSubtitleTime(id: clip.id, end: endTime) }
                    }
                }
            }

            // ── 字幕文字 ──────────────────────────────────
            ISection(title: "字幕文字") {
                SubtitleTextBox(text: $text, clipID: clip.id)

                HStack(spacing: 12) {
                    Text("合并换行")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    Toggle("", isOn: $ls.mergeLineBreaks)
                        .toggleStyle(.switch)
                        .scaleEffect(0.7, anchor: .leading)
                        .labelsHidden()
                        .onChange(of: ls.mergeLineBreaks) { _ in writeStyle() }
                    Spacer()
                }
            }

            // ── 字体 ──────────────────────────────────────
            ISection(title: "字体") {
                HStack(alignment: .bottom, spacing: 8) {
                    IField(label: "字体") {
                        IPicker(selection: $ls.fontName,
                                options: ["PingFang SC","思源黑体","Helvetica Neue","Arial","Times New Roman"].map { ($0, $0) })
                            .onChange(of: ls.fontName) { _ in writeStyle() }
                    }
                    IField(label: "字号") {
                        MiniStepper(value: Binding(
                            get: { Double(ls.fontSize) },
                            set: { ls.fontSize = CGFloat($0); writeStyle() }
                        ), step: 1, decimals: 0, minValue: 8, maxValue: 200)
                    }
                    .frame(width: 92)
                }
            }

            // ── 颜色 ──────────────────────────────────────
            ISection(title: "颜色") {
                HStack(spacing: 12) {
                    Text("文字颜色")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    ColorPicker("", selection: $ls.textColor).labelsHidden()
                        .onChange(of: ls.textColor) { _ in writeStyle() }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Text("背景颜色")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    ColorPicker("", selection: $ls.backgroundColor).labelsHidden()
                        .onChange(of: ls.backgroundColor) { _ in writeStyle() }
                    Spacer(minLength: 0)
                }

                ISlider(label: "背景不透明度",
                        value: Binding(get:{ls.backgroundOpacity*100}, set:{ls.backgroundOpacity=$0/100}),
                        range: 0...100, unit: "%")
                    .onChange(of: ls.backgroundOpacity) { _ in writeStyle() }
            }

            // ── 布局 ──────────────────────────────────────
            ISection(title: "布局") {
                ISlider(label: "字幕宽度",  value: $ls.widthPercent,  range: 30...100, unit: "%")
                    .onChange(of: ls.widthPercent)  { _ in writeStyle() }
                ISlider(label: "距下边缘",  value: $project.subtitleBottomMargin,  range: 0...50,   unit: "%")
                    .onChange(of: project.subtitleBottomMargin) { _ in project.pushUndoThrottled() }
                ISlider(label: "字幕间距",  value: $project.subtitleLineSpacing,   range: 0...60,   unit: "pt")
                    .onChange(of: project.subtitleLineSpacing) { _ in project.pushUndoThrottled() }

                HStack(spacing: 12) {
                    Text("对齐方式")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach([("text.alignleft","left"),("text.aligncenter","center"),("text.alignright","right")], id:\.1) { icon, val in
                            Button { ls.alignment = val; writeStyle() } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundColor(ls.alignment == val ? Color.accent : Color.labelSecondary)
                                    .frame(width: 34, height: 26)
                                    .background(ls.alignment == val ? Color.accent.opacity(0.15) : Color.white.opacity(0.05))
                                    .cornerRadius(5)
                            }.buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }

            }
        }
        .onAppear { syncAll() }
        .onChange(of: clip.id) { _ in syncAll() }
        .onChange(of: currentStyle) { newStyle in
            // 撤销/重做等外部改变样式时，同步回本地 ls 以刷新面板（不回写）
            guard !isSyncing, newStyle != ls else { return }
            isSyncing = true
            ls = newStyle
            DispatchQueue.main.async { isSyncing = false }
        }
    }

    // MARK: Helpers

    private func syncAll() {
        isSyncing = true
        text = clip.text; startTime = clip.startTime; endTime = clip.endTime
        if let i = trackIndex { ls = project.subtitleTracks[i].subtitleStyle ?? SubtitleStyle() }
        DispatchQueue.main.async { isSyncing = false }
    }

    private func writeStyle() {
        guard !isSyncing, let i = trackIndex else { return }  // 同步中或 clip 已删除，禁止写入
        project.pushUndoThrottled()
        project.subtitleTracks[i].subtitleStyle = ls
    }

}

// MARK: - Translator (Google Translate public endpoint)

enum Translator {
    /// Bilingual-aware translation:
    ///  • Splits the source by newline into lines
    ///  • Detects the dominant language of each line (via NaturalLanguage)
    ///  • If any line is already in the target language, return ONLY those lines
    ///    (so a "Hello\n你好" → Chinese subtitle becomes just "你好")
    ///  • Otherwise translate every line to the target language
    static func translateSmart(_ text: String, to targetLang: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let targetCode = languageCode(targetLang)

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return text }

        let recognizer = NLLanguageRecognizer()
        var targetLines: [String] = []
        var otherLines:  [String] = []
        for line in lines {
            recognizer.reset()
            recognizer.processString(line)
            let detectedRaw = recognizer.dominantLanguage?.rawValue ?? ""
            // NLLanguageRecognizer 用 zh-Hans / zh-Hant，而目标用 zh-CN / zh-TW
            // 需要精确匹配：zh-Hans ↔ zh-CN，zh-Hant ↔ zh-TW
            if isExactMatch(detected: detectedRaw, target: targetCode) {
                targetLines.append(line)
            } else {
                otherLines.append(line)
            }
        }

        if !targetLines.isEmpty {
            return targetLines.joined(separator: "\n")
        }

        var translated: [String] = []
        for line in otherLines {
            translated.append(await translate(line, to: targetLang))
        }
        return translated.joined(separator: "\n")
    }

    /// 精确语言匹配，区分简繁体中文
    private static func isExactMatch(detected: String, target: String) -> Bool {
        // 中文特殊处理：zh-Hans = zh-CN（简体），zh-Hant = zh-TW（繁体）
        let normalizedDetected = normalizeChineseLang(detected)
        let normalizedTarget = normalizeChineseLang(target)
        // 如果都是中文子类型，需要完整匹配
        if normalizedDetected.hasPrefix("zh-") && normalizedTarget.hasPrefix("zh-") {
            return normalizedDetected == normalizedTarget
        }
        // 非中文：比较 base（en, ja, ko...）
        let detectedBase = String(detected.split(separator: "-").first ?? Substring(detected))
        let targetBase = String(target.split(separator: "-").first ?? Substring(target))
        return detectedBase == targetBase
    }

    private static func normalizeChineseLang(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-CN": return "zh-CN"
        case "zh-Hant", "zh-TW": return "zh-TW"
        default: return code
        }
    }

    /// Plain translation of a single text via Google Translate's public endpoint.
    /// Returns the original text on any failure so subtitles never go blank.
    static func translate(_ text: String, to lang: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let code = languageCode(lang)
        guard let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(code)&dt=t&q=\(q)")
        else { return text }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let segs = outer.first as? [Any] else { return text }
            // Each seg is [translatedText, originalText, ...]
            let parts: [String] = segs.compactMap {
                guard let arr = $0 as? [Any], let s = arr.first as? String else { return nil }
                return s
            }
            let joined = parts.joined()
            return joined.isEmpty ? text : joined
        } catch {
            return text
        }
    }

    private static func languageCode(_ label: String) -> String {
        switch label {
        case "中文（简体）": return "zh-CN"
        case "中文（繁体）": return "zh-TW"
        case "English":     return "en"
        case "日本語":       return "ja"
        case "한국어":       return "ko"
        case "Français":    return "fr"
        case "Deutsch":     return "de"
        case "Español":     return "es"
        case "Русский":     return "ru"
        case "العربية":      return "ar"
        case "Português":   return "pt"
        case "Italiano":    return "it"
        default:            return "zh-CN"
        }
    }
}

// MARK: - Video Inspector

// MARK: - Image Inspector

private struct ImageInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: ImageClip

    @State private var scaleX: Double = 1.0
    @State private var scaleY: Double = 1.0
    @State private var lockAspect: Bool = true
    @State private var offsetX: Double = 0
    @State private var offsetY: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var hasPushedUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "片段信息") {
                if let thumb = project.mediaThumbnails[clip.assetID] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                InfoRow(label: "名称",   value: clip.name)
                InfoRow(label: "分辨率", value: "\(clip.imageWidth) × \(clip.imageHeight)")
                InfoRow(label: "时长",   value: String(format: "%.1f 秒", clip.duration))
            }

            ISection(title: nil) {
                imgSectionHeader("位置") {
                    Button { offsetX = 0; offsetY = 0; applyTransform() } label: {
                        Text("居中")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(hasOffset ? .black : Color.labelSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(hasOffset ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(!hasOffset)
                }
                HStack(spacing: 10) {
                    imgDualSlider("X", value: $offsetX, range: -1.0...1.0) { _ in applyTransform() }
                    imgDualSlider("Y", value: $offsetY, range: -1.0...1.0) { _ in applyTransform() }
                }
            }

            ISection(title: nil) {
                imgSectionHeader("缩放") {
                    Button { lockAspect.toggle(); syncLock() } label: {
                        Image(systemName: lockAspect ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundColor(lockAspect ? Color.accent : Color.labelSecondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    imgDualSlider("宽", value: $scaleX, range: 0.1...3.0, unit: "%", scale: 100) { v in
                        if lockAspect { scaleY = v }; applyTransform()
                    }
                    imgDualSlider("高", value: $scaleY, range: 0.1...3.0, unit: "%", scale: 100) { v in
                        if lockAspect { scaleX = v }; applyTransform()
                    }
                }
            }

            ISection(title: nil) {
                imgSectionHeader("裁剪") {
                    Button { cropTop = 0; cropBottom = 0; cropLeft = 0; cropRight = 0; applyTransform() } label: {
                        Text("重置")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(hasCrop ? .black : Color.labelSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(hasCrop ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(!hasCrop)
                }
                VStack(spacing: 8) {
                    cropSlider(label: "上", value: $cropTop, edge: 0)
                    cropSlider(label: "下", value: $cropBottom, edge: 1)
                    cropSlider(label: "左", value: $cropLeft, edge: 2)
                    cropSlider(label: "右", value: $cropRight, edge: 3)
                }
            }
        }
        .onAppear { syncFromClip() }
        .onChange(of: clip.id) { _ in syncFromClip() }
        .onChange(of: clip.offsetX)    { v in if abs(v - offsetX) > 0.001 { offsetX = v } }
        .onChange(of: clip.offsetY)    { v in if abs(v - offsetY) > 0.001 { offsetY = v } }
        .onChange(of: clip.scaleX)     { v in if abs(v - scaleX)  > 0.001 { scaleX  = v } }
        .onChange(of: clip.scaleY)     { v in if abs(v - scaleY)  > 0.001 { scaleY  = v } }
        .onChange(of: clip.cropTop)    { v in if abs(v - cropTop)    > 0.001 { cropTop    = v } }
        .onChange(of: clip.cropBottom) { v in if abs(v - cropBottom) > 0.001 { cropBottom = v } }
        .onChange(of: clip.cropLeft)   { v in if abs(v - cropLeft)   > 0.001 { cropLeft   = v } }
        .onChange(of: clip.cropRight)  { v in if abs(v - cropRight)  > 0.001 { cropRight  = v } }
    }

    private var hasOffset: Bool {
        abs(offsetX) > 0.001 || abs(offsetY) > 0.001
    }

    private var hasCrop: Bool {
        cropTop > 0.001 || cropBottom > 0.001 || cropLeft > 0.001 || cropRight > 0.001
    }

    @ViewBuilder
    private func cropSlider(label: String, value: Binding<Double>, edge: Int) -> some View {
        ICapsuleSlider(label: label, value: value, range: 0...0.99,
                       unit: "%", displayScale: 100, labelWidth: 14,
                       onChange: { _ in applyCropWithCompensation(edge: edge) })
    }

    private func syncFromClip() {
        scaleX = clip.scaleX
        scaleY = clip.scaleY
        lockAspect = clip.lockAspect
        offsetX = clip.offsetX
        offsetY = clip.offsetY
        cropTop = clip.cropTop
        cropBottom = clip.cropBottom
        cropLeft = clip.cropLeft
        cropRight = clip.cropRight
        hasPushedUndo = false
    }

    private func syncLock() {
        project.updateImageClip(id: clip.id) { $0.lockAspect = lockAspect }
    }

    private func applyTransform() {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        project.updateImageClip(id: clip.id) {
            $0.scaleX = scaleX
            $0.scaleY = scaleY
            $0.lockAspect = lockAspect
            $0.offsetX = offsetX
            $0.offsetY = offsetY
            $0.cropTop = cropTop
            $0.cropBottom = cropBottom
            $0.cropLeft = cropLeft
            $0.cropRight = cropRight
        }
        project.rebuildTimelinePreviewDebounced()
    }

    /// 裁剪滑块变化时，直接更新裁剪值（scale 不随 crop 变化，对面边自然不动）
    private func applyCropWithCompensation(edge: Int) {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        applyTransform()
    }

    @ViewBuilder
    private func imgSectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
                .tracking(0.2)
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func imgDualSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              unit: String = "", scale: Double = 100,
                              onChange: @escaping (Double) -> Void) -> some View {
        ICapsuleSlider(label: label, value: value, range: range,
                       unit: unit, displayScale: scale, labelWidth: 14,
                       onChange: onChange)
    }
}

// MARK: - Video Inspector

private struct VideoInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: VideoClip

    @State private var sourceRes: String = "—"
    @State private var sourceFPS: String = "—"
    @State private var sourceBitrate: String = "—"
    @State private var sourceCodec: String = "—"
    @State private var audioTrackLabels: [String] = []  // 多音轨标签

    @State private var scaleX: Double = 1.0
    @State private var scaleY: Double = 1.0
    @State private var lockAspect: Bool = true
    @State private var offsetX: Double = 0
    @State private var offsetY: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var hasPushedUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "片段信息") {
                InfoRow(label: "文件名", value: clip.name)
                InfoRow(label: "时长",   value: fmtDur(clip.duration))
                InfoRow(label: "分辨率", value: sourceRes)
                InfoRow(label: "帧率",   value: sourceFPS)
                InfoRow(label: "码率",   value: sourceBitrate)
                InfoRow(label: "编码",   value: sourceCodec)
            }

            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: Binding(
                            get: { clip.startTime },
                            set: { v in
                                let dur = clip.duration
                                project.updateVideoClip(id: clip.id) { $0.startTime = max(0, v); $0.endTime = max(0, v) + dur }
                            }
                        ), step: 0.1, decimals: 2)
                    }
                    IField(label: "持续") {
                        MiniStepper(value: Binding(
                            get: { clip.duration },
                            set: { v in project.updateVideoClip(id: clip.id) { $0.endTime = $0.startTime + max(0.05, v) } }
                        ), step: 0.1, decimals: 2)
                    }
                }
            }

            ISection(title: "音量") {
                ISlider(label: "整体音量", value: Binding(
                    get: { Double(clip.volume) * 100 },
                    set: { v in
                        project.updateVideoClip(id: clip.id) { $0.volume = Float(v / 100) }
                        project.rebuildTimelinePreview()
                    }
                ), range: 0...400, unit: "%")
            }

            if audioTrackLabels.count >= 2 {
                ISection(title: "音轨") {
                    IPicker(selection: Binding(
                                get: { min(clip.audioTrackIndex, audioTrackLabels.count - 1) },
                                set: { idx in
                                    project.updateVideoClip(id: clip.id) { $0.audioTrackIndex = idx }
                                    project.rebuildTimelinePreview()
                                }
                            ),
                            options: audioTrackLabels.enumerated().map { ($0.offset, $0.element) })
                }
            }

            ISection(title: nil) {
                sectionHeader("位置") {
                    Button { offsetX = 0; offsetY = 0; applyTransform() } label: {
                        Text("居中")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(hasOffset ? .black : Color.labelSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(hasOffset ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(!hasOffset)
                }
                HStack(spacing: 10) {
                    dualSlider("X", value: $offsetX, range: -1.0...1.0) { _ in applyTransform() }
                    dualSlider("Y", value: $offsetY, range: -1.0...1.0) { _ in applyTransform() }
                }
            }

            ISection(title: nil) {
                sectionHeader("缩放") {
                    Button { lockAspect.toggle(); syncLock() } label: {
                        Image(systemName: lockAspect ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundColor(lockAspect ? Color.accent : Color.labelSecondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    dualSlider("宽", value: $scaleX, range: 0.1...3.0, unit: "%", scale: 100) { v in
                        if lockAspect { scaleY = v }; applyTransform()
                    }
                    dualSlider("高", value: $scaleY, range: 0.1...3.0, unit: "%", scale: 100) { v in
                        if lockAspect { scaleX = v }; applyTransform()
                    }
                }
            }

            ISection(title: nil) {
                sectionHeader("裁剪") {
                    Button { cropTop = 0; cropBottom = 0; cropLeft = 0; cropRight = 0; applyTransform() } label: {
                        Text("重置")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(hasCrop ? .black : Color.labelSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(hasCrop ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(!hasCrop)
                }
                VStack(spacing: 8) {
                    videoCropSlider(label: "上", value: $cropTop, edge: 0)
                    videoCropSlider(label: "下", value: $cropBottom, edge: 1)
                    videoCropSlider(label: "左", value: $cropLeft, edge: 2)
                    videoCropSlider(label: "右", value: $cropRight, edge: 3)
                }
            }
        }
        .onAppear { loadMeta(); syncFromClip() }
        .onChange(of: clip.id) { _ in loadMeta(); syncFromClip() }
        .onChange(of: clip.offsetX)    { v in if abs(v - offsetX) > 0.001 { offsetX = v } }
        .onChange(of: clip.offsetY)    { v in if abs(v - offsetY) > 0.001 { offsetY = v } }
        .onChange(of: clip.scaleX)     { v in if abs(v - scaleX)  > 0.001 { scaleX  = v } }
        .onChange(of: clip.scaleY)     { v in if abs(v - scaleY)  > 0.001 { scaleY  = v } }
        .onChange(of: clip.cropTop)    { v in if abs(v - cropTop)    > 0.001 { cropTop    = v } }
        .onChange(of: clip.cropBottom) { v in if abs(v - cropBottom) > 0.001 { cropBottom = v } }
        .onChange(of: clip.cropLeft)   { v in if abs(v - cropLeft)   > 0.001 { cropLeft   = v } }
        .onChange(of: clip.cropRight)  { v in if abs(v - cropRight)  > 0.001 { cropRight  = v } }
    }

    private var hasOffset: Bool {
        abs(offsetX) > 0.001 || abs(offsetY) > 0.001
    }

    private var hasCrop: Bool {
        cropTop > 0.001 || cropBottom > 0.001 || cropLeft > 0.001 || cropRight > 0.001
    }

    @ViewBuilder
    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
                .tracking(0.2)
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func dualSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                            unit: String = "", scale: Double = 100,
                            onChange: @escaping (Double) -> Void) -> some View {
        ICapsuleSlider(label: label, value: value, range: range,
                       unit: unit, displayScale: scale, labelWidth: 14,
                       onChange: onChange)
    }

    @ViewBuilder
    private func videoCropSlider(label: String, value: Binding<Double>, edge: Int) -> some View {
        ICapsuleSlider(label: label, value: value, range: 0...0.99,
                       unit: "%", displayScale: 100, labelWidth: 14,
                       onChange: { _ in applyTransform() })
    }

    private func syncFromClip() {
        scaleX = clip.scaleX
        scaleY = clip.scaleY
        lockAspect = clip.lockAspect
        offsetX = clip.offsetX
        offsetY = clip.offsetY
        cropTop = clip.cropTop
        cropBottom = clip.cropBottom
        cropLeft = clip.cropLeft
        cropRight = clip.cropRight
        hasPushedUndo = false
    }

    private func syncLock() {
        project.updateVideoClip(id: clip.id) { $0.lockAspect = lockAspect }
    }

    private func applyTransform() {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        project.updateVideoClip(id: clip.id) {
            $0.scaleX = scaleX
            $0.scaleY = scaleY
            $0.lockAspect = lockAspect
            $0.offsetX = offsetX
            $0.offsetY = offsetY
            $0.cropTop = cropTop
            $0.cropBottom = cropBottom
            $0.cropLeft = cropLeft
            $0.cropRight = cropRight
        }
        project.rebuildTimelinePreviewDebounced()
    }

    private func loadMeta() {
        guard let url = clip.url else { return }
        Task {
            let asset = AVURLAsset(url: url)
            if let vt = try? await asset.loadTracks(withMediaType: .video).first {
                let size = try? await vt.load(.naturalSize)
                let fps  = try? await vt.load(.nominalFrameRate)
                let rate = try? await vt.load(.estimatedDataRate)
                let descs = try? await vt.load(.formatDescriptions)
                let codec = descs?.first.flatMap {
                    let ext = CMFormatDescriptionGetExtensions($0 as CMFormatDescription) as? [String: Any]
                    return ext?["FormatName"] as? String
                }
                await MainActor.run {
                    if let s = size { sourceRes = "\(Int(s.width))×\(Int(s.height))" }
                    if let f = fps, f > 0 { sourceFPS = String(format: "%.2f fps", f) }
                    if let r = rate, r > 0 { sourceBitrate = "\(Int(r / 1000)) kbps" }
                    sourceCodec = codec ?? "—"
                }
            }
            // 探测音频轨道（多音轨切换）
            let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if aTracks.count >= 2 {
                var labels: [String] = []
                for (i, at) in aTracks.enumerated() {
                    var label = "音轨 \(i + 1)"
                    // 尝试获取语言标签
                    if let langCode = try? await at.load(.languageCode), !langCode.isEmpty {
                        let locale = Locale(identifier: "zh-Hans")
                        let langName = locale.localizedString(forLanguageCode: langCode) ?? langCode
                        label = "\(langName)"
                    }
                    // 尝试获取编码格式
                    if let descs = try? await at.load(.formatDescriptions), let desc = descs.first {
                        let ext = CMFormatDescriptionGetExtensions(desc as CMFormatDescription) as? [String: Any]
                        if let fmt = ext?["FormatName"] as? String {
                            label += " (\(fmt))"
                        }
                    }
                    labels.append(label)
                }
                await MainActor.run { audioTrackLabels = labels }
            }
        }
    }
}

// MARK: - Transition Inspector

private struct TransitionInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clipID: UUID

    private var transition: Transition? {
        project.videoTracks.flatMap(\.clips).first(where: { $0.id == clipID })?.inTransition
    }

    var body: some View {
        VStack(spacing: 0) {
            if let t = transition {
                ISection(title: "转场效果") {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color.accent)
                        Text(t.type.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.labelPrimary)
                    }
                }
                ISection(title: "时长") {
                    ICapsuleSlider(
                        label: "时长",
                        value: Binding(
                            get: { t.duration },
                            set: { v in
                                project.pushUndoThrottled()
                                project.updateVideoClip(id: clipID) {
                                    $0.inTransition?.duration = max(0.1, min(v, 2.0))
                                }
                                project.rebuildTimelinePreviewDebounced()
                            }
                        ),
                        range: 0.1...2.0,
                        decimals: 1,
                        unit: "秒"
                    )
                }
            } else {
                ISection(title: "转场效果") {
                    Text("未设置转场")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Audio Inspector

private struct AudioInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: AudioClip

    @State private var sourceSampleRate: String = "—"
    @State private var sourceChannels: String = "—"
    @State private var sourceBitrate: String = "—"
    @State private var sourceFormat: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "片段信息") {
                InfoRow(label: "文件名",  value: clip.name)
                InfoRow(label: "时长",    value: fmtDur(clip.duration))
                InfoRow(label: "采样率",  value: sourceSampleRate)
                InfoRow(label: "声道",    value: sourceChannels)
                InfoRow(label: "码率",    value: sourceBitrate)
                InfoRow(label: "格式",    value: sourceFormat)
            }

            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: Binding(
                            get: { clip.startTime },
                            set: { v in
                                let dur = clip.duration
                                project.updateAudioClip(id: clip.id) { $0.startTime = max(0, v); $0.endTime = max(0, v) + dur }
                            }
                        ), step: 0.1, decimals: 2)
                    }
                    IField(label: "持续") {
                        MiniStepper(value: Binding(
                            get: { clip.duration },
                            set: { v in project.updateAudioClip(id: clip.id) { $0.endTime = $0.startTime + max(0.05, v) } }
                        ), step: 0.1, decimals: 2)
                    }
                }
            }

            ISection(title: "音量") {
                ISlider(label: "整体音量", value: dbl(\.volume, scale: 100), range: 0...400, unit: "%")
                ISlider(label: "左声道",  value: dbl(\.leftChannel,  scale: 100), range: 0...100, unit: "%")
                ISlider(label: "右声道",  value: dbl(\.rightChannel, scale: 100), range: 0...100, unit: "%")
            }

            ISection(title: "淡入淡出") {
                HStack(spacing: 12) {
                    Text("淡入")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    Toggle("", isOn: Binding(
                        get: { clip.fadeInEnabled },
                        set: { v in
                            project.updateAudioClip(id: clip.id) { $0.fadeInEnabled = v }
                            project.rebuildTimelinePreview()
                        }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.7, anchor: .leading)
                    .labelsHidden()
                    Spacer()
                }
                if clip.fadeInEnabled {
                    ISlider(label: "淡入时长", value: Binding(
                        get: { ((min(max(0, clip.fadeInDuration), clip.duration) * 10).rounded() / 10) },
                        set: { v in
                            project.updateAudioClip(id: clip.id) {
                                let newIn = (max(0, min(v, $0.duration)) * 10).rounded() / 10
                                $0.fadeInDuration = newIn
                                if $0.fadeOutEnabled, newIn + $0.fadeOutDuration > $0.duration {
                                    $0.fadeOutDuration = ((max(0, $0.duration - newIn)) * 10).rounded() / 10
                                }
                            }
                            project.rebuildTimelinePreviewDebounced()
                        }
                    ), range: 0...max(0.1, clip.duration), unit: "秒", decimals: 1)
                }
                HStack(spacing: 12) {
                    Text("淡出")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 68, alignment: .leading)
                    Toggle("", isOn: Binding(
                        get: { clip.fadeOutEnabled },
                        set: { v in
                            project.updateAudioClip(id: clip.id) { $0.fadeOutEnabled = v }
                            project.rebuildTimelinePreview()
                        }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.7, anchor: .leading)
                    .labelsHidden()
                    Spacer()
                }
                if clip.fadeOutEnabled {
                    ISlider(label: "淡出时长", value: Binding(
                        get: { ((min(max(0, clip.fadeOutDuration), clip.duration) * 10).rounded() / 10) },
                        set: { v in
                            project.updateAudioClip(id: clip.id) {
                                let newOut = (max(0, min(v, $0.duration)) * 10).rounded() / 10
                                $0.fadeOutDuration = newOut
                                if $0.fadeInEnabled, $0.fadeInDuration + newOut > $0.duration {
                                    $0.fadeInDuration = ((max(0, $0.duration - newOut)) * 10).rounded() / 10
                                }
                            }
                            project.rebuildTimelinePreviewDebounced()
                        }
                    ), range: 0...max(0.1, clip.duration), unit: "秒", decimals: 1)
                }
            }
        }
        .onAppear { loadMeta() }
        .onChange(of: clip.id) { _ in loadMeta() }
    }

    private func loadMeta() {
        guard let url = clip.url else { return }
        Task {
            let asset = AVURLAsset(url: url)
            if let at = try? await asset.loadTracks(withMediaType: .audio).first {
                let rate = try? await at.load(.estimatedDataRate)
                let descs = try? await at.load(.formatDescriptions)
                if let desc = descs?.first {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc as CMAudioFormatDescription)
                    await MainActor.run {
                        if let a = asbd?.pointee {
                            sourceSampleRate = "\(Int(a.mSampleRate)) Hz"
                            sourceChannels = a.mChannelsPerFrame == 1 ? "单声道" : (a.mChannelsPerFrame == 2 ? "立体声" : "\(a.mChannelsPerFrame) 声道")
                        }
                        if let r = rate, r > 0 { sourceBitrate = "\(Int(r / 1000)) kbps" }
                        let ext = CMFormatDescriptionGetExtensions(desc as CMFormatDescription) as? [String: Any]
                        sourceFormat = (ext?["FormatName"] as? String) ?? url.pathExtension.uppercased()
                    }
                }
            }
        }
    }

    private func dbl(_ kp: WritableKeyPath<AudioClip, Float>, scale: Double) -> Binding<Double> {
        Binding(
            get: { Double(clip[keyPath: kp]) * scale },
            set: { v in
                project.updateAudioClip(id: clip.id) { $0[keyPath: kp] = Float(v/scale) }
                project.rebuildTimelinePreview()
            }
        )
    }
}

// MARK: - Shared layout components

struct ISection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                    .tracking(0.2)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IDivider: View {
    var body: some View { Divider().background(Color.divider) }
}

struct IField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slider track starts at this x-offset (within the section content area):
///   labelW (76) + leading spacing (12) = 88
private let kSliderTrackLeading: CGFloat = 88

struct ISlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var decimals: Int = 0

    var body: some View {
        ICapsuleSlider(label: label, value: $value, range: range,
                       decimals: decimals, unit: unit, labelWidth: 64)
    }
}

/// 胶囊式滑块：标签(左) + 滑块 + 可编辑数值(右)，整体浅色圆角胶囊。
/// 参考 Sketch 属性面板：滑块与数值并存，可拖动也可点击数值直接输入。
struct ICapsuleSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals: Int = 0
    var unit: String = ""
    var displayScale: Double = 1    // 显示值 = value × displayScale（如 offset -1...1 显示为 -100...100）
    var labelWidth: CGFloat = 18
    var onChange: ((Double) -> Void)? = nil
    // (reserved for future use)

    @State private var editText: String = ""
    @State private var dragging = false
    @FocusState private var focused: Bool

    private var disp: Double { value * displayScale }
    private var fmt: String {
        decimals > 0 ? String(format: "%.\(decimals)f", disp) : "\(Int(disp.rounded()))"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
            CustomSlider(value: $value, range: range, onDragging: { d in
                dragging = d
            })
            HStack(spacing: 1) {
                TextField("", text: $editText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color.labelPrimary)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(width: 30)
                    .onAppear { editText = fmt }
                    .onChange(of: value) { v in if !focused { editText = fmt }; if dragging { onChange?(v) } }
                    .onSubmit { commit() }
                    .onChange(of: focused) { _ in if !focused { commit() } }
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(0.06))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Color.accent : Color.white.opacity(0.08),
                        lineWidth: focused ? 1 : 0.5)
        )
    }

    private func commit() {
        if let v = Double(editText) {
            value = (v / displayScale).clamped(to: range)
            onChange?(value)
        }
        editText = fmt
    }
}

struct InfoRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(Color.labelSecondary)
            Spacer()
            Text(value).font(.system(size: 10)).foregroundColor(Color.labelPrimary).lineLimit(1)
        }
    }
}

private struct ActionBtn: View {
    let label: String; let primary: Bool; let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(primary ? .black : Color.labelPrimary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(primary
                    ? (hov ? Color.accent.opacity(0.8) : Color.accent)
                    : Color.white.opacity(hov ? 0.12 : 0.07))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }
}

// MARK: - CustomSlider（自绘滑块，替代 macOS Slider 解决精度问题）

/// 完全自绘的滑块：轨道 + 填充 + 圆形 thumb + 拖拽手势。
/// 拖到最左精确等于 range.lowerBound，最右精确等于 range.upperBound，
/// 无 macOS Slider 的像素精度、刻度线、最小值跳变等问题。
struct CustomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onDragging: ((Bool) -> Void)? = nil

    private let trackH: CGFloat = 4
    private let thumbR: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let fillW = frac * w   // 填充宽度（0 ~ w）

            ZStack(alignment: .leading) {
                // 轨道背景
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: trackH)

                // 已填充
                if fillW > 0.5 {
                    Capsule()
                        .fill(Color.accent)
                        .frame(width: fillW, height: trackH)
                }

                // Thumb（中心在 fillW 位置，钳制在 thumbR...w-thumbR 之间）
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: thumbR * 2, height: thumbR * 2)
                    .position(x: max(thumbR, min(fillW, w - thumbR)),
                              y: geo.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onDragging?(true)
                        // 直接映射：鼠标 x / 轨道宽度 = 比例 → 值。最左=0，最右=最大
                        let newFrac = max(0, min(1, Double(v.location.x / w)))
                        value = (range.lowerBound + newFrac * span).clamped(to: range)
                    }
                    .onEnded { _ in
                        onDragging?(false)
                    }
            )
        }
        .frame(height: thumbR * 2 + 4)
    }
}

// MARK: - MiniStepper (compact, no SwiftUI Stepper)

struct MiniStepper: View {
    @Binding var value: Double
    var step: Double = 1
    var decimals: Int = 0
    var minValue: Double = 0
    var maxValue: Double = .infinity

    @State private var editText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $editText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Color.labelPrimary)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.leading, 6)
                .focused($isFocused)
                .onAppear { editText = formatted }
                .onChange(of: value) { _ in editText = formatted }
                .onSubmit { applyText() }
                .onChange(of: isFocused) { _ in if !isFocused { applyText() } }

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)

            VStack(spacing: 0) {
                Button { value = min(maxValue, value + step) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 18, height: 1)

                Button { value = max(minValue, value - step) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.trailing, 1)
        }
        .frame(height: 26)
        .background(Color.white.opacity(0.08))
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isFocused ? Color.accent : Color.white.opacity(0.10)))
    }

    private var formatted: String {
        decimals > 0 ? String(format: "%.\(decimals)f", value) : "\(Int(value))"
    }

    private func applyText() {
        if let v = Double(editText) {
            value = max(minValue, min(maxValue, v))
        }
        editText = formatted
    }
}

// MARK: - IPicker (full-width custom dropdown — Button + NSMenu popup)

struct IPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @State private var hov = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? ""
    }

    private func showMenu() {
        let menu = NSMenu()
        IPickerItemHandler.shared.actions.removeAll()
        for (i, (_, label)) in options.enumerated() {
            let item = NSMenuItem(title: label,
                                  action: #selector(IPickerItemHandler.pick(_:)),
                                  keyEquivalent: "")
            item.target = IPickerItemHandler.shared
            item.tag = i
            IPickerItemHandler.shared.actions[i] = { selection = options[i].0 }
            if options[i].0 == selection { item.state = .on }
            menu.addItem(item)
        }
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }
}

/// Singleton target/action handler for IPicker's NSMenu items.
final class IPickerItemHandler: NSObject {
    static let shared = IPickerItemHandler()
    var actions: [Int: () -> Void] = [:]
    @objc func pick(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

// MARK: - SubtitleTextBox

private struct SubtitleTextBox: View {
    @Binding var text: String
    let clipID: UUID
    @EnvironmentObject private var project: ProjectState
    @FocusState private var isFocused: Bool
    @State private var boxHeight: CGFloat = 72
    @State private var isDragging = false

    private let minH: CGFloat = 48
    private let maxH: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("输入字幕内容…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.labelSecondary.opacity(0.4))
                        .padding(.top, 8).padding(.leading, 6)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .focused($isFocused)
                    .onChange(of: text) { _ in project.updateSubtitleText(id: clipID, text: text) }
            }
            .frame(height: boxHeight)

            // Drag handle
            HStack {
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color.labelSecondary.opacity(0.4))
                    .frame(width: 20, height: 10)
            }
            .padding(.trailing, 4)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { val in
                        if !isDragging { isDragging = true }
                        let newH = boxHeight + val.translation.height
                        boxHeight = min(maxH, max(minH, newH))
                    }
                    .onEnded { val in
                        isDragging = false
                        let newH = boxHeight + val.translation.height
                        boxHeight = min(maxH, max(minH, newH))
                    }
            )
            .cursor(.resizeUpDown)
        }
        .background(Color.white.opacity(0.08))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isFocused ? Color.accent : Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Helpers

private func fmtDur(_ t: Double) -> String {
    let m = Int(t)/60%60; let s = Int(t)%60; let ms = Int((t-Double(Int(t)))*1000)
    return String(format: "%02d:%02d.%03d", m, s, ms)
}
