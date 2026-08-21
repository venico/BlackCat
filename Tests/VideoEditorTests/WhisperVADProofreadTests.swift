// 模块 27：语音识别 VAD 时间对齐 与 字幕 AI 校对（v4.6.0）
//
// 这两块的核心风险都不是"跑没跑起来"，而是**悄悄把字幕搞错**：
// 对齐把字幕挂在静音上、校对让模型改了时间戳或者漏掉几条。
// 所以测的是边界与退回路径，不是happy path。
import XCTest
@testable import VideoEditorLib

final class WhisperVADAlignTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private typealias Seg = (start: Double, end: Double, text: String)

    // TC-WH-010: 静音处不再挂字幕 —— 整条落在静音里的段落直接丢掉
    func testWH010_SegmentFullyInSilenceIsDropped() {
        let segs: [Seg] = [(0.0, 2.0, "有人说话"),
                           (2.0, 5.0, "这段全是静音"),
                           (5.0, 7.0, "又开始说话")]
        // VAD 只在 0~2 和 5~7 找到语音，2~5 是静音
        let speech = [(start: 0.0, end: 2.0), (start: 5.0, end: 7.0)]

        let out = WhisperTranscriber.alignToSpeech(segs, speech: speech)

        XCTAssertEqual(out.count, 2, "落在静音区的那条必须被丢掉")
        XCTAssertFalse(out.contains { $0.text == "这段全是静音" })
    }

    // TC-WH-011: 首尾收紧 —— 开头 1.5 秒没人声时，第一条字幕不该从 00:00 开始
    func testWH011_LeadingSilenceIsTrimmed() {
        // whisper 的段落首尾相接、铺满整条音频，所以第一条是从 0 开始的
        let segs: [Seg] = [(0.0, 4.0, "开头有一段空白")]
        let speech = [(start: 1.5, end: 3.8)]

        let out = WhisperTranscriber.alignToSpeech(segs, speech: speech)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 1.5, accuracy: 0.001, "起点应收到人声开始处")
        XCTAssertEqual(out[0].end, 3.8, accuracy: 0.001, "终点应收到人声结束处")
    }

    // 重叠短于 minOverlap(0.15s) 当噪声，不算命中
    func testTinyOverlapIsTreatedAsNoise() {
        let segs: [Seg] = [(0.0, 1.0, "只蹭到一点点")]
        let speech = [(start: 0.95, end: 3.0)]   // 只重叠 0.05s

        XCTAssertTrue(WhisperTranscriber.alignToSpeech(segs, speech: speech).isEmpty)
    }

    // mergeGap(0.6s)：短于此的停顿是句内换气，不拆句
    func testShortPauseDoesNotSplitSentence() {
        let segs: [Seg] = [(0.0, 5.0, "前半句 后半句")]
        // 中间只停了 0.3 秒
        let speech = [(start: 0.0, end: 2.0), (start: 2.3, end: 5.0)]

        let out = WhisperTranscriber.alignToSpeech(segs, speech: speech)

        XCTAssertEqual(out.count, 1, "0.3s 的停顿属于换气，不该拆成两条")
        XCTAssertEqual(out[0].text, "前半句 后半句")
    }

    // 跨长静音才拆，且按词边界拆 —— 不能切出 "At ove" / "r 600 grams" 这种碎片
    func testLongPauseSplitsOnWordBoundary() {
        let segs: [Seg] = [(0.0, 10.0, "At over 600 grams per serving")]
        let speech = [(start: 0.0, end: 4.0), (start: 6.0, end: 10.0)]   // 中间静音 2s

        let out = WhisperTranscriber.alignToSpeech(segs, speech: speech)

        XCTAssertEqual(out.count, 2, "跨 2 秒静音应该拆开")
        for piece in out {
            for word in piece.text.split(separator: " ") {
                XCTAssertTrue("At over 600 grams per serving".contains(word),
                              "拆出了不完整的单词碎片：\(word)")
            }
        }
        // 拆完的文字合起来还是原文，不能丢词
        XCTAssertEqual(out.map(\.text).joined(separator: " "),
                       "At over 600 grams per serving")
    }

    // TC-WH-019: VAD 不可用时降级 —— 拿不到语音区间就原样返回，不报错不中断
    func testWH019_EmptySpeechFallsBackToOriginal() {
        let segs: [Seg] = [(0.0, 2.0, "一"), (2.0, 4.0, "二")]

        let out = WhisperTranscriber.alignToSpeech(segs, speech: [])

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.start), segs.map(\.start))
        XCTAssertEqual(out.map(\.end), segs.map(\.end))
    }

    // 输出必须按时间升序，否则字幕轨插入顺序会乱
    func testOutputIsSortedByStart() {
        let segs: [Seg] = [(5.0, 7.0, "后"), (0.0, 2.0, "先")]
        let speech = [(start: 0.0, end: 2.0), (start: 5.0, end: 7.0)]

        let out = WhisperTranscriber.alignToSpeech(segs, speech: speech)

        XCTAssertEqual(out.map(\.text), ["先", "后"])
    }
}

