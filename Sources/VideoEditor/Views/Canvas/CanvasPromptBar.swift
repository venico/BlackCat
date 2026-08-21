import SwiftUI

/// 选中图片/视频/音频节点时，从画布底部升起的输入框（v5.1.0，B4）
///
/// 模型、子模型、比例这些下拉直接复用「设置 → AI 设置」那套配置，
/// 不另起一份 —— app 里已经有两套大模型配置了，再多一套只会更乱。
struct CanvasPromptBar: View {
    @EnvironmentObject var project: ProjectState
    @ObservedObject var canvas: CanvasState
    @ObservedObject private var service = AIVideoService.shared
    @ObservedObject private var settings = AppSettings.shared

    let node: CanvasNode

    @State private var draftPrompt: String = ""
    @FocusState private var focused: Bool

    /// 这个节点连进来的上游 —— 它们是这次生成的参考
    private var upstream: [CanvasNode] { canvas.upstreamNodes(of: node.id) }

    private var category: AIVideoService.ProviderCategory {
        switch node.kind {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .text:  return .text
        }
    }

    /// 这类节点该用哪个模型。每种类型各记各的 —— 选中图片卡片就该是图片模型
    private var provider: AIVideoService.Provider {
        let saved = settings.canvasProvider(for: category.rawValue)
        if let p = AIVideoService.Provider(rawValue: saved), p.category == category, !p.isHidden {
            return p
        }
        return matchingProviders.first ?? service.selectedProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !upstream.isEmpty { referenceRow }

            TextEditor(text: $draftPrompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if draftPrompt.isEmpty {
                        Text(node.kind == .text ? "描述你想要生成的文字内容" : "描述你想要生成的画面内容")
                            .font(.system(size: 12))
                            .foregroundColor(Color.labelSecondary.opacity(0.45))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            bottomRow
        }
        .padding(14)
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .onAppear { draftPrompt = node.prompt }
        .onChange(of: node.id) { _, _ in draftPrompt = node.prompt }
    }

    /// 上游节点作为参考挂在输入框上方，顺序就是连线先后
    private var referenceRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(upstream.enumerated()), id: \.element.id) { index, up in
                HStack(spacing: 4) {
                    Image(nsImage: SidebarSVGIcon.load(CanvasNodeView.iconKey(for: up.kind), size: 11))
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                    Text(refLabel(up))
                        .font(.system(size: 10))
                        .lineLimit(1)
                    // 顺序对生成有影响（首图/次图），标出来
                    Text("\(index + 1)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Color.labelSecondary.opacity(0.6))
                }
                .foregroundColor(Color.labelSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer()
            Text("已作为参考")
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary.opacity(0.6))
        }
    }

