import SwiftUI
import AppKit
import CoreImage
import AVFoundation

/// 选中卡片时浮在它上方的操作栏（v5.1.0，B5）
///
/// 按卡片类型给不同的按钮。能力都是 app 里现成的：
/// 去背景、清晰度提升、分离音轨走各自那条链路，镜像/旋转/裁剪本地用 CoreImage 做。
///
/// **产物落地分两种**：去背景、清晰度提升、分离音轨这类「变出新东西」的产出新卡片；
/// 镜像、旋转、裁剪是同一张图的另一个样子，就地替换 —— 每转一次多一张卡片太啰嗦。
///
/// 图标复用项目自己那两套：素材库的 `removeBg` / `clarity` / `separateAudio` /
/// `exportFile` / `folder` / `clear`，时间轴的 `mirrorH` / `mirrorV` / `rotate`。
/// **只有「裁剪」两套里都没有**，先用 SF Symbol `crop` 顶着，等补图标再换。
struct CanvasNodeActionBar: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    let node: CanvasNode

    var body: some View {
        HStack(spacing: 2) {
            if node.kind == .text {
                textActions
            } else {
                mediaActions
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    // MARK: - 图片 / 视频 / 音频

    @ViewBuilder
    private var mediaActions: some View {
        switch node.kind {
        case .image:
            actionButton(svg: "removeBg", tip: "去除背景") { runRemoveBackground() }
            actionButton(system: "crop", tip: "裁剪") { runCrop() }
            divider
            actionButton(timeline: "mirrorV", tip: "垂直镜像") { runMirror(vertical: true) }
            actionButton(timeline: "mirrorH", tip: "水平镜像") { runMirror(vertical: false) }
            actionButton(timeline: "rotate", tip: "旋转 90°") { runRotate() }
            divider
            actionButton(svg: "importFile", tip: "下载") { runDownload() }
            actionButton(svg: "folder", tip: "保存到素材库") { runSaveToLibrary() }

        case .video:
            actionButton(svg: "clarity", tip: "清晰度提升") { runUpscale() }
            actionButton(svg: "separateAudio", tip: "分离音频") { runSeparateAudio() }
            actionButton(system: "crop", tip: "裁剪") { runCrop() }
            divider
            actionButton(timeline: "mirrorV", tip: "垂直镜像") { runMirror(vertical: true) }
            actionButton(timeline: "mirrorH", tip: "水平镜像") { runMirror(vertical: false) }
            actionButton(timeline: "rotate", tip: "旋转 90°") { runRotate() }
            divider
            actionButton(svg: "importFile", tip: "下载") { runDownload() }
            actionButton(svg: "folder", tip: "保存到素材库") { runSaveToLibrary() }

        case .audio:
            actionButton(svg: "separateAudio", tip: "分离音频") { runSeparateAudio() }
            divider
            actionButton(svg: "importFile", tip: "下载") { runDownload() }
            actionButton(svg: "folder", tip: "保存到素材库") { runSaveToLibrary() }

        case .text:
            EmptyView()
        }
    }

    // MARK: - 文字

    /// 文本卡片改用 markdown 语法（v5.1.0）：H1/H2/H3/B/I/U/S 不再是「整段统一
    /// 属性」的开关，而是往 `node.text` 里插入/去掉对应的 markdown 符号 ——
    /// 默认态照 `CanvasMarkdown` 渲染出实际样式，编辑态看到的是原始符号。
    /// 这是**整段**操作（不是选中范围），跟改动前的行为范围一致，只是
    /// 存储方式从独立字段换成了内嵌在文本里的符号
    @ViewBuilder
    private var textActions: some View {
        ColorSwatch(hex: node.textColorHex) { hex in
            canvas.updateNode(id: node.id) { $0.textColorHex = hex }
        }
        divider
        ForEach(1...3, id: \.self) { level in
            labelButton("H\(level)", active: current.heading == level) {
                rewriteText { CanvasMarkdown.toggleHeading($0, level: level) }
            }
        }
        divider
        labelButton("B", active: current.styles.contains(.bold), weight: .bold) {
            rewriteText { CanvasMarkdown.toggle($0, style: .bold) }
        }
        labelButton("I", active: current.styles.contains(.italic), italic: true) {
            rewriteText { CanvasMarkdown.toggle($0, style: .italic) }
        }
        labelButton("U", active: current.styles.contains(.underline), underline: true) {
            rewriteText { CanvasMarkdown.toggle($0, style: .underline) }
        }
        labelButton("S", active: current.styles.contains(.strikethrough), strikethrough: true) {
            rewriteText { CanvasMarkdown.toggle($0, style: .strikethrough) }
        }
        divider
        actionButton(svg: "clear", tip: "清空文字", enabled: !node.text.isEmpty) {
            // 撤销点由 rewriteText 统一压，这里再压一次会变成要按两下 ⌘Z
            rewriteText { _ in "" }
        }
    }

    /// 工具栏改文字都走这儿。两件事：
    ///
    /// 1. **只改光标所在那一行** —— 光标在第二段就改第二段，
    ///    不能不管光标在哪都往第一行加
    /// 2. 改完把 `textEditRevision` 加一，好让**正在编辑中**的输入框知道
    ///    「这次是程序改的，该同步进来」；不加的话编辑器为了不冲掉用户正在敲的字
    ///    会拒绝覆盖，表现就是「点了 H1 没反应，退出编辑再进来才看见 #」
    private func rewriteText(_ transform: @escaping (String) -> String) {
        // 工具栏这一下是独立的一步，跟用户手打的那轮分开记
        canvas.endTextEditUndoGroup()
        canvas.pushUndo()
        let caret = canvas.textCaretLocation
        canvas.updateNode(id: node.id) {
            $0.text = CanvasMarkdown.replacingLine(in: $0.text, caret: caret, transform)
        }
        canvas.textEditRevision += 1
    }

    /// 光标所在那一行被哪些样式包着、标题是几级 —— 按钮高亮和 toggle 用的是
    /// **同一行、同一份拆解**，不会出现「按钮亮的是第一行的状态，改的却是第二行」
    private var current: (heading: Int, styles: Set<CanvasMarkdown.StyleKind>, body: String) {
        CanvasMarkdown.decompose(CanvasMarkdown.line(of: node.text, caret: canvas.textCaretLocation))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    /// `enabled` 默认跟着「这张卡片有没有内容」走 —— 空卡片上所有处理按钮都该是灰的
    private func actionButton(svg: String? = nil, timeline: String? = nil, system: String? = nil,
                              tip: String, enabled: Bool? = nil,
                              action: @escaping () -> Void) -> some View {
        CanvasActionButton(svg: svg, timeline: timeline, system: system, tip: tip,
                           enabled: enabled ?? node.hasContent, action: action)
    }

    private func labelButton(_ text: String, active: Bool,
                             weight: Font.Weight = .regular,
                             italic: Bool = false,
                             underline: Bool = false,
                             strikethrough: Bool = false,
                             action: @escaping () -> Void) -> some View {
        CanvasLabelButton(text: text, active: active, weight: weight,
                          isItalic: italic, isUnderline: underline,
                          isStrikethrough: strikethrough, action: action)
    }

    // MARK: - 动作

    /// 产出新卡片，摆在原卡片右边。**不连线** —— 处理产物跟原图是同一个东西的两个版本
    private func makeResultNode(url: URL, kind: CanvasNode.Kind, rowOffset: Int = 0) {
        let pos = CGPoint(x: node.position.x + node.size.width + 90,
                          y: node.position.y + CGFloat(rowOffset) * 140)
        let new = canvas.addNode(kind: kind, at: pos, ratio: node.ratio)
        project.importFile(url)
        let asset = project.mediaAssets.first { $0.url == url }
        canvas.updateNode(id: new.id) {
            $0.mediaPath = url.path
            $0.assetID = asset?.id
            if kind == node.kind { $0.size = node.size }
        }
        // addNode 里已经按类型排过号了，这里不重复命名
        canvas.recordProducedAsset(url: url, kind: kind)
    }

    /// 就地换掉这张卡片的内容（镜像/旋转/裁剪走这条）
    private func replaceContent(url: URL, newSize: CGSize? = nil) {
        canvas.pushUndo()
        project.importFile(url)
        let asset = project.mediaAssets.first { $0.url == url }
        canvas.updateNode(id: node.id) {
            $0.mediaPath = url.path
            $0.assetID = asset?.id
            if let newSize { $0.size = newSize }
        }
        canvas.recordProducedAsset(url: url, kind: node.kind)
    }

    private func runRemoveBackground() {
        guard let url = node.mediaURL else { return }
        let nodeID = node.id
        canvas.updateNode(id: nodeID) { $0.isGenerating = true }
        Task { @MainActor in
            defer { canvas.updateNode(id: nodeID) { $0.isGenerating = false } }
            do {
                let out = try await BackgroundRemover.removeBackground(
                    from: url,
                    outputName: url.deletingPathExtension().lastPathComponent + "_去背景",
                    mode: .subject,
                    onStage: { _ in })
                makeResultNode(url: out, kind: .image)
            } catch {
                canvas.updateNode(id: nodeID) { $0.failure = error.localizedDescription }
            }
        }
    }

    /// 清晰度提升。**跟时间轴走同一条流水线**（`runClarityEnhancePipeline`），
    /// 只是进度显示在卡片上而不是通知卡片里，产物落成新卡片而不是新轨道
    private func runUpscale() {
        guard let url = node.mediaURL else { return }
        let nodeID = node.id
        // 引擎和倍数都读「设置 → 清晰度提升」那份，跟时间轴用同一套配置
        let engine = AppSettings.shared.clarityEngine
        let useSystemSR = engine == .system
        let proModel: ClarityProModel? = engine.proModel(scale: 4)
        let model: ClarityModel = .x4

        // 模型没下就别开工，白等一场
        if !useSystemSR {
            let ready = proModel?.isDownloaded ?? model.isDownloaded
            guard ready else {
                canvas.updateNode(id: nodeID) { $0.failure = "超分模型还没下载，去「设置 → 清晰度提升」下一次" }
                return
            }
        }

        let cancelFlag = ClarityCancelFlag()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas_clarity_\(UUID().uuidString)")
        let out = Self.outputURL(basedOn: url, suffix: "_超分", ext: url.pathExtension)

        canvas.updateNode(id: nodeID) {
            $0.isGenerating = true; $0.failure = nil
            $0.progressText = "准备中…"; $0.progress = 0
        }

        let duration = assetDuration(url)
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ProjectState.runClarityEnhancePipeline(
                    sourceURL: url, trimStart: 0, duration: duration,
                    model: model, workDir: workDir, outputURL: out,
                    cancelFlag: cancelFlag,
                    useSystemSR: useSystemSR, proModel: proModel,
                    // 这个回调在 concurrentPerform 的闭包里、**多线程同时进来**，
                    // 必须先回主线程再碰 @Published，否则撞成 EXC_BAD_ACCESS
                    onStateChange: { state in
                        Task { @MainActor in
                            canvas.updateNode(id: nodeID) {
                                $0.progressText = state.canvasLabel
                                $0.progress = state.canvasProgress
                            }
                        }
                    })
                await MainActor.run {
                    canvas.updateNode(id: nodeID) {
                        $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                    }
                    makeResultNode(url: result, kind: .video)
                }
            } catch {
                await MainActor.run {
                    canvas.updateNode(id: nodeID) {
                        $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                        $0.failure = error.localizedDescription
                    }
                }
            }
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    /// 分离音轨。同样复用 `AudioSeparator.separateStems`，
    /// 分出来的每一轨各落一张音频卡片
    private func runSeparateAudio() {
        guard let url = node.mediaURL else { return }
        let nodeID = node.id
        guard AudioSeparator.demucsReady else {
            canvas.updateNode(id: nodeID) { $0.failure = "分离音轨的组件没装好" }
            return
        }

        canvas.updateNode(id: nodeID) {
            $0.isGenerating = true; $0.failure = nil
            $0.progressText = "准备中…"; $0.progress = 0
        }

        Task { @MainActor in
            do {
                if !AudioSeparator.modelReady {
                    canvas.updateNode(id: nodeID) { $0.progressText = "下载模型中…" }
                    try await AudioSeparator.downloadModel { p in
                        Task { @MainActor in
                            canvas.updateNode(id: nodeID) { $0.progress = p }
                        }
                    }
                }
                let stems = try await AudioSeparator.separateStems(
                    mediaURL: url,
                    onProgress: { p, label in
                        Task { @MainActor in
                            canvas.updateNode(id: nodeID) {
                                $0.progress = p
                                $0.progressText = label
                            }
                        }
                    })
                canvas.updateNode(id: nodeID) {
                    $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                }
                // 每一轨一张卡片，竖着排在原卡片右边
                for (i, stem) in stems.enumerated() {
                    makeResultNode(url: stem.url, kind: .audio, rowOffset: i)
                }
            } catch {
                canvas.updateNode(id: nodeID) {
                    $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                    $0.failure = error.localizedDescription
                }
            }
        }
    }

    private func assetDuration(_ url: URL) -> Double {
        if let a = project.mediaAssets.first(where: { $0.url == url }), a.duration > 0 {
            return a.duration
        }
        return AVURLAsset(url: url).duration.seconds
    }

    private func clearHintLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            canvas.rejectMessage = nil
        }
    }

    /// 裁剪：直接在卡片上拉框，确认了才真裁（框和确认在 CanvasNodeView 里）。
    /// 图片本地裁，视频走 ffmpeg —— 都是同一个框
    private func runCrop() {
        guard hasContent else { return }
        canvas.croppingNodeID = node.id
    }

    private func runMirror(vertical: Bool) {
        guard hasContent, let url = node.mediaURL else { return }
        if node.kind == .image {
            do {
                replaceContent(url: try CanvasImageOps.mirror(url, vertical: vertical))
            } catch {
                canvas.updateNode(id: node.id) { $0.failure = error.localizedDescription }
            }
        } else {
            // 视频得整段重编码，走 ffmpeg
            runVideoOp(label: vertical ? "垂直镜像中…" : "水平镜像中…") {
                try await CanvasVideoOps.mirror(url, vertical: vertical)
            }
        }
    }

    private func runRotate() {
        guard hasContent, let url = node.mediaURL else { return }
        // 转完宽高互换，卡片也跟着换
        let swapped = CGSize(width: node.size.height, height: node.size.width)
        if node.kind == .image {
            do {
                replaceContent(url: try CanvasImageOps.rotate90(url), newSize: swapped)
            } catch {
                canvas.updateNode(id: node.id) { $0.failure = error.localizedDescription }
            }
        } else {
            runVideoOp(label: "旋转中…", newSize: swapped) {
                try await CanvasVideoOps.rotate90(url)
            }
        }
    }

    /// 视频的三个变换共用这条：转圈 → ffmpeg 重编码 → 就地换掉卡片内容
    private func runVideoOp(label: String, newSize: CGSize? = nil,
                            work: @escaping () async throws -> URL) {
        let nodeID = node.id
        canvas.updateNode(id: nodeID) {
            $0.isGenerating = true; $0.failure = nil; $0.progressText = label
        }
        Task { @MainActor in
            do {
                let out = try await work()
                canvas.updateNode(id: nodeID) {
                    $0.isGenerating = false; $0.progressText = nil
                }
                replaceContent(url: out, newSize: newSize)
            } catch {
                canvas.updateNode(id: nodeID) {
                    $0.isGenerating = false; $0.progressText = nil
                    $0.failure = error.localizedDescription
                }
            }
        }
    }

    /// 空卡片没东西可处理。按钮本来就置灰了，这里是二道保险
    private var hasContent: Bool {
        guard node.mediaURL != nil else {
            canvas.rejectMessage = "这张卡片还没有内容"
            clearHintLater()
            return false
        }
        return true
    }

    /// 下载：让用户选存哪儿
    private func runDownload() {
        guard let url = node.mediaURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            canvas.rejectMessage = "已保存"
        } catch {
            canvas.rejectMessage = "保存失败：\(error.localizedDescription)"
        }
        clearHintLater()
    }

    private func runSaveToLibrary() {
        guard let url = node.mediaURL else { return }
        project.importFile(url)
        canvas.rejectMessage = "已保存到素材库"
        clearHintLater()
    }

    // MARK: - 落盘

    /// 产物落盘统一走 `CanvasImageOps`
    static func outputURL(basedOn source: URL, suffix: String, ext: String = "png") -> URL {
        CanvasImageOps.outputURL(basedOn: source, suffix: suffix, ext: ext)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try CanvasImageOps.writePNG(image, to: url)
    }
}

