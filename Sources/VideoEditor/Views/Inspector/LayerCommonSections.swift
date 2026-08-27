// LayerCommonSections.swift
//
// 图片、文字、图形共同的那几组属性：变换 / 位置 / 缩放 / 裁剪 / 外观 / 对齐。
// 预览区属性区和封面弹窗属性区**共用这一份**，六个面板长得一样、顺序一样。
//
// 组件只管控件和布局，值全靠 Binding 传进来 —— 各元素的字段名和量纲差得远
// （图片位置是 -1~1 的偏移、文字图形是 0~1 的中心点；文字的「宽高」是范围框），
// 换算留在各自的面板里做，这里只认「百分比」。
//
// 不支持的项传 nil 就不显示：文字没有圆角，线段和箭头没有裁剪。

import SwiftUI

/// 对齐方式。单选时对齐画面，多选时对齐选中元素的包围盒
enum LayerAlignMode {
    case left, hcenter, right, top, vcenter, bottom, hdist, vdist
    var needsThree: Bool { self == .hdist || self == .vdist }
}

/// 变换那三个卡片按钮用的图标
enum LayerTransformIcon: String {
    case mirrorH, mirrorV, rotate
}

struct LayerCommonSections: View {
    // ── 变换 ──
    var mirrorH: Binding<Bool>? = nil
    var mirrorV: Binding<Bool>? = nil
    var rotation: Binding<Double>? = nil
    var onRotate90: (() -> Void)? = nil

    // ── 位置（0~100%）──
    var posX: Binding<Double>? = nil
    var posY: Binding<Double>? = nil
    var onCenter: (() -> Void)? = nil

    // ── 缩放（0~400%）──
    var scaleW: Binding<Double>? = nil
    var scaleH: Binding<Double>? = nil
    var lockAspect: Binding<Bool>? = nil
    /// 缩放的量纲。图片图形是百分比，文字量的是范围框像素
    var scaleRange: ClosedRange<Double> = 5...400
    var scaleUnit: String = "%"
    var scaleLabels: (both: String, w: String, h: String) = ("缩放", "宽", "高")

    // ── 裁剪（0~100%）──
    var cropTop: Binding<Double>? = nil
    var cropBottom: Binding<Double>? = nil
    var cropLeft: Binding<Double>? = nil
    var cropRight: Binding<Double>? = nil

    // ── 外观 ──
    var opacity: Binding<Double>? = nil          // 0~100
    var cornerRadius: Binding<Double>? = nil     // nil = 这种元素没有圆角
    /// 圆角是否可调。图形里只有矩形、三角形、梯形、平行四边形能圆角，其余灰掉
    var cornerEnabled = true

    // ── 对齐 ──
    var onAlign: ((LayerAlignMode) -> Void)? = nil
    /// 分布要选中三个以上才有意义
    var canDistribute = false

    /// 改动前的回调，用来压撤销点
    var onBeforeChange: (() -> Void)? = nil

    var body: some View {
        Group {
            transformSection
            positionSection
            scaleSection
            cropSection
            appearanceSection
            alignSection
        }
    }

    // MARK: 变换

