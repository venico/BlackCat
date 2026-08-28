// 属性区排版：标题和控件的左边缘必须齐
import XCTest
import SwiftUI
import AppKit
@testable import VideoEditorLib

@MainActor
final class InspectorLayoutTests: XCTestCase {

    /// 渲染一段视图，返回每一「行墨迹」的最左像素（2x）
    private func inkColumns(_ view: some View, width: CGFloat, height: CGFloat,
                            threshold: CGFloat = 0.12) -> [(y: Int, x: Int)] {
        let r = ImageRenderer(content: view.frame(width: width, height: height).background(Color.black))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff) else { return [] }
        var out: [(Int, Int)] = []
        for y in 0..<bmp.pixelsHigh {
            for x in 0..<bmp.pixelsWide {
                guard let c = bmp.colorAt(x: x, y: y) else { continue }
                if c.brightnessComponent > threshold { out.append((y, x)); break }
            }
        }
        return out
    }

    func testSectionTitleAlignsWithControls() throws {
        let probe = ISection(title: "速度") {
            ICapsuleSlider(label: "速率", value: .constant(1), range: 0...2)
        }
        // 阈值压到 0.03 才抓得到 6% 白的胶囊背景
        let cols = inkColumns(probe, width: 280, height: 90, threshold: 0.03)
        XCTAssertFalse(cols.isEmpty, "什么都没渲染出来")

        // 分成上下两块：上面是标题那几行，下面是胶囊
        let ys = cols.map(\.y)
        guard let top = ys.min(), let bottom = ys.max() else { return XCTFail() }
        let mid = (top + bottom) / 2
        let titleX = cols.filter { $0.y < mid }.map(\.x).min()
        let ctrlX  = cols.filter { $0.y > mid }.map(\.x).min()
        print("标题最左 = \(titleX.map { Double($0)/2 } ?? -1)pt，控件最左 = \(ctrlX.map { Double($0)/2 } ?? -1)pt")

        guard let t = titleX, let c = ctrlX else { return XCTFail("没量到") }
        // 两边都该落在 ISection 的内边距上
        XCTAssertEqual(Double(t) / 2, ISectionMetrics.hPadding, accuracy: 0.5,
                       "分组标题没落在 \(ISectionMetrics.hPadding)pt 上")
        XCTAssertEqual(Double(c) / 2, ISectionMetrics.hPadding, accuracy: 0.5,
                       "控件背景没落在 \(ISectionMetrics.hPadding)pt 上")
    }

    /// 属性区最窄的时候，视频面板那几组也得摆得下 ——
    /// 摆不下的话内容会溢出容器，左边整列被裁掉（速度按钮、滑块标签都缺一截）
    func testVideoInspectorFitsAtMinimumWidth() {
        // 「速度」是最宽的一组：五个预设按钮并排
        let speed = ISection(title: "速度") {
            HStack(spacing: 4) {
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { v in
                    Text(v == 1.0 ? "1×" : (v < 1 ? String(format: "%.2g×", v) : String(format: "%.0f×", v)))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                }
            }
        }
        let need = NSHostingView(rootView: speed).intrinsicContentSize.width
        XCTAssertLessThanOrEqual(need, InspectorLayout.minWidth,
                                 "速度那一组要 \(need)pt，比属性区下限 \(InspectorLayout.minWidth)pt 还宽")
    }
}
