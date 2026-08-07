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
