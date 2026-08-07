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
