import Foundation

// MARK: - 关键帧
//
// 关键帧按**单个属性**记：位置 X、位置 Y、宽、高、旋转、亮度……各管各的，
// 属性区每个滑块后面一个 `< ◇ >`。只给 X 打了关键帧，Y 还是普通的静态值。

struct Keyframe: Codable, Equatable, Hashable {
    /// 关键帧所在的时间。**单位由片段类型自己定**：视频片段存的是源素材秒数，
    /// 这样左边裁掉一段、从中间切开、变速，关键帧都还贴着原来那一帧画面
    var time: Double
    var value: Double
    /// 从这一帧到下一帧这段怎么过渡。nil = 线性
    var easing: KeyframeEasing? = nil
}

// MARK: - 区间缓动

/// 两个关键帧之间的过渡曲线。输入 0~1 的时间进度，输出 0~1 的数值进度（弹性会冲过 1 再回来）
struct KeyframeEasing: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        /// 三次贝塞尔，控制点 (x1,y1) (x2,y2)，同 CSS cubic-bezier
        case curve
        /// 弹性：冲过目标再回弹，`amount` 是第一下冲过去多少（0.25 = 冲出 25%）
        case elastic
        /// 弹跳：像球落地弹几下
        case bounce
    }
    var kind: Kind = .curve
    var x1 = 0.0, y1 = 0.0, x2 = 1.0, y2 = 1.0
    var amount = 0.25
    /// 延时：这一段开始后先停多久才动（**关键帧时间单位**，视频片段是源素材秒数）。nil = 不延时
    var delay: Double? = nil
    /// 用户选了「自定义」（值碰巧跟某个预设一样也算自定义）
    var isCustom: Bool? = nil

    static let linear     = KeyframeEasing()
    static let easeIn     = KeyframeEasing(kind: .curve, x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let easeOut    = KeyframeEasing(kind: .curve, x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeInOut  = KeyframeEasing(kind: .curve, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static func elastic(_ a: Double) -> KeyframeEasing { KeyframeEasing(kind: .elastic, amount: a) }
    static let bounce     = KeyframeEasing(kind: .bounce)

    /// 跟什么都没设一样（存档里就不存它）
    var isLinear: Bool {
        kind == .curve && abs(x1) < 1e-6 && abs(y1) < 1e-6 && abs(x2 - 1) < 1e-6 && abs(y2 - 1) < 1e-6
            && (delay ?? 0) < 1e-9 && isCustom != true
    }

    func apply(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch kind {
        case .curve:   return Self.cubicBezier(t, x1, y1, x2, y2)
        case .elastic: return Self.elastic(t, amount: amount)
        case .bounce:  return Self.bounce(t)
        }
    }

    /// 贝塞尔：先按 x 反解出参数 u（牛顿迭代，不收敛再二分），再求 y
    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bx(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u }
        func by(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u }
        func dx(_ u: Double) -> Double {
            3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2)
        }
        var u = x
        for _ in 0..<8 {
            let e = bx(u) - x
            if abs(e) < 1e-7 { return by(u) }
            let d = dx(u)
            if abs(d) < 1e-6 { break }
            u -= e / d
        }
        var lo = 0.0, hi = 1.0
        u = x
        for _ in 0..<40 {
            let v = bx(u)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = u } else { hi = u }
            u = (lo + hi) / 2
        }
        return by(u)
    }

    /// 衰减余弦：第一个峰在 t≈0.32、冲出 `amount`，之后越晃越小；末尾补一点线性差值保证正好停在 1
    static func elastic(_ t: Double, amount: Double) -> Double {
        let a = min(0.95, max(0.01, amount))
        let w = Double.pi / 0.32
        let d = -w * log(a) / Double.pi
        func f(_ x: Double) -> Double { 1 - cos(w * x) * exp(-d * x) }
        return f(t) + t * (1 - f(1))
    }

    /// 弹跳（同常见的 easeOutBounce）
    static func bounce(_ t: Double) -> Double {
        let n = 7.5625, d = 2.75
        if t < 1 / d { return n * t * t }
        if t < 2 / d { let x = t - 1.5 / d; return n * x * x + 0.75 }
        if t < 2.5 / d { let x = t - 2.25 / d; return n * x * x + 0.9375 }
        let x = t - 2.625 / d
        return n * x * x + 0.984375
    }
}

