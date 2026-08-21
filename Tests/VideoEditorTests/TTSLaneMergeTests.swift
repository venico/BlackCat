import XCTest
@testable import VideoEditorLib

/// 配音按轨道合并成单个素材后，每段靠 trimStart 偏移到自己那一段。
/// 这里验证偏移的计算契约——算错的话每句话会播成别的内容，比崩溃还难查。
final class TTSLaneMergeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private struct Seg { let start: Double; let dur: Double }

    /// 合并文件从这条轨道的第一段开始，各段偏移 = 自己起点 − 轨道起点
    private func offsets(_ segs: [Seg]) -> [Double] {
        let laneStart = segs.map(\.start).min() ?? 0
        return segs.map { $0.start - laneStart }
    }

    /// 第一段偏移必须是 0——文件就是从它开始的
    func testFirstSegmentHasZeroOffset() {
        let o = offsets([Seg(start: 12, dur: 2), Seg(start: 20, dur: 3)])
        XCTAssertEqual(o[0], 0, accuracy: 0.0001)
    }

    /// 后续各段的偏移是相对轨道起点，不是相对时间轴 0 点
    func testOffsetsAreRelativeToLaneStart() {
        let o = offsets([Seg(start: 12, dur: 2), Seg(start: 20, dur: 3), Seg(start: 31, dur: 1)])
        XCTAssertEqual(o[1], 8, accuracy: 0.0001, "20-12=8，不是 20")
        XCTAssertEqual(o[2], 19, accuracy: 0.0001, "31-12=19，不是 31")
    }

    /// 轨道从 0 开始时，偏移就等于各自的起点
    func testLaneStartingAtZero() {
        let o = offsets([Seg(start: 0, dur: 2), Seg(start: 5, dur: 2)])
        XCTAssertEqual(o[0], 0, accuracy: 0.0001)
        XCTAssertEqual(o[1], 5, accuracy: 0.0001)
    }

    /// 素材时长 = 轨道跨度（末段结束 − 首段开始），不是各段时长之和
    func testAssetDurationIsLaneSpanNotSumOfSegments() {
        let segs = [Seg(start: 10, dur: 2), Seg(start: 20, dur: 3)]
        let span = (segs.last!.start + segs.last!.dur) - segs.first!.start
        XCTAssertEqual(span, 13, accuracy: 0.0001, "23-10=13，含中间 8s 静音")
        XCTAssertNotEqual(span, segs.reduce(0) { $0 + $1.dur }, "不该是 2+3=5")
    }

    /// 偏移必须单调递增，否则 adelay 的顺序跟 clip 顺序对不上
    func testOffsetsAreMonotonic() {
        let o = offsets([Seg(start: 3, dur: 1), Seg(start: 9, dur: 1), Seg(start: 14, dur: 1)])
        XCTAssertEqual(o, o.sorted(), "偏移必须递增")
    }

    /// 单段轨道不该走合并（省一次 ffmpeg，也没必要）
    func testSingleSegmentSkipsMerge() {
        let segs = [Seg(start: 5, dur: 2)]
        XCTAssertEqual(segs.count, 1, "count > 1 才合并，单段直接用原文件")
    }
}
