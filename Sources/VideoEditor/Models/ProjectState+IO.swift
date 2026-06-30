import SwiftUI
import AVFoundation

// MARK: - Project File Management (.bcj)

extension ProjectState {

    func createNewProject(name: String, directory: URL) {
        projectName = name
        let fileURL = directory.appendingPathComponent("\(name).bcj")
        projectFileURL = fileURL
        // 重置到空项目状态（素材库保留，不清空）
        videoTracks = [Track(label: "视频")]
        audioTracks = []
        imageTracks = []
        subtitleTracks = []
        textTracks = []
        subtitleBottomMargin = 5
        subtitleLineSpacing = 6
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0; duration = 60
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedTextClipID = nil
        selectedClipIDs.removeAll()
        assetThumbnails.removeAll()
        waveformCache.removeAll()
        imageVideoCache.removeAll()
        playerItem = nil
        showWelcome = false
        isSaved = true
        // 为保留的素材重新生成缩略图
        for asset in mediaAssets {
            if mediaThumbnails[asset.id] == nil {
                loadMediaResources(asset)
            }
        }
        saveProject(silent: true)
    }

    func openProject(url: URL) {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法打开项目"
                alert.informativeText = "文件不存在：\(url.lastPathComponent)\n路径：\(url.path)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法访问项目文件"
                alert.informativeText = "系统安全权限不足，请重新选择文件或检查权限设置。\n路径：\(url.path)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
        accessedURLs.append(url)
        defer { /* keep access alive */ }

        guard let data = try? Data(contentsOf: url) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法读取项目"
                alert.informativeText = "文件可能已损坏：\(url.lastPathComponent)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
        guard let doc = try? JSONDecoder().decode(ProjectDocument.self, from: data) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "无法解析项目"
                alert.informativeText = "文件格式不正确：\(url.lastPathComponent)"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }

        projectName = url.deletingPathExtension().lastPathComponent
        projectFileURL = url
        videoTracks = doc.videoTracks
        audioTracks = doc.audioTracks
        imageTracks = doc.imageTracks
        // 加载字幕轨道，兼容旧 .bcj（subtitleStyles 单独数组）：把旧 style 迁移进 track
        var loadedSubtitleTracks = doc.subtitleTracks
        for i in loadedSubtitleTracks.indices {
            if loadedSubtitleTracks[i].subtitleStyle == nil,
               i < doc.subtitleStyles.count {
                loadedSubtitleTracks[i].subtitleStyle = doc.subtitleStyles[i]
            }
        }
        subtitleTracks = loadedSubtitleTracks
        textTracks = doc.textTracks ?? []
        textTemplates = doc.textTemplates ?? []
        subtitleBottomMargin = doc.subtitleBottomMargin ?? doc.subtitleStyles.first?.bottomMargin ?? 5
        subtitleLineSpacing = doc.subtitleLineSpacing ?? doc.subtitleStyles.first?.lineSpacing ?? 6
        overlayTrackOrder = doc.overlayTrackOrder ?? []
        exportSettings = doc.exportSettings
        previewResolution = doc.previewResolution

        // 恢复媒体资源（以项目文件为准，完全替换）
        mediaAssets.removeAll()
        mediaThumbnails.removeAll()
        for asset in doc.mediaAssets {
            if asset.url.startAccessingSecurityScopedResource() {
                accessedURLs.append(asset.url)
            }
            mediaAssets.append(asset)
            loadMediaResources(asset)
        }

        // 重建时间轴缩略图和波形
        for track in videoTracks {
            for clip in track.clips {
                if let url = clip.url {
                    loadTimelineThumbnails(assetID: clip.assetID, url: url)
                }
            }
        }
        for track in audioTracks {
            for clip in track.clips {
                if let url = clip.url {
                    loadWaveform(assetID: clip.assetID, url: url)
                }
            }
        }

        syncOverlayOrder()
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0
        showWelcome = false
        isSaved = true
        rebuildTimelinePreview()
    }

    /// Schedule auto-save after a 3-second idle period.
    /// Each call resets the timer, so rapid edits are batched.
    func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        let interval = AppSettings.shared.autoSaveInterval
        guard interval > 0 else { return }
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, !self.isSaved, self.projectFileURL != nil else { return }
            self.saveProject(silent: true)
        }
    }

    func saveProject(silent: Bool = false) {
        if projectFileURL == nil && !silent {
            let panel = NSSavePanel()
            panel.title = "保存项目"
            panel.nameFieldStringValue = (projectName.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名项目" : projectName) + ".bcj"
            panel.allowedContentTypes = [.init(filenameExtension: "bcj") ?? .json]
            panel.canCreateDirectories = true
            panel.directoryURL = AppSettings.shared.effectiveProjectDir
            guard panel.runModal() == .OK, let url = panel.url else { return }
            projectName = url.deletingPathExtension().lastPathComponent
            projectFileURL = url
        } else if projectFileURL == nil {
            let docDir = AppSettings.shared.effectiveProjectDir
            let name = projectName.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名项目" : projectName
            projectName = name
            projectFileURL = docDir.appendingPathComponent("\(name).bcj")
        }
        guard let fileURL = projectFileURL else { return }
        let doc = ProjectDocument(
            name: projectName,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            imageTracks: imageTracks,
            subtitleTracks: subtitleTracks,
            subtitleStyles: subtitleTracks.map { $0.subtitleStyle ?? SubtitleStyle() },  // 向后兼容旧格式
            textTracks: textTracks,
            textTemplates: textTemplates.isEmpty ? nil : textTemplates,
            mediaAssets: mediaAssets,
            exportSettings: exportSettings,
            previewResolution: previewResolution,
            subtitleBottomMargin: subtitleBottomMargin,
            subtitleLineSpacing: subtitleLineSpacing,
            overlayTrackOrder: overlayTrackOrder.isEmpty ? nil : overlayTrackOrder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            isSaved = true
        } catch {
            isSaved = false
            if silent {
                showImportToast("自动保存失败：\(error.localizedDescription)")
            } else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return
        }
        guard !silent else { return }
        showSuccessToast(icon: "checkmark", title: "已保存", subtitle: fileURL.lastPathComponent, revealURL: fileURL)
    }

    /// Show a brief import feedback toast (auto-dismiss after 3 seconds)
    func showImportToast(_ message: String) {
        importToastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.importToastMessage == message {
                self?.importToastMessage = nil
            }
        }
    }
}
