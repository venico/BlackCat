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
        p.clarityEnhanceState = .failed("测试错误")
        XCTAssertFalse(p.isEnhancingClarity, "失败态不应算作进行中")
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
