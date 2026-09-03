// AgentAttachments.swift
//
// Agent 对话的附件：图片直接给模型看，文本文件读成文字塞进提示词。
//
// 跟生成模型那套「参考图/首尾帧」不是一回事 —— 那些是喂给出图出片的模型的，
// 有张数上限、有首尾帧语义；这里只是给 Agent 看的资料。

import SwiftUI
import UniformTypeIdentifiers

struct AgentAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// 图片才有缩略图；没有就是文本类
    var thumb: NSImage?

    var isImage: Bool { thumb != nil }
    var name: String { url.lastPathComponent }

    static func == (a: AgentAttachment, b: AgentAttachment) -> Bool { a.id == b.id }
}

enum AgentAttachmentIO {
    /// 能当图片看的
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]
    /// 能读成文字的。二进制不收 —— 塞一堆乱码进提示词只会把模型带偏
    static let textExts: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "yml", "yaml", "xml",
        "html", "css", "js", "ts", "swift", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "sh", "toml", "ini", "conf", "srt", "vtt"
    ]

    static func accepts(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return imageExts.contains(e) || textExts.contains(e)
    }

    static func make(_ url: URL) -> AgentAttachment? {
        let e = url.pathExtension.lowercased()
        if imageExts.contains(e) {
            return AgentAttachment(url: url, thumb: NSImage(contentsOf: url))
        }
        return textExts.contains(e) ? AgentAttachment(url: url, thumb: nil) : nil
    }

    /// 图片压成 JPEG 再发。原图动辄几 MB，base64 之后更大，
    /// 长边 1600 对模型看图足够了
    static func jpegData(_ image: NSImage, maxSide: CGFloat = 1600) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
        let target = NSSize(width: floor(w * scale), height: floor(h * scale))
        guard let ctx = CGContext(data: nil, width: Int(target.width), height: Int(target.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = rep.cgImage else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: target))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// 文本文件读出来，太长的截断 —— 整本日志塞进去会把上下文吃光
    static func readText(_ url: URL, limit: Int = 20_000) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return raw.count > limit
            ? String(raw.prefix(limit)) + "\n…（太长，只给了前 \(limit) 字）"
            : raw
    }
}

/// 输入框上方那排附件缩略图
struct AgentAttachmentBar: View {
    let items: [AgentAttachment]
    let onRemove: (AgentAttachment) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { it in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let img = it.thumb {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            VStack(spacing: 2) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 13, weight: .light))
                                Text(it.url.pathExtension.uppercased())
                                    .font(.system(size: 7, weight: .medium))
                            }
                            .foregroundColor(Color.labelSecondary.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.06))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5))

                    // 跟画布上参考图的那个删除按钮同一个样子（CanvasPromptBar
                    // 的 thumbActionButton）。**整个留在框内**：原来靠 offset
                    // 顶出去一半，越过父视图 bounds 的那半收不到鼠标
                    Button { onRemove(it) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
                .help(it.name)
            }
        }
    }
}
