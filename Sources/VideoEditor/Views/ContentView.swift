import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var project = ProjectState()
    @State private var topHeight: CGFloat = 420
    @State private var isDraggingH = false
    @State private var sidebarVisible = true

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
                .frame(width: 220)
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
                // no trailing — gap to video card comes from video's own leading padding
                .transition(.move(edge: .leading).combined(with: .opacity))
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
                                .frame(width: 280)
                                .background(Color.panelBg)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.20), lineWidth: 0.5))
                        }
                        .frame(height: topHeight)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)

                        // Drag handle — the 8px gap between top and bottom cards
                        Color.clear
                            .frame(height: 8)
                            .onHover { _ in NSCursor.resizeUpDown.set() }
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { v in
                                    isDraggingH = true
                                    let avail = geo.size.height - 24
                                    topHeight = (topHeight + v.translation.height)
                                        .clamped(to: 180...(avail - 130))
                                }
                                .onEnded { _ in isDraggingH = false; NSCursor.arrow.set() }
                            )

                        // Timeline card
                        VStack(spacing: 0) {
                            TimelineToolbar()
                            TimelineView()
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
        .environmentObject(project)
        .ignoresSafeArea()
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: sidebarVisible)
        .sheet(isPresented: $project.showExportSheet) {
            ExportSheetView().environmentObject(project)
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
