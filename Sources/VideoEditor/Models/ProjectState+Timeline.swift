import SwiftUI
import AVFoundation

// MARK: - Timeline Track Operations

/// 新建字幕 / 文字 / 图形片段的默认时长（秒）。三者统一，改这里就够了
let kNewClipDuration: Double = 5.0

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
        NSLog("BC_DBG txtMove IN to=%d %@", to, textTracks.map { $0.clips.map { $0.startTime } } as NSArray)
        defer { NSLog("BC_DBG txtMove OUT %@", textTracks.map { $0.clips.map { $0.startTime } } as NSArray) }
        let clip = textTracks[from].clips.remove(at: idx)
        textTracks[to].clips.append(clip)
    }

    func moveShapeClipToTrack(id: UUID, from: Int, to: Int) {
        guard shapeTracks.indices.contains(from), shapeTracks.indices.contains(to) else { return }
        guard let idx = shapeTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = shapeTracks[from].clips.remove(at: idx)
        shapeTracks[to].clips.append(clip)
    }

    func moveEffectClipToTrack(id: UUID, from: Int, to: Int) {
        guard effectTracks.indices.contains(from), effectTracks.indices.contains(to) else { return }
        guard let idx = effectTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = effectTracks[from].clips.remove(at: idx)
        effectTracks[to].clips.append(clip)
    }

    func moveAdjustClipToTrack(id: UUID, from: Int, to: Int) {
        guard adjustTracks.indices.contains(from), adjustTracks.indices.contains(to) else { return }
        guard let idx = adjustTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = adjustTracks[from].clips.remove(at: idx)
        adjustTracks[to].clips.append(clip)
    }

    func moveFilterClipToTrack(id: UUID, from: Int, to: Int) {
        guard filterTracks.indices.contains(from), filterTracks.indices.contains(to) else { return }
        guard let idx = filterTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = filterTracks[from].clips.remove(at: idx)
        filterTracks[to].clips.append(clip)
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
                    syncVideoSectionOrder()
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
                // 重叠：在目标轨道正下方新建轨道安置，保持图层顺序，不塞回原轨道
                let anchorID = imageTracks[ti].id
                let removed = imageTracks[ti].clips.remove(at: ci)
                var newTrack = Track<ImageClip>(label: "图片")
                newTrack.clips.append(removed)
                imageTracks.append(newTrack)
                insertOverlayRefAbove(.image(newTrack.id), above: anchorID)
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
                    syncAudioSectionOrder()
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
                // 重叠：在目标轨道正下方新建轨道安置，保持图层顺序，不塞回原轨道
                let anchorID = subtitleTracks[ti].id
                let removed = subtitleTracks[ti].clips.remove(at: ci)
                var newTrack = Track<SubtitleClip>(label: "字幕")
                newTrack.clips.append(removed)
                newTrack.subtitleStyle = newSubtitleStyle()
                subtitleTracks.append(newTrack)
                insertOverlayRefAbove(.subtitle(newTrack.id), above: anchorID)
            }
            return
        }
    }

    func resolveTextOverlap(id: UUID) {
        NSLog("BC_DBG txtResolve IN %@", textTracks.map { $0.clips.map { $0.startTime } } as NSArray)
        defer { NSLog("BC_DBG txtResolve OUT %@", textTracks.map { $0.clips.map { $0.startTime } } as NSArray) }
        for ti in textTracks.indices {
            guard let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = textTracks[ti].clips[ci]
            let hasOverlap = textTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                // 重叠：在目标轨道正下方新建轨道安置，保持图层顺序，不塞回原轨道
                let anchorID = textTracks[ti].id
                let removed = textTracks[ti].clips.remove(at: ci)
                var newTrack = Track<TextClip>(label: "文字")
                newTrack.clips.append(removed)
                textTracks.append(newTrack)
                insertOverlayRefAbove(.text(newTrack.id), above: anchorID)
            }
            return
        }
    }

    func resolveShapeOverlap(id: UUID) {
        for ti in shapeTracks.indices {
            guard let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = shapeTracks[ti].clips[ci]
            let hasOverlap = shapeTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let anchorID = shapeTracks[ti].id
                let removed = shapeTracks[ti].clips.remove(at: ci)
                var newTrack = Track<ShapeClip>(label: "图形")
                newTrack.clips.append(removed)
                shapeTracks.append(newTrack)
                insertOverlayRefAbove(.shape(newTrack.id), above: anchorID)
            }
            return
        }
    }

    func moveCompoundClipToTrack(id: UUID, from: Int, to: Int) {
        guard compoundTracks.indices.contains(from), compoundTracks.indices.contains(to) else { return }
        guard let idx = compoundTracks[from].clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoThrottled()
        let clip = compoundTracks[from].clips.remove(at: idx)
        compoundTracks[to].clips.append(clip)
    }

    func resolveCompoundOverlap(id: UUID) {
        for ti in compoundTracks.indices {
            guard let ci = compoundTracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = compoundTracks[ti].clips[ci]
            let hasOverlap = compoundTracks[ti].clips.contains {
                $0.id != id && $0.startTime < clip.endTime - 0.001 && $0.endTime > clip.startTime + 0.001
            }
            if hasOverlap {
                let kind = compoundTrackKind(compoundTracks[ti])
                let anchorID = compoundTracks[ti].id
                let removed = compoundTracks[ti].clips.remove(at: ci)
                var newTrack = Track<CompoundClip>(label: "复合")
                newTrack.clips.append(removed)
                compoundTracks.append(newTrack)
                syncOverlayOrder()
                if kind == .overlay {
                    insertOverlayRefAbove(.compound(newTrack.id), above: anchorID)
                } else if kind == .video {
                    if let ai = videoSectionOrder.firstIndex(where: { $0.trackID == anchorID }) {
                        videoSectionOrder.insert(.compound(newTrack.id), at: ai + 1)
                    }
                } else if kind == .audio {
                    if let ai = audioSectionOrder.firstIndex(where: { $0.trackID == anchorID }) {
                        audioSectionOrder.insert(.compound(newTrack.id), at: ai + 1)
                    }
                }
            }
            return
        }
    }

    func updateCompoundClip(id: UUID, _ modify: (inout CompoundClip) -> Void) {
        pushUndoThrottled()
        for i in compoundTracks.indices {
            if let j = compoundTracks[i].clips.firstIndex(where: { $0.id == id }) {
                modify(&compoundTracks[i].clips[j]); return
            }
        }
    }

    func updateShapeTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in shapeTracks.indices {
            if let j = shapeTracks[i].clips.firstIndex(where: { $0.id == id }) {
                if let s = start { shapeTracks[i].clips[j].startTime = s }
                if let e = end   { shapeTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    /// 为新字幕轨自动计算 bottomMargin，避免与已有轨道重叠
    /// 新字幕轨道的默认样式。给了文本就按语言定字号（纯英文小一档）
    func newSubtitleStyle(for texts: [String] = []) -> SubtitleStyle {
        var s = SubtitleStyle()
        if !texts.isEmpty {
            s.fontSize = SubtitleStyle.defaultFontSize(forSubtitles: texts)
        }
        return s
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

    func updateCompoundTime(id: UUID, start: Double? = nil, end: Double? = nil) {
        pushUndoThrottled()
        for i in compoundTracks.indices {
            if let j = compoundTracks[i].clips.firstIndex(where: { $0.id == id }) {
                if let s = start { compoundTracks[i].clips[j].startTime = s }
                if let e = end   { compoundTracks[i].clips[j].endTime   = e }
                return
            }
        }
    }

    // MARK: - Multi-select helpers

    /// Shift+click: toggle a clip in/out of multi-selection
    func shiftToggleClip(_ id: UUID) {
        if selectedClipIDs.contains(id) {
            selectedClipIDs.remove(id)
            if selectedVideoClipID == id    { selectedVideoClipID = nil }
            if selectedImageClipID == id    { selectedImageClipID = nil }
            if selectedAudioClipID == id    { selectedAudioClipID = nil }
            if selectedSubtitleClipID == id { selectedSubtitleClipID = nil }
            if selectedTextClipID == id     { selectedTextClipID = nil }
            if selectedShapeClipID == id    { selectedShapeClipID = nil }
            if selectedCompoundClipID == id { selectedCompoundClipID = nil }
        } else {
            if let pid = selectedVideoClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedImageClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedAudioClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedSubtitleClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedTextClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedShapeClipID, pid != id { selectedClipIDs.insert(pid) }
            if let pid = selectedCompoundClipID, pid != id { selectedClipIDs.insert(pid) }
            selectedClipIDs.insert(id)
            if compoundTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedCompoundClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil
            } else if videoTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedVideoClipID = id
                selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil; selectedCompoundClipID = nil
            } else if imageTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedImageClipID = id
                selectedVideoClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil; selectedCompoundClipID = nil
            } else if audioTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedAudioClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil; selectedCompoundClipID = nil
            } else if subtitleTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedSubtitleClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil; selectedCompoundClipID = nil
            } else if textTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedTextClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedShapeClipID = nil; selectedCompoundClipID = nil
            } else if shapeTracks.flatMap(\.clips).contains(where: { $0.id == id }) {
                selectedShapeClipID = id
                selectedVideoClipID = nil; selectedImageClipID = nil; selectedAudioClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil; selectedCompoundClipID = nil
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
        if let pid = selectedCompoundClipID { selectedClipIDs.insert(pid) }
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
        for track in textTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime <= clip.startTime }.map(\.id)); return
            }
        }
        for track in shapeTracks {
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
        for track in textTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectedClipIDs.formUnion(track.clips.filter { $0.startTime >= clip.startTime }.map(\.id)); return
            }
        }
        for track in shapeTracks {
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
            let trackIdx: Int
            if let emptyIdx = videoTracks.firstIndex(where: { $0.clips.isEmpty }) {
                trackIdx = emptyIdx
            } else {
                videoTracks.append(Track(label: "视频"))
                trackIdx = videoTracks.count - 1
            }
            syncVideoSectionOrder()
            let placeholderDur = asset.duration > 0 ? asset.duration : 30.0
            let clip = VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                 startTime: 0, endTime: placeholderDur)
            videoTracks[trackIdx].clips.append(clip)
            duration = max(duration, placeholderDur)
            rebuildTimelinePreview()
            let clipID = clip.id
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
                    for ti in self.videoTracks.indices {
                        if let ci = self.videoTracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                            self.videoTracks[ti].clips[ci].endTime = dur
                            self.videoTracks[ti].clips[ci].videoWidth = finalW
                            self.videoTracks[ti].clips[ci].videoHeight = finalH
                            break
                        }
                    }
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
            syncAudioSectionOrder()
            let placeholderDur = asset.duration > 0 ? asset.duration : 30.0
            let clip = AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                 startTime: 0, endTime: placeholderDur)
            audioTracks[trackIdx].clips.append(clip)
            duration = max(duration, placeholderDur)
            rebuildTimelinePreview()
            let clipID = clip.id
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    for ti in self.audioTracks.indices {
                        if let ci = self.audioTracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                            self.audioTracks[ti].clips[ci].endTime = dur
                            break
                        }
                    }
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
                newTrack.subtitleStyle = newSubtitleStyle(for: clips.map(\.text))
                subtitleTracks.append(newTrack)
                overlayTrackOrder.insert(.subtitle(newTrack.id), at: 0)
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
                let newTrack = Track<ImageClip>(label: "图片")
                imageTracks.append(newTrack)
                overlayTrackOrder.insert(.image(newTrack.id), at: 0)
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
    func addToTimelineAt(_ asset: MediaAsset, time: Double, skipUndo: Bool = false) {
        if !skipUndo { pushUndo() }
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
            syncVideoSectionOrder()
            let placeholderDur = asset.duration > 0 ? asset.duration : 30.0
            let clip = VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                                 startTime: insertTime, endTime: insertTime + placeholderDur)
            videoTracks[trackIdx].clips.append(clip)
            duration = max(duration, insertTime + placeholderDur)
            rebuildTimelinePreview()
            let clipID = clip.id
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
                    for ti in self.videoTracks.indices {
                        if let ci = self.videoTracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                            self.videoTracks[ti].clips[ci].endTime = insertTime + dur
                            self.videoTracks[ti].clips[ci].videoWidth = finalW
                            self.videoTracks[ti].clips[ci].videoHeight = finalH
                            break
                        }
                    }
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
            syncAudioSectionOrder()
            let placeholderDur = asset.duration > 0 ? asset.duration : 30.0
            let aClip = AudioClip(assetID: asset.id, name: asset.name, url: asset.url,
                                  startTime: insertTime, endTime: insertTime + placeholderDur)
            audioTracks[audioTrackIdx].clips.append(aClip)
            duration = max(duration, insertTime + placeholderDur)
            rebuildTimelinePreview()
            let aClipID = aClip.id
            Task {
                let dur = (try? await AVURLAsset(url: asset.url).load(.duration))?.seconds ?? 30
                await MainActor.run {
                    for ti in self.audioTracks.indices {
                        if let ci = self.audioTracks[ti].clips.firstIndex(where: { $0.id == aClipID }) {
                            self.audioTracks[ti].clips[ci].endTime = insertTime + dur
                            break
                        }
                    }
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
                let newTrack = Track<ImageClip>(label: "图片")
                imageTracks.append(newTrack)
                overlayTrackOrder.insert(.image(newTrack.id), at: 0)
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
        defer { refreshOverlayComposite() }
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
                modify(&imageTracks[i].clips[j])
                refreshOverlayComposite()
                return
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
    /// 在播放头插入字幕。`text` 留空用默认占位文案 ——
    /// 聊天面板右键「添加到字幕」会把选中的文字带进来
    func insertSubtitleAtPlayhead(text: String? = nil) {
        let snap = currentSnapshot()

        let start = currentTime
        let end   = min(currentTime + kNewClipDuration,
                        max(duration, currentTime + kNewClipDuration))

        let trackIdx: Int
        if let sid = selectedSubtitleClipID,
           let i = subtitleTracks.firstIndex(where: { $0.clips.contains { $0.id == sid } }) {
            let hasOverlap = subtitleTracks[i].clips.contains { $0.startTime < end && $0.endTime > start }
            if hasOverlap {
                var newTrack = Track<SubtitleClip>(label: "字幕")
                newTrack.subtitleStyle = subtitleTracks[i].subtitleStyle ?? newSubtitleStyle()
                subtitleTracks.append(newTrack)
                overlayTrackOrder.insert(.subtitle(newTrack.id), at: 0)
                trackIdx = subtitleTracks.count - 1
            } else {
                trackIdx = i
            }
        } else if let i = subtitleTracks.firstIndex(where: { t in
            !t.clips.contains { $0.startTime < end && $0.endTime > start }
        }) {
            trackIdx = i
        } else {
            var newTrack = Track<SubtitleClip>(label: "字幕")
            newTrack.subtitleStyle = newSubtitleStyle()
            subtitleTracks.append(newTrack)
            overlayTrackOrder.insert(.subtitle(newTrack.id), at: 0)
            trackIdx = subtitleTracks.count - 1
        }

        let clip  = SubtitleClip(text: text ?? "新字幕", startTime: start, endTime: end)
        subtitleTracks[trackIdx].clips.append(clip)
        subtitleTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        selectedSubtitleClipID = clip.id
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedTextClipID = nil; selectedShapeClipID = nil
        selectedCompoundClipID = nil; selectedClipIDs.removeAll()

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
    }

    // MARK: - 文字/标题图层

    /// 在播放头插入文字图层（选中文字则在其轨道，否则用最后一条文字轨道，无则新建）
    func addTextAtPlayhead(text: String? = nil) {
        let snap = currentSnapshot()
        let start = currentTime
        let end   = currentTime + kNewClipDuration

        let trackIdx: Int
        if let tid = selectedTextClipID,
           let i = textTracks.firstIndex(where: { $0.clips.contains { $0.id == tid } }) {
            let hasOverlap = textTracks[i].clips.contains { $0.startTime < end && $0.endTime > start }
            if hasOverlap {
                let newTrack = Track<TextClip>(label: "文字")
                textTracks.append(newTrack)
                overlayTrackOrder.insert(.text(newTrack.id), at: 0)
                trackIdx = textTracks.count - 1
            } else {
                trackIdx = i
            }
        } else if let i = textTracks.firstIndex(where: { t in
            !t.clips.contains { $0.startTime < end && $0.endTime > start }
        }) {
            trackIdx = i
        } else {
            let newTrack = Track<TextClip>(label: "文字")
            textTracks.append(newTrack)
            overlayTrackOrder.insert(.text(newTrack.id), at: 0)
            trackIdx = textTracks.count - 1
        }

        let clip  = TextClip(text: text ?? "标题文字", startTime: start, endTime: end)
        textTracks[trackIdx].clips.append(clip)
        textTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        // 选中新建的文字，清其他选中
        selectedTextClipID = clip.id
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil; selectedShapeClipID = nil
        selectedCompoundClipID = nil; selectedClipIDs.removeAll()

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
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
                refreshOverlayComposite()
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
                // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
                if !suppressUndoPush {
                    undoStack.append(snap)
                }
                if undoStack.count > 30 { undoStack.removeFirst() }
                redoStack.removeAll()
                undoCount = undoStack.count; redoCount = 0
                isSaved = false
                return
            }
        }
    }

    // MARK: - 图形图层

    /// 在播放头处添加图形片段（无轨道则新建），并选中它。参照 addTextAtPlayhead。
    func addShapeAtPlayhead(type: ShapeType) {
        addShape(type: type, at: currentTime)
    }

    /// 在指定时间插入图形。点击素材库图形卡片走播放头位置，
    /// 从素材库拖到时间轴则走落点换算出来的时间
    func addShape(type: ShapeType, at time: Double) {
        let snap = currentSnapshot()
        let start = max(0, time)
        let end   = start + kNewClipDuration
        let trackIdx: Int
        if shapeTracks.isEmpty {
            let newTrack = Track<ShapeClip>(label: "图形")
            shapeTracks.append(newTrack)
            overlayTrackOrder.insert(.shape(newTrack.id), at: 0)
            trackIdx = shapeTracks.count - 1
        } else {
            var candidate: Int
            if let sid = selectedShapeClipID,
               let i = shapeTracks.firstIndex(where: { $0.clips.contains { $0.id == sid } }) {
                candidate = i
            } else {
                candidate = shapeTracks.count - 1
            }
            let overlaps = shapeTracks[candidate].clips.contains { c in
                c.startTime < end && c.endTime > start
            }
            if overlaps {
                if let freeIdx = shapeTracks.indices.first(where: { idx in
                    !shapeTracks[idx].clips.contains { c in c.startTime < end && c.endTime > start }
                }) {
                    candidate = freeIdx
                } else {
                    let newTrack = Track<ShapeClip>(label: "图形")
                    shapeTracks.append(newTrack)
                    overlayTrackOrder.insert(.shape(newTrack.id), at: 0)
                    candidate = shapeTracks.count - 1
                }
            }
            trackIdx = candidate
        }
        var clip  = ShapeClip(type: type, startTime: start, endTime: end)
        // 基准尺寸按预览分辨率给合适比例
        let rs = previewRenderSize
        if type == .pen {
            clip.width = Double(rs.width) * 0.3; clip.height = Double(rs.height) * 0.3
            penRawPoints = []
            penDrawingMode = true
        } else if type.isClosed {
            let side = Double(rs.height) * 0.18
            clip.width = side; clip.height = side
        } else if type == .line {
            clip.width = Double(rs.width) * 0.1; clip.height = Double(rs.height) * 0.03
        } else {
            clip.width = Double(rs.width) * 0.084; clip.height = Double(rs.height) * 0.028
        }
        shapeTracks[trackIdx].clips.append(clip)
        shapeTracks[trackIdx].clips.sort { $0.startTime < $1.startTime }
        // 选中新建图形，清其他选中
        selectedShapeClipID = clip.id
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil; selectedTextClipID = nil
        selectedClipIDs.removeAll()

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        isSaved = false
    }

    /// 更新指定图形片段（Inspector / 预览编辑用）
    func updateShapeClip(id: UUID, _ mutate: (inout ShapeClip) -> Void) {
        for ti in shapeTracks.indices {
            if let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&shapeTracks[ti].clips[ci])
                isSaved = false
                refreshOverlayComposite()
                return
            }
        }
    }

    /// 删除指定图形片段
    func deleteShapeClip(id: UUID) {
        let snap = currentSnapshot()
        for ti in shapeTracks.indices {
            if let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                shapeTracks[ti].clips.remove(at: ci)
                if selectedShapeClipID == id { selectedShapeClipID = nil }
                // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
                if !suppressUndoPush {
                    undoStack.append(snap)
                }
                if undoStack.count > 30 { undoStack.removeFirst() }
                redoStack.removeAll()
                undoCount = undoStack.count; redoCount = 0
                isSaved = false
                return
            }
        }
    }

    /// 完成钢笔路径绘制（由 PenDrawingOverlay 调用）
    func finalizePenDrawing(clipID: UUID, rawPoints: [(x: Double, y: Double, cInDX: Double, cInDY: Double, cOutDX: Double, cOutDY: Double, smooth: Bool)], closed: Bool) {
        guard rawPoints.count >= 2 else {
            deleteShapeClip(id: clipID)
            penDrawingMode = false
            return
        }
        let allX = rawPoints.flatMap { p in [p.x, p.x + p.cInDX, p.x + p.cOutDX] }
        let allY = rawPoints.flatMap { p in [p.y, p.y + p.cInDY, p.y + p.cOutDY] }
        let minX = allX.min()!, maxX = allX.max()!, minY = allY.min()!, maxY = allY.max()!
        let pad = 4.0
        let bx = minX - pad, by = minY - pad
        let bw = max(maxX - minX + pad * 2, 8), bh = max(maxY - minY + pad * 2, 8)

        let points: [PenPoint] = rawPoints.map { p in
            PenPoint(x: (p.x - bx) / bw, y: (p.y - by) / bh,
                     ctrlInDX: p.cInDX / bw, ctrlInDY: p.cInDY / bh,
                     ctrlOutDX: p.cOutDX / bw, ctrlOutDY: p.cOutDY / bh,
                     smooth: p.smooth)
        }

        updateShapeClip(id: clipID) { c in
            c.width = bw; c.height = bh
            c.posX = (bx + bw / 2) / max(Double(previewRenderSize.width), 1)
            c.posY = (by + bh / 2) / max(Double(previewRenderSize.height), 1)
            c.penPoints = points
            c.penClosed = closed
            if closed { c.fillEnabled = true; c.fillColor = .white; c.fillOpacity = 0.3 }
        }
        penDrawingMode = false
    }

    /// 取消钢笔绘制
    func cancelPenDrawing(clipID: UUID) {
        deleteShapeClip(id: clipID)
        penDrawingMode = false
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

// MARK: - 图层对齐（图片 / 文字 / 图形共用）

extension ProjectState {
    /// 图层在**渲染坐标系**里的中心和尺寸。对齐和多选包围盒都靠它。
    ///
    /// 三种元素存位置的方式不一样：图片是相对画面的偏移（0 = 居中），
    /// 文字和图形是 0~1 的中心点，这里统一换算成像素
    func layerBounds(for id: UUID) -> (center: CGPoint, size: CGSize)? {
        let rw = Double(previewRenderSize.width), rh = Double(previewRenderSize.height)
        guard rw > 0, rh > 0 else { return nil }

        if let s = shapeTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
            return (CGPoint(x: s.posX * rw, y: s.posY * rh),
                    CGSize(width: s.width * s.scaleX, height: s.height * s.scaleY))
        }
        if let t = textTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
            let box = textLayerSize(t)
            return (CGPoint(x: t.posX * rw, y: t.posY * rh), box)
        }
        if let i = imageTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
            let natW = Double(i.imageWidth), natH = Double(i.imageHeight)
            guard natW > 0, natH > 0 else { return nil }
            let fit = rotatedFitSize(CGSize(width: natW, height: natH), rotation: i.rotation)
            let base = min(rw / Double(fit.width), rh / Double(fit.height))
            return (CGPoint(x: (0.5 + i.offsetX) * rw, y: (0.5 + i.offsetY) * rh),
                    CGSize(width: natW * base * i.scaleX, height: natH * base * i.scaleY))
        }
        return nil
    }

    /// 文字图层的尺寸（渲染坐标）。拖过边定死了范围框就用它，否则按文字量一次
    private func textLayerSize(_ t: TextClip) -> CGSize {
        if let w = t.boxWidth {
            return CGSize(width: w + 20, height: (t.boxHeight ?? Double(t.fontSize) * 1.4) + 10)
        }
        var font = NSFont(name: t.fontName, size: t.fontSize) ?? NSFont.systemFont(ofSize: t.fontSize)
        if t.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        let str = t.text.isEmpty ? " " : t.text
        let sz = (str as NSString).size(withAttributes: [.font: font])
        return CGSize(width: sz.width + 20, height: sz.height + 10)
    }

    /// 把图层挪到中心点（渲染坐标）
    private func moveLayer(_ id: UUID, to c: CGPoint) {
        let rw = Double(previewRenderSize.width), rh = Double(previewRenderSize.height)
        guard rw > 0, rh > 0 else { return }
        if shapeTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            updateShapeClip(id: id) { $0.posX = Double(c.x) / rw; $0.posY = Double(c.y) / rh }
        } else if textTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            updateTextClip(id: id) { $0.posX = Double(c.x) / rw; $0.posY = Double(c.y) / rh }
        } else if imageTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            updateImageClip(id: id) {
                $0.offsetX = Double(c.x) / rw - 0.5
                $0.offsetY = Double(c.y) / rh - 0.5
            }
        }
    }

    /// 对齐。**只选中一个就对齐画面，多选就对齐选中那几个的包围盒**；
    /// 分布要三个以上才有意义
    func alignLayers(_ mode: LayerAlignMode, anchorID: UUID) {
        let ids = selectedClipIDs.count > 1 ? Array(selectedClipIDs) : [anchorID]
        let items = ids.compactMap { id -> (id: UUID, c: CGPoint, s: CGSize)? in
            guard let b = layerBounds(for: id) else { return nil }
            return (id, b.center, b.size)
        }
        guard !items.isEmpty else { return }
        let rw = Double(previewRenderSize.width), rh = Double(previewRenderSize.height)
        let single = items.count <= 1
        let left = single ? 0 : items.map { Double($0.c.x) - Double($0.s.width) / 2 }.min()!
        let right = single ? rw : items.map { Double($0.c.x) + Double($0.s.width) / 2 }.max()!
        let top = single ? 0 : items.map { Double($0.c.y) - Double($0.s.height) / 2 }.min()!
        let bottom = single ? rh : items.map { Double($0.c.y) + Double($0.s.height) / 2 }.max()!

        pushUndo()
        switch mode {
        case .left:
            for it in items { moveLayer(it.id, to: CGPoint(x: left + Double(it.s.width) / 2, y: Double(it.c.y))) }
        case .hcenter:
            let cx = (left + right) / 2
            for it in items { moveLayer(it.id, to: CGPoint(x: cx, y: Double(it.c.y))) }
        case .right:
            for it in items { moveLayer(it.id, to: CGPoint(x: right - Double(it.s.width) / 2, y: Double(it.c.y))) }
        case .top:
            for it in items { moveLayer(it.id, to: CGPoint(x: Double(it.c.x), y: top + Double(it.s.height) / 2)) }
        case .vcenter:
            let cy = (top + bottom) / 2
            for it in items { moveLayer(it.id, to: CGPoint(x: Double(it.c.x), y: cy)) }
        case .bottom:
            for it in items { moveLayer(it.id, to: CGPoint(x: Double(it.c.x), y: bottom - Double(it.s.height) / 2)) }
        case .hdist:
            let sorted = items.sorted { $0.c.x < $1.c.x }
            guard sorted.count >= 3 else { return }
            let total = sorted.reduce(0.0) { $0 + Double($1.s.width) }
            let spanL = Double(sorted.first!.c.x) - Double(sorted.first!.s.width) / 2
            let spanR = Double(sorted.last!.c.x) + Double(sorted.last!.s.width) / 2
            let gap = (spanR - spanL - total) / Double(sorted.count - 1)
            var cur = spanL
            for it in sorted {
                moveLayer(it.id, to: CGPoint(x: cur + Double(it.s.width) / 2, y: Double(it.c.y)))
                cur += Double(it.s.width) + gap
            }
        case .vdist:
            let sorted = items.sorted { $0.c.y < $1.c.y }
            guard sorted.count >= 3 else { return }
            let total = sorted.reduce(0.0) { $0 + Double($1.s.height) }
            let spanT = Double(sorted.first!.c.y) - Double(sorted.first!.s.height) / 2
            let spanB = Double(sorted.last!.c.y) + Double(sorted.last!.s.height) / 2
            let gap = (spanB - spanT - total) / Double(sorted.count - 1)
            var cur = spanT
            for it in sorted {
                moveLayer(it.id, to: CGPoint(x: Double(it.c.x), y: cur + Double(it.s.height) / 2))
                cur += Double(it.s.height) + gap
            }
        }
        rebuildTimelinePreviewDebounced()
    }
}

