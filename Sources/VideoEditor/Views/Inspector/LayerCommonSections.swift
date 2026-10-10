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

/// 关键帧挂钩：每个滑块后面的 `< ◇ >`、标签前的曲线展开箭头、滑块下面展开的曲线面板
struct LayerKeyframeHooks {
    /// nil = 这种元素的这个属性不能打关键帧（比如文字的范围框宽高），那一行就只是滑块
    let nav: (KeyframeProp) -> AnyView?
    let toggle: (KeyframeProp) -> AnyView?
    let panel: (KeyframeProp) -> AnyView
}

struct LayerCommonSections: View {
    /// 给了就在能打关键帧的滑块上挂关键帧控件（目前只有图片）
    var keyframeHooks: LayerKeyframeHooks? = nil

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
            // 外观放在变换前面（各面板统一）
            appearanceSection
            // 位置 / 缩放 / 裁剪是「变换」下面的三级分组，在 transformSection 里
            transformSection
            alignSection
        }
    }

    /// 滑块 + 关键帧控件。没给挂钩就只是滑块；id 给「选中关键帧时属性区滚到这一行」用
    @ViewBuilder
    private func kfRow<S: View>(_ p: KeyframeProp, @ViewBuilder _ slider: () -> S) -> some View {
        if let h = keyframeHooks, let nav = h.nav(p) {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    slider()
                        .environment(\.capsuleSliderLeading, h.toggle(p))
                    nav
                }
                h.panel(p)
            }
            .id("kf-\(p.rawValue)")
        } else {
            slider()
        }
    }

    // MARK: 变换

    @ViewBuilder
    private var transformSection: some View {
        if mirrorH != nil || mirrorV != nil || rotation != nil
            || posX != nil || scaleW != nil || cropTop != nil {
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
                    kfRow(.angle) {
                        ISlider(label: "旋转", value: Binding(
                            get: {
                                let v = r.wrappedValue.truncatingRemainder(dividingBy: 360)
                                return v < 0 ? v + 360 : v
                            },
                            set: { r.wrappedValue = $0 }
                        ), range: 0...360, unit: "°")
                    }
                }
                // 三级分组
                positionSection
                scaleSection
                cropSection
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
            IFoldGroup(title: "位置", trailing: {
                if let center = onCenter {
                    headerButton("居中") { onBeforeChange?(); center() }
                }
            }) {
                kfRow(.offsetX) { ISlider(label: "水平位置", value: x, range: 0...100, unit: "%") }
                kfRow(.offsetY) { ISlider(label: "垂直位置", value: y, range: 0...100, unit: "%") }
            }
        }
    }

    // MARK: 缩放

    @ViewBuilder
    private var scaleSection: some View {
        if let w = scaleW, let h = scaleH {
            IFoldGroup(title: "缩放", trailing: {
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
            }) {
                // 锁着就只给一个滑块（拖它宽高一起走），解开才拆成两条
                if lockAspect?.wrappedValue ?? false {
                    // 锁着的时候拖一条，宽高按**原来的比例**一起走，
                    // 直接把两个值设成一样会把非等比的元素拉方
                    // 锁着时这一条代表宽高两个，关键帧挂在「宽」上（打帧时宽高成对打）
                    kfRow(.scaleX) {
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
                    }
                } else {
                    kfRow(.scaleX) {
                        ISlider(label: scaleLabels.w, value: w, range: scaleRange,
                                unit: scaleUnit)
                    }
                    kfRow(.scaleY) {
                        ISlider(label: scaleLabels.h, value: h, range: scaleRange,
                                unit: scaleUnit)
                    }
                }
            }
        }
    }

    // MARK: 裁剪

    @ViewBuilder
    private var cropSection: some View {
        if let t = cropTop, let b = cropBottom, let l = cropLeft, let r = cropRight {
            IFoldGroup(title: "裁剪", trailing: {
                headerButton("重置") {
                    onBeforeChange?()
                    t.wrappedValue = 0; b.wrappedValue = 0
                    l.wrappedValue = 0; r.wrappedValue = 0
                }
            }) {
                kfRow(.cropTop)    { ISlider(label: "上", value: t, range: 0...95, unit: "%") }
                kfRow(.cropBottom) { ISlider(label: "下", value: b, range: 0...95, unit: "%") }
                kfRow(.cropLeft)   { ISlider(label: "左", value: l, range: 0...95, unit: "%") }
                kfRow(.cropRight)  { ISlider(label: "右", value: r, range: 0...95, unit: "%") }
            }
        }
    }

    // MARK: 外观

    @ViewBuilder
    private var appearanceSection: some View {
        if opacity != nil || cornerRadius != nil {
            ISection(title: "外观") {
                if let o = opacity {
                    kfRow(.opacity) { ISlider(label: "不透明度", value: o, range: 0...100, unit: "%") }
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


// MARK: - 调节参数（片段属性区和调节轨道共用这一份）

/// 十一个调节滑块。**两个入口同一套控件**：
/// 片段属性区里挂在某一个片段上（默认折叠），调节轨道上覆盖一段时间的所有画面（默认展开）
struct AdjustSliders: View {
    @Binding var adjust: ColorAdjust
    /// 折叠态由外面给，两个入口的默认值不一样
    @State var expanded: Bool
    let onChange: () -> Void
    /// 每个滑块后面的附加控件（视频片段放关键帧 `< ◇ >`）。nil = 不放
    var rowAccessory: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil
    /// 每个滑块**下面**的附加内容（视频片段放展开的曲线面板）
    var rowBelow: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil
    /// 每个滑块标签**前面**的小控件（视频片段放曲线面板的展开箭头）
    var rowLeading: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil

    /// 变了就展开（外面要滚到某一行时先展开）
    var expandSignal: Int = 0
    /// 每一行的滚动锚点 id
    var rowAnchor: ((WritableKeyPath<ColorAdjust, Double>) -> String?)? = nil

    init(adjust: Binding<ColorAdjust>, expandedByDefault: Bool,
         expandSignal: Int = 0,
         rowAnchor: ((WritableKeyPath<ColorAdjust, Double>) -> String?)? = nil,
         rowAccessory: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil,
         rowLeading: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil,
         rowBelow: ((WritableKeyPath<ColorAdjust, Double>) -> AnyView?)? = nil,
         onChange: @escaping () -> Void) {
        self._adjust = adjust
        // 面板刚建出来时信号就已经在了（点关键帧时属性区从「项目」换成「视频」），onChange 等不到，直接展开
        self._expanded = State(initialValue: expandedByDefault || expandSignal != 0)
        self.expandSignal = expandSignal
        self.rowAnchor = rowAnchor
        self.rowAccessory = rowAccessory
        self.rowLeading = rowLeading
        self.rowBelow = rowBelow
        self.onChange = onChange
    }

    private var isNeutral: Bool { adjust.isIdentity }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        // 实心三角，跟属性区其他分组的折叠图标一样
                        IFoldTriangle(folded: !expanded)
                        Text("调节")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.2)
                    }
                    .foregroundColor(Color.labelPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    adjust = .identity
                    onChange()
                } label: {
                    Text("重置")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isNeutral ? Color.labelSecondary : .black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isNeutral ? Color.white.opacity(0.08) : Color(hex: "#E8A54B"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isNeutral)
            }

            if expanded {
                group("基础")
                slider("亮度", \.brightness, -1...1)
                slider("对比", \.contrast, -1...1)
                slider("饱和", \.saturation, -1...1)
                slider("自然饱和", \.vibrance, -1...1)

                group("光影")
                slider("曝光", \.exposure, -2...2)
                slider("伽马", \.gamma, 0.25...4)
                slider("高光", \.highlight, -1...1)
                slider("阴影", \.shadow, -1...1)

                group("色彩")
                slider("色温", \.temperature, -1...1)
                slider("色调", \.tint, -1...1)
                slider("色相", \.hue, -180...180, decimals: 0, unit: "°")
            }
        }
        .onChange(of: expandSignal) { sig in if sig != 0 { expanded = true } }
    }

    private func group(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color.labelSecondary)
            .padding(.top, 2)
    }

    private func slider(_ label: String, _ kp: WritableKeyPath<ColorAdjust, Double>,
                        _ range: ClosedRange<Double>,
                        decimals: Int = 2, unit: String = "") -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ICapsuleSlider(label: label, value: $adjust[dynamicMember: kp], range: range,
                               decimals: decimals, unit: unit, onChange: { _ in onChange() })
                    .environment(\.capsuleSliderLeading, rowLeading?(kp))
                if let acc = rowAccessory?(kp) { acc }
            }
            if let below = rowBelow?(kp) { below }
        }
        .id(rowAnchor?(kp) ?? label)
    }
}

