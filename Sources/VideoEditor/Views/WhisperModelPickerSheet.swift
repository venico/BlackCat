import SwiftUI

struct WhisperModelPickerSheet: View {
    @EnvironmentObject private var project: ProjectState
    @State private var selected: WhisperTranscriber.ModelSize = .small

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 16))
                Text("语音识别模型")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Text("首次使用需下载语音识别模型，请选择合适的模型：")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            // Model list
            VStack(spacing: 6) {
                ForEach(WhisperTranscriber.ModelSize.allCases, id: \.rawValue) { model in
                    modelRow(model)
                }
            }
            .padding(.horizontal, 16)

            Spacer().frame(height: 16)

            // Actions
            HStack {
                Button("取消") {
                    project.showWhisperModelPicker = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("下载并识别") {
                    project.selectedWhisperModel = selected
                    project.showWhisperModelPicker = false
                    project.downloadModelAndTranscribe()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 340)
        .onAppear { selected = project.selectedWhisperModel }
    }

    private func modelRow(_ model: WhisperTranscriber.ModelSize) -> some View {
        let isSelected = selected == model
        let downloaded = FileManager.default.fileExists(
            atPath: WhisperTranscriber.downloadedModelURL(model).path)
        return Button {
            selected = model
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .medium))
                        if model == .small {
                            Text("推荐")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .cornerRadius(3)
                        }
                        if downloaded {
                            Text("已下载")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                    }
                    Text(model.sizeDesc)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.04))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
