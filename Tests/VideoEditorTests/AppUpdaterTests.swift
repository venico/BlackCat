// 应用内更新。版本比较是最容易错的一环——错了要么永远提示不更新，
// 要么把用户往旧版本上带，两种都很难被用户发现。
import XCTest
@testable import VideoEditorLib

final class AppUpdaterTests: XCTestCase {

    func testBasicOrdering() {
        XCTAssertTrue(AppUpdater.isNewer("4.3.6", than: "4.3.5"))
        XCTAssertFalse(AppUpdater.isNewer("4.3.5", than: "4.3.6"))
        XCTAssertFalse(AppUpdater.isNewer("4.3.5", than: "4.3.5"), "同版本不算有更新")
    }

    func testTolerantOfVPrefix() {
        // GitHub 的 tag 是 v4.3.6，Info.plist 里是 4.3.5，两种写法要能直接比
        XCTAssertTrue(AppUpdater.isNewer("v4.3.6", than: "4.3.5"))
        XCTAssertFalse(AppUpdater.isNewer("v4.3.5", than: "4.3.5"))
    }

    func testDifferentComponentCounts() {
        // 位数不同按补 0：4.4 == 4.4.0，所以比 4.3.5 新
        XCTAssertTrue(AppUpdater.isNewer("4.4", than: "4.3.5"))
        XCTAssertFalse(AppUpdater.isNewer("4.3", than: "4.3.5"))
        XCTAssertTrue(AppUpdater.isNewer("4.3.5.1", than: "4.3.5"))
        XCTAssertFalse(AppUpdater.isNewer("4.3.5", than: "4.3.5.1"))
    }

    func testNumericNotLexicographic() {
        // 字符串比较会认为 "4.3.9" > "4.3.10"，那样发了 4.3.10 用户永远收不到
        XCTAssertTrue(AppUpdater.isNewer("4.3.10", than: "4.3.9"))
        XCTAssertFalse(AppUpdater.isNewer("4.3.9", than: "4.3.10"))
        XCTAssertTrue(AppUpdater.isNewer("4.10.0", than: "4.9.9"))
    }

    func testMajorVersionDominates() {
        XCTAssertTrue(AppUpdater.isNewer("5.0.0", than: "4.99.99"))
        XCTAssertFalse(AppUpdater.isNewer("4.99.99", than: "5.0.0"))
    }

    func testGarbageDoesNotCrashOrFalselyTrigger() {
        XCTAssertFalse(AppUpdater.isNewer("", than: "4.3.5"))
        XCTAssertFalse(AppUpdater.isNewer("abc", than: "4.3.5"))
        // 带后缀的按数字前缀取：4.3.6-beta 的第三位仍是 6
        XCTAssertTrue(AppUpdater.isNewer("4.3.6-beta", than: "4.3.5"))
    }

    @MainActor
    func testCurrentVersionIsReadable() {
        // 从 Info.plist 读，不硬编码——测试环境没有 bundle 版本时退回 "0"
        XCTAssertFalse(AppUpdater.currentVersion.isEmpty)
    }
}

/// tag 过滤。app 和模型包共用一个仓库，必须能分清哪个 tag 是 app 版本——
/// 分不清的话更新检查会指到模型包上，而且不报任何错
final class AppVersionTagTests: XCTestCase {

    func testAcceptsPlainVersionTags() {
        XCTAssertTrue(AppUpdater.isAppVersionTag("v4.3.6"))
        XCTAssertTrue(AppUpdater.isAppVersionTag("4.3.6"))
        XCTAssertTrue(AppUpdater.isAppVersionTag("v5.0"))
        XCTAssertTrue(AppUpdater.isAppVersionTag("10.20.30"))
    }

    func testRejectsModelPackageTags() {
        // 这三个是 blackcat-models 里实际存在的模型包 tag
        XCTAssertFalse(AppUpdater.isAppVersionTag("clarity-pro-v1"))
        XCTAssertFalse(AppUpdater.isAppVersionTag("fsrcnn-v1"))
        XCTAssertFalse(AppUpdater.isAppVersionTag("birefnet-v1"))
    }

    func testRejectsOtherNonVersionTags() {
        XCTAssertFalse(AppUpdater.isAppVersionTag(""))
        XCTAssertFalse(AppUpdater.isAppVersionTag("latest"))
        XCTAssertFalse(AppUpdater.isAppVersionTag("v4"), "单个数字不算版本号，至少要有一个点")
        XCTAssertFalse(AppUpdater.isAppVersionTag("4.3.6-beta"), "带后缀的不收，避免把预发布当正式版")
    }

    /// 选版本时按版本号大小取，不按发布时间——模型包和 app 交替发布时，
    /// 时间顺序完全不能代表版本新旧
    func testPicksHighestVersionNotNewestByTime() {
        let tags = ["v4.3.5", "v4.10.0", "v4.9.9", "clarity-pro-v1"]
        let appTags = tags.filter(AppUpdater.isAppVersionTag)
        let highest = appTags.max { AppUpdater.isNewer($1, than: $0) }
        XCTAssertEqual(highest, "v4.10.0")
    }
}
