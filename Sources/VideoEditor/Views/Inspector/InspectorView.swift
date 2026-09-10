import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import NaturalLanguage
import CryptoKit
#if canImport(Translation)
import Translation
#endif

enum TransformIconType { case mirrorH, mirrorV, rotate, reverse }

// MARK: - Root

struct InspectorView: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
              ScrollView(showsIndicators: false) {
                // 统一给所有属性面板留出底部间距，各 Inspector 不必各自处理
                Group {
                    // 多选优先：只放三种元素都有、一起调有意义的那几项
                    if project.selectedClipIDs.count > 1, !multiLayers.isEmpty {
                        MultiSelectInspector(
                            layers: multiLayers,
                            canvasSize: project.previewRenderSize,
                            onAlign: { mode in
                                if let first = multiLayers.first {
                                    project.alignLayers(mode, anchorID: first.id)
                                }
                            },
                            onDelete: { project.deleteSelected() },
                            onBeforeChange: { project.pushUndoThrottled() }
                        )
                    } else if let clip = project.selectedAdjustClip {
                        AdjustInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedEffectClip {
                        EffectInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedFilterClip {
                        FilterInspector(clip: clip).id(clip.id)
                    } else if let transID = project.selectedTransitionClipID {
                        TransitionInspector(clipID: transID)
                    } else if let clip = project.selectedTextClip {
                        TextInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedShapeClip {
                        ShapeInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedSubtitleClip {
                        SubtitleInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedImageClip {
                        ImageInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedVideoClip {
                        VideoInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedAudioClip {
                        AudioInspector(clip: clip).id(clip.id)
                    } else if let clip = project.selectedCompoundClip {
                        CompoundInspector(clip: clip).id(clip.id)
                    } else {
                        // 未选中任何片段时显示整个项目的设置
                        ProjectInspector()
                    }
                }
                .padding(.bottom, 16)
                // **宽度写死成容器宽度**，不让 ScrollView 自己推断。
                // alignment 必须给 leading：不给的话默认居中，内容一旦比容器宽
                // 就往两边溢出，左边那一列（按钮、滑块标签）直接被裁掉
                .frame(width: geo.size.width, alignment: .leading)
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

    /// 头部：左边是当前选中的东西叫什么，右边是删除。跟封面弹窗那套一致，
    /// 各面板底部原来那个大红删除按钮就不用了
    private var header: some View {
        HStack {
            Text(tag)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
            Spacer()
            if let del = deleteAction {
                Button(action: del) {
                    Image(nsImage: TimelineSVGIcon.load("delete"))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundColor(Color.labelSecondary)
                        // 图标贴右，才跟下面滑块行的右边缘齐
                        .frame(width: 24, height: 24, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除")
            }
        }
        // **边距不自己写死**：跟下面每一组内容走同一个容器的同一份内边距，
        // 各写各的迟早会差那么一两个点，肉眼还真看得出来
        .padding(.horizontal, ISectionMetrics.hPadding)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }

    /// 多选里那些能一起调的图层。视频、音频、字幕不参与
    private var multiLayers: [MultiLayerHandle] { project.multiLayerHandles() }

    private var tag: String {
        if project.selectedClipIDs.count > 1 { return "已选 \(project.selectedClipIDs.count) 个" }
        if project.selectedAdjustClipID != nil { return "调节" }
        if project.selectedEffectClipID != nil { return "特效" }
        if project.selectedFilterClipID != nil { return "滤镜" }
        if project.selectedTransitionClipID != nil { return "转场" }
        if project.selectedTextClipID       != nil { return "文字" }
        if project.selectedShapeClipID      != nil { return "图形" }
        if project.selectedSubtitleClipID   != nil { return "字幕" }
        if project.selectedImageClipID      != nil { return "图片" }
        if project.selectedVideoClipID      != nil { return "视频" }
        if project.selectedAudioClipID      != nil { return "音频" }
        if project.selectedCompoundClipID   != nil { return "复合片段" }
        return "项目"
    }

    /// 当前该删谁。项目设置那一档没有删除，返回 nil 就不画图标
    private var deleteAction: (() -> Void)? {
        // 除了文字和图形有各自的删除，其余（含多选）都走时间轴那个统一入口
        if project.selectedClipIDs.count > 1 { return { project.deleteSelected() } }
        if let id = project.selectedAdjustClipID { return { project.deleteAdjustClip(id: id) } }
        if let id = project.selectedEffectClipID { return { project.deleteEffectClip(id: id) } }
        if let id = project.selectedFilterClipID { return { project.deleteFilterClip(id: id) } }
        if let id = project.selectedTextClipID { return { project.deleteTextClip(id: id) } }
        if let id = project.selectedShapeClipID { return { project.deleteShapeClip(id: id) } }
        if project.selectedImageClipID != nil || project.selectedVideoClipID != nil
            || project.selectedAudioClipID != nil || project.selectedSubtitleClipID != nil
            || project.selectedCompoundClipID != nil {
            return { project.deleteSelected() }
        }
        return nil
    }
}

// MARK: - Compound

private struct CompoundInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: CompoundClip
    @State private var editName: String = ""

    private var trackSummary: String {
        var parts: [String] = []
        if !clip.videoTracks.isEmpty    { parts.append("视频 \(clip.videoTracks.flatMap(\.clips).count)") }
        if !clip.audioTracks.isEmpty    { parts.append("音频 \(clip.audioTracks.flatMap(\.clips).count)") }
        if !clip.imageTracks.isEmpty    { parts.append("图片 \(clip.imageTracks.flatMap(\.clips).count)") }
        if !clip.subtitleTracks.isEmpty { parts.append("字幕 \(clip.subtitleTracks.flatMap(\.clips).count)") }
        if !clip.textTracks.isEmpty     { parts.append("文字 \(clip.textTracks.flatMap(\.clips).count)") }
        if !clip.shapeTracks.isEmpty    { parts.append("图形 \(clip.shapeTracks.flatMap(\.clips).count)") }
        return parts.isEmpty ? "空" : parts.joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "片段信息") {
                HStack {
                    Text("名称").font(.system(size: 10)).foregroundColor(Color.labelSecondary)
                    Spacer()
                    TextField("", text: $editName, onCommit: {
                        project.updateCompoundClip(id: clip.id) { $0.name = editName }
                    })
                    .font(.system(size: 10))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
                }
                InfoRow(label: "时长", value: String(format: "%.1f 秒", clip.duration))
                InfoRow(label: "内容", value: trackSummary)
            }
            ISection(title: nil) {
                Button {
                    guard let ti = project.compoundTracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }),
                          let ci = project.compoundTracks[ti].clips.firstIndex(where: { $0.id == clip.id })
                    else { return }
                    project.enterCompound(trackIndex: ti, clipIndex: ci)
                } label: {
                    HStack {
                        Image(nsImage: SidebarSVGIcon.load("compound"))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                        Text("进入编辑")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color(hex: "#FF9F43").opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, ISectionMetrics.hPadding)
        .onAppear { editName = clip.name }
        .onChange(of: clip.id) { _ in editName = clip.name }
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
                        .inspectorSwitch(anchor: .leading)
                        .onChange(of: ls.mergeLineBreaks) { _ in writeStyle() }
                    Spacer()
                }
            }

            // ── 字体 ──────────────────────────────────────
            ISection(title: "字体") {
                HStack(alignment: .bottom, spacing: 8) {
                    IField(label: "字体") {
                        IPicker(selection: $ls.fontName,
                                options: FontHelper.fontOptions)
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
                IFieldRow(label: "文字颜色") {
                    ColorPicker("", selection: $ls.textColor).inspectorColorWell()
                        .onChange(of: ls.textColor) { _ in writeStyle() }
                }
                IFieldRow(label: "背景颜色") {
                    ColorPicker("", selection: $ls.backgroundColor).inspectorColorWell()
                        .onChange(of: ls.backgroundColor) { _ in writeStyle() }
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
                        ForEach([("alignLeft","left"),("alignVCenter","center"),("alignRight","right")], id:\.1) { svg, val in
                            Button { ls.alignment = val; writeStyle() } label: {
                                Image(nsImage: SidebarSVGIcon.load(svg))
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(ls.alignment == val ? Color.accent : Color.labelSecondary)
                                    .frame(width: 30, height: 26)
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

/// 翻译失败的原因回传。
///
/// 各引擎失败时一律"返回原文"（不这么做的话一批里坏一条就整批丢），
/// 上层只能看到"结果==原文"，于是不管什么原因都笼统报「可能被限流」——
/// Apple 缺语言包、DeepL 拒收目标语言、有道签名错，全被抹成同一句话。
/// 这里留个通道把真实原因带上去。
@MainActor
enum TranslateDiagnostics {
    /// 本轮翻译中最后一次失败的可读原因。开始翻译前清空
    static var lastFailureHint: String?
    static func reset() { lastFailureHint = nil }
    static func record(_ hint: String) { lastFailureHint = hint }
}

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
    /// 这段文字是不是已经是目标语言了。
    ///
    /// 调用方据此**提前退出**：不建翻译轨、不亮进度卡片、也不占一次撤销栈 ——
    /// 光在 translate 里挡住网络请求不够，那时轨道和占位都已经建好了
    /// 目标语言是不是中文（简繁都算）。简繁之间最容易被引擎静默降级，
    /// 译文语言校验只在这个范围内做，别的语言不碰，免得误伤
    /// 按引擎给并发上限。DeepL 免费版限流很严 —— 实测 4 路并发整轨翻译直接一片 429
    /// （返回原文，看起来像"翻出来还是原文/简中"），压到 1 路串行
    static var recommendedConcurrency: Int {
        // DeepL 走真批量后请求数已经很少，2 路足够快又不至于撞限流；
        // 其余引擎维持 4 路
        AppSettings.shared.translateProvider == .deepL ? 2 : 4
    }

    static func isChineseTarget(_ lang: String) -> Bool {
        lang == "中文（简体）" || lang == "中文（繁体）"
    }

    /// 这段文字是不是中文（简繁不限）。
    ///
    /// 不走 NLLanguageRecognizer：字幕大量是三五个字的短句，短文本上它很不稳。
    /// 改成数字形——先用假名/谚文把日文韩文排掉（它们也含汉字），再看汉字在字母里的占比。
    /// 有没有汉字。判「翻没翻成中文」用它，别用占比 —— 夹个英文品牌名占比就过不了线
    static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)      // CJK 基本区
            || (0x3400...0x4DBF).contains($0.value)   // 扩展 A
            || (0xF900...0xFAFF).contains($0.value)   // 兼容汉字
        }
    }

    static func isChineseText(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var han = 0, letters = 0
        for u in trimmed.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF,          // 平假名 / 片假名
                 0xAC00...0xD7AF,          // 谚文音节
                 0x1100...0x11FF:          // 谚文字母
                return false
            case 0x4E00...0x9FFF,          // CJK 基本区
                 0x3400...0x4DBF,          // 扩展 A
                 0xF900...0xFAFF,          // 兼容汉字
                 0x20000...0x2FA1F:        // 扩展 B~F
                han += 1; letters += 1
            default:
                if u.properties.isAlphabetic { letters += 1 }
            }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) >= 0.5
    }

    /// 整批文本的主语言（多数决），拿不准返回 nil。
    ///
    /// 逐条检测在字幕这种短句上很不稳 —— 实测一条英文字幕被判成**土耳其语**，
    /// 而 Apple 的 `installedSource:` 要求那对语言包已装好，于是整轨翻完
    /// 孤零零剩一条没翻、还提示"缺少语言包"。字幕整轨本来就是同一种语言，
    /// 按整批投票定一次，个别短句的误判就被淹掉了。
    static func dominantLanguage(of texts: [String]) -> String? {
        var votes: [String: Int] = [:]
        let recognizer = NLLanguageRecognizer()
        for t in texts {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }   // 太短的不投票
            recognizer.reset()
            recognizer.processString(trimmed)
            guard let lang = recognizer.dominantLanguage?.rawValue else { continue }
            votes[lang, default: 0] += 1
        }
        return votes.max { $0.value < $1.value }?.key
    }

    /// 中文内部的简繁转换 —— 能本地转就返回结果，转不了返回 nil（该走翻译引擎）。
    ///
    /// **简繁互转不是翻译，是字形转换**，本来就不该花 API 额度：
    /// 各家对 zh-Hant 的支持还参差不齐 —— DeepL 收下 `ZH-HANT` 照样回简体、
    /// 免费版翻十来条就 429；Apple 要用户另外去系统里下繁中语言包；
    /// 有道 `from=auto` 是中英互译逻辑，压根不看 `to`。
    /// 本地转一次是瞬时的，不限流、不耗额度，词组准确度还比 API 高。
    static func localChineseConvert(_ text: String, to lang: String) -> String? {
        guard isChineseTarget(lang), isChineseText(text) else { return nil }
        return lang == "中文（繁体）" ? OpenCC.toTraditional(text) : OpenCC.toSimplified(text)
    }

    /// 送给翻译引擎的目标语言。
    ///
    /// 目标是繁中时一律改成简中 —— 简中是每家引擎都稳的，繁体最后本地转
    /// （见 `localChineseConvert`）。这样"翻不出繁体"这条失败路径整个消失。
    static func engineLanguage(for lang: String) -> String {
        lang == "中文（繁体）" ? "中文（简体）" : lang
    }

    static func isAlreadyTarget(_ text: String, lang: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // 太短的识别不可靠：一条 "OK"、纯数字、单个专有名词都会被判成英文，
        // 一条就足以把整轨拖进翻译流程。这类本来也不值得翻，当作"已是目标语言"
        guard trimmed.count >= 4 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let detected = recognizer.dominantLanguage?.rawValue else { return true }
        return isExactMatch(detected: detected, target: languageCode(lang))
    }

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

    /// 翻译一段文本，失败会退避重试。
    ///
    /// 各家引擎的失败路径清一色是「返回原文」（网络错、解析失败、被限流，
    /// 表现完全一样），所以只能拿「结果跟原文一模一样」当失败信号。
    /// 批量翻几百条时 Google 的免费接口必然限流，不重试的话后半段原样返回，
    /// 界面上还显示"翻译完成"——用户看到的就是"只翻译了前面一部分"。
    ///
    /// 误判的代价可以接受：本来就翻不动的内容（纯数字、专名）无非多发两次请求，
    /// 而 translateSmart 已经把「本来就是目标语言」的行挑走了，不会走到这儿。
    ///
    /// - Parameter sourceHint: 整批算出来的源语言。只有 Apple 用得上（它要求显式指定
    ///   源语言），批量翻译时由 `translateBatch` 投票产生，见 `dominantLanguage(of:)`
    static func translate(_ text: String, to lang: String, sourceHint: String? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // 中文之间只是简繁差异 —— 本地转完就走，一个请求都不发。
        // 要排在 isAlreadyTarget 前面：那个函数对 4 字以下一律返回"已是目标"，
        // 排在后面的话一整轨短句会原样留在简体
        if let converted = localChineseConvert(text, to: lang) { return converted }

        // 原文已经是目标语言就别送去翻 —— 各家引擎在"源=目标"时行为不一致，
        // 有的会**擅自翻成英文**：
        //
        // - **有道**（实测踩到）：请求带 `from=auto`，它的 auto 是中英互译逻辑，
        //   检测到中文就翻英文，不管 `to=zh-CHS`。中文字幕选简中，翻出来整条是英文
        // - **Apple**：`TranslationSession(installedSource:target:)` 两边相同时行为未定义
        // - **Google**：规矩地返回原文，但下面的重试会把"结果==原文"当成失败，
        //   白白重试 3 次、发 3 个请求
        //
        // 统一在这里挡掉，各引擎行为一致：已经是目标语言就原样返回
        if isAlreadyTarget(text, lang: lang) { return text }

        let engineLang = engineLanguage(for: lang)

        var delay: UInt64 = 400_000_000   // 0.4s 起步，每次翻倍
        for attempt in 1...3 {
            let result = await translateOnce(text, to: engineLang, sourceHint: sourceHint)
            if result != text {
                // 校验译文**确实是目标语言**：有的引擎会静默降级，
                // 既没报错也没翻对，用户拿到一条"翻译过却还是原文语言的轨"。
                // 只在中文目标上校验（这是已知会降级的场景），太短的不查
                // 判「引擎没按目标语言翻」的标准要**宽**：译文里只要出现汉字就算翻了。
                //
                // 原来拿 `isAlreadyTarget`（按主导语言判）来卡，夹着英文专有名词的
                // 短句必然中招 —— 「It's an iPhone.」翻成「这是一部 iPhone。」，
                // 汉字只占四成，被判成英语，于是误报「该引擎不支持这个目标语言」，
                // 好好的译文被丢掉退回原文。
                // 真没翻的样子只有两种：一个汉字都没有，或者原样退回来
                if isChineseTarget(engineLang), result.count >= 4,
                   !containsHan(result) || result == text {
                    DiagLog.log("[翻译] 引擎未按目标语言返回 目标=\(engineLang)，译文=\(result.prefix(30))")
                    await TranslateDiagnostics.record("该引擎不支持这个目标语言，请换一个翻译引擎")
                    return text
                }
                // 目标是繁中的话，引擎给的是简中，最后本地补一步字形转换
                return engineLang == lang ? result : OpenCC.toTraditional(result)
            }
            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
        return text
    }

    private static func translateOnce(_ text: String, to lang: String,
                                      sourceHint: String? = nil) async -> String {
        switch AppSettings.shared.translateProvider {
        case .google:   return await translateGoogle(text, to: lang)
        case .deepL:    return await translateDeepL(text, to: lang)
        // 只有 Apple 要显式源语言，其余几家都是 auto
        case .apple:    return await translateApple(text, to: lang, sourceHint: sourceHint)
        case .youdao:   return await translateYoudao(text, to: lang)
        case .volcano:  return await translateVolcano(text, to: lang)
        }
    }

    // MARK: - Google 翻译

    private static func translateGoogle(_ text: String, to lang: String) async -> String {
        let code = languageCode(lang)
        guard let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(code)&dt=t&q=\(q)")
        else { return text }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let segs = outer.first as? [Any] else { return text }
            let parts: [String] = segs.compactMap {
                guard let arr = $0 as? [Any], let s = arr.first as? String else { return nil }
                return s
            }
            let joined = parts.joined()
            return joined.isEmpty ? text : joined
        } catch {
            DiagLog.log("[翻译] Google 请求失败 目标=\(code)：\(error.localizedDescription)")
            return text
        }
    }

    // MARK: - DeepL 翻译

    /// DeepL 的**真批量**：一次请求带多条 text，返回等长的 translations。
    ///
    /// 之前是逐条发（batchSize 只是把多条拼成一个长字符串再当成一条发），
    /// 整轨几十条就是几十个请求，DeepL 免费版直接一片 429 —— 返回原文，
    /// 表现成"翻出来还是原文"。改成一次发一批后请求数少一个数量级。
    /// - Returns: 失败返回 nil，让调用方回退到逐条路径
    static func translateDeepLBatch(_ texts: [String], to lang: String) async -> [String]? {
        let key = AppSettings.shared.deeplAPIKey
        guard !key.isEmpty, !texts.isEmpty else { return nil }
        let targetCode = deeplLanguageCode(lang)
        let base = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        guard let url = URL(string: "\(base)/v2/translate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["text": texts, "target_lang": targetCode])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                DiagLog.log("[翻译] DeepL 批量 HTTP \(http.statusCode) \(texts.count) 条 目标=\(targetCode)："
                            + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
                let hint: String
                switch http.statusCode {
                case 429: hint = "DeepL 请求过于频繁被限流，稍后再试"
                case 456: hint = "DeepL 本月额度用尽"
                case 400: hint = "DeepL 不支持该目标语言"
                case 401, 403: hint = "DeepL API Key 无效"
                default:  hint = "DeepL 拒绝了请求（HTTP \(http.statusCode)）"
                }
                await TranslateDiagnostics.record(hint)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["translations"] as? [[String: Any]] else { return nil }
            let out = arr.compactMap { $0["text"] as? String }
            // 条数对不上就别用，交给逐条路径，免得整批错位
            guard out.count == texts.count else {
                DiagLog.log("[翻译] DeepL 批量条数不符：发 \(texts.count) 回 \(out.count)")
                return nil
            }
            return out
        } catch {
            DiagLog.log("[翻译] DeepL 批量请求失败 目标=\(targetCode)：\(error.localizedDescription)")
            return nil
        }
    }

    private static func translateDeepL(_ text: String, to lang: String) async -> String {
        let key = AppSettings.shared.deeplAPIKey
        guard !key.isEmpty else { return text }
        let targetCode = deeplLanguageCode(lang)
        let base = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        guard let url = URL(string: "\(base)/v2/translate") else { return text }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": [text], "target_lang": targetCode])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                DiagLog.log("[翻译] DeepL HTTP \(http.statusCode) 目标=\(targetCode)："
                            + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
                let hint: String
                switch http.statusCode {
                case 429: hint = "DeepL 请求过于频繁被限流，稍后再试"
                case 456: hint = "DeepL 本月额度用尽"
                case 400: hint = "DeepL 不支持该目标语言"
                case 401, 403: hint = "DeepL API Key 无效"
                default:  hint = "DeepL 拒绝了请求（HTTP \(http.statusCode)）"
                }
                await TranslateDiagnostics.record(hint)
                return text
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["translations"] as? [[String: Any]],
               let t = arr.first?["text"] as? String { return t }
            DiagLog.log("[翻译] DeepL 响应解析不出译文 目标=\(targetCode)："
                        + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
            return text
        } catch {
            DiagLog.log("[翻译] DeepL 请求失败 目标=\(targetCode)：\(error.localizedDescription)")
            return text
        }
    }

    private static func deeplLanguageCode(_ label: String) -> String {
        switch label {
        case "中文（简体）": return "ZH-HANS"
        case "中文（繁体）": return "ZH-HANT"
        case "English":     return "EN"
        case "日本語":       return "JA"
        case "한국어":       return "KO"
        case "Français":    return "FR"
        case "Deutsch":     return "DE"
        case "Español":     return "ES"
        case "Русский":     return "RU"
        case "العربية":      return "AR"
        case "Português":   return "PT"
        case "Italiano":    return "IT"
        default:            return "ZH-HANS"
        }
    }

    // MARK: - Apple 翻译

    private static func translateApple(_ text: String, to lang: String,
                                       sourceHint: String? = nil) async -> String {
        #if canImport(Translation)
        if #available(macOS 26, *) {
            let code = appleLanguageCode(lang)
            let target = Locale.Language(identifier: code)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)

            // 源语言优先用整批投票的结果 —— 单条检测在短句上会离谱到把英文判成
            // 土耳其语（实测 tr→zh-Hans），而这里检测错就等于报"缺少语言包"
            let detected = sourceHint ?? recognizer.dominantLanguage?.rawValue ?? "en"

            // source == target 时 TranslationSession 的行为未定义，直接给回原文。
            // 上层 translate 已经挡过一道，这里防的是别处直接调进来
            if isExactMatch(detected: detected, target: code) { return text }

            do {
                return try await appleTranslate(text, from: detected, to: target)
            } catch {
                // 再给一次机会：正确答案通常还在候选里，只是没排第一
                let alternatives = recognizer.languageHypotheses(withMaximum: 3)
                    .sorted { $0.value > $1.value }
                    .map(\.key.rawValue)
                    .filter { $0 != detected && !isExactMatch(detected: $0, target: code) }
                for alt in alternatives {
                    if let retried = try? await appleTranslate(text, from: alt, to: target) {
                        DiagLog.log("[翻译] Apple \(detected)→\(code) 失败，改用 \(alt) 成功")
                        return retried
                    }
                }
                // Apple 走的是**本地语言包**：`installedSource:` 要求该语言对已经装好，
                // 没装就直接抛错。上层只看到"结果==原文"，会误报成"可能被限流"，
                // 所以这里必须留下真实原因
                DiagLog.log("[翻译] Apple 失败 \(detected)→\(code)：\(error.localizedDescription)"
                            + "（候选 \(alternatives) 也都失败，多半是系统里没装这对语言包，"
                            + "去 系统设置 → 语言与地区 → 翻译语言 下载）")
                await TranslateDiagnostics.record("缺少该语言包，请在系统中下载")
                return text
            }
        }
        #endif
        return text
    }

    #if canImport(Translation)
    @available(macOS 26, *)
    private static func appleTranslate(_ text: String, from source: String,
                                       to target: Locale.Language) async throws -> String {
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: target)
        try await session.prepareTranslation()
        return try await session.translate(text).targetText
    }
    #endif

    private static func appleLanguageCode(_ label: String) -> String {
        switch label {
        case "中文（简体）": return "zh-Hans"
        case "中文（繁体）": return "zh-Hant"
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
        default:            return "zh-Hans"
        }
    }

    // MARK: - 有道翻译

    private static func translateYoudao(_ text: String, to lang: String) async -> String {
        let appKey = AppSettings.shared.youdaoAppKey
        let appSecret = AppSettings.shared.youdaoAppSecret
        guard !appKey.isEmpty, !appSecret.isEmpty else { return text }
        let targetCode = youdaoLanguageCode(lang)
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let input: String
        if text.count > 20 {
            input = String(text.prefix(10)) + String(text.count) + String(text.suffix(10))
        } else {
            input = text
        }
        let signStr = appKey + input + salt + curtime + appSecret
        let sign = sha256Hex(Data(signStr.utf8))
        var comps = URLComponents(string: "https://openapi.youdao.com/api")!
        comps.queryItems = [
            .init(name: "q", value: text),
            .init(name: "from", value: "auto"),
            .init(name: "to", value: targetCode),
            .init(name: "appKey", value: appKey),
            .init(name: "salt", value: salt),
            .init(name: "sign", value: sign),
            .init(name: "signType", value: "v3"),
            .init(name: "curtime", value: curtime),
        ]
        guard let url = comps.url else { return text }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["translation"] as? [String],
               let first = arr.first { return first }
            // 有道把失败塞在 errorCode 里（101 缺参数 / 108 appKey 无效 /
            // 202 签名错 / 411 频率受限 / 412 长请求过多…），不记就只剩"返回原文"
            DiagLog.log("[翻译] 有道未返回译文 目标=\(targetCode)："
                        + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
            await TranslateDiagnostics.record("有道未返回译文，请检查 Key 与语言支持")
            return text
        } catch {
            DiagLog.log("[翻译] 有道请求失败 目标=\(targetCode)：\(error.localizedDescription)")
            return text
        }
    }

    private static func youdaoLanguageCode(_ label: String) -> String {
        switch label {
        case "中文（简体）": return "zh-CHS"
        case "中文（繁体）": return "zh-CHT"
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
        default:            return "zh-CHS"
        }
    }

    // MARK: - 火山翻译

    private static func translateVolcano(_ text: String, to lang: String) async -> String {
        let accessKey = AppSettings.shared.volcanoAccessKeyId
        let secretKey = AppSettings.shared.volcanoSecretAccessKey
        guard !accessKey.isEmpty, !secretKey.isEmpty else { return text }
        let targetCode = volcanoLanguageCode(lang)
        let host = "open.volcengineapi.com"
        let service = "translate"
        let region = "cn-north-1"
        let action = "TranslateText"
        let version = "2020-06-01"
        let body: [String: Any] = ["SourceLanguage": "", "TargetLanguage": targetCode, "TextList": [text]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return text }
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let dateTime = fmt.string(from: now)
        let dateOnly = String(dateTime.prefix(8))
        let credScope = "\(dateOnly)/\(region)/\(service)/request"
        let query = "Action=\(action)&Version=\(version)"
        let payloadHash = sha256Hex(bodyData)
        let canonHeaders = "content-type:application/json\nhost:\(host)\nx-date:\(dateTime)\n"
        let signedHeaders = "content-type;host;x-date"
        let canonReq = "POST\n/\n\(query)\n\(canonHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let strToSign = "HMAC-SHA256\n\(dateTime)\n\(credScope)\n\(sha256Hex(Data(canonReq.utf8)))"
        let kDate = hmacSHA256(key: Data(secretKey.utf8), msg: Data(dateOnly.utf8))
        let kRegion = hmacSHA256(key: kDate, msg: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, msg: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, msg: Data("request".utf8))
        let sig = hmacSHA256(key: kSigning, msg: Data(strToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        let auth = "HMAC-SHA256 Credential=\(accessKey)/\(credScope), SignedHeaders=\(signedHeaders), Signature=\(sig)"
        guard let url = URL(string: "https://\(host)/?Action=\(action)&Version=\(version)") else { return text }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(dateTime, forHTTPHeaderField: "X-Date")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["TranslationList"] as? [[String: Any]],
               let t = list.first?["Translation"] as? String { return t }
            DiagLog.log("[翻译] 火山未返回译文 目标=\(targetCode)："
                        + (String(data: data, encoding: .utf8)?.prefix(200).description ?? ""))
            await TranslateDiagnostics.record("火山未返回译文，请检查密钥与语言支持")
            return text
        } catch {
            DiagLog.log("[翻译] 火山请求失败 目标=\(targetCode)：\(error.localizedDescription)")
            return text
        }
    }

    private static func volcanoLanguageCode(_ label: String) -> String {
        switch label {
        case "中文（简体）": return "zh"
        case "中文（繁体）": return "zh-Hant"
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
        default:            return "zh"
        }
    }

    // MARK: - Crypto helpers

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// 批量翻译。先把「本地就能出结果」的挑走（已是目标语言、或只差简繁），
    /// 剩下真需要引擎的才发请求 —— 一整轨中文转繁体因此是零请求。
    static func translateBatch(_ texts: [String], to lang: String,
                               sourceHint: String? = nil) async -> [String] {
        guard !texts.isEmpty else { return texts }

        var output = Array(repeating: "", count: texts.count)
        var pendingIndices: [Int] = []
        for (i, t) in texts.enumerated() {
            if let converted = localChineseConvert(t, to: lang) {
                output[i] = converted
            } else if isAlreadyTarget(t, lang: lang) {
                output[i] = t
            } else {
                pendingIndices.append(i)
            }
        }
        guard !pendingIndices.isEmpty else { return output }

        let pending = pendingIndices.map { texts[$0] }
        // 只拿真要送引擎的那些投票：已是目标语言的条目留在里面会带偏结果
        let hint = sourceHint ?? dominantLanguage(of: pending)
        let engineLang = engineLanguage(for: lang)
        var translated = await translateEngineBatch(pending, to: engineLang, sourceHint: hint)
        if engineLang != lang {
            translated = translated.map { OpenCC.toTraditional($0) }
        }
        for (k, i) in pendingIndices.enumerated() where k < translated.count {
            output[i] = translated[k]
        }
        return output
    }

    /// 真正送去翻译引擎的那部分：多条文本用 \n 拼接成一次请求，翻译后按行还原。
    /// 如果行数不匹配则回退到逐条翻译。
    private static func translateEngineBatch(_ texts: [String], to lang: String,
                                             sourceHint: String? = nil) async -> [String] {
        guard !texts.isEmpty else { return texts }

        // DeepL 有真批量接口：一次请求带走整批，请求数少一个数量级，
        // 是躲开它那个很严的频率限制的正路（串行降并发只会让整轨翻译慢好几倍）
        if AppSettings.shared.translateProvider == .deepL,
           let batched = await translateDeepLBatch(texts, to: lang) {
            // 逐条过一遍语言校验：引擎收下了目标语言却回原文语言时要当失败
            return zip(texts, batched).map { src, out in
                if isChineseTarget(lang), out.count >= 4, !isAlreadyTarget(out, lang: lang) {
                    return src
                }
                return out
            }
        }

        if texts.count == 1 { return [await translate(texts[0], to: lang, sourceHint: sourceHint)] }

        let lineCounts = texts.map { $0.components(separatedBy: "\n").count }
        let combined = texts.joined(separator: "\n")
        let result = await translate(combined, to: lang, sourceHint: sourceHint)
        let allLines = result.components(separatedBy: "\n")

        let expectedTotal = lineCounts.reduce(0, +)
        if allLines.count == expectedTotal {
            var output: [String] = []
            var offset = 0
            for count in lineCounts {
                let segment = allLines[offset..<(offset + count)].joined(separator: "\n")
                output.append(segment.trimmingCharacters(in: .whitespaces))
                offset += count
            }
            return output
        }

        var results: [String] = []
        for text in texts {
            results.append(await translate(text, to: lang, sourceHint: sourceHint))
        }
        return results
    }

    /// 并发 + 批量翻译：分批（每批 batchSize 条），最多 concurrency 路同时发。
    /// onProgress 在每批完成时回调已翻译总数。
    /// - Parameter onBatch: 每批完成时回调 (该批在原数组里的起始下标, 该批结果)，
    ///   调用方据此逐批回填界面，不用等全部翻完
    static func translateConcurrent(
        _ texts: [String], to lang: String,
        batchSize: Int = 15, concurrency: Int = 6,
        onProgress: (@Sendable (Int) async -> Void)? = nil,
        onBatch: (@Sendable (Int, [String]) async -> Void)? = nil
    ) async -> [String] {
        guard !texts.isEmpty else { return texts }

        var batches: [(offset: Int, texts: [String])] = []
        for i in stride(from: 0, to: texts.count, by: batchSize) {
            let end = min(i + batchSize, texts.count)
            batches.append((i, Array(texts[i..<end])))
        }

        // 源语言在**整轨**范围内投一次票再分批：每批各自投票的话，某一批恰好
        // 短句偏多就可能投出个离谱结果（实测单条英文字幕被判成土耳其语）
        let hint = dominantLanguage(of: texts)

        var results = Array(repeating: "", count: texts.count)
        var completed = 0

        await withTaskGroup(of: (Int, [String]).self) { group in
            var launched = 0
            for batch in batches.prefix(concurrency) {
                let b = batch
                group.addTask { (b.offset, await translateBatch(b.texts, to: lang, sourceHint: hint)) }
                launched += 1
            }
            for await (offset, translated) in group {
                for (j, t) in translated.enumerated() where offset + j < results.count {
                    results[offset + j] = t
                }
                completed += translated.count
                await onProgress?(completed)
                await onBatch?(offset, translated)

                if launched < batches.count {
                    let b = batches[launched]
                    group.addTask { (b.offset, await translateBatch(b.texts, to: lang, sourceHint: hint)) }
                    launched += 1
                }
            }
        }
        return results
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

private struct TextInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: TextClip

    @State private var text = ""
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var fontName = "PingFang SC"
    @State private var fontSize: Double = 64
    @State private var bold = true
    @State private var italic = false
    @State private var textColor: Color = .white
    @State private var strokeColor: Color = .black
    @State private var strokeWidth: Double = 0
    @State private var strokeSoftness: Double = 0
    @State private var bgColor: Color = .black
    @State private var bgOpacity: Double = 0
    @State private var alignment = "center"
    @State private var posX: Double = 0.5
    @State private var posY: Double = 0.5
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1
    @State private var animation: TextAnimation = .none
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: $startTime, step: 0.1, decimals: 2)
                            .onChange(of: startTime) { _ in
                                if endTime <= startTime { endTime = startTime + 0.5 }
                                write { $0.startTime = startTime; $0.endTime = endTime }
                            }
                    }
                    IField(label: "持续") {
                        MiniStepper(value: Binding(
                            get: { max(endTime - startTime, 0) },
                            set: { endTime = startTime + max($0, 0.1) }
                        ), step: 0.1, decimals: 2)
                        .onChange(of: endTime) { _ in write { $0.endTime = endTime } }
                    }
                }
            }

            ISection(title: "文字内容") {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.clear))
                    .onChange(of: text) { _ in write { $0.text = text } }
            }

            ISection(title: "字体") {
                HStack(alignment: .bottom, spacing: 8) {
                    IField(label: "字体") {
                        IPicker(selection: $fontName,
                                options: FontHelper.fontOptions)
                            .onChange(of: fontName) { _ in write { $0.fontName = fontName } }
                    }
                    IField(label: "字号") {
                        MiniStepper(value: $fontSize, step: 1, decimals: 0, minValue: 8, maxValue: 300)
                            .onChange(of: fontSize) { _ in write { $0.fontSize = CGFloat(fontSize) } }
                    }.frame(width: 92)
                }
                HStack(spacing: 8) {
                    styleGlyph("B", isOn: bold, weight: .bold) { bold.toggle(); write { $0.bold = bold } }
                    styleGlyph("I", isOn: italic, italic: true) { italic.toggle(); write { $0.italic = italic } }
                    // 文字自己的多行对齐，跟 B / I 排在同一行
                    ForEach([("alignLeft", "left"), ("alignVCenter", "center"),
                             ("alignRight", "right")], id: \.1) { svg, val in
                    Button { alignment = val; write { $0.alignment = val } } label: {
                        Image(nsImage: SidebarSVGIcon.load(svg))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(alignment == val ? Color.accent : Color.labelSecondary)
                            .frame(width: 30, height: 26)
                            .background(alignment == val ? Color.accent.opacity(0.15) : Color.white.opacity(0.05))
                            .cornerRadius(5)
                    }.buttonStyle(.plain)
                }
                    Spacer()
                }
                .padding(.top, 6)
            }

            ISection(title: "颜色与描边") {
                colorRow("文字颜色", $textColor) { write { $0.textColor = textColor } }
                colorRow("描边颜色", $strokeColor) { write { $0.strokeColor = strokeColor } }
                ISlider(label: "描边宽度", value: $strokeWidth, range: 0...100, unit: "px")
                    .onChange(of: strokeWidth) { _ in write { $0.strokeWidth = strokeWidth } }
                ISlider(label: "柔和", value: $strokeSoftness, range: 0...1, unit: "", decimals: 2)
                    .onChange(of: strokeSoftness) { _ in write { $0.strokeSoftness = strokeSoftness } }
                colorRow("背景颜色", $bgColor) { write { $0.bgColor = bgColor } }
                ISlider(label: "背景不透明", value: Binding(get:{bgOpacity*100}, set:{bgOpacity=$0/100}), range: 0...100, unit: "%")
                    .onChange(of: bgOpacity) { _ in write { $0.bgOpacity = bgOpacity } }
            
            }

            // 六组共同属性，跟图片、图形、封面那三个面板同一份
            LayerCommonSections(
                mirrorH: Binding(get: { clip.mirrorH }, set: { v in write { $0.mirrorH = v } }),
                mirrorV: Binding(get: { clip.mirrorV }, set: { v in write { $0.mirrorV = v } }),
                rotation: Binding(get: { rotation }, set: { rotation = $0; write { $0.rotation = rotation } }),
                onRotate90: {
                    rotation = (rotation - 90 + 360).truncatingRemainder(dividingBy: 360)
                    write { $0.rotation = rotation }
                },
                posX: Binding(get: { posX * 100 }, set: { posX = $0 / 100; write { $0.posX = posX } }),
                posY: Binding(get: { posY * 100 }, set: { posY = $0 / 100; write { $0.posY = posY } }),
                onCenter: { posX = 0.5; posY = 0.5; write { $0.posX = 0.5; $0.posY = 0.5 } },
                // 文字量的是**范围框**的像素宽高，不是百分比
                scaleW: Binding(
                    get: { clip.boxWidth ?? Double(clip.fontSize) * Double(max(clip.text.count, 1)) },
                    set: { v in
                        let old = clip.boxWidth ?? Double(clip.fontSize) * Double(max(clip.text.count, 1))
                        // 锁着比例时字号跟着一起放大，跟拖四角圆点的手感一致
                        if clip.lockBoxAspect, old > 0.01 {
                            write { $0.fontSize = max(8, $0.fontSize * CGFloat(v / old)) }
                        }
                        write { $0.boxWidth = v }
                    }),
                scaleH: Binding(
                    get: { clip.boxHeight ?? Double(clip.fontSize) * 1.4 },
                    set: { v in write { $0.boxHeight = v } }),
                lockAspect: Binding(get: { clip.lockBoxAspect },
                                    set: { v in write { $0.lockBoxAspect = v } }),
                scaleRange: 20...2000,
                scaleUnit: "px",
                cropTop: Binding(get: { clip.cropTop * 100 }, set: { v in write { $0.cropTop = v / 100 } }),
                cropBottom: Binding(get: { clip.cropBottom * 100 }, set: { v in write { $0.cropBottom = v / 100 } }),
                cropLeft: Binding(get: { clip.cropLeft * 100 }, set: { v in write { $0.cropLeft = v / 100 } }),
                cropRight: Binding(get: { clip.cropRight * 100 }, set: { v in write { $0.cropRight = v / 100 } }),
                opacity: Binding(get: { opacity * 100 },
                                 set: { opacity = $0 / 100; write { $0.opacity = opacity } }),
                // 文字没有圆角（背景框的圆角跟着字号走）
                cornerRadius: nil,
                onAlign: { project.alignLayers($0, anchorID: clip.id) },
                canDistribute: project.selectedClipIDs.count >= 3,
                onBeforeChange: { project.pushUndo() }
            )

            ISection(title: "入场动画") {
                IPicker(selection: $animation, options: TextAnimation.allCases.map { ($0, $0.label) })
                    .onChange(of: animation) { _ in write { $0.animation = animation } }
            }

        }
        .onAppear { syncAll() }
        .onChange(of: clip.id) { _ in syncAll() }
        // 只认 id 变化不够：应用文字模板改的是**同一个片段**的内容，id 没变，
        // 面板就一直显示旧值。这里监听整个 clip —— 自己写入引起的回流由
        // syncing 标志挡住（write 里 guard !syncing）
        // 只认 id 变化不够：应用文字模板改的是**同一个片段**的内容，id 没变，
        // 面板就一直显示旧值。
        //
        // 必须用闭包参数里的新值 —— 闭包里的 `clip` 是视图**本次求值时**的旧快照，
        // 拿它去 syncAll 等于把旧值原样写回（实测：模板已把字号改成 32，
        // 这里读到的仍是 64）。自己写入引起的回流由 syncing 标志挡住
        .onChange(of: clip) { newClip in
            guard !syncing else { return }
            syncAll(from: newClip)
        }
    }

    private func write(_ mutate: (inout TextClip) -> Void) {
        guard !syncing else { return }
        project.updateTextClip(id: clip.id, mutate)
        project.pushUndoThrottled()
    }
    /// 把片段的值同步进面板。
    /// - Parameter src: 数据源。onChange 必须传闭包给的**新值**——
    ///   视图属性 `clip` 在闭包里是旧快照
    private func syncAll(from src: TextClip? = nil) {
        let c = src ?? clip
        syncing = true
        text = c.text; startTime = c.startTime; endTime = c.endTime
        fontName = c.fontName; fontSize = Double(c.fontSize)
        bold = c.bold; italic = c.italic
        textColor = c.textColor; strokeColor = c.strokeColor; strokeWidth = c.strokeWidth
        bgColor = c.bgColor; bgOpacity = c.bgOpacity
        alignment = c.alignment; posX = c.posX; posY = c.posY
        rotation = c.rotation; opacity = c.opacity; animation = c.animation
        DispatchQueue.main.async { syncing = false }
    }

    @ViewBuilder private func colorRow(_ label: String, _ binding: Binding<Color>, _ onChange: @escaping () -> Void) -> some View {
        IFieldRow(label: label) {
            ColorPicker("", selection: binding)
                .inspectorColorWell()
                .onChange(of: binding.wrappedValue) { _ in onChange() }
        }
    }
    @ViewBuilder private func styleToggle(_ label: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .black : Color.labelSecondary)
                .padding(.horizontal, 14).frame(height: 26)
                .background(isOn ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }
}

