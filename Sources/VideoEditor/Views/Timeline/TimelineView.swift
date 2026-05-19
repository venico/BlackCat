import SwiftUI
import AVFoundation

// MARK: - Timeline root

struct TimelineView: View {
    @EnvironmentObject private var project: ProjectState
    private let labelW: CGFloat = 84
    private let trackH: CGFloat = 52
    private let subtitleTrackH: CGFloat = 28
    private let rulerH: CGFloat = 26

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
        case trimVideoLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double)
        case trimVideoRight(id: UUID, originStart: Double, originEnd: Double)
        case trimImageLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimImageRight(id: UUID, originStart: Double, originEnd: Double)
        case trimAudioLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double)
        case trimAudioRight(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleRight(id: UUID, originStart: Double, originEnd: Double)
        case movingPlayhead
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
        GeometryReader { outerGeo in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    labelColumn
                    clipArea
                }
                .frame(minHeight: outerGeo.size.height)
            }
        }
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

            // ⌫ or ⌦ → 删除
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
                    .clamped(to: 2...150)
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

            if project.showImageTracks {
                ForEach(project.imageTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"photo", title: project.imageTracks[i].label,
                               count: project.imageTracks[i].clips.count, hasMute: false,
                               isMuted: false, isVis: project.imageTracks[i].isVisible,
                               onMute: nil,
                               onVis:  { project.imageTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                               onDel:  { project.imageTracks.remove(at:i) })
                        .frame(height: trackH)
                }
            }
            if project.showVideoTracks {
                ForEach(project.videoTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"film", title: project.videoTracks[i].label,
                               count: project.videoTracks[i].clips.count, hasMute: true,
                               isMuted: project.videoTracks[i].isMuted, isVis: project.videoTracks[i].isVisible,
                               onMute: { project.videoTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  { project.videoTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                               onDel:  { project.videoTracks.remove(at:i) })
                        .frame(height: trackH)
                }
            }
            if project.showAudioTracks {
                ForEach(project.audioTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"music.note", title: project.audioTracks[i].label,
                               count: project.audioTracks[i].clips.count, hasMute: true,
                               isMuted: project.audioTracks[i].isMuted, isVis: true, hasVis: false,
                               onMute: { project.audioTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                               onVis:  {},
                               onDel:  { project.audioTracks.remove(at:i) })
                        .frame(height: trackH)
                }
            }
            if project.showSubtitleTracks {
                ForEach(project.subtitleTracks.indices, id:\.self) { i in
                    TrackLabel(icon:"text.bubble", title: project.subtitleTracks[i].label,
                               count: project.subtitleTracks[i].clips.count, hasMute: false,
                               isMuted: false, isVis: project.subtitleTracks[i].isVisible,
                               onMute: nil,
                               onVis:  { project.subtitleTracks[i].isVisible.toggle() },
                               onDel:  { project.subtitleTracks.remove(at:i) })
                        .frame(height: subtitleTrackH)
                }
            }
        }
        .frame(width: labelW)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red:0.09,green:0.09,blue:0.10))
    }

    // MARK: Clip scroll area

    private var clipArea: some View {
        let totalW = max(project.duration * project.pixelsPerSecond + 300, 800)
        return ScrollView(.horizontal, showsIndicators: false) {
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

                    // 吸附指示线
                    if let snapT = activeSnapTime {
                        let snapX = snapT * project.pixelsPerSecond
                        Rectangle()
                            .fill(Color.accent)
                            .frame(width: 1)
                            .position(x: snapX, y: totalContentH() / 2)
                            .frame(height: totalContentH())
                            .allowsHitTesting(false)
                    }

                    DraggablePlayhead(pps: project.pixelsPerSecond)
                }
                .frame(width: totalW, alignment: .topLeading)
                .frame(minHeight: totalContentH())
                .contentShape(Rectangle())
                // Single tap on empty track area (below ruler, not on a clip) → seek.
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let loc = value.location
                            guard loc.y >= rulerH else { return }
                            guard findClipTarget(at: loc) == nil else { return }
                            let t = (loc.x / project.pixelsPerSecond)
                                .clamped(to: 0...project.duration)
                            project.requestSeek(to: t)
                        }
                )
                .onContinuousHover { phase in
                    guard dragOp == nil else { return }
                    switch phase {
                    case .active(let loc):
                        if let edge = findClipTarget(at: loc)?.trimEdge {
                            (edge == .left ? Self.trimLeftCursor : Self.trimRightCursor).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
                .simultaneousGesture(unifiedDragGesture)
            }
            .scrollClipDisabled(true)
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
                // 点击空白处（没有拖动）→ 取消所有选择
                if dragOp == nil && v.startLocation.y >= rulerH {
                    if findClipTarget(at: v.startLocation) == nil {
                        project.selectedClipIDs.removeAll()
                        project.selectedVideoClipID    = nil
                        project.selectedImageClipID    = nil
                        project.selectedAudioClipID    = nil
                        project.selectedSubtitleClipID = nil
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
                    case .moveVideo(let id, _, _, _), .trimVideoLeft(let id, _, _, _), .trimVideoRight(let id, _, _):
                        project.resolveVideoOverlap(id: id)
                    case .moveImage(let id, _, _, _), .trimImageLeft(let id, _, _), .trimImageRight(let id, _, _):
                        project.resolveImageOverlap(id: id)
                    case .moveAudio(let id, _, _, _), .trimAudioLeft(let id, _, _, _), .trimAudioRight(let id, _, _):
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
                let ts = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts)
                Self.trimLeftCursor.set()
            case (.video(let id, let s, let d), .right):
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoRight(id: id, originStart: s, originEnd: s + d)
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
                dragOp = .trimAudioLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts)
                Self.trimLeftCursor.set()
            case (.audio(let id, let s, let d), .right):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedImageClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimAudioRight(id: id, originStart: s, originEnd: s + d)
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
        var pts: [Double] = [0] // 轨道起始位置
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
            // 用第一个 item 做吸附计算
            let firstRaw = (items.first?.originStart ?? 0) + clampedDt
            let firstDur = items.first?.originDur ?? 0
            let (snapped, sp) = snapStart(firstRaw, duration: firstDur, excluding: excludeIDs)
            activeSnapTime = sp
            let snapDelta = snapped - firstRaw
            for it in items {
                let ns = it.originStart + clampedDt + snapDelta
                let ne = ns + it.originDur
                switch it.kind {
                case .video:    project.updateVideoClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .image:    project.updateImageClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .audio:    project.updateAudioClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .subtitle: project.updateSubtitleTime(id: it.id, start: ns, end: ne)
                }
            }
        case .trimVideoLeft(let id, let originStart, let originEnd, let originTrimStart):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateVideoClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimVideoRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
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
        case .trimAudioLeft(let id, let originStart, let originEnd, let originTrimStart):
            var ns = max(0, min(originStart + dt, originEnd - 0.1))
            let (snapped, sp) = snapEdge(ns, excluding: [id])
            ns = snapped; activeSnapTime = sp
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateAudioClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimAudioRight(let id, let originStart, let originEnd):
            var ne = max(originStart + 0.1, originEnd + dt)
            let (snapped, sp) = snapEdge(ne, excluding: [id])
            ne = snapped; activeSnapTime = sp
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
            let t = (Double(current.x) / pps).clamped(to: 0...project.duration)
            project.requestSeek(to: t)
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

        func edge(x: CGFloat, xMin: CGFloat, xMax: CGFloat) -> ClipTrimEdge? {
            guard xMax - xMin >= 20 else { return nil }
            if abs(x - xMin) <= threshold { return .left }
            if abs(x - xMax) <= threshold { return .right }
            return nil
        }

        if project.showImageTracks {
            for ti in project.imageTracks.indices {
                if pt.y >= rowTop && pt.y < rowTop + trackH {
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
                rowTop += trackH
            }
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                if pt.y >= rowTop && pt.y < rowTop + trackH {
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
                rowTop += trackH
            }
        }
        if project.showAudioTracks {
            for ti in project.audioTracks.indices {
                if pt.y >= rowTop && pt.y < rowTop + trackH {
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
                rowTop += trackH
            }
        }
        if project.showSubtitleTracks {
            for ti in project.subtitleTracks.indices {
                if pt.y >= rowTop && pt.y < rowTop + subtitleTrackH {
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
                rowTop += subtitleTrackH
            }
        }
        return nil
    }

    private func finalizeBoxSelect(rect: CGRect) {
        let pps = project.pixelsPerSecond
        var ids: Set<UUID> = []
        var rowTop = rulerH

        if project.showImageTracks {
            for ti in project.imageTracks.indices {
                let yRange = rowTop ... (rowTop + trackH)
                for c in project.imageTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += trackH
            }
        }
        if project.showVideoTracks {
            for ti in project.videoTracks.indices {
                let yRange = rowTop ... (rowTop + trackH)
                for c in project.videoTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += trackH
            }
        }
        if project.showAudioTracks {
            for ti in project.audioTracks.indices {
                let yRange = rowTop ... (rowTop + trackH)
                for c in project.audioTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += trackH
            }
        }
        if project.showSubtitleTracks {
            for ti in project.subtitleTracks.indices {
                let yRange = rowTop ... (rowTop + subtitleTrackH)
                for c in project.subtitleTracks[ti].clips {
                    let xRange = (c.startTime*pps) ... (c.endTime*pps)
                    if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
                }
                rowTop += subtitleTrackH
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

    private func totalContentH() -> CGFloat {
        var h = rulerH
        if project.showImageTracks    { h += trackH * CGFloat(project.imageTracks.count) }
        if project.showVideoTracks    { h += trackH * CGFloat(project.videoTracks.count) }
        if project.showAudioTracks    { h += trackH * CGFloat(project.audioTracks.count) }
        if project.showSubtitleTracks { h += subtitleTrackH * CGFloat(project.subtitleTracks.count) }
        return h
    }

    @ViewBuilder
    private var trackRows: some View {
        if project.showImageTracks {
            ForEach(project.imageTracks.indices, id:\.self) { i in
                trackRow(height: trackH, hidden: !project.imageTracks[i].isVisible, tint: Color(hex: "#E8A54B")) {
                    ForEach(project.imageTracks[i].clips) { clip in
                        ImageClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                      sel: isSelected(clip.id, primary: project.selectedImageClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showVideoTracks {
            ForEach(project.videoTracks.indices, id:\.self) { i in
                trackRow(height: trackH, hidden: !project.videoTracks[i].isVisible, tint: Color(hex: "#3DBFBA")) {
                    ForEach(project.videoTracks[i].clips) { clip in
                        VideoClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                      sel: isSelected(clip.id, primary: project.selectedVideoClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showAudioTracks {
            ForEach(project.audioTracks.indices, id:\.self) { i in
                trackRow(height: trackH, hidden: !project.audioTracks[i].isVisible, muted: project.audioTracks[i].isMuted, tint: Color(hex: "#5DB85D")) {
                    ForEach(project.audioTracks[i].clips) { clip in
                        AudioClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                      sel: isSelected(clip.id, primary: project.selectedAudioClipID),
                                      isDragging: draggingClipID == clip.id)
                    }
                }
            }
        }
        if project.showSubtitleTracks {
            ForEach(project.subtitleTracks.indices, id:\.self) { i in
                trackRow(height: subtitleTrackH, hidden: !project.subtitleTracks[i].isVisible, tint: Color(hex: "#7B6FC4")) {
                    ForEach(project.subtitleTracks[i].clips) { clip in
                        SubtitleClipView(clip: clip, pps: project.pixelsPerSecond, h: subtitleTrackH,
                                         sel: isSelected(clip.id, primary: project.selectedSubtitleClipID),
                                         isDragging: draggingClipID == clip.id)
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
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#3DBFBA"), height: trackH - 4, isSubtitle: false)
        case .moveImage(let id, _, _, _):
            guard let clip = project.imageTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#E8A54B"), height: trackH - 4, isSubtitle: false)
        case .moveAudio(let id, _, _, _):
            guard let clip = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.name, duration: clip.duration, color: Color(hex: "#5DB85D"), height: trackH - 4, isSubtitle: false)
        case .moveSubtitle(let id, _, _, _):
            guard let clip = project.subtitleTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return GhostInfo(name: clip.text.components(separatedBy: "\n").first ?? clip.text, duration: clip.duration, color: Color(hex: "#7B6FC4"), height: (trackH - 4) / 2, isSubtitle: true)
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
            if r < iCount { top += trackH }
            else if r < iCount + vCount { top += trackH }
            else if r < iCount + vCount + aCount { top += trackH }
            else { top += subtitleTrackH }
        }
        let h: CGFloat = row >= iCount + vCount + aCount ? subtitleTrackH : trackH
        return top + h / 2
    }

    private func trackIndexFromY(_ y: CGFloat) -> TrackTarget {
        var top = rulerH
        if project.showImageTracks {
            for i in project.imageTracks.indices {
                if y < top + trackH { return TrackTarget(imageIndex: i) }
                top += trackH
            }
        }
        if project.showVideoTracks {
            for i in project.videoTracks.indices {
                if y < top + trackH { return TrackTarget(videoIndex: i) }
                top += trackH
            }
        }
        if project.showAudioTracks {
            for i in project.audioTracks.indices {
                if y < top + trackH { return TrackTarget(audioIndex: i) }
                top += trackH
            }
        }
        if project.showSubtitleTracks {
            for i in project.subtitleTracks.indices {
                if y < top + subtitleTrackH { return TrackTarget(subtitleIndex: i) }
                top += subtitleTrackH
            }
        }
        return TrackTarget()
    }

    @ViewBuilder
    private func trackRow<C: View>(height: CGFloat, hidden: Bool = false, muted: Bool = false, tint: Color = .white, @ViewBuilder clips: () -> C) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tint.opacity(0.03)).allowsHitTesting(false)
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

            // hover 时：操作按钮
            if isHovered {
                Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.92)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .onHover { isHovered = $0 }
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
                .foregroundColor(on ? Color.accent : Color.labelSecondary.opacity(0.4))
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
                .font(.system(size: 9, weight: .light))
                .foregroundColor(hov ? (destructive ? .red.opacity(0.9) : .white) : Color.labelSecondary)
                .frame(width: 20, height: 20)
                .background(hov ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .onHover { hov = $0 }
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
        .onAppear {
            if let url = clip.url {
                project.loadTimelineThumbnails(assetID: clip.assetID, url: url)
            }
        }
        .gesture(TapGesture().modifiers(.shift).onEnded {
            project.shiftToggleClip(clip.id)
        })
        .simultaneousGesture(TapGesture().onEnded {
            guard !NSEvent.modifierFlags.contains(.shift) else { return }
            project.selectedVideoClipID    = clip.id
            project.selectedImageClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedSubtitleClipID = nil
            project.selectedClipIDs.removeAll()
            project.loadClipForPreview(clip)
        })
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

    @ViewBuilder
    private func thumbnailStrip(frames: [ThumbnailFrame], clipWidth: CGFloat) -> some View {
        let thumbW = h - 4  // roughly square tiles
        let count = max(1, Int(ceil(clipWidth / thumbW)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let t = clip.trimStart + clip.duration * Double(i) / Double(count)
                let frame = closestFrame(frames, at: t)
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: i == count - 1 ? clipWidth - thumbW * CGFloat(count - 1) : thumbW,
                           height: h - 4)
                    .clipped()
            }
        }
        .frame(width: clipWidth, height: h - 4)
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
        .gesture(TapGesture().modifiers(.shift).onEnded {
            project.shiftToggleClip(clip.id)
        })
        .simultaneousGesture(TapGesture().onEnded {
            guard !NSEvent.modifierFlags.contains(.shift) else { return }
            project.selectedImageClipID    = clip.id
            project.selectedVideoClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedSubtitleClipID = nil
            project.selectedClipIDs.removeAll()
        })
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
        .gesture(TapGesture().modifiers(.shift).onEnded {
            project.shiftToggleClip(clip.id)
        })
        .simultaneousGesture(TapGesture().onEnded {
            guard !NSEvent.modifierFlags.contains(.shift) else { return }
            project.selectedAudioClipID    = clip.id
            project.selectedVideoClipID    = nil
            project.selectedImageClipID    = nil
            project.selectedSubtitleClipID = nil
            project.selectedClipIDs.removeAll()
        })
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

    var body: some View {
        let w = max(clip.duration*pps, 4)
        let clipH = h - 6
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:3).fill(Color(hex:"#7B6FC4").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius:3)
                    .stroke(sel ? Color.white : Color(hex:"#9B8FD4").opacity(0.4), lineWidth: sel ? 2 : 1))
            if w > 16 {
                Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                    .font(.system(size:8, weight:.medium))
                    .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: w, height: clipH)
        .opacity(isDragging ? 0 : (project.clipboardIsCut && project.clipboardSourceID == clip.id ? 0.35 : 1.0))
        .offset(x: clip.startTime*pps + 1)
        .gesture(TapGesture().modifiers(.shift).onEnded {
            project.shiftToggleClip(clip.id)
        })
        .simultaneousGesture(TapGesture().onEnded {
            guard !NSEvent.modifierFlags.contains(.shift) else { return }
            project.selectedSubtitleClipID = clip.id
            project.selectedVideoClipID    = nil
            project.selectedImageClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedClipIDs.removeAll()
        })
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

// MARK: - Ruler

private struct TimelineRuler: View {
    let pps:Double; let duration:Double
    var body: some View {
        Canvas { ctx,size in
            let step = rulerStep(pps)
            var t = 0.0
            while t <= duration+step {
                let x = t*pps
                let maj = t.truncatingRemainder(dividingBy:step*5) < 0.01
                ctx.stroke(Path { p in
                    p.move(to:CGPoint(x:x,y:size.height-(maj ? 14:7)))
                    p.addLine(to:CGPoint(x:x,y:size.height))
                }, with:.color(.white.opacity(maj ? 0.4:0.15)), lineWidth:1)
                if maj { ctx.draw(Text(fmtT(t)).font(.system(size:9).monospacedDigit()).foregroundColor(.white.opacity(0.4)),
                                  at:CGPoint(x:x+3,y:8)) }
                t+=step
            }
        }
        .background(Color(red:0.09,green:0.09,blue:0.10))
    }
    private func rulerStep(_ p:Double)->Double {
        if p>=100{return 0.5};if p>=40{return 1};if p>=15{return 2}
        if p>=7{return 5};if p>=3{return 10};return 30
    }
}

// MARK: - Draggable Playhead

private struct DraggablePlayhead: View {
    @EnvironmentObject private var project: ProjectState
    let pps: Double

    var body: some View {
        GeometryReader { geo in
            let x = project.currentTime * pps
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: x,   y: 16))
                    p.addLine(to: CGPoint(x: x-5, y: 6))
                    p.addLine(to: CGPoint(x: x+5, y: 6))
                    p.closeSubpath()
                }.fill(Color.accent)
                Rectangle().fill(Color.accent.opacity(0.7))
                    .frame(width: 1, height: geo.size.height - 16)
                    .offset(x: x - 0.5, y: 16)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @EnvironmentObject private var project: ProjectState
    var body: some View {
        HStack(spacing:0) {
            // 左侧：编辑工具
            HStack(spacing:2) {
                TBtn(icon:"arrow.uturn.backward", help:"撤销", enabled: project.undoCount > 0) { project.undo() }
                TBtn(icon:"arrow.uturn.forward",  help:"重做", enabled: project.redoCount > 0) { project.redo() }
                Divider().frame(height:16).padding(.horizontal,4)
                TBtn(icon:"scissors",         help:"在播放头分割片段", enabled: project.selectedImageClipID == nil) { project.splitAtPlayhead() }
                TBtn(icon:"trash",            help:"删除选中片段")   { project.deleteSelected() }
                TBtn(icon:"text.alignleft",   help:"将选中片段对齐到播放头") { project.alignSelectedToPlayhead() }
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
                    .foregroundColor(project.snapEnabled ? Color.accent : Color.labelSecondary.opacity(0.4))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("自动吸附")
            .padding(.trailing, 8)

            // 右侧：缩放
            HStack(spacing:6) {
                TBtn(icon:"minus.magnifyingglass") { project.pixelsPerSecond = max(2, project.pixelsPerSecond/1.5) }
                Slider(value:$project.pixelsPerSecond, in:2...150).frame(width:100).accentColor(Color.accent)
                TBtn(icon:"plus.magnifyingglass")  { project.pixelsPerSecond = min(150, project.pixelsPerSecond*1.5) }
            }.padding(.trailing,12)
        }
        .frame(height:36)
        .background(Color(red:0.09,green:0.09,blue:0.10))
    }
}

// MARK: - 翻译 & 样式工具组

private struct TranslateToolGroup: View {
    @EnvironmentObject private var project: ProjectState

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
            }
            .buttonStyle(.plain)

            TBtn(icon: "translate", help: "翻译当前字幕",
                 enabled: project.selectedSubtitleClip != nil) { translateCurrent() }
            TBtn(icon: "list.bullet.rectangle", help: "翻译整条轨道",
                 enabled: !project.subtitleTracks.isEmpty && !project.subtitleTracks[0].clips.isEmpty) { translateAll() }
        }
    }

    private func shortLang(_ lang: String) -> String {
        // 显示简短标签
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

    // MARK: - 翻译逻辑（从 InspectorView 迁移）

    private func ensureTrack2() {
        if project.subtitleTracks.count < 2 {
            project.subtitleTracks.append(Track(label: "字幕"))
        }
        while project.subtitleStyles.count < 2 {
            var s = SubtitleStyle()
            if let first = project.subtitleStyles.first {
                s.bottomMargin = max(0, first.bottomMargin - 10)
            }
            project.subtitleStyles.append(s)
        }
    }

    private func translateCurrent() {
        guard let clip = project.selectedSubtitleClip else { return }
        let lang = project.translationTargetLang
        ensureTrack2()
        Task {
            let translated = await Translator.translateSmart(clip.text, to: lang)
            await MainActor.run {
                let newClip = SubtitleClip(text: translated,
                                           startTime: clip.startTime, endTime: clip.endTime)
                project.subtitleTracks[1].clips.removeAll {
                    abs($0.startTime - clip.startTime) < 0.01
                }
                project.subtitleTracks[1].clips.append(newClip)
                project.subtitleTracks[1].clips.sort { $0.startTime < $1.startTime }
            }
        }
    }

    private func translateAll() {
        guard !project.subtitleTracks.isEmpty else { return }
        let lang = project.translationTargetLang
        let originals = project.subtitleTracks[0].clips
        ensureTrack2()
        Task {
            var translatedClips: [SubtitleClip] = []
            translatedClips.reserveCapacity(originals.count)
            for c in originals {
                let t = await Translator.translateSmart(c.text, to: lang)
                translatedClips.append(SubtitleClip(text: t,
                                                    startTime: c.startTime,
                                                    endTime: c.endTime))
            }
            await MainActor.run {
                project.subtitleTracks[1].clips = translatedClips
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
