#!/usr/bin/env bash
set -euo pipefail

: "${MQTT_HOST:?}" "${MQTT_USER:?}" "${MQTT_PASS:?}" "${Z2M_PREFIX:?}" "${SWITCH_FRIENDLY:?}" "${TARGETS:?}"

ts(){ date +"[%Y-%m-%dT%H:%M:%S%z]"; }

_pub_json() {
  local topic="$1" json="$2"
  docker exec -i mosquitto mosquitto_pub \
    -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$topic" -m "$json"
}

_sub_switch() {
  docker exec -i mosquitto mosquitto_sub \
    -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "${Z2M_PREFIX}/${SWITCH_FRIENDLY}"
}

echo "$(ts) z2m-link: starting; following ${Z2M_PREFIX}/${SWITCH_FRIENDLY} → $TARGETS"

# Subscribe forever, restart on transient errors
while true; do
  _sub_switch | while IFS= read -r line; do
    # Zigbee2MQTT usually emits JSON like {"state":"ON", ...}
    state=""
    if [[ "$line" == \{* ]]; then
      state="$(jq -r 'try .state // empty' <<<"$line" 2>/dev/null || true)"
    else
      case "$line" in
        ON|OFF) state="$line" ;;
      esac
    fi

    [[ -z "$state" ]] && continue

    case "$state" in
      ON|OFF)
        for tgt in $TARGETS; do
          _pub_json "${Z2M_PREFIX}/${tgt}/set" "{\"state\":\"${state}\"}"
        done
        echo "$(ts) z2m-link: ${SWITCH_FRIENDLY}=${state} → (${TARGETS})"
        ;;
      *) : ;; # ignore other states
    esac
  done

  echo "$(ts) z2m-link: mosquitto_sub ended; retrying in 3s..."
  sleep 3
done
