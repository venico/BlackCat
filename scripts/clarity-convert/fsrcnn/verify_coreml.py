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
