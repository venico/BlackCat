import SwiftUI

/// 画布上的素材浏览器（v5.1.0，B5）
///
/// 一份内容，两种外壳：
/// - **弹窗**（`CanvasAssetPicker`）：给节点换素材、从菜单进素材库时用，样式跟「设置」对齐
/// - **抽屉**（侧栏右边那块）：常驻浏览用，窄一点
///
/// 标签始终四个都显示 —— 给某个节点选素材时，不能选的那几个**置灰**而不是藏掉，
/// 藏掉的话用户会以为素材库里没有那类东西。
struct CanvasAssetBrowser: View {
    @EnvironmentObject var project: ProjectState

    /// 只让选这一类（给节点换素材时给）。nil = 随便选
    var limitTo: CanvasNode.Kind?
    /// 元素库模式：只列这张画布产出过的东西
    var producedOnly: [CanvasState.ProducedAsset]?
    /// 每行几列由外壳定：弹窗宽、抽屉窄
    var cellWidth: CGFloat = 96
    var onPick: (URL, CanvasNode.Kind) -> Void

    @State private var keyword = ""
    @State private var tab: Tab = .all

    enum Tab: String, CaseIterable {
        case all = "全部", video = "视频", audio = "音频", image = "图片"

        var assetType: AssetType? {
            switch self {
            case .all:   return nil
            case .video: return .video
            case .audio: return .audio
            case .image: return .image
            }
        }

        var nodeKind: CanvasNode.Kind? {
            switch self {
            case .all:   return nil
            case .video: return .video
            case .audio: return .audio
            case .image: return .image
            }
        }
    }


