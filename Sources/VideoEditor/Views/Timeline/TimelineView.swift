import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Timeline root

struct TimelineView: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    private let labelW: CGFloat = 84
    private let rulerH: CGFloat = 26

    // 可拖动轨道高度
    @State private var imageTrackHeights: [Int: CGFloat] = [:]
    @State private var videoTrackHeights: [Int: CGFloat] = [:]
    @State private var audioTrackHeights: [Int: CGFloat] = [:]
    @State private var subtitleTrackHeights: [Int: CGFloat] = [:]
    @State private var textTrackHeights: [Int: CGFloat] = [:]
    private let defaultTrackH: CGFloat = 52
    private let defaultSubTrackH: CGFloat = 28
    private func imgH(_ i: Int) -> CGFloat { imageTrackHeights[i] ?? defaultTrackH }
    private func vidH(_ i: Int) -> CGFloat { videoTrackHeights[i] ?? defaultTrackH }
    private func audH(_ i: Int) -> CGFloat { audioTrackHeights[i] ?? defaultTrackH }
    private func subH(_ i: Int) -> CGFloat { subtitleTrackHeights[i] ?? defaultSubTrackH }
    private func txtH(_ i: Int) -> CGFloat { textTrackHeights[i] ?? defaultSubTrackH }
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
    @State private var activeSnapTime: Double? = nil  // 吸附指示线位置

    // Global event monitors
    @State private var keyMonitor:    Any? = nil
    @State private var scrollMonitor: Any? = nil
    @State private var scrollBarHovered = false
    @State private var scrollFraction: Double = 0
    @State private var scrollViewportFraction: Double = 1
    @State private var scrollOffsetX: CGFloat = 0
    @State private var thumbRefreshWork: DispatchWorkItem? = nil
    @State private var lastThumbPPS: Double = 0

    // 轨道标签拖拽排序
    private enum TrackDragType: Equatable { case video, audio, overlay }
    @State private var trackLabelDragType: TrackDragType? = nil
    @State private var trackLabelDragSrc: Int = 0
    @State private var trackLabelDragOffset: CGFloat = 0
    @State private var trackLabelDropIdx: Int? = nil

    private enum DragOp {
        case moveVideo(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveImage(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveAudio(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveSubtitle(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveText(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
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
        case movingPlayhead
        case resizeTrack(TrackKind)
        case box
        case ignored
    }

    struct DragItem {
        enum Kind { case video, image, audio, subtitle, text }
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

        var id: UUID {
            switch self {
            case .video(let id, _, _), .image(let id, _, _), .audio(let id, _, _), .subtitle(let id, _, _), .text(let id, _, _):
                return id
            }
        }
        var start: Double {
            switch self {
            case .video(_, let s, _), .image(_, let s, _), .audio(_, let s, _), .subtitle(_, let s, _), .text(_, let s, _):
                return s
            }
        }
        var duration: Double {
            switch self {
            case .video(_, _, let d), .image(_, _, let d), .audio(_, _, let d), .subtitle(_, _, let d), .text(_, _, let d):
                return d
            }
        }
    }

    private enum TrackKind: Equatable { case image(Int), video(Int), audio(Int), subtitle(Int), text(Int) }
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
        }
        .background(GeometryReader { geo -> Color in
            DispatchQueue.main.async { viewportH = geo.size.height }
            return Color.clear
        })
        .clipped()
        // 播放头三角和竖线都在 DraggablePlayhead 内部（ScrollView 内），完全同步不分离
        // 翻译进度已移至右下角全局浮层
        .onAppear { setupMonitors(); lastThumbPPS = project.pixelsPerSecond }
        .onDisappear { teardownMonitors() }
        .onChange(of: project.pixelsPerSecond) { newPPS in
            let ratio = max(newPPS, lastThumbPPS) / max(min(newPPS, lastThumbPPS), 1)
            guard ratio > 1.8 else { return }
            thumbRefreshWork?.cancel()
            let p = project
            let work = DispatchWorkItem { p.refreshAllThumbnails() }
            thumbRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            lastThumbPPS = newPPS
        }
    }

    private func setupMonitors() {
        // Delete key → delete selected clips.
        // Only skip when the user is actively editing text in a field editor
        // (an NSTextView acting as field editor inside an NSTextField).
        // Inspector panels contain TextFields but only block delete while focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 文本编辑中不拦截（包括 NSTextField 的 field editor 和 SwiftUI TextEditor 的独立 NSTextView）
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                return event
            }

            // Esc → 取消选择
            if event.keyCode == 53 {
                project.selectedVideoClipID      = nil
                project.selectedImageClipID      = nil
                project.selectedAudioClipID      = nil
                project.selectedSubtitleClipID   = nil
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
            // ⌘Z → 撤销
            if event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "z" {
                project.undo()
                return nil
            }

            // 空格键 → 播放/暂停
            if event.keyCode == 49 {
                NotificationCenter.default.post(name: .togglePlayback, object: nil)
                return nil
            }

            return event
        }

        // Command + scroll wheel → zoom timeline (pixelsPerSecond)，以播放头为中心
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
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
        if let m = keyMonitor    { NSEvent.removeMonitor(m); keyMonitor    = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    // MARK: Label column

    private var labelColumn: some View {
        VStack(spacing: 0) {
            // "+" dropdown to add tracks
            Menu {
                Button("添加视频轨道") { project.videoTracks.append(Track(label: "视频")) }
                Button("添加图片轨道") { project.imageTracks.append(Track(label: "图片")); project.syncOverlayOrder() }
                Button("添加音频轨道") { project.audioTracks.append(Track(label: "音频")) }
                Button("添加字幕轨道") {
                    var newTrack = Track<SubtitleClip>(label: "字幕")
                    newTrack.subtitleStyle = SubtitleStyle()
                    project.subtitleTracks.append(newTrack)
                    project.syncOverlayOrder()
                }
                Button("添加文字轨道") { project.textTracks.append(Track(label: "文字")); project.syncOverlayOrder() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: labelW, height: rulerH)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: rulerH)

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
                ForEach(project.videoTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"film", title: project.videoTracks[i].label,
                               count: project.videoTracks[i].clips.count, hasMute: true,
                               isMuted: project.videoTracks[i].isMuted, isVis: project.videoTracks[i].isVisible,
                               onMute: { project.pushUndo(); project.videoTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  { project.pushUndo(); project.videoTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                               onDel:  { project.pushUndo(); project.videoTracks.remove(at:i); project.rebuildTimelinePreview() },
                               onDragChanged: { handleDragChanged(type: .video, index: i, offsetY: $0) },
                               onDragEnded:   { handleDragEnded(type: .video, index: i, offsetY: $0) })
                        .frame(height: vidH(i))
                        .offset(y: isTrackDragging(.video, i) ? trackLabelDragOffset : 0)
                        .zIndex(isTrackDragging(.video, i) ? 10 : 0)
                        .opacity(isTrackDragging(.video, i) ? 0.55 : 1.0)
                }
            }
            if project.showAudioTracks {
                ForEach(project.audioTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"music.note", title: project.audioTracks[i].label,
                               count: project.audioTracks[i].clips.count, hasMute: true,
                               isMuted: project.audioTracks[i].isMuted, isVis: true, hasVis: false,
                               onMute: { project.pushUndo(); project.audioTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  {},
                               onDel:  { project.pushUndo(); project.audioTracks.remove(at:i); project.rebuildTimelinePreview() },
                               onDragChanged: { handleDragChanged(type: .audio, index: i, offsetY: $0) },
                               onDragEnded:   { handleDragEnded(type: .audio, index: i, offsetY: $0) })
                        .frame(height: audH(i))
                        .offset(y: isTrackDragging(.audio, i) ? trackLabelDragOffset : 0)
                        .zIndex(isTrackDragging(.audio, i) ? 10 : 0)
                        .opacity(isTrackDragging(.audio, i) ? 0.55 : 1.0)
                }
            }
            } // end inner VStack
            .overlay(trackDropIndicatorLine())
            .background(Color(red:0.09,green:0.09,blue:0.10))
        }
        .frame(width: labelW)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private struct ResolvedOverlay {
        enum Kind { case image, subtitle, text }
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
            }
        }
    }

    private var visibleOverlays: [ResolvedOverlay] {
        resolvedOverlays.filter { entry in
            switch entry.kind {
            case .image: return project.showImageTracks
            case .subtitle: return project.showSubtitleTracks
            case .text: return project.showTextTracks
            }
        }
    }

    private func overlayH(_ entry: ResolvedOverlay) -> CGFloat {
        switch entry.kind {
        case .image: return imgH(entry.index)
        case .subtitle: return subH(entry.index)
        case .text: return txtH(entry.index)
        }
    }

    private func trackLabelDropTarget(type: TrackDragType, source: Int, offset: CGFloat) -> Int {
        let count: Int
        let heights: [CGFloat]
        switch type {
        case .video:
            count = project.videoTracks.count
            heights = (0..<count).map { vidH($0) }
        case .audio:
            count = project.audioTracks.count
            heights = (0..<count).map { audH($0) }
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
                let t = project.videoTracks.remove(at: trackLabelDragSrc)
                project.videoTracks.insert(t, at: target)
            case .audio:
                let t = project.audioTracks.remove(at: trackLabelDragSrc)
                project.audioTracks.insert(t, at: target)
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
            TrackLabel(icon:"photo", title: project.imageTracks[i].label,
                       count: project.imageTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.imageTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.imageTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                       onDel:  { project.pushUndo(); project.imageTracks.remove(at:i); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .subtitle:
            TrackLabel(icon:"text.bubble", title: project.subtitleTracks[i].label,
                       count: project.subtitleTracks[i].clips.count, hasMute: false,
                       isMuted: false, isVis: project.subtitleTracks[i].isVisible,
                       onMute: nil,
                       onVis:  { project.pushUndo(); project.subtitleTracks[i].isVisible.toggle() },
                       onDel:  { project.pushUndo(); project.subtitleTracks.remove(at:i); project.syncOverlayOrder(); project.rebuildTimelinePreview() },
                       onDragChanged: { handleDragChanged(type: .overlay, index: ovIdx, offsetY: $0) },
                       onDragEnded:   { handleDragEnded(type: .overlay, index: ovIdx, offsetY: $0) })
        case .text:
            TextTrackLabel(title: project.textTracks[i].label,
                       count: project.textTracks[i].clips.count,
                       isVis: project.textTracks[i].isVisible,
                       onVis:  { project.pushUndo(); project.textTracks[i].isVisible.toggle() },
                       onDel:  { project.pushUndo(); project.textTracks.remove(at:i); project.syncOverlayOrder() },
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
            heights = project.videoTracks.indices.map { vidH($0) }
            let ovs = visibleOverlays
            baseY = ovs.reduce(CGFloat(0)) { $0 + overlayH($1) } + (ovs.isEmpty ? 0 : CGFloat(ovs.count))
        case .audio:
            heights = project.audioTracks.indices.map { audH($0) }
            let ovs = visibleOverlays
            baseY = ovs.reduce(CGFloat(0)) { $0 + overlayH($1) } + (ovs.isEmpty ? 0 : CGFloat(ovs.count))
            if project.showVideoTracks {
                baseY += project.videoTracks.indices.reduce(CGFloat(0)) { $0 + vidH($1) } + CGFloat(project.videoTracks.count)
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
            let contentW = clock.duration * project.pixelsPerSecond + 300
            let totalW = max(contentW, max(visibleW, 800))
            let effectiveH = max(totalContentH(), viewportH)
            ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    TimelineScrollViewFinder(project: project, onScroll: { frac, vpFrac, offX in
                        scrollFraction = frac
                        scrollViewportFraction = vpFrac
                        scrollOffsetX = offX
                    })
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    TimelineRuler(pps: project.pixelsPerSecond, duration: clock.duration,
                                  scrollOffsetX: scrollOffsetX, vpWidth: visibleW)
                        .frame(height: rulerH)
                        .allowsHitTesting(false)

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

                    if let gPos = dragGhostPos, let ghostInfo = dragGhostInfo() {
                        let cr: CGFloat = ghostInfo.isSubtitle ? 3 : 4
                        RoundedRectangle(cornerRadius: cr)
                            .fill(ghostInfo.color.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: cr)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                            )
                            .overlay(
                                Text(ghostInfo.name)
                                    .font(.system(size: ghostInfo.isSubtitle ? 8 : 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(1)
                                    .padding(.leading, ghostInfo.isSubtitle ? 4 : 5)
                                    .padding(.top, ghostInfo.isSubtitle ? 0 : 4)
                                , alignment: ghostInfo.isSubtitle ? .leading : .topLeading
                            )
                            .frame(width: max(ghostInfo.duration * project.pixelsPerSecond, 30),
                                   height: ghostInfo.height)
                            .position(x: gPos.x, y: gPos.y)
                            .allowsHitTesting(false)
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

                    DraggablePlayhead(pps: project.pixelsPerSecond, fullHeight: effectiveH)
                        .zIndex(10)
                }
                .frame(width: totalW, alignment: .topLeading)
                .frame(minHeight: effectiveH)
                .contentShape(Rectangle())
                .contextMenu {
                    let selID = project.selectedVideoClipID ?? project.selectedImageClipID
                              ?? project.selectedAudioClipID ?? project.selectedSubtitleClipID
                    if let id = selID {
                        Button { project.selectLeftOf(id) } label: { Label("向左全选", systemImage: "arrow.left.to.line") }
                        Button { project.selectRightOf(id) } label: { Label("向右全选", systemImage: "arrow.right.to.line") }
                        Divider()
                    }
                    if let textID = project.selectedTextClipID {
                        Button {
                            project.saveTextTemplateFromClip(textID)
                        } label: { Label("保存为文字模板", systemImage: "square.and.arrow.down") }
                        Divider()
                    }
                    Button { project.copySelected() } label: { Label("复制", systemImage: "doc.on.doc") }
                    Button { project.cutSelected() } label: { Label("剪切", systemImage: "scissors") }
                    Button { project.pasteAtPlayhead() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                    if selID != nil || project.selectedTextClipID != nil {
                        Divider()
                        Button(role: .destructive) { project.deleteSelected() } label: { Label("删除", systemImage: "trash") }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        scrollBarHovered = loc.y > effectiveH - 24
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
                        scrollBarHovered = false
                        NSCursor.arrow.set()
                    }
                }
                .simultaneousGesture(unifiedDragGesture)
                .onDrop(of: [UTType.plainText], isTargeted: $isLibraryDragOver) { providers, location in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                        guard let idStr = obj as? String,
                              let assetID = UUID(uuidString: idStr) else { return }
                        DispatchQueue.main.async {
                            let time = max(0, location.x / self.project.pixelsPerSecond)
                            if let asset = self.project.mediaAssets.first(where: { $0.id == assetID }) {
                                self.project.addToTimelineAt(asset, time: time)
                            }
                        }
                    }
                    return true
                }
            }


            // 自定义水平滚动条
            if scrollViewportFraction < 1 {
                TimelineScrollBar(
                    fraction: scrollFraction,
                    viewportFraction: scrollViewportFraction,
                    isVisible: scrollBarHovered,
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
                        // Ruler strip (includes playhead triangle): move playhead immediately.
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
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle, .moveText:
                    dragGhostPos = CGPoint(x: v.location.x - dragGhostOffset.width,
                                           y: v.location.y - dragGhostOffset.height)
                default: break
                }
                applyDrag(op: op, totalTranslation: v.translation, current: v.location)
            }
            .onEnded { v in
                // 点击（没有拖动）→ 优先检测转场图标，然后选中clip或取消选择
                if dragOp == nil && v.startLocation.y >= rulerH {
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
                        if isShift {
                            switch hit {
                            case .video(let id, _, _), .image(let id, _, _),
                                 .audio(let id, _, _), .subtitle(let id, _, _), .text(let id, _, _):
                                project.shiftToggleClip(id)
                            }
                        } else {
                            project.selectedClipIDs.removeAll()
                            project.selectedTransitionClipID = nil
                            switch hit {
                            case .video(let id, _, _):
                                project.selectedVideoClipID = id
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                                project.selectedTextClipID = nil
                            case .image(let id, _, _):
                                project.selectedImageClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                                project.selectedTextClipID = nil
                            case .audio(let id, _, _):
                                project.selectedAudioClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedSubtitleClipID = nil
                                project.selectedTextClipID = nil
                            case .subtitle(let id, _, _):
                                project.selectedSubtitleClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedTextClipID = nil
                            case .text(let id, _, _):
                                project.selectedTextClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                            }
                        }
                    } else if !hitTransition {
                        // 点击空白区域：取消选择 + seek
                        project.selectedClipIDs.removeAll()
                        project.selectedVideoClipID      = nil
                        project.selectedImageClipID      = nil
                        project.selectedAudioClipID      = nil
                        project.selectedSubtitleClipID   = nil
                        project.selectedTextClipID       = nil
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
                        }
                    case .moveImage(let id, _, _, let srcTrack):
                        if let dst = destTrack.imageIndex, dst != srcTrack {
                            project.moveImageClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveAudio(let id, _, _, let srcTrack):
                        if let dst = destTrack.audioIndex, dst != srcTrack {
                            project.moveAudioClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveSubtitle(let id, _, _, let srcTrack):
                        if let dst = destTrack.subtitleIndex, dst != srcTrack {
                            project.moveSubtitleClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveText(let id, _, _, let srcTrack):
                        if let dst = destTrack.textIndex, dst != srcTrack {
                            project.moveTextClipToTrack(id: id, from: srcTrack, to: dst)
                        }
                    case .moveMulti(let items):
                        for it in items {
                            switch it.kind {
                            case .subtitle:
                                if let dst = destTrack.subtitleIndex, dst != it.srcTrack {
                                    project.moveSubtitleClipToTrack(id: it.id, from: it.srcTrack, to: dst)
                                }
                            case .text:
                                if let dst = destTrack.textIndex, dst != it.srcTrack {
                                    project.moveTextClipToTrack(id: it.id, from: it.srcTrack, to: dst)
                                }
                            case .image:
                                if let dst = destTrack.imageIndex, dst != it.srcTrack {
                                    project.moveImageClipToTrack(id: it.id, from: it.srcTrack, to: dst)
                                }
                            case .video:
                                if let dst = destTrack.videoIndex, dst != it.srcTrack {
                                    project.moveVideoClipToTrack(id: it.id, from: it.srcTrack, to: dst)
                                }
                            case .audio:
                                if let dst = destTrack.audioIndex, dst != it.srcTrack {
                                    project.moveAudioClipToTrack(id: it.id, from: it.srcTrack, to: dst)
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
                    case .moveMulti(let items):
                        for it in items {
                            switch it.kind {
                            case .video:    project.resolveVideoOverlap(id: it.id)
                            case .image:    project.resolveImageOverlap(id: it.id)
                            case .audio:    project.resolveAudioOverlap(id: it.id)
                            case .subtitle: project.resolveSubtitleOverlap(id: it.id)
                            case .text:     project.resolveTextOverlap(id: it.id)
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
                     .trimTextLeft, .trimTextRight:
                    NSCursor.arrow.set()
                    project.rebuildTimelinePreview()
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle, .moveText, .moveMulti:
                    project.rebuildTimelinePreview()
                case .resizeTrack:
                    NSCursor.arrow.set()
                default: break
                }
                dragOp = nil
                boxStart = nil
                boxEnd = nil
                dragGhostPos = nil
                dragGhostOffset = .zero
                draggingClipID = nil
                activeSnapTime = nil
            }
    }

    private func startDrag(at pt: CGPoint) {
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
            // Multi-drag only for interior (move) grabs on already-selected group.
            if trimEdge == nil,
               project.selectedClipIDs.contains(hit.id),
               project.selectedClipIDs.count > 1 {
                let items = collectMultiDragItems()
                project.pushUndo()
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

            project.selectedClipIDs.removeAll()
            project.pushUndo()
            switch (hit, trimEdge) {
            case (.video(let id, let s, let d), nil):
                project.selectedVideoClipID    = id
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
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
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveImage(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.image(let id, let s, let d), .left):
                project.selectedImageClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                dragOp = .trimImageLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.image(let id, let s, let d), .right):
                project.selectedImageClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                dragOp = .trimImageRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.audio(let id, let s, let d), nil):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveAudio(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.audio(let id, let s, let d), .left):
                let ts = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                let aClip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ad = project.mediaAssets.first(where: { $0.id == aClip?.assetID })?.duration ?? Double.infinity
                dragOp = .trimAudioLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimLeftCursor.set()
            case (.audio(let id, let s, let d), .right):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedTextClipID     = nil
                let aClip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ts = aClip?.trimStart ?? 0
                let ad = project.mediaAssets.first(where: { $0.id == aClip?.assetID })?.duration ?? Double.infinity
                dragOp = .trimAudioRight(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimRightCursor.set()
            case (.subtitle(let id, let s, let d), nil):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedTextClipID     = nil
                let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveSubtitle(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.subtitle(let id, let s, let d), .left):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedTextClipID     = nil
                dragOp = .trimSubtitleLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.subtitle(let id, let s, let d), .right):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedTextClipID     = nil
                dragOp = .trimSubtitleRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.text(let id, let s, let d), nil):
                project.selectedTextClipID     = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveText(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.text(let id, let s, let d), .left):
                project.selectedTextClipID     = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimTextLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.text(let id, let s, let d), .right):
                project.selectedTextClipID     = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimTextRight(id: id, originStart: s, originEnd: s + d)
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
                }
            }
            let newH = (dragOriginTrackH + totalTranslation.height).clamped(to: 28...120)
            switch kind {
            case .image(let i):    imageTrackHeights[i] = newH
            case .video(let i):    videoTrackHeights[i] = newH
            case .audio(let i):    audioTrackHeights[i] = newH
            case .subtitle(let i): subtitleTrackHeights[i] = newH
            case .text(let i):     textTrackHeights[i] = newH
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

    private func findClipTarget(at pt: CGPoint) -> (hit: ClipHit, trimEdge: ClipTrimEdge?)? {
        guard pt.y >= rulerH else { return nil }
        let pps = project.pixelsPerSecond
        let threshold: CGFloat = 8
        var rowTop: CGFloat = rulerH
        var first = true

        // 边缘检测：当两个片段相邻时，左边缘优先（离片段中心更近的边优先）
        func edge(x: CGFloat, xMin: CGFloat, xMax: CGFloat) -> ClipTrimEdge? {
            guard xMax - xMin >= 20 else { return nil }
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
                }
                return nil
            }
            rowTop += h
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = vidH(ti)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    if let m = bestMatch(project.videoTracks[ti].clips, x: pt.x,
                        { c, _, _ in .video(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
                    return nil
                }
                rowTop += h
            }
        }
        if project.showAudioTracks {
            for ti in project.audioTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = audH(ti)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    if let m = bestMatch(project.audioTracks[ti].clips, x: pt.x,
                        { c, _, _ in .audio(id: c.id, start: c.startTime, dur: c.duration) },
                        { $0.startTime }, { $0.endTime }) { return m }
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
            }
            rowTop += h
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = vidH(ti)
                let yRange = rowTop ... (rowTop + h)
                for c in project.videoTracks[ti].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    let xRange = (c.startTime*pps) ... xEnd
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += h
            }
        }
        if project.showAudioTracks {
            for ti in project.audioTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = audH(ti)
                let yRange = rowTop ... (rowTop + h)
                for c in project.audioTracks[ti].clips {
                    let xEnd = max(c.startTime*pps, c.endTime*pps)
                    let xRange = (c.startTime*pps) ... xEnd
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
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
            }
        }
        if project.showVideoTracks {
            for i in project.videoTracks.indices {
                if !first { top += 1 }; first = false
                top += vidH(i)
                if abs(y - top) <= threshold { return .video(i) }
            }
        }
        if project.showAudioTracks {
            for i in project.audioTracks.indices {
                if !first { top += 1 }; first = false
                top += audH(i)
                if abs(y - top) <= threshold { return .audio(i) }
            }
        }
        return nil
    }

    private func totalContentH() -> CGFloat {
        var h = rulerH
        var trackCount = 0
        for entry in visibleOverlays { h += overlayH(entry); trackCount += 1 }
        if project.showVideoTracks    { for i in project.videoTracks.indices    { h += vidH(i) }; trackCount += project.videoTracks.count }
        if project.showAudioTracks    { for i in project.audioTracks.indices    { h += audH(i) }; trackCount += project.audioTracks.count }
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
        // Overlay tracks (image/subtitle/text) — unified order
        ForEach(Array(visibleOverlays.enumerated()), id:\.element.trackID) { ovIdx, entry in
            overlayClipRow(entry: entry)
                .offset(y: isTrackDragging(.overlay, ovIdx) ? trackLabelDragOffset : 0)
                .zIndex(isTrackDragging(.overlay, ovIdx) ? 10 : 0)
                .opacity(isTrackDragging(.overlay, ovIdx) ? 0.55 : 1.0)
        }
        if project.showVideoTracks {
            ForEach(project.videoTracks.indices, id:\.self) { i in
                trackRow(height: vidH(i), hidden: !project.videoTracks[i].isVisible, tint: Color(hex: "#3DBFBA")) {
                    ForEach(project.videoTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                        VideoClipView(clip: clip, pps: project.pixelsPerSecond, h: vidH(i),
                                      sel: isSelected(clip.id, primary: project.selectedVideoClipID),
                                      isDragging: draggingClipID == clip.id,
                                      scrollOffsetX: scrollOffsetX)
                    }
                    transitionIcons(trackIndex: i, trackHeight: vidH(i))
                }
                .offset(y: isTrackDragging(.video, i) ? trackLabelDragOffset : 0)
                .zIndex(isTrackDragging(.video, i) ? 10 : 0)
                .opacity(isTrackDragging(.video, i) ? 0.55 : 1.0)
            }
        }
        if project.showAudioTracks {
            ForEach(project.audioTracks.indices, id:\.self) { i in
                trackRow(height: audH(i), hidden: !project.audioTracks[i].isVisible, muted: project.audioTracks[i].isMuted, tint: Color(hex: "#5DB85D")) {
                    ForEach(project.audioTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                        AudioClipView(clip: clip, pps: project.pixelsPerSecond, h: audH(i),
                                      sel: isSelected(clip.id, primary: project.selectedAudioClipID),
                                      isDragging: draggingClipID == clip.id,
                                      scrollOffsetX: scrollOffsetX)
                    }
                }
                .offset(y: isTrackDragging(.audio, i) ? trackLabelDragOffset : 0)
                .zIndex(isTrackDragging(.audio, i) ? 10 : 0)
                .opacity(isTrackDragging(.audio, i) ? 0.55 : 1.0)
            }
        }
        }
        .overlay(trackDropIndicatorLine())
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
                                  isDragging: draggingClipID == clip.id,
                                  scrollOffsetX: scrollOffsetX)
                }
            }
        case .subtitle:
            trackRow(height: subH(i), hidden: !project.subtitleTracks[i].isVisible, tint: Color(hex: "#7B6FC4")) {
                ForEach(project.subtitleTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    SubtitleClipView(clip: clip, pps: project.pixelsPerSecond, h: subH(i),
                                     sel: isSelected(clip.id, primary: project.selectedSubtitleClipID),
                                     isDragging: draggingClipID == clip.id,
                                     scrollOffsetX: scrollOffsetX)
                }
            }
        case .text:
            trackRow(height: txtH(i), hidden: !project.textTracks[i].isVisible, tint: Color(hex: "#D4668E")) {
                ForEach(project.textTracks[i].clips.filter { isClipVisible(startTime: $0.startTime, endTime: $0.endTime) }) { clip in
                    TextClipView(clip: clip, pps: project.pixelsPerSecond, h: txtH(i),
                                 sel: isSelected(clip.id, primary: project.selectedTextClipID),
                                 isDragging: draggingClipID == clip.id,
                                 scrollOffsetX: scrollOffsetX)
                }
            }
        }
    }

    private struct GhostInfo {
        let name: String
        let duration: Double
        let color: Color
        let height: CGFloat
        let isSubtitle: Bool
    }

    private func dragGhostInfo() -> GhostInfo? {
        switch dragOp {
        case .moveVideo(let id, _, _, _):
            guard let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#3DBFBA"), height: vidH(ti) - 4, isSubtitle: false)
        case .moveImage(let id, _, _, _):
            guard let clip = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#E8A54B"), height: imgH(ti) - 4, isSubtitle: false)
        case .moveAudio(let id, _, _, _):
            guard let clip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#5DB85D"), height: audH(ti) - 4, isSubtitle: false)
        case .moveSubtitle(let id, _, _, _):
            guard let clip = project.subtitleTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.text.components(separatedBy: "\n").first ?? clip.text, duration: clip.duration, color: Color(hex: "#7B6FC4"), height: subH(ti) - 4, isSubtitle: true)
        case .moveText(let id, _, _, _):
            guard let clip = project.textTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            let ti = project.textTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return GhostInfo(name: clip.text, duration: clip.duration, color: Color(hex: "#D4668E"), height: txtH(ti) - 4, isSubtitle: true)
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
    }

    private func trackRowForClip(_ hit: ClipHit) -> Int {
        let overlays = resolvedOverlays
        let oCount = overlays.count
        let vCount = project.videoTracks.count
        switch hit {
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
        case .video(let id, _, _):
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return oCount + ti
        case .audio(let id, _, _):
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return oCount + vCount + ti
        }
    }

    private func trackCenterY(row: Int) -> CGFloat {
        let overlays = resolvedOverlays
        let oCount = overlays.count
        let vCount = project.showVideoTracks ? project.videoTracks.count : 0
        var top = rulerH

        func heightForRow(_ r: Int) -> CGFloat {
            if r < oCount { return overlayH(overlays[r]) }
            let afterOverlay = r - oCount
            if afterOverlay < vCount { return vidH(afterOverlay) }
            return audH(afterOverlay - vCount)
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
                }
            }
            top += h
        }
        if project.showVideoTracks {
            for i in project.videoTracks.indices {
                if !first { top += 1 }; first = false
                let h = vidH(i)
                if y < top + h { return TrackTarget(videoIndex: i) }
                top += h
            }
        }
        if project.showAudioTracks {
            for i in project.audioTracks.indices {
                if !first { top += 1 }; first = false
                let h = audH(i)
                if y < top + h { return TrackTarget(audioIndex: i) }
                top += h
            }
        }
        return TrackTarget()
    }

    /// 在视频轨道中渲染转场菱形图标（相邻 clip 之间）
    @ViewBuilder
    private func transitionIcons(trackIndex: Int, trackHeight: CGFloat) -> some View {
        let pairs = adjacentPairs(in: project.videoTracks[trackIndex])
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
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .light))
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
                    if hasMute, let onMute {
                        OverlayBtn(icon: isMuted ? "speaker.slash" : "speaker.wave.2",
                                   action: onMute)
                    }
                    if hasVis {
                        OverlayBtn(icon: isVis ? "eye" : "eye.slash",
                                   action: onVis)
                    }
                    OverlayBtn(icon: "trash", destructive: true,
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
                    .gesture(DragGesture()
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
                Text("T")
                    .font(.system(size: 11, weight: .bold, design: .serif))
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
                    OverlayBtn(icon: isVis ? "eye" : "eye.slash", action: onVis)
                    OverlayBtn(icon: "trash", destructive: true, action: onDel)
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
                    .gesture(DragGesture()
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
    let icon: String
    var destructive: Bool = false
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
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

private struct VideoClipView: View {
    let clip: VideoClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    var scrollOffsetX: CGFloat = 0
    @EnvironmentObject var project: ProjectState
    @State private var thumbBreathing = false

    private var isReloading: Bool {
        project.thumbnailsReloading.contains(clip.assetID)
    }

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 5)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return min(-clipLeftInViewport + 5, w - 60) }
        return 5
    }

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment:.leading) {
            // Thumbnail strip or solid color
            if let frames = project.assetThumbnails[clip.assetID], !frames.isEmpty {
                thumbnailStrip(frames: frames, clipWidth: w)
            } else {
                RoundedRectangle(cornerRadius:6).fill(Color(hex:"#3DBFBA").opacity(0.82))
            }
            // 重建缩略图时的呼吸遮罩
            if isReloading {
                RoundedRectangle(cornerRadius:6)
                    .fill(Color(hex:"#3DBFBA").opacity(thumbBreathing ? 0.35 : 0.15))
            }
            // Selection border
            RoundedRectangle(cornerRadius:6)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            // Name label — sticky to viewport left edge
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 速率徽章（speed != 1.0 时显示）
            if abs(clip.speed - 1.0) > 0.01 {
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
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .animation(isReloading ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: thumbBreathing)
        .onChange(of: isReloading) { loading in thumbBreathing = loading }
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
        .onAppear {
            if let url = clip.url {
                project.loadTimelineThumbnails(assetID: clip.assetID, url: url)
            }
        }
    }

    @ViewBuilder
    private func thumbnailStrip(frames: [ThumbnailFrame], clipWidth: CGFloat) -> some View {
        let thumbH = h - 4
        let ratio: CGFloat = frames.first.map { CGFloat($0.image.size.width) / max(CGFloat($0.image.size.height), 1) } ?? 1.0
        let thumbW = max(thumbH * ratio, 1)
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        // 只渲染可视范围内的缩略图
        let clipStartX = clip.startTime * pps
        let visLeft = scrollOffsetX - clipStartX - thumbW  // 相对于片段左侧的可见左边界
        let visRight = scrollOffsetX + max(project.timelineVisibleWidth, 400) - clipStartX + thumbW
        let startIdx = max(0, Int(floor(visLeft / thumbW)))
        let endIdx = max(startIdx, min(count, Int(ceil(visRight / thumbW))))
        HStack(spacing: 0) {
            if startIdx > 0 {
                Color.clear.frame(width: thumbW * CGFloat(startIdx), height: thumbH)
            }
            ForEach(startIdx..<endIdx, id: \.self) { i in
                let t = clip.trimStart + clip.duration * max(0.01, clip.speed) * Double(i) / Double(count)
                let frame = closestFrame(frames, at: t)
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: i == count - 1 ? clipWidth - thumbW * CGFloat(count - 1) : thumbW,
                           height: thumbH)
                    .clipped()
            }
            if endIdx < count {
                Color.clear.frame(width: thumbW * CGFloat(count - endIdx), height: thumbH)
            }
        }
        .frame(width: clipWidth, height: thumbH)
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

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 5)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return min(-clipLeftInViewport + 5, w - 60) }
        return 5
    }

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment:.leading) {
            if let thumb = project.mediaThumbnails[clip.assetID] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h - 4)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius:6).fill(Color(hex:"#E8A54B").opacity(0.82))
            }
            RoundedRectangle(cornerRadius:6)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
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

    private var stickyTitleX: CGFloat {
        let w = max(clip.duration * pps, 5)
        let clipStart = CGFloat(clip.startTime * pps) + 1
        let clipLeftInViewport = clipStart - scrollOffsetX
        if clipLeftInViewport < 5 { return min(-clipLeftInViewport + 5, w - 60) }
        return 5
    }

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius:6).fill(Color(hex:"#5DB85D").opacity(0.78))
            if let wave = project.waveformCache[clip.assetID] {
                AudioWaveformCanvas(waveData: wave, trimStart: clip.trimStart,
                                     clipDuration: clip.duration, fullHeight: true,
                                     clipStartX: CGFloat(clip.startTime * pps),
                                     scrollOffsetX: scrollOffsetX,
                                     vpWidth: max(project.timelineVisibleWidth, 400))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            RoundedRectangle(cornerRadius:6).stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, stickyTitleX)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if abs(clip.speed - 1.0) > 0.01 {
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
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .onAppear {
            if let url = clip.url {
                project.loadWaveform(assetID: clip.assetID, url: url)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Canvas-based audio waveform visualization
private struct AudioWaveformCanvas: View {
    let waveData: WaveformData
    let trimStart: Double
    let clipDuration: Double
    var fullHeight: Bool = false
    var clipStartX: CGFloat = 0      // 片段在内容坐标中的起始 x
    var scrollOffsetX: CGFloat = 0
    var vpWidth: CGFloat = 800

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
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.30)))
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
        if clipLeftInViewport < 4 { return min(-clipLeftInViewport + 4, w - 40) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:6)
                .fill(Color(hex:"#7B6FC4").opacity(isPlaceholder ? 0.35 : 0.85))
                .overlay(RoundedRectangle(cornerRadius:6)
                    .stroke(sel ? Color.white : Color(hex:"#9B8FD4").opacity(0.4), lineWidth: sel ? 2 : 1))
            if !isPlaceholder && w > 16 {
                Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                    .font(.system(size:8, weight:.medium))
                    .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    .padding(.leading, stickyTitleX)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 : isPlaceholder ? (breathing ? 0.7 : 0.3) :
                 (project.clipboardIsCut && project.clipboardSourceIDs.contains(clip.id) ? 0.35 : 1.0))
        .animation(isPlaceholder ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: breathing)
        .onAppear { if isPlaceholder { breathing = true } }
        .onChange(of: isPlaceholder) { ph in breathing = ph }
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
        if clipLeftInViewport < 4 { return min(-clipLeftInViewport + 4, w - 40) }
        return 4
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:6)
                .fill(Color(hex:"#D4668E").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius:6)
                    .stroke(sel ? Color.white : Color(hex:"#E088A8").opacity(0.4), lineWidth: sel ? 2 : 1))
            if w > 16 {
                HStack(spacing: 3) {
                    Text("T")
                        .font(.system(size: 8, weight: .bold, design: .serif))
                        .foregroundColor(.white.opacity(0.6))
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
                let x = t * pps
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
        .background(Color(red: 0.09, green: 0.09, blue: 0.10))
    }
}

