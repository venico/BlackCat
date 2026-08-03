# 清晰度提升（视频超分辨率）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在黑猫剪辑里加一个"清晰度提升"功能——时间轴视频片段右键选 2x/4x，本地 CoreML 跑 FSRCNN 逐帧放大，生成新素材+新建视频轨道，跟原片段时间对齐。

**Architecture:** ffmpeg 抽帧 → CoreML（FSRCNN，x2/x4 两个模型）逐帧超分（大于模型固定输入尺寸的帧做 tile 分块推理再拼接；FSRCNN 只处理 Y 通道，Cb/Cr 通道插值放大后合并）→ ffmpeg 用放大后帧序列+原始音轨重编码 → 写入素材库 → 建新轨道插入片段。整条链路结构上照抄 `ProjectState+AudioSeparate.swift`（demucs 分离音轨）的骨架：状态机 + 进度气泡 + 后台任务 + 可取消。全程不碰 `AVAssetReader`/`AVAssetImageGenerator`（本次会话验证过这类调用在部分机器上会永久挂死拖垮协作池）。

**技术方案变更记录**：本计划最初写的是 Real-ESRGAN（RRDBNet），Task 1-3 完整走过一遍并验证转换可行，但实测推理速度不可接受（10 秒 1080p 片段需要 79.4 分钟）。改用 FSRCNN 后实测速度快 15-130 倍。下面的 Task 1-4 已经按 FSRCNN 重写；如果需要查阅 Real-ESRGAN 那次的完整过程和踩过的坑，见 git 历史（`git log -p -- docs/superpowers/plans/2026-08-03-clarity-enhance.md`）和 `.superpowers/sdd/progress.md`。

**Tech Stack:** Swift 5.9 / SwiftUI / CoreML / ffmpeg（项目内置静态编译版）/ Python + PyTorch + TensorFlow（仅权重提取）+ coremltools（仅模型转换阶段，不进最终 app）

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
Task 1 (权重获取+提取) → Task 2 (PyTorch复现+转CoreML) → Task 3 (耗时实测) → Task 4 (打包上传)
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

**Task 1-4 是 Python 侧的一次性模型转换准备工作，不产出 Swift 代码，也不在 `swift test` 框架内。** FSRCNN → CoreML 的转换可行性和推理速度已经过探索性验证（转换零报错、速度远超预期，见设计文档"已验证的技术细节"），本计划 Task 1-4 里最大的不确定性是**权重迁移的正确性**——TensorFlow 官方权重迁移到 PyTorch 后，必须验证输出跟原始 OpenCV 推理一致，不能假设"形状对上了就是对的"。如果 Task 1-2 中发现输出明显不一致（不只是精度误差，而是结构性错误比如输出全黑/全噪声/色彩明显不对），必须停下来用 `superpowers:systematic-debugging` 排查根因，不能跳过验证直接往下走 Swift 集成。

---

### Task 1: FSRCNN 官方权重获取 + TensorFlow 权重提取

**目的**：官方权重是 OpenCV `dnn_superres` 项目发布的 TensorFlow 冻结图（`.pb`），需要先解析出里面的卷积核/偏置/PReLU 参数，导出成一个跟 TensorFlow 无关的中间格式（`.npz`），后续 Task 2 才能在 PyTorch 环境里加载。

**关键教训（本计划探索阶段已踩过，必须遵守）**：`tensorflow`/`tensorflow-macos` 跟 `coremltools`/`scipy` 对 numpy 版本的要求互相冲突（tensorflow 要 `numpy<2.0`，coremltools/scipy 要 `numpy>=2`），在同一个 venv 里装两者会互相破坏对方的依赖。**必须用两个完全独立的 venv**：一个只装 tensorflow（本任务用），一个只装 PyTorch/coremltools（Task 2-3 用，两者互不接触）。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/extract_tf_weights.py`（在独立 TF venv 里跑）
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/tf_venv/`（独立虚拟环境，跟主 `venv/` 完全分开）

**Interfaces:**
- Produces: `FSRCNN_x2_weights.npz`、`FSRCNN_x4_weights.npz`（每个包含 8 个卷积核 `f1..f8`、8 个偏置 `b1..b8`、7 个 PReLU 参数 `alpha1..alpha7`，键名与 TF 图节点名一致）

- [ ] **Step 1: 建独立 TF 环境**

```bash
mkdir -p /Users/Venico/claude/clarity-convert/fsrcnn
cd /Users/Venico/claude/clarity-convert/fsrcnn
python3.12 -m venv tf_venv
source tf_venv/bin/activate
pip install tensorflow --quiet
```

Expected: 安装成功。这个 venv 之后只用来跑权重提取脚本，不装任何 PyTorch/coremltools 相关的包。

- [ ] **Step 2: 下载官方权重**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
curl -sL -o FSRCNN_x2.pb "https://raw.githubusercontent.com/Saafke/FSRCNN_Tensorflow/master/models/FSRCNN_x2.pb"
curl -sL -o FSRCNN_x4.pb "https://raw.githubusercontent.com/Saafke/FSRCNN_Tensorflow/master/models/FSRCNN_x4.pb"
ls -la *.pb
```

Expected: `FSRCNN_x2.pb` 38973 字节，`FSRCNN_x4.pb` 41661 字节（已用 `curl`/GitHub API 验证过这两个数字准确）。仓库 `Saafke/FSRCNN_Tensorflow` 是 Apache 2.0 许可证（已用 `gh repo view` 确认）。

- [ ] **Step 3: 用 OpenCV 验证官方权重能正确推理（建立"正确答案"基准，供 Task 2 比对）**

这一步在**主 venv**（不是 tf_venv）里做，因为只需要 `opencv-contrib-python`，不需要 tensorflow：

```bash
cd /Users/Venico/claude/clarity-convert
source venv/bin/activate
pip install opencv-contrib-python --quiet
```

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/opencv_baseline.py
import cv2
import sys

scale = int(sys.argv[1])
sr = cv2.dnn_superres.DnnSuperResImpl_create()
sr.readModel(f"FSRCNN_x{scale}.pb")
sr.setModel("fsrcnn", scale)

img = cv2.imread("../test_input_crop256.png")
if img is None:
    # Task 1（Real-ESRGAN 那版）产出的测试图，如果不存在就用任意一张 256x256 图代替
    raise FileNotFoundError("需要一张测试图，参照旧 Task 1 Step 5 的方式准备")
result = sr.upsample(img)
print(f"x{scale}: input {img.shape} -> output {result.shape}")
cv2.imwrite(f"opencv_baseline_x{scale}.png", result)
```

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
python opencv_baseline.py 4
python opencv_baseline.py 2
open opencv_baseline_x4.png opencv_baseline_x2.png ../test_input_crop256.png
```

Expected: 两个输出尺寸精确 4 倍/2 倍放大（256×256 → 1024×1024 / 512×512）。肉眼确认输出图片清晰、无噪声/伪影——这是官方权重本身没问题的证据，也是后续 Task 2 迁移到 PyTorch 之后要对比的"标准答案"。

- [ ] **Step 4: 解析 .pb 图结构，确认节点名（防止不同版本的 .pb 文件节点命名不一致）**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source tf_venv/bin/activate
python3 -c "
import tensorflow as tf
with tf.io.gfile.GFile('FSRCNN_x4.pb', 'rb') as f:
    graph_def = tf.compat.v1.GraphDef()
    graph_def.ParseFromString(f.read())
for node in graph_def.node:
    if node.op == 'Const':
        try:
            t = tf.make_ndarray(node.attr['value'].tensor)
            if t.size > 1:
                print(f'{node.name}: shape={t.shape}')
        except Exception:
            pass
"
```

