// 拖入路由：宿主统一收 drop，按落点 + 载荷类型分发给素材区或时间轴。
//
// 为什么不能用 SwiftUI 的 .onDrop：合并绘制之下 hitTest 命中的始终是最外层
// NSHostingView，挂在内层的 .onDrop（甚至内嵌的真实 NSView）一次都收不到。
// Finder 拖入当初为此排查过一整轮；素材库拖到时间轴是同一个坑 ——
// 代码里 .onDrag / .onDrop 都写了，功能却一直不工作（TC-ML-017 / TC-ML-018）。
import XCTest
@testable import VideoEditorLib

@MainActor
final class FileDropRouterTests: XCTestCase {

    private let win = WindowID()
    /// 素材区在左边，时间轴在下方，两块不重叠
    private let libRect = CGRect(x: 0, y: 100, width: 200, height: 400)
    private let tlRect  = CGRect(x: 200, y: 400, width: 1000, height: 200)

    override func tearDown() {
        FileDropRouter.unregister(win)
        super.tearDown()
    }

    private func registerBoth(onFiles: @escaping ([URL]) -> Void = { _ in },
                              onAsset: @escaping (UUID, CGPoint) -> Void = { _, _ in },
                              onShape: @escaping (ShapeType, CGPoint) -> Void = { _, _ in },
                              libTargeted: @escaping (Bool) -> Void = { _ in },
                              tlTargeted: @escaping (Bool) -> Void = { _ in }) {
        FileDropRouter.register(win, rect: libRect, onFiles: onFiles, onTargetChange: libTargeted)
        FileDropRouter.register(
            win, kind: .timeline, rect: tlRect,
            accepts: {
                switch $0 {
                case .asset, .shape: return true
                case .files:         return false
                }
            },
            onDrop: { payload, local in
                switch payload {
                case .asset(let id): onAsset(id, local)
                case .shape(let t):  onShape(t, local)
                case .files:         break
                }
            },
            onTargetChange: tlTargeted)
    }

    /// 图形卡片拖到时间轴：按落点插入
    func testShapeDroppedOnTimelineIsDelivered() {
        var got: (ShapeType, CGPoint)?
        registerBoth(onShape: { got = ($0, $1) })

        let hit = FileDropRouter.deliver(.shape(.ellipse), at: CGPoint(x: 700, y: 450), in: win)

        XCTAssertTrue(hit)
        XCTAssertEqual(got?.0, .ellipse)
        XCTAssertEqual(got?.1.x, 500)
    }

    /// 图形拖回素材区不该被接收
    func testShapeDroppedOnMediaLibraryIsRejected() {
        registerBoth()
        XCTAssertFalse(FileDropRouter.deliver(.shape(.rectangle),
                                              at: CGPoint(x: 100, y: 200), in: win))
    }

    /// pasteboard 串要能原样解回来，且跟素材的裸 UUID 区分得开
    func testShapePasteboardStringRoundTrips() {
        for t in ShapeType.allCases {
            let s = FileDropRouter.pasteboardString(for: t)
            XCTAssertTrue(s.hasPrefix(FileDropRouter.shapePrefix))
            XCTAssertEqual(ShapeType(rawValue: String(s.dropFirst(FileDropRouter.shapePrefix.count))), t)
            XCTAssertNil(UUID(uuidString: s), "不能被当成素材 id 解析")
        }
    }

    /// **图形载荷串本身是个合法 URL**（scheme = shape）。
    /// 宿主解析 pasteboard 时如果先问 NSURL，这串会被解析成功、判成文件拖拽，
    /// 时间轴收不到 —— 而且是在 draggingEntered 阶段就被拒，日志都不会打，
    /// 现象是「能拖但落不下去」。这条钉住：解析顺序必须应用内载荷在前。
    func testShapeStringIsAlsoAValidURLSoOrderMatters() {
        let s = FileDropRouter.pasteboardString(for: .rectangle)
        XCTAssertNotNil(URL(string: s), "它确实能被当成 URL 解析，所以顺序不能反")
        XCTAssertEqual(URL(string: s)?.scheme, "shape")
        // 但它不是文件 URL —— 宿主那边额外用 urlReadingFileURLsOnly 兜了一道
        XCTAssertFalse(URL(string: s)?.isFileURL ?? true)
    }

