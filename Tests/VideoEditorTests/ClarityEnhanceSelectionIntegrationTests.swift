// Tests/VideoEditorTests/ClarityEnhanceSelectionIntegrationTests.swift
// Task 12 端到端集成测试：不经过 UI 点击，直接调用时间轴右键菜单实际会调用的
// 同一个函数 ProjectState.enhanceClaritySelection(scale:)，验证真实数据流：
// 导入素材 -> 落轨 -> 选中 -> 触发放大 -> 素材库/时间轴的产出是否正确 -> 用 ffprobe
// 校验输出文件的真实分辨率确实是原分辨率的 N 倍——这是"画面确实更清晰"这个本该
// 靠肉眼判断的验收点，在没有桌面访问权限时能做到的最接近的客观等价物。
// 另外验证取消功能：进程真的被杀、状态复位、临时工作目录没有残留。
//
// 跟 Task 9 的 ClarityEnhanceProgressTests.testRunClarityEnhancePipelineEndToEnd 的分工：
// 那边测的是 runClarityEnhancePipeline 这个静态函数本身的抽帧->推理->编码链路；
// 这里测的是外面一层——enhanceClaritySelection 的边界检查、素材/轨道/z-order 的
// 建立与善后、以及 cancelClarityEnhance 的清理是否干净，这些只有走完整
// ProjectState 实例方法才会触发，静态 pipeline 测试测不到。
//
// 测试素材参数（640x480、约 8 帧）比 brief 原本设想的"3~5 秒"小得多，这不是
// 图省事：Task 12 验证过程中实测发现 ClarityEnhancer.enhance() 真实单帧耗时
// 远超 Task 3 文档记录的数字（640x480 基准 x2 ≈1.16s/帧、x4 ≈3.80s/帧，而不是
// 文档里的 1.55ms/1.58ms 单 tile），照 brief 建议的 3~5 秒（90~150 帧）跑一遍 x4 会
// 需要 8~13 分钟，对一个要反复跑、还要在 CI 里跑的集成测试不现实。8 帧已经
// 足够触发这个测试真正要验证的东西（真实 ffmpeg 抽帧/编码、真实多 tile
// CoreML 推理与拼接、真实素材/轨道/z-order 落地、真实取消清理），更长的素材
// 只是把同样的循环多跑几次，不会验证到质变的新逻辑。详见
// ProjectState+ClarityEnhance.swift 里 estimatedMsPerFrame 的注释和
// Task 12 报告。
import XCTest
import Foundation
@testable import VideoEditorLib

@MainActor
final class ClarityEnhanceSelectionIntegrationTests: XCTestCase {

    /// 测试素材固定用这个时长：Int(0.28 * 30) = 8 帧，远离取整边界（不用 0.3
    /// 这种可能因为浮点误差落在 8/9 帧边界两侧的数字）。按实测最新的
    /// estimatedMsPerFrame 640x480 基准值（x2 333ms/帧、x4 940ms/帧）算，
    /// 8 帧 x4 预计约 30 秒、x2 约 9 秒，都在 60 秒确认框阈值以内，不会弹出
    /// 没人能点的 NSAlert.runModal() 模态框。这里的 VideoClip 没有设置
    /// videoWidth/videoHeight（保持默认值 0），estimatedMsPerFrame 按分辨率
    /// 缩放耗时估算时会因此回退到不缩放的 640x480 基准值，上面这两个数字就是
    /// 实际生效的值，不用换算
    private nonisolated static let testClipSeconds = 0.28

    // MARK: - 测试素材构造