Expected（已验证过的标准 FSRCNN `d=56 s=12 m=4` 配置，输出应该匹配）：
```
f1: shape=(5, 5, 1, 56)     b1: shape=(56,)    alpha1: shape=(56,)
f2: shape=(1, 1, 56, 12)    b2: shape=(12,)    alpha2: shape=(12,)
f3: shape=(3, 3, 12, 12)    b3: shape=(12,)    alpha3: shape=(12,)
f4: shape=(3, 3, 12, 12)    b4: shape=(12,)    alpha4: shape=(12,)
f5: shape=(3, 3, 12, 12)    b5: shape=(12,)    alpha5: shape=(12,)
f6: shape=(3, 3, 12, 12)    b6: shape=(12,)    alpha6: shape=(12,)
f7: shape=(1, 1, 12, 56)    b7: shape=(56,)    alpha7: shape=(56,)
f8: shape=(1, 1, 56, 16)    b8: shape=(16,)
```
`f1` 的输入通道是 1（不是 3）——**FSRCNN 只处理 YCbCr 的 Y 亮度通道**，这是这个方案跟 Real-ESRGAN（直接处理 RGB）的关键差异，Task 2/6 都要考虑这一点。`f8` 输出 16 = 4²（scale² for x4；x2 的话 f8 应该是 4=2²），配合图里的 `DepthToSpace` 节点做 sub-pixel 上采样（等价于 PyTorch 的 `nn.PixelShuffle`）。

**如果节点名/shape 跟这里列的不一致**：说明这个 `.pb` 文件版本或配置跟已验证过的不同，需要按实际输出调整后续的 PyTorch 架构定义，不要硬套这里给的形状。

- [ ] **Step 5: 提取权重到 .npz**

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/extract_tf_weights.py
import tensorflow as tf
import numpy as np
import sys

scale = int(sys.argv[1])
with tf.io.gfile.GFile(f"FSRCNN_x{scale}.pb", "rb") as f:
    graph_def = tf.compat.v1.GraphDef()
    graph_def.ParseFromString(f.read())

weights = {}
for node in graph_def.node:
    if node.op == "Const":
        try:
            t = tf.make_ndarray(node.attr["value"].tensor)
            if t.size > 1 or node.name.startswith(("f", "b", "alpha")):
                weights[node.name] = t
        except Exception:
            continue

expected_keys = [f"f{i}" for i in range(1, 9)] + [f"b{i}" for i in range(1, 9)] + [f"alpha{i}" for i in range(1, 8)]
missing = [k for k in expected_keys if k not in weights]
assert not missing, f"缺少预期的权重键: {missing}，实际提取到: {list(weights.keys())}"

np.savez(f"FSRCNN_x{scale}_weights.npz", **weights)
print(f"已保存 FSRCNN_x{scale}_weights.npz，共 {len(weights)} 个数组")
for k in expected_keys:
    print(f"  {k}: {weights[k].shape}")
```

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source tf_venv/bin/activate
python extract_tf_weights.py 4
python extract_tf_weights.py 2
deactivate
```

Expected: 两条命令都打印"已保存"，`assert` 不报错（说明所有 23 个预期权重键都提取到了）。产出 `FSRCNN_x4_weights.npz`、`FSRCNN_x2_weights.npz`，这两个文件后续会在 PyTorch venv 里加载，不再需要 tensorflow。

- [ ] **Step 6: 验证 .npz 能在主 venv（无 tensorflow）里独立加载**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source ../venv/bin/activate
python3 -c "
import numpy as np
d = np.load('FSRCNN_x4_weights.npz')
print('keys:', list(d.keys()))
print('f1 shape:', d['f1'].shape)
"
```

Expected: 正常打印，不需要 tensorflow 也能读取 `.npz`（这是 numpy 原生格式，不依赖 TF）——证明后续 Task 2 完全不需要在同一个环境里装 tensorflow，两个 venv 的隔离是有效的。

---

### Task 2: PyTorch 复现 FSRCNN + 加载迁移权重 + 转 CoreML

**目的**：用 Task 1 提取的权重在 PyTorch 里复现 FSRCNN，验证输出跟 Task 1 Step 3 的 OpenCV 基准一致，再转换成 CoreML。这是本计划最大的不确定性所在——权重迁移如果哪里对应错了（比如卷积核的维度顺序、PReLU 的通道对应关系），不会报错，只会输出错误的图像，必须靠数值/视觉比对才能发现。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/fsrcnn_arch.py`
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/load_weights.py`
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/convert_coreml.py`

**Interfaces:**
- Consumes: Task 1 产出的 `FSRCNN_x2_weights.npz`/`FSRCNN_x4_weights.npz`
- Produces: `FSRCNN_x2.mlpackage`、`FSRCNN_x4.mlpackage`

- [ ] **Step 1: 定义 PyTorch 架构**

层的顺序和通道数必须跟 Task 1 Step 4 解析出的 TF 图完全对应（`d=56 s=12 m=4`，单通道输入）：

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/fsrcnn_arch.py
import torch
import torch.nn as nn

