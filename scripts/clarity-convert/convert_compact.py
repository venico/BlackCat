#!/usr/bin/env python3
"""把 Real-ESRGAN 的 SRVGGNetCompact 轻量模型转成 CoreML。

跟 convert_coreml.py（RRDBNet / x4plus）分开写：这两个是完全不同的架构，
SRVGGNetCompact 是纯 conv+prelu 串联 + 一次 PixelShuffle，没有 RRDB 的残差密集块，
也不需要那个 pixel_unshuffle 的静态化 patch。

不依赖 basicsr：网络结构直接按权重形状复刻（34/18 层 conv、末层 48 通道 = 3*4*4），
少一个装起来会跟 torchvision 打架的重依赖。
"""
import sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN 的轻量分支。结构和权重命名跟 basicsr 的实现一致，
    这样官方 .pth 能直接 load_state_dict 进来。"""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        # 网络学的是残差，要叠回最近邻放大的底图
        return out + F.interpolate(x, scale_factor=self.upscale, mode='nearest')


class _ForCoreML(nn.Module):
    """输出从 [0,1] 拉到 [0,255]。

    理由跟 convert_coreml.py 里的 _RRDBNetForCoreML 完全一样：coremltools 的
    ImageType **输出**转换不会插入任何 scale/bias，只挂一个色彩空间描述符，
    所以 ~[0,1] 的张量会被直接当成 0-255 像素写出去，得到一张近乎全黑的图。
    输入侧的 scale=1/255 是另一套独立机制，只作用于输入。
    """

    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, x):
        return torch.clamp(self.base(x), 0.0, 1.0) * 255.0


def infer_num_conv(state_dict):
    """从权重反推 body 里有多少个中间 conv。
    body 的排列是 [conv, prelu] * (1 + num_conv) + [conv]，
    所以 conv 总数 = num_conv + 2。"""
    idx = sorted({int(k.split('.')[1]) for k in state_dict
                  if k.startswith("body.") and k.endswith(".weight")
                  and state_dict[k].dim() == 4})
    return len(idx) - 2


def convert(pth_path, out_path, tile_size=256):
    sd = torch.load(pth_path, map_location="cpu", weights_only=True)
    sd = sd.get("params", sd)
    num_conv = infer_num_conv(sd)
    print(f"{pth_path}: num_conv={num_conv}, 参数量 {sum(v.numel() for v in sd.values())/1e6:.2f} M")

    model = SRVGGNetCompact(num_conv=num_conv, upscale=4)
    model.load_state_dict(sd, strict=True)   # strict：结构对不上就当场报错，不静默错配
    model.eval()

    wrapped = _ForCoreML(model).eval()
    example = torch.rand(1, 3, tile_size, tile_size)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example.shape,
                             scale=1/255.0, bias=[0, 0, 0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.save(out_path)
    print(f"已保存 {out_path}")
    return out_path


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
