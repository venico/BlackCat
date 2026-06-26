<p align="center">
  <img src="icon.png" width="128" alt="黑猫剪辑">
</p>

<h1 align="center">黑猫剪辑 BlackCat</h1>

<p align="center">
  轻量级 macOS 原生视频编辑器<br>
  Swift · SwiftUI · AVFoundation · Core Image · whisper.cpp
</p>

<p align="center">
  <a href="https://github.com/venico/BlackCat/releases/latest"><img src="https://img.shields.io/github/v/release/venico/BlackCat?label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC&color=black" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/language-Swift-orange" alt="Swift">
  <a href="https://venico.github.io/blackcat-privacy/"><img src="https://img.shields.io/badge/%E9%9A%90%E7%A7%81%E6%94%BF%E7%AD%96-green" alt="Privacy Policy"></a>
</p>

---

## 功能特性

### 多轨时间轴编辑
- 视频 / 音频 / 图片 / 字幕 / 文字 五种轨道类型
- 剪切、分割、复制粘贴、撤销重做（无限步）
- 轨道拖拽排序、片段跨轨拖动
- 时间轴缩放、自动吸附、防重叠

### 字幕与语音识别
- **Whisper 本地语音识别** — 基于 [whisper.cpp](https://github.com/ggerganov/whisper.cpp)，离线运行，隐私安全
- 模型按需下载（Tiny ~ Large v3 Turbo，75MB ~ 1.6GB）
- **多语言翻译** — Google Translate 6 路并发 + 批量合并
- SRT / ASS / VTT 字幕导入
- OpenCC 繁体 → 简体自动转换
- 字幕样式编辑（字体、大小、颜色、位置、斜体）

### 视觉效果
- **11 种转场** — 溶解、淡黑、推入（4 向）、缩放、滑入（4 向）
- **色调调节** — 亮度 / 对比度 / 饱和度 / 色温（CIFilter GPU 加速）
- 文字 / 标题图层叠加

### 高性能导出
- **快速路径** — 无 overlay 时使用 AVAssetExportSession（5-10x 加速）
- **GPU 管线** — CIImage 零拷贝 + CIFilter 链 + 字幕缓存
- H.264 硬件编码加速
- autoreleasepool 内存优化，支持数小时长视频导出
- 可取消 + 实时进度条

### 变速
- 视频变速（0.1x ~ 10x）
- 音频同步变速（保持音调）

### 项目管理
- `.bcj` 项目文件保存 / 打开
- Finder 双击 `.bcj` 直接打开
- 自动保存

### 其他
- 素材库管理（缩略图 / 波形预览 / 搜索排序）
- FFmpeg 转码（动态链接，支持全格式导入）
- 统一通知系统（右下角弹窗，成功倒计时，可取消）
- 全中文菜单栏

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | macOS 14.0 (Sonoma) 及以上 |
| 芯片 | Apple Silicon (M1/M2/M3/M4) 或 Intel |
| 内存 | 建议 8GB 以上 |

## 安装

### 方式一：下载 DMG / ZIP

前往 [Releases](https://github.com/venico/BlackCat/releases/latest) 下载最新版本。

### 方式二：从源码构建

```bash
git clone https://github.com/venico/BlackCat.git
cd BlackCat
swift build
```

构建产物位于 `.build/arm64-apple-macosx/debug/VideoEditor`。

## 技术架构

```
Sources/VideoEditor/
├── App/                    # 应用入口、菜单栏
├── Models/
│   ├── ProjectState        # 核心状态（拆分为 9 个扩展文件）
│   │   ├── +IO             # 项目文件读写
│   │   ├── +Media          # 素材库管理
│   │   ├── +Timeline       # 时间轴操作
│   │   ├── +Edit           # 撤销/重做、剪切
│   │   ├── +Subtitle       # 字幕解析 + Whisper
│   │   ├── +Preview        # 预览合成、转场
│   │   └── +Import         # 文件导入、FFmpeg 转码
│   ├── DataTypes           # Clip/Track/Transition 等数据结构
│   ├── WhisperTranscriber  # Whisper 模型管理与识别
│   └── ColorCompositor     # 色调调节 CIFilter
└── Views/
    ├── Timeline/           # 多轨时间轴
    ├── Player/             # 视频预览播放器
    ├── Inspector/          # 属性检查器
    ├── MediaLibrary/       # 素材库
    ├── Export/             # 导出引擎
    └── Sidebar/            # 侧边栏
```

**核心技术栈：**
- **UI**：SwiftUI + AppKit（NSWindow 自定义标题栏）
- **音视频**：AVFoundation（播放/合成/导出）
- **图像处理**：Core Image（色调/字幕/转场 GPU 渲染）
- **语音识别**：whisper.cpp（本地推理，支持 auto 语言检测）
- **转码**：FFmpeg（动态链接，全格式支持）
- **序列化**：Codable（`.bcj` 项目文件）

## 版本历史

| 版本 | 主要更新 |
|------|---------|
| v3.5.2 | 导出内存泄漏修复、macOS 15 图标圆角、模型下载改进 |
| v3.5.1 | 导出 GPU 加速、翻译 6 路并发、Whisper 实时进度 |
| v3.5.0 | 代码架构重构，ProjectState 拆分为 9 个模块 |
| v3.4.0 | 时间轴拖拽优化、导出修复 |
| v3.3.x | Whisper 模型选择器、轨道拖拽排序、通知系统 |
| v3.2.0 | 素材库搜索排序、NSSavePanel 保存 |
| v3.0.0 | 转场功能完整实现（11 种） |
| v2.x | 色调调节、变速、字幕样式、FFmpeg 转码 |
| v1.0 | 多轨视频编辑器初版 |

## 隐私政策

黑猫剪辑不收集任何用户数据。语音识别完全在本地运行。

[查看完整隐私政策](https://venico.github.io/blackcat-privacy/)

## 许可证

本项目为个人作品，保留所有权利。
