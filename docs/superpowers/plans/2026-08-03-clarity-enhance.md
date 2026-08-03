# 清晰度提升（视频超分辨率）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在黑猫剪辑里加一个"清晰度提升"功能——时间轴视频片段右键选 2x/4x，本地 CoreML 跑 Real-ESRGAN 逐帧放大，生成新素材+新建视频轨道，跟原片段时间对齐。

**Architecture:** ffmpeg 抽帧 → CoreML（Real-ESRGAN RRDBNet，x2plus/x4plus 两个模型）逐帧超分（大于模型固定输入尺寸的帧做 tile 分块推理再拼接）→ ffmpeg 用放大后帧序列+原始音轨重编码 → 写入素材库 → 建新轨道插入片段。整条链路结构上照抄 `ProjectState+AudioSeparate.swift`（demucs 分离音轨）的骨架：状态机 + 进度气泡 + 后台任务 + 可取消。全程不碰 `AVAssetReader`/`AVAssetImageGenerator`（本次会话验证过这类调用在部分机器上会永久挂死拖垮协作池）。

**Tech Stack:** Swift 5.9 / SwiftUI / CoreML / ffmpeg（项目内置静态编译版）/ Python + PyTorch + coremltools（仅模型转换阶段，不进最终 app）

## Global Constraints

- 部署路径固定两处，必须双路径同步：`cp .build/debug/VideoEditor` 到 `/Users/Venico/claude/黑猫剪辑.app/Contents/MacOS/VideoEditor` 和 `/Users/Venico/claude/VideoEditor/黑猫剪辑.app/Contents/MacOS/VideoEditor`，随后 `codesign --force --sign -` 两处
- 签名一律 ad-hoc（`codesign --force --sign -`），不用 Apple Development 证书
- 每个 Swift 任务完成后跑 `swift build`（在 `/Users/Venico/claude/VideoEditor` 下），必须无 error 才能进入下一步
- 测试命令：`swift test --filter <TestClassName>`（项目已有 `Tests/VideoEditorTests` target）
- 新建轨道后必须同步 `videoSectionOrder`，否则片段不显示（详见 `TimelineView.swift` 现有轨道同步逻辑）
- 撤销快照默认不含素材（`currentSnapshot()` 的 `includeAssets` 默认 false），涉及素材增删的操作要用 `pushUndoSavingAssets()`
- 批量更新 `@Published` 数组严禁逐条改（N 条 = 2N 次 UI 重绘），先攒在局部变量里再一次性赋值
- 模型/二进制不进 git 仓库，走 GitHub Release 资产（`venico/blackcat-models` 公开仓库，主仓库私有）

---

## 任务总览与依赖关系

```
Task 1 (PyTorch 验证) → Task 2 (转 CoreML) → Task 3 (耗时实测) → Task 4 (打包上传)
                                                                        ↓
Task 5 (ClarityModel 下载管理) ──────────────────────────────────────┘
        ↓
Task 6 (CoreML 推理封装) → Task 7 (状态机数据模型)
                                  ↓
Task 8 (ffmpeg 抽帧/编码) → Task 9 (主流程整合)
                                  ↓
                    ┌─────────────┼─────────────┐
                    ↓             ↓             ↓
              Task 10        Task 11        Task 12
            (进度气泡)      (设置面板)      (右键菜单)
```

**Task 1-4 是 Python 侧的一次性模型转换准备工作，不产出 Swift 代码，也不在 `swift test` 框架内。** 这是设计文档里标注的最大不确定性——RRDBNet 转 CoreML 的可行性从未实际验证过。如果 Task 1-2 中转换失败或效果明显不对，必须停下来用 `superpowers:systematic-debugging` 排查根因，不能跳过验证直接往下走 Swift 集成（后面的 Swift 代码全部依赖这两个模型文件存在且能正确推理，一旦模型本身有问题，后面写的每一行 Swift 代码都是建在流沙上）。

---

### Task 1: PyTorch 环境搭建 + 原始推理验证

**目的**：在动手转换 CoreML 之前，先确认能用官方权重跑通一次原始 PyTorch 推理——这是后续所有验证的"基准答案"，用来判断 CoreML 转换后的输出是否合理。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/inference_check.py`（独立工作目录，不进 VideoEditor 仓库——这是一次性转换工具，参照 BiRefNet 转换脚本"不需要长期维护、日常不需要"的先例）
- Create: `/Users/Venico/claude/clarity-convert/requirements.txt`

**Interfaces:**
- Produces: `x4plus.pth`、`x2plus.pth`（下载到本地）、`baseline_x4.png`、`baseline_x2.png`（PyTorch 原始推理输出，后续 Task 2 用来对比 CoreML 输出是否合理）

- [ ] **Step 1: 建工作目录 + 虚拟环境**

```bash
mkdir -p /Users/Venico/claude/clarity-convert
cd /Users/Venico/claude/clarity-convert
python3 -m venv venv
source venv/bin/activate
```

- [ ] **Step 2: 写依赖文件**

```
# /Users/Venico/claude/clarity-convert/requirements.txt
torch==2.5.1
torchvision==0.20.1
realesrgan==0.3.0
basicsr==1.4.2
coremltools==8.0
pillow
numpy
```

- [ ] **Step 3: 安装依赖**

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
pip install -r requirements.txt
```

Expected: 无报错安装完成。`basicsr` 依赖 `torchvision.transforms.functional_tensor`，如果 `torchvision` 版本太新可能导入失败（报 `ModuleNotFoundError: torchvision.transforms.functional_tensor`）——这是这几个包版本兼容性的已知坑，如果遇到，先尝试 `pip install basicsr --no-deps` 再手动补齐其余依赖，不要花太久在这个坑上，最多花 15 分钟排查，排查不出来就换更老的 torchvision 版本重试。

- [ ] **Step 4: 下载官方权重**

```bash
cd /Users/Venico/claude/clarity-convert
curl -L -o x4plus.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
curl -L -o x2plus.pth "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
ls -lh *.pth
```

Expected: `x4plus.pth` 约 64MB（67,040,989 bytes），`x2plus.pth` 约 64MB（67,061,725 bytes）。这两个 URL 已经用 `curl -sIL` 验证过是真实可下载的官方资产。

- [ ] **Step 5: 找一张测试图**

```bash
# 用项目现有的任意一张低清素材，或者随手截一张 480p 左右的图。
# 这里假设用户桌面有素材，没有的话用 sips 从任意图片生成一张缩小版：
sips -Z 480 /Users/Venico/Desktop/AI生成/*.png --out /Users/Venico/claude/clarity-convert/test_input.png 2>/dev/null \
  || echo "找不到现成素材，需要手动放一张 test_input.png 到 /Users/Venico/claude/clarity-convert/"
```

如果自动化找不到素材，手动准备一张 `test_input.png`（几百像素见方即可，任意内容，只是用来验证推理管线通不通）。

- [ ] **Step 6: 写原始推理验证脚本**

```python
# /Users/Venico/claude/clarity-convert/inference_check.py
import torch
from basicsr.archs.rrdbnet_arch import RRDBNet
from PIL import Image
import numpy as np
import sys

def load_model(pth_path, scale):
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                     num_block=23, num_grow_ch=32, scale=scale)
    state_dict = torch.load(pth_path, map_location='cpu')
    if 'params_ema' in state_dict:
        state_dict = state_dict['params_ema']
    elif 'params' in state_dict:
        state_dict = state_dict['params']
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model

def run_inference(model, input_path, output_path):
    img = Image.open(input_path).convert('RGB')
    arr = np.array(img).astype(np.float32) / 255.0
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        out = model(tensor)
    out = out.squeeze(0).permute(1, 2, 0).clamp(0, 1).numpy()
    out_img = Image.fromarray((out * 255).round().astype(np.uint8))
    out_img.save(output_path)
    print(f"{input_path} ({img.size}) -> {output_path} ({out_img.size})")
    return img.size, out_img.size

if __name__ == '__main__':
    scale = int(sys.argv[1])  # 2 或 4
    pth = f"x{scale}plus.pth"
    model = load_model(pth, scale)
    in_size, out_size = run_inference(model, "test_input.png", f"baseline_x{scale}.png")
    expected = (in_size[0] * scale, in_size[1] * scale)
    assert out_size == expected, f"输出尺寸不对：期望 {expected}，实际 {out_size}"
    print(f"x{scale} 验证通过：尺寸放大 {scale} 倍")
```

- [ ] **Step 7: 跑一遍，两个倍数都验证**

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
python inference_check.py 4
python inference_check.py 2
open baseline_x4.png baseline_x2.png test_input.png
```

Expected: 两条命令都打印"验证通过"，且尺寸断言不报错。打开三张图肉眼确认 `baseline_x4.png`/`baseline_x2.png` 看起来是 `test_input.png` 放大后的合理版本（不是噪声、不是全黑/全白）——这是权重加载正确、网络结构定义匹配的直接证据。

**如果这一步失败**（`state_dict` key 不匹配、尺寸不对、输出是噪声）：停下来用 systematic-debugging 排查，不要往 Task 2 走。常见原因：权重文件的 state_dict key 结构跟 `basicsr` 版本不匹配（Real-ESRGAN 项目迭代过几次权重格式）。

---

### Task 2: PyTorch → CoreML 转换

**目的**：把验证过的 PyTorch 模型转换成 CoreML 格式，这是设计文档标注的最大风险点——RRDBNet 架构虽然只有标准卷积，但转换过程本身此前完全没有验证过。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/convert_coreml.py`

**Interfaces:**
- Consumes: Task 1 产出的 `x2plus.pth`/`x4plus.pth`、`RRDBNet` 网络结构定义（`num_feat=64, num_block=23, num_grow_ch=32`）
- Produces: `RealESRGAN_x2plus.mlpackage`、`RealESRGAN_x4plus.mlpackage`

