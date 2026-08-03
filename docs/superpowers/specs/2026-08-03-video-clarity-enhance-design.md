# 清晰度提升（视频超分辨率）— 设计文档

**日期**：2026-08-03
**状态**：已获用户批准，待写实施计划

## 背景与目标

黑猫剪辑目前没有"让模糊/低清视频变清晰"的能力。用户希望参照 BiRefNet 去背景、demucs 音轨分离等已有 AI 组件的模式，在设置面板"视频"标签下新增一个可安装组件，并在时间轴视频片段右键菜单里加一个「清晰度提升」入口，把低清素材放大为高清版本。

## 技术方案与模型选型

| 方案 | 优势 | 代价 |
|---|---|---|
| **本地 Real-ESRGAN（采纳）** | 离线免费；RRDBNet 是纯前馈 CNN（标准卷积+残差块），无 `deform_conv2d` 这类需要自定义算子的复杂结构，CoreML 转换预期比 BiRefNet 轻松；模型小（约 64MB），符合项目"二进制/模型打包+按需下载"的一贯模式 | 逐帧处理无时序建模，复杂运动画面可能有轻微闪烁；效果不如 SeedVR2/FlashVSR |
| 云端 SeedVR2/FlashVSR | 2026 年最强开源视频超分，效果媲美/超越 Topaz Video AI | 目前没有验证过的第三方托管平台；PyTorch/CUDA 生态转 CoreML 工程量巨大，不可行 |
| Video2X 包装器 | 一键整合多个模型 | 只是调度层非模型本身；项目已有 ffmpeg 抽帧/编码管线，不需要它的包装 |

**采纳**：本地 Real-ESRGAN，固定使用 `RealESRGAN_x4plus`（通用版，4 倍放大）。不做动漫版变体（`x4plus_anime_6B`）——黑猫剪辑是通用剪辑软件，先做一个模型跑通，参照 BiRefNet"一个模型全包"的简化原则。

云端方案在架构上预留扩展点：
```swift
enum ClarityEngine {
    case realESRGAN
    case cloud(Provider)  // 本轮不实现
}
```

**风险标注（未验证）**：RRDBNet 转 CoreML 的可行性判断是基于架构简单性的乐观推断，尚未实际操作验证过。这是实施阶段的第一个验证点——如果转换遇到阻碍（激活函数、上采样层等在 CoreML 里的支持度问题），需要重新评估方案，不能假设一定顺利。

## 处理流程与数据流

参照 demucs 分离的骨架（`ProjectState+AudioSeparate.swift`）：

1. **抽帧**：ffmpeg 把片段裁剪范围（`trimStart` 到 `trimStart + duration * speed`）解码成 PNG 序列到临时目录
2. **逐帧推理**：CoreML 跑 Real-ESRGAN，每帧放大 4 倍
3. **重编码**：ffmpeg 把放大后的帧序列编回视频，**音轨直接从原片段复制**（不重新处理音频）
4. **入库**：写到 `~/Library/Application Support/黑猫剪辑/clarity/output/`，命名 `源名_清晰_uid.mp4`，作为新素材加入素材库（`mediaAssets`）
5. **建轨道**：新建一条视频轨道插到原轨道紧邻位置（`videoSectionOrder` 相邻插入），新片段 `startTime`/`endTime` 与原片段完全一致

**关键设计决定：全程只用 ffmpeg 做抽帧和编码，不碰 `AVAssetReader`/`AVAssetImageGenerator`。** 这是直接吸取本次会话debug 经验的决定——家用机上 AVFoundation 的这类调用会让读取请求永久挂死、占满 Swift 协作池，波及全应用（详见 `home_machine_decode_issue.md`）。这个功能逐帧吞吐量大、耗时长，一旦踩中同样的坑影响面更大。ffmpeg 静态编译、解码器内置，不依赖系统解码服务，更可控。

## 状态机

```swift
enum ClarityEnhanceState: Equatable {
    case idle
    case downloadingModel(Double)
    case extractingFrames(Double)
    case inferring(Double)      // 最耗时的阶段，逐帧推理进度
    case encoding
    case failed(String)
}
```

