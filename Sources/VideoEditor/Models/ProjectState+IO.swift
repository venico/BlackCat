import SwiftUI
import AVFoundation

// MARK: - Project File Management (.bcj)

extension ProjectState {

    func createNewProject(name: String, directory: URL) {
        projectName = name
        let fileURL = directory.appendingPathComponent("\(name).bcj")
        projectFileURL = fileURL
        // 重置到空项目状态（素材库保留，不清空）
        // 跟冷启动保持一致：六种类型各留一条空轨
        videoTracks = [Track(label: "视频")]
        audioTracks = [Track(label: "音频")]
        imageTracks = [Track(label: "图片")]
        subtitleTracks = [ProjectState.makeEmptySubtitleTrack()]
        textTracks = [Track(label: "文字")]
        shapeTracks = [Track(label: "图形")]
        filterTracks = []
        adjustTracks = []
        overlayTrackOrder.removeAll()
        cover = nil
        videoSectionOrder.removeAll()
        audioSectionOrder.removeAll()
        seedDefaultTrackOrder()
        subtitleBottomMargin = 5
        subtitleLineSpacing = 6
        undoStack.removeAll(); redoStack.removeAll()
        undoCount = 0; redoCount = 0
        currentTime = 0; duration = 60
        selectedVideoClipID = nil; selectedAudioClipID = nil
        selectedImageClipID = nil; selectedSubtitleClipID = nil
        selectedTextClipID = nil; selectedShapeClipID = nil
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

    /// 打开项目失败时的提示。测试环境下只写日志——没人点「确定」的话
    /// `runModal()` 会永久阻塞主线程，把整套测试卡死（见 DiagLog.isUnitTesting）
    private func reportOpenFailure(_ title: String, _ detail: String) {
        guard !DiagLog.isUnitTesting else {
            DiagLog.log("[打开项目] \(title)：\(detail)")
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    func openProject(url: URL) {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            reportOpenFailure("无法打开项目",
                              "文件不存在：\(url.lastPathComponent)\n路径：\(url.path)")
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            reportOpenFailure("无法访问项目文件",
                              "系统安全权限不足，请重新选择文件或检查权限设置。\n路径：\(url.path)")
            return
        }
        accessedURLs.append(url)
        defer { /* keep access alive */ }

        guard let data = try? Data(contentsOf: url) else {
            reportOpenFailure("无法读取项目", "文件可能已损坏：\(url.lastPathComponent)")
            return
        }
        // 解码失败要把真实原因记下来 —— `try?` 会把 DecodingError 整个吞掉，
        // 界面只剩一句「文件格式不正确」，缺哪个字段全靠猜
        let decoded: ProjectDocument?
        do {
            decoded = try JSONDecoder().decode(ProjectDocument.self, from: data)
        } catch {
            DiagLog.log("[打开项目] 解析失败 \(url.lastPathComponent)：\(error)")
            decoded = nil
        }
        guard let doc = decoded else {
            reportOpenFailure("无法解析项目", "文件格式不正确：\(url.lastPathComponent)")
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
        shapeTracks = doc.shapeTracks ?? []
        filterTracks = doc.filterTracks ?? []
        adjustTracks = doc.adjustTracks ?? []
        subtitleBottomMargin = doc.subtitleBottomMargin ?? doc.subtitleStyles.first?.bottomMargin ?? 5
        subtitleLineSpacing = doc.subtitleLineSpacing ?? doc.subtitleStyles.first?.lineSpacing ?? 6
        overlayTrackOrder = doc.overlayTrackOrder ?? []
        cover = doc.cover
        compoundTracks = doc.compoundTracks ?? []
        videoSectionOrder = doc.videoSectionOrder ?? []
        audioSectionOrder = doc.audioSectionOrder ?? []
        effectTracks = doc.effectTracks ?? []

        // 新文件带整组标签页，直接用；老文件没有这一层，
        // 上面刚读进来的那套轨道就是它唯一的时间线，收成一个标签页
        if let saved = doc.tabs, !saved.isEmpty {
            tabs = saved
            activeTab = min(max(doc.activeTab ?? 0, 0), saved.count - 1)
            // 全关着的话至少把当前这个打开，否则轨道区空着还找不回来
            if !tabs.contains(where: { $0.isTabOpen }) { tabs[activeTab].isTabOpen = true }
        } else if tabs.count == 1 {
            tabs[0].name = "时间线 1"
        }

        exportSettings = doc.exportSettings
        previewResolution = doc.previewResolution
        previewAspectRatio = doc.previewAspectRatio ?? "原始"
        customOutputWidth  = doc.customOutputWidth  ?? 1920
        customOutputHeight = doc.customOutputHeight ?? 1080
        projectFPS         = doc.projectFPS         ?? 30
        projectBitrate     = doc.projectBitrate     ?? 5000

        // 素材库是全局的，打开项目**不能**清空它 —— 那会连带端掉别的项目的素材。
        // 项目文件里带的素材并进全局库；同一个文件全局库已有时不新增，
        // 而是把这个项目里引用旧 id 的片段重映射到全局那条上（改全局的 id 会让别的项目失效）
        let remap = MediaLibrary.shared.merge(doc.mediaAssets)
        if !remap.isEmpty {
            remapAssetIDs(remap)
            DiagLog.log("[素材库] 打开项目重映射了 \(remap.count) 条素材引用")
        }
        for asset in MediaLibrary.shared.assets where mediaThumbnails[asset.id] == nil {
            loadMediaResources(asset)
        }
        reportMissingAssetReferences()
        refreshMissingAssets()

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
        let recordedName = projectName
        Task { @MainActor in RecentProjects.shared.record(url: url, name: recordedName) }
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
        // 测试环境下弹保存面板同样会卡死主线程，直接放弃这次保存
        if projectFileURL == nil && !silent && DiagLog.isUnitTesting {
            DiagLog.log("[保存项目] 测试环境跳过 NSSavePanel，未保存")
            return
        }
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
            shapeTracks: shapeTracks.isEmpty ? nil : shapeTracks,
            filterTracks: filterTracks.isEmpty ? nil : filterTracks,
            adjustTracks: adjustTracks.isEmpty ? nil : adjustTracks,
            effectTracks: effectTracks.isEmpty ? nil : effectTracks,
            // 新文件真正读的是 tabs；上面那些散字段照旧写着，
            // 老版本 app 打开这个文件时还能读出第一个标签页的内容
            tabs: tabs,
            activeTab: activeTab,
            // 素材库已全局化（v5.1.0），项目文件不再存素材清单。
            // 字段留着写空数组、不改成 optional —— 老版本 app 那边它是必需字段，
            // 省掉这个键会让旧版本直接解析失败、项目打不开
            mediaAssets: [],
            exportSettings: exportSettings,
            previewResolution: previewResolution,
            previewAspectRatio: previewAspectRatio,
            customOutputWidth: customOutputWidth,
            customOutputHeight: customOutputHeight,
            projectFPS: projectFPS,
            projectBitrate: projectBitrate,
            subtitleBottomMargin: subtitleBottomMargin,
            subtitleLineSpacing: subtitleLineSpacing,
            cover: cover,
            overlayTrackOrder: overlayTrackOrder.isEmpty ? nil : overlayTrackOrder,
            compoundTracks: compoundTracks.isEmpty ? nil : compoundTracks,
            videoSectionOrder: videoSectionOrder.isEmpty ? nil : videoSectionOrder,
            audioSectionOrder: audioSectionOrder.isEmpty ? nil : audioSectionOrder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            isSaved = true
            // 进「最近文件」。放在写盘成功之后——写失败的项目不该出现在列表里
            let recordedName = projectName
            Task { @MainActor in RecentProjects.shared.record(url: fileURL, name: recordedName) }
        } catch {
            isSaved = false
            if silent {
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "自动保存失败",
                                 subtitle: error.localizedDescription)
            } else if DiagLog.isUnitTesting {
                DiagLog.log("[保存项目] 保存失败：\(error.localizedDescription)")
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
        // 带 revealURL 时 subtitle 后面还要接「 · 点击查看」，名字预算相应收窄
        showSuccessToast(icon: "checkmark", title: "已保存",
                         subtitle: fileURL.lastPathComponent.truncatedFileName(maxVisualWidth: 15),
                         revealURL: fileURL)
    }
}