/// 可以打关键帧的属性。rawValue 就是存档里的键，**改名会让老存档读不回**
enum KeyframeProp: String, CaseIterable, Codable {
    /// 文字字号（属性区里排在最前，所以放第一个）
    case fontSize
    case offsetX, offsetY, scaleX, scaleY, angle, opacity
    case cropTop, cropBottom, cropLeft, cropRight
    case brightness, contrast, saturation, vibrance
    case exposure, gamma, highlight, shadow
    case temperature, tint, hue
    /// 音量（1 = 100%）。视频、音频片段都有
    case volume

    /// 调节的哪一项（不是调节类属性返回 nil）
    var adjustKeyPath: WritableKeyPath<ColorAdjust, Double>? {
        switch self {
        case .brightness:  return \.brightness
        case .contrast:    return \.contrast
        case .saturation:  return \.saturation
        case .vibrance:    return \.vibrance
        case .exposure:    return \.exposure
        case .gamma:       return \.gamma
        case .highlight:   return \.highlight
        case .shadow:      return \.shadow
        case .temperature: return \.temperature
        case .tint:        return \.tint
        case .hue:         return \.hue
        default:           return nil
        }
    }

    /// 调节的某一项对应哪个属性
    static func adjust(_ kp: WritableKeyPath<ColorAdjust, Double>) -> KeyframeProp? {
        allCases.first { $0.adjustKeyPath == kp }
    }
}

struct ClipKeyframes: Codable, Equatable, Hashable {
    /// 属性名 → 按时间排好序的关键帧。用字典：以后加属性不用改存档结构
    var props: [String: [Keyframe]] = [:]

    var isEmpty: Bool { props.values.allSatisfy(\.isEmpty) }

    func frames(_ p: KeyframeProp) -> [Keyframe] { props[p.rawValue] ?? [] }

    func has(_ p: KeyframeProp) -> Bool { !(props[p.rawValue] ?? []).isEmpty }

    /// 某个时间点的取值。两帧之间线性过渡，第一帧之前 / 最后一帧之后保持端点值。
    /// 这个属性没有关键帧时返回 nil（用片段自己的静态值）
    func sample(_ p: KeyframeProp, at t: Double) -> Double? {
        let k = frames(p)
        guard let first = k.first, let last = k.last else { return nil }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        for i in 0..<(k.count - 1) where t < k[i + 1].time {
            let a = k[i], b = k[i + 1]
            let span = b.time - a.time
            // 延时：段首先停 d，剩下的时间里走完整条曲线
            let d = min(max(a.easing?.delay ?? 0, 0), span)
            let rest = span - d
            var f = rest > 1e-9 ? max(0, t - a.time - d) / rest : (t >= b.time ? 1 : 0)
            f = min(1, f)
            if let e = a.easing { f = e.apply(f) }
            return a.value + (b.value - a.value) * f
        }
        return last.value
    }

    /// 在 t 处写一帧：`tolerance` 以内已有的那帧就地改值，没有就插一帧
    mutating func upsert(_ p: KeyframeProp, at t: Double, value: Double, tolerance: Double) {
        var k = frames(p)
        if let i = k.firstIndex(where: { abs($0.time - t) <= tolerance }) {
            k[i].value = value
        } else {
            k.append(Keyframe(time: t, value: value))
            k.sort { $0.time < $1.time }
        }
        props[p.rawValue] = k
    }

    /// 这个属性在 t 处所在的那一段：返回段首那一帧的下标。
    /// 正好停在某一帧上时算它往后那段；停在最后一帧上算它前面那段；在第一帧之前 / 最后一帧之后返回 nil
    func segmentIndex(_ p: KeyframeProp, at t: Double, tolerance: Double) -> Int? {
        let k = frames(p)
        guard k.count >= 2 else { return nil }
        if abs(t - k[k.count - 1].time) <= tolerance { return k.count - 2 }
        for i in 0..<(k.count - 1) where t >= k[i].time - tolerance && t < k[i + 1].time - tolerance {
            return i
        }
        return nil
    }

    mutating func setEasing(_ p: KeyframeProp, index: Int, _ e: KeyframeEasing?) {
        var k = frames(p)
        guard k.indices.contains(index) else { return }
        k[index].easing = (e?.isLinear ?? true) ? nil : e
        props[p.rawValue] = k
    }

