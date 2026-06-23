import SwiftUI
import AVFoundation

// MARK: - Timeline Track Operations

extension ProjectState {

    // MARK: - Cross-track move

    func moveVideoClipToTrack(id: UUID, from: Int, to: Int) {
        guard videoTracks.indices.contains(from), videoTracks.indices.contains(to) else { return }
        guard let idx = videoTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = videoTracks[from].clips.remove(at: idx)
        videoTracks[to].clips.append(clip)
    }

    func moveImageClipToTrack(id: UUID, from: Int, to: Int) {
        guard imageTracks.indices.contains(from), imageTracks.indices.contains(to) else { return }
        guard let idx = imageTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = imageTracks[from].clips.remove(at: idx)
        imageTracks[to].clips.append(clip)
    }

    func moveAudioClipToTrack(id: UUID, from: Int, to: Int) {
        guard audioTracks.indices.contains(from), audioTracks.indices.contains(to) else { return }
        guard let idx = audioTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = audioTracks[from].clips.remove(at: idx)
        audioTracks[to].clips.append(clip)
    }

    func moveSubtitleClipToTrack(id: UUID, from: Int, to: Int) {
        guard subtitleTracks.indices.contains(from), subtitleTracks.indices.contains(to) else { return }
        guard let idx = subtitleTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = subtitleTracks[from].clips.remove(at: idx)
        subtitleTracks[to].clips.append(clip)
    }

    func moveTextClipToTrack(id: UUID, from: Int, to: Int) {
        guard textTracks.indices.contains(from), textTracks.indices.contains(to) else { return }
        guard let idx = textTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = textTracks[from].clips.remove(at: idx)
        textTracks[to].clips.append(clip)
    }

    // MARK: - Overlap resolution

