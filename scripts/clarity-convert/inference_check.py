import sys
import types

# --- Compat shim -----------------------------------------------------------
# torchvision >= 0.17 removed `torchvision.transforms.functional_tensor`
# (deprecated since 0.15). basicsr==1.4.2's degradations.py still does
# `from torchvision.transforms.functional_tensor import rgb_to_grayscale`,
# which raises ModuleNotFoundError with torch==2.5.1 / torchvision==0.20.1
# (the officially paired versions pinned in requirements.txt -- there is no
# newer torchvision with the old module, and downgrading would mean
# downgrading torch too). `rgb_to_grayscale` still exists, unchanged, in
# `torchvision.transforms.functional`, so we register a tiny shim module
# that re-exports it under the old name before basicsr is imported.
import torchvision.transforms.functional as _tv_functional
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    _shim = types.ModuleType('torchvision.transforms.functional_tensor')
    _shim.rgb_to_grayscale = _tv_functional.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor'] = _shim
# --- End compat shim ---------------------------------------------------------

import torch
from basicsr.archs.rrdbnet_arch import RRDBNet
from PIL import Image
import numpy as np

def load_model(pth_path, scale):
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

def run_inference(model, input_path, output_path):
    img = Image.open(input_path).convert('RGB')
    arr = np.array(img).astype(np.float32) / 255.0
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        out = model(tensor)
    out = out.squeeze(0).permute(1, 2, 0).clamp(0, 1).numpy()
    out_img = Image.fromarray((out * 255).round().astype(np.uint8))
    out_img.save(output_path)
    print(f"{input_path} ({img.size}) -> {output_path} ({out_img.size})")
    return img.size, out_img.size

if __name__ == '__main__':
    scale = int(sys.argv[1])  # 2 或 4
    pth = f"x{scale}plus.pth"
    model = load_model(pth, scale)
    in_size, out_size = run_inference(model, "test_input.png", f"baseline_x{scale}.png")
    expected = (in_size[0] * scale, in_size[1] * scale)
    assert out_size == expected, f"输出尺寸不对：期望 {expected}，实际 {out_size}"
    print(f"x{scale} 验证通过：尺寸放大 {scale} 倍")
