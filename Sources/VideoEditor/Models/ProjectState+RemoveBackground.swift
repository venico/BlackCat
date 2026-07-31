// ProjectState+RemoveBackground.swift
// 去除图片背景：抠出主体存成透明 PNG，结果单独新建一条图片轨道，原片段保持不动。
import Foundation
import AppKit

extension ProjectState {

    /// 只有选中图片片段时可用
    var canRemoveImageBackground: Bool {
        guard !isRemovingBackground else { return false }
        return selectedImageClipID != nil
    }

    func removeBackgroundForSelection(mode: BackgroundRemover.Mode) {
        guard !isRemovingBackground else { return }

        guard let id = selectedImageClipID,
              let clip = imageTracks.flatMap(\.clips).first(where: { $0.id == id }),
              let url = clip.imageURL ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                             title: "去除背景", subtitle: "请先选中一个图片片段")
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "去除背景", subtitle: "源文件不存在", autoCountdown: false)
            return
        }

        removeBackgroundState = .processing
        removeBackgroundTask = Task { @MainActor in
            do {
                let outURL = try await BackgroundRemover.removeBackground(
                    from: url,
                    outputName: url.deletingPathExtension().lastPathComponent,
                    mode: mode,
                    onStage: { [weak self] stage in
                        Task { @MainActor in
                            // 已经取消就别再把状态改回处理中，否则卡片会闪回来
                            guard let self, self.isRemovingBackground else { return }
                            self.removeBackgroundState = stage
                        }
                    })
                try Task.checkCancellation()
                let ok = addRemovedBackgroundTrack(url: outURL, source: clip)
                removeBackgroundState = .idle
                removeBackgroundTask = nil
                if ok {
                    showSuccessToast(icon: "checkmark", iconColor: .green,
                                     title: "去除背景", subtitle: "已新建图片轨道",
                                     revealURL: outURL)
                } else {
                    showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                                     title: "去除背景",
                                     subtitle: "处理完成但轨道创建失败，文件已保存",
                                     autoCountdown: false, revealURL: outURL)
                }
            } catch is CancellationError {
                // 取消的提示由 cancelRemoveBackground() 统一弹，这里只复位
                removeBackgroundState = .idle
                removeBackgroundTask = nil
            } catch {
                removeBackgroundState = .idle
                removeBackgroundTask = nil
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "去除背景", subtitle: error.localizedDescription,
                                 autoCountdown: false)
            }
        }
    }

    /// 新建一条图片轨道放去背结果，画面属性沿用原片段，两层叠起来位置才对得上
    @discardableResult
    private func addRemovedBackgroundTrack(url: URL, source: ImageClip) -> Bool {
        // 会新增素材，快照必须带上 mediaAssets，否则撤销后素材还在、文件却对不上
        pushUndoSavingAssets()

        let name = url.deletingPathExtension().lastPathComponent
        importFileDirectly(url: url, type: .image, displayName: name)
        guard let asset = mediaAssets.first(where: { $0.url == url }) else {
            NSLog("[RemoveBG] 导入失败: %@", url.path)
            return false
        }

        var clip = ImageClip(assetID: asset.id, name: name, imageURL: url,
                             startTime: source.startTime, endTime: source.endTime)
        // 去背输出保持了原始尺寸，所以这些属性可以照搬
        clip.imageWidth  = source.imageWidth
        clip.imageHeight = source.imageHeight
        clip.scaleX      = source.scaleX
        clip.scaleY      = source.scaleY
        clip.lockAspect  = source.lockAspect
        clip.offsetX     = source.offsetX
        clip.offsetY     = source.offsetY
        clip.cropTop     = source.cropTop
        clip.cropBottom  = source.cropBottom
        clip.cropLeft    = source.cropLeft
        clip.cropRight   = source.cropRight
        clip.mirrorH     = source.mirrorH
        clip.mirrorV     = source.mirrorV
        clip.rotation    = source.rotation

        imageTracks.append(Track(clips: [clip], label: name))
        // 图片轨归 overlay 管，不同步 order 的话轨道建了也不显示
        syncOverlayOrder()
        rebuildTimelinePreview()
        return true
    }
}
