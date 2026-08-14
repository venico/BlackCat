// 翻译前的「已经是目标语言」判定。
//
// 起因：中文字幕选目标简中，点翻译后整条变英文 —— 有道的 from=auto 是中英互译逻辑，
// 检测到中文就翻英文、根本不看 to 参数（Apple 在 source==target 时行为也未定义）。
// 修法是在送去翻译之前就判掉，各引擎统一行为。
import XCTest
@testable import VideoEditorLib

final class TranslateTargetGuardTests: XCTestCase {

    private let zh = "对我来说，营销的核心是价值观"
    private let en = "For me, the core of marketing is values"

    func testChineseTextIsAlreadyChineseTarget() {
        XCTAssertTrue(Translator.isAlreadyTarget(zh, lang: "中文（简体）"))
    }

    func testEnglishTextNeedsTranslationToChinese() {
        XCTAssertFalse(Translator.isAlreadyTarget(en, lang: "中文（简体）"))
    }

    func testEnglishTextIsAlreadyEnglishTarget() {
        XCTAssertTrue(Translator.isAlreadyTarget(en, lang: "English"))
    }

    /// 简繁要分开：简体原文 + 繁体目标 = 需要翻
    func testSimplifiedIsNotTreatedAsTraditional() {
        XCTAssertFalse(Translator.isAlreadyTarget(zh, lang: "中文（繁体）"))
    }

    /// 太短的识别不可靠（"OK"、数字、单个名词），一律当作不用翻 ——
    /// 否则一整轨中文里混一条 "OK" 就会把整轨拖进翻译流程
    func testTooShortTextIsSkipped() {
        for s in ["OK", "2024", "——", "Hi"] {
            XCTAssertTrue(Translator.isAlreadyTarget(s, lang: "中文（简体）"),
                          "「\(s)」太短，不该被判成需要翻译")
        }
    }

    func testEmptyTextIsSkipped() {
        XCTAssertTrue(Translator.isAlreadyTarget("", lang: "中文（简体）"))
        XCTAssertTrue(Translator.isAlreadyTarget("   \n ", lang: "中文（简体）"))
    }

    /// 够长的英文句子仍要翻，别被短文本规则误伤
    func testLongEnoughEnglishStillNeedsTranslation() {
        XCTAssertFalse(Translator.isAlreadyTarget("Hello world", lang: "中文（简体）"))
    }
}
