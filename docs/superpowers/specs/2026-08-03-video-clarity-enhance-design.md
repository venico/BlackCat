# 清晰度提升（视频超分辨率）— 设计文档

**日期**：2026-08-03
**状态**：已获用户批准，待写实施计划

## 背景与目标

黑猫剪辑目前没有"让模糊/低清视频变清晰"的能力。用户希望参照 BiRefNet 去背景、demucs 音轨分离等已有 AI 组件的模式，在设置面板"视频"标签下新增一个可安装组件，并在时间轴视频片段右键菜单里加一个「清晰度提升」入口，把低清素材放大为高清版本。

## 技术方案与模型选型（2026-08-04 修订：Real-ESRGAN → FSRCNN）

### 修订背景

第一版方案（Real-ESRGAN）已经过 Task 1-3 实测验证：CoreML 转换本身可行（PSNR 59dB+，两个已知转换 bug 都定位修复），但**推理速度不可接受**——x4 模式处理 10 秒 1080p 片段实测需要 79.4 分钟（CPU+GPU），即使用 ANE 加速也要 36.3 分钟，x2 最快也要 8.1 分钟。这远超"后台处理，用户可接受"的范畴。

调研了字节跳动 SeedVR2/阿里 FlashVSR（效果最强但 PyTorch/CUDA 生态转 CoreML 不可行）和 PiperSR（专为 ANE 设计，比 Real-ESRGAN 快 160 倍，但 **AGPL-3.0 许可证**对商业 App Store 应用是法律风险，且只有 2x 没有 4x）之后，转向验证经典轻量架构 ESPCN/FSRCNN。

### 新方案对比

| 方案 | 优势 | 代价 |
|---|---|---|
| **FSRCNN（采纳）** | 实测 CoreML 推理极快（见下方数据），Apache 2.0 许可证无法律风险，模型仅约 40KB（比 Real-ESRGAN 小 1600 倍）；架构里的算子（Conv2D/PReLU/DepthToSpace）全部标准，转换零报错 | 纯 MSE 训练，从未针对真实世界压缩/噪声素材优化，效果预期不如 Real-ESRGAN 这类专门做"真实退化"训练的模型；只在学术 benchmark（Set5 等干净图像）上验证过效果，真实素材效果待验证 |
| Real-ESRGAN | 效果好、经过实测验证转换可行 | 速度不可接受（见上），已放弃 |
| PiperSR | 效果最好、速度最快（专为 ANE 设计） | AGPL-3.0 许可证法律风险，只有 2x，已放弃 |
| SeedVR2/FlashVSR | 2026 年最强开源视频超分 | PyTorch/CUDA 生态转 CoreML 不可行，已放弃 |

**採纳**：FSRCNN，x2/x4 分别一个模型。

### 已验证的技术细节（2026-08-04 探索性验证记录）

1. **权重来源**：OpenCV 官方 `dnn_superres` 模块的预训练权重，仓库 `Saafke/FSRCNN_Tensorflow`（Apache 2.0），TensorFlow 冻结图格式（`.pb`），直接 GitHub raw 下载，`FSRCNN_x2.pb` 38973 字节，`FSRCNN_x4.pb` 41661 字节。
2. **架构**（已用 `tf.compat.v1.GraphDef` 解析确认）：标准 FSRCNN 配置 `d=56（特征维度）s=12（收缩维度）m=4（映射层数）`——
   - `f1`(5×5, 1→56) 特征提取，**输入是单通道（Y 亮度通道，YCbCr 色彩空间）**，不是 RGB 三通道
   - `f2`(1×1, 56→12) 收缩
   - `f3-f6`(3×3, 12→12) × 4 映射层
   - `f7`(1×1, 12→56) 扩展
   - `f8`(1×1, 56→16=4²) + **DepthToSpace（即 PyTorch 的 `PixelShuffle`）** 上采样——不是原始论文的反卷积（deconvolution），这个具体实现用的是 sub-pixel 卷积方式
   - 7 处 PReLU（TF 图里用 `Relu+Abs+Sub+Mul+Add` 手工拼出等价计算，PyTorch 里直接用 `nn.PReLU` 数学等价，不需要照抄这个拼接）
   - 全部是 `Conv2D`/`PReLU`/`DepthToSpace` 标准算子，无自定义/动态形状操作