// MARK: - 按钮

/// 图标按钮。项目自己的 SVG 优先，没有的用 SF Symbols 顶着
private struct CanvasActionButton: View {
    /// 素材库那套图标
    var svg: String?
    /// 时间轴那套图标（镜像/旋转在这儿）
    var timeline: String?
    var system: String?
    let tip: String
    /// 空卡片上没东西可处理，按钮置灰
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let svg, SidebarSVGIcon.svgs[svg] != nil {
                    Image(nsImage: SidebarSVGIcon.load(svg, size: 14))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else if let timeline {
                    Image(nsImage: TimelineSVGIcon.load(timeline))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: system ?? "questionmark")
                        .font(.system(size: 12))
                }
            }
            .foregroundColor(enabled
                             ? (hovering ? Color.labelPrimary : Color.labelSecondary)
                             : Color.labelSecondary.opacity(0.3))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(enabled && hovering ? 0.12 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = enabled && $0 }
        .help(enabled ? tip : "\(tip)：这张卡片还没有内容")
    }
}

/// 文字样式那几个（H1/B/I/U/S）：按钮本身就长成它代表的样子
private struct CanvasLabelButton: View {
    let text: String
    let active: Bool
    var weight: Font.Weight = .regular
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: weight))
                .italic(isItalic)
                .underline(isUnderline)
                .strikethrough(isStrikethrough)
                .foregroundColor(active ? .white : Color.labelSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(active ? 0.18 : (hovering ? 0.12 : 0))))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 颜色块：一个圆点，点开在它**正下方**展开调色板。
