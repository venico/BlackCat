import SwiftUI
import AVFoundation

// MARK: - Edit Operations (Undo/Redo, Split, Delete, Copy/Paste)

extension ProjectState {

    // MARK: - Undo / Redo

    func pushUndo() {
        // Agent 跑一轮期间不再打快照：整轮只在开跑前打一个，
        // ⌘Z 一次回到它动手之前。工具内部各自 pushUndo 的话，
        // 一轮会被切成好几步，撤一次只退回中间某个状态
        guard !suppressUndoPush else { return }
        undoStack.append(currentSnapshot())
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()
    }

    /// 撤下最近一次 `pushUndo()` 压进去的快照。
    ///
    /// 给"操作最终没做成、要连痕迹一起收掉"的场景用（如翻译整批失败后删掉刚建的翻译轨）——
    /// 不弹的话撤销栈里会留一步"什么都没变"的记录，用户按 ⌘Z 像是没反应
    func popUndo() {
        guard !undoStack.isEmpty else { return }
        undoStack.removeLast()
        undoCount = undoStack.count
    }

    func pushUndoSavingAssets() {
        guard !suppressUndoPush else { return }   // 同 pushUndo，Agent 跑一轮期间不打快照
        var snap = currentSnapshot()
        snap.mediaAssets = mediaAssets
        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
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

    /// 撤销/重做只回滚数据，磁盘文件名不会跟着变，素材会变成「丢失」。
    /// 这里比对快照前后的 URL：目标不存在而原位置还在，就把文件改回去
    private func reconcileAssetFiles(from previous: [MediaAsset]) {
        let fm = FileManager.default
        for asset in mediaAssets {
            guard let prev = previous.first(where: { $0.id == asset.id }),
                  prev.url != asset.url,
                  !fm.fileExists(atPath: asset.url.path),
                  fm.fileExists(atPath: prev.url.path) else { continue }
            do {
                try fm.moveItem(at: prev.url, to: asset.url)
            } catch {
                NSLog("[Rename] 撤销回滚文件失败: %@", error.localizedDescription)
            }
        }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        // 带上素材：否则重做时还原不了素材名，磁盘文件也校准不回来
        redoStack.append(currentSnapshot(includeAssets: true))
        let before = mediaAssets
        applySnapshot(s)
        reconcileAssetFiles(from: before)
        // 这一步撤回来的素材，画布上那些卡片也跟着回来 ——
        // 一次 ⌘Z 素材、片段、卡片一起恢复
        let restored = Set(mediaAssets.map(\.id)).subtracting(before.map(\.id))
        for id in restored {
            NotificationCenter.default.post(name: .assetRestoredToLibrary, object: nil,
                                            userInfo: ["assetID": id, "origin": instanceID])
        }
        undoCount = undoStack.count
        redoCount = redoStack.count
        isSaved = false
        scheduleAutoSave()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot(includeAssets: true))
        let before = mediaAssets
        applySnapshot(s)
        reconcileAssetFiles(from: before)
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
                        filterTracks: filterTracks,
                        adjustTracks: adjustTracks,
                        effectTracks: effectTracks,
                        compoundTracks: compoundTracks,
                        overlayTrackOrder: overlayTrackOrder,
                        videoSectionOrder: videoSectionOrder,
                        audioSectionOrder: audioSectionOrder,
                        subtitleBottomMargin: subtitleBottomMargin,
                        subtitleLineSpacing: subtitleLineSpacing,
                        duration: duration,
                        mediaAssets: includeAssets ? mediaAssets : nil)
    }

    func applySnapshot(_ s: ProjectSnapshot) {
        filterTracks   = s.filterTracks
        adjustTracks   = s.adjustTracks
        effectTracks   = s.effectTracks
        videoTracks    = s.videoTracks
        audioTracks    = s.audioTracks
        imageTracks    = s.imageTracks
        subtitleTracks = s.subtitleTracks
        textTracks     = s.textTracks
        shapeTracks    = s.shapeTracks
        compoundTracks = s.compoundTracks
        overlayTrackOrder = s.overlayTrackOrder
        videoSectionOrder = s.videoSectionOrder
        audioSectionOrder = s.audioSectionOrder
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
                        let splitOffset = t - c.startTime
                        videoTracks[ti].clips[ci].endTime = t
                        // 整体复制再改必要字段。原来是逐字段手抄，colorAdjust、mirrorH/V、
                        // rotation、reversed、audioTrackIndex 全漏了 —— 表现就是
                        // 「片段变色后分割，只有前半段还留着变色」。图片/文字/图形那几路
                        // 本来就是这么复制的，这里跟上，以后 VideoClip 加字段也不会再漏
                        var newClip = c
                        newClip.id = UUID()
                        newClip.startTime = t
                        newClip.endTime = c.endTime
                        // 分割点在时间轴上的偏移 * speed = 源素材消耗量
                        newClip.trimStart = c.trimStart + splitOffset * c.speed
                        // 入场转场属于原片段的开头，右半段不该凭空多出一个
                        newClip.inTransition = nil
                        // 标记按落点各归各家。time 是相对片段起点的偏移
                        // （clipMarkerPins 里 absTime = clip.startTime + m.time）
                        videoTracks[ti].clips[ci].markers = c.markers?.filter { $0.time <= splitOffset }
                        newClip.markers = c.markers?.compactMap { m in
                            guard m.time > splitOffset else { return nil }
                            var moved = m
                            moved.time = m.time - splitOffset
                            return moved
                        }
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
        } else if let id = selectedImageClipID {
            outer: for ti in imageTracks.indices {
                if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = imageTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        imageTracks[ti].clips[ci].endTime = t
                        var newClip = c; newClip.id = UUID()
                        newClip.startTime = t; newClip.endTime = c.endTime
                        imageTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedTextClipID {
            outer: for ti in textTracks.indices {
                if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = textTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        textTracks[ti].clips[ci].endTime = t
                        var newClip = c; newClip.id = UUID()
                        newClip.startTime = t; newClip.endTime = c.endTime
                        textTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedShapeClipID {
            outer: for ti in shapeTracks.indices {
                if let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = shapeTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        shapeTracks[ti].clips[ci].endTime = t
                        var newClip = c; newClip.id = UUID()
                        newClip.startTime = t; newClip.endTime = c.endTime
                        shapeTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        } else if let id = selectedCompoundClipID {
            outer: for ti in compoundTracks.indices {
                if let ci = compoundTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = compoundTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        compoundTracks[ti].clips[ci].endTime = t
                        var newClip = c; newClip.id = UUID()
                        newClip.startTime = t; newClip.endTime = c.endTime
                        newClip.internalStart = c.internalStart + (t - c.startTime)
                        compoundTracks[ti].clips.insert(newClip, at: ci + 1)
                        changed = true
                    }
                    break outer
                }
            }
        }

        if changed {
            // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
            if !suppressUndoPush {
                undoStack.append(snap)
            }
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count
            redoCount = 0
            rebuildTimelinePreview()
            scheduleAutoSave()
        }
    }

    /// 向左分割：保留播放头左边，删除右边
    func splitKeepLeft() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false

        if let id = selectedVideoClipID {
            for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = videoTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        videoTracks[ti].clips[ci].endTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedAudioClipID {
            for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = audioTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        audioTracks[ti].clips[ci].endTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedSubtitleClipID {
            for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = subtitleTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        subtitleTracks[ti].clips[ci].endTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedImageClipID {
            for ti in imageTracks.indices {
                if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if imageTracks[ti].clips[ci].startTime + 0.01 < t && imageTracks[ti].clips[ci].endTime - 0.01 > t {
                        imageTracks[ti].clips[ci].endTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedTextClipID {
            for ti in textTracks.indices {
                if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if textTracks[ti].clips[ci].startTime + 0.01 < t && textTracks[ti].clips[ci].endTime - 0.01 > t {
                        textTracks[ti].clips[ci].endTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedShapeClipID {
            for ti in shapeTracks.indices {
                if let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if shapeTracks[ti].clips[ci].startTime + 0.01 < t && shapeTracks[ti].clips[ci].endTime - 0.01 > t {
                        shapeTracks[ti].clips[ci].endTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedCompoundClipID {
            for ti in compoundTracks.indices {
                if let ci = compoundTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if compoundTracks[ti].clips[ci].startTime + 0.01 < t && compoundTracks[ti].clips[ci].endTime - 0.01 > t {
                        compoundTracks[ti].clips[ci].endTime = t; changed = true
                    }; break
                }
            }
        }

        if changed {
            // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
            if !suppressUndoPush {
                undoStack.append(snap)
            }
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count; redoCount = 0
            rebuildTimelinePreview(); scheduleAutoSave()
        }
    }

    /// 向右分割：保留播放头右边，删除左边
    func splitKeepRight() {
        let t = currentTime
        let snap = currentSnapshot()
        var changed = false

        if let id = selectedVideoClipID {
            for ti in videoTracks.indices {
                if let ci = videoTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = videoTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        videoTracks[ti].clips[ci].trimStart = c.trimStart + (t - c.startTime) * c.speed
                        videoTracks[ti].clips[ci].startTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedAudioClipID {
            for ti in audioTracks.indices {
                if let ci = audioTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = audioTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        audioTracks[ti].clips[ci].trimStart = c.trimStart + (t - c.startTime) * c.speed
                        audioTracks[ti].clips[ci].startTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedSubtitleClipID {
            for ti in subtitleTracks.indices {
                if let ci = subtitleTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = subtitleTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        subtitleTracks[ti].clips[ci].startTime = t
                        changed = true
                    }
                    break
                }
            }
        } else if let id = selectedImageClipID {
            for ti in imageTracks.indices {
                if let ci = imageTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if imageTracks[ti].clips[ci].startTime + 0.01 < t && imageTracks[ti].clips[ci].endTime - 0.01 > t {
                        imageTracks[ti].clips[ci].startTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedTextClipID {
            for ti in textTracks.indices {
                if let ci = textTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if textTracks[ti].clips[ci].startTime + 0.01 < t && textTracks[ti].clips[ci].endTime - 0.01 > t {
                        textTracks[ti].clips[ci].startTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedShapeClipID {
            for ti in shapeTracks.indices {
                if let ci = shapeTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    if shapeTracks[ti].clips[ci].startTime + 0.01 < t && shapeTracks[ti].clips[ci].endTime - 0.01 > t {
                        shapeTracks[ti].clips[ci].startTime = t; changed = true
                    }; break
                }
            }
        } else if let id = selectedCompoundClipID {
            for ti in compoundTracks.indices {
                if let ci = compoundTracks[ti].clips.firstIndex(where: { $0.id == id }) {
                    let c = compoundTracks[ti].clips[ci]
                    if c.startTime + 0.01 < t && c.endTime - 0.01 > t {
                        compoundTracks[ti].clips[ci].internalStart = c.internalStart + (t - c.startTime)
                        compoundTracks[ti].clips[ci].startTime = t
                        changed = true
                    }; break
                }
            }
        }

        if changed {
            // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
            if !suppressUndoPush {
                undoStack.append(snap)
            }
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            undoCount = undoStack.count; redoCount = 0
            rebuildTimelinePreview(); scheduleAutoSave()
        }
    }

    // MARK: - Compound Clip (复合片段)

    func createCompoundFromSelected() {
        let snap = currentSnapshot()

        // 收集所有选中片段的 ID
        var ids = selectedClipIDs
        if let id = selectedVideoClipID { ids.insert(id) }
        if let id = selectedAudioClipID { ids.insert(id) }
        if let id = selectedSubtitleClipID { ids.insert(id) }
        if let id = selectedImageClipID { ids.insert(id) }
        if let id = selectedTextClipID { ids.insert(id) }
        if let id = selectedShapeClipID { ids.insert(id) }
        if let id = selectedCompoundClipID { ids.insert(id) }
        guard !ids.isEmpty else { return }

        // 找出所有匹配的片段，计算时间范围
        var minTime = Double.infinity
        var maxTime = 0.0

        var collectedVideo: [Track<VideoClip>] = []
        var collectedAudio: [Track<AudioClip>] = []
        var collectedImage: [Track<ImageClip>] = []
        var collectedSubtitle: [Track<SubtitleClip>] = []
        var collectedText: [Track<TextClip>] = []
        var collectedShape: [Track<ShapeClip>] = []

        for ti in videoTracks.indices {
            let matched = videoTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                collectedVideo.append(Track(clips: matched, label: videoTracks[ti].label))
            }
        }
        for ti in audioTracks.indices {
            let matched = audioTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                collectedAudio.append(Track(clips: matched, label: audioTracks[ti].label))
            }
        }
        var origToNew: [UUID: OverlayTrackRef] = [:]
        for ti in imageTracks.indices {
            let matched = imageTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                let newTrack = Track<ImageClip>(clips: matched, label: imageTracks[ti].label)
                origToNew[imageTracks[ti].id] = .image(newTrack.id)
                collectedImage.append(newTrack)
            }
        }
        for ti in subtitleTracks.indices {
            let matched = subtitleTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                var newTrack = Track<SubtitleClip>(clips: matched, label: subtitleTracks[ti].label)
                newTrack.subtitleStyle = subtitleTracks[ti].subtitleStyle
                origToNew[subtitleTracks[ti].id] = .subtitle(newTrack.id)
                collectedSubtitle.append(newTrack)
            }
        }
        for ti in textTracks.indices {
            let matched = textTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                let newTrack = Track<TextClip>(clips: matched, label: textTracks[ti].label)
                origToNew[textTracks[ti].id] = .text(newTrack.id)
                collectedText.append(newTrack)
            }
        }
        for ti in shapeTracks.indices {
            let matched = shapeTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                let newTrack = Track<ShapeClip>(clips: matched, label: shapeTracks[ti].label)
                origToNew[shapeTracks[ti].id] = .shape(newTrack.id)
                collectedShape.append(newTrack)
            }
        }
        var collectedCompound: [Track<CompoundClip>] = []
        for ti in compoundTracks.indices {
            let matched = compoundTracks[ti].clips.filter { ids.contains($0.id) }
            if !matched.isEmpty {
                for c in matched { minTime = min(minTime, c.startTime); maxTime = max(maxTime, c.endTime) }
                collectedCompound.append(Track(clips: matched, label: compoundTracks[ti].label))
            }
        }

        guard minTime < maxTime else { return }

        // 确定复合片段类型和锚点（在移除源片段前记录）
        let willBeVideo = !collectedVideo.isEmpty || collectedCompound.flatMap(\.clips).contains(where: { compoundHasVideo($0) })
        let willBeAudio = !willBeVideo && (!collectedAudio.isEmpty || collectedCompound.flatMap(\.clips).contains(where: { compoundHasAudio($0) }))
        var anchorTrackID: UUID?
        var anchorOverlayIdx: Int?
        if willBeVideo {
            anchorTrackID = videoTracks.first(where: { t in t.clips.contains { ids.contains($0.id) } })?.id
            if anchorTrackID == nil {
                anchorTrackID = compoundTracks.first(where: { t in t.clips.contains { ids.contains($0.id) } })?.id
            }
        } else if willBeAudio {
            anchorTrackID = audioTracks.first(where: { t in t.clips.contains { ids.contains($0.id) } })?.id
            if anchorTrackID == nil {
                anchorTrackID = compoundTracks.first(where: { t in t.clips.contains { ids.contains($0.id) } })?.id
            }
        } else {
            for (oi, ref) in overlayTrackOrder.enumerated() {
                let tid = ref.trackID
                var affected = false
                switch ref {
                case .image: affected = imageTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .subtitle: affected = subtitleTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .text: affected = textTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .shape: affected = shapeTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .filter: affected = filterTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .adjust: affected = adjustTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .effect: affected = effectTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                case .compound: affected = compoundTracks.first(where: { $0.id == tid })?.clips.contains { ids.contains($0.id) } ?? false
                }
                if affected { anchorOverlayIdx = oi; break }
            }
        }

        // 根据父 overlayTrackOrder 的顺序构建复合片段的 overlayTrackOrder
        var compoundOverlayOrder: [OverlayTrackRef] = []
        for ref in overlayTrackOrder {
            if let newRef = origToNew[ref.trackID] {
                compoundOverlayOrder.append(newRef)
            }
        }

        // 偏移子片段时间到从 0 开始
        let offset = minTime
        for ti in collectedVideo.indices {
            for ci in collectedVideo[ti].clips.indices {
                collectedVideo[ti].clips[ci].startTime -= offset
                collectedVideo[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedAudio.indices {
            for ci in collectedAudio[ti].clips.indices {
                collectedAudio[ti].clips[ci].startTime -= offset
                collectedAudio[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedImage.indices {
            for ci in collectedImage[ti].clips.indices {
                collectedImage[ti].clips[ci].startTime -= offset
                collectedImage[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedSubtitle.indices {
            for ci in collectedSubtitle[ti].clips.indices {
                collectedSubtitle[ti].clips[ci].startTime -= offset
                collectedSubtitle[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedText.indices {
            for ci in collectedText[ti].clips.indices {
                collectedText[ti].clips[ci].startTime -= offset
                collectedText[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedShape.indices {
            for ci in collectedShape[ti].clips.indices {
                collectedShape[ti].clips[ci].startTime -= offset
                collectedShape[ti].clips[ci].endTime -= offset
            }
        }
        for ti in collectedCompound.indices {
            for ci in collectedCompound[ti].clips.indices {
                collectedCompound[ti].clips[ci].startTime -= offset
                collectedCompound[ti].clips[ci].endTime -= offset
            }
        }

        // 从父时间线移除选中片段
        for ti in videoTracks.indices {
            videoTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in audioTracks.indices {
            audioTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in imageTracks.indices {
            imageTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in subtitleTracks.indices {
            subtitleTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in textTracks.indices {
            textTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in shapeTracks.indices {
            shapeTracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for ti in compoundTracks.indices {
            compoundTracks[ti].clips.removeAll { ids.contains($0.id) }
        }

        // 清理变空的轨道
        let emptyImageIDs = imageTracks.filter { $0.clips.isEmpty }.map(\.id)
        let emptySubIDs = subtitleTracks.filter { $0.clips.isEmpty }.map(\.id)
        let emptyTextIDs = textTracks.filter { $0.clips.isEmpty }.map(\.id)
        let emptyShapeIDs = shapeTracks.filter { $0.clips.isEmpty }.map(\.id)
        let emptyCompIDs = compoundTracks.filter { $0.clips.isEmpty }.map(\.id)
        videoTracks.removeAll { $0.clips.isEmpty }
        audioTracks.removeAll { $0.clips.isEmpty }
        imageTracks.removeAll { $0.clips.isEmpty }
        subtitleTracks.removeAll { $0.clips.isEmpty }
        textTracks.removeAll { $0.clips.isEmpty }
        shapeTracks.removeAll { $0.clips.isEmpty }
        compoundTracks.removeAll { $0.clips.isEmpty }
        let removedOverlayIDs = Set(emptyImageIDs + emptySubIDs + emptyTextIDs + emptyShapeIDs + emptyCompIDs)
        if !removedOverlayIDs.isEmpty {
            overlayTrackOrder.removeAll { removedOverlayIDs.contains($0.trackID) }
        }

        let parentNum: String
        if let pn = compositionStack.last?.name {
            parentNum = pn.replacingOccurrences(of: "复合片段", with: "").trimmingCharacters(in: .whitespaces)
        } else {
            parentNum = ""
        }
        let childIdx = compoundTracks.flatMap(\.clips).count + 1
        var compound = CompoundClip(
            name: "复合片段\(parentNum)\(childIdx)",
            startTime: minTime, endTime: maxTime,
            videoTracks: collectedVideo, audioTracks: collectedAudio,
            imageTracks: collectedImage, subtitleTracks: collectedSubtitle,
            textTracks: collectedText, shapeTracks: collectedShape,
            compoundTracks: collectedCompound
        )
        compound.overlayTrackOrder = compoundOverlayOrder

        // 找一个不重叠的轨道放入，否则新建
        var placed = false
        for ti in compoundTracks.indices {
            let overlaps = compoundTracks[ti].clips.contains { c in
                c.startTime < compound.endTime && c.endTime > compound.startTime
            }
            if !overlaps {
                compoundTracks[ti].clips.append(compound)
                placed = true
                break
            }
        }
        if !placed {
            compoundTracks.append(Track(clips: [compound], label: "复合"))
        }

        // 清除选中
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedSubtitleClipID = nil; selectedImageClipID = nil
        selectedTextClipID = nil; selectedShapeClipID = nil
        selectedCompoundClipID = nil
        selectedClipIDs.removeAll()

        // 将新复合轨道插入到源轨道的位置
        if let cTrackID = compoundTracks.first(where: { $0.clips.contains(where: { $0.id == compound.id }) })?.id {
            if willBeVideo, let anchor = anchorTrackID {
                if let ai = videoSectionOrder.firstIndex(where: { $0.trackID == anchor }) {
                    videoSectionOrder.insert(.compound(cTrackID), at: ai)
                }
            } else if willBeAudio, let anchor = anchorTrackID {
                if let ai = audioSectionOrder.firstIndex(where: { $0.trackID == anchor }) {
                    audioSectionOrder.insert(.compound(cTrackID), at: ai)
                }
            } else if let oi = anchorOverlayIdx {
                let insertAt = min(oi, overlayTrackOrder.count)
                overlayTrackOrder.insert(.compound(cTrackID), at: insertAt)
            }
        }

        syncOverlayOrder()
        syncVideoSectionOrder()
        syncAudioSectionOrder()
        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count; redoCount = 0
        rebuildTimelinePreview(); scheduleAutoSave()
    }

    func enterCompound(trackIndex: Int, clipIndex: Int) {
        guard trackIndex < compoundTracks.count,
              clipIndex < compoundTracks[trackIndex].clips.count else { return }
        let compound = compoundTracks[trackIndex].clips[clipIndex]

        var level = CompositionLevel(
            name: compound.name,
            snapshot: currentSnapshot(),
            compoundTrackIndex: trackIndex,
            compoundClipIndex: clipIndex,
            activeStart: compound.internalStart,
            activeDuration: compound.duration
        )
        level.savedUndoStack = undoStack
        level.savedRedoStack = redoStack
        level.savedUndoCount = undoCount
        level.savedRedoCount = redoCount
        compositionStack.append(level)

        videoTracks = compound.videoTracks
        audioTracks = compound.audioTracks
        imageTracks = compound.imageTracks
        subtitleTracks = compound.subtitleTracks
        textTracks = compound.textTracks
        shapeTracks = compound.shapeTracks
        compoundTracks = compound.compoundTracks
        if compound.overlayTrackOrder.isEmpty {
            overlayTrackOrder = []
            syncOverlayOrder()
        } else {
            overlayTrackOrder = compound.overlayTrackOrder
            syncOverlayOrder()
        }

        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedSubtitleClipID = nil; selectedImageClipID = nil
        selectedTextClipID = nil; selectedShapeClipID = nil
        selectedClipIDs.removeAll()
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0

        currentTime = 0
        rebuildTimelinePreview()
    }

    func exitCompound() {
        guard let level = compositionStack.popLast() else { return }

        // 把当前编辑内容保存回复合片段
        var snap = level.snapshot
        if level.compoundTrackIndex < snap.compoundTracks.count,
           level.compoundClipIndex < snap.compoundTracks[level.compoundTrackIndex].clips.count {
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].videoTracks = videoTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].audioTracks = audioTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].imageTracks = imageTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].subtitleTracks = subtitleTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].textTracks = textTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].shapeTracks = shapeTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].compoundTracks = compoundTracks
            snap.compoundTracks[level.compoundTrackIndex].clips[level.compoundClipIndex].overlayTrackOrder = overlayTrackOrder
        }

        applySnapshot(snap)

        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedSubtitleClipID = nil; selectedImageClipID = nil
        selectedTextClipID = nil; selectedShapeClipID = nil
        selectedClipIDs.removeAll()
        undoStack = level.savedUndoStack
        redoStack = level.savedRedoStack
        undoCount = level.savedUndoCount
        redoCount = level.savedRedoCount
    }

    private func firstNonOverlappingTrack(newRanges: [(Double, Double)], existingPerTrack: [[(Double, Double)]]) -> Int? {
        for ti in existingPerTrack.indices {
            let hasOverlap = newRanges.contains { nr in
                existingPerTrack[ti].contains { er in nr.0 < er.1 - 0.001 && nr.1 > er.0 + 0.001 }
            }
            if !hasOverlap { return ti }
        }
        return nil
    }

    private static func renameCompoundHierarchy(_ clip: inout CompoundClip, oldPrefix: String, newPrefix: String) {
        let num = clip.name.replacingOccurrences(of: "复合片段", with: "")
        if num.hasPrefix(oldPrefix) {
            clip.name = "复合片段\(newPrefix)\(num.dropFirst(oldPrefix.count))"
        }
        for ti in clip.compoundTracks.indices {
            for ci in clip.compoundTracks[ti].clips.indices {
                renameCompoundHierarchy(&clip.compoundTracks[ti].clips[ci], oldPrefix: oldPrefix, newPrefix: newPrefix)
            }
        }
    }

    func dissolveCompound(_ compoundID: UUID) {
        let snap = currentSnapshot()
        guard let ti = compoundTracks.firstIndex(where: { $0.clips.contains { $0.id == compoundID } }),
              let ci = compoundTracks[ti].clips.firstIndex(where: { $0.id == compoundID }) else { return }
        let compound = compoundTracks[ti].clips[ci]
        let offset = compound.startTime
        // 解除前的轨道数。里面的图层会散到多条新轨道上，很容易落在可视区外，
        // 所以收尾时按增量报一句「展开为 N 条轨道」
        let beforeTrackCount = videoTracks.count + audioTracks.count + imageTracks.count
            + subtitleTracks.count + textTracks.count + shapeTracks.count

        // 记录复合轨道在 section order 中的位置（释放后新轨道插到这里）
        let compoundTrackUUID = compoundTracks[ti].id
        let videoAnchorIdx = videoSectionOrder.firstIndex(where: { $0.trackID == compoundTrackUUID })
        let audioAnchorIdx = audioSectionOrder.firstIndex(where: { $0.trackID == compoundTrackUUID })

        for subTrack in compound.videoTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            let nr = clips.map { ($0.startTime, $0.endTime) }
            if let di = firstNonOverlappingTrack(newRanges: nr, existingPerTrack: videoTracks.map { $0.clips.map { ($0.startTime, $0.endTime) } }) {
                videoTracks[di].clips.append(contentsOf: clips)
            } else {
                videoTracks.append(Track(clips: clips, label: subTrack.label))
            }
        }
        for subTrack in compound.audioTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            let nr = clips.map { ($0.startTime, $0.endTime) }
            if let di = firstNonOverlappingTrack(newRanges: nr, existingPerTrack: audioTracks.map { $0.clips.map { ($0.startTime, $0.endTime) } }) {
                audioTracks[di].clips.append(contentsOf: clips)
            } else {
                audioTracks.append(Track(clips: clips, label: subTrack.label))
            }
        }
        var subIDtoNewRef: [UUID: OverlayTrackRef] = [:]
        for subTrack in compound.imageTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            let newTrack = Track<ImageClip>(clips: clips, label: subTrack.label)
            imageTracks.append(newTrack)
            subIDtoNewRef[subTrack.id] = .image(newTrack.id)
        }
        for subTrack in compound.subtitleTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            var newTrack = Track<SubtitleClip>(clips: clips, label: subTrack.label)
            newTrack.subtitleStyle = subTrack.subtitleStyle ?? newSubtitleStyle()
            subtitleTracks.append(newTrack)
            subIDtoNewRef[subTrack.id] = .subtitle(newTrack.id)
        }
        for subTrack in compound.textTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            let newTrack = Track<TextClip>(clips: clips, label: subTrack.label)
            textTracks.append(newTrack)
            subIDtoNewRef[subTrack.id] = .text(newTrack.id)
        }
        for subTrack in compound.shapeTracks {
            var clips = subTrack.clips
            for i in clips.indices { clips[i].startTime += offset; clips[i].endTime += offset }
            let newTrack = Track<ShapeClip>(clips: clips, label: subTrack.label)
            shapeTracks.append(newTrack)
            subIDtoNewRef[subTrack.id] = .shape(newTrack.id)
        }
        let dissolvedNum = compound.name.replacingOccurrences(of: "复合片段", with: "")
        let parentNum: String
        if let pn = compositionStack.last?.name {
            parentNum = pn.replacingOccurrences(of: "复合片段", with: "")
        } else {
            parentNum = ""
        }
        var usedNames = Set(compoundTracks.flatMap(\.clips).filter { $0.id != compoundID }.map(\.name))
        for subTrack in compound.compoundTracks {
            var clips = subTrack.clips
            for i in clips.indices {
                clips[i].startTime += offset; clips[i].endTime += offset
                Self.renameCompoundHierarchy(&clips[i], oldPrefix: dissolvedNum, newPrefix: parentNum)
                var name = clips[i].name
                if usedNames.contains(name) {
                    var n = 2
                    while usedNames.contains("\(name)(\(n))") { n += 1 }
                    name = "\(name)(\(n))"
                    clips[i].name = name
                }
                usedNames.insert(name)
            }
            compoundTracks.append(Track(clips: clips, label: subTrack.label))
        }

        // 按复合片段内部 overlayTrackOrder 的顺序插入新建的 overlay 轨道
        var newOverlayRefs: [OverlayTrackRef] = []
        for ref in compound.overlayTrackOrder {
            if let newRef = subIDtoNewRef[ref.trackID] {
                newOverlayRefs.append(newRef)
            }
        }
        for ref in subIDtoNewRef.values where !newOverlayRefs.contains(where: { $0.trackID == ref.trackID }) {
            newOverlayRefs.append(ref)
        }

        let compoundTrackID = compoundTracks[ti].id
        let compoundOrderIndex = overlayTrackOrder.firstIndex(where: { $0.trackID == compoundTrackID })

        compoundTracks[ti].clips.remove(at: ci)
        let trackEmpty = compoundTracks[ti].clips.isEmpty
        if trackEmpty { compoundTracks.remove(at: ti) }

        var insertAt: Int
        if let idx = compoundOrderIndex {
            if trackEmpty {
                overlayTrackOrder.remove(at: idx)
                insertAt = idx
            } else {
                insertAt = idx + 1
            }
        } else {
            insertAt = overlayTrackOrder.count
        }
        insertAt = min(insertAt, overlayTrackOrder.count)
        overlayTrackOrder.insert(contentsOf: newOverlayRefs, at: insertAt)

        selectedCompoundClipID = nil

        // 将释放出的新视频/音频轨道插入到复合轨道原来的 section order 位置
        if let anchor = videoAnchorIdx {
            let existingIDs = Set(videoSectionOrder.map(\.trackID))
            var newRefs: [VideoSectionRef] = []
            for t in videoTracks where !existingIDs.contains(t.id) { newRefs.append(.video(t.id)) }
            if !newRefs.isEmpty {
                videoSectionOrder.insert(contentsOf: newRefs, at: min(anchor, videoSectionOrder.count))
            }
        }
        if let anchor = audioAnchorIdx {
            let existingIDs = Set(audioSectionOrder.map(\.trackID))
            var newRefs: [AudioSectionRef] = []
            for t in audioTracks where !existingIDs.contains(t.id) { newRefs.append(.audio(t.id)) }
            if !newRefs.isEmpty {
                audioSectionOrder.insert(contentsOf: newRefs, at: min(anchor, audioSectionOrder.count))
            }
        }

        syncOverlayOrder()

        let afterTrackCount = videoTracks.count + audioTracks.count + imageTracks.count
            + subtitleTracks.count + textTracks.count + shapeTracks.count
        let addedTracks = max(0, afterTrackCount - beforeTrackCount)
        showSuccessToast(icon: "square.on.square", iconColor: .accentColor,
                         title: "已解除复合片段",
                         subtitle: addedTracks > 0 ? "展开为 \(addedTracks) 条新轨道"
                                                   : "内容已并入现有轨道",
                         autoCountdown: true)

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count; redoCount = 0
        rebuildTimelinePreview(); scheduleAutoSave()
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
        if let id = selectedFilterClipID   { ids.insert(id) }
        if let id = selectedAdjustClipID   { ids.insert(id) }
        if let id = selectedEffectClipID   { ids.insert(id) }
        if let id = selectedCompoundClipID { ids.insert(id) }
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
        for i in filterTracks.indices {
            let before = filterTracks[i].clips.count
            filterTracks[i].clips.removeAll { ids.contains($0.id) }
            if filterTracks[i].clips.count != before { changed = true }
        }
        for i in adjustTracks.indices {
            let before = adjustTracks[i].clips.count
            adjustTracks[i].clips.removeAll { ids.contains($0.id) }
            if adjustTracks[i].clips.count != before { changed = true }
        }
        for i in effectTracks.indices {
            let before = effectTracks[i].clips.count
            effectTracks[i].clips.removeAll { ids.contains($0.id) }
            if effectTracks[i].clips.count != before { changed = true }
        }
        for i in compoundTracks.indices {
            let before = compoundTracks[i].clips.count
            compoundTracks[i].clips.removeAll { ids.contains($0.id) }
            if compoundTracks[i].clips.count != before { changed = true }
        }

        selectedVideoClipID    = nil
        selectedImageClipID    = nil
        selectedAudioClipID    = nil
        selectedSubtitleClipID = nil
        selectedTextClipID     = nil
        selectedFilterClipID   = nil
        selectedShapeClipID    = nil
        selectedCompoundClipID = nil
        selectedClipIDs.removeAll()

        if changed {
            // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
            if !suppressUndoPush {
                undoStack.append(snap)
            }
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
        if let id = selectedFilterClipID   { allIDs.insert(id) }
        if let id = selectedAdjustClipID   { allIDs.insert(id) }
        if let id = selectedEffectClipID   { allIDs.insert(id) }
        if let id = selectedCompoundClipID { allIDs.insert(id) }

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
            for (ti, track) in filterTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.filter(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in adjustTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.adjust(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in effectTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.effect(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
            for (ti, track) in compoundTracks.enumerated() {
                if let clip = track.clips.first(where: { $0.id == id }) {
                    items.append(.compound(clip, trackIndex: ti)); srcIDs.insert(id)
                }
            }
        }

        guard !items.isEmpty else { return }
        clipboard = items
        clipboardIsCut = isCut
        clipboardSourceIDs = isCut ? srcIDs : []
    }

    /// 把一段效果片段（滤镜/调节）放进轨道：原轨道这段时间被占了就新开一条，
    /// 新轨道要压在原轨道正上方 —— 效果类只作用于排在它下面的图层，
    /// 顺序摆错了粘出来的东西作用范围就跟原来不是一回事
    private func placeEffectClip<C: Identifiable & Equatable & Codable>(
        _ clip: C, preferredTrack: Int,
        tracks: inout [Track<C>], label: String,
        ref: (UUID) -> OverlayTrackRef,
        start: (C) -> Double, end: (C) -> Double
    ) {
        let idx = tracks.indices.contains(preferredTrack) ? preferredTrack : 0
        guard tracks.indices.contains(idx) else {
            var t = Track<C>(label: label)
            t.clips.append(clip)
            tracks.append(t)
            syncOverlayOrder()
            return
        }
        let overlaps = tracks[idx].clips.contains {
            start($0) < end(clip) - 0.001 && end($0) > start(clip) + 0.001
        }
        if overlaps {
            let anchorID = tracks[idx].id
            var t = Track<C>(label: label)
            t.clips.append(clip)
            tracks.append(t)
            insertOverlayRefAbove(ref(t.id), above: anchorID)
        } else {
            tracks[idx].clips.append(clip)
        }
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
            for i in filterTracks.indices   { filterTracks[i].clips.removeAll   { srcIDs.contains($0.id) } }
            for i in adjustTracks.indices   { adjustTracks[i].clips.removeAll   { srcIDs.contains($0.id) } }
            for i in effectTracks.indices   { effectTracks[i].clips.removeAll   { srcIDs.contains($0.id) } }
            for i in compoundTracks.indices { compoundTracks[i].clips.removeAll { srcIDs.contains($0.id) } }
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
            case .filter(let c, _): return c.startTime
            case .adjust(let c, _): return c.startTime
            case .effect(let c, _): return c.startTime
            case .compound(let c, _): return c.startTime
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
        selectedCompoundClipID = nil
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
                        insertOverlayRefAbove(.image(newTrack.id), above: anchorID)
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
                        insertOverlayRefAbove(.text(newTrack.id), above: anchorID)
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

            case .filter(let clip, let trackIdx):
                var newClip = FilterClip(kind: clip.kind,
                                         startTime: t + offset,
                                         endTime: t + offset + clip.duration)
                newClip.intensity = clip.intensity
                newClip.lutPath = clip.lutPath
                placeEffectClip(newClip, preferredTrack: trackIdx,
                                tracks: &filterTracks, label: "滤镜",
                                ref: { .filter($0) },
                                start: { $0.startTime }, end: { $0.endTime })
                selectedClipIDs.insert(newClip.id)

            case .effect(let clip, let trackIdx):
                var newClip = EffectClip(kind: clip.kind,
                                         startTime: t + offset,
                                         endTime: t + offset + clip.duration)
                newClip.intensity = clip.intensity
                newClip.amount = clip.amount
                newClip.angle = clip.angle
                newClip.centerX = clip.centerX
                newClip.centerY = clip.centerY
                placeEffectClip(newClip, preferredTrack: trackIdx,
                                tracks: &effectTracks, label: "特效",
                                ref: { .effect($0) },
                                start: { $0.startTime }, end: { $0.endTime })
                selectedClipIDs.insert(newClip.id)

            case .adjust(let clip, let trackIdx):
                var newClip = AdjustClip(startTime: t + offset,
                                         endTime: t + offset + clip.duration)
                newClip.adjust = clip.adjust
                newClip.customName = clip.customName
                placeEffectClip(newClip, preferredTrack: trackIdx,
                                tracks: &adjustTracks, label: "调节",
                                ref: { .adjust($0) },
                                start: { $0.startTime }, end: { $0.endTime })
                selectedClipIDs.insert(newClip.id)

            case .compound(let clip, let trackIdx):
                var newClip = clip
                newClip.id = UUID()
                newClip.startTime = t + offset
                newClip.endTime = t + offset + clip.duration
                let idx = compoundTracks.indices.contains(trackIdx) ? trackIdx : 0
                if compoundTracks.indices.contains(idx) {
                    let hasOverlap = compoundTracks[idx].clips.contains {
                        $0.startTime < newClip.endTime - 0.001 && $0.endTime > newClip.startTime + 0.001
                    }
                    if hasOverlap {
                        let kind = compoundTrackKind(compoundTracks[idx])
                        let anchorID = compoundTracks[idx].id
                        var newTrack = Track<CompoundClip>(label: "复合")
                        newTrack.clips.append(newClip)
                        compoundTracks.append(newTrack)
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
                    } else {
                        compoundTracks[idx].clips.append(newClip)
                    }
                    selectedClipIDs.insert(newClip.id)
                }
            }
        }

        syncOverlayOrder()
        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
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
            // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
            if !suppressUndoPush {
                undoStack.append(snap)
            }
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
                // 用户点取消时 cancelSceneDetect 已经弹过「已停止」，进程被 kill 又会
                // 从这里抛出 CancellationError —— 再弹一张就成了「已停止 + 失败」两张卡，
                // 而且失败那张显示的是 CancellationError 的英文描述
                if error is CancellationError || Task.isCancelled { return }
                await MainActor.run {
                    isDetectingScenes = false
                    sceneDetectProgress = 0
                    showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                     title: "智能分割",
                                     subtitle: "智能分割失败（\(error.localizedDescription)）",
                                     autoCountdown: false)
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

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
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
                             title: "大模型分析", subtitle: "请先在设置→AI 设置中配置所选供应商的 API Key", autoCountdown: false)
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

                // 供应商在「设置 → AI 剪辑」里选，其余参数（Key / 接口地址 / 子模型 /
                // 推理强度）全取「AI 设置」里配好的那份，跟字幕校对同一条链路
                guard let textProvider = AIVideoService.Provider(
                    rawValue: settings.llmProvider.sharedProviderKey) else {
                    throw NSError(domain: "LLM", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "无法识别所选模型供应商"])
                }
                let highlights = try await LLMAnalyzer.analyze(
                    subtitles: subData,
                    send: { try await AIVideoService.shared.generateText(provider: textProvider, prompt: $0) }
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
        // 时间轴按 videoSectionOrder 渲染，不遍历 videoTracks。
        // 漏这一步轨道建了也不显示，而提示照样报「已生成」
        syncVideoSectionOrder()

        // Agent 跑一轮期间不打快照，整轮共用开跑前那一个
        if !suppressUndoPush {
            undoStack.append(snap)
        }
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
