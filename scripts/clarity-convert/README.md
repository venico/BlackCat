# 清晰度提升（超分）模型的 CoreML 转换工具链

app 里「清晰度提升」用的 CoreML 模型，都是拿上游 PyTorch / TensorFlow 权重在这里转出来的。
转换产物走 GitHub release 分发（`venico/blackcat-models`），app 按需下载。

**为什么这堆脚本要入 git**：BiRefNet（抠图）的转换脚本原本也留在 `~/claude/` 下一个临时目录里，
后来目录清掉，脚本没了 —— 模型本体还在 release 上能用，但想换个变体、改 tile 尺寸、
或者上游发了新权重想重转，就得把当初趟过的坑（动态形状、自定义算子、FP16 权重）全部重趟一遍。
所以超分这套按同样的教训收进仓库。

原始工作目录 `/Users/Venico/claude/clarity-convert/`（含 venv、权重、产物、测试图，4.2 GB）**不入库**，
这里只放脚本 —— 权重能按下面的地址重新下载，产物能重新转出来。

---

## 一、三条链路，对应 app 里的 6 个引擎中的 5 个

| app 引擎（`ClarityModel` / `ClarityProModel`） | 上游模型 | 转换脚本 |
|---|---|---|
| FSRCNN x2 / x4 | FSRCNN（TensorFlow `.pb`） | `fsrcnn/` 整个目录 |
| 实拍素材增强（`generalX4V3`） | realesr-general-x4v3 | `convert_compact.py` |
| 动漫增强·快（`animeVideoV3`） | realesr-animevideov3 | `convert_compact.py` |
| 动漫增强·质量优先 2x（`realCUGAN2x`） | Real-CUGAN up2x denoise1x | `convert_cugan.py` |
| 动漫增强·质量优先 4x（`realCUGAN`） | Real-CUGAN up4x | `convert_cugan.py` |

剩下两个引擎不经过这里：**系统内置**走 `AppleSuperResolution`（VideoToolbox），
**fal.ai** 走云端 API（`FalUpscaleService`）。

`convert_coreml.py`（RRDBNet / Real-ESRGAN x2plus·x4plus）转出来的模型**没有上线**：
16.7 M 参数，实测 201.9 ms/图块，7 分钟 1080p 要跑 28 小时。脚本保留是因为 RRDBNet 那套
`pixel_unshuffle` 静态化的坑值得留档，真要转别的 RRDBNet 系模型能直接用。

---

## 二、环境

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

`requirements.txt` 里的版本是配套关系，别单独升级：`basicsr==1.4.2` 只被
`convert_coreml.py` / `inference_check.py` / `verify_coreml.py` 用到（RRDBNet 那条线），
而它在 `torchvision>=0.17` 下会 import 一个已删除的模块，脚本顶部有 shim 兜着（见第五节）。
`convert_compact.py` 和 `convert_cugan.py` 不依赖 basicsr。

**fsrcnn/ 需要两个额外环境**，都跟主环境冲突，各建各的 venv：

- `extract_tf_weights.py` 要 `tensorflow`（只在从 `.pb` 提权重这一步用）
- `opencv_baseline.py` 要 `opencv-contrib-python`（`cv2.dnn_superres` 在 contrib 模块里，
  普通 `opencv-python` 没有）；`verify_pytorch.py` / `fsrcnn/verify_coreml.py` 要 `opencv-python`

---

## 三、权重下载

Real-ESRGAN 系的 4 个地址已经用 HEAD 请求核对过 `content-length`，与当初转换用的文件
逐字节吻合：

```bash
# Real-ESRGAN 轻量分支（已上线的两个）
curl -L -O https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth
curl -L -O https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth

# Real-ESRGAN RRDBNet（未上线，太慢；转换脚本留档用）
curl -L -o x4plus.pth https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
curl -L -o x2plus.pth https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth

# FSRCNN（OpenCV dnn_superres 用的 TensorFlow 权重）
curl -L -O https://raw.githubusercontent.com/Saafke/FSRCNN_Tensorflow/master/models/FSRCNN_x2.pb
curl -L -O https://raw.githubusercontent.com/Saafke/FSRCNN_Tensorflow/master/models/FSRCNN_x4.pb
```

