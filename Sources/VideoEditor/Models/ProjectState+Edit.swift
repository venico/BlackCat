import SwiftUI
import AVFoundation

// MARK: - Edit Operations (Undo/Redo, Split, Delete, Copy/Paste)

extension ProjectState {

    // MARK: - Undo / Redo

    func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()
    }

    func pushUndoSavingAssets() {
        var snap = currentSnapshot()
        snap.mediaAssets = mediaAssets
        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()
    }

    /// 节流版 pushUndo — 1秒内连续编辑只记录一次（适合滑块、步进器等高频操作）
    func pushUndoThrottled() {
        isSaved = false
        scheduleAutoSave()
        if Date().timeIntervalSince(lastUndoPushTime) > 1.0 {
            pushUndo()
        }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
        isSaved = false
        scheduleAutoSave()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(s)
        undoCount = undoStack.count
        redoCount = redoStack.count
        isSaved = false
        scheduleAutoSave()
    }

    func currentSnapshot(includeAssets: Bool = false) -> ProjectSnapshot {
        ProjectSnapshot(videoTracks: videoTracks, audioTracks: audioTracks,
                        imageTracks: imageTracks,
                        subtitleTracks: subtitleTracks,
                        textTracks: textTracks,
                        shapeTracks: shapeTracks,
                        overlayTrackOrder: overlayTrackOrder,
                        subtitleBottomMargin: subtitleBottomMargin,
                        subtitleLineSpacing: subtitleLineSpacing,
                        duration: duration,
                        mediaAssets: includeAssets ? mediaAssets : nil)
    }

    func applySnapshot(_ s: ProjectSnapshot) {
        videoTracks    = s.videoTracks
        audioTracks    = s.audioTracks
        imageTracks    = s.imageTracks
        subtitleTracks = s.subtitleTracks
        textTracks     = s.textTracks
        shapeTracks    = s.shapeTracks
        overlayTrackOrder = s.overlayTrackOrder
        subtitleBottomMargin = s.subtitleBottomMargin
        subtitleLineSpacing  = s.subtitleLineSpacing
        duration       = s.duration
        if let assets = s.mediaAssets {
            mediaAssets = assets
            // Regenerate thumbnails for restored assets
            for asset in assets {
                if asset.fileExists { loadMediaResources(asset) }
            }
        }
        rebuildTimelinePreview()
    }

    // MARK: - Split

    /// Split ONLY the currently selected clip at the playhead. If nothing selected, do nothing.
    func splitAtPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false

        if let id = selectedVideoClipID {
            outer: for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = videoTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        videoTracks[ti].clips[ci].endTime = t
                        var newClip = VideoClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            // 分割点在时间轴上的偏移 * speed = 源素材消耗量
                            trimStart: c.trimStart + (t - c.startTime) * c.speed,
                            overrideResolution: c.overrideResolution,
                            overrideFPS: c.overrideFPS,
                            overrideBitrate: c.overrideBitrate)
                        newClip.volume = c.volume
                        newClip.speed = c.speed   // 继承速率
                        newClip.videoWidth = c.videoWidth; newClip.videoHeight = c.videoHeight
                        newClip.scaleX = c.scaleX; newClip.scaleY = c.scaleY
                        newClip.lockAspect = c.lockAspect
                        newClip.offsetX = c.offsetX; newClip.offsetY = c.offsetY
                        newClip.cropTop = c.cropTop; newClip.cropBottom = c.cropBottom
                        newClip.cropLeft = c.cropLeft; newClip.cropRight = c.cropRight
                        videoTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedAudioClipID {
            outer: for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = audioTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        audioTracks[ti].clips[ci].endTime = t
                        var newClip = AudioClip(
                            assetID: c.assetID, name: c.name, url: c.url,
                            startTime: t, endTime: c.endTime,
                            trimStart: c.trimStart + (t - c.startTime) * c.speed,
                            volume: c.volume, leftChannel: c.leftChannel, rightChannel: c.rightChannel,
                            sampleRate: c.sampleRate, format: c.format)
                        newClip.speed = c.speed
                        audioTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedSubtitleClipID {
            outer: for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = subtitleTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        subtitleTracks[ti].clips[ci].endTime = t
                        var newClip = SubtitleClip(text: c.text, startTime: t, endTime: c.endTime)
                        newClip.assetID = c.assetID
                        subtitleTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        }

        if changed {
            undoStack.append(snap)
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
        }
    }

    // MARK: - Delete

    /// Delete every selected clip — multi-selection (box-select) + the
    /// single-selection IDs used by the Inspector.
    func deleteSelected() {
        let snap = currentSnapshot()
        var changed = false

        // Pool of all IDs to remove
        var ids = selectedClipIDs
        if let id = selectedVideoClipID    { ids.insert(id) }
        if let id = selectedImageClipID    { ids.insert(id) }
        if let id = selectedAudioClipID    { ids.insert(id) }
        if let id = selectedSubtitleClipID { ids.insert(id) }
        if let id = selectedTextClipID     { ids.insert(id) }
        if let id = selectedShapeClipID    { ids.insert(id) }
        guard !ids.isEmpty else { return }

        for i in videoTracks.indices {
            let before = videoTracks[i].clips.count
            videoTracks[i].clips.removeAll { ids.contains($0.id) }
            if videoTracks[i].clips.count != before { changed = true }
        }
        for i in imageTracks.indices {
            let before = imageTracks[i].clips.count
            imageTracks[i].clips.removeAll { ids.contains($0.id) }
            if imageTracks[i].clips.count != before { changed = true }
        }
        for i in audioTracks.indices {
            let before = audioTracks[i].clips.count
            audioTracks[i].clips.removeAll { ids.contains($0.id) }
            if audioTracks[i].clips.count != before { changed = true }
        }
        for i in subtitleTracks.indices {
            let before = subtitleTracks[i].clips.count
            subtitleTracks[i].clips.removeAll { ids.contains($0.id) }
            if subtitleTracks[i].clips.count != before { changed = true }
        }
        for i in textTracks.indices {
            let before = textTracks[i].clips.count
            textTracks[i].clips.removeAll { ids.contains($0.id) }
            if textTracks[i].clips.count != before { changed = true }
        }
        for i in shapeTracks.indices {
            let before = shapeTracks[i].clips.count
            shapeTracks[i].clips.removeAll { ids.contains($0.id) }
            if shapeTracks[i].clips.count != before { changed = true }
        }

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedTextClipID     = nil
        selectedShapeClipID    = nil
        selectedClipIDs.removeAll()

        if changed {
            undoStack.append(snap)
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
        }
    }

    // MARK: - Copy / Cut / Paste

    /// 复制当前选中的片段到剪贴板
    func copySelected() {
        collectToClipboard(isCut: false)
    }

    func cutSelected() {
        collectToClipboard(isCut: true)
    }

    func collectToClipboard(isCut: Bool) {
        var items: [ClipboardItem] = []
        var srcIDs: Set<UUID> = []

        var allIDs = selectedClipIDs
        if let id = selectedVideoClipID    { allIDs.insert(id) }
        if let id = selectedImageClipID    { allIDs.insert(id) }
        if let id = selectedAudioClipID    { allIDs.insert(id) }
        if let id = selectedSubtitleClipID { allIDs.insert(id) }
        if let id = selectedTextClipID     { allIDs.insert(id) }
        if let id = selectedShapeClipID    { allIDs.insert(id) }

        for id in allIDs {
            for (ti, track) in videoTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.video(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in imageTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.image(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in audioTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.audio(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in subtitleTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.subtitle(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in textTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.text(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in shapeTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.shape(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
        }

        guard !items.isEmpty else { return }
        clipboard = items
        clipboardIsCut = isCut
        clipboardSourceIDs = isCut ? srcIDs : []
    }

    /// 粘贴剪贴板内容到当前播放头位置
    func pasteAtPlayhead() {
        guard !clipboard.isEmpty else { return }
        let snap = currentSnapshot()
        let t = currentTime

        // 如果是剪切，先删除原始片段
        if clipboardIsCut, !clipboardSourceIDs.isEmpty {
            let srcIDs = clipboardSourceIDs
            for i in videoTracks.indices    { videoTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in imageTracks.indices    { imageTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in audioTracks.indices    { audioTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll { srcIDs.contains($0.id) } }
            for i in textTracks.indices     { textTracks[i].clips.removeAll     { srcIDs.contains($0.id) } }
            for i in shapeTracks.indices    { shapeTracks[i].clips.removeAll    { srcIDs.contains($0.id) } }
            clipboardIsCut = false
            clipboardSourceIDs = []
        }

        func startOf(_ item: ClipboardItem) -> Double {
            switch item {
            case .video(let c, _): return c.startTime
            case .image(let c, _): return c.startTime
            case .audio(let c, _): return c.startTime
            case .subtitle(let c, _): return c.startTime
            case .text(let c, _): return c.startTime
            case .shape(let c, _): return c.startTime
            }
        }
        let earliest = clipboard.map { startOf($0) }.min() ?? 0

        selectedClipIDs.removeAll()
        selectedVideoClipID = nil
        selectedImageClipID = nil
        selectedAudioClipID = nil
        selectedSubtitleClipID = nil
        selectedTextClipID = nil
        selectedShapeClipID = nil
        for item in clipboard {
            let offset = startOf(item) - earliest

            switch item {
            case .video(let clip, let trackIdx):
                var newClip = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                        startTime: t + offset, endTime: t + offset + clip.duration, trimStart: clip.trimStart)
                newClip.volume = clip.volume
                newClip.videoWidth = clip.videoWidth; newClip.videoHeight = clip.videoHeight
                newClip.overrideResolution = clip.overrideResolution
                newClip.overrideFPS = clip.overrideFPS
                newClip.overrideBitrate = clip.overrideBitrate
                newClip.scaleX = clip.scaleX; newClip.scaleY = clip.scaleY
                newClip.lockAspect = clip.lockAspect
                newClip.offsetX = clip.offsetX; newClip.offsetY = clip.offsetY
                newClip.cropTop = clip.cropTop; newClip.cropBottom = clip.cropBottom
                newClip.cropLeft = clip.cropLeft; newClip.cropRight = clip.cropRight
                let idx = videoTracks.indices.contains(trackIdx) ? trackIdx : 0
                if videoTracks.indices.contains(idx) {
                    let hasOverlap = videoTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        // 播放头处当前视频轨道有内容 → 正下方新建视频轨道；否则放当前轨道
                        var newTrack = Track<VideoClip>(label: "视频")
                        newTrack.clips.append(newClip)
                        videoTracks.insert(newTrack, at: idx + 1)
                    } else {
                        videoTracks[idx].clips.append(newClip)
                    }
                    selectedClipIDs.insert(newClip.id)
                }

            case .image(let clip, let trackIdx):
                var newClip = ImageClip(assetID: clip.assetID, name: clip.name, imageURL: clip.imageURL,
                                         videoURL: clip.videoURL, startTime: t + offset, endTime: t + offset + clip.duration,
                                         imageWidth: clip.imageWidth, imageHeight: clip.imageHeight)
                newClip.scaleX = clip.scaleX; newClip.scaleY = clip.scaleY
                newClip.lockAspect = clip.lockAspect
                newClip.offsetX = clip.offsetX; newClip.offsetY = clip.offsetY
                newClip.cropTop = clip.cropTop; newClip.cropBottom = clip.cropBottom
                newClip.cropLeft = clip.cropLeft; newClip.cropRight = clip.cropRight
                let idx = imageTracks.indices.contains(trackIdx) ? trackIdx : 0
                if imageTracks.indices.contains(idx) {
                    let hasOverlap = imageTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        // 播放头处当前轨道有内容 → 正下方新建图片轨道；否则放当前轨道
                        let anchorID = imageTracks[idx].id
                        var newTrack = Track<ImageClip>(label: "图片")
                        newTrack.clips.append(newClip)
                        imageTracks.append(newTrack)
                        insertOverlayRefBelow(.image(newTrack.id), below: anchorID)
                    } else {
                        imageTracks[idx].clips.append(newClip)
                    }
                    selectedClipIDs.insert(newClip.id)
                }

            case .audio(let clip, let trackIdx):
                var newClip = AudioClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                        startTime: t + offset, endTime: t + offset + clip.duration, trimStart: clip.trimStart)
                newClip.volume = clip.volume
                newClip.leftChannel = clip.leftChannel
                newClip.rightChannel = clip.rightChannel
                newClip.sampleRate = clip.sampleRate
                newClip.format = clip.format
                let idx = audioTracks.indices.contains(trackIdx) ? trackIdx : 0
                if audioTracks.indices.contains(idx) {
                    let hasOverlap = audioTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        // 播放头处当前音频轨道有内容 → 正下方新建音频轨道；否则放当前轨道
                        var newTrack = Track<AudioClip>(label: "音频")
                        newTrack.clips.append(newClip)
                        audioTracks.insert(newTrack, at: idx + 1)
                    } else {
                        audioTracks[idx].clips.append(newClip)
                    }
                    selectedClipIDs.insert(newClip.id)
                }

            case .subtitle(let clip, let trackIdx):
                let st = t + offset
                var newClip = SubtitleClip(text: clip.text, startTime: st, endTime: st + clip.duration)
                newClip.assetID = clip.assetID
                var idx = subtitleTracks.indices.contains(trackIdx) ? trackIdx : 0
                if subtitleTracks.indices.contains(idx) {
                    let hasOverlap = subtitleTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        var placed = false
                        for dti in subtitleTracks.indices where dti != idx {
                            let noOverlap = !subtitleTracks[dti].clips.contains {
                                $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                            }
                            if noOverlap { idx = dti; placed = true; break }
                        }
                        if !placed {
                            var newTrack = Track<SubtitleClip>(label: "字幕")
                            newTrack.subtitleStyle = newSubtitleStyle()
                            subtitleTracks.append(newTrack)
                            syncOverlayOrder()
                            idx = subtitleTracks.count - 1
                        }
                    }
                    subtitleTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }

            case .text(let clip, let trackIdx):
                let st = t + offset
                var newClip = TextClip(text: clip.text, startTime: st, endTime: st + clip.duration)
                newClip.fontName = clip.fontName; newClip.fontSize = clip.fontSize
                newClip.bold = clip.bold; newClip.italic = clip.italic
                newClip.textColor = clip.textColor; newClip.strokeColor = clip.strokeColor
                newClip.strokeWidth = clip.strokeWidth; newClip.bgColor = clip.bgColor
                newClip.bgOpacity = clip.bgOpacity; newClip.alignment = clip.alignment
                newClip.rotation = clip.rotation; newClip.opacity = clip.opacity
                newClip.posX = clip.posX; newClip.posY = clip.posY
                newClip.animation = clip.animation
                let idx = textTracks.indices.contains(trackIdx) ? trackIdx : 0
                if textTracks.indices.contains(idx) {
                    let hasOverlap = textTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        // 播放头处当前轨道有内容 → 正下方新建文字轨道；否则放当前轨道
                        let anchorID = textTracks[idx].id
                        var newTrack = Track<TextClip>(label: "文字")
                        newTrack.clips.append(newClip)
                        textTracks.append(newTrack)
                        insertOverlayRefBelow(.text(newTrack.id), below: anchorID)
                    } else {
                        textTracks[idx].clips.append(newClip)
                    }
                    selectedClipIDs.insert(newClip.id)
                }

            case .shape(let clip, let trackIdx):
                var newClip = clip
                newClip.id = UUID()
                newClip.startTime = t + offset
                newClip.endTime = t + offset + clip.duration
                var idx = shapeTracks.indices.contains(trackIdx) ? trackIdx : 0
                if shapeTracks.indices.contains(idx) {
                    let hasOverlap = shapeTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        var placed = false
                        for dti in shapeTracks.indices where dti != idx {
                            let noOverlap = !shapeTracks[dti].clips.contains {
                                $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                            }
                            if noOverlap { idx = dti; placed = true; break }
                        }
                        if !placed {
                            let newTrack = Track<ShapeClip>(label: "图形")
                            shapeTracks.append(newTrack)
                            syncOverlayOrder()
                            idx = shapeTracks.count - 1
                        }
                    }
                    shapeTracks[idx].clips.append(newClip)
                    selectedClipIDs.insert(newClip.id)
                }
            }
        }

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// Move the selected clip so its start aligns with the current playhead.
    func alignSelectedToPlayhead() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false
        if let id = selectedVideoClipID {
            for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = videoTracks[ti].clips[ci].duration
                    videoTracks[ti].clips[ci].startTime = t
                    videoTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
        } else if let id = selectedAudioClipID {
            for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = audioTracks[ti].clips[ci].duration
                    audioTracks[ti].clips[ci].startTime = t
                    audioTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
        } else if let id = selectedImageClipID {
            for ti in imageTracks.indices {
                if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let d = imageTracks[ti].clips[ci].duration
                    imageTracks[ti].clips[ci].startTime = t
                    imageTracks[ti].clips[ci].endTime = t + d
                    changed = true; break
                }
            }
        } else if let id = selectedSubtitleClipID {
            for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where:{ $0.id==id }) {
                    let d = subtitleTracks[ti].clips[ci].duration
                    subtitleTracks[ti].clips[ci].startTime = t
                    subtitleTracks[ti].clips[ci].endTime   = t + d
                    changed = true; break
                }
            }
        }
        if changed {
            undoStack.append(snap)
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
        }
    }

    // MARK: - 场景检测分割

    func sceneDetectSelectedClip() {
        guard !isDetectingScenes else { return }
        guard SceneDetector.isInstalled else {
            showSuccessToast(icon: "exclamationmark.triangle.fill", iconColor: .yellow,
                             title: "智能分割", subtitle: "请先在设置→视频分析中下载组件", autoCountdown: false)
            return
        }
        guard let clipID = selectedVideoClipID else { return }
        var clip: VideoClip?
        var trackIdx = 0
        var clipIdx = 0
        for ti in videoTracks.indices {
            if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                clip = videoTracks[ti].clips[ci]
                trackIdx = ti; clipIdx = ci
                break
            }
        }
        guard let c = clip, let url = c.url else { return }

        isDetectingScenes = true
        sceneDetectProgress = 0

        sceneDetectTask = Task {
            do {
                let cuts = try await SceneDetector.detect(videoURL: url) { pct in
                    DispatchQueue.main.async { self.sceneDetectProgress = pct }
                }
                await MainActor.run { applySceneCuts(trackIdx: trackIdx, clipIdx: clipIdx, clip: c, cuts: cuts) }
            } catch {
                await MainActor.run {
                    isDetectingScenes = false
                    sceneDetectProgress = 0
                    showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                     title: "智能分割", subtitle: error.localizedDescription, autoCountdown: false)
                }
            }
        }
    }

    private func applySceneCuts(trackIdx: Int, clipIdx: Int, clip: VideoClip, cuts: [Double]) {
        isDetectingScenes = false
        sceneDetectProgress = 0
        guard trackIdx < videoTracks.count,
              clipIdx < videoTracks[trackIdx].clips.count,
              videoTracks[trackIdx].clips[clipIdx].id == clip.id else {
            showSuccessToast(icon: "exclamationmark.triangle.fill", iconColor: .yellow,
                             title: "智能分割", subtitle: "片段已变更，请重新操作", autoCountdown: false)
            return
        }

        let relevant = cuts.filter { $0 > clip.trimStart + 0.05 && $0 < clip.trimStart + (clip.endTime - clip.startTime) * clip.speed - 0.05 }
        guard !relevant.isEmpty else {
            showSuccessToast(icon: "checkmark.circle.fill", iconColor: .green,
                             title: "智能分割", subtitle: "未检测到场景切换", autoCountdown: true)
            return
        }

        let snap = currentSnapshot()
        var splits: [VideoClip] = []
        var prevTrimStart = clip.trimStart
        var prevTimelineStart = clip.startTime

        for cutSec in relevant {
            let offsetInClip = cutSec - clip.trimStart
            let timelinePos = clip.startTime + offsetInClip / clip.speed

            var seg = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                startTime: prevTimelineStart, endTime: timelinePos,
                                trimStart: prevTrimStart,
                                overrideResolution: clip.overrideResolution,
                                overrideFPS: clip.overrideFPS,
                                overrideBitrate: clip.overrideBitrate)
            seg.volume = clip.volume; seg.speed = clip.speed
            seg.videoWidth = clip.videoWidth; seg.videoHeight = clip.videoHeight
            seg.scaleX = clip.scaleX; seg.scaleY = clip.scaleY
            seg.lockAspect = clip.lockAspect
            seg.offsetX = clip.offsetX; seg.offsetY = clip.offsetY
            seg.cropTop = clip.cropTop; seg.cropBottom = clip.cropBottom
            seg.cropLeft = clip.cropLeft; seg.cropRight = clip.cropRight
            splits.append(seg)

            prevTrimStart = cutSec
            prevTimelineStart = timelinePos
        }

        var lastSeg = VideoClip(assetID: clip.assetID, name: clip.name, url: clip.url,
                                startTime: prevTimelineStart, endTime: clip.endTime,
                                trimStart: prevTrimStart,
                                overrideResolution: clip.overrideResolution,
                                overrideFPS: clip.overrideFPS,
                                overrideBitrate: clip.overrideBitrate)
        lastSeg.volume = clip.volume; lastSeg.speed = clip.speed
        lastSeg.videoWidth = clip.videoWidth; lastSeg.videoHeight = clip.videoHeight
        lastSeg.scaleX = clip.scaleX; lastSeg.scaleY = clip.scaleY
        lastSeg.lockAspect = clip.lockAspect
        lastSeg.offsetX = clip.offsetX; lastSeg.offsetY = clip.offsetY
        lastSeg.cropTop = clip.cropTop; lastSeg.cropBottom = clip.cropBottom
        lastSeg.cropLeft = clip.cropLeft; lastSeg.cropRight = clip.cropRight
        splits.append(lastSeg)

        videoTracks[trackIdx].clips.remove(at: clipIdx)
        videoTracks[trackIdx].clips.insert(contentsOf: splits, at: clipIdx)

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()

        showSuccessToast(icon: "checkmark.circle.fill", iconColor: .green,
                         title: "智能分割", subtitle: "已分割为 \(splits.count) 个片段", autoCountdown: true)
    }

    // MARK: - 大模型分析（一站式：语音识别 → LLM → 新轨道）

    func llmAnalyzeSelectedClip() {
        guard !isLLMAnalyzing else { return }
        let settings = AppSettings.shared
        guard !settings.llmAPIKey.isEmpty else {
            showSuccessToast(icon: "exclamationmark.triangle.fill", iconColor: .yellow,
                             title: "大模型分析", subtitle: "请先在设置→视频分析中配置 API Key", autoCountdown: false)
            return
        }
        guard WhisperTranscriber.modelReady else {
            showWhisperModelPicker = true
            return
        }
        guard WhisperTranscriber.whisperReady else {
            showSuccessToast(icon: "exclamationmark.triangle.fill", iconColor: .yellow,
                             title: "大模型分析", subtitle: "语音识别引擎未就绪（whisper-cli 缺失）", autoCountdown: false)
            return
        }
        guard let clipID = selectedVideoClipID else { return }

        var clip: VideoClip?
        var trackIdx = 0
        for ti in videoTracks.indices {
            if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                clip = videoTracks[ti].clips[ci]
                trackIdx = ti
                break
            }
        }
        guard let c = clip, let mediaURL = c.url else { return }

        isLLMAnalyzing = true
        llmAnalyzeProgress = 0

        let capSpeed = max(0.01, c.speed)
        let capOffset = c.startTime
        let srcDur = c.duration * capSpeed

        llmAnalyzeTask = Task {
            do {
                // ── 步骤 1：语音识别 (0~60%) ──
                try Task.checkCancellation()
                let segs = try await WhisperTranscriber.transcribe(
                    mediaURL: mediaURL, trimStart: c.trimStart,
                    duration: srcDur, language: "auto", prompt: nil
                ) { pct in
                    DispatchQueue.main.async { self.llmAnalyzeProgress = pct * 0.6 }
                }

                guard !segs.isEmpty else {
                    throw NSError(domain: "LLM", code: 10,
                                  userInfo: [NSLocalizedDescriptionKey: "语音识别未产生字幕"])
                }

                let subData = segs.map { s -> (start: Double, end: Double, text: String) in
                    let st = capOffset + s.start / capSpeed
                    let en = capOffset + s.end   / capSpeed
                    return (start: st, end: en, text: s.text)
                }

                // ── 步骤 2：大模型分析 (60~95%) ──
                try Task.checkCancellation()
                await MainActor.run { self.llmAnalyzeProgress = 0.6 }

                let highlights = try await LLMAnalyzer.analyze(
                    subtitles: subData,
                    provider: settings.llmProvider,
                    apiKey: settings.llmAPIKey
                ) { pct in
                    DispatchQueue.main.async { self.llmAnalyzeProgress = 0.6 + pct * 0.35 }
                }

                // ── 步骤 3：生成新轨道 (95~100%) ──
                try Task.checkCancellation()
                await MainActor.run {
                    self.llmAnalyzeProgress = 0.95
                    self.applyLLMHighlightsNewTrack(sourceClip: c, sourceTrackIdx: trackIdx, highlights: highlights)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLLMAnalyzing = false
                    llmAnalyzeProgress = 0
                }
            } catch {
                await MainActor.run {
                    let wasCancelled = !isLLMAnalyzing
                    isLLMAnalyzing = false
                    llmAnalyzeProgress = 0
                    if !wasCancelled {
                        showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                         title: "大模型分析", subtitle: error.localizedDescription, autoCountdown: false)
                    }
                }
            }
        }
    }

    private func applyLLMHighlightsNewTrack(sourceClip: VideoClip, sourceTrackIdx: Int,
                                             highlights: [LLMAnalyzer.Highlight]) {
        isLLMAnalyzing = false
        llmAnalyzeProgress = 0

        let sorted = highlights.sorted { $0.start < $1.start }
            .filter { $0.start >= sourceClip.startTime && $0.end <= sourceClip.endTime && $0.end > $0.start }

        guard !sorted.isEmpty else {
            showSuccessToast(icon: "checkmark.circle.fill", iconColor: .green,
                             title: "大模型分析", subtitle: "未找到精彩片段", autoCountdown: true)
            return
        }

        let snap = currentSnapshot()
        var keeps: [VideoClip] = []
        var cursor = 0.0

        for hl in sorted {
            let trimOffset = (hl.start - sourceClip.startTime) * sourceClip.speed
            let dur = hl.end - hl.start
            var seg = VideoClip(assetID: sourceClip.assetID, name: sourceClip.name, url: sourceClip.url,
                                startTime: cursor, endTime: cursor + dur,
                                trimStart: sourceClip.trimStart + trimOffset,
                                overrideResolution: sourceClip.overrideResolution,
                                overrideFPS: sourceClip.overrideFPS,
                                overrideBitrate: sourceClip.overrideBitrate)
            seg.volume = sourceClip.volume; seg.speed = sourceClip.speed
            seg.videoWidth = sourceClip.videoWidth; seg.videoHeight = sourceClip.videoHeight
            seg.scaleX = sourceClip.scaleX; seg.scaleY = sourceClip.scaleY
            seg.lockAspect = sourceClip.lockAspect
            seg.offsetX = sourceClip.offsetX; seg.offsetY = sourceClip.offsetY
            seg.cropTop = sourceClip.cropTop; seg.cropBottom = sourceClip.cropBottom
            seg.cropLeft = sourceClip.cropLeft; seg.cropRight = sourceClip.cropRight
            keeps.append(seg)
            cursor += dur
        }

        var newTrack = Track<VideoClip>(label: "精彩片段")
        newTrack.clips = keeps
        videoTracks.append(newTrack)

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()

        showSuccessToast(icon: "checkmark.circle.fill", iconColor: .green,
                         title: "大模型分析", subtitle: "已生成精彩片段轨道（\(keeps.count) 段）", autoCountdown: true)
    }
}