// MARK: - 多选属性面板的数据源

extension ProjectState {
    /// 当前多选里那些能一起调的图层（图片 / 文字 / 图形）。
    /// 视频、音频、字幕这些不参与 —— 它们没有共同的位置和缩放语义
    func multiLayerHandles() -> [MultiLayerHandle] {
        let rw = Double(previewRenderSize.width), rh = Double(previewRenderSize.height)
        guard rw > 0, rh > 0 else { return [] }

        return selectedClipIDs.compactMap { id -> MultiLayerHandle? in
            guard let b = layerBounds(for: id) else { return nil }

            if let s = shapeTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
                return MultiLayerHandle(
                    id: id, center: b.center, size: b.size, opacity: s.opacity,
                    scaleBy: { k in self.updateShapeClip(id: id) { $0.scaleX *= k; $0.scaleY *= k } },
                    moveBy: { d in self.updateShapeClip(id: id) {
                        $0.posX = min(1, max(0, $0.posX + Double(d.x) / rw))
                        $0.posY = min(1, max(0, $0.posY + Double(d.y) / rh))
                    } },
                    rotateBy: { d in self.updateShapeClip(id: id) { $0.rotation += d } },
                    setOpacity: { v in self.updateShapeClip(id: id) { $0.opacity = v } })
            }
            if let t = textTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
                return MultiLayerHandle(
                    id: id, center: b.center, size: b.size, opacity: t.opacity,
                    // 文字的「放大」是字号加范围框一起走，跟拖四角圆点一个意思
                    scaleBy: { k in self.updateTextClip(id: id) {
                        $0.fontSize = max(8, $0.fontSize * CGFloat(k))
                        if let w = $0.boxWidth { $0.boxWidth = w * k }
                        if let h = $0.boxHeight { $0.boxHeight = h * k }
                    } },
                    moveBy: { d in self.updateTextClip(id: id) {
                        $0.posX = min(1, max(0, $0.posX + Double(d.x) / rw))
                        $0.posY = min(1, max(0, $0.posY + Double(d.y) / rh))
                    } },
                    rotateBy: { d in self.updateTextClip(id: id) { $0.rotation += d } },
                    setOpacity: { v in self.updateTextClip(id: id) { $0.opacity = v } })
            }
            if let i = imageTracks.flatMap({ $0.clips }).first(where: { $0.id == id }) {
                return MultiLayerHandle(
                    id: id, center: b.center, size: b.size, opacity: i.alpha,
                    scaleBy: { k in self.updateImageClip(id: id) { $0.scaleX *= k; $0.scaleY *= k } },
                    moveBy: { d in self.updateImageClip(id: id) {
                        $0.offsetX += Double(d.x) / rw
                        $0.offsetY += Double(d.y) / rh
                    } },
                    rotateBy: { d in self.updateImageClip(id: id) { $0.rotation += d } },
                    setOpacity: { v in self.updateImageClip(id: id) { $0.opacity = v } })
            }
            return nil
        }
    }
}