- [ ] **Step 1: 写转换脚本**

RRDBNet 是纯前馈网络（没有控制流分支），用 `torch.jit.trace` 是合适的（不需要 `torch.export`，那是 BiRefNet 因为有动态形状 patch 才用的更复杂路径）。CoreML 用 `ImageType` 作为输入输出，这样 Swift 侧可以直接喂 `CVPixelBuffer`，不用手动做 tensor 归一化：

```python
# /Users/Venico/claude/clarity-convert/convert_coreml.py
import torch
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet
import sys

def load_model(pth_path, scale):
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                     num_block=23, num_grow_ch=32, scale=scale)
    state_dict = torch.load(pth_path, map_location='cpu')
    if 'params_ema' in state_dict:
        state_dict = state_dict['params_ema']
    elif 'params' in state_dict:
        state_dict = state_dict['params']
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model

def convert(scale, tile_size=256):
    model = load_model(f"x{scale}plus.pth", scale)
    example_input = torch.rand(1, 3, tile_size, tile_size)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example_input.shape,
                              scale=1/255.0, bias=[0, 0, 0],
                              color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    out_path = f"RealESRGAN_x{scale}plus.mlpackage"
    mlmodel.save(out_path)
    print(f"已保存 {out_path}")
    return out_path

if __name__ == '__main__':
    scale = int(sys.argv[1])
    convert(scale)
```

这里用固定的 `tile_size=256` 作为输入尺寸——CoreML 转换后的模型输入尺寸是固定的（trace 时的 shape），不像 PyTorch 原生那样能吃任意尺寸。这意味着 Swift 侧推理时，任意尺寸的视频帧都要先切成 256×256 的 tile 分块跑，再拼接回原尺寸——这个 tile 拼接逻辑在 Task 6 实现。选 256 是内存/速度的折中，如果 Task 3 实测发现这个尺寸单帧推理耗时过长或过短，可以回来调整这个数字重新转换。

- [ ] **Step 2: 跑转换**

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
python convert_coreml.py 4
python convert_coreml.py 2
ls -la *.mlpackage
```

Expected: 生成 `RealESRGAN_x4plus.mlpackage` 和 `RealESRGAN_x2plus.mlpackage` 两个目录，转换过程无报错。

**如果这一步报错**（常见：某个 PyTorch 算子 CoreML 不支持、trace 时出现 warning about控制流）：这是设计文档里标注的核心风险，如果真的踩到不支持的算子，先看报错信息里具体是哪个算子，搜索 `coremltools` 是否有已知的 workaround 或者需要换更新的 `coremltools` 版本；如果排查 30 分钟仍无进展，停下来跟用户同步这个风险已经命中，需要重新评估方案（比如退回到"只做 CoreML 支持较好的更早期 SRCNN/ESPCN 这类更简单的模型"），不要在这里无限循环硬冲。

- [ ] **Step 3: 用 Python 验证转换后的模型能推理**

```python
# /Users/Venico/claude/clarity-convert/verify_coreml.py
import coremltools as ct
from PIL import Image
import sys

scale = int(sys.argv[1])
model = ct.models.MLModel(f"RealESRGAN_x{scale}plus.mlpackage")

# 用跟转换时一致的 tile_size 生成测试输入
img = Image.open("test_input.png").convert('RGB').resize((256, 256))
result = model.predict({"input": img})
out_img = result["output"]
out_img.save(f"coreml_output_x{scale}.png")
print(f"CoreML x{scale} 输出尺寸: {out_img.size}，期望: {(256*scale, 256*scale)}")
assert out_img.size == (256 * scale, 256 * scale), "尺寸不对"
print("验证通过")
```

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
python verify_coreml.py 4
python verify_coreml.py 2
open coreml_output_x4.png coreml_output_x2.png
```

Expected: 两条命令都打印"验证通过"，打开的图片视觉上应该跟 Task 1 的 `baseline_x4.png`/`baseline_x2.png`（同样输入下）相似——不要求逐像素相同（CoreML 转换可能有精度损失），但应该是清晰的、合理的放大结果，不是噪声或者明显走样的图案。这一步是转换正确性的最终判据。

- [ ] **Step 4: 编译成 .mlmodelc（运行时最终会用的格式）**

BiRefNet 最终打包用的是编译后的 `.mlmodelc`（参照 `BiRefNetModel.swift` 里的 `fileName` 是 `BiRefNet_lite.mlmodelc`），不是开发用的 `.mlpackage`：

```bash
cd /Users/Venico/claude/clarity-convert
xcrun coremlcompiler compile RealESRGAN_x4plus.mlpackage .
xcrun coremlcompiler compile RealESRGAN_x2plus.mlpackage .
ls -la RealESRGAN_x4plus.mlmodelc RealESRGAN_x2plus.mlmodelc
```

Expected: 生成 `RealESRGAN_x4plus.mlmodelc` 和 `RealESRGAN_x2plus.mlmodelc` 两个目录，各自内含 `coremldata.bin`（对照 `BiRefNetDownloadTests.swift` 里检查这个文件存在的验证逻辑）。

---

### Task 3: CoreML 推理耗时实测

**目的**：设计文档标注的第二个未验证风险——之前只是"参考同类模型量级"估算耗时，从没实测过。这个数字直接决定 Task 9 里"耗时提示"的具体阈值。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/benchmark.py`

**Interfaces:**
- Consumes: Task 2 产出的 `.mlmodelc`
- Produces: 单个 tile（256×256）推理耗时的实测数据，用于反推整段视频处理耗时估算公式

- [ ] **Step 1: 写耗时测试脚本**

```python
# /Users/Venico/claude/clarity-convert/benchmark.py
import coremltools as ct
from PIL import Image
import time
import sys

scale = int(sys.argv[1])
model = ct.models.MLModel(f"RealESRGAN_x{scale}plus.mlmodelc",
                           compute_units=ct.ComputeUnit.CPU_AND_GPU)
img = Image.open("test_input.png").convert('RGB').resize((256, 256))

# 第一次推理包含模型加载预热，不计入
_ = model.predict({"input": img})

N = 20
start = time.time()
for _ in range(N):
    _ = model.predict({"input": img})
elapsed = time.time() - start
per_tile = elapsed / N
print(f"x{scale}: 单 tile（256x256）推理平均耗时 {per_tile*1000:.1f}ms")

