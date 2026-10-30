#!/bin/zsh
# Puts this checkout's web app (Web/) and station list (Data/stations.json) into a running server's config folder,
# without rebuilding its image. The server reads them again within a few seconds and open pages reload themselves.
# To go back to the image's own copies, delete them from the config folder.
#
#   scripts/push-config.sh <ssh host> [folder on the host with compose.yaml, default "interlude"] [web|stations]
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${1:?usage: scripts/push-config.sh <ssh host> [compose folder] [web|stations]}
DIR=${2:-interlude}
WHAT=${3:-all}
# The server runs as its own user, so the files must be readable by everyone.
ssh "$HOST" "mkdir -p '$DIR/config/web' && test -w '$DIR/config/web'" || {
  echo "Can't write to $DIR/config on $HOST. If Docker made it, run: ssh $HOST sudo chown -R \$USER '$DIR/config'" >&2; exit 1; }
if [[ $WHAT == all || $WHAT == web ]]; then
  rsync -a Web/index.html Web/app.css Web/app.js "$HOST:$DIR/config/web/"
  ssh "$HOST" "chmod a+r '$DIR'/config/web/*"
  echo "Updated the web app on $HOST. Open pages reload themselves."
fi
if [[ $WHAT == all || $WHAT == stations ]]; then
  python3 -c 'import json, sys; json.load(open(sys.argv[1]))' Data/stations.json
  rsync -a Data/stations.json "$HOST:$DIR/config/stations.json"
  ssh "$HOST" "chmod a+r '$DIR/config/stations.json'"
  echo "Updated the station list on $HOST. The server reads it within a few seconds."
fi
