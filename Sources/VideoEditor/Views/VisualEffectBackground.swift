// VisualEffectBackground.swift
// 系统材质背景。macOS 的「窗口底色跟着墙纸变」不是取色算出来的，
// 而是 NSVisualEffectView 在 .behindWindow 模式下**实时采样窗口后面的内容**
// （墙纸、别的 app 窗口）做模糊+染色——系统设置、访达、备忘录都是这套。
//
// 生效的两个前提，缺一个就退化成一块纯色：
//   1. 窗口必须 isOpaque = false 且 backgroundColor = .clear，
//      不然不透明的窗口底色直接盖住采样结果
//   2. 材质上层不能再压一层不透明的 Color，只能用半透明色叠色调
import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    /// 默认 .behindWindow：采样窗口后面。.withinWindow 是采样同窗口内更下层的内容，
    /// 用来做面板叠面板的层次，那种不会跟着墙纸变
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
        // 跟系统一致：窗口失焦时材质自动变淡（系统设置、访达都是这个行为）
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
        v.state = .followsWindowActiveState
    }
}

extension Color {
    /// 系统分隔线颜色。面板描边直接用这个常量，而不是自己调一个白色透明度——
    /// 它是动态色，随外观/对比度设置变，这才是「跟系统一样」
    static let systemSeparator = Color(nsColor: .separatorColor)
}

/// 面板描边。系统（Liquid Glass）那圈边不是一条均匀细线，是**顶亮底暗的渐变**——
/// 模拟光从上方打下来，所以上沿有明显高光、下沿几乎看不见。
/// 之前用 separatorColor 是均匀的、而且太暗，完全没有那种亮度感。
struct PanelBorder: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.38),
                                 Color.white.opacity(0.14),
                                 Color.white.opacity(0.07)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
        )
    }
}

/// 玻璃的压暗量。Liquid Glass 默认透得很厉害，浅色墙纸下整个界面会发白，
/// 这个 app 是深色主题，需要往下压。数值集中在这里，调一处全局生效
private let kGlassTint = Color.black.opacity(0.58)

/// 窗口最底层（面板之间的缝隙）的压暗量。材质本身没法调暗度，只能在它上面
/// 叠一层半透明黑。跟 kGlassTint 分开：底层要比面板更暗才拉得开层次
private let kWindowTint = Color.black.opacity(0.42)

/// 面板的两种角色，决定回退路径用哪档材质
enum PanelKind {
    case sidebar    // 素材栏、欢迎页侧栏
    case content    // 预览区、属性栏、时间轴、最近区

    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: return .sidebar
        case .content: return .contentBackground
        }
    }
}

extension View {
    /// 面板外观。macOS 26 及以上直接用系统的 Liquid Glass（glassEffect），
    /// 玻璃的折射、高光、边缘都由系统给，跟系统 app 天然一致；
    /// 26 以下回退到 NSVisualEffectView 材质 + 手工渐变描边这套近似实现。
    @ViewBuilder
    func panelSurface(_ kind: PanelKind = .content, cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(kGlassTint), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(VisualEffectBackground(material: kind.material))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .panelBorder(cornerRadius: cornerRadius)
        }
    }

    /// 弱边缘面板。用 Liquid Glass 的 .clear 变体：仍是玻璃，但边缘高光比
    /// .regular 弱很多，介于"有描边"和"无描边"之间。
    /// 26 以下回退到纯材质（无描边），靠跟底层的明暗差划界
    @ViewBuilder
    func panelSurfaceClear(_ kind: PanelKind = .content,
                           cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.clear.tint(kGlassTint), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(VisualEffectBackground(material: kind.material))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// 完全没有描边的面板。预览区、属性区、轨道区用它 ——
    /// Liquid Glass 那圈边缘高光去不掉，所以这三块统一走材质，
    /// 只留材质底色和圆角，靠明暗差划界
    func panelSurfacePlain(_ kind: PanelKind = .content, cornerRadius: CGFloat = 12) -> some View {
        background(VisualEffectBackground(material: kind.material))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// 柔和阴影。给需要"浮起来"的面板用（素材栏、欢迎页侧栏）
    func softPanelShadow() -> some View {
        shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 4)
    }

    /// 面板描边，带光照渐变。26 以下的回退路径用
    func panelBorder(cornerRadius: CGFloat = 12) -> some View {
        modifier(PanelBorder(cornerRadius: cornerRadius))
    }

    /// 侧边栏材质（系统设置左栏、访达边栏用的就是这个）
    func sidebarMaterial() -> some View {
        background(VisualEffectBackground(material: .sidebar))
    }

    /// 内容区材质（系统设置右侧那块）
    func contentMaterial() -> some View {
        background(VisualEffectBackground(material: .contentBackground))
    }

    /// 窗口底层材质。用 .underWindowBackground——它比面板用的那两档暗，
    /// 属性区/预览区/轨道区去掉描边之后就靠这个明暗差来划界
    func windowMaterial() -> some View {
        // ignoresSafeArea：窗口是 fullSizeContentView，顶部标题栏那条也归窗口，
        // 不忽略 safe area 的话材质铺不到那儿，顶端会缺一条透明带
        background(
            VisualEffectBackground(material: .underWindowBackground)
                .overlay(kWindowTint)
                .ignoresSafeArea()
        )
    }

    /// 浮层材质（设置、导出、新建项目这些盖在主界面上的面板）。
    /// 用 .withinWindow 而不是 .behindWindow：这类面板浮在主界面之上，
    /// 该模糊的是它**下面的界面内容**而不是窗口后面的桌面——系统的 popover、
    /// 检查器浮层都是这个取向，这样才有"浮起来"的层次
    func floatingPanelMaterial() -> some View {
        background(VisualEffectBackground(material: .hudWindow, blending: .withinWindow))
    }
}
