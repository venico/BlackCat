import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelStates: [WhisperTranscriber.ModelSize: ModelState] = [:]
    var dismiss: () -> Void

    enum ModelState {
        case notDownloaded, downloaded, downloading(Double), failed(String)
    }

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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    fileSection
                    autoSaveSection
                    whisperSection
                    translateSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 540, height: 580)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .onAppear { refreshModelStates() }
    }

    // MARK: - 文件存储

    @ViewBuilder
    private var fileSection: some View {
        pathRow(label: "项目保存位置", path: settings.projectSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
            settings.projectSaveDir = url
        }
        pathRow(label: "导出保存位置", path: settings.exportSaveDir, placeholder: AppSettings.defaultSaveDir.path) { url in
            settings.exportSaveDir = url
        }
    }

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

    // MARK: - 自动保存

    private var autoSaveSection: some View {
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

    // MARK: - 语音识别

    private var whisperSection: some View {
        let displayDir = settings.whisperModelDir ?? WhisperTranscriber.supportDir
        return SSection(title: "") {
            pathRow(label: "语音识别模型存储位置", path: displayDir, placeholder: "", defaultDir: WhisperTranscriber.supportDir) { url in
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

    // MARK: - 翻译来源

    private var translateSection: some View {
        SSection(title: "字幕翻译") {
            IPicker(selection: Binding(
                get: { settings.translateProvider.displayName },
                set: { name in
                    if let p = AppSettings.TranslateProvider.allCases.first(where: { $0.displayName == name }) {
                        settings.translateProvider = p
                    }
                }
            ), options: AppSettings.TranslateProvider.allCases.map { ($0.displayName, $0.displayName) })
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