    /// 删掉 t 附近的那一帧。删光了整条移除（这个属性回到静态值）
    @discardableResult
    mutating func remove(_ p: KeyframeProp, at t: Double, tolerance: Double) -> Bool {
        var k = frames(p)
        guard let i = k.firstIndex(where: { abs($0.time - t) <= tolerance }) else { return false }
        k.remove(at: i)
        props[p.rawValue] = k.isEmpty ? nil : k
        return true
    }
}

/// 属性区正在调曲线的那一段（时间轴上这段连线变黄）
struct EasingSegmentRef: Equatable {
    var clipID: UUID
    var prop: KeyframeProp
    /// 段首那一帧在这个属性关键帧里的下标
    var index: Int
}

/// 剪贴板里的一个关键帧：哪个属性、离这批里最早那一刻多远（时间轴秒）、值、往后那段的曲线
struct KeyframeClipItem {
    var prop: KeyframeProp
    var dt: Double
    var value: Double
    var easing: KeyframeEasing?
}

/// 让属性区滚到某个属性那一行（选中关键帧时用）。seq 每次加一，同一个属性连点也能再触发
struct InspectorFocusRequest: Equatable {
    var prop: KeyframeProp
    var seq: Int
}

/// 时间轴上选中的那个关键帧菱形（片段 + 时间轴时间）。菱形把同一时刻各属性的帧合成一个，
/// 删除也是这一时刻的全删
struct KeyframeSelection: Equatable {
    var clipID: UUID
    var time: Double
}

// MARK: - 可打关键帧的片段

/// 片段类型实现这几条，就能用上面的整套：求值、编辑写回、打/删关键帧、上一帧/下一帧
protocol KeyframeAnimatable {
    var id: UUID { get }
    var keyframes: ClipKeyframes? { get set }
    var startTime: Double { get }
    var endTime: Double { get }
    /// 锁着等比时宽高的关键帧成对打、成对改
    var lockAspect: Bool { get }
    /// 时间轴走 1 秒，关键帧时间走多少（视频是变速倍率，图片是 1）
    var keyframeTimeScale: Double { get }
    /// 时间轴时间 → 关键帧时间
    func keyframeTime(atTimeline t: Double) -> Double
    /// 关键帧时间 → 时间轴时间
    func timelineTime(ofKeyframe k: Double) -> Double
    /// 这个属性现在的静态值（不看关键帧）。这类片段没有这个属性返回 nil
    func propValue(_ p: KeyframeProp) -> Double?
    mutating func setPropValue(_ p: KeyframeProp, _ v: Double)
}

extension KeyframeAnimatable {
    /// 判断「播放头在不在这一帧上」的容差：时间轴上半帧多一点（30fps）
    static var keyframeSnap: Double { 0.02 }

    /// 时间轴容差换算成关键帧时间的容差（视频变速时两边单位不一样）
    private func keyframeTolerance(atTimeline t: Double) -> Double {
        abs(keyframeTime(atTimeline: t + Self.keyframeSnap) - keyframeTime(atTimeline: t))
    }

    var hasKeyframes: Bool { !(keyframes?.isEmpty ?? true) }

    /// 播放头不在片段里时，关键帧打在离它最近的片段边上
    func clampedTimeline(_ t: Double) -> Double {
        min(max(t, startTime), max(startTime, endTime - 0.001))
    }

    /// 这一刻的样子：有关键帧的属性换成插值结果，其余原样
    func animated(atTimeline t: Double) -> Self {
        guard let kf = keyframes, !kf.isEmpty else { return self }
        var c = self
        let k = keyframeTime(atTimeline: t)
        for p in KeyframeProp.allCases {
            if let v = kf.sample(p, at: k), propValue(p) != nil { c.setPropValue(p, v) }
        }
        return c
    }

