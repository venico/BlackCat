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
