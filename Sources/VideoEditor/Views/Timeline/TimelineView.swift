import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Timeline root

private struct VScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TimelineView: View {
    /// 按片段类型显示的那几组功能（识别/分析/分离音轨/清晰度/转语音/翻译/去背景）。
    /// 全摊在 contextMenu 里会让 ViewBuilder 的类型推断炸掉，必须抽出来
    @ViewBuilder
    private var clipTypeMenuItems: some View {
        if project.selectedVideoClipID != nil || project.selectedAudioClipID != nil {
            Divider()
            transcribeAndAnalyzeItems
            Button { project.removeBackgroundMusicForSelection() } label: {
                Image(nsImage: SidebarSVGIcon.load("separateAudio", size: 14))
                Text("分离音轨")
            }
            .disabled(!project.canRemoveBackgroundMusic)
        }
        // 清晰度提升只对视频有意义（音频没有清晰度概念），单独用
        // selectedVideoClipID 分支包裹，不复用上面分离音轨的 OR 条件——
        // 跟下面「去除背景」（仅图片，canRemoveImageBackground 同样是
        // `guard !isXxx else return false; return selectedImageClipID != nil`
        // 的形状）保持同一套模式：只对单一片段类型有意义的功能，用自己的
        // if 分支控制显隐，而不是挂在别的功能的 OR 分支下用 .disabled 兜底
        // ——否则右键音频片段时会看到一个永远灰着的「清晰度提升」，容易让人
        // 误以为是 bug。canEnhanceClarity 内部仍会检查 selectedVideoClipID，
        // .disabled 在这里只负责处理"任务进行中不能重复触发"这一种状态。
        if project.selectedVideoClipID != nil {
            Divider()
            Menu {
                // 系统超分只有 4 倍这一档（VTSuperResolutionScaler
                // 的硬限制），选了它就不摆一个点了会直接报错的 2 倍
                if AppSettings.shared.clarityEngine.supportsX2 {
                    Button { project.enhanceClaritySelection(scale: .x2) } label: {
                        Text("提升 2 倍")
                    }
                }
                Button { project.enhanceClaritySelection(scale: .x4) } label: {
                    Text("提升 4 倍")
                }
            } label: {
                Image(nsImage: SidebarSVGIcon.load("clarity", size: 14))
                Text("清晰度提升")
            }
            .disabled(!project.canEnhanceClarity)
        }
        if !project.selectedSubtitleClipsForTTS.isEmpty {
            Divider()
            Button { project.convertSelectedSubtitlesToSpeech() } label: {
                Image(nsImage: SidebarSVGIcon.load("toSpeech", size: 14))
                Text("转换成语音")
            }
            .disabled(!project.canConvertSubtitleToSpeech)
            Button { project.translateSelectedTick += 1 } label: {
                Image(nsImage: TimelineSVGIcon.load("translate", size: 14))
                Text("翻译选中字幕")
            }
            .disabled(project.selectedSubtitleClipID == nil)
            Button { project.translateTrackTick += 1 } label: {
                Image(nsImage: TimelineSVGIcon.load("translateTrack", size: 14))
                Text("翻译整条轨道")
            }
            .disabled(project.subtitleTracks.allSatisfy { $0.clips.isEmpty })
        }
        if project.selectedImageClipID != nil {
            Divider()
            // BiRefNet 一个模型全包，不用分方式；系统内置才需要在语义分割和色键之间选
            if AppSettings.shared.bgRemovalEngine == .biRefNet {
                Button { project.removeBackgroundForSelection(mode: .subject) } label: {
                    Image(nsImage: SidebarSVGIcon.load("removeBg", size: 14))
                    Text("去除背景")
                }
                .disabled(!project.canRemoveImageBackground)
            } else {
                Menu {
                    Button { project.removeBackgroundForSelection(mode: .subject) } label: {
                        Text("智能识别主体")
                    }
                    Button { project.removeBackgroundForSelection(mode: .solid) } label: {
                        Text("纯色背景")
                    }
                } label: {
                    Image(nsImage: SidebarSVGIcon.load("removeBg", size: 14))
                    Text("去除背景")
                }
                .disabled(!project.canRemoveImageBackground)
            }
        }
    }

    /// 视频/音频片段右键里的「语音识别字幕 / 视频分析」。
    /// 抽出来是因为 contextMenu 的 ViewBuilder 嵌套一深，类型就推断不出来了
    @ViewBuilder
    private var transcribeAndAnalyzeItems: some View {
        Button { project.showTranscribeOptions = true } label: {
            Image(nsImage: TimelineSVGIcon.load("whisper", size: 14))
            Text("语音识别字幕")
        }
        .disabled(project.isTranscribing)
        // 视频分析只对视频有意义，音频片段不显示
        if project.selectedVideoClipID != nil {
            Menu {
                Button { project.sceneDetectSelectedClip() } label: { Text("智能分割") }
                    .disabled(!SceneDetector.isInstalled)
                Button { project.llmAnalyzeSelectedClip() } label: { Text("AI 剪辑") }
                    .disabled(AppSettings.shared.llmAPIKey.isEmpty)
            } label: {
                Image(nsImage: TimelineSVGIcon.load("smartAnalysis", size: 14))
                Text("视频智能剪辑")
            }
            .disabled(project.isDetectingScenes || project.isLLMAnalyzing)
        }
    }

    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    /// 本视图属于哪个窗口。键盘快捷键要按窗口隔离，见 setupMonitors
    @Environment(\.windowID) private var windowID
    private let labelW: CGFloat = 84
    private let rulerH: CGFloat = 26

    // 可拖动轨道高度
    @State private var imageTrackHeights: [Int: CGFloat] = [:]
    @State private var videoTrackHeights: [Int: CGFloat] = [:]
    @State private var audioTrackHeights: [Int: CGFloat] = [:]
    @State private var subtitleTrackHeights: [Int: CGFloat] = [:]
    @State private var textTrackHeights: [Int: CGFloat] = [:]
    @State private var shapeTrackHeights: [Int: CGFloat] = [:]
    @State private var compoundTrackHeights: [Int: CGFloat] = [:]
    private let defaultTrackH: CGFloat = 52
    private let defaultSubTrackH: CGFloat = 28
    private func imgH(_ i: Int) -> CGFloat { imageTrackHeights[i] ?? defaultTrackH }
    private func vidH(_ i: Int) -> CGFloat { videoTrackHeights[i] ?? defaultTrackH }
    private func audH(_ i: Int) -> CGFloat { audioTrackHeights[i] ?? defaultTrackH }
    private func subH(_ i: Int) -> CGFloat { subtitleTrackHeights[i] ?? defaultSubTrackH }
    private func txtH(_ i: Int) -> CGFloat { textTrackHeights[i] ?? defaultSubTrackH }
    private func shpH(_ i: Int) -> CGFloat { shapeTrackHeights[i] ?? defaultSubTrackH }
    private func cmpH(_ i: Int) -> CGFloat { compoundTrackHeights[i] ?? defaultTrackH }
    // 拖动起始值
    @State private var dragOriginTrackH: CGFloat = 0
    @State private var isLibraryDragOver = false
    @State private var viewportH: CGFloat = 300

    // Unified drag state
    @State private var dragOp:   DragOp?  = nil
    @State private var boxStart: CGPoint? = nil
    @State private var boxEnd:   CGPoint? = nil
    @State private var dragGhostPos: CGPoint? = nil  // ghost center position during clip drag
    @State private var dragGhostOffset: CGSize = .zero // offset from mouse to clip center at drag start
    @State private var draggingClipID: UUID? = nil   // hide original while dragging
    /// 多选拖动时正在搬的那一组。原片段要全部隐藏，只显示跟着鼠标的半透明幻影
    @State private var draggingClipIDs: Set<UUID> = []
    /// 多选幻影：每个的外观 + 相对抓取点的偏移（拖动开始时算一次，之后整体跟着鼠标走）
    @State private var multiGhosts: [MultiGhost] = []
    @State private var activeSnapTime: Double? = nil  // 吸附指示线位置

    // Global event monitors
    @State private var keyMonitor:     Any? = nil
    @State private var scrollMonitor:  Any? = nil
    @State private var lastMagnifyValue: CGFloat = 1.0
    @State private var scrollBarHovered = false
    /// 正在横向滚动。滚动时也把滚动条亮出来（细版，只报位置不请你点），
    /// 停手 1.2s 后自动收——跟 macOS overlay scroller 一个路子
    @State private var scrollBarScrolling = false
    @State private var scrollIdleWork: DispatchWorkItem?
    @State private var scrollFraction: Double = 0
    @State private var scrollViewportFraction: Double = 1
    @State private var scrollOffsetX: CGFloat = 0
    @State private var lastCompoundClickID: UUID? = nil
    @State private var lastCompoundClickTime: Date = .distantPast
    @State private var hoveredMarkerID: UUID? = nil
    @State private var hoveredMarkerY: CGFloat = 0
    @State private var editingMarkerID: UUID? = nil
    @State private var lastMarkerClickID: UUID? = nil
    @State private var lastMarkerClickTime: Date = .distantPast

    // 轨道标签拖拽排序
    private enum TrackDragType: Equatable { case video, audio, overlay }
    @State private var trackLabelDragType: TrackDragType? = nil
    @State private var trackLabelDragSrc: Int = 0
    @State private var trackLabelDragOffset: CGFloat = 0
    @State private var trackLabelDropIdx: Int? = nil
    @State private var vScrollOffset: CGFloat = 0

    private enum DragOp {
        case moveVideo(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveImage(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveAudio(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveSubtitle(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveText(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveShape(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveFilter(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveAdjust(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveEffect(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveCompound(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveMulti(items: [DragItem])
        case trimVideoLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimVideoRight(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimImageLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimImageRight(id: UUID, originStart: Double, originEnd: Double)
        case trimAudioLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimAudioRight(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimSubtitleLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleRight(id: UUID, originStart: Double, originEnd: Double)
        case trimTextLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimTextRight(id: UUID, originStart: Double, originEnd: Double)
        case trimShapeLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimShapeRight(id: UUID, originStart: Double, originEnd: Double)
        case trimFilterLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimFilterRight(id: UUID, originStart: Double, originEnd: Double)
        case trimAdjustLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimAdjustRight(id: UUID, originStart: Double, originEnd: Double)
        case trimEffectLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimEffectRight(id: UUID, originStart: Double, originEnd: Double)
        case trimCompoundLeft(id: UUID, originStart: Double, originEnd: Double, originInternalStart: Double)
        case trimCompoundRight(id: UUID, originStart: Double, originEnd: Double)
        case movingPlayhead
        case resizeTrack(TrackKind)
        case box
        case ignored
    }

    struct DragItem {
        enum Kind { case video, image, audio, subtitle, text, shape, compound }
        let id: UUID
        let kind: Kind
        let originStart: Double
        let originDur: Double
        var srcTrack: Int = 0
    }

    private enum ClipHit {
        case video(id: UUID, start: Double, dur: Double)
        case image(id: UUID, start: Double, dur: Double)
        case audio(id: UUID, start: Double, dur: Double)
        case subtitle(id: UUID, start: Double, dur: Double)
        case text(id: UUID, start: Double, dur: Double)
        case shape(id: UUID, start: Double, dur: Double)
        case filter(id: UUID, start: Double, dur: Double)
        case adjust(id: UUID, start: Double, dur: Double)
        case effect(id: UUID, start: Double, dur: Double)
        case compound(id: UUID, start: Double, dur: Double, trackIndex: Int, clipIndex: Int)

        var id: UUID {
            switch self {
            case .video(let id, _, _), .image(let id, _, _), .audio(let id, _, _), .subtitle(let id, _, _), .text(let id, _, _), .shape(let id, _, _), .filter(let id, _, _), .adjust(let id, _, _), .effect(let id, _, _), .compound(let id, _, _, _, _):
                return id
            }
        }
        var start: Double {
            switch self {
            case .video(_, let s, _), .image(_, let s, _), .audio(_, let s, _), .subtitle(_, let s, _), .text(_, let s, _), .shape(_, let s, _), .filter(_, let s, _), .adjust(_, let s, _), .effect(_, let s, _), .compound(_, let s, _, _, _):
                return s
            }
        }
        var duration: Double {
            switch self {
            case .video(_, _, let d), .image(_, _, let d), .audio(_, _, let d), .subtitle(_, _, let d), .text(_, _, let d), .shape(_, _, let d), .filter(_, _, let d), .adjust(_, _, let d), .effect(_, _, let d), .compound(_, _, let d, _, _):
                return d
            }
        }
    }

    private enum TrackKind: Equatable { case image(Int), video(Int), audio(Int), subtitle(Int), text(Int), shape(Int), filter(Int), adjust(Int), effect(Int), compound(Int) }
    private enum ClipTrimEdge { case left, right }

    // Custom trim cursors: trapezoid + triangle indicating direction
    private static func makeTrimCursorImage(leftSide: Bool) -> NSImage {
        let w: CGFloat = 20, h: CGFloat = 22
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setShouldAntialias(true)

            if leftSide {
                // 微梯形：左窄右宽，宽度减半
                let trap = CGMutablePath()
                trap.move(to: CGPoint(x: 4, y: 3))
                trap.addLine(to: CGPoint(x: 7, y: 1))
                trap.addLine(to: CGPoint(x: 7, y: 21))
                trap.addLine(to: CGPoint(x: 4, y: 19))
                trap.closeSubpath()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(trap); ctx.strokePath()
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                ctx.addPath(trap); ctx.fillPath()

                // 右三角 ▶
                let tri = CGMutablePath()
                tri.move(to: CGPoint(x: 11, y: 7))
                tri.addLine(to: CGPoint(x: 16, y: 11))
                tri.addLine(to: CGPoint(x: 11, y: 15))
                tri.closeSubpath()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.0)
                ctx.addPath(tri); ctx.strokePath()
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                ctx.addPath(tri); ctx.fillPath()
            } else {
                // 微梯形：右窄左宽，宽度减半
                let trap = CGMutablePath()
                trap.move(to: CGPoint(x: 13, y: 1))
                trap.addLine(to: CGPoint(x: 16, y: 3))
                trap.addLine(to: CGPoint(x: 16, y: 19))
                trap.addLine(to: CGPoint(x: 13, y: 21))
                trap.closeSubpath()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(trap); ctx.strokePath()
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                ctx.addPath(trap); ctx.fillPath()

                // 左三角 ◀
                let tri = CGMutablePath()
                tri.move(to: CGPoint(x: 9, y: 7))
                tri.addLine(to: CGPoint(x: 4, y: 11))
                tri.addLine(to: CGPoint(x: 9, y: 15))
                tri.closeSubpath()
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.0)
                ctx.addPath(tri); ctx.strokePath()
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                ctx.addPath(tri); ctx.fillPath()
            }
            return true
        }
    }

    static let trimLeftCursor: NSCursor = {
        NSCursor(image: makeTrimCursorImage(leftSide: true), hotSpot: NSPoint(x: 6, y: 11))
    }()

    static let trimRightCursor: NSCursor = {
        NSCursor(image: makeTrimCursorImage(leftSide: false), hotSpot: NSPoint(x: 14, y: 11))
    }()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                labelColumn
                clipArea
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: VScrollOffsetKey.self,
                                       value: g.frame(in: .named("tlVScroll")).minY)
            })
        }
        .coordinateSpace(name: "tlVScroll")
        .onPreferenceChange(VScrollOffsetKey.self) { v in
            let off = max(0, -v)
            if abs(vScrollOffset - off) > 0.5 { vScrollOffset = off }
        }
        .background(GeometryReader { geo in
            let _ = DispatchQueue.main.async { viewportH = geo.size.height }
            Color.clear
        })
        .clipped()
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let delta = value / lastMagnifyValue
                    project.zoomTo(project.pixelsPerSecond * Double(delta))
                    lastMagnifyValue = value
                }
                .onEnded { _ in
                    lastMagnifyValue = 1.0
                }
        )
        .overlay(alignment: .topLeading) {
            // 固定顶条：刻度尺 + 播放头三角。位于竖向滚动内容之外 → 竖滑永远不动。
            GeometryReader { geo in
                let clipW = max(geo.size.width - labelW, 0)
                HStack(spacing: 0) {
                    // 左角："+" 添加轨道菜单（顶条里唯一可点的部分）
                    addTrackMenu

                    ZStack(alignment: .topLeading) {
                        // 刻度必须画到跟内容区一样远。原来只画到 max(duration,
                        // contentEndTime)，而内容区还多带 300pt 余量——那截尾巴滚得
                        // 过去却没有刻度，就是时间轴最右边空一块的原因
                        TimelineRuler(pps: project.pixelsPerSecond,
                                      duration: project.timelineContentWidth(viewportWidth: clipW)
                                                / max(project.pixelsPerSecond, 0.001),
                                      scrollOffsetX: scrollOffsetX, vpWidth: clipW)
                            .frame(width: clipW, height: rulerH)
                        // 播放头三角 + 补一段竖线到顶条底部，与轨道区竖线无缝相接
                        Canvas { ctx, _ in
                            let px = clock.currentTime * project.pixelsPerSecond - scrollOffsetX
                            var tri = Path()
                            tri.move(to: CGPoint(x: px, y: 16))
                            tri.addLine(to: CGPoint(x: px - 5, y: 6))
                            tri.addLine(to: CGPoint(x: px + 5, y: 6))
                            tri.closeSubpath()
                            ctx.fill(tri, with: .color(Color.accent))
                            let connector = CGRect(x: px - 0.5, y: 16, width: 1, height: rulerH - 16)
                            ctx.fill(Path(connector), with: .color(Color.accent))
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: clipW, height: rulerH)
                    .background(Color.clear)   // 底色交给外层的系统材质
                    .clipped()
                    // 顶条自己接管点击/拖拽定位播放头，不再靠 allowsHitTesting(false)
                    // 把事件漏给下层的滚动内容去处理。
                    //
                    // 原来那套在竖滑之后必然失效：顶条是 overlay、盖在滚动区上面，
                    // 漏下去之后由统一手势用 `loc.y < rulerH` 判断"是不是点在刻度尺"，
                    // 而那个 loc 是**滚动内容**的坐标 = 屏幕坐标 + 竖滚量。轨道一多、
                    // 竖滑超过 26pt，点顶条漏下去的 loc.y 就已经大于 rulerH，判断落空，
                    // 事件被当成点轨道区，于是选中了刻度尺正下方那条片段、播放头不动。
                    //
                    // 顶条固定不滚，它的 local 坐标恒等于屏幕坐标，这里直接算时间即可。
                    // x 要加回 scrollOffsetX 换算到内容坐标系——正是刻度尺画播放头三角
                    // 那个公式（px = time*pps - scrollOffsetX）的逆运算。
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let t = max(0, (v.location.x + scrollOffsetX) / project.pixelsPerSecond)
                                project.requestSeek(to: t)
                            }
                    )
                }
            }
            .frame(height: rulerH)
        }
        // 播放头：三角在固定顶条，竖线在轨道区(DraggablePlayhead)，两者同一横向公式，不会分离
        // 翻译进度已移至右下角全局浮层
        .onAppear { setupMonitors() }
        .onDisappear { teardownMonitors() }
        .onChange(of: clock.currentTime) { _ in
            if project.selectedMarkerID != nil { project.selectedMarkerID = nil }
        }
    }

    private func setupMonitors() {
        // Delete key → delete selected clips.
        // Only skip when the user is actively editing text in a field editor
        // (an NSTextView acting as field editor inside an NSTextField).
        // Inspector panels contain TextFields but only block delete while focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // local monitor 是**进程级**的，每个窗口都会装一个。不按当前窗口过滤的话，
            // 按一次 ⌘Z 所有打开的项目一起撤销、按一次空格所有预览一起播/停、
            // 删除键把每个窗口选中的片段都删掉（跟菜单命令当初那个
            // 「保存把所有项目都存一遍」是同一类问题）
            guard WindowManager.shared.window(for: windowID)?.isKeyWindow == true else {
                return event
            }
            // **弹窗开着时键盘归弹窗**。封面设计里按删除键本来是要删封面上的图层，
            // 这儿不让开的话事件先被吃掉，还会顺手把时间轴上选中的片段删了
            if project.showCoverDesigner || project.showExportSheet {
                return event
            }
            // 文本编辑中不拦截（包括 NSTextField 的 field editor 和 SwiftUI TextEditor 的独立 NSTextView）
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return event
            }

            // Esc → 取消选择（钢笔绘制/编辑时跳过，让 PenDrawingOverlay 处理）
            if event.keyCode == 53, !project.penDrawingMode, project.penEditingClipID == nil {
                project.selectedVideoClipID      = nil
                project.selectedImageClipID      = nil
                project.selectedAudioClipID      = nil
                project.selectedSubtitleClipID   = nil
                project.selectedCompoundClipID   = nil
                project.selectedTransitionClipID = nil
                project.selectedClipIDs.removeAll()
                return nil
            }

            // ⌫ or ⌦ → 删除（有撤销兜底，无需确认）
            if event.keyCode == 51 || event.keyCode == 117 {
                project.deleteSelected()
                return nil
            }

