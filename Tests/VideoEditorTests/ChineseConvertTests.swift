// 简繁互转走本地 OpenCC/ICU，不经翻译引擎。
//
// 起因：DeepL 选目标繁中，12 条字幕翻到最后才弹限流，翻出来的还全是简体。
// 根因是把「简繁转换」当成了「翻译」——各家对 zh-Hant 支持参差：DeepL 收下
// ZH-HANT 照样回简体且免费版十来条就 429，Apple 要用户另外下语言包，
// 有道 from=auto 是中英互译逻辑压根不看 to。字形转换本地做才是正路。
import XCTest
@testable import VideoEditorLib

final class ChineseConvertTests: XCTestCase {

    // MARK: - 字形转换本身

    /// 一简对多繁的歧义字是这套方案的成败点：单字表反查只能二选一必然出错，
    /// 所以用了带词组规则的 ICU。这几条错一条就说明该换实现
    func testSimplifiedToTraditionalHandlesAmbiguousChars() {
        let cases = [
            ("头发很长", "頭髮很長"),
            ("干净的水", "乾淨的水"),
            ("面条",     "麵條"),
            ("手表",     "手錶"),
            ("冲突",     "衝突"),
            ("复杂",     "複雜"),
            ("里面",     "裡面"),
        ]
        for (src, expected) in cases {
            XCTAssertEqual(OpenCC.toTraditional(src), expected, "「\(src)」转繁体不对")
        }
    }

    func testTraditionalToSimplifiedRoundTrip() {
        XCTAssertEqual(OpenCC.toSimplified("頭髮很長"), "头发很长")
        XCTAssertEqual(OpenCC.toSimplified("這是繁體字幕"), "这是繁体字幕")
    }

    /// 非中文原样保留，别把英文数字标点也动了
    func testNonChineseUntouched() {
        XCTAssertEqual(OpenCC.toTraditional("Hello 2024!"), "Hello 2024!")
        XCTAssertEqual(OpenCC.toSimplified("Hello 2024!"), "Hello 2024!")
    }

    // MARK: - 中文识别

    func testIsChineseText() {
        XCTAssertTrue(Translator.isChineseText("这是一条中文字幕"))
        XCTAssertTrue(Translator.isChineseText("繁體字幕"))
        XCTAssertTrue(Translator.isChineseText("你好"), "两个字的短句也要认出来")
        XCTAssertFalse(Translator.isChineseText("This is English"))
        XCTAssertFalse(Translator.isChineseText(""))
    }

    /// 日文韩文也含汉字，必须排掉 —— 否则日文字幕选繁中会被本地"转"一道
    func testJapaneseAndKoreanAreNotChinese() {
        XCTAssertFalse(Translator.isChineseText("これは日本語です"))
        XCTAssertFalse(Translator.isChineseText("動画の編集"), "含假名就是日文")
        XCTAssertFalse(Translator.isChineseText("한국어 자막입니다"))
    }

    // MARK: - 分流：哪些本地转、哪些送引擎

    func testChineseToChineseConvertsLocally() {
        XCTAssertEqual(Translator.localChineseConvert("头发很长", to: "中文（繁体）"), "頭髮很長")
        XCTAssertEqual(Translator.localChineseConvert("頭髮很長", to: "中文（简体）"), "头发很长")
    }

    /// 短句是这次的关键回归点：isAlreadyTarget 对 4 字以下一律返回"已是目标"，
    /// 本地转换必须排在它前面，否则一整轨短句会原样留在简体
    func testShortChineseStillConverts() {
        XCTAssertEqual(Translator.localChineseConvert("干净", to: "中文（繁体）"), "乾淨")
        XCTAssertEqual(Translator.localChineseConvert("头发", to: "中文（繁体）"), "頭髮")
    }

    /// 非中文原文要送引擎（返回 nil），不能被本地转换截胡
    func testNonChineseSourceGoesToEngine() {
        XCTAssertNil(Translator.localChineseConvert("Hello world", to: "中文（繁体）"))
        XCTAssertNil(Translator.localChineseConvert("これは日本語です", to: "中文（简体）"))
    }

    /// 目标不是中文的一律送引擎
    func testNonChineseTargetGoesToEngine() {
        XCTAssertNil(Translator.localChineseConvert("这是中文", to: "English"))
        XCTAssertNil(Translator.localChineseConvert("这是中文", to: "日本語"))
    }

    // MARK: - 引擎目标语言改写

    /// 繁中不交给引擎翻 —— 一律让它翻简中，繁体最后本地转
    func testEngineNeverAskedForTraditional() {
        XCTAssertEqual(Translator.engineLanguage(for: "中文（繁体）"), "中文（简体）")
    }

    func testOtherTargetsPassThroughUnchanged() {
        for lang in ["中文（简体）", "English", "日本語", "Français"] {
            XCTAssertEqual(Translator.engineLanguage(for: lang), lang)
        }
    }
}