// MARK: - Draggable Playhead

private struct DraggablePlayhead: View {
    @EnvironmentObject private var project: ProjectState
    @EnvironmentObject private var clock: PlaybackClock
    let pps: Double
    let fullHeight: CGFloat

    var body: some View {
        let x = clock.currentTime * pps
        Canvas { ctx, size in
            // 三角（y 6~16）
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: 16))
            tri.addLine(to: CGPoint(x: x - 5, y: 6))
            tri.addLine(to: CGPoint(x: x + 5, y: 6))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Color.accent))
            // 竖线（y 16 ~ fullHeight）
            let line = CGRect(x: x - 0.5, y: 16, width: 1, height: fullHeight - 16)
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

// MARK: - Toolbar

struct TimelineToolbar: View {
    @EnvironmentObject private var project: ProjectState
    private var hasSelection: Bool {
        project.selectedVideoClipID != nil || project.selectedImageClipID != nil ||
        project.selectedAudioClipID != nil || project.selectedSubtitleClipID != nil ||
        project.selectedTextClipID != nil || !project.selectedClipIDs.isEmpty
    }
    var body: some View {
        HStack(spacing:0) {
            // 左侧：编辑工具
            HStack(spacing:2) {
                TBtn(icon:"arrow.uturn.backward", help:"撤销", enabled: project.undoCount > 0) { project.undo() }
                TBtn(icon:"arrow.uturn.forward",  help:"重做", enabled: project.redoCount > 0) { project.redo() }
                Divider().frame(height:16).padding(.horizontal,4)
                TBtn(icon:"scissors",         help:"在播放头分割片段", enabled: hasSelection && project.selectedImageClipID == nil && project.selectedTextClipID == nil) { project.splitAtPlayhead() }
                TBtn(icon:"trash",            help:"删除选中片段", enabled: hasSelection)   { project.deleteSelected() }
                TBtn(icon:"text.alignleft",   help:"将选中片段对齐到播放头", enabled: hasSelection) { project.alignSelectedToPlayhead() }
                TBtn(icon:"character.bubble", help:"在当前字幕轨道插入字幕")  { project.insertSubtitleAtPlayhead() }
                TextToolBtn { project.addTextAtPlayhead() }

                Divider().frame(height:16).padding(.horizontal,4)

                // 翻译 & 样式工具
                TranslateToolGroup()
            }.padding(.leading,8)

            Spacer()

            // 轨道显示开关
            HStack(spacing: 2) {
                TrackToggleBtn(icon: "photo", on: $project.showImageTracks, help: "图片轨道")
                TrackToggleBtn(icon: "film", on: $project.showVideoTracks, help: "视频轨道")
                TrackToggleBtn(icon: "music.note", on: $project.showAudioTracks, help: "音频轨道")
                TrackToggleBtn(icon: "captions.bubble", on: $project.showSubtitleTracks, help: "字幕轨道")
                TrackToggleBtnT(on: $project.showTextTracks, help: "文字轨道")
            }
            .padding(.trailing, 4)

            // 吸附开关
            Button { project.snapEnabled.toggle() } label: {
                Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(project.snapEnabled ? Color.accent : Color.labelSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("自动吸附")
            .padding(.trailing, 8)

            // 右侧：缩放
            HStack(spacing:6) {
                TBtn(icon:"arrow.left.and.right.square", help:"缩放至适合") { project.zoomToFit() }
                TBtn(icon:"minus.magnifyingglass", help:"缩小") { project.zoomTo(project.pixelsPerSecond / 1.5) }
                LogSlider(value: Binding(
                    get: { project.pixelsPerSecond },
                    set: { project.zoomTo($0) }
                ), range: min(project.minPixelsPerSecond, 3000)...3000).frame(width:100).help("时间轴缩放")
                TBtn(icon:"plus.magnifyingglass", help:"放大")  { project.zoomTo(project.pixelsPerSecond * 1.5) }
            }.padding(.trailing,12)
        }
        .frame(height:36)
        .background(Color(red:0.09,green:0.09,blue:0.10))
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

    /// 选中字幕所在轨道的 index（没选中则 nil）
    private var selectedTrackIndex: Int? {
        guard let sid = project.selectedSubtitleClipID else { return nil }
        return project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == sid } }
    }

    /// "翻译整条轨道"按钮是否可用
    private var translateAllEnabled: Bool {
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
            // 目标语言下拉
            Button { showLangMenu() } label: {
                HStack(spacing: 3) {
                    Text(shortLang(project.translationTargetLang))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Color.labelSecondary)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TBtn(icon: "translate", help: "翻译选中字幕",
                 enabled: project.selectedSubtitleClipID != nil) { translateCurrent() }
            TBtn(icon: "list.bullet.rectangle", help: "翻译整条轨道",
                 enabled: translateAllEnabled) { translateAll() }
            TBtn(icon: project.isTranscribing ? "waveform" : "waveform.badge.mic",
                 help: project.isTranscribing ? "正在识别字幕…" : "自动识别字幕（按当前翻译目标语言生成）",
                 enabled: !project.isTranscribing) { project.autoTranscribeSelectedClip() }
        }
    }

    private func shortLang(_ lang: String) -> String {
        switch lang {
        case "中文（简体）": return "简中"
        case "中文（繁体）": return "繁中"
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

    private func translateCurrent() {
        guard let srcIdx = sourceTrackIndex() else { return }

        var allSelectedIDs = project.selectedClipIDs
        if let pid = project.selectedSubtitleClipID { allSelectedIDs.insert(pid) }
        let srcClips = project.subtitleTracks[srcIdx].clips
        let clips = srcClips.filter { allSelectedIDs.contains($0.id) }
            .sorted { $0.startTime < $1.startTime }
        guard !clips.isEmpty else { return }

        let lang = project.translationTargetLang
        project.pushUndo()
        let destIdx = createTranslationTrack(before: srcIdx)
        let destTrackID = project.subtitleTracks[destIdx].id

        var placeholders: [SubtitleClip] = []
        for c in clips {
            let ph = SubtitleClip(text: "", startTime: c.startTime, endTime: c.endTime)
            placeholders.append(ph)
            project.placeholderClipIDs.insert(ph.id)
        }
        project.subtitleTracks[destIdx].clips = placeholders
        project.translatingTrackIDs.insert(destTrackID)
        project.translationTotal = clips.count
        project.translationDone = 0
        project.translationProgress = 0

        project.translationTask = Task {
            for (i, c) in clips.enumerated() {
                guard !Task.isCancelled else { return }
                let translated = await Translator.translateSmart(c.text, to: lang)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let ti = project.subtitleTracks.firstIndex(where: { $0.id == destTrackID }) else { return }
                    let phID = placeholders[i].id
                    if let ci = project.subtitleTracks[ti].clips.firstIndex(where: { $0.id == phID }) {
                        project.subtitleTracks[ti].clips[ci] = SubtitleClip(
                            text: translated, startTime: c.startTime, endTime: c.endTime)
                    }
                    project.placeholderClipIDs.remove(phID)
                    project.translationDone = i + 1
                    project.translationProgress = Double(i + 1) / Double(clips.count)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                project.translatingTrackIDs.remove(destTrackID)
                project.translationTotal = 0
                project.translationDone = 0
                project.translationProgress = 0
                project.translationTask = nil
                project.showSuccessToast(icon: "checkmark", title: "翻译", subtitle: "翻译完成")
            }
        }
    }

    private func translateAll() {
        guard let srcIdx = sourceTrackIndex() else { return }
        let lang = project.translationTargetLang
        let originals = project.subtitleTracks[srcIdx].clips
        guard !originals.isEmpty else { return }
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

        project.translationTask = Task {
            for (i, c) in originals.enumerated() {
                guard !Task.isCancelled else { return }
                let t = await Translator.translateSmart(c.text, to: lang)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let ti = project.subtitleTracks.firstIndex(where: { $0.id == destTrackID }) else { return }
                    let phID = placeholders[i].id
                    if let ci = project.subtitleTracks[ti].clips.firstIndex(where: { $0.id == phID }) {
                        project.subtitleTracks[ti].clips[ci] = SubtitleClip(
                            text: t, startTime: c.startTime, endTime: c.endTime)
                    }
                    project.placeholderClipIDs.remove(phID)
                    project.translationDone = i + 1
                    project.translationProgress = Double(i + 1) / Double(originals.count)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                project.translatingTrackIDs.remove(destTrackID)
                project.translationTotal = 0
                project.translationDone = 0
                project.translationProgress = 0
                project.translationTask = nil
                project.showSuccessToast(icon: "checkmark", title: "翻译", subtitle: "翻译完成")
            }
        }
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
            Image(systemName: icon).font(.system(size: 12, weight: .light))
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

private struct TextToolBtn: View {
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Text("T").font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundColor(hov ? Color.labelPrimary : Color.labelSecondary)
                .frame(width: 28, height: 28)
                .background(hov ? Color.white.opacity(0.08) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
        .help("添加文字/标题图层")
    }
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
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sv.contentView, queue: .main
            ) { [weak self, weak sv] _ in self?.update(sv) }
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
    let onDrag: (Double) -> Void

    @State private var isDragging = false
    @State private var dragStartFraction: Double = 0

    private let barH: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width - 16
            let knobW = max(trackW * viewportFraction, 30)
            let maxOffset = max(trackW - knobW, 1)
            let knobX = 8 + fraction * maxOffset
            let show = isVisible || isDragging

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: trackW, height: barH)
                    .offset(x: 8)

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isDragging ? 0.55 : 0.35))
                    .frame(width: knobW, height: barH)
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
            .frame(height: barH)
            .opacity(show ? 1 : 0)
            .animation(.easeInOut(duration: show ? 0.15 : 0.4), value: show)
        }
        .frame(height: barH + 4)
    }
}
