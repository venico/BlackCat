import SwiftUI
import AppKit

/// 新建项目表单。原来是欢迎页里的一个 Tab，欢迎页改成「侧栏动作 + 最近文件」
/// 之后没地方摆了，抽成 sheet。表单本身的逻辑（校验、同名检查）原样搬过来。
struct NewProjectSheet: View {
    @EnvironmentObject private var project: ProjectState
    let onCancel: () -> Void

    @State private var name = ""
    @State private var directory: URL? = AppSettings.shared.effectiveProjectDir
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && directory != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建项目")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.labelPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                FocusTextField(text: $name, placeholder: "输入项目名称")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保存位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(nsImage: SidebarSVGIcon.load("folder"))
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(Color.labelSecondary)
                        Text(directory?.path ?? "未选择")
                            .font(.system(size: 11))
                            .foregroundColor(directory == nil
                                             ? Color.labelSecondary.opacity(0.5)
                                             : Color.labelPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(7)

                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "选择"
                        if panel.runModal() == .OK { directory = panel.url }
                    } label: {
                        Text("选择")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.labelPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 12))
                        .foregroundColor(Color.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Button(action: create) {
                    Text("新建")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(canCreate ? .black : Color.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(canCreate ? Color.accent : Color.white.opacity(0.06))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.black.opacity(0.30))
        .floatingPanelMaterial()
        .onExitCommand(perform: onCancel)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { errorMessage = "请输入项目名称"; return }
        guard let dir = directory else { errorMessage = "请选择保存位置"; return }
        // 同名保护：createNewProject 会直接落盘，撞名等于覆盖别人的项目
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(n).bcj").path) {
            errorMessage = "该位置已存在同名项目文件"
            return
        }
        onCancel()   // 先收起 sheet，再建项目——不然欢迎页关掉时 sheet 会留在屏幕上
        project.createNewProject(name: n, directory: dir)
    }
}