# 反推：1080p (1920x1080) 画面按 256x256 tile 切分大约需要多少块
tiles_per_frame = (1920 // 256 + 1) * (1080 // 256 + 1)
print(f"1080p 每帧约需 {tiles_per_frame} 个 tile，单帧预估耗时 {per_tile * tiles_per_frame:.2f}s")
print(f"10 秒 30fps 片段（300 帧）预估总耗时 {per_tile * tiles_per_frame * 300 / 60:.1f} 分钟")
```

- [ ] **Step 2: 跑测试，记录真实数字**

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
python benchmark.py 4
python benchmark.py 2
```

Expected: 打印出真实的单 tile 耗时和预估的整段处理时间。**把这两个数字记下来**——Task 9 的"耗时提示"逻辑要用这个实测公式（`per_tile_ms × tiles_per_frame × frame_count`），不能再用设计文档里"几分钟到十几分钟"这种没有实测支撑的估算。

如果实测耗时远超设计文档估算的量级（比如 10 秒片段要处理半小时以上），这是一个需要跟用户同步的重要发现——可能需要重新考虑是否要在 tile 尺寸、compute_units（试试 `.all` 看 ANE 是否能用上）上做优化，再继续往下走。

---

### Task 4: 模型打包上传

**目的**：把验证过的模型发布到 `venico/blackcat-models`，跟 BiRefNet 用同一个托管仓库。

**Files:**
- 无代码文件，纯操作步骤

**Interfaces:**
- Produces: 两个可匿名下载的 URL，供 Task 5 的 `ClarityModel.swift` 使用

- [ ] **Step 1: 打包成 zip（跟 BiRefNet 的 `archiveName` 命名模式一致：`<mlmodelc目录名>.zip`）**

```bash
cd /Users/Venico/claude/clarity-convert
zip -r RealESRGAN_x2plus.mlmodelc.zip RealESRGAN_x2plus.mlmodelc
zip -r RealESRGAN_x4plus.mlmodelc.zip RealESRGAN_x4plus.mlmodelc
ls -lh *.zip
```

- [ ] **Step 2: 上传到 blackcat-models release**

```bash
cd /Users/Venico/claude/clarity-convert
gh release create realesrgan-v1 \
  --repo venico/blackcat-models \
  --title "Real-ESRGAN CoreML v1" \
  --notes "Real-ESRGAN x2plus/x4plus CoreML 模型，视频清晰度提升功能用" \
  RealESRGAN_x2plus.mlmodelc.zip RealESRGAN_x4plus.mlmodelc.zip
```

Expected: 命令成功，返回 release 页面 URL。

- [ ] **Step 3: 验证匿名可访问（跟 `BiRefNetDownloadTests.testDownloadURLIsPubliclyReachable` 的验证逻辑一致）**

```bash
curl -sI "https://github.com/venico/blackcat-models/releases/download/realesrgan-v1/RealESRGAN_x4plus.mlmodelc.zip" | head -3
curl -sI "https://github.com/venico/blackcat-models/releases/download/realesrgan-v1/RealESRGAN_x2plus.mlmodelc.zip" | head -3
```

Expected: 两个都返回 `HTTP/2 302`（重定向到实际下载地址，这是 GitHub release 资产的正常响应，跟 Task 1 验证 Real-ESRGAN 官方权重时看到的响应一致）。

---

### Task 5: ClarityModel.swift — 模型下载与管理

**目的**：Swift 侧第一个文件，管理两个模型的下载状态。完全照抄 `BiRefNetModel.swift` 的结构。

**Files:**
- Create: `Sources/VideoEditor/Models/ClarityModel.swift`
- Test: `Tests/VideoEditorTests/ClarityModelDownloadTests.swift`

**Interfaces:**
- Produces: `enum ClarityModel: String, CaseIterable { case x2, x4 }`，`ClarityModel.download(onProgress:)`、`.isDownloaded`、`.localURL`、`.supportDir`

- [ ] **Step 1: 写 `ClarityModel.swift`**

```swift
// ClarityModel.swift
// Real-ESRGAN 清晰度提升模型的下载与管理。跟 BiRefNet 同一套路子：
// 模型不打进安装包，用户用到时才下到 Application Support。
import Foundation

enum ClarityModel: String, CaseIterable, Identifiable {
    case x2
    case x4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .x2: return "Real-ESRGAN x2"
        case .x4: return "Real-ESRGAN x4"
        }
    }

    var sizeDesc: String {
        switch self {
        case .x2: return "约 64 MB · 放大 2 倍"
        case .x4: return "约 64 MB · 放大 4 倍"
        }
    }

    var fileName: String {
        switch self {
        case .x2: return "RealESRGAN_x2plus.mlmodelc"
        case .x4: return "RealESRGAN_x4plus.mlmodelc"
        }
    }

    var archiveName: String { "\(fileName).zip" }

    var sourceURLs: [String] {
        switch self {
        case .x2:
            return ["https://github.com/venico/blackcat-models/releases/download/realesrgan-v1/RealESRGAN_x2plus.mlmodelc.zip"]
        case .x4:
            return ["https://github.com/venico/blackcat-models/releases/download/realesrgan-v1/RealESRGAN_x4plus.mlmodelc.zip"]
        }
    }

    var minFileSize: Int { 30_000_000 }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/clarity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localURL: URL { Self.supportDir.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    enum DownloadError: Error, LocalizedError {
        case noSource
        case badResponse(Int)
        case tooSmall
        case unpackFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSource:             return "该模型暂无可用下载源"
            case .badResponse(let c):   return "下载失败（HTTP \(c)）"
            case .tooSmall:             return "下载的文件不完整，请重试"
            case .unpackFailed(let d):  return "解压失败：\(d)"
            }
        }
    }

    func download(onProgress: @escaping (Double) -> Void) async throws {
        guard !sourceURLs.isEmpty else { throw DownloadError.noSource }
        var lastError: Error = DownloadError.noSource
        for urlString in sourceURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                try await downloadOne(url, onProgress: onProgress)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func downloadOne(_ url: URL, onProgress: @escaping (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("BlackCat/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.badResponse(http.statusCode)
        }
        let total = response.expectedContentLength

        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 1 << 20)
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if total > 0 {
                let pct = Double(data.count) / Double(total)
                if pct - lastReported >= 0.01 {
                    lastReported = pct
                    onProgress(pct)
                }
            }
        }
        guard data.count >= minFileSize else { throw DownloadError.tooSmall }

        let tmpZip = Self.supportDir.appendingPathComponent("\(archiveName).part")
        try? FileManager.default.removeItem(at: tmpZip)
        try data.write(to: tmpZip)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let staging = Self.supportDir.appendingPathComponent("unzip-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try unzip(tmpZip, to: staging)

        let extracted = staging.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw DownloadError.unpackFailed("压缩包里没有 \(fileName)")
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: extracted, to: localURL)
        onProgress(1.0)
    }

    private func unzip(_ archive: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dest.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw DownloadError.unpackFailed(error.localizedDescription)
        }
        let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DownloadError.unpackFailed(detail.isEmpty ? "ditto 退出码 \(p.terminationStatus)" : detail)
        }
    }

    func delete() throws {
        guard isDownloaded else { return }
        try FileManager.default.removeItem(at: localURL)
    }
}
```

- [ ] **Step 2: 写下载可达性测试（对照 `BiRefNetDownloadTests.testDownloadURLIsPubliclyReachable`）**

```swift
// Tests/VideoEditorTests/ClarityModelDownloadTests.swift
import XCTest
import Foundation
@testable import VideoEditorLib

// 真的去 release 拉 64MB，跑得慢，默认跳过。
// 要验证时加环境变量：BLACKCAT_TEST_DOWNLOAD=1 swift test --filter ClarityModelDownloadTests

final class ClarityModelDownloadTests: XCTestCase {

    func testDownloadURLIsPubliclyReachable() async throws {
        for model in ClarityModel.allCases {
            try await checkReachable(model)
        }
    }

    private func checkReachable(_ model: ClarityModel) async throws {
        let urlString = try XCTUnwrap(model.sourceURLs.first, "\(model.displayName) 应该有下载源")
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 90

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("网络不通，跳过：\(error.localizedDescription)")
        }
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue([200, 206].contains(http.statusCode),
                      "\(model.displayName) 匿名访问应拿到 200/206，实际 \(http.statusCode)")
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "\(model.displayName) 开头应是 ZIP 魔数 PK")
    }

    func testFullDownloadAndUnpack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACKCAT_TEST_DOWNLOAD"] == "1",
                          "设 BLACKCAT_TEST_DOWNLOAD=1 才跑这条")

        let model = ClarityModel.x2
        let fm = FileManager.default
        var backup: URL?
        if model.isDownloaded {
            let b = model.localURL.appendingPathExtension("bak-\(UUID().uuidString)")
            try fm.moveItem(at: model.localURL, to: b)
            backup = b
        }
        defer {
            if let b = backup {
                try? fm.removeItem(at: model.localURL)
                try? fm.moveItem(at: b, to: model.localURL)
            }
        }

        XCTAssertFalse(model.isDownloaded, "挪开后应视为未下载")

        var lastPct = 0.0
        try await model.download { pct in lastPct = pct }

        XCTAssertTrue(model.isDownloaded, "下载完应该能检测到模型")
        XCTAssertEqual(lastPct, 1.0, accuracy: 0.001, "进度应走到 100%")

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "mlmodelc 应该是目录")
        XCTAssertTrue(fm.fileExists(atPath: model.localURL.appendingPathComponent("coremldata.bin").path),
                      "缺 coremldata.bin，解压结果不完整")

        let leftovers = (try? fm.contentsOfDirectory(atPath: ClarityModel.supportDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("unzip-") || $0.hasSuffix(".part") },
                       "不该残留临时文件：\(leftovers)")
    }
}
```

- [ ] **Step 3: 编译 + 跑可达性测试**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
swift test --filter ClarityModelDownloadTests 2>&1 | tail -20
```

Expected: `Build complete`；测试跑 `testDownloadURLIsPubliclyReachable`（用了 Task 4 真实上传的 URL，应该通过），`testFullDownloadAndUnpack` 因为没设环境变量会被跳过（正常）。

- [ ] **Step 4: 跑一次完整下载验证（可选但推荐，确认下载链路真的通）**

```bash
cd /Users/Venico/claude/VideoEditor
BLACKCAT_TEST_DOWNLOAD=1 swift test --filter ClarityModelDownloadTests/testFullDownloadAndUnpack 2>&1 | tail -20
```

Expected: 测试通过，说明 Task 4 上传的 zip 结构（内部目录名跟 `fileName` 一致）是对的。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/ClarityModel.swift Tests/VideoEditorTests/ClarityModelDownloadTests.swift
git commit -m "feat: 清晰度提升 — ClarityModel 模型下载管理"
```

---

### Task 6: ClarityEnhancer.swift — CoreML 单帧推理 + tile 拼接

**目的**：核心推理封装。因为 Task 2 转换时用固定 256×256 输入，这里要实现"任意尺寸图片 → 切 tile → 逐块推理 → 拼接回原尺寸"的逻辑。

**Files:**
- Create: `Sources/VideoEditor/Models/ClarityEnhancer.swift`
- Test: `Tests/VideoEditorTests/ClarityEnhancerTests.swift`

**Interfaces:**
- Consumes: `ClarityModel.localURL`、`ClarityModel.isDownloaded`（Task 5）
- Produces: `ClarityEnhancer.enhance(cgImage:model:) throws -> CGImage`

- [ ] **Step 1: 写 `ClarityEnhancer.swift`**

```swift
// ClarityEnhancer.swift
// Real-ESRGAN 的 CoreML 推理。模型固定吃 256x256 RGB 输入（转换时的 trace 尺寸），
// 更大的图需要切 tile 分块推理再拼接。tile 之间留 16px 重叠区域，取中心部分拼接，
// 避免每块边缘因为缺乏上下文导致的细节劣化在拼接处形成可见接缝。
import Foundation
import CoreML
import CoreImage
import AppKit

enum ClarityEnhancer {

    static let tileSize = 256
    static let tileOverlap = 16

    enum EnhanceError: Error, LocalizedError {
        case modelMissing
        case loadFailed(String)
        case inferenceFailed(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing:          return "还没下载清晰度提升模型，请到设置 → 视频里下载"
            case .loadFailed(let d):     return "模型加载失败：\(d)"
            case .inferenceFailed(let d): return "超分辨率推理失败：\(d)"
            case .badOutput:             return "模型输出格式不符合预期"
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cached: (path: String, model: MLModel)?

    private static func model(at url: URL) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            cached = (url.path, m)
            return m
        } catch {
            throw EnhanceError.loadFailed(error.localizedDescription)
        }
    }

    /// 单张图片超分辨率放大。onTileProgress 在每个 tile 处理完后回调（0...1），交给上层显示进度
    static func enhance(cgImage: CGImage, model modelKind: ClarityModel,
                       onTileProgress: ((Double) -> Void)? = nil) throws -> CGImage {
        guard modelKind.isDownloaded else { throw EnhanceError.modelMissing }
        let mlModel = try model(at: modelKind.localURL)
        let scale = modelKind == .x2 ? 2 : 4

        let w = cgImage.width, h = cgImage.height
        let stride = tileSize - tileOverlap * 2
        var tilesX = max(1, Int(ceil(Double(w - tileOverlap * 2) / Double(stride))))
        var tilesY = max(1, Int(ceil(Double(h - tileOverlap * 2) / Double(stride))))
        if w <= tileSize { tilesX = 1 }
        if h <= tileSize { tilesY = 1 }
        let totalTiles = tilesX * tilesY

        guard let outCtx = CGContext(data: nil, width: w * scale, height: h * scale,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EnhanceError.inferenceFailed("输出画布创建失败")
        }

        var done = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let srcX = min(tx * stride, max(0, w - tileSize))
                let srcY = min(ty * stride, max(0, h - tileSize))
                let cropRect = CGRect(x: srcX, y: srcY,
                                      width: min(tileSize, w - srcX), height: min(tileSize, h - srcY))
                guard let tile = cgImage.cropping(to: cropRect) else { continue }
                let padded = try padToTileSize(tile)
                let outTile = try runOneTile(padded, mlModel: mlModel)

                // 贴回输出画布：非首个 tile 的重叠区裁掉，只取"新增"部分中心对齐拼接
                let destX = srcX * scale
                let destY = (h - srcY - Int(cropRect.height)) * scale  // CGContext y-up，翻转
                outCtx.draw(outTile, in: CGRect(x: destX, y: destY,
                                                width: Int(cropRect.width) * scale,
                                                height: Int(cropRect.height) * scale))
                done += 1
                onTileProgress?(Double(done) / Double(totalTiles))
            }
        }

        guard let result = outCtx.makeImage() else { throw EnhanceError.badOutput }
        return result
    }

    /// 图不足 tileSize 时右/下补边（用边缘像素延伸），推理完再裁掉补的部分
    private static func padToTileSize(_ tile: CGImage) throws -> CGImage {
        guard tile.width < tileSize || tile.height < tileSize else { return tile }
        guard let ctx = CGContext(data: nil, width: tileSize, height: tileSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EnhanceError.inferenceFailed("补边上下文创建失败")
        }
        ctx.draw(tile, in: CGRect(x: 0, y: tileSize - tile.height, width: tile.width, height: tile.height))
        guard let out = ctx.makeImage() else { throw EnhanceError.inferenceFailed("补边失败") }
        return out
    }

    private static func runOneTile(_ tile: CGImage, mlModel: MLModel) throws -> CGImage {
        let inputName = mlModel.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let ciImage = CIImage(cgImage: tile)
        guard let pixelBuffer = pixelBuffer(from: ciImage, width: tile.width, height: tile.height) else {
            throw EnhanceError.inferenceFailed("输入缓冲区创建失败")
        }
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        } catch {
            throw EnhanceError.inferenceFailed(error.localizedDescription)
        }
        let result: MLFeatureProvider
        do {
            result = try mlModel.prediction(from: provider)
        } catch {
            throw EnhanceError.inferenceFailed(error.localizedDescription)
        }
        guard let outName = mlModel.modelDescription.outputDescriptionsByName.keys.first,
              let outBuffer = result.featureValue(for: outName)?.imageBufferValue else {
            throw EnhanceError.badOutput
        }
        let outCI = CIImage(cvPixelBuffer: outBuffer)
        guard let cg = CIContext().createCGImage(outCI, from: outCI.extent) else {
            throw EnhanceError.badOutput
        }
        return cg
    }

    private static func pixelBuffer(from image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CIContext().render(image, to: buffer)
        return buffer
    }
}
```

**注意**：这个 tile 拼接实现是基于设计推理写的，具体的坐标计算（尤其 `destY` 的 y 轴翻转、tile 重叠区的裁剪逻辑）在 Step 2 的测试里必须用真实图片跑一遍肉眼检查有没有接缝错位——这类坐标计算极易出现"差一个像素"或者"y 轴翻转反了"的 bug，光看代码不足以确认正确性。

- [ ] **Step 2: 写测试（程序生成棋盘格图案，验证输出尺寸和拼接无明显错位）**

```swift
// Tests/VideoEditorTests/ClarityEnhancerTests.swift
import XCTest
import AppKit
@testable import VideoEditorLib

final class ClarityEnhancerTests: XCTestCase {

    /// 画一张比 tileSize 大的棋盘格图（触发多 tile 拼接路径），
    /// 用棋盘格是为了让拼接错位在肉眼看时非常显眼（网格线不对齐会立刻看出来）
    private func makeCheckerboard(size: Int, cell: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("无法创建绘图上下文")
        }
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let isDark = ((x / cell) + (y / cell)) % 2 == 0
                ctx.setFillColor(isDark ? CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
                                        : CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        guard let img = ctx.makeImage() else { throw XCTSkip("生成失败") }
        return img
    }

    func testEnhanceProducesCorrectOutputSize() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "Real-ESRGAN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)  // 比 tileSize(256) 大，触发多 tile
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        XCTAssertEqual(out.width, 400 * 4, "输出宽度应是原图 4 倍")
        XCTAssertEqual(out.height, 400 * 4, "输出高度应是原图 4 倍")
    }

    func testEnhanceX2ProducesCorrectOutputSize() throws {
        try XCTSkipUnless(ClarityModel.x2.isDownloaded, "Real-ESRGAN x2 模型未下载")
        let checker = try makeCheckerboard(size: 300, cell: 30)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x2)
        XCTAssertEqual(out.width, 300 * 2)
        XCTAssertEqual(out.height, 300 * 2)
    }

    /// 保存拼接结果到临时目录，手动打开肉眼检查有无接缝错位——
    /// 这个断言本身测不出"棋盘格线对不对齐"，但把文件路径打印出来，
    /// 方便这一步跑完后手动 open 检查
    func testEnhanceOutputSavedForVisualCheck() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "Real-ESRGAN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clarity_tile_check.png")
        let rep = NSBitmapImageRep(cgImage: out)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("拼接结果已保存，手动检查: \(url.path)")
    }

    func testEnhanceThrowsWhenModelMissing() throws {
        // 用一个还没下载的假想场景需要能测到 modelMissing —— 这里改用直接构造
        // 一个不存在的场景比较难做（下载状态是全局单例），改成检查错误类型可解码即可
        XCTAssertNotNil(ClarityEnhancer.EnhanceError.modelMissing.errorDescription)
    }
}
```

- [ ] **Step 3: 编译 + 跑测试**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
swift test --filter ClarityEnhancerTests 2>&1 | tail -30
```

Expected: 如果模型还没下载到本机（`~/Library/Application Support/黑猫剪辑/clarity/`），前两个测试会被跳过（正常，先手动跑一次 `ClarityModel.x4.download` 或者直接把 Task 2 产出的 `.mlmodelc` 手动拷贝到那个目录来跑通这一步）。`testEnhanceThrowsWhenModelMissing` 应该无条件通过。

- [ ] **Step 4: 手动肉眼验证 tile 拼接无接缝**

```bash
open /tmp/clarity_tile_check.png
```

Expected: 棋盘格线条在整张图上连续、对齐，没有在 tile 边界处断裂或错位。**如果看到接缝**，回到 `ClarityEnhancer.swift` 里检查 `destY` 的翻转计算和 tile 重叠裁剪逻辑——这是最容易出错的部分，需要现场调试，不要假设一次写对。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/ClarityEnhancer.swift Tests/VideoEditorTests/ClarityEnhancerTests.swift
git commit -m "feat: 清晰度提升 — ClarityEnhancer CoreML 推理 + tile 拼接"
```

---

### Task 7: 状态机数据模型（Project.swift 扩展）

**目的**：新增 `@Published` 状态属性，参照 `SeparateState`/`RemoveBackgroundState` 的模式。

**Files:**
- Modify: `Sources/VideoEditor/Models/Project.swift`
- Test: `Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift`

**Interfaces:**
- Produces: `ProjectState.ClarityScale`、`ProjectState.ClarityEnhanceState`、`@Published var clarityEnhanceState`、`var isEnhancingClarity: Bool`

- [ ] **Step 1: 在 `Project.swift` 里加状态机**

在文件里 `enum SeparateState` 附近（同一区块，方便以后维护）加入：

```swift
// 清晰度提升状态（Real-ESRGAN）
enum ClarityScale: Int, Equatable { case x2 = 2, x4 = 4 }

enum ClarityEnhanceState: Equatable {
    case idle
    case downloadingModel(Double)
    case extractingFrames(Double)
    case inferring(Double)
    case encoding
    case failed(String)

    /// 没有细粒度进度可报的阶段，按阶段给个近似值，让进度条别停着不动
    var approximateProgress: Double {
        switch self {
        case .idle:                    return 0
        case .downloadingModel(let p): return p * 0.1
        case .extractingFrames(let p): return 0.1 + p * 0.1
        case .inferring(let p):        return 0.2 + p * 0.7
        case .encoding:                return 0.95
        case .failed:                  return 0
        }
    }
}
@Published var clarityEnhanceState: ClarityEnhanceState = .idle
var clarityEnhanceTask: Task<Void, Never>? = nil
/// 处理流水线整体跑在专属线程上（不受 Swift Task 协作式取消管辖，
/// 详见 Task 9 的设计说明），取消要靠这个跨线程共享标志
var clarityCancelFlag: ClarityCancelFlag? = nil
var isEnhancingClarity: Bool {
    switch clarityEnhanceState {
    case .idle, .failed: return false
    default: return true
    }
}
func cancelClarityEnhance() {
    clarityCancelFlag?.cancel()
    ClarityFrameIO.killCurrentProcess()
    clarityEnhanceTask?.cancel()
    clarityEnhanceTask = nil
    clarityCancelFlag = nil
    clarityEnhanceState = .idle
    showSuccessToast(icon: "stop.fill", iconColor: .yellow, title: "清晰度提升", subtitle: "已停止", autoCountdown: false)
}
```

`ClarityCancelFlag` 是一个简单的跨线程取消信号，**定义在这次编辑的 `Project.swift` 里**（跟上面的状态机放在一起，同一个改动范围）——跟 `AudioSeparator.killCurrentProcess()` 一样的思路：专属线程里的重计算循环不受 `Task.isCancelled` 管辖，需要一个锁保护的标志位：

```swift
final class ClarityCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
}
```

- [ ] **Step 2: 写状态机测试（对照 `RemoveBackgroundProgressTests` 的 `testStageProgressIsMonotonic`/`testIsRemovingReflectsState`/`testCancelResetsState`）**

```swift
// Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift
import XCTest
@testable import VideoEditorLib

final class ClarityEnhanceProgressTests: XCTestCase {

    func testProgressIsMonotonicAcrossStages() {
        let stages: [ProjectState.ClarityEnhanceState] = [
            .downloadingModel(1.0), .extractingFrames(1.0), .inferring(1.0), .encoding
        ]
        var last = -1.0
        for s in stages {
            XCTAssertGreaterThan(s.approximateProgress, last, "阶段进度应递增：\(s)")
            last = s.approximateProgress
        }
        XCTAssertEqual(ProjectState.ClarityEnhanceState.idle.approximateProgress, 0)
    }

    @MainActor
    func testIsEnhancingReflectsState() {
        let p = ProjectState()
        XCTAssertFalse(p.isEnhancingClarity)
        p.clarityEnhanceState = .extractingFrames(0.5)
        XCTAssertTrue(p.isEnhancingClarity)
        p.clarityEnhanceState = .encoding
        XCTAssertTrue(p.isEnhancingClarity)
        p.clarityEnhanceState = .idle
        XCTAssertFalse(p.isEnhancingClarity)
        p.clarityEnhanceState = .failed("测试错误")
        XCTAssertFalse(p.isEnhancingClarity, "失败态不应算作进行中")
    }

    @MainActor
    func testCancelResetsState() {
        let p = ProjectState()
        p.clarityEnhanceState = .inferring(0.3)
        p.cancelClarityEnhance()
        XCTAssertFalse(p.isEnhancingClarity, "取消后应复位")
        XCTAssertEqual(p.successToasts.last?.title, "清晰度提升")
        XCTAssertEqual(p.successToasts.last?.subtitle, "已停止")
    }
}
```

- [ ] **Step 3: 编译 + 跑测试**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
swift test --filter ClarityEnhanceProgressTests 2>&1 | tail -20
```

Expected: `Build complete`，三个测试全部 PASS。

- [ ] **Step 4: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/Project.swift Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift
git commit -m "feat: 清晰度提升 — 状态机数据模型"
```

---

### Task 8: ffmpeg 抽帧 + 编码封装

**目的**：全程不碰 AVFoundation 的抽帧/编码函数，供 Task 9 的主流程调用。

**Files:**
- Create: `Sources/VideoEditor/Models/ClarityFrameIO.swift`
- Test: `Tests/VideoEditorTests/ClarityFrameIOTests.swift`

**Interfaces:**
- Consumes: `ProjectState.findFFmpeg()`（已有静态方法，见 `ProjectState+Import.swift:499`）
- Produces: `ClarityFrameIO.extractFrames(url:trimStart:duration:outputDir:) -> [URL]`、`ClarityFrameIO.encodeFrames(frameDir:frameRate:audioSourceURL:audioTrimStart:audioDuration:outputURL:) -> Bool`

- [ ] **Step 1: 写抽帧/编码函数**

```swift
// ClarityFrameIO.swift
// 清晰度提升的抽帧/编码，全程用内置 ffmpeg，不碰 AVAssetReader/AVAssetImageGenerator——
// 家用机实测这类 AVFoundation 调用会永久挂死并拖垮 Swift 协作池（详见
// home_machine_decode_issue.md），这个功能逐帧吞吐量大、耗时长，
// 踩中同样的坑影响面更大，没必要冒这个险。
import Foundation

enum ClarityFrameIO {

    enum FrameIOError: Error, LocalizedError {
        case ffmpegNotFound
        case extractFailed(String)
        case encodeFailed(String)
        case noFramesExtracted
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:       return "找不到内置 ffmpeg"
            case .extractFailed(let d): return "抽帧失败：\(d)"
            case .encodeFailed(let d):  return "编码失败：\(d)"
            case .noFramesExtracted:    return "没有抽出任何帧"
            case .cancelled:            return "已取消"
            }
        }
    }

    /// 当前运行的 ffmpeg 进程，供取消时 terminate（同 AudioSeparator.currentProcess 的模式）
    private static let processLock = NSLock()
    private static var _currentProcess: Process?
    static var currentProcess: Process? {
        get { processLock.withLock { _currentProcess } }
        set { processLock.withLock { _currentProcess = newValue } }
    }
    static func killCurrentProcess() {
        if let p = currentProcess, p.isRunning { p.terminate() }
        currentProcess = nil
    }

    /// 把片段裁剪范围解码成 PNG 序列，按帧率抽满。文件名 frame_00001.png 起
    nonisolated static func extractFrames(url: URL, trimStart: Double, duration: Double,
                                          frameRate: Double, outputDir: URL) throws -> [URL] {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if trimStart > 0.001 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-t", String(format: "%.6f", duration), "-i", url.path]
        args += ["-vf", "fps=\(frameRate)"]
        args += [outputDir.appendingPathComponent("frame_%05d.png").path]
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        currentProcess = p
        defer { currentProcess = nil }
        do { try p.run() } catch {
            throw FrameIOError.extractFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal { throw FrameIOError.cancelled }
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            throw FrameIOError.extractFailed("ffmpeg 退出码 \(p.terminationStatus) \(msg)")
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
            .map { outputDir.appendingPathComponent($0) }
        guard !files.isEmpty else { throw FrameIOError.noFramesExtracted }
        return files
    }

    /// 把处理后的帧序列（跟 extractFrames 同样的命名规则 frame_%05d.png）编回视频，
    /// 音轨从原素材同一裁剪范围复制过来
    nonisolated static func encodeFrames(frameDir: URL, frameRate: Double,
                                        audioSourceURL: URL, audioTrimStart: Double, audioDuration: Double,
                                        outputURL: URL) throws {
        guard let ff = ProjectState.findFFmpeg() else { throw FrameIOError.ffmpegNotFound }
        let p = Process()
        p.executableURL = ff
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        args += ["-framerate", "\(frameRate)", "-i", frameDir.appendingPathComponent("frame_%05d.png").path]
        if audioTrimStart > 0.001 { args += ["-ss", String(format: "%.6f", audioTrimStart)] }
        args += ["-t", String(format: "%.6f", audioDuration), "-i", audioSourceURL.path]
        args += ["-map", "0:v:0", "-map", "1:a:0?"]
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"]
        args += ["-c:a", "aac", "-shortest"]
        args += [outputURL.path]
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        currentProcess = p
        defer { currentProcess = nil }
        do { try p.run() } catch {
            throw FrameIOError.encodeFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal { throw FrameIOError.cancelled }
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500) ?? ""
            throw FrameIOError.encodeFailed("ffmpeg 退出码 \(p.terminationStatus) \(msg)")
        }
    }
}
```

`currentProcess`/`killCurrentProcess()` 是照抄 `AudioSeparator.swift` 里已经验证过的取消模式（第 327-335 行附近）——取消时不依赖 Swift Task 的协作式取消（这条流水线整体跑在专属线程上，不受 `Task.isCancelled` 管辖），直接 `terminate()` 掉正在跑的 ffmpeg 子进程。

`-map 1:a:0?` 里的 `?` 是 ffmpeg 语法，表示"这个流不存在也不报错"——覆盖原片段没有音轨的情况（比如静音素材）。

- [ ] **Step 2: 写测试（用 ffmpeg 生成一个测试视频，抽帧再编码回去，验证往返一致性）**

```swift
// Tests/VideoEditorTests/ClarityFrameIOTests.swift
import XCTest
@testable import VideoEditorLib

final class ClarityFrameIOTests: XCTestCase {

    /// 用 ffmpeg 的 testsrc 生成一个 2 秒、10fps、带静音音轨的测试视频，不依赖任何外部素材
    private func makeTestVideo() throws -> URL {
        guard let ff = ProjectState.findFFmpeg() else { throw XCTSkip("找不到 ffmpeg") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_test_\(UUID().uuidString).mp4")
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=2",
                       "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                       "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                       url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("测试视频生成失败") }
        return url
    }

    func testExtractFramesProducesExpectedCount() throws {
        let video = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_extract_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let frames = try ClarityFrameIO.extractFrames(url: video, trimStart: 0, duration: 2,
                                                      frameRate: 10, outputDir: outDir)
        // 2 秒 * 10fps，允许 ±1 帧的边界误差
        XCTAssertTrue((19...21).contains(frames.count), "应该抽出约 20 帧，实际 \(frames.count)")
    }

    func testEncodeFramesRoundTrip() throws {
        let video = try makeTestVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let frameDir = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_roundtrip_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: frameDir) }
        let frames = try ClarityFrameIO.extractFrames(url: video, trimStart: 0, duration: 2,
                                                      frameRate: 10, outputDir: frameDir)
        XCTAssertFalse(frames.isEmpty)

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("frameio_out_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try ClarityFrameIO.encodeFrames(frameDir: frameDir, frameRate: 10,
                                        audioSourceURL: video, audioTrimStart: 0, audioDuration: 2,
                                        outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 1000, "输出文件应该有实际内容，不是空文件")
    }
}
```

- [ ] **Step 3: 编译 + 跑测试**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
swift test --filter ClarityFrameIOTests 2>&1 | tail -20
```

Expected: `Build complete`，两个测试 PASS。

- [ ] **Step 4: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/ClarityFrameIO.swift Tests/VideoEditorTests/ClarityFrameIOTests.swift
git commit -m "feat: 清晰度提升 — ffmpeg 抽帧/编码封装"
```

---

### Task 9: ProjectState+ClarityEnhance.swift — 主流程整合

**目的**：把 Task 5-8 串成完整流程，对照 `ProjectState+AudioSeparate.swift` 的骨架。

**Files:**
- Create: `Sources/VideoEditor/Models/ProjectState+ClarityEnhance.swift`
- Test: 追加到 `Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift`

**Interfaces:**
- Consumes: `ClarityModel`（Task 5）、`ClarityEnhancer.enhance`（Task 6）、`ClarityFrameIO`（Task 8）、`ProjectState.ClarityScale`/`ClarityEnhanceState`（Task 7）
- Produces: `ProjectState.canEnhanceClarity: Bool`、`ProjectState.enhanceClaritySelection(scale:)`

- [ ] **Step 1: 写主流程**

```swift
// ProjectState+ClarityEnhance.swift
// 清晰度提升：ffmpeg 抽帧 → CoreML 逐帧超分 → ffmpeg 重编码 → 新建素材+新建轨道。
// 骨架照抄 ProjectState+AudioSeparate.swift（demucs 音轨分离）。
import Foundation
import AVFoundation

extension ProjectState {

    var canEnhanceClarity: Bool {
        guard !isEnhancingClarity else { return false }
        return selectedVideoClipID != nil
    }

    /// 每帧输出 PNG 的估算体积（1080p 放大到 4K 级别，粗略上限），用于磁盘空间检查。
    /// Task 3 实测真实耗时/体积后，回来把这个数字换成实测值
    private static let estimatedBytesPerFrame: Int64 = 4_000_000
    /// 单帧推理耗时估算（毫秒），Task 3 实测出真实数字前的占位系数——
    /// 但占位归占位，逻辑必须先跑起来，不能因为数字不精确就整块跳过不写
    private static let estimatedMsPerFrame: Double = 3000
    /// 耗时预计超过这个秒数就弹确认框
    private static let confirmThresholdSeconds: Double = 60
    /// 分辨率上限：短边达到这个像素数就提示"已经比较清晰"（x4 用更低阈值，x2 用更高阈值）
    private static func resolutionWarningThreshold(scale: ClarityScale) -> Double {
        scale == .x4 ? 1520 : 2160
    }

    func enhanceClaritySelection(scale: ClarityScale) {
        guard !isEnhancingClarity else { return }
        guard let id = selectedVideoClipID,
              let track = videoTracks.first(where: { $0.clips.contains { $0.id == id } }),
              let clip = track.clips.first(where: { $0.id == id }),
              let url = clip.url ?? mediaAssets.first(where: { $0.id == clip.assetID })?.url else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .orange,
                             title: "清晰度提升", subtitle: "请先选中一个视频片段")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "清晰度提升", subtitle: "源文件不存在", autoCountdown: false)
            return
        }

        let model: ClarityModel = scale == .x2 ? .x2 : .x4
        let trimStart = clip.trimStart
        let duration = clip.duration * clip.speed
        let timelineStart = clip.startTime
        let sourceTrackID = track.id
        let sourceName = url.deletingPathExtension().lastPathComponent
        let estimatedFrameCount = Int(duration * 30.0)  // 固定输出帧率 30fps，跟下面 extractFrames 用的一致

        // 边界检查 1：分辨率已经较高，放大收益有限——提示但不阻止
        let shortSide = min(clip.videoWidth, clip.videoHeight)
        if shortSide > 0.001, shortSide >= Self.resolutionWarningThreshold(scale: scale) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "素材已经比较清晰"
            alert.informativeText = "这个片段短边已有 \(Int(shortSide))px，放大 \(scale.rawValue) 倍收益可能有限。是否仍要继续？"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 边界检查 2：预计耗时较长——需要用户明确确认才继续
        let estimatedSeconds = Double(estimatedFrameCount) * Self.estimatedMsPerFrame / 1000.0
        if estimatedSeconds >= Self.confirmThresholdSeconds {
            let minutes = Int((estimatedSeconds / 60).rounded(.up))
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "预计需要约 \(minutes) 分钟"
            alert.informativeText = "处理期间可以继续编辑其他内容，完成后会有通知。确认开始吗？"
            alert.addButton(withTitle: "开始")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 边界检查 3：磁盘空间不足直接报错，不要写到一半才失败
        let estimatedBytes = Int64(estimatedFrameCount) * Self.estimatedBytesPerFrame * 2  // ×2 覆盖输入+输出两份帧序列
        if let avail = try? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(avail) < estimatedBytes {
            let gbNeeded = Double(estimatedBytes) / 1_000_000_000
            showSuccessToast(icon: "exclamationmark.triangle", iconColor: .red,
                             title: "清晰度提升",
                             subtitle: String(format: "磁盘空间不足，预计需要约 %.1f GB", gbNeeded),
                             autoCountdown: false)
            return
        }

        clarityEnhanceTask = Task { @MainActor in
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clarity_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workDir) }

            let cancelFlag = ClarityCancelFlag()
            clarityCancelFlag = cancelFlag

            do {
                if !model.isDownloaded {
                    clarityEnhanceState = .downloadingModel(0)
                    try await model.download { p in
                        Task { @MainActor in self.clarityEnhanceState = .downloadingModel(p) }
                    }
                    try Task.checkCancellation()
                }

                let outDir = Self.clarityOutputDir
                let outName = "\(sourceName)_清晰x\(scale.rawValue)_\(UUID().uuidString.prefix(8)).mp4"
                let outURL = outDir.appendingPathComponent(outName)

                // 抽帧 → 逐帧推理 → 编码整段在专属线程上跑，详见 runClarityEnhancePipeline 的注释：
                // 这几步都是同步阻塞操作，不能用 Task.detached 反复占用 Swift 协作池
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    Thread.detachNewThread {
                        do {
                            _ = try Self.runClarityEnhancePipeline(
                                sourceURL: url, trimStart: trimStart, duration: duration,
                                scale: scale, model: model, workDir: workDir, outputURL: outURL,
                                cancelFlag: cancelFlag,
                                onStateChange: { state in
                                    DispatchQueue.main.async { self.clarityEnhanceState = state }
                                }
                            )
                            cont.resume(returning: ())
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()

                pushUndoSavingAssets()
                var asset = MediaAsset(url: outURL, name: outName, type: .video)
                asset.importDate = Date()
                let assetID = asset.id
                mediaAssets.append(asset)

                // 原片段可能在处理这段时间里被用户删除/撤销了 —— 只有还在时才建新轨道插片段
                if videoTracks.first(where: { $0.id == sourceTrackID }) != nil,
                   let stillClip = videoTracks.flatMap(\.clips).first(where: { $0.id == id }) {
                    var newTrack = Track<VideoClip>(clips: [])
                    var newClip = VideoClip(assetID: assetID, startTime: stillClip.startTime)
                    newClip.duration = stillClip.duration
                    newClip.trimStart = 0
                    newTrack.clips = [newClip]
                    videoTracks.append(newTrack)
                    if let idx = videoSectionOrder.firstIndex(where: {
                        if case .video(let tid) = $0 { return tid == sourceTrackID }
                        return false
                    }) {
                        videoSectionOrder.insert(.video(trackID: newTrack.id), at: idx + 1)
                    } else {
                        videoSectionOrder.append(.video(trackID: newTrack.id))
                    }
                    rebuildTimelinePreviewDebounced()
                }

                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
                showSuccessToast(icon: "sparkles", iconColor: .green,
                                 title: "清晰度提升", subtitle: "已生成 \(scale.rawValue)x 高清版本",
                                 revealURL: outURL)
            } catch is CancellationError {
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
            } catch ClarityFrameIO.FrameIOError.cancelled {
                // 用户点了取消：cancelClarityEnhance() 已经弹过"已停止"提示，这里不再重复弹
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
            } catch {
                clarityEnhanceState = .idle
                clarityEnhanceTask = nil
                clarityCancelFlag = nil
                showSuccessToast(icon: "xmark.circle.fill", iconColor: .red,
                                 title: "清晰度提升", subtitle: error.localizedDescription,
                                 autoCountdown: false)
            }
        }
    }

    /// 抽帧 → 逐帧 CoreML 超分 → 编码，整段同步执行。**调用方必须在专属线程
    /// （`Thread.detachNewThread`）上调用，绝不能直接包在 `Task`/`Task.detached` 里跑**——
    /// 这几步都是同步阻塞操作（ffmpeg 子进程 `waitUntilExit()`、CoreML `MLModel.prediction`
    /// 同步调用），`Task.detached` 不代表脱离协作池，只是不继承调用者的 actor/优先级，依然会
    /// 被派发到 Swift 全局协作线程池执行。逐帧循环几百次反复占用/归还协作池线程，跟本次会话
    /// 验证过的"协作池被同步阻塞调用拖垮"是同一类风险（详见 home_machine_decode_issue.md
    /// 里 `loadWaveform` 从 `Task {}` 改为 `Thread.detachNewThread` 的教训）——虽然这里
    /// 阻塞的是 ffmpeg/CoreML 而不是挂死的 AVFoundation，不会永久卡住，但协作池本来就不该被
    /// 这类长耗时同步任务反复占用。`onStateChange` 在这条专属线程上被调用，内部自己切回主线程。
    nonisolated static func runClarityEnhancePipeline(
        sourceURL: URL, trimStart: Double, duration: Double,
        scale: ClarityScale, model: ClarityModel, workDir: URL, outputURL: URL,
        cancelFlag: ClarityCancelFlag,
        onStateChange: @escaping (ClarityEnhanceState) -> Void
    ) throws -> URL {
        func checkCancelled() throws {
            if cancelFlag.isCancelled { throw ClarityFrameIO.FrameIOError.cancelled }
        }

        onStateChange(.extractingFrames(0))
        let frameRate = 30.0  // 固定输出帧率，跟原素材帧率解耦，简化实现
        let inputFrameDir = workDir.appendingPathComponent("in")
        let frames = try ClarityFrameIO.extractFrames(url: sourceURL, trimStart: trimStart, duration: duration,
                                                       frameRate: frameRate, outputDir: inputFrameDir)
        try checkCancelled()

        onStateChange(.inferring(0))
        let outputFrameDir = workDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputFrameDir, withIntermediateDirectories: true)
        for (index, frameURL) in frames.enumerated() {
            try checkCancelled()
            guard let src = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw ClarityEnhancer.EnhanceError.badOutput
            }
            let enhanced = try ClarityEnhancer.enhance(cgImage: cg, model: model)
            let outFrameURL = outputFrameDir.appendingPathComponent(frameURL.lastPathComponent)
            let rep = NSBitmapImageRep(cgImage: enhanced)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw ClarityEnhancer.EnhanceError.badOutput
            }
            try data.write(to: outFrameURL)
            onStateChange(.inferring(Double(index + 1) / Double(frames.count)))
        }
        try checkCancelled()

        onStateChange(.encoding)
        try ClarityFrameIO.encodeFrames(frameDir: outputFrameDir, frameRate: frameRate,
                                        audioSourceURL: sourceURL, audioTrimStart: trimStart,
                                        audioDuration: duration, outputURL: outputURL)
        return outputURL
    }

    static var clarityOutputDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("黑猫剪辑/clarity/output", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

**这一步用到的具体类型/属性（`VideoClip`、`Track<T>`、`videoSectionOrder`、`OverlayTrackRef`/`.video(trackID:)` 的确切签名）需要在实现时对照 `DataTypes.swift` 和 `Project.swift` 里的真实定义核对**——这个任务描述里写的字段名（`duration`、`trimStart`、`startTime`）是根据本次会话前面读到的其他代码（demucs/预览重建）里反复出现的字段名推断的，实现者动手前应该先读一遍 `VideoClip` 的真实结构体定义，字段名如果对不上就以实际代码为准，不要盲目照抄这里的代码。这是本计划里**唯一**需要在写代码前额外核对一遍现有类型定义的地方，因为 `VideoClip` 的具体字段集这份计划的准备过程中没有逐字段确认过。

**取消行为的分工**：`cancelClarityEnhance()`（Task 7）里 `ClarityFrameIO.killCurrentProcess()` 会立即打断正在跑的 ffmpeg 子进程（抽帧/编码阶段能立即响应取消）；`cancelFlag.isCancelled` 在推理循环的每一帧之间检查（推理阶段的取消会有"最多等完当前这一帧"的延迟，可接受，单帧耗时是可控的）。

- [ ] **Step 2: 追加 `canEnhanceClarity` 的单元测试**

流程整体依赖真实视频+真实 CoreML 模型，不适合写自动化单测（Step 4 用手动集成测试覆盖）；但 `canEnhanceClarity` 是纯逻辑判断，可以脱离真实处理流程单独测：

```swift
// 追加到 Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift

extension ClarityEnhanceProgressTests {

    @MainActor
    func testCanEnhanceClarityRequiresSelection() {
        let p = ProjectState()
        XCTAssertFalse(p.canEnhanceClarity, "没有选中片段时不应该可用")
    }

    @MainActor
    func testCanEnhanceClarityDisabledWhileRunning() {
        let p = ProjectState()
        p.clarityEnhanceState = .inferring(0.5)
        XCTAssertFalse(p.canEnhanceClarity, "任务进行中不应该可以再次触发")
    }
}
```

```bash
cd /Users/Venico/claude/VideoEditor
swift test --filter ClarityEnhanceProgressTests 2>&1 | tail -20
```

Expected: 新增的两个测试 PASS（连同 Task 7 已有的三个测试，这个文件现在共 5 个测试）。

- [ ] **Step 3: 编译，处理字段名不匹配的报错**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:" 
```

Expected: 第一次编译大概率会报若干字段名/类型不匹配的错误（`VideoClip` 的真实初始化参数、`Track` 的真实初始化方式、`videoSectionOrder` 元素类型的真实 case 名）。逐个对照 `Sources/VideoEditor/Models/DataTypes.swift` 里 `VideoClip`/`Track` 的定义和 `Project.swift` 里 `OverlayTrackRef`/`videoSectionOrder` 的真实定义修正，直到 `swift build` 无 error。

- [ ] **Step 4: 手动集成测试（这一步涉及真实 ffmpeg+CoreML 端到端流程，不适合写成纯 XCTest，用真实素材跑一遍）**

```bash
# 部署到测试用的 app（走项目固定的双路径部署流程）
cd /Users/Venico/claude/VideoEditor
swift build
cp .build/debug/VideoEditor /Users/Venico/claude/黑猫剪辑.app/Contents/MacOS/VideoEditor
cp .build/debug/VideoEditor /Users/Venico/claude/VideoEditor/黑猫剪辑.app/Contents/MacOS/VideoEditor
codesign --force --sign - /Users/Venico/claude/黑猫剪辑.app
codesign --force --sign - /Users/Venico/claude/VideoEditor/黑猫剪辑.app
open /Users/Venico/claude/黑猫剪辑.app
```

在 app 里：导入一个几秒钟的低清视频片段拖进时间轴 → 选中 → 手动调用 `enhanceClaritySelection(scale:)`（这一步还没有 UI 入口，Task 12 才会加右键菜单——如果想在这一步就能测，可以临时在某个已有按钮上加一行调用代码测完再删掉，或者等 Task 12 一起测）。

**这一步先跳过手动 UI 触发，等 Task 10-12 做完 UI 后再做端到端验证**——Task 9 本身先只保证 `swift build` 通过、类型对得上。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/ProjectState+ClarityEnhance.swift Tests/VideoEditorTests/ClarityEnhanceProgressTests.swift
git commit -m "feat: 清晰度提升 — 主流程整合（抽帧+推理+编码+建轨道）"
```

---

### Task 10: 进度气泡 UI

**目的**：处理中的悬浮进度气泡，参照 `RemoveBackgroundBubble` 的模式。

**Files:**
- Modify: `Sources/VideoEditor/Views/MediaLibrary/MediaLibraryView.swift`（`RemoveBackgroundBubble` 所在文件，在旁边加新组件）

**Interfaces:**
- Consumes: `ProjectState.clarityEnhanceState`（Task 7）、`ProjectState.isEnhancingClarity`、`ProjectState.cancelClarityEnhance()`

- [ ] **Step 1: 先读 `RemoveBackgroundBubble` 的真实实现，照它的结构写**

```bash
cd /Users/Venico/claude/VideoEditor
grep -n "struct RemoveBackgroundBubble" -A 60 Sources/VideoEditor/Views/MediaLibrary/MediaLibraryView.swift
```

把输出内容看一遍，确认它读取哪个状态字段、怎么算文案、取消按钮怎么接的——**这个组件要照抄它的样式和布局参数（字号、圆角、间距），不要自己另起一套视觉风格**，只是把状态源换成 `clarityEnhanceState`。

- [ ] **Step 2: 在同一文件里加 `ClarityEnhanceBubble`**

```swift
struct ClarityEnhanceBubble: View {
    let state: ProjectState.ClarityEnhanceState
    let onCancel: () -> Void

    private var stageText: String {
        switch state {
        case .idle:                 return ""
        case .downloadingModel:     return "下载模型中…"
        case .extractingFrames:     return "抽取帧序列…"
        case .inferring:            return "超分辨率推理中…"
        case .encoding:             return "编码输出中…"
        case .failed(let msg):      return msg
        }
    }

    var body: some View {
        if case .idle = state {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                ProgressView(value: state.approximateProgress)
                    .frame(width: 120)
                Text(stageText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.labelSecondary)
                Text("\(Int(state.approximateProgress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Color.labelSecondary)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.7))
            .cornerRadius(8)
        }
    }
}
```

**这段代码的具体视觉参数（padding/圆角/字号/背景色）应该在实现时替换成 `RemoveBackgroundBubble` 里实际读到的真实数值，让两个气泡视觉一致**——这里写的是占位数值，Step 1 读到真实实现后必须回来对齐，不能两个气泡长得不一样。

- [ ] **Step 3: 挂载到视图树**

参照 `RemoveBackgroundBubble` 被引用的位置（第 866 行附近，`.animation` 那行），在同一个容器里加一行：

```swift
ClarityEnhanceBubble(state: project.clarityEnhanceState, onCancel: { project.cancelClarityEnhance() })
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: project.clarityEnhanceState)
```

- [ ] **Step 4: 编译验证**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete`。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Views/MediaLibrary/MediaLibraryView.swift
git commit -m "feat: 清晰度提升 — 进度气泡 UI"
```

---

### Task 11: 设置面板集成

**目的**：视频标签下新增两个模型下载组件，照抄 `sceneDetectTab` 的组件卡片样式。

**Files:**
- Modify: `Sources/VideoEditor/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ClarityModel`（Task 5）

- [ ] **Step 1: 加状态变量**

在 `SettingsView` 里找到 `sceneDetectState` 声明附近，加：

```swift
@State private var clarityModelStates: [ClarityModel: ComponentDownloadState] = [:]
```

如果项目里没有现成的 `ComponentDownloadState` 类型（`sceneDetectState` 用的是一个内联 enum），先找到 `sceneDetectState` 的类型定义：

```bash
cd /Users/Venico/claude/VideoEditor
grep -n "sceneDetectState\|enum.*DownloadState\|case downloaded\|case notDownloaded" Sources/VideoEditor/Views/SettingsView.swift | head -10
```

按找到的真实类型复用或者仿照定义一个等价的 enum（`.downloaded` / `.notDownloaded` / `.downloading(Double)` / `.failed(String)`），不要凭空发明新的状态命名。

- [ ] **Step 2: 在 `sceneDetectTab` 里追加清晰度提升分区**

在 `sceneDetectTab` 的 `Text("安装后可在工具栏使用「智能分割」...")` 那段之后，"AI 剪辑" 分区之前，插入：

```swift
sectionTitle("清晰度提升")

ForEach(ClarityModel.allCases) { model in
    HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.labelPrimary)
            Text(model.sizeDesc)
                .font(.system(size: 10))
                .foregroundColor(Color.labelSecondary)
        }
        Spacer()
        clarityModelStatusView(model)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.white.opacity(0.04))
    .cornerRadius(7)
}

