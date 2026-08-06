// 系统超分的可用性判断：以前尺寸超限会静默回落到随包 FSRCNN，用户选了系统超分
// 却拿到另一个引擎的画质、界面上还没有任何提示。现在改成"选哪个就是哪个"，
// 跑不了就拦下并说明原因。这组测试锁的就是"什么情况该拦、什么情况该放行"。
import XCTest
@testable import VideoEditorLib

final class ClaritySystemSRGateTests: XCTestCase {

    /// 这台机器支不支持系统超分。不支持时只有"版本/芯片不支持"那条分支会走到，
    /// 尺寸相关的断言就没有意义，跳过而不是假装通过
    private var systemSRAvailable: Bool {
        if #available(macOS 26.0, *) { return AppleSuperResolution.isSupported }
        return false
    }

    func testWithinLimitIsAllowed() throws {
        try XCTSkipUnless(systemSRAvailable, "这台机器不支持系统超分")
        XCTAssertNil(ProjectState.systemSRUnavailableReason(width: 1920, height: 1080),
                     "正好等于上限应该放行")
        XCTAssertNil(ProjectState.systemSRUnavailableReason(width: 1280, height: 720))
    }

    func testOversizeIsBlockedWithReason() throws {
        try XCTSkipUnless(systemSRAvailable, "这台机器不支持系统超分")
        // 4K：宽高都超
        let reason4K = ProjectState.systemSRUnavailableReason(width: 3840, height: 2160)
        XCTAssertNotNil(reason4K, "4K 素材必须被拦下，不能静默换引擎")
        // 原因里要带上实际尺寸，用户才知道是自己素材的问题
        XCTAssertTrue(reason4K?.contains("3840×2160") == true, "实际尺寸要出现在提示里：\(reason4K ?? "nil")")
        XCTAssertTrue(reason4K?.contains("1920×1080") == true, "上限也要写清楚：\(reason4K ?? "nil")")
    }

    func testOnlyOneDimensionOversizeIsAlsoBlocked() throws {
        try XCTSkipUnless(systemSRAvailable, "这台机器不支持系统超分")
        // 竖屏 1080x1920：宽没超但高超了，Apple 的配置一样建不起来
        XCTAssertNotNil(ProjectState.systemSRUnavailableReason(width: 1080, height: 1920),
                        "高超限也要拦")
        XCTAssertNotNil(ProjectState.systemSRUnavailableReason(width: 2560, height: 1080),
                        "宽超限也要拦")
    }

    func testUnknownSizeIsAllowedThrough() throws {
        try XCTSkipUnless(systemSRAvailable, "这台机器不支持系统超分")
        // 读不到尺寸时不拦——拦了就等于把一批本来能跑的素材挡在外面，
        // 真跑起来尺寸不对会在 AppleSuperResolution 初始化时抛错，走统一的失败提示
        XCTAssertNil(ProjectState.systemSRUnavailableReason(width: 0, height: 0))
    }
}
