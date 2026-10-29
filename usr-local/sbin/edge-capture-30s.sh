#!/usr/bin/env bash
set -Eeuo pipefail

MAP="${HOMEAUTO_DIR}/frigate/rtsp.map"
OUT_HOST="${HOMEAUTO_DIR}/frigate/recordings/on_demand"    # host path
OUT_CONT="/media/frigate/recordings/on_demand"               # container path

mkdir -p "$OUT_HOST"

url_for() { awk '!/^#/ && NF>=2 { if ($1=="'"$1"'") { $1=""; sub(/^ +/,""); print; exit } }' "$MAP"; }

# Subscribe to capture commands via mosquitto container
docker exec -i mosquitto mosquitto_sub -v -t 'cloud/cmd/capture/+/30s' |
while read -r topic payload; do
  cam="${topic#cloud/cmd/capture/}"; cam="${cam%/30s}"
  if [[ "$cam" == "ALL" ]]; then
    # fan-out using retained map
    while read -r c; do
      [[ -z "$c" ]] && continue
      docker exec mosquitto mosquitto_pub -t "cloud/cmd/capture/$c/30s" -n
    done < <(awk '!/^#/ && NF>=2 {print $1}' "$MAP")
    continue
  fi

  url="$(url_for "$cam")"
  [[ -z "$url" ]] && continue

  ts=$(date +%s)
  base="${cam}-${ts}.mp4"
  outc="${OUT_CONT}/${base}"
  outh="${OUT_HOST}/${base}"

  # Use frigate container's ffmpeg to fetch 30s
  docker exec frigate sh -lc \
    "mkdir -p '$OUT_CONT' && ffmpeg -y -rtsp_transport tcp -stimeout 10000000 -i '$url' -t 30 -c copy '$outc' >/dev/null 2>&1" || continue

  size=$(stat -c%s "$outh" 2>/dev/null || echo 0)
  msg=$(python3 - <<PY
import json, time
print(json.dumps({"type":"capture_30s","camera":"$cam","path":"$outh","size":$size,"ts":$ts}))
PY
)
  docker exec mosquitto mosquitto_pub -t 'edge/media/new' -m "$msg"
done