    private var items: [Item] {
        var list: [Item]
        if let produced = producedOnly {
            list = produced.map { Item(url: $0.url, kind: $0.kind, name: $0.url.lastPathComponent, assetID: nil) }
        } else {
            list = project.mediaAssets.compactMap { asset in
                guard asset.type != .subtitle,
                      let kind = CanvasSurfaceKindResolver.nodeKind(for: asset.url) else { return nil }
                return Item(url: asset.url, kind: kind, name: asset.name, assetID: asset.id)
            }
        }
        // 不按 limitTo 过滤 —— 不能选的素材照样列出来，只是格子置灰。
        // 直接藏掉的话用户会以为素材库里没有那些东西
        if let want = tab.nodeKind { list = list.filter { $0.kind == want } }
        if !keyword.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        }
        return sorted(list)
    }

    /// 排序跟素材库侧边栏共用同一份设置（`mediaSortOrder` / `mediaSortAscending`），
    /// 那边改了这边跟着变，不另立一套
    private func sorted(_ list: [Item]) -> [Item] {
        let asc = project.mediaSortAscending
        func asset(_ i: Item) -> MediaAsset? {
            i.assetID.flatMap { id in project.mediaAssets.first { $0.id == id } }
                ?? project.mediaAssets.first { $0.url == i.url }
        }
        switch project.mediaSortOrder {
        case .name:
            return list.sorted { asc ? $0.name.localizedCompare($1.name) == .orderedAscending
                                     : $0.name.localizedCompare($1.name) == .orderedDescending }
        case .duration:
            return list.sorted {
                let a = asset($0)?.duration ?? 0, b = asset($1)?.duration ?? 0
                return asc ? a < b : a > b
            }
        case .importDate:
            return list.sorted {
                let a = asset($0)?.importDate ?? .distantPast
                let b = asset($1)?.importDate ?? .distantPast
                return asc ? a < b : a > b
            }
        case .fileSize:
            return list.sorted {
                let a = asset($0)?.fileSize ?? 0, b = asset($1)?.fileSize ?? 0
                return asc ? a < b : a > b
            }
        }
    }

    /// 音频没有画面，摆成网格全是一样的图标 —— 跟素材库侧边栏一样用列表
    private var showsAsList: Bool { tab == .audio }

    struct Item: Identifiable {
        var id: URL { url }
        let url: URL
        let kind: CanvasNode.Kind
        let name: String
        let assetID: UUID?
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            searchRow

            if items.isEmpty {
                Spacer()
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    if showsAsList {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                AssetRow(item: item,
                                         enabled: limitTo == nil || item.kind == limitTo) {
                                    onPick(item.url, item.kind)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 10)], spacing: 12) {
                            ForEach(items) { item in
                                AssetCell(item: item,
                                          width: cellWidth,
                                          // 限定了类型时，别的类型置灰不可选
                                          enabled: limitTo == nil || item.kind == limitTo) {
                                    onPick(item.url, item.kind)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .onAppear {
            // 限定类型时默认落在那个标签上，省得用户还要自己找
            if let limitTo, let t = Tab.allCases.first(where: { $0.nodeKind == limitTo }) {
                tab = t
            }
        }
    }

    private var emptyHint: String {
        if producedOnly != nil { return "这张画布还没生成过东西" }
        return keyword.isEmpty ? "素材库里还没有这类素材" : "没有匹配的素材"
    }

    /// 标签栏跟「设置」那套一致：胶囊底 + 选中态填充
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tab == t ? .white : Color.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(tab == t ? Color.white.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// 搜索框跟素材库侧边栏那个一致
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarSVGIcon.load("search"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundColor(Color.labelSecondary)
            TextField("搜索", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.labelPrimary)
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 搜索 + 排序一行。排序菜单直接用素材库那个，选项和当前项都一致
    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            Button { showSortNSMenu(project: project) } label: {
                Image(nsImage: SidebarSVGIcon.load("sort", size: 13))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("排序")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// 一格素材。缩略图**先定尺寸再裁切** ——
/// 只给 aspectRatio(.fill) 不裁的话，竖图会顶出格子盖住旁边那几个
private struct AssetCell: View {
    @EnvironmentObject var project: ProjectState
    let item: CanvasAssetBrowser.Item
    let width: CGFloat
    /// 这个卡片放不了的类型：压暗 + 不可点，但仍然列出来
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    private var height: CGFloat { width * 0.7 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: height)
                            .clipped()
                    } else {
                        Image(nsImage: SidebarSVGIcon.load(CanvasNodeView.iconKey(for: item.kind), size: 18))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .foregroundColor(Color.labelSecondary.opacity(0.4))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accent.opacity(hovering ? 0.9 : 0), lineWidth: 1.5))

                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundColor(hovering ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(1)
                    .frame(width: width)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = enabled && $0 }
        .help(enabled ? item.name : "这个卡片放不了\(item.kind.label)素材")
    }

    /// 视频靠素材库那份缩略图（跟素材库/时间轴共用缓存，不重复抽帧），
    /// 图片没进库就直接读文件
    private var thumbnail: NSImage? {
        if let id = item.assetID, let thumb = project.mediaThumbnails[id] { return thumb }
        if let asset = project.mediaAssets.first(where: { $0.url == item.url }),
           let thumb = project.mediaThumbnails[asset.id] { return thumb }
        return item.kind == .image ? NSImage(contentsOf: item.url) : nil
    }
}

// MARK: - 弹窗外壳

/// 从素材库挑一个（弹窗版）。标题、边距、关闭按钮都按「设置」那套来
struct CanvasAssetPicker: View {
    @EnvironmentObject var project: ProjectState
    var limitTo: CanvasNode.Kind?
    var onPick: (MediaAsset?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(limitTo == nil ? "从素材库选择" : "选择\(limitTo!.label)素材")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Button { onPick(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            CanvasAssetBrowser(limitTo: limitTo, cellWidth: 110) { url, _ in
                onPick(project.mediaAssets.first { $0.url == url })
            }
            .environmentObject(project)
        }
        .frame(width: 560, height: 480)
        .floatingPanelMaterial()
    }
}


/// 音频那种没画面的，用列表行：名称 + 时长，跟素材库侧边栏一致
private struct AssetRow: View {
    @EnvironmentObject var project: ProjectState
    let item: CanvasAssetBrowser.Item
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundColor(Color.labelPrimary)
                        .lineLimit(1)
                    Text(durationText)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(hovering && enabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = enabled && $0 }
        .help(enabled ? item.name : "这个卡片放不了\(item.kind.label)素材")
    }

    private var durationText: String {
        let asset = item.assetID.flatMap { id in project.mediaAssets.first { $0.id == id } }
            ?? project.mediaAssets.first { $0.url == item.url }
        let d = asset?.duration ?? 0
        guard d > 0 else { return "--:--" }
        return String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
    }
}