            // ⌘C → 复制
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
                project.copySelected()
                return nil
            }
            // ⌘X → 剪切
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "x" {
                project.cutSelected()
                return nil
            }
            // ⌘V → 粘贴到播放头位置
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                project.pasteAtPlayhead()
                return nil
            }
            // ⌘⇧Z → 重做（先检查，避免被⌘Z拦截）
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift)
                && event.charactersIgnoringModifiers?.lowercased() == "z" {
                project.redo()
                return nil
            }
            // 画布开着的时候，键盘归画布管。
            // 光靠画布那层 monitor 吞不住 —— 多个 local monitor 谁先拿到事件
            // 取决于注册顺序，时间轴这个装得早，空格照样会被它拿去播放/暂停
            if project.showCanvas { return event }

            // ⌘Z → 撤销
            if event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "z" {
                project.undo()
                return nil
            }

            // 空格键 → 播放/暂停。
            // 走 clock（每个窗口一份）而不是 NotificationCenter 裸广播——
            // 那个通知没有目标窗口，所有窗口的 PlayerView 都会收到
            if event.keyCode == 49 {
                clock.togglePlaybackRequest &+= 1
                return nil
            }

            return event
        }

        // Command + scroll wheel → zoom timeline (pixelsPerSecond)，以播放头为中心
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            // 画布开着时滚轮归画布（⌘+滚轮缩画布，普通滚轮平移画布）
            if project.showCanvas { return event }

            // Shift + 滚轮 → 横向滚动时间轴（竖直滚轮不加修饰=纵向滚轨道，走 ScrollView 默认）
            if event.modifierFlags.contains(.shift) {
                let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                if abs(d) > 0, let sv = project.timelineHScrollView, let doc = sv.documentView {
                    DispatchQueue.main.async {
                        let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
                        let newX = (sv.contentView.bounds.origin.x - d).clamped(to: 0...maxX)
                        sv.contentView.scroll(to: NSPoint(x: newX, y: 0))
                        sv.reflectScrolledClipView(sv.contentView)
                    }
                }
                return nil  // consume
            }
            // Command + 滚轮 → 缩放
            guard event.modifierFlags.contains(.command) else { return event }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(delta) > 0 else { return event }
            DispatchQueue.main.async {
                let factor = delta > 0 ? 1.08 : 1.0 / 1.08
                project.zoomTo(project.pixelsPerSecond * Double(factor))
            }
            return nil  // consume — prevents scroll view from also scrolling
        }

    }

    private func teardownMonitors() {
        if let m = keyMonitor     { NSEvent.removeMonitor(m); keyMonitor     = nil }
        if let m = scrollMonitor  { NSEvent.removeMonitor(m); scrollMonitor  = nil }
    }

    // MARK: Label column

    /// "+" 添加轨道菜单：放在固定顶条左角，不随竖滑动
    private var addTrackMenu: some View {
        Menu {
            // 这个 + 就是"新建空轨"，任何时候都该可用，不做置灰
            Button("添加视频轨道") {
                project.videoTracks.append(Track(label: "视频"))
                project.syncVideoSectionOrder()
            }
            Button("添加图片轨道") { project.imageTracks.append(Track(label: "图片")); project.syncOverlayOrder() }
            Button("添加音频轨道") { project.audioTracks.append(Track(label: "音频")); project.syncAudioSectionOrder() }
            Button("添加字幕轨道") {
                var newTrack = Track<SubtitleClip>(label: "字幕")
                newTrack.subtitleStyle = SubtitleStyle()
                project.subtitleTracks.append(newTrack)
                project.syncOverlayOrder()
            }
            Button("添加文字轨道") { project.textTracks.append(Track(label: "文字")); project.syncOverlayOrder() }
            Button("添加图形轨道") { project.shapeTracks.append(Track(label: "图形")); project.syncOverlayOrder() }
        } label: {
            Text("")
                .frame(width: labelW, height: rulerH)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: labelW, height: rulerH)
        .overlay {
            Image(nsImage: TimelineSVGIcon.load("add"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(Color.labelSecondary)
                .allowsHitTesting(false)
        }
        .background(Color.clear)   // 底色交给外层的系统材质
    }

    private var labelColumn: some View {
        VStack(spacing: 0) {
            // 顶部留出刻度尺高度（"+" 已移到固定顶条），保持标签与轨道竖向对齐
            Color.clear.frame(height: rulerH)

            VStack(spacing: 1) {
            // Overlay tracks (image/subtitle/text) — unified order
            ForEach(Array(visibleOverlays.enumerated()), id:\.element.trackID) { ovIdx, entry in
                overlayLabel(entry: entry, overlayIndex: ovIdx)
                    .frame(height: overlayH(entry))
                    .offset(y: isTrackDragging(.overlay, ovIdx) ? trackLabelDragOffset : 0)
                    .zIndex(isTrackDragging(.overlay, ovIdx) ? 10 : 0)
                    .opacity(isTrackDragging(.overlay, ovIdx) ? 0.55 : 1.0)
            }
            if project.showVideoTracks {
                let vs = resolvedVideoSection
                ForEach(vs.indices, id:\.self) { secIdx in
                    let item = vs[secIdx]
                    if item.kind == .video {
                        let i = item.trackIndex
                        TrackLabel(icon:"video", title: project.videoTracks[i].label,
                                   count: project.videoTracks[i].clips.count, hasMute: true,
                                   isMuted: project.videoTracks[i].isMuted, isVis: project.videoTracks[i].isVisible,
                                   onMute: { project.pushUndo(); project.videoTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                                   onVis:  { project.pushUndo(); project.videoTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                                   onDel:  { project.pushUndo(); project.videoTracks.remove(at:i); project.syncVideoSectionOrder(); project.rebuildTimelinePreview() },
                                   onDragChanged: { handleDragChanged(type: .video, index: secIdx, offsetY: $0) },
                                   onDragEnded:   { handleDragEnded(type: .video, index: secIdx, offsetY: $0) })
                            .frame(height: vidH(i))
                            .offset(y: isTrackDragging(.video, secIdx) ? trackLabelDragOffset : 0)
                            .zIndex(isTrackDragging(.video, secIdx) ? 10 : 0)
                            .opacity(isTrackDragging(.video, secIdx) ? 0.55 : 1.0)
                    } else {
                        let ti = item.trackIndex
                        compoundTrackLabel(ti, dragType: .video, secIdx: secIdx)
                            .frame(height: cmpH(ti))
                            .offset(y: isTrackDragging(.video, secIdx) ? trackLabelDragOffset : 0)
                            .zIndex(isTrackDragging(.video, secIdx) ? 10 : 0)
                            .opacity(isTrackDragging(.video, secIdx) ? 0.55 : 1.0)
                    }
                }
            }
            if project.showAudioTracks {
                let as_ = resolvedAudioSection
                ForEach(as_.indices, id:\.self) { secIdx in
                    let item = as_[secIdx]
                    if item.kind == .audio {
                        let i = item.trackIndex
                        TrackLabel(icon:"audio", title: project.audioTracks[i].label,
                                   count: project.audioTracks[i].clips.count, hasMute: true,
                                   isMuted: project.audioTracks[i].isMuted, isVis: true, hasVis: false,
                                   onMute: { project.pushUndo(); project.audioTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                                   onVis:  {},
                                   onDel:  { project.pushUndo(); project.audioTracks.remove(at:i); project.syncAudioSectionOrder(); project.rebuildTimelinePreview() },
                                   onDragChanged: { handleDragChanged(type: .audio, index: secIdx, offsetY: $0) },
                                   onDragEnded:   { handleDragEnded(type: .audio, index: secIdx, offsetY: $0) })
                            .frame(height: audH(i))
                            .offset(y: isTrackDragging(.audio, secIdx) ? trackLabelDragOffset : 0)
                            .zIndex(isTrackDragging(.audio, secIdx) ? 10 : 0)
                            .opacity(isTrackDragging(.audio, secIdx) ? 0.55 : 1.0)
                    } else {
                        let ti = item.trackIndex
                        compoundTrackLabel(ti, dragType: .audio, secIdx: secIdx)
                            .frame(height: cmpH(ti))
                            .offset(y: isTrackDragging(.audio, secIdx) ? trackLabelDragOffset : 0)
                            .zIndex(isTrackDragging(.audio, secIdx) ? 10 : 0)
                            .opacity(isTrackDragging(.audio, secIdx) ? 0.55 : 1.0)
                    }
                }
            }
            } // end inner VStack
            .overlay(trackDropIndicatorLine())
            .background(Color.clear)   // 底色交给外层的系统材质
        }
        .frame(width: labelW)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func compoundTrackLabel(_ ti: Int, dragType: TrackDragType? = nil, secIdx: Int = 0) -> some View {
        TrackLabel(icon: "compound", title: project.compoundTracks[ti].label.isEmpty ? "复合" : project.compoundTracks[ti].label,
                   count: project.compoundTracks[ti].clips.count, hasMute: true,
                   isMuted: project.compoundTracks[ti].isMuted, isVis: project.compoundTracks[ti].isVisible,
                   onMute: { project.pushUndo(); project.compoundTracks[ti].isMuted.toggle(); project.rebuildTimelinePreview() },
                   onVis:  { project.pushUndo(); project.compoundTracks[ti].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                   onDel:  { project.pushUndo(); project.compoundTracks.remove(at: ti); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                   onDragChanged: { dy in if let dt = dragType { handleDragChanged(type: dt, index: secIdx, offsetY: dy) } },
                   onDragEnded:   { dy in if let dt = dragType { handleDragEnded(type: dt, index: secIdx, offsetY: dy) } })
    }

    private struct ResolvedOverlay {
        enum Kind { case image, subtitle, text, shape, filter, adjust, effect, compound }
        let kind: Kind
        let index: Int
        let trackID: UUID
    }

    private var resolvedOverlays: [ResolvedOverlay] {
        project.overlayTrackOrder.compactMap { ref in
            switch ref {
            case .image(let id):
                guard let i = project.imageTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .image, index: i, trackID: id)
            case .subtitle(let id):
                guard let i = project.subtitleTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .subtitle, index: i, trackID: id)
            case .text(let id):
                guard let i = project.textTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .text, index: i, trackID: id)
            case .shape(let id):
                guard let i = project.shapeTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .shape, index: i, trackID: id)
            case .filter(let id):
                guard let i = project.filterTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .filter, index: i, trackID: id)
            case .adjust(let id):
                guard let i = project.adjustTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .adjust, index: i, trackID: id)
            case .effect(let id):
                guard let i = project.effectTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return ResolvedOverlay(kind: .effect, index: i, trackID: id)
            case .compound(let id):
                guard let i = project.compoundTracks.firstIndex(where: { $0.id == id }),
                      project.compoundTrackKind(project.compoundTracks[i]) == .overlay else { return nil }
                return ResolvedOverlay(kind: .compound, index: i, trackID: id)
            }
        }
    }

    private var visibleOverlays: [ResolvedOverlay] {
        resolvedOverlays.filter { entry in
            switch entry.kind {
            case .image: return project.showImageTracks
            case .subtitle: return project.showSubtitleTracks
            case .text: return project.showTextTracks
            case .shape: return project.showShapeTracks
            case .filter, .adjust, .effect: return true   // 这三类没有单独的显隐开关
            case .compound: return project.showCompoundTracks
            }
        }
    }

    private func overlayH(_ entry: ResolvedOverlay) -> CGFloat {
        switch entry.kind {
        case .image: return imgH(entry.index)
        case .subtitle: return subH(entry.index)
        case .text: return txtH(entry.index)
        case .shape: return shpH(entry.index)
        case .filter, .adjust, .effect: return defaultSubTrackH   // 固定用字幕那一档
        case .compound: return cmpH(entry.index)
        }
    }

    private var videoCompoundIndices: [Int] {
        project.compoundTracks.indices.filter { project.compoundTrackKind(project.compoundTracks[$0]) == .video }
    }
    private var audioCompoundIndices: [Int] {
        project.compoundTracks.indices.filter { project.compoundTrackKind(project.compoundTracks[$0]) == .audio }
    }

    private struct SectionItem {
        enum Kind { case video, compound, audio }
        let kind: Kind
        let trackIndex: Int
    }

    private var resolvedVideoSection: [SectionItem] {
        project.videoSectionOrder.compactMap { ref in
            switch ref {
            case .video(let id):
                guard let idx = project.videoTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return SectionItem(kind: .video, trackIndex: idx)
            case .compound(let id):
                guard project.showCompoundTracks else { return nil }
                guard let idx = project.compoundTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return SectionItem(kind: .compound, trackIndex: idx)
            }
        }
    }

    private var resolvedAudioSection: [SectionItem] {
        project.audioSectionOrder.compactMap { ref in
            switch ref {
            case .audio(let id):
                guard let idx = project.audioTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return SectionItem(kind: .audio, trackIndex: idx)
            case .compound(let id):
                guard project.showCompoundTracks else { return nil }
                guard let idx = project.compoundTracks.firstIndex(where: { $0.id == id }) else { return nil }
                return SectionItem(kind: .compound, trackIndex: idx)
            }
        }
    }

    private func videoSectionH(_ item: SectionItem) -> CGFloat {
        item.kind == .video ? vidH(item.trackIndex) : cmpH(item.trackIndex)
    }
    private func audioSectionH(_ item: SectionItem) -> CGFloat {
        item.kind == .audio ? audH(item.trackIndex) : cmpH(item.trackIndex)
    }

    private func trackLabelDropTarget(type: TrackDragType, source: Int, offset: CGFloat) -> Int {
        let count: Int
        let heights: [CGFloat]
        switch type {
        case .video:
            let vs = resolvedVideoSection
            count = vs.count
            heights = vs.map { videoSectionH($0) }
        case .audio:
            let as_ = resolvedAudioSection
            count = as_.count
            heights = as_.map { audioSectionH($0) }
        case .overlay:
            let ovs = visibleOverlays
            count = ovs.count
            heights = ovs.map { overlayH($0) }
        }
        guard count > 1 else { return source }
        var centerY: CGFloat = 0
        for j in 0..<source { centerY += heights[j] + 1 }
        centerY += heights[source] / 2 + offset
        var top: CGFloat = 0
        for j in 0..<count {
            if centerY < top + heights[j] / 2 { return j }
            top += heights[j] + 1
        }
        return count - 1
    }

    private func handleDragChanged(type: TrackDragType, index: Int, offsetY: CGFloat) {
        if trackLabelDragType == nil {
            trackLabelDragType = type
            trackLabelDragSrc = index
        }
        trackLabelDragOffset = offsetY
        let target = trackLabelDropTarget(type: type, source: trackLabelDragSrc, offset: offsetY)
        trackLabelDropIdx = target != trackLabelDragSrc ? target : nil
    }

    private func handleDragEnded(type: TrackDragType, index: Int, offsetY: CGFloat) {
        let target = trackLabelDropTarget(type: type, source: trackLabelDragSrc, offset: offsetY)
        if target != trackLabelDragSrc {
            project.pushUndo()
            switch type {
            case .video:
                let item = project.videoSectionOrder.remove(at: trackLabelDragSrc)
                project.videoSectionOrder.insert(item, at: target)
            case .audio:
                let item = project.audioSectionOrder.remove(at: trackLabelDragSrc)
                project.audioSectionOrder.insert(item, at: target)
            case .overlay:
                let ovs = visibleOverlays
                guard trackLabelDragSrc < ovs.count, target < ovs.count else { break }
                let srcID = ovs[trackLabelDragSrc].trackID
                let dstID = ovs[target].trackID
                if let si = project.overlayTrackOrder.firstIndex(where: { $0.trackID == srcID }),
                   let di = project.overlayTrackOrder.firstIndex(where: { $0.trackID == dstID }) {
                    let item = project.overlayTrackOrder.remove(at: si)
                    project.overlayTrackOrder.insert(item, at: di)
                }
            }
            project.rebuildTimelinePreview()
        }
        trackLabelDragType = nil
        trackLabelDragOffset = 0
        trackLabelDropIdx = nil
    }

    @ViewBuilder
    private func overlayLabel(entry: ResolvedOverlay, overlayIndex: Int) -> some View {
        let i = entry.index
        let ovIdx = overlayIndex
        switch entry.kind {
        case .image:
            TrackLabel(icon:"image", title: project.imageTracks[i].label,
                       count: project.imageTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.imageTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.imageTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.imageTracks.remove(at:i); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .subtitle:
            TrackLabel(icon:"subtitle", title: project.subtitleTracks[i].label,
                       count: project.subtitleTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.subtitleTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.subtitleTracks[i].isVisible.toggle()
                                 // 内容归合成器画时，光改标志位画面不会动
                                 project.refreshOverlayComposite() },
                       onDel:  { project.pushUndo(); project.subtitleTracks.remove(at:i); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .text:
            TextTrackLabel(title: project.textTracks[i].label,
                       count: project.textTracks[i].clips.count,
                       isVis: project.textTracks[i].isVisible,
                       onVis:  { project.pushUndo(); project.textTracks[i].isVisible.toggle()
                                 // 内容归合成器画时，光改标志位画面不会动
                                 project.refreshOverlayComposite() },
                       onDel:  { project.pushUndo(); project.textTracks.remove(at:i); project.syncOverlayOrder() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .shape:
            TrackLabel(icon:"shape", title: project.shapeTracks[i].label,
                       count: project.shapeTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.shapeTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.shapeTracks[i].isVisible.toggle()
                                 // 内容归合成器画时，光改标志位画面不会动
                                 project.refreshOverlayComposite() },
                       onDel:  { project.pushUndo(); project.shapeTracks.remove(at:i); project.syncOverlayOrder() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .filter:
            TrackLabel(icon:"filter", title: project.filterTracks[i].label.isEmpty ? "滤镜" : project.filterTracks[i].label,
                       count: project.filterTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.filterTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.filterTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.filterTracks.remove(at:i)
                                 project.clearClipSelections()
                                 project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .adjust:
            TrackLabel(icon:"adjust", title: project.adjustTracks[i].label.isEmpty ? "调节" : project.adjustTracks[i].label,
                       count: project.adjustTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.adjustTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.adjustTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.adjustTracks.remove(at:i)
                                 project.clearClipSelections()
                                 project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .effect:
            TrackLabel(icon:"effect", title: project.effectTracks[i].label.isEmpty ? "特效" : project.effectTracks[i].label,
                       count: project.effectTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.effectTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.effectTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.effectTracks.remove(at:i)
                                 project.clearClipSelections()
                                 project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .compound:
            TrackLabel(icon:"compound", title: project.compoundTracks[i].label.isEmpty ? "复合" : project.compoundTracks[i].label,
                       count: project.compoundTracks[i].clips.count, hasMute: true,
                       isMuted: project.compoundTracks[i].isMuted, isVis: project.compoundTracks[i].isVisible,
                       onMute: { project.pushUndo(); project.compoundTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                       onVis:  { project.pushUndo(); project.compoundTracks[i].isVisible.toggle(); project.refreshOverlayComposite(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.compoundTracks.remove(at:i); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        }
    }

    private func trackDropLineY() -> CGFloat? {
        guard let dragType = trackLabelDragType, let dropIdx = trackLabelDropIdx else { return nil }
        let heights: [CGFloat]
        var baseY: CGFloat
        switch dragType {
        case .overlay:
            let ovs = visibleOverlays
            heights = ovs.map { overlayH($0) }
            baseY = 0
        case .video:
            let vs = resolvedVideoSection
            heights = vs.map { videoSectionH($0) }
            let ovs = visibleOverlays
            baseY = ovs.reduce(CGFloat(0)) { $0 + overlayH($1) } + (ovs.isEmpty ? 0 : CGFloat(ovs.count))
        case .audio:
            let as_ = resolvedAudioSection
            heights = as_.map { audioSectionH($0) }
            let ovs = visibleOverlays
            baseY = ovs.reduce(CGFloat(0)) { $0 + overlayH($1) } + (ovs.isEmpty ? 0 : CGFloat(ovs.count))
            if project.showVideoTracks {
                let vs = resolvedVideoSection
                baseY += vs.reduce(CGFloat(0)) { $0 + videoSectionH($1) } + CGFloat(vs.count)
            }
        }
        let insertBefore = dropIdx < trackLabelDragSrc
        let lineIdx = insertBefore ? dropIdx : dropIdx + 1
        var lineY = baseY
        for j in 0..<min(lineIdx, heights.count) {
            lineY += heights[j] + 1
        }
        return lineY
    }

    @ViewBuilder
    private func trackDropIndicatorLine() -> some View {
        if let lineY = trackDropLineY() {
            Rectangle()
                .fill(Color.accent)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .offset(y: lineY - 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }

    private func updateVisibleWidth(_ w: Double) {
        if abs(project.timelineVisibleWidth - w) > 1 {
            DispatchQueue.main.async { project.timelineVisibleWidth = w }
        }
    }

    // MARK: Clip scroll area

    private var clipArea: some View {
        GeometryReader { visibleGeo in
            let visibleW = visibleGeo.size.width
            let _ = updateVisibleWidth(visibleW)
            // 末尾余量给足一屏（原来是固定 300pt）。两个作用：素材能往内容之后拖，
            // 以及内容很短时滚动条不会长得几乎占满整条轨道——滚动条长度就是
            // 「视口 / 内容宽」，余量太小它就短不下来
            let contentW = project.timelineContentWidth(viewportWidth: visibleW)
            let totalW = max(contentW, max(visibleW, 800))
            let effectiveH = max(totalContentH(), viewportH)
            ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    TimelineScrollViewFinder(project: project, onScroll: { frac, vpFrac, offX in
                        scrollFraction = frac
                        scrollViewportFraction = vpFrac
                        scrollOffsetX = offX
                        // 滚一下就亮，并把"停手收起"的倒计时往后推
                        scrollBarScrolling = true
                        scrollIdleWork?.cancel()
                        let work = DispatchWorkItem { scrollBarScrolling = false }
                        scrollIdleWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                    })
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: rulerH).allowsHitTesting(false)
                        trackRows
                    }

                    if let s = boxStart, let e = boxEnd {
                        let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                          width: abs(e.x - s.x), height: abs(e.y - s.y))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.accent.opacity(0.7), lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }

                    if let gPos = dragGhostPos {
                        if multiGhosts.isEmpty {
                            if let ghostInfo = dragGhostInfo() {
                                ghostView(ghostInfo).position(x: gPos.x, y: gPos.y)
                            }
                        } else {
                            // 多选：整组一起跟手，各自保持拖动开始时的相对位置
                            ForEach(multiGhosts) { g in
                                ghostView(g.info).position(x: gPos.x + g.dx, y: gPos.y + g.dy)
                            }
                        }
                    }

                    // 吸附指示线（延伸到视口底部）
                    if let snapT = activeSnapTime {
                        let snapX = snapT * project.pixelsPerSecond
                        Rectangle()
                            .fill(Color.accent)
                            .frame(width: 1)
                            .position(x: snapX, y: effectiveH / 2)
                            .frame(height: effectiveH)
                            .allowsHitTesting(false)
                    }

                    DraggablePlayhead(pps: project.pixelsPerSecond, fullHeight: effectiveH,
                                      topInset: rulerH)
                        .zIndex(10)

                    if let hid = hoveredMarkerID, editingMarkerID == nil,
                       let hm = project.allMarkersAbsolute.first(where: { $0.id == hid }) {
                        let t = hm.absoluteTime
                        let mm = Int(t) / 60, ss = Int(t) % 60, ff = Int((t - floor(t)) * 30)
                        VStack(spacing: 2) {
                            Text(hm.marker.title.isEmpty ? "标记" : hm.marker.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.labelPrimary)
                            Text(String(format: "%02d:%02d:%02d", mm, ss, ff))
                                .font(.system(size: 9))
                                .foregroundColor(Color.labelSecondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.18, green: 0.18, blue: 0.19)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        .fixedSize()
                        .position(x: t * project.pixelsPerSecond + 1, y: hoveredMarkerY + 17)
                        .zIndex(12)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: totalW, alignment: .topLeading)
                .frame(minHeight: effectiveH)
                .contentShape(Rectangle())
                .contextMenu {
                    let selID = project.selectedVideoClipID ?? project.selectedImageClipID
                              ?? project.selectedAudioClipID ?? project.selectedSubtitleClipID
                              ?? project.selectedTextClipID ?? project.selectedShapeClipID
                              ?? project.selectedCompoundClipID
                              ?? project.selectedClipIDs.first
                    if let mid = project.selectedMarkerID, selID == nil {
                        Button(role: .destructive) {
                            project.removeMarker(id: mid)
                        } label: { Label("删除标记", systemImage: "xmark.circle") }
                    } else {
                        if let id = selID {
                            Button { project.selectLeftOf(id) } label: {
                                Image(nsImage: SidebarSVGIcon.load("selectLeft", size: 14))
                                Text("向左全选")
                            }
                            Button { project.selectRightOf(id) } label: {
                                Image(nsImage: SidebarSVGIcon.load("selectRight", size: 14))
                                Text("向右全选")
                            }
                            Divider()
                        }
                        if let textID = project.selectedTextClipID, project.selectedClipIDs.isEmpty {
                            Button {
                                project.saveTextTemplateFromClip(textID)
                            } label: {
                                Image(nsImage: SidebarSVGIcon.load("saveTextTemplate", size: 14))
                                Text("保存为文字模板")
                            }
                            Divider()
                        }
                        // 复制/剪切认的范围比 selID 大：滤镜和调节也能复制，
                        // 但「向左全选」「创建复合片段」那些对它们没有意义，
                        // 所以不直接把它们并进 selID
                        let canCopy = selID != nil || project.isEffectClipSelected
                        Button { project.copySelected() } label: {
                            Image(nsImage: SidebarSVGIcon.load("copy", size: 14))
                            Text("复制")
                        }
                            .disabled(!canCopy)
                        Button { project.cutSelected() } label: {
                            Image(nsImage: SidebarSVGIcon.load("cut", size: 14))
                            Text("剪切")
                        }
                            .disabled(!canCopy)
                        Button { project.pasteAtPlayhead() } label: {
                            Image(nsImage: SidebarSVGIcon.load("paste", size: 14))
                            Text("粘贴")
                        }
                            .disabled(project.clipboard.isEmpty)
                        clipTypeMenuItems
                        if selID != nil {
                            Divider()
                            Button { project.createCompoundFromSelected() } label: {
                                Image(nsImage: SidebarSVGIcon.load("compound", size: 14))
                                Text("创建复合片段")
                            }
                            if let rid = project.selectedVideoClipID ?? project.selectedImageClipID
                                        ?? project.selectedAudioClipID {
                                Button { project.renamingClipID = rid } label: {
                                    Image(nsImage: SidebarSVGIcon.load("rename", size: 14))
                                    Text("重命名")
                                }
                                // 源文件没了才给这一项。关联走的是素材，所以关联完
                                // 素材库、其它引用它的片段、画布卡片一起恢复
                                if let aid = project.assetIDOfSelectedClip(rid),
                                   project.missingAssetIDs.contains(aid) {
                                    Button { relinkAssetWithPanel(aid, project: project) } label: {
                                        Image(nsImage: SidebarSVGIcon.load("relink", size: 14))
                                        Text("重新关联文件…")
                                    }
                                }
                            }
                            if let cid = project.selectedCompoundClipID {
                                Button { project.renamingCompoundClipID = cid } label: {
                                    Image(nsImage: SidebarSVGIcon.load("rename", size: 14))
                                    Text("重命名")
                                }
                                Button { project.dissolveCompound(cid) } label: {
                                    Image(nsImage: SidebarSVGIcon.load("dissolveCompound", size: 14))
                                    Text("解除复合片段")
                                }
                            }
                        }
                        // 删除放在 selID 那一块**外面** —— 滤镜/调节/特效不进 selID
                        // （创建复合片段、重命名那些对它们没意义），但删是能删的
                        if canCopy {
                            Divider()
                            Button(role: .destructive) { project.deleteSelected() } label: {
                                Image(nsImage: TimelineSVGIcon.load("delete", size: 14))
                                Text("删除")
                            }
                        }
                        if let mid = project.selectedMarkerID {
                            Divider()
                            Button(role: .destructive) {
                                project.removeMarker(id: mid)
                            } label: { Label("删除标记", systemImage: "xmark.circle") }
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        // 24 必须 ≤ TimelineScrollBar.hitH(22) 对应的实际可点范围，
                        // 否则最下面那几 pt 是"看得见滚动条、却拖不动"的死区。
                        // 这里取 22 跟它对齐
                        scrollBarHovered = loc.y > effectiveH - 22
                        let hoverTime = loc.x / project.pixelsPerSecond
                        if loc.y >= rulerH, let hm = project.allMarkersAbsolute.first(where: {
                            abs($0.absoluteTime - hoverTime) * project.pixelsPerSecond < 6
                        }) {
                            if hoveredMarkerID != hm.id {
                                hoveredMarkerID = hm.id
                                hoveredMarkerY = trackTopFromY(loc.y) + 25
                            }
                        } else {
                            hoveredMarkerID = nil
                        }
                        guard dragOp == nil else { return }
                        if trackGapHit(y: loc.y) != nil {
                            NSCursor.resizeUpDown.set()
                        } else if hitTestTransitionIcon(at: loc) != nil {
                            NSCursor.pointingHand.set()
                        } else if let edge = findClipTarget(at: loc)?.trimEdge {
                            (edge == .left ? Self.trimLeftCursor : Self.trimRightCursor).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    case .ended:
                        // 延迟一拍再收，别立刻置 false。指针从轨道区移到滚动条上时，
                        // 这里会先收到 .ended（滚动条把事件挡住了），而滚动条自己的
                        // onHover 要等它仍然可 hit test 才能触发——立刻置 false 会让
                        // show 瞬间变假、allowsHitTesting 关掉，接管就再也发生不了，
                        // 直接卡死在隐藏。留 0.2s 的交接窗口
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            scrollBarHovered = false
                        }
                        hoveredMarkerID = nil
                        NSCursor.arrow.set()
                    }
                }
                .simultaneousGesture(unifiedDragGesture)
                // 收素材库拖过来的素材。**不能用 `.onDrop`** —— SwiftUI 合并绘制，
                // hitTest 命中的始终是最外层 GatedHostingView，内层的 onDrop 一次都收不到
                // （Finder 拖入排查过一整轮，见 WindowDragGate.swift 顶部）。
                // 所以跟素材区一样：宿主统一收，按落点分发到这里
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { registerTimelineDropZone(g.frame(in: .global)) }
                        .onChange(of: g.frame(in: .global)) { _, r in registerTimelineDropZone(r) }
                        .onDisappear { FileDropRouter.unregister(windowID, kind: .timeline) }
                })
            }


            // 自定义水平滚动条
            if scrollViewportFraction < 1 {
                TimelineScrollBar(
                    fraction: scrollFraction,
                    viewportFraction: scrollViewportFraction,
                    isVisible: scrollBarHovered,
                    isScrolling: scrollBarScrolling,
                    onDrag: { newFrac in
                        guard let sv = project.timelineHScrollView, let doc = sv.documentView else { return }
                        let maxX = doc.frame.width - sv.contentView.bounds.width
                        sv.contentView.scroll(to: NSPoint(x: max(0, newFrac * maxX), y: 0))
                        sv.reflectScrolledClipView(sv.contentView)
                    }
                )
            }
            } // ZStack
        }
    }

    // MARK: Unified drag (clip move + box select)
    //
    // Both clip-drag-to-move AND empty-area-drag-to-box-select are handled by a
    // single DragGesture on the ZStack. We pick the mode at drag-start based on
    // whether the start point lands inside a clip frame.
    //
    // Children with their own gestures (TimelineRuler, DraggablePlayhead) take
    // precedence for clicks on them, so this gesture only fires for drags on
    // the track area / clips.

    private var unifiedDragGesture: some Gesture {
        // minimumDistance: 0 so ruler/triangle area responds on mousedown without any movement.
        // Track-area clip ops still require >3 px before startDrag is called (see below).
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if dragOp == nil {
                    let loc = v.startLocation
                    if loc.y < rulerH {
                        dragOp = .movingPlayhead
                    } else if let kind = trackGapHit(y: loc.y) {
                        // 轨道间隙：开始调整轨道高度
                        dragOp = .resizeTrack(kind)
                    } else if v.translation.width.magnitude > 3 || v.translation.height.magnitude > 3 {
                        startDrag(at: loc)
                    }
                }
                guard let op = dragOp else { return }
                // Track ghost position for move ops (offset so clip stays under grab point)
                switch op {
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle, .moveText, .moveShape,
                     .moveFilter, .moveAdjust, .moveEffect, .moveCompound, .moveMulti:
                    dragGhostPos = CGPoint(x: v.location.x - dragGhostOffset.width,
                                           y: v.location.y - dragGhostOffset.height)
                default: break
                }
                applyDrag(op: op, totalTranslation: v.translation, current: v.location)
            }
            .onEnded { v in
                // 点击（没有拖动）→ 优先检测转场图标，然后选中clip或取消选择
                if dragOp == nil && v.startLocation.y >= rulerH {
                    // 标记 click 检测
                    let clickTime = v.startLocation.x / project.pixelsPerSecond
                    if let hitMA = project.allMarkersAbsolute.first(where: {
                        abs($0.absoluteTime - clickTime) * project.pixelsPerSecond < 6
                    }) {
                        let hitMarker = hitMA.marker
                        if project.selectedMarkerID == hitMarker.id {
                            project.selectedMarkerID = nil
                        } else {
                            project.selectedMarkerID = hitMarker.id
                        }
                        if lastMarkerClickID == hitMarker.id,
                           Date().timeIntervalSince(lastMarkerClickTime) < 0.4 {
                            editingMarkerID = hitMarker.id
                            lastMarkerClickID = nil
                        } else {
                            lastMarkerClickID = hitMarker.id
                            lastMarkerClickTime = Date()
                        }
                        dragOp = nil; return
                    }
                    project.selectedMarkerID = nil
                    // 点轨道区任意位置都结束重命名（输入框失焦会自动提交）
                    if project.renamingClipID != nil || project.renamingCompoundClipID != nil {
                        project.renamingClipID = nil
                        project.renamingCompoundClipID = nil
                    }
                    // 转场图标优先（图标在片段内部，不在边缘）
                    if let transClipID = hitTestTransitionIcon(at: v.startLocation) {
                        project.selectedTransitionClipID = transClipID
                        project.mediaLibraryTab = "transition"
                        project.selectedVideoClipID    = nil
                        project.selectedImageClipID    = nil
                        project.selectedAudioClipID    = nil
                        project.selectedSubtitleClipID = nil
                        project.selectedTextClipID     = nil
                        project.selectedClipIDs.removeAll()
                    }
                    let isShift = NSEvent.modifierFlags.contains(.shift)
                    let hitTransition = hitTestTransitionIcon(at: v.startLocation) != nil
                    if !hitTransition, let (hit, _) = findClipTarget(at: v.startLocation) {
                        if case .compound(let id, _, _, let ti, let ci) = hit, !isShift {
                            if lastCompoundClickID == id && Date().timeIntervalSince(lastCompoundClickTime) < 0.35 {
                                project.enterCompound(trackIndex: ti, clipIndex: ci)
                                lastCompoundClickID = nil
                            } else {
                                lastCompoundClickID = id
                                lastCompoundClickTime = Date()
                                project.selectedCompoundClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                                project.selectedTextClipID = nil
                                project.selectedShapeClipID = nil
                                project.selectedClipIDs.removeAll()
                                project.selectedTransitionClipID = nil
                            }
                        } else if isShift {
                            switch hit {
                            case .video(let id, _, _), .image(let id, _, _),
                                 .audio(let id, _, _), .subtitle(let id, _, _), .text(let id, _, _),
                                 .shape(let id, _, _), .filter(let id, _, _), .adjust(let id, _, _),
                                 .effect(let id, _, _):
                                project.shiftToggleClip(id)
                            case .compound(let id, _, _, _, _):
                                project.shiftToggleClip(id)
                            }
                        } else {
                            // **先一把清干净再设自己的**。逐个列举「把别的置空」
                            // 已经漏过两回了：加滤镜时漏、加特效时又漏，
                            // 表现都是选了别的片段、效果类那条还亮着
                            project.clearClipSelections()
                            project.selectedClipIDs.removeAll()
                            switch hit {
                            case .video(let id, _, _):
                                project.selectedVideoClipID = id
                            case .image(let id, _, _):
                                project.selectedImageClipID = id
                            case .audio(let id, _, _):
                                project.selectedAudioClipID = id
                            case .subtitle(let id, _, _):
                                project.selectedSubtitleClipID = id
                            case .text(let id, _, _):
                                project.selectedTextClipID = id
                            case .shape(let id, _, _):
                                project.selectedShapeClipID = id
                            case .filter(let id, _, _):
                                project.clearClipSelections()
                                project.selectedFilterClipID = id
                            case .adjust(let id, _, _):
                                project.clearClipSelections()
                                project.selectedAdjustClipID = id
                            case .effect(let id, _, _):
                                project.clearClipSelections()
                                project.selectedEffectClipID = id
                            case .compound(let id, _, _, _, _):
                                project.selectedCompoundClipID = id
                            }
                        }
                    } else if !hitTransition {
                        // 点击空白区域：取消选择 + seek。
                        // **走统一的清空**：这里原先是挨个列的，滤镜漏在外面，
                        // 结果点了空白属性区还认为选着滤镜
                        project.clearClipSelections()
                        project.selectedClipIDs.removeAll()
                        project.selectedTransitionClipID = nil
                        let t = max(0, Double(v.startLocation.x) / project.pixelsPerSecond)
                        project.requestSeek(to: t)
                    }
                }
                if case .box = dragOp, let s = boxStart, let e = boxEnd {
                    let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                      width: abs(e.x - s.x), height: abs(e.y - s.y))
                    finalizeBoxSelect(rect: rect)
                }
                // Cross-track move: if the clip was dragged to a different track of the same type
                if let op = dragOp {
                    let endY = v.location.y
                    let destTrack = trackIndexFromY(endY)
                    switch op {
                    case .moveVideo(let id, _, _, let srcTrack):
                        if let dst = destTrack.videoIndex, dst != srcTrack {
                            project.moveVideoClipToTrack(id: id, from: srcTrack, to: dst)
                        } else if destTrack.videoIndex == nil, endY > rulerH {
                            // 落点不在任何视频轨道上（空白区、或音频/字幕等其它类型轨道）：
                            // 新建一条接住它。否则轨道没换、位置却已跟着拖动改了，看起来就是消失
                            project.videoTracks.append(Track(label: "视频"))
                            project.syncVideoSectionOrder()
                            project.moveVideoClipToTrack(id: id, from: srcTrack, to: project.videoTracks.count - 1)
                        }
                    case .moveImage(let id, _, _, let srcTrack):
                        if let dst = destTrack.imageIndex, dst != srcTrack {
                            project.moveImageClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveAudio(let id, _, _, let srcTrack):
                        if let dst = destTrack.audioIndex, dst != srcTrack {
                            project.moveAudioClipToTrack(id: id, from: srcTrack, to: dst)
                        } else if destTrack.audioIndex == nil, endY > rulerH {
                            project.audioTracks.append(Track(label: "音频"))
                            project.syncAudioSectionOrder()
                            project.moveAudioClipToTrack(id: id, from: srcTrack, to: project.audioTracks.count - 1)
                        }
                    case .moveSubtitle(let id, _, _, let srcTrack):
                        if let dst = destTrack.subtitleIndex, dst != srcTrack {
                            project.moveSubtitleClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveText(let id, _, _, let srcTrack):
                        if let dst = destTrack.textIndex, dst != srcTrack {
                            project.moveTextClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveShape(let id, _, _, let srcTrack):
                        if let dst = destTrack.shapeIndex, dst != srcTrack {
                            project.moveShapeClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveFilter(let id, _, _, let srcTrack):
                        if let dst = destTrack.filterIndex, dst != srcTrack {
                            project.moveFilterClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveAdjust(let id, _, _, let srcTrack):
                        if let dst = destTrack.adjustIndex, dst != srcTrack {
                            project.moveAdjustClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveEffect(let id, _, _, let srcTrack):
                        if let dst = destTrack.effectIndex, dst != srcTrack {
                            project.moveEffectClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveCompound(let id, _, _, let srcTrack):
                        if let dst = destTrack.compoundIndex, dst != srcTrack {
                            project.moveCompoundClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveMulti(let items):
                        // 多选整体换轨。只在「所有片段同类型 + 都来自同一条轨道」时做：
                        // 混合类型（比如同时选了字幕和图片）或跨多条源轨道选出来的一组，
                        // 「整体搬到落点那条轨道」没有唯一解——那种情况只平移时间，不动轨道。
                        // 时间平移在 onChanged 里已经做完了，这里只负责换轨道
                        if let first = items.first,
                           items.allSatisfy({ $0.kind == first.kind && $0.srcTrack == first.srcTrack }) {
                            let src = first.srcTrack
                            let ids = items.map(\.id)
                            switch first.kind {
                            case .video:
                                if let dst = destTrack.videoIndex, dst != src {
                                    ids.forEach { project.moveVideoClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .image:
                                if let dst = destTrack.imageIndex, dst != src {
                                    ids.forEach { project.moveImageClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .audio:
                                if let dst = destTrack.audioIndex, dst != src {
                                    ids.forEach { project.moveAudioClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .subtitle:
                                if let dst = destTrack.subtitleIndex, dst != src {
                                    ids.forEach { project.moveSubtitleClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .text:
                                if let dst = destTrack.textIndex, dst != src {
                                    ids.forEach { project.moveTextClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .shape:
                                if let dst = destTrack.shapeIndex, dst != src {
                                    ids.forEach { project.moveShapeClipToTrack(id: $0, from: src, to: dst) }
                                }
                            case .compound:
                                if let dst = destTrack.compoundIndex, dst != src {
                                    ids.forEach { project.moveCompoundClipToTrack(id: $0, from: src, to: dst) }
                                }
                            }
                        }
                    default: break
                    }
                }
                // 重叠检测：移动/trim 结束后检查是否与同轨片段重叠
                if let op = dragOp {
                    switch op {
                    case .moveVideo(let id, _, _, _), .trimVideoLeft(let id, _, _, _, _), .trimVideoRight(let id, _, _, _, _):
                        project.resolveVideoOverlap(id: id)
                    case .moveImage(let id, _, _, _), .trimImageLeft(let id, _, _), .trimImageRight(let id, _, _):
                        project.resolveImageOverlap(id: id)
                    case .moveAudio(let id, _, _, _), .trimAudioLeft(let id, _, _, _, _), .trimAudioRight(let id, _, _, _, _):
                        project.resolveAudioOverlap(id: id)
                    case .moveSubtitle(let id, _, _, _), .trimSubtitleLeft(let id, _, _), .trimSubtitleRight(let id, _, _):
                        project.resolveSubtitleOverlap(id: id)
                    case .moveText(let id, _, _, _), .trimTextLeft(let id, _, _), .trimTextRight(let id, _, _):
                        project.resolveTextOverlap(id: id)
                    case .moveShape(let id, _, _, _), .trimShapeLeft(let id, _, _), .trimShapeRight(let id, _, _):
                        project.resolveShapeOverlap(id: id)
                    case .moveCompound(let id, _, _, _), .trimCompoundLeft(let id, _, _, _), .trimCompoundRight(let id, _, _):
                        project.resolveCompoundOverlap(id: id)
                    case .moveMulti(let items):
                        for it in items {
                            switch it.kind {
                            case .video:    project.resolveVideoOverlap(id: it.id)
                            case .image:    project.resolveImageOverlap(id: it.id)
                            case .audio:    project.resolveAudioOverlap(id: it.id)
                            case .subtitle: project.resolveSubtitleOverlap(id: it.id)
                            case .text:     project.resolveTextOverlap(id: it.id)
                            case .shape:    project.resolveShapeOverlap(id: it.id)
                            case .compound: project.resolveCompoundOverlap(id: it.id)
                            }
                        }
                    default: break
                    }
                }

                switch dragOp {
                case .trimVideoLeft(let id, _, _, _, _), .trimVideoRight(let id, _, _, _, _):
                    NSCursor.arrow.set()
                    project.rebuildTimelinePreview()
                    if let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id }),
                       let url = clip.url {
                        project.reloadThumbnails(assetID: clip.assetID, url: url)
                    }
                case .trimImageLeft, .trimImageRight,
                     .trimAudioLeft, .trimAudioRight,
                     .trimSubtitleLeft, .trimSubtitleRight,
                     .trimTextLeft, .trimTextRight,
                     .trimShapeLeft, .trimShapeRight,
                     .trimCompoundLeft, .trimCompoundRight:
                    NSCursor.arrow.set()
                    project.rebuildTimelinePreview()
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle, .moveText, .moveShape, .moveCompound, .moveMulti:
                    project.rebuildTimelinePreview()
                case .resizeTrack:
                    NSCursor.arrow.set()
                default: break
                }
                dragOp = nil
                boxStart = nil
                boxEnd = nil
                dragGhostPos = nil
                draggingClipIDs.removeAll()
                multiGhosts = []
                dragGhostOffset = .zero
                draggingClipID = nil
                activeSnapTime = nil
            }
    }

    private func startDrag(at pt: CGPoint) {
        project.selectedMarkerID = nil
        let playheadX = clock.currentTime * project.pixelsPerSecond
        // Dragging anywhere on the playhead stem (±10 px) moves the playhead.
        if abs(pt.x - playheadX) < 10 { dragOp = .movingPlayhead; return }

        // 检测转场菱形图标点击（±10px 范围）
        if let transClipID = hitTestTransitionIcon(at: pt) {
            project.selectedTransitionClipID = transClipID
            project.mediaLibraryTab = "transition"
            // 清除片段选中
            project.selectedVideoClipID = nil
            project.selectedImageClipID = nil
            project.selectedAudioClipID = nil
            project.selectedSubtitleClipID = nil
            project.selectedTextClipID = nil
            project.selectedClipIDs.removeAll()
            dragOp = .ignored
            return
        }

        if let (hit, trimEdge) = findClipTarget(at: pt) {
            // 多选状态下，按住选中集合里的**任何一条**都是整体移动——包括按在边缘上。
            //
            // 原来这里要求 trimEdge == nil（只认片段"内部"）。字幕片段普遍很窄，
            // 而边缘判定按宽度分级：≥20pt 时两端各 8pt 算拉伸区，12~20pt 时两端
            // 各占 30%。一条 30pt 宽的字幕，中间只剩十几 pt 算"内部"，多选之后
            // 想整体拖，十次有八次落在边缘上，变成拉伸其中一条。
            // 多选时用户要的就是整体移动，单条拉伸没有意义，直接不看 trimEdge
            if project.selectedClipIDs.contains(hit.id),
               project.selectedClipIDs.count > 1 {
                let items = collectMultiDragItems()
                project.pushUndo()
                // 整组原片段隐藏，改成半透明幻影跟着鼠标走，松手才落到目标轨道——
                // 跟单选拖动一个观感
                draggingClipIDs = Set(items.map(\.id))
                multiGhosts = buildMultiGhosts(items, grab: pt)
                dragGhostOffset = .zero
                dragOp = .moveMulti(items: items)
                return
            }

            // 计算鼠标点击位置相对于片段中心的偏移（用于拖拽跟手）
            if trimEdge == nil {
                let pps = project.pixelsPerSecond
                let clipCenterX = hit.start * pps + hit.duration * pps / 2
                let trackRow = trackRowForClip(hit)
                let clipCenterY = trackCenterY(row: trackRow)
                dragGhostOffset = CGSize(width: pt.x - clipCenterX, height: pt.y - clipCenterY)
            }

            // 同上：先一把清干净，各 case 只管设自己那个
            project.clearClipSelections()
            project.selectedClipIDs.removeAll()
            project.pushUndo()
            switch (hit, trimEdge) {
            case (.video(let id, let s, let d), nil):
                project.selectedVideoClipID    = id
                let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveVideo(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.video(let id, let s, let d), .left):
                let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ts = clip?.trimStart ?? 0
                let ad = project.mediaAssets.first(where: { $0.id == clip?.assetID })?.duration ?? Double.infinity
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimLeftCursor.set()
            case (.video(let id, let s, let d), .right):
                let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ts = clip?.trimStart ?? 0
                let ad = project.mediaAssets.first(where: { $0.id == clip?.assetID })?.duration ?? Double.infinity
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoRight(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimRightCursor.set()
            case (.image(let id, let s, let d), nil):
                project.selectedImageClipID    = id
                let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveImage(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.image(let id, let s, let d), .left):
                project.selectedImageClipID    = id
                dragOp = .trimImageLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.image(let id, let s, let d), .right):
                project.selectedImageClipID    = id
                dragOp = .trimImageRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.audio(let id, let s, let d), nil):
                project.selectedAudioClipID    = id
                let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveAudio(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.audio(let id, let s, let d), .left):
                let ts = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                project.selectedAudioClipID    = id
                let aClip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ad = project.mediaAssets.first(where: { $0.id == aClip?.assetID })?.duration ?? Double.infinity
                dragOp = .trimAudioLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimLeftCursor.set()
            case (.audio(let id, let s, let d), .right):
                project.selectedAudioClipID    = id
                let aClip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ts = aClip?.trimStart ?? 0
                let ad = project.mediaAssets.first(where: { $0.id == aClip?.assetID })?.duration ?? Double.infinity
                dragOp = .trimAudioRight(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimRightCursor.set()
            case (.subtitle(let id, let s, let d), nil):
                project.selectedSubtitleClipID = id
                let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveSubtitle(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.subtitle(let id, let s, let d), .left):
                project.selectedSubtitleClipID = id
                dragOp = .trimSubtitleLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.subtitle(let id, let s, let d), .right):
                project.selectedSubtitleClipID = id
                dragOp = .trimSubtitleRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.text(let id, let s, let d), nil):
                project.selectedTextClipID     = id
                let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveText(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.text(let id, let s, let d), .left):
                project.selectedTextClipID     = id
                dragOp = .trimTextLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.text(let id, let s, let d), .right):
                project.selectedTextClipID     = id
                dragOp = .trimTextRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.shape(let id, let s, let d), nil):
                project.selectedShapeClipID    = id
                project.selectedVideoClipID = nil; project.selectedImageClipID = nil
                project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil; project.selectedTextClipID = nil
                let ti = project.shapeTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveShape(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.shape(let id, let s, let d), .left):
                project.selectedShapeClipID    = id
                project.selectedVideoClipID = nil; project.selectedImageClipID = nil
                project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil; project.selectedTextClipID = nil
                dragOp = .trimShapeLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.shape(let id, let s, let d), .right):
                project.selectedShapeClipID    = id
                project.selectedVideoClipID = nil; project.selectedImageClipID = nil
                project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil; project.selectedTextClipID = nil
                dragOp = .trimShapeRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.filter(let id, let s, let d), nil):
                selectFilterExclusively(id)
                let ti = project.filterTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveFilter(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.filter(let id, let s, let d), .left):
                selectFilterExclusively(id)
                dragOp = .trimFilterLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.effect(let id, let s, let d), nil):
                selectEffectExclusively(id)
                let ti = project.effectTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveEffect(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.effect(let id, let s, let d), .left):
                selectEffectExclusively(id)
                dragOp = .trimEffectLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.effect(let id, let s, let d), .right):
                selectEffectExclusively(id)
                dragOp = .trimEffectRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.adjust(let id, let s, let d), nil):
                selectAdjustExclusively(id)
                let ti = project.adjustTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveAdjust(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.adjust(let id, let s, let d), .left):
                selectAdjustExclusively(id)
                dragOp = .trimAdjustLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.adjust(let id, let s, let d), .right):
                selectAdjustExclusively(id)
                dragOp = .trimAdjustRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.filter(let id, let s, let d), .right):
                selectFilterExclusively(id)
                dragOp = .trimFilterRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.compound(let id, let s, let d, let ti, _), nil):
                project.selectedCompoundClipID = id
                project.selectedVideoClipID = nil; project.selectedImageClipID = nil
                project.selectedAudioClipID = nil; project.selectedSubtitleClipID = nil
                project.selectedTextClipID = nil; project.selectedShapeClipID = nil
                draggingClipID = id
                dragOp = .moveCompound(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.compound(let id, let s, let d, let ti, _), .left):
                project.selectedCompoundClipID = id
                let iStart = project.compoundTracks[ti].clips.first(where: { $0.id == id })?.internalStart ?? 0
                dragOp = .trimCompoundLeft(id: id, originStart: s, originEnd: s + d, originInternalStart: iStart)
                Self.trimLeftCursor.set()
            case (.compound(let id, let s, let d, _, _), .right):
                project.selectedCompoundClipID = id
                dragOp = .trimCompoundRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            }
        } else {
            dragOp = .box
            boxStart = pt
            project.selectedClipIDs.removeAll()
            project.selectedVideoClipID    = nil
            project.selectedImageClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedSubtitleClipID = nil
            project.selectedTextClipID     = nil
        }
    }

    private func selectVideoAndLoad(id: UUID) {
        project.selectedVideoClipID    = id
        project.selectedImageClipID    = nil
        project.selectedAudioClipID    = nil
        project.selectedSubtitleClipID = nil
        project.selectedTextClipID     = nil
        if let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            project.loadClipForPreview(clip)
        }
    }

    private func collectMultiDragItems() -> [DragItem] {
        var items: [DragItem] = []
        for id in project.selectedClipIDs {
            for (ti, t) in project.videoTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .video,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.imageTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .image,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.audioTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .audio,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.subtitleTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .subtitle,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.textTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .text,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.shapeTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .shape,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
            for (ti, t) in project.compoundTracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .compound,
                                          originStart: c.startTime, originDur: c.duration, srcTrack: ti))
                }
            }
        }
        return items
    }

    /// 收集所有片段的起止时间作为吸附点（排除指定 ID）
    private func collectSnapPoints(excluding ids: Set<UUID>) -> [Double] {
        var pts: [Double] = [0, clock.currentTime] // 轨道起始位置 + 播放头
        for t in project.videoTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        for t in project.imageTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        for t in project.audioTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        for t in project.subtitleTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        for t in project.textTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        for t in project.shapeTracks {
            for c in t.clips where !ids.contains(c.id) { pts.append(c.startTime); pts.append(c.endTime) }
        }
        return pts
    }

    /// 对片段的 start 和 end 做吸附，返回 (吸附后的 start, 吸附点时间)
    private func snapStart(_ rawStart: Double, duration: Double, excluding ids: Set<UUID>) -> (Double, Double?) {
        guard project.snapEnabled else { return (rawStart, nil) }
        let threshold = 8.0 / project.pixelsPerSecond  // 8 像素阈值
        let pts = collectSnapPoints(excluding: ids)
        var best = rawStart
        var bestDist = Double.infinity
        var snapPt: Double? = nil
        let rawEnd = rawStart + duration
        // 片段起点吸附
        for p in pts {
            let d = abs(rawStart - p)
            if d < threshold && d < bestDist { bestDist = d; best = p; snapPt = p }
        }
        // 片段终点吸附
        for p in pts {
            let d = abs(rawEnd - p)
            if d < threshold && d < bestDist { bestDist = d; best = p - duration; snapPt = p }
        }
        return (max(0, best), snapPt)
    }

    /// 对单个边（trim 时）做吸附，返回 (吸附后的值, 吸附点时间)
    private func snapEdge(_ rawTime: Double, excluding ids: Set<UUID>) -> (Double, Double?) {
        guard project.snapEnabled else { return (rawTime, nil) }
        let threshold = 8.0 / project.pixelsPerSecond
        let pts = collectSnapPoints(excluding: ids)
        var best = rawTime
        var bestDist = Double.infinity
        var snapPt: Double? = nil
        for p in pts {
            let d = abs(rawTime - p)
            if d < threshold && d < bestDist { bestDist = d; best = p; snapPt = p }
        }
        return (best, snapPt)
    }

    private func applyDrag(op: DragOp, totalTranslation: CGSize, current: CGPoint) {
        let pps = project.pixelsPerSecond
        let dt  = Double(totalTranslation.width) / pps
        switch op {
        case .moveVideo(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateVideoClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveImage(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateImageClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveAudio(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateAudioClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveSubtitle(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateSubtitleTime(id: id, start: ns, end: ns + d)
        case .moveText(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateTextTime(id: id, start: ns, end: ns + d)
        case .moveShape(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateShapeTime(id: id, start: ns, end: ns + d)
        case .moveFilter(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateFilterClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveAdjust(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateAdjustClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveEffect(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateEffectClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveCompound(let id, let s, let d, _):
            let raw = max(0, s + dt)
            let (ns, sp) = snapStart(raw, duration: d, excluding: [id])
            activeSnapTime = sp
            project.updateCompoundClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveMulti(let items):
            let minOrig = items.map(\.originStart).min() ?? 0
            let clampedDt = max(dt, -minOrig)
            let excludeIDs = Set(items.map(\.id))
            // 以整体的最小起点和最大终点作为吸附点
            let pts = collectSnapPoints(excluding: excludeIDs)
            let threshold = 8.0 / project.pixelsPerSecond
            var bestDelta = 0.0
            var bestDist = Double.infinity
            var bestSnap: Double? = nil
            let groupStart = (items.map(\.originStart).min() ?? 0) + clampedDt
            let groupEnd = (items.map { $0.originStart + $0.originDur }.max() ?? 0) + clampedDt
            for p in pts {
                let ds = abs(groupStart - p)
                if ds < threshold && ds < bestDist { bestDist = ds; bestDelta = p - groupStart; bestSnap = p }
                let de = abs(groupEnd - p)
                if de < threshold && de < bestDist { bestDist = de; bestDelta = p - groupEnd; bestSnap = p }
            }
            activeSnapTime = bestSnap
            for it in items {
                let ns = it.originStart + clampedDt + (project.snapEnabled ? bestDelta : 0)
                let ne = ns + it.originDur
                switch it.kind {
                case .video:    project.updateVideoClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .image:    project.updateImageClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .audio:    project.updateAudioClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .subtitle: project.updateSubtitleTime(id: it.id, start: ns, end: ne)
                case .text:     project.updateTextTime(id: it.id, start: ns, end: ne)
                case .shape:    project.updateShapeTime(id: it.id, start: ns, end: ne)
                case .compound: project.updateCompoundTime(id: it.id, start: ns, end: ne)
                }
            }
        case .trimVideoLeft(let id, let originStart, let originEnd, let originTrimStart, let assetDur):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            // 不能左移超过素材起点
            let minStart = originStart - originTrimStart
            ns = max(minStart, ns)
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = max(minStart, snapped); activeSnapTime = sp
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateVideoClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimVideoRight(let id, let originStart, let originEnd, let originTrimStart, let assetDur):
            var ne = max(originStart + 0.1, originEnd + dt)
            // 不能超过素材总时长
            let maxEnd = originStart + (assetDur - originTrimStart)
            ne = min(ne, maxEnd)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = min(snapped, maxEnd); activeSnapTime = sp
            project.updateVideoClip(id: id) { $0.endTime = ne }
            if ne > clock.duration { clock.duration = ne }
        case .trimImageLeft(let id, let originStart, let originEnd):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            project.updateImageClip(id: id) { $0.startTime = ns }
        case .trimImageRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateImageClip(id: id) { $0.endTime = ne }
            if ne > clock.duration { clock.duration = ne }
        case .trimAudioLeft(let id, let originStart, let originEnd, let originTrimStart, let assetDur):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let minStart = originStart - originTrimStart
            ns = max(minStart, ns)
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = max(minStart, snapped); activeSnapTime = sp
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateAudioClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimAudioRight(let id, let originStart, let originEnd, let originTrimStart, let assetDur):
            var ne = max(originStart + 0.1, originEnd + dt)
            let maxEnd = originStart + (assetDur - originTrimStart)
            ne = min(ne, maxEnd)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = min(snapped, maxEnd); activeSnapTime = sp
            project.updateAudioClip(id: id) { $0.endTime = ne }
            if ne > clock.duration { clock.duration = ne }
        case .trimSubtitleLeft(let id, let originStart, let originEnd):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            project.updateSubtitleTime(id: id, start: ns)
        case .trimSubtitleRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateSubtitleTime(id: id, end: ne)
            if ne > clock.duration { clock.duration = ne }
        case .trimTextLeft(let id, let originStart, let originEnd):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            project.updateTextTime(id: id, start: ns)
        case .trimTextRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateTextTime(id: id, end: ne)
            if ne > clock.duration { clock.duration = ne }
        case .trimShapeLeft(let id, let originStart, let originEnd):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            project.updateShapeTime(id: id, start: ns)
        case .trimShapeRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateShapeTime(id: id, end: ne)
        case .trimEffectLeft(let id, let originStart, let originEnd):
            let raw = min(originStart + dt, originEnd - 0.1)
            let (ns, sp) = snapEdge(max(0, raw), excluding: [id])
            activeSnapTime = sp
            project.updateEffectClip(id: id) { $0.startTime = ns }
        case .trimEffectRight(let id, let originStart, let originEnd):
            let raw = max(originEnd + dt, originStart + 0.1)
            let (ne, sp) = snapEdge(raw, excluding: [id])
            activeSnapTime = sp
            project.updateEffectClip(id: id) { $0.endTime = ne }
        case .trimAdjustLeft(let id, let originStart, let originEnd):
            let raw = min(originStart + dt, originEnd - 0.1)
            let (ns, sp) = snapEdge(max(0, raw), excluding: [id])
            activeSnapTime = sp
            project.updateAdjustClip(id: id) { $0.startTime = ns }
        case .trimAdjustRight(let id, let originStart, let originEnd):
            let raw = max(originEnd + dt, originStart + 0.1)
            let (ne, sp) = snapEdge(raw, excluding: [id])
            activeSnapTime = sp
            project.updateAdjustClip(id: id) { $0.endTime = ne }
        case .trimFilterLeft(let id, let originStart, let originEnd):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            project.updateFilterClip(id: id) { $0.startTime = ns }
        case .trimFilterRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateFilterClip(id: id) { $0.endTime = ne }
            if ne > clock.duration { clock.duration = ne }
        case .trimCompoundLeft(let id, let originStart, let originEnd, let originInternalStart):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            let newInternal = max(0, originInternalStart + (ns - originStart))
            project.updateCompoundClip(id: id) { $0.startTime = ns; $0.internalStart = newInternal }
        case .trimCompoundRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
            project.updateCompoundClip(id: id) { $0.endTime = ne }
            if ne > clock.duration { clock.duration = ne }
        case .movingPlayhead:
            activeSnapTime = nil
            let t = max(0, Double(current.x) / pps)
            project.requestSeek(to: t)
        case .resizeTrack(let kind):
            activeSnapTime = nil
            if totalTranslation == .zero {
                switch kind {
                case .image(let i):    dragOriginTrackH = imgH(i)
                case .video(let i):    dragOriginTrackH = vidH(i)
                case .audio(let i):    dragOriginTrackH = audH(i)
                case .subtitle(let i): dragOriginTrackH = subH(i)
                case .text(let i):     dragOriginTrackH = txtH(i)
                case .shape(let i):    dragOriginTrackH = shpH(i)
                case .filter, .adjust, .effect: dragOriginTrackH = defaultSubTrackH
                case .compound(let i): dragOriginTrackH = cmpH(i)
                }
            }
            let newH = (dragOriginTrackH + totalTranslation.height).clamped(to: 28...120)
            switch kind {
            case .image(let i):    imageTrackHeights[i] = newH
            case .video(let i):    videoTrackHeights[i] = newH
            case .audio(let i):    audioTrackHeights[i] = newH
            case .subtitle(let i): subtitleTrackHeights[i] = newH
            case .text(let i):     textTrackHeights[i] = newH
            case .shape(let i):    shapeTrackHeights[i] = newH
            case .filter, .adjust, .effect: break   // 这三类轨道高度固定
            case .compound(let i): compoundTrackHeights[i] = newH
            }
        case .box:
            activeSnapTime = nil
            boxEnd = current
        case .ignored:
            activeSnapTime = nil
        }
    }

    /// Returns the clip at `pt` plus which trim edge was hit (nil = interior / move).
    /// The edge hit zone is 8 px; clips narrower than 20 px are always treated as interior.
    /// 检测点击是否命中转场菱形图标，返回对应 clip 的 ID
    private func hitTestTransitionIcon(at pt: CGPoint) -> UUID? {
        guard pt.y >= rulerH, project.showVideoTracks else { return nil }
        let pps = project.pixelsPerSecond
        var rowTop: CGFloat = rulerH
        var first = true
        for entry in visibleOverlays {
            if !first { rowTop += 1 }; first = false
            rowTop += overlayH(entry)
        }
        // 视频轨道
        for ti in project.videoTracks.indices {
            if !first { rowTop += 1 }; first = false
            let h = vidH(ti)
            if pt.y >= rowTop && pt.y < rowTop + h {
                let sorted = project.videoTracks[ti].clips.sorted { $0.startTime < $1.startTime }
                guard sorted.count >= 2 else { return nil }
                for idx in 1..<sorted.count {
                    let prev = sorted[idx - 1]
                    let clip = sorted[idx]
                    if abs(prev.endTime - clip.startTime) < 0.05 {
                        // 图标在切割点顶部：x 对齐 cutX，y 在轨道顶部附近（rowTop + 14）
                        let cutX = clip.startTime * pps
                        let iconCenterY = rowTop + 16
                        if abs(pt.x - cutX) < 18 && abs(pt.y - iconCenterY) < 18 {
                            return clip.id
                        }
                    }
                }
                return nil
            }
            rowTop += h
        }
        return nil
    }

    /// 登记时间轴的拖入接收区。素材库把素材 id 拖过来，落点 x 换算成插入时间。
    ///
    /// rect 取的是**内容层**的 global frame：横向滚动时它的 minX 会变成负值，
    /// 所以 `落点 - rect.minX` 自动带上了滚动偏移，直接除 pixelsPerSecond 就是时间码
    private func registerTimelineDropZone(_ rect: CGRect) {
        FileDropRouter.register(
            windowID, kind: .timeline, rect: rect,
            accepts: {
                switch $0 {
                case .asset, .shape, .filter, .adjust, .effect: return true
                case .files:                                   return false   // Finder 拖的文件归素材区
                case .folder:                                  return false   // 文件夹只在素材区内部排序
                }
            },
            onDrop: { payload, local in
                let time = max(0, local.x / project.pixelsPerSecond)
                switch payload {
                case .asset(let assetID):
                    guard let asset = project.mediaAssets.first(where: { $0.id == assetID })
                    else { return }
                    // 文件丢了的素材不该能拖（素材库那边 onDrag 已经拦了一道，这里兜底）
                    guard asset.fileExists else { return }
                    project.addToTimelineAt(asset, time: time)
                case .shape(let type):
                    project.addShape(type: type, at: time)
                case .filter(let kind):
                    project.addFilter(kind: kind, at: time)
                case .effect(let kind):
                    project.addEffect(kind: kind, at: time)
                case .adjust:
                    project.addAdjust(at: time)
                case .files, .folder:
                    break
                }
            },
            onTargetChange: { isLibraryDragOver = $0 })
    }

    /// 只选中这一段滤镜，其余选中态清空
    private func selectFilterExclusively(_ id: UUID) {
        project.clearClipSelections()
        project.selectedFilterClipID = id
    }

    /// 只选中这一段调节
    private func selectAdjustExclusively(_ id: UUID) {
        project.clearClipSelections()
        project.selectedAdjustClipID = id
    }

    /// 只选中这一段特效
    private func selectEffectExclusively(_ id: UUID) {
        project.clearClipSelections()
        project.selectedEffectClipID = id
    }

    private func findClipTarget(at pt: CGPoint) -> (hit: ClipHit, trimEdge: ClipTrimEdge?)? {
        guard pt.y >= rulerH else { return nil }
        let pps = project.pixelsPerSecond
        let threshold: CGFloat = 8
        var rowTop: CGFloat = rulerH
        var first = true

        // 边缘检测：当两个片段相邻时，左边缘优先（离片段中心更近的边优先）
        func edge(x: CGFloat, xMin: CGFloat, xMax: CGFloat) -> ClipTrimEdge? {
            let width = xMax - xMin
            // 太窄时整体让给「移动」——移动是主操作，被拉伸抢走会导致一拖就把片段拉没
            guard width >= 12 else { return nil }
            // 12~20pt：边缘热区按比例收窄，中间始终保留移动区
            if width < 20 {
                let zone = width * 0.3
                if x <= xMin + zone { return .left }
                if x >= xMax - zone { return .right }
                return nil
            }
            let nearLeft = abs(x - xMin) <= threshold
            let nearRight = abs(x - xMax) <= threshold
            if nearLeft && nearRight {
                // 两边都在阈值内（极短片段），选更近的
                return abs(x - xMin) <= abs(x - xMax) ? .left : .right
            }
            if nearLeft { return .left }
            if nearRight { return .right }
            return nil
        }

        // 在一行 clips 中找最佳匹配：优先匹配鼠标在 clip 内部的（解决相邻片段边缘重叠问题）
        typealias Match = (hit: ClipHit, trimEdge: ClipTrimEdge?)
        func bestMatch<C>(_ clips: [C], x: CGFloat, _ makeHit: (C, CGFloat, CGFloat) -> ClipHit,
                          _ start: (C) -> Double, _ end: (C) -> Double) -> Match? {
            var insideMatch: Match? = nil
            var edgeMatch: Match? = nil
            for c in clips {
                let xMin = CGFloat(start(c) * pps) + 1
                let xMax = CGFloat(end(c) * pps) + 1
                let inside = x >= xMin && x <= xMax
                let inZone = x >= xMin - threshold && x <= xMax + threshold
                guard inZone else { continue }
                let e = edge(x: x, xMin: xMin, xMax: xMax)
                let hit = makeHit(c, xMin, xMax)
                if inside {
                    // 鼠标在 clip 内部 → 最高优先级
                    if insideMatch == nil { insideMatch = (hit, e) }
                } else if edgeMatch == nil {
                    edgeMatch = (hit, e)
                }
            }
            return insideMatch ?? edgeMatch
        }

        for entry in visibleOverlays {
            if !first { rowTop += 1 }; first = false
            let h = overlayH(entry)
            if pt.y >= rowTop && pt.y < rowTop + h {
                switch entry.kind {
                case .image:
                    if let m = bestMatch(project.imageTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .image(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .subtitle:
                    if let m = bestMatch(project.subtitleTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .subtitle(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .text:
                    if let m = bestMatch(project.textTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .text(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .effect:
                    if let m = bestMatch(project.effectTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .effect(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .adjust:
                    if let m = bestMatch(project.adjustTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .adjust(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .filter:
                    if let m = bestMatch(project.filterTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .filter(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .shape:
                    if let m = bestMatch(project.shapeTracks[entry.index].clips, x: pt.x,
                        { c, _, _ in .shape(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                case .compound:
                    let ti = entry.index
                    if let m = bestMatch(project.compoundTracks[ti].clips.enumerated().map { ($0, $1) }, x: pt.x,
                        { pair, _, _ in let (ci, c) = pair; return .compound(id: c.id, start: c.startTime, dur: c.duration, trackIndex: ti, clipIndex: ci) },
                        { $0.1.startTime }, { $0.1.endTime }) { return m }
                }
                return nil
            }
            rowTop += h
        }
        if project.showVideoTracks {
            for item in resolvedVideoSection {
                if !first { rowTop += 1 }; first = false
                let h = videoSectionH(item)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    if item.kind == .video {
                        if let m = bestMatch(project.videoTracks[item.trackIndex].clips, x: pt.x,
                            { c, _, _ in .video(id: c.id, start: c.startTime, dur: c.duration) },
                            { $0.startTime }, { $0.endTime }) { return m }
                    } else {
                        let ti = item.trackIndex
                        if let m = bestMatch(project.compoundTracks[ti].clips.enumerated().map { ($0, $1) }, x: pt.x,
                            { pair, _, _ in let (ci, c) = pair; return .compound(id: c.id, start: c.startTime, dur: c.duration, trackIndex: ti, clipIndex: ci) },
                            { $0.1.startTime }, { $0.1.endTime }) { return m }
                    }
                    return nil
                }
                rowTop += h
            }
        }
        if project.showAudioTracks {
            for item in resolvedAudioSection {
                if !first { rowTop += 1 }; first = false
                let h = audioSectionH(item)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    if item.kind == .audio {
                        if let m = bestMatch(project.audioTracks[item.trackIndex].clips, x: pt.x,
                            { c, _, _ in .audio(id: c.id, start: c.startTime, dur: c.duration) },
                            { $0.startTime }, { $0.endTime }) { return m }
                    } else {
                        let ti = item.trackIndex
                        if let m = bestMatch(project.compoundTracks[ti].clips.enumerated().map { ($0, $1) }, x: pt.x,
                            { pair, _, _ in let (ci, c) = pair; return .compound(id: c.id, start: c.startTime, dur: c.duration, trackIndex: ti, clipIndex: ci) },
                            { $0.1.startTime }, { $0.1.endTime }) { return m }
                    }
                    return nil
                }
                rowTop += h
            }
        }
        return nil
    }

    private func finalizeBoxSelect(rect: CGRect) {
        let pps = project.pixelsPerSecond
        var ids: Set<UUID> = []
        var rowTop = rulerH
        var first = true

        for entry in visibleOverlays {
            if !first { rowTop += 1 }; first = false
            let h = overlayH(entry)
            let yRange = rowTop ... (rowTop + h)
            switch entry.kind {
            case .image:
                for c in project.imageTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .subtitle:
                for c in project.subtitleTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .text:
                for c in project.textTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .shape:
                for c in project.shapeTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .effect:
                for c in project.effectTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .adjust:
                for c in project.adjustTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .filter:
                for c in project.filterTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            case .compound:
                for c in project.compoundTracks[entry.index].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                }
            }
            rowTop += h
        }
        if project.showVideoTracks {
            for item in resolvedVideoSection {
                if !first { rowTop += 1 }; first = false
                let h = videoSectionH(item)
                let yRange = rowTop ... (rowTop + h)
                if item.kind == .video {
                    for c in project.videoTracks[item.trackIndex].clips {
                        let xEnd = max(c.startTime*pps, c.endTime*pps)
                        if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                    }
                } else {
                    for c in project.compoundTracks[item.trackIndex].clips {
                        let xEnd = max(c.startTime*pps, c.endTime*pps)
                        if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                    }
                }
                rowTop += h
            }
        }
        if project.showAudioTracks {
            for item in resolvedAudioSection {
                if !first { rowTop += 1 }; first = false
                let h = audioSectionH(item)
                let yRange = rowTop ... (rowTop + h)
                if item.kind == .audio {
                    for c in project.audioTracks[item.trackIndex].clips {
                        let xEnd = max(c.startTime*pps, c.endTime*pps)
                        if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                    }
                } else {
                    for c in project.compoundTracks[item.trackIndex].clips {
                        let xEnd = max(c.startTime*pps, c.endTime*pps)
                        if rectIntersects(rect, xRange: (c.startTime*pps)...xEnd, yRange: yRange) { ids.insert(c.id) }
                    }
                }
                rowTop += h
            }
        }

        project.selectedClipIDs = ids
    }

    private func rectIntersects(_ rect: CGRect,
                                xRange: ClosedRange<Double>,
                                yRange: ClosedRange<CGFloat>) -> Bool {
        let xa = Double(rect.minX), xb = Double(rect.maxX)
        if xb < xRange.lowerBound || xa > xRange.upperBound { return false }
        let ya = rect.minY, yb = rect.maxY
        if yb < yRange.lowerBound || ya > yRange.upperBound { return false }
        return true
    }

    /// 检测 y 坐标是否在轨道底部边缘（±3px），返回对应轨道类型+索引
    private func trackGapHit(y: CGFloat) -> TrackKind? {
        let threshold: CGFloat = 3
        var top = rulerH
        var first = true
        for entry in visibleOverlays {
            if !first { top += 1 }; first = false
            top += overlayH(entry)
            switch entry.kind {
            case .image: if abs(y - top) <= threshold { return .image(entry.index) }
            case .subtitle: if abs(y - top) <= threshold { return .subtitle(entry.index) }
            case .text: if abs(y - top) <= threshold { return .text(entry.index) }
            case .shape: if abs(y - top) <= threshold { return .shape(entry.index) }
            case .filter, .adjust, .effect: break   // 这三类轨道高度固定，不给拖

            case .compound: if abs(y - top) <= threshold { return .compound(entry.index) }
            }
        }
        if project.showVideoTracks {
            for item in resolvedVideoSection {
                if !first { top += 1 }; first = false
                top += videoSectionH(item)
                if abs(y - top) <= threshold {
                    return item.kind == .video ? .video(item.trackIndex) : .compound(item.trackIndex)
                }
            }
        }
        if project.showAudioTracks {
            for item in resolvedAudioSection {
                if !first { top += 1 }; first = false
                top += audioSectionH(item)
                if abs(y - top) <= threshold {
                    return item.kind == .audio ? .audio(item.trackIndex) : .compound(item.trackIndex)
                }
            }
        }
        return nil
    }

    private func trackTopFromY(_ y: CGFloat) -> CGFloat {
        var top = rulerH
        var first = true
        for entry in visibleOverlays {
            if !first { top += 1 }; first = false
            let h = overlayH(entry)
            if y >= top && y < top + h { return top }
            top += h
        }
        if project.showVideoTracks {
            for item in resolvedVideoSection {
                if !first { top += 1 }; first = false
                let h = videoSectionH(item)
                if y >= top && y < top + h { return top }
                top += h
            }
        }
        if project.showAudioTracks {
            for item in resolvedAudioSection {
                if !first { top += 1 }; first = false
                let h = audioSectionH(item)
                if y >= top && y < top + h { return top }
                top += h
            }
        }
        return rulerH
    }

    private func totalContentH() -> CGFloat {
        var h = rulerH
        var trackCount = 0
        for entry in visibleOverlays { h += overlayH(entry); trackCount += 1 }
        if project.showVideoTracks {
            let vs = resolvedVideoSection
            for item in vs { h += videoSectionH(item) }; trackCount += vs.count
        }
        if project.showAudioTracks {
            let as_ = resolvedAudioSection
            for item in as_ { h += audioSectionH(item) }; trackCount += as_.count
        }
        if trackCount > 1 { h += CGFloat(trackCount - 1) }
        return h
    }

    /// 判断片段是否在可视区域内（含缓冲区）
    private func isClipVisible(startTime: Double, endTime: Double) -> Bool {
        let pps = project.pixelsPerSecond
        let vpW = max(project.timelineVisibleWidth, 400)
        let buffer = vpW * 0.5  // 左右各半屏缓冲，减少滚动时闪烁
        let visibleLeft = scrollOffsetX - buffer
        let visibleRight = scrollOffsetX + vpW + buffer
        let clipLeft = startTime * pps
        let clipRight = endTime * pps
        return clipRight >= visibleLeft && clipLeft <= visibleRight
    }

    private func isTrackDragging(_ type: TrackDragType, _ idx: Int) -> Bool {
        trackLabelDragType == type && trackLabelDragSrc == idx
    }

    private var trackRows: some View {
        VStack(spacing: 1) {
        // Overlay tracks (image/subtitle/text/filter) — unified order
        ForEach(Array(visibleOverlays.enumerated()), id:\.element.trackID) { ovIdx, entry in
            overlayClipRow(entry: entry)
                .offset(y: isTrackDragging(.overlay, ovIdx) ? trackLabelDragOffset : 0)
                .zIndex(isTrackDragging(.overlay, ovIdx) ? 10 : 0)
                .opacity(isTrackDragging(.overlay, ovIdx) ? 0.55 : 1.0)
        }
        if project.showVideoTracks {
            let vs = resolvedVideoSection
            ForEach(vs.indices, id:\.self) { secIdx in
                let item = vs[secIdx]
                if item.kind == .video {
                    let i = item.trackIndex
                    trackRow(height: vidH(i), hidden: !project.videoTracks[i].isVisible, tint: Color(hex: "#3DBFBA")) {
                        ForEach(project.videoTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                            VideoClipView(clip: clip, pps: project.pixelsPerSecond, h: vidH(i),
                                          sel: isSelected(clip.id, primary: project.selectedVideoClipID),
                                          isDragging: isDraggingClip(clip.id),
                                          scrollOffsetX: scrollOffsetX)
                        }
                        transitionIcons(trackIndex: i, trackHeight: vidH(i))
                        clipMarkerPins(project.videoTracks[i].clips, pps: project.pixelsPerSecond,
                                       trackHeight: vidH(i), startTime: \.startTime, markers: \.markers)
                    }
                    .offset(y: isTrackDragging(.video, secIdx) ? trackLabelDragOffset : 0)
                    .zIndex(isTrackDragging(.video, secIdx) ? 10 : 0)
                    .opacity(isTrackDragging(.video, secIdx) ? 0.55 : 1.0)
                } else {
                    let ti = item.trackIndex
                    trackRow(height: cmpH(ti), hidden: !project.compoundTracks[ti].isVisible,
                             muted: project.compoundTracks[ti].isMuted, tint: Color(hex: "#FF9F43")) {
                        ForEach(project.compoundTracks[ti].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                            CompoundClipView(clip: clip, pps: project.pixelsPerSecond, h: cmpH(ti),
                                             scrollOffsetX: scrollOffsetX,
                                             sel: isSelected(clip.id, primary: project.selectedCompoundClipID),
                                             isDragging: isDraggingClip(clip.id))
                        }
                        clipMarkerPins(project.compoundTracks[ti].clips, pps: project.pixelsPerSecond,
                                       trackHeight: cmpH(ti), startTime: \.startTime, markers: \.markers)
                    }
                    .offset(y: isTrackDragging(.video, secIdx) ? trackLabelDragOffset : 0)
                    .zIndex(isTrackDragging(.video, secIdx) ? 10 : 0)
                    .opacity(isTrackDragging(.video, secIdx) ? 0.55 : 1.0)
                }
            }
        }
        if project.showAudioTracks {
            let as_ = resolvedAudioSection
            ForEach(as_.indices, id:\.self) { secIdx in
                let item = as_[secIdx]
                if item.kind == .audio {
                    let i = item.trackIndex
                    trackRow(height: audH(i), hidden: !project.audioTracks[i].isVisible, muted: project.audioTracks[i].isMuted, tint: Color(hex: "#5DB85D")) {
                        ForEach(project.audioTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                            AudioClipView(clip: clip, pps: project.pixelsPerSecond, h: audH(i),
                                          sel: isSelected(clip.id, primary: project.selectedAudioClipID),
                                          isDragging: isDraggingClip(clip.id),
                                          scrollOffsetX: scrollOffsetX)
                        }
                        clipMarkerPins(project.audioTracks[i].clips, pps: project.pixelsPerSecond,
                                       trackHeight: audH(i), startTime: \.startTime, markers: \.markers)
                    }
                    .offset(y: isTrackDragging(.audio, secIdx) ? trackLabelDragOffset : 0)
                    .zIndex(isTrackDragging(.audio, secIdx) ? 10 : 0)
                    .opacity(isTrackDragging(.audio, secIdx) ? 0.55 : 1.0)
                } else {
                    let ti = item.trackIndex
                    trackRow(height: cmpH(ti), hidden: !project.compoundTracks[ti].isVisible,
                             muted: project.compoundTracks[ti].isMuted, tint: Color(hex: "#FF9F43")) {
                        ForEach(project.compoundTracks[ti].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                            CompoundClipView(clip: clip, pps: project.pixelsPerSecond, h: cmpH(ti),
                                             scrollOffsetX: scrollOffsetX,
                                             sel: isSelected(clip.id, primary: project.selectedCompoundClipID),
                                             isDragging: isDraggingClip(clip.id))
                        }
                        clipMarkerPins(project.compoundTracks[ti].clips, pps: project.pixelsPerSecond,
                                       trackHeight: cmpH(ti), startTime: \.startTime, markers: \.markers)
                    }
                    .offset(y: isTrackDragging(.audio, secIdx) ? trackLabelDragOffset : 0)
                    .zIndex(isTrackDragging(.audio, secIdx) ? 10 : 0)
                    .opacity(isTrackDragging(.audio, secIdx) ? 0.55 : 1.0)
                }
            }
        }
        }
        .overlay(trackDropIndicatorLine())
        .overlay(compoundGrayOverlay())
    }

    @ViewBuilder
    private func compoundGrayOverlay() -> some View {
        if let level = project.compositionStack.last {
            let pps = project.pixelsPerSecond
            let activeStart = level.activeStart
            let activeEnd = activeStart + level.activeDuration
            let allEnd = compoundSubContentEnd()
            GeometryReader { geo in
                // 左侧灰色区域（0 ~ activeStart）
                if activeStart > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: CGFloat(activeStart * pps))
                        .frame(maxHeight: .infinity)
                        .position(x: CGFloat(activeStart * pps) / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                // 右侧灰色区域（activeEnd ~ allEnd）
                if activeEnd < allEnd {
                    let rightX = CGFloat(activeEnd * pps)
                    let rightW = max(0, CGFloat(allEnd * pps) - rightX)
                    Rectangle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: rightW)
                        .frame(maxHeight: .infinity)
                        .position(x: rightX + rightW / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                // 左边界线
                if activeStart > 0 {
                    Rectangle().fill(Color.yellow.opacity(0.6))
                        .frame(width: 1).frame(maxHeight: .infinity)
                        .position(x: CGFloat(activeStart * pps), y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                // 右边界线
                if activeEnd < allEnd {
                    Rectangle().fill(Color.yellow.opacity(0.6))
                        .frame(width: 1).frame(maxHeight: .infinity)
                        .position(x: CGFloat(activeEnd * pps), y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func compoundSubContentEnd() -> Double {
        var maxEnd = 0.0
        for t in project.videoTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.audioTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.imageTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.subtitleTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.textTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.shapeTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        for t in project.compoundTracks { for c in t.clips { maxEnd = max(maxEnd, c.endTime) } }
        return maxEnd
    }

    @ViewBuilder
    private func overlayClipRow(entry: ResolvedOverlay) -> some View {
        let i = entry.index
        switch entry.kind {
        case .image:
            trackRow(height: imgH(i), hidden: !project.imageTracks[i].isVisible, tint: Color(hex: "#E8A54B")) {
                ForEach(project.imageTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    ImageClipView(clip: clip, pps: project.pixelsPerSecond, h: imgH(i),
                                  sel: isSelected(clip.id, primary: project.selectedImageClipID),
                                  isDragging: isDraggingClip(clip.id),
                                  scrollOffsetX: scrollOffsetX)
                }
                clipMarkerPins(project.imageTracks[i].clips, pps: project.pixelsPerSecond,
                               trackHeight: imgH(i), startTime: \.startTime, markers: \.markers)
            }
        case .subtitle:
            trackRow(height: subH(i), hidden: !project.subtitleTracks[i].isVisible, tint: Color(hex: "#7B6FC4")) {
                ForEach(project.subtitleTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    SubtitleClipView(clip: clip, pps: project.pixelsPerSecond, h: subH(i),
                                     sel: isSelected(clip.id, primary: project.selectedSubtitleClipID),
                                     isDragging: isDraggingClip(clip.id),
                                     scrollOffsetX: scrollOffsetX)
                }
                clipMarkerPins(project.subtitleTracks[i].clips, pps: project.pixelsPerSecond,
                               trackHeight: subH(i), startTime: \.startTime, markers: \.markers)
            }
        case .text:
            trackRow(height: txtH(i), hidden: !project.textTracks[i].isVisible, tint: Color(hex: "#D4668E")) {
                ForEach(project.textTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    TextClipView(clip: clip, pps: project.pixelsPerSecond, h: txtH(i),
                                 sel: isSelected(clip.id, primary: project.selectedTextClipID),
                                 isDragging: isDraggingClip(clip.id),
                                 scrollOffsetX: scrollOffsetX)
                }
                clipMarkerPins(project.textTracks[i].clips, pps: project.pixelsPerSecond,
                               trackHeight: txtH(i), startTime: \.startTime, markers: \.markers)
            }
        case .shape:
            trackRow(height: shpH(i), hidden: !project.shapeTracks[i].isVisible, tint: Color(hex: "#5B8FF9")) {
                ForEach(project.shapeTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    ShapeTimelineClipView(clip: clip, pps: project.pixelsPerSecond, h: shpH(i),
                                          sel: isSelected(clip.id, primary: project.selectedShapeClipID),
                                          isDragging: isDraggingClip(clip.id),
                                          scrollOffsetX: scrollOffsetX)
                }
                clipMarkerPins(project.shapeTracks[i].clips, pps: project.pixelsPerSecond,
                               trackHeight: shpH(i), startTime: \.startTime, markers: \.markers)
            }
        case .filter:
            trackRow(height: defaultSubTrackH,
                     hidden: !project.filterTracks[i].isVisible,
                     tint: Color(hex: "#6FBF8F")) {
                ForEach(project.filterTracks[i].clips.filter {
                    isClipVisible(startTime: $0.startTime, endTime: $0.endTime)
                }) { clip in
                    FilterTimelineClipView(clip: clip, pps: project.pixelsPerSecond,
                                           h: defaultSubTrackH,
                                           sel: isSelected(clip.id, primary: project.selectedFilterClipID),
                                           isDragging: isDraggingClip(clip.id),
                                           scrollOffsetX: scrollOffsetX)
                }
            }
        case .effect:
            trackRow(height: defaultSubTrackH,
                     hidden: !project.effectTracks[i].isVisible,
                     tint: Color(hex: "#C97BB0")) {
                ForEach(project.effectTracks[i].clips.filter {
                    isClipVisible(startTime: $0.startTime, endTime: $0.endTime)
                }) { clip in
                    EffectTimelineClipView(clip: clip, pps: project.pixelsPerSecond,
                                           h: defaultSubTrackH,
                                           sel: isSelected(clip.id, primary: project.selectedEffectClipID),
                                           isDragging: isDraggingClip(clip.id),
                                           scrollOffsetX: scrollOffsetX)
                }
            }
        case .adjust:
            trackRow(height: defaultSubTrackH,
                     hidden: !project.adjustTracks[i].isVisible,
                     tint: Color(hex: "#7E8FD6")) {
                ForEach(project.adjustTracks[i].clips.filter {
                    isClipVisible(startTime: $0.startTime, endTime: $0.endTime)
                }) { clip in
                    AdjustTimelineClipView(clip: clip, pps: project.pixelsPerSecond,
                                           h: defaultSubTrackH,
                                           sel: isSelected(clip.id, primary: project.selectedAdjustClipID),
                                           isDragging: isDraggingClip(clip.id),
                                           scrollOffsetX: scrollOffsetX)
                }
            }
        case .compound:
            trackRow(height: cmpH(i), hidden: !project.compoundTracks[i].isVisible,
                     muted: project.compoundTracks[i].isMuted, tint: Color(hex: "#FF9F43")) {
                ForEach(project.compoundTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    CompoundClipView(clip: clip, pps: project.pixelsPerSecond, h: cmpH(i),
                                     scrollOffsetX: scrollOffsetX,
                                     sel: isSelected(clip.id, primary: project.selectedCompoundClipID),
                                     isDragging: isDraggingClip(clip.id))
                }
                clipMarkerPins(project.compoundTracks[i].clips, pps: project.pixelsPerSecond,
                               trackHeight: cmpH(i), startTime: \.startTime, markers: \.markers)
            }
        }
    }

    private struct GhostInfo {
        let name: String
        let duration: Double
        let color: Color
        let height: CGFloat
        let isSubtitle: Bool
        /// 片段自带的标记，画在幻影上跟着一起走。
        ///
        /// 标记本来是按**轨道**渲染的（clipMarkerPins 挂在每条 trackRow 里），
        /// 而跨轨移动要到松手才执行 moveXxxClipToTrack —— 拖动全程 clip 还属于原轨道，
        /// 于是标记钉在原轨道那一行不动，只有 x 跟着变，看着就是「标记不跟片段走」。
        /// 幻影自己带一份就跟手了
        var markers: [Marker] = []
    }

    /// 多选拖动的一个幻影。dx/dy 是它相对抓取点的偏移，
    /// 拖动过程中整组保持相对位置不变，跟单选那个幻影一样跟手
    /// 拖动时跟着鼠标的半透明幻影。单选和多选共用一套外观
    @ViewBuilder
    private func ghostView(_ info: GhostInfo) -> some View {
        let cr: CGFloat = info.isSubtitle ? 3 : 4
        RoundedRectangle(cornerRadius: cr)
            .fill(info.color.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: cr)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            )
            .overlay(
                Text(info.name)
                    .font(.system(size: info.isSubtitle ? 8 : 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.leading, info.isSubtitle ? 4 : 5)
                    .padding(.top, info.isSubtitle ? 0 : 4)
                , alignment: info.isSubtitle ? .leading : .topLeading
            )
            // 标记跟着幻影走。轨道上那份标记在拖动期间仍钉在原轨道
            // （clip 要到松手才换轨），所以这里自己画一份
            .overlay(alignment: .topLeading) {
                ForEach(info.markers) { m in
                    ghostMarkerPin(m)
                        // 幻影比轨道行矮（height 取的是 xxxH(ti) - 4），
                        // 所以这里贴边（y = pin 高一半）才跟轨道上那份留 2px 的效果对齐。
                        // 别照抄轨道那份的 +2，会多沉一截
                        .position(x: m.time * project.pixelsPerSecond + 1, y: 6)
                }
            }
            .frame(width: max(info.duration * project.pixelsPerSecond, 30), height: info.height)
            .allowsHitTesting(false)
    }

    /// 幻影上的标记图钉。形状跟 clipMarkerPins 保持一致，只是不做选中/悬停态
    private func ghostMarkerPin(_ m: Marker) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var pin = Path()
            let r: CGFloat = 1.5
            pin.move(to: CGPoint(x: r, y: 0))
            pin.addLine(to: CGPoint(x: w - r, y: 0))
            pin.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
            pin.addLine(to: CGPoint(x: w, y: h * 0.6))
            pin.addLine(to: CGPoint(x: w / 2, y: h))
            pin.addLine(to: CGPoint(x: 0, y: h * 0.6))
            pin.addLine(to: CGPoint(x: 0, y: r))
            pin.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            pin.closeSubpath()
            ctx.fill(pin, with: .color(m.color.swiftUIColor))
        }
        .frame(width: 8, height: 12)
        .allowsHitTesting(false)
    }

    private struct MultiGhost: Identifiable {
        let id: UUID
        let info: GhostInfo
        let dx: CGFloat
        let dy: CGFloat
    }

    /// 这个片段是不是正在被拖（单选或多选）。原片段隐藏、只留幻影时用
    private func isDraggingClip(_ id: UUID) -> Bool {
        draggingClipID == id || draggingClipIDs.contains(id)
    }

    /// 按 DragItem 取幻影外观 + 它在时间轴上的命中信息（用来算所在行）
    private func ghostInfoAndHit(for it: DragItem) -> (GhostInfo, ClipHit)? {
        switch it.kind {
        case .video:
            guard let c = project.videoTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.name, duration: c.duration, color: Color(hex: "#3DBFBA"),
                              height: vidH(ti) - 4, isSubtitle: false, markers: c.markers ?? []),
                    .video(id: it.id, start: c.startTime, dur: c.duration))
        case .image:
            guard let c = project.imageTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.name, duration: c.duration, color: Color(hex: "#E8A54B"),
                              height: imgH(ti) - 4, isSubtitle: false, markers: c.markers ?? []),
                    .image(id: it.id, start: c.startTime, dur: c.duration))
        case .audio:
            guard let c = project.audioTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.name, duration: c.duration, color: Color(hex: "#5DB85D"),
                              height: audH(ti) - 4, isSubtitle: false, markers: c.markers ?? []),
                    .audio(id: it.id, start: c.startTime, dur: c.duration))
        case .subtitle:
            guard let c = project.subtitleTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.text.components(separatedBy: "\n").first ?? c.text,
                              duration: c.duration, color: Color(hex: "#7B6FC4"),
                              height: subH(ti) - 4, isSubtitle: true, markers: c.markers ?? []),
                    .subtitle(id: it.id, start: c.startTime, dur: c.duration))
        case .text:
            guard let c = project.textTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.text, duration: c.duration, color: Color(hex: "#D4668E"),
                              height: txtH(ti) - 4, isSubtitle: true, markers: c.markers ?? []),
                    .text(id: it.id, start: c.startTime, dur: c.duration))
        case .shape:
            guard let c = project.shapeTracks.flatMap(\.clips).first(where: { $0.id == it.id }) else { return nil }
            let ti = project.shapeTracks.firstIndex { $0.clips.contains { $0.id == it.id } } ?? 0
            return (GhostInfo(name: c.type.label, duration: c.duration, color: Color(hex: "#5B8FF9"),
                              height: shpH(ti) - 4, isSubtitle: true, markers: c.markers ?? []),
                    .shape(id: it.id, start: c.startTime, dur: c.duration))
        case .compound:
            guard let ti = project.compoundTracks.firstIndex(where: { $0.clips.contains { $0.id == it.id } }),
                  let ci = project.compoundTracks[ti].clips.firstIndex(where: { $0.id == it.id })
            else { return nil }
            let c = project.compoundTracks[ti].clips[ci]
            return (GhostInfo(name: c.name, duration: c.duration, color: Color(hex: "#FF9F43"),
                              height: cmpH(ti) - 4, isSubtitle: false, markers: c.markers ?? []),
                    .compound(id: it.id, start: c.startTime, dur: c.duration,
                              trackIndex: ti, clipIndex: ci))
        }
    }

    /// 拖动开始时算好整组幻影相对抓取点的位置，之后只跟着鼠标平移
    private func buildMultiGhosts(_ items: [DragItem], grab: CGPoint) -> [MultiGhost] {
        let pps = project.pixelsPerSecond
        return items.compactMap { it in
            guard let (info, hit) = ghostInfoAndHit(for: it) else { return nil }
            let cx = CGFloat((it.originStart + it.originDur / 2) * pps)
            let cy = trackCenterY(row: trackRowForClip(hit))
            return MultiGhost(id: it.id, info: info, dx: cx - grab.x, dy: cy - grab.y)
        }
    }

    private func dragGhostInfo() -> GhostInfo? {
        switch dragOp {
        case .moveVideo(let id, _, _, _):
            guard let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#3DBFBA"), height: vidH(ti) - 4, isSubtitle: false, markers: clip.markers ?? [])
        case .moveImage(let id, _, _, _):
            guard let clip = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#E8A54B"), height: imgH(ti) - 4, isSubtitle: false, markers: clip.markers ?? [])
        case .moveAudio(let id, _, _, _):
            guard let clip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#5DB85D"), height: audH(ti) - 4, isSubtitle: false, markers: clip.markers ?? [])
        case .moveSubtitle(let id, _, _, _):
            guard let clip = project.subtitleTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.text.components(separatedBy: "\n").first ?? clip.text, duration: clip.duration, color: Color(hex: "#7B6FC4"), height: subH(ti) - 4, isSubtitle: true, markers: clip.markers ?? [])
        case .moveFilter(let id, _, _, _):
            guard let clip = project.filterTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.name, duration: clip.duration,
                             color: Color(hex: "#3F8F6B"), height: defaultSubTrackH - 4,
                             isSubtitle: false, markers: [])
        case .moveAdjust(let id, _, _, _):
            guard let clip = project.adjustTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.name, duration: clip.duration,
                             color: Color(hex: "#7E8FD6"), height: defaultSubTrackH - 4,
                             isSubtitle: false, markers: [])
        case .moveEffect(let id, _, _, _):
            guard let clip = project.effectTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.name, duration: clip.duration,
                             color: Color(hex: "#C97BB0"), height: defaultSubTrackH - 4,
                             isSubtitle: false, markers: [])
        case .moveText(let id, _, _, _):
            guard let clip = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.text, duration: clip.duration, color: Color(hex: "#D4668E"), height: txtH(ti) - 4, isSubtitle: true, markers: clip.markers ?? [])
        case .moveShape(let id, _, _, _):
            guard let clip = project.shapeTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.shapeTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.type.label, duration: clip.duration, color: Color(hex: "#5B8FF9"), height: shpH(ti) - 4, isSubtitle: true, markers: clip.markers ?? [])
        case .moveCompound(let id, _, _, _):
            guard let clip = project.compoundTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.compoundTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#FF9F43"), height: cmpH(ti) - 4, isSubtitle: false, markers: clip.markers ?? [])
        default: return nil
        }
    }

    private func isSelected(_ id: UUID, primary: UUID?) -> Bool {
        primary == id || project.selectedClipIDs.contains(id)
    }

    /// Determine which track type & index the y coordinate falls on
    private struct TrackTarget {
        var videoIndex: Int?
        var imageIndex: Int?
        var audioIndex: Int?
        var subtitleIndex: Int?
        var textIndex: Int?
        var shapeIndex: Int?
        var filterIndex: Int?
        var adjustIndex: Int?
        var effectIndex: Int?
        var compoundIndex: Int?
    }

    private func trackRowForClip(_ hit: ClipHit) -> Int {
        let overlays = resolvedOverlays
        let oCount = overlays.count
        let vs = resolvedVideoSection
        switch hit {
        case .filter(let id, _, _):
            let ti = project.filterTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.filterTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .adjust(let id, _, _):
            let ti = project.adjustTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.adjustTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .effect(let id, _, _):
            let ti = project.effectTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.effectTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .image(let id, _, _):
            let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.imageTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .subtitle(let id, _, _):
            let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.subtitleTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .text(let id, _, _):
            let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.textTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .shape(let id, _, _):
            let ti = project.shapeTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.shapeTracks[ti].id
            return overlays.firstIndex { $0.trackID == trackID } ?? 0
        case .video(let id, _, _):
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.videoTracks[ti].id
            return oCount + (vs.firstIndex { $0.kind == .video && $0.trackIndex == ti } ?? 0)
        case .audio(let id, _, _):
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            let trackID = project.audioTracks[ti].id
            let as_ = resolvedAudioSection
            return oCount + vs.count + (as_.firstIndex { $0.kind == .audio && $0.trackIndex == ti } ?? 0)
        case .compound(_, _, _, let ti, _):
            let kind = project.compoundTrackKind(project.compoundTracks[ti])
            switch kind {
            case .overlay:
                let trackID = project.compoundTracks[ti].id
                return overlays.firstIndex { $0.trackID == trackID } ?? 0
            case .video:
                return oCount + (vs.firstIndex { $0.kind == .compound && $0.trackIndex == ti } ?? 0)
            case .audio:
                let as_ = resolvedAudioSection
                return oCount + vs.count + (as_.firstIndex { $0.kind == .compound && $0.trackIndex == ti } ?? 0)
            }
        }
    }

    private func trackCenterY(row: Int) -> CGFloat {
        let overlays = resolvedOverlays
        let oCount = overlays.count
        let vs = project.showVideoTracks ? resolvedVideoSection : []
        let as_ = project.showAudioTracks ? resolvedAudioSection : []
        var top = rulerH

        func heightForRow(_ r: Int) -> CGFloat {
            if r < oCount { return overlayH(overlays[r]) }
            let afterOverlay = r - oCount
            if afterOverlay < vs.count { return videoSectionH(vs[afterOverlay]) }
            let afterVideo = afterOverlay - vs.count
            if afterVideo < as_.count { return audioSectionH(as_[afterVideo]) }
            return defaultTrackH
        }

        for r in 0..<row {
            if r > 0 { top += 1 }
            top += heightForRow(r)
        }
        if row > 0 { top += 1 }
        return top + heightForRow(row) / 2
    }

    private func trackIndexFromY(_ y: CGFloat) -> TrackTarget {
        var top = rulerH
        var first = true
        for entry in visibleOverlays {
            if !first { top += 1 }; first = false
            let h = overlayH(entry)
            if y < top + h {
                switch entry.kind {
                case .image: return TrackTarget(imageIndex: entry.index)
                case .subtitle: return TrackTarget(subtitleIndex: entry.index)
                case .text: return TrackTarget(textIndex: entry.index)
                case .shape: return TrackTarget(shapeIndex: entry.index)
                case .filter: return TrackTarget(filterIndex: entry.index)
                case .adjust: return TrackTarget(adjustIndex: entry.index)
                case .effect: return TrackTarget(effectIndex: entry.index)
                case .compound: return TrackTarget(compoundIndex: entry.index)
                }
            }
            top += h
        }
        if project.showVideoTracks {
            for item in resolvedVideoSection {
                if !first { top += 1 }; first = false
                let h = videoSectionH(item)
                if y < top + h {
                    if item.kind == .video { return TrackTarget(videoIndex: item.trackIndex) }
                    return TrackTarget(compoundIndex: item.trackIndex)
                }
                top += h
            }
        }
        if project.showAudioTracks {
            for item in resolvedAudioSection {
                if !first { top += 1 }; first = false
                let h = audioSectionH(item)
                if y < top + h {
                    if item.kind == .audio { return TrackTarget(audioIndex: item.trackIndex) }
                    return TrackTarget(compoundIndex: item.trackIndex)
                }
                top += h
            }
        }
        return TrackTarget()
    }

    /// 在视频轨道中渲染转场菱形图标（相邻 clip 之间）
    @ViewBuilder
    private func transitionIcons(trackIndex: Int, trackHeight: CGFloat) -> some View {
        // 正在被拖的片段，它的转场图标一起藏起来。
        // 图标位置是实时从 clip.startTime 算的，而拖动过程中数据只做水平平移
        // （垂直方向由跟手的幻影表现），不藏的话图标会横着挪、却留在原来那条轨道上，
        // 跟幻影分家。松手落位后自然按新位置重新出现
        let pairs = adjacentPairs(in: project.videoTracks[trackIndex])
            .filter { !isDraggingClip($0.clipID) }
        ForEach(pairs, id: \.clipID) { pair in
            TransitionDiamond(hasTransition: pair.hasTransition, isSelected: project.selectedTransitionClipID == pair.clipID)
                .offset(x: pair.cutX - 16, y: 0)
                .zIndex(5)
                .allowsHitTesting(true)
                .onTapGesture {
                    project.selectedTransitionClipID = pair.clipID
                    project.mediaLibraryTab = "transition"
                    project.selectedVideoClipID    = nil
                    project.selectedImageClipID    = nil
                    project.selectedAudioClipID    = nil
                    project.selectedSubtitleClipID = nil
                    project.selectedClipIDs.removeAll()
                }
                .contextMenu {
                    Button(role: .destructive) {
                        project.pushUndo()
                        project.updateVideoClip(id: pair.clipID) { $0.inTransition = nil }
                        if project.selectedTransitionClipID == pair.clipID {
                            project.selectedTransitionClipID = nil
                        }
                        project.rebuildTimelinePreviewDebounced()
                    } label: {
                        Label("删除转场", systemImage: "trash")
                    }
                }
        }
    }

    /// 计算一个视频轨道中所有相邻切割点信息
    private func adjacentPairs(in track: Track<VideoClip>) -> [(clipID: UUID, cutX: CGFloat, hasTransition: Bool)] {
        let sorted = track.clips.sorted { $0.startTime < $1.startTime }
        var result: [(clipID: UUID, cutX: CGFloat, hasTransition: Bool)] = []
        guard sorted.count >= 2 else { return result }
        let pps = project.pixelsPerSecond
        for i in 1..<sorted.count {
            if abs(sorted[i-1].endTime - sorted[i].startTime) < 0.05 {
                let cutX = CGFloat(sorted[i].startTime * pps)
                result.append((sorted[i].id, cutX, sorted[i].inTransition != nil))
            }
        }
        return result
    }

    @ViewBuilder
    private func clipMarkerPins<Clip: Identifiable>(_ clips: [Clip], pps: Double, trackHeight: CGFloat,
                                                    startTime: KeyPath<Clip, Double>,
                                                    markers: KeyPath<Clip, [Marker]?>) -> some View
    where Clip.ID == UUID {
        // 正在拖的片段跳过：它的原体已经隐藏、显示的是幻影，而幻影自己带了一份标记。
        // 不跳过的话拖动时会看到两份标记 —— 一份钉在原位、一份跟着手走
        ForEach(clips.filter { !isDraggingClip($0.id) }.flatMap { clip in
            (clip[keyPath: markers] ?? []).map { m in
                (id: m.id, absTime: clip[keyPath: startTime] + m.time, marker: m)
            }
        }, id: \.id) { entry in
            let isSel = project.selectedMarkerID == entry.id
            let isHov = hoveredMarkerID == entry.id
            Canvas { ctx, size in
                let w = size.width, h = size.height
                var pin = Path()
                let r: CGFloat = 1.5
                pin.move(to: CGPoint(x: r, y: 0))
                pin.addLine(to: CGPoint(x: w - r, y: 0))
                pin.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
                pin.addLine(to: CGPoint(x: w, y: h * 0.6))
                pin.addLine(to: CGPoint(x: w / 2, y: h))
                pin.addLine(to: CGPoint(x: 0, y: h * 0.6))
                pin.addLine(to: CGPoint(x: 0, y: r))
                pin.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
                pin.closeSubpath()
                ctx.fill(pin, with: .color(entry.marker.color.swiftUIColor))
                if isSel {
                    ctx.stroke(pin, with: .color(.white), lineWidth: 1)
                }
            }
            .frame(width: isHov ? 10 : 8, height: isHov ? 14 : 12)
            .popover(isPresented: Binding(
                get: { self.editingMarkerID == entry.id },
                set: { if !$0 { self.editingMarkerID = nil } }
            )) {
                MarkerEditPopover(markerID: entry.id)
                    .environmentObject(project)
            }
            // 顶部距片段上边缘固定留 2px。
            // 原来写死 y: 8，常态 pin 高 12 顶部落在 2 是对的，
            // 但 hover 时 pin 变高到 14、顶部就成了 1，间距会跳一下 ——
            // 改成按高度算，两种状态都稳定在 2
            .position(x: entry.absTime * pps + 1, y: (isHov ? 14 : 12) / 2 + 2)
            .allowsHitTesting(false)
        }
    }

    private func trackRow<C: View>(height: CGFloat, hidden: Bool = false, muted: Bool = false, tint: Color = .white, @ViewBuilder clips: () -> C) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tint.opacity(0.08)).allowsHitTesting(false)
            clips()
        }
        .frame(height: height)
        .opacity(hidden ? 0.32 : (muted ? 0.4 : 1.0))
    }
}

// MARK: - Transition Diamond Icon

private struct TransitionDiamond: View {
    let hasTransition: Bool
    let isSelected: Bool

    var body: some View {
        ZStack {
            // 菱形填充
            Image(systemName: "diamond.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(hasTransition
                    ? (isSelected ? Color.accent : Color(hex: "#3DBFBA"))
                    : Color.white.opacity(0.7))
            // 描边，让菱形在任何背景上都清晰
            Image(systemName: "diamond")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSelected ? .white : Color.black.opacity(0.4))
        }
        .frame(width: 32, height: 32)
    }
}

// MARK: - Track Label

private struct TrackLabel: View {
    let icon: String; let title: String; let count: Int
    let hasMute: Bool; let isMuted: Bool; let isVis: Bool
    var hasVis: Bool = true
    let onMute: (() -> Void)?
    let onVis: () -> Void; let onDel: () -> Void
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: ((CGFloat) -> Void)? = nil

    @State private var isHovered = false
    @State private var isDragging = false

    private var showHandle: Bool { (isHovered || isDragging) && onDragChanged != nil }

    var body: some View {
        ZStack {
            // 默认：图标左对齐 + 数量右对齐
            HStack {
                if SidebarSVGIcon.svgs[icon] != nil {
                    Image(nsImage: SidebarSVGIcon.load(icon))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundColor(Color.labelSecondary)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .light))
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .opacity(isHovered ? 0 : 1)

            if isHovered {
                HStack(spacing: 2) {
                    if hasMute, let onMute {
                        OverlayBtn(svgIcon: SidebarSVGIcon.load(isMuted ? "mute" : "audioSpeaker"),
                                   action: onMute)
                    }
                    if hasVis {
                        OverlayBtn(svgIcon: SidebarSVGIcon.load(isVis ? "show" : "hide"),
                                   action: onVis)
                    }
                    OverlayBtn(svgIcon: TimelineSVGIcon.load("delete"), destructive: true,
                               action: onDel)
                }
            }

            // 拖拽手柄（overlay 不影响布局）
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .topLeading) {
            if showHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(Color.labelSecondary.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in isDragging = true; onDragChanged?(v.translation.height) }
                        .onEnded { v in isDragging = false; onDragEnded?(v.translation.height) })
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.white.opacity(isHovered ? 0.08 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct TrackVisibilityMenu: View {
    @EnvironmentObject var project: ProjectState
    @State private var hov = false
    var body: some View {
        Button {
            let menu = NSMenu()
            func item(_ title: String, _ on: Bool, _ toggle: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.state = on ? .on : .off
                mi.target = nil
                let action = ToggleAction(toggle)
                mi.target = action
                mi.action = #selector(ToggleAction.doToggle)
                objc_setAssociatedObject(mi, "action", action, .OBJC_ASSOCIATION_RETAIN)
                menu.addItem(mi)
            }
            item("图片轨道", project.showImageTracks) { project.showImageTracks.toggle() }
            item("视频轨道", project.showVideoTracks) { project.showVideoTracks.toggle() }
            item("音频轨道", project.showAudioTracks) { project.showAudioTracks.toggle() }
            item("字幕轨道", project.showSubtitleTracks) { project.showSubtitleTracks.toggle() }
            item("文字轨道", project.showTextTracks) { project.showTextTracks.toggle() }
            item("图形轨道", project.showShapeTracks) { project.showShapeTracks.toggle() }
            item("复合片段", project.showCompoundTracks) { project.showCompoundTracks.toggle() }
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: event.window!.contentView!)
            }
        } label: {
            Image(nsImage: TimelineSVGIcon.load("show"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(hov ? Color.labelPrimary : Color.labelSecondary)
                .frame(width: 28, height: 28)
                .background(hov ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help("显示/隐藏轨道")
    }
}

private class ToggleAction: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func doToggle() { closure() }
}

private struct TrackToggleBtn: View {
    let icon: String
    @Binding var on: Bool
    let help: String
    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(on ? Color.accent : Color.labelSecondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct TrackToggleBtnT: View {
    @Binding var on: Bool
    let help: String
    var body: some View {
        Button { on.toggle() } label: {
            Text("T")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundColor(on ? Color.accent : Color.labelSecondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct TextTrackLabel: View {
    let title: String; let count: Int
    let isVis: Bool
    let onVis: () -> Void; let onDel: () -> Void
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: ((CGFloat) -> Void)? = nil
    @State private var isHovered = false
    @State private var isDragging = false

    private var showHandle: Bool { (isHovered || isDragging) && onDragChanged != nil }

    var body: some View {
        ZStack {
            HStack {
                Image(nsImage: SidebarSVGIcon.load("text"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .opacity(isHovered ? 0 : 1)

            if isHovered {
                HStack(spacing: 2) {
                    OverlayBtn(svgIcon: SidebarSVGIcon.load(isVis ? "show" : "hide"), action: onVis)
                    OverlayBtn(svgIcon: TimelineSVGIcon.load("delete"), destructive: true, action: onDel)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .topLeading) {
            if showHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(Color.labelSecondary.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in isDragging = true; onDragChanged?(v.translation.height) }
                        .onEnded { v in isDragging = false; onDragEnded?(v.translation.height) })
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 0)
            .stroke(Color.white.opacity(isHovered ? 0.08 : 0), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct OverlayBtn: View {
    var icon: String = ""
    var svgIcon: NSImage? = nil
    var destructive: Bool = false
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Group {
                if let svgIcon {
                    Image(nsImage: svgIcon)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundColor(hov ? (destructive ? .red.opacity(0.9) : .white.opacity(0.95)) : Color.labelSecondary)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
    }
}

// MARK: - Visual Effect Blur (NSVisualEffectView wrapper)

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Clip views

// Clip views are now passive visuals — drag (move) AND box-select are
// handled by ONE unified gesture on the outer ZStack (see `unifiedDragGesture`),
// which dispatches based on whether the drag origin lands on a clip or empty
// timeline space. Tap behavior (selection) stays here on each clip.

/// 时间轴片段的通用尺寸阈值
enum TimelineClipMetrics {
    /// 标题和时长能否并排放下。放不下就让时长换到第二行，
    /// 固定阈值判断不了 —— 名字长的片段在同样宽度下早就撞上了
    static func fitsOnOneLine(title: String, duration: String,
                              clipWidth: CGFloat, leading: CGFloat) -> Bool {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium)]
        let titleW = (title as NSString).size(withAttributes: attrs).width
        let durW = (duration as NSString).size(withAttributes: attrs).width
        // 两侧内边距 + 中间至少 8pt 间隔
        return leading + titleW + 8 + durW + 5 <= clipWidth
    }

    /// 窄于此宽度就不画缩略图/波形，只铺纯色 —— 那个尺度下内容本身也看不清，
    /// 还要为每个片段做抽帧和绘制，缩到很小时白白拖慢时间轴
    static let contentMinWidth: CGFloat = 16
    /// 窄于此宽度连标题行都不画
    static let labelMinWidth: CGFloat = 16
}

private struct VideoClipView: View {
    let clip: VideoClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState
    @State private var thumbBreathing = false
    @State private var placeholderBreathing = false

    private var isReloading: Bool {
        project.thumbnailsReloading.contains(clip.assetID)
    }

    /// 生成中的空占位（目前来自「清晰度提升」：点完 x2/x4 立刻插一条空轨道，
    /// 处理完再原地填成真实素材）。跟字幕翻译的占位共用 placeholderClipIDs
    private var isPlaceholder: Bool {
        project.placeholderClipIDs.contains(clip.id)
    }

    @State private var editName: String = ""
    @State private var editing = false          // 本地编辑标志：置空 renamingClipID 后仍能提交
    @FocusState private var nameFieldFocused: Bool
    private var isRenaming: Bool { project.renamingClipID == clip.id }
    private func commitRename() {
        guard editing else { return }           // Esc 已把它置 false，则不提交
        editing = false
        project.renameClipOrAsset(clipID: clip.id, to: editName)
        project.renamingClipID = nil
    }
    private func cancelRename() {
        editing = false
        project.renamingClipID = nil
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return max(0, min(-clipLeftInViewport + 5, w - 60)) }
        return 5
    }

    private var durationText: String {
        let d = clip.duration
        let h = Int(d) / 3600; let m = Int(d) / 60 % 60; let s = Int(d) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        // 标题前不再放类型图标（轨道左侧标签已表明类型），只留文字
        let showDurRight = TimelineClipMetrics.fitsOnOneLine(
            title: clip.name, duration: durationText, clipWidth: w, leading: stickyTitleX)
        let showDuration = w > TimelineClipMetrics.labelMinWidth
        ZStack(alignment:.leading) {
            // Thumbnail strip or solid color —— 窄到画不下内容时只铺纯色
            if w > TimelineClipMetrics.contentMinWidth,
               let frames = project.assetThumbnails[clip.assetID], !frames.isEmpty {
                thumbnailStrip(frames: frames, clipWidth: w)
            } else {
                // 占位（还在生成、没有画面）用更淡的底色，跟有内容的片段区分开
                RoundedRectangle(cornerRadius:6)
                    .fill(Color(hex:"#3DBFBA").opacity(isPlaceholder ? 0.35 : 0.82))
            }
            // 重建缩略图时的呼吸遮罩（这条是叠在已有画面上的，同色半透明能看出来）。
            // 占位不走这里——占位底下是同色实块，再叠一层同色遮罩，0.18 和 0.55
            // 混出来几乎一个样，动画在跑却看不见。占位改成让整块的 opacity 呼吸，
            // 跟 SubtitleClipView 的占位一致，见本视图末尾的 .opacity / .onAppear
            if isReloading && !isPlaceholder {
                RoundedRectangle(cornerRadius:6)
                    .fill(Color(hex:"#3DBFBA").opacity(thumbBreathing ? 0.35 : 0.15))
            }
            // Selection border
            RoundedRectangle(cornerRadius:6)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            // Name label — sticky to viewport left edge，太窄就整行不画
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    if isRenaming {
                        TextField("", text: $editName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white)
                            .focused($nameFieldFocused)
                            .frame(minWidth: 40, maxWidth: 120)
                            .onSubmit { commitRename() }
                            .onAppear {
                                editName = clip.name
                                editing = true
                                DispatchQueue.main.async { nameFieldFocused = true }
                            }
                            .onChange(of: nameFieldFocused) { f in if !f { commitRename() } }
                            .onDisappear { commitRename() }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(clip.name).font(.system(size:8, weight:.medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // 时长
            if showDuration, showDurRight {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.trailing, 5).padding(.top, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if showDuration {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.leading, stickyTitleX).padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // 速率徽章（speed != 1.0 时显示）
            if showDuration, abs(clip.speed - 1.0) > 0.01 {
                let speedLabel: String = {
                    let s = clip.speed
                    if s < 1.0 { return String(format: "%.2g×", s) }
                    else { return String(format: s.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f×" : "%.1f×", s) }
                }()
                Text(speedLabel)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 5).padding(.bottom, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // 源文件没了：压暗 + 橙描边 + 可点的警示图标（点了重新关联）。
        // 在 clipShape 之后挂，标记才跟着片段的圆角裁剪
        .overlay(ClipMissingOverlay(assetID: clip.assetID, width: w, selected: sel))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        // 占位：整块 opacity 在 1.0 ↔ 0.45 之间呼吸。必须作用在整块上而不是叠一层
        // 同色遮罩——底下就是同色实块，叠加前后混出来一个样，看不出在动。
        .opacity(isPlaceholder && placeholderBreathing ? 0.45 : 1.0)
        .onAppear {
            // 占位是插进来时就已经存在的，等不到 onChange，必须在 onAppear 起动
            if isPlaceholder {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    placeholderBreathing = true
                }
            }
        }
        .onChange(of: isPlaceholder) { ph in
            if ph {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    placeholderBreathing = true
                }
            } else {
                // 填上真实素材后要停下来，否则整条轨道会一直忽明忽暗
                withAnimation(.easeInOut(duration: 0.2)) { placeholderBreathing = false }
            }
        }
        // 重建缩略图的遮罩呼吸（跟上面占位那套互不干扰）
        .animation(isReloading ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                   value: thumbBreathing)
        .onChange(of: isReloading) { loading in thumbBreathing = loading }
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(isRenaming)
        .onAppear {
            if let url = clip.url {
                project.loadTimelineThumbnails(assetID: clip.assetID, url: url)
            }
        }
    }

    @ViewBuilder
    private func thumbnailStrip(frames: [ThumbnailFrame], clipWidth: CGFloat) -> some View {
        let thumbH = h - 4
        // 格子宽高比优先用片段自己的原始尺寸算——它是固定值，不会因为缩略图重建
        // 而变。原本取自 frames.first 的图片尺寸：缩略图一重建，如果新帧来自
        // ffmpeg 兜底而不是 AVFoundation（两者输出尺寸不同），ratio 就变了，
        // 连带 thumbW / count 全变，整条缩略图重新排布，看着就是片段在抖。
        // 只有拿不到原始尺寸时（新建 clip 还没探测出来，值为 0）才退回用首帧。
        let ratio: CGFloat = {
            if clip.videoWidth > 0.001, clip.videoHeight > 0.001 {
                return CGFloat(clip.videoWidth / clip.videoHeight)
            }
            return frames.first.map { CGFloat($0.image.size.width) / max(CGFloat($0.image.size.height), 1) } ?? 1.0
        }()
        let thumbW = max(thumbH * ratio, 1)
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        // 只渲染可视范围内的缩略图
        let clipStartX = clip.startTime * pps
        let visLeft = scrollOffsetX - clipStartX - thumbW  // 相对于片段左侧的可见左边界
        let visRight = scrollOffsetX + max(project.timelineVisibleWidth, 400) - clipStartX + thumbW
        let startIdx = max(0, Int(floor(visLeft / thumbW)))
        let endIdx = max(startIdx, min(count, Int(ceil(visRight / thumbW))))
        // 每张缩略图按索引**绝对定位**，不用 HStack 流式布局 + 空占位撑位置。
        //
        // 流式布局的问题只在多片段时才暴露：头部占位宽度是 thumbW * startIdx，
        // 而 startIdx 由 (scrollOffsetX - clip.startTime * pps) 推出来。单条片段
        // startTime 通常是 0，startIdx 基本恒为 0、根本走不到占位那条路；多条片段
        // 每条的 startTime 都不同，缩放时 pps 和 scrollOffsetX 只要有一帧不同步，
        // startIdx 就会跳一格，头部占位跟着跳一个 thumbW，整条图平移一格——
        // 表现出来就是"多条片段缩放时晃，单条不晃"。
        //
        // 绝对定位后，每张图的 x 只由它自己的索引决定（thumbW * i），跟 startIdx、
        // 跟渲染了多少张都无关。虚拟化窗口怎么抖，已渲染的图都待在原地不动。
        ZStack(alignment: .topLeading) {
            // 撑满整条，保证 ZStack 尺寸稳定、不随渲染出的图数量变化
            Color.clear.frame(width: clipWidth, height: thumbH)
            ForEach(startIdx..<endIdx, id: \.self) { i in
                // 采样时间按**位置比例**算，不用 i/count。count 是 ceil 出来的整数，
                // 缩放时 clipWidth 连续变而 count 跳变，i/count 会突然跳一下，
                // closestFrame 就选到另一帧、图片内容闪一下。用 (thumbW*i)/clipWidth
                // 是连续量，缩放过程中采样点平滑移动，不会闪。
                let posRatio = clipWidth > 0 ? Double(thumbW * CGFloat(i) / clipWidth) : 0
                // 倒放的片段，左端放的是源素材**末尾**那一帧，所以采样比例要翻过来 ——
                // 不翻的话画面倒着播、缩略图却顺着排，对不上
                let srcRatio = clip.reversed ? (1 - min(1, posRatio)) : min(1, posRatio)
                let t = clip.trimStart + clip.duration * max(0.01, clip.speed) * srcRatio
                let frame = closestFrame(frames, at: t)
                // 最后一格用余数宽度，避免最后一张越过片段右边缘
                let wCell = i == count - 1 ? max(0, clipWidth - thumbW * CGFloat(count - 1)) : thumbW
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: wCell, height: thumbH)
                    .clipped()
                    .offset(x: thumbW * CGFloat(i))
            }
        }
        // alignment 必须显式给 .leading。默认是 .center，一旦 HStack 内容的实际
        // 总宽跟 clipWidth 差一点（几百个 Image frame 的亚像素舍入会累积，缩放
        // 倍数越大格数越多、误差越大），居中就会把这点误差平摊到左右两边——
        // 表现出来就是整条缩略图相对片段左右晃。左对齐后，内容永远从片段左边缘
        // 开始画，宽度误差只会落在右端被 clipShape 裁掉，看不出来。
        .frame(width: clipWidth, height: thumbH, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func closestFrame(_ frames: [ThumbnailFrame], at time: Double) -> ThumbnailFrame {
        frames.min(by: { abs($0.time - time) < abs($1.time - time) }) ?? frames[0]
    }
}

private struct ImageClipView: View {
    let clip: ImageClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    @State private var editName: String = ""
    @State private var editing = false          // 本地编辑标志：置空 renamingClipID 后仍能提交
    @FocusState private var nameFieldFocused: Bool
    private var isRenaming: Bool { project.renamingClipID == clip.id }
    private func commitRename() {
        guard editing else { return }           // Esc 已把它置 false，则不提交
        editing = false
        project.renameClipOrAsset(clipID: clip.id, to: editName)
        project.renamingClipID = nil
    }
    private func cancelRename() {
        editing = false
        project.renamingClipID = nil
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return max(0, min(-clipLeftInViewport + 5, w - 60)) }
        return 5
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        ZStack(alignment:.leading) {
            if w > TimelineClipMetrics.contentMinWidth,
               let thumb = project.mediaThumbnails[clip.assetID] {
                // 按固定单元宽（轨道高 × 宽高比）平铺，跟视频缩略图条一致。
                // 原来是 frame(width: w) 拉满整条，左右裁剪时封面会被拉伸压扁
                let ratio = CGFloat(thumb.size.width) / max(CGFloat(thumb.size.height), 1)
                let cellH = h - 4
                let cellW = max(cellH * ratio, 1)
                let count = max(1, Int(ceil(w / cellW)))
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        let wCell = i == count - 1
                            ? max(0, w - cellW * CGFloat(count - 1)) : cellW
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: wCell, height: cellH)
                            .clipped()
                    }
                }
                .frame(width: w, height: cellH, alignment: .leading)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius:6).fill(Color(hex:"#E8A54B").opacity(0.82))
            }
            RoundedRectangle(cornerRadius:6)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    if isRenaming {
                        TextField("", text: $editName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white)
                            .focused($nameFieldFocused)
                            .frame(minWidth: 40, maxWidth: 120)
                            .onSubmit { commitRename() }
                            .onAppear {
                                editName = clip.name
                                editing = true
                                DispatchQueue.main.async { nameFieldFocused = true }
                            }
                            .onChange(of: nameFieldFocused) { f in if !f { commitRename() } }
                            .onDisappear { commitRename() }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(clip.name).font(.system(size:8, weight:.medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // 源文件没了：压暗 + 橙描边 + 可点的警示图标（点了重新关联）。
        // 在 clipShape 之后挂，标记才跟着片段的圆角裁剪
        .overlay(ClipMissingOverlay(assetID: clip.assetID, width: w, selected: sel))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(isRenaming)
    }
}

private struct AudioClipView: View {
    let clip: AudioClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    @State private var editName: String = ""
    @State private var editing = false          // 本地编辑标志：置空 renamingClipID 后仍能提交
    @FocusState private var nameFieldFocused: Bool
    private var isRenaming: Bool { project.renamingClipID == clip.id }
    private func commitRename() {
        guard editing else { return }           // Esc 已把它置 false，则不提交
        editing = false
        project.renameClipOrAsset(clipID: clip.id, to: editName)
        project.renamingClipID = nil
    }
    private func cancelRename() {
        editing = false
        project.renamingClipID = nil
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return max(0, min(-clipLeftInViewport + 5, w - 60)) }
        return 5
    }

    private var durationText: String {
        let d = clip.duration
        let hh = Int(d) / 3600; let m = Int(d) / 60 % 60; let s = Int(d) % 60
        return hh > 0 ? String(format: "%d:%02d:%02d", hh, m, s) : String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        // 标题前不再放类型图标（轨道左侧标签已表明类型），只留文字
        let showDurRight = TimelineClipMetrics.fitsOnOneLine(
            title: clip.name, duration: durationText, clipWidth: w, leading: stickyTitleX)
        let showDuration = w > TimelineClipMetrics.labelMinWidth
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius:6).fill(Color(hex:"#5DB85D").opacity(0.78))
            if w > TimelineClipMetrics.contentMinWidth,
               let wave = project.waveformCache[clip.assetID] {
                AudioWaveformCanvas(waveData: wave, trimStart: clip.trimStart,
                                     clipDuration: clip.duration, fullHeight: true,
                                     clipStartX: CGFloat(clip.startTime * pps),
                                     scrollOffsetX: scrollOffsetX,
                                     vpWidth: max(project.timelineVisibleWidth, 400))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            RoundedRectangle(cornerRadius:6).stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    if isRenaming {
                        TextField("", text: $editName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white)
                            .focused($nameFieldFocused)
                            .frame(minWidth: 40, maxWidth: 120)
                            .onSubmit { commitRename() }
                            .onAppear {
                                editName = clip.name
                                editing = true
                                DispatchQueue.main.async { nameFieldFocused = true }
                            }
                            .onChange(of: nameFieldFocused) { f in if !f { commitRename() } }
                            .onDisappear { commitRename() }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(clip.name).font(.system(size:8, weight:.medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if showDuration, showDurRight {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.trailing, 5).padding(.top, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if showDuration {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.leading, stickyTitleX).padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if showDuration, abs(clip.speed - 1.0) > 0.01 {
                let speedLabel: String = {
                    let s = clip.speed
                    if s < 1.0 { return String(format: "%.2g×", s) }
                    else { return String(format: s.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f×" : "%.1f×", s) }
                }()
                Text(speedLabel)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 5).padding(.bottom, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // 源文件没了：压暗 + 橙描边 + 可点的警示图标（点了重新关联）。
        // 在 clipShape 之后挂，标记才跟着片段的圆角裁剪
        .overlay(ClipMissingOverlay(assetID: clip.assetID, width: w, selected: sel))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .onAppear {
            if let url = clip.url {
                project.loadWaveform(assetID: clip.assetID, url: url)
            }
        }
        .allowsHitTesting(isRenaming)
    }
}

/// Canvas-based audio waveform visualization
/// 波形绘制。时间轴和画布的音频卡片共用这一份
struct AudioWaveformCanvas: View {
    let waveData: WaveformData
    let trimStart: Double
    let clipDuration: Double
    var fullHeight: Bool = false
    var clipStartX: CGFloat = 0      // 片段在内容坐标中的起始 x
    var scrollOffsetX: CGFloat = 0
    var vpWidth: CGFloat = 800
    /// 波形颜色。时间轴里是半透明白，画布的音频卡片要绿色 ——
    /// 写死在 Canvas 里的话外面套 foregroundColor 是不生效的
    var barColor: Color = .white.opacity(0.30)

    var body: some View {
        Canvas { ctx, size in
            guard waveData.totalDuration > 0, !waveData.samples.isEmpty else { return }
            let startFrac = trimStart / waveData.totalDuration
            let endFrac   = (trimStart + clipDuration) / waveData.totalDuration
            let startIdx  = max(0, Int(startFrac * Double(waveData.samples.count)))
            let endIdx    = max(startIdx, min(Int(endFrac * Double(waveData.samples.count)), waveData.samples.count))
            guard startIdx < endIdx else { return }

            let visible = Array(waveData.samples[startIdx..<endIdx])
            let barCount = Int(size.width)
            guard barCount > 0 else { return }

            // 只绘制可视范围内的条
            let visLeft = max(0, Int(scrollOffsetX - clipStartX - 2))
            let visRight = min(barCount, Int(scrollOffsetX + vpWidth - clipStartX + 2))
            let drawStart = max(0, visLeft)
            let drawEnd = min(barCount, visRight)
            guard drawStart < drawEnd else { return }

            if fullHeight {
                let maxPeak = max(visible.max() ?? 1, 0.01)
                for x in drawStart..<drawEnd {
                    let sIdx = x * visible.count / barCount
                    let eIdx = min(sIdx + max(1, visible.count / barCount), visible.count)
                    guard sIdx < eIdx else { continue }
                    let peak = (visible[sIdx..<eIdx].max() ?? 0) / maxPeak
                    let barH = max(1, CGFloat(peak) * size.height)
                    let rect = CGRect(x: CGFloat(x), y: size.height - barH,
                                      width: 1, height: barH)
                    ctx.fill(Path(rect), with: .color(barColor))
                }
            } else {
                let midY = size.height / 2
                for x in drawStart..<drawEnd {
                    let sIdx = x * visible.count / barCount
                    let eIdx = min(sIdx + max(1, visible.count / barCount), visible.count)
                    guard sIdx < eIdx else { continue }
                    let peak = visible[sIdx..<eIdx].max() ?? 0
                    let barH = CGFloat(peak) * (size.height * 0.75)
                    let rect = CGRect(x: CGFloat(x), y: midY - barH / 2,
                                      width: 1, height: max(1, barH))
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.35)))
                }
            }
        }
    }
}

private struct SubtitleClipView: View {
    let clip: SubtitleClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState
    @State private var breathing = false

    private var isPlaceholder: Bool {
        project.placeholderClipIDs.contains(clip.id)
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 4 { return max(0, min(-clipLeftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:6)
                .fill(Color(hex:"#7B6FC4").opacity(isPlaceholder ? 0.35 : 0.85))
                .overlay(RoundedRectangle(cornerRadius:6)
                    .stroke(sel ? Color.white : Color(hex:"#9B8FD4").opacity(0.4), lineWidth: 1))
            if !isPlaceholder && w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                        .font(.system(size:8, weight:.medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 : (isPlaceholder && breathing) ? 0.4 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .onAppear { if isPlaceholder { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true } } }
        .onChange(of: isPlaceholder) { ph in
            if ph {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
            } else {
                withAnimation(.default) { breathing = false }
            }
        }
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
    }
}

private struct TextClipView: View {
    let clip: TextClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 4 { return max(0, min(-clipLeftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:6)
                .fill(Color(hex:"#D4668E").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius:6)
                    .stroke(sel ? Color.white : Color(hex:"#E088A8").opacity(0.4), lineWidth: 1))
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                        .font(.system(size:8, weight:.medium))
                        .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                }
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
    }
}

private struct ShapeTimelineClipView: View {
    let clip: ShapeClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 4 { return max(0, min(-clipLeftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:6)
                .fill(Color(hex:"#5B8FF9").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius:6)
                    .stroke(sel ? Color.white : Color(hex:"#8AB4FF").opacity(0.4), lineWidth: 1))
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Text(clip.type.label)
                        .font(.system(size:8, weight:.medium))
                        .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                }
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
    }
}

private struct CompoundClipView: View {
    let clip: CompoundClip
    let pps: Double
    let h: CGFloat
    var scrollOffsetX: CGFloat = 0
    var sel: Bool = false
    var isDragging: Bool = false
    @EnvironmentObject var project: ProjectState
    @State private var editName: String = ""
    @State private var editingCompound = false
    @FocusState private var nameFieldFocused: Bool

    private var isRenaming: Bool { project.renamingCompoundClipID == clip.id }

    private enum ContentKind { case video(UUID, reversed: Bool), image(UUID), audio(UUID), subtitle(String), text(String), shape, empty }

    private var primaryContent: ContentKind {
        let c = clip.flattened()
        if let vc = c.videoTracks.flatMap(\.clips).first { return .video(vc.assetID, reversed: vc.reversed) }
        if let ic = c.imageTracks.flatMap(\.clips).first { return .image(ic.assetID) }
        if let ac = c.audioTracks.flatMap(\.clips).first { return .audio(ac.assetID) }
        if !c.shapeTracks.flatMap(\.clips).isEmpty { return .shape }
        if let tc = c.textTracks.flatMap(\.clips).first { return .text(tc.text) }
        if let sub = c.subtitleTracks.flatMap(\.clips).first { return .subtitle(sub.text) }
        return .empty
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        // w - 60 在窄片段上是负数，直接当 padding 会把标题推出片段左边界
        if clipLeftInViewport < 5 { return max(0, min(-clipLeftInViewport + 5, w - 60)) }
        return 5
    }

    private var durationText: String {
        let d = clip.duration
        let h = Int(d) / 3600; let m = Int(d) / 60 % 60; let s = Int(d) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 时长在右上角时标题要让出的宽度（8pt 等宽数字约 5pt/字符 + 两侧边距）
    private var durationReserve: CGFloat {
        CGFloat(durationText.count) * 5 + 10
    }

    var body: some View {
        let w = max(clip.duration * pps, 4)
        let clipH = h - 4
        // 复合片段标题前还有 8pt 图标 + 3pt 间距
        let showDurRight = TimelineClipMetrics.fitsOnOneLine(
            title: clip.name, duration: durationText, clipWidth: w, leading: stickyTitleX)
        let showDuration = w > TimelineClipMetrics.labelMinWidth
        ZStack(alignment: .leading) {
            contentBackground(w: w, clipH: clipH)
            if w > TimelineClipMetrics.labelMinWidth {
            HStack(spacing: 3) {
                if isRenaming {
                    TextField("", text: $editName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white)
                        .focused($nameFieldFocused)
                        .frame(minWidth: 40, maxWidth: 120)
                        .onSubmit { commitRename() }
                        .onAppear {
                            editName = clip.name
                            editingCompound = true
                            DispatchQueue.main.async { nameFieldFocused = true }
                        }
                        .onChange(of: nameFieldFocused) { focused in
                            if !focused { commitRename() }
                        }
                        .onDisappear { commitRename() }
                        .onExitCommand {
                            editingCompound = false
                            project.renamingCompoundClipID = nil
                        }
                } else {
                    // 宽度不够时优先压缩名字（复合片段1 → 复…），图标和时长保持原样
                    Text(clip.name)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
            .padding(.leading, stickyTitleX)
            .padding(.trailing, showDurRight ? durationReserve : 4)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if showDuration, showDurRight {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.trailing, 5)
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if showDuration {
                Text(durationText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                    .padding(.leading, stickyTitleX)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: w, height: clipH)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 1 : 0)
        )
        .opacity(isDragging ? 0 : 1.0)
        .offset(x: clip.startTime * pps + 1)
        .allowsHitTesting(isRenaming)
    }

    private func commitRename() {
        guard editingCompound else { return }
        editingCompound = false
        let n = editName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty && n != clip.name {
            project.updateCompoundClip(id: clip.id) { $0.name = n }
        }
        project.renamingCompoundClipID = nil
    }

    @ViewBuilder
    private func contentBackground(w: CGFloat, clipH: CGFloat) -> some View {
        if w <= TimelineClipMetrics.contentMinWidth {
            // 窄到画不下内容，只铺纯色
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
        } else {
            compoundContent(w: w, clipH: clipH)
        }
    }

    @ViewBuilder
    private func compoundContent(w: CGFloat, clipH: CGFloat) -> some View {
        switch primaryContent {
        case .video(let assetID, let reversed):
            if let frames = project.assetThumbnails[assetID], !frames.isEmpty {
                videoThumbnailStrip(frames: frames, clipWidth: w, clipH: clipH, reversed: reversed)
                    .overlay(Color(hex: "#FF9F43").opacity(0.15))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
            }
        case .image(let assetID):
            if let thumb = project.mediaThumbnails[assetID] {
                imageThumbnailStrip(thumb, clipWidth: w, clipH: clipH)
                    .overlay(Color(hex: "#FF9F43").opacity(0.15))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
            }
        case .audio(let assetID):
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.78))
                if let wave = project.waveformCache[assetID] {
                    AudioWaveformCanvas(waveData: wave, trimStart: 0, clipDuration: clip.duration, fullHeight: true)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .opacity(0.5)
                }
            }
        case .text:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
                Image(nsImage: SidebarSVGIcon.load("text"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white.opacity(0.3))
            }
        case .subtitle:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
                Image(nsImage: SidebarSVGIcon.load("subtitle"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white.opacity(0.3))
            }
        case .shape:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
                Image(nsImage: SidebarSVGIcon.load("shape"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(.white.opacity(0.3))
            }
        case .empty:
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#FF9F43").opacity(0.82))
        }
    }

    /// 图片片段的缩略图条：按**固定单元宽**（轨道高 × 图片宽高比）平铺同一张图。
    ///
    /// 原来是 `frame(width: 整个片段宽)` 直接拉满，左右裁剪改变片段长度时
    /// 封面就跟着被拉伸压扁 —— 视频那边一直是按单元宽平铺的，这里跟它对齐
    @ViewBuilder
    private func imageThumbnailStrip(_ thumb: NSImage, clipWidth: CGFloat, clipH: CGFloat) -> some View {
        let ratio = CGFloat(thumb.size.width) / max(CGFloat(thumb.size.height), 1)
        let thumbW = max(clipH * ratio, 1)
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                // 最后一格用余数宽度，别越过片段右边缘
                let wCell = i == count - 1
                    ? max(0, clipWidth - thumbW * CGFloat(count - 1)) : thumbW
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: wCell, height: clipH)
                    .clipped()
            }
        }
        .frame(width: clipWidth, height: clipH, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private func videoThumbnailStrip(frames: [ThumbnailFrame], clipWidth: CGFloat, clipH: CGFloat,
                                     reversed: Bool = false) -> some View {
        let ratio: CGFloat = frames.first.map { CGFloat($0.image.size.width) / max(CGFloat($0.image.size.height), 1) } ?? 1.0
        let thumbW = max(clipH * ratio, 1)
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        let clipStartX = clip.startTime * pps
        let visLeft = scrollOffsetX - clipStartX - thumbW
        let visRight = scrollOffsetX + max(project.timelineVisibleWidth, 400) - clipStartX + thumbW
        let startIdx = max(0, Int(floor(visLeft / thumbW)))
        let endIdx = max(startIdx, min(count, Int(ceil(visRight / thumbW))))
        HStack(spacing: 0) {
            if startIdx > 0 { Color.clear.frame(width: thumbW * CGFloat(startIdx), height: clipH) }
            ForEach(startIdx..<endIdx, id: \.self) { i in
                // 里面的视频是倒放的话，缩略图也得倒着排（跟画面走）
                let idx = reversed ? (count - 1 - i) : i
                let t = clip.duration * Double(idx) / Double(count)
                let frame = frames.min(by: { abs($0.time - t) < abs($1.time - t) }) ?? frames[0]
                Image(nsImage: frame.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: i == count - 1 ? clipWidth - thumbW * CGFloat(count - 1) : thumbW, height: clipH)
                    .clipped()
            }
            if endIdx < count { Color.clear.frame(width: max(0, clipWidth - thumbW * CGFloat(endIdx)), height: clipH) }
        }
        .frame(width: clipWidth, height: clipH)
    }
}

// MARK: - Ruler

private struct TimelineRuler: View {
    let pps: Double; let duration: Double
    var scrollOffsetX: CGFloat = 0; var vpWidth: CGFloat = 800
    private let fps: Double = 30

    // 主刻度级别（每个主刻度显示标签）
    // pixelThreshold: 当一个主刻度间距 >= 这么多像素时使用该级别
    private struct Level {
        let majorStep: Double   // 主刻度间隔（秒）
        let minorDiv: Int       // 主刻度之间的小刻度数量
        let isFrame: Bool       // 是否用帧数标签
        let frameCount: Int     // 帧数（仅 isFrame=true 时）
    }

    /// 根据 pps 选择合适的刻度级别
    private func chooseLevel() -> Level {
        let f = 1.0 / fps
        // 从最精细到最粗，取第一个主刻度像素间距 >= 40px 的
        let levels: [Level] = [
            Level(majorStep: f * 2,   minorDiv: 2,  isFrame: true,  frameCount: 2),   // 2f
            Level(majorStep: f * 3,   minorDiv: 3,  isFrame: true,  frameCount: 3),   // 3f
            Level(majorStep: f * 5,   minorDiv: 5,  isFrame: true,  frameCount: 5),   // 5f
            Level(majorStep: f * 10,  minorDiv: 5,  isFrame: true,  frameCount: 10),  // 10f
            Level(majorStep: f * 15,  minorDiv: 5,  isFrame: true,  frameCount: 15),  // 15f
            Level(majorStep: 1,       minorDiv: 5,  isFrame: false, frameCount: 0),   // 1s
            Level(majorStep: 2,       minorDiv: 4,  isFrame: false, frameCount: 0),   // 2s
            Level(majorStep: 3,       minorDiv: 3,  isFrame: false, frameCount: 0),   // 3s
            Level(majorStep: 5,       minorDiv: 5,  isFrame: false, frameCount: 0),   // 5s
            Level(majorStep: 10,      minorDiv: 5,  isFrame: false, frameCount: 0),   // 10s
            Level(majorStep: 30,      minorDiv: 6,  isFrame: false, frameCount: 0),   // 30s
            Level(majorStep: 60,      minorDiv: 6,  isFrame: false, frameCount: 0),   // 1min
            Level(majorStep: 120,     minorDiv: 4,  isFrame: false, frameCount: 0),   // 2min
            Level(majorStep: 180,     minorDiv: 3,  isFrame: false, frameCount: 0),   // 3min
            Level(majorStep: 300,     minorDiv: 5,  isFrame: false, frameCount: 0),   // 5min
            Level(majorStep: 600,     minorDiv: 5,  isFrame: false, frameCount: 0),   // 10min
            Level(majorStep: 900,     minorDiv: 3,  isFrame: false, frameCount: 0),   // 15min
            Level(majorStep: 1800,    minorDiv: 6,  isFrame: false, frameCount: 0),   // 30min
        ]
        for lv in levels {
            if lv.majorStep * pps >= 40 { return lv }
        }
        return levels.last!
    }

    /// 格式化刻度标签
    private func labelFor(_ t: Double, level: Level) -> String {
        if level.isFrame {
            let frame = Int((t * fps).rounded())
            return "\(frame)f"
        }
        let totalSec = Int(t.rounded())
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        Canvas { ctx, size in
            let level = chooseLevel()
            let majorStep = level.majorStep
            let minorStep = majorStep / Double(level.minorDiv)

            // 只绘制可视范围内的刻度（Canvas 坐标 = 内容坐标）
            // Canvas 自动裁剪，但跳过不可见区域避免无用计算
            let startTime = max(0, floor((scrollOffsetX / pps) / minorStep) * minorStep - minorStep)
            let endTime = min(max(duration, size.width / pps) + majorStep,
                              ((scrollOffsetX + vpWidth) / pps) + majorStep)

            var t = startTime
            while t <= endTime {
                // 内容坐标 → 视口坐标（固定顶条里刻度尺不再被 ScrollView 自动平移，需手动减去横滑量）
                let x = t * pps - scrollOffsetX
                let majRem = majorStep > 0.001 ? t.truncatingRemainder(dividingBy: majorStep) : 0
                let isMajor = majRem < 0.001 || (majorStep - majRem) < 0.001

                let tickH: CGFloat = isMajor ? 14 : 7
                let opacity: Double = isMajor ? 0.4 : 0.15

                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - tickH))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(.white.opacity(opacity)), lineWidth: 1)

                if isMajor {
                    let label = labelFor(t, level: level)
                    ctx.draw(
                        Text(label)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.white.opacity(0.4)),
                        at: CGPoint(x: x + 3, y: 8),
                        anchor: .leading)
                }
                t += minorStep
            }
        }
        .background(Color.clear)   // 底色交给外层的系统材质
    }
}

// MARK: - Draggable Playhead

private struct DraggablePlayhead: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    let pps: Double
    let fullHeight: CGFloat
    /// 顶部要让开的高度（= 刻度尺高度）。
    /// 滚动内容的最上面 rulerH 那一段是给固定顶条留的透明占位，顶条自己没有底色
    /// （底色交给外层材质），所以从 y=0 画的话这一截会从顶条底下透出来，
    /// 看着就是竖线穿过播放头三角、还高出三角顶边一截。
    /// 顶条内部的 connector 画到 y=rulerH 为止，这里正好从那里接上
    let topInset: CGFloat

    var body: some View {
        let x = clock.currentTime * pps
        Canvas { ctx, size in
            // 三角已移到固定顶条；这里只画贯穿轨道的竖线
            let line = CGRect(x: x - 0.5, y: topInset, width: 1,
                              height: max(0, fullHeight - topInset))
            ctx.fill(Path(line), with: .color(Color.accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Log-scale Slider

/// 对数刻度 Slider：低值区细腻，高值区快速
private struct LogSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var logValue: Binding<Double> {
        Binding(
            get: { log(value) },
            set: { value = exp($0).clamped(to: range) }
        )
    }

    var body: some View {
        CustomSlider(value: logValue, range: log(range.lowerBound)...log(range.upperBound))
    }
}

// MARK: - Compound Breadcrumb

struct CompoundBreadcrumb: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        if project.isInsideCompound {
            HStack(spacing: 4) {
                Button {
                    while project.isInsideCompound { project.exitCompound() }
                } label: {
                    Text("主时间线")
                        .font(.system(size: 11))
                        .foregroundColor(Color.accent)
                }
                .buttonStyle(.plain)
                ForEach(Array(project.compositionStack.enumerated()), id: \.offset) { idx, level in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(Color.labelSecondary)
                    if idx == project.compositionStack.count - 1 {
                        Text(level.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                    } else {
                        Button {
                            let pops = project.compositionStack.count - idx - 1
                            for _ in 0..<pops { project.exitCompound() }
                        } label: {
                            Text(level.name)
                                .font(.system(size: 11))
                                .foregroundColor(Color.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @EnvironmentObject private var project: ProjectState
    private var hasSelection: Bool {
        project.selectedVideoClipID != nil || project.selectedImageClipID != nil ||
        project.selectedAudioClipID != nil || project.selectedSubtitleClipID != nil ||
        project.selectedTextClipID != nil || project.selectedShapeClipID != nil ||
        project.selectedCompoundClipID != nil || !project.selectedClipIDs.isEmpty
    }
    /// 能删的范围比能分割的大：滤镜和调节片段可以删，但
    /// splitAtPlayhead / alignSelectedToPlayhead 都不处理这两条轨道，
    /// 跟着一起亮起来就会变成「按钮能点但没反应」
    private var canDelete: Bool {
        hasSelection || project.selectedFilterClipID != nil || project.selectedAdjustClipID != nil
    }
    private var canSplit: Bool { hasSelection }

    private var canMirrorRotate: Bool {
        project.selectedVideoClipID != nil ||
        project.selectedImageClipID != nil ||
        project.selectedShapeClipID != nil ||
        compoundHasVideo
    }
    private var canReverse: Bool {
        project.selectedVideoClipID != nil || compoundHasVideo
    }
    private var compoundHasVideo: Bool {
        guard let c = project.selectedCompoundClip else { return false }
        return c.videoTracks.contains(where: { !$0.clips.isEmpty })
    }

    private func toggleMirrorH() {
        project.pushUndo()
        if let id = project.selectedVideoClipID {
            project.updateVideoClip(id: id) { $0.mirrorH.toggle() }
            let v = project.selectedVideoClip?.mirrorH ?? false
            debugLog("[Mirror] video id=\(id) mirrorH=\(v)")
        } else if let id = project.selectedImageClipID {
            project.updateImageClip(id: id) { $0.mirrorH.toggle() }
            debugLog("[Mirror] image mirrorH toggled")
        } else if let id = project.selectedShapeClipID {
            project.updateShapeClip(id: id) { $0.mirrorH.toggle() }
            debugLog("[Mirror] shape mirrorH toggled")
        } else {
            debugLog("[Mirror] no clip selected, canMirrorRotate=\(canMirrorRotate)")
        }
        project.rebuildTimelinePreview()
    }
    private func toggleMirrorV() {
        project.pushUndo()
        if let id = project.selectedVideoClipID {
            project.updateVideoClip(id: id) { $0.mirrorV.toggle() }
        } else if let id = project.selectedImageClipID {
            project.updateImageClip(id: id) { $0.mirrorV.toggle() }
        } else if let id = project.selectedShapeClipID {
            project.updateShapeClip(id: id) { $0.mirrorV.toggle() }
        }
        project.rebuildTimelinePreview()
    }
    private func rotateClip() {
        project.pushUndo()
        if let id = project.selectedVideoClipID {
            project.updateVideoClip(id: id) { $0.rotation = ($0.rotation + 270) % 360 }
        } else if let id = project.selectedImageClipID {
            project.updateImageClip(id: id) {
                $0.rotation = ($0.rotation - 90 + 360).truncatingRemainder(dividingBy: 360)
            }
        } else if let id = project.selectedShapeClipID {
            project.updateShapeClip(id: id) { $0.rotation -= 90 }
        }
        project.rebuildTimelinePreview()
    }
    private func toggleReverse() {
        project.pushUndo()
        if let id = project.selectedVideoClipID {
            project.updateVideoClip(id: id) { $0.reversed.toggle() }
        }
        project.rebuildTimelinePreview()
    }

    var body: some View {
        HStack(spacing:0) {
            // 左侧：编辑工具
            HStack(spacing:2) {
                TBtn(icon:"undo", help:"撤销", enabled: project.undoCount > 0) { project.undo() }
                TBtn(icon:"redo",  help:"重做", enabled: project.redoCount > 0) { project.redo() }
                Divider().frame(height:16).padding(.horizontal,4)
                SplitBtn(style: .center, help: "在播放头分割片段", enabled: canSplit) { project.splitAtPlayhead() }
                SplitBtn(style: .keepLeft, help: "裁掉右边", enabled: canSplit) { project.splitKeepLeft() }
                SplitBtn(style: .keepRight, help: "裁掉左边", enabled: canSplit) { project.splitKeepRight() }
                TBtn(icon:"delete",            help:"删除选中片段", enabled: canDelete)   { project.deleteSelected() }
                TBtn(icon:"alignPlayhead",   help:"对齐到播放头", enabled: hasSelection) { project.alignSelectedToPlayhead() }
                TBtn(icon:"subtitle", help:"新建字幕") { project.insertSubtitleAtPlayhead() }
                TBtn(icon:"text", help:"新建标题文字") { project.addTextAtPlayhead() }

                Divider().frame(height:16).padding(.horizontal,4)

                TransformBtn(style: .mirror, help: "水平镜像", enabled: canMirrorRotate) { toggleMirrorH() }
                TransformBtn(style: .mirrorV, help: "垂直镜像", enabled: canMirrorRotate) { toggleMirrorV() }
                TransformBtn(style: .rotate, help: "旋转90°", enabled: canMirrorRotate) { rotateClip() }
                TransformBtn(style: .reverse, help: "倒放", enabled: canReverse) { toggleReverse() }

                Divider().frame(height:16).padding(.horizontal,4)

                MarkerBtn()

                Divider().frame(height:16).padding(.horizontal,4)

                // 翻译 & 样式工具
                TranslateToolGroup()

                Divider().frame(height:16).padding(.horizontal,4)

                // 语音识别、视频分析、去背景、分离音轨、转语音、清晰度提升
                // 都收在这一个下拉里
                AIToolsMenuBtn()
                    .environmentObject(project)
            }.padding(.leading,8)

            Spacer()

            // 轨道显示开关
            TrackVisibilityMenu()
                .environmentObject(project)
                .padding(.trailing, 4)

            // 吸附开关
            Button { project.snapEnabled.toggle() } label: {
                Image(nsImage: TimelineSVGIcon.load("snap"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(project.snapEnabled ? Color.accent : Color.labelSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("自动吸附")
            .padding(.trailing, 8)

            // 右侧：缩放
            HStack(spacing:6) {
                TBtn(icon:"zoomFit", help:"缩放至适合") { project.zoomToFit() }
                TBtn(icon:"zoomOut", help:"缩小") { project.zoomTo(project.pixelsPerSecond / 1.5) }
                LogSlider(value: Binding(
                    get: { project.pixelsPerSecond },
                    set: { project.zoomTo($0) }
                ), range: min(project.minPixelsPerSecond, 3000)...3000).frame(width:100).help("时间轴缩放")
                TBtn(icon:"zoomIn", help:"放大")  { project.zoomTo(project.pixelsPerSecond * 1.5) }
            }.padding(.trailing,12)
        }
        .frame(height:36)
        .background(Color.clear)   // 底色交给外层的系统材质
    }
}

// MARK: - 翻译进度气泡

private struct TranslationProgressBubble: View {
    @EnvironmentObject private var project: ProjectState

    private var isDone: Bool { project.translationDone >= project.translationTotal && project.translationTotal > 0 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isDone ? Color(hex: "#5DB85D").opacity(0.2) : Color.accent.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: isDone ? "checkmark" : "translate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isDone ? Color(hex: "#5DB85D") : Color.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(isDone ? "翻译完成" : "正在翻译…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.labelPrimary)

                if !isDone {
                    HStack(spacing: 6) {
                        ProgressView(value: project.translationProgress)
                            .progressViewStyle(.linear)
                            .tint(Color.accent)
                            .frame(width: 80)
                        Text("\(project.translationDone)/\(project.translationTotal)")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(Color.labelSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.16))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        )
    }
}

// MARK: - 翻译 & 样式工具组

private struct TranslateToolGroup: View {
    @EnvironmentObject private var project: ProjectState
    @State private var langHov = false

    /// 语音识别只能对视频/音频做。选中图片、图形、字幕、文字时按钮该置灰 ——
    /// 此前只判断 `!isTranscribing`，点下去要走到 `startTranscribe` 才弹
    /// 「请先选择一个视频或音频片段」，等于让人白点一次。
    /// 无选中时实现会退回「时间轴第一个视频片段」，所以那种情况仍可用
    private var canTranscribe: Bool {
        if project.isTranscribing { return false }
        if project.selectedVideoClipID != nil || project.selectedAudioClipID != nil { return true }
        if let c = project.selectedCompoundClip,
           c.videoTracks.contains(where: { !$0.clips.isEmpty }) { return true }
        // 选中的是图片/图形/字幕/文字 —— 这些没有音轨可识别
        if project.selectedImageClipID != nil || project.selectedShapeClipID != nil
            || project.selectedSubtitleClipID != nil || project.selectedTextClipID != nil {
            return false
        }
        // 什么都没选：退回时间轴上第一个视频片段
        return project.videoTracks.contains { !$0.clips.isEmpty }
    }

    /// 选中字幕所在轨道的 index（没选中则 nil）
    private var selectedTrackIndex: Int? {
        guard let sid = project.selectedSubtitleClipID else { return nil }
        return project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == sid } }
    }

    /// "翻译整条轨道"按钮是否可用
    private var translateAllEnabled: Bool {
        // 选中的是标题文字：翻译整条轨道对它没有意义（它不在字幕轨道上）
        if project.selectedTextClipID != nil { return false }
        let count = project.subtitleTracks.count
        if count == 0 { return false }
        if count == 1 {
            // 只有一条轨道：只要有字幕片段就可以
            return !project.subtitleTracks[0].clips.isEmpty
        }
        // 多条轨道：必须选中某个字幕片段
        return selectedTrackIndex != nil
    }

    var body: some View {
        HStack(spacing: 2) {
            // 目标语言下拉。悬停反馈跟 AI 工具那个下拉保持一致
            let langOn = !project.isEffectClipSelected
            Button { showLangMenu() } label: {
                HStack(spacing: 3) {
                    Text(shortLang(project.translationTargetLang))
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundColor(langOn ? (langHov ? Color.labelPrimary : Color.labelSecondary)
                                        : Color.labelSecondary.opacity(0.35))
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background((langOn && langHov) ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!langOn)
            .onHover { langHov = $0 && langOn }

            TBtn(icon: "translate", help: "翻译选中字幕",
                 enabled: project.selectedSubtitleClipID != nil) { translateCurrent() }
            TBtn(icon: "translateTrack", help: "翻译整条轨道",
                 enabled: translateAllEnabled) { translateAll() }
        }
        // 片段右键菜单里的那两项走这两个计数器转发过来
        .onChange(of: project.translateSelectedTick) { _, _ in translateCurrent() }
        .onChange(of: project.translateTrackTick) { _, _ in translateAll() }
    }

    private func shortLang(_ lang: String) -> String {
        switch lang {
        case "中文（简体）": return "SC"
        case "中文（繁体）": return "TC"
        case "English":   return "EN"
        case "日本語":     return "JP"
        case "한국어":     return "KR"
        case "Français":  return "FR"
        case "Deutsch":   return "DE"
        case "Español":   return "ES"
        case "Русский":   return "RU"
        case "العربية":   return "AR"
        case "Português": return "PT"
        case "Italiano":  return "IT"
        default:          return String(lang.prefix(2))
        }
    }

    private func showLangMenu() {
        let menu = NSMenu()
        for lang in ProjectState.supportedLanguages {
            let item = NSMenuItem(title: lang, action: nil, keyEquivalent: "")
            item.target = LangMenuHandler.shared
            item.action = #selector(LangMenuHandler.pick(_:))
            item.tag = ProjectState.supportedLanguages.firstIndex(of: lang) ?? 0
            if lang == project.translationTargetLang { item.state = .on }
            menu.addItem(item)
        }
        LangMenuHandler.shared.project = project
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    // MARK: - 翻译逻辑

    /// 这批字幕是不是**基本上**已经是目标语言了 —— 是就别翻。
    ///
    /// 按多数判而不是"一条都不能有"：语言识别对短句、人名、数字、中英混排都不可靠，
    /// 一整轨中文里混一条 "Jony Ive" 就会被判成需要翻译，结果拉出一条几乎全是原文的新轨
    /// （非目标语言的条目在 Translator.translate 那层还会被逐条挡回原文）。
    /// 需要翻的不到两成就当作不用翻
    private func mostlyAlreadyTarget(_ texts: [String], lang: String) -> Bool {
        let meaningful = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !meaningful.isEmpty else { return true }
        let need = meaningful.filter { text in
            // 简繁差异也算「需要处理」：isAlreadyTarget 对 4 字以下一律返回"已是目标"，
            // 只看它的话，一整轨简体短句想转繁体会被当成"无需翻译"直接拒掉
            if let converted = Translator.localChineseConvert(text, to: lang) {
                return converted != text
            }
            return !Translator.isAlreadyTarget(text, lang: lang)
        }.count
        return Double(need) / Double(meaningful.count) <= 0.2
    }

    /// 确定要翻译的源轨道 index
    private func sourceTrackIndex() -> Int? {
        let count = project.subtitleTracks.count
        if count == 0 { return nil }
        if count == 1 { return 0 }
        // 多轨道：用选中字幕所在的轨道
        return selectedTrackIndex
    }

    /// 在源轨道下方新建翻译轨道，返回新轨道 index
    private func createTranslationTrack(before srcIdx: Int) -> Int {
        let lang = shortLang(project.translationTargetLang)
        var newTrack = Track<SubtitleClip>(label: "字幕(\(lang))")
        newTrack.subtitleStyle = SubtitleStyle()
        let srcTrackID = project.subtitleTracks[srcIdx].id
        project.subtitleTracks.insert(newTrack, at: srcIdx)
        let newRef = ProjectState.OverlayTrackRef.subtitle(newTrack.id)
        if let oi = project.overlayTrackOrder.firstIndex(where: { $0 == .subtitle(srcTrackID) }) {
            project.overlayTrackOrder.insert(newRef, at: oi)
        } else {
            project.syncOverlayOrder()
        }
        return srcIdx
    }

    /// 一条待翻译的字幕：文本 + 它该回填到哪条翻译轨的哪个占位片段。
    /// 跨轨多选时每条源轨各有自己的翻译轨，所以目标轨要跟着每一条走
    private struct TranslateItem {
        let text: String
        let start: Double
        let end: Double
        let destTrackID: UUID
        let placeholderID: UUID
    }

    private func translateCurrent() {
        var allSelectedIDs = project.selectedClipIDs
        if let pid = project.selectedSubtitleClipID { allSelectedIDs.insert(pid) }

        // 按**源轨道**分组收集选中的字幕。
        // 原来这里先用 sourceTrackIndex() 锁死一条轨、再从那条轨里 filter，
        // 跨轨多选时其余轨道的选中项被静默丢掉，表现为「只有第一条被翻译」
        var groups: [(srcTrackID: UUID, clips: [SubtitleClip])] = []
        for track in project.subtitleTracks {
            let picked = track.clips.filter { allSelectedIDs.contains($0.id) }
                .sorted { $0.startTime < $1.startTime }
            if !picked.isEmpty { groups.append((track.id, picked)) }
        }
        guard !groups.isEmpty else { return }

        let lang = project.translationTargetLang

        // 原文已经就是目标语言 → 提前退出：不建翻译轨、不亮进度卡片、不占撤销栈。
        // （只在 Translator.translate 里挡住请求是不够的，那时轨道和占位都建好了，
        // 表现就是"点了翻译，进度条闪一下，多出一条内容一模一样的轨"）
        guard !mostlyAlreadyTarget(groups.flatMap { $0.clips.map(\.text) }, lang: lang) else {
            project.showSuccessToast(icon: "checkmark", title: "翻译",
                                     subtitle: "已经是目标语言，无需翻译")
            return
        }

        project.pushUndo()

        // 每条源轨各建一条翻译轨。插入会让后面的 index 整体后移，
        // 所以每次都按 ID 重新定位源轨，不能缓存 index
        var items: [TranslateItem] = []
        var destTrackIDs: [UUID] = []
        for g in groups {
            guard let srcIdx = project.subtitleTracks.firstIndex(where: { $0.id == g.srcTrackID }) else { continue }
            let destIdx = createTranslationTrack(before: srcIdx)
            let destTrackID = project.subtitleTracks[destIdx].id
            destTrackIDs.append(destTrackID)

            var placeholders: [SubtitleClip] = []
            for c in g.clips {
                let ph = SubtitleClip(text: "", startTime: c.startTime, endTime: c.endTime)
                placeholders.append(ph)
                project.placeholderClipIDs.insert(ph.id)
                items.append(TranslateItem(text: c.text, start: c.startTime, end: c.endTime,
                                           destTrackID: destTrackID, placeholderID: ph.id))
            }
            project.subtitleTracks[destIdx].clips = placeholders
            project.translatingTrackIDs.insert(destTrackID)
        }
        guard !items.isEmpty else { return }

        project.translationTotal = items.count
        project.translationDone = 0
        project.translationProgress = 0

        TranslateDiagnostics.reset()   // 别把上一轮的失败原因带到这次提示里
        project.translationTask = Task {
            let total = items.count
            let texts = items.map(\.text)

            // 批量：15 条合并成一次请求，最多 4 路并发。
            // 原来是**每条一个请求、6 路并发**，选中几百条字幕就是几百个请求打过去，
            // Google 的免费接口直接限流，而所有引擎失败时都静默返回原文——
            // 于是前一部分翻好了、后面全是原文，界面还显示"翻译完成"。
            // 合并之后请求数掉一个数量级，Translator.translate 里也加了退避重试
            let translated = await Translator.translateConcurrent(
                texts, to: lang, batchSize: 15, concurrency: Translator.recommendedConcurrency,
                onProgress: { done in
                    await MainActor.run {
                        guard project.translationTask != nil else { return }
                        project.translationDone = min(done, total)
                        project.translationProgress = Double(min(done, total)) / Double(max(total, 1))
                    }
                },
                onBatch: { offset, batch in
                    // 一批翻完就回填一批，不用等全部结束。
                    // 一批里的条目可能分属不同的翻译轨（跨轨多选），所以逐条按自己的
                    // destTrackID 定位，不能在循环外一次性取轨道
                    await MainActor.run {
                        guard project.translationTask != nil else { return }
                        for (j, t) in batch.enumerated() {
                            let i = offset + j
                            guard i < items.count else { break }
                            let item = items[i]
                            if let ti = project.subtitleTracks.firstIndex(where: { $0.id == item.destTrackID }),
                               let ci = project.subtitleTracks[ti].clips.firstIndex(where: { $0.id == item.placeholderID }) {
                                project.subtitleTracks[ti].clips[ci] = SubtitleClip(
                                    text: t, startTime: item.start, endTime: item.end)
                            }
                            project.placeholderClipIDs.remove(item.placeholderID)
                        }
                    }
                })

            guard !Task.isCancelled else { return }
            // 结果跟原文一字不差的，多半是重试之后仍然失败（限流/网络）。
            // 以前这种情况完全无感，只能靠肉眼一条条发现
            let failed = zip(texts, translated).filter { $0 == $1 && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            await MainActor.run {
                for id in destTrackIDs { project.translatingTrackIDs.remove(id) }
                // 一条都没翻成 → 把刚建的翻译轨收掉，撤销栈里那步也弹掉。
                // 留一条内容全是原文的空壳轨没有意义，还得用户手动删
                if failed == total {
                    for id in destTrackIDs {
                        project.subtitleTracks.removeAll { $0.id == id }
                        project.overlayTrackOrder.removeAll { $0 == .subtitle(id) }
                    }
                    project.popUndo()
                }
                project.translationTotal = 0
                project.translationDone = 0
                project.translationProgress = 0
                project.translationTask = nil
                if failed > 0 {
                    // 完成情况放标题、原因放副标题 —— 都塞进 subtitle 会被气泡截断，
                    // 恰好把最有用的失败原因截没了。
                    // 全军覆没时翻译轨已经被收掉了，就别再说"完成 0/N"
                    project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                             title: failed == total
                                                 ? "翻译失败"
                                                 : "翻译完成 \(total - failed)/\(total) 条，\(failed) 条未成功",
                                             subtitle: TranslateDiagnostics.lastFailureHint ?? "可能被限流，稍后重试这几条",
                                             autoCountdown: false)
                } else {
                    project.showSuccessToast(icon: "checkmark", title: "翻译", subtitle: "翻译完成")
                }
            }
        }
    }

    private func translateAll() {
        guard let srcIdx = sourceTrackIndex() else { return }
        let lang = project.translationTargetLang
        let originals = project.subtitleTracks[srcIdx].clips
        guard !originals.isEmpty else { return }

        // 同 translateCurrent：整轨已经是目标语言就别建轨、别亮进度
        guard !mostlyAlreadyTarget(originals.map(\.text), lang: lang) else {
            project.showSuccessToast(icon: "checkmark", title: "翻译",
                                     subtitle: "已经是目标语言，无需翻译")
            return
        }

        project.pushUndo()
        let destIdx = createTranslationTrack(before: srcIdx)
        let destTrackID = project.subtitleTracks[destIdx].id

        var placeholders: [SubtitleClip] = []
        for c in originals {
            let ph = SubtitleClip(text: "", startTime: c.startTime, endTime: c.endTime)
            placeholders.append(ph)
            project.placeholderClipIDs.insert(ph.id)
        }
        project.subtitleTracks[destIdx].clips = placeholders
        project.translatingTrackIDs.insert(destTrackID)
        project.translationTotal = originals.count
        project.translationDone = 0
        project.translationProgress = 0

        TranslateDiagnostics.reset()   // 别把上一轮的失败原因带到这次提示里
        project.translationTask = Task {
            let maxConcurrent = Translator.recommendedConcurrency
            let total = originals.count
            var done = 0
            var failed = 0
            await withTaskGroup(of: (Int, String).self) { group in
                var nextIdx = 0
                for _ in 0..<min(maxConcurrent, total) {
                    let idx = nextIdx; let text = originals[idx].text
                    group.addTask { (idx, await Translator.translateSmart(text, to: lang)) }
                    nextIdx += 1
                }
                for await (i, translated) in group {
                    guard !Task.isCancelled else { return }
                    done += 1
                    // 结果跟原文一字不差 = 这条没翻成（各引擎失败时都返回原文）
                    if translated == originals[i].text,
                       !originals[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
                        failed += 1
                    }
                    await MainActor.run {
                        guard project.translationTask != nil else { return }
                        guard let ti = project.subtitleTracks.firstIndex(where: { $0.id == destTrackID }) else { return }
                        let phID = placeholders[i].id
                        if let ci = project.subtitleTracks[ti].clips.firstIndex(where: { $0.id == phID }) {
                            project.subtitleTracks[ti].clips[ci] = SubtitleClip(
                                text: translated, startTime: originals[i].startTime, endTime: originals[i].endTime)
                        }
                        project.placeholderClipIDs.remove(phID)
                        project.translationDone = done
                        project.translationProgress = Double(done) / Double(total)
                    }
                    if nextIdx < total {
                        let idx = nextIdx; let text = originals[idx].text
                        group.addTask { (idx, await Translator.translateSmart(text, to: lang)) }
                        nextIdx += 1
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                project.translatingTrackIDs.remove(destTrackID)
                // 同上：整轨一条都没翻成就别留这条轨
                if failed == total {
                    project.subtitleTracks.removeAll { $0.id == destTrackID }
                    project.overlayTrackOrder.removeAll { $0 == .subtitle(destTrackID) }
                    project.popUndo()
                }
                project.translationTotal = 0
                project.translationDone = 0
                project.translationProgress = 0
                project.translationTask = nil
                if failed > 0 {
                    // 完成情况放标题、原因放副标题 —— 都塞进 subtitle 会被气泡截断，
                    // 恰好把最有用的失败原因截没了。
                    // 全军覆没时翻译轨已经被收掉了，就别再说"完成 0/N"
                    project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                             title: failed == total
                                                 ? "翻译失败"
                                                 : "翻译完成 \(total - failed)/\(total) 条，\(failed) 条未成功",
                                             subtitle: TranslateDiagnostics.lastFailureHint ?? "可能被限流，稍后重试这几条",
                                             autoCountdown: false)
                } else {
                    project.showSuccessToast(icon: "checkmark", title: "翻译", subtitle: "翻译完成")
                }
            }
        }
    }

}

private struct AnalyzeMenuBtn: View {
    @EnvironmentObject private var project: ProjectState
    @State private var hov = false

    private var busy: Bool { project.isDetectingScenes || project.isLLMAnalyzing }
    private var enabled: Bool { !busy && project.selectedVideoClipID != nil }

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: 2) {
                Image(nsImage: TimelineSVGIcon.load("smartAnalysis"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundColor(enabled ? (hov ? Color.labelPrimary : Color.labelSecondary)
                                     : Color.labelSecondary.opacity(0.35))
            .frame(height: 28)
            .padding(.horizontal, 4)
            .background((enabled && hov) ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hov = $0 }
        .help(busy ? "正在分析…" : "视频智能剪辑")
    }

    private func showMenu() {
        let menu = NSMenu()
        let auto = NSMenuItem(title: "智能分割", action: #selector(AnalyzeMenuHandler.autoDetect(_:)), keyEquivalent: "")
        auto.target = AnalyzeMenuHandler.shared
        auto.isEnabled = SceneDetector.isInstalled
        menu.addItem(auto)

        let llm = NSMenuItem(title: "AI 剪辑", action: #selector(AnalyzeMenuHandler.llmAnalyze(_:)), keyEquivalent: "")
        llm.target = AnalyzeMenuHandler.shared
        llm.isEnabled = !AppSettings.shared.llmAPIKey.isEmpty
        menu.addItem(llm)

        AnalyzeMenuHandler.shared.project = project
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

private final class AnalyzeMenuHandler: NSObject {
    static let shared = AnalyzeMenuHandler()
    weak var project: ProjectState?

    @objc func autoDetect(_ sender: NSMenuItem) {
        project?.sceneDetectSelectedClip()
    }

    @objc func llmAnalyze(_ sender: NSMenuItem) {
        project?.llmAnalyzeSelectedClip()
    }
}

private struct SplitBtn: View {
    enum Style: String { case center = "split", keepLeft = "trimRight", keepRight = "trimLeft" }
    let style: Style
    var help: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    @State private var hov = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: TimelineSVGIcon.load(style.rawValue))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(enabled ? (hov ? Color.labelPrimary : Color.labelSecondary)
                                         : Color.labelSecondary.opacity(0.35))
                .frame(width: 28, height: 28)
                .background((enabled && hov) ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hov = $0 }
        .help(help ?? "")
    }
}

private struct TBtn: View {
    let icon: String
    var help: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Image(nsImage: TimelineSVGIcon.load(icon))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(enabled ? (hov ? Color.labelPrimary : Color.labelSecondary)
                                         : Color.labelSecondary.opacity(0.35))
                .frame(width: 28, height: 28)
                .background((enabled && hov) ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hov = $0 }
        .help(help ?? "")
    }
}

private struct TransformBtn: View {
    enum Style: String { case reverse, mirror = "mirrorH", mirrorV, rotate }
    let style: Style
    var help: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Image(nsImage: TimelineSVGIcon.load(style.rawValue))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(enabled ? (hov ? Color.labelPrimary : Color.labelSecondary) : Color.labelSecondary.opacity(0.35))
                .frame(width: 28, height: 28)
                .background((enabled && hov) ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hov = $0 }
        .help(help ?? "")
    }
}

// SVG icons are in TimelineSVGIcons.swift

// MARK: - Marker Button

private struct MarkerBtn: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    @State private var hov = false
    private var hasMarkerSelected: Bool { project.selectedMarkerID != nil }
    private var canAdd: Bool {
        let t = clock.currentTime
        func inRange(_ start: Double, _ dur: Double) -> Bool { t >= start && t <= start + dur }
        if let c = project.selectedVideoClip { return inRange(c.startTime, c.duration) }
        if let id = project.selectedAudioClipID, let c = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if let id = project.selectedImageClipID, let c = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if let id = project.selectedSubtitleClipID, let c = project.subtitleTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if let id = project.selectedTextClipID, let c = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if let id = project.selectedShapeClipID, let c = project.shapeTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if let id = project.selectedCompoundClipID, let c = project.compoundTracks.flatMap(\.clips).first(where: { $0.id == id }) { return inRange(c.startTime, c.duration) }
        if !project.selectedClipIDs.isEmpty { return true }
        return false
    }
    private var isDisabled: Bool { !hasMarkerSelected && !canAdd }
    var body: some View {
        Button {
            if let mid = project.selectedMarkerID {
                project.removeMarker(id: mid)
            } else {
                project.addMarkerToSelectedClip()
            }
        } label: {
            Image(nsImage: TimelineSVGIcon.load(hasMarkerSelected ? "markerDel" : "markerAdd"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(isDisabled ? Color.labelSecondary.opacity(0.3) : (hasMarkerSelected ? Color(hex: "#E8A54B") : (hov ? Color.labelPrimary : Color.labelSecondary)))
                .frame(width: 28, height: 28)
                .background(hov && !isDisabled ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hov = $0 }
        .help(hasMarkerSelected ? "删除标记" : "添加标记")
    }
}

// MARK: - Marker Edit Popover

private struct MarkerEditPopover: View {
    let markerID: UUID
    @EnvironmentObject private var project: ProjectState
    @State private var title: String = ""
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss

    private var marker: Marker? { project.findMarker(id: markerID)?.marker }
    private var markerAbsTime: Double? { project.findMarker(id: markerID)?.absoluteTime }

    var body: some View {
        VStack(spacing: 10) {
            TextField("标记名称", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
                .onSubmit { save() }

            if let absT = markerAbsTime {
                let t = absT
                let h = Int(t) / 3600, min = (Int(t) % 3600) / 60, s = Int(t) % 60, f = Int((t - floor(t)) * 30)
                TextField("", text: .constant(String(format: "%02d:%02d:%02d:%02d", h, min, s, f)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                    .disabled(true)
            }

            HStack(spacing: 10) {
                Spacer()
                ForEach(Marker.MarkerColor.allCases, id: \.self) { mc in
                    Canvas { ctx, size in
                        let w = size.width, h = size.height
                        var p = Path()
                        let r: CGFloat = 2
                        p.move(to: CGPoint(x: r, y: 0))
                        p.addLine(to: CGPoint(x: w - r, y: 0))
                        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
                        p.addLine(to: CGPoint(x: w, y: h * 0.6))
                        p.addLine(to: CGPoint(x: w / 2, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h * 0.6))
                        p.addLine(to: CGPoint(x: 0, y: r))
                        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
                        p.closeSubpath()
                        ctx.fill(p, with: .color(mc.swiftUIColor))
                        if marker?.color == mc {
                            ctx.stroke(p, with: .color(.white), lineWidth: 1)
                        }
                    }
                    .frame(width: 12, height: 16)
                    .onTapGesture {
                        project.updateMarker(id: markerID) { $0.color = mc }
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    project.removeMarker(id: markerID)
                    dismiss()
                } label: {
                    Text("删除")
                        .font(.system(size: 13))
                        .foregroundColor(Color.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    save()
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            if !appeared, let m = marker {
                title = m.title
                appeared = true
            }
        }
    }

    private func save() {
        project.updateMarker(id: markerID) { $0.title = title }
    }
}

// MARK: - Debug

private func debugLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let path = "/tmp/blackcat_debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
    NSLog(msg)
}

// MARK: - Helpers

private func fmtT(_ t:Double)->String {
    let m=Int(t)/60%60; let s=Int(t)%60; let ms=Int((t-Double(Int(t)))*1000)
    return String(format:"%02d:%02d.%03d",m,s,ms)
}

final class LangMenuHandler: NSObject {
    static let shared = LangMenuHandler()
    weak var project: ProjectState?
    @objc func pick(_ sender: NSMenuItem) {
        let langs = ProjectState.supportedLanguages
        guard langs.indices.contains(sender.tag) else { return }
        project?.translationTargetLang = langs[sender.tag]
    }
}

// MARK: - NSScrollView finder (always-visible scrollbar + programmatic scroll)

private struct TimelineScrollViewFinder: NSViewRepresentable {
    let project: ProjectState
    let onScroll: (Double, Double, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let v = _FinderNSView()
        v.coordinator = context.coordinator
        v.project = project
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    final class Coordinator: NSObject {
        var onScroll: (Double, Double, CGFloat) -> Void
        var observer: Any?
        init(onScroll: @escaping (Double, Double, CGFloat) -> Void) { self.onScroll = onScroll }
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

        func observe(_ sv: NSScrollView) {
            sv.contentView.postsBoundsChangedNotifications = true
            // queue 必须传 nil（在发通知的线程上同步回调），不能用 .main。
            //
            // 用 .main 是异步派发，缩放时会错开一帧：zoomTo 先同步设好滚动位置
            // （通知只是排进队列），紧接着设 pixelsPerSecond 触发 SwiftUI 布局，
            // 这一帧拿到的是**新 pps + 旧 scrollOffsetX**；等队列里的通知被处理，
            // scrollOffsetX 才更新、再布局一次。凡是拿这两个量做减法的地方
            // （片段标题的吸附位置 clip.startTime*pps - scrollOffsetX、缩略图的
            // 可视窗口）中间那帧都会算歪，表现就是缩放时文字左右抽动。
            //
            // 同步回调就落在同一个更新周期里，两个量一起变，不会错位。
            // 滚动都是主线程操作，这里理应同步；万一有非主线程来的通知，
            // 兜底切回主线程，避免在别的线程上改 @State。
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sv.contentView, queue: nil
            ) { [weak self, weak sv] _ in
                if Thread.isMainThread {
                    self?.update(sv)
                } else {
                    DispatchQueue.main.async { self?.update(sv) }
                }
            }
            update(sv)
        }

        func update(_ sv: NSScrollView?) {
            guard let sv = sv, let doc = sv.documentView else { return }
            let cW = doc.frame.width, vW = sv.contentView.bounds.width
            guard cW > 0 else { return }
            let vpFrac = min(vW / cW, 1.0)
            let maxS = cW - vW
            let frac = maxS > 0 ? sv.contentView.bounds.origin.x / maxS : 0
            let offX = sv.contentView.bounds.origin.x
            onScroll(frac, vpFrac, offX)
        }
    }

    private final class _FinderNSView: NSView {
        weak var project: ProjectState?
        weak var coordinator: Coordinator?
        private var didFind = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFind, window != nil, let sv = enclosingScrollView else { return }
            didFind = true
            sv.hasHorizontalScroller = false
            project?.timelineHScrollView = sv
            coordinator?.observe(sv)
        }
    }
}

// MARK: - Custom horizontal scrollbar

private struct TimelineScrollBar: View {
    let fraction: Double
    let viewportFraction: Double
    let isVisible: Bool
    /// 正在横向滚动。这时只是把位置报给用户看，不指望他去点，所以用细版
    let isScrolling: Bool
    let onDrag: (Double) -> Void

    @State private var isDragging = false
    @State private var dragStartFraction: Double = 0
    /// 指针是否落在滚动条自己身上。
    ///
    /// 必须有这个，否则会来回闪：父视图靠 onContinuousHover 判断"指针在不在轨道区
    /// 底部"来决定 isVisible，而滚动条一旦显示就开始接事件（allowsHitTesting），
    /// 把 hover 事件挡住了——父视图收到 .ended 以为指针离开了，于是隐藏；隐藏后
    /// 不再拦截，事件又落回父视图，再显示。指针明明没动，滚动条却在自己开关。
    /// 让它自己也报一份 hover，跟 isVisible 取或，指针在它身上时就由它保证不消失。
    @State private var selfHovered = false

    /// 只因为「正在滚动」而露面时的高度：此刻用户在滑轨道、不是在瞄滑块，
    /// 细一点不挡视线，也跟"现在还不能拖"这个状态对应上
    private let barHThin: CGFloat = 6
    /// 指针进到底部区域时的高度。滚动条本来就只在这时才淡入，既然露面了就说明
    /// 用户要用它，直接给好点的尺寸，不再要求"精确悬停到滑块上"才加粗。
    ///
    /// 试过做二级 hover（指到滑块上再从 6pt 变 10pt），结果是抖：用
    /// .frame(height:) 做加粗改的是**布局**属性，动画期间 SwiftUI 会在中间尺寸上
    /// 反复 hit test，onHover 跟着 true/false 来回翻、又驱动动画，形成自激循环，
    /// 指针不动也会一粗一细。反馈范围和可点范围本来就该一致，这里索性合成一个。
    private let barH: CGFloat = 10
    /// 滑块的**命中**高度。视觉上仍是 barH(6pt) 的细条，但只有 6pt 可点实在太难瞄——
    /// 鼠标差几个像素就落空，事件穿到下面的轨道区变成框选（用户原话："放上去了
    /// 拖动结果是框选"）。这个值跟父视图 onContinuousHover 里
    /// `loc.y > effectiveH - 24` 的 24pt 对齐：看得见滚动条的地方就一定拖得动。
    private let hitH: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width - 16
            let knobW = max(trackW * viewportFraction, 30)
            let maxOffset = max(trackW - knobW, 1)
            let knobX = 8 + fraction * maxOffset
            // 能拖 = 指针在底部区域 / 在滚动条上 / 正在拖。单纯因为滚动而露面时
            // 不算可交互，只报位置
            let interactive = isVisible || isDragging || selfHovered
            let show = interactive || isScrolling
            let knobH = interactive ? barH : barHThin

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: trackW, height: knobH)
                    .animation(.easeOut(duration: 0.12), value: knobH)
                    // 轨道背景也接事件：点空白处直接把滑块挪过去（标准滚动条行为），
                    // 不接的话点在滑块之外就穿透下去变成框选，跟点不中滑块是同一个毛病
                    .frame(width: trackW, height: hitH)
                    .contentShape(Rectangle())
                    .offset(x: 8)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                // 让滑块中心落到指针处
                                onDrag(((v.location.x - knobW / 2) / maxOffset).clamped(to: 0...1))
                            }
                    )

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isDragging ? 0.55 : 0.35))
                    .frame(width: knobW, height: knobH)
                    // 外层撑到 hitH 再配 contentShape：视觉是 10pt（滚动时 6pt）的条
                    // 在 22pt 里垂直居中，可点范围始终是这 22pt
                    .animation(.easeOut(duration: 0.12), value: knobH)
                    .frame(width: knobW, height: hitH)
                    .contentShape(Rectangle())
                    .offset(x: knobX)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if !isDragging {
                                    isDragging = true
                                    dragStartFraction = fraction
                                }
                                let delta = v.translation.width / maxOffset
                                onDrag((dragStartFraction + delta).clamped(to: 0...1))
                            }
                            .onEnded { _ in isDragging = false }
                    )
            }
            .frame(height: hitH)
            // 挂在整个条上而不是只挂滑块：指针在轨道背景上也算"在滚动条上"，
            // 不然从滑块滑到旁边空白就会触发隐藏。这里只驱动 opacity /
            // allowsHitTesting，不改任何布局尺寸——上一版把 onHover 接到
            // .frame(height:) 上导致过自激抖动，别再犯
            .onHover { selfHovered = $0 }
            .opacity(show ? 1 : 0)
            // 只有「可交互」时才拦事件，不能用 show：
            //  · opacity 0 的视图照样会接事件，命中区域又有 22pt，隐藏时不关掉的话
            //    底部那条会把框选的拖拽吃掉
            //  · 单纯因为滚动而露面的那 1.2s 同理——那时用户在滑轨道，不该顺手
            //    把接下来的框选也吞了。指针真进到底部区域时 isVisible 会点亮
            //    interactive，照样拖得动
            .allowsHitTesting(interactive)
            .animation(.easeInOut(duration: show ? 0.15 : 0.4), value: show)
        }
        .frame(height: hitH)
    }
}

// MARK: - AI 工具（工具栏合集）

/// 把散在各处的 AI 功能收进一个下拉。
///
/// 这些功能原本只在片段右键菜单里，工具栏上只有语音识别和视频分析两个孤零零的按钮。
/// 收成一个入口后，用户不用记"哪个功能要右键哪种片段"，
/// 每一项按当前选中的片段类型自动置灰。片段右键菜单保留原样，多个入口并存
private struct AIToolsMenuBtn: View {
    @EnvironmentObject private var project: ProjectState
    @State private var hov = false

    var body: some View {
        // 滤镜/调节片段选中时整个下拉都置灰：里面每一项要的都是
        // 视频、音频或字幕，对这两类片段没有一项能用
        let on = !project.isEffectClipSelected
        Button { showMenu() } label: {
            HStack(spacing: 2) {
                Image(nsImage: TimelineSVGIcon.load("aiTools"))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundColor(on ? (hov ? Color.labelPrimary : Color.labelSecondary)
                                : Color.labelSecondary.opacity(0.35))
            .frame(height: 28)
            .padding(.horizontal, 5)
            .background((on && hov) ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(5)
        }
        .disabled(!on)
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help("AI 工具")
    }

    // MARK: 各项的可用条件

    private var canTranscribe: Bool {
        if project.isTranscribing { return false }
        if project.selectedVideoClipID != nil || project.selectedAudioClipID != nil { return true }
        if let c = project.selectedCompoundClip,
           c.videoTracks.contains(where: { !$0.clips.isEmpty }) { return true }
        if project.selectedImageClipID != nil || project.selectedShapeClipID != nil
            || project.selectedSubtitleClipID != nil || project.selectedTextClipID != nil {
            return false
        }
        return project.videoTracks.contains { !$0.clips.isEmpty }
    }

    private var canAnalyze: Bool {
        !(project.isDetectingScenes || project.isLLMAnalyzing) && project.selectedVideoClipID != nil
    }

    private func showMenu() {
        let p = project
        let menu = NSMenu()
        menu.minimumWidth = 200

        func add(_ title: String, enabled: Bool, _ act: @escaping () -> Void) {
            menu.addItem(MenuRowView.item(title: title, width: 200,
                                          enabled: enabled, action: act))
        }

        add("语音识别字幕", enabled: canTranscribe) { p.showTranscribeOptions = true }

        // 视频分析：二级菜单
        let sub = NSMenu()
        sub.minimumWidth = 160
        sub.addItem(MenuRowView.item(title: "智能分割", width: 160,
                                     enabled: canAnalyze && SceneDetector.isInstalled) {
            p.sceneDetectSelectedClip()
        })
        sub.addItem(MenuRowView.item(title: "AI 剪辑", width: 160,
                                     enabled: canAnalyze && !AppSettings.shared.llmAPIKey.isEmpty) {
            p.llmAnalyzeSelectedClip()
        })
        menu.addItem(MenuRowView.item(title: "视频智能剪辑", width: 200,
                                      enabled: canAnalyze, submenu: sub))

        menu.addItem(.separator())
        add("去除背景", enabled: p.canRemoveImageBackground) { p.removeBackgroundForSelection(mode: .subject) }
        add("分离音轨", enabled: p.canRemoveBackgroundMusic) { p.removeBackgroundMusicForSelection() }
        add("转换成语音", enabled: p.canConvertSubtitleToSpeech) { p.convertSelectedSubtitlesToSpeech() }

        // 清晰度提升：二级菜单
        let csub = NSMenu()
        csub.minimumWidth = 160
        // 系统超分只有 4 倍这一档，选了它就不摆一个点下去会报错的 2 倍
        if AppSettings.shared.clarityEngine.supportsX2 {
            csub.addItem(MenuRowView.item(title: "提升 2 倍", width: 160,
                                          enabled: p.canEnhanceClarity) {
                p.enhanceClaritySelection(scale: .x2)
            })
        }
        csub.addItem(MenuRowView.item(title: "提升 4 倍", width: 160,
                                      enabled: p.canEnhanceClarity) {
            p.enhanceClaritySelection(scale: .x4)
        })
        menu.addItem(MenuRowView.item(title: "清晰度提升", width: 200,
                                      enabled: p.canEnhanceClarity, submenu: csub))

        menu.popUpHere()
    }
}



// MARK: - 素材丢失（片段上的标记 + 重新关联）

/// 弹面板给某个素材重新指定文件。
///
/// **素材是唯一的真相源**：这里一改，素材库那条、时间轴上所有引用它的片段、
/// 画布上的卡片全都跟着恢复 —— 所以从哪个入口关联效果都一样
@MainActor
func relinkAssetWithPanel(_ assetID: UUID, project: ProjectState) {
    guard let asset = project.mediaAssets.first(where: { $0.id == assetID }) else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "请选择「\(asset.name)」的新位置"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    project.relinkAsset(id: assetID, newURL: url)
}

/// 片段上的「素材丢失」标记：压暗 + 左上角警示图标，**图标本身可点**，
/// 点了就是重新关联（用户要的「上边有重新关联的图标」）。
/// 不画描边 —— 那是选中态的事（白框）。
///
/// 判据读 `project.missingAssetIDs` 这个缓存，**绝不能在这里查盘** ——
/// 时间轴上百个片段每帧都渲染，`fileExists` 是每次一个系统调用
private struct ClipMissingOverlay: View {
    @EnvironmentObject var project: ProjectState
    let assetID: UUID
    /// 片段当前多宽 —— 太窄就只留图标，放不下文字
    let width: CGFloat
    /// 片段选中没有。选中时压暗层要让出边缘那圈，白框才跟别的片段一样
    var selected: Bool = false

    @State private var hovering = false

    var body: some View {
        if project.missingAssetIDs.contains(assetID) {
            ZStack(alignment: .topLeading) {
                // 压暗直接铺满叠上去，不内缩 —— 内缩会让边缘露出片段底色，
                // 看着像给丢失片段镶了一圈绿边
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4))
                // 选中的白框在这一层**重画一遍**：片段自己那圈画在压暗底下，
                // 会被压成灰的，跟别的片段选中时不一样。
                //
                // 必须用 `strokeBorder`（往内画）而不是 `stroke`（居中）：
                // 居中描边有一半探到边界外，而这一层是 overlay、不受片段的
                // clipShape 裁剪，于是跟底下那圈错开半像素，两圈叠起来看着就更粗
                if selected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white, lineWidth: 1)
                }
                Button { relinkAssetWithPanel(assetID, project: project) } label: {
                    HStack(spacing: 3) {
                        Image(nsImage: SidebarSVGIcon.load("toastWarn", size: 10))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10, height: 10)
                        if width > 110 {
                            Text(hovering ? "重新关联…" : "素材丢失")
                                .font(.system(size: 8, weight: .medium))
                        }
                    }
                    .foregroundColor(Color(hex: "#FF9230"))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(hovering ? 0.75 : 0.5)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("素材丢失 —— 点一下重新关联")
                .padding(3)
            }
        }
    }
}

private struct EffectTimelineClipView: View {
    let clip: EffectClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let leftInViewport = clipStart - scrollOffsetX
        if leftInViewport < 4 { return max(0, min(-leftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration * pps, 4)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#C97BB0").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(sel ? Color.white : Color(hex: "#E29FCC").opacity(0.4), lineWidth: 1))
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Image(nsImage: SidebarSVGIcon.load("effect", size: 9))
                        .renderingMode(.template)
                    Text(clip.name)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: h - 6)
        .opacity(isDragging ? 0 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime * pps + 1)
        .allowsHitTesting(false)
    }
}

private struct AdjustTimelineClipView: View {
    let clip: AdjustClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    /// 片段左边被滚出去时标题跟着贴边（跟其它片段一个做法）
    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let leftInViewport = clipStart - scrollOffsetX
        if leftInViewport < 4 { return max(0, min(-leftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration * pps, 4)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#7E8FD6").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(sel ? Color.white : Color(hex: "#9FAEE8").opacity(0.4), lineWidth: 1))
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Image(nsImage: SidebarSVGIcon.load("adjust", size: 9))
                        .renderingMode(.template)
                    Text(clip.name)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: h - 6)
        .opacity(isDragging ? 0 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime * pps + 1)
        .allowsHitTesting(false)
    }
}

private struct FilterTimelineClipView: View {
    let clip: FilterClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState

    /// 片段左边被滚出去时标题跟着贴边，别跟着滚没了（跟其它片段一个做法）
    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 4)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let leftInViewport = clipStart - scrollOffsetX
        if leftInViewport < 4 { return max(0, min(-leftInViewport + 4, w - 40)) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration * pps, 4)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#3F8F6B").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(sel ? Color.white : Color(hex: "#6FBF8F").opacity(0.4), lineWidth: 1))
            if w > TimelineClipMetrics.labelMinWidth {
                HStack(spacing: 3) {
                    Image(nsImage: SidebarSVGIcon.load("filter", size: 9))
                        .renderingMode(.template)
                    Text(clip.name)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.leading, stickyTitleX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: h - 6)
        .opacity(isDragging ? 0 :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime * pps + 1)
        .allowsHitTesting(false)
    }
}
