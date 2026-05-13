import SwiftUI
import AVFoundation

// MARK: - Timeline root

struct TimelineView: View {
    @EnvironmentObject private var project: ProjectState
    private let labelW: CGFloat = 130
    private let trackH: CGFloat = 52
    private let rulerH: CGFloat = 26

    // Unified drag state
    @State private var dragOp:   DragOp?  = nil
    @State private var boxStart: CGPoint? = nil
    @State private var boxEnd:   CGPoint? = nil

    // Global event monitors
    @State private var keyMonitor:    Any? = nil
    @State private var scrollMonitor: Any? = nil

    private enum DragOp {
        case moveVideo(id: UUID, originStart: Double, originDur: Double)
        case moveAudio(id: UUID, originStart: Double, originDur: Double)
        case moveSubtitle(id: UUID, originStart: Double, originDur: Double)
        case moveMulti(items: [DragItem])
        case trimVideoLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double)
        case trimVideoRight(id: UUID, originStart: Double, originEnd: Double)
        case trimAudioLeft(id: UUID, originStart: Double, originEnd: Double, originTrimStart: Double)
        case trimAudioRight(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleLeft(id: UUID, originStart: Double, originEnd: Double)
        case trimSubtitleRight(id: UUID, originStart: Double, originEnd: Double)
        case movingPlayhead
        case box
        case ignored
    }

    struct DragItem {
        enum Kind { case video, audio, subtitle }
        let id: UUID
        let kind: Kind
        let originStart: Double
        let originDur: Double
    }

    private enum ClipHit {
        case video(id: UUID, start: Double, dur: Double)
        case audio(id: UUID, start: Double, dur: Double)
        case subtitle(id: UUID, start: Double, dur: Double)

        var id: UUID {
            switch self {
            case .video(let id, _, _), .audio(let id, _, _), .subtitle(let id, _, _):
                return id
            }
        }
    }

    private enum ClipTrimEdge { case left, right }

