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
# (Same shim as inference_check.py from Task 1 -- reused verbatim since it
# was already reviewed and confirmed to be a precise, side-effect-free fix.)
import torchvision.transforms.functional as _tv_functional
if 'torchvision.transforms.functional_tensor' not in sys.modules:
    _shim = types.ModuleType('torchvision.transforms.functional_tensor')
    _shim.rgb_to_grayscale = _tv_functional.rgb_to_grayscale
    sys.modules['torchvision.transforms.functional_tensor'] = _shim
# --- End compat shim ---------------------------------------------------------

import torch
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet
import basicsr.archs.rrdbnet_arch as _rrdbnet_arch_module

# --- pixel_unshuffle static-shape patch --------------------------------------
# basicsr's pixel_unshuffle() (used by RRDBNet.forward only on the scale=2
# branch; the scale=4 branch skips it entirely -- confirmed x4plus converts
# fine with the unpatched function) does:
#     b, c, hh, hw = x.size()
#     ...
#     x_view = x.view(b, c, h, scale, w, scale)
# Under torch.jit.trace (torch==2.5.1), the batch/spatial dims pulled from
# x.size() get recorded as dynamic-shape ops (`aten::size` + `aten::Int`)
# instead of baked-in constants (visible as a TracerWarning: "Converting a
# tensor to a Python boolean might cause the trace to be incorrect", pointing
# at the `assert hh % scale == 0` line). coremltools==9.0's MIL frontend then
# fails translating that `aten::Int` node:
#     TypeError: only 0-dimensional arrays can be converted to Python scalars
# Since we always trace at one fixed, known static shape anyway (CoreML
# models require static input shape -- that's the whole premise of this
# conversion), there is no dynamic-shape behavior worth preserving here. This
# patch replaces pixel_unshuffle with a version that uses plain Python ints
# (batch=1, channels=3, spatial=tile_size -- all known at trace time) instead
# of tensor-derived sizes, producing an identical reshape/permute result for
# our actual input but with a fully static graph. Scoped as a module patch
# (not an edit to the installed basicsr package) so it's easy to see/revert.
def _make_static_pixel_unshuffle(tile_size):
    def _static_pixel_unshuffle(x, scale):
        b, c, hh, hw = 1, 3, tile_size, tile_size
        out_channel = c * (scale ** 2)
        h = hh // scale
        w = hw // scale
        x_view = x.view(b, c, h, scale, w, scale)
        return x_view.permute(0, 1, 3, 5, 2, 4).reshape(b, out_channel, h, w)
    return _static_pixel_unshuffle
# --- End pixel_unshuffle static-shape patch ----------------------------------


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


class _RRDBNetForCoreML(torch.nn.Module):
    """Wraps RRDBNet to scale its raw [0,1]-ish output into [0,255] before
    tracing.

    RRDBNet's forward() returns raw conv output with no final clamp/scale --
    the reference PyTorch postprocessing (inference_check.py) does
    `.clamp(0, 1)` then `* 255` by hand after calling the model. coremltools'
    ImageType *output* conversion does NOT insert any equivalent scale/bias
    (confirmed by reading converters/mil/backend/mil/load.py:
    get_func_output() -- for ImageType outputs it only attaches a color-space
    / shape descriptor to the raw output var, it never rescales values).
    ImageType input preprocessing (scale=1/255.0 in convert()) is a real,
    separate feature (see insert_image_preprocessing_op.py) that only applies
    to inputs. Without this wrapper, the ~[0,1]-valued output tensor gets
    written directly as 0-255 pixel intensities, producing a near-black image
    (empirically confirmed: raw traced output range was
    [-0.047, 1.069] on the test crop, and the resulting coreml_output_x4.png
    before this fix was almost entirely black).
    """

    def __init__(self, base_model):
        super().__init__()
        self.base_model = base_model

    def forward(self, x):
        out = self.base_model(x)
        out = torch.clamp(out, 0.0, 1.0) * 255.0
        return out


def convert(scale, tile_size=256):
    # Patch pixel_unshuffle to a static-shape equivalent before tracing (see
    # comment above) -- only exercised by the scale=2 forward path, no-op for
    # scale=4 which never calls it.
    _rrdbnet_arch_module.pixel_unshuffle = _make_static_pixel_unshuffle(tile_size)

    model = load_model(f"x{scale}plus.pth", scale)
    wrapped = _RRDBNetForCoreML(model)
    wrapped.eval()
    example_input = torch.rand(1, 3, tile_size, tile_size)
    traced = torch.jit.trace(wrapped, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example_input.shape,
                              scale=1/255.0, bias=[0, 0, 0],
                              color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    out_path = f"RealESRGAN_x{scale}plus.mlpackage"
    mlmodel.save(out_path)
    print(f"已保存 {out_path}")
    return out_path


if __name__ == '__main__':
    scale = int(sys.argv[1])
    convert(scale)