    private func refLabel(_ up: CanvasNode) -> String {
        switch up.kind {
        case .text:
            let t = up.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "文本" : String(t.prefix(10))
        default:
            return up.mediaURL?.lastPathComponent ?? up.kind.label
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            // 供应商 + 子模型，跟 AI 面板一样按类型过滤
            capsule(currentProviderLabel) { showProviderMenu() }
            if !provider.subModels.isEmpty {
                capsule(currentSubModelLabel) { showSubModelMenu() }
            }
            if node.kind != .text && node.kind != .audio {
                capsule(ratioLabel) { showRatioMenu() }
            }
            // 视频还要选时长和清晰度
            if node.kind == .video {
                capsule("\(settings.aiDuration)s") { showDurationMenu() }
                capsule(settings.aiResolution) { showResolutionMenu() }
            }
            // 文字模型：推理强度在前，联网在后
            if node.kind == .text {
                if !provider.reasoningLevels.isEmpty {
                    capsule(reasoningLabel) { showReasoningMenu() }
                }
                if provider.supportsWebSearch || !settings.braveSearchKey.isEmpty || !settings.tavilySearchKey.isEmpty {
                    Button { service.webSearchEnabled.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: SidebarSVGIcon.load("webSearch", size: 11))
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                            Text("联网").font(.system(size: 10))
                        }
                        .foregroundColor(service.webSearchEnabled ? Color.accent : Color.labelSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(service.webSearchEnabled ? 0.14 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("让模型联网查资料")
                }
            }

            Spacer()

            if node.isGenerating || node.isWaiting {
                Button { canvas.cancelGeneration(nodeID: node.id) } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(node.isWaiting ? "等上游" : "生成中")
                            .font(.system(size: 11))
                            .foregroundColor(Color.labelSecondary)
                    }
                }
                .buttonStyle(.plain)
                .help("点一下取消")
            } else {
                Button { submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var currentProviderLabel: String { provider.displayName }

    private var currentSubModelLabel: String {
        let saved = settings.providerModel(for: provider.rawValue)
        return provider.subModels.first { $0.id == saved }?.label
            ?? provider.subModels.first?.label ?? ""
    }

    private var ratioLabel: String {
        node.kind == .image ? settings.aiImageRatio : settings.aiRatio
    }

    private func capsule(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).font(.system(size: 10)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundColor(Color.labelSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 下拉

    /// 只列跟这个节点类型对得上的供应商 —— 图片节点没必要列视频模型
    private var matchingProviders: [AIVideoService.Provider] {
        AIVideoService.Provider.allCases.filter { !$0.isHidden && $0.category == category }
    }

    private func showProviderMenu() {
        let menu = NSMenu()
        for p in matchingProviders {
            let item = NSMenuItem(title: p.displayName, action: nil, keyEquivalent: "")
            item.representedObject = p.rawValue
            item.target = MenuBridge.shared
            item.action = #selector(MenuBridge.pickProvider(_:))
            menu.addItem(item)
        }
        let cat = category.rawValue
        MenuBridge.shared.onPickProvider = { raw in
            settings.setCanvasProvider(raw, for: cat)
        }
        popUp(menu)
    }

    private func showSubModelMenu() {
        let menu = NSMenu()
        let provider = self.provider
        for m in provider.subModels {
            let item = NSMenuItem(title: m.label, action: #selector(MenuBridge.pickSubModel(_:)), keyEquivalent: "")
            item.representedObject = m.id
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickSubModel = { id in
            settings.setProviderModel(id, for: provider.rawValue)
        }
        popUp(menu)
    }

    private func showRatioMenu() {
        let menu = NSMenu()
        let options = node.kind == .image
            ? ["1:1", "16:9", "9:16", "4:3", "3:4", "21:9"]
            : ["16:9", "9:16", "1:1", "4:3"]
        for r in options {
            let item = NSMenuItem(title: r, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = r
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        let isImage = node.kind == .image
        let nodeID = node.id
        MenuBridge.shared.onPickRatio = { [weak canvas] r in
            if isImage { settings.aiImageRatio = r } else { settings.aiRatio = r }
            canvas?.setRatio(r, for: nodeID)   // 卡片跟着变形
        }
        popUp(menu)
    }

    private var reasoningLabel: String {
        let saved = settings.providerReasoning(for: provider.rawValue)
        return provider.reasoningLevels.first { $0.value == saved }?.label
            ?? provider.reasoningLevels.first?.label ?? "推理"
    }

    private func showDurationMenu() {
        let menu = NSMenu()
        for d in ["4", "5", "6", "8", "10"] {
            let item = NSMenuItem(title: "\(d) 秒", action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = d
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.aiDuration = $0 }
        popUp(menu)
    }

    private func showResolutionMenu() {
        let menu = NSMenu()
        for r in ["480P", "720P", "1080P"] {
            let item = NSMenuItem(title: r, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = r
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.aiResolution = $0 }
        popUp(menu)
    }

    private func showReasoningMenu() {
        let menu = NSMenu()
        let p = provider
        for level in p.reasoningLevels {
            let item = NSMenuItem(title: level.label, action: #selector(MenuBridge.pickRatio(_:)), keyEquivalent: "")
            item.representedObject = level.value
            item.target = MenuBridge.shared
            menu.addItem(item)
        }
        MenuBridge.shared.onPickRatio = { settings.setProviderReasoning($0, for: p.rawValue) }
        popUp(menu)
    }

    private func popUp(_ menu: NSMenu) {
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    private func submit() {
        canvas.updateNode(id: node.id) { $0.prompt = draftPrompt }
        canvas.submitGeneration(nodeID: node.id, provider: provider)
    }
}

/// NSMenu 的 target 得是 NSObject。SwiftUI 结构体当不了 target，
/// 拿一个常驻的桥接对象转发
final class MenuBridge: NSObject {
    static let shared = MenuBridge()
    var onPickProvider: ((String) -> Void)?
    var onPickSubModel: ((String) -> Void)?
    var onPickRatio: ((String) -> Void)?

    @objc func pickProvider(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String { onPickProvider?(raw) }
    }
    @objc func pickSubModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onPickSubModel?(id) }
    }
    @objc func pickRatio(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? String { onPickRatio?(r) }
    }
}
