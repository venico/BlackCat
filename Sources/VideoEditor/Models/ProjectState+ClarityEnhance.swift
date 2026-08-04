// ProjectState+ClarityEnhance.swift
// 清晰度提升：ffmpeg 抽帧 → CoreML 逐帧超分 → ffmpeg 重编码 → 新建素材+新建轨道。
// 骨架照抄 ProjectState+AudioSeparate.swift（demucs 音轨分离）。
import Foundation
import SwiftUI
import AVFoundation
import AppKit

extension ProjectState {

    var canEnhanceClarity: Bool {
        guard !isEnhancingClarity else { return false }
        return selectedVideoClipID != nil
    }

    /// 每像素输出 PNG 的估算体积（bytes/px），用于按"这次实际要放大到的分辨率"推算
    /// 磁盘占用。Whole-branch review 实测真实 PNG 体积（photographic 内容）反推：
    /// 1080p→x2 3.93MB（输出 3840x2160=830万px，≈0.47 B/px）、1080p→x4 12.2MB
    /// （输出 7680x4320=3318万px，≈0.37 B/px）、4K源→x4 48MB（输出
    /// 15360x8640=1.33亿px，≈0.36 B/px）。三组实测收敛在 0.36~0.47 B/px，取 0.5
    /// 留安全余量——宁可预计空间比实际需要略多，也不要重演"通过检查后跑到一半
    /// 磁盘满、ENOSPC 原始错误字符串弹给用户"的问题。
    private static let estimatedBytesPerOutputPixel: Double = 0.5
    /// videoWidth/videoHeight 未知时（新建 clip 没探测过尺寸，值为 0）的回退值，
    /// 就是原先唯一使用的那个固定常量
    private static let fallbackEstimatedBytesPerFrame: Int64 = 4_000_000

