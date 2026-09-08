// LibraryFolderCard.swift
//
// 文件夹的那身皮：毛玻璃前盖 + 左凸右凹的后板 + 前盖里透出的内容颜色。
//
// **三处共用**：侧栏素材库、画布上的素材浏览器、聊天框里的「从素材库选择」。
// 抽出来之前只有侧栏有，另外两处是临时画的一个圆角方块加图标，
// 同一个文件夹在两个地方长得不一样。

import SwiftUI

struct LibraryFolderCard: View {

    let folder: LibraryFolder
    /// 前盖张不张开。侧栏是 hover / 拖拽落点时张开
    var open: Bool = false
    /// 露在文件夹口上的缩略图，最多三张。外面按各自的缓存取
    var peek: [NSImage] = []
    /// 里头有几样东西。0 就不显示角标
    var count: Int = 0

    var body: some View {
        let tint = folder.colorHex.map { Color(hex: $0) } ?? Color(white: 0.62)
        let back = FolderBackShape()
        let front = FolderFrontShape(openness: open ? 1 : 0)
    Color.clear
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay {
            GeometryReader { g in
                let w = g.size.width
                let h = g.size.height
                // 里面素材的缩略图，错开叠着。这一组画两遍：
                // 一遍露在前盖上头，一遍糊掉透在前盖里，当「隔着毛玻璃看见的颜色」
                let peekLayer = ZStack {
                    ForEach(Array(peek.enumerated().reversed()), id: \.offset) { i, img in
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w * 0.395, height: h * 0.393)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .rotationEffect(.degrees(Double(i - 1) * 7))
                            .offset(x: CGFloat(i - 1) * w * 0.112,
                                    y: CGFloat(i) * -h * 0.014)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                }
                .offset(y: -h * (open ? 0.388 : 0.302))

                ZStack(alignment: .bottom) {
                    // 最底层：后板。上沿**左凸右凹**，那道台阶就是文件夹的轮廓 ——
                    // 画成平顶矩形的话，空文件夹看着就是块光板
                    back
                        .fill(tint.opacity(0.22))
                        // 板面往下压暗：有明暗差才看得出这是块「凹进去」的板
                        .overlay(back.fill(LinearGradient(
                            colors: [.black.opacity(0.14), .black.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom)))
                        // 一圈微高光，上沿最亮
                        .overlay(back.stroke(LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                        .frame(width: w * 0.750, height: h * 0.714)
                        .offset(y: -h * 0.129)

                    // 中层：露在前盖上头的那截缩略图
                    peekLayer

                    // 前盖：**背景模糊**（毛玻璃），不是简单的半透明色块。
                    // 打开时上边往两侧长、同时下沉，下边钉死 —— 盖子朝外翻，立体感就来了
                    front
                        .fill(.ultraThinMaterial)
                        .frame(width: w * 0.80, height: h * 0.630)
                        // 隔着毛玻璃看见的那点颜色。
                        // **`.ultraThinMaterial` 办不到这件事**：SwiftUI 的 Material
                        // 采样的是自己背后的**窗口背景**，取不到 ZStack 里同层的兄弟视图，
                        // 前盖挡住的那几张缩略图它压根看不见，盖子就成了一块死色板。
                        // 所以把缩略图按**同一套坐标**再画一遍，糊掉再裁进前盖轮廓 ——
                        // 两边底边都对着 ZStack 的底，offset 直接沿用，位置天然对上
                        .overlay(alignment: .bottom) {
                            ZStack(alignment: .bottom) { peekLayer }
                                .frame(width: w * 0.80, height: h * 0.630)
                                .blur(radius: max(w * 0.055, 3))
                                .opacity(0.65)
                                .mask(front)
                                .allowsHitTesting(false)
                        }
                        .overlay(front.fill(tint.opacity(open ? 0.34 : 0.26)))
                        // 底部反光：光从下面反上来，越靠底越亮，过半高就没了
                        .overlay(front.fill(LinearGradient(
                            stops: [.init(color: .white.opacity(0),    location: 0.50),
                                    .init(color: .white.opacity(0.14), location: 1.00)],
                            startPoint: .top, endPoint: .bottom)))
                        // 一圈微高光：上沿最亮，侧面淡下去，底沿又亮回来一点
                        .overlay(front.stroke(LinearGradient(
                            colors: [.white.opacity(0.46), .white.opacity(0.10),
                                     .white.opacity(0.28)],
                            startPoint: .top, endPoint: .bottom), lineWidth: 0.9))
                        .overlay(alignment: .bottomLeading) {
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.leading, 11).padding(.bottom, 5)
                            }
                        }
                        .offset(y: open ? h * 0.043 : 0)
                        .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
                }
                .frame(width: w, height: h)
                .animation(.easeOut(duration: 0.16), value: open)
            }
        }
    }
}

/// 把一串顶点连成**曲率连续**的圆角多边形 —— iOS 那种「squircle」角。
///
/// `addArc(tangent1End:…)` 拐出来的是一段正圆弧：直线段曲率是 0、圆弧段是 1/r，
/// 交界处曲率**跳变**，小尺寸下眼睛能看出那道折痕。这里改成三次贝塞尔，
/// 把圆角摊到相邻两条边上（影响范围 1.42r，比正圆弧长四成），
/// 曲率从 0 慢慢长起来、过了顶点再落回 0，边和角之间没有接缝
///
/// - Parameter pts: 顶点 + 该顶点的圆角半径，按顺时针给
private func continuousRoundedPath(_ pts: [(CGPoint, CGFloat)]) -> Path {
    var path = Path()
    let n = pts.count
    guard n >= 3 else { return path }

    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
    /// 从 a 朝 b 走 d
    func step(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
        let len = max(dist(a, b), 0.0001)
        let t = min(d / len, 1)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    let spread: CGFloat = 1.42   // 圆角摊开多远。正圆弧是 1.0
    let grip: CGFloat = 0.62     // 控制点离顶点多近。越大角越紧

    // 每个顶点先算出进入点 / 离开点：沿两条边各退 spread·r，
    // 退的距离夹在边长一半以内，相邻两个角才不会打架
    var entry = [CGPoint](repeating: .zero, count: n)
    var exit  = [CGPoint](repeating: .zero, count: n)
    for i in 0..<n {
        let (c, r) = pts[i]
        let prev = pts[(i + n - 1) % n].0
        let next = pts[(i + 1) % n].0
        entry[i] = step(c, prev, min(r * spread, dist(c, prev) * 0.5))
        exit[i]  = step(c, next, min(r * spread, dist(c, next) * 0.5))
    }

    path.move(to: exit[0])
    for i in 1...n {
        let j = i % n
        let c = pts[j].0
        path.addLine(to: entry[j])
        // 两个控制点都落在「顶点—端点」的连线上：这样曲线在两端
        // 跟边**相切**，切完还能一路平滑地把曲率带过去
        path.addCurve(to: exit[j],
                      control1: step(entry[j], c, dist(entry[j], c) * grip),
                      control2: step(exit[j],  c, dist(exit[j],  c) * grip))
    }
    path.closeSubpath()
    return path
}

/// 文件夹后板：**左边一段高（那个标签），右边低**，中间斜着过渡 ——
/// 就是文件夹最认得出来的那个轮廓。
/// 四角和那道台阶的两个钝角全走曲率连续圆角，硬折角看着像贴纸、不像实体
private struct FolderBackShape: Shape {
    func path(in r: CGRect) -> Path {
        let cr = min(r.width, r.height) * 0.12    // 四角。比前盖收敛，窄板配大圆角显得胀
        let tabW = r.width * 0.30                 // 左边凸起占 3 成，右边低的那段占 7 成
        let drop = r.height * 0.12                // 右边比左边低多少
        let slope = r.width * 0.10                // 斜过渡多长
        let kr = min(drop, slope) * 0.85          // 台阶那两个钝角的圆角

        return continuousRoundedPath([
            (CGPoint(x: r.minX, y: r.minY), cr),                              // 左上
            (CGPoint(x: r.minX + tabW, y: r.minY), kr),                       // 台阶上拐点
            (CGPoint(x: r.minX + tabW + slope, y: r.minY + drop), kr),        // 台阶下拐点
            (CGPoint(x: r.maxX, y: r.minY + drop), cr),                       // 右上
            (CGPoint(x: r.maxX, y: r.maxY), cr),                              // 右下
            (CGPoint(x: r.minX, y: r.maxY), cr),                              // 左下
        ])
    }
}

/// 文件夹前盖。`openness` 从 0 到 1：0 是正面的圆角矩形，
/// 1 是**上宽下窄**的梯形 —— 盖子朝外翻开，底边离得远所以看着窄
private struct FolderFrontShape: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in r: CGRect) -> Path {
        // 底边钉死不动；顶边往两侧长出去、同时往下沉 ——
        // 盖子朝观察者倒下来，near 的那条边看着更宽更低
        let grow = r.width * 0.075 * openness
        let drop = r.height * 0.22 * openness
        let top = r.minY + drop
        let cr = min(r.width, r.height - drop) * 0.16