    /// 生成一个不依赖任何外部素材的低清测试视频（testsrc + anullsrc），跟
    /// ClarityFrameIOTests.makeTestVideo() / ClarityEnhanceProgressTests 里
    /// makeClarityPipelineTestVideo() 同样的模式。默认 640x480——短边 480px，
    /// 远低于 resolutionWarningThreshold（x2 用 2160，x4 用 1520），不会弹
    /// "素材已经比较清晰"的确认框。这两个 NSAlert.runModal() 都是同步阻塞的
    /// 模态框，这个测试环境没有人去点，一旦弹出来测试就会永久卡死——分辨率和
    /// 时长这两个参数不是随便选的，必须双双绕开（时长安全边界见
    /// testClipSeconds 的注释）。
    private func makeLowResTestVideo(width: Int = 640, height: Int = 480,
                                      seconds: Double = ClarityEnhanceSelectionIntegrationTests.testClipSeconds,
                                      suffix: String = "") throws -> URL {
        guard let ff = ProjectState.findFFmpeg() else { throw XCTSkip("找不到 ffmpeg") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarity_selection_src_\(suffix)_\(UUID().uuidString).mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=\(width)x\(height):rate=10:duration=\(seconds)",
                       "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                       "-t", "\(seconds)", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                       url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("测试视频生成失败") }
        return url
    }

    /// ffprobe 读取视频真实的宽高——校验"分辨率确实翻了 N 倍"要用真实解码结果，
    /// 不能用 clip/asset 里缓存的元数据字段（这个测试压根没去设置那些字段）
    private func probeResolution(_ url: URL) -> (width: Int, height: Int)? {
        guard let ff = ProjectState.findFFmpeg() else { return nil }
        let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let p = Process()
        p.executableURL = probe
        p.arguments = ["-v", "error", "-select_streams", "v:0",
                       "-show_entries", "stream=width,height", "-of", "csv=p=0", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = str.split(separator: ",")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    /// 把测试视频当成真实素材导入 + 落到时间轴一条视频轨。
    ///
    /// 刻意不复用 ProjectState.addToTimeline(_:)：它的视频分支里有一段用
    /// AVURLAsset(url:).load(.duration) / .loadTracks(...) 异步补时长/尺寸的
    /// 裸 Task，直接 await AVFoundation，没有本项目其它地方统一用的
    /// Thread.detachNewThread + 超时兜底（详见 home_machine_decode_issue.md、
    /// ClarityFrameIO.swift 顶部注释——清晰度提升这个功能本身就是因为不信任
    /// AVFoundation 才全程改用 ffmpeg 的）。测试不应该让通过与否依赖一个没有
    /// 超时保护的 AVFoundation 调用会不会在这台机器上卡住，所以改成手动构造
    /// VideoClip 直接落 videoTracks，再调用真实的 syncVideoSectionOrder() 维护
    /// 顺序表——字段跟 addToTimeline 视频分支里创建 clip 那几行完全一致
    /// （assetID/url/startTime/endTime），只是跳过它那段有风险的异步尾巴；这里
    /// 这些字段全部是测试预先设好的已知值，不需要靠异步补全。素材导入本身仍然
    /// 用生产代码的 importFileDirectly，没有另起一套导入方式。
    private func importAndPlaceOnTimeline(_ project: ProjectState, url: URL, duration: Double) throws -> (trackID: UUID, clipID: UUID) {
        project.importFileDirectly(url: url, type: .video)
        guard let assetIdx = project.mediaAssets.firstIndex(where: { $0.url == url }) else {
            throw XCTSkip("素材导入失败：mediaAssets 里找不到对应 URL")
        }
        project.mediaAssets[assetIdx].duration = duration
        let asset = project.mediaAssets[assetIdx]

        let clip = VideoClip(assetID: asset.id, name: asset.name, url: asset.url,
                              startTime: 0, endTime: duration)
        let track = Track<VideoClip>(clips: [clip], label: "视频")
        project.videoTracks.append(track)
        project.syncVideoSectionOrder()
        return (track.id, clip.id)
    }

    /// 轮询等到状态不再是 idle（即 enhanceClaritySelection 内部的 Task 真的已经
    /// 开始跑），用于取消测试里精确判断"处理中"这个时间点——比固定 sleep 一个
    /// 数再取消更不容易因为环境快慢而抖动
    private func waitUntilEnhancingStarted(_ project: ProjectState, timeoutSeconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if project.isEnhancingClarity { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
        return false
    }

    /// 扫描系统临时目录下所有 clarity_* 工作目录（enhanceClaritySelection 里
    /// workDir 的命名规则是 clarity_<uuid>），用差集而不是"数量应为 0"来判断
    /// 有没有新增残留——这台机器上可能因为之前手动测试留过其它 clarity_* 目录，
    /// 跟本次触发的这一个不是一回事，不该被这个断言误伤
    private func clarityWorkDirNames() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return [] }
        return Set(items.map(\.lastPathComponent).filter { $0.hasPrefix("clarity_") })
    }

    // MARK: - x2 / x4 端到端

    private func runFullEnhanceAndVerify(scale: ProjectState.ClarityScale, multiplier: Int) async throws {
        try XCTSkipUnless(ClarityModel.x2.isDownloaded && ClarityModel.x4.isDownloaded,
                           "本机 FSRCNN 模型未下载全，跳过端到端测试")

        // 这个测试验的是 FSRCNN 那条流水线，必须把引擎钉死在随包模型上。
        // 不钉的话它会跟着开发者本机的设置走：选了系统超分就强制 4 倍（x2 用例
        // 于是拿到 4 倍输出而失败），选了云端还会真的发起付费请求
        let savedEngine = AppSettings.shared.clarityEngine
        AppSettings.shared.clarityEngine = .builtIn
        defer { AppSettings.shared.clarityEngine = savedEngine }

        let srcW = 640, srcH = 480
        let srcSeconds = Self.testClipSeconds
        let video = try makeLowResTestVideo(width: srcW, height: srcH, seconds: srcSeconds,
                                             suffix: "x\(multiplier)")
        defer { try? FileManager.default.removeItem(at: video) }

        let project = ProjectState()
        let (sourceTrackID, clipID) = try importAndPlaceOnTimeline(project, url: video, duration: srcSeconds)
        project.selectedVideoClipID = clipID

        let assetCountBefore = project.mediaAssets.count
        let trackCountBefore = project.videoTracks.count
        let sourceIdxBefore = project.videoSectionOrder.firstIndex(where: { $0.trackID == sourceTrackID })
        XCTAssertNotNil(sourceIdxBefore, "落轨后源轨道应该已经在 videoSectionOrder 里")

        XCTAssertTrue(project.canEnhanceClarity, "满足条件时右键菜单项应该可用")

        let t0 = Date()
        project.enhanceClaritySelection(scale: scale)
        guard let task = project.clarityEnhanceTask else {
            XCTFail("enhanceClaritySelection 没有创建后台任务——多半是前置 guard 提前返回了（比如源文件校验失败）")
            return
        }
        await task.value
        print("[TEST] scale=x\(multiplier) 全流程耗时 \(Date().timeIntervalSince(t0))s（\(Int(srcSeconds * 30)) 帧）")

        // 1. mediaAssets 确实多了一个新素材
        XCTAssertEqual(project.mediaAssets.count, assetCountBefore + 1, "应该新增一个素材")
        let newAsset = try XCTUnwrap(project.mediaAssets.last, "新素材应该在数组末尾")
        XCTAssertEqual(newAsset.type, .video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAsset.url.path), "新素材文件应该真实存在")
        defer { try? FileManager.default.removeItem(at: newAsset.url) }

        // 2. videoTracks 确实多了一条新轨道，新片段 startTime/duration 跟原片段一致
        XCTAssertEqual(project.videoTracks.count, trackCountBefore + 1, "应该新增一条视频轨道")
        let newTrack = try XCTUnwrap(project.videoTracks.last, "新轨道应该在数组末尾（append 的）")
        XCTAssertEqual(newTrack.label, "清晰度提升")
        XCTAssertEqual(newTrack.clips.count, 1, "新轨道应该只有一个片段")
        let newClip = try XCTUnwrap(newTrack.clips.first)
        XCTAssertEqual(newClip.startTime, 0, accuracy: 0.001, "新片段起点应跟原片段一致")
        XCTAssertEqual(newClip.duration, srcSeconds, accuracy: 0.001, "新片段时长应跟原片段一致")

        // 2b. 像素尺寸必须填上，否则预览区选中这个片段时画不出裁剪框
        // （PlayerView.computeVideoRect 头一行 `guard natW > 0, natH > 0`）。
        // 这条路径不走正常落轨那套异步探测 naturalSize 的逻辑，得自己填
        XCTAssertEqual(newClip.videoWidth, Double(srcW * multiplier), accuracy: 1,
                       "新片段的像素宽应是源的 \(multiplier) 倍，否则裁剪框画不出来")
        XCTAssertEqual(newClip.videoHeight, Double(srcH * multiplier), accuracy: 1,
                       "新片段的像素高应是源的 \(multiplier) 倍")

        // 3. 用 ffprobe 检查生成的输出视频文件的真实分辨率，确认宽高确实是原始
        // 测试视频分辨率的 N 倍——这是"画面确实更清晰"这个主观验证要求在这里能
        // 做到的最接近的客观等价物：分辨率提升了，且走的是真实 FSRCNN 推理管线
        // （包含多 tile 拼接，640x480 > tileSize 256，会触发真实的多 tile 路径）
        let res = try XCTUnwrap(probeResolution(newAsset.url), "ffprobe 应该能读出输出视频的分辨率")
        print("[TEST] scale=x\(multiplier) 输出分辨率实测 = \(res.width)x\(res.height)，"
              + "源分辨率 = \(srcW)x\(srcH)，期望 = \(srcW * multiplier)x\(srcH * multiplier)")
        XCTAssertEqual(res.width, srcW * multiplier, "宽度应该是源分辨率的 \(multiplier) 倍")
        XCTAssertEqual(res.height, srcH * multiplier, "高度应该是源分辨率的 \(multiplier) 倍")

        // 4. z-order：新轨道插入到源轨道原来的位置，源轨道被推到后面一位
        //    （Task 9 修复过的逻辑：数组下标越小越靠上层，插在源轨道后面会被源
        //    轨道盖住看不见）
        let newIdx = project.videoSectionOrder.firstIndex(where: { $0.trackID == newTrack.id })
        let sourceIdxAfter = project.videoSectionOrder.firstIndex(where: { $0.trackID == sourceTrackID })
        let newIdxU = try XCTUnwrap(newIdx, "新轨道应该出现在 videoSectionOrder 里")
        let sourceIdxAfterU = try XCTUnwrap(sourceIdxAfter, "源轨道应该仍然在 videoSectionOrder 里")
        XCTAssertLessThan(newIdxU, sourceIdxAfterU, "新轨道下标应该小于源轨道下标（盖在源轨道上面）")
        XCTAssertEqual(newIdxU, sourceIdxBefore, "新轨道应该正好插在源轨道原来的位置")
        XCTAssertEqual(sourceIdxAfterU, newIdxU + 1, "源轨道应该正好被挤到新轨道后面一位")

        // 5. 状态收尾正常
        XCTAssertFalse(project.isEnhancingClarity)
        XCTAssertEqual(project.clarityEnhanceState, .idle)
        XCTAssertNil(project.clarityCancelFlag)
    }

    func testEnhanceX2() async throws {
        try await runFullEnhanceAndVerify(scale: .x2, multiplier: 2)
    }

    func testEnhanceX4() async throws {
        try await runFullEnhanceAndVerify(scale: .x4, multiplier: 4)
    }

    // MARK: - 取消

    func testCancelKillsProcessAndCleansWorkDir() async throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "本机未下载 FSRCNN x4 模型，跳过取消测试")

