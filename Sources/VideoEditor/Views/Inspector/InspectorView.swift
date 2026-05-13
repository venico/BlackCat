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
                if let clip = project.selectedSubtitleClip {
                    SubtitleInspector(clip: clip)
                } else if let clip = project.selectedVideoClip {
                    VideoInspector(clip: clip)
                } else if let clip = project.selectedAudioClip {
                    AudioInspector(clip: clip)
                } else {
                    EmptyInspector()
                }
            }
        }
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
        if project.selectedSubtitleClipID != nil { return "字幕片段" }
        if project.selectedVideoClipID    != nil { return "视频片段" }
        if project.selectedAudioClipID    != nil { return "音频片段" }
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

    private var trackIndex: Int {
        for (i, t) in project.subtitleTracks.enumerated() {
            if t.clips.contains(where: { $0.id == clip.id }) { return i }
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 时间 ──────────────────────────────────────
            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: $startTime, step: 0.1, decimals: 2)
                            .onChange(of: startTime) { project.updateSubtitleTime(id: clip.id, start: startTime) }
                    }
                    IField(label: "持续") {
                        MiniStepper(
                            value: Binding(
                                get: { max(endTime - startTime, 0) },
                                set: { endTime = startTime + max($0, 0.05) }
                            ),
                            step: 0.1, decimals: 2
                        )
                        .onChange(of: endTime) { project.updateSubtitleTime(id: clip.id, end: endTime) }
                    }
                }
            }

            // ── 字幕文字 ──────────────────────────────────
            ISection(title: "字幕文字") {
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
                        .onChange(of: text) { project.updateSubtitleText(id: clip.id, text: text) }
                }
                .frame(minHeight: 72, maxHeight: 100)
                .background(Color.white.opacity(0.05))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.10)))
            }

            // ── 字体 ──────────────────────────────────────
            ISection(title: "字体") {
                HStack(alignment: .bottom, spacing: 8) {
                    IField(label: "字体") {
                        IPicker(selection: $ls.fontName,
                                options: ["PingFang SC","思源黑体","Helvetica Neue","Arial","Times New Roman"].map { ($0, $0) })
                            .onChange(of: ls.fontName) { writeStyle() }
                    }
                    IField(label: "字号") {
                        MiniStepper(value: Binding(
                            get: { Double(ls.fontSize) },
                            set: { ls.fontSize = CGFloat($0) }
                        ), step: 1, decimals: 0)
                        .onChange(of: ls.fontSize) { writeStyle() }
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
                        .frame(width: 76, alignment: .leading)
                    ColorPicker("", selection: $ls.textColor).labelsHidden()
                        .onChange(of: ls.textColor) { writeStyle() }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Text("背景颜色")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 76, alignment: .leading)
                    ColorPicker("", selection: $ls.backgroundColor).labelsHidden()
                        .onChange(of: ls.backgroundColor) { writeStyle() }
                    Spacer(minLength: 0)
                }

                ISlider(label: "背景不透明度",
                        value: Binding(get:{ls.backgroundOpacity*100}, set:{ls.backgroundOpacity=$0/100}),
                        range: 0...100, unit: "%")
                    .onChange(of: ls.backgroundOpacity) { writeStyle() }
            }

            // ── 布局 ──────────────────────────────────────
            ISection(title: "布局") {
                ISlider(label: "字幕宽度",  value: $ls.widthPercent,  range: 30...100, unit: "%")
                    .onChange(of: ls.widthPercent)  { writeStyle() }
                ISlider(label: "距下边缘",  value: $ls.bottomMargin,  range: 0...50,   unit: "%")
                    .onChange(of: ls.bottomMargin)  { writeStyle() }
                ISlider(label: "双语间距",  value: $ls.lineSpacing,   range: 0...60,   unit: "pt")
                    .onChange(of: ls.lineSpacing)   { writeStyle() }

                HStack(spacing: 12) {
                    Text("对齐方式")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 76, alignment: .leading)
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
        .onChange(of: clip.id) { syncAll() }
    }

    // MARK: Helpers

    private func syncAll() {
        text = clip.text; startTime = clip.startTime; endTime = clip.endTime
        let i = trackIndex
        if project.subtitleStyles.indices.contains(i) { ls = project.subtitleStyles[i] }
    }

    private func writeStyle() {
        let i = trackIndex
        guard project.subtitleStyles.indices.contains(i) else { return }
        project.subtitleStyles[i] = ls
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
        let targetBase = String(targetCode.split(separator: "-").first ?? Substring(targetCode))

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
            let lang = recognizer.dominantLanguage?.rawValue ?? ""
            let base = String(lang.split(separator: "-").first ?? Substring(lang))
            if base == targetBase { targetLines.append(line) }
            else                   { otherLines.append(line) }
        }

        if !targetLines.isEmpty {
            // Already contains target-language line(s) — keep those, drop the rest.
            return targetLines.joined(separator: "\n")
        }

        // No target-language line — translate everything.
        var translated: [String] = []
        for line in otherLines {
            translated.append(await translate(line, to: targetLang))
        }
        return translated.joined(separator: "\n")
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

private struct VideoInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: VideoClip

    @State private var sourceRes: String = "—"
    @State private var sourceFPS: String = "—"
    @State private var sourceBitrate: String = "—"
    @State private var sourceCodec: String = "—"

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
                ), range: 0...200, unit: "%")
            }
        }
        .onAppear { loadMeta() }
        .onChange(of: clip.id) { loadMeta() }
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
        }
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
                ISlider(label: "整体音量", value: dbl(\.volume, scale: 100), range: 0...200, unit: "%")
                ISlider(label: "左声道",  value: dbl(\.leftChannel,  scale: 100), range: 0...100, unit: "%")
                ISlider(label: "右声道",  value: dbl(\.rightChannel, scale: 100), range: 0...100, unit: "%")
            }
        }
        .onAppear { loadMeta() }
        .onChange(of: clip.id) { loadMeta() }
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
        VStack(alignment: .leading, spacing: 14) {
            if let t = title {
                Text(t)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                    .tracking(0.4)
                    .textCase(.uppercase)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 3) {
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

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 76, alignment: .leading)
            Slider(value: $value, in: range).accentColor(Color.accent)
            Text("\(Int(value))\(unit)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Color.labelSecondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

struct InfoRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(Color.labelSecondary)
            Spacer()
            Text(value).font(.system(size: 11)).foregroundColor(Color.labelPrimary).lineLimit(1)
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

// MARK: - MiniStepper (compact, no SwiftUI Stepper)

struct MiniStepper: View {
    @Binding var value: Double
    var step: Double = 1
    var decimals: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            Text(formatted)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Color.labelPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 6)

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)

            VStack(spacing: 0) {
                Button { value += step } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 18, height: 12)
                }.buttonStyle(.plain)

                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 18, height: 1)

                Button { value = max(0, value - step) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 18, height: 12)
                }.buttonStyle(.plain)
            }
            .padding(.trailing, 1)
        }
        .frame(height: 26)
        .background(Color.white.opacity(0.06))
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.10)))
    }

    private var formatted: String {
        decimals > 0 ? String(format: "%.\(decimals)f", value) : "\(Int(value))"
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

// MARK: - Helpers

private func fmtDur(_ t: Double) -> String {
    let m = Int(t)/60%60; let s = Int(t)%60; let ms = Int((t-Double(Int(t)))*1000)
    return String(format: "%02d:%02d.%03d", m, s, ms)
}