3. **色彩空间处理**（新增环节，Real-ESRGAN 方案没有）：FSRCNN 只处理 Y 通道，Cb/Cr 通道需要用双线性插值放大（不过模型）。这跟 OpenCV `dnn_superres` 模块内部的标准做法一致。
4. **速度实测**（随机权重测的，速度只取决于网络结构与权重数值无关，可信）：
   | 配置 | 单 tile（256×256）耗时 | 10 秒 1080p 片段预估 |
   |---|---|---|
   | x4, CPU+GPU | 7.52ms | 1.5 分钟 |
   | x4, ANE(`.all`) | 3.06ms | 0.6 分钟 |
   | x2, CPU+GPU | 4.36ms | 0.87 分钟 |
   | x2, ANE(`.all`) | 26.34ms | 5.27 分钟（**ANE 对这个小模型反而更慢**，需要按 scale 分别测试选最优 compute unit，不能假设 `.all` 总是最快） |

   比 Real-ESRGAN 快 15-130 倍，是完全可接受的后台处理耗时（用户体验上接近甚至优于 demucs 音轨分离）。
5. **视觉效果初验**：用 OpenCV `dnn_superres`（加载官方真实权重，非 CoreML）在一张插画类测试图上验证，效果清晰、无噪声/伪影，视觉上接近 Real-ESRGAN 基准。**但这只是一张插画图的验证，插画对任何超分模型都相对"友好"**（线条清晰、色块分明，不含真实拍摄的压缩伪影/噪点/运动模糊）——真实视频素材上的效果还没有验证，这是实施阶段必须补的验证，不能假设学术 benchmark/插画效果能代表真实使用场景。

### 待实施阶段解决的技术工作

**权重迁移**：官方权重是 TensorFlow `.pb` 格式，需要迁移到 PyTorch 才能复用已经验证过的 PyTorch→CoreML 转换流程。做法：用独立的 TensorFlow venv（跟主 PyTorch/CoreML venv 隔离，避免 numpy 版本冲突——这是本次探索验证时踩过的坑，`tensorflow-macos` 会把 numpy 降级到 `<2.0`，破坏 `coremltools`/`scipy` 依赖）解析 `.pb` 里的 8 个卷积核权重 + 偏置 + 7 组 PReLU alpha，导出成 `.npz`，再在主环境里按层对应关系加载进 PyTorch 定义的 FSRCNN 模型，**必须验证迁移后 PyTorch 模型的输出与原始 OpenCV 推理数值/视觉一致**，不能假设权重对应关系猜对了。

云端方案在架构上预留扩展点（不变）：
```swift
enum ClarityEngine {
    case fsrcnn
    case cloud(Provider)  // 本轮不实现
}
```

## 处理流程与数据流

参照 demucs 分离的骨架（`ProjectState+AudioSeparate.swift`）：

1. **抽帧**：ffmpeg 把片段裁剪范围（`trimStart` 到 `trimStart + duration * speed`）解码成 PNG 序列到临时目录
2. **逐帧推理**：CoreML 跑对应倍数的 FSRCNN 模型（用户选 x2 就跑 `FSRCNN_x2`，选 x4 就跑 `FSRCNN_x4`）。**FSRCNN 只处理 Y（亮度）通道**：每帧先转 YCbCr，Y 通道过模型放大，Cb/Cr 通道用双线性插值放大到同尺寸，三通道合并转回 RGB 再写出——这是 FSRCNN 方案独有的环节，Real-ESRGAN 没有（它直接处理 RGB 三通道）
3. **重编码**：ffmpeg 把放大后的帧序列编回视频，**音轨直接从原片段复制**（不重新处理音频）
4. **入库**：写到 `~/Library/Application Support/黑猫剪辑/clarity/output/`，命名 `源名_清晰x2_uid.mp4` 或 `源名_清晰x4_uid.mp4`，作为新素材加入素材库（`mediaAssets`）
5. **建轨道**：新建一条视频轨道插到原轨道紧邻位置（`videoSectionOrder` 相邻插入），新片段 `startTime`/`endTime` 与原片段完全一致

