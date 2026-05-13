import SwiftUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @EnvironmentObject private var project: ProjectState
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("素材库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                    .textCase(.uppercase)
                Spacer()
                if project.mediaAssets.count > 0 {
                    Text("\(project.mediaAssets.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.labelSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Asset list + drag-drop target
            ZStack {
                if project.mediaAssets.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(project.mediaAssets) { asset in
                                AssetRow(asset: asset)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }

                // Drag overlay
                if isDragOver {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accent, lineWidth: 1.5)
                        .background(Color.accent.opacity(0.06).cornerRadius(10))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 26, weight: .ultraLight))
                                Text("松开以导入")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color.accent)
                        }
                        .padding(10)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { project.importFile(url) }
                    }
                }
                return true
            }

            Spacer()

            // Bottom actions
            VStack(spacing: 8) {
                ImportButton()
                ExportButton()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.30))
            Text("拖入文件或点击导入")
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Asset Row

private struct AssetRow: View {
    @EnvironmentObject private var project: ProjectState
    let asset: MediaAsset
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Icon — plain colored icon, no background
            Image(systemName: asset.type.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(asset.type.color)
                .frame(width: 20)

            // Title + duration (no type label)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.labelPrimary)
                    .lineLimit(2)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .help(asset.name)

                if asset.duration > 0 {
                    Text(fmtDur(asset.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                }
            }

            Spacer()

            // Action buttons on hover
            if hovered {
                HStack(spacing: 2) {
                    miniBtn(icon: "plus.circle") { project.addToTimeline(asset) }
                    miniBtn(icon: "trash")       { project.mediaAssets.removeAll { $0.id == asset.id } }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { project.addToTimeline(asset) })
        .contextMenu {
            Button("添加到时间轴") { project.addToTimeline(asset) }
            Divider()
            Button("移除", role: .destructive) { project.mediaAssets.removeAll { $0.id == asset.id } }
        }
    }

    private func fmtDur(_ d: Double) -> String {
        let h = Int(d)/3600; let m = Int(d)/60%60; let s = Int(d)%60
        return h > 0 ? String(format:"%d:%02d:%02d",h,m,s) : String(format:"%02d:%02d",m,s)
    }

    @ViewBuilder
    private func miniBtn(icon: String, action: @escaping () -> Void) -> some View {
        MiniBtnView(icon: icon, action: action)
    }
}

private struct MiniBtnView: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .light))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 26, height: 26)
                .background(hovering ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Import / Export Buttons

private struct ImportButton: View {
    @EnvironmentObject private var project: ProjectState

    var body: some View {
        Button { openPicker() } label: {
            HStack {
                Spacer()
                Text("导入素材")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundColor(Color.labelPrimary)
            .frame(height: 36)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .movie, .audio,
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "ass") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText
        ]
        panel.begin { r in
            guard r == .OK else { return }
            panel.urls.forEach { project.importFile($0) }
        }
    }
}

private struct ExportButton: View {
    @EnvironmentObject private var project: ProjectState
    var body: some View {
        Button { project.showExportSheet = true } label: {
            HStack {
                Spacer()
                Text("导出 MP4")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                Spacer()
            }
            .frame(height: 36)
            .background(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