    /// 检查片段是否与同轨道其他片段重叠，如果重叠则自动新建轨道并移过去
    func resolveVideoOverlap(id: UUID) {
        for ti in videoTracks.indices {
            guard let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = videoTracks[ti].clips[ci]
            let hasOverlap = videoTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = videoTracks[ti].clips.remove(at: ci)
                // 尝试找一个没有重叠的已有轨道
                var placed = false
                for dti in videoTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !videoTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        videoTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<VideoClip>(label: "视频")
                    newTrack.clips.append(removed)
                    videoTracks.append(newTrack)
                }
            }
            return
        }
    }

    func resolveImageOverlap(id: UUID) {
        for ti in imageTracks.indices {
            guard let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = imageTracks[ti].clips[ci]
            let hasOverlap = imageTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = imageTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in imageTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !imageTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        imageTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<ImageClip>(label: "图片")
                    newTrack.clips.append(removed)
                    imageTracks.append(newTrack)
                    syncOverlayOrder()
                }
            }
            return
        }
    }

    func resolveAudioOverlap(id: UUID) {
        for ti in audioTracks.indices {
            guard let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = audioTracks[ti].clips[ci]
            let hasOverlap = audioTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = audioTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in audioTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !audioTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        audioTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<AudioClip>(label: "音频")
                    newTrack.clips.append(removed)
                    audioTracks.append(newTrack)
                }
            }
            return
        }
    }

    func resolveSubtitleOverlap(id: UUID) {
        for ti in subtitleTracks.indices {
            guard let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = subtitleTracks[ti].clips[ci]
            let hasOverlap = subtitleTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = subtitleTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in subtitleTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !subtitleTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        subtitleTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<SubtitleClip>(label: "字幕")
                    newTrack.clips.append(removed)
                    newTrack.subtitleStyle = newSubtitleStyle()
                    subtitleTracks.append(newTrack)
                    syncOverlayOrder()
                }
            }
            return
        }
    }

    func resolveTextOverlap(id: UUID) {
        for ti in textTracks.indices {
            guard let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = textTracks[ti].clips[ci]
            let hasOverlap = textTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let removed = textTracks[ti].clips.remove(at: ci)
                var placed = false
                for dti in textTracks.indices {
                    if dti == ti { continue }
                    let noOverlap = !textTracks[dti].clips.contains {
                        $0.startTime < removed.endTime - 0.001 && $0.endTime > removed.startTime + 0.001
                    }
                    if noOverlap {
                        textTracks[dti].clips.append(removed)
                        placed = true
                        break
                    }
                }
                if !placed {
                    var newTrack = Track<TextClip>(label: "文字")
                    newTrack.clips.append(removed)
                    textTracks.append(newTrack)
                    syncOverlayOrder()
                }
            }
            return
        }
    }

    /// 为新字幕轨自动计算 bottomMargin，避免与已有轨道重叠
    func newSubtitleStyle() -> SubtitleStyle {
        SubtitleStyle()
    }

    func updateTextTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in textTracks.indices {
            if let j = textTracks[i].clips.firstIndex(where: { $0.id == id }) {
                if let s = start { textTracks[i].clips[j].startTime = s }
                if let e = end   { textTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    // MARK: - Multi-select helpers

    /// Shift+click: toggle a clip in/out of multi-selection
    func shiftToggleClip(_ id: UUID) {
        if selectedClipIDs.contains(id) {
            selectedClipIDs.remove(id)
            // Also clear primary if it matches
            if selectedVideoClipID == id    { selectedVideoClipID = nil }
            if selectedImageClipID == id    { selectedImageClipID = nil }
            if selectedAudioClipID == id    { selectedAudioClipID = nil }
            if selectedSubtitleClipID == id { selectedSubtitleClipID = nil }
            if selectedTextClipID == id     { selectedTextClipID = nil }
        } else {
            // Move current primary into multi-set if needed
            if let pid = selectedVideoClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedImageClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedAudioClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedSubtitleClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedTextClipID, pid != id { selectedClipIDs.insert(pid) }
            selectedClipIDs.insert(id)
            // Set as new primary based on type
            if videoTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedVideoClipID = id
                selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedImageClipID = id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if audioTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedAudioClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
            } else if subtitleTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedSubtitleClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedTextClipID = nil
            } else if textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedTextClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil
            }
        }
    }

    /// 把当前主选中片段合并进 selectedClipIDs（用于向左/右全选等场景）
    func mergePrimaryIntoSelection() {
        if let pid = selectedVideoClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedImageClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedAudioClipID    { selectedClipIDs.insert(pid) }
        if let pid = selectedSubtitleClipID { selectedClipIDs.insert(pid) }
        if let pid = selectedTextClipID     { selectedClipIDs.insert(pid) }
    }

    /// 向左全选：选中同轨道中 startTime <= 当前片段的所有片段
    func selectLeftOf(_ id: UUID) {
        mergePrimaryIntoSelection()
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
    }

    /// 向右全选：选中同轨道中 startTime >= 当前片段的所有片段
    func selectRightOf(_ id: UUID) {
        mergePrimaryIntoSelection()
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in imageTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in subtitleTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
    }

    // MARK: - Add to Timeline

    func addToTimeline(_ asset: MediaAsset) {
        pushUndo()
        switch asset.type {
        case .video:
            // 每条视频放到独立的视频轨道，方便多轨编辑
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            Task {
                let avAsset = AVURLAsset(url: asset.url)
                let dur = (try? await avAsset.load(.duration))?.seconds ?? 30
                var natW: Double = 0, natH: Double = 0
                if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first,
                   let sz = try? await vTrack.load(.naturalSize) {
                    natW = sz.width; natH = sz.height
                }
                let finalW = natW, finalH = natH
                await MainActor.run {
                    self.videoTracks[trackIdx].clips.append(
                        VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: 0, endTime: dur, videoWidth: finalW, videoHeight: finalH))
                    self.duration = max(self.duration, dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .audio:
            let trackIdx: Int
            if let emptyIdx = audioTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                audioTracks.append(Track(label: "音频"))
                trackIdx = audioTracks.count - 1
            }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[trackIdx].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: 0, endTime: dur))
                    self.duration = max(self.duration, dur)
                    if let i = self.mediaAssets.firstIndex(where:{ $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .subtitle:
            let ext = asset.url.pathExtension.lowercased()
            var clips: [SubtitleClip]
            switch ext {
            case "ass": clips = parseASS(url: asset.url)
            case "vtt": clips = parseVTT(url: asset.url)
            default:    clips = parseSRT(url: asset.url)
            }
            // 给每个字幕片段打上素材 ID，供级联删除使用
            for i in clips.indices { clips[i].assetID = asset.id }
            // Use the first empty subtitle track if available; otherwise create
            // a brand-new track so each imported subtitle file lives on its own
            // line (so bilingual / multi-language workflows don't merge).
            if let idx = subtitleTracks.firstIndex(where: { $0.clips.isEmpty }) {
                subtitleTracks[idx].clips = clips
                if subtitleTracks[idx].subtitleStyle == nil {
                    subtitleTracks[idx].subtitleStyle = newSubtitleStyle()
                }
            } else {
                var newTrack = Track<SubtitleClip>(clips: clips, label: "字幕")
                newTrack.subtitleStyle = newSubtitleStyle()
                subtitleTracks.append(newTrack)
                syncOverlayOrder()
            }
            if let mx = clips.map(\.endTime).max() { duration = max(duration, mx) }
            if let i = mediaAssets.firstIndex(where:{ $0.id == asset.id }) {
                mediaAssets[i].duration = clips.last?.endTime ?? 0
            }
        case .image:
            let trackIdx: Int
            if let emptyIdx = imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                imageTracks.append(Track(label: "图片"))
                syncOverlayOrder()
                trackIdx = imageTracks.count - 1
            }
            let dur = 5.0
            let videoURL = imageVideoCache[asset.id]
            var imgW = 0, imgH = 0
            if let img = NSImage(contentsOf: asset.url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imgW = cg.width; imgH = cg.height
            }
            imageTracks[trackIdx].clips.append(
                ImageClip(assetID: asset.id, name: asset.name, imageURL: asset.url,
                          videoURL: videoURL, startTime: 0, endTime: dur,
                          imageWidth: imgW, imageHeight: imgH))
            duration = max(duration, dur)
            // Generate video if not cached yet, then update clip
            if videoURL == nil {
                let aid = asset.id
                let imgURL = asset.url
                let ti = trackIdx
                Task {
                    guard let vURL = await Self.createVideoFromImage(imageURL: imgURL, duration: dur) else { return }
                    await MainActor.run {
                        self.imageVideoCache[aid] = vURL
                        for ci in self.imageTracks[ti].clips.indices where self.imageTracks[ti].clips[ci].assetID == aid {
                            self.imageTracks[ti].clips[ci].videoURL = vURL
                        }
                        self.rebuildTimelinePreview()
                    }
                }
            } else {
                rebuildTimelinePreview()
            }
        }
    }

    /// Add asset to timeline at a specific time position (used for drag-drop from media library)
    func addToTimelineAt(_ asset: MediaAsset, time: Double) {
        pushUndo()
        let insertTime = max(0, time)
        switch asset.type {
        case .video:
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            Task {
                let avAsset = AVURLAsset(url: asset.url)
                let dur = (try? await avAsset.load(.duration))?.seconds ?? 30
                var natW: Double = 0, natH: Double = 0
                if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first,
                   let sz = try? await vTrack.load(.naturalSize) {
                    natW = sz.width; natH = sz.height
                }
                let finalW = natW, finalH = natH
                await MainActor.run {
                    self.videoTracks[trackIdx].clips.append(
                        VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: insertTime, endTime: insertTime + dur,
                                  videoWidth: finalW, videoHeight: finalH))
                    self.duration = max(self.duration, insertTime + dur)
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .audio:
            let audioTrackIdx: Int
            if let emptyIdx = audioTracks.firstIndex(where: { $0.clips.isEmpty }) {
                audioTrackIdx = emptyIdx
            } else {
                audioTracks.append(Track(label: "音频"))
                audioTrackIdx = audioTracks.count - 1
            }
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    self.audioTracks[audioTrackIdx].clips.append(
                        AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: insertTime, endTime: insertTime + dur))
                    self.duration = max(self.duration, insertTime + dur)
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == asset.id }) { self.mediaAssets[i].duration = dur }
                    self.rebuildTimelinePreview()
                }
            }
        case .image:
            let trackIdx: Int
            if let emptyIdx = imageTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                imageTracks.append(Track(label: "图片"))
                syncOverlayOrder()
                trackIdx = imageTracks.count - 1
            }
            let dur = 5.0
            let videoURL = imageVideoCache[asset.id]
            var imgW = 0, imgH = 0
            if let img = NSImage(contentsOf: asset.url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imgW = cg.width; imgH = cg.height
            }
            imageTracks[trackIdx].clips.append(
                ImageClip(assetID: asset.id, name: asset.name, imageURL: asset.url,
                          videoURL: videoURL, startTime: insertTime, endTime: insertTime + dur,
                          imageWidth: imgW, imageHeight: imgH))
            duration = max(duration, insertTime + dur)
            if videoURL == nil {
                let aid = asset.id; let imgURL = asset.url; let ti = trackIdx
                Task {
                    guard let vURL = await Self.createVideoFromImage(imageURL: imgURL, duration: dur) else { return }
                    await MainActor.run {
                        self.imageVideoCache[aid] = vURL
                        for ci in self.imageTracks[ti].clips.indices where self.imageTracks[ti].clips[ci].assetID == aid {
                            self.imageTracks[ti].clips[ci].videoURL = vURL
                        }
                        self.rebuildTimelinePreview()
                    }
                }
            } else {
                rebuildTimelinePreview()
            }
        case .subtitle:
            // Subtitles use parsed timing, not drop position — delegate to normal add
            addToTimeline(asset)
        }
    }

    // MARK: - Mutation helpers

    func updateSubtitleText(id: UUID, text: String) {
        pushUndoThrottled()
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                subtitleTracks[i].clips[j].text = text; return
            }
        }
    }

    func updateSubtitleTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in subtitleTracks.indices {
            if let j = subtitleTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                if let s = start { subtitleTracks[i].clips[j].startTime = s }
                if let e = end   { subtitleTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    func updateVideoClip(id: UUID, _ modify: (inout VideoClip) -> Void) {
        pushUndoThrottled()
        for i in videoTracks.indices {
            if let j = videoTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&videoTracks[i].clips[j]); return
            }
        }
    }

    func updateImageClip(id: UUID, _ modify: (inout ImageClip) -> Void) {
        pushUndoThrottled()
        for i in imageTracks.indices {
            if let j = imageTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&imageTracks[i].clips[j]); return
            }
        }
    }

    func updateAudioClip(id: UUID, _ modify: (inout AudioClip) -> Void) {
        pushUndoThrottled()
        for i in audioTracks.indices {
            if let j = audioTracks[i].clips.firstIndex(where:{ $0.id == id }) {
                modify(&audioTracks[i].clips[j]); return
            }
        }
    }

    /// Insert a new subtitle clip into the active subtitle track at the playhead.
    func insertSubtitleAtPlayhead() {
        let snap = currentSnapshot()

        let trackIdx: Int
        if let sid = selectedSubtitleClipID {
            // 选中了字幕片段 → 在其所在轨道新建
            trackIdx = subtitleTracks.firstIndex { $0.clips.contains { $0.id == sid } } ?? 0
        } else {
            // 没选中任何字幕 → 新建轨道（放在最后）
            var newTrack = Track<SubtitleClip>(label: "字幕")
            newTrack.subtitleStyle = newSubtitleStyle()
            subtitleTracks.append(newTrack)
            syncOverlayOrder()
            trackIdx = subtitleTracks.count - 1
        }

        let start = currentTime
        let end   = min(currentTime + 2.0, max(duration, currentTime + 2.0))
        let clip  = SubtitleClip(text: "新字幕", startTime: start, endTime: end)
        subtitleTracks[trackIdx].clips.append(clip)
        subtitleTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        selectedSubtitleClipID = clip.id

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }

    // MARK: - 文字/标题图层

    /// 在播放头插入文字图层（选中文字则在其轨道，否则用最后一条文字轨道，无则新建）
    func addTextAtPlayhead() {
        let snap = currentSnapshot()
        let trackIdx: Int
        if let tid = selectedTextClipID,
           let i = textTracks.firstIndex(where: { $0.clips.contains { $0.id == tid } }) {
            trackIdx = i
        } else if !textTracks.isEmpty {
            trackIdx = textTracks.count - 1
        } else {
            textTracks.append(Track<TextClip>(label: "文字"))
            syncOverlayOrder()
            trackIdx = textTracks.count - 1
        }
        let start = currentTime
        let end   = currentTime + 3.0
        let clip  = TextClip(text: "标题文字", startTime: start, endTime: end)
        textTracks[trackIdx].clips.append(clip)
        textTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        // 选中新建的文字，清其他选中
        selectedTextClipID = clip.id
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()

        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        isSaved = false
    }

    /// 更新指定文字片段（Inspector 编辑用）
    func updateTextClip(id: UUID, _ mutate: (inout TextClip) -> Void) {
        for ti in textTracks.indices {
            if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&textTracks[ti].clips[ci])
                isSaved = false
                return
            }
        }
    }

    /// 删除指定文字片段
    func deleteTextClip(id: UUID) {
        let snap = currentSnapshot()
        for ti in textTracks.indices {
            if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                textTracks[ti].clips.remove(at: ci)
                if selectedTextClipID == id { selectedTextClipID = nil }
                undoStack.append(snap)
                if undoStack.count > 30 { undoStack.removeFirst() }
                redoStack.removeAll()
                undoCount = undoStack.count; redoCount = 0
                isSaved = false
                return
            }
        }
    }

    // MARK: - 文字样式模板

    func saveTextTemplate(from clipID: UUID, name: String) {
        guard let clip = textTracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { return }
        let template = TextTemplate.from(clip, name: name)
        textTemplates.append(template)
        isSaved = false
        scheduleAutoSave()
    }

    func saveTextTemplateFromClip(_ clipID: UUID) {
        let idx = textTemplates.count + 1
        saveTextTemplate(from: clipID, name: "模板 \(idx)")
    }

    func applyTextTemplate(_ template: TextTemplate, to clipID: UUID) {
        pushUndo()
        updateTextClip(id: clipID) { clip in
            template.apply(to: &clip)
        }
    }

    func deleteTextTemplate(id: UUID) {
        textTemplates.removeAll { $0.id == id }
        isSaved = false
        scheduleAutoSave()
    }
}