**关键设计决定：全程只用 ffmpeg 做抽帧和编码，不碰 `AVAssetReader`/`AVAssetImageGenerator`。** 这是直接吸取本次会话debug 经验的决定——家用机上 AVFoundation 的这类调用会让读取请求永久挂死、占满 Swift 协作池，波及全应用（详见 `home_machine_decode_issue.md`）。这个功能逐帧吞吐量大、耗时长，一旦踩中同样的坑影响面更大。ffmpeg 静态编译、解码器内置，不依赖系统解码服务，更可控。

## 状态机

```swift
enum ClarityScale: Int { case x2 = 2, x4 = 4 }

enum ClarityEnhanceState: Equatable {
    case idle
    case downloadingModel(Double)
    case extractingFrames(Double)
    case inferring(Double)      // 最耗时的阶段，逐帧推理进度
    case encoding
    case failed(String)
}
```

处理任务需要携带 `scale: ClarityScale` 参数，决定用哪个模型、临时文件/输出文件命名带上倍数后缀。

同一时间只允许一个清晰度提升任务在跑（互斥，不支持多任务并发/排队，跟 demucs 一致）。支持取消（杀掉 ffmpeg 子进程和推理任务，清理临时文件，状态回 `idle`）。

UI 上需要一个悬浮进度气泡组件（参照 `RemoveBackgroundBubble`/`SceneDetectBubble` 的模式），显示当前阶段+进度百分比。

## 界面设计

### 设置面板

在"视频"标签（`sceneDetectTab` 所在位置）下新增分区，复用现有组件卡片样式（状态徽章：已安装/下载按钮/下载进度条/失败重试，完全对照 `SceneDetector` 的实现）。x2/x4 是两个独立模型文件，各自独立的安装状态：

```
清晰度提升
┌─────────────────────────────────────┐
│ FSRCNN x2             [已安装/下载/进度条] │
│ 视频超分辨率模型 2倍放大（CoreML），约 50KB  │
├─────────────────────────────────────┤
│ FSRCNN x4             [已安装/下载/进度条] │
│ 视频超分辨率模型 4倍放大（CoreML），约 50KB  │
└─────────────────────────────────────┘
安装后可在时间轴视频片段右键使用「清晰度提升」，
把低清素材放大为高清版本，新建独立轨道，不影响原片段。
```
（模型体积极小，下载几乎瞬间完成——这跟 BiRefNet/whisper/demucs 那种"要等几十秒到几分钟"的下载体验不同，下载进度条可能一晃而过，属于预期行为不是 bug）

### 右键菜单

在 `TimelineView.swift` 的右键菜单里，`project.selectedVideoClipID != nil` 分支下（跟"分离音轨"同级）新增一个二级菜单——两个倍数是离散的少量选项，对照 BiRefNet 系统内置引擎下"去除背景"的子菜单模式（`Menu { Button 智能识别主体; Button 纯色背景 }`）：

```swift
Menu {
    Button { project.enhanceClaritySelection(scale: .x2) } label: {
        Text("放大 2 倍")
    }
    Button { project.enhanceClaritySelection(scale: .x4) } label: {
        Text("放大 4 倍")
    }
} label: {
    Label("清晰度提升", systemImage: "sparkles")
}
.disabled(!project.canEnhanceClarity)
```

`canEnhanceClarity` 只判断"有选中视频片段"+"当前没有任务在跑"——**不因模型未下载而 disabled**。两个子选项都始终可点，点击后内部检查对应倍数的模型是否已下载，没有就先触发下载（对照 BiRefNet 的模式：托管模型按需下载，不是"缺二进制先阻断提示装"那种，因为 CoreML 模型没有额外的二进制依赖）。

## 错误处理与边界情况

