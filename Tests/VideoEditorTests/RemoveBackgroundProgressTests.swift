import XCTest
import Foundation
import AppKit
@testable import VideoEditorLib

// MARK: - 去背进度卡片

final class RemoveBackgroundProgressTests: XCTestCase {

    private var savedEngine: BackgroundRemover.Engine!

    override func setUp() {
        MediaLibrary.shared.resetForTesting()
        super.setUp()
        savedEngine = AppSettings.shared.bgRemovalEngine
    }

    override func tearDown() {
        AppSettings.shared.bgRemovalEngine = savedEngine
        super.tearDown()
    }

    private func makeSolidImage() throws -> URL {
        let w = 300, h = 300
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("无法创建上下文")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 90, width: 120, height: 120))
        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw XCTSkip("无法生成测试图")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmbg_progress_\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    /// 阶段回调必须真的发出来，否则卡片会一直停在 0% 不动
    func testStageCallbacksAreEmitted() async throws {
        AppSettings.shared.bgRemovalEngine = .system
        let src = try makeSolidImage()
        defer { try? FileManager.default.removeItem(at: src) }

        let box = StageBox()
        let out = try await BackgroundRemover.removeBackground(
            from: src, outputName: "unittest_progress", mode: .solid,
            onStage: { box.append($0) })
        defer { try? FileManager.default.removeItem(at: out) }

        let stages = box.stages
        XCTAssertTrue(stages.contains(.processing), "应报告抠图阶段，实际 \(stages)")
        XCTAssertTrue(stages.contains(.composing), "应报告生成图层阶段，实际 \(stages)")
        // 顺序不能乱：先抠图后合成
        if let p = stages.firstIndex(of: .processing), let c = stages.firstIndex(of: .composing) {
            XCTAssertLessThan(p, c, "抠图阶段应早于生成图层")
        }
    }

    /// 走 BiRefNet 且模型尚未加载时，要先报「加载模型」——那是最慢的一段
    func testBiRefNetReportsModelLoading() async throws {
        let model = BiRefNetModel.lite
        try XCTSkipUnless(model.isDownloaded, "BiRefNet Lite 未下载")
        try XCTSkipIf(BiRefNetSegmenter.isLoaded(model), "模型已在内存里，测不到加载阶段")

        AppSettings.shared.bgRemovalEngine = .biRefNet
        AppSettings.shared.biRefNetModel = model
        let src = try makeSolidImage()
        defer { try? FileManager.default.removeItem(at: src) }

        let box = StageBox()
        let out = try await BackgroundRemover.removeBackground(
            from: src, outputName: "unittest_progress_bn", mode: .subject,
            onStage: { box.append($0) })
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertTrue(box.stages.contains(.loadingModel),
                      "首次调用应报告加载模型阶段，实际 \(box.stages)")
    }

    /// 各阶段的进度值必须递增且落在 0~1，卡片才不会倒着走
    func testStageProgressIsMonotonic() {
        let order: [ProjectState.RemoveBackgroundState] = [.loadingModel, .processing, .composing]
        for s in order {
            XCTAssertGreaterThan(s.progress, 0)
            XCTAssertLessThan(s.progress, 1)
        }
        XCTAssertLessThan(ProjectState.RemoveBackgroundState.loadingModel.progress,
                          ProjectState.RemoveBackgroundState.processing.progress)
        XCTAssertLessThan(ProjectState.RemoveBackgroundState.processing.progress,
                          ProjectState.RemoveBackgroundState.composing.progress)
        XCTAssertEqual(ProjectState.RemoveBackgroundState.idle.progress, 0)
    }

    /// isRemovingBackground 得跟状态同步，卡片靠它决定显不显示
    @MainActor
    func testIsRemovingReflectsState() {
        let p = ProjectState()
        XCTAssertFalse(p.isRemovingBackground)
        p.removeBackgroundState = .loadingModel
        XCTAssertTrue(p.isRemovingBackground)
        p.removeBackgroundState = .composing
        XCTAssertTrue(p.isRemovingBackground)
        p.removeBackgroundState = .idle
        XCTAssertFalse(p.isRemovingBackground)
    }

    /// 取消要复位状态并给出提示
    @MainActor
    func testCancelResetsState() {
        let p = ProjectState()
        p.removeBackgroundState = .processing
        p.cancelRemoveBackground()
        XCTAssertFalse(p.isRemovingBackground, "取消后应复位")
        XCTAssertEqual(p.successToasts.last?.title, "去除背景")
        XCTAssertEqual(p.successToasts.last?.subtitle, "已停止")
    }
}

/// onStage 会从后台线程回调，用锁收集
private final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProjectState.RemoveBackgroundState] = []

    func append(_ s: ProjectState.RemoveBackgroundState) {
        lock.lock(); items.append(s); lock.unlock()
    }

    var stages: [ProjectState.RemoveBackgroundState] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
