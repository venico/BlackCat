import SwiftUI
import AppKit

/// 新建项目表单。两处用：
///   1. 窗口内（欢迎页/主界面点新建）——ContentView 的 .sheet
///   2. 一个窗口都没有时点菜单新建——独立面板，见 WindowManager.showNewProjectPanel
/// 所以它**不持有 ProjectState**——「建在哪」由调用方通过 onCreate 决定，
/// 表单只管收集名字和目录、做校验
struct NewProjectSheet: View {
    let onCancel: () -> Void
    /// 校验通过后回调。调用方决定是就地建还是开新窗口
    let onCreate: (String, URL) -> Void

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
                // 填完名字直接回车就建，不用去点按钮。
                // modifiers: [] 是必须的——默认带 .command，那样就成了 ⌘↩
                .keyboardShortcut(.return, modifiers: [])
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
        onCreate(n, dir)
    }
}
