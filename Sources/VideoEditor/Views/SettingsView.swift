import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelStates: [WhisperTranscriber.ModelSize: ModelState] = [:]
    @State private var selectedTab = 0
    var dismiss: () -> Void

    enum ModelState {
        case notDownloaded, downloaded, downloading(Double), failed(String)
    }

    private let tabs = ["保存位置", "语音识别", "字幕翻译"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelSecondary)
                Spacer()
                Button { dismiss() } label: {
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
            .padding(.bottom, 16)

            Divider().background(Color.divider)

            // 标签栏
            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    Button { selectedTab = i } label: {
                        Text(tabs[i])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(selectedTab == i ? .white : Color.labelSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(selectedTab == i ? Color.white.opacity(0.15) : Color.clear)
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case 0: saveTab
                    case 1: whisperTab
                    case 2: translateTab
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 540, height: 520)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .onAppear { refreshModelStates() }
    }

    // MARK: - 保存位置

    private var saveTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "项目保存位置", path: settings.projectSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
                settings.projectSaveDir = url
            }
            pathRow(label: "导出保存位置", path: settings.exportSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
                settings.exportSaveDir = url
            }

            SSection(title: "自动保存") {
                HStack(spacing: 8) {
                    ForEach(AppSettings.autoSaveOptions, id: \.value) { opt in
                        Button {
                            settings.autoSaveInterval = opt.value
                        } label: {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(settings.autoSaveInterval == opt.value ? .black : Color.labelPrimary)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(settings.autoSaveInterval == opt.value ? Color.accent : Color.white.opacity(0.08))
                                .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if settings.autoSaveInterval == 0 {
                    Text("关闭后需手动保存（⌘S）")
                        .font(.system(size: 10))
                        .foregroundColor(Color.accent.opacity(0.8))
                }
            }
        }
    }

    // MARK: - 语音识别

    private var whisperTab: some View {
        let displayDir = settings.whisperModelDir ?? WhisperTranscriber.supportDir
        return VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "模型存储位置", path: displayDir, placeholder: "", defaultDir: WhisperTranscriber.supportDir) { url in
                settings.whisperModelDir = url
                refreshModelStates()
            }

            Text("识别模型")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)

            VStack(spacing: 4) {
                ForEach(WhisperTranscriber.ModelSize.allCases, id: \.rawValue) { model in
                    modelRow(model)
                }
            }
        }
    }

    // MARK: - 字幕翻译

    private var translateTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            SSection(title: "翻译引擎") {
                IPicker(selection: Binding(
                    get: { settings.translateProvider.displayName },
                    set: { name in
                        if let p = AppSettings.TranslateProvider.allCases.first(where: { $0.displayName == name }) {
                            settings.translateProvider = p
                        }
                    }
                ), options: AppSettings.TranslateProvider.allCases.map { ($0.displayName, $0.displayName) })

                if settings.translateProvider == .google {
                    Text("免费，无需配置")
                        .font(.system(size: 10))
                        .foregroundColor(Color.labelSecondary)
                }

                if settings.translateProvider == .apple {
                    if #available(macOS 15, *) {
                        Text("使用系统内置翻译，无需 API Key（需先在系统设置中下载语言包）")
                            .font(.system(size: 10))
                            .foregroundColor(Color.labelSecondary)
                    } else {
                        Text("Apple 翻译需要 macOS 15 或更高版本")
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }

                if settings.translateProvider.needsAPIKey {
                    apiKeyField(
                        label: settings.translateProvider.keyLabel,
                        placeholder: settings.translateProvider.keyPlaceholder,
                        text: translateKeyBinding
                    )
                }

                if settings.translateProvider.needsSecretKey {
                    apiKeyField(
                        label: settings.translateProvider.secretLabel,
                        placeholder: settings.translateProvider.secretPlaceholder,
                        text: translateSecretBinding
                    )
                }
            }
        }
    }

    // MARK: - 共用组件

    private func pathRow(label: String, path: URL?, placeholder: String, defaultDir: URL? = nil, onSelect: @escaping (URL?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(Color.labelSecondary)
                    Text(path?.path ?? placeholder)
                        .font(.system(size: 11))
                        .foregroundColor(path == nil
                                         ? Color.labelSecondary.opacity(0.5)
                                         : Color.labelPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .cornerRadius(7)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = "选择"
                    if let dir = path ?? defaultDir {
                        panel.directoryURL = dir
                    }
                    if panel.runModal() == .OK { onSelect(panel.url) }
                } label: {
                    Text("选择")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.labelPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                if path != nil {
                    Button { onSelect(nil) } label: {
                        Text("重置")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.labelSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func modelRow(_ model: WhisperTranscriber.ModelSize) -> some View {
        let isSelected = settings.selectedWhisperModel == model
        let state = modelStates[model] ?? .notDownloaded

        return HStack(spacing: 10) {
            Button {
                if case .downloaded = state {
                    settings.selectedWhisperModel = model
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? Color.accent : Color.labelSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(Color.labelPrimary)
                Text(model.sizeDesc)
                    .font(.system(size: 10))
                    .foregroundColor(Color.labelSecondary)
            }

            Spacer()

            switch state {
            case .downloaded:
                Text("已下载")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.8))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
            case .notDownloaded:
                Button { downloadModel(model) } label: {
                    Text("下载")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.accent.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            case .downloading(let pct):
                HStack(spacing: 6) {
                    ProgressView(value: pct)
                        .frame(width: 50)
                        .tint(Color.accent)
                    Text("\(Int(pct * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 28)
                }
            case .failed(let msg):
                HStack(spacing: 6) {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                    Button { downloadModel(model) } label: {
                        Text("重试")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.accent)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Color.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
        .cornerRadius(7)
    }

    private func refreshModelStates() {
        for model in WhisperTranscriber.ModelSize.allCases {
            let url = modelFileURL(model)
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                modelStates[model] = size > model.minFileSize ? .downloaded : .notDownloaded
            } else {
                if case .downloading = modelStates[model] { continue }
                modelStates[model] = .notDownloaded
            }
        }
    }

    private func modelFileURL(_ model: WhisperTranscriber.ModelSize) -> URL {
        let dir = settings.whisperModelDir ?? WhisperTranscriber.supportDir
        return dir.appendingPathComponent(model.fileName)
    }

    private func downloadModel(_ model: WhisperTranscriber.ModelSize) {
        modelStates[model] = .downloading(0)
        Task {
            do {
                try await WhisperTranscriber.downloadModel(model) { pct in
                    DispatchQueue.main.async { modelStates[model] = .downloading(pct) }
                }
                await MainActor.run {
                    modelStates[model] = .downloaded
                    settings.selectedWhisperModel = model
                }
            } catch {
                await MainActor.run {
                    modelStates[model] = .failed(error.localizedDescription)
                }
            }
        }
    }

    private var translateKeyBinding: Binding<String> {
        switch settings.translateProvider {
        case .deepL:
            return Binding(get: { settings.deeplAPIKey }, set: { settings.deeplAPIKey = $0 })
        case .youdao:
            return Binding(get: { settings.youdaoAppKey }, set: { settings.youdaoAppKey = $0 })
        case .volcano:
            return Binding(get: { settings.volcanoAccessKeyId }, set: { settings.volcanoAccessKeyId = $0 })
        default:
            return .constant("")
        }
    }

    private var translateSecretBinding: Binding<String> {
        switch settings.translateProvider {
        case .youdao:
            return Binding(get: { settings.youdaoAppSecret }, set: { settings.youdaoAppSecret = $0 })
        case .volcano:
            return Binding(get: { settings.volcanoSecretAccessKey }, set: { settings.volcanoSecretAccessKey = $0 })
        default:
            return .constant("")
        }
    }

    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.labelSecondary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.labelPrimary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.06))
                .cornerRadius(7)
        }
    }
}

// MARK: - Section

private struct SSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary).tracking(0.4)
            }
            content
        }
    }
}