    /// 单帧输出 PNG 的估算体积：按这次要放大到的输出分辨率（源分辨率 × scale）算，
    /// 不是一个跟分辨率无关的固定常量——固定常量在放大倍数越高、源分辨率越大时
    /// 会严重低估（1080p x4 低估 3 倍，4K 源 x4 低估 12 倍，都实测验证过）。
    private static func estimatedBytesPerFrame(outputWidth: Double, outputHeight: Double) -> Int64 {
        guard outputWidth > 0.001, outputHeight > 0.001 else { return fallbackEstimatedBytesPerFrame }
        return Int64(outputWidth * outputHeight * estimatedBytesPerOutputPixel)
    }
    /// 单帧处理耗时（毫秒）。**第四版数字**，端到端集成测试实测（完整走一遍
    /// enhanceClaritySelection 全流程，含 ffmpeg 抽帧/编码，640x480 源素材、
    /// 8 帧、模型预热后的稳态）：x2 ≈ 333ms/帧，x4 ≈ 940ms/帧。
    ///
    /// 四版数字的来历，写下来是为了别再被同一个坑绊倒：
    /// 1. 初版（Task 3 benchmark 推算）：x2 单 tile 1.55ms × 40 tile = 62ms/帧。
    ///    Task 3 用 Python coremltools 测的**纯推理**耗时本身没错，错在直接拿它
    ///    当整帧耗时——漏掉了 Swift 侧读输出、色彩空间转换等步骤。
    /// 2. 第二版（Task 12 首测）：x2 1484ms/帧、x4 5244ms/帧。数字本身是真的，
    ///    但归因错了——当时认为瓶颈是 `mlModel.prediction(from:)` 的固定开销
    ///    （≈130ms/tile），据此判断"需要 batch 推理的架构改动才能解决"。
    /// 3. 第三版：那个归因是错的。单独测裸 `prediction(from:)` 只要 1.5~3ms/tile，
    ///    跟 Task 3 完全吻合；真正的 ≈120ms/tile 花在 `readMultiArrayFast` 读
    ///    模型输出上——FSRCNN 输出的 MLMultiArray 是 float16，而当时那条分支
    ///    误以为"预期不会走到"，用的是逐元素 subscript 装箱的慢路径。改成
    ///    `bindMemory(to: Float16.self)` 后单次读取 122ms → 24ms，端到端
    ///    x2 13.5s → 9.25s、x4 48.6s → 30.4s（8 帧）。不需要 batch 架构改动。
    ///
    /// 4. 本版：把上一版点名的那三个纯 Swift 逐像素循环（rgbToYCbCr、
    ///    upsampleBilinear、yCbCrToRGB，合计占单帧 47%）全部换成 Accelerate 向量化
    ///    实现——前两个用 vDSP 重写（公式系数逐字未变），upsampleBilinear 换
    ///    vImageScale_PlanarF 直接在 float 域重采样，省掉原先
    ///    float→uint8→CGImage→CGContext→uint8→float 一整圈往返。
    ///    实测 x2 9.25s→2.67s、x4 30.4s→7.52s（8 帧），约 3.5~4 倍。
    ///    x4 提升更大是因为旧实现那圈 CGImage 往返的成本随输出像素数平方级增长。
    ///    副作用：色度精度反而提高了（旧实现被 uint8 中转压成 256 阶，实测输出
    ///    只有 154 个不同取值；新实现保留完整 float 精度，65276 个取值）。
    ///    代价是 testEnhanceMatchesPythonReference 的 PSNR 从 52.66→52.43dB——
    ///    这不是画质劣化，是 Cb/Cr 数值变了导致 RGB 打包时量化噪声重新分布
    ///    （该测试只看 Y 通道，而 Y 不经过 upsampleBilinear，纯属间接耦合），
    ///    MAE 差异只有 0.006 个灰阶。
    ///
    /// 上面 333ms/940ms 是 640x480（偏低）分辨率源素材的实测基准值，不能直接
    /// 当成任意分辨率的耗时——Whole-branch review 实测：这两个数字原样套用在
    /// 1080p 素材上会低估约 7 倍（1080p tile 数约 45 个 vs 640x480 只有 6 个，
    /// 差 7.5 倍；色彩空间转换那几步也随像素数增长，合计约 7 倍）——这个倍数
    /// 在第四版向量化之后依然成立，因为向量化是把每一步都按比例加速，没有改变
    /// 各步骤随分辨率增长的关系。这个数字是说给用户听的，往轻里说等于误导用户，
    /// 跟"阈值宁可保守触发"的初衷（那是说给"要不要弹确认框"这个内部判断听的）
    /// 方向正好相反，所以必须按输出分辨率跟 640x480 基准的面积比缩放。
    /// videoWidth 未知时（新建 clip 没探测过尺寸，值为 0）按 1 倍处理，不去猜；
    /// 下限 clamp 到 1，避免源分辨率比 640x480 还小时把预计耗时估得比基准更短
    /// （基准本身已经是所有实测里最快的档位，没必要再往下算）。
    private static func estimatedMsPerFrame(scale: ClarityScale, videoWidth: Double, videoHeight: Double) -> Double {
        let base = scale == .x4 ? 940.0 : 333.0
        guard videoWidth > 0.001, videoHeight > 0.001 else { return base }
        let areaRatio = (videoWidth * videoHeight) / (640.0 * 480.0)
        return base * max(1.0, areaRatio)
    }
    /// 耗时预计超过这个秒数就弹确认框。FSRCNN 实测速度下，绝大多数正常长度（几秒
    /// 以上）的片段都会触发这个提示——这不是异常片段的兜底，是当前实现下的常态，
    /// 提示阈值本身不需要因此调高：处理确实要花这么久，用户应该被提前告知
    private static let confirmThresholdSeconds: Double = 60
    /// 分辨率上限：短边达到这个像素数就提示"已经比较清晰"（x4 用更低阈值，x2 用更高阈值）
    private static func resolutionWarningThreshold(scale: ClarityScale) -> Double {
        scale == .x4 ? 1520 : 2160
    }

