# syntax=docker/dockerfile:1.7
# interlude-server: InterLude as a web app on a Linux host. See compose.yaml for how it is run.

FROM swift:6.2-noble AS build
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
COPY --from=build /interlude-server /usr/local/bin/interlude-server
COPY Data/stations.json /usr/share/interlude/stations.json
COPY Web /usr/share/interlude/web
ADD --checksum=sha256:d016c1230496ee59f3f5b01c16cce4cc01b5a1d3d357adec200c908b131ebe49 \
    https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js /usr/share/interlude/web/hls.min.js
RUN chmod 644 /usr/share/interlude/web/hls.min.js
USER interlude
VOLUME /var/lib/interlude
EXPOSE 8642
ENTRYPOINT ["interlude-server"]
CMD ["--port", "8642", "--data", "/var/lib/interlude"]