        // 选 x4（单帧耗时比 x2 更长，640x480 基准约 3.8 秒/帧），即使只有 8 帧，
        // 自然跑完也要 ~30 秒，取消轮询在毫秒级就该命中，中途打断的窗口非常
        // 充裕，不会出现"轮询检测到已开始之前，流程已经跑完"这种测不出东西的情况
        let video = try makeLowResTestVideo(width: 640, height: 480, suffix: "cancel")
        defer { try? FileManager.default.removeItem(at: video) }

        let project = ProjectState()
        let (_, clipID) = try importAndPlaceOnTimeline(project, url: video, duration: Self.testClipSeconds)
        project.selectedVideoClipID = clipID

        let workDirsBefore = clarityWorkDirNames()
        let assetCountBefore = project.mediaAssets.count

        project.enhanceClaritySelection(scale: .x4)
        guard let task = project.clarityEnhanceTask else {
            XCTFail("enhanceClaritySelection 没有创建后台任务")
            return
        }

        let started = await waitUntilEnhancingStarted(project)
        XCTAssertTrue(started, "5 秒内应该能观察到状态从 idle 变为处理中")

        project.cancelClarityEnhance()
        await task.value  // 等后台线程真正收尾（defer 清理 workDir 就在这条路径里跑）

        // 1. isEnhancingClarity 复位
        XCTAssertFalse(project.isEnhancingClarity, "取消后应该复位")
        XCTAssertEqual(project.clarityEnhanceState, .idle)

        // 2. 没有残留的 ffmpeg 进程还在跑（ClarityFrameIO 自己维护的当前进程句柄，
        //    比 shell 出去 ps aux | grep ffmpeg 更精确，不会被系统上其它无关的
        //    ffmpeg 进程误伤）
        XCTAssertNil(ClarityFrameIO.currentProcess, "取消后不应该还有 ffmpeg 进程句柄")

        // 3. 没有生成新素材——证明是真的被中途打断，而不是恰好跑完了才"取消"
        XCTAssertEqual(project.mediaAssets.count, assetCountBefore, "取消应该真的打断流程，不应该仍然生成新素材")

        // 4. 临时工作目录没有残留
        let workDirsAfter = clarityWorkDirNames()
        let leaked = workDirsAfter.subtracting(workDirsBefore)
        XCTAssertTrue(leaked.isEmpty, "取消后不应该有残留的 clarity_* 工作目录，实际残留：\(leaked)")
    }
}