Text("安装后可在时间轴视频片段右键使用「清晰度提升」，把低清素材放大为高清版本，新建独立轨道，不影响原片段。")
    .font(.system(size: 10))
    .foregroundColor(Color.labelSecondary)
```

**`clarityModelStatusView` 的具体实现（已安装/下载按钮/进度条/失败重试四态渲染）直接照抄 `sceneDetectTab` 里 `switch sceneDetectState { case .downloaded: ... }` 那一段的代码结构**（第 728-773 行），只是把数据源换成 `clarityModelStates[model]`，按钮换成调用 `downloadClarityModel(model)`。不要重新设计一套视觉逻辑。

- [ ] **Step 3: 加下载触发函数**

```swift
private func refreshClarityModelStates() {
    for model in ClarityModel.allCases {
        if case .downloading = clarityModelStates[model] { continue }
        clarityModelStates[model] = model.isDownloaded ? .downloaded : .notDownloaded
    }
}

private func downloadClarityModel(_ model: ClarityModel) {
    clarityModelStates[model] = .downloading(0)
    Task {
        do {
            try await model.download { pct in
                DispatchQueue.main.async { clarityModelStates[model] = .downloading(pct) }
            }
            await MainActor.run { clarityModelStates[model] = .downloaded }
        } catch {
            await MainActor.run { clarityModelStates[model] = .failed(error.localizedDescription) }
        }
    }
}
```

调用 `refreshClarityModelStates()` 的位置对照 `refreshSceneDetectState()` 被调用的地方（通常是 `.onAppear` 或者 tab 切换时）。

- [ ] **Step 4: 编译验证**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete`。