private struct ShapeInspector: View {
    @EnvironmentObject private var project: ProjectState
    let clip: ShapeClip

    @State private var startTime = 0.0
    @State private var endTime = 0.0
    @State private var width = 100.0
    @State private var height = 100.0
    @State private var scale = 100.0
    @State private var scaleXPct = 100.0
    @State private var scaleYPct = 100.0
    @State private var lockAspect = true
    @State private var posX = 0.5
    @State private var posY = 0.5
    @State private var rotation = 0.0
    @State private var opacity = 1.0
    @State private var fillEnabled = true
    @State private var fillColor = Color.white
    @State private var fillOpacity = 1.0
    @State private var strokeEnabled = false
    @State private var strokeColor = Color.white
    @State private var strokeWidth = 4.0
    @State private var strokeOpacity = 1.0
    @State private var strokeDashed = false
    @State private var capStartV: LineCapStyle = .none
    @State private var capEndV: LineCapStyle = .none
    @State private var cornerRadius = 0.0
    @State private var shadowEnabled = false
    @State private var shadowColor = Color.black
    @State private var shadowRadius = 8.0
    @State private var shadowOffsetX = 0.0
    @State private var shadowOffsetY = 4.0
    @State private var shadowOpacityV = 0.5
    @State private var shadowDistance = 0.0
    @State private var shadowAngle = 45.0
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "时间") {
                HStack(spacing: 8) {
                    IField(label: "开始") {
                        MiniStepper(value: $startTime, step: 0.1, decimals: 2)
                            .onChange(of: startTime) { _ in
                                if endTime <= startTime { endTime = startTime + 0.5 }
                                write { $0.startTime = startTime; $0.endTime = endTime }
                            }
                    }
                    IField(label: "持续") {
                        MiniStepper(value: Binding(
                            get: { max(endTime - startTime, 0) },
                            set: { endTime = startTime + max($0, 0.1) }
                        ), step: 0.1, decimals: 2)
                        .onChange(of: endTime) { _ in write { $0.endTime = endTime } }
                    }
                }
            }

            // 六组共同属性，跟图片、文字、封面那三个面板同一份
            LayerCommonSections(
                mirrorH: Binding(get: { clip.mirrorH }, set: { v in write { $0.mirrorH = v } }),
                mirrorV: Binding(get: { clip.mirrorV }, set: { v in write { $0.mirrorV = v } }),
                rotation: Binding(get: { rotation }, set: { rotation = $0; write { $0.rotation = rotation } }),
                onRotate90: {
                    rotation = (rotation - 90 + 360).truncatingRemainder(dividingBy: 360)
                    write { $0.rotation = rotation }
                },
                posX: Binding(get: { posX * 100 }, set: { posX = $0 / 100; write { $0.posX = posX } }),
                posY: Binding(get: { posY * 100 }, set: { posY = $0 / 100; write { $0.posY = posY } }),
                onCenter: { posX = 0.5; posY = 0.5; write { $0.posX = 0.5; $0.posY = 0.5 } },
                scaleW: Binding(get: { scaleXPct }, set: { scaleXPct = $0; write { $0.scaleX = scaleXPct / 100 } }),
                scaleH: Binding(get: { scaleYPct }, set: { scaleYPct = $0; write { $0.scaleY = scaleYPct / 100 } }),
                lockAspect: Binding(get: { lockAspect }, set: { lockAspect = $0; write { $0.lockAspect = lockAspect } }),
                cropTop: Binding(get: { clip.cropTop * 100 }, set: { v in write { $0.cropTop = v / 100 } }),
                cropBottom: Binding(get: { clip.cropBottom * 100 }, set: { v in write { $0.cropBottom = v / 100 } }),
                cropLeft: Binding(get: { clip.cropLeft * 100 }, set: { v in write { $0.cropLeft = v / 100 } }),
                cropRight: Binding(get: { clip.cropRight * 100 }, set: { v in write { $0.cropRight = v / 100 } }),
                opacity: Binding(get: { opacity * 100 }, set: { opacity = $0 / 100; write { $0.opacity = opacity } }),
                cornerRadius: Binding(get: { cornerRadius },
                                      set: { cornerRadius = $0; write { $0.cornerRadius = cornerRadius } }),
                // 圆角只有矩形、三角形、梯形、平行四边形有，其余灰掉
                cornerEnabled: ShapeGeometry.supportsCorner(clip.type),
                onAlign: { project.alignLayers($0, anchorID: clip.id) },
                canDistribute: project.selectedClipIDs.count >= 3,
                onBeforeChange: { project.pushUndo() }
            )

            // 填充只对有面积的图形有意义（线段、箭头没有）
            if clip.effectiveIsClosed {
                ISection(title: "填充") {
                    toggleRow("启用填充", $fillEnabled, dimKP: \.fillEnabled) { write { $0.fillEnabled = fillEnabled } }
                    if fillEnabled {
                        colorRow("颜色", $fillColor, dimKP: \.fillColor) { write { $0.fillColor = fillColor } }
                        ISlider(label: "不透明度", value: Binding(get: { fillOpacity * 100 }, set: { fillOpacity = $0 / 100 }), range: 0...100, unit: "%")
                            .onChange(of: fillOpacity) { _ in write { $0.fillOpacity = fillOpacity } }
                    }
                }
            }

            ISection(title: "描边") {
                toggleRow("启用描边", $strokeEnabled, dimKP: \.strokeEnabled) { write { $0.strokeEnabled = strokeEnabled } }
                if strokeEnabled {
                    IFieldRow(label: "样式") {
                        IPicker(selection: Binding(
                            get: { strokeDashed ? "虚线" : "直线" },
                            set: { strokeDashed = ($0 == "虚线"); write { $0.strokeDashed = strokeDashed } }
                        ), options: [("直线", "直线"), ("虚线", "虚线")])
                    }
                    colorRow("颜色", $strokeColor, dimKP: \.strokeColor) { write { $0.strokeColor = strokeColor } }
                    ISlider(label: "粗细", value: $strokeWidth, range: 1...30, unit: "px")
                        .onChange(of: strokeWidth) { _ in write { $0.strokeWidth = strokeWidth } }
                        .dimNonUniform(dim(\.strokeWidth))
                    ISlider(label: "不透明度", value: Binding(get: { strokeOpacity * 100 }, set: { strokeOpacity = $0 / 100 }), range: 0...100, unit: "%")
                        .onChange(of: strokeOpacity) { _ in write { $0.strokeOpacity = strokeOpacity } }
                    if !clip.type.isClosed && clip.type != .pen {
                        IFieldRow(label: "起点") {
                            IPicker(selection: Binding(get: { capStartV.label }, set: { setCap($0, start: true) }), options: LineCapStyle.allCases.map { ($0.label, $0.label) })
                        }
                        IFieldRow(label: "终点") {
                            IPicker(selection: Binding(get: { capEndV.label }, set: { setCap($0, start: false) }), options: LineCapStyle.allCases.map { ($0.label, $0.label) })
                        }
                    }
                }
            }


            ISection(title: "投影") {
                toggleRow("启用投影", $shadowEnabled, dimKP: \.shadowEnabled) { write { $0.shadowEnabled = shadowEnabled } }
                if shadowEnabled {
                    colorRow("颜色", $shadowColor, dimKP: \.shadowColor) { write { $0.shadowColor = shadowColor } }
                    ISlider(label: "不透明度", value: Binding(get: { shadowOpacityV * 100 }, set: { shadowOpacityV = $0 / 100 }), range: 0...100, unit: "%")
                        .onChange(of: shadowOpacityV) { _ in write { $0.shadowOpacity = shadowOpacityV } }
                    ISlider(label: "距离", value: $shadowDistance, range: 0...100, unit: "px")
                        .onChange(of: shadowDistance) { _ in applyShadowVector() }
                    ISlider(label: "角度", value: $shadowAngle, range: 0...360, unit: "°")
                        .onChange(of: shadowAngle) { _ in applyShadowVector() }
                }
            }

            if clip.type == .pen {
                ISection(title: "路径") {
                    HStack {
                        Text("闭合路径").font(.system(size: 11)).foregroundColor(Color.labelSecondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { clip.penClosed },
                            set: { v in write { $0.penClosed = v; if v && !$0.fillEnabled { $0.fillEnabled = true; $0.fillOpacity = 0.3 } } }
                        )).inspectorSwitch()
                    }
                    Button {
                        project.penEditingClipID = clip.id
                    } label: {
                        HStack { Spacer(); Image(systemName: "pencil.and.outline"); Text("编辑路径"); Spacer() }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.accent)
                            .frame(height: 32)
                            .background(Color.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }

        }
        .onAppear { syncAll() }
        .onChange(of: clip.id) { _ in syncAll() }
    }

    private var clipNow: ShapeClip { project.selectedShapeClip ?? clip }

    // 多选时的目标集合；单选时只有当前
    private var targetIDs: [UUID] {
        project.selectedClipIDs.count > 1 ? Array(project.selectedClipIDs) : [clip.id]
    }
    private var isMulti: Bool { project.selectedClipIDs.count > 1 }
    /// 选中集在某属性上是否一致（不一致 → 该属性置灰）
    private func uniform<T: Equatable>(_ kp: KeyPath<ShapeClip, T>) -> Bool {
        let all = project.shapeTracks.flatMap { $0.clips }
        let vals = targetIDs.compactMap { id in all.first { $0.id == id }?[keyPath: kp] }
        guard let f = vals.first else { return true }
        return vals.allSatisfy { $0 == f }
    }
    private func dim(_ kp: KeyPath<ShapeClip, some Equatable>) -> Bool {
        isMulti && !uniform(kp)
    }

    private func write(_ mutate: (inout ShapeClip) -> Void) {
        guard !syncing else { return }
        for id in targetIDs { project.updateShapeClip(id: id, mutate) }
        project.pushUndoThrottled()
    }

    private func applyShadowVector() {
        let rad = shadowAngle * .pi / 180
        write {
            $0.shadowOffsetX = shadowDistance * cos(rad)
            $0.shadowOffsetY = shadowDistance * sin(rad)
        }
    }

    enum AlignMode {
        case left, hcenter, right, top, vcenter, bottom, hdist, vdist
        var needsThree: Bool { self == .hdist || self == .vdist }
    }

    @ViewBuilder
    private func alignBtn(_ icon: String, _ mode: AlignMode, svgName: String? = nil) -> some View {
        let enabled = mode.needsThree ? project.selectedClipIDs.count >= 3 : true
        Button { alignShapes(mode) } label: {
            Group {
                if let svgName {
                    Image(nsImage: SidebarSVGIcon.load(svgName))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon).font(.system(size: 11))
                }
            }
            .foregroundColor(enabled ? Color.labelPrimary : Color.labelSecondary.opacity(0.3))
            .frame(width: 28, height: 24)
            .background(Color.white.opacity(enabled ? 0.06 : 0.02)).cornerRadius(4)
        }.buttonStyle(.plain).disabled(!enabled)
    }

    /// 单选=对齐预览画面；多选=对齐选中包围盒；分布需≥3
    private func alignShapes(_ mode: AlignMode) {
        let ids = project.selectedClipIDs.count > 1 ? Array(project.selectedClipIDs) : [clip.id]
        let all = project.shapeTracks.flatMap { $0.clips }
        let shapes = ids.compactMap { id in all.first { $0.id == id } }
        guard !shapes.isEmpty else { return }
        let rw = Double(project.previewRenderSize.width)
        let rh = Double(project.previewRenderSize.height)
        func hw(_ s: ShapeClip) -> Double { s.width * s.scaleX / 2 }
        func hh(_ s: ShapeClip) -> Double { s.height * s.scaleY / 2 }
        func cx(_ s: ShapeClip) -> Double { s.posX * rw }
        func cy(_ s: ShapeClip) -> Double { s.posY * rh }
        let single = shapes.count <= 1
        let left = single ? 0 : shapes.map { cx($0) - hw($0) }.min()!
        let right = single ? rw : shapes.map { cx($0) + hw($0) }.max()!
        let top = single ? 0 : shapes.map { cy($0) - hh($0) }.min()!
        let bottom = single ? rh : shapes.map { cy($0) + hh($0) }.max()!
        project.pushUndo()
        switch mode {
        case .left:
            for s in shapes { let v = (left + hw(s)) / rw; project.updateShapeClip(id: s.id) { $0.posX = v } }
        case .hcenter:
            let c = (left + right) / 2 / rw; for s in shapes { project.updateShapeClip(id: s.id) { $0.posX = c } }
        case .right:
            for s in shapes { let v = (right - hw(s)) / rw; project.updateShapeClip(id: s.id) { $0.posX = v } }
        case .top:
            for s in shapes { let v = (top + hh(s)) / rh; project.updateShapeClip(id: s.id) { $0.posY = v } }
        case .vcenter:
            let c = (top + bottom) / 2 / rh; for s in shapes { project.updateShapeClip(id: s.id) { $0.posY = c } }
        case .bottom:
            for s in shapes { let v = (bottom - hh(s)) / rh; project.updateShapeClip(id: s.id) { $0.posY = v } }
        case .hdist:
            let sorted = shapes.sorted { cx($0) < cx($1) }
            guard sorted.count >= 3 else { return }
            let totalW = sorted.reduce(0.0) { $0 + hw($1) * 2 }
            let spanL = cx(sorted.first!) - hw(sorted.first!)
            let spanR = cx(sorted.last!) + hw(sorted.last!)
            let gap = (spanR - spanL - totalW) / Double(sorted.count - 1)
            var cur = spanL
            for s in sorted { let v = (cur + hw(s)) / rw; project.updateShapeClip(id: s.id) { $0.posX = v }; cur += hw(s) * 2 + gap }
        case .vdist:
            let sorted = shapes.sorted { cy($0) < cy($1) }
            guard sorted.count >= 3 else { return }
            let totalH = sorted.reduce(0.0) { $0 + hh($1) * 2 }
            let spanT = cy(sorted.first!) - hh(sorted.first!)
            let spanB = cy(sorted.last!) + hh(sorted.last!)
            let gap = (spanB - spanT - totalH) / Double(sorted.count - 1)
            var cur = spanT
            for s in sorted { let v = (cur + hh(s)) / rh; project.updateShapeClip(id: s.id) { $0.posY = v }; cur += hh(s) * 2 + gap }
        }
    }

    private func setCap(_ label: String, start: Bool) {
        guard let c = LineCapStyle.allCases.first(where: { $0.label == label }) else { return }
        if start { capStartV = c; write { $0.capStart = c } }
        else { capEndV = c; write { $0.capEnd = c } }
    }
    private func syncAll() {
        syncing = true
        startTime = clip.startTime; endTime = clip.endTime
        width = clip.width; height = clip.height
        scale = clip.scaleX * 100; scaleXPct = clip.scaleX * 100; scaleYPct = clip.scaleY * 100
        lockAspect = clip.lockAspect
        posX = clip.posX; posY = clip.posY; rotation = clip.rotation; opacity = clip.opacity
        fillEnabled = clip.fillEnabled; fillColor = clip.fillColor; fillOpacity = clip.fillOpacity
        strokeEnabled = clip.strokeEnabled; strokeColor = clip.strokeColor
        strokeWidth = clip.strokeWidth
        strokeOpacity = clip.strokeOpacity; strokeDashed = clip.strokeDashed
        capStartV = clip.capStart; capEndV = clip.capEnd
        cornerRadius = clip.cornerRadius
        shadowEnabled = clip.shadowEnabled; shadowColor = clip.shadowColor
        shadowRadius = clip.shadowRadius; shadowOffsetX = clip.shadowOffsetX; shadowOffsetY = clip.shadowOffsetY
        shadowOpacityV = clip.shadowOpacity
        shadowDistance = hypot(clip.shadowOffsetX, clip.shadowOffsetY)
        shadowAngle = atan2(clip.shadowOffsetY, clip.shadowOffsetX) * 180 / .pi
        DispatchQueue.main.async { syncing = false }
    }

    @ViewBuilder private func colorRow(_ label: String, _ binding: Binding<Color>, dimKP: KeyPath<ShapeClip, Color>? = nil, _ onChange: @escaping () -> Void) -> some View {
        IFieldRow(label: label) {
            ColorPicker("", selection: binding)
                .inspectorColorWell()
                .onChange(of: binding.wrappedValue) { _ in onChange() }
        }
        .dimNonUniform(dimKP.map { isMulti && !uniform($0) } ?? false)
    }
    @ViewBuilder private func toggleRow(_ label: String, _ isOn: Binding<Bool>, dimKP: KeyPath<ShapeClip, Bool>? = nil, _ onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(Color.labelSecondary)
            Spacer()
            Toggle("", isOn: isOn).inspectorSwitch().onChange(of: isOn.wrappedValue) { _ in onChange() }
        }
        .dimNonUniform(dimKP.map { isMulti && !uniform($0) } ?? false)
    }
}

