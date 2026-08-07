#!/usr/bin/env python3
"""把 Real-CUGAN up4x 转成 CoreML。

架构（UNet1 + UNet2 级联 + SEBlock）直接复用官方 upcunet_v3.py 里的类定义，
不自己复刻——它比 SRVGGNetCompact 复杂得多（两级 UNet、通道注意力、多处
非对称 pad/crop），照抄一遍出错的面积太大。

只重写 forward：官方 UpCunet4x.forward 把 tile 切分、显存 cache 模式、fp16
分支、pro 归一化全塞在一个函数里，还会 .byte() 量化输出——这些都不能进
CoreML 图。这里只保留 tile_mode=0（不切分）那条主干，尺寸固定为 tile_size，
输出保持 float [0,255]，跟 convert_compact.py 转出来的两个模型对齐。
"""
import sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

from upcunet_v3 import UNet1, UNet2

# Real-CUGAN 里到处在用 F.pad(x, (-4,-4,-4,-4)) 这种**负数 pad** 当裁剪用
# （UNet1/UNet2 内部各两处，主干里还有 -20 和 -1）。CoreML 的 pad 算子只接受
# 非负数，转换会在第一处就报 "converting 'pad' op"。这里全局换掉 F.pad：
# 负数走切片，正数原样转发。patch 全局属性即可——upcunet_v3 是
# `from torch.nn import functional as F` 然后运行时查 F.pad，拿到的是新的。
_orig_pad = F.pad


def _pad_or_crop(x, pads, mode='constant', value=0):
    if len(pads) == 4 and any(p < 0 for p in pads):
        assert all(p <= 0 for p in pads), f"不支持正负混合的 pad: {pads}"
        l, r, t, b = pads          # F.pad 顺序：最后一维在前 → (W左, W右, H上, H下)
        # 用 Python 负索引直接切，不去读 x.shape：trace 遇到 x.shape[i] 会生成
        # aten::size + aten::Int，而 CoreML 转不了这个 'int' op
        return x[:, :, -t: (b if b < 0 else None), -l: (r if r < 0 else None)]
    return _orig_pad(x, pads, mode, value)


F.pad = _pad_or_crop
torch.nn.functional.pad = _pad_or_crop


class UpCunet4xForCoreML(nn.Module):
    """UpCunet4x 的固定尺寸推理版。

    权重命名跟官方 UpCunet4x 一致（unet1./unet2./conv_final.），
    所以官方 .pth 能直接 load_state_dict 进来。
    """

    def __init__(self, in_channels=3, out_channels=3):
        super().__init__()
        self.unet1 = UNet1(in_channels, 64, deconv=True)
        self.unet2 = UNet2(64, 64, deconv=False)
        self.ps = nn.PixelShuffle(2)
        self.conv_final = nn.Conv2d(64, 12, 3, 1, padding=0, bias=True)

    def forward(self, x):
        x00 = x
        # 官方在这里按输入尺寸算 ph/pw 补到偶数；我们的输入尺寸是固定的偶数
        # （tile_size=256），所以补齐项恒为 0，只留下四边各 19 的 reflect pad
        x = F.pad(x, (19, 19, 19, 19), 'reflect')
        x = self.unet1(x)
        # 官方 UNet2.forward 带一个 alpha（增强强度实验参数），1 是不改变
        x0 = self.unet2(x, 1)
        x1 = F.pad(x, (-20, -20, -20, -20))
        x = torch.add(x0, x1)
        x = self.conv_final(x)
        x = F.pad(x, (-1, -1, -1, -1))
        x = self.ps(x)
        x = x + F.interpolate(x00, scale_factor=4, mode='nearest')
        # 官方这里是 (x*255).round().clamp_(0,255).byte()；CoreML 的 ImageType
        # 输出不做任何 rescale，所以这里必须自己乘到 [0,255]，但不 round/byte
        # （量化成整数张量会让 coremltools 把输出类型判成 int，接不上 ImageType）
        return torch.clamp(x * 255.0, 0.0, 255.0)


class UpCunet2xForCoreML(nn.Module):
    """UpCunet2x 的固定尺寸推理版。

    结构跟 4x 差别不小，不是换个倍数那么简单：
      · unet1 直接输出 3 通道（4x 是输出 64 通道再接 conv_final + PixelShuffle）
      · 没有 conv_final、没有 PixelShuffle，放大全靠 unet1 里 deconv=True 的转置卷积
      · reflect pad 是 18 不是 19
      · 结尾不叠最近邻放大的底图（4x 那条要叠）
    """

    def __init__(self, in_channels=3, out_channels=3):
        super().__init__()
        self.unet1 = UNet1(in_channels, out_channels, deconv=True)
        self.unet2 = UNet2(in_channels, out_channels, deconv=False)

    def forward(self, x):
        x = F.pad(x, (18, 18, 18, 18), 'reflect')
        x = self.unet1(x)
        x0 = self.unet2(x, 1)
        x = F.pad(x, (-20, -20, -20, -20))
        x = torch.add(x0, x)
        return torch.clamp(x * 255.0, 0.0, 255.0)


def convert(pth_path, out_path, tile_size=256, scale=4):
    sd = torch.load(pth_path, map_location="cpu", weights_only=True)
    sd = sd.get("params", sd)
    print(f"{pth_path}: 参数量 {sum(v.numel() for v in sd.values())/1e6:.2f} M  (x{scale})")

    model = UpCunet4xForCoreML() if scale == 4 else UpCunet2xForCoreML()
    model.load_state_dict(sd, strict=True)   # 结构对不上当场报错，不静默错配
    model.eval()

    example = torch.rand(1, 3, tile_size, tile_size)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

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
    convert(sys.argv[1], sys.argv[2],
            scale=int(sys.argv[3]) if len(sys.argv) > 3 else 4)
