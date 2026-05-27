import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Timeline root

struct TimelineView: View {
    @EnvironmentObject private var project: ProjectState
    private let labelW: CGFloat = 84
    private let rulerH: CGFloat = 26

    // 可拖动轨道高度
    @State private var imageTrackHeights: [Int: CGFloat] = [:]
    @State private var videoTrackHeights: [Int: CGFloat] = [:]
    @State private var audioTrackHeights: [Int: CGFloat] = [:]
    @State private var subtitleTrackHeights: [Int: CGFloat] = [:]
    private let defaultTrackH: CGFloat = 52
    private let defaultSubTrackH: CGFloat = 28
    private func imgH(_ i: Int) -> CGFloat { imageTrackHeights[i] ?? defaultTrackH }
    private func vidH(_ i: Int) -> CGFloat { videoTrackHeights[i] ?? defaultTrackH }
    private func audH(_ i: Int) -> CGFloat { audioTrackHeights[i] ?? defaultTrackH }
    private func subH(_ i: Int) -> CGFloat { subtitleTrackHeights[i] ?? defaultSubTrackH }
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

    private enum DragOp {
        case moveVideo(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveImage(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveAudio(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveSubtitle(id: UUID, originStart: Double, originDur: Double, srcTrack: Int)
        case moveMulti(items: [DragItem])
        case trimVideoLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimVideoRight(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimImageLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimImageRight(id: UUID, originStart: Double, originEnd: Double)
        case trimAudioLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimAudioRight(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double, assetDur: Double)
        case trimSubtitleLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleRight(id: UUID, originStart: Double, originEnd: Double)
        case movingPlayhead
        case resizeTrack(TrackKind)
        case box
        case ignored
    }

    struct DragItem {
        enum Kind { case video, image, audio, subtitle }
        let id: UUID
        let kind: Kind
        let originStart: Double
        let originDur: Double
    }

    private enum ClipHit {
        case video(id: UUID, start: Double, dur: Double)
        case image(id: UUID, start: Double, dur: Double)
        case audio(id: UUID, start: Double, dur: Double)
        case subtitle(id: UUID, start: Double, dur: Double)

        var id: UUID {
            switch self {
            case .video(let id, _, _), .image(let id, _, _), .audio(let id, _, _), .subtitle(let id, _, _):
                return id
            }
        }
        var start: Double {
            switch self {
            case .video(_, let s, _), .image(_, let s, _), .audio(_, let s, _), .subtitle(_, let s, _):
                return s
            }
        }
        var duration: Double {
            switch self {
            case .video(_, _, let d), .image(_, _, let d), .audio(_, _, let d), .subtitle(_, _, let d):
                return d
            }
        }
    }

    private enum TrackKind: Equatable { case image(Int), video(Int), audio(Int), subtitle(Int) }
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
        .overlay(alignment: .bottomTrailing) {
            if project.translationTotal > 0 {
                TranslationProgressBubble()
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.translationTotal)
        .onAppear { setupMonitors() }
        .onDisappear { teardownMonitors() }
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
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
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

        // Command + scroll wheel → zoom timeline (pixelsPerSecond)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(delta) > 0 else { return event }
            DispatchQueue.main.async {
                let factor = delta > 0 ? 1.08 : 1.0 / 1.08
                project.pixelsPerSecond = (project.pixelsPerSecond * Double(factor))
                    .clamped(to: project.minPixelsPerSecond...3000)
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
                Button("添加图片轨道") { project.imageTracks.append(Track(label: "图片")) }
                Button("添加音频轨道") { project.audioTracks.append(Track(label: "音频")) }
                Button("添加字幕轨道") {
                    project.subtitleTracks.append(Track(label: "字幕"))
                    project.subtitleStyles.append(SubtitleStyle())
                }
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
            if project.showImageTracks {
                ForEach(project.imageTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"photo", title: project.imageTracks[i].label,
                               count: project.imageTracks[i].clips.count, hasMute: false,
                               isMuted: false, isVis: project.imageTracks[i].isVisible,
                               onMute: nil,
                               onVis:  { project.pushUndo(); project.imageTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                               onDel:  { project.pushUndo(); project.imageTracks.remove(at:i); project.rebuildTimelinePreview() })
                        .frame(height: imgH(i))
                }
            }
            if project.showVideoTracks {
                ForEach(project.videoTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"film", title: project.videoTracks[i].label,
                               count: project.videoTracks[i].clips.count, hasMute: true,
                               isMuted: project.videoTracks[i].isMuted, isVis: project.videoTracks[i].isVisible,
                               onMute: { project.pushUndo(); project.videoTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  { project.pushUndo(); project.videoTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                               onDel:  { project.pushUndo(); project.videoTracks.remove(at:i); project.rebuildTimelinePreview() })
                        .frame(height: vidH(i))
                }
            }
            if project.showAudioTracks {
                ForEach(project.audioTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"music.note", title: project.audioTracks[i].label,
                               count: project.audioTracks[i].clips.count, hasMute: true,
                               isMuted: project.audioTracks[i].isMuted, isVis: true, hasVis: false,
                               onMute: { project.pushUndo(); project.audioTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  {},
                               onDel:  { project.pushUndo(); project.audioTracks.remove(at:i); project.rebuildTimelinePreview() })
                        .frame(height: audH(i))
                }
            }
            if project.showSubtitleTracks {
                ForEach(project.subtitleTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"text.bubble", title: project.subtitleTracks[i].label,
                               count: project.subtitleTracks[i].clips.count, hasMute: false,
                               isMuted: false, isVis: project.subtitleTracks[i].isVisible,
                               onMute: nil,
                               onVis:  { project.pushUndo(); project.subtitleTracks[i].isVisible.toggle() },
                               onDel:  { project.pushUndo(); project.subtitleTracks.remove(at:i); project.rebuildTimelinePreview() })
                        .frame(height: subH(i))
                }
            }
            } // end inner VStack
        }
        .frame(width: labelW)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red:0.09,green:0.09,blue:0.10))
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
            let contentW = project.duration * project.pixelsPerSecond + 300
            let totalW = max(contentW, max(visibleW, 800))
            let effectiveH = max(totalContentH(), viewportH)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    TimelineRuler(pps: project.pixelsPerSecond, duration: project.duration)
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
                }
                .frame(width: totalW, alignment: .topLeading)
                .frame(minHeight: effectiveH)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard dragOp == nil else { return }
                    switch phase {
                    case .active(let loc):
                        if trackGapHit(y: loc.y) != nil {
                            NSCursor.resizeUpDown.set()
                        } else if let edge = findClipTarget(at: loc)?.trimEdge {
                            (edge == .left ? Self.trimLeftCursor : Self.trimRightCursor).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    case .ended:
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
            .scrollClipDisabled(true)
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
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle:
                    dragGhostPos = CGPoint(x: v.location.x - dragGhostOffset.width,
                                           y: v.location.y - dragGhostOffset.height)
                default: break
                }
                applyDrag(op: op, totalTranslation: v.translation, current: v.location)
            }
            .onEnded { v in
                // 点击（没有拖动）→ 选中clip或取消选择
                if dragOp == nil && v.startLocation.y >= rulerH {
                    let isShift = NSEvent.modifierFlags.contains(.shift)
                    if let (hit, _) = findClipTarget(at: v.startLocation) {
                        if isShift {
                            switch hit {
                            case .video(let id, _, _), .image(let id, _, _),
                                 .audio(let id, _, _), .subtitle(let id, _, _):
                                project.shiftToggleClip(id)
                            }
                        } else {
                            project.selectedClipIDs.removeAll()
                            switch hit {
                            case .video(let id, _, _):
                                project.selectedVideoClipID = id
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                            case .image(let id, _, _):
                                project.selectedImageClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedAudioClipID = nil
                                project.selectedSubtitleClipID = nil
                            case .audio(let id, _, _):
                                project.selectedAudioClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedSubtitleClipID = nil
                            case .subtitle(let id, _, _):
                                project.selectedSubtitleClipID = id
                                project.selectedVideoClipID = nil
                                project.selectedImageClipID = nil
                                project.selectedAudioClipID = nil
                            }
                        }
                    } else {
                        project.selectedClipIDs.removeAll()
                        project.selectedVideoClipID    = nil
                        project.selectedImageClipID    = nil
                        project.selectedAudioClipID    = nil
                        project.selectedSubtitleClipID = nil
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
                    case .moveMulti(let items):
                        for it in items {
                            switch it.kind {
                            case .video:    project.resolveVideoOverlap(id: it.id)
                            case .image:    project.resolveImageOverlap(id: it.id)
                            case .audio:    project.resolveAudioOverlap(id: it.id)
                            case .subtitle: project.resolveSubtitleOverlap(id: it.id)
                            }
                        }
                    default: break
                    }
                }

                switch dragOp {
                case .trimVideoLeft, .trimVideoRight,
                     .trimImageLeft, .trimImageRight,
                     .trimAudioLeft, .trimAudioRight,
                     .trimSubtitleLeft, .trimSubtitleRight:
                    NSCursor.arrow.set()
                    project.rebuildTimelinePreview()
                case .moveVideo, .moveImage, .moveAudio, .moveSubtitle, .moveMulti:
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
        let playheadX = project.currentTime * project.pixelsPerSecond
        // Dragging anywhere on the playhead stem (±10 px) moves the playhead.
        if abs(pt.x - playheadX) < 10 { dragOp = .movingPlayhead; return }

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
                let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveImage(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.image(let id, let s, let d), .left):
                project.selectedImageClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimImageLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.image(let id, let s, let d), .right):
                project.selectedImageClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimImageRight(id: id, originStart: s, originEnd: s + d)
                Self.trimRightCursor.set()
            case (.audio(let id, let s, let d), nil):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveAudio(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.audio(let id, let s, let d), .left):
                let ts = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                let aClip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })
                let ad = project.mediaAssets.first(where: { $0.id == aClip?.assetID })?.duration ?? Double.infinity
                dragOp = .trimAudioLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts, assetDur: ad)
                Self.trimLeftCursor.set()
            case (.audio(let id, let s, let d), .right):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
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
                let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
                draggingClipID = id
                dragOp = .moveSubtitle(id: id, originStart: s, originDur: d, srcTrack: ti)
            case (.subtitle(let id, let s, let d), .left):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                dragOp = .trimSubtitleLeft(id: id, originStart: s, originEnd: s + d)
                Self.trimLeftCursor.set()
            case (.subtitle(let id, let s, let d), .right):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedAudioClipID    = nil
                dragOp = .trimSubtitleRight(id: id, originStart: s, originEnd: s + d)
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
        }
    }

    private func selectVideoAndLoad(id: UUID) {
        project.selectedVideoClipID    = id
        project.selectedImageClipID    = nil
        project.selectedAudioClipID    = nil
        project.selectedSubtitleClipID = nil
        if let clip = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            project.loadClipForPreview(clip)
        }
    }

    private func collectMultiDragItems() -> [DragItem] {
        var items: [DragItem] = []
        for id in project.selectedClipIDs {
            for t in project.videoTracks {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .video,
                                          originStart: c.startTime, originDur: c.duration))
                }
            }
            for t in project.imageTracks {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .image,
                                          originStart: c.startTime, originDur: c.duration))
                }
            }
            for t in project.audioTracks {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .audio,
                                          originStart: c.startTime, originDur: c.duration))
                }
            }
            for t in project.subtitleTracks {
                if let c = t.clips.first(where: { $0.id == id }) {
                    items.append(DragItem(id: id, kind: .subtitle,
                                          originStart: c.startTime, originDur: c.duration))
                }
            }
        }
        return items
    }

    /// 收集所有片段的起止时间作为吸附点（排除指定 ID）
    private func collectSnapPoints(excluding ids: Set<UUID>) -> [Double] {
        var pts: [Double] = [0, project.currentTime] // 轨道起始位置 + 播放头
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
        case .moveMulti(let items):
            let minOrig = items.map(\.originStart).min() ?? 0
            let clampedDt = max(dt, -minOrig)
            let excludeIDs = Set(items.map(\.id))
            // 遍历所有选中片段的起点和终点，找最近的吸附点
            let pts = collectSnapPoints(excluding: excludeIDs)
            let threshold = 8.0 / project.pixelsPerSecond
            var bestDelta = 0.0
            var bestDist = Double.infinity
            var bestSnap: Double? = nil
            for it in items {
                let rawS = it.originStart + clampedDt
                let rawE = rawS + it.originDur
                for p in pts {
                    let ds = abs(rawS - p)
                    if ds < threshold && ds < bestDist { bestDist = ds; bestDelta = p - rawS; bestSnap = p }
                    let de = abs(rawE - p)
                    if de < threshold && de < bestDist { bestDist = de; bestDelta = p - rawE; bestSnap = p }
                }
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
            if ne > project.duration { project.duration = ne }
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
            if ne > project.duration { project.duration = ne }
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
            if ne > project.duration { project.duration = ne }
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
            if ne > project.duration { project.duration = ne }
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
                }
            }
            let newH = (dragOriginTrackH + totalTranslation.height).clamped(to: 28...120)
            switch kind {
            case .image(let i):    imageTrackHeights[i] = newH
            case .video(let i):    videoTrackHeights[i] = newH
            case .audio(let i):    audioTrackHeights[i] = newH
            case .subtitle(let i): subtitleTrackHeights[i] = newH
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
    private func findClipTarget(at pt: CGPoint) -> (hit: ClipHit, trimEdge: ClipTrimEdge?)? {
        guard pt.y >= rulerH else { return nil }
        let pps = project.pixelsPerSecond
        let threshold: CGFloat = 8
        var rowTop: CGFloat = rulerH
        var first = true

        func edge(x: CGFloat, xMin: CGFloat, xMax: CGFloat) -> ClipTrimEdge? {
            guard xMax - xMin >= 20 else { return nil }
            if abs(x - xMin) <= threshold { return .left }
            if abs(x - xMax) <= threshold { return .right }
            return nil
        }

        if project.showImageTracks {
            for ti in project.imageTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = imgH(ti)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    for c in project.imageTracks[ti].clips {
                        let xMin = CGFloat(c.startTime * pps) + 1
                        let xMax = CGFloat(c.endTime   * pps) + 1
                        if pt.x >= xMin - threshold && pt.x <= xMax + threshold {
                            let hit = ClipHit.image(id: c.id, start: c.startTime, dur: c.duration)
                            return (hit, edge(x: pt.x, xMin: xMin, xMax: xMax))
                        }
                    }
                    return nil
                }
                rowTop += h
            }
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = vidH(ti)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    for c in project.videoTracks[ti].clips {
                        let xMin = CGFloat(c.startTime * pps) + 1
                        let xMax = CGFloat(c.endTime   * pps) + 1
                        if pt.x >= xMin - threshold && pt.x <= xMax + threshold {
                            let hit = ClipHit.video(id: c.id, start: c.startTime, dur: c.duration)
                            return (hit, edge(x: pt.x, xMin: xMin, xMax: xMax))
                        }
                    }
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
                    for c in project.audioTracks[ti].clips {
                        let xMin = CGFloat(c.startTime * pps) + 1
                        let xMax = CGFloat(c.endTime   * pps) + 1
                        if pt.x >= xMin - threshold && pt.x <= xMax + threshold {
                            let hit = ClipHit.audio(id: c.id, start: c.startTime, dur: c.duration)
                            return (hit, edge(x: pt.x, xMin: xMin, xMax: xMax))
                        }
                    }
                    return nil
                }
                rowTop += h
            }
        }
        if project.showSubtitleTracks {
            for ti in project.subtitleTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = subH(ti)
                if pt.y >= rowTop && pt.y < rowTop + h {
                    for c in project.subtitleTracks[ti].clips {
                        let xMin = CGFloat(c.startTime * pps) + 1
                        let xMax = CGFloat(c.endTime   * pps) + 1
                        if pt.x >= xMin - threshold && pt.x <= xMax + threshold {
                            let hit = ClipHit.subtitle(id: c.id, start: c.startTime, dur: c.duration)
                            return (hit, edge(x: pt.x, xMin: xMin, xMax: xMax))
                        }
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

        if project.showImageTracks {
            for ti in project.imageTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = imgH(ti)
                let yRange = rowTop ... (rowTop + h)
                for c in project.imageTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += h
            }
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = vidH(ti)
                let yRange = rowTop ... (rowTop + h)
                for c in project.videoTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
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
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += h
            }
        }
        if project.showSubtitleTracks {
            for ti in project.subtitleTracks.indices {
                if !first { rowTop += 1 }; first = false
                let h = subH(ti)
                let yRange = rowTop ... (rowTop + h)
                for c in project.subtitleTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
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
        if project.showImageTracks {
            for i in project.imageTracks.indices {
                if !first { top += 1 }; first = false
                top += imgH(i)
                if abs(y - top) <= threshold { return .image(i) }
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
        if project.showSubtitleTracks {
            for i in project.subtitleTracks.indices {
                if !first { top += 1 }; first = false
                top += subH(i)
                if abs(y - top) <= threshold { return .subtitle(i) }
            }
        }
        return nil
    }

    private func totalContentH() -> CGFloat {
        var h = rulerH
        var trackCount = 0
        if project.showImageTracks    { for i in project.imageTracks.indices    { h += imgH(i) }; trackCount += project.imageTracks.count }
        if project.showVideoTracks    { for i in project.videoTracks.indices    { h += vidH(i) }; trackCount += project.videoTracks.count }
        if project.showAudioTracks    { for i in project.audioTracks.indices    { h += audH(i) }; trackCount += project.audioTracks.count }
        if project.showSubtitleTracks { for i in project.subtitleTracks.indices { h += subH(i) }; trackCount += project.subtitleTracks.count }
        if trackCount > 1 { h += CGFloat(trackCount - 1) } // 1px gaps
        return h
    }

    private var trackRows: some View {
        VStack(spacing: 1) {
        if project.showImageTracks {
            ForEach(project.imageTracks.indices, id:\.self) { i in
                trackRow(height: imgH(i), hidden: !project.imageTracks[i].isVisible, tint: Color(hex: "#E8A54B")) {
                    ForEach(project.imageTracks[i].clips) { clip in
                        ImageClipView(clip: clip, pps: project.pixelsPerSecond, h: imgH(i),
                                      sel: isSelected(clip.id, primary: project.selectedImageClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showVideoTracks {
            ForEach(project.videoTracks.indices, id:\.self) { i in
                trackRow(height: vidH(i), hidden: !project.videoTracks[i].isVisible, tint: Color(hex: "#3DBFBA")) {
                    ForEach(project.videoTracks[i].clips) { clip in
                        VideoClipView(clip: clip, pps: project.pixelsPerSecond, h: vidH(i),
                                      sel: isSelected(clip.id, primary: project.selectedVideoClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showAudioTracks {
            ForEach(project.audioTracks.indices, id:\.self) { i in
                trackRow(height: audH(i), hidden: !project.audioTracks[i].isVisible, muted: project.audioTracks[i].isMuted, tint: Color(hex: "#5DB85D")) {
                    ForEach(project.audioTracks[i].clips) { clip in
                        AudioClipView(clip: clip, pps: project.pixelsPerSecond, h: audH(i),
                                      sel: isSelected(clip.id, primary: project.selectedAudioClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showSubtitleTracks {
            ForEach(project.subtitleTracks.indices, id:\.self) { i in
                trackRow(height: subH(i), hidden: !project.subtitleTracks[i].isVisible, tint: Color(hex: "#7B6FC4")) {
                    ForEach(project.subtitleTracks[i].clips) { clip in
                        SubtitleClipView(clip: clip, pps: project.pixelsPerSecond, h: subH(i),
                                         sel: isSelected(clip.id, primary: project.selectedSubtitleClipID),
                                         isDragging: draggingClipID == clip.id)
                    }
                }
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
    }

    private func trackRowForClip(_ hit: ClipHit) -> Int {
        let iCount = project.imageTracks.count
        let vCount = project.videoTracks.count
        let aCount = project.audioTracks.count
        switch hit {
        case .image(let id, _, _):
            let ti = project.imageTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return ti
        case .video(let id, _, _):
            let ti = project.videoTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return iCount + ti
        case .audio(let id, _, _):
            let ti = project.audioTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return iCount + vCount + ti
        case .subtitle(let id, _, _):
            let ti = project.subtitleTracks.firstIndex { $0.clips.contains { $0.id == id } } ?? 0
            return iCount + vCount + aCount + ti
        }
    }

    private func trackCenterY(row: Int) -> CGFloat {
        let iCount = project.showImageTracks ? project.imageTracks.count : 0
        let vCount = project.showVideoTracks ? project.videoTracks.count : 0
        let aCount = project.showAudioTracks ? project.audioTracks.count : 0
        var top = rulerH
        for r in 0..<row {
            if r > 0 { top += 1 } // 1px gap
            if r < iCount { top += imgH(r) }
            else if r < iCount + vCount { top += vidH(r - iCount) }
            else if r < iCount + vCount + aCount { top += audH(r - iCount - vCount) }
            else { top += subH(r - iCount - vCount - aCount) }
        }
        if row > 0 { top += 1 }
        let h: CGFloat
        if row < iCount { h = imgH(row) }
        else if row < iCount + vCount { h = vidH(row - iCount) }
        else if row < iCount + vCount + aCount { h = audH(row - iCount - vCount) }
        else { h = subH(row - iCount - vCount - aCount) }
        return top + h / 2
    }

    private func trackIndexFromY(_ y: CGFloat) -> TrackTarget {
        var top = rulerH
        var first = true
        if project.showImageTracks {
            for i in project.imageTracks.indices {
                if !first { top += 1 }; first = false
                let h = imgH(i)
                if y < top + h { return TrackTarget(imageIndex: i) }
                top += h
            }
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
        if project.showSubtitleTracks {
            for i in project.subtitleTracks.indices {
                if !first { top += 1 }; first = false
                let h = subH(i)
                if y < top + h { return TrackTarget(subtitleIndex: i) }
                top += h
            }
        }
        return TrackTarget()
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

// MARK: - Track Label

private struct TrackLabel: View {
    let icon: String; let title: String; let count: Int
    let hasMute: Bool; let isMuted: Bool; let isVis: Bool
    var hasVis: Bool = true
    let onMute: (() -> Void)?
    let onVis: () -> Void; let onDel: () -> Void

    @State private var isHovered = false

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
            .padding(.horizontal, 8)
            .opacity(isHovered ? 0 : 1)

            // hover 时：操作按钮（提亮背景 + 按钮浮层）
            if isHovered {
                Color.white.opacity(0.06)

                HStack(spacing: 3) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.white.opacity(isHovered ? 0.08 : 0), lineWidth: 0.5)
        )
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
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hov ? Color.white.opacity(0.16) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(hov ? 0.15 : 0.05), lineWidth: 0.5)
                )
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
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment:.leading) {
            // Thumbnail strip or solid color
            if let frames = project.assetThumbnails[clip.assetID], !frames.isEmpty {
                thumbnailStrip(frames: frames, clipWidth: w)
            } else {
                RoundedRectangle(cornerRadius:4).fill(Color(hex:"#3DBFBA").opacity(0.82))
            }
            // Selection border
            RoundedRectangle(cornerRadius:4)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            // Name label top-left with shadow
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, 5)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceID == clip.id ? 0.35 : 1.0))
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
        let thumbW = thumbH * ratio
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let t = clip.trimStart + clip.duration * Double(i) / Double(count)
                let frame = closestFrame(frames, at: t)
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: i == count - 1 ? clipWidth - thumbW * CGFloat(count - 1) : thumbW,
                           height: thumbH)
                    .clipped()
            }
        }
        .frame(width: clipWidth, height: thumbH)
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment:.leading) {
            // Thumbnail or solid color
            if let thumb = project.mediaThumbnails[clip.assetID] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h - 4)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius:4).fill(Color(hex:"#E8A54B").opacity(0.82))
            }
            RoundedRectangle(cornerRadius:4)
                .stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, 5)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceID == clip.id ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
        .contextMenu {
            Button { project.selectLeftOf(clip.id) } label: { Label("向左全选", systemImage: "arrow.left.to.line") }
            Button { project.selectRightOf(clip.id) } label: { Label("向右全选", systemImage: "arrow.right.to.line") }
            Divider()
            Button { project.copySelected() } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { project.cutSelected() } label: { Label("剪切", systemImage: "scissors") }
            Button { project.pasteAtPlayhead() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
            Divider()
            Button(role: .destructive) { project.deleteSelected() } label: { Label("删除", systemImage: "trash") }
        }
    }
}

private struct AudioClipView: View {
    let clip: AudioClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    var isDragging: Bool = false
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius:4).fill(Color(hex:"#5DB85D").opacity(0.78))
            // Waveform overlay — full height
            if let wave = project.waveformCache[clip.assetID] {
                AudioWaveformCanvas(waveData: wave, trimStart: clip.trimStart,
                                     clipDuration: clip.duration, fullHeight: true)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            // Selection border
            RoundedRectangle(cornerRadius:4).stroke(sel ? Color.white : Color.clear, lineWidth: sel ? 2 : 0)
            // Name top-left with light shadow
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, 5)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: w, height: h-4)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceID == clip.id ? 0.35 : 1.0))
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

    var body: some View {
        Canvas { ctx, size in
            guard waveData.totalDuration > 0, !waveData.samples.isEmpty else { return }
            let startFrac = trimStart / waveData.totalDuration
            let endFrac   = (trimStart + clipDuration) / waveData.totalDuration
            let startIdx  = Int(startFrac * Double(waveData.samples.count))
            let endIdx    = min(Int(endFrac * Double(waveData.samples.count)), waveData.samples.count)
            guard startIdx < endIdx else { return }

            let visible = Array(waveData.samples[startIdx..<endIdx])
            let barCount = Int(size.width)
            guard barCount > 0 else { return }

            if fullHeight {
                // Normalize: find max peak in visible range so waveform fills height
                let maxPeak = max(visible.max() ?? 1, 0.01)
                // Bars grow from bottom, full height
                for x in 0..<barCount {
                    let sIdx = x * visible.count / barCount
                    let eIdx = min(sIdx + max(1, visible.count / barCount), visible.count)
                    guard sIdx < eIdx else { continue }
                    let peak = (visible[sIdx..<eIdx].max() ?? 0) / maxPeak  // normalized 0..1
                    let barH = max(1, CGFloat(peak) * size.height)
                    let rect = CGRect(x: CGFloat(x), y: size.height - barH,
                                      width: 1, height: barH)
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.30)))
                }
            } else {
                // Centered waveform
                let midY = size.height / 2
                for x in 0..<barCount {
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
    @EnvironmentObject var project: ProjectState
    @State private var breathing = false

    private var isPlaceholder: Bool {
        project.placeholderClipIDs.contains(clip.id)
    }

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:3)
                .fill(Color(hex:"#7B6FC4").opacity(isPlaceholder ? 0.35 : 0.85))
                .overlay(RoundedRectangle(cornerRadius:3)
                    .stroke(sel ? Color.white : Color(hex:"#9B8FD4").opacity(0.4), lineWidth: sel ? 2 : 1))
            if !isPlaceholder && w > 16 {
                Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                    .font(.system(size:8, weight:.medium))
                    .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 : isPlaceholder ? (breathing ? 0.7 : 0.3) :
                 (project.clipboardIsCut && project.clipboardSourceID == clip.id ? 0.35 : 1.0))
        .animation(isPlaceholder ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: breathing)
        .onAppear { if isPlaceholder { breathing = true } }
        .onChange(of: isPlaceholder) { ph in breathing = ph }
        .offset(x: clip.startTime*pps + 1)
        .allowsHitTesting(false)
    }
}

// MARK: - Ruler

private struct TimelineRuler: View {
    let pps: Double; let duration: Double
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
            let maxTime = max(duration, size.width / pps) + majorStep

            var t = 0.0
            while t <= maxTime {
                let x = t * pps
                // 判断是否是主刻度（容差处理浮点精度）
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
    let pps: Double
    let fullHeight: CGFloat

    var body: some View {
        let x = project.currentTime * pps
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: x,   y: 16))
                p.addLine(to: CGPoint(x: x-5, y: 6))
                p.addLine(to: CGPoint(x: x+5, y: 6))
                p.closeSubpath()
            }.fill(Color.accent)
            Rectangle().fill(Color.accent.opacity(0.7))
                .frame(width: 1, height: fullHeight - 16)
                .offset(x: x - 0.5, y: 16)
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
        Slider(value: logValue, in: log(range.lowerBound)...log(range.upperBound))
            .accentColor(Color.accent)
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @EnvironmentObject private var project: ProjectState
    private var hasSelection: Bool {
        project.selectedVideoClipID != nil || project.selectedImageClipID != nil ||
        project.selectedAudioClipID != nil || project.selectedSubtitleClipID != nil ||
        !project.selectedClipIDs.isEmpty
    }
    var body: some View {
        HStack(spacing:0) {
            // 左侧：编辑工具
            HStack(spacing:2) {
                TBtn(icon:"arrow.uturn.backward", help:"撤销", enabled: project.undoCount > 0) { project.undo() }
                TBtn(icon:"arrow.uturn.forward",  help:"重做", enabled: project.redoCount > 0) { project.redo() }
                Divider().frame(height:16).padding(.horizontal,4)
                TBtn(icon:"scissors",         help:"在播放头分割片段", enabled: hasSelection && project.selectedImageClipID == nil) { project.splitAtPlayhead() }
                TBtn(icon:"trash",            help:"删除选中片段", enabled: hasSelection)   { project.deleteSelected() }
                TBtn(icon:"text.alignleft",   help:"将选中片段对齐到播放头", enabled: hasSelection) { project.alignSelectedToPlayhead() }
                TBtn(icon:"character.bubble", help:"在当前字幕轨道插入字幕")  { project.insertSubtitleAtPlayhead() }

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
                TBtn(icon:"minus.magnifyingglass", help:"缩小") { project.pixelsPerSecond = max(project.minPixelsPerSecond, project.pixelsPerSecond/1.5) }
                LogSlider(value: $project.pixelsPerSecond, range: project.minPixelsPerSecond...3000).frame(width:100).help("时间轴缩放")
                TBtn(icon:"plus.magnifyingglass", help:"放大")  { project.pixelsPerSecond = min(3000, project.pixelsPerSecond*1.5) }
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

            TBtn(icon: "translate", help: "翻译当前字幕",
                 enabled: project.selectedSubtitleClip != nil) { translateCurrent() }
            TBtn(icon: "list.bullet.rectangle", help: "翻译整条轨道",
                 enabled: translateAllEnabled) { translateAll() }
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
    private func createTranslationTrack(after srcIdx: Int) -> Int {
        let lang = shortLang(project.translationTargetLang)
        let newTrack = Track<SubtitleClip>(label: "字幕(\(lang))")
        let insertIdx = srcIdx + 1
        project.subtitleTracks.insert(newTrack, at: insertIdx)
        project.subtitleStyles.insert(SubtitleStyle(), at: min(insertIdx, project.subtitleStyles.count))
        return insertIdx
    }

    private func translateCurrent() {
        guard let clip = project.selectedSubtitleClip,
              let srcIdx = sourceTrackIndex() else { return }
        let lang = project.translationTargetLang
        project.pushUndo()
        let destIdx = createTranslationTrack(after: srcIdx)

        // 插入占位字幕
        let placeholder = SubtitleClip(text: "", startTime: clip.startTime, endTime: clip.endTime)
        project.subtitleTracks[destIdx].clips.append(placeholder)
        project.placeholderClipIDs.insert(placeholder.id)
        project.translatingTrackIndices.insert(destIdx)
        project.translationTotal = 1
        project.translationDone = 0
        project.translationProgress = 0

        Task {
            let translated = await Translator.translateSmart(clip.text, to: lang)
            await MainActor.run {
                if let ci = project.subtitleTracks[destIdx].clips.firstIndex(where: { $0.id == placeholder.id }) {
                    project.subtitleTracks[destIdx].clips[ci] = SubtitleClip(
                        text: translated, startTime: clip.startTime, endTime: clip.endTime)
                }
                project.placeholderClipIDs.remove(placeholder.id)
                project.translatingTrackIndices.remove(destIdx)
                project.translationDone = 1
                project.translationProgress = 1
                // 延迟清除进度
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if project.translatingTrackIndices.isEmpty {
                        project.translationTotal = 0
                        project.translationDone = 0
                        project.translationProgress = 0
                    }
                }
            }
        }
    }

    private func translateAll() {
        guard let srcIdx = sourceTrackIndex() else { return }
        let lang = project.translationTargetLang
        let originals = project.subtitleTracks[srcIdx].clips
        guard !originals.isEmpty else { return }
        project.pushUndo()
        let destIdx = createTranslationTrack(after: srcIdx)

        // 插入所有占位字幕
        var placeholders: [SubtitleClip] = []
        for c in originals {
            let ph = SubtitleClip(text: "", startTime: c.startTime, endTime: c.endTime)
            placeholders.append(ph)
            project.placeholderClipIDs.insert(ph.id)
        }
        project.subtitleTracks[destIdx].clips = placeholders
        project.translatingTrackIndices.insert(destIdx)
        project.translationTotal = originals.count
        project.translationDone = 0
        project.translationProgress = 0

        Task {
            for (i, c) in originals.enumerated() {
                let t = await Translator.translateSmart(c.text, to: lang)
                await MainActor.run {
                    let phID = placeholders[i].id
                    if let ci = project.subtitleTracks[destIdx].clips.firstIndex(where: { $0.id == phID }) {
                        project.subtitleTracks[destIdx].clips[ci] = SubtitleClip(
                            text: t, startTime: c.startTime, endTime: c.endTime)
                    }
                    project.placeholderClipIDs.remove(phID)
                    project.translationDone = i + 1
                    project.translationProgress = Double(i + 1) / Double(originals.count)
                }
            }
            await MainActor.run {
                project.translatingTrackIndices.remove(destIdx)
                // 延迟清除进度
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if project.translatingTrackIndices.isEmpty {
                        project.translationTotal = 0
                        project.translationDone = 0
                        project.translationProgress = 0
                    }
                }
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