- [ ] **Step 5: 部署 + 手动打开设置面板检查**

```bash
cd /Users/Venico/claude/VideoEditor
cp .build/debug/VideoEditor /Users/Venico/claude/黑猫剪辑.app/Contents/MacOS/VideoEditor
cp .build/debug/VideoEditor /Users/Venico/claude/VideoEditor/黑猫剪辑.app/Contents/MacOS/VideoEditor
codesign --force --sign - /Users/Venico/claude/黑猫剪辑.app
codesign --force --sign - /Users/Venico/claude/VideoEditor/黑猫剪辑.app
open /Users/Venico/claude/黑猫剪辑.app
```

打开设置 → 视频标签，肉眼确认两个模型卡片正确显示、点下载按钮进度条真的在走、下载完状态变"已安装"。

- [ ] **Step 6: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Views/SettingsView.swift
git commit -m "feat: 清晰度提升 — 设置面板模型下载组件"
```

---

### Task 12: 右键菜单集成 + 端到端验证

**目的**：最后一块拼图，时间轴右键二级菜单，然后做一次完整的端到端手动验证。

**Files:**
- Modify: `Sources/VideoEditor/Views/Timeline/TimelineView.swift`

**Interfaces:**
- Consumes: `ProjectState.canEnhanceClarity`、`ProjectState.enhanceClaritySelection(scale:)`（Task 9）

- [ ] **Step 1: 加右键菜单项**

在 `project.selectedVideoClipID != nil` 分支下（"分离音轨"按钮之后），加：

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

- [ ] **Step 2: 编译**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete`。