- **磁盘空间**：处理前按帧数估算所需临时空间（1080p→4K，300 帧量级可能接近 1GB），检查可用磁盘，不够直接报错，不要写到一半才失败
- **临时文件清理**：抽帧目录无论成功/失败/取消都要清理（`defer` 兜底，参照现有 `ffmpegFrameStrip` 的模式）
- **耗时提示**：点击「清晰度提升」时按片段时长估算处理耗时量级，预计较长时先弹确认提示（"预计需要 X 分钟，确认继续吗"）。FSRCNN 实测耗时公式：`per_tile_ms（x4=7.52ms 或按 Task 3 重新实测的真实模型数值）× 40（1080p tile 数）× frame_count`——按这个公式算，绝大多数片段长度都不会触发这个确认框（FSRCNN 处理 10 秒 1080p 片段最多约 1.5 分钟），这个提示逻辑保留是为了极长片段（几分钟以上素材）兜底，不是像 Real-ESRGAN 那样的常态
- **分辨率上限保护**：源片段短边已经较高（阈值待实现时定，参考 x4 时 ≥1520、x2 时 ≥2160）时提示"素材已经较清晰，放大 N 倍收益有限"，但不强制阻止，用户可自行选择继续
- **处理中原片段被删除/撤销**：任务只依赖抽出来的临时文件和 URL，不依赖 clip 对象存活。完成时如果发现原片段已经不在时间轴上了，只把结果放进素材库，不再新建轨道插入片段
- **取消**：杀掉 ffmpeg 子进程和推理任务，清理临时文件，状态回 `idle`（同 `cancelSeparate` 的模式）

## 明确不做的范围（Out of Scope）

- 云端引擎（`.cloud` 分支）的实际实现——只留架构扩展点
- 批量/多选片段一起处理——跟 demucs 一致，单选单任务
- 实时预览滤镜级效果——本功能是"生成新文件"模式，不是实时预览

## 待验证风险清单（实施第一步必须做，2026-08-04 按 FSRCNN 方案更新）

之前版本（Real-ESRGAN）标注的两个风险——"CoreML 转换是否顺畅"、"实际推理耗时"——已经通过探索性验证解决（转换零报错；速度实测见上，比 Real-ESRGAN 快 15-130 倍）。FSRCNN 方案新的风险点：

1. **权重迁移正确性**（最大不确定性）：官方权重是 TensorFlow `.pb` 格式，需要手动迁移到 PyTorch 模型（按层对应关系赋值 8 个卷积核+偏置+7 组 PReLU alpha）。必须验证迁移后的 PyTorch 模型输出，跟原始 OpenCV `dnn_superres`（真实官方权重）推理输出数值/视觉一致——不能假设"权重形状对上了就是对的"，卷积核的通道顺序、PReLU 的 alpha 广播方式都可能有隐蔽的对应错误。
2. **真实素材效果**（未验证）：目前只在一张插画图上验证过视觉效果，插画对任何超分模型都相对友好。必须用真实拍摄、有压缩痕迹/噪点/轻微模糊的视频帧做验证，确认效果是否真的达到"清晰度提升"这个功能名副其实的程度——如果真实素材上效果明显不如学术 benchmark 暗示的那样好，需要重新跟用户同步这个发现，不能自己下结论说"能用"。
3. Y/Cb/Cr 色彩空间转换的正确性（新增环节，Real-ESRGAN 方案没有这一步）：双线性插值放大 Cb/Cr 通道 + 模型放大 Y 通道 + 三通道合并转回 RGB，这个流程本身简单但容易在色彩空间转换的具体实现细节上出错（比如 BT.601 vs BT.709 的 YCbCr 转换系数差异，可能导致轻微的色偏）。

## 关联文档

- 处理流程骨架参照：`Sources/VideoEditor/Models/ProjectState+AudioSeparate.swift`
- 进度气泡组件参照：`RemoveBackgroundBubble`（`MediaLibraryView.swift`）
- 家用机 AVFoundation 死锁教训：`.claude/projects/-Users-Venico-claude/memory/home_machine_decode_issue.md`
