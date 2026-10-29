#!/usr/bin/env bash
set -Eeuo pipefail

# --- settings (override via env or EnvironmentFile) ---
LIMIT="${LIMIT:-10}"                                   # how many alerts to publish
FRIGATE_CONTAINER="${FRIGATE_CONTAINER:-frigate}"     # Frigate container name
MOSQ_CONTAINER="${MOSQ_CONTAINER:-mosquitto}"         # Mosquitto container name
LOG_FILE="${LOG_FILE:-${HOMEAUTO_DIR}/log/frigate_alerts_publisher.log}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"

# REQUIRED: provided by EnvironmentFile or exported beforehand
: "${MQTT_USER:?Set MQTT_USER in the unit EnvironmentFile}"
: "${MQTT_PASS:?Set MQTT_PASS in the unit EnvironmentFile}"

log(){ printf "%(%F %T)T frigate-alerts %s\n" -1 "$*" >> "$LOG_FILE"; }

# 1) Query Frigate locally (inside its container) for Alerts-like events
RAW="$(docker exec "${FRIGATE_CONTAINER}" sh -lc \
  "curl -s 'http://127.0.0.1:5000/api/events?has_clip=1&in_progress=0&limit=${LIMIT}'")" \
  || { log "curl failed"; exit 1; }

# 2) Normalize/minify the list (match UI semantics; avoid nulls)
JSON="$(jq -c '[ .[]
  | select(((.entered_zones // .zones // []) | length) > 0)
  | { id,
      camera,
      label: (.label // .sub_label // "object"),
      start_time, end_time,
      has_clip, has_snapshot,
      top_score: (.top_score // .score // 0),
      entered_zones: (.entered_zones // .zones // []),
      false_positive: (.false_positive // false)
    } ]' <<<"$RAW")" || { log "jq transform failed"; exit 1; }

# 2.5) Enrich each alert with a thumbnail (base64 data URL) fetched from Frigate HTTP
ENRICHED='[]'
# preserve order as returned by Frigate
while IFS= read -r id; do
  base="$(jq -c --arg id "$id" 'map(select(.id==$id))[0]' <<<"$JSON")"

  # get thumbnail bytes (may be empty if Frigate hasn't rendered it yet)
  b64="$(docker exec "${FRIGATE_CONTAINER}" sh -lc \
        "curl -s http://127.0.0.1:5000/api/events/${id}/thumbnail.jpg | base64 | tr -d '\n'" \
        || true)"

  if [ -n "$b64" ]; then
    base="$(jq -c --arg b64 "$b64" '. + {thumbnail: ("data:image/jpeg;base64," + $b64)}' <<<"$base")"
  else
    base="$(jq -c '. + {thumbnail: null}' <<<"$base")"
  fi

  ENRICHED="$(jq -c --argjson obj "$base" '. + [ $obj ]' <<<"$ENRICHED")"
done < <(jq -r '.[].id' <<<"$JSON")

JSON="$ENRICHED"


# 3) Publish retained to edge/frigate/alerts on the Pi5 broker
printf '%s' "$JSON" \
| docker exec -i "${MOSQ_CONTAINER}" sh -lc '
  tmp=/tmp/alerts.$RANDOM.json
  cat >"$tmp" && \
  mosquitto_pub -h "'"${MQTT_HOST}"'" -u "'"${MQTT_USER}"'" -P "'"${MQTT_PASS}"'" \
    -t frigate/alerts -q 1 -r -f "$tmp" && \
  rm -f "$tmp"
' \
&& log "published $(jq 'length' <<<"$JSON") alerts to frigate/alerts" \
|| { log "publish failed"; exit 1; }