    /// 编辑写回。`edit` 改的是**这一刻**的样子（属性面板、预览手柄看到的都是它）：
    /// - 有关键帧的属性：值变了就在播放头处写一帧，片段自己的静态值不动
    /// - 没关键帧的属性：照旧改静态值
    mutating func applyAnimatedEdit(atTimeline t: Double, _ edit: (inout Self) -> Void) {
        guard let kf = keyframes, !kf.isEmpty else { edit(&self); return }
        let before = animated(atTimeline: t)
        var after = before
        edit(&after)
        var result = after
        var newKF = kf
        let tt = clampedTimeline(t)
        let k = keyframeTime(atTimeline: tt)
        let tol = keyframeTolerance(atTimeline: tt)
        for p in KeyframeProp.allCases where kf.has(p) {
            if let base = propValue(p) { result.setPropValue(p, base) }
            if let a = after.propValue(p), let b = before.propValue(p), abs(a - b) > 1e-9 {
                newKF.upsert(p, at: k, value: a, tolerance: tol)
            }
        }
        result.keyframes = newKF
        self = result
    }

    /// 播放头处这个属性有没有关键帧
    func hasKeyframe(_ p: KeyframeProp, atTimeline t: Double) -> Bool {
        let k = keyframeTime(atTimeline: t)
        let tol = keyframeTolerance(atTimeline: t)
        return keyframes?.frames(p).contains { abs($0.time - k) <= tol } ?? false
    }

    /// 中间那个菱形：有就删，没有就按这一刻的值打一帧
    mutating func toggleKeyframe(_ p: KeyframeProp, atTimeline t: Double) {
        let tt = clampedTimeline(t)
        if hasKeyframe(p, atTimeline: tt) {
            setKeyframe(p, atTimeline: tt, on: false)
        } else {
            setKeyframe(p, atTimeline: tt, on: true)
        }
    }

    /// 播放头处打上（on）或删掉（off）这个属性的关键帧。已经是那个状态就不动
    mutating func setKeyframe(_ p: KeyframeProp, atTimeline t: Double, on: Bool) {
        let tt = clampedTimeline(t)
        let k = keyframeTime(atTimeline: tt)
        let tol = keyframeTolerance(atTimeline: tt)
        var kf = keyframes ?? ClipKeyframes()
        let exists = hasKeyframe(p, atTimeline: tt)
        if on {
            guard !exists, let v = animated(atTimeline: tt).propValue(p) else { return }
            kf.upsert(p, at: k, value: v, tolerance: tol)
        } else {
            guard exists else { return }
            // 删光之后回到打关键帧之前的值：有关键帧期间的编辑都写进了帧里，静态值一直没动过
            kf.remove(p, at: k, tolerance: tol)
        }
        keyframes = kf.isEmpty ? nil : kf
    }

    /// 时间轴上拖动关键帧：`a` 处（时间轴时间）所有属性的关键帧一起挪到 `b`，`b` 夹在片段内
    mutating func moveKeyframes(fromTimeline a: Double, toTimeline b: Double) {
        moveKeyframes([(from: a, to: b)])
    }

    /// 一次挪好几处（多选拖动）。每一帧按**原来**的时间认领一次，挪完的不会被下一处再认领 ——
    /// 否则 A 挪到 B 原来的位置，再挪 B 时会把 A 一起带走
    mutating func moveKeyframes(_ moves: [(from: Double, to: Double)]) {
        guard var kf = keyframes, !moves.isEmpty else { return }
        let mapped = moves.map { m in
            (from: keyframeTime(atTimeline: m.from),
             to: keyframeTime(atTimeline: clampedTimeline(m.to)),
             tol: keyframeTolerance(atTimeline: m.from))
        }
        for (name, frames) in kf.props {
            var f = frames
            for i in f.indices {
                if let m = mapped.first(where: { abs(f[i].time - $0.from) <= $0.tol }) { f[i].time = m.to }
            }
            f.sort { $0.time < $1.time }
            kf.props[name] = f
        }
        keyframes = kf
    }

    /// 播放头所在的那一段（段首帧下标 + 两端在时间轴上的位置）。不在两帧之间返回 nil
    func keyframeSegment(_ p: KeyframeProp, atTimeline t: Double) -> (index: Int, from: Double, to: Double)? {
        guard let kf = keyframes,
              let i = kf.segmentIndex(p, at: keyframeTime(atTimeline: t), tolerance: keyframeTolerance(atTimeline: t))
        else { return nil }
        let f = kf.frames(p)
        return (i, timelineTime(ofKeyframe: f[i].time), timelineTime(ofKeyframe: f[i + 1].time))
    }