class FSRCNN(nn.Module):
    """d=56(特征维度) s=12(收缩维度) m=4(映射层数)，单通道(Y)输入，
    最后 Conv(1x1) + PixelShuffle 做 sub-pixel 上采样（不是反卷积）"""
    def __init__(self, scale_factor):
        super().__init__()
        self.scale_factor = scale_factor
        self.feature = nn.Conv2d(1, 56, kernel_size=5, padding=2)
        self.act1 = nn.PReLU(56)
        self.shrink = nn.Conv2d(56, 12, kernel_size=1)
        self.act2 = nn.PReLU(12)
        self.map1 = nn.Conv2d(12, 12, kernel_size=3, padding=1)
        self.act3 = nn.PReLU(12)
        self.map2 = nn.Conv2d(12, 12, kernel_size=3, padding=1)
        self.act4 = nn.PReLU(12)
        self.map3 = nn.Conv2d(12, 12, kernel_size=3, padding=1)
        self.act5 = nn.PReLU(12)
        self.map4 = nn.Conv2d(12, 12, kernel_size=3, padding=1)
        self.act6 = nn.PReLU(12)
        self.expand = nn.Conv2d(12, 56, kernel_size=1)
        self.act7 = nn.PReLU(56)
        self.out_conv = nn.Conv2d(56, scale_factor * scale_factor, kernel_size=1)
        self.pixel_shuffle = nn.PixelShuffle(scale_factor)

    def forward(self, x):
        x = self.act1(self.feature(x))
        x = self.act2(self.shrink(x))
        x = self.act3(self.map1(x))
        x = self.act4(self.map2(x))
        x = self.act5(self.map3(x))
        x = self.act6(self.map4(x))
        x = self.act7(self.expand(x))
        x = self.out_conv(x)
        x = self.pixel_shuffle(x)
        return x
```

- [ ] **Step 2: 写权重加载脚本，验证输出跟 OpenCV 基准一致**

TensorFlow 卷积核格式是 `(H, W, in_channels, out_channels)`，PyTorch 是 `(out_channels, in_channels, H, W)`——需要转置 `(3, 2, 0, 1)`：

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/load_weights.py
import numpy as np
import torch
from fsrcnn_arch import FSRCNN

def load_from_npz(model: FSRCNN, npz_path: str):
    w = np.load(npz_path)
    layer_map = [
        ("feature", "act1", "f1", "b1", "alpha1"),
        ("shrink", "act2", "f2", "b2", "alpha2"),
        ("map1", "act3", "f3", "b3", "alpha3"),
        ("map2", "act4", "f4", "b4", "alpha4"),
        ("map3", "act5", "f5", "b5", "alpha5"),
        ("map4", "act6", "f6", "b6", "alpha6"),
        ("expand", "act7", "f7", "b7", "alpha7"),
    ]
    with torch.no_grad():
        for conv_name, act_name, f_key, b_key, alpha_key in layer_map:
            conv = getattr(model, conv_name)
            act = getattr(model, act_name)
            conv.weight.copy_(torch.from_numpy(w[f_key].transpose(3, 2, 0, 1).copy()))
            conv.bias.copy_(torch.from_numpy(w[b_key].copy()))
            act.weight.copy_(torch.from_numpy(w[alpha_key].copy()))
        # 最后一层没有 PReLU
        model.out_conv.weight.copy_(torch.from_numpy(w["f8"].transpose(3, 2, 0, 1).copy()))
        model.out_conv.bias.copy_(torch.from_numpy(w["b8"].copy()))
    return model
```

```python
# 追加到同一个文件或新建 verify_pytorch.py，跟 OpenCV 基准数值比对
# /Users/Venico/claude/clarity-convert/fsrcnn/verify_pytorch.py
import sys
import numpy as np
import torch
import cv2
from fsrcnn_arch import FSRCNN
from load_weights import load_from_npz

scale = int(sys.argv[1])
model = FSRCNN(scale_factor=scale)
load_from_npz(model, f"FSRCNN_x{scale}_weights.npz")
model.eval()

# 用跟 OpenCV 完全一样的预处理：BGR -> YCrCb，取 Y 通道
img_bgr = cv2.imread("../test_input_crop256.png")
img_ycrcb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2YCrCb)
y = img_ycrcb[:, :, 0].astype(np.float32) / 255.0
y_tensor = torch.from_numpy(y).unsqueeze(0).unsqueeze(0)

with torch.no_grad():
    out_y = model(y_tensor).squeeze().clamp(0, 1).numpy()

# 跟 Task 1 的 OpenCV 输出对比（同样转到 Y 通道再比较，避开 Cb/Cr 插值方式差异的干扰）
baseline_bgr = cv2.imread(f"opencv_baseline_x{scale}.png")
baseline_y = cv2.cvtColor(baseline_bgr, cv2.COLOR_BGR2YCrCb)[:, :, 0].astype(np.float32) / 255.0

diff = np.abs(out_y - baseline_y)
mae_255 = diff.mean() * 255
psnr = 20 * np.log10(1.0 / max(np.sqrt((diff ** 2).mean()), 1e-10))
print(f"x{scale} PyTorch vs OpenCV baseline: shape={out_y.shape} MAE(0-255)={mae_255:.3f} PSNR={psnr:.2f}dB")

cv2.imwrite(f"pytorch_y_x{scale}.png", (out_y * 255).astype(np.uint8))
cv2.imwrite(f"opencv_y_x{scale}.png", (baseline_y * 255).astype(np.uint8))

assert psnr > 30, f"PSNR 太低（{psnr:.2f}dB），权重迁移大概率有错，不要继续往下走"
print("验证通过：权重迁移正确")
```

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source ../venv/bin/activate
python verify_pytorch.py 4
python verify_pytorch.py 2
open pytorch_y_x4.png opencv_y_x4.png
```

Expected: 打印"验证通过"，PSNR 明显高于 30dB（理想情况下应该在 40dB+，因为这是同一个模型在两个不同推理引擎上跑同样的输入，唯一的误差来源是浮点精度，不应该有结构性差异）。打开两张图肉眼对比应该几乎一样。

**如果 PSNR 很低（比如 <20dB）或者 assert 报错**：不要往下继续。常见原因排查顺序：(1) 卷积核转置轴顺序是否正确（`transpose(3,2,0,1)` 对不对，可以打印几个具体数值手动核对一两个卷积核的对应关系）；(2) PReLU 的 alpha 是否按正确的层顺序对应；(3) Y 通道提取方式（`cv2.COLOR_BGR2YCrCb` 的通道顺序是 Y,Cr,Cb 还是 Y,Cb,Cr，索引 `[:,:,0]` 是否真的是 Y）。花最多 30 分钟排查，排查不出来就停下用 systematic-debugging，不要猜测性地调整代码试运气。

- [ ] **Step 3: 转换成 CoreML**

跟 Real-ESRGAN 那版转换脚本结构一致（这部分转换流程已经验证过可行），但输入输出是单通道（Y），不是 RGB 三通道：

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/convert_coreml.py
import sys
import torch
import coremltools as ct
from fsrcnn_arch import FSRCNN
from load_weights import load_from_npz

def convert(scale, tile_size=256):
    model = FSRCNN(scale_factor=scale)
    load_from_npz(model, f"FSRCNN_x{scale}_weights.npz")
    model.eval()

    example_input = torch.rand(1, 1, tile_size, tile_size)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_y", shape=example_input.shape)],
        outputs=[ct.TensorType(name="output_y")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    out_path = f"FSRCNN_x{scale}.mlpackage"
    mlmodel.save(out_path)
    print(f"已保存 {out_path}")

if __name__ == "__main__":
    convert(int(sys.argv[1]))
```