    /// 素材 id 拖到时间轴要送达，并且落点换算成**区内本地坐标**（时间轴拿它算时间码）
    func testAssetDroppedOnTimelineIsDelivered() {
        var got: (UUID, CGPoint)?
        let asset = UUID()
        registerBoth(onAsset: { got = ($0, $1) })

        let hit = FileDropRouter.deliver(.asset(asset), at: CGPoint(x: 500, y: 450), in: win)

        XCTAssertTrue(hit)
        XCTAssertEqual(got?.0, asset)
        // 落点 500 在时间轴区（起点 200）里的本地坐标是 300
        XCTAssertEqual(got?.1.x, 300)
        XCTAssertEqual(got?.1.y, 50)
    }

    /// 素材 id 落在素材区上不该被接收 —— 素材区只收文件
    func testAssetDroppedOnMediaLibraryIsRejected() {
        var libCalled = false
        registerBoth(onFiles: { _ in libCalled = true })

        let hit = FileDropRouter.deliver(.asset(UUID()), at: CGPoint(x: 100, y: 200), in: win)

        XCTAssertFalse(hit, "素材区不收应用内拖来的素材 id")
        XCTAssertFalse(libCalled)
    }

    /// Finder 文件落在时间轴上不该被接收 —— 时间轴只收素材 id
    func testFilesDroppedOnTimelineAreRejected() {
        var assetCalled = false
        registerBoth(onAsset: { _, _ in assetCalled = true })

        let hit = FileDropRouter.deliver(.files([URL(fileURLWithPath: "/tmp/a.mp4")]),
                                         at: CGPoint(x: 500, y: 450), in: win)

        XCTAssertFalse(hit)
        XCTAssertFalse(assetCalled)
    }

    func testFilesDroppedOnMediaLibraryIsDelivered() {
        var got: [URL] = []
        registerBoth(onFiles: { got = $0 })

        let hit = FileDropRouter.deliver(.files([URL(fileURLWithPath: "/tmp/a.mp4")]),
                                         at: CGPoint(x: 100, y: 200), in: win)

        XCTAssertTrue(hit)
        XCTAssertEqual(got.count, 1)
    }

    /// 落在两块区之外一律不收
    func testDropOutsideAnyZoneIsRejected() {
        registerBoth()
        XCTAssertFalse(FileDropRouter.deliver(.asset(UUID()), at: CGPoint(x: 900, y: 50), in: win))
        XCTAssertFalse(FileDropRouter.canAccept(CGPoint(x: 900, y: 50),
                                                payload: .asset(UUID()), in: win))
    }

    /// 高亮只点亮命中的那一块，另一块必须熄灭 —— 否则拖过时间轴时素材区还亮着
    func testOnlyTheHitZoneIsHighlighted() {
        var lib = false, tl = false
        registerBoth(libTargeted: { lib = $0 }, tlTargeted: { tl = $0 })

        FileDropRouter.setTargeted(true, at: CGPoint(x: 500, y: 450),
                                   payload: .asset(UUID()), in: win)
        XCTAssertTrue(tl); XCTAssertFalse(lib)

        FileDropRouter.setTargeted(true, at: CGPoint(x: 100, y: 200),
                                   payload: .files([]), in: win)
        XCTAssertFalse(tl); XCTAssertTrue(lib)
    }

    /// 拖拽结束要全部熄灭
    func testClearTargetTurnsEverythingOff() {
        var lib = true, tl = true
        registerBoth(libTargeted: { lib = $0 }, tlTargeted: { tl = $0 })

        FileDropRouter.setTargeted(false, at: .zero, payload: .files([]), in: win)

        XCTAssertFalse(lib); XCTAssertFalse(tl)
    }

    /// 按窗口隔离：A 窗口的接收区不能拿去匹配 B 窗口的拖拽
    func testZonesAreIsolatedPerWindow() {
        let other = WindowID()
        registerBoth()
        XCTAssertFalse(FileDropRouter.deliver(.asset(UUID()),
                                              at: CGPoint(x: 500, y: 450), in: other))
    }

    /// 只注销时间轴那块，素材区照常工作（关掉时间轴视图不该连带废掉素材导入）
    func testUnregisterOneKindKeepsTheOther() {
        var libCalled = false
        registerBoth(onFiles: { _ in libCalled = true })

        FileDropRouter.unregister(win, kind: .timeline)

        XCTAssertFalse(FileDropRouter.deliver(.asset(UUID()),
                                              at: CGPoint(x: 500, y: 450), in: win))
        XCTAssertTrue(FileDropRouter.deliver(.files([URL(fileURLWithPath: "/tmp/a.mp4")]),
                                             at: CGPoint(x: 100, y: 200), in: win))
        XCTAssertTrue(libCalled)
    }
}