/// 属性区的宽度范围。
///
/// 下限不是随便定的：视频面板的「速度」那一组是五个预设按钮并排，
/// 再窄就摆不下，内容会溢出容器、左边一整列被裁掉（按钮和滑块标签都缺一截）。
/// 图片、文字那些面板的控件都能压缩，所以看不出问题 —— 下限得按最挤的那个面板定
enum InspectorLayout {
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 450
    static let defaultWidth: CGFloat = 300
}

// MARK: - 关键帧导航 `< ◇ >`

/// 属性分区标题右侧的关键帧控件：左右跳到上一帧 / 下一帧，中间的菱形在播放头处打 / 删关键帧。
/// 自己盯着播放时钟（只有这一小块跟着播放头刷新，属性区其余部分不受影响）
struct KeyframeNav: View {
    @ObservedObject var clock: PlaybackClock
    /// 这组关键帧在时间轴上的位置（升序）
    let times: [Double]
    /// 片段在时间轴上的范围，播放头在外面时菱形不可点
    let clipStart: Double
    let clipEnd: Double
    let onToggle: () -> Void

    private let snap = 0.02
    private let accent = Color(hex: "#E8A54B")
    @State private var hovering = false

    var body: some View {
        let now = clock.currentTime
        let onFrame = times.contains { abs($0 - now) <= snap }
        let prev = times.last { $0 < now - snap }
        let next = times.first { $0 > now + snap }
        let inClip = now >= clipStart - snap && now <= clipEnd + snap
        HStack(spacing: 0) {
            arrow("chevron.left", target: prev)
            Button(action: onToggle) {
                let hot = hovering && inClip
                ZStack {
                    // 悬停时空菱形变成灰色实心、里面白「+」（点了打一帧）；
                    // 黄菱形里显示「−」（点了删掉）
                    Image(systemName: onFrame || hot ? "diamond.fill" : "diamond")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(onFrame ? accent
                                         : hot ? Color.white.opacity(0.35)
                                         : (times.isEmpty ? Color.labelSecondary : Color.labelPrimary))
                    if hot {
                        Text(onFrame ? "−" : "+")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundColor(onFrame ? .black : .white)
                            .offset(y: -0.5)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inClip)
            .opacity(inClip ? 1 : 0.35)
            .onHover { hovering = $0 }
            .help(onFrame ? "删除关键帧" : "添加关键帧")
            arrow("chevron.right", target: next)
        }
    }

    private func arrow(_ icon: String, target: Double?) -> some View {
        Button {
            guard let t = target else { return }
            clock.currentTime = t
            clock.seekRequest += 1
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.3 : 1)
        .help(icon == "chevron.left" ? "上一个关键帧" : "下一个关键帧")
    }
}

// MARK: - 关键帧控件工厂（图片面板用；视频面板自己有一份同样的）

/// 给某个片段生成三样关键帧控件：`< ◇ >`、曲线展开箭头、曲线面板
struct KeyframeControls {
    let project: ProjectState
    /// 当前片段（body 每次求值都传最新的进来）
    let clip: any KeyframeAnimatable
    /// 展开了曲线面板的属性。同一时间只开一个，锁着等比时宽高成对
    let easingOpen: Binding<Set<KeyframeProp>>

    func nav(_ p: KeyframeProp) -> AnyView? {
        guard clip.propValue(p) != nil else { return nil }
        let id = clip.id
        return AnyView(KeyframeNav(clock: project.clock, times: clip.keyframeTimelineTimes(p),
                                   clipStart: clip.startTime, clipEnd: clip.endTime) {
            project.toggleKeyframe(clipID: id, prop: p)
        })
    }

    /// 标签前的展开箭头（样子同转场分组）。这个属性不到两帧就不出现（一帧没有「两帧之间」可调）
    func toggle(_ p: KeyframeProp) -> AnyView? {
        guard (clip.keyframes?.frames(p).count ?? 0) >= 2 else { return nil }
        let open = easingOpen.wrappedValue.contains(p)
        let pair: Set<KeyframeProp> = clip.lockAspect && (p == .scaleX || p == .scaleY) ? [.scaleX, .scaleY] : [p]
        let binding = easingOpen
        return AnyView(
            Button {
                binding.wrappedValue = open ? binding.wrappedValue.subtracting(pair) : pair
            } label: {
                Image(nsImage: SidebarSVGIcon.load(open ? "groupExpanded" : "groupCollapsed", size: 9))
                    .renderingMode(.template)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 10, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "收起曲线" : "调节这一段的变化曲线")
        )
    }

    func panel(_ p: KeyframeProp) -> AnyView {
        guard easingOpen.wrappedValue.contains(p), (clip.keyframes?.frames(p).count ?? 0) >= 2 else { return AnyView(EmptyView()) }
        return AnyView(KeyframeEasingPanel(clock: project.clock, clipID: clip.id, prop: p))
    }

    var hooks: LayerKeyframeHooks {
        LayerKeyframeHooks(nav: nav, toggle: toggle, panel: panel)
    }
}