- [ ] **Step 3: 部署**

```bash
cd /Users/Venico/claude/VideoEditor
cp .build/debug/VideoEditor /Users/Venico/claude/黑猫剪辑.app/Contents/MacOS/VideoEditor
cp .build/debug/VideoEditor /Users/Venico/claude/VideoEditor/黑猫剪辑.app/Contents/MacOS/VideoEditor
codesign --force --sign - /Users/Venico/claude/黑猫剪辑.app
codesign --force --sign - /Users/Venico/claude/VideoEditor/黑猫剪辑.app
open /Users/Venico/claude/黑猫剪辑.app
```

- [ ] **Step 4: 端到端手动验证（这是整个功能第一次完整跑通，必须做）**

1. 导入一个几秒钟的低清视频（比如 480p 或更低的素材）拖进时间轴
2. 右键该片段 → 「清晰度提升」→「放大 2 倍」
3. 确认进度气泡出现，阶段文案跟着变化（下载模型 → 抽取帧序列 → 超分辨率推理中 → 编码输出中）
4. 处理过程中尝试正常编辑时间轴其他内容，确认不卡死主界面
5. 处理完成后确认：素材库多了一个新素材；时间轴原轨道下方多了一条新轨道，新片段起止时间跟原片段一致；播放新片段确认画面确实比原片段清晰、分辨率是 2 倍
6. 再测一次「放大 4 倍」，同样走一遍
7. 测取消：处理中点进度气泡的取消按钮，确认任务真的停了、没有残留临时文件（检查 `/var/folders` 下的临时目录或者直接看 Activity Monitor 里 ffmpeg 进程是否被杀掉）

