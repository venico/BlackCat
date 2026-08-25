import SwiftUI

/// 画布左侧的悬浮栏（v5.1.0，B5）
///
/// 三个入口：添加（跟双击空白同一个菜单）、素材库（全局那份）、
/// 元素库（**这张画布**产出过的东西）。
/// 后两个点开是同一个抽屉，只是内容不同。
struct CanvasSideBar: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState

    /// 从菜单里选了一种类型
    var onPickKind: (CanvasNode.Kind) -> Void
    /// 菜单里的「上传」
    var onUpload: () -> Void
    /// 菜单里的「从素材库选择」
    var onPickAssetFromLibrary: () -> Void
    /// 从库里选中一项，落成卡片
    var onPickAsset: (URL, CanvasNode.Kind) -> Void

    @State private var panel: Panel?

    enum Panel: String, Identifiable {
        case library, assets
        var id: String { rawValue }
    }

    /// 侧栏整条的宽度（含内边距），外层画菜单时要按它算位置
    static let barWidth: CGFloat = 54

    var body: some View {
        VStack(spacing: 10) {
            // 「添加」是主操作，给实心圆底突出出来（其余两个是普通图标按钮）。
            // hover 就出菜单，不用点。菜单画在**外层**，见 CanvasState.sideMenuVisible
            AddButton(isHovering: canvas.sideMenuVisible) { canvas.sideAddHovering = $0 }
            sideButton(icon: "folder", help: "素材库", active: panel == .library) {
                panel = (panel == .library) ? nil : .library
            }
            sideButton(icon: "elementLibrary", help: "元素库（这张画布生成的）", active: panel == .assets) {
                panel = (panel == .assets) ? nil : .assets
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: Self.barWidth)
        // 整条是胶囊形（全圆角）
        .background(Capsule().fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        // 抽屉比侧栏高，同样不能当 HStack 的兄弟（会把侧栏顶上去），
        // 但它是点开的、不靠 hover，压在侧栏上也不影响按钮
        .overlay(alignment: .topLeading) { drawerOverlay }
        .animation(.easeOut(duration: 0.15), value: panel)
    }

    @ViewBuilder
    private var drawerOverlay: some View {
        if let panel {
            drawer(for: panel)
                .fixedSize()
                .offset(x: Self.barWidth + 16, y: 0)
                .transition(.opacity)
        }
    }

    private func sideButton(icon: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        SideBarButton(icon: icon, help: help, active: active, action: action)
    }

    // MARK: - 抽屉

    /// 抽屉跟弹窗共用 `CanvasAssetBrowser` —— 标题、标签、搜索、格子样式一套，
    /// 差别只有外壳尺寸和它挂在哪
    private func drawer(for panel: Panel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel == .library ? "素材库" : "元素库")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Button { self.panel = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            CanvasAssetBrowser(
                producedOnly: panel == .assets ? canvas.producedAssets : nil,
                cellWidth: 92,
                onPick: onPickAsset)
                .environmentObject(project)
        }
        .frame(width: 300, height: 420)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

/// 「添加」按钮：实心圆底，比另外两个显眼一档
private struct AddButton: View {
    /// 传值而不是 Binding：Binding 到 ObservableObject 的属性时，
    /// Binding 本身没变，SwiftUI 会跳过这个子视图的重绘 ——
    /// 表现就是「菜单弹出来了，但 + 没转」
    let isHovering: Bool
    let onHoverChange: (Bool) -> Void

    private var hovering: Bool { isHovering }

    var body: some View {
        Button {} label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.black)
                // hover 时转 45° 变成 ×：菜单开着，再点一下/移开就收
                .rotationEffect(.degrees(hovering ? 45 : 0))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(hovering ? 1 : 0.9)))
        }
        .buttonStyle(.plain)
        .onHover { onHoverChange($0) }
        .help("添加节点")
    }
}

private struct SideBarButton: View {
    let icon: String
    let help: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: SidebarSVGIcon.load(icon, size: 15))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                .foregroundColor(active ? Color.accent
                                 : (hovering ? Color.labelPrimary : Color.labelSecondary))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(active ? 0.16 : (hovering ? 0.12 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
