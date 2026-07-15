import SwiftUI
import AVFoundation

struct AIChatPanel: View {
    @EnvironmentObject private var project: ProjectState
    @StateObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var inputText = ""
    @State private var showHistory = false

    private let durations = ["5", "10"]
    private let ratios = ["16:9", "9:16", "1:1"]

    var body: some View {
        VStack(spacing: 0) {
            header
            historySection
            messageList
            inputArea
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack {
            Text("视频生成")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.labelSecondary)
                .textCase(.uppercase)
            Spacer()
            Button { service.newConversation() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
            }
            .buttonStyle(.plain)
            .help("新建对话")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 13)
        .padding(.bottom, 8)
    }

    // MARK: - 历史会话

    private var historySection: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showHistory.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("历史会话")
                        .font(.system(size: 10, weight: .medium))
                    if !service.history.isEmpty {
                        Text("\(service.history.count)")
                            .font(.system(size: 9))
                            .foregroundColor(Color.labelSecondary.opacity(0.6))
                    }
                    Spacer()
                    Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(Color.labelSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHistory && !service.history.isEmpty {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(service.history) { conv in
                            historyRow(conv)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 170)
            }
        }
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func historyRow(_ conv: AIVideoService.ConversationRecord) -> some View {
        let isActive = conv.id == service.currentConversationId
        Button {
            service.loadConversation(conv.id)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title)
                        .font(.system(size: 11))
                        .foregroundColor(isActive ? .white : Color.labelPrimary)
                        .lineLimit(1)
                    Text(formatDate(conv.createdAt))
                        .font(.system(size: 9))
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isActive ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { service.deleteConversation(conv.id) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            return "今天 " + fmt.string(from: date)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                if service.messages.isEmpty {
                    emptyHint
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(service.messages) { msg in
                            MessageBubble(message: msg, onInsertToTimeline: { url in
                                insertVideoToTimeline(url)
                            })
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
            .onChange(of: service.messages.count) { _ in
                if let last = service.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.3))
            Text("描述你想生成的视频")
                .font(.system(size: 12))
                .foregroundColor(Color.labelSecondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 输入区域

    private var inputArea: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                TextEditor(text: $inputText)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 30, maxHeight: 50)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                    .onKeyPress(.return) {
                        sendMessage()
                        return .handled
                    }
                    .overlay(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text("描述你想生成的视频…")
                                .font(.system(size: 12))
                                .foregroundColor(Color.labelSecondary.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 4) {
                    Menu {
                        ForEach(AIVideoService.Provider.allCases) { provider in
                            Button(provider.displayName) {
                                service.selectedProvider = provider
                                settings.aiProvider = provider.rawValue
                            }
                        }
                    } label: {
                        Text(service.selectedProvider.displayName)
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(Color.labelSecondary)

                    Menu {
                        ForEach(durations, id: \.self) { d in
                            Button(d + "s") { settings.aiDuration = d }
                        }
                    } label: {
                        Text(settings.aiDuration + "s")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(Color.labelSecondary)

                    Menu {
                        ForEach(ratios, id: \.self) { r in
                            Button(r) { settings.aiRatio = r }
                        }
                    } label: {
                        Text(settings.aiRatio)
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(Color.labelSecondary)

                    Spacer()

                    if service.isGenerating {
                        Button { service.cancelGeneration() } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.accent)
                                    .frame(width: 20, height: 20)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.black)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { sendMessage() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(canSend ? Color.accent : Color.labelSecondary.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Actions

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isGenerating
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !service.isGenerating else { return }
        inputText = ""
        service.sendPrompt(text, duration: settings.aiDuration, aspectRatio: settings.aiRatio)
    }

    private func insertVideoToTimeline(_ url: URL) {
        project.importFile(url)
        guard let asset = project.mediaAssets.first(where: { $0.url == url }) else { return }
        let playhead = project.currentTime
        project.pushUndo()
        let hasClipAtPlayhead = project.videoTracks.contains { track in
            track.clips.contains { $0.startTime <= playhead && $0.endTime > playhead }
        }
        if hasClipAtPlayhead {
            project.videoTracks.append(Track(label: "视频"))
        }
        project.addToTimelineAt(asset, time: playhead, skipUndo: true)
        project.showSuccessToast(icon: "sparkles", iconColor: .purple, title: "AI 视频", subtitle: "已插入视频轨道")
    }
}

// MARK: - 消息气泡

private struct MessageBubble: View {
    let message: AIVideoService.ChatMessage
    var onInsertToTimeline: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                assistantBubble
                Spacer(minLength: 20)
            } else {
                Spacer(minLength: 20)
                userBubble
            }
        }
    }

    private var userBubble: some View {
        Text(message.content)
            .font(.system(size: 12))
            .foregroundColor(.black)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.status {
            case .generating(let progress):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                }

            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("下载中…")
                        .font(.system(size: 11))
                        .foregroundColor(Color.labelSecondary)
                }

            case .completed(let url):
                VStack(alignment: .leading, spacing: 6) {
                    VideoThumbnailView(url: url)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "film.stack", tip: "插入视频轨道") {
                            onInsertToTimeline(url)
                        }
                        HoverIconButton(icon: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }

            case .failed(let error):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }

            case .idle:
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .textSelection(.enabled)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 视频封面

private struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var duration: String = ""

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 100)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if !duration.isEmpty {
                Text(duration)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(6)
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)

        if let dur = try? await asset.load(.duration) {
            let s = Int(dur.seconds)
            let m = s / 60; let sec = s % 60
            await MainActor.run { duration = String(format: "%d:%02d", m, sec) }
        }

        if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            let ns = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            await MainActor.run { thumbnail = ns }
        }
    }
}

// MARK: - Hover 图标按钮

private struct HoverIconButton: View {
    let icon: String
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color.labelSecondary)
                .frame(width: 24, height: 24)
                .background(hovering ? Color.white.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tip)
    }
}
