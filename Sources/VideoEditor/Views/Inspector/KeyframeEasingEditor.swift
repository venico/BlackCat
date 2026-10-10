import SwiftUI

// MARK: - 关键帧区间缓动面板
//
// 属性区某个滑块展开后出现：调的是播放头所在的那一段（两个关键帧之间）。
// 「曲线」是三次贝塞尔，拖两个控制点；「弹性」是冲过头再回弹，上下拖峰值点改幅度。

/// 盯着播放头找当前那一段，把它的缓动交给编辑器；同时告诉时间轴这段要画成黄色
struct KeyframeEasingPanel: View {
    @EnvironmentObject private var project: ProjectState
    @ObservedObject var clock: PlaybackClock
    let clipID: UUID
    let prop: KeyframeProp

    private var clip: (any KeyframeAnimatable)? { project.keyframedClip(clipID) }

    var body: some View {
        let c = clip
        let seg = c?.editableKeyframeSegment(prop, atTimeline: clock.currentTime)
        Group {
            if let c, let seg, let frames = c.keyframes?.frames(prop), frames.indices.contains(seg.index) {
                let e = frames[seg.index].easing ?? .linear
                KeyframeEasingEditor(
                    easing: e,
                    duration: seg.to - seg.from,
                    delay: (e.delay ?? 0) / c.keyframeTimeScale,
                    onChange: { project.setKeyframeEasing(clipID: clipID, prop: prop, index: seg.index, $0) },
                    onDuration: { project.setKeyframeSegmentDuration(clipID: clipID, prop: prop, index: seg.index, seconds: $0) },
                    onDelay: { project.setKeyframeDelay(clipID: clipID, prop: prop, index: seg.index, seconds: $0) })
            }
            // 只有一帧时没有「两帧之间」可调，什么都不显示
        }
        .onAppear { publish(seg?.index) }
        .onChange(of: seg?.index) { i in publish(i) }
        .onDisappear {
            if project.editingEasing?.clipID == clipID, project.editingEasing?.prop == prop {
                project.editingEasing = nil
            }
        }
    }

    private func publish(_ index: Int?) {
        let ref = index.map { EasingSegmentRef(clipID: clipID, prop: prop, index: $0) }
        if project.editingEasing != ref { project.editingEasing = ref }
    }
}

/// 纯编辑器：给一份缓动，改了就回调
struct KeyframeEasingEditor: View {
    let easing: KeyframeEasing
    /// 这一段的时长 / 延时（时间轴秒）
    let duration: Double
    let delay: Double
    let onChange: (KeyframeEasing) -> Void
    let onDuration: (Double) -> Void
    let onDelay: (Double) -> Void

    private let accent = Color(hex: "#E8A54B")
    private let graphH: CGFloat = 130

    private var isElasticMode: Bool { easing.kind != .curve }

