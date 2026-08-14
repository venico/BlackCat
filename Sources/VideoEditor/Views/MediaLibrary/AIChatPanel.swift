import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct AIChatPanel: View {
    @EnvironmentObject private var project: ProjectState
    @StateObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var inputText = ""
    @State private var showHistory = false
    @State private var swapHovering = false

    // 输入区状态存在 service 上，切 tab 重建 View 时不丢失
    private typealias RefContentType = AIVideoService.RefContentType
    private typealias RefContent = AIVideoService.RefContent
    private typealias ImageInputMode = AIVideoService.ImageInputMode

    private var referenceContents: [RefContent] {
        get { service.referenceContents }
        nonmutating set { service.referenceContents = newValue }
    }
    private var firstFrameImage: (url: URL, image: NSImage)? {
        get { service.firstFrameImage }
        nonmutating set { service.firstFrameImage = newValue }
    }
    private var lastFrameImage: (url: URL, image: NSImage)? {
        get { service.lastFrameImage }
        nonmutating set { service.lastFrameImage = newValue }
    }
    private var imageMode: ImageInputMode {
        get { service.imageMode }
        nonmutating set { service.imageMode = newValue }
    }

    private let durations = ["4", "5", "6", "7", "8", "9", "10"]
    private let ratios = ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]
    private let resolutions = ["480P", "720P", "1080P", "4K"]

    var body: some View {
        VStack(spacing: 0) {
            header
            historySection
            messageList
            inputArea
        }
        .onChange(of: service.selectedProvider) { _ in
            pruneInputsForProvider()
        }
        // 试听播放器是单例，view 销毁不会带走它 —— 切会话和关面板都得手动停，否则声音继续响
        .onChange(of: service.currentConversationId) { _ in
            AIInlinePlayer.shared.stop()
        }
        .onDisappear { AIInlinePlayer.shared.stop() }
    }

    /// 切换模型后，裁掉新模型不支持的参考内容，避免带着旧模型的数据发出去被静默丢弃
    private func pruneInputsForProvider() {
        let provider = service.selectedProvider
        if !provider.supportsLastFrame { lastFrameImage = nil }
        if !provider.supportsFirstFrame { firstFrameImage = nil }

        var kept: [RefContent] = []
        var imgCount = 0, vidCount = 0, audCount = 0
        for item in referenceContents {
            guard kept.count < provider.maxReferenceTotal else { break }
            switch item.type {
            case .image where imgCount < provider.maxReferenceImages: imgCount += 1
            case .video where vidCount < provider.maxReferenceVideos: vidCount += 1
            case .audio where audCount < provider.maxReferenceAudios: audCount += 1
            default: continue
            }
            kept.append(item)
        }
        if kept.count != referenceContents.count { referenceContents = kept }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack {
            Text("AI 生成")
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
                Image(nsImage: TimelineSVGIcon.load("delete", size: 14))
                Text("删除")
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
                                insertMediaToTimeline(url)
                            }, onRestoreAttachment: { att in
                                restoreAttachment(att)
                            })
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
            .onChange(of: service.messages.count) { _ in scrollToLast(proxy) }
            // 生成完成时消息条数**没变**：同一条 assistant 消息的 status 从 .generating
            // 变成 .completed 并挂上视频卡片。只看 count 就不会滚，用户得自己往下拖
            .onChange(of: service.messages.last?.status) { _ in
                scrollToLast(proxy, waitForLayout: true)
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, waitForLayout: Bool = false) {
        guard let last = service.messages.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        // 视频卡片是状态变完成之后才挂上去的，挂上去气泡才变高 —— 这一下只能滚到
        // 旧高度，等布局稳定再补一次才真到底
        guard waitForLayout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundColor(Color.labelSecondary.opacity(0.3))
            Text(emptyHintText)
                .font(.system(size: 12))
                .foregroundColor(Color.labelSecondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 输入区域

    private var inputArea: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if service.selectedProvider.maxReferenceImages > 0 {
                        imagePreviewArea
                    }
                    Spacer()
                    Button { showProviderMenu() } label: {
                        HStack(spacing: 3) {
                            Text(service.selectedProvider.displayName)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundColor(Color.labelSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                TextEditor(text: $inputText)
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 30, maxHeight: 50)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .onKeyPress(.return) {
                        sendMessage()
                        return .handled
                    }
                    .overlay(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text(inputPlaceholder)
                                .font(.system(size: 12))
                                .foregroundColor(Color.labelSecondary.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 4) {
                    if service.selectedProvider.category == .video {
                        capsuleMenu(label: imageMode == .reference ? refSlotLabel : imageMode.label) {
                            Button {
                                firstFrameImage = nil; lastFrameImage = nil
                                imageMode = .reference
                            } label: { Text(refSlotLabel) }
                            Button {
                                referenceContents.removeAll()
                                imageMode = .frames
                            } label: { Text("首尾帧") }
                        }
                        capsuleMenu(label: settings.aiDuration + "s") {
                            ForEach(durations, id: \.self) { d in
                                Button(d + "s") { settings.aiDuration = d }
                            }
                        }
                        capsuleMenu(label: settings.aiRatio) {
                            ForEach(ratios, id: \.self) { r in
                                Button(r) { settings.aiRatio = r }
                            }
                        }
                        capsuleMenu(label: settings.aiResolution) {
                            ForEach(resolutions, id: \.self) { r in
                                Button(r) { settings.aiResolution = r }
                            }
                        }
                    } else if service.selectedProvider.category == .image {
                        capsuleMenu(label: settings.aiImageRatio) {
                            ForEach(ratios, id: \.self) { r in
                                Button(r) { settings.aiImageRatio = r }
                            }
                        }
                    }

                    if service.selectedProvider.supportsWebSearch {
                        Button {
                            service.webSearchEnabled.toggle()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "globe")
                                    .font(.system(size: 9))
                                Text("联网")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(service.webSearchEnabled ? Color.accent : Color.labelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(service.webSearchEnabled ? Color.accent.opacity(0.15) : Color.white.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

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
                .clipped()
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func capsuleMenu<Content: View>(label: String, active: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        Menu { content() } label: {
            Text(label)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(active ? Color.accent : Color.labelSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(active ? Color.accent.opacity(0.15) : Color.white.opacity(0.06))
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .tint(Color.labelSecondary)
    }

    // MARK: - 图片预览区

    private var imagePreviewArea: some View {
        HStack(spacing: 6) {
            if imageMode == .reference || service.selectedProvider.category != .video {
                refContentSlot
            } else {
                frameSlot(image: firstFrameImage, label: "首帧") {
                    pickSingleImage { u, i in firstFrameImage = (u, i) }
                }
                // 只有支持尾帧的模型才显示尾帧槽，否则用户设了会被 API 静默丢弃
                if service.selectedProvider.supportsLastFrame {
                    swapFramesButton
                    frameSlot(image: lastFrameImage, label: "尾帧") {
                        pickSingleImage { u, i in lastFrameImage = (u, i) }
                    }
                }
            }
        }
    }

    /// 首尾帧互换：两个槽位都空时不可点
    private var swapFramesButton: some View {
        let enabled = firstFrameImage != nil || lastFrameImage != nil
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                let tmp = firstFrameImage
                firstFrameImage = lastFrameImage
                lastFrameImage = tmp
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary.opacity(enabled ? (swapHovering ? 0.9 : 0.55) : 0.25))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "交换首帧和尾帧" : "先添加首帧或尾帧")
        .onHover { swapHovering = $0 && enabled }
    }

    /// 只收图片的模型显示「参考图」，能收视频/音频的才叫「参考内容」
    private var refSlotLabel: String {
        let p = service.selectedProvider
        return (p.maxReferenceVideos == 0 && p.maxReferenceAudios == 0) ? "参考图" : "参考内容"
    }

    private var refContentSlot: some View {
        Group {
            if referenceContents.isEmpty {
                placeholderSlot(label: refSlotLabel, icon: "photo.badge.plus") { pickRefContents() }
            } else {
                ZStack {
                    fanThumbnails
                }
                .frame(width: refFanWidth, height: 48)
                .overlay(alignment: .topLeading) {
                    if referenceContents.count > 1 {
                        Text("\(referenceContents.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 14, height: 14)
                            .background(Color.accent)
                            .clipShape(Circle())
                            .offset(x: -3, y: -3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    deleteBadge { referenceContents.removeAll() }
                }
                .onTapGesture { pickRefContents() }
            }
        }
    }

    private var refFanWidth: CGFloat {
        let count = min(referenceContents.count, 3)
        return count <= 1 ? 48 : 48 + CGFloat(count - 1) * 8
    }

    private var fanThumbnails: some View {
        let items = Array(referenceContents.prefix(3))
        let count = items.count
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let angle = count == 1 ? 0.0 : Double(i - (count - 1)) * 8.0 + Double(count - 1) * 4.0
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .overlay(alignment: .bottomTrailing) {
                        if item.type == .video {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(2)
                        } else if item.type == .audio {
                            Image(systemName: "waveform")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(2)
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .rotationEffect(.degrees(angle))
            }
        }
    }

    private func frameSlot(image: (url: URL, image: NSImage)?, label: String, onPick: @escaping () -> Void) -> some View {
        Group {
            if let img = image {
                Image(nsImage: img.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        deleteBadge {
                            if label == "首帧" { firstFrameImage = nil } else { lastFrameImage = nil }
                        }
                    }
                    .onTapGesture(perform: onPick)
            } else {
                placeholderSlot(label: label, icon: "photo", action: onPick)
            }
        }
    }

    /// 统一的删除角标：白圈 + 深色叉，垫深色底保证压在浅色图片上时观感一致
    private func deleteBadge(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .background {
                    Circle()
                        .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
                        .frame(width: 10, height: 10)
                }
        }
        .buttonStyle(.plain)
        .offset(x: 2, y: -3)
    }

    private func placeholderSlot(label: String, icon: String = "photo", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 48, height: 48)
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color.labelSecondary.opacity(0.45))
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundColor(Color.labelSecondary.opacity(0.4))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 参考内容选择

    private static let imageExts = AIVideoService.imageExts
    private static let videoExts = AIVideoService.videoExts
    private static let audioExts = AIVideoService.audioExts

    private func pickRefContents() {
        let provider = service.selectedProvider
        let maxImg = provider.maxReferenceImages
        let maxVid = provider.maxReferenceVideos
        let maxAud = provider.maxReferenceAudios
        let totalLimit = provider.maxReferenceTotal
        let remaining = totalLimit - referenceContents.count
        guard remaining > 0 else { return }

        var types: [UTType] = []
        if maxImg > 0 { types.append(.image) }
        if maxVid > 0 { types.append(.movie) }
        if maxAud > 0 { types.append(.audio) }
        guard !types.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = totalLimit > 1
        panel.canChooseDirectories = false
        var limitParts: [String] = []
        if maxImg > 0 { limitParts.append("图片≤\(maxImg)") }
        if maxVid > 0 { limitParts.append("视频≤\(maxVid)") }
        if maxAud > 0 { limitParts.append("音频≤\(maxAud)") }
        panel.message = limitParts.count == 1
            ? "选择\(refSlotLabel)（最多 \(maxImg) 张）"
            : "选择\(refSlotLabel)（\(limitParts.joined(separator: " ")) 总数≤\(totalLimit)）"
        panel.begin { [self] response in
            guard response == .OK else { return }
            let urls = Array(panel.urls.prefix(remaining))
            var imgCount = referenceContents.filter { $0.type == .image }.count
            var vidCount = referenceContents.filter { $0.type == .video }.count
            var audCount = referenceContents.filter { $0.type == .audio }.count
            var newItems: [RefContent] = []
            for u in urls {
                let ext = u.pathExtension.lowercased()
                if Self.imageExts.contains(ext), imgCount < maxImg {
                    if let img = NSImage(contentsOf: u) {
                        newItems.append(RefContent(url: u, type: .image, thumbnail: img.thumbnailImage(maxSize: 200)))
                        imgCount += 1
                    }
                } else if Self.videoExts.contains(ext), vidCount < maxVid {
                    let thumb = Self.videoThumbnail(url: u)
                    newItems.append(RefContent(url: u, type: .video, thumbnail: thumb))
                    vidCount += 1
                } else if Self.audioExts.contains(ext), audCount < maxAud {
                    let thumb = Self.audioThumbnail()
                    newItems.append(RefContent(url: u, type: .audio, thumbnail: thumb))
                    audCount += 1
                }
                if referenceContents.count + newItems.count >= totalLimit { break }
            }
            DispatchQueue.main.async { referenceContents.append(contentsOf: newItems) }
        }
    }

    /// 点击历史消息里的附件缩略图回填输入区。
    /// 去向只看当前处于哪个模式，不切模式；首尾帧按点击先后决定角色。
    private func restoreAttachment(_ att: AIVideoService.Attachment) {
        guard let url = att.resolvedURL() else {
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "文件已不存在", subtitle: att.url.lastPathComponent.truncatedFileName())
            return
        }
        switch service.addToReference(url: url) {
        case .added, .duplicate:
            break
        case .unsupportedType:
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "不支持当前素材类型", subtitle: "当前占位不接受该类型素材")
        case .limitReached(let msg):
            project.showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange, title: "无法添加", subtitle: msg)
        }
    }

    private static func videoThumbnail(url: URL) -> NSImage { AIVideoService.videoFrameThumbnail(url: url) }
    private static func audioThumbnail() -> NSImage { AIVideoService.audioPlaceholderThumbnail() }

    private func pickSingleImage(completion: @escaping (URL, NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
            let thumb = img.thumbnailImage(maxSize: 200)
            DispatchQueue.main.async { completion(url, thumb) }
        }
    }

    // MARK: - Actions

    private var inputPlaceholder: String {
        switch service.selectedProvider.category {
        case .video: return "描述你想生成的视频…"
        case .image: return "描述你想生成的图片…"
        case .audio: return "描述你想生成的声音…"
        case .text: return "输入你的问题…"
        }
    }

    private var emptyHintText: String {
        switch service.selectedProvider.category {
        case .video: return "描述你想生成的视频"
        case .image: return "描述你想生成的图片"
        case .audio: return "描述你想生成的声音"
        case .text: return "开始对话"
        }
    }

    private func showProviderMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 180
        IPickerItemHandler.shared.actions.removeAll()
        var tag = 0
        for cat in AIVideoService.ProviderCategory.allCases {
            let header = NSMenuItem(title: cat.rawValue, action: nil, keyEquivalent: "")
            header.isEnabled = false
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            header.attributedTitle = NSAttributedString(string: cat.rawValue, attributes: attrs)
            menu.addItem(header)

            for provider in AIVideoService.Provider.providers(for: cat) {
                let item = NSMenuItem(title: provider.displayName,
                                      action: #selector(IPickerItemHandler.pick(_:)),
                                      keyEquivalent: "")
                item.target = IPickerItemHandler.shared
                item.tag = tag
                item.indentationLevel = 1
                let isSelected = provider.rawValue == settings.aiProvider
                let svc = service
                let sets = settings
                IPickerItemHandler.shared.actions[tag] = {
                    svc.selectedProvider = provider
                    sets.aiProvider = provider.rawValue
                }

                let title = NSMutableAttributedString(string: provider.displayName, attributes: [
                    .font: NSFont.systemFont(ofSize: 13)
                ])
                if isSelected {
                    title.append(NSAttributedString(string: "  ✓", attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor.white
                    ]))
                }
                item.attributedTitle = title
                menu.addItem(item)
                tag += 1
            }
            menu.addItem(.separator())
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        let view = NSApp.keyWindow?.contentView ?? NSView()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isGenerating
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !service.isGenerating else { return }
        inputText = ""
        let refImageURLs = referenceContents.filter { $0.type == .image }.map(\.url)
        let refVideoURLs = referenceContents.filter { $0.type == .video }.map(\.url)
        let refAudioURLs = referenceContents.filter { $0.type == .audio }.map(\.url)
        let firstURL = firstFrameImage?.url
        let lastURL = lastFrameImage?.url
        service.sendPrompt(text, duration: settings.aiDuration, aspectRatio: settings.aiRatio, resolution: settings.aiResolution, imageRatio: settings.aiImageRatio, referenceImages: refImageURLs, referenceVideos: refVideoURLs, referenceAudios: refAudioURLs, firstFrame: firstURL, lastFrame: lastURL)
        referenceContents.removeAll()
        firstFrameImage = nil
        lastFrameImage = nil
    }

    private func insertMediaToTimeline(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        project.importFile(url)
        guard let asset = project.mediaAssets.first(where: { $0.url == url }) else { return }
        let playhead = project.currentTime
        project.pushUndo()

        if ["mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "waveform", iconColor: .blue, title: "AI 音频", subtitle: "已插入音频轨道")
        } else if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"].contains(ext) {
            project.addToTimelineAt(asset, time: playhead, skipUndo: true)
            project.showSuccessToast(icon: "photo", iconColor: .green, title: "AI 图片", subtitle: "已插入图片轨道")
        } else {
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
}

// MARK: - 消息气泡

private struct MessageBubble: View {
    let message: AIVideoService.ChatMessage
    var onInsertToTimeline: (URL) -> Void
    var onRestoreAttachment: (AIVideoService.Attachment) -> Void = { _ in }

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
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.black)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !message.attachments.isEmpty {
                attachmentRow
            }
        }
    }

    /// 气泡底部的参考内容/首尾帧缩略图，点击回填输入区
    private var attachmentRow: some View {
        HStack(spacing: 4) {
            ForEach(message.attachments) { att in
                AttachmentThumb(attachment: att) { onRestoreAttachment(att) }
            }
        }
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
                    VideoThumbnailView(url: message.resolvedVideoURL() ?? url)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "film.stack", svgName: "addToVideoTrack", tip: "插入视频轨道") {
                            onInsertToTimeline(message.resolvedVideoURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedVideoURL() ?? url])
                        }
                    }
                    .frame(width: AIMediaThumbSize.width)
                }

            case .completedImage(let url):
                VStack(alignment: .leading, spacing: 6) {
                    ImageThumbnailView(url: message.resolvedImageURL() ?? url)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "photo.on.rectangle", svgName: "addToImageTrack", tip: "插入图片轨道") {
                            onInsertToTimeline(message.resolvedImageURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedImageURL() ?? url])
                        }
                    }
                    .frame(width: AIMediaThumbSize.width)
                }

            case .completedAudio(let url):
                VStack(alignment: .leading, spacing: 6) {
                    AudioWaveformView(url: message.resolvedAudioURL() ?? url)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("已生成")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelPrimary)
                            .lineLimit(1)

                        Spacer()

                        HoverIconButton(icon: "waveform", svgName: "addToAudioTrack", tip: "插入音频轨道") {
                            onInsertToTimeline(message.resolvedAudioURL() ?? url)
                        }
                        HoverIconButton(icon: "folder", svgName: "folder", tip: "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([message.resolvedAudioURL() ?? url])
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
                MarkdownContentView(text: message.content)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 视频封面

// MARK: - 消息附件缩略图

private struct AttachmentThumb: View {
    let attachment: AIVideoService.Attachment
    var onTap: () -> Void

    @State private var thumbnail: NSImage?
    @State private var missing = false
    @State private var hovering = false

    /// 只标内容类型，不标首/尾角色 —— 角色由点击顺序决定
    private var badge: (icon: String?, text: String?)? {
        switch attachment.kind {
        case .video: return ("video.fill", nil)
        case .audio: return ("waveform", nil)
        case .image, .firstFrame, .lastFrame: return nil
        }
    }

    private var tip: String {
        switch attachment.kind {
        case .video: return "视频 · 点击添加"
        case .audio: return "音频 · 点击添加"
        case .image, .firstFrame, .lastFrame: return "图片 · 点击添加"
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: missing ? "questionmark" : "photo")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(Color.labelSecondary.opacity(0.5))
                        }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(hovering ? 0.5 : 0.15), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if let b = badge {
                    Group {
                        if let t = b.text {
                            Text(t).font(.system(size: 7, weight: .bold))
                        } else if let icon = b.icon {
                            Image(systemName: icon).font(.system(size: 6))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(1.5)
                }
            }
            .opacity(missing ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(missing ? "文件已不存在" : tip)
        .onHover { hovering = $0 }
        .task { await load() }
    }

    private func load() async {
        guard let url = attachment.resolvedURL() else {
            await MainActor.run { missing = true }
            return
        }
        switch attachment.kind {
        case .audio:
            return  // 用占位图标即可
        case .video:
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 120, height: 120)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { thumbnail = ns }
            }
        case .image, .firstFrame, .lastFrame:
            if let img = NSImage(contentsOf: url) {
                let thumb = img.thumbnailImage(maxSize: 120)
                await MainActor.run { thumbnail = thumb }
            }
        }
    }
}

private struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var duration: String = ""
    @ObservedObject private var inline = AIInlinePlayer.shared

    /// 固定宽度，不再随聊天区宽度伸缩
    private var displaySize: CGSize {
        AIMediaThumbSize.fit(thumbnail?.size)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: displaySize.width, height: displaySize.height)
                        // 播放时画面盖在缩略图上，停了自动露回缩略图
                        .overlay {
                            if inline.isPlaying(url), let p = inline.player {
                                InlinePlayerLayer(player: p)
                                    .frame(width: displaySize.width, height: displaySize.height)
                            }
                        }
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .frame(width: AIMediaThumbSize.width, height: 90)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { if thumbnail != nil { InlinePlayButton(url: url) } }

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

// MARK: - 图片缩略图

/// AI 生成结果缩略图的固定尺寸。宽度写死，高度按素材比例算。
/// 宽度必须始终等于 width，否则竖图会比下方状态行窄，右边留出空档
enum AIMediaThumbSize {
    static let width: CGFloat = 140

    static func fit(_ source: CGSize?) -> CGSize {
        guard let s = source, s.width > 0, s.height > 0 else {
            return CGSize(width: width, height: 90)
        }
        return CGSize(width: width, height: width * s.height / s.width)
    }
}

private struct ImageThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    private var displaySize: CGSize {
        AIMediaThumbSize.fit(image?.size)
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displaySize.width, height: displaySize.height)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: AIMediaThumbSize.width, height: 90)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            if let img = NSImage(contentsOf: url) {
                await MainActor.run { image = img }
            }
        }
    }
}