        return continuousRoundedPath([
            (CGPoint(x: r.minX - grow, y: top), cr),
            (CGPoint(x: r.maxX + grow, y: top), cr),
            (CGPoint(x: r.maxX, y: r.maxY), cr),
            (CGPoint(x: r.minX, y: r.maxY), cr),
        ])
    }
}

/// 侧栏里所有宫格共用的列。**封面宽度钉死**，富余的宽度全摊到列间距上，
/// 拖宽拉窄只加减列数，卡片本身一动不动。
///
/// 宽度取的是**外面传进来的侧栏宽**，不是自己量的：自己量会绕成一个环 ——
/// 列数算多了 → grid 变宽 → 把外面撑开 → 量到更大的宽度 → 列数更多，
/// 拉窄时列就再也减不回来
func sidebarGridColumns(sidebarWidth: CGFloat,
                        cell target: CGFloat = 128,
                        minGap: CGFloat) -> [GridItem] {
    // 44 = 左侧图标栏，13 = grid 的 leading 3 + trailing 10
    let w = max(sidebarWidth - 44 - 13, 60)
    // 侧栏窄到一列都装不下时，卡片只好跟着缩
    let cell = min(target, w)
    let cols = max(1, Int((w + minGap) / (cell + minGap)))
    let gap = cols > 1
        ? max(minGap, (w - CGFloat(cols) * cell) / CGFloat(cols - 1))
        : minGap
    return Array(repeating: GridItem(.fixed(cell), spacing: gap), count: cols)
}