    func enhanceClaritySelection(scale: ClarityScale) {
        guard !isEnhancingClarity else { return }
        guard let id = selectedVideoClipID,
              let track = videoTracks.first(where: { $0.clips.contains { $0.id == id } }),
              let clip = track.clips.first(where: { $0.id == id }),
              let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                             title: "清晰度提升", subtitle: "请先选中一个视频片段")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "清晰度提升", subtitle: "源文件不存在", autoCountdown: false)
            return
        }

        let model: ClarityModel = scale == .x2 ? .x2 : .x4
        let trimStart = clip.trimStart
        let duration = clip.duration * clip.speed
        let sourceTrackID = track.id
        let sourceName = url.deletingPathExtension().lastPathComponent
        let estimatedFrameCount = Int(duration * 30.0)  // 固定输出帧率 30fps，跟下面 extractFrames 用的一致

        // 边界检查 1：分辨率已经较高，放大收益有限——提示但不阻止
        let shortSide = min(clip.videoWidth, clip.videoHeight)
        if shortSide > 0.001, shortSide >= Self.resolutionWarningThreshold(scale: scale) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "素材已经比较清晰"
            alert.informativeText = "这个片段短边已有 \(Int(shortSide))px，放大 \(scale.rawValue) 倍收益可能有限。是否仍要继续？"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 边界检查 2：预计耗时较长——需要用户明确确认才继续
        let estimatedSeconds = Double(estimatedFrameCount)
            * Self.estimatedMsPerFrame(scale: scale, videoWidth: clip.videoWidth, videoHeight: clip.videoHeight) / 1000.0
        if estimatedSeconds >= Self.confirmThresholdSeconds {
            let minutes = Int((estimatedSeconds / 60).rounded(.up))
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "预计需要约 \(minutes) 分钟"
            alert.informativeText = "处理期间可以继续编辑其他内容，完成后会有通知。确认开始吗？"
            alert.addButton(withTitle: "开始")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 边界检查 3：磁盘空间不足直接报错，不要写到一半才失败
        let outputWidth = clip.videoWidth * Double(scale.rawValue)
        let outputHeight = clip.videoHeight * Double(scale.rawValue)
        let bytesPerFrame = Self.estimatedBytesPerFrame(outputWidth: outputWidth, outputHeight: outputHeight)
        let estimatedBytes = Int64(estimatedFrameCount) * bytesPerFrame * 2  // ×2 覆盖输入+输出两份帧序列
        if let avail = try? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(avail) < estimatedBytes {
            let gbNeeded = Double(estimatedBytes) / 1_000_000_000
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "清晰度提升",
                             subtitle: String(format: "磁盘空间不足，预计需要约 %.1f GB", gbNeeded),
                             autoCountdown: false)
            return
        }

        clarityEnhanceTask = Task { @MainActor in
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clarity_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workDir) }

            let cancelFlag = ClarityCancelFlag()
            clarityCancelFlag = cancelFlag
            // 本次运行的身份标记。取消检查点在后台线程循环顶部、状态回写在循环底部，
            // 两者之间有窗口：cancelClarityEnhance() 已经把状态设成 .idle 之后，
            // 后台线程可能还会再推一次滞后的 onStateChange，把状态又改回处理中，
            // 气泡就会闪回来；如果用户取消后又立刻重新触发，第一次运行收尾时的
            // 无条件清空还会把第二次运行的 task/flag 句柄清掉，导致第二次运行
            // 完全无法取消。下面所有会修改 clarityEnhanceState/clarityEnhanceTask/
            // clarityCancelFlag 这几个共享状态的地方，一律先确认"我还是当前这次
            // 运行"再动手，不是自己发起的、后来被取代的运行只负责清理自己的
            // workDir（顶部的 defer 已经覆盖，不受这个判断影响）
            func isCurrent() -> Bool { clarityCancelFlag === cancelFlag }

            do {
                if !model.isDownloaded {
                    clarityEnhanceState = .downloadingModel(0)
                    try await model.download { p in
                        Task { @MainActor in
                            guard isCurrent() else { return }
                            self.clarityEnhanceState = .downloadingModel(p)
                        }
                    }
                    try Task.checkCancellation()
                }

                let outDir = Self.clarityOutputDir
                let outName = "\(sourceName)_清晰x\(scale.rawValue)_\(UUID().uuidString.prefix(8)).mp4"
                let outURL = outDir.appendingPathComponent(outName)

                // 抽帧 → 逐帧推理 → 编码整段在专属线程上跑，详见 runClarityEnhancePipeline 的注释：
                // 这几步都是同步阻塞操作，不能用 Task.detached 反复占用 Swift 协作池
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    Thread.detachNewThread {
                        do {
                            _ = try Self.runClarityEnhancePipeline(
                                sourceURL: url, trimStart: trimStart, duration: duration,
                                model: model, workDir: workDir, outputURL: outURL,
                                cancelFlag: cancelFlag,
                                onStateChange: { state in
                                    DispatchQueue.main.async {
                                        guard isCurrent() else { return }
                                        self.clarityEnhanceState = state
                                    }
                                }
                            )
                            cont.resume(returning: ())
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()
                // 已经被取代的旧任务（用户取消后又立刻重新触发）不该再往时间轴里插东西
                guard isCurrent() else { return }

                pushUndoSavingAssets()
                var asset = MediaAsset(url: outURL, name: outName, type: .video)
                asset.importDate = Date()
                // 已知精确时长（跟上面抽帧/编码用的是同一个值），避免素材库把它当未知时长
                // 素材处理，拖到时间轴时给出错误的 30s 占位长度
                asset.duration = duration
                let assetID = asset.id
                mediaAssets.append(asset)

                // 原片段可能在处理这段时间里被用户删除/撤销了 —— 只有还在时才建新轨道插片段
                if videoTracks.first(where: { $0.id == sourceTrackID }) != nil,
                   let stillClip = videoTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                    var newClip = VideoClip(assetID: assetID, startTime: stillClip.startTime,
                                            endTime: stillClip.startTime + stillClip.duration)
                    newClip.trimStart = 0
                    // 新文件是按 clip.duration * clip.speed 秒抽帧/编码出来的（未变速的原始时长），
                    // 新 clip 要占用跟原片段相同的时间轴时长，必须带上同样的 speed 才能让
                    // 播放消耗量（duration * speed）跟新文件的实际时长对上，否则要么截断
                    // （原速度>1 时只播出前半段）要么留空（原速度<1 时后半段没内容）
                    newClip.speed = stillClip.speed
                    let newTrack = Track<VideoClip>(clips: [newClip], label: "清晰度提升")
                    videoTracks.append(newTrack)
                    // 新轨道插到源轨道原来的位置（而不是它后面）：videoSectionOrder 的合成顺序是
                    // 反向遍历、数组里排得靠前的盖在最上层（见 ProjectState+Preview.swift「反序添加
                    // （底层先、顶层后覆盖）」以及 ColorCompositor 里 result = ci.composited(over:
                    // result) 的叠加顺序，数组第 0 位最终显示在最上层）。插在源轨道后面会让新轨道
                    // 排到更底层，被源轨道盖住、用户什么都看不到；插在原位置（源轨道被顶到往后
                    // 一位）新轨道才会盖住源轨道、让用户立刻看到增强画面，源轨道仍保留供随时对比。
                    if let idx = videoSectionOrder.firstIndex(where: { $0.trackID == sourceTrackID }) {
                        videoSectionOrder.insert(.video(newTrack.id), at: idx)
                    } else {
                        videoSectionOrder.append(.video(newTrack.id))
                    }
                    rebuildTimelinePreviewDebounced()
                }

                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
                showSuccessToast(icon: "sparkles", iconColor: .green,
                                 title: "清晰度提升", subtitle: "已生成 \(scale.rawValue)x 高清版本",
                                 revealURL: outURL)
            } catch is CancellationError {
                guard isCurrent() else { return }
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
            } catch ClarityFrameIO.FrameIOError.cancelled {
                guard isCurrent() else { return }
                // 用户点了取消：cancelClarityEnhance() 已经弹过"已停止"提示，这里不再重复弹
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
            } catch {
                guard isCurrent() else { return }
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "清晰度提升", subtitle: error.localizedDescription,
                                 autoCountdown: false)
            }
        }
    }

    /// 抽帧 → 逐帧 CoreML 超分 → 编码，整段同步执行。**调用方必须在专属线程
    /// （`Thread.detachNewThread`）上调用，绝不能直接包在 `Task`/`Task.detached` 里跑**——
    /// 这几步都是同步阻塞操作（ffmpeg 子进程 `waitUntilExit()`、CoreML `MLModel.prediction`
    /// 同步调用），`Task.detached` 不代表脱离协作池，只是不继承调用者的 actor/优先级，依然会
    /// 被派发到 Swift 全局协作线程池执行。逐帧循环几百次反复占用/归还协作池线程，跟本次会话
    /// 验证过的"协作池被同步阻塞调用拖垮"是同一类风险（详见 home_machine_decode_issue.md
    /// 里 `loadWaveform` 从 `Task {}` 改为 `Thread.detachNewThread` 的教训）——虽然这里
    /// 阻塞的是 ffmpeg/CoreML 而不是挂死的 AVFoundation，不会永久卡住，但协作池本来就不该被
    /// 这类长耗时同步任务反复占用。`onStateChange` 在这条专属线程上被调用，内部自己切回主线程。
    nonisolated static func runClarityEnhancePipeline(
        sourceURL: URL, trimStart: Double, duration: Double,
        model: ClarityModel, workDir: URL, outputURL: URL,
        cancelFlag: ClarityCancelFlag,
        onStateChange: @escaping (ClarityEnhanceState) -> Void
    ) throws -> URL {
        func checkCancelled() throws {
            if cancelFlag.isCancelled { throw ClarityFrameIO.FrameIOError.cancelled }
        }

        // 管道式流水线：ffmpeg 解码进程把 rawvideo RGBA 裸字节从 stdout 吐出来，
        // 我们在内存里逐帧超分，再把结果字节写进 ffmpeg 编码进程的 stdin。
        // 相比原先的「解成 PNG 文件序列 → 逐个读写 → 再编码」，省掉了每帧一次
        // PNG 编码（实测 2560x1920 要 29.5ms）+ 一次解码 + 两次磁盘 I/O，
        // 临时磁盘占用也从「300 帧 1080p x4 约 3.7GB」直接降到 0。
        //
        // 死锁防线（这条流水线两端都在阻塞读写，任何一端卡住都是死锁）：
        //  · 两个 ffmpeg 的 stderr 都设成 nullDevice——留给没人排空的管道，写满就卡死
        //  · 读 stdout 用 readExactly 循环补齐：一帧几十 MB 必然被拆成多次 read
        //  · 严格「读满一批 → 处理 → 写出一批」，不会出现两端同时等对方的局面
        onStateChange(.extractingFrames(0))
        let frameRate = 30.0  // 固定输出帧率，跟原素材帧率解耦，简化实现
        let (srcW, srcH) = try ClarityFrameIO.probeVideoSize(sourceURL)
        let scale = model == .x2 ? 2 : 4
        let dstW = srcW * scale, dstH = srcH * scale
        let inFrameBytes = srcW * srcH * 4
        let outFrameBytes = dstW * dstH * 4
        try checkCancelled()

        let (decodeProc, decodeOut) = try ClarityFrameIO.startRawDecode(
            url: sourceURL, trimStart: trimStart, duration: duration, frameRate: frameRate)
        let (encodeProc, encodeIn) = try ClarityFrameIO.startRawEncode(
            width: dstW, height: dstH, frameRate: frameRate,
            audioSourceURL: sourceURL, audioTrimStart: trimStart,
            audioDuration: duration, outputURL: outputURL)

        // 无论正常结束还是抛错，两个进程都要收干净，不能留孤儿卡在管道上
        var finished = false
        defer {
            if !finished {
                try? encodeIn.close()
                ClarityFrameIO.killCurrentProcess()
            }
            ClarityFrameIO.unregister(decodeProc)
            ClarityFrameIO.unregister(encodeProc)
        }

        // 总帧数只能按时长×帧率估——管道没有"总数"这个信息。多估一点不影响正确性，
        // 进度不会倒退，只会在最后一批读不满时直接收尾
        let estimatedTotal = max(1, Int((duration * frameRate).rounded()))
        onStateChange(.inferring(0))

        // 并发度按输出分辨率定：并发 N 帧就是 N 份单帧峰值内存。单帧峰值实测约
        // 48 bytes/输出像素，预算取物理内存 1/8、上限 2GB。640x480 素材吃满 4 并发；
        // 1080p x4（输出 7680x4320）单帧就要 1.6GB，自动退回串行——慢，但不会 OOM，
        // 这个取舍方向不能反。
        let concurrency: Int = {
            let hardCap = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
            let perFrameBytes = Double(dstW) * Double(dstH) * 48
            let budget = min(2_000_000_000.0, Double(ProcessInfo.processInfo.physicalMemory) / 8)
            return max(1, min(hardCap, Int(budget / max(perFrameBytes, 1))))
        }()

        let shared = ClarityParallelState(total: estimatedTotal)
        // 结果槽位也必须放引用类型里：并发闭包直接改外层局部 var 会触发 Swift 的
        // 独占访问检查而 SIGTRAP，加锁也没用（详见 ClarityParallelState 的注释）
        let slots = ClarityFrameSlots(capacity: concurrency)

        while true {
            try checkCancelled()
            if let e = shared.firstError { throw e }

            // 读一批（顺序读，管道本来就是顺序流）
            var batch: [Data] = []
            batch.reserveCapacity(concurrency)
            for _ in 0..<concurrency {
                guard let f = ClarityFrameIO.readExactly(decodeOut, count: inFrameBytes) else { break }
                batch.append(f)
            }
            if batch.isEmpty { break }

            // 批内并发处理
            slots.reset(count: batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                if shared.firstError != nil || cancelFlag.isCancelled { return }
                autoreleasepool {
                    do {
                        let out = try ClarityEnhancer.enhanceRGBA([UInt8](batch[i]),
                                                                  width: srcW, height: srcH,
                                                                  model: model)
                        slots.set(i, Data(out))
                        onStateChange(.inferring(shared.recordCompletedAndProgress()))
                    } catch {
                        shared.record(error)
                    }
                }
            }
            if let e = shared.firstError { throw e }
            try checkCancelled()

            // 按原始顺序写出——批内并发但批间串行，天然保序，不需要乱序重排缓冲
            for i in 0..<batch.count {
                guard let out = slots.get(i), out.count == outFrameBytes else {
                    throw ClarityEnhancer.EnhanceError.badOutput
                }
                try encodeIn.write(contentsOf: out)
            }
        }

        // 让编码进程看到 EOF 才会收尾写完 moov box，漏掉这步产出的 mp4 是坏的
        onStateChange(.encoding)
        try encodeIn.close()
        decodeProc.waitUntilExit()
        encodeProc.waitUntilExit()
        finished = true
        ClarityFrameIO.unregister(decodeProc)
        ClarityFrameIO.unregister(encodeProc)

        if cancelFlag.isCancelled { throw ClarityFrameIO.FrameIOError.cancelled }
        guard encodeProc.terminationStatus == 0 else {
            if encodeProc.terminationReason == .uncaughtSignal {
                throw ClarityFrameIO.FrameIOError.cancelled
            }
            throw ClarityFrameIO.FrameIOError.encodeFailed("ffmpeg 退出码 \(encodeProc.terminationStatus)")
        }
        return outputURL
    }

    static var clarityOutputDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/clarity/output", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 逐帧并发处理时的共享可变状态（完成计数 + 首个错误）。