extension ProjectState {
    /// 只选中这一个图层，其余选中态清空。按 id 属于哪类自动分派
    func selectLayerExclusive(_ id: UUID) {
        selectedVideoClipID = nil
        selectedImageClipID = nil
        selectedAudioClipID = nil
        selectedSubtitleClipID = nil
        selectedTextClipID = nil
        selectedShapeClipID = nil
        selectedCompoundClipID = nil

        if shapeTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            selectedShapeClipID = id
        } else if textTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            selectedTextClipID = id
        } else if imageTracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) {
            selectedImageClipID = id
        }
        selectedClipIDs = [id]
    }
}

// MARK: - 预览区点击穿透

extension ProjectState {
    // MARK: - Tap 穿透选择

    /// 点在重叠处时**循环切换**：把命中的图层从上到下列出来，
    /// 选中当前那个的下一个，到底了绕回第一个。
    /// 按住 Shift 是加选/取消选，不参与轮换
    func tapThroughSelect(at pt: CGPoint, viewSize: CGSize, time: Double,
                          currentClipID: UUID? = nil) {
        let hits = layersHit(at: pt, viewSize: viewSize, time: time)
        guard !hits.isEmpty else {
            selectedImageClipID = nil; selectedShapeClipID = nil
            selectedTextClipID = nil; selectedVideoClipID = nil
            selectedClipIDs.removeAll()
            editingTextClipID = nil
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {
            // 点图片走的是这条路，之前只 toggle 最上面那个，
            // 所以在图片重叠处按 shift 一点循环效果都没有
            shiftCycle(in: hits, fallback: hits[0])
            return
        }
        // 当前选中的那个（优先用调用方给的，其次看单选状态）
        let cur = currentClipID
            ?? selectedShapeClipID ?? selectedTextClipID
            ?? selectedImageClipID
        let next: UUID
        if let cur, let i = hits.firstIndex(of: cur) {
            next = hits[(i + 1) % hits.count]
        } else {
            next = hits[0]
        }
        editingTextClipID = nil
        selectLayerExclusive(next)
    }

    /// 命中点击位置的图层，**上层在前**（`overlayTrackOrder` 就是叠放顺序）
    func layersHit(at pt: CGPoint, viewSize: CGSize, time: Double) -> [UUID] {
        let t = time
        let scale = viewSize.width / max(previewRenderSize.width, 1)
        var out: [UUID] = []
        for ref in overlayTrackOrder {
            switch ref {
            case .shape(let trackID):
                guard let track = shapeTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let sc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * sc.posX, cy = viewSize.height * sc.posY
                let w = sc.width * sc.scaleX * scale, h = sc.height * sc.scaleY * scale
                if CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).contains(pt) {
                    out.append(sc.id)
                }
            case .text(let trackID):
                guard let track = textTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let tc = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }) else { continue }
                let cx = viewSize.width * tc.posX, cy = viewSize.height * tc.posY
                let sz = textClipViewSizes[tc.id] ?? CGSize(width: 100, height: 30)
                if CGRect(x: cx - sz.width / 2, y: cy - sz.height / 2,
                          width: sz.width, height: sz.height).contains(pt) {
                    out.append(tc.id)
                }
            case .image(let trackID):
                guard let track = imageTracks.first(where: { $0.id == trackID }),
                      track.isVisible,
                      let ic = track.clips.first(where: { $0.startTime <= t && $0.endTime > t }),
                      let b = layerBounds(for: ic.id) else { continue }
                // layerBounds 给的是渲染坐标，换算到视图坐标
                let cx = Double(b.center.x) * Double(scale), cy = Double(b.center.y) * Double(scale)
                let w = Double(b.size.width) * Double(scale), h = Double(b.size.height) * Double(scale)
                if CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).contains(pt) {
                    out.append(ic.id)
                }
            default: continue
            }
        }
        return out
    }
}

