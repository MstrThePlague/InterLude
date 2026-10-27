# Converts Google's YAMNet (Apache 2.0) from TensorFlow Hub to ONNX for interlude-server, and checks that ONNX Runtime
# gives the same scores as TensorFlow. Run by scripts/yamnet/convert.sh inside a throwaway Python container.
import csv, sys
import numpy as np
import tensorflow as tf
import tensorflow_hub as hub
import tf2onnx
import onnxruntime as ort
from tensorflow.python.framework.convert_to_constants import convert_variables_to_constants_v2

out = sys.argv[1]
model = hub.load("https://tfhub.dev/google/yamnet/1")

@tf.function(input_signature=[tf.TensorSpec([None], tf.float32, name="waveform")])
def scores(waveform):
    s, _, _ = model(waveform)
    return tf.identity(s, name="scores")

# Freeze the weights into the graph, so the ONNX model's only input is the waveform.
frozen = convert_variables_to_constants_v2(scores.get_concrete_function())
tf2onnx.convert.from_graph_def(frozen.graph.as_graph_def(), input_names=["waveform:0"],
                               output_names=[t.name for t in frozen.outputs], opset=17, output_path=out + "/yamnet.onnx")
with open(out + "/yamnet_class_map.csv", "w") as f:
    f.write(tf.io.read_file(model.class_map_path()).numpy().decode())

# The same 20 s of noise and tones through both, as a check that the conversion kept the front end and the network.
rng = np.random.default_rng(1)
t = np.arange(16000 * 20) / 16000
wave = (0.1 * rng.standard_normal(t.size) + 0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
want = scores(tf.constant(wave)).numpy()
session = ort.InferenceSession(out + "/yamnet.onnx")
print("inputs", [(i.name, i.shape) for i in session.get_inputs()], "outputs", [(o.name, o.shape) for o in session.get_outputs()])
got = session.run(None, {session.get_inputs()[0].name: wave})[0]
print("frames", want.shape, got.shape, "max abs diff", float(np.abs(want - got).max()))
assert want.shape == got.shape and np.abs(want - got).max() < 1e-3