final class SubtitleProofreadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    private typealias Seg = (start: Double, end: Double, text: String)

    private let three: [Seg] = [(0.0, 1.0, "第一条"),
                                (1.0, 2.0, "第二条"),
                                (2.0, 3.0, "第三条")]

    /// 造一个只会回固定 JSON 的假模型
    private func stub(_ json: String) -> (String) async throws -> String {
        { _ in json }
    }

    // TC-WH-015: 修错别字 + 合并碎片，并如实报告改动条数
    func testWH015_MergeAndFixReportsChangeCount() async {
        let json = """
        [{"from":1,"to":2,"text":"第一条和第二条合并"},{"from":3,"to":3,"text":"第三条改过"}]
        """
        let (out, changed, err) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertNil(err)
        XCTAssertEqual(out.count, 2, "1、2 合并后应剩两条")
        XCTAssertEqual(out[0].text, "第一条和第二条合并")
        XCTAssertGreaterThan(changed, 0, "改动条数必须如实汇报，不能报 0")
    }

    // TC-WH-016: 时间戳一概不交给模型 —— 合并后的起止 = 首条 start、末条 end
    func testWH016_TimestampsComeFromCodeNotModel() async {
        let json = """
        [{"from":1,"to":2,"text":"合并"},{"from":3,"to":3,"text":"末条"}]
        """
        let (out, _, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out[0].start, 0.0, accuracy: 0.0001)
        XCTAssertEqual(out[0].end,   2.0, accuracy: 0.0001, "合并段的终点该取末条的 end")
        XCTAssertEqual(out[1].start, 2.0, accuracy: 0.0001)
        XCTAssertEqual(out[1].end,   3.0, accuracy: 0.0001)
    }

    // TC-WH-017: 模型调用失败 → 字幕仍按识别结果生成，一条不丢，并带出错误原因
    func testWH017_SendFailureKeepsOriginalAndReportsError() async {
        let failing: (String) async throws -> String = { _ in
            throw NSError(domain: "test", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 API Key"])
        }
        let (out, changed, err) = await LLMAnalyzer.proofreadSubtitles(
            three, send: failing, progress: { _ in })

        XCTAssertEqual(out.count, 3, "校对失败不能丢字幕")
        XCTAssertEqual(out.map(\.text), three.map(\.text))
        XCTAssertEqual(changed, 0)
        XCTAssertNotNil(err, "失败必须报出来，不能静默返回原文还显示完成")
    }

    // TC-WH-018: 模型一处没改时 changed 为 0，调用方据此提示"未改动任何内容"
    func testWH018_NoChangeReportsZero() async {
        let json = """
        [{"from":1,"to":1,"text":"第一条"},{"from":2,"to":2,"text":"第二条"},{"from":3,"to":3,"text":"第三条"}]
        """
        let (out, changed, err) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(changed, 0)
        XCTAssertNil(err)
    }

    // 结果校验：跳号 → 整批退回原文（宁可不校对，也不能把字幕搞乱）
    func testSkippedIndexRollsBackWholeBatch() async {
        let json = """
        [{"from":1,"to":1,"text":"改了"},{"from":3,"to":3,"text":"跳过了第二条"}]
        """
        let (out, _, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out.map(\.text), three.map(\.text), "跳号该整批退回")
    }

    // 结果校验：越界序号 → 整批退回原文
    func testOutOfRangeIndexRollsBack() async {
        let json = """
        [{"from":1,"to":9,"text":"越界了"}]
        """
        let (out, _, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out.map(\.text), three.map(\.text))
    }

    // 结果校验：没盖全（漏掉末条）→ 整批退回原文
    func testIncompleteCoverageRollsBack() async {
        let json = """
        [{"from":1,"to":2,"text":"只盖了前两条"}]
        """
        let (out, _, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out.map(\.text), three.map(\.text))
    }

    // 结果校验：空文本 → 整批退回原文（不能把字幕改没）
    func testEmptyTextRollsBack() async {
        let json = """
        [{"from":1,"to":1,"text":"   "},{"from":2,"to":2,"text":"二"},{"from":3,"to":3,"text":"三"}]
        """
        let (out, _, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out.map(\.text), three.map(\.text))
    }

    // 模型爱把 JSON 包在 ```json 代码块里，或前后加说明 —— 都要能取出来
    func testJSONWrappedInCodeFenceStillParses() async {
        let json = """
        好的，这是校对结果：
        ```json
        [{"from":1,"to":1,"text":"第一条"},{"from":2,"to":2,"text":"第二条"},{"from":3,"to":3,"text":"三改了"}]
        ```
        以上。
        """
        let (out, changed, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub(json), progress: { _ in })

        XCTAssertEqual(out[2].text, "三改了")
        XCTAssertEqual(changed, 1)
    }

    // 回复根本不是 JSON → 原样保留，不崩不丢
    func testGarbageReplyKeepsOriginal() async {
        let (out, changed, _) = await LLMAnalyzer.proofreadSubtitles(
            three, send: stub("抱歉，我无法完成这个请求。"), progress: { _ in })

        XCTAssertEqual(out.map(\.text), three.map(\.text))
        XCTAssertEqual(changed, 0)
    }

    // 空输入不该炸
    func testEmptyInputIsNoOp() async {
        let (out, changed, err) = await LLMAnalyzer.proofreadSubtitles(
            [], send: stub("[]"), progress: { _ in })

        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(changed, 0)
        XCTAssertNil(err)
    }
}