extension ProjectState {
    /// 跟这个图层**外接框相交**的所有图层，按叠放顺序（下层在前）
    func overlappingLayers(_ id: UUID) -> [UUID] {
        guard let base = layerBounds(for: id) else { return [id] }
        let baseRect = CGRect(x: base.center.x - base.size.width / 2,
                              y: base.center.y - base.size.height / 2,
                              width: base.size.width, height: base.size.height)
        var out: [UUID] = []
        for ref in overlayTrackOrder {
            let clipIDs: [UUID]
            switch ref {
            case .shape(let tid):
                clipIDs = shapeTracks.first { $0.id == tid }?.clips.map(\.id) ?? []
            case .text(let tid):
                clipIDs = textTracks.first { $0.id == tid }?.clips.map(\.id) ?? []
            case .image(let tid):
                clipIDs = imageTracks.first { $0.id == tid }?.clips.map(\.id) ?? []
            default:
                clipIDs = []
            }
            for cid in clipIDs {
                guard let b = layerBounds(for: cid) else { continue }
                let r = CGRect(x: b.center.x - b.size.width / 2,
                               y: b.center.y - b.size.height / 2,
                               width: b.size.width, height: b.size.height)
                if r.intersects(baseRect) { out.append(cid) }
            }
        }
        return out.isEmpty ? [id] : out
    }