    var body: some View {
        HStack(spacing: 0) {
            labelColumn
            clipArea
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
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }  // ⌫ or ⌦
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
                return event  // user is typing in a text field — let it delete text
            }
            project.deleteSelected()
            return nil
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
                Button("添加视频轨道") { project.videoTracks.append(Track(label: "视频轨道 \(project.videoTracks.count+1)")) }
                Button("添加音频轨道") { project.audioTracks.append(Track(label: "音频轨道 \(project.audioTracks.count+1)")) }
                Button("添加字幕轨道") {
                    project.subtitleTracks.append(Track(label: "字幕轨道 \(project.subtitleTracks.count+1)"))
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

            ForEach(project.videoTracks.indices, id:\.self) { i in
                TrackLabel(icon:"film", title: project.videoTracks[i].label,
                           count: project.videoTracks[i].clips.count, hasMute: true,
                           isMuted: project.videoTracks[i].isMuted, isVis: project.videoTracks[i].isVisible,
                           onMute: { project.videoTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                           onVis:  { project.videoTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                           onDel:  { project.videoTracks.remove(at:i) })
                    .frame(height: trackH)
            }
            ForEach(project.audioTracks.indices, id:\.self) { i in
                TrackLabel(icon:"music.note", title: project.audioTracks[i].label,
                           count: project.audioTracks[i].clips.count, hasMute: true,
                           isMuted: project.audioTracks[i].isMuted, isVis: project.audioTracks[i].isVisible,
                           onMute: { project.audioTracks[i].isMuted.toggle(); project.rebuildTimelinePreview() },
                           onVis:  { project.audioTracks[i].isVisible.toggle(); project.rebuildTimelinePreview() },
                           onDel:  { project.audioTracks.remove(at:i) })
                    .frame(height: trackH)
            }
            ForEach(project.subtitleTracks.indices, id:\.self) { i in
                TrackLabel(icon:"text.bubble", title: project.subtitleTracks[i].label,
                           count: project.subtitleTracks[i].clips.count, hasMute: false,
                           isMuted: false, isVis: project.subtitleTracks[i].isVisible,
                           onMute: nil,
                           onVis:  { project.subtitleTracks[i].isVisible.toggle() },
                           onDel:  { project.subtitleTracks.remove(at:i) })
                    .frame(height: trackH)
            }
            Spacer()
        }
        .frame(width: labelW)
        .background(Color(red:0.09,green:0.09,blue:0.10))
    }

    // MARK: Clip scroll area

    private var clipArea: some View {
        let totalW = max(project.duration * project.pixelsPerSecond + 300, 800)
        return GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Ruler — visual only; seeking is handled by the unified drag gesture below.
                    TimelineRuler(pps: project.pixelsPerSecond, duration: project.duration)
                        .frame(height: rulerH)
                        .allowsHitTesting(false)

                    // Track rows (push down past ruler with a non-hit-testing spacer)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: rulerH).allowsHitTesting(false)
                        trackRows
                    }

                    // Box-select rectangle overlay — drawn above clips, doesn't block input.
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

                    // Playhead (draggable)
                    DraggablePlayhead(pps: project.pixelsPerSecond)
                }
                .padding(.leading, 6)   // prevent playhead triangle from being clipped at x=0
                .frame(width: totalW + 6,
                       height: max(geo.size.height, totalContentH()),
                       alignment: .topLeading)
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
                        if findClipTarget(at: loc)?.trimEdge != nil {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
                .simultaneousGesture(unifiedDragGesture)
            }
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
                    } else if v.translation.width.magnitude > 3 || v.translation.height.magnitude > 3 {
                        startDrag(at: loc)
                    }
                }
                guard let op = dragOp else { return }
                applyDrag(op: op, totalTranslation: v.translation, current: v.location)
            }
            .onEnded { _ in
                if case .box = dragOp, let s = boxStart, let e = boxEnd {
                    let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                                      width: abs(e.x - s.x), height: abs(e.y - s.y))
                    finalizeBoxSelect(rect: rect)
                }
                switch dragOp {
                case .trimVideoLeft, .trimVideoRight,
                     .trimAudioLeft, .trimAudioRight,
                     .trimSubtitleLeft, .trimSubtitleRight:
                    NSCursor.arrow.set()
                    project.rebuildTimelinePreview()
                case .moveVideo, .moveAudio, .moveMulti:
                    project.rebuildTimelinePreview()
                default: break
                }
                dragOp = nil
                boxStart = nil
                boxEnd = nil
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

            project.selectedClipIDs.removeAll()
            project.pushUndo()
            switch (hit, trimEdge) {
            case (.video(let id, let s, let d), nil):
                project.selectedVideoClipID    = id
                project.selectedAudioClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .moveVideo(id: id, originStart: s, originDur: d)
            case (.video(let id, let s, let d), .left):
                let ts = project.videoTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts)
                NSCursor.resizeLeftRight.set()
            case (.video(let id, let s, let d), .right):
                selectVideoAndLoad(id: id)
                dragOp = .trimVideoRight(id: id, originStart: s, originEnd: s + d)
                NSCursor.resizeLeftRight.set()
            case (.audio(let id, let s, let d), nil):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .moveAudio(id: id, originStart: s, originDur: d)
            case (.audio(let id, let s, let d), .left):
                let ts = project.audioTracks.flatMap(\.clips).first(where: { $0.id == id })?.trimStart ?? 0
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimAudioLeft(id: id, originStart: s, originEnd: s + d, originTrimStart: ts)
                NSCursor.resizeLeftRight.set()
            case (.audio(let id, let s, let d), .right):
                project.selectedAudioClipID    = id
                project.selectedVideoClipID    = nil
                project.selectedSubtitleClipID = nil
                dragOp = .trimAudioRight(id: id, originStart: s, originEnd: s + d)
                NSCursor.resizeLeftRight.set()
            case (.subtitle(let id, let s, let d), nil):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                dragOp = .moveSubtitle(id: id, originStart: s, originDur: d)
            case (.subtitle(let id, let s, let d), .left):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                dragOp = .trimSubtitleLeft(id: id, originStart: s, originEnd: s + d)
                NSCursor.resizeLeftRight.set()
            case (.subtitle(let id, let s, let d), .right):
                project.selectedSubtitleClipID = id
                project.selectedVideoClipID    = nil
                project.selectedAudioClipID    = nil
                dragOp = .trimSubtitleRight(id: id, originStart: s, originEnd: s + d)
                NSCursor.resizeLeftRight.set()
            }
        } else {
            dragOp = .box
            boxStart = pt
            project.selectedClipIDs.removeAll()
            project.selectedVideoClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedSubtitleClipID = nil
        }
    }

    private func selectVideoAndLoad(id: UUID) {
        project.selectedVideoClipID    = id
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

    private func applyDrag(op: DragOp, totalTranslation: CGSize, current: CGPoint) {
        let pps = project.pixelsPerSecond
        let dt  = Double(totalTranslation.width) / pps
        switch op {
        case .moveVideo(let id, let s, let d):
            let ns = max(0, s + dt)
            project.updateVideoClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveAudio(let id, let s, let d):
            let ns = max(0, s + dt)
            project.updateAudioClip(id: id) { $0.startTime = ns; $0.endTime = ns + d }
        case .moveSubtitle(let id, let s, let d):
            let ns = max(0, s + dt)
            project.updateSubtitleTime(id: id, start: ns, end: ns + d)
        case .moveMulti(let items):
            // Clamp delta so the leftmost clip in the group stays at >= 0.
            let minOrig = items.map(\.originStart).min() ?? 0
            let clampedDt = max(dt, -minOrig)
            for it in items {
                let ns = it.originStart + clampedDt
                let ne = ns + it.originDur
                switch it.kind {
                case .video:    project.updateVideoClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .audio:    project.updateAudioClip(id: it.id) { $0.startTime = ns; $0.endTime = ne }
                case .subtitle: project.updateSubtitleTime(id: it.id, start: ns, end: ne)
                }
            }
        case .trimVideoLeft(let id, let originStart, let originEnd, let originTrimStart):
            let ns = max(0, min(originStart + dt, originEnd - 0.1))
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateVideoClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimVideoRight(let id, let originStart, let originEnd):
            let ne = max(originStart + 0.1, originEnd + dt)
            project.updateVideoClip(id: id) { $0.endTime = ne }
            if ne > project.duration { project.duration = ne }
        case .trimAudioLeft(let id, let originStart, let originEnd, let originTrimStart):
            let ns = max(0, min(originStart + dt, originEnd - 0.1))
            let newTrimStart = max(0, originTrimStart + (ns - originStart))
            project.updateAudioClip(id: id) { $0.startTime = ns; $0.trimStart = newTrimStart }
        case .trimAudioRight(let id, let originStart, let originEnd):
            let ne = max(originStart + 0.1, originEnd + dt)
            project.updateAudioClip(id: id) { $0.endTime = ne }
            if ne > project.duration { project.duration = ne }
        case .trimSubtitleLeft(let id, let originStart, let originEnd):
            let ns = max(0, min(originStart + dt, originEnd - 0.1))
            project.updateSubtitleTime(id: id, start: ns)
        case .trimSubtitleRight(let id, let originStart, let originEnd):
            let ne = max(originStart + 0.1, originEnd + dt)
            project.updateSubtitleTime(id: id, end: ne)
            if ne > project.duration { project.duration = ne }
        case .movingPlayhead:
            let t = (Double(current.x) / pps).clamped(to: 0...project.duration)
            project.requestSeek(to: t)
        case .box:
            boxEnd = current
        case .ignored:
            break
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
        for ti in project.subtitleTracks.indices {
            if pt.y >= rowTop && pt.y < rowTop + trackH {
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
            rowTop += trackH
        }
        return nil
    }

    private func finalizeBoxSelect(rect: CGRect) {
        let pps = project.pixelsPerSecond
        var ids: Set<UUID> = []
        var rowTop = rulerH

        for ti in project.videoTracks.indices {
            let yRange = rowTop ... (rowTop + trackH)
            for c in project.videoTracks[ti].clips {
                let xRange = (c.startTime*pps) ... (c.endTime*pps)
                if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
            }
            rowTop += trackH
        }
        for ti in project.audioTracks.indices {
            let yRange = rowTop ... (rowTop + trackH)
            for c in project.audioTracks[ti].clips {
                let xRange = (c.startTime*pps) ... (c.endTime*pps)
                if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
            }
            rowTop += trackH
        }
        for ti in project.subtitleTracks.indices {
            let yRange = rowTop ... (rowTop + trackH)
            for c in project.subtitleTracks[ti].clips {
                let xRange = (c.startTime*pps) ... (c.endTime*pps)
                if rectIntersects(rect, xRange: xRange, yRange: yRange) { ids.insert(c.id) }
            }
            rowTop += trackH
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
        rulerH + trackH * CGFloat(project.videoTracks.count
                                  + project.audioTracks.count
                                  + project.subtitleTracks.count)
    }

    @ViewBuilder
    private var trackRows: some View {
        ForEach(project.videoTracks.indices, id:\.self) { i in
            trackRow(height: trackH, hidden: !project.videoTracks[i].isVisible) {
                ForEach(project.videoTracks[i].clips) { clip in
                    VideoClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                  sel: isSelected(clip.id, primary: project.selectedVideoClipID))
                }
            }
        }
        ForEach(project.audioTracks.indices, id:\.self) { i in
            trackRow(height: trackH, hidden: !project.audioTracks[i].isVisible) {
                ForEach(project.audioTracks[i].clips) { clip in
                    AudioClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                  sel: isSelected(clip.id, primary: project.selectedAudioClipID))
                }
            }
        }
        ForEach(project.subtitleTracks.indices, id:\.self) { i in
            trackRow(height: trackH, hidden: !project.subtitleTracks[i].isVisible) {
                ForEach(project.subtitleTracks[i].clips) { clip in
                    SubtitleClipView(clip: clip, pps: project.pixelsPerSecond, h: trackH,
                                     sel: isSelected(clip.id, primary: project.selectedSubtitleClipID))
                }
            }
        }
    }

    private func isSelected(_ id: UUID, primary: UUID?) -> Bool {
        primary == id || project.selectedClipIDs.contains(id)
    }

    @ViewBuilder
    private func trackRow<C: View>(height: CGFloat, hidden: Bool = false, @ViewBuilder clips: () -> C) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.02)).allowsHitTesting(false)
            clips()
        }
        .frame(height: height)
        .opacity(hidden ? 0.32 : 1.0)
    }
}

