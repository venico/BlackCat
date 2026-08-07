import sys
import types

# --- Compat shim (same as Task 1's inference_check.py / convert_coreml.py) --
import torchvision.transforms.functional as _tv_functional
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    _shim = types.ModuleType('torchvision.transforms.functional_tensor')
    _shim.rgb_to_grayscale = _tv_functional.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor'] = _shim
# --- End compat shim ---------------------------------------------------------

import coremltools as ct
import torch
import numpy as np
from PIL import Image
from basicsr.archs.rrdbnet_arch import RRDBNet

CROP_SIZE = 256


def load_pytorch_model(pth_path, scale):
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                     num_block=23, num_grow_ch=32, scale=scale)
    state_dict = torch.load(pth_path, map_location='cpu')
    if 'params_ema' in state_dict:
        state_dict = state_dict['params_ema']
    elif 'params' in state_dict:
        state_dict = state_dict['params']
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model


def center_crop(img, size):
    w, h = img.size
    left = (w - size) // 2
    top = (h - size) // 2
    return img.crop((left, top, left + size, top + size))


def run_pytorch(model, img):
    arr = np.array(img).astype(np.float32) / 255.0
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        out = model(tensor)
    out = out.squeeze(0).permute(1, 2, 0).clamp(0, 1).numpy()
    return Image.fromarray((out * 255).round().astype(np.uint8))


def compare(img_a, img_b, label):
    a = np.array(img_a).astype(np.float32)
    b = np.array(img_b).astype(np.float32)
    assert a.shape == b.shape, f"{label} 尺寸不一致: {a.shape} vs {b.shape}"
    diff = np.abs(a - b)
    mae = diff.mean()
    max_err = diff.max()
    mse = ((a - b) ** 2).mean()
    psnr = 10 * np.log10((255.0 ** 2) / mse) if mse > 0 else float('inf')
    print(f"[{label}] MAE={mae:.3f} (0-255 scale)  MaxAbsErr={max_err:.1f}  PSNR={psnr:.2f}dB")
    return mae, max_err, psnr


if __name__ == '__main__':
    scale = int(sys.argv[1])

    # 用中心裁切（不是拉伸）生成跟 Swift 端未来 tile 逻辑语义一致的测试输入，
    # 同时也让基准对比在几何上站得住脚（brief 原始的 resize((256,256)) 会把
    # 270x480 的图挤压变形，和 baseline_x4/x2.png 用的原始比例对不上）。
    src = Image.open("test_input.png").convert('RGB')
    crop = center_crop(src, CROP_SIZE)
    crop.save(f"test_input_crop{CROP_SIZE}.png")

    # --- CoreML 推理（对应 brief Step 3）---
    model = ct.models.MLModel(f"RealESRGAN_x{scale}plus.mlpackage")
    result = model.predict({"input": crop})
    out_img = result["output"]
    # coremltools 9.0 returns the ImageType output as RGBA (mode="RGBA") even
    # though color_layout=RGB was requested at conversion time -- a known
    # quirk of the PIL wrapping around the underlying CVPixelBuffer, not a
    # correctness issue with the model itself (alpha is fully opaque).
    # Convert to RGB so it's directly comparable to the RGB baseline images.
    out_img = out_img.convert('RGB')
    out_img.save(f"coreml_output_x{scale}.png")
    expected_size = (CROP_SIZE * scale, CROP_SIZE * scale)
    print(f"CoreML x{scale} 输出尺寸: {out_img.size}，期望: {expected_size}")
    assert out_img.size == expected_size, "尺寸不对"
    print("验证通过（尺寸）")

    # --- 用同一份裁切图跑原始 PyTorch 模型，作为逐像素可比的基准 ---
    # （Task 1 的 baseline_x4.png/baseline_x2.png 是对整张 270x480 图跑的，
    # 直接跟这里 256x256 裁切的 CoreML 输出比较没有意义；这里额外生成一份
    # 跟 CoreML 输入完全一致的 PyTorch 基准，做真正同输入的数值/视觉对比）
    pt_model = load_pytorch_model(f"x{scale}plus.pth", scale)
    pt_out = run_pytorch(pt_model, crop)
    pt_out.save(f"baseline_crop_x{scale}.png")
    print(f"PyTorch(同输入裁切) x{scale} 输出尺寸: {pt_out.size}")

    compare(out_img, pt_out, f"CoreML vs PyTorch(同输入裁切) x{scale}")