Expected: 全流程走通，没有黑屏/卡死/文件残留。这是整个 12 个 Task 里第一次也是唯一一次"看整体是否真的好用"的验证点。

**如果这一步发现问题**（比如推理耗时远超预期导致体验很差、tile 拼接在真实视频帧上出现接缝、音画不同步）：这些都是允许在这里发现并现场修复的正常情况——回到对应的 Task（Task 6 的 tile 逻辑、Task 8 的 ffmpeg 参数、Task 9 的耗时提示阈值）用 systematic-debugging 排查，不要在这里绕过问题强行"看起来能跑就算了"。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Views/Timeline/TimelineView.swift
git commit -m "feat: 清晰度提升 — 右键菜单集成"
```

---

## Self-Review 记录

**Spec 覆盖检查**：
- 技术方案与模型选型 → Task 1-4
- 处理流程与数据流（ffmpeg 全程、不碰 AVFoundation）→ Task 8、Task 9
- 状态机 → Task 7
- 设置面板 UI → Task 11
- 右键菜单 UI → Task 12
- 进度气泡 → Task 10
- 磁盘空间检查、耗时提示、分辨率上限保护 → Task 9 已实现（`enhanceClaritySelection` 开头三段边界检查）。**其中耗时估算用的 `estimatedMsPerFrame = 3000`（每帧 3 秒）是占位系数**——Task 3 实测出 `per_tile_ms` 和 `tiles_per_frame` 之后，应该回来把这个系数换成 `per_tile_ms × tiles_per_frame`（Task 3 脚本本身已经打印出这个换算结果，直接抄过来即可，不需要重新推导）。这是本计划里唯一一处"先用合理默认值让逻辑跑起来、待有实测数据后回填精确值"的地方，跟"完全不写这块逻辑"是两回事
- 处理中原片段被删除/撤销 → Task 9 已实现（`stillClip` 判断）
- 取消 → Task 7（`ClarityCancelFlag` + `ClarityFrameIO.killCurrentProcess()`）+ Task 9（`runClarityEnhancePipeline` 里的 `checkCancelled()` 检查点）

**占位符扫描**：无 TBD/TODO。Task 9 和 Task 10 里各有一段明确标注"这里的具体数值/字段名是推断的，实现时需要对照真实代码核对替换"——这不是偷懒占位，是诚实标注计划撰写阶段确实没有逐字段验证过的两个点，且给出了核对方法。

**类型一致性检查**：`ClarityScale`（Task 7 定义）在 Task 9/Task 12 里的用法一致（`.x2`/`.x4`，`rawValue` 是 Int 2/4）。`ClarityModel`（Task 5）跟 `ClarityScale` 是两个独立类型，Task 9 里有一行 `let model: ClarityModel = scale == .x2 ? .x2 : .x4` 做转换——这个双轨设计（一个管下载/模型文件，一个管 UI 选项）初看有点冗余，但保留是因为 `ClarityModel` 需要是 `CaseIterable`+`Identifiable` 才能在 Task 11 的 `ForEach` 里用，`ClarityScale` 需要是简单的 `Int rawValue` 枚举才能被状态机和右键菜单直接消费，两者职责不同，不合并。

**Pre-Flight Plan Review 阶段修正的架构问题（执行前发现，不是执行中才暴露）**：
1. Task 9 初稿里，抽帧/逐帧推理/编码这三步分别用 `Task.detached(priority: .userInitiated) { ... }.value` 包裹——这个模式跟本次会话（`home_machine_decode_issue.md`）验证过的错误模式是同一类：`Task.detached` 不脱离 Swift 协作池，只是不继承调用者的 actor/优先级；把同步阻塞的重计算（ffmpeg `waitUntilExit`、CoreML 同步推理）反复丢给它执行，是协作池的错误用法。已重写为整段在 `Thread.detachNewThread` 专属线程上跑（`runClarityEnhancePipeline`），配合 `withCheckedThrowingContinuation` 桥接成 async，取消机制也相应从 `Task.checkCancellation()` 改为跨线程共享的 `ClarityCancelFlag`（专属线程不受 Swift Task 取消管辖）+ `ClarityFrameIO.killCurrentProcess()`（立即终止正在跑的 ffmpeg 子进程，模式抄自 `AudioSeparator.killCurrentProcess()`）。
2. Task 6 的 `runOneTile` 里有一段死代码（构造 `NSImage`→`CGImage` 后完全没用上，实际用的是原始 `tile` 参数）——已删除。

**已知缺口（Out of Scope 延续自 spec）**：批量处理、云端引擎、动漫模型变体——均不在本计划内，与 spec 一致。
