import numpy as np
import torch
from fsrcnn_arch import FSRCNN

def load_from_npz(model: FSRCNN, npz_path: str):
    w = np.load(npz_path)
    layer_map = [
        ("feature", "act1", "f1", "b1", "alpha1"),
        ("shrink", "act2", "f2", "b2", "alpha2"),
        ("map1", "act3", "f3", "b3", "alpha3"),
        ("map2", "act4", "f4", "b4", "alpha4"),
        ("map3", "act5", "f5", "b5", "alpha5"),
        ("map4", "act6", "f6", "b6", "alpha6"),
        ("expand", "act7", "f7", "b7", "alpha7"),
    ]
    with torch.no_grad():
        for conv_name, act_name, f_key, b_key, alpha_key in layer_map:
            conv = getattr(model, conv_name)
            act = getattr(model, act_name)
            conv.weight.copy_(torch.from_numpy(w[f_key].transpose(3, 2, 0, 1).copy()))
            conv.bias.copy_(torch.from_numpy(w[b_key].copy()))
            act.weight.copy_(torch.from_numpy(w[alpha_key].copy()))
        # 最后一层没有 PReLU；out_conv 是 bias=False（见 fsrcnn_arch.py 里的说明），
        # b8 是加在 PixelShuffle 之后的标量，赋给 output_bias 而不是 out_conv.bias
        model.out_conv.weight.copy_(torch.from_numpy(w["f8"].transpose(3, 2, 0, 1).copy()))
        model.output_bias.copy_(torch.from_numpy(w["b8"].copy()))
    return model