private extension View {
    @ViewBuilder func dimNonUniform(_ shouldDim: Bool) -> some View {
        disabled(shouldDim).opacity(shouldDim ? 0.4 : 1)
    }
}

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
    // 色调调节。跟调节轨道共用同一个结构和同一套滑块
    @State private var colorAdj = ColorAdjust.identity
    // 描边
    @State private var strokeColor: Color = .white
    @State private var strokeWidth: Double = 0
    @State private var strokeSoftness: Double = 0

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

            // 六组共同属性，跟文字、图形、封面那三个面板同一份
            LayerCommonSections(
                mirrorH: Binding(get: { clip.mirrorH },
                                 set: { v in
                                     project.updateImageClip(id: clip.id) { $0.mirrorH = v }
                                     project.rebuildTimelinePreview()
                                 }),
                mirrorV: Binding(get: { clip.mirrorV },
                                 set: { v in
                                     project.updateImageClip(id: clip.id) { $0.mirrorV = v }
                                     project.rebuildTimelinePreview()
                                 }),
                rotation: Binding(get: { clip.rotation },
                                  set: { v in
                                      project.updateImageClip(id: clip.id) { $0.rotation = v }
                                      project.rebuildTimelinePreviewDebounced()
                                  }),
                onRotate90: {
                    project.updateImageClip(id: clip.id) {
                        $0.rotation = ($0.rotation - 90 + 360).truncatingRemainder(dividingBy: 360)
                    }
                    project.rebuildTimelinePreview()
                },
                // 图片的位置存的是相对画面的偏移（0 = 居中），换算成 0~100 的位置
                posX: Binding(get: { (offsetX + 0.5) * 100 },
                              set: { offsetX = $0 / 100 - 0.5; applyTransform() }),
                posY: Binding(get: { (offsetY + 0.5) * 100 },
                              set: { offsetY = $0 / 100 - 0.5; applyTransform() }),
                onCenter: { offsetX = 0; offsetY = 0; applyTransform() },
                scaleW: Binding(get: { scaleX * 100 },
                                set: { scaleX = $0 / 100; applyTransform() }),
                scaleH: Binding(get: { scaleY * 100 },
                                set: { scaleY = $0 / 100; applyTransform() }),
                lockAspect: Binding(get: { lockAspect },
                                    set: { lockAspect = $0; applyTransform() }),
                cropTop: Binding(get: { cropTop * 100 },
                                 set: { cropTop = $0 / 100; applyTransform() }),
                cropBottom: Binding(get: { cropBottom * 100 },
                                    set: { cropBottom = $0 / 100; applyTransform() }),
                cropLeft: Binding(get: { cropLeft * 100 },
                                  set: { cropLeft = $0 / 100; applyTransform() }),
                cropRight: Binding(get: { cropRight * 100 },
                                   set: { cropRight = $0 / 100; applyTransform() }),
                opacity: Binding(get: { clip.alpha * 100 },
                                 set: { v in
                                     project.updateImageClip(id: clip.id) { $0.opacity = v / 100 }
                                     project.rebuildTimelinePreviewDebounced()
                                 }),
                cornerRadius: Binding(get: { clip.corner },
                                      set: { v in
                                          project.updateImageClip(id: clip.id) { $0.cornerRadius = v }
                                          project.rebuildTimelinePreviewDebounced()
                                      }),
                onAlign: { project.alignLayers($0, anchorID: clip.id) },
                canDistribute: project.selectedClipIDs.count >= 3,
                onBeforeChange: { project.pushUndo() }
            )

            ISection(title: nil) {
                imgSectionHeader("描边") {
                    Button { strokeWidth = 0; applyStroke() } label: {
                        Text("重置")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(strokeWidth > 0.01 ? .black : Color.labelSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(strokeWidth > 0.01 ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(strokeWidth <= 0.01)
                }
                IFieldRow(label: "颜色") {
                    ColorPicker("", selection: $strokeColor)
                        .inspectorColorWell()
                        .onChange(of: strokeColor) { _ in applyStroke() }
                }
                ICapsuleSlider(label: "宽度", value: $strokeWidth, range: 0...100,
                               decimals: 1, unit: "px",
                               onChange: { _ in applyStroke() })
                ICapsuleSlider(label: "柔和", value: $strokeSoftness, range: 0...1,
                               decimals: 2,
                               onChange: { _ in applyStroke() })
                // 去背图片会沿主体轮廓描边，未去背的矩形图片则沿画面边缘
                Text("描边沿图片不透明区域的轮廓生成，柔和 0 为硬边")
                    .font(.system(size: 9))
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }

            ISection(title: nil) {
                // 跟视频属性区、调节轨道同一个组件，这边默认收起来
                AdjustSliders(adjust: $colorAdj, expandedByDefault: false) {
                    applyColorAdjust()
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
        .onChange(of: clip.colorAdjust) { v in if v != colorAdj { colorAdj = v } }
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
                       unit: "%", displayScale: 100,
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
        colorAdj = clip.colorAdjust
        strokeColor = clip.strokeColor
        strokeWidth = clip.strokeW
        strokeSoftness = clip.strokeSoft
        hasPushedUndo = false
    }

    private func syncLock() {
        project.updateImageClip(id: clip.id) { $0.lockAspect = lockAspect }
    }

    private func applyStroke() {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        project.updateImageClip(id: clip.id) {
            $0.strokeColorHex = strokeColor.toHex()
            $0.strokeWidth = strokeWidth
            $0.strokeSoftness = strokeSoftness
        }
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

    private func applyColorAdjust() {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        let adj = colorAdj
        project.updateImageClip(id: clip.id) { $0.colorAdjust = adj }
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
                       unit: unit, displayScale: scale,
                       onChange: onChange)
    }

    private func imgCanvasBtn(_ icon: TransformIconType, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        let nsImg: NSImage = {
            switch icon {
            case .mirrorH: return TimelineSVGIcon.load("mirrorH")
            case .mirrorV: return TimelineSVGIcon.load("mirrorV")
            case .rotate:  return TimelineSVGIcon.load("rotate")
            case .reverse: return TimelineSVGIcon.load("reverse")
            }
        }()
        return Button {
            project.pushUndo()
            action()
        } label: {
            Image(nsImage: nsImg)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(active ? .black : Color.labelSecondary)
                .frame(width: 28, height: 22)
                .background(active ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(label)
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
    // 色调调节。整份存着，跟调节轨道共用同一个结构
    @State private var colorAdj = ColorAdjust.identity

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

            ISection(title: "速度") {
                // 预设按钮
                HStack(spacing: 4) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { v in
                        let isActive = abs(clip.speed - v) < 0.01
                        Button {
                            project.updateVideoClip(id: clip.id) { c in
                                // 保持"源素材秒数"不变，调整 timeline 宽度
                                let srcSec = c.duration * c.speed
                                c.speed = v
                                c.endTime = c.startTime + max(0.1, srcSec / v)
                            }
                            project.rebuildTimelinePreview()
                            project.pushUndoThrottled()
                        } label: {
                            Text(v == 1.0 ? "1×" : (v < 1 ? String(format: "%.2g×", v) : String(format: "%.0f×", v)))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isActive ? .black : Color.labelSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(isActive ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                ICapsuleSlider(label: "速率", value: Binding(
                    get: { clip.speed },
                    set: { v in
                        project.updateVideoClip(id: clip.id) { c in
                            let srcSec = c.duration * c.speed
                            c.speed = v
                            c.endTime = c.startTime + max(0.1, srcSec / v)
                        }
                        project.rebuildTimelinePreview()
                    }
                ), range: 0.1...4.0, decimals: 2, unit: "×")
                if abs(clip.speed - 1.0) > 0.01 {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                            .foregroundColor(Color.labelSecondary)
                        Text("变速后音调随之改变")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    .padding(.top, 2)
                }
            }

            ISection(title: "变换") {
                HStack(spacing: 4) {
                    canvasBtn(.mirrorH, label: "水平镜像", active: clip.mirrorH) {
                        project.updateVideoClip(id: clip.id) { $0.mirrorH.toggle() }
                        project.rebuildTimelinePreview()
                    }
                    canvasBtn(.mirrorV, label: "垂直镜像", active: clip.mirrorV) {
                        project.updateVideoClip(id: clip.id) { $0.mirrorV.toggle() }
                        project.rebuildTimelinePreview()
                    }
                    canvasBtn(.rotate, label: "旋转90°", active: clip.rotation != 0) {
                        project.updateVideoClip(id: clip.id) { $0.rotation = ($0.rotation + 270) % 360 }
                        project.rebuildTimelinePreview()
                    }
                    canvasBtn(.reverse, label: "倒放", active: clip.reversed) {
                        project.updateVideoClip(id: clip.id) { $0.reversed.toggle() }
                        project.rebuildTimelinePreview()
                    }
                    Spacer()
                }
                if clip.rotation != 0 {
                    Text("旋转 \(clip.rotation)°")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
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
                // 一行一个。两个并排的话属性区一窄，右边那个就被挤出容器
                dualSlider("X", value: $offsetX, range: -1.0...1.0) { _ in applyTransform() }
                dualSlider("Y", value: $offsetY, range: -1.0...1.0) { _ in applyTransform() }
            }

            ISection(title: nil) {
                sectionHeader("缩放") {
                    Button { lockAspect.toggle(); syncLock() } label: {
                        Image(systemName: lockAspect ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundColor(lockAspect ? Color.accent : Color.labelSecondary)
                    }.buttonStyle(.plain)
                }
                dualSlider("宽", value: $scaleX, range: 0.1...3.0, unit: "%", scale: 100) { v in
                    if lockAspect { scaleY = v }; applyTransform()
                }
                dualSlider("高", value: $scaleY, range: 0.1...3.0, unit: "%", scale: 100) { v in
                    if lockAspect { scaleX = v }; applyTransform()
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

            ISection(title: nil) {
                // 跟调节轨道用的是同一个组件，这边默认收起来 ——
                // 挂在单个片段上的调节属于「进阶」，不该一上来就占满属性区
                AdjustSliders(adjust: $colorAdj, expandedByDefault: false) {
                    applyColorAdjust()
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
        .onChange(of: clip.colorAdjust) { v in if v != colorAdj { colorAdj = v } }
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
                       unit: unit, displayScale: scale,
                       onChange: onChange)
    }

    @ViewBuilder
    private func videoCropSlider(label: String, value: Binding<Double>, edge: Int) -> some View {
        ICapsuleSlider(label: label, value: value, range: 0...0.99,
                       unit: "%", displayScale: 100,
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
        colorAdj = clip.colorAdjust
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
        if let trackID = project.videoClipTrackIDMap[clip.id] {
            ColorCompositor.setDragOffset(trackID: trackID, offsetX: CGFloat(offsetX), offsetY: CGFloat(offsetY))
            project.clock.refreshSeekRequest &+= 1
        }
        project.rebuildTimelinePreviewDebounced()
    }

    private func applyColorAdjust() {
        if !hasPushedUndo {
            project.pushUndo()
            hasPushedUndo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { hasPushedUndo = false }
        }
        let adj = colorAdj
        project.updateVideoClip(id: clip.id) { $0.colorAdjust = adj }
        // 视频的色调在 compositor 里逐帧算，光改 clip 要等 rebuild 才可见（防抖 0.15s，
        // 表现就是"松手才变"）。这里照位移滑块的做法把值直接喂给 compositor
        // 并逼播放器重绘当前帧，拖动过程就是实时的。
        // rebuild 仍然照常跑：它会 clearStore 把这份覆盖清掉，届时 entries 里已是同样的真值
        if let trackID = project.videoClipTrackIDMap[clip.id] {
            ColorCompositor.setLiveColorAdjust(trackID: trackID, adj)
            project.clock.refreshSeekRequest &+= 1
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

    private func canvasBtn(_ icon: TransformIconType, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        let nsImg: NSImage = {
            switch icon {
            case .mirrorH: return TimelineSVGIcon.load("mirrorH")
            case .mirrorV: return TimelineSVGIcon.load("mirrorV")
            case .rotate:  return TimelineSVGIcon.load("rotate")
            case .reverse: return TimelineSVGIcon.load("reverse")
            }
        }()
        return Button {
            project.pushUndo()
            action()
        } label: {
            Image(nsImage: nsImg)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(active ? .black : Color.labelSecondary)
                .frame(width: 28, height: 22)
                .background(active ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(label)
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

            ISection(title: "速度") {
                HStack(spacing: 4) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { v in
                        let isActive = abs(clip.speed - v) < 0.01
                        Button {
                            project.updateAudioClip(id: clip.id) { c in
                                let srcSec = c.duration * c.speed
                                c.speed = v
                                c.endTime = c.startTime + max(0.1, srcSec / v)
                            }
                            project.rebuildTimelinePreview()
                            project.pushUndoThrottled()
                        } label: {
                            Text(v == 1.0 ? "1×" : (v < 1 ? String(format: "%.2g×", v) : String(format: "%.0f×", v)))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isActive ? .black : Color.labelSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(isActive ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                ICapsuleSlider(label: "速率", value: Binding(
                    get: { clip.speed },
                    set: { v in
                        project.updateAudioClip(id: clip.id) { c in
                            let srcSec = c.duration * c.speed
                            c.speed = v
                            c.endTime = c.startTime + max(0.1, srcSec / v)
                        }
                        project.rebuildTimelinePreview()
                    }
                ), range: 0.1...4.0, decimals: 2, unit: "×")
                if abs(clip.speed - 1.0) > 0.01 {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                            .foregroundColor(Color.labelSecondary)
                        Text("变速后音调随之改变")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    }
                    .padding(.top, 2)
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
                    .inspectorSwitch(anchor: .leading)
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
                    .inspectorSwitch(anchor: .leading)
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

/// 属性区里所有开关统一走这个：**小一号 + 开启时是主题黄**。
///
/// 原来各处自己写 `.scaleEffect(0.8)` / `.scaleEffect(0.7, anchor: .leading)`，
/// 大小不一，开启时还是系统蓝，跟界面里别的选中态（橙黄）对不上。
///
/// anchor 默认 `.trailing`：开关基本都在行尾，`scaleEffect` 不改变布局尺寸，
/// 按 leading 缩会把右边缘往里收，跟下面滑块胶囊的右边缘差出十几个点。
/// 少数开关排在标签右边、后面还跟着 Spacer（合并换行、淡入淡出），那几处传 `.leading`
extension View {
    /// 属性区里的颜色入口。缩到跟开关一个量级，右边缘跟滑块对齐
    /// （`scaleEffect` 不改布局尺寸，占位还是原来那么宽，所以右边缘照样齐）
    func inspectorColorWell() -> some View {
        // 色块左边缘要跟滑轨对齐，所以按左边缘缩
        self.labelsHidden().scaleEffect(0.6, anchor: .leading)
    }

    func inspectorSwitch(anchor: UnitPoint = .trailing) -> some View {
        self.labelsHidden()
            .toggleStyle(.switch)
            .tint(Color.accent)
            .scaleEffect(0.53, anchor: anchor)
    }
}

/// 属性区的横向内边距。标题栏和每一组内容都取这里，避免两边各写各的
enum ISectionMetrics {
    static let hPadding: CGFloat = 14
}

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
        .padding(.horizontal, ISectionMetrics.hPadding)
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
    /// 标签占多宽。**统一五个字**，六个面板一个样，滑轨起点才对得齐
    var labelWidth: CGFloat = ILayout.labelWidth

    var body: some View {
        ICapsuleSlider(label: label, value: $value, range: range,
                       decimals: decimals, unit: unit, labelWidth: labelWidth)
    }
}

/// 胶囊式滑块：标签(左) + 滑块 + 可编辑数值(右)，整体浅色圆角胶囊。
/// 参考 Sketch 属性面板：滑块与数值并存，可拖动也可点击数值直接输入。
/// 粗体、斜体这种字形开关。样子跟画布文字卡片那排一致 —— B 就是粗的 B，I 就是斜的 I
func styleGlyph(_ text: String, isOn: Bool,
                weight: Font.Weight = .regular, italic: Bool = false,
                action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(text)
            .font(.system(size: 13, weight: weight))
            .italic(italic)
            .foregroundColor(isOn ? .black : Color.labelSecondary)
            .frame(width: 30, height: 26)
            .background(isOn ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
            .cornerRadius(5)
    }
    .buttonStyle(.plain)
}

/// 属性区的排版基准。六个面板都照这套走，滑轨、色块、下拉框才对得成一条线
enum ILayout {
    /// 标签宽度：五个字
    static let labelWidth: CGFloat = 52
    /// 胶囊滑块的左右内边距
    static let hPadding: CGFloat = 8
    /// 标签和控件之间的间距
    static let gap: CGFloat = 6
    /// 控件（滑轨、色块、下拉框、输入框）的左边缘，相对整行左边缘
    static var contentInset: CGFloat { hPadding + labelWidth + gap }
}

/// 「左标题 + 右控件」的一行。控件左边缘跟滑块的滑轨对齐
struct IFieldRow<Content: View>: View {
    let label: String
    var trailing = false      // true = 控件靠右（开关那种）
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: ILayout.gap) {
            // 标题**从整行最左边开始**，跟滑块那个胶囊背景的左边缘齐；
            // 宽度多算上胶囊的内边距，后面的控件左边缘正好落在滑轨起点上
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .frame(width: ILayout.labelWidth + ILayout.hPadding, alignment: .leading)
                .lineLimit(1)
            if trailing { Spacer(minLength: 0) }
            content
            if !trailing { Spacer(minLength: 0) }
        }
    }
}

struct ICapsuleSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals: Int = 0
    var unit: String = ""
    var displayScale: Double = 1    // 显示值 = value × displayScale（如 offset -1...1 显示为 -100...100）
    var labelWidth: CGFloat = ILayout.labelWidth
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
            .frame(maxWidth: .infinity)
            // 数值区**固定宽度 + fixedSize**：滑轨那头是个 GeometryReader，
            // 在 HStack 里会一路撑开，不把这头钉死的话「344°」会被压到滑轨底下
            HStack(spacing: 1) {
                TextField("", text: $editText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color.labelPrimary)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(width: 34)
                    .onAppear { editText = fmt }
                    .onChange(of: value) { v in if !focused { editText = fmt }; if dragging { onChange?(v) } }
                    .onSubmit { commit() }
                    .onChange(of: focused) { _ in if !focused { commit() } }
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                        .fixedSize()
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, ILayout.hPadding)
        .frame(height: 28)
        .background(Color.white.opacity(0.06))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Color.accent : Color.clear,
                        lineWidth: 1)
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

    private let trackH: CGFloat = 2
    private let thumbR: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let rawFrac = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            // **必须钳住**：值越出 range 时（比如旋转 344° 配 -180...180 的区间）
            // 比例会大于 1，橙色轨道一路画到数值区上面去，看着就是「数字和滑轨重合」
            let frac = max(0, min(1, rawFrac))
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
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isFocused ? Color.accent : Color.clear))
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
    var height: CGFloat = 26
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
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Color.white.opacity(hov ? 0.10 : 0.06))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? ""
    }

    private func showMenu() {
        // 自绘行：系统画的项高亮跟着系统强调色走（蓝底），跟这里的黄主色打架
        NSMenu.picker(options.map { opt in
            (label: opt.1, checked: opt.0 == selection, action: { selection = opt.0 })
        }).popUpHere()
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

// MARK: - FontHelper

/// 字体列表。封面弹窗的文字属性也要用同一份，所以不是 private
enum FontHelper {
    static let fontOptions: [(String, String)] = {
        let all = NSFontManager.shared.availableFontFamilies
        let cjk = all.filter { name in
            name.contains("SC") || name.contains("TC") || name.contains("CN") ||
            name.contains("JP") || name.contains("KR") ||
            name.unicodeScalars.contains { $0.value > 0x3000 }
        }.sorted()
        let rest = all.filter { !cjk.contains($0) }.sorted()
        return (cjk + rest).map { ($0, $0) }
    }()
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
                .stroke(isFocused ? Color.accent : Color.clear, lineWidth: 1)
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

// MARK: - Filter Inspector

/// 滤镜片段的属性。只有名称和强度 —— 具体是哪个滤镜在效果栏里选，
/// 想换就删了重加，跟剪映一个路子
/// 调节片段的属性。参数那块跟片段属性区是同一个组件，只是这里默认展开
struct AdjustInspector: View {
    let clip: AdjustClip
    @EnvironmentObject private var project: ProjectState

    @State private var adjust = ColorAdjust.identity
    @State private var startTime: Double = 0
    @State private var duration: Double = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: nil) {
                AdjustSliders(adjust: $adjust, expandedByDefault: true) {
                    project.updateAdjustClip(id: clip.id) { $0.adjust = adjust }
                }
            }

            ISection(title: "时间") {
                let span = max(project.contentEndTime, 1)
                ISlider(label: "开始", value: $startTime, range: 0...span, unit: "秒", decimals: 2)
                    .onChange(of: startTime) { _ in
                        let s = max(0, startTime)
                        project.updateAdjustClip(id: clip.id) { $0.startTime = s; $0.endTime = s + duration }
                    }
                ISlider(label: "持续", value: $duration, range: 0.1...span, unit: "秒", decimals: 2)
                    .onChange(of: duration) { _ in
                        let d = max(0.1, duration)
                        project.updateAdjustClip(id: clip.id) { $0.endTime = $0.startTime + d }
                    }
            }
        }
        .onAppear { sync() }
        .onChange(of: clip.id) { _ in sync() }
        .onChange(of: clip.startTime) { v in if abs(v - startTime) > 0.001 { startTime = v } }
        .onChange(of: clip.endTime) { _ in
            if abs(clip.duration - duration) > 0.001 { duration = clip.duration }
        }
    }

    private func sync() {
        adjust = clip.adjust
        startTime = clip.startTime
        duration = clip.duration
    }
}

struct FilterInspector: View {
    let clip: FilterClip
    @EnvironmentObject private var project: ProjectState

    @State private var intensity: Double = 100
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var duration: Double = 3
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "滤镜") {
                IFieldRow(label: "名称") {
                    Text(clip.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                }
                ISlider(label: "强度", value: $intensity, range: 0...100, unit: "%")
                    .onChange(of: intensity) { _ in write { $0.intensity = intensity / 100 } }
            }

            ISection(title: "时间") {
                let span = max(project.contentEndTime, 1)
                ISlider(label: "开始", value: $startTime, range: 0...span, unit: "秒", decimals: 2)
                    .onChange(of: startTime) { _ in
                        // 起点不能越过终点，至少留 0.1 秒
                        let s = max(0, min(startTime, endTime - 0.1))
                        write { $0.startTime = s }
                    }
                ISlider(label: "持续", value: $duration, range: 0.1...span, unit: "秒", decimals: 2)
                    .onChange(of: duration) { _ in
                        endTime = startTime + max(duration, 0.1)
                        write { $0.endTime = endTime }
                    }
            }
        }
        .onAppear { sync() }
        .onChange(of: clip.id) { _ in sync() }
        // 在时间轴上拖片段改了起止时间，属性区这几个数也得跟着回填
        .onChange(of: clip.startTime) { _ in sync() }
        .onChange(of: clip.endTime) { _ in sync() }
    }

    private func sync() {
        syncing = true
        intensity = clip.intensity * 100
        startTime = clip.startTime
        endTime = clip.endTime
        duration = max(clip.duration, 0.1)
        DispatchQueue.main.async { syncing = false }
    }

    private func write(_ mutate: @escaping (inout FilterClip) -> Void) {
        guard !syncing else { return }
        project.pushUndoThrottled()
        project.updateFilterClip(id: clip.id, mutate)
    }
}


// MARK: - 特效属性

struct EffectInspector: View {
    let clip: EffectClip
    @EnvironmentObject private var project: ProjectState

    @State private var intensity: Double = 100
    @State private var amount: Double = 30
    @State private var angle: Double = 0
    @State private var centerX: Double = 50
    @State private var centerY: Double = 50
    @State private var startTime: Double = 0
    @State private var duration: Double = 3
    @State private var syncing = false

    /// 主参数在界面上叫什么。同样是「尺寸」，不同特效的说法不一样
    private var amountLabel: String {
        switch clip.kind {
        case .pixellate, .crystallize, .pointillize: return "颗粒"
        case .cmykHalftone, .dotScreen, .lineScreen,
             .circularScreen, .hatchedScreen:        return "网点"
        case .twirl, .vortex, .bump, .pinch, .hole,
             .circleSplash, .lightTunnel:            return "范围"
        case .edges:                                 return "强弱"
        case .noiseReduction:                        return "力度"
        default:                                     return "半径"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ISection(title: "特效") {
                IFieldRow(label: "名称") {
                    Text(clip.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                }
                ISlider(label: "强度", value: $intensity, range: 0...100, unit: "%")
                    .onChange(of: intensity) { _ in write { $0.intensity = intensity / 100 } }
                if clip.kind.amountScale != nil || clip.kind == .edges || clip.kind == .noiseReduction {
                    ISlider(label: amountLabel, value: $amount, range: 0...100, unit: "%")
                        .onChange(of: amount) { _ in write { $0.amount = amount / 100 } }
                }
                if clip.kind.usesAngle {
                    ISlider(label: "角度", value: $angle,
                            range: clip.kind.angleRange, unit: "°", decimals: 0)
                        .onChange(of: angle) { _ in write { $0.angle = angle } }
                }
            }

            if clip.kind.usesCenter {
                ISection(title: "中心点") {
                    ISlider(label: "水平", value: $centerX, range: 0...100, unit: "%")
                        .onChange(of: centerX) { _ in write { $0.centerX = centerX / 100 } }
                    ISlider(label: "垂直", value: $centerY, range: 0...100, unit: "%")
                        .onChange(of: centerY) { _ in write { $0.centerY = centerY / 100 } }
                    Text("也可以直接在预览区拖那个圆点")
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                }
            }

            ISection(title: "时间") {
                let span = max(project.contentEndTime, 1)
                ISlider(label: "开始", value: $startTime, range: 0...span, unit: "秒", decimals: 2)
                    .onChange(of: startTime) { _ in
                        write { $0.startTime = startTime; $0.endTime = startTime + duration }
                    }
                ISlider(label: "持续", value: $duration, range: 0.1...span, unit: "秒", decimals: 2)
                    .onChange(of: duration) { _ in
                        write { $0.endTime = $0.startTime + max(0.1, duration) }
                    }
            }
        }
        .onAppear { sync() }
        .onChange(of: clip.id) { _ in sync() }
        .onChange(of: clip.centerX) { v in if !syncing { centerX = v * 100 } }
        .onChange(of: clip.centerY) { v in if !syncing { centerY = v * 100 } }
        // 在时间轴上拖片段两端改的是 clip，属性区这两个数得跟着回来。
        // **回填时必须挡住写回**：不挡的话回填会触发滑块自己的 onChange，
        // 那边又拿旧的 duration 去算 endTime —— 拖左边右边跟着抖就是这么来的
        .onChange(of: clip.startTime) { v in syncBack() }
        .onChange(of: clip.endTime)   { _ in syncBack() }
    }

    /// 从 clip 把时间回填到滑块，期间不许写回
    private func syncBack() {
        guard !syncing else { return }
        syncing = true
        startTime = clip.startTime
        duration = clip.duration
        DispatchQueue.main.async { syncing = false }
    }

    private func sync() {
        syncing = true
        intensity = clip.intensity * 100
        amount = clip.amount * 100
        angle = clip.angle
        centerX = clip.centerX * 100
        centerY = clip.centerY * 100
        startTime = clip.startTime
        duration = clip.duration
        syncing = false
    }

    private func write(_ mutate: @escaping (inout EffectClip) -> Void) {
        guard !syncing else { return }
        project.pushUndoThrottled()
        project.updateEffectClip(id: clip.id, mutate)
    }
}
