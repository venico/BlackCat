// 字幕排版尺寸：预览和导出必须共用同一份计算。
//
// 曾经预览侧是另一套 —— `.background(GeometryReader)` 实测 SwiftUI Label 高度，
// 再 `DispatchQueue.main.async` 写回 @State，堆叠时读那份实测值。
// 快速拖动播放头时字幕一条接一条切换，每条文字长短不同、高度一直在变，
// 异步写回跟不上帧率，那几帧就拿上一条字幕的高度来排版 → **间距忽大忽小**。
// 导出侧没这毛病，因为它一直是同步用 CoreText 算的。
import XCTest
@testable import VideoEditorLib

final class SubtitleLayoutTests: XCTestCase {

    private let zh = "微软已经宣布了 Macintosh 版的 Multiplan，现在店里就有卖"
    private let en = "Microsoft has announced Multiplan for Macintosh, and it's in the stores now."

    /// 同一份文本+样式，无论算多少次结果都一样 —— 没有异步状态就没有竞态
    func testLayerSizeIsDeterministic() {
        let style = SubtitleStyle()
        let first = style.layerSize(text: zh, scale: 1, renderWidth: 1920)
        for _ in 0..<20 {
            XCTAssertEqual(style.layerSize(text: zh, scale: 1, renderWidth: 1920), first,
                           "同样输入必须永远得到同样尺寸")
        }
    }

    /// 层高随 scale 线性缩放：预览（scale<1）和导出（scale=1）换算到同一坐标系必须重合
    func testHeightScalesLinearly() {
        let style = SubtitleStyle()
        let full = style.layerSize(text: zh, scale: 1, renderWidth: 1920).height
        let half = style.layerSize(text: zh, scale: 0.5, renderWidth: 1920).height
        // 允许 ceil 带来的 1~2pt 误差
        XCTAssertEqual(half * 2, full, accuracy: 3,
                       "预览缩小一半算出来的层高，换算回去要跟导出对得上")
    }

    /// 层高含上下内边距，且大于纯字号 —— 排版要留出行高
    func testHeightIncludesPadding() {
        let style = SubtitleStyle()
        let h = style.layerSize(text: zh, scale: 1, renderWidth: 1920).height
        XCTAssertGreaterThan(h, style.fontSize, "层高至少要盖住字号")
        XCTAssertLessThan(h, style.fontSize * 2, "单行字幕的层高不该到两倍字号")
    }

    /// 文字长到需要换行时层高翻倍——这正是拖播放头时高度会剧烈变化的原因，
    /// 所以更不能靠「上一帧实测值」来排版
    func testWrappingIncreasesHeight() {
        var style = SubtitleStyle()
        style.widthPercent = 20   // 挤窄，强制换行
        let single = style.layerSize(text: "短", scale: 1, renderWidth: 1920).height
        let wrapped = style.layerSize(text: en, scale: 1, renderWidth: 1920).height
        XCTAssertGreaterThan(wrapped, single * 1.5, "换行后层高应明显变高")
    }

    /// 双语堆叠：上面那条的底边距 = 下面那条的层高 + 行距
    /// 预览的 subtitleBottomPad 和导出的 yPos 递减都按这个公式，两边必须一致
    func testBilingualStackOffset() {
        let style = SubtitleStyle()
        let lower = style.layerSize(text: en, scale: 1, renderWidth: 1920).height
        let spacing = CGFloat(style.lineSpacing)
        let offset = lower + spacing
        XCTAssertEqual(offset, lower + 6, accuracy: 0.001)
        XCTAssertGreaterThan(offset, lower, "上面那条必须整体抬高，不能压在下面那条上")
    }

    /// 加粗会让字变宽，但单行层高不该跟着变
    func testBoldDoesNotChangeSingleLineHeight() {
        var plain = SubtitleStyle()
        plain.widthPercent = 100
        var bold = plain
        bold.bold = true
        let a = plain.layerSize(text: "短句", scale: 1, renderWidth: 1920)
        let b = bold.layerSize(text: "短句", scale: 1, renderWidth: 1920)
        XCTAssertEqual(a.height, b.height, accuracy: 2)
    }
}
