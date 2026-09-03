// MediaPreviewOverlay.swift
//
// 聊天区点图片/视频弹出的全屏查看层。
//
// 挂在 ContentView 最外层、**排在画布之后** —— 画布里那张聊天卡片点出来的
// 预览也得盖在画布上面。

import SwiftUI
import AVKit

/// 正在全屏查看的那个东西
struct MediaPreviewItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isVideo: Bool

    static func == (a: MediaPreviewItem, b: MediaPreviewItem) -> Bool { a.id == b.id }
}

struct MediaPreviewOverlay: View {
    let item: MediaPreviewItem
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            // 遮罩。点空白处也关，跟点右上角那个叉是一回事
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            content
                // 留出四周的余量，别顶到屏幕边上
                .padding(.horizontal, 60)
                .padding(.vertical, 56)

            closeButton
        }
        .ignoresSafeArea()
        .onAppear { start() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        if item.isVideo {
            if let p = player {
                VideoPlayer(player: p)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            }
        } else if let img = image {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                // 图片本身不接点击，让给底下的遮罩去关
                .allowsHitTesting(false)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            Spacer()
        }
        .padding(18)
    }

    private func start() {
        if item.isVideo {
            // 行内那个小播放器还响着的话先停掉，不然两路声音叠在一起
            AIInlinePlayer.shared.stop()
            let p = AVPlayer(url: item.url)
            player = p
            p.play()
        } else {
            image = NSImage(contentsOf: item.url)
        }
    }
}
