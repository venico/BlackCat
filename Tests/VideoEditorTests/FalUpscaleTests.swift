// fal.ai 云端超分接入的纯逻辑部分：引擎属性、阶段→进度映射。
// 真实网络调用不在这里测（要 Key、要花钱），只锁住不依赖网络的判断。
import XCTest
@testable import VideoEditorLib

final class FalUpscaleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    // MARK: - 引擎属性

    func testCloudEnginesHaveEndpoints() {
        XCTAssertEqual(AppSettings.ClarityEngine.flashVSR.falEndpoint,
                       "fal-ai/flashvsr/upscale/video")
        XCTAssertEqual(AppSettings.ClarityEngine.seedVR2.falEndpoint,
                       "fal-ai/seedvr/upscale/video")
        // 本地引擎不能有 endpoint，否则会被当成云端跑
        XCTAssertNil(AppSettings.ClarityEngine.system.falEndpoint)
        XCTAssertNil(AppSettings.ClarityEngine.builtIn.falEndpoint)
    }

    func testIsCloudMatchesEndpointPresence() {
        // isCloud 和 falEndpoint 是两处独立判断，必须始终一致——不一致会出现
        // "按云端收 Key 却走本地流水线"这类错位
        for engine in AppSettings.ClarityEngine.allCases {
            XCTAssertEqual(engine.isCloud, engine.falEndpoint != nil,
                           "\(engine.rawValue) 的 isCloud 和 falEndpoint 对不上")
        }
    }

    func testOnlySystemEngineLacksX2() {
        // 只有系统超分锁死 4 倍（VTSuperResolutionScaler 的硬限制），
        // 云端两个的 upscale_factor 都能取 2
        XCTAssertFalse(AppSettings.ClarityEngine.system.supportsX2)
        XCTAssertTrue(AppSettings.ClarityEngine.builtIn.supportsX2)
        XCTAssertTrue(AppSettings.ClarityEngine.flashVSR.supportsX2)
        XCTAssertTrue(AppSettings.ClarityEngine.seedVR2.supportsX2)
    }

    // MARK: - 阶段 → 进度

    func testStageProgressIsMonotonic() {
        // 阶段推进时进度只能涨不能退，否则进度条会往回跳
        let ordered: [FalUpscaleService.Stage] = [
            .uploading(0), .uploading(0.5), .uploading(1),
            .queued(3), .processing,
            .downloading(0), .downloading(0.5), .downloading(1)
        ]
        var last = -1.0
        for stage in ordered {
            let p = stage.overallProgress
            XCTAssertGreaterThanOrEqual(p, last, "\(stage.label) 的进度比上一阶段还小")
            last = p
        }
        XCTAssertEqual(ordered.last!.overallProgress, 1.0, accuracy: 0.0001, "跑完必须到 100%")
    }

    func testStageProgressClampsOutOfRangeInput() {
        // URLSession 的进度回调偶尔会给出越界值，别让进度条冲出 0…1
        XCTAssertEqual(FalUpscaleService.Stage.uploading(-1).overallProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(FalUpscaleService.Stage.uploading(5).overallProgress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(FalUpscaleService.Stage.downloading(9).overallProgress, 1.0, accuracy: 0.0001)
    }

    func testQueuedLabelShowsPositionOnlyWhenKnown() {
        XCTAssertEqual(FalUpscaleService.Stage.queued(5).label, "排队中（第 5 位）")
        // fal 有时不给 queue_position，这时候不能显示"第 0 位"
        XCTAssertEqual(FalUpscaleService.Stage.queued(0).label, "排队中")
    }

    // MARK: - 状态机接线

    func testCloudStateCarriesProgressAndStage() {
        let state = ProjectState.ClarityEnhanceState.cloud(progress: 0.42, stage: "云端处理中")
        XCTAssertEqual(state.approximateProgress, 0.42, accuracy: 0.0001,
                       "云端进度要原样透出，不能再套一层本地阶段的换算")
        XCTAssertEqual(state.cloudStage, "云端处理中")
    }

    func testLocalStatesHaveNoCloudStage() {
        // 本地阶段不能返回 cloudStage，否则进度卡片会把 ETA 挤掉
        XCTAssertNil(ProjectState.ClarityEnhanceState.inferring(0.5).cloudStage)
        XCTAssertNil(ProjectState.ClarityEnhanceState.encoding.cloudStage)
        XCTAssertNil(ProjectState.ClarityEnhanceState.idle.cloudStage)
    }
}
