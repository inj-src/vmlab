#!/usr/bin/env bash
# Copy the tool lists cached by the last live connect to each VM into seed/ (shipped in the binary).
set -euo pipefail
cd "$(dirname "$0")/.."
cache=${VMLAB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/vmlab}
for m in win mac; do
  f=$cache/cua-tools-$m.json
  [[ -s $f ]] || { echo "no $f: connect to $m once first" >&2; exit 1; }
  python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); assert t and all("name" in x for x in t); print(sys.argv[1], len(t), "tools")' "$f"
  cp "$f" "seed/cua-tools-$m.json"
done
