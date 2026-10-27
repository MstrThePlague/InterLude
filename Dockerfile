# syntax=docker/dockerfile:1.7
# interlude-server: InterLude as a web app on a Linux host. See compose.yaml for how it is run.

# YAMNet, converted from TensorFlow Hub to ONNX and checked against TensorFlow. Cached, so it runs once.
FROM python:3.11-slim AS yamnet
COPY scripts/yamnet /work
RUN pip install -q tensorflow-cpu==2.15.1 tensorflow-hub==0.16.1 tf2onnx==1.16.1 onnxruntime==1.17.3 'numpy<2' \
 && mkdir /models && python /work/convert.py /models

FROM swift:6.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config curl cmake build-essential && rm -rf /var/lib/apt/lists/*
COPY scripts/install-linux-deps.sh /tmp/
RUN /tmp/install-linux-deps.sh
WORKDIR /src
# Resolve dependencies first, so editing the sources doesn't refetch them.
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product interlude-server --static-swift-stdlib \
 && cp "$(swift build -c release --show-bin-path)/interlude-server" /interlude-server

FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates libcurl4 libxml2 tzdata \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home-dir /var/lib/interlude interlude \
 && mkdir -p /var/lib/interlude && chown interlude:interlude /var/lib/interlude
COPY --from=build /usr/local/lib/libonnxruntime.so* /usr/local/lib/libwhisper.so* /usr/local/lib/libggml*.so* /usr/local/lib/
RUN ldconfig
COPY --from=build /interlude-server /usr/local/bin/interlude-server
COPY --from=yamnet /models /usr/share/interlude/models
# whisper.cpp's base English model (MIT), for the newsreader's opening and sign-off.
ADD --checksum=sha256:a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002 \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin /usr/share/interlude/models/ggml-base.en.bin
COPY Resources/Ambience /usr/share/interlude/ambience
COPY Data/stations.json /usr/share/interlude/stations.json
COPY Web /usr/share/interlude/web
# hls.js plays the stream in browsers without HLS of their own; qrcode-generator draws Settings' QR code. Both MIT.
ADD --checksum=sha256:d016c1230496ee59f3f5b01c16cce4cc01b5a1d3d357adec200c908b131ebe49 \
    https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js /usr/share/interlude/web/hls.min.js
ADD --checksum=sha256:18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780 \
    https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js /usr/share/interlude/web/qrcode.js
# ADD leaves downloads readable by root only, and the server runs as its own user.
RUN chmod 644 /usr/share/interlude/web/* /usr/share/interlude/models/*
USER interlude
VOLUME /var/lib/interlude
EXPOSE 8642
ENTRYPOINT ["interlude-server"]
CMD ["--port", "8642", "--data", "/var/lib/interlude"]
