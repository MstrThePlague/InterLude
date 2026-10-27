#!/bin/sh
# Installs the native libraries InterLudeML links on Linux (x86-64 or arm64), for the server image and CI, since
# Ubuntu packages neither: ONNX Runtime from Microsoft's release, with a pkg-config file, and whisper.cpp built from
# source for the CPU. Needs curl, cmake and build-essential.
set -eu
ORT_VERSION=1.31.1
WHISPER_VERSION=1.9.5
case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=aarch64 ;; *) echo "unsupported $(uname -m)"; exit 1 ;; esac
prefix=/usr/local
curl -fsSL "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-$arch-$ORT_VERSION.tgz" \
  | tar -xz -C /tmp
src=/tmp/onnxruntime-linux-$arch-$ORT_VERSION
mkdir -p $prefix/include/onnxruntime $prefix/lib/pkgconfig
cp -r $src/include/* $prefix/include/onnxruntime/
cp -P $src/lib/libonnxruntime.so* $prefix/lib/
cat > $prefix/lib/pkgconfig/libonnxruntime.pc <<PC
prefix=$prefix
Name: onnxruntime
Description: ONNX Runtime
Version: $ORT_VERSION
Cflags: -I\${prefix}/include/onnxruntime
Libs: -L\${prefix}/lib -lonnxruntime
PC
rm -rf $src

# whisper.cpp and the ggml it bundles, as shared libraries. GGML_NATIVE=OFF so the build runs on any x86-64 CPU,
# not just the build machine's.
curl -fsSL "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" | tar -xz -C /tmp
cmake -S /tmp/whisper.cpp-$WHISPER_VERSION -B /tmp/whisper-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_NATIVE=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_INSTALL_PREFIX=$prefix >/dev/null
cmake --build /tmp/whisper-build -j "$(nproc)" >/dev/null
cmake --install /tmp/whisper-build >/dev/null
# whisper.h includes ggml.h, so the Swift module for ggml needs a pkg-config file if the install didn't write one.
[ -f $prefix/lib/pkgconfig/ggml.pc ] || cat > $prefix/lib/pkgconfig/ggml.pc <<PC
prefix=$prefix
Name: ggml
Description: ggml, as bundled with whisper.cpp $WHISPER_VERSION
Version: $WHISPER_VERSION
Cflags: -I\${prefix}/include
Libs: -L\${prefix}/lib -lggml -lggml-base
PC
rm -rf /tmp/whisper.cpp-$WHISPER_VERSION /tmp/whisper-build
ldconfig
