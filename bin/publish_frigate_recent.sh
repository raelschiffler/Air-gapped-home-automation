#!/usr/bin/env bash
set -Eeuo pipefail

# --- settings (override via env or EnvironmentFile) ---
LIMIT="${LIMIT:-10}"                                   # how many recent events
FRIGATE_CONTAINER="${FRIGATE_CONTAINER:-frigate}"     # Frigate container
MOSQ_CONTAINER="${MOSQ_CONTAINER:-mosquitto}"         # Mosquitto container
LOG_FILE="${LOG_FILE:-${HOMEAUTO_DIR}/log/frigate_recent_publisher.log}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"

# REQUIRED (from EnvironmentFile)
: "${MQTT_USER:?Set MQTT_USER in the unit EnvironmentFile}"
: "${MQTT_PASS:?Set MQTT_PASS in the unit EnvironmentFile}"

log(){ printf "%(%F %T)T recent-publisher %s\n" -1 "$*" >> "$LOG_FILE"; }

# 1) Pull last N finished events (regardless of zones), newest first
RAW="$(docker exec "${FRIGATE_CONTAINER}" sh -lc \
  "curl -fsS 'http://127.0.0.1:5000/api/events?has_clip=1&in_progress=0&limit=${LIMIT}'")" \
  || { log "curl events failed"; exit 1; }

# 2) Normalize + keep minimal fields
BASE="$(jq -c '[ .[]
  | { id, camera,
      label: (.label // .sub_label // "object"),
      start_time, end_time,
      has_clip, has_snapshot
    } ]' <<<"$RAW")" || { log "jq normalize failed"; exit 1; }

# 3) For each id, fetch snapshot thumb and embed as data URL (base64)
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
jq -r '.[].id' <<<"$BASE" | while read -r id; do
  # Snapshot endpoint works well for thumbnails
  docker exec "${FRIGATE_CONTAINER}" sh -lc \
    "curl -fsS 'http://127.0.0.1:5000/api/events/${id}/snapshot.jpg'" \
    | base64 -w0 > "${TMPDIR}/${id}.b64" || true
done

# Build augmented JSON with .thumbnail when available
AUG="$(
  jq -c --arg dir "$TMPDIR" '
    map(. + ( if ( input_filename | . ) then {} else {} end )) as $arr
    | $arr
    | map( . + (
        ( $ENV | .id ) as $id
      ) )' <<<"$BASE" 2>/dev/null || true
)"

# Simpler merge: walk BASE and add thumbnail if we downloaded it
AUG="$(
  jq -c --arg tmp "$TMPDIR" '
    map( . + (
      ( (try (input_filename) catch null) | . ) as $x
      | {}
    ) )' <<<"$BASE" 2>/dev/null || true
)"

# (Busybox jq merge hack is brittle; do a shell loop instead)
OUT="["; first=1
while read -r row; do
  id=$(jq -r .id <<<"$row")
  if [ -s "${TMPDIR}/${id}.b64" ]; then
    b64=$(cat "${TMPDIR}/${id}.b64")
    row=$(jq -c --arg t "data:image/jpeg;base64,${b64}" '. + {thumbnail:$t}' <<<"$row")
  fi
  if [ $first -eq 1 ]; then OUT="${OUT}${row}"; first=0; else OUT="${OUT},${row}"; fi
done < <(jq -c '.[]' <<<"$BASE")
OUT="${OUT}]"

# 4) Publish retained to frigate/recent
printf '%s' "$OUT" \
| docker exec -i "${MOSQ_CONTAINER}" sh -lc '
  tmp=/tmp/recent.$RANDOM.json
  cat >"$tmp" && \
  mosquitto_pub -h "'"${MQTT_HOST}"'" -u "'"${MQTT_USER}"'" -P "'"${MQTT_PASS}"'" \
    -t frigate/recent -q 1 -r -f "$tmp" && \
  rm -f "$tmp"
' \
&& log "published $(jq 'length' <<<"$OUT") events to frigate/recent" \
|| { log "publish failed"; exit 1; }
