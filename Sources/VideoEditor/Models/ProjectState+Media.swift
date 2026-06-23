import SwiftUI
import AVFoundation

// MARK: - Media Library Management

extension ProjectState {

    /// Remove an asset from the media library AND remove any timeline clips
    /// referencing it (with undo support including asset restoration).
    /// Shows a confirmation alert before proceeding.
    func removeAsset(id: UUID) {
        let assetName = mediaAssets.first(where: { $0.id == id })?.name ?? "未知素材"

        // Count timeline clips that reference this asset
        var clipCount = 0
        for t in videoTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in audioTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in imageTracks    { clipCount += t.clips.filter { $0.assetID == id }.count }
        for t in subtitleTracks { clipCount += t.clips.filter { $0.assetID == id }.count }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确定移除「\(assetName)」？"
        if clipCount > 0 {
            alert.informativeText = "时间轴上有 \(clipCount) 个片段使用了此素材，将一并移除。"
        } else {
            alert.informativeText = "素材将从素材库中移除。"
        }
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // User confirmed — save snapshot WITH mediaAssets for undo
        let snapshot = currentSnapshot(includeAssets: true)
        undoStack.append(snapshot)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        lastUndoPushTime = Date()
        isSaved = false
        scheduleAutoSave()

        // Remove timeline clips (all track types including subtitle)
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll    { $0.assetID == id } }
        for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll { $0.assetID == id } }
        // Clean up caches
        mediaThumbnails.removeValue(forKey: id)
        assetThumbnails.removeValue(forKey: id)
        waveformCache.removeValue(forKey: id)
        imageVideoCache.removeValue(forKey: id)
        // Remove from asset list
        mediaAssets.removeAll { $0.id == id }
        // Deselect
        selectedVideoClipID = nil
        selectedAudioClipID = nil
        selectedImageClipID = nil
        selectedSubtitleClipID = nil
        selectedClipIDs.removeAll()
        rebuildTimelinePreview()
    }

    func saveMediaLibrary(_ assets: [MediaAsset]) {
        let bookmarks: [Data] = assets.compactMap { asset in
            try? asset.url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.mediaLibraryKey)
    }

    func loadSavedMediaLibrary() {
        // 兼容旧版纯路径格式，自动迁移
        if let paths = UserDefaults.standard.stringArray(forKey: "savedMediaAssetPaths") {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                importFileFromRestore(url)
            }
            UserDefaults.standard.removeObject(forKey: "savedMediaAssetPaths")
            saveMediaLibrary(mediaAssets)
            return
        }

        guard let dataArray = UserDefaults.standard.array(forKey: Self.mediaLibraryKey) as? [Data] else { return }
        for data in dataArray {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                      options: .withSecurityScope,
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessedURLs.append(url)
            importFileFromRestore(url)
        }
    }

    /// 从持久化数据恢复素材（不触发重复保存）
    func importFileFromRestore(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard let type = Self.assetType(for: ext) else { return }
        guard !mediaAssets.contains(where: { $0.url == url }) else { return }
        let asset = MediaAsset(url: url, name: url.lastPathComponent, type: type)
        mediaAssets.append(asset)
        if asset.fileExists {
            loadMediaResources(asset)
        }
    }

    func refreshMediaLibrary() {
        for asset in mediaAssets {
            if asset.fileExists && mediaThumbnails[asset.id] == nil {
                loadMediaResources(asset)
            }
        }
    }

    func loadMediaResources(_ asset: MediaAsset) {
        let aid = asset.id
        let url = asset.url
        switch asset.type {
        case .video:
            loadMediaThumbnail(assetID: aid, url: url)
            loadTimelineThumbnails(assetID: aid, url: url)
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where: { $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        case .audio:
            loadWaveform(assetID: aid, url: url)
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run {
                        if let i = self.mediaAssets.firstIndex(where: { $0.id == aid }) {
                            self.mediaAssets[i].duration = d.seconds
                        }
                    }
                }
            }
        case .image:
            loadImageThumbnail(assetID: aid, url: url)
        case .subtitle: break
        }
    }

    // MARK: - Thumbnail & Waveform Generation

    /// Generate a single thumbnail for the media library (video assets only).
    func loadMediaThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { self.mediaThumbnails[id] = img }
            }
        }
    }

    /// Generate timeline thumbnail strip for a video asset (evenly spaced frames).
    func loadTimelineThumbnails(assetID: UUID, url: URL) {
        guard assetThumbnails[assetID] == nil else { return }
        generateThumbnails(assetID: assetID, url: url)
    }

    func reloadThumbnails(assetID: UUID, url: URL) {
        guard !thumbnailsReloading.contains(assetID) else { return }
        thumbnailsReloading.insert(assetID)
        generateThumbnails(assetID: assetID, url: url, isReload: true)
    }

    func generateThumbnails(assetID: UUID, url: URL, isReload: Bool = false) {
        if !isReload { assetThumbnails[assetID] = [] }
        let id = assetID
        let pps = pixelsPerSecond
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0.1 else {
                await MainActor.run { self.thumbnailsReloading.remove(id) }
                return
            }
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 104)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.3, preferredTimescale: 600)

            let thumbWidth = 48.0
            let neededFrames = Int(dur * pps / thumbWidth)
            let frameCount = max(10, min(200, neededFrames))
            let interval = dur / Double(frameCount)
            var times: [NSValue] = []
            var t = 0.0
            while t < dur {
                times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
                t += interval
            }

            var frames: [ThumbnailFrame] = []
            let semaphore = DispatchSemaphore(value: 0)
            var remaining = times.count
            gen.generateCGImagesAsynchronously(forTimes: times) { requested, cgImage, actual, result, error in
                if result == .succeeded, let cg = cgImage {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    frames.append(ThumbnailFrame(time: requested.seconds, image: img))
                }
                remaining -= 1
                if remaining == 0 { semaphore.signal() }
            }
            await Task.detached(priority: .utility) { semaphore.wait() }.value
            let sorted = frames.sorted(by: { $0.time < $1.time })
            await MainActor.run {
                self.assetThumbnails[id] = sorted
                self.thumbnailsReloading.remove(id)
            }
        }
    }

    func refreshAllThumbnails() {
        var seen = Set<UUID>()
        for t in videoTracks {
            for c in t.clips {
                guard !seen.contains(c.assetID), let url = c.url else { continue }
                seen.insert(c.assetID)
                reloadThumbnails(assetID: c.assetID, url: url)
            }
        }
    }

    /// Generate waveform peak data for an audio asset.
    func loadWaveform(assetID: UUID, url: URL) {
        guard waveformCache[assetID] == nil else { return }
        let id = assetID
        Task {
            let av = AVURLAsset(url: url)
            let dur = (try? await av.load(.duration))?.seconds ?? 0
            guard dur > 0 else { return }
            guard let track = try? await av.loadTracks(withMediaType: .audio).first else { return }
            guard let reader = try? AVAssetReader(asset: av) else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            reader.startReading()

            var allPeaks: [Float] = []
            let chunkTarget = 2000  // samples per peak
            // 直接在原始缓冲区上计算峰值，避免反复 append/removeFirst 的内存拷贝
            var runningPeak: Int16 = 0
            var samplesInChunk = 0

            while let sampleBuf = output.copyNextSampleBuffer() {
                guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuf) else { continue }
                var length = 0
                var dataPtr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPtr)
                guard let ptr = dataPtr else { continue }
                let count = length / MemoryLayout<Int16>.size
                let samples = UnsafeBufferPointer(
                    start: UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: count), count: count)

                for sample in samples {
                    let absSample = sample == Int16.min ? Int16.max : abs(sample)
                    if absSample > runningPeak { runningPeak = absSample }
                    samplesInChunk += 1
                    if samplesInChunk >= chunkTarget {
                        allPeaks.append(Float(runningPeak) / Float(Int16.max))
                        runningPeak = 0
                        samplesInChunk = 0
                    }
                }
            }
            if samplesInChunk > 0 {
                allPeaks.append(Float(runningPeak) / Float(Int16.max))
            }

            await MainActor.run {
                self.waveformCache[id] = WaveformData(totalDuration: dur, samples: allPeaks)
            }
        }
    }

    /// Load an image file as thumbnail for the media library.
    func loadImageThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        if let img = NSImage(contentsOf: url) {
            mediaThumbnails[assetID] = img
        }
    }

    // MARK: - Relink missing asset

    /// Update all timeline clips that reference a given asset to use a new URL.
    /// 删除素材并移除时间轴上所有引用该素材的片段
    func removeAssetAndClips(assetID: UUID) {
        let snap = currentSnapshot(includeAssets: true)
        mediaAssets.removeAll { $0.id == assetID }
        for i in videoTracks.indices {
            videoTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in audioTracks.indices {
            audioTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in imageTracks.indices {
            imageTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        for i in subtitleTracks.indices {
            subtitleTracks[i].clips.removeAll { $0.assetID == assetID }
        }
        mediaThumbnails.removeValue(forKey: assetID)
        undoStack.append(snap)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoCount = undoStack.count
        redoCount = 0
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 清空素材库及时间轴上所有关联片段
    func clearMediaLibrary() {
        pushUndoSavingAssets()
        mediaAssets.removeAll()
        mediaThumbnails.removeAll()
        waveformCache.removeAll()
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll() }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll() }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll() }
        for i in subtitleTracks.indices { subtitleTracks[i].clips.removeAll() }
        rebuildTimelinePreview()
        scheduleAutoSave()
    }

    /// 统计素材在时间轴上被引用的片段数
    func clipCountForAsset(_ assetID: UUID) -> Int {
        var count = 0
        for t in videoTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in audioTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in imageTracks    { count += t.clips.filter { $0.assetID == assetID }.count }
        for t in subtitleTracks { count += t.clips.filter { $0.assetID == assetID }.count }
        return count
    }

    func relinkAsset(id: UUID, newURL: URL) {
        pushUndoSavingAssets()
        if let i = mediaAssets.firstIndex(where: { $0.id == id }) {
            mediaAssets[i].url = newURL
            mediaAssets[i].name = newURL.lastPathComponent
        }
        for ti in videoTracks.indices {
            for ci in videoTracks[ti].clips.indices where videoTracks[ti].clips[ci].assetID == id {
                videoTracks[ti].clips[ci].url = newURL
            }
        }
        for ti in audioTracks.indices {
            for ci in audioTracks[ti].clips.indices where audioTracks[ti].clips[ci].assetID == id {
                audioTracks[ti].clips[ci].url = newURL
            }
        }
        // 图片轨：更新 imageURL 并清理旧缓存视频，重新生成
        for ti in imageTracks.indices {
            for ci in imageTracks[ti].clips.indices where imageTracks[ti].clips[ci].assetID == id {
                imageTracks[ti].clips[ci].imageURL = newURL
                imageTracks[ti].clips[ci].videoURL = nil
            }
        }
        imageVideoCache.removeValue(forKey: id)
        // 清理旧缓存，重新加载素材资源
        mediaThumbnails.removeValue(forKey: id)
        waveformCache.removeValue(forKey: id)
        if let asset = mediaAssets.first(where: { $0.id == id }) {
            loadMediaResources(asset)
        }
        // 重新加载时长和尺寸
        Task {
            let avAsset = AVURLAsset(url: newURL)
            if let dur = try? await avAsset.load(.duration) {
                await MainActor.run {
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == id }) {
                        self.mediaAssets[i].duration = dur.seconds
                    }
                }
            }
            if let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first {
                let sz = try? await vTrack.load(.naturalSize)
                await MainActor.run {
                    if let sz {
                        for ti in self.videoTracks.indices {
                            for ci in self.videoTracks[ti].clips.indices where self.videoTracks[ti].clips[ci].assetID == id {
                                self.videoTracks[ti].clips[ci].videoWidth = sz.width
                                self.videoTracks[ti].clips[ci].videoHeight = sz.height
                            }
                        }
                    }
                }
            }
        }
        rebuildTimelinePreview()
    }
}