///
/// 不用 SwiftUI 的 `ColorPicker` —— 它是系统样式的方块，
/// 弹出位置也归系统管，没法跟着这个圆点走
private struct ColorSwatch: View {
    let hex: String
    let onPick: (String) -> Void

    @State private var hovering = false
    @State private var showPalette = false

    /// 常用色。最后一个是「更多」，走系统取色器
    private static let presets = [
        "#FFFFFF", "#000000", "#FF3B30", "#FF9F43", "#FFD60A",
        "#34C759", "#00C7BE", "#0A84FF", "#5E5CE6", "#BF5AF2",
    ]

    var body: some View {
        Button { showPalette.toggle() } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.6 : 0.25), lineWidth: 1))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("文字颜色")
        .overlay(alignment: .top) {
            if showPalette {
                palette
                    // 挂在圆点正下方，跟着它走
                    .offset(y: 32)
                    .zIndex(10)
            }
        }
    }

    private var palette: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.presets, id: \.self) { c in
                    Button {
                        onPick(c)
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(Color(hex: c))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(
                                c.caseInsensitiveCompare(hex) == .orderedSame
                                    ? Color.accent : Color.white.opacity(0.2),
                                lineWidth: c.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.15)

            ColorPicker("更多颜色", selection: Binding(
                get: { Color(hex: hex) },
                set: { onPick($0.toHex() ?? "#FFFFFF") }), supportsOpacity: false)
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
        }
        .padding(10)
        .frame(width: 156)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 5)
    }
}
