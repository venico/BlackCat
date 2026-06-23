import SwiftUI
import AVFoundation
import Accelerate
import MediaToolbox

// MARK: - Preview Composition

extension ProjectState {

    /// Debounced rebuild — coalesces rapid changes (e.g. dragging sliders)
    /// into a single rebuild after a short delay, preventing flicker.
    func rebuildTimelinePreviewDebounced() {
        rebuildDebounceTimer?.invalidate()
        rebuildDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.rebuildTimelinePreview()
        }
    }

    /// Build a full timeline composition from all clips and load it as the
    /// playerItem. If `seekTo` is given, also seeks to that time after load.
    /// Gaps between clips are rendered black by AVPlayer automatically.
    func rebuildTimelinePreview(seekTo: Double? = nil) {
        // Snapshot the clip arrays so the async task captures stable values.
        let vTracks = videoTracks
        let iTracks = imageTracks
        let aTracks = audioTracks
        let sTracks = subtitleTracks
        // 默认保留当前播放位置
        let restoreTime = seekTo ?? currentTime
        // endTime 取所有轨道（不管可见性），保证播放头范围正确
        let vEnd = vTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let iEnd = iTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let aEnd = aTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let sEnd = sTracks.flatMap(\.clips).map(\.endTime).max() ?? 0
        let endTime = max(vEnd, max(iEnd, max(aEnd, sEnd)))

        // 指纹检测：跳过无变化的重复 rebuild（seekTo 除外）
        var hasher = Hasher()
        hasher.combine(vTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.trimStart)\($0.speed)\($0.volume)\($0.scaleX)\($0.scaleY)\($0.offsetX)\($0.offsetY)\($0.cropTop)\($0.cropBottom)\($0.cropLeft)\($0.cropRight)\($0.audioTrackIndex)\($0.inTransition?.type.rawValue ?? "")\($0.inTransition?.duration ?? 0)\($0.colorAdjust.brightness)\($0.colorAdjust.contrast)\($0.colorAdjust.saturation)\($0.colorAdjust.hue)" }.joined())
        hasher.combine(iTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.scaleX)\($0.scaleY)\($0.offsetX)\($0.offsetY)\($0.cropTop)\($0.cropBottom)\($0.cropLeft)\($0.cropRight)\($0.colorAdjust.brightness)\($0.colorAdjust.contrast)\($0.colorAdjust.saturation)\($0.colorAdjust.hue)" }.joined())
        hasher.combine(aTracks.flatMap(\.clips).map { "\($0.id)\($0.startTime)\($0.endTime)\($0.trimStart)\($0.speed)\($0.volume)\($0.leftChannel)\($0.rightChannel)\($0.fadeInEnabled)\($0.fadeInDuration)\($0.fadeOutEnabled)\($0.fadeOutDuration)" }.joined())
        hasher.combine(vTracks.map { "\($0.isVisible)\($0.isMuted)" }.joined())
        hasher.combine(iTracks.map { "\($0.isVisible)" }.joined())
        hasher.combine(aTracks.map { "\($0.isVisible)\($0.isMuted)" }.joined())
        let fp = hasher.finalize()
        if seekTo == nil && fp == lastRebuildFingerprint { return }
        lastRebuildFingerprint = fp
        rebuildTask?.cancel()
        rebuildTask = Task {
            let composition = AVMutableComposition()
            var audioParams: [(trackID: CMPersistentTrackID, volume: Float, left: Float, right: Float, startTime: Double, duration: Double, fadeIn: Double, fadeOut: Double)] = []
            var videoCompTracks: [(track: AVMutableCompositionTrack, clip: VideoClip, startTime: Double, endTime: Double)] = []  // from video clips
            var imageCompTracks: [(track: AVMutableCompositionTrack, clip: ImageClip)] = []  // from image clips (on top)
            let renderSize = previewRenderSize

            // 视频轨道 — 第一遍：预加载 assetDur，计算平均分配的 half
            // aExtend = A 延伸量（借 A 的 asset 尾部），bAdvance = B 提前量（借 B 的 trimStart 前内容）
            struct TransAdj { let clipAID: UUID; let clipBID: UUID; let half: Double; let type: TransitionType }
            var transAdjusts: [TransAdj] = []
            var clipAssetDurSec: [UUID: Double] = [:]
            for track in vTracks {
                let sortedClips = track.clips.sorted { $0.startTime < $1.startTime }
                for clip in sortedClips {
                    guard let url = clip.url else { continue }
                    let dur = (try? await self.cachedAVAsset(url: url).load(.duration))?.seconds ?? 0
                    clipAssetDurSec[clip.id] = dur
                }
                guard sortedClips.count >= 2 else { continue }
                for i in 1..<sortedClips.count {
                    let cA = sortedClips[i - 1], cB = sortedClips[i]
                    guard let trans = cB.inTransition,
                          abs(cA.endTime - cB.startTime) < 0.05 else { continue }
                    let wantedHalf = trans.duration / 2
                    let half: Double
                    if trans.type == .fadeToBlack {
                        // fadeToBlack 无 overlap，half 直接用 wantedHalf（各自消耗自己的内容）
                        half = wantedHalf
                    } else {
                        // 平均分配：A 延伸 half（受 asset 尾部余量限制），B 提前 half（受 trimStart 限制）
                        // A 消耗的源素材 = duration * speed，剩余可延伸 = assetDur - trimStart - duration*speed
                        let availA = max(0, (clipAssetDurSec[cA.id] ?? 0) - (cA.trimStart + cA.duration * cA.speed))
                        let availB = cB.trimStart
                        half = max(0, min(wantedHalf, min(availA, availB)))
                    }
                    if half > 0.005 {
                        transAdjusts.append(TransAdj(clipAID: cA.id, clipBID: cB.id, half: half, type: trans.type))
                    }
                }
            }

            // 视频轨道 — 第二遍：按 transAdjusts 插入（A 延伸 + B 提前）
            for track in vTracks {
                let sortedClips = track.clips.sorted(by: { $0.startTime < $1.startTime })
                for clip in sortedClips {
                    guard let url = clip.url else { continue }
                    let asset = self.cachedAVAsset(url: url)
                    let assetDurSec = clipAssetDurSec[clip.id] ?? 0
                    let assetDur = CMTime(seconds: assetDurSec, preferredTimescale: 600)
                    let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
                    let maxSrcDur = assetDur - trimSt
                    // 变速：源素材消耗 = duration * speed，timeline 时长上限 = maxSrcDur / speed
                    let speed = max(0.01, clip.speed)
                    let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / speed, preferredTimescale: 600)
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), maxTimelineDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let srcContentDurSec = useDur.seconds * speed  // 源素材实际消耗量（秒）

                    // 查询该 clip 作为 A 需要延伸多少，作为 B 需要提前多少
                    let aExtend  = transAdjusts.first(where: { $0.clipAID == clip.id && $0.type != .fadeToBlack })?.half ?? 0
                    let bAdvance = transAdjusts.first(where: { $0.clipBID == clip.id && $0.type != .fadeToBlack })?.half ?? 0

                    // 视频 source range：从 (trimStart - bAdvance) 开始，读 (srcContentDur + bAdvance + aExtend) 秒源素材
                    let actualTrimSt = CMTime(seconds: clip.trimStart - bAdvance, preferredTimescale: 600)
                    let actualSrcDur = CMTime(seconds: srcContentDurSec + bAdvance + aExtend, preferredTimescale: 600)
                    let actualRange  = CMTimeRange(start: actualTrimSt, duration: actualSrcDur)
                    let at           = CMTime(seconds: clip.startTime - bAdvance, preferredTimescale: 600)
                    let targetDurSec = useDur.seconds + bAdvance + aExtend   // timeline 上的目标时长
                    if track.isVisible,
                       let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? vt.insertTimeRange(actualRange, of: vAsset, at: at)
                        // 变速：把 actualSrcDur 缩放到 targetDur
                        if abs(speed - 1.0) > 0.001 {
                            let compRange = CMTimeRange(start: at, duration: actualSrcDur)
                            vt.scaleTimeRange(compRange, toDuration: CMTime(seconds: targetDurSec, preferredTimescale: 600))
                        }
                        videoCompTracks.append((vt, clip,
                                                clip.startTime - bAdvance,         // 实际开始（B 提前）
                                                clip.startTime + useDur.seconds + aExtend)) // 实际结束（A 延伸）
                    }
                    if !track.isMuted {
                        let audioAt = CMTime(seconds: clip.startTime, preferredTimescale: 44100)
                        if abs(speed - 1.0) > 0.001 {
                            // 变速：ffmpeg atempo 预处理，生成已变速的临时音频文件（正常速度 insert）
                            if let speedURL = await self.generateSpeedAudio(
                                inputURL: url, trimStart: clip.trimStart,
                                srcDurSec: srcContentDurSec, speed: speed,
                                audioTrackIndex: clip.audioTrackIndex),
                               let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let sAsset = AVURLAsset(url: speedURL)
                                if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                    let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                    let ins = CMTimeMinimum(sDur, CMTime(seconds: useDur.seconds, preferredTimescale: 44100))
                                    try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: audioAt)
                                    audioParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, ins.seconds, 0, 0))
                                }
                            }
                        } else {
                            // 正常速度
                            let allAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                            let idx = min(clip.audioTrackIndex, max(allAudioTracks.count - 1, 0))
                            if let aAsset = allAudioTracks.isEmpty ? nil : allAudioTracks[idx] as AVAssetTrack?,
                               let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid) {
                                let ats: CMTimeScale = 44100
                                let trimSt  = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                                let useDurC = CMTime(seconds: useDur.seconds, preferredTimescale: ats)
                                try? at2.insertTimeRange(CMTimeRange(start: trimSt, duration: useDurC), of: aAsset, at: audioAt)
                                audioParams.append((at2.trackID, clip.volume, 1.0, 1.0, clip.startTime, useDur.seconds, 0, 0))
                            }
                        }
                    }
                }
            }

            // 收集转场信息
            var transitionInfos: [TransitionCompInfo] = []
            for adj in transAdjusts {
                guard let entryA = videoCompTracks.first(where: { $0.clip.id == adj.clipAID }),
                      let entryB = videoCompTracks.first(where: { $0.clip.id == adj.clipBID }) else { continue }
                let ts: CMTimeScale = 600
                let cutT         = CMTime(seconds: entryB.clip.startTime, preferredTimescale: ts)
                let overlapStart = CMTime(seconds: entryB.clip.startTime - adj.half, preferredTimescale: ts)
                let overlapEnd   = CMTime(seconds: entryB.clip.startTime + adj.half, preferredTimescale: ts)
                let natSizeA = (try? await entryA.track.load(.naturalSize)) ?? .zero
                let natSizeB = (try? await entryB.track.load(.naturalSize)) ?? .zero
                transitionInfos.append(TransitionCompInfo(
                    trackA: entryA.track, trackB: entryB.track,
                    clipA: entryA.clip, clipB: entryB.clip,
                    type: adj.type,
                    overlapStart: overlapStart, overlapEnd: overlapEnd, cutT: cutT,
                    half: adj.half, renderSize: renderSize,
                    natSizeA: natSizeA, natSizeB: natSizeB
                ))
            }

            // 图片轨道（上层）
            for track in iTracks {
                guard track.isVisible else { continue }
                for clip in track.clips {
                    var url = clip.videoURL
                    if let u = url, !FileManager.default.fileExists(atPath: u.path) {
                        url = nil
                    }
                    if url == nil, let imgURL = clip.imageURL {
                        url = await Self.createVideoFromImage(imageURL: imgURL, duration: clip.duration)
                        if let u = url {
                            await MainActor.run {
                                self.imageVideoCache[clip.assetID] = u
                                self.updateImageClip(id: clip.id) { $0.videoURL = u }
                            }
                        }
                    }
                    guard let url else { continue }
                    let asset = self.cachedAVAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let useDur = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: 600), assetDur)
                    guard useDur.seconds > 0.01 else { continue }
                    if let vAsset = try? await asset.loadTracks(withMediaType: .video).first,
                       let vt = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                        // 先填充 clip 之前的空白区间（确保 track 在所有 segment 都有 sample）
                        if clip.startTime > 0.01 {
                            var pos = CMTime.zero
                            let fillEnd = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        // 在 clip 的时间位置插入实际内容
                        let range = CMTimeRange(start: .zero, duration: useDur)
                        let at = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                        try? vt.insertTimeRange(range, of: vAsset, at: at)
                        // clip 之后也填充到 endTime（处理视频比图片长的情况）
                        let afterEnd = clip.startTime + useDur.seconds
                        if endTime > afterEnd + 0.01 {
                            var pos = CMTime(seconds: afterEnd, preferredTimescale: 600)
                            let fillEnd = CMTime(seconds: endTime, preferredTimescale: 600)
                            while pos < fillEnd {
                                let remaining = fillEnd - pos
                                let fillDur = CMTimeMinimum(assetDur, remaining)
                                try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: fillDur), of: vAsset, at: pos)
                                pos = pos + fillDur
                            }
                        }
                        imageCompTracks.append((track: vt, clip: clip))
                    }
                }
            }

            for track in aTracks {
                guard track.isVisible && !track.isMuted else { continue }
                for clip in track.clips {
                    guard let url = clip.url else { continue }
                    let asset    = self.cachedAVAsset(url: url)
                    let assetDur = (try? await asset.load(.duration)) ?? .zero
                    let aspeed   = max(0.01, clip.speed)
                    let ats: CMTimeScale = 44100
                    let trimSt   = CMTime(seconds: clip.trimStart, preferredTimescale: ats)
                    let maxSrcDur = assetDur - trimSt
                    let maxTimelineDur = CMTime(seconds: maxSrcDur.seconds / aspeed, preferredTimescale: ats)
                    let useDur   = CMTimeMinimum(CMTime(seconds: clip.duration, preferredTimescale: ats), maxTimelineDur)
                    guard useDur.seconds > 0.01 else { continue }
                    let srcDurSec = useDur.seconds * aspeed
                    let at        = CMTime(seconds: clip.startTime, preferredTimescale: ats)

                    if abs(aspeed - 1.0) > 0.001 {
                        // 变速：ffmpeg atempo 预处理
                        if let speedURL = await self.generateSpeedAudio(
                            inputURL: url, trimStart: clip.trimStart,
                            srcDurSec: srcDurSec, speed: aspeed, audioTrackIndex: 0),
                           let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
                            let sAsset = AVURLAsset(url: speedURL)
                            if let sTrack = try? await sAsset.loadTracks(withMediaType: .audio).first {
                                let sDur = (try? await sAsset.load(.duration)) ?? .zero
                                let ins  = CMTimeMinimum(sDur, useDur)
                                try? at2.insertTimeRange(CMTimeRange(start: .zero, duration: ins), of: sTrack, at: at)
                                let effDur  = ins.seconds
                                let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  effDur) : 0
                                let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, effDur - fadeIn)) : 0
                                audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, effDur, fadeIn, fadeOut))
                            }
                        }
                    } else {
                        // 正常速度
                        guard let aAsset = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                        if let at2 = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
                            try? at2.insertTimeRange(CMTimeRange(start: trimSt, duration: useDur), of: aAsset, at: at)
                            let effDur  = useDur.seconds
                            let fadeIn  = clip.fadeInEnabled  ? min(max(0, clip.fadeInDuration),  effDur) : 0
                            let fadeOut = clip.fadeOutEnabled ? min(max(0, clip.fadeOutDuration), max(0, effDur - fadeIn)) : 0
                            audioParams.append((at2.trackID, clip.volume, clip.leftChannel, clip.rightChannel, clip.startTime, effDur, fadeIn, fadeOut))
                        }
                    }
                }
            }

            // 用空白音频轨道撑开 composition 到 endTime
            let compositionDur = composition.duration.seconds
            if endTime > compositionDur + 0.1 {
                if let padTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                    padTrack.insertEmptyTimeRange(
                        CMTimeRange(start: CMTime(seconds: compositionDur, preferredTimescale: 600),
                                    duration: CMTime(seconds: endTime - compositionDur, preferredTimescale: 600)))
                }
            }

            // 构建 AudioMix — 音量 + 淡入淡出 + 左右声道
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParams.map { param in
                let p = AVMutableAudioMixInputParameters(track: composition.track(withTrackID: param.trackID))
                p.trackID = param.trackID
                let ts: CMTimeScale = 600
                let clipStart = CMTime(seconds: param.startTime, preferredTimescale: ts)
                let clipDur   = param.duration
                if param.fadeIn > 0 || param.fadeOut > 0 {
                    // volume ramp 必须按时间递增顺序添加：淡入 → 中间 → 淡出，否则 AVFoundation 抛异常崩溃
                    // 1) 淡入：0 → volume
                    if param.fadeIn > 0 {
                        p.setVolumeRamp(fromStartVolume: 0, toEndVolume: param.volume,
                                        timeRange: CMTimeRange(start: clipStart,
                                                               duration: CMTime(seconds: param.fadeIn, preferredTimescale: ts)))
                    }
                    // 2) 中间段：保持基准音量（淡入结束 → 淡出开始）
                    let midStartSec = param.startTime + param.fadeIn
                    let midDurSec   = clipDur - param.fadeIn - param.fadeOut
                    if midDurSec > 0.001 {
                        p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: param.volume,
                                        timeRange: CMTimeRange(start: CMTime(seconds: midStartSec, preferredTimescale: ts),
                                                               duration: CMTime(seconds: midDurSec, preferredTimescale: ts)))
                    }
                    // 3) 淡出：volume → 0
                    if param.fadeOut > 0 {
                        let fadeOutStart = CMTime(seconds: param.startTime + clipDur - param.fadeOut, preferredTimescale: ts)
                        p.setVolumeRamp(fromStartVolume: param.volume, toEndVolume: 0,
                                        timeRange: CMTimeRange(start: fadeOutStart,
                                                               duration: CMTime(seconds: param.fadeOut, preferredTimescale: ts)))
                    }
                } else {
                    p.setVolume(param.volume, at: .zero)
                }
                // 左右声道不全是 1.0 时，用 MTAudioProcessingTap 处理
                if param.left != 1.0 || param.right != 1.0 {
                    if let tap = makeChannelTap(left: param.left, right: param.right) {
                        p.audioTapProcessor = tap
                    }
                }
                return p
            }

            // Build AVVideoComposition to layer image tracks on top of video tracks.
            let allVideoTracks = videoCompTracks.map(\.track) + imageCompTracks.map(\.track)
            var videoComposition: AVMutableVideoComposition? = nil
            if !allVideoTracks.isEmpty && composition.duration.seconds > 0.01 {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: 30)
                vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid

                // Collect image clip time ranges
                let ts: CMTimeScale = 600
                let imageClipCMRanges = imageCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.clip.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.clip.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                // Collect video clip time ranges
                let videoClipCMRanges = videoCompTracks.map { entry -> (start: CMTime, end: CMTime) in
                    let s = CMTime(seconds: entry.startTime, preferredTimescale: ts)
                    let e = CMTime(seconds: entry.endTime, preferredTimescale: ts)
                    return (s, e)
                }

                // Collect all time boundaries (CMTime)
                var cmBoundaries: [CMTime] = [.zero, composition.duration]
                for r in imageClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                for r in videoClipCMRanges { cmBoundaries.append(r.start); cmBoundaries.append(r.end) }
                for ti in transitionInfos {
                    cmBoundaries.append(ti.overlapStart)
                    cmBoundaries.append(ti.overlapEnd)
                    if ti.type == .fadeToBlack { cmBoundaries.append(ti.cutT) }
                }
                let sortedCM = Array(Set(cmBoundaries.map { $0.value })).sorted().map { CMTime(value: $0, timescale: ts) }

                vc.customVideoCompositorClass = ColorCompositor.self
                ColorCompositor.clearStore()
                var colorInstructions: [AVVideoCompositionInstruction] = []
                for i in 0..<(sortedCM.count - 1) {
                    let segStartCM = sortedCM[i]
                    let segEndCM   = sortedCM[i + 1]
                    let segDur = segEndCM - segStartCM
                    guard segDur.seconds > 0.001 else { continue }

                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: segStartCM, duration: segDur)

                    var entries:      [CompositorTrackEntry] = []
                    var activeTracks: [AVCompositionTrack]   = []
                    var hasTween = false

                    // 视频 track（底层）
                    for (idx, entry) in videoCompTracks.enumerated() {
                        let clipStart = videoClipCMRanges[idx].start
                        let clipEnd   = videoClipCMRanges[idx].end
                        guard segStartCM >= clipStart && segStartCM < clipEnd else { continue }
                        guard (try? await entry.track.load(.naturalSize)) != nil else { continue }
                        let clip = entry.clip
                        var te = CompositorTrackEntry(
                            trackID:     entry.track.trackID,
                            userScaleX:  CGFloat(clip.scaleX),
                            userScaleY:  CGFloat(clip.scaleY),
                            userOffsetX: CGFloat(clip.offsetX),
                            userOffsetY: CGFloat(clip.offsetY),
                            cropTop:     CGFloat(clip.cropTop),
                            cropBottom:  CGFloat(clip.cropBottom),
                            cropLeft:    CGFloat(clip.cropLeft),
                            cropRight:   CGFloat(clip.cropRight),
                            colorAdjust: clip.colorAdjust,
                            opacityRamp: nil,
                            pushRamp:    nil)
                        // 转场渐变
                        for trans in transitionInfos {
                            let isA = entry.track === trans.trackA
                            let isB = entry.track === trans.trackB
                            guard isA || isB else { continue }
                            let effStart: CMTime
                            let effEnd: CMTime
                            if trans.type == .fadeToBlack {
                                effStart = isA ? trans.overlapStart : trans.cutT
                                effEnd   = isA ? trans.cutT : trans.overlapEnd
                            } else {
                                effStart = trans.overlapStart
                                effEnd   = trans.overlapEnd
                            }
                            guard segStartCM >= effStart && segStartCM < effEnd else { continue }
                            let fOp: Float = isA ? 1.0 : 0.0
                            let tOp: Float = isA ? 0.0 : 1.0
                            switch trans.type {
                            case .dissolve, .fadeToBlack:
                                te.opacityRamp = (from: fOp, to: tOp,
                                                  start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .pushLeft, .pushRight, .pushUp, .pushDown:
                                let (dx, dy): (CGFloat, CGFloat) = {
                                    switch trans.type {
                                    case .pushLeft:  return (-renderSize.width,  0)
                                    case .pushRight: return ( renderSize.width,  0)
                                    case .pushUp:    return (0,  renderSize.height)
                                    default:         return (0, -renderSize.height)
                                    }
                                }()
                                te.pushRamp = (dx: dx, dy: dy, isA: isA,
                                               start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .zoom:
                                te.opacityRamp = (from: fOp, to: tOp,
                                                  start: effStart.seconds, end: effEnd.seconds)
                                te.zoomRamp = (from: isA ? 1.0 : 1.4, to: isA ? 1.4 : 1.0,
                                               start: effStart.seconds, end: effEnd.seconds)
                                hasTween = true
                            case .slideLeft, .slideRight, .slideUp, .slideDown:
                                if isB {
                                    let (dx, dy): (CGFloat, CGFloat) = {
                                        switch trans.type {
                                        case .slideLeft:  return (-renderSize.width,  0)
                                        case .slideRight: return ( renderSize.width,  0)
                                        case .slideUp:    return (0,  renderSize.height)
                                        default:          return (0, -renderSize.height)
                                        }
                                    }()
                                    te.pushRamp = (dx: dx, dy: dy, isA: false,
                                                   start: effStart.seconds, end: effEnd.seconds)
                                }
                                hasTween = true
                            }
                            break
                        }
                        entries.append(te)
                        activeTracks.append(entry.track)
                    }

                    // 图片 track（顶层）
                    for (idx, entry) in imageCompTracks.enumerated() {
                        let clipStartCM = imageClipCMRanges[idx].start
                        let clipEndCM   = imageClipCMRanges[idx].end
                        guard segStartCM >= clipStartCM && segStartCM < clipEndCM else { continue }
                        let iclip = entry.clip
                        let te = CompositorTrackEntry(
                            trackID:     entry.track.trackID,
                            userScaleX:  CGFloat(iclip.scaleX),
                            userScaleY:  CGFloat(iclip.scaleY),
                            userOffsetX: CGFloat(iclip.offsetX),
                            userOffsetY: CGFloat(iclip.offsetY),
                            cropTop:     CGFloat(iclip.cropTop),
                            cropBottom:  CGFloat(iclip.cropBottom),
                            cropLeft:    CGFloat(iclip.cropLeft),
                            cropRight:   CGFloat(iclip.cropRight),
                            colorAdjust: iclip.colorAdjust,
                            opacityRamp: nil,
                            pushRamp:    nil)
                        entries.append(te)
                        activeTracks.append(entry.track)
                    }

                    instr.layerInstructions = activeTracks.map {
                        AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
                    }
                    instr.enablePostProcessing = hasTween

                    let colorData = ColorCompositionData()
                    colorData.entries    = entries
                    colorData.renderSize = renderSize
                    let key = CMTimeConvertScale(segStartCM, timescale: 600, method: .default).value
                    ColorCompositor.setData(colorData, forStartValue: key)

                    colorInstructions.append(instr)
                }

                if !colorInstructions.isEmpty {
                    vc.instructions = colorInstructions
                    videoComposition = vc
                }
            }

            let visualEnd = max(vEnd, iEnd)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lastVideoEndTime = visualEnd
                self.duration = max(endTime, 0.01)
                self.pendingSeekTime = restoreTime
                if composition.tracks.isEmpty && endTime < 0.01 {
                    self.playerItem = nil
                } else {
                    let item = AVPlayerItem(asset: composition)
                    item.audioTimePitchAlgorithm = .varispeed
                    item.audioMix = audioMix
                    if let vc = videoComposition {
                        item.videoComposition = vc
                    }
                    self.playerItem = item
                }
            }
        }
    }

    // MARK: - Image transform helpers

    static func imageTransform(clip: ImageClip, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard natSize.width > 0, natSize.height > 0 else {
            return CGAffineTransform(scaleX: 0, y: 0)
        }
        let baseScale = min(renderSize.width / natSize.width, renderSize.height / natSize.height)
        let finalSX = baseScale * CGFloat(clip.scaleX)
        let finalSY = baseScale * CGFloat(clip.scaleY)
        let tx = (renderSize.width  - natSize.width  * finalSX) / 2 + CGFloat(clip.offsetX) * renderSize.width
        let ty = (renderSize.height - natSize.height * finalSY) / 2 + CGFloat(clip.offsetY) * renderSize.height
        return CGAffineTransform(scaleX: finalSX, y: finalSY)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    static func imageCropRect(clip: ImageClip, natSize: CGSize) -> CGRect {
        let x = natSize.width  * CGFloat(clip.cropLeft)
        let y = natSize.height * CGFloat(clip.cropTop)
        let w = natSize.width  * (1 - CGFloat(clip.cropLeft + clip.cropRight))
        let h = natSize.height * (1 - CGFloat(clip.cropTop  + clip.cropBottom))
        return CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
    }

    // MARK: - Video transform helpers

    static func videoTransform(clip: VideoClip, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard natSize.width > 0, natSize.height > 0 else {
            return CGAffineTransform(scaleX: 0, y: 0)
        }
        let baseScale = min(renderSize.width / natSize.width, renderSize.height / natSize.height)
        let finalSX = baseScale * CGFloat(clip.scaleX)
        let finalSY = baseScale * CGFloat(clip.scaleY)
        let tx = (renderSize.width  - natSize.width  * finalSX) / 2 + CGFloat(clip.offsetX) * renderSize.width
        let ty = (renderSize.height - natSize.height * finalSY) / 2 + CGFloat(clip.offsetY) * renderSize.height
        return CGAffineTransform(scaleX: finalSX, y: finalSY)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    static func videoCropRect(clip: VideoClip, natSize: CGSize) -> CGRect {
        let x = natSize.width  * CGFloat(clip.cropLeft)
        let y = natSize.height * CGFloat(clip.cropTop)
        let w = natSize.width  * (1 - CGFloat(clip.cropLeft + clip.cropRight))
        let h = natSize.height * (1 - CGFloat(clip.cropTop  + clip.cropBottom))
        return CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
    }

    // MARK: - Transition ramp helper

    static func applyTransitionRamp(
        li: AVMutableVideoCompositionLayerInstruction,
        track: AVMutableCompositionTrack,
        clip: VideoClip,
        transform t: CGAffineTransform,
        natSize: CGSize,
        renderSize: CGSize,
        segStart: CMTime,
        transitions: [TransitionCompInfo]
    ) {
        let ts: CMTimeScale = 600
        for trans in transitions {
            let isA = track === trans.trackA
            let isB = track === trans.trackB
            guard isA || isB else { continue }

            let segStart_forA: CMTime
            let segEnd_forA:   CMTime
            let segStart_forB: CMTime
            let segEnd_forB:   CMTime
            if trans.type == .fadeToBlack {
                segStart_forA = trans.overlapStart;  segEnd_forA = trans.cutT
                segStart_forB = trans.cutT;          segEnd_forB = trans.overlapEnd
            } else {
                segStart_forA = trans.overlapStart;  segEnd_forA = trans.overlapEnd
                segStart_forB = trans.overlapStart;  segEnd_forB = trans.overlapEnd
            }

            let effectStart = isA ? segStart_forA : segStart_forB
            let effectEnd   = isA ? segEnd_forA   : segEnd_forB
            guard segStart >= effectStart && segStart < effectEnd else { continue }

            let fadeRange = CMTimeRange(start: effectStart, duration: effectEnd - effectStart)
            let fromOpacity: Float = isA ? 1 : 0
            let toOpacity:   Float = isA ? 0 : 1

            let pushDX: CGFloat
            let pushDY: CGFloat
            switch trans.type {
            case .pushLeft:  pushDX = -renderSize.width;  pushDY = 0
            case .pushRight: pushDX =  renderSize.width;  pushDY = 0
            case .pushUp:    pushDX = 0; pushDY =  renderSize.height
            case .pushDown:  pushDX = 0; pushDY = -renderSize.height
            default:         pushDX = 0; pushDY = 0
            }

            switch trans.type {
            case .dissolve, .fadeToBlack:
                li.setOpacityRamp(fromStartOpacity: fromOpacity, toEndOpacity: toOpacity,
                                  timeRange: fadeRange)
            case .pushLeft, .pushRight, .pushUp, .pushDown:
                let offsetFwd = CGAffineTransform(translationX:  pushDX, y:  pushDY)
                let offsetRev = CGAffineTransform(translationX: -pushDX, y: -pushDY)
                let fromT = isA ? t : t.concatenating(offsetRev)
                let toT   = isA ? t.concatenating(offsetFwd) : t
                li.setTransformRamp(fromStart: fromT, toEnd: toT, timeRange: fadeRange)
            case .zoom:
                let cx = renderSize.width / 2, cy = renderSize.height / 2
                func zoomAffine(_ s: CGFloat) -> CGAffineTransform {
                    CGAffineTransform(translationX: cx, y: cy)
                        .scaledBy(x: s, y: s)
                        .translatedBy(x: -cx, y: -cy)
                }
                let fromS: CGFloat = isA ? 1.0 : 1.4
                let toS:   CGFloat = isA ? 1.4 : 1.0
                li.setOpacityRamp(fromStartOpacity: fromOpacity, toEndOpacity: toOpacity,
                                  timeRange: fadeRange)
                li.setTransformRamp(fromStart: t.concatenating(zoomAffine(fromS)),
                                    toEnd:     t.concatenating(zoomAffine(toS)),
                                    timeRange: fadeRange)
            case .slideLeft, .slideRight, .slideUp, .slideDown:
                if isB {
                    let (sdx, sdy): (CGFloat, CGFloat) = {
                        switch trans.type {
                        case .slideLeft:  return (-renderSize.width,  0)
                        case .slideRight: return ( renderSize.width,  0)
                        case .slideUp:    return (0,  renderSize.height)
                        default:          return (0, -renderSize.height)
                        }
                    }()
                    let offsetRev = CGAffineTransform(translationX: -sdx, y: -sdy)
                    li.setTransformRamp(fromStart: t.concatenating(offsetRev),
                                        toEnd: t, timeRange: fadeRange)
                }
            }
            break
        }
    }

    /// Select a clip for preview and seek to its start so the user sees it.
    func loadClipForPreview(_ clip: VideoClip) {
        rebuildTimelinePreview(seekTo: clip.startTime)
    }

    // MARK: - Image -> Video generation

    static func createVideoFromImage(imageURL: URL, duration: Double) async -> URL? {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let width = cgImage.width
        let height = cgImage.height

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Write 1 frame per second
        let totalFrames = max(Int(duration), 1)
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: 1))
        }
        // Final frame at exact end
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(pb, withPresentationTime: CMTime(seconds: duration, preferredTimescale: 600))

        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }
}