    /// 曲线面板调的那一段：播放头在两帧之间就是那段；在第一帧之前算第一段、最后一帧之后算最后一段。
    /// 不到两帧返回 nil
    func editableKeyframeSegment(_ p: KeyframeProp, atTimeline t: Double) -> (index: Int, from: Double, to: Double)? {
        if let s = keyframeSegment(p, atTimeline: t) { return s }
        let ts = keyframeTimelineTimes(p)
        guard ts.count >= 2 else { return nil }
        return t < ts[0] ? (0, ts[0], ts[1]) : (ts.count - 2, ts[ts.count - 2], ts[ts.count - 1])
    }

    /// 在 t 处写一帧（已有就改值）。value 为 nil 时取这一刻原本的值；easing 是从这一帧往后那段的过渡
    mutating func putKeyframe(_ p: KeyframeProp, atTimeline t: Double, value: Double?, easing: KeyframeEasing?) {
        guard let v = value ?? animated(atTimeline: clampedTimeline(t)).propValue(p) else { return }
        let tt = clampedTimeline(t)
        let k = keyframeTime(atTimeline: tt)
        let tol = keyframeTolerance(atTimeline: tt)
        var kf = keyframes ?? ClipKeyframes()
        kf.upsert(p, at: k, value: v, tolerance: tol)
        if let e = easing, let i = kf.frames(p).firstIndex(where: { abs($0.time - k) <= tol }) {
            kf.setEasing(p, index: i, e)
        }
        keyframes = kf
    }

    /// 这个属性的关键帧在时间轴上的位置（升序）
    func keyframeTimelineTimes(_ p: KeyframeProp) -> [Double] {
        (keyframes?.frames(p) ?? []).map { timelineTime(ofKeyframe: $0.time) }.sorted()
    }

    /// 所有属性的关键帧在时间轴上的位置（去重，时间轴上画菱形用）
    func allKeyframeTimelineTimes() -> [Double] {
        var out: [Double] = []
        for p in KeyframeProp.allCases {
            for t in keyframeTimelineTimes(p) where !out.contains(where: { abs($0 - t) < Self.keyframeSnap }) {
                out.append(t)
            }
        }
        return out.sorted()
    }
}

// MARK: - 入点（图片 / 文字 / 图形共用）

/// 没有素材入点的片段，自己记一个关键帧入点 `kfIn`
protocol KeyframeInPoint: KeyframeAnimatable {
    var kfIn: Double? { get set }
}

extension KeyframeInPoint {
    var keyframeTimeScale: Double { 1 }
    func keyframeTime(atTimeline t: Double) -> Double { t - startTime + (kfIn ?? 0) }
    func timelineTime(ofKeyframe k: Double) -> Double { startTime + k - (kfIn ?? 0) }

    /// 起点往后挪 d 秒但内容不动（左边裁掉 / 切开后的右半段）：入点跟着挪，关键帧不跑位
    mutating func shiftKeyframeIn(by d: Double) {
        guard keyframes != nil else { return }
        kfIn = (kfIn ?? 0) + d
    }
}

// MARK: - 文字片段

extension TextClip: KeyframeInPoint {
    /// 文字的「缩放」是范围框，不打关键帧；字号单独一项
    var lockAspect: Bool { false }

    func propValue(_ p: KeyframeProp) -> Double? {
        switch p {
        case .fontSize:   return Double(fontSize)
        case .offsetX:    return posX
        case .offsetY:    return posY
        case .angle:      return rotation
        case .opacity:    return opacity
        case .cropTop:    return cropTop
        case .cropBottom: return cropBottom
        case .cropLeft:   return cropLeft
        case .cropRight:  return cropRight
        default:          return nil
        }
    }

    mutating func setPropValue(_ p: KeyframeProp, _ v: Double) {
        switch p {
        case .fontSize:   fontSize = CGFloat(max(1, v))
        case .offsetX:    posX = v
        case .offsetY:    posY = v
        case .angle:      rotation = v
        case .opacity:    opacity = min(1, max(0, v))
        case .cropTop:    cropTop = v
        case .cropBottom: cropBottom = v
        case .cropLeft:   cropLeft = v
        case .cropRight:  cropRight = v
        default:          break
        }
    }
}

// MARK: - 图形片段