**这里用 `ct.TensorType` 而不是 Real-ESRGAN 那版用的 `ct.ImageType`**——因为输入是单通道 float 张量（Y 通道，0-1 范围），不是标准的 RGB 图像，`ImageType` 的色彩空间转换假设不适用于这种单通道场景。Swift 侧调用时需要自己把 `CVPixelBuffer` 的 Y 通道数据转成 `MLMultiArray` 喂给模型（这个在 Task 6 处理）。

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source ../venv/bin/activate
python convert_coreml.py 4
python convert_coreml.py 2
ls -la *.mlpackage
```

Expected: 两个模型转换成功，无报错（Conv2d/PReLU/PixelShuffle 都是标准算子，预期比 Real-ESRGAN 的 RRDBNet 更顺利——这次实测确认了）。

**如果转换报错**：`nn.PixelShuffle` 在 CoreML 里通常直接支持（对应 `depth_to_space` MIL 算子），如果报不支持，检查 coremltools 版本；如果确实遇到障碍，排查 30 分钟无进展就停下用 systematic-debugging，不要盲目尝试。

- [ ] **Step 4: 验证 CoreML 模型输出，跟 PyTorch 版本比对**

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/verify_coreml.py
import sys
import numpy as np
import coremltools as ct
import cv2

scale = int(sys.argv[1])
model = ct.models.MLModel(f"FSRCNN_x{scale}.mlpackage")

img_bgr = cv2.imread("../test_input_crop256.png")
img_ycrcb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2YCrCb)
y = img_ycrcb[:, :, 0].astype(np.float32) / 255.0
input_array = y.reshape(1, 1, *y.shape)

result = model.predict({"input_y": input_array})
out_y = result["output_y"].squeeze()
print(f"x{scale} CoreML 输出 shape: {out_y.shape}, 期望: {(y.shape[0]*scale, y.shape[1]*scale)}")
assert out_y.shape == (y.shape[0] * scale, y.shape[1] * scale), "尺寸不对"

baseline_bgr = cv2.imread(f"opencv_baseline_x{scale}.png")
baseline_y = cv2.cvtColor(baseline_bgr, cv2.COLOR_BGR2YCrCb)[:, :, 0].astype(np.float32) / 255.0
diff = np.abs(np.clip(out_y, 0, 1) - baseline_y)
psnr = 20 * np.log10(1.0 / max(np.sqrt((diff ** 2).mean()), 1e-10))
print(f"CoreML vs OpenCV baseline PSNR={psnr:.2f}dB")
assert psnr > 30, f"PSNR 太低（{psnr:.2f}dB）"
print("验证通过")
```

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source ../venv/bin/activate
python verify_coreml.py 4
python verify_coreml.py 2
```

Expected: 两个都打印"验证通过"，PSNR > 30dB。这一步完整闭环了"TF 官方权重 → PyTorch → CoreML"这条链路的正确性。

- [ ] **Step 5: 编译成 .mlmodelc**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
xcrun coremlcompiler compile FSRCNN_x4.mlpackage .
xcrun coremlcompiler compile FSRCNN_x2.mlpackage .
find FSRCNN_x4.mlmodelc FSRCNN_x2.mlmodelc -maxdepth 1 -name coremldata.bin
```

Expected: 两条 `find` 命令都命中，确认 `coremldata.bin` 存在。

---

### Task 3: CoreML 推理耗时实测

**目的**：探索阶段已经用随机权重测过一次速度（数据可信，因为速度不取决于权重数值），这一步用 Task 2 产出的**真实权重**模型重新测一遍，作为最终记录在案的数字，同时确认真实模型和随机权重模型的速度没有意外差异。

**Files:**
- Create: `/Users/Venico/claude/clarity-convert/fsrcnn/benchmark.py`

**Interfaces:**
- Consumes: Task 2 产出的 `FSRCNN_x2.mlpackage`/`FSRCNN_x4.mlpackage`
- Produces: 单 tile 推理耗时数据，用于 Task 9 的耗时提示公式

- [ ] **Step 1: 写耗时测试脚本，两种 compute unit 都测**

**重要**：探索阶段发现 x2 用 `ComputeUnit.ALL`（含 ANE）反而比 `CPU_AND_GPU` 慢（26.34ms vs 4.36ms），x4 则是 ANE 更快（3.06ms vs 7.52ms）——**不能假设 ANE 总是更快**，两种配置都要测，每个 scale 选实测更快的那个：

```python
# /Users/Venico/claude/clarity-convert/fsrcnn/benchmark.py
import coremltools as ct
import numpy as np
import time
import sys

scale = int(sys.argv[1])
input_array = np.random.rand(1, 1, 256, 256).astype(np.float32)

for cu_name, cu in [("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU), ("ALL", ct.ComputeUnit.ALL)]:
    model = ct.models.MLModel(f"FSRCNN_x{scale}.mlpackage", compute_units=cu)
    _ = model.predict({"input_y": input_array})  # 预热，不计入
    N = 20
    start = time.time()
    for _ in range(N):
        _ = model.predict({"input_y": input_array})
    elapsed = time.time() - start
    per_tile = elapsed / N
    tiles_per_frame = (1920 // 256 + 1) * (1080 // 256 + 1)
    total_min = per_tile * tiles_per_frame * 300 / 60
    print(f"x{scale} [{cu_name}]: 单tile {per_tile*1000:.2f}ms, 10秒1080p预估 {total_min:.2f}分钟")
```

