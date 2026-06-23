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

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedTextClipID     = nil
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
            }
        }
        let earliest = clipboard.map { startOf($0) }.min() ?? 0

        selectedClipIDs.removeAll()
        selectedVideoClipID = nil
        selectedImageClipID = nil
        selectedAudioClipID = nil
        selectedSubtitleClipID = nil
        selectedTextClipID = nil
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
                    videoTracks[idx].clips.append(newClip)
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
                    imageTracks[idx].clips.append(newClip)
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
                    audioTracks[idx].clips.append(newClip)
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
                    textTracks[idx].clips.append(newClip)
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
}