extension ShapeClip: KeyframeInPoint {
    func propValue(_ p: KeyframeProp) -> Double? {
        switch p {
        case .offsetX:    return posX
        case .offsetY:    return posY
        case .scaleX:     return scaleX
        case .scaleY:     return scaleY
        case .angle:      return rotation
        case .opacity:    return opacity
        case .cropTop:    return cropTop
        case .cropBottom: return cropBottom
        case .cropLeft:   return cropLeft
        case .cropRight:  return cropRight
        default:          return nil
        }
    }

    mutating func setPropValue(_ p: KeyframeProp, _ v: Double) {
        switch p {
        case .offsetX:    posX = v
        case .offsetY:    posY = v
        case .scaleX:     scaleX = v
        case .scaleY:     scaleY = v
        case .angle:      rotation = v
        case .opacity:    opacity = min(1, max(0, v))
        case .cropTop:    cropTop = v
        case .cropBottom: cropBottom = v
        case .cropLeft:   cropLeft = v
        case .cropRight:  cropRight = v
        default:          break
        }
    }
}

// MARK: - 图片片段

extension ImageClip: KeyframeInPoint {

    func propValue(_ p: KeyframeProp) -> Double? {
        if let kp = p.adjustKeyPath { return colorAdjust[keyPath: kp] }
        switch p {
        case .offsetX:    return offsetX
        case .offsetY:    return offsetY
        case .scaleX:     return scaleX
        case .scaleY:     return scaleY
        case .angle:      return rotation
        case .opacity:    return alpha
        case .cropTop:    return cropTop
        case .cropBottom: return cropBottom
        case .cropLeft:   return cropLeft
        case .cropRight:  return cropRight
        default:          return nil
        }
    }

    mutating func setPropValue(_ p: KeyframeProp, _ v: Double) {
        if let kp = p.adjustKeyPath { colorAdjust[keyPath: kp] = v; return }
        switch p {
        case .offsetX:    offsetX = v
        case .offsetY:    offsetY = v
        case .scaleX:     scaleX = v
        case .scaleY:     scaleY = v
        case .angle:      rotation = v
        case .opacity:    opacity = min(1, max(0, v))
        case .cropTop:    cropTop = v
        case .cropBottom: cropBottom = v
        case .cropLeft:   cropLeft = v
        case .cropRight:  cropRight = v
        default:          break
        }
    }
}

// MARK: - 音频片段

extension AudioClip: KeyframeAnimatable {
    /// 只有音量能打关键帧，没有宽高
    var lockAspect: Bool { false }
    var keyframeTimeScale: Double { max(0.01, speed) }

    /// 同视频：存源素材秒数，裁剪 / 切开 / 变速后关键帧还贴着原来那一处声音
    func keyframeTime(atTimeline t: Double) -> Double {
        trimStart + (t - startTime) * max(0.01, speed)
    }

    func timelineTime(ofKeyframe k: Double) -> Double {
        startTime + (k - trimStart) / max(0.01, speed)
    }

    func propValue(_ p: KeyframeProp) -> Double? {
        p == .volume ? Double(volume) : nil
    }

    mutating func setPropValue(_ p: KeyframeProp, _ v: Double) {
        if p == .volume { volume = Float(max(0, v)) }
    }
}

// MARK: - 视频片段

extension VideoClip: KeyframeAnimatable {
    var keyframeTimeScale: Double { max(0.01, speed) }

    /// 存的是源素材秒数：左边裁掉一段、从中间切开、变速，关键帧都跟着画面走
    func keyframeTime(atTimeline t: Double) -> Double {
        trimStart + (t - startTime) * max(0.01, speed)
    }

    func timelineTime(ofKeyframe k: Double) -> Double {
        startTime + (k - trimStart) / max(0.01, speed)
    }

    func propValue(_ p: KeyframeProp) -> Double? {
        if let kp = p.adjustKeyPath { return colorAdjust[keyPath: kp] }
        switch p {
        case .offsetX:    return offsetX
        case .offsetY:    return offsetY
        case .scaleX:     return scaleX
        case .scaleY:     return scaleY
        case .angle:      return angleDeg
        case .opacity:    return alpha
        case .cropTop:    return cropTop
        case .cropBottom: return cropBottom
        case .cropLeft:   return cropLeft
        case .cropRight:  return cropRight
        case .volume:     return Double(volume)
        default:          return nil
        }
    }

