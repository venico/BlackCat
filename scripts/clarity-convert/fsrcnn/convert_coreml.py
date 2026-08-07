import sys
import torch
import coremltools as ct
from fsrcnn_arch import FSRCNN
from load_weights import load_from_npz

def convert(scale, tile_size=256):
    model = FSRCNN(scale_factor=scale)
    load_from_npz(model, f"FSRCNN_x{scale}_weights.npz")
    model.eval()

    example_input = torch.rand(1, 1, tile_size, tile_size)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_y", shape=example_input.shape)],
        outputs=[ct.TensorType(name="output_y")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    out_path = f"FSRCNN_x{scale}.mlpackage"
    mlmodel.save(out_path)
    print(f"已保存 {out_path}")

if __name__ == "__main__":
    convert(int(sys.argv[1]))
