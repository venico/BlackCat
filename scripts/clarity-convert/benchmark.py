#!/usr/bin/env python3
import coremltools as ct
from PIL import Image
import time
import sys

scale = int(sys.argv[1])
model = ct.models.MLModel(f"RealESRGAN_x{scale}plus.mlpackage",
                           compute_units=ct.ComputeUnit.CPU_AND_GPU)

# 优先用 test_input_crop256.png，如果不存在则退回到 test_input.png + resize
try:
    img = Image.open("test_input_crop256.png").convert('RGB')
except FileNotFoundError:
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
