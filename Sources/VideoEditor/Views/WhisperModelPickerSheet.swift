import SwiftUI

struct WhisperModelPickerSheet: View {
    @EnvironmentObject private var project: ProjectState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: WhisperTranscriber.ModelSize = .small

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("语音识别模型")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
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
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.divider)

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text("首次使用需下载语音识别模型，请选择合适的模型：")
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)

                VStack(spacing: 6) {
                    ForEach(WhisperTranscriber.ModelSize.allCases, id: \.rawValue) { model in
                        modelRow(model)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider().background(Color.divider)

            // Action row
            HStack(spacing: 16) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("取消").font(.system(size: 13))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 80, height: 36)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    project.selectedWhisperModel = selected
                    dismiss()
                    project.downloadModelAndTranscribe()
                } label: {
                    Text("下载并识别")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 120, height: 36)
                        .background(Color.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
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
                    .foregroundColor(isSelected ? Color.accent : Color.labelSecondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.labelPrimary)
                        if model == .small {
                            Text("推荐")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accent)
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
                        .foregroundColor(Color.labelSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accent.opacity(0.1) : Color.white.opacity(0.04))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
