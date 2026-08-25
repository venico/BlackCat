import SwiftUI

/// 卡片上的裁剪框（v5.1.0，B5）
///
/// 点操作栏的「裁剪」之后，直接在卡片上拉框选区域，回车/点勾确认。
/// 四角 + 四边都能拖，跟预览区那套控制框一个手感。
///
/// 热区 10pt —— 跟预览区控制框统一。做宽了会把下层内容的点击也吃掉（那边踩过）。
struct CanvasCropOverlay: View {
    @ObservedObject var canvas: CanvasState
    let node: CanvasNode
    /// 裁剪框（0~1 的相对坐标，相对卡片）
    @Binding var rect: CGRect
    var onConfirm: () -> Void
    var onCancel: () -> Void

    private static let handleHit: CGFloat = 10

    /// 这一次拖拽开始时的框。
    ///
    /// **必须记这个快照**：`DragGesture.translation` 是相对手势起点的**累计**位移，
    /// 而 `rect` 每帧都被改。拿当前 rect 再加一次完整位移，等于把位移一遍遍累加 ——
    /// 框先加速冲出去、撞到边界被 clamp 卡住，鼠标再动它也不动，
    /// 表现就是「不跟鼠标」。一律以起始框为基准算
    @State private var dragStartRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let frame = CGRect(x: rect.minX * w, y: rect.minY * h,
                               width: rect.width * w, height: rect.height * h)
            ZStack {
                // 框外压暗，一眼看出留哪块
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.accent, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)

                // 三分线
                Path { p in
                    for i in 1...2 {
                        let x = frame.minX + frame.width * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: frame.minY))
                        p.addLine(to: CGPoint(x: x, y: frame.maxY))
                        let y = frame.minY + frame.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: frame.minX, y: y))
                        p.addLine(to: CGPoint(x: frame.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                .allowsHitTesting(false)

                // 整体拖动
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: max(0, frame.width - Self.handleHit * 2),
                           height: max(0, frame.height - Self.handleHit * 2))
                    .position(x: frame.midX, y: frame.midY)
                    .gesture(moveGesture(size: geo.size))

                // 四角
                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(at: corner.point(in: frame))
                        .gesture(cornerGesture(corner, size: geo.size))
                }

                // 确认 / 取消
                HStack(spacing: 8) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                    Button(action: onConfirm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accent))
                    }
                    .buttonStyle(.plain)
                }
                .position(x: frame.midX, y: min(h - 20, frame.maxY + 22))
            }
        }
    }

    private func handle(at p: CGPoint) -> some View {
        Circle()
            .fill(Color.accent)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            // 视觉 9pt，热区 20pt —— 只按视觉大小做热区根本抓不住
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .position(p)
    }

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeading:     return CGPoint(x: r.minX, y: r.minY)
            case .topTrailing:    return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeading:  return CGPoint(x: r.minX, y: r.maxY)
            case .bottomTrailing: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let base = dragStartRect ?? rect
                if dragStartRect == nil { dragStartRect = rect }
                let dx = v.translation.width / size.width
                let dy = v.translation.height / size.height
                var r = base
                r.origin.x = min(max(0, base.minX + dx), 1 - base.width)
                r.origin.y = min(max(0, base.minY + dy), 1 - base.height)
                rect = r
            }
            .onEnded { _ in dragStartRect = nil }
    }

    /// 拖角。最小 10% —— 拖到 0 会裁出一张空图
    private func cornerGesture(_ corner: Corner, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                // 跟 moveGesture 同一个道理：基准是**起始框**，不是每帧变着的 rect
                let base = dragStartRect ?? rect
                if dragStartRect == nil { dragStartRect = rect }
                let dx = v.translation.width / size.width
                let dy = v.translation.height / size.height
                var r = base
                let minSide: CGFloat = 0.1
                switch corner {
                case .topLeading:
                    let nx = min(max(0, base.minX + dx), base.maxX - minSide)
                    let ny = min(max(0, base.minY + dy), base.maxY - minSide)
                    r = CGRect(x: nx, y: ny, width: base.maxX - nx, height: base.maxY - ny)
                case .topTrailing:
                    let nx = max(min(1, base.maxX + dx), base.minX + minSide)
                    let ny = min(max(0, base.minY + dy), base.maxY - minSide)
                    r = CGRect(x: base.minX, y: ny, width: nx - base.minX, height: base.maxY - ny)
                case .bottomLeading:
                    let nx = min(max(0, base.minX + dx), base.maxX - minSide)
                    let ny = max(min(1, base.maxY + dy), base.minY + minSide)
                    r = CGRect(x: nx, y: base.minY, width: base.maxX - nx, height: ny - base.minY)
                case .bottomTrailing:
                    let nx = max(min(1, base.maxX + dx), base.minX + minSide)
                    let ny = max(min(1, base.maxY + dy), base.minY + minSide)
                    r = CGRect(x: base.minX, y: base.minY, width: nx - base.minX, height: ny - base.minY)
                }
                rect = r
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