同一时间只允许一个清晰度提升任务在跑（互斥，不支持多任务并发/排队，跟 demucs 一致）。支持取消（杀掉 ffmpeg 子进程和推理任务，清理临时文件，状态回 `idle`）。

UI 上需要一个悬浮进度气泡组件（参照 `RemoveBackgroundBubble`/`SceneDetectBubble` 的模式），显示当前阶段+进度百分比。

## 界面设计

### 设置面板

在"视频"标签（`sceneDetectTab` 所在位置）下新增分区，复用现有组件卡片样式（状态徽章：已安装/下载按钮/下载进度条/失败重试，完全对照 `SceneDetector` 的实现）：

```
清晰度提升
┌─────────────────────────────────────┐
│ Real-ESRGAN          [已安装/下载/进度条] │
│ 视频超分辨率模型（CoreML），约 XX MB     │
└─────────────────────────────────────┘
安装后可在时间轴视频片段右键使用「清晰度提升」，
把低清素材放大为高清版本，新建独立轨道，不影响原片段。
```

### 右键菜单

在 `TimelineView.swift` 的右键菜单里，`project.selectedVideoClipID != nil` 分支下（跟"分离音轨"同级）新增：

```swift
Button { project.enhanceClaritySelection() } label: {
    Label("清晰度提升", systemImage: "sparkles")
}
.disabled(!project.canEnhanceClarity)
```

`canEnhanceClarity` 只判断"有选中视频片段"+"当前没有任务在跑"——**不因模型未下载而 disabled**。按钮始终可点，点击后内部检查模型是否已下载，没有就先触发下载（对照 BiRefNet 的模式：托管模型按需下载，不是"缺二进制先阻断提示装"那种，因为 CoreML 模型没有额外的二进制依赖）。

## 错误处理与边界情况

- **磁盘空间**：处理前按帧数估算所需临时空间（1080p→4K，300 帧量级可能接近 1GB），检查可用磁盘，不够直接报错，不要写到一半才失败
- **临时文件清理**：抽帧目录无论成功/失败/取消都要清理（`defer` 兜底，参照现有 `ffmpegFrameStrip` 的模式）
- **耗时提示**：点击「清晰度提升」时按片段时长估算处理耗时量级，预计较长时先弹确认提示（"预计需要 X 分钟，确认继续吗"），避免用户误触发一个要跑十几分钟的任务却毫无心理准备
- **分辨率上限保护**：源片段短边已经较高（阈值待实现时定，参考 ≥1520）时提示"素材已经较清晰，放大 4 倍收益有限"，但不强制阻止，用户可自行选择继续
- **处理中原片段被删除/撤销**：任务只依赖抽出来的临时文件和 URL，不依赖 clip 对象存活。完成时如果发现原片段已经不在时间轴上了，只把结果放进素材库，不再新建轨道插入片段
- **取消**：杀掉 ffmpeg 子进程和推理任务，清理临时文件，状态回 `idle`（同 `cancelSeparate` 的模式）

## 明确不做的范围（Out of Scope）

- 云端引擎（`.cloud` 分支）的实际实现——只留架构扩展点
- 动漫模型变体（`x4plus_anime_6B`）——只做通用版
- 放大倍数可选（x2/x4）——固定 x4
- 批量/多选片段一起处理——跟 demucs 一致，单选单任务
- 实时预览滤镜级效果——本功能是"生成新文件"模式，不是实时预览

## 待验证风险清单（实施第一步必须做）

1. **RRDBNet → CoreML 转换是否真的顺畅**（未验证，方案的最大不确定性）
2. **CoreML 在 Apple Silicon 上跑 Real-ESRGAN 单帧推理的实际耗时**（未实测，影响"耗时提示"的具体数值和整体可用性判断）
3. 模型实际下载体积、是否需要额外的 fp16/量化处理来控制体积和速度

## 关联文档

- 处理流程骨架参照：`Sources/VideoEditor/Models/ProjectState+AudioSeparate.swift`
- 进度气泡组件参照：`RemoveBackgroundBubble`（`MediaLibraryView.swift`）
- 家用机 AVFoundation 死锁教训：`.claude/projects/-Users-Venico-claude/memory/home_machine_decode_issue.md`
