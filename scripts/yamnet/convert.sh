#!/bin/sh
# Makes yamnet.onnx and yamnet_class_map.csv in the directory given (default Models/), using Docker.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-Models}" && cd "${1:-Models}" && pwd)
docker run --rm -v "$here:/work:ro" -v "$out:/out" python:3.11-slim sh -c \
  "pip install -q tensorflow-cpu==2.15.1 tensorflow-hub==0.16.1 tf2onnx==1.16.1 onnxruntime==1.17.3 'numpy<2' && python /work/convert.py /out"
