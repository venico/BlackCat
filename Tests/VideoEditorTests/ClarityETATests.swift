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

// MARK: - 进度条真实性

final class ClarityProgressRealismTests: XCTestCase {

    /// 推理一开始不该已经是 20%——管道式下推理就是全部工作量，
    /// 前面那些阶段（下载 20KB 模型、启动进程）都是一瞬间的事
    func testProgressStartsNearZeroWhenInferenceBegins() {
        let p = ProjectState.ClarityEnhanceState.inferring(0).approximateProgress
        XCTAssertLessThan(p, 0.05, "推理刚开始时进度应接近 0，实际 \(p)")
    }

    /// 推理占的区间要跟它的真实耗时占比匹配（99% 的时间都在这个阶段）
    func testInferenceOwnsMostOfTheBar() {
        let lo = ProjectState.ClarityEnhanceState.inferring(0).approximateProgress
        let hi = ProjectState.ClarityEnhanceState.inferring(1).approximateProgress
        XCTAssertGreaterThan(hi - lo, 0.9, "推理阶段应占进度条 90% 以上，实际 \((hi-lo)*100)%")
    }

    /// 推理进度要线性映射，不能中间加速或减速
    func testInferenceProgressIsLinear() {
        let a = ProjectState.ClarityEnhanceState.inferring(0.25).approximateProgress
        let b = ProjectState.ClarityEnhanceState.inferring(0.50).approximateProgress
        let c = ProjectState.ClarityEnhanceState.inferring(0.75).approximateProgress
        XCTAssertEqual(b - a, c - b, accuracy: 0.0001, "等量进度应对应等量进度条推进")
    }

    /// 全程不能倒退，也不能超过 100%
    func testProgressNeverExceedsOneOrGoesBackwards() {
        var last = -1.0
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = ProjectState.ClarityEnhanceState.inferring(p).approximateProgress
            XCTAssertGreaterThanOrEqual(v, last)
            XCTAssertLessThanOrEqual(v, 1.0)
            last = v
        }
        let enc = ProjectState.ClarityEnhanceState.encoding.approximateProgress
        XCTAssertGreaterThanOrEqual(enc, last, "收尾阶段不能比推理结束时还低")
        XCTAssertLessThanOrEqual(enc, 1.0)
    }

    /// 分母是估算的帧数，实际多出一两帧时不能让进度冲破 100%
    func testProgressClampedWhenActualFramesExceedEstimate() {
        let s = ClarityParallelState(total: 10)
        var lastP = 0.0
        for _ in 0..<15 { lastP = s.recordCompletedAndProgress() }   // 跑 15 帧但只估了 10 帧
        XCTAssertLessThanOrEqual(lastP, 1.0, "实际帧数超出估算时进度必须 clamp 在 1.0")
    }
}
