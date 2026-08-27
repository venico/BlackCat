// MultiSelectInspector.swift
//
// 多选时的属性面板。预览区和封面弹窗共用这一份 —— 只放三种元素都有、
// 而且一起调有意义的那几项。
//
// **位置、缩放、旋转按「相对增量」走**：拖 +10% 就各自放大 10%，
// 不是把所有元素的值设成同一个数（那样一拖就全叠一块儿去了）。
// 不透明度反过来，按统一赋值 —— 那是「让这几个一样淡」的诉求。

import SwiftUI

/// 多选面板要读写的一个图层。调用方（预览区 / 封面）各自提供
struct MultiLayerHandle: Identifiable {
    let id: UUID
    /// 渲染坐标系里的中心和尺寸，用来算包围盒
    var center: CGPoint
    var size: CGSize
    var opacity: Double
    /// 相对缩放：ratio 是相对**起手那一刻**的倍率
    var scaleBy: (Double) -> Void
    /// 相对移动：dx/dy 是渲染坐标的位移
    var moveBy: (CGPoint) -> Void
    /// 相对旋转：delta 是角度增量
    var rotateBy: (Double) -> Void
    /// 统一赋值
    var setOpacity: (Double) -> Void
}

struct MultiSelectInspector: View {
    let layers: [MultiLayerHandle]
    /// 画布尺寸（渲染坐标），单选时对齐它
    let canvasSize: CGSize
    var onAlign: ((LayerAlignMode) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onBeforeChange: (() -> Void)? = nil

    /// 拖动中的增量。松手清零 —— 面板上的滑块量的是「这次拖了多少」，
    /// 不是某个绝对值（多选本来就没有统一的绝对值）
    @State private var scalePct: Double = 100
    @State private var rotateDelta: Double = 0
    @State private var moveX: Double = 0
    @State private var moveY: Double = 0
    @State private var opacityPct: Double = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let align = onAlign {
                ISection(title: "对齐") {
                    HStack(spacing: 3) {
                        alignButton("alignLeft", .left, align)
                        alignButton("alignHCenter", .vcenter, align)
                        alignButton("alignRight", .right, align)
                        alignButton("alignTop", .top, align)
                            alignButton("alignVCenter", .hcenter, align)
                        alignButton("alignBottom", .bottom, align)
                        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 18)
                        alignButton("hDistribute", .hdist, align)
                        alignButton("vDistribute", .vdist, align)
                    }
                }
            }

            ISection(title: "一起调整") {
                // 这几条都是**相对量**：松手回到基准值，下次拖再从基准算
                ISlider(label: "缩放", value: Binding(
                    get: { scalePct },
                    set: { v in
                        let k = scalePct > 0.01 ? v / scalePct : 1
                        scalePct = v
                        onBeforeChange?()
                        for l in layers { l.scaleBy(k) }
                    }
                ), range: 20...300, unit: "%")

                ISlider(label: "旋转", value: Binding(
                    get: { rotateDelta },
                    set: { v in
                        let d = v - rotateDelta
                        rotateDelta = v
                        onBeforeChange?()
                        for l in layers { l.rotateBy(d) }
                    }
                ), range: -180...180, unit: "°")

                ISlider(label: "水平移动", value: Binding(
                    get: { moveX },
                    set: { v in
                        let d = (v - moveX) / 100 * Double(canvasSize.width)
                        moveX = v
                        onBeforeChange?()
                        for l in layers { l.moveBy(CGPoint(x: d, y: 0)) }
                    }
                ), range: -50...50, unit: "%")

                ISlider(label: "垂直移动", value: Binding(
                    get: { moveY },
                    set: { v in
                        let d = (v - moveY) / 100 * Double(canvasSize.height)
                        moveY = v
                        onBeforeChange?()
                        for l in layers { l.moveBy(CGPoint(x: 0, y: d)) }
                    }
                ), range: -50...50, unit: "%")
            }

            ISection(title: "外观") {
                // 不透明度是**统一赋值** —— 多选调它就是想让这几个一样淡
                ISlider(label: "不透明度", value: Binding(
                    get: { opacityPct },
                    set: { v in
                        opacityPct = v
                        onBeforeChange?()
                        for l in layers { l.setOpacity(v / 100) }
                    }
                ), range: 0...100, unit: "%")
            }
        }
        .onAppear { syncFromLayers() }
        .onChange(of: layers.count) { _ in syncFromLayers() }
    }

    /// 面板打开时把几个相对量归位。不透明度取选中项的平均值，
    /// 这样滑块起点看着是对的
    private func syncFromLayers() {
        scalePct = 100
        rotateDelta = 0
        moveX = 0
        moveY = 0
        guard !layers.isEmpty else { opacityPct = 100; return }
        opacityPct = layers.map { $0.opacity }.reduce(0, +) / Double(layers.count) * 100
    }

    private func alignButton(_ svg: String, _ mode: LayerAlignMode,
                             _ action: @escaping (LayerAlignMode) -> Void) -> some View {
        let enabled = mode.needsThree ? layers.count >= 3 : true
        return Button { action(mode) } label: {
            Image(nsImage: SidebarSVGIcon.load(svg))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundColor(enabled ? Color.labelPrimary : Color.labelSecondary.opacity(0.3))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Color.white.opacity(enabled ? 0.06 : 0.02))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