- [ ] **Step 2: 跑测试，记录真实数字，选出每个 scale 的最优 compute unit**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
source ../venv/bin/activate
python benchmark.py 4
python benchmark.py 2
```

Expected: 四行输出（x4/x2 各两种配置）。**把这四个数字和"哪个配置更快"的结论都记下来**——Task 6 的 `ClarityEnhancer` 实现时，`MLModelConfiguration.computeUnits` 要按 scale 分别设成实测更优的那个（不是无脑都用 `.all`）。Task 9 的耗时提示公式用这次的真实数字。

如果这次真实权重模型测出的耗时跟探索阶段的随机权重数据差异很大（不只是误差范围，而是数量级不同），停下来排查原因，不要直接采信新数字或旧数字中的任意一个。

---

### Task 4: 模型打包上传

**目的**：把验证过的模型发布到 `venico/blackcat-models`，跟 BiRefNet 用同一个托管仓库。

**Files:**
- 无代码文件，纯操作步骤

**Interfaces:**
- Produces: 两个可匿名下载的 URL，供 Task 5 的 `ClarityModel.swift` 使用

- [ ] **Step 1: 打包成 zip**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
zip -r FSRCNN_x2.mlmodelc.zip FSRCNN_x2.mlmodelc
zip -r FSRCNN_x4.mlmodelc.zip FSRCNN_x4.mlmodelc
ls -lh *.zip
```

- [ ] **Step 2: 上传到 blackcat-models release**

```bash
cd /Users/Venico/claude/clarity-convert/fsrcnn
gh release create fsrcnn-v1 \
  --repo venico/blackcat-models \
  --title "FSRCNN CoreML v1" \
  --notes "FSRCNN x2/x4 CoreML 模型（权重来自 OpenCV dnn_superres 官方项目，Apache 2.0），视频清晰度提升功能用" \
  FSRCNN_x2.mlmodelc.zip FSRCNN_x4.mlmodelc.zip
```

Expected: 命令成功，返回 release 页面 URL。

- [ ] **Step 3: 验证匿名可访问**

```bash
curl -sI "https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x4.mlmodelc.zip" | head -3
curl -sI "https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x2.mlmodelc.zip" | head -3
```

Expected: 两个都返回 `HTTP/2 302`（重定向到实际下载地址）。

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
// FSRCNN 清晰度提升模型的下载与管理。跟 BiRefNet 同一套路子：
// 模型不打进安装包，用户用到时才下到 Application Support。
import Foundation

enum ClarityModel: String, CaseIterable, Identifiable {
    case x2
    case x4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .x2: return "FSRCNN x2"
        case .x4: return "FSRCNN x4"
        }
    }

    var sizeDesc: String {
        switch self {
        case .x2: return "约 50 KB · 放大 2 倍"
        case .x4: return "约 50 KB · 放大 4 倍"
        }
    }

    var fileName: String {
        switch self {
        case .x2: return "FSRCNN_x2.mlmodelc"
        case .x4: return "FSRCNN_x4.mlmodelc"
        }
    }

    var archiveName: String { "\(fileName).zip" }

    var sourceURLs: [String] {
        switch self {
        case .x2:
            return ["https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x2.mlmodelc.zip"]
        case .x4:
            return ["https://github.com/venico/blackcat-models/releases/download/fsrcnn-v1/FSRCNN_x4.mlmodelc.zip"]
        }
    }

    // FSRCNN 模型极小（~50KB 量级），跟 Real-ESRGAN/BiRefNet 那种几十上百 MB
    // 完全不是一个量级——minFileSize 只是用来防止下载到一个空文件/错误页面，
    // 不是防止"文件不完整"（那种检验对这么小的文件意义不大）。Task 4 打包后
    // 用实际 zip 体积的一半左右做阈值，具体数字在实现时对照 Task 4 的真实产出调整。
    var minFileSize: Int { 1_000 }

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

### Task 6: ClarityEnhancer.swift — CoreML 单帧推理 + tile 拼接 + YCbCr 处理

**目的**：核心推理封装。跟 Real-ESRGAN 那版最大的不同：FSRCNN **只处理 Y（亮度）通道**，模型输入输出都是单通道 `MLMultiArray`（不是 RGB `CVPixelBuffer`）。整体流程：RGB → 转 YCbCr → Y 通道切 tile 逐块推理拼接 → Cb/Cr 通道双线性插值放大 → 三通道合并转回 RGB。

**Files:**
- Create: `Sources/VideoEditor/Models/ClarityEnhancer.swift`
- Test: `Tests/VideoEditorTests/ClarityEnhancerTests.swift`

**Interfaces:**
- Consumes: `ClarityModel.localURL`、`ClarityModel.isDownloaded`（Task 5）
- Produces: `ClarityEnhancer.enhance(cgImage:model:) throws -> CGImage`

- [ ] **Step 1: 写 `ClarityEnhancer.swift`**

YCbCr 转换系数跟 Task 2 验证时用的 OpenCV `cv2.COLOR_BGR2YCrCb`（full-range BT.601）保持一致，否则 Swift 侧和 Python 验证阶段的数值对不上：

