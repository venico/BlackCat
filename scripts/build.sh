#!/bin/bash
set -e

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="黑猫剪辑.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "=== 黑猫剪辑 构建脚本 ==="

# ─── 1. 检查/安装 FFmpeg ───
if [ -x "$MACOS/ffmpeg" ] && [ -x "$MACOS/ffprobe" ]; then
    echo "✅ FFmpeg 已存在于 app bundle"
else
    echo "📦 正在获取 FFmpeg..."
    mkdir -p "$MACOS"

    # 优先从 Homebrew 复制
    BREW_FFMPEG=""
    if [ -x "/opt/homebrew/bin/ffmpeg" ]; then
        BREW_FFMPEG="/opt/homebrew/bin"
    elif [ -x "/usr/local/bin/ffmpeg" ]; then
        BREW_FFMPEG="/usr/local/bin"
    fi

    if [ -n "$BREW_FFMPEG" ]; then
        echo "  从 Homebrew 复制: $BREW_FFMPEG"
        cp "$BREW_FFMPEG/ffmpeg" "$MACOS/ffmpeg"
        cp "$BREW_FFMPEG/ffprobe" "$MACOS/ffprobe"
        chmod +x "$MACOS/ffmpeg" "$MACOS/ffprobe"
        echo "✅ FFmpeg 已复制到 app bundle"
    else
        # Homebrew 未安装 ffmpeg，尝试自动安装
        if command -v brew &>/dev/null; then
            echo "  Homebrew 已安装但缺少 ffmpeg，正在安装..."
            brew install ffmpeg
            BREW_FFMPEG="$(brew --prefix)/bin"
            cp "$BREW_FFMPEG/ffmpeg" "$MACOS/ffmpeg"
            cp "$BREW_FFMPEG/ffprobe" "$MACOS/ffprobe"
            chmod +x "$MACOS/ffmpeg" "$MACOS/ffprobe"
            echo "✅ FFmpeg 已安装并复制"
        else
            echo "⚠️  未找到 FFmpeg，MKV 等格式导入将回退到系统 ffmpeg"
            echo "   安装方法: brew install ffmpeg"
        fi
    fi
fi

# ─── 2. 检查 app bundle 结构 ───
mkdir -p "$RESOURCES"
if [ ! -f "$APP/Contents/Info.plist" ]; then
    echo "❌ 缺少 Info.plist，请确认 app bundle 完整"
    exit 1
fi

# ─── 3. 编译 ───
MODE="${1:-debug}"
echo "🔨 编译中 ($MODE)..."
if [ "$MODE" = "release" ]; then
    swift build -c release 2>&1 | tail -3
    cp .build/release/VideoEditor "$MACOS/VideoEditor"
else
    swift build 2>&1 | tail -3
    cp .build/debug/VideoEditor "$MACOS/VideoEditor"
fi

echo "✅ 构建完成: $ROOT/$APP"
echo "   双击打开或运行: open \"$APP\""
