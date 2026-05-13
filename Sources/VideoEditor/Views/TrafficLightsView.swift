import SwiftUI
import AppKit

/// 自定义交通灯按钮，替代系统原生按钮，位置完全由布局控制
struct TrafficLightsView: View {
    @State private var isHovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var isActive: Bool { controlActiveState == .key }

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightBtn(
                color: isActive ? Color(hex: "#FF5F57") : Color(hex: "#BEBEBF"),
                symbol: "xmark",
                hovered: isHovered
            ) {
                NSApplication.shared.keyWindow?.close()
            }
            TrafficLightBtn(
                color: isActive ? Color(hex: "#FFBD2E") : Color(hex: "#BEBEBF"),
                symbol: "minus",
                hovered: isHovered
            ) {
                NSApplication.shared.keyWindow?.miniaturize(nil)
            }
            TrafficLightBtn(
                color: isActive ? Color(hex: "#28C840") : Color(hex: "#BEBEBF"),
                symbol: "plus",
                hovered: isHovered
            ) {
                NSApplication.shared.keyWindow?.zoom(nil)
            }
        }
        .onHover { isHovered = $0 }
    }
}

private struct TrafficLightBtn: View {
    let color: Color
    let symbol: String
    let hovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                if hovered {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.black.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 12, height: 12)
    }
}