    mutating func setPropValue(_ p: KeyframeProp, _ v: Double) {
        if let kp = p.adjustKeyPath { colorAdjust[keyPath: kp] = v; return }
        switch p {
        case .volume:     volume = Float(max(0, v))
        case .offsetX:    offsetX = v
        case .offsetY:    offsetY = v
        case .scaleX:     scaleX = v
        case .scaleY:     scaleY = v
        case .angle:      angle = v
        case .opacity:    opacity = min(1, max(0, v))
        case .cropTop:    cropTop = v
        case .cropBottom: cropBottom = v
        case .cropLeft:   cropLeft = v
        case .cropRight:  cropRight = v
        default:          break
        }
    }
}

// MARK: - 音量曲线 → 混音

import AVFoundation

enum VolumeCurve {
    /// 片段音量随时间的取样点（时间轴秒，音量倍数）。没打音量关键帧返回 nil，照旧用静态音量。
    /// 关键帧范围内每 0.05 秒取一个点（曲线、弹性这些非线性过渡也跟得上），范围外音量不变只要两头
    static func points(for clip: any KeyframeAnimatable, start: Double, duration: Double) -> [(t: Double, v: Float)]? {
        guard let kf = clip.keyframes, kf.has(.volume), duration > 0.001 else { return nil }
        let ts = clip.keyframeTimelineTimes(.volume)
        let end = start + duration
        let lo = max(start, (ts.first ?? start) - 0.001), hi = min(end, (ts.last ?? end) + 0.001)
        var times: [Double] = [start, end]
        if hi > lo {
            var t = lo
            while t < hi { times.append(t); t += 0.05 }
            times.append(hi)
        }
        times += ts.filter { $0 > start && $0 < end }
        times.sort()
        var out: [(Double, Float)] = []
        for t in times where out.last.map({ t - $0.0 > 1e-4 }) ?? true {
            let v = clip.animated(atTimeline: t).propValue(.volume) ?? 1
            out.append((t, Float(max(0, v))))
        }
        return out
    }

    /// 按曲线写进混音参数，叠上淡入淡出（两者相乘）。音量 ramp 必须按时间递增、不重叠
    static func apply(_ p: AVMutableAudioMixInputParameters, points: [(t: Double, v: Float)],
                      start: Double, duration: Double, fadeIn: Double, fadeOut: Double) {
        let end = start + duration
        func fade(_ t: Double) -> Float {
            var f: Double = 1
            if fadeIn > 0.001 { f = min(f, max(0, (t - start) / fadeIn)) }
            if fadeOut > 0.001 { f = min(f, max(0, (end - t) / fadeOut)) }
            return Float(f)
        }
        func vol(_ t: Double) -> Float {
            guard let first = points.first, let last = points.last else { return 1 }
            if t <= first.t { return first.v }
            if t >= last.t { return last.v }
            for i in 0..<(points.count - 1) where t <= points[i + 1].t {
                let a = points[i], b = points[i + 1]
                let f = b.t - a.t > 1e-9 ? Float((t - a.t) / (b.t - a.t)) : 0
                return a.v + (b.v - a.v) * f
            }
            return last.v
        }
        // 淡入淡出段也细分，乘出来的曲线才平滑
        var times = points.map(\.t)
        for (a, b) in [(start, start + fadeIn), (end - fadeOut, end)] where b - a > 0.001 {
            var t = a
            while t < b { times.append(t); t += 0.05 }
            times.append(b)
        }
        times = times.filter { $0 >= start - 1e-6 && $0 <= end + 1e-6 }.sorted()
        var last: Double?
        // 时间刻度用 44100：600 的话太近的两点会被取整成零长度的 ramp
        let ts: CMTimeScale = 44100
        for t in times {
            defer { if last == nil || t - last! > 0.001 { last = t } }
            guard let a = last, t - a > 0.001 else { continue }
            p.setVolumeRamp(fromStartVolume: vol(a) * fade(a), toEndVolume: vol(t) * fade(t),
                            timeRange: CMTimeRange(start: CMTime(seconds: a, preferredTimescale: ts),
                                                   end: CMTime(seconds: t, preferredTimescale: ts)))
        }
    }
}
