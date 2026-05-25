import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var project: ProjectState = {
        let p = ProjectState()
        if AppDelegate.pendingOpenURL != nil {
            p.showWelcome = false
        }
        return p
    }()
    @StateObject private var exportManager = ExportManager.shared
    @State private var topHeight: CGFloat = 420
    @State private var isDraggingH = false
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220
    @State private var inspectorWidth: CGFloat = 280
    // Drag origin tracking (prevents cumulative translation bug)
    @State private var dragOriginSidebar: CGFloat = 220
    @State private var dragOriginInspector: CGFloat = 280
    @State private var dragOriginTop: CGFloat = 420

    // Height of the shared "title-bar" row that contains traffic lights + toggle
    private let toolbarH: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ────────────────────────────────────────────
            if sidebarVisible {
                VStack(spacing: 0) {
                    // 标题栏行：自定义交通灯（SwiftUI）+ toggle 按钮
                    HStack(spacing: 0) {
                        TrafficLightsView()
                            .padding(.leading, 12)
                        Spacer()
                        toggleButton
                            .padding(.trailing, 12)
                    }
                    .frame(height: toolbarH)

                    // Content
                    MediaLibraryView()
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(Color(red: 0.15, green: 0.15, blue: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                )
                .padding(.top, 8)
                .padding(.leading, 8)
                .padding(.bottom, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
                // Sidebar right-edge drag handle (overlaps the 8px gap)
                .overlay(alignment: .trailing) {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .offset(x: 4)
                        .onHover { h in if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if v.translation == .zero { dragOriginSidebar = sidebarWidth }
                                sidebarWidth = (dragOriginSidebar + v.translation.width)
                                    .clamped(to: 160...400)
                            }
                            .onEnded { _ in NSCursor.arrow.set() }
                        )
                }
            }

            // ── Main content ───────────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // Player + Inspector cards
                        HStack(spacing: 8) {
                            PlayerView()
                                .frame(maxWidth: .infinity)
                                .background(Color.previewBg)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                            InspectorView()
                                .frame(width: inspectorWidth)
                                .background(Color.panelBg)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                                // Inspector left-edge drag handle (overlaps the 8px gap)
                                .overlay(alignment: .leading) {
                                    Color.clear
                                        .frame(width: 8)
                                        .contentShape(Rectangle())
                                        .offset(x: -4)
                                        .onHover { h in if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                                        .gesture(DragGesture(minimumDistance: 1)
                                            .onChanged { v in
                                                if v.translation == .zero { dragOriginInspector = inspectorWidth }
                                                inspectorWidth = (dragOriginInspector - v.translation.width)
                                                    .clamped(to: 200...450)
                                            }
                                            .onEnded { _ in NSCursor.arrow.set() }
                                        )
                                }
                        }
                        .frame(height: topHeight)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)

                        // Drag handle — the 8px gap between top and bottom cards
                        Color.clear
                            .frame(height: 8)
                            .contentShape(Rectangle())
                            .onHover { h in if h { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { v in
                                    if !isDraggingH { dragOriginTop = topHeight }
                                    isDraggingH = true
                                    let avail = geo.size.height - 24
                                    topHeight = (dragOriginTop + v.translation.height)
                                        .clamped(to: 180...(avail - 130))
                                }
                                .onEnded { _ in isDraggingH = false; NSCursor.arrow.set() }
                            )

                        // Timeline card
                        VStack(spacing: 0) {
                            TimelineToolbar()
                                .fixedSize(horizontal: false, vertical: true)
                            TimelineView()
                                .frame(maxHeight: .infinity)
                                .clipped()
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color.timelineBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                        .padding(.bottom, 8)
                        .padding(.horizontal, 8)
                    }
                    .onAppear {
                        topHeight = geo.size.height * 0.60
                    }

                    // 侧边栏收起时：交通灯 + toggle 在左上角
                    if !sidebarVisible {
                        HStack(spacing: 10) {
                            TrafficLightsView()
                            toggleButton
                        }
                        .padding(.leading, 12)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .background(Color.black)
        .overlay(alignment: .bottomTrailing) {
            ExportProgressOverlay(manager: exportManager)
        }
        .overlay(alignment: .bottomTrailing) {
            SaveToastStack()
                .environmentObject(project)
                .padding(.trailing, 16)
                .padding(.bottom, 48)
        }
        .environmentObject(project)
        .ignoresSafeArea()
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: sidebarVisible)
        .sheet(isPresented: $project.showExportSheet) {
            ExportSheetView().environmentObject(project)
        }
        .overlay {
            if project.showWelcome {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                WelcomeView()
                    .environmentObject(project)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: project.showWelcome)
        .onReceive(NotificationCenter.default.publisher(for: .menuImportFiles)) { note in
            if let urls = note.object as? [URL] {
                urls.forEach { project.importFile($0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuExportVideo)) { _ in
            project.showExportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuSaveProject)) { _ in
            project.saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewProject)) { _ in
            project.showWelcome = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenProject)) { _ in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.init(filenameExtension: "bcj") ?? .json]
            panel.prompt = "打开"
            if panel.runModal() == .OK, let url = panel.url {
                project.openProject(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenProjectFile)) { note in
            if let url = note.object as? URL {
                project.openProject(url: url)
            }
        }
        .alert("清空素材库", isPresented: $project.showClearLibraryConfirm) {
            Button("清空", role: .destructive) { project.clearMediaLibrary() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除所有素材，并同时删除时间轴上的所有片段，此操作可撤销。")
        }
        .alert("确认移除素材", isPresented: $project.showAssetDeleteConfirm) {
            Button("移除", role: .destructive) {
                if let id = project.pendingDeleteAssetID {
                    project.removeAssetAndClips(assetID: id)
                    project.pendingDeleteAssetID = nil
                }
            }
            Button("取消", role: .cancel) { project.pendingDeleteAssetID = nil }
        } message: {
            if let id = project.pendingDeleteAssetID {
                let count = project.clipCountForAsset(id)
                let name = project.mediaAssets.first(where: { $0.id == id })?.name ?? ""
                if count > 0 {
                    Text("「\(name)」在时间轴上有 \(count) 个片段引用，移除素材将同时删除这些片段。")
                } else {
                    Text("确定要移除「\(name)」吗？")
                }
            } else {
                Text("确定要移除该素材吗？")
            }
        }
        .onAppear {
            if let url = AppDelegate.pendingOpenURL {
                AppDelegate.pendingOpenURL = nil
                project.showWelcome = false
                project.openProject(url: url)
            }
        }
    }

    private var toggleButton: some View {
        Button { sidebarVisible.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Design Tokens
extension Color {
    static let panelBg        = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let previewBg      = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let timelineBg     = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let divider        = Color.white.opacity(0.08)
    static let labelPrimary   = Color.white.opacity(0.88)
    static let labelSecondary = Color.white.opacity(0.45)
    static let accent         = Color(hex: "#F5B942")
    static let hoverBg        = Color.white.opacity(0.07)
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Save Toast Stack

struct SaveToastStack: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(project.saveToasts, id: \.self) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("已保存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.15).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let msg = project.importToastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.15).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: project.saveToasts.count)
        .animation(.easeInOut(duration: 0.25), value: project.importToastMessage)
    }
}