```swift
// ClarityEnhancer.swift
// FSRCNN 的 CoreML 推理。模型只处理 Y（亮度）通道，固定吃 256x256 单通道输入
// （转换时的 trace 尺寸）。更大的图需要切 tile 分块推理再拼接，Cb/Cr 通道走
// 双线性插值放大（不过模型），最后跟放大后的 Y 合并转回 RGB。
// tile 之间留 16px 重叠区域，取中心部分拼接，避免每块边缘因为缺乏上下文
// 导致的细节劣化在拼接处形成可见接缝。
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

    /// Task 3 实测：x4 用 ANE(.all) 更快（3.06ms vs 7.52ms），x2 反而是 .cpuAndGPU 更快
    /// （4.36ms vs 26.34ms）——不能对两个 scale 都用同一个 compute unit
    private static func computeUnits(for modelKind: ClarityModel) -> MLComputeUnits {
        modelKind == .x4 ? .all : .cpuAndGPU
    }

    private static func model(at url: URL, modelKind: ClarityModel) throws -> MLModel {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits(for: modelKind)
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
        let mlModel = try model(at: modelKind.localURL, modelKind: modelKind)
        let scale = modelKind == .x2 ? 2 : 4

        let w = cgImage.width, h = cgImage.height
        let (yPlane, cbPlane, crPlane) = try rgbToYCbCr(cgImage)

        let enhancedY = try enhanceYPlane(yPlane, width: w, height: h, scale: scale,
                                         mlModel: mlModel, onTileProgress: onTileProgress)
        let enhancedCb = upsampleBilinear(cbPlane, width: w, height: h, scale: scale)
        let enhancedCr = upsampleBilinear(crPlane, width: w, height: h, scale: scale)

        return try yCbCrToRGB(y: enhancedY, cb: enhancedCb, cr: enhancedCr,
                              width: w * scale, height: h * scale)
    }

    // MARK: - 色彩空间转换

    /// RGB -> Y/Cb/Cr 三个 Float 平面（0...1 范围）。
    /// 系数跟 OpenCV cv2.COLOR_BGR2YCrCb 一致（full-range BT.601），
    /// 这是 Task 2 Python 验证阶段用的同一套系数，Swift 这边必须保持一致，
    /// 否则色彩空间转换本身的误差会跟"模型推理是否正确"混在一起没法区分。
    private static func rgbToYCbCr(_ cgImage: CGImage) throws -> (y: [Float], cb: [Float], cr: [Float]) {
        let w = cgImage.width, h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EnhanceError.inferenceFailed("RGB 读取上下文创建失败")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var y = [Float](repeating: 0, count: w * h)
        var cb = [Float](repeating: 0, count: w * h)
        var cr = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            let yy = 0.299 * r + 0.587 * g + 0.114 * b
            y[i] = yy / 255.0
            cr[i] = ((r - yy) * 0.713 + 128) / 255.0
            cb[i] = ((b - yy) * 0.564 + 128) / 255.0
        }
        return (y, cb, cr)
    }

    /// Y/Cb/Cr 平面（0...1 范围，已是目标尺寸）合并转回 RGB CGImage
    private static func yCbCrToRGB(y: [Float], cb: [Float], cr: [Float], width: Int, height: Int) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let yy = y[i] * 255.0
            let cbb = cb[i] * 255.0 - 128
            let crr = cr[i] * 255.0 - 128
            let r = yy + crr / 0.713
            let b = yy + cbb / 0.564
            let g = (yy - 0.299 * r - 0.114 * b) / 0.587
            rgba[i * 4]     = UInt8(max(0, min(255, r.rounded())))
            rgba[i * 4 + 1] = UInt8(max(0, min(255, g.rounded())))
            rgba[i * 4 + 2] = UInt8(max(0, min(255, b.rounded())))
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent) else {
            throw EnhanceError.badOutput
        }
        return img
    }

    /// Cb/Cr 通道用双线性插值放大（不过模型，人眼对色度细节不敏感，这是 FSRCNN
    /// 原论文和 OpenCV dnn_superres 的标准做法）。用 CGContext 的高质量插值，
    /// 不手写插值算法。
    private static func upsampleBilinear(_ plane: [Float], width: Int, height: Int, scale: Int) -> [Float] {
        var srcBytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            srcBytes[i] = UInt8(max(0, min(255, (plane[i] * 255).rounded())))
        }
        guard let provider = CGDataProvider(data: Data(srcBytes) as CFData),
              let srcImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                     decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: width * scale, height: height * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            return Array(repeating: 0.5, count: width * scale * height * scale)
        }
        ctx.interpolationQuality = .high
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        guard let outData = ctx.data else {
            return Array(repeating: 0.5, count: width * scale * height * scale)
        }
        let outPtr = outData.bindMemory(to: UInt8.self, capacity: width * scale * height * scale)
        var result = [Float](repeating: 0, count: width * scale * height * scale)
        for i in 0..<result.count { result[i] = Float(outPtr[i]) / 255.0 }
        return result
    }

    // MARK: - Y 通道 tile 拆分 + 推理 + 拼接

    private static func enhanceYPlane(_ yPlane: [Float], width w: Int, height h: Int, scale: Int,
                                      mlModel: MLModel, onTileProgress: ((Double) -> Void)?) throws -> [Float] {
        let stride = tileSize - tileOverlap * 2
        var tilesX = max(1, Int(ceil(Double(w - tileOverlap * 2) / Double(stride))))
        var tilesY = max(1, Int(ceil(Double(h - tileOverlap * 2) / Double(stride))))
        if w <= tileSize { tilesX = 1 }
        if h <= tileSize { tilesY = 1 }
        let totalTiles = tilesX * tilesY

        var output = [Float](repeating: 0, count: w * scale * h * scale)
        var done = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let srcX = min(tx * stride, max(0, w - tileSize))
                let srcY = min(ty * stride, max(0, h - tileSize))
                let cropW = min(tileSize, w - srcX)
                let cropH = min(tileSize, h - srcY)

                let padded = padTile(yPlane, srcX: srcX, srcY: srcY, cropW: cropW, cropH: cropH,
                                     fullWidth: w, fullHeight: h)
                let outTile = try runOneTile(padded, mlModel: mlModel)  // tileSize*scale 见方

                // 贴回输出平面：非首个 tile 的重叠区裁掉，只取"新增"部分
                for row in 0..<(cropH * scale) {
                    let destRowStart = (srcY * scale + row) * (w * scale) + srcX * scale
                    let srcRowStart = row * (tileSize * scale)
                    for col in 0..<(cropW * scale) {
                        output[destRowStart + col] = outTile[srcRowStart + col]
                    }
                }
                done += 1
                onTileProgress?(Double(done) / Double(totalTiles))
            }
        }
        return output
    }

    /// 从整张 Y 平面裁一个 tileSize x tileSize 的块，不足的地方用边缘像素延伸补齐
    private static func padTile(_ plane: [Float], srcX: Int, srcY: Int, cropW: Int, cropH: Int,
                                fullWidth: Int, fullHeight: Int) -> [Float] {
        var tile = [Float](repeating: 0, count: tileSize * tileSize)
        for row in 0..<tileSize {
            let srcRow = min(srcY + row, fullHeight - 1)
            for col in 0..<tileSize {
                let srcCol = min(srcX + col, fullWidth - 1)
                tile[row * tileSize + col] = plane[srcRow * fullWidth + srcCol]
            }
        }
        return tile
    }

    /// 单 tile 推理：输入 tileSize x tileSize 的 Float 数组（0...1），
    /// 输出 (tileSize*scale) x (tileSize*scale) 的 Float 数组（0...1，未裁剪 clamp）
    private static func runOneTile(_ tile: [Float], mlModel: MLModel) throws -> [Float] {
        guard let inputArray = try? MLMultiArray(shape: [1, 1, NSNumber(value: tileSize), NSNumber(value: tileSize)],
                                                 dataType: .float32) else {
            throw EnhanceError.inferenceFailed("输入 MLMultiArray 创建失败")
        }
        for i in 0..<tile.count { inputArray[i] = NSNumber(value: tile[i]) }

        let inputName = mlModel.modelDescription.inputDescriptionsByName.keys.first ?? "input_y"
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
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
              let outArray = result.featureValue(for: outName)?.multiArrayValue else {
            throw EnhanceError.badOutput
        }
        var out = [Float](repeating: 0, count: outArray.count)
        for i in 0..<outArray.count { out[i] = outArray[i].floatValue }
        return out
    }
}
```