///
/// 必须是 class：`DispatchQueue.concurrentPerform` 的闭包如果直接捕获并修改外层
/// 函数里的局部 `var`，会触发 Swift 运行时的独占访问检查（exclusivity
/// enforcement）而 SIGTRAP 崩溃——自己加 NSLock 也没用，那套检查不认识锁，它管的
/// 是"同一块内存有没有被并发地独占访问"。把状态挪进引用类型、只通过方法读写，
/// 闭包捕获的就只是一个不可变的引用，检查自然不再触发。锁的写法照抄同文件
/// ClarityCancelFlag。
final class ClarityParallelState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private var _firstError: Error?
    private let total: Int

    init(total: Int) { self.total = max(1, total) }

    /// 记一帧完成，返回当前整体进度（0...1）
    func recordCompletedAndProgress() -> Double {
        lock.lock(); defer { lock.unlock() }
        completed += 1
        return Double(completed) / Double(total)
    }

    /// 只留第一个错误——后面的多半是同一个原因的连锁反应，报第一个更有诊断价值
    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if _firstError == nil { _firstError = error }
    }

    var firstError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _firstError
    }
}

/// 批内并发处理的结果槽位。跟 ClarityParallelState 同理，必须是引用类型：
/// 并发闭包往外层局部数组里写会触发 Swift 运行时的独占访问检查而 SIGTRAP，
/// 哪怕各线程写的是互不相干的下标也一样——那套检查管的是"同一块内存有没有被
/// 并发独占访问"，不认识"我们保证下标不冲突"这种约定。
final class ClarityFrameSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data?]

    init(capacity: Int) { storage = [Data?](repeating: nil, count: max(1, capacity)) }

    func reset(count: Int) {
        lock.lock(); defer { lock.unlock() }
        storage = [Data?](repeating: nil, count: max(1, count))
    }
    func set(_ index: Int, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < storage.count else { return }
        storage[index] = data
    }
    func get(_ index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < storage.count else { return nil }
        return storage[index]
    }
}
