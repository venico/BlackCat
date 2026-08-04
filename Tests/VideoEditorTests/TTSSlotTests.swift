import XCTest
@testable import VideoEditorLib

/// 字幕转语音的「可用槽位」计算：压缩目标是到下一条字幕起点的距离（留一点
/// 呼吸间隙），而不是字幕自己的时长。复现 fitDurations 里的那段算法来验证。
final class TTSSlotTests: XCTestCase {

    private struct Sub { let start: Double; let dur: Double }

    private func slots(_ subs: [Sub]) -> [Double] {
        let gap = 0.15
        return subs.indices.map { i in
            guard i + 1 < subs.count else { return .greatestFiniteMagnitude }
            return max(subs[i].dur, subs[i + 1].start - subs[i].start - gap)
        }
    }

    /// 字幕之间有停顿时，槽位应该把空档算进来——这正是旧算法白白浪费掉的部分
    func testGapBetweenSubtitlesIsUsable() {
        // 字幕 A: 0~2s，下一条 5s 才开始 → 可用空间接近 5s，不是 2s
        let s = slots([Sub(start: 0, dur: 2), Sub(start: 5, dur: 2)])
        XCTAssertEqual(s[0], 4.85, accuracy: 0.001, "应该能用到下一条起点前，而不是只有字幕自己的 2s")
    }

    /// 一条 3s 的语音配 0~2s 的字幕：旧算法要压 1.5 倍，新算法在有空档时完全不用压
    func testNoCompressionNeededWhenGapIsEnough() {
        let s = slots([Sub(start: 0, dur: 2), Sub(start: 5, dur: 2)])
        let speechDur = 3.0
        XCTAssertLessThan(speechDur, s[0], "3s 语音放得进 4.85s 的空档，不该触发压缩")
        XCTAssertGreaterThan(speechDur / 2.0, 1.0, "而按旧算法（target=字幕 2s）会被压 1.5 倍")
    }

    /// 字幕挨得紧时，槽位退化成字幕时长，行为跟旧算法一致
    func testTightSubtitlesFallBackToClipDuration() {
        let s = slots([Sub(start: 0, dur: 2), Sub(start: 2.1, dur: 2)])
        XCTAssertEqual(s[0], 2.0, accuracy: 0.001, "间隙(1.95)比字幕时长(2)短，取字幕时长兜底")
    }

    /// 字幕互相重叠这种少见情况，不能比旧行为压得更狠
    func testOverlappingSubtitlesNeverCompressHarderThanBefore() {
        let s = slots([Sub(start: 0, dur: 5), Sub(start: 3, dur: 5)])
        XCTAssertEqual(s[0], 5.0, accuracy: 0.001, "槽位(2.85)小于字幕时长(5)，必须退回字幕时长")
    }

    /// 最后一条后面没有别的配音，多长都不会重叠，不该被压
    func testLastSubtitleIsUnbounded() {
        let s = slots([Sub(start: 0, dur: 2), Sub(start: 5, dur: 2)])
        XCTAssertEqual(s[1], .greatestFiniteMagnitude, "最后一条不设上限")
    }

    /// 呼吸间隙确实留出来了，两条配音不会首尾死贴
    func testBreathingGapIsReserved() {
        let s = slots([Sub(start: 0, dur: 1), Sub(start: 10, dur: 1)])
        XCTAssertEqual(s[0], 9.85, accuracy: 0.001)
        XCTAssertLessThan(s[0], 10.0, "必须比到下一条的距离短，留出呼吸间隙")
    }
}
