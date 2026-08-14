// 送给 Apple 翻译的**源**语言按整批投票，不逐条检测。
//
// 起因：Apple 引擎、英文轨、目标繁中，整轨翻完孤零零剩一条没翻，还提示"缺少语言包"。
// 那条是「Nike, Disney, Coke, Sony.」—— 纯品牌名罗列没有语法结构，
// NLLanguageRecognizer 判成土耳其语（tr 0.39，en 才 0.26），
// 而 Apple 的 installedSource: 要求那对语言包已装，于是直接抛错。
// 只有 Apple 需要显式源语言，别家都是 auto，所以只有它踩到。
import XCTest
@testable import VideoEditorLib

final class TranslateSourceLanguageTests: XCTestCase {

    private let brandLine = "Nike, Disney, Coke, Sony."

    /// 核心保证：一条检测不准的字幕不能带偏整轨的源语言
    func testBrandNameLineDoesNotSkewBatchLanguage() {
        let texts = [
            "For me, the core of marketing is values",
            brandLine,
            "These brands tell a story about who you are",
            "That is why people keep coming back",
        ]
        XCTAssertEqual(Translator.dominantLanguage(of: texts), "en")
    }

    /// 就算难判的那条排在最前面也一样
    func testHardLineFirstStillVotesEnglish() {
        let texts = [
            brandLine,
            "For me, the core of marketing is values",
            "These brands tell a story about who you are",
        ]
        XCTAssertEqual(Translator.dominantLanguage(of: texts), "en")
    }

    func testChineseTrackVotesChinese() {
        let texts = [
            "对我来说，营销的核心是价值观",
            "这些品牌讲的是你是谁",
            "所以人们才会一直回来",
        ]
        XCTAssertEqual(Translator.dominantLanguage(of: texts)?.hasPrefix("zh"), true)
    }

    /// 投不出结果时返回 nil，让调用方回到逐条检测，而不是硬塞一个错的源语言
    func testNoVotesReturnsNil() {
        XCTAssertNil(Translator.dominantLanguage(of: []))
        XCTAssertNil(Translator.dominantLanguage(of: ["OK", "42", "—"]),
                     "太短的不参与投票")
    }
}