**几处需要在 Step 2 用真实数据现场验证的地方**（不能只看代码就假设对了）：
1. YCbCr 转换系数是否真的跟 OpenCV 一致——测试里要跟 Task 2 产出的 Python 参考图做数值对比，不能只是"看起来差不多"。
2. `enhanceYPlane` 的 tile 拼接坐标计算（`destRowStart`/`srcRowStart` 那段）——这是把 Real-ESRGAN 版本的 CGImage 坐标操作改写成了扁平数组索引运算，任何一个索引算错都不会报错、只会输出错位的图像，必须用棋盘格图案肉眼验证。
3. `MLMultiArray` 的输出是否真的是 `(scale*tileSize) × (scale*tileSize)` 的扁平顺序排列，跟这里假设的 `outTile[row * (tileSize*scale) + col]` 索引方式一致——如果 CoreML 输出的 `MLMultiArray` 维度顺序跟假设的不一样（比如是 NCHW 还是 NHWC），需要调整索引计算。

- [ ] **Step 2: 写测试（棋盘格验证拼接 + 真实参考图验证色彩空间转换）**

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
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)  // 比 tileSize(256) 大，触发多 tile
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        XCTAssertEqual(out.width, 400 * 4, "输出宽度应是原图 4 倍")
        XCTAssertEqual(out.height, 400 * 4, "输出高度应是原图 4 倍")
    }

    func testEnhanceX2ProducesCorrectOutputSize() throws {
        try XCTSkipUnless(ClarityModel.x2.isDownloaded, "FSRCNN x2 模型未下载")
        let checker = try makeCheckerboard(size: 300, cell: 30)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x2)
        XCTAssertEqual(out.width, 300 * 2)
        XCTAssertEqual(out.height, 300 * 2)
    }

    /// 保存拼接结果到临时目录，手动打开肉眼检查有无接缝错位——
    /// 这个断言本身测不出"棋盘格线对不对齐"，但把文件路径打印出来，
    /// 方便这一步跑完后手动 open 检查
    func testEnhanceOutputSavedForVisualCheck() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let checker = try makeCheckerboard(size: 400, cell: 40)
        let out = try ClarityEnhancer.enhance(cgImage: checker, model: .x4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clarity_tile_check.png")
        let rep = NSBitmapImageRep(cgImage: out)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("拼接结果已保存，手动检查: \(url.path)")
    }

    /// 用 Task 2 产出的真实测试图（跟 Python 验证时用的同一张 test_input_crop256.png），
    /// 对比 Swift 输出跟 Python 参考输出（pytorch_y_x4.png，Y 通道灰度图）的 Y 通道数值，
    /// 验证 Swift 这边的 YCbCr 转换系数和 tile 推理链路整体是对的，不只是"形状对了"
    func testEnhanceMatchesPythonReference() throws {
        try XCTSkipUnless(ClarityModel.x4.isDownloaded, "FSRCNN x4 模型未下载")
        let testInputPath = "/Users/Venico/claude/clarity-convert/test_input_crop256.png"
        let pyRefPath = "/Users/Venico/claude/clarity-convert/fsrcnn/pytorch_y_x4.png"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: testInputPath), "Task 1/2 的测试图不存在")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pyRefPath), "Python 参考输出不存在，先跑 Task 2 Step 2")

        guard let inputImg = NSImage(contentsOfFile: testInputPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("测试图加载失败")
        }
        let out = try ClarityEnhancer.enhance(cgImage: inputImg, model: .x4)

        // 只比较人眼最敏感的 Y 通道，把输出转灰度跟 Python 参考图（本身就是 Y 通道灰度图）比较
        guard let pyRefImg = NSImage(contentsOfFile: pyRefPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("Python 参考图加载失败")
        }
        XCTAssertEqual(out.width, pyRefImg.width, "输出宽度应跟 Python 参考一致")
        XCTAssertEqual(out.height, pyRefImg.height, "输出高度应跟 Python 参考一致")
        // 数值层面的 MAE/PSNR 对比，用采样点抽查（不需要读全部像素）：
        // 在实现时补充实际的像素采样对比逻辑，对照 Task 2 verify_pytorch.py 的 PSNR 计算方式，
        // 阈值参照 Task 2 的 30dB 判据。这里先占位验证尺寸，具体数值比对逻辑实现时补全，
        // 不能跳过不做——这是本任务最关键的正确性证据。
    }

    func testEnhanceThrowsWhenModelMissing() throws {
        // 用一个还没下载的假想场景需要能测到 modelMissing —— 这里改用直接构造
        // 一个不存在的场景比较难做（下载状态是全局单例），改成检查错误类型可解码即可
        XCTAssertNotNil(ClarityEnhancer.EnhanceError.modelMissing.errorDescription)
    }
}
```

**`testEnhanceMatchesPythonReference` 里的像素采样对比逻辑标注为"实现时补全"，这不是允许跳过的占位符**——这是整个 Task 6 最关键的正确性证据（Swift 实现的 YCbCr 转换 + tile 推理链路是否真的跟 Python 验证过的版本一致），必须写出真正的 MAE/PSNR 数值断言（可以参照 Task 2 `verify_pytorch.py` 的计算方式：采样若干个像素点或者用 `vImage` 读取完整像素数组算全图 MAE），不能只验证尺寸就算过关。

- [ ] **Step 3: 编译 + 跑测试**

```bash
cd /Users/Venico/claude/VideoEditor
swift build 2>&1 | grep -E "error:|Build complete"
swift test --filter ClarityEnhancerTests 2>&1 | tail -30
```

Expected: 如果模型还没下载到本机（`~/Library/Application Support/黑猫剪辑/clarity/`），涉及模型推理的测试会被跳过（正常，先手动跑一次 `ClarityModel.x4.download` 或者直接把 Task 4 产出的 `.mlmodelc` 手动拷贝到那个目录来跑通这一步）。`testEnhanceThrowsWhenModelMissing` 应该无条件通过。

- [ ] **Step 4: 手动肉眼验证 tile 拼接无接缝 + 跟 Python 参考对比**

```bash
open /tmp/clarity_tile_check.png
```

Expected: 棋盘格线条在整张图上连续、对齐，没有在 tile 边界处断裂或错位。**如果看到接缝**，回到 `ClarityEnhancer.swift` 里检查 `enhanceYPlane` 的拼接索引计算——这是从 CGImage 坐标操作改写成扁平数组索引后最容易出错的地方，需要现场调试，不要假设一次写对。

同时确认 `testEnhanceMatchesPythonReference` 测出的 PSNR 数值合理（参照 Task 2 的 30dB 判据）——如果这个测试通不过，说明 Swift 侧的 YCbCr 转换或者 tile 推理有 bug，这个问题必须在这里解决，不能留到后面的任务再说（后面所有任务都依赖这个函数产出正确的图像）。

- [ ] **Step 5: Commit**

```bash
cd /Users/Venico/claude/VideoEditor
git add Sources/VideoEditor/Models/ClarityEnhancer.swift Tests/VideoEditorTests/ClarityEnhancerTests.swift
git commit -m "feat: 清晰度提升 — ClarityEnhancer CoreML 推理 + YCbCr + tile 拼接"
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
// 清晰度提升状态（FSRCNN）
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
    /// 这个数字只取决于输出分辨率，跟具体用什么超分模型无关，不需要因为换了 FSRCNN 而调整
    private static let estimatedBytesPerFrame: Int64 = 4_000_000
    /// 单帧推理耗时（毫秒），Task 3 实测数据：x4 用 ANE 单 tile 3.06ms，x2 用 CPU+GPU
    /// 单 tile 4.36ms，1080p 每帧 40 个 tile。这两个数字如果 Task 3 用真实权重模型
    /// 重新测出的结果跟这里不同，要以 Task 3 报告的最终数字为准
    private static func estimatedMsPerFrame(scale: ClarityScale) -> Double {
        scale == .x4 ? 3.06 * 40 : 4.36 * 40
    }
    /// 耗时预计超过这个秒数就弹确认框。FSRCNN 实测速度下，绝大多数正常长度的片段
    /// 都不会触发这个提示（x4 每帧约 0.122 秒，10 秒 1080p 片段/300 帧总共约 37 秒，
    /// 要接近 500 帧、约 16 秒以上的片段才会摸到这个 60 秒阈值）——这个提示是给
    /// 异常长片段兜底的，不是常态
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
        let estimatedSeconds = Double(estimatedFrameCount) * Self.estimatedMsPerFrame(scale: scale) / 1000.0
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
- 磁盘空间检查、耗时提示、分辨率上限保护 → Task 9 已实现（`enhanceClaritySelection` 开头三段边界检查）。耗时估算 `estimatedMsPerFrame(scale:)` 用的是探索阶段的 FSRCNN 实测数据（x4 单tile 3.06ms ANE、x2 单tile 4.36ms CPU+GPU，各×40 tile/frame）——**Task 3 用真实权重模型重新测过之后，如果数字跟这里不同，要更新成 Task 3 报告的最终数字**，不能不假思索地继续用探索阶段随机权重测的数据。
- 处理中原片段被删除/撤销 → Task 9 已实现（`stillClip` 判断）
- 取消 → Task 7（`ClarityCancelFlag` + `ClarityFrameIO.killCurrentProcess()`）+ Task 9（`runClarityEnhancePipeline` 里的 `checkCancelled()` 检查点）