// MARK: - Track Label

private struct TrackLabel: View {
    let icon: String; let title: String; let count: Int
    let hasMute: Bool; let isMuted: Bool; let isVis: Bool
    let onMute: (() -> Void)?
    let onVis: () -> Void; let onDel: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            // 默认：居中图标 + 标题 + 数量
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .light))
                    .foregroundColor(Color.labelSecondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.labelSecondary.opacity(0.6))
            }
            .opacity(isHovered ? 0 : 1)

            // hover 时：遮罩 + 三个图标按钮
            if isHovered {
                Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.92)

                HStack(spacing: 6) {
                    if hasMute, let onMute {
                        OverlayBtn(icon: isMuted ? "speaker.slash" : "speaker.wave.2",
                                   action: onMute)
                    }
                    OverlayBtn(icon: isVis ? "eye" : "eye.slash",
                               action: onVis)
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

private struct OverlayBtn: View {
    let icon: String
    var destructive: Bool = false
    let action: () -> Void
    @State private var hov = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .light))
                .foregroundColor(hov ? (destructive ? .red.opacity(0.9) : .white) : Color.labelSecondary)
                .frame(width: 26, height: 22)
                .background(hov ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                .cornerRadius(4)
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
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment:.leading) {
            RoundedRectangle(cornerRadius:4).fill(Color(hex:"#3DBFBA").opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(sel ? Color.accent : Color.clear, lineWidth: 1.5))
            VStack(alignment:.leading, spacing:1) {
                Text(clip.name).font(.system(size:9, weight:.medium))
                    .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                Text(fmtT(clip.duration)).font(.system(size:8).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
            }.padding(.horizontal, 5)
        }
        .frame(width: w, height: h-4)
        .offset(x: clip.startTime*pps + 1)
        .onTapGesture {
            project.selectedVideoClipID    = clip.id
            project.selectedAudioClipID    = nil
            project.selectedSubtitleClipID = nil
            project.selectedClipIDs.removeAll()
            project.loadClipForPreview(clip)
        }
    }
}

