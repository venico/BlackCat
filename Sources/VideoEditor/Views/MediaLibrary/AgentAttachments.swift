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
    /// 能当图片看的。跟 AIVideoService 那张表一致，免得「拖得进画布、
    /// 却当不了聊天附件」这种对不上的情况
    static let imageExts: Set<String> = AIVideoService.imageExts
    /// 能读成文字的。二进制不收 —— 塞一堆乱码进提示词只会把模型带偏
    static let textExts: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "yml", "yaml", "xml",
        "html", "css", "js", "ts", "swift", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "sh", "toml", "ini", "conf", "srt", "vtt"
    ]

    /// 视频 / 音频也收 —— 用户可能还没点名生成模型，先放附件里存着，
    /// 之后打了 `/命令`，promoteAttachmentsToReference 会按那家支持的类型
    /// 把它们收进参考区，收不下的继续留在附件
    static func isMedia(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return AIVideoService.videoExts.contains(e) || AIVideoService.audioExts.contains(e)
    }

    /// 能读成文字贴进提示词的
    static func isTextDoc(_ url: URL) -> Bool {
        textExts.contains(url.pathExtension.lowercased())
    }

    static func accepts(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return imageExts.contains(e) || textExts.contains(e) || isMedia(url)
    }

    static func make(_ url: URL) -> AgentAttachment? {
        let e = url.pathExtension.lowercased()
        if imageExts.contains(e) {
            return AgentAttachment(url: url, thumb: NSImage(contentsOf: url))
        }
        // 视频 / 音频没有缩略图，卡片上显示成文件图标
        return (textExts.contains(e) || isMedia(url))
            ? AgentAttachment(url: url, thumb: nil) : nil
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

    /// 把粘贴板里的位图存成 PNG。
    ///
    /// 放历史记录旁边，别塞系统临时目录 —— 那儿会被清掉，
    /// 素材库里就成了失效链接
    static func savePastedImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackCat/pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("粘贴_\(Int(Date().timeIntervalSince1970)).png")
        do { try png.write(to: url) } catch { return nil }
        return url
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
    /// 能用多宽（由面板那层量好传进来）。**不自己量** ——
    /// 量自己会被网格内容撑大，量到的又是撑大后的值，列数再也减不回去
    let availableWidth: CGFloat
    let onRemove: (AgentAttachment) -> Void
    let onClear: () -> Void
    /// 默认叠成一摞，点开才平铺 —— 跟参考区一个交互，
    /// 不然十几个附件占掉半个聊天框，删还得一个一个删
    @State private var expanded = false

    private static let cell: CGFloat = 40
    private static let gap: CGFloat = 4
    /// 最多铺三行，再多就在里头滚
    private static let maxHeight: CGFloat = 3 * (cell + gap) - gap

    var body: some View {
        if expanded { grid } else { fan }
    }

    /// 收起态：叠成一摞，带个数和清空
    private var fan: some View {
        let top = Array(items.prefix(3))
        return ZStack {
            ForEach(Array(top.enumerated()), id: \.offset) { i, it in
                thumbBody(it)
                    .frame(width: Self.cell, height: Self.cell)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .rotationEffect(.degrees(top.count == 1 ? 0
                                             : Double(i - (top.count - 1)) * 8 + Double(top.count - 1) * 4))
            }
        }
        .frame(width: Self.cell + CGFloat(max(0, top.count - 1)) * 8, height: Self.cell)
        .overlay(alignment: .topLeading) {
            if items.count > 1 {
                Text("\(items.count)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 14, height: 14)
                    .background(Color.accent)
                    .clipShape(Circle())
                    .offset(x: -3, y: -3)
            }
        }
        .overlay(alignment: .topTrailing) {
            ThumbCloseButton(size: 14, action: onClear)
                .offset(x: 3, y: -3)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
        }
        .help("\(items.count) 个附件，点开看全部")
    }

    /// 展开态：按宽度换行铺开，最多三行，超了在里头滚
    private var grid: some View {
        let cols = max(1, Int((availableWidth + Self.gap) / (Self.cell + Self.gap)))
        let rows = max(1, (items.count + cols - 1) / cols)
        let height = min(CGFloat(rows) * (Self.cell + Self.gap) - Self.gap, Self.maxHeight)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
                } label: {
                    // 尖对尖的两个尖括号，转 45° —— 「收起来」那个意思。
                    // SF Symbol 里没有现成的，自己拼：上面那个尖朝下、下面那个尖朝上
                    VStack(spacing: -1) {
                        Image(systemName: "chevron.down")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 6, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .foregroundColor(Color.labelSecondary.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("收起")
            }
            .padding(.bottom, 2)

            ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.gap),
                                     count: cols),
                      alignment: .leading, spacing: Self.gap) {
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
                    // **必须锁命中范围**。缩略图是裁切填充的，实际内容比格子宽，
                    // clipShape 只管裁显示、不裁鼠标 —— 溢出的那部分会压住
                    // 左边那个格子的删除按钮（实测五张图时第四个的 × 右下点不动，
                    // 删掉第五张就好了）
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5))

                    // 跟画布上参考图的那个删除按钮同一个样子（CanvasPromptBar
                    // 的 thumbActionButton）。**整个留在框内**：原来靠 offset
                    // 顶出去一半，越过父视图 bounds 的那半收不到鼠标
                    ThumbCloseButton(size: 16, opacity: 0.7) { onRemove(it) }
                        .padding(2)
                }
                .help(it.name)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height)
        // 同参考区：不裁的话拉窄侧栏时这一行会把容器撑大，
        // 量到的宽度一直是撑大后的，列数减不回去
        .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 缩略图本体：图片直接画，其它按后缀画个文档图标
    @ViewBuilder
    private func thumbBody(_ it: AgentAttachment) -> some View {
        if let img = it.thumb {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if AIVideoService.videoExts.contains(it.url.pathExtension.lowercased()) {
            // 视频原来一律显示文件图标。缩略图不能在 make() 里同步取 ——
            // 取帧要解码，会把加附件那一下卡住，所以挪到这儿后台取
            AttachmentVideoThumb(url: it.url)
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
}

/// 附件格子里的视频封面。
///
/// 取帧走跟参考区同一个函数（`AIVideoService.videoFrameThumbnail`），但那是同步的、
/// 要解码，直接在 body 里调会卡住聊天框 —— 丢到后台线程取，回来再贴上。
/// 右下角压个播放角标，跟图片附件一眼区分得开
private struct AttachmentVideoThumb: View {
    let url: URL
    @State private var img: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let i = img {
                Image(nsImage: i)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 12, height: 12)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .padding(2)
        }
        .task(id: url) {
            let u = url
            img = await Task.detached(priority: .utility) {
                AIVideoService.videoFrameThumbnail(url: u)
            }.value
        }
    }
}