    var body: some View {
        // 行距跟属性区滑块之间一样（ISection 的 10）
        VStack(spacing: 10) {
            // 时长 / 延时一行两个，样子同「时间」那组的开始 / 持续
            HStack(spacing: 8) {
                IField(label: "时长（秒）") { secondsStepper(duration, min: 0.05, onDuration) }
                IField(label: "延时（秒）") { secondsStepper(delay, min: 0, onDelay) }
            }
            // 模式
            fieldRow("区间缓动") {
                IPicker(selection: Binding(
                    get: { isElasticMode ? 1 : 0 },
                    set: { m in
                        guard m != (isElasticMode ? 1 : 0) else { return }
                        var e: KeyframeEasing = m == 1 ? .elastic(0.25) : .linear
                        e.delay = easing.delay
                        onChange(e)
                    }), options: [(0, "曲线"), (1, "弹性")])
            }
            // 预设
            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { p in
                    let on = p.0 == activePreset
                    Button {
                        var e: KeyframeEasing
                        if let preset = p.1 {
                            e = preset
                        } else {
                            // 自定义：保留当前的值，只是标成自定义；弹跳没参数可调，换成弹性
                            e = easing
                            if e.kind == .bounce { e = .elastic(easing.amount) }
                            e.isCustom = true
                        }
                        e.delay = easing.delay
                        onChange(e)
                    } label: {
                        Text(p.0)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(on ? .black : Color.labelSecondary)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(on ? accent : Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            graph
            footer
        }
    }

    // MARK: 预设

    private var presets: [(String, KeyframeEasing?)] {
        isElasticMode
            ? [("轻度", .elastic(0.1)), ("中度", .elastic(0.25)), ("重度", .elastic(0.5)),
               ("弹跳", .bounce), ("自定义", nil)]
            : [("线性", .linear), ("缓入", .easeIn), ("缓出", .easeOut),
               ("缓入缓出", .easeInOut), ("自定义", nil)]
    }

    private var activePreset: String {
        if easing.isCustom == true { return "自定义" }
        for p in presets { if let e = p.1, close(e, easing) { return p.0 } }
        return "自定义"
    }

    private func close(_ a: KeyframeEasing, _ b: KeyframeEasing) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .curve:
            return abs(a.x1 - b.x1) < 0.005 && abs(a.y1 - b.y1) < 0.005
                && abs(a.x2 - b.x2) < 0.005 && abs(a.y2 - b.y2) < 0.005
        case .elastic: return abs(a.amount - b.amount) < 0.005
        case .bounce:  return true
        }
    }

    // MARK: 曲线图

    /// 纵轴范围：曲线留出控制点往外拉的余量，弹性留出冲过头的余量
    private var yRange: ClosedRange<Double> { isElasticMode ? -0.1...1.7 : -0.35...1.35 }

    private var graph: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 14, dy: 12)
            let pt = { (x: Double, y: Double) -> CGPoint in
                CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                        y: rect.maxY - CGFloat((y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)) * rect.height)
            }
            let inv = { (p: CGPoint) -> (Double, Double) in
                let x = Double((p.x - rect.minX) / max(rect.width, 1))
                let y = yRange.lowerBound + Double((rect.maxY - p.y) / max(rect.height, 1)) * (yRange.upperBound - yRange.lowerBound)
                return (x, y)
            }
            ZStack {
                Canvas { ctx, _ in
                    // 目标线（弹性才画：冲过头要有个参照）
                    if isElasticMode {
                        var g = Path(); g.move(to: pt(0, 1)); g.addLine(to: pt(1, 1))
                        ctx.stroke(g, with: .color(.white.opacity(0.18)), lineWidth: 1)
                    }
                    if easing.kind == .curve {
                        var h = Path()
                        h.move(to: pt(0, 0)); h.addLine(to: pt(easing.x1, easing.y1))
                        h.move(to: pt(1, 1)); h.addLine(to: pt(easing.x2, easing.y2))
                        ctx.stroke(h, with: .color(.white.opacity(0.3)), lineWidth: 1.5)
                    }
                    var c = Path()
                    let n = 80
                    for i in 0...n {
                        let x = Double(i) / Double(n)
                        let p = pt(x, easing.apply(x))
                        if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
                    }
                    ctx.stroke(c, with: .color(.white.opacity(0.9)), lineWidth: 2)
                }
                if easing.kind == .curve {
                    handle(at: pt(easing.x1, easing.y1)) { loc in
                        let (x, y) = inv(loc)
                        var e = easing; e.x1 = clamp01(x); e.y1 = clampY(y); e.isCustom = true; onChange(e)
                    }
                    handle(at: pt(easing.x2, easing.y2)) { loc in
                        let (x, y) = inv(loc)
                        var e = easing; e.x2 = clamp01(x); e.y2 = clampY(y); e.isCustom = true; onChange(e)
                    }
                } else if easing.kind == .elastic {
                    // 峰值点只能上下拖：高出目标线多少就是冲过头多少
                    handle(at: pt(0.32, KeyframeEasing.elastic(0.32, amount: easing.amount))) { loc in
                        let (_, y) = inv(loc)
                        var e = easing; e.amount = min(0.6, max(0.01, y - 1)); e.isCustom = true; onChange(e)
                    }
                }
            }
        }
        .frame(height: graphH)
        .background(Color.black.opacity(0.18))
        .cornerRadius(6)
    }

    private func handle(at p: CGPoint, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .stroke(accent, lineWidth: 2.5)
            .background(Circle().fill(Color(white: 0.12)))
            .frame(width: 11, height: 11)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .claimsDragFromWindow()
            .position(p)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onDrag(v.location) })
    }

    /// 标签 + 控件，控件一直撑到右边缘。不用 IFieldRow：它末尾那个 Spacer 前面还有一份间距，
    /// 控件右边会比预设按钮、曲线图短一截
    private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: ILayout.gap) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
                .frame(width: ILayout.labelWidth + ILayout.hPadding, alignment: .leading)
                .lineLimit(1)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func secondsStepper(_ v: Double, min lo: Double, _ set: @escaping (Double) -> Void) -> some View {
        MiniStepper(value: Binding(get: { v }, set: { set(Swift.max(lo, $0)) }),
                    step: 0.1, decimals: 2, minValue: lo, maxValue: 3600)
    }

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    private func clampY(_ v: Double) -> Double { min(yRange.upperBound, max(yRange.lowerBound, v)) }

    // MARK: 底部数值

    @ViewBuilder
    private var footer: some View {
        switch easing.kind {
        case .curve:
            Text(String(format: "%.2f, %.2f, %.2f, %.2f", easing.x1, easing.y1, easing.x2, easing.y2))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Color.labelPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Color.white.opacity(0.06)).cornerRadius(6)
        case .elastic:
            fieldRow("幅度") {
                MiniStepper(value: Binding(get: { easing.amount },
                                           set: { v in var e = easing; e.amount = min(0.6, max(0.01, v)); e.isCustom = true; onChange(e) }),
                            step: 0.05, decimals: 2, minValue: 0.01, maxValue: 0.6)
                    .frame(maxWidth: .infinity)
            }
        case .bounce:
            EmptyView()
        }
    }
}