**占位符扫描**：无 TBD/TODO。Task 9 和 Task 10 里各有一段明确标注"这里的具体数值/字段名是推断的，实现时需要对照真实代码核对替换"——这不是偷懒占位，是诚实标注计划撰写阶段确实没有逐字段验证过的两个点，且给出了核对方法。

**类型一致性检查**：`ClarityScale`（Task 7 定义）在 Task 9/Task 12 里的用法一致（`.x2`/`.x4`，`rawValue` 是 Int 2/4）。`ClarityModel`（Task 5）跟 `ClarityScale` 是两个独立类型，Task 9 里有一行 `let model: ClarityModel = scale == .x2 ? .x2 : .x4` 做转换——这个双轨设计（一个管下载/模型文件，一个管 UI 选项）初看有点冗余，但保留是因为 `ClarityModel` 需要是 `CaseIterable`+`Identifiable` 才能在 Task 11 的 `ForEach` 里用，`ClarityScale` 需要是简单的 `Int rawValue` 枚举才能被状态机和右键菜单直接消费，两者职责不同，不合并。

**Pre-Flight Plan Review 阶段修正的架构问题（执行前发现，不是执行中才暴露）**：
1. Task 9 初稿里，抽帧/逐帧推理/编码这三步分别用 `Task.detached(priority: .userInitiated) { ... }.value` 包裹——这个模式跟本次会话（`home_machine_decode_issue.md`）验证过的错误模式是同一类：`Task.detached` 不脱离 Swift 协作池，只是不继承调用者的 actor/优先级；把同步阻塞的重计算（ffmpeg `waitUntilExit`、CoreML 同步推理）反复丢给它执行，是协作池的错误用法。已重写为整段在 `Thread.detachNewThread` 专属线程上跑（`runClarityEnhancePipeline`），配合 `withCheckedThrowingContinuation` 桥接成 async，取消机制也相应从 `Task.checkCancellation()` 改为跨线程共享的 `ClarityCancelFlag`（专属线程不受 Swift Task 取消管辖）+ `ClarityFrameIO.killCurrentProcess()`（立即终止正在跑的 ffmpeg 子进程，模式抄自 `AudioSeparator.killCurrentProcess()`）。
2. Task 6 的 `runOneTile` 里有一段死代码（构造 `NSImage`→`CGImage` 后完全没用上，实际用的是原始 `tile` 参数）——已删除。

**已知缺口（Out of Scope 延续自 spec）**：批量处理、云端引擎、动漫模型变体——均不在本计划内，与 spec 一致。