**Real-CUGAN 的下载地址没有记录下来**，上游是 [bilibili/ailab](https://github.com/bilibili/ailab)
的 Real-CUGAN。当初用的两份权重按下面的 SHA256 核对，别拿错档位 ——
up2x 有 `no-denoise` 和 `denoise1x` 两个版本，**上线的是 denoise1x**
（依据：`ClarityProModel.infoText` 写的是「Real-CUGAN up2x denoise1x 模型」）。

### SHA256（转换时实际用的文件）

```
49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb  x2plus.pth                     (RealESRGAN_x2plus.pth, 67061725 B)
4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1  x4plus.pth                     (RealESRGAN_x4plus.pth, 67040989 B)
b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d  realesr-animevideov3.pth       (2504012 B)
8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292  realesr-general-x4v3.pth       (4885111 B)
42bd8fcdae37c12c5b25ed59625266bfa65780071a8d38192d83756cb85e98dd  cugan4x.pth                    (Real-CUGAN up4x, 5636403 B)
2e783c39da6a6394fbc250fdd069c55eaedc43971c4f2405322f18949ce38573  up2x-latest-denoise1x.pth      (5147249 B, ← 上线用的是这个)
f491f9ecf6964ead9f3a36bf03e83527f32c6a341b683f7378ac6c1e2a5f0d16  up2x-latest-no-denoise.pth     (5147249 B, 未采用)
366b33f0084c7b3f2bf6724f0a2c77bca94fcec9d7b6d72389d330073b380d5c  FSRCNN_x2.pb                   (38973 B)
5c68d18db561aed8ead4ffedf1b897ea615baaf60ebf6c35f8e641f8fa4a21bf  FSRCNN_x4.pb                   (41661 B)
```

`cugan4x.pth` 是本地起的名字，上游文件名不是这个。

---

## 四、转换命令

所有脚本都固定 `tile_size=256` —— CoreML 模型必须是静态输入尺寸，app 侧按 256 的图块切分推理。

### Real-ESRGAN 轻量分支（SRVGGNetCompact）

```bash
python convert_compact.py realesr-animevideov3.pth RealESRGAN_animevideo_x4v3.mlpackage
python convert_compact.py realesr-general-x4v3.pth RealESRGAN_general_x4v3.mlpackage
```

`num_conv` 从权重形状反推，不用手填；`load_state_dict(strict=True)` 保证结构对不上当场报错。

### Real-CUGAN

```bash
python convert_cugan.py cugan4x.pth RealCUGAN_up4x.mlpackage 4
python convert_cugan.py up2x-latest-denoise1x.pth RealCUGAN_up2x.mlpackage 2
```

第三个参数是倍数，默认 4。2x 和 4x 的网络结构差别不小（不是换个倍数），见
`convert_cugan.py` 里 `UpCunet2xForCoreML` 的注释。

### Real-ESRGAN RRDBNet（未上线）

```bash
python convert_coreml.py 4      # 读当前目录的 x4plus.pth，输出 RealESRGAN_x4plus.mlpackage
python convert_coreml.py 2
```

路径是写死的（`x{scale}plus.pth`），跟前两个脚本的传参风格不一致。

### FSRCNN

三步走，因为上游只有 TensorFlow 的 `.pb`：

```bash
cd fsrcnn
python extract_tf_weights.py 4      # TF 环境：.pb → FSRCNN_x4_weights.npz
python convert_coreml.py 4          # 主环境：npz → PyTorch → FSRCNN_x4.mlpackage
```

验证（需要 `../test_input_crop256.png`，随便一张 256×256 的图即可）：

```bash
python opencv_baseline.py 4     # contrib 环境：OpenCV dnn_superres 跑出基准图
python verify_pytorch.py 4      # PyTorch 复刻 vs 基准，PSNR < 30dB 直接断言失败
python verify_coreml.py 4       # CoreML vs 基准
python benchmark.py 4           # CPU_AND_GPU / ALL 两种计算单元的单图块耗时
```

FSRCNN 只超分亮度通道（输入 1 通道 Y，色度靠插值放大），所以它的接口是
`TensorType` 而不是别的三个的 `ImageType` —— app 侧也因此分成
`ClarityEnhancer`（Y + MultiArray）和 `ClarityProEnhancer`（RGB ImageType）两套。

### 验证（Real-ESRGAN 系）

```bash
python inference_check.py       # 纯 PyTorch 推理，产出 baseline_x4.png
python verify_coreml.py         # CoreML 输出 vs PyTorch 输出
python benchmark.py RealESRGAN_general_x4v3.mlpackage
```

---

## 五、发布到 release

app 下载的是编译后的 `.mlmodelc` 打的 zip，不是 `.mlpackage`：

```bash
xcrun coremlcompiler compile RealCUGAN_up4x.mlpackage .
ditto -c -k --sequesterRsrc --keepParent RealCUGAN_up4x.mlmodelc RealCUGAN_up4x.mlmodelc.zip
gh release upload clarity-pro-v1 RealCUGAN_up4x.mlmodelc.zip --repo venico/blackcat-models
```

文件名必须跟代码里的 `fileName` 完全一致，否则 app 下载 404：

| 引擎 | 文件名 | release tag |
|---|---|---|
| FSRCNN x2 / x4 | `FSRCNN_x2.mlmodelc` / `FSRCNN_x4.mlmodelc` | `fsrcnn-v1` |
| general-x4v3 | `RealESRGAN_general_x4v3.mlmodelc` | `clarity-pro-v1` |
| animevideov3 | `RealESRGAN_animevideo_x4v3.mlmodelc` | `clarity-pro-v1` |
| Real-CUGAN 2x | `RealCUGAN_up2x.mlmodelc` | `clarity-pro-v1` |
| Real-CUGAN 4x | `RealCUGAN_up4x.mlmodelc` | `clarity-pro-v1` |

仓库 `venico/blackcat-models` 是**公开**的（app 内不能内嵌 token，未认证访问私有仓库
GitHub 返回 404）。模型包的 tag 必须带连字符 —— `AppUpdater.isAppVersionTag` 用
`^[0-9]+(\.[0-9]+)+$` 区分 app 版本和模型包，写成纯版本号会被自动更新当成 app 新版本。

---

## 六、转换时踩过的坑

**1. coremltools 的 ImageType 输出不做任何 rescale。**
输入侧的 `scale=1/255.0` 是一套独立机制，只作用于输入；输出侧只挂一个色彩空间描述符，
不插 scale/bias。所以 ~[0,1] 的张量会被当成 0-255 像素直接写出去，得到一张近乎全黑的图。
三个 RGB 模型都在 forward 末尾自己 `clamp(0,1) * 255`。
（依据是读 `converters/mil/backend/mil/load.py` 的 `get_func_output()`，不是猜的）

**2. CoreML 的 pad 算子不接受负数。**
Real-CUGAN 到处用 `F.pad(x, (-4,-4,-4,-4))` 当裁剪使（UNet1/UNet2 内部各两处，主干还有
-20 和 -1），转换会在第一处就报 `converting 'pad' op`。`convert_cugan.py` 全局 patch 掉
`F.pad`：负数走切片、正数原样转发。切片时用 Python 负索引直接切，**不能读 `x.shape`** ——
trace 遇到 `x.shape[i]` 会生成 `aten::size` + `aten::Int`，CoreML 转不了。

**3. `pixel_unshuffle` 的动态形状。**
basicsr 的实现从 `x.size()` 取维度，`torch.jit.trace` 会把它录成动态形状算子，
coremltools 9.0 报 `TypeError: only 0-dimensional arrays can be converted to Python scalars`。
`convert_coreml.py` 把它换成写死 int 的等价实现（反正 CoreML 本来就要求静态输入尺寸）。
只有 scale=2 分支会走到，scale=4 不调用它。

**4. torchvision ≥ 0.17 删了 `transforms.functional_tensor`，basicsr 1.4.2 还在 import 它。**
`rgb_to_grayscale` 本身还在 `transforms.functional` 里没变，所以在 import basicsr 之前
注册一个只重导出这一个函数的 shim 模块即可。降版本不行：torch 2.5.1 / torchvision 0.20.1
是官方配套，没有更新的 torchvision 还带旧模块。

**5. FSRCNN 官方权重的 `b8` 不是卷积的 per-channel bias。**
它是加在 PixelShuffle **之后**的最终单通道输出上的一个标量（如果是 conv 的 bias，
x4 的 shape 应该是 16）。两种写法数值等价，但 `nn.Conv2d.bias` 长度必须等于
`out_channels`，装不下标量，所以 `fsrcnn_arch.py` 里 `out_conv` 是 `bias=False`，
另开一个 `output_bias` 参数。

**6. Real-CUGAN 官方 forward 不能直接 trace。**
`UpCunet4x.forward` 把 tile 切分、显存 cache 模式、fp16 分支、pro 归一化全塞在一个函数里，
末尾还 `.byte()` 量化输出（量化成整数张量会让 coremltools 把输出类型判成 int，接不上
ImageType）。`convert_cugan.py` 只重写 forward，架构类照用官方的 —— 两级 UNet + 通道注意力
+ 多处非对称 pad/crop，自己复刻出错面积太大。

---

## 七、第三方文件

`upcunet_v3.py`（74 KB）是 [bilibili/ailab](https://github.com/bilibili/ailab) 的 Real-CUGAN
官方架构定义，**原样拷进来未做改动**，`convert_cugan.py` 从它 import `UNet1` / `UNet2`。
不入库的话转换脚本直接跑不起来，而且上游改版后类定义未必还对得上当初的权重。

---

## 八、没有入库的东西

- `venv/`、`fsrcnn/tf_venv/`、`__pycache__/` —— 环境，按第二节重建
- `*.pth` / `*.pb` —— 上游权重，按第三节下载，SHA256 可核对
- `*.mlpackage` / `*.mlmodelc` / `*.zip` —— 转换产物，重新跑脚本即可
- `test_input.png`、`baseline_*.png`、`coreml_output_*.png` 等测试图 —— 随便找张图代替，
  验证脚本比的是「PyTorch vs CoreML 在同一张图上的差异」，不依赖具体是哪张
- `fsrcnn_test/` —— FSRCNN 定型前的中间试验版（`fsrcnn_arch.py` 是三通道的通用实现），
  已被 `fsrcnn/` 取代
