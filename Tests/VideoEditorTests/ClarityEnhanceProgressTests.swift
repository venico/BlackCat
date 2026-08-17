// Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift
import XCTest
@testable import VideoEditorLib

final class ClarityEnhanceProgressTests: XCTestCase {

    func testProgressIsMonotonicAcrossStages() {
        let stages: [ProjectState.ClarityEnhanceState] = [
            .downloadingModel(1.0), .extractingFrames(1.0), .inferring(1.0), .encoding
        ]
        var last = -1.0
        for s in stages {
            XCTAssertGreaterThan(s.approximateProgress, last, "阶段进度应递增：\(s)")
            last = s.approximateProgress
        }
        XCTAssertEqual(ProjectState.ClarityEnhanceState.idle.approximateProgress, 0)
    }

    @MainActor
    func testIsEnhancingReflectsState() {
        let p = ProjectState()
        XCTAssertFalse(p.isEnhancingClarity)
        p.clarityEnhanceState = .extractingFrames(0.5)
        XCTAssertTrue(p.isEnhancingClarity)
        p.clarityEnhanceState = .encoding
        XCTAssertTrue(p.isEnhancingClarity)
        p.clarityEnhanceState = .idle
        XCTAssertFalse(p.isEnhancingClarity)
    }

    @MainActor
    func testCancelResetsState() {
        let p = ProjectState()
        p.clarityEnhanceState = .inferring(0.3)
        p.cancelClarityEnhance()
        XCTAssertFalse(p.isEnhancingClarity, "取消后应复位")
        XCTAssertEqual(p.successToasts.last?.title, "清晰度提升")
        XCTAssertEqual(p.successToasts.last?.subtitle, "已停止")
    }
}

// MARK: - Task 9: canEnhanceClarity

extension ClarityEnhanceProgressTests {

    @MainActor
    func testCanEnhanceClarityRequiresSelection() {
        let p = ProjectState()
        XCTAssertFalse(p.canEnhanceClarity, "没有选中片段时不应该可用")
    }

    @MainActor
    func testCanEnhanceClarityDisabledWhileRunning() {
        let p = ProjectState()
        p.clarityEnhanceState = .inferring(0.5)
        XCTAssertFalse(p.canEnhanceClarity, "任务进行中不应该可以再次触发")
    }
}

// MARK: - Task 9 补充: runClarityEnhancePipeline 端到端集成测试
//
// Task 5(模型下载)/Task 6(CoreML 推理)/Task 8(ffmpeg 抽帧编码) 各自都已经过独立验证，
// 但它们串起来是否真的顺畅衔接（解码进程吐出的 rawvideo 帧字节 → ClarityEnhancer
// 的超分 → 写回编码进程 stdin，三者对宽高/像素格式/字节数的约定必须完全一致）
// 是这一层独有的集成风险，
// 前面几个任务的单测都测不到，这里用 ffmpeg testsrc 生成的短视频跑一遍完整流程验证。

extension ClarityEnhanceProgressTests {

    /// 跟 ClarityFrameIOTests.makeTestVideo() 同样的模式：ffmpeg testsrc/anullsrc
    /// 生成一个不依赖任何外部素材的 2 秒测试视频
    private func makeClarityPipelineTestVideo() throws -> URL {
        guard let ff = ProjectState.findFFmpeg() else { throw XCTSkip("找不到 ffmpeg") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarity_pipeline_src_\(UUID().uuidString).mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=2",
                       "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                       "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                       url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("测试视频生成失败") }
        return url
    }

    func testRunClarityEnhancePipelineEndToEnd() throws {
        // 用 x2（比 x4 输出尺寸小、tile 数少）节省测试时间；模型没下载的机器直接跳过，不阻塞 CI
        try XCTSkipUnless(ClarityModel.x2.isDownloaded, "本机未下载 FSRCNN x2 模型，跳过 pipeline 集成测试")

        let video = try makeClarityPipelineTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarity_pipeline_work_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarity_pipeline_out_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // onStateChange 是在 DispatchQueue.concurrentPerform 的闭包里调的（推理阶段
        // 每帧回调一次），**会从多个线程同时进来**。直接往数组 append 会撞成
        // EXC_BAD_ACCESS —— 实测三次全量里崩过一次，栈就停在 Array.append。
        // 生产侧的调用方一进回调就 DispatchQueue.main.async 派发，所以不受影响，
        // 只有这里图省事直接收集。
        let collector = StateCollector()
        let cancelFlag = ClarityCancelFlag()

        let start = Date()
        let result = try ProjectState.runClarityEnhancePipeline(
            sourceURL: video, trimStart: 0, duration: 2,
            model: .x2, workDir: workDir, outputURL: outputURL,
            cancelFlag: cancelFlag,
            onStateChange: { state in collector.append(state) }
        )
        let elapsed = Date().timeIntervalSince(start)
        let observedStates = collector.snapshot()

        XCTAssertEqual(result, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "应该生成输出视频文件")
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("[TEST] Clarity pipeline end-to-end: elapsed=\(String(format: "%.2f", elapsed))s, "
              + "output size=\(size) bytes, states=\(observedStates.count)")
        XCTAssertGreaterThan(size, 1000, "输出文件应该有实际内容，不是空文件或错误输出")

        // 阶段应该按 extractingFrames -> inferring -> encoding 的顺序推进（各阶段可能连续
        // 出现多次，尤其 inferring 每帧回调一次），不应该出现倒退
        func phaseIndex(_ s: ProjectState.ClarityEnhanceState) -> Int? {
            switch s {
            case .extractingFrames: return 0
            case .inferring:        return 1
            case .encoding:         return 2
            default:                return nil
            }
        }
        let phases = observedStates.compactMap(phaseIndex)
        XCTAssertFalse(observedStates.isEmpty, "onStateChange 应该至少被调用过")
        XCTAssertTrue(phases.contains(0), "应该经过抽帧阶段 extractingFrames")
        XCTAssertTrue(phases.contains(1), "应该经过推理阶段 inferring")
        XCTAssertTrue(phases.contains(2), "应该经过编码阶段 encoding")
        var lastPhase = -1
        for ph in phases {
            XCTAssertGreaterThanOrEqual(ph, lastPhase, "阶段顺序应该是 extractingFrames -> inferring -> encoding，不应倒退")
            lastPhase = ph
        }
    }
}

/// 线程安全的状态收集器：onStateChange 会从 concurrentPerform 的多个线程同时回调
private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ProjectState.ClarityEnhanceState] = []

    func append(_ s: ProjectState.ClarityEnhanceState) {
        lock.lock(); defer { lock.unlock() }
        states.append(s)
    }

    func snapshot() -> [ProjectState.ClarityEnhanceState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }
}
