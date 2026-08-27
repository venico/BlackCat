// TransformBox.swift
//
// 预览区和封面弹窗里那个选中框。图片、文字、图形**共用这一个** ——
// 四角圆点缩放、四边橙条裁剪、上方手柄旋转，三种元素一套手感。
//
// 组件只管几何和手势，改什么数据由外面的回调决定：
// 图片的缩放写 scaleX/scaleY、文字写 fontSize、图形写 scaleX/scaleY，
// 但对使用者来说都是「放大了多少倍」。
//
// 文字比另外两种多一个编辑态（双击出光标）：那时候裁剪条收起来，
// 改成直接拖四条边改文本框大小 —— 条要画在**框外面**，
// 框里是 NSTextView，压在它上面的鼠标事件会被它当成选文字全吃掉。
//
// 每个手柄都要 `.claimsDragFromWindow()`：预览区一直铺到窗口顶端，
// 落在顶部那 32pt 里的手柄不声明的话，按下去拖走的是整个窗口
// （详见 WindowDragGate.swift）。而且它和 onHover 都必须排在
// `.position()` **之前** —— position 之后视图占满整个容器，
// hover 区域就跟着变成整块预览区了

import SwiftUI
import AppKit

/// 四边的裁剪比例（0~1，从各边往里裁掉多少）
struct TransformCrop: Equatable {
    var top: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    var right: Double = 0

    var isEmpty: Bool { top <= 0 && bottom <= 0 && left <= 0 && right <= 0 }

    init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
}

/// 手柄的鼠标样式。旋转那个系统没有现成的，自己画一个
enum TransformCursor {
    static let rotate: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        guard let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
            return .arrow
        }
        // **符号图不能靠 `NSColor.set()` 上色** —— draw 会照它自己的原色画，
        // 之前那版设了颜色其实没生效，画出来还是原样。
        // 正确做法是先画图形，再用 sourceAtop 往非透明的地方灌颜色
        func tinted(_ color: NSColor) -> NSImage {
            let out = NSImage(size: sym.size)
            out.lockFocus()
            sym.draw(in: NSRect(origin: .zero, size: sym.size))
            color.set()
            NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
            out.unlockFocus()
            return out
        }
        let white = tinted(.white), black = tinted(.black)

        let pad: CGFloat = 3
        let size = NSSize(width: sym.size.width + pad * 2, height: sym.size.height + pad * 2)
        let img = NSImage(size: size)
        img.lockFocus()
        let r = NSRect(x: pad, y: pad, width: sym.size.width, height: sym.size.height)
        // 白色描一圈边打底，再压黑色本体 —— 跟旋转手柄上那个图标一个样子
        for dx in [-1.5, 0, 1.5] as [CGFloat] {
            for dy in [-1.5, 0, 1.5] as [CGFloat] {
                white.draw(in: r.offsetBy(dx: dx, dy: dy))
            }
        }
        black.draw(in: r)
        img.unlockFocus()
        img.isTemplate = false
        return NSCursor(image: img, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()
}

struct TransformBox: View {
    /// 完整框的中心（视图坐标，**裁剪之前**）
    let center: CGPoint
    /// 完整框的尺寸（视图坐标，裁剪之前）
    let size: CGSize
    let rotation: Double
    var crop = TransformCrop()

    /// 文字的编辑态：裁剪条收起来，四条边改成拖框大小
    var editing = false
    /// 线段、箭头这类没有面积的图形不给裁剪条
    var showEdgeBars = true
    /// 编辑态下不画边框（文字自己那圈输入框边框已经够了）
    var showBorder = true
    /// 外面已经套了多少度的 `rotationEffect`。
    /// 图片那层是整层一起转的（移动区和手柄必须在同一个坐标系里，
    /// 各转各的会打架），所以 `rotation` 传 0、几何按没转来算，
    /// 这个值只用来决定边条的鼠标样式是上下拉还是左右拉
    var outerRotation: Double = 0

    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    /// 四角缩放：相对起手位置放大了多少倍
    var onScale: (Double) -> Void = { _ in }
    /// 拖裁剪条：边序号（0上 1下 2左 3右）+ 该边新的裁剪比例
    var onCrop: (Int, Double) -> Void = { _, _ in }
    /// 旋转：相对起手转过多少度
    var onRotate: (Double) -> Void = { _ in }
    /// 编辑态拖边：边序号 + 鼠标位置（**转回框自己坐标系**、相对中心）
    var onEdgeResize: ((Int, CGPoint) -> Void)? = nil

