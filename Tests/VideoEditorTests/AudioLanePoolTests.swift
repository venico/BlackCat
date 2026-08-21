import XCTest
@testable import VideoEditorLib

/// composition 音轨复用池的分配逻辑（对应 ProjectState+Preview 里 audioLanePool
/// 那段）。这里复现同一套规则来验证分配结果，重点是"绝不把时间重叠的片段塞进
/// 同一条 track"——真那样会让后插入的覆盖掉前一段，直接静音。
final class AudioLanePoolTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private struct Seg { let start: Double; let end: Double; let key: String? }

    /// 返回每个片段落到的 lane 编号；nil key（有 fade）一律独占一条
    private func assign(_ segs: [Seg]) -> [Int] {
        var pool: [String: [(lane: Int, endTime: Double)]] = [:]
        var laneCount = 0
        var result: [Int] = []
        for s in segs {
            if let k = s.key,
               let idx = pool[k]?.firstIndex(where: { $0.endTime <= s.start + 0.0001 }) {
                result.append(pool[k]![idx].lane)
                pool[k]![idx].endTime = s.end
            } else {
                let lane = laneCount; laneCount += 1
                result.append(lane)
                if let k = s.key { pool[k, default: []].append((lane, s.end)) }
            }
        }
        return result
    }

    /// TTS 的典型形态：几十条互不重叠、参数相同的配音 —— 应该全部挤进 1 条 track
    func testNonOverlappingSameParamsCollapseToOneLane() {
        let segs = (0..<50).map { Seg(start: Double($0) * 2, end: Double($0) * 2 + 1.8, key: "v1-l1-r1") }
        let lanes = assign(segs)
        XCTAssertEqual(Set(lanes).count, 1, "50 条不重叠的同参数配音应该只占 1 条 composition track，实际 \(Set(lanes).count) 条")
    }

    /// 重叠的必须分开，否则后插入的会覆盖前一段
    func testOverlappingSegmentsGetSeparateLanes() {
        let segs = [Seg(start: 0, end: 10, key: "v1-l1-r1"),
                    Seg(start: 5, end: 15, key: "v1-l1-r1")]   // 与上一条重叠
        XCTAssertEqual(Set(assign(segs)).count, 2, "重叠片段必须各占一条 track")
    }

    /// 首尾相接（前一条正好结束时后一条开始）算不重叠，可以复用
    func testAdjacentSegmentsShareLane() {
        let segs = [Seg(start: 0, end: 5, key: "v1-l1-r1"),
                    Seg(start: 5, end: 10, key: "v1-l1-r1")]
        XCTAssertEqual(Set(assign(segs)).count, 1, "首尾相接应可复用同一条 track")
    }

    /// 参数不同不能复用——音量是按整条 track 设的，混用会串味
    func testDifferentParamsNeverShareLane() {
        let segs = [Seg(start: 0, end: 5, key: "v1-l1-r1"),
                    Seg(start: 6, end: 10, key: "v0.5-l1-r1")]  // 音量不同
        XCTAssertEqual(Set(assign(segs)).count, 2, "音量不同必须分开，否则整条 track 只能有一个音量")
    }

    /// 带淡入淡出的（key=nil）一律独占，避免多段 ramp 互相打架
    func testFadeClipsAlwaysGetOwnLane() {
        let segs = [Seg(start: 0, end: 5, key: nil),
                    Seg(start: 6, end: 10, key: nil),
                    Seg(start: 11, end: 15, key: nil)]
        XCTAssertEqual(Set(assign(segs)).count, 3, "带 fade 的片段必须各自独占一条 track")
    }

    /// 混合场景：无 fade 的合并、有 fade 的独占，互不干扰
    func testMixedFadeAndPlainSegments() {
        let segs = [Seg(start: 0, end: 5, key: "v1-l1-r1"),
                    Seg(start: 6, end: 10, key: nil),          // 有 fade
                    Seg(start: 11, end: 15, key: "v1-l1-r1"),  // 应复用第 0 条
                    Seg(start: 16, end: 20, key: "v1-l1-r1")]  // 也复用第 0 条
        let lanes = assign(segs)
        XCTAssertEqual(lanes[0], lanes[2])
        XCTAssertEqual(lanes[0], lanes[3])
        XCTAssertNotEqual(lanes[0], lanes[1])
        XCTAssertEqual(Set(lanes).count, 2, "应该是 1 条合并轨 + 1 条 fade 独占轨")
    }
}
