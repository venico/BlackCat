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
        # bias=False：Task 1 排查确认，官方权重的 b8 不是这层卷积的 per-channel
        # bias（那样 shape 应该是 scale²，比如 x4 是 16），而是加在 PixelShuffle
        # 之后的最终单通道输出上的一个标量——两种写法数值等价，但 PyTorch 的
        # nn.Conv2d.bias 长度必须等于 out_channels，装不下这个标量，必须分开处理
        self.out_conv = nn.Conv2d(56, scale_factor * scale_factor, kernel_size=1, bias=False)
        self.pixel_shuffle = nn.PixelShuffle(scale_factor)
        self.output_bias = nn.Parameter(torch.zeros(1))

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
        x = x + self.output_bias
        return x