    /// 点在重叠处时**沿叠放顺序轮换**：选中当前那个的下一个，到底了绕回第一个。
    ///
    /// 各图层自己的点击手势都调这个 —— 之前它们各调各的
    /// `selectXXXExclusive`，压在上面的图层一拦，下面那个永远点不到
    func cycleSelectOverlapping(_ id: UUID) {
        let hits = overlappingLayers(id)
        guard hits.count > 1 else { selectLayerExclusive(id); return }
        let cur = selectedShapeClipID ?? selectedTextClipID ?? selectedImageClipID
        if let cur, let i = hits.firstIndex(of: cur) {
            selectLayerExclusive(hits[(i + 1) % hits.count])
        } else {
            selectLayerExclusive(id)
        }
    }
}

extension ProjectState {
    /// Shift 点击。
    ///
    /// - 非重叠处：就是普通的加选 / 减选
    /// - 重叠处：**先把叠在一起的挨个加进来**，全加完了再点就挨个移出去
    func shiftCycleOverlapping(_ id: UUID) {
        shiftCycle(in: overlappingLayers(id), fallback: id)
    }

    /// Shift 在一叠图层上的行为。`hits` 是叠在一起的那些（下层在前）。
    ///
    /// **要记着现在是在加还是在减**：只看「有没有没选中的」的话，
    /// 加满之后移出第一个，下一次点又发现它没选中、于是原样加回去，
    /// 两个状态之间来回跳，看着就是「减选没反应」
    func shiftCycle(in hits: [UUID], fallback: UUID) {
        guard hits.count > 1 else {
            shiftToggleClip(fallback)
            shiftCycleRemoving = false
            return
        }
        // 一个都没选中 → 重新从加选开始
        if !hits.contains(where: { selectedClipIDs.contains($0) }) {
            shiftCycleRemoving = false
        }

        if shiftCycleRemoving {
            if let first = hits.first(where: { selectedClipIDs.contains($0) }) {
                shiftToggleClip(first)
            }
            // 减光了，下一轮回到加选
            if !hits.contains(where: { selectedClipIDs.contains($0) }) {
                shiftCycleRemoving = false
            }
        } else if let next = hits.first(where: { !selectedClipIDs.contains($0) }) {
            shiftToggleClip(next)
            // 加满了，下一次点开始往外减
            if hits.allSatisfy({ selectedClipIDs.contains($0) }) {
                shiftCycleRemoving = true
            }
        }
    }
}

