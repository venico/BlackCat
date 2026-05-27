import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WelcomeView: View {
    @EnvironmentObject private var project: ProjectState
    @State private var selectedTab = 0  // 0 = 新建, 1 = 打开
    @State private var newProjectName = ""
    @State private var saveDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // 关闭按钮
            HStack {
                Spacer()
                Button { project.showWelcome = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.labelSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.top, 10)
            .padding(.trailing, 10)

            // Logo + 标题
            VStack(spacing: 12) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundColor(Color.accent)
                }
                Text("黑猫剪辑")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color.labelPrimary)
                Text("创建或打开项目开始编辑")
                    .font(.system(size: 12))
                    .foregroundColor(Color.labelSecondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 20)

            // Tab 切换 — 胶囊滑块样式
            HStack(spacing: 2) {
                tabButton(title: "新建项目", index: 0)
                tabButton(title: "打开项目", index: 1)
            }
            .padding(3)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

            // Tab 内容
            if selectedTab == 0 {
                newProjectTab
            } else {
                openProjectTab
            }

            // 错误提示
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 420)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        .onExitCommand { project.showWelcome = false }
    }

    // MARK: - Tab Button
    private func tabButton(title: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = index }
            errorMessage = nil
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? Color.labelPrimary : Color.labelSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(isSelected ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 新建项目
    private var newProjectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 项目名称
            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                TextField("", text: $newProjectName,
                          prompt: Text("输入项目名称").foregroundColor(Color.labelSecondary.opacity(0.5)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color.labelPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.10)))
            }

            // 保存位置
            VStack(alignment: .leading, spacing: 6) {
                Text("保存位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.labelSecondary)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(Color.labelSecondary)
                        Text(saveDirectory?.path ?? "未选择")
                            .font(.system(size: 11))
                            .foregroundColor(saveDirectory == nil
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
                        if panel.runModal() == .OK {
                            saveDirectory = panel.url
                        }
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

            // 新建按钮
            Button {
                createProject()
            } label: {
                Text("新建项目")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canCreate ? .black : Color.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(canCreate ? Color.accent : Color.white.opacity(0.06))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    // MARK: - 打开项目
    private var openProjectTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(Color.labelSecondary.opacity(0.6))
                .padding(.top, 8)

            Text("选择 .bcj 项目文件")
                .font(.system(size: 12))
                .foregroundColor(Color.labelSecondary)

            Button {
                openExistingProject()
            } label: {
                Text("打开项目文件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.accent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    private var canCreate: Bool {
        !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty && saveDirectory != nil
    }

    // MARK: - Actions

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = "请输入项目名称"
            return
        }
        guard let dir = saveDirectory else {
            errorMessage = "请选择保存位置"
            return
        }
        // 检查是否已存在同名文件
        let fileURL = dir.appendingPathComponent("\(name).bcj")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            errorMessage = "该位置已存在同名项目文件"
            return
        }
        project.createNewProject(name: name, directory: dir)
    }

    private func openExistingProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bcj") ?? .json]
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.openProject(url: url)
    }
}
