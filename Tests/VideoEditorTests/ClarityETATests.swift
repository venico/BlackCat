import XCTest
@testable import VideoEditorLib

final class ClarityETATests: XCTestCase {

    /// 前 3% 不该给出实测 ETA——样本太少，除出来的数会乱跳
    @MainActor
    func testETANotOverwrittenTooEarly() {
        let p = ProjectState()
        p.clarityETASeconds = 600            // 开工前的静态预估
        p.updateClarityETA(for: .inferring(0.01))
        XCTAssertEqual(p.clarityETASeconds, 600, "进度不足 3% 时应保留开工前的预估值")
    }

    /// 跑起来之后按实际速度推算：已用 t、进度 p ⇒ 剩余 ≈ t/p × (1-p)
    @MainActor
    func testETAUsesMeasuredSpeed() {
        let p = ProjectState()
        p.updateClarityETA(for: .inferring(0.01))       // 只为了打上开始时间戳
        p.clarityInferStartTime = Date().addingTimeInterval(-10)  // 假装已跑 10 秒
        p.updateClarityETA(for: .inferring(0.25))       // 完成 25%
        // 10 秒跑了 25% ⇒ 总共约 40 秒 ⇒ 还剩约 30 秒
        let eta = try? XCTUnwrap(p.clarityETASeconds)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta ?? 0, 30, accuracy: 1.5, "应按实测速度推算剩余时间")
    }

    /// 进度推进时 ETA 要跟着收敛，不能越跑越多
    @MainActor
    func testETAShrinksAsProgressAdvances() {
        let p = ProjectState()
        p.updateClarityETA(for: .inferring(0.01))
        p.clarityInferStartTime = Date().addingTimeInterval(-10)
        p.updateClarityETA(for: .inferring(0.25))
        let early = p.clarityETASeconds ?? 0
        p.clarityInferStartTime = Date().addingTimeInterval(-30)
        p.updateClarityETA(for: .inferring(0.90))
        let late = p.clarityETASeconds ?? 0
        XCTAssertLessThan(late, early, "进度推进后剩余时间应变少")
    }

    /// 编码阶段和收尾要把倒计时清掉，不能停在一个永远不变的数上
    @MainActor
    func testETAClearedOnEncodingAndIdle() {
        let p = ProjectState()
        p.clarityETASeconds = 120
        p.updateClarityETA(for: .encoding)
        XCTAssertNil(p.clarityETASeconds, "编码阶段应清空倒计时")

        p.clarityETASeconds = 120
        p.clarityInferStartTime = Date()
        p.updateClarityETA(for: .idle)
        XCTAssertNil(p.clarityETASeconds)
        XCTAssertNil(p.clarityInferStartTime, "回到 idle 要把开始时间也清掉，否则下一次运行会用上一次的时间戳")
    }

    /// 取消后必须清干净——否则下次启动会先闪一下上次的残留数字
    @MainActor
    func testCancelClearsETA() {
        let p = ProjectState()
        p.clarityEnhanceState = .inferring(0.4)
        p.clarityETASeconds = 300
        p.clarityInferStartTime = Date()
        p.cancelClarityEnhance()
        XCTAssertNil(p.clarityETASeconds)
        XCTAssertNil(p.clarityInferStartTime)
    }
}