// MARK: - 行内试听

/// AI 面板里缩略图上的试听播放器。全局单例，同一时刻只播一条，
/// 点第二条会自动停掉上一条，避免多条一起响
@MainActor
final class AIInlinePlayer: ObservableObject {
    static let shared = AIInlinePlayer()

    @Published private(set) var playingURL: URL?
    @Published private(set) var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    private init() {}

    func isPlaying(_ url: URL) -> Bool { playingURL == url }

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        let p = AVPlayer(url: url)
        // 播完自动复位成播放态图标
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: p.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in AIInlinePlayer.shared.stop() }
        }
        player = p
        playingURL = url
        p.play()
    }

    func stop() {
        player?.pause()
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        player = nil
        playingURL = nil
    }
}

/// 缩略图上的播放/暂停按钮：半透明黑底圆形 + 白色图标
private struct InlinePlayButton: View {
    let url: URL
    var size: CGFloat = 28
    @ObservedObject private var inline = AIInlinePlayer.shared

    var body: some View {
        Button { inline.toggle(url) } label: {
            Image(nsImage: TimelineSVGIcon.load(inline.isPlaying(url) ? "pause" : "play"))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.43, height: size * 0.43)
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 播放视频时盖在缩略图上的画面层
private struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

// MARK: - 音频波形

private struct AudioWaveformView: View {
    let url: URL
    @State private var samples: [Float] = []
    @State private var duration: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let barCount = max(Int(w / 3), 1)
                let displaySamples = resample(samples, to: barCount)
                HStack(spacing: 1) {
                    ForEach(0..<displaySamples.count, id: \.self) { i in
                        let barH = max(CGFloat(displaySamples[i]) * h, 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accent.opacity(0.8))
                            .frame(width: 2, height: barH)
                    }
                }
                .frame(height: h, alignment: .center)
            }
            .frame(height: 40)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { InlinePlayButton(url: url, size: 24) }

            if !duration.isEmpty {
                Text(duration)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color.labelSecondary)
            }
        }
        .task { await loadWaveform() }
    }

    private func resample(_ input: [Float], to count: Int) -> [Float] {
        guard !input.isEmpty, count > 0 else { return Array(repeating: 0.3, count: max(count, 20)) }
        let step = Float(input.count) / Float(count)
        return (0..<count).map { i in
            let idx = min(Int(Float(i) * step), input.count - 1)
            return input[idx]
        }
    }

    /// 家用机实证：坏掉的音频读取服务会让 copyNextSampleBuffer 永久挂死并占满 Swift 协作池
    /// （详见 ProjectState.loadWaveform）。这里复用同一套专属线程+超时+ffmpeg 兜底的静态方法，
    /// 不直接在 Task 里做同步 AVAssetReader 调用。
    private func loadWaveform() async {
        let u = url
        let (durText, wfSamples): (String?, [Float]) = await withCheckedContinuation { cont in
            Thread.detachNewThread {
                var durText: String? = nil
                if case .success(let d) = ProjectState.durationSyncWithTimeout(url: u, seconds: 10) {
                    let s = Int(d)
                    durText = String(format: "%d:%02d", s / 60, s % 60)
                }
                var wf = Array(repeating: Float(0.3), count: 60)
                if let data = ProjectState.waveformSyncWithTimeout(url: u, timeout: 15) {
                    wf = data.samples
                } else if let data = ProjectState.ffmpegWaveform(url: u) {
                    wf = data.samples
                }
                cont.resume(returning: (durText, wf))
            }
        }
        await MainActor.run {
            if let durText { duration = durText }
            samples = wfSamples
        }
    }
}

