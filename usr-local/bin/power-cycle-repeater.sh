#!/usr/bin/env bash
set -euo pipefail

: "${MQTT_HOST:?}" "${MQTT_USER:?}" "${MQTT_PASS:?}" \
  "${MQTT_PUBLISH_TOPIC:?}" "${MQTT_STATE_TOPIC:?}" "${OFF_DELAY:?}"

ts(){ date +"[%Y-%m-%dT%H:%M:%S%z]"; }

# Publish via stdin (-s) to avoid any quoting issues. QoS 1 for reliability.
_pub() {
  local payload="$1"
  printf '%s' "$payload" | docker exec -i mosquitto sh -lc \
    "mosquitto_pub -q 1 -h '${MQTT_HOST}' -u '${MQTT_USER}' -P '${MQTT_PASS}' -t '${MQTT_PUBLISH_TOPIC}' -s"
}

# Wait for a single state message that matches the wanted value
wait_for_state() {
  local want="$1"; local timeout="${2:-8}"
  docker exec mosquitto sh -lc \
    "mosquitto_sub -h '${MQTT_HOST}' -u '${MQTT_USER}' -P '${MQTT_PASS}' -t '${MQTT_STATE_TOPIC}' -W $timeout -C 1" \
  | grep -q "\"state\":\"$want\""
}

echo "[$(date --iso-8601=seconds)] Powering OFF"
_pub '{"state":"OFF"}' || { echo "$(ts) ERROR publishing OFF" >&2; exit 1; }

if ! wait_for_state "OFF" 8; then
  echo "$(ts) WARN no OFF echo; retrying once"
  _pub '{"state":"OFF"}' || true
  wait_for_state "OFF" 8 || echo "$(ts) WARN still no OFF confirmation"
fi

sleep "${OFF_DELAY}"

echo "$(ts) Powering ON"
_pub '{"state":"ON"}' || { echo "$(ts) ERROR publishing ON" >&2; exit 1; }

if ! wait_for_state "ON" 8; then
  echo "$(ts) WARN no ON echo; retrying once"
  _pub '{"state":"ON"}' || true
  wait_for_state "ON" 8 || echo "$(ts) WARN still no ON confirmation"
fi
