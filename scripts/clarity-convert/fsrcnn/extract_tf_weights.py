import tensorflow as tf
import numpy as np
import sys

scale = int(sys.argv[1])
with tf.io.gfile.GFile(f"FSRCNN_x{scale}.pb", "rb") as f:
    graph_def = tf.compat.v1.GraphDef()
    graph_def.ParseFromString(f.read())

weights = {}
for node in graph_def.node:
    if node.op == "Const":
        try:
            t = tf.make_ndarray(node.attr["value"].tensor)
            if t.size > 1 or node.name.startswith(("f", "b", "alpha")):
                weights[node.name] = t
        except Exception:
            continue

expected_keys = [f"f{i}" for i in range(1, 9)] + [f"b{i}" for i in range(1, 9)] + [f"alpha{i}" for i in range(1, 8)]
missing = [k for k in expected_keys if k not in weights]
assert not missing, f"缺少预期的权重键: {missing}，实际提取到: {list(weights.keys())}"

np.savez(f"FSRCNN_x{scale}_weights.npz", **weights)
print(f"已保存 FSRCNN_x{scale}_weights.npz，共 {len(weights)} 个数组")
for k in expected_keys:
    print(f"  {k}: {weights[k].shape}")