// MARK: - Markdown 渲染

private struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(Int, String)
        case code(String, String?)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                i += 1
                continue
            }

            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let m = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let matched = trimmed[m]
                let num = Int(matched.prefix(while: { $0.isNumber })) ?? 1
                blocks.append(.numbered(num, String(trimmed[m.upperBound...])))
            } else if !trimmed.isEmpty {
                blocks.append(.paragraph(trimmed))
            }
            i += 1
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 15 : level == 2 ? 13.5 : 12.5
            inlineMarkdown(text)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.top, 2)

        case .code(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(8)
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .bullet(let text):
            HStack(alignment: .top, spacing: 0) {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
                inlineMarkdown(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(.leading, 12)

        case .numbered(let n, let text):
            HStack(alignment: .top, spacing: 2) {
                Text("\(n).")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Color.white.opacity(0.5))
                inlineMarkdown(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(.leading, 8)

        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.7))
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(text)
    }
}

// MARK: - Hover 图标按钮

private struct HoverIconButton: View {
    let icon: String
    var svgName: String? = nil
    let tip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let svgName, SidebarSVGIcon.svgs[svgName] != nil {
                    Image(nsImage: SidebarSVGIcon.load(svgName))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
            }
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

private extension NSImage {
    func thumbnailImage(maxSize: CGFloat) -> NSImage { aiThumbnail(maxSize: maxSize) }
}
