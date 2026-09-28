// AgentTools+CanvasEdit.swift
//
// 画布卡片上那条操作条 + 右键菜单里的事：成组、副本、裁剪、镜像、旋转、
// 存素材库、另存到磁盘，以及卡片上的去背景 / 清晰度提升 / 分离音频。
//
// 处理逻辑都是界面那边现成的（CanvasImageOps / CanvasVideoOps / BackgroundRemover /
// 超分流水线 / AudioSeparator），这里只是照着操作条的做法串起来 ——
// 产物进素材库、就地换内容还是另起一张卡片，跟用户手点的结果一致。

import AVFoundation
import AppKit
import Foundation

extension AgentToolbox {

    static var canvasEditTools: [AgentToolSpec] {
        [
            AgentToolSpec(
                name: "canvas_edit",
                description: """
                改画布上的卡片（id 用 read_canvas 查）。
                group：把 node_ids 几张并成一组（name 可选）；ungroup：解散 group_id；group_color：给组换颜色。
                duplicate：给 node_ids 各做一份副本（连线一起带）。
                crop：按 x/y/width/height（都是卡片画面的百分比，左上为原点）裁剪图片或视频卡片。
                mirror_h / mirror_v / rotate：水平镜像、垂直镜像、顺时针转 90°（就地替换卡片内容）。
                save_to_library：把卡片内容存进素材库；export：复制到磁盘 path。
                remove_background：抠图，结果另起一张卡片；upscale：清晰度提升（视频，慢，后台跑）；
                separate_audio：把声音拆成人声 / 伴奏等，每轨一张音频卡片（后台跑）。
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string",
                                   "enum": ["group", "ungroup", "group_color", "duplicate", "crop",
                                            "mirror_h", "mirror_v", "rotate", "save_to_library", "export",
                                            "remove_background", "upscale", "separate_audio"]],
                        "node_id": ["type": "string"],
                        "node_ids": ["type": "array", "items": ["type": "string"]],
                        "group_id": ["type": "string"],
                        "name": ["type": "string"],
                        "color": ["type": "string", "description": "#RRGGBB，none = 默认"],
                        "x": ["type": "number"], "y": ["type": "number"],
                        "width": ["type": "number"], "height": ["type": "number"],
                        "path": ["type": "string", "description": "export 时存到哪（绝对路径，含文件名或文件夹）"]
                    ] as [String: Any],
                    "required": ["action"]
                ],
                risk: .mutating)
        ]
    }

    @MainActor
    static func runCanvasEditTool(_ name: String, args: [String: Any],
                                  project p: ProjectState) async -> AgentToolResult? {
        guard name == "canvas_edit" else { return nil }
        let canvas = p.canvas
        func s(_ k: String) -> String? { (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func n(_ k: String) -> Double? {
            if let d = args[k] as? Double { return d }
            if let i = args[k] as? Int { return Double(i) }
            if let t = args[k] as? String { return Double(t) }
            return nil
        }
        func nodeIDs() -> [UUID] {
            var keys = (args["node_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let one = s("node_id") { keys.append(one) }
            return keys.compactMap { k in canvas.nodes.first { "\($0.id)".hasPrefix(k) }?.id }
        }
        func one() -> CanvasNode? { nodeIDs().first.flatMap { canvas.node($0) } }
        func group() -> CanvasGroup? {
            guard let k = s("group_id"), !k.isEmpty else { return nil }
            return canvas.groups.first { "\($0.id)".hasPrefix(k) || $0.name == k }
        }
        /// 就地换内容（镜像 / 旋转 / 裁剪）。产物进素材库，卡片挂新素材
        func replace(_ nodeID: UUID, url: URL, size: CGSize?) {
            canvas.pushUndo()
            if AIInlinePlayer.shared.isCurrent(nodeID) { AIInlinePlayer.shared.stop() }
            p.importFile(url)
            let asset = p.mediaAssets.first { $0.url == url }
            canvas.updateNode(id: nodeID) {
                $0.mediaPath = url.path
                $0.assetID = asset?.id
                if let n = asset?.name { $0.displayName = n }
                if let size { $0.size = size }
            }
        }
        /// 产物另起一张卡片，摆在原卡片右边
        func addResult(_ src: CanvasNode, url: URL, kind: CanvasNode.Kind, row: Int = 0) {
            let pos = CGPoint(x: src.position.x + src.size.width + 90, y: src.position.y + CGFloat(row) * 140)
            let new = canvas.addNode(kind: kind, at: pos, ratio: src.ratio)
            p.importFile(url)
            let asset = p.mediaAssets.first { $0.url == url }
            canvas.updateNode(id: new.id) {
                $0.mediaPath = url.path
                $0.assetID = asset?.id
                if kind == src.kind { $0.size = src.size }
            }
        }

        switch s("action") ?? "" {
        case "group":
            let ids = nodeIDs()
            guard ids.count > 1 else { return .fail("成组至少要两张卡片。") }
            canvas.selectedNodeIDs = Set(ids)
            canvas.groupSelected()
            if let nm = s("name"), !nm.isEmpty, let gid = canvas.selectedGroupID,
               let i = canvas.groups.firstIndex(where: { $0.id == gid }) {
                canvas.groups[i].name = nm
            }
            return .ok("\(ids.count) 张卡片并成了一组。")
        case "ungroup":
            guard let g = group() else { return .fail("找不到这个组，read_canvas 看看。") }
            canvas.ungroup(g.id)
            return .ok("解散了「\(g.name)」。")
        case "group_color":
            guard let g = group() else { return .fail("找不到这个组。") }
            let c = s("color")
            canvas.setGroupColor(g.id, (c == nil || c == "none") ? nil : (c!.hasPrefix("#") ? c! : "#" + c!))
            return .ok("改好了。")
        case "duplicate":
            let ids = nodeIDs()
            guard !ids.isEmpty else { return .fail("一张卡片都没找到。") }
            canvas.duplicate(ids: Set(ids))
            return .ok("做了 \(ids.count) 张副本。")
        case "crop":
            guard let node = one(), let url = node.mediaURL else { return .fail("找不到卡片，或者卡片还没有内容。") }
            guard node.kind == .image || node.kind == .video else { return .fail("只有图片和视频卡片能裁。") }
            let x = (n("x") ?? 0) / 100, y = (n("y") ?? 0) / 100
            let w = (n("width") ?? 100) / 100, h = (n("height") ?? 100) / 100
            let rect = CGRect(x: max(0, x), y: max(0, y), width: min(w, 1 - max(0, x)), height: min(h, 1 - max(0, y)))
            guard rect.width > 0.02, rect.height > 0.02 else { return .fail("裁剪框太小了。") }
            let newSize = CGSize(width: node.size.width * rect.width, height: node.size.height * rect.height)
            do {
                let out = node.kind == .image ? try CanvasImageOps.crop(url, to: rect)
                                              : try await CanvasVideoOps.crop(url, to: rect)
                replace(node.id, url: out, size: newSize)
                return .ok("裁好了。")
            } catch { return .fail("裁剪失败：\(error.localizedDescription)") }
        case "mirror_h", "mirror_v", "rotate":
            guard let node = one(), let url = node.mediaURL else { return .fail("找不到卡片，或者卡片还没有内容。") }
            guard node.kind == .image || node.kind == .video else { return .fail("只有图片和视频卡片能翻转。") }
            let action = s("action")!
            let swapped = CGSize(width: node.size.height, height: node.size.width)
            do {
                let out: URL
                if node.kind == .image {
                    out = action == "rotate" ? try CanvasImageOps.rotate90(url)
                                             : try CanvasImageOps.mirror(url, vertical: action == "mirror_v")
                } else {
                    out = action == "rotate" ? try await CanvasVideoOps.rotate90(url)
                                             : try await CanvasVideoOps.mirror(url, vertical: action == "mirror_v")
                }
                replace(node.id, url: out, size: action == "rotate" ? swapped : nil)
                return .ok("处理好了。")
            } catch { return .fail("处理失败：\(error.localizedDescription)") }
        case "save_to_library":
            guard let node = one(), let url = node.mediaURL else { return .fail("找不到卡片，或者卡片还没有内容。") }
            p.importFile(url)
            let a = p.mediaAssets.first { $0.url == url }
            return .ok("存进素材库了" + (a.map { "，素材 id \($0.id.uuidString.prefix(8))。" } ?? "。"))
        case "export":
            guard let node = one(), let url = node.mediaURL else { return .fail("找不到卡片，或者卡片还没有内容。") }
            guard let path = s("path"), !path.isEmpty else { return .fail("export 要给 path") }
            var dest = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
                dest = dest.appendingPathComponent(url.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: url, to: dest) } catch {
                return .fail("保存失败：\(error.localizedDescription)")
            }
            return .ok("存到了 \(dest.path)。")
        case "remove_background":
            guard let node = one(), let url = node.mediaURL, node.kind == .image else {
                return .fail("要一张有内容的图片卡片。")
            }
            canvas.updateNode(id: node.id) { $0.isGenerating = true }
            defer { canvas.updateNode(id: node.id) { $0.isGenerating = false } }
            do {
                let out = try await BackgroundRemover.removeBackground(
                    from: url, outputName: url.deletingPathExtension().lastPathComponent + "_去背景",
                    mode: .subject, onStage: { _ in })
                addResult(node, url: out, kind: .image)
                return .ok("抠好了，结果放在原卡片右边的新卡片上。")
            } catch { return .fail("抠图失败：\(error.localizedDescription)") }
        case "upscale":
            guard let node = one(), let url = node.mediaURL, node.kind == .video else {
                return .fail("要一张有内容的视频卡片。")
            }
            let engine = AppSettings.shared.clarityEngine
            let useSystemSR = engine == .system
            let proModel: ClarityProModel? = engine.proModel(scale: 4)
            let model: ClarityModel = .x4
            if !useSystemSR, !(proModel?.isDownloaded ?? model.isDownloaded) {
                return .fail("超分模型还没下载，让用户去「设置 → 清晰度提升」下一个。")
            }
            let nodeID = node.id
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("canvas_clarity_\(UUID().uuidString)")
            let out = CanvasImageOps.outputURL(basedOn: url, suffix: "_超分", ext: url.pathExtension)
            let duration = p.mediaAssets.first(where: { $0.url == url }).map(\.duration).flatMap { $0 > 0 ? $0 : nil }
                ?? AVURLAsset(url: url).duration.seconds
            canvas.updateNode(id: nodeID) { $0.isGenerating = true; $0.failure = nil; $0.progressText = "准备中…"; $0.progress = 0 }
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try ProjectState.runClarityEnhancePipeline(
                        sourceURL: url, trimStart: 0, duration: duration, model: model, workDir: workDir,
                        outputURL: out, cancelFlag: ClarityCancelFlag(), useSystemSR: useSystemSR, proModel: proModel,
                        onStateChange: { state in
                            Task { @MainActor in
                                canvas.updateNode(id: nodeID) { $0.progressText = state.canvasLabel; $0.progress = state.canvasProgress }
                            }
                        })
                    await MainActor.run {
                        canvas.updateNode(id: nodeID) { $0.isGenerating = false; $0.progressText = nil; $0.progress = nil }
                        if let src = canvas.node(nodeID) { addResult(src, url: result, kind: .video) }
                    }
                } catch {
                    await MainActor.run {
                        canvas.updateNode(id: nodeID) {
                            $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                            $0.failure = error.localizedDescription
                        }
                    }
                }
                try? FileManager.default.removeItem(at: workDir)
            }
            return .ok("开始提升清晰度了，很慢，进度显示在卡片上，做完结果会另起一张卡片。")
        case "separate_audio":
            guard let node = one(), let url = node.mediaURL, node.kind == .video || node.kind == .audio else {
                return .fail("要一张有内容的视频或音频卡片。")
            }
            guard AudioSeparator.demucsReady else { return .fail("分离音轨的组件没装好。") }
            let nodeID = node.id
            canvas.updateNode(id: nodeID) { $0.isGenerating = true; $0.failure = nil; $0.progressText = "准备中…"; $0.progress = 0 }
            Task { @MainActor in
                do {
                    if !AudioSeparator.modelReady {
                        canvas.updateNode(id: nodeID) { $0.progressText = "下载模型中…" }
                        try await AudioSeparator.downloadModel { pr in
                            Task { @MainActor in canvas.updateNode(id: nodeID) { $0.progress = pr } }
                        }
                    }
                    let stems = try await AudioSeparator.separateStems(mediaURL: url, onProgress: { pr, label in
                        Task { @MainActor in canvas.updateNode(id: nodeID) { $0.progress = pr; $0.progressText = label } }
                    })
                    canvas.updateNode(id: nodeID) { $0.isGenerating = false; $0.progressText = nil; $0.progress = nil }
                    if let src = canvas.node(nodeID) {
                        for (i, st) in stems.enumerated() { addResult(src, url: st.url, kind: .audio, row: i) }
                    }
                } catch {
                    canvas.updateNode(id: nodeID) {
                        $0.isGenerating = false; $0.progressText = nil; $0.progress = nil
                        $0.failure = error.localizedDescription
                    }
                }
            }
            return .ok("开始分离了，进度在卡片上，分完每一轨各一张音频卡片。")
        default:
            return .fail("action 不认识。")
        }
    }
}
