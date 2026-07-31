// ProjectState+AudioSeparate.swift
// 分离音轨：调用 demucs 分离，勾选的每一轨各生成一条独立音频轨道。
import Foundation
import AVFoundation

/// 进度节流：分离进程回调极频繁，限制成最多每 0.2 秒或进度跳变 1% 才向主线程派发
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = Date.distantPast
    private var lastPct: Double = -1

    func shouldEmit(_ pct: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastTime) > 0.2 || abs(pct - lastPct) >= 0.01 || pct >= 1.0 else {
            return false
        }
        lastTime = now
        lastPct = pct
        return true
    }
}

extension ProjectState {

    /// 当前选中片段能否做音源分离（只有视频/音频片段有音轨）
    var canRemoveBackgroundMusic: Bool {
        guard !isSeparatingAudio else { return false }
        if let id = selectedVideoClipID,
           let clip = videoTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            return !isSeparatedOutput(clip.url ?? mediaAssets.first { $0.id == clip.assetID }?.url)
        }
        if let id = selectedAudioClipID,
           let clip = audioTracks.flatMap(\.clips).first(where: { $0.id == id }) {
            return !isSeparatedOutput(clip.url ?? mediaAssets.first { $0.id == clip.assetID }?.url)
        }
        return false
    }

    /// 分离产物再分离没意义（人声轨里已无音乐），按输出目录判断
    private func isSeparatedOutput(_ url: URL?) -> Bool {
        guard let url else { return false }
        let outDir = AudioSeparator.separatedDir.standardizedFileURL.path
        return url.standardizedFileURL.deletingLastPathComponent().path == outDir
    }

    /// 分离选中片段的音轨，勾选的每一轨各生成一条独立音频轨道
    func removeBackgroundMusicForSelection() {
        guard !isSeparatingAudio else { return }

        guard AudioSeparator.demucsReady else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "分离音轨",
                             subtitle: "缺少 demucs.cpp.main，请先安装分离组件",
                             autoCountdown: false)
            return
        }

        // 找到源文件、裁剪范围和片段在时间轴上的位置
        let source: (url: URL, trimStart: Double, duration: Double, timelineStart: Double)
        if let id = selectedVideoClipID,
           let clip = videoTracks.flatMap(\.clips).first(where: { $0.id == id }),
           let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url {
            source = (url, clip.trimStart, clip.duration * clip.speed, clip.startTime)
        } else if let id = selectedAudioClipID,
                  let clip = audioTracks.flatMap(\.clips).first(where: { $0.id == id }),
                  let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url {
            source = (url, clip.trimStart, clip.duration * clip.speed, clip.startTime)
        } else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                             title: "分离音轨", subtitle: "请先选中一个视频或音频片段")
            return
        }

        guard FileManager.default.fileExists(atPath: source.url.path) else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "分离音轨", subtitle: "源文件不存在", autoCountdown: false)
            return
        }

        separateTask = Task { @MainActor in
            do {
                // 模型缺失时先下载
                if !AudioSeparator.modelReady {
                    separateState = .downloading(0)
                    try await AudioSeparator.downloadModel { p in
                        Task { @MainActor in self.separateState = .downloading(p) }
                    }
                    try Task.checkCancellation()
                }

                separateState = .running(0, "准备中…")
                // demucs 每秒回调几十次，不节流会把主线程队列打满
                let throttle = ProgressThrottle()
                let stems = try await AudioSeparator.separateStems(
                    mediaURL: source.url,
                    trimStart: source.trimStart,
                    duration: source.duration
                ) { pct, stage in
                    guard throttle.shouldEmit(pct) else { return }
                    Task { @MainActor in self.separateState = .running(pct, stage) }
                }
                try Task.checkCancellation()

                let added = addStemTracks(stems, timelineStart: source.timelineStart,
                                          duration: source.duration,
                                          sourceName: source.url.deletingPathExtension().lastPathComponent)
                separateState = .idle
                separateTask = nil
                if added > 0 {
                    showSuccessToast(icon: "waveform", iconColor: .green,
                                     title: "音轨分离",
                                     subtitle: "已生成 \(added) 条音轨",
                                     revealURL: stems.first?.url)
                } else {
                    showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                     title: "音轨分离",
                                     subtitle: "处理完成但轨道创建失败，文件已保存",
                                     autoCountdown: false, revealURL: stems.first?.url)
                }
            } catch is CancellationError {
                separateState = .idle
                separateTask = nil
            } catch AudioSeparator.SeparateError.cancelled {
                // 取消的提示统一由 cancelSeparate() 弹，这里再弹会出现两张卡片
                separateState = .idle
                separateTask = nil
            } catch {
                separateState = .idle
                separateTask = nil
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "分离音轨",
                                 subtitle: error.localizedDescription,
                                 autoCountdown: false)
            }
        }
    }

    /// 「视频名_人声」，已存在同名就往后排序号：视频名_人声2、视频名_人声3…
    private func uniqueStemName(sourceName: String, stem: String) -> String {
        let base = "\(sourceName)_\(stem)"
        var used = Set(mediaAssets.map(\.name))
        used.formUnion(audioTracks.map(\.label))
        used.formUnion(audioTracks.flatMap(\.clips).map(\.name))
        guard used.contains(base) else { return base }
        var i = 2
        while used.contains("\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    /// 每条分离出的轨各建一条音频轨道，对齐到原片段的时间轴位置。整体一次撤销
    /// - Returns: 成功创建的轨道数
    private func addStemTracks(_ stems: [(stem: AudioSeparator.Stem, url: URL)],
                               timelineStart: Double, duration: Double,
                               sourceName: String) -> Int {
        guard !stems.isEmpty else { return 0 }
        pushUndo()

        var added = 0
        for item in stems {
            // 素材名、片段标题、轨道名共用同一个，三处保持一致
            let name = uniqueStemName(sourceName: sourceName, stem: item.stem.displayName)
            importFileDirectly(url: item.url, type: .audio, displayName: name)
            guard let asset = mediaAssets.first(where: { $0.url == item.url }) else {
                NSLog("[Separate] 导入失败: %@", item.url.path)
                continue
            }
            // 分离出的文件已按 trim 范围裁好，从头播放即可
            let clip = AudioClip(assetID: asset.id,
                                 name: name,
                                 url: item.url,
                                 startTime: timelineStart,
                                 endTime: timelineStart + duration,
                                 trimStart: 0)
            audioTracks.append(Track(clips: [clip], label: name))
            added += 1
        }

        if added > 0 {
            // 时间轴按 audioSectionOrder 渲染，不同步的话新轨道建了也不显示
            syncAudioSectionOrder()
            rebuildTimelinePreview()
        }
        return added
    }
}