    @State private var mode = 0          // 0=无 1=缩放 2=裁剪 3=旋转 4=改框
    @State private var startAngle = 0.0
    @State private var startCrop = TransformCrop()

    private let accent = Color.accent

    // MARK: 裁剪之后还露着的那块

    private var visibleSize: CGSize {
        CGSize(width: max(size.width * (1 - crop.left - crop.right), 8),
               height: max(size.height * (1 - crop.top - crop.bottom), 8))
    }

    private var visibleCenter: CGPoint {
        let off = rotate(size.width * (crop.left - crop.right) / 2,
                         size.height * (crop.top - crop.bottom) / 2,
                         rotation)
        return CGPoint(x: center.x + off.x, y: center.y + off.y)
    }

    var body: some View {
        let vs = visibleSize
        let vc = visibleCenter

        ZStack {
            if showBorder {
                Rectangle().stroke(accent, lineWidth: 1.5)
                    .frame(width: vs.width, height: vs.height)
                    .rotationEffect(.degrees(rotation))
                    .position(vc)
                    .allowsHitTesting(false)
            }

            // 四边：平时是裁剪条，编辑态换成整条边都能拖的宽条
            if showEdgeBars {
                ForEach(0..<4, id: \.self) { e in
                    let horiz = e < 2
                    if editing {
                        // 编辑态：**不另画条，就拖原来那圈框的边**。
                        // 热区贴着边线、主要落在框外侧 —— 框里是个 NSTextView，
                        // 压在它上面的鼠标事件会被它当成选文字全吃掉
                        // 热区以边线为中心、里外各 8pt。往框里那半边压在 NSTextView 上，
                        // 光标和拖动能不能生效由它说了算；外面那半边一定有效
                        let len = horiz ? vs.width : vs.height
                        Color.white.opacity(0.001)
                            .frame(width: horiz ? len + 16 : 16, height: horiz ? 16 : len + 16)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                cursorForEdge(e, hovering: hovering)
                            }
                            .claimsDragFromWindow()
                            .rotationEffect(.degrees(rotation))
                            .position(edgeMid(e, center: vc, size: vs))
                            .highPriorityGesture(edgeGesture(e))
                    } else {
                        let len = horiz ? min(vs.width * 0.4, 44) : min(vs.height * 0.4, 44)
                        edgeBar(horizontal: horiz, length: len)
                            .position(edgeMid(e, center: vc, size: vs))
                            .gesture(edgeGesture(e))
                    }
                }
            }

            // 四角缩放 + 旋转。编辑态只留四条边，别的都收起来
            if !editing {
                ForEach(0..<4, id: \.self) { i in
                    handleDot()
                        .position(corner(i, center: vc, size: vs))
                        .gesture(scaleGesture(center: vc))
                }

                rotHandle()
                    .position(rotateHandlePos(center: vc, size: vs))
                    .gesture(rotateGesture(center: vc))
            }
        }
    }

    // MARK: 手柄样子

    private func handleDot() -> some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 11, height: 11)
            Circle().stroke(accent, lineWidth: 1.5).frame(width: 11, height: 11)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onHover { if $0 { NSCursor.crosshair.set() } else { NSCursor.arrow.set() } }
        .claimsDragFromWindow()
    }

    private func rotHandle() -> some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 14, height: 14)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold)).foregroundColor(accent)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .onHover { if $0 { TransformCursor.rotate.set() } else { NSCursor.arrow.set() } }
        .claimsDragFromWindow()
    }

    private func edgeBar(horizontal: Bool, length: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Color.orange)
            .frame(width: horizontal ? length : 3, height: horizontal ? 3 : length)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            // 热区比视觉宽是为了好抓，但别宽过头：边条盖在别的图层上时，
            // 会把露在外面那一溜窄区也吃掉，导致点不中下层
            .frame(width: horizontal ? length + 8 : 10, height: horizontal ? 10 : length + 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                cursorForEdge(horizontal ? 0 : 2, hovering: hovering)
            }
            .claimsDragFromWindow()
            .rotationEffect(.degrees(rotation))
    }

    /// 边条的鼠标样式。框转过 90° 之后横条实际是在左右拉，光标要跟着换
    private func cursorForEdge(_ e: Int, hovering: Bool) {
        guard hovering else { NSCursor.arrow.set(); return }
        let quarter = Int(((rotation + outerRotation) / 90).rounded()) % 2 != 0
        let vertical = (e < 2) != quarter
        (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
    }

    // MARK: 位置计算

    private func rotate(_ dx: CGFloat, _ dy: CGFloat, _ deg: Double) -> CGPoint {
        let r = CGFloat(deg * .pi / 180)
        return CGPoint(x: dx * cos(r) - dy * sin(r), y: dx * sin(r) + dy * cos(r))
    }

    private func corner(_ i: Int, center c: CGPoint, size s: CGSize) -> CGPoint {
        let hw = s.width / 2, hh = s.height / 2
        let offs = [(-hw, -hh), (hw, -hh), (-hw, hh), (hw, hh)][i]
        let p = rotate(offs.0, offs.1, rotation)
        return CGPoint(x: c.x + p.x, y: c.y + p.y)
    }

    /// - Parameter outset: 往框外挪多少（编辑态用，避开框里的 NSTextView）
    private func edgeMid(_ e: Int, center c: CGPoint, size s: CGSize, outset: CGFloat = 0) -> CGPoint {
        let hw = s.width / 2 + outset, hh = s.height / 2 + outset
        let offs = [(0, -hh), (0, hh), (-hw, 0), (hw, 0)][e]
        let p = rotate(offs.0, offs.1, rotation)
        return CGPoint(x: c.x + p.x, y: c.y + p.y)
    }

    private func rotateHandlePos(center c: CGPoint, size s: CGSize) -> CGPoint {
        let p = rotate(0, -s.height / 2 - 26, rotation)
        return CGPoint(x: c.x + p.x, y: c.y + p.y)
    }

    // MARK: 手势

    private func scaleGesture(center c: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if mode != 1 { onBegin(); mode = 1 }
                let d0 = hypot(v.startLocation.x - c.x, v.startLocation.y - c.y)
                let d1 = hypot(v.location.x - c.x, v.location.y - c.y)
                guard d0 > 1 else { return }
                onScale(Double(d1 / d0))
            }
            .onEnded { _ in mode = 0; onEnd() }
    }

    private func rotateGesture(center c: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if mode != 3 {
                    onBegin(); mode = 3
                    startAngle = atan2(Double(v.startLocation.y - c.y),
                                       Double(v.startLocation.x - c.x)) * 180 / .pi
                }
                // 每帧都设一次：鼠标一离开手柄那 28pt，系统就把光标换回箭头了，
                // 转起来光标一闪一闪的
                TransformCursor.rotate.set()
                let cur = atan2(Double(v.location.y - c.y),
                                Double(v.location.x - c.x)) * 180 / .pi
                onRotate(cur - startAngle)
            }
            .onEnded { _ in mode = 0; NSCursor.arrow.set(); onEnd() }
    }

    /// 拖边。平时算裁剪比例，编辑态把局部坐标交给外面自己处理。
    /// 两种都先把鼠标位置**转回框自己的坐标系**，转过角度之后拖边才跟手
    private func edgeGesture(_ e: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let want = editing ? 4 : 2
                if mode != want { onBegin(); mode = want; startCrop = crop }
                let d = rotate(v.location.x - center.x, v.location.y - center.y, -rotation)

                if editing {
                    onEdgeResize?(e, d)
                    return
                }
                let w = size.width, h = size.height
                let value: Double
                switch e {
                case 0:  value = min(max(Double((d.y + h / 2) / h), 0), 1 - startCrop.bottom - 0.05)
                case 1:  value = min(max(Double((h / 2 - d.y) / h), 0), 1 - startCrop.top - 0.05)
                case 2:  value = min(max(Double((d.x + w / 2) / w), 0), 1 - startCrop.right - 0.05)
                default: value = min(max(Double((w / 2 - d.x) / w), 0), 1 - startCrop.left - 0.05)
                }
                onCrop(e, value)
            }
            .onEnded { _ in mode = 0; onEnd() }
    }
}