private struct AudioClipView: View {
    let clip: AudioClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 5)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius:4).fill(Color(hex:"#5DB85D").opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(sel ? Color.accent : Color.clear, lineWidth: 1.5))
            Text(clip.name).font(.system(size:9, weight:.medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.leading, 5).lineLimit(1)
        }
        .frame(width: w, height: h-4)
        .offset(x: clip.startTime*pps + 1)
            .onTapGesture {
                project.selectedAudioClipID    = clip.id
                project.selectedVideoClipID    = nil
                project.selectedSubtitleClipID = nil
                project.selectedClipIDs.removeAll()
            }
    }
}

private struct SubtitleClipView: View {
    let clip: SubtitleClip
    let pps: Double
    let h: CGFloat
    let sel: Bool
    @EnvironmentObject var project: ProjectState

    var body: some View {
        let w = max(clip.duration*pps, 4)
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:4).fill(Color(hex:"#7B6FC4").opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius:4)
                    .stroke(sel ? Color.accent : Color(hex:"#9B8FD4").opacity(0.4), lineWidth: 1))
            if w > 16 {
                VStack(alignment:.leading, spacing:1) {
                    Text(clip.text.components(separatedBy:"\n").first ?? clip.text)
                        .font(.system(size:8, weight:.medium))
                        .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    Text(fmtT(clip.startTime)).font(.system(size:7).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                }.padding(.horizontal, 3).padding(.vertical, 2)
            }
        }
        .frame(width: w, height: h-4)
        .offset(x: clip.startTime*pps + 1)
        .onTapGesture {
            project.selectedSubtitleClipID = clip.id
            project.selectedVideoClipID    = nil
            project.selectedAudioClipID    = nil
            project.selectedClipIDs.removeAll()
            project.currentTime = clip.startTime
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
                TBtn(icon:"scissors",         help:"在播放头分割片段") { project.splitAtPlayhead() }
                TBtn(icon:"trash",            help:"删除选中片段")   { project.deleteSelected() }
                TBtn(icon:"text.alignleft",   help:"将选中片段对齐到播放头") { project.alignSelectedToPlayhead() }
                TBtn(icon:"character.bubble", help:"在当前字幕轨道插入字幕")  { project.insertSubtitleAtPlayhead() }

                Divider().frame(height:16).padding(.horizontal,4)

                // 翻译 & 样式工具
                TranslateToolGroup()
            }.padding(.leading,8)

            Spacer()

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
            Menu {
                ForEach(ProjectState.supportedLanguages, id: \.self) { lang in
                    Button {
                        project.translationTargetLang = lang
                    } label: {
                        HStack {
                            Text(lang)
                            if lang == project.translationTargetLang {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .light))
                    Text(shortLang(project.translationTargetLang))
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundColor(Color.labelSecondary)
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(Color.white.opacity(0.06))
                .cornerRadius(5)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

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

    // MARK: - 翻译逻辑（从 InspectorView 迁移）

    private func ensureTrack2() {
        if project.subtitleTracks.count < 2 {
            project.subtitleTracks.append(Track(label: "字幕轨道 2"))
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
