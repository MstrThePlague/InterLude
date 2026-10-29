#!/bin/zsh
# Updates the web app's page on a running server without rebuilding the image. It takes the page from
# Sources/InterLudeCore/Remote.swift and copies it into the server's data volume, where it replaces the built-in page
# until an image built after it is started. Reload the page in the browser to see it.
#
#   scripts/push-web.sh <ssh host> [folder on the host with compose.yaml, default "interlude"]
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${1:?usage: scripts/push-web.sh <ssh host> [compose folder]}
DIR=${2:-interlude}
PAGE=$(mktemp)
trap 'rm -f "$PAGE"' EXIT
python3 - "$PAGE" <<'EOF'
import sys
s = open("Sources/InterLudeCore/Remote.swift", encoding="utf-8").read()
start = s.index('static let html = #"""\n') + len('static let html = #"""\n')
open(sys.argv[1], "w", encoding="utf-8").write(s[start:s.index('\n"""#', start)])
EOF
scp -q "$PAGE" "$HOST:/tmp/interlude-index.html"
ssh "$HOST" "cd '$DIR' && docker compose exec -T interlude mkdir -p /var/lib/interlude/web \
  && docker compose cp /tmp/interlude-index.html interlude:/var/lib/interlude/web/index.html && rm /tmp/interlude-index.html"
echo "Updated the page on $HOST. Reload it in the browser."
