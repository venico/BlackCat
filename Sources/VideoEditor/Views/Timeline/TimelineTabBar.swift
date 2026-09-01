// TimelineTabBar.swift
//
// 轨道区最上面那条时间线标签栏。
//
// 关闭按钮**只在 hover 时露出来**，平时那个位置是空的 —— 一直挂着的话
// 一排标签看上去全是叉，很吵。

import SwiftUI

struct TimelineTabBar: View {
    @EnvironmentObject private var project: ProjectState

    @State private var hoveredTab: UUID?
    @State private var moreHover = false
    @State private var plusHover = false
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    /// 待确认删除的那条时间线。删是真丢数据，得拦一下
    @State private var deletingTab: TimelineTab?
    /// 标签排满没有。排满了 + 就钉在最右边，不跟着一起滚出去
    @State private var tabsWidth: CGFloat = 0
    @State private var barWidth: CGFloat = 0
    private var overflowing: Bool { barWidth > 0 && tabsWidth > barWidth - 4 }

    var body: some View {
        HStack(spacing: 6) {
            moreMenu

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(project.tabs.filter(\.isTabOpen)) { tab in
                            tabChip(tab)
                        }
                    }
                    // 量的是标签本身的宽度，**不含 +** ——
                    // 把 + 算进来的话，它一挪位置宽度就变，两种摆法之间会来回跳
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { tabsWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in tabsWidth = w }
                    })

                    // 位置够就紧跟最后一个标签，不够时挪到栏外钉住
                    if !overflowing { plusButton }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { barWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in barWidth = w }
            })

            if overflowing { plusButton }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        // 删除是真的把这条时间线连轨道一起丢掉，**左取消右确定**
        .alert("是否删除该时间线", isPresented: Binding(
            get: { deletingTab != nil },
            set: { if !$0 { deletingTab = nil } }
        ), presenting: deletingTab) { tab in
            Button("取消", role: .cancel) { deletingTab = nil }
            Button("确定", role: .destructive) {
                project.deleteTab(id: tab.id); deletingTab = nil
            }
        } message: { tab in
            Text("「\(tab.name)」里的所有轨道都会被删掉，且不能撤回到关闭前的状态。素材库不受影响。")
        }
    }

    private var plusButton: some View {
        Button { project.addTimelineTab() } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(plusHover ? Color.labelPrimary : Color.labelSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(plusHover ? Color.white.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { plusHover = $0 }
        .help("新建时间线")
    }

    // MARK: - 单个标签

    @ViewBuilder
    private func tabChip(_ tab: TimelineTab) -> some View {
        let isActive = tab.id == project.tab.id
        let isHover = hoveredTab == tab.id

        HStack(spacing: 4) {
            if renamingID == tab.id {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(Color.labelPrimary)
                    .frame(width: 80)
                    .focused($renameFocused)
                    .onSubmit { commitRename(tab) }
                    .onChange(of: renameFocused) { f in if !f { commitRename(tab) } }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(tab.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.labelPrimary : Color.labelSecondary)
                    .lineLimit(1)
            }

            // 关闭按钮只在 hover 时出现。**位置一直占着**，
            // 否则鼠标一进来标签就变宽，整排跟着抖
            Button { project.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHover ? 1 : 0)
            .allowsHitTesting(isHover)
            .help("关闭标签页")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(isActive ? Color.white.opacity(0.12)
                           : (isHover ? Color.white.opacity(0.06) : Color.clear)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hoveredTab = $0 ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab) }
        .onTapGesture { project.switchToTab(id: tab.id) }
        .gesture(TapGesture(count: 2).onEnded {
            renamingID = tab.id
            renameDraft = tab.name
            DispatchQueue.main.async { renameFocused = true }
        })
        .contextMenu {
            Button("重命名") {
                renamingID = tab.id
                renameDraft = tab.name
                DispatchQueue.main.async { renameFocused = true }
            }
            Divider()
            Button("关闭标签页") { project.closeTab(id: tab.id) }
            Button("删除时间线", role: .destructive) { deletingTab = tab }
        }
    }

    private func commitRename(_ tab: TimelineTab) {
        guard renamingID == tab.id else { return }
        project.renameTab(id: tab.id, to: renameDraft)
        renamingID = nil
    }

    // MARK: - 更多

    private var moreMenu: some View {
        Menu {
            Button("显示所有标签页") { project.showAllTabs() }
            Button("关闭所有标签页") { project.closeAllTabs() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(moreHover ? Color.labelPrimary : Color.labelSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(moreHover ? Color.white.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .onHover { moreHover = $0 }
    }
}
