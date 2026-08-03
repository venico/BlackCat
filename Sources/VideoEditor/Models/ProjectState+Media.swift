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
                                      bookmarkDataIsStale: &isStale) else {
                DiagLog.log("[素材恢复] bookmark 解析失败，跳过一条")
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                DiagLog.log("[素材恢复] security-scoped 访问被拒 \(url.lastPathComponent)")
                continue
            }
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
        } else {
            DiagLog.log("[素材恢复] 文件不存在，不生成缩略图 \(url.lastPathComponent)")
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
            updateAssetDuration(assetID: aid, url: url)
        case .audio:
            loadWaveform(assetID: aid, url: url)
            updateAssetDuration(assetID: aid, url: url)
        case .image:
            loadImageThumbnail(assetID: aid, url: url)
        case .subtitle: break
        }
    }

    /// 素材时长更新（专属 pthread + 超时，挂起机器上安全）
    func updateAssetDuration(assetID: UUID, url: URL) {
        Thread.detachNewThread {
            if case .success(let d) = Self.durationSyncWithTimeout(url: url, seconds: 10) {
                DispatchQueue.main.async {
                    if let i = self.mediaAssets.firstIndex(where: { $0.id == assetID }) {
                        self.mediaAssets[i].duration = d
                    }
                }
            }
        }
    }

    // MARK: - Thumbnail & Waveform Generation

    /// Generate a single thumbnail for the media library (video assets only).
    ///
    /// 线程模型（家用机 -11821 实证倒逼，勿改回 Task/GCD）：
    /// 解码服务会让本进程的 AVFoundation 调用**同步挂死**（AVURLAsset init 都可能卡住），
    /// 挂死会占满 Swift 协作池和 GCD 全局池 —— 排进这两个池的任务（包括超时定时器）永不执行。
    /// 因此整条链路用专属 pthread（Thread.detachNewThread，无池限制）+ 信号量超时，
    /// 结果经 DispatchQueue.main（RunLoop 驱动，不依赖线程池）回写 @Published。
    func loadMediaThumbnail(assetID: UUID, url: URL) {
        guard mediaThumbnails[assetID] == nil else { return }
        guard !coverGenerating.contains(assetID) else { return }
        coverGenerating.insert(assetID)
        let id = assetID
        Thread.detachNewThread {
            let outcome = Self.avSingleFrameSync(url: url, maxSize: 400, timeout: 10)
            var cover: NSImage? = nil
            switch outcome {
            case .success(let cg):
                cover = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            case .failure(let msg):
                DiagLog.log("[缩略图] 素材库封面 AVFoundation 失败 \(url.lastPathComponent) 错误=\(msg)，改用 ffmpeg")
            case .timedOut:
                DiagLog.log("[缩略图] 素材库封面 AVFoundation 超时(10s)无响应 \(url.lastPathComponent)，改用 ffmpeg")
            }
            if cover == nil {
                cover = Self.ffmpegSingleFrame(url: url, maxSize: 400)
                if cover != nil {
                    DiagLog.log("[缩略图] 素材库封面 ffmpeg 兜底成功 \(url.lastPathComponent)")
                } else {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    let readable = FileManager.default.isReadableFile(atPath: url.path)
                    DiagLog.log("[缩略图] 素材库封面 ffmpeg 兜底也失败 \(url.lastPathComponent) 存在=\(exists ? "是" : "否") 可读=\(readable ? "是" : "否")")
                }
            }
            let result = cover
            DispatchQueue.main.async {
                if let img = result { self.mediaThumbnails[id] = img }
                self.coverGenerating.remove(id)
            }
        }
    }

    enum AVFrameOutcome {
        case success(CGImage)
        case failure(String)
        case timedOut
    }

    /// 带超时的 AVFoundation 单帧抽取（同步版，须在专属 pthread 上调用）。
    /// AVFoundation 交互放在再开的一条 pthread 里：挂死只废弃那条线程；
    /// 超时用信号量 wait(timeout:)，不依赖 GCD 定时器（全局池可能已被挂死任务占满）
    nonisolated static func avSingleFrameSync(url: URL, maxSize: CGFloat, timeout: Double) -> AVFrameOutcome {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: AVFrameOutcome? = nil
        func finish(_ r: AVFrameOutcome) {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return }
            outcome = r
            sem.signal()
        }
        Thread.detachNewThread {
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSize, height: maxSize)
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, result, error in
                if result == .succeeded, let cg = cg {
                    finish(.success(cg))
                } else {
                    finish(.failure(error?.localizedDescription ?? "result=\(result.rawValue)"))
                }
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            finish(.timedOut)
        }
        lock.lock(); defer { lock.unlock() }
        return outcome ?? .timedOut
    }

    enum DurationOutcome {
        case success(Double)
        case failure(String)
        case timedOut
    }

    /// 带超时的时长读取（同步版，须在专属 pthread 上调用）。
    /// 用回调式 loadValuesAsynchronously（不需要 async 上下文，避开协作池）
    nonisolated static func durationSyncWithTimeout(url: URL, seconds: Double) -> DurationOutcome {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: DurationOutcome? = nil
        func finish(_ r: DurationOutcome) {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return }
            outcome = r
            sem.signal()
        }
        Thread.detachNewThread {
            let av = AVURLAsset(url: url)
            av.loadValuesAsynchronously(forKeys: ["duration"]) {
                var err: NSError? = nil
                let status = av.statusOfValue(forKey: "duration", error: &err)
                if status == .loaded {
                    finish(.success(av.duration.seconds))
                } else {
                    finish(.failure(err?.localizedDescription ?? "status=\(status.rawValue)"))
                }
            }
        }
        if sem.wait(timeout: .now() + seconds) == .timedOut {
            finish(.timedOut)
        }
        lock.lock(); defer { lock.unlock() }
        return outcome ?? .timedOut
    }

    /// 时间轴条批量抽帧结果
    enum AVStripOutcome {
        case frames([ThumbnailFrame], firstError: String?)
        case timedOut(partial: [ThumbnailFrame])
    }

    private final class StripState: @unchecked Sendable {
        let lock = NSLock()
        var frames: [ThumbnailFrame] = []
        var firstError: String? = nil
        var abandoned = false
        var remaining: Int
        init(remaining: Int) { self.remaining = remaining }
        func snapshot() -> [ThumbnailFrame] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
    }

    /// 带超时的 AVFoundation 批量抽帧（同步版，须在专属 pthread 上调用）。
    /// 线程模型同 avSingleFrameSync；信号量超时兜"同步挂死"和"回调不齐"两种情况
    nonisolated static func avFrameStripSync(url: URL, times: [NSValue], maxSize: CGSize,
                                             tolerance: CMTime, timeout: Double) -> AVStripOutcome {
        let sem = DispatchSemaphore(value: 0)
        let state = StripState(remaining: times.count)
        var genRef: AVAssetImageGenerator? = nil
        let genLock = NSLock()
        Thread.detachNewThread {
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = maxSize
            gen.requestedTimeToleranceBefore = tolerance
            gen.requestedTimeToleranceAfter  = tolerance
            genLock.lock(); genRef = gen; genLock.unlock()
            gen.generateCGImagesAsynchronously(forTimes: times) { requested, cgImage, _, result, error in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.abandoned else { return }
                if result == .succeeded, let cg = cgImage {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    state.frames.append(ThumbnailFrame(time: requested.seconds, image: img))
                } else if state.firstError == nil {
                    state.firstError = error?.localizedDescription ?? "result=\(result.rawValue)"
                }
                state.remaining -= 1
                if state.remaining == 0 { sem.signal() }
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            state.lock.lock(); state.abandoned = true; state.lock.unlock()
            genLock.lock(); genRef?.cancelAllCGImageGeneration(); genLock.unlock()
            return .timedOut(partial: state.snapshot())
        }
        state.lock.lock()
        let fs = state.frames
        let err = state.firstError
        state.lock.unlock()
        return .frames(fs, firstError: err)
    }

    // MARK: - FFmpeg 兜底抽帧

    /// 用 ffprobe 读视频时长（AVFoundation load(.duration) 失败时的兜底）。同步执行，须在后台线程调用。
    nonisolated static func ffprobeDuration(url: URL) -> Double? {
        guard let ff = findFFmpeg() else { return nil }
        let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else {
            DiagLog.log("[缩略图] ffprobe 不存在（\(probe.path)），时长兜底放弃")
            return nil
        }
        let p = Process()
        p.executableURL = probe
        p.arguments = ["-v", "error",
                       "-show_entries", "format=duration",
                       "-of", "default=noprint_wrappers=1:nokey=1",
                       url.path]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            DiagLog.log("[缩略图] ffprobe 进程启动失败：\(error.localizedDescription)")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let dur = Double(text), dur > 0 else { return nil }
        return dur
    }

    /// 用内置 ffmpeg 抽单帧（素材库封面用）。同步执行，须在后台线程调用。
    nonisolated static func ffmpegSingleFrame(url: URL, maxSize: Int) -> NSImage? {
        guard let ff = findFFmpeg() else {
            DiagLog.log("[缩略图] 找不到 ffmpeg（bundle 与系统路径均无），封面兜底放弃 \(url.lastPathComponent)")
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffcover_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                       "-ss", "0", "-i", url.path,
                       "-frames:v", "1",
                       "-vf", "scale=w=\(maxSize):h=\(maxSize):force_original_aspect_ratio=decrease",
                       "-y", out.path]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do { try p.run() } catch {
            DiagLog.log("[缩略图] ffmpeg 进程启动失败（\(ff.path)）：\(error.localizedDescription)")
            return nil
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            DiagLog.log("[缩略图] ffmpeg 抽帧退出码 \(p.terminationStatus) \(url.lastPathComponent) stderr=\(msg)")
            return nil
        }
        guard let img = NSImage(contentsOf: out) else {
            DiagLog.log("[缩略图] ffmpeg 抽帧成功但 PNG 读不出 \(url.lastPathComponent)")
            return nil
        }
        return img
    }

    /// 用内置 ffmpeg 按固定间隔抽帧（时间轴缩略图条用）。同步执行，须在后台线程调用。
    /// fps 滤镜一次解码流式出全部帧，比逐帧 seek 快得多。
    nonisolated static func ffmpegFrameStrip(url: URL, interval: Double) -> [ThumbnailFrame] {
        guard interval > 0 else { return [] }
        guard let ff = findFFmpeg() else {
            DiagLog.log("[缩略图] 找不到 ffmpeg（bundle 与系统路径均无），时间轴条兜底放弃 \(url.lastPathComponent)")
            return []
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffstrip_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DiagLog.log("[缩略图] 临时目录创建失败：\(error.localizedDescription)")
            return []
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                       "-i", url.path,
                       "-vf", "fps=\(1.0 / interval),scale=w=160:h=104:force_original_aspect_ratio=decrease",
                       "-fps_mode", "vfr",
                       dir.appendingPathComponent("f_%05d.png").path]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do { try p.run() } catch {
            DiagLog.log("[缩略图] ffmpeg 进程启动失败（\(ff.path)）：\(error.localizedDescription)")
            return []
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            DiagLog.log("[缩略图] ffmpeg 整条抽帧退出码 \(p.terminationStatus) \(url.lastPathComponent) stderr=\(msg)")
            return []
        }

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
        var frames: [ThumbnailFrame] = []
        for (i, name) in files.enumerated() {
            if let img = NSImage(contentsOf: dir.appendingPathComponent(name)) {
                // fps 滤镜第 i 帧（0 起）对应时间 i*interval，与请求的时间点一致
                frames.append(ThumbnailFrame(time: Double(i) * interval, image: img))
            }
        }
        return frames
    }

    /// Generate timeline thumbnail strip for a video asset (evenly spaced frames).
    func loadTimelineThumbnails(assetID: UUID, url: URL) {
        // 空数组是"上次没生成出来"，不能当成已有缓存 —— 否则那条片段的缩略图
        // 会一直空着且永不重试，只有重启 app 清掉内存缓存才恢复
        if let cached = assetThumbnails[assetID], !cached.isEmpty { return }
        guard !thumbnailsGenerating.contains(assetID) else { return }
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
        thumbnailsGenerating.insert(id)
        // 线程模型说明见 loadMediaThumbnail：专属 pthread + 信号量超时，不碰协作池/GCD 全局池
        Thread.detachNewThread {
            var loadError: String? = nil
            var dur: Double = 0
            var avDurationOK = false
            switch Self.durationSyncWithTimeout(url: url, seconds: 10) {
            case .success(let d): dur = d; avDurationOK = true
            case .failure(let msg): loadError = msg
            case .timedOut: loadError = "超时(10s)无响应"
            }
            if dur <= 0.1 {
                // AVFoundation 读不出时长（-11821 机器上可能连元数据都拒）→ ffprobe 兜底再试一次
                let exists = FileManager.default.fileExists(atPath: url.path)
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                DiagLog.log("[缩略图] AVFoundation 读不出时长 \(url.lastPathComponent) 存在=\(exists ? "是" : "否") 可读=\(readable ? "是" : "否") 时长=\(String(format: "%.2f", dur)) 错误=\(loadError ?? "无")，改用 ffprobe")
                if let d = Self.ffprobeDuration(url: url) {
                    DiagLog.log("[缩略图] ffprobe 读出时长 \(String(format: "%.2f", d)) \(url.lastPathComponent)")
                    dur = d
                }
            }
            guard dur > 0.1 else {
                // 两条路都读不出时长。必须把占位的空数组撤掉，
                // 留着它会让 loadTimelineThumbnails 以为已有缓存，从此不再重试
                DiagLog.log("[缩略图] ffprobe 也读不出时长，放弃 \(url.lastPathComponent)")
                DispatchQueue.main.async {
                    self.assetThumbnails.removeValue(forKey: id)
                    self.thumbnailsReloading.remove(id)
                    self.thumbnailsGenerating.remove(id)
                }
                return
            }
            let thumbWidth = 48.0
            let neededFrames = Int(dur * pps / thumbWidth)
            let frameCount = max(10, min(200, neededFrames))
            let interval = dur / Double(frameCount)

            var sorted: [ThumbnailFrame] = []
            var timedOut = false
            if avDurationOK {
                var times: [NSValue] = []
                var t = 0.0
                while t < dur {
                    times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
                    t += interval
                }
                let tol = CMTime(seconds: 0.3, preferredTimescale: 600)
                switch Self.avFrameStripSync(url: url, times: times,
                                             maxSize: CGSize(width: 160, height: 104),
                                             tolerance: tol, timeout: 60) {
                case .frames(let fs, let firstError):
                    sorted = fs.sorted(by: { $0.time < $1.time })
                    if sorted.isEmpty {
                        DiagLog.log("[缩略图] \(url.lastPathComponent) AVFoundation \(times.count) 帧全部失败（首个错误：\(firstError ?? "无")），改用 ffmpeg")
                    }
                case .timedOut(let partial):
                    timedOut = true
                    sorted = partial.sorted(by: { $0.time < $1.time })
                    DiagLog.log("[缩略图] \(url.lastPathComponent) AVFoundation 60s 超时（完成 \(sorted.count)/\(frameCount) 帧），改用 ffmpeg")
                }
            } else {
                // 时长是 ffprobe 读出来的 = AVFoundation 已证明挂起/失败，别再碰它
                DiagLog.log("[缩略图] \(url.lastPathComponent) AVFoundation 时长不可用，直接 ffmpeg 抽条")
            }
            // 超时或全失败 → ffmpeg 整条重抽；ffmpeg 也没出帧时保留超时前的部分帧
            if timedOut || sorted.isEmpty {
                let ffFrames = Self.ffmpegFrameStrip(url: url, interval: interval)
                if !ffFrames.isEmpty {
                    DiagLog.log("[缩略图] \(url.lastPathComponent) ffmpeg 兜底成功，出帧 \(ffFrames.count) 张")
                    sorted = ffFrames
                }
            }
            let finalFrames = sorted
            DispatchQueue.main.async {
                // 两条路都没出帧才算失败，别留空数组挡住重试
                if finalFrames.isEmpty {
                    DiagLog.log("[缩略图] \(url.lastPathComponent) ffmpeg 兜底也没出帧")
                    self.assetThumbnails.removeValue(forKey: id)
                } else {
                    self.assetThumbnails[id] = finalFrames
                }
                self.thumbnailsReloading.remove(id)
                self.thumbnailsGenerating.remove(id)
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
    ///
    /// 线程模型见 loadMediaThumbnail。家用机 sample 实证：坏掉的音频读取服务会让
    /// copyNextSampleBuffer 永久挂死，曾一次占满 11 条协作池线程（user-initiated 层），
    /// 饿死预览重建 Task 导致播放黑屏。专属 pthread + 超时遗弃 + ffmpeg 兜底。
    func loadWaveform(assetID: UUID, url: URL) {
        guard waveformCache[assetID] == nil else { return }
        guard !waveformGenerating.contains(assetID) else { return }
        waveformGenerating.insert(assetID)
        let id = assetID
        Thread.detachNewThread {
            var result = Self.waveformSyncWithTimeout(url: url, timeout: 30)
            if result == nil {
                DiagLog.log("[波形] AVAssetReader 失败/超时(30s) \(url.lastPathComponent)，改用 ffmpeg")
                result = Self.ffmpegWaveform(url: url)
                DiagLog.log(result != nil ? "[波形] ffmpeg 兜底成功 \(url.lastPathComponent)"
                                          : "[波形] ffmpeg 兜底也失败 \(url.lastPathComponent)")
            }
            let data = result
            DispatchQueue.main.async {
                if let d = data { self.waveformCache[id] = d }
                self.waveformGenerating.remove(id)
            }
        }
    }

    /// AVAssetReader 波形读取（内层专属 pthread；外层信号量超时，挂死即遗弃该线程）
    nonisolated static func waveformSyncWithTimeout(url: URL, timeout: Double) -> WaveformData? {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: WaveformData? = nil
        var abandoned = false
        Thread.detachNewThread {
            var dur: Double = 0
            if case .success(let d) = durationSyncWithTimeout(url: url, seconds: min(10, timeout)) {
                dur = d
            }
            guard dur > 0 else {
                lock.lock(); defer { lock.unlock() }
                if !abandoned { sem.signal() }
                return
            }
            let av = AVURLAsset(url: url)
            guard let track = av.tracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: av) else {
                lock.lock(); defer { lock.unlock() }
                if !abandoned { sem.signal() }
                return
            }
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
                // 超时后外层已放弃，尽早停止读取
                lock.lock()
                let stop = abandoned
                lock.unlock()
                if stop { reader.cancelReading(); return }
            }
            if samplesInChunk > 0 {
                allPeaks.append(Float(runningPeak) / Float(Int16.max))
            }
            lock.lock(); defer { lock.unlock() }
            guard !abandoned else { return }
            result = WaveformData(totalDuration: dur, samples: allPeaks)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); abandoned = true; lock.unlock()
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// ffmpeg 波形兜底：提 8kHz 单声道 PCM 算峰值（音频读取服务坏掉的机器用）
    nonisolated static func ffmpegWaveform(url: URL) -> WaveformData? {
        guard let ff = findFFmpeg() else { return nil }
        guard let dur = ffprobeDuration(url: url), dur > 0 else { return nil }
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                       "-i", url.path, "-vn",
                       "-f", "s16le", "-ac", "1", "-ar", "8000", "-"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        var peaks: [Float] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            // 8kHz 下每 360 样本 ≈ 45ms/峰，与原 44.1kHz/2000 样本的密度对齐
            let chunkTarget = 360
            var runningPeak: Int16 = 0
            var samplesInChunk = 0
            for sample in samples {
                let absSample = sample == Int16.min ? Int16.max : abs(sample)
                if absSample > runningPeak { runningPeak = absSample }
                samplesInChunk += 1
                if samplesInChunk >= chunkTarget {
                    peaks.append(Float(runningPeak) / Float(Int16.max))
                    runningPeak = 0
                    samplesInChunk = 0
                }
            }
            if samplesInChunk > 0 {
                peaks.append(Float(runningPeak) / Float(Int16.max))
            }
        }
        return WaveformData(totalDuration: dur, samples: peaks)
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

    /// 清空指定类型的素材，及时间轴上引用这些素材的片段
    /// 片段按 assetID 匹配删除，不按轨道类型 —— 视频素材也可能被拖进音频轨
    func clearMediaLibrary(type: AssetType) {
        let ids = Set(mediaAssets.filter { $0.type == type }.map(\.id))
        guard !ids.isEmpty else { return }
        pushUndoSavingAssets()
        mediaAssets.removeAll { ids.contains($0.id) }
        for i in videoTracks.indices    { videoTracks[i].clips.removeAll { ids.contains($0.assetID) } }
        for i in audioTracks.indices    { audioTracks[i].clips.removeAll { ids.contains($0.assetID) } }
        for i in imageTracks.indices    { imageTracks[i].clips.removeAll { ids.contains($0.assetID) } }
        // 字幕片段的 assetID 可选：手动新建的字幕没有来源素材，不该被清掉
        for i in subtitleTracks.indices {
            subtitleTracks[i].clips.removeAll { $0.assetID.map(ids.contains) ?? false }
        }
        for id in ids {
            mediaThumbnails.removeValue(forKey: id)
            waveformCache.removeValue(forKey: id)
        }
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