// MARK: - 滤镜

extension ProjectState {
    /// 滤镜片段的默认时长
    static let defaultFilterDuration: Double = 3

    /// 往时间轴上加一段滤镜。
    ///
    /// 落到**第一条这段时间空着的轨道**上；都占着就新开一条 ——
    /// 多条轨道就是叠加，所以不用挤在一条里
    @discardableResult
    func addFilter(kind: FilterKind, at time: Double? = nil, lutPath: String? = nil) -> UUID {
        pushUndo()
        let start = max(0, time ?? currentTime)
        var clip = FilterClip(kind: kind, startTime: start,
                              endTime: start + Self.defaultFilterDuration)
        clip.lutPath = lutPath

        func free(_ track: Track<FilterClip>) -> Bool {
            !track.clips.contains { $0.startTime < clip.endTime && $0.endTime > clip.startTime }
        }
        if let i = filterTracks.firstIndex(where: free) {
            filterTracks[i].clips.append(clip)
        } else {
            filterTracks.append(Track(clips: [clip], label: "滤镜"))
            syncOverlayOrder()
        }
        selectedFilterClipID = clip.id
        selectedClipIDs = [clip.id]
        isSaved = false
        rebuildTimelinePreview()
        return clip.id
    }

    func updateFilterClip(id: UUID, _ mutate: (inout FilterClip) -> Void) {
        for ti in filterTracks.indices {
            if let ci = filterTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&filterTracks[ti].clips[ci])
                isSaved = false
                // 拖强度滑块是连续的，每次都立刻重建会让播放器一直在重置，
                // 画面反而卡着不动 —— 这里要防抖
                rebuildTimelinePreviewDebounced()
                return
            }
        }
    }

    func deleteFilterClip(id: UUID) {
        pushUndo()
        for ti in filterTracks.indices {
            filterTracks[ti].clips.removeAll { $0.id == id }
        }
        if selectedFilterClipID == id { selectedFilterClipID = nil }
        selectedClipIDs.remove(id)
        isSaved = false
        rebuildTimelinePreviewDebounced()
    }

    /// 选中的是效果类片段（滤镜/调节）。
    /// 这两类既没有音轨也没有画面内容，翻译、语音识别、去背景那些工具对它们都没意义
    var isEffectClipSelected: Bool {
        selectedFilterClipID != nil || selectedAdjustClipID != nil || selectedEffectClipID != nil
    }

    /// 清掉所有片段的选中态。
    ///
    /// 选中态有九种，各处「选中 A 就把 B…H 挨个置空」很容易漏 —— 滤镜就漏过：
    /// 删掉整条滤镜轨道时没清 id，属性区标题还认为选着滤镜，内容却掉回项目设置
    func clearClipSelections() {
        selectedVideoClipID = nil
        selectedImageClipID = nil
        selectedAudioClipID = nil
        selectedSubtitleClipID = nil
        selectedTextClipID = nil
        selectedShapeClipID = nil
        selectedFilterClipID = nil
        selectedAdjustClipID = nil
        selectedEffectClipID = nil
        selectedCompoundClipID = nil
    }

    // MARK: - 特效

    @discardableResult
    func addEffect(kind: EffectKind, at time: Double? = nil) -> UUID {
        pushUndo()
        let start = max(0, time ?? currentTime)
        let clip = EffectClip(kind: kind, startTime: start,
                              endTime: start + Self.defaultFilterDuration)

        func free(_ track: Track<EffectClip>) -> Bool {
            !track.clips.contains { $0.startTime < clip.endTime && $0.endTime > clip.startTime }
        }
        if let i = effectTracks.firstIndex(where: free) {
            effectTracks[i].clips.append(clip)
        } else {
            effectTracks.append(Track(clips: [clip], label: "特效"))
            syncOverlayOrder()
        }
        selectedEffectClipID = clip.id
        selectedClipIDs = [clip.id]
        isSaved = false
        rebuildTimelinePreview()
        return clip.id
    }

    /// 改一段特效。
    ///
    /// `live` = 正在拖手柄/滑块：**不重建预览**，直接把新参数喂给合成器再逼一帧重绘。
    /// 整份重建会把播放器按在重置上，拖中心点时画面一顿一顿地闪
    func updateEffectClip(id: UUID, live: Bool = false, _ mutate: (inout EffectClip) -> Void) {
        for ti in effectTracks.indices {
            if let ci = effectTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&effectTracks[ti].clips[ci])
                isSaved = false
                if live {
                    ColorCompositor.setEffectTracks(effectTracks)
                    clock.refreshSeekRequest &+= 1
                } else {
                    rebuildTimelinePreviewDebounced()
                }
                return
            }
        }
    }

    func deleteEffectClip(id: UUID) {
        pushUndo()
        for ti in effectTracks.indices {
            effectTracks[ti].clips.removeAll { $0.id == id }
        }
        if selectedEffectClipID == id { selectedEffectClipID = nil }
        selectedClipIDs.remove(id)
        isSaved = false
        rebuildTimelinePreviewDebounced()
    }

    var selectedEffectClip: EffectClip? {
        guard let id = selectedEffectClipID else { return nil }
        return effectTracks.flatMap(\.clips).first { $0.id == id }
    }

    // MARK: - 调节

    @discardableResult
    func addAdjust(at time: Double? = nil) -> UUID {
        pushUndo()
        let start = max(0, time ?? currentTime)
        let clip = AdjustClip(startTime: start, endTime: start + Self.defaultFilterDuration)

        func free(_ track: Track<AdjustClip>) -> Bool {
            !track.clips.contains { $0.startTime < clip.endTime && $0.endTime > clip.startTime }
        }
        if let i = adjustTracks.firstIndex(where: free) {
            adjustTracks[i].clips.append(clip)
        } else {
            adjustTracks.append(Track(clips: [clip], label: "调节"))
            syncOverlayOrder()
        }
        selectedAdjustClipID = clip.id
        selectedClipIDs = [clip.id]
        isSaved = false
        rebuildTimelinePreview()
        return clip.id
    }

    func updateAdjustClip(id: UUID, _ mutate: (inout AdjustClip) -> Void) {
        for ti in adjustTracks.indices {
            if let ci = adjustTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                mutate(&adjustTracks[ti].clips[ci])
                isSaved = false
                // 滑块是连着拖的，每动一下都重建会把播放器一直按在重置上
                rebuildTimelinePreviewDebounced()
                return
            }
        }
    }

    func deleteAdjustClip(id: UUID) {
        pushUndo()
        for ti in adjustTracks.indices {
            adjustTracks[ti].clips.removeAll { $0.id == id }
        }
        if selectedAdjustClipID == id { selectedAdjustClipID = nil }
        selectedClipIDs.remove(id)
        isSaved = false
        rebuildTimelinePreviewDebounced()
    }

    var selectedAdjustClip: AdjustClip? {
        guard let id = selectedAdjustClipID else { return nil }
        return adjustTracks.flatMap(\.clips).first { $0.id == id }
    }

    var selectedFilterClip: FilterClip? {
        guard let id = selectedFilterClipID else { return nil }
        return filterTracks.flatMap(\.clips).first { $0.id == id }
    }
}

extension ProjectState {
    /// 某一时刻正在生效的滤镜（按轨道顺序，下层在前）
    /// 某一时刻正在生效的调节（按轨道顺序，下层在前）
    /// 某一时刻正在生效的特效（按轨道顺序，下层在前）
    func activeEffectClips(at time: Double) -> [EffectClip] {
        effectTracks
            .filter(\.isVisible)
            .flatMap { $0.clips }
            .filter { $0.startTime <= time && $0.endTime > time }
    }

    func activeAdjustClips(at time: Double) -> [AdjustClip] {
        adjustTracks
            .filter(\.isVisible)
            .flatMap { $0.clips }
            .filter { $0.startTime <= time && $0.endTime > time }
    }

    func activeFilterClips(at time: Double) -> [FilterClip] {
        filterTracks
            .filter(\.isVisible)
            .flatMap { $0.clips }
            .filter { $0.startTime <= time && $0.endTime > time }
    }
}