    @ViewBuilder
    private var transformSection: some View {
        if mirrorH != nil || mirrorV != nil || rotation != nil {
            ISection(title: "变换") {
                HStack(spacing: 6) {
                    if let m = mirrorH {
                        transformCard(.mirrorH, label: "水平镜像", active: m.wrappedValue) {
                            m.wrappedValue.toggle()
                        }
                    }
                    if let m = mirrorV {
                        transformCard(.mirrorV, label: "垂直镜像", active: m.wrappedValue) {
                            m.wrappedValue.toggle()
                        }
                    }
                    if let rot90 = onRotate90 {
                        transformCard(.rotate, label: "左旋90°",
                                      active: abs(rotation?.wrappedValue ?? 0) > 0.01) {
                            rot90()
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let r = rotation {
                    // 区间取 0~360，跟「左旋 90°」按钮规范化后的值对得上；
                    // 手柄自由转出来的负角度也在这儿折回正区间
                    ISlider(label: "旋转", value: Binding(
                        get: {
                            let v = r.wrappedValue.truncatingRemainder(dividingBy: 360)
                            return v < 0 ? v + 360 : v
                        },
                        set: { r.wrappedValue = $0 }
                    ), range: 0...360, unit: "°")
                }
            }
        }
    }

    private func transformCard(_ icon: LayerTransformIcon, label: String,
                               active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            onBeforeChange?()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: TimelineSVGIcon.load(icon.rawValue))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(active ? .black : Color.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(active ? Color(hex: "#E8A54B") : Color.white.opacity(0.08))
                    .cornerRadius(4)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(Color.labelSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: 位置

    @ViewBuilder
    private var positionSection: some View {
        if let x = posX, let y = posY {
            ISection(title: nil) {
                sectionHeader("位置") {
                    if let center = onCenter {
                        headerButton("居中") { onBeforeChange?(); center() }
                    }
                }
                ISlider(label: "水平位置", value: x, range: 0...100, unit: "%")
                ISlider(label: "垂直位置", value: y, range: 0...100, unit: "%")
            }
        }
    }

    // MARK: 缩放

    @ViewBuilder
    private var scaleSection: some View {
        if let w = scaleW, let h = scaleH {
            ISection(title: nil) {
                sectionHeader("缩放") {
                    if let lock = lockAspect {
                        Button {
                            lock.wrappedValue.toggle()
                        } label: {
                            Image(systemName: lock.wrappedValue ? "lock.fill" : "lock.open")
                                .font(.system(size: 10))
                                .foregroundColor(lock.wrappedValue ? Color.accent : Color.labelSecondary)
                                .frame(width: 22, height: 20)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help(lock.wrappedValue ? "已锁定比例，点击解锁分别调节" : "宽高分别调节，点击锁定等比")
                    }
                }
                // 锁着就只给一个滑块（拖它宽高一起走），解开才拆成两条
                if lockAspect?.wrappedValue ?? false {
                    // 锁着的时候拖一条，宽高按**原来的比例**一起走，
                    // 直接把两个值设成一样会把非等比的元素拉方
                    ISlider(label: scaleLabels.both, value: Binding(
                        get: { w.wrappedValue },
                        set: { v in
                            let old = w.wrappedValue
                            let k = old > 0.01 ? v / old : 1
                            w.wrappedValue = v
                            h.wrappedValue = max(scaleRange.lowerBound,
                                                 min(scaleRange.upperBound, h.wrappedValue * k))
                        }
                    ), range: scaleRange, unit: scaleUnit)
                } else {
                    ISlider(label: scaleLabels.w, value: w, range: scaleRange,
                            unit: scaleUnit)
                    ISlider(label: scaleLabels.h, value: h, range: scaleRange,
                            unit: scaleUnit)
                }
            }
        }
    }

    // MARK: 裁剪

    @ViewBuilder
    private var cropSection: some View {
        if let t = cropTop, let b = cropBottom, let l = cropLeft, let r = cropRight {
            ISection(title: nil) {
                sectionHeader("裁剪") {
                    headerButton("重置") {
                        onBeforeChange?()
                        t.wrappedValue = 0; b.wrappedValue = 0
                        l.wrappedValue = 0; r.wrappedValue = 0
                    }
                }
                ISlider(label: "上", value: t, range: 0...95, unit: "%")
                ISlider(label: "下", value: b, range: 0...95, unit: "%")
                ISlider(label: "左", value: l, range: 0...95, unit: "%")
                ISlider(label: "右", value: r, range: 0...95, unit: "%")
            }
        }
    }

    // MARK: 外观

    @ViewBuilder
    private var appearanceSection: some View {
        if opacity != nil || cornerRadius != nil {
            ISection(title: "外观") {
                if let o = opacity {
                    ISlider(label: "不透明度", value: o, range: 0...100, unit: "%")
                }
                if let c = cornerRadius {
                    // 间距 6 和标签宽度都跟 ICapsuleSlider 对齐，
                    // 输入框再占满右边剩下的宽度 —— 这样它和滑块左右两头都齐
                    IFieldRow(label: "圆角") {
                        MiniStepper(value: c, step: 1, minValue: 0, maxValue: 500)
                            .frame(maxWidth: .infinity)
                            .disabled(!cornerEnabled)
                            .opacity(cornerEnabled ? 1 : 0.35)
                    }
                    .help(cornerEnabled ? "" : "这种图形没有圆角")
                }
            }
        }
    }

    // MARK: 对齐

    @ViewBuilder
    private var alignSection: some View {
        if let align = onAlign {
            ISection(title: "对齐") {
                // 八个按钮等分整行，右边缘跟上面滑块的右边缘齐
                HStack(spacing: 3) {
                    alignButton("alignLeft", .left, align)
                    alignButton("alignHCenter", .vcenter, align)
                    alignButton("alignRight", .right, align)
                    alignButton("alignTop", .top, align)
                    alignButton("alignVCenter", .hcenter, align)
                    alignButton("alignBottom", .bottom, align)
                    Rectangle().fill(Color.white.opacity(0.15))
                        .frame(width: 1, height: 18)
                    alignButton("hDistribute", .hdist, align)
                    alignButton("vDistribute", .vdist, align)
                }
            }
        }
    }

    private func alignButton(_ svg: String, _ mode: LayerAlignMode,
                            _ action: @escaping (LayerAlignMode) -> Void) -> some View {
        let enabled = mode.needsThree ? canDistribute : true
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

    // MARK: 小件

    /// 带右侧按钮的分组标题。ISection 的标题不带按钮，这里自己画一行
    private func sectionHeader<T: View>(_ title: String,
                                        @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 2)
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
