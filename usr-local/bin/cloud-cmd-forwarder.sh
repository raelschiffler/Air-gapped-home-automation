#!/usr/bin/env bash
set -Eeuo pipefail

MOSQ=mosquitto               # docker container name for mosquitto on Pi5
LOG_TAG="cloud-cmd-forwarder"

log(){ printf '%s [%s] %s\n' "$(date '+%F %T')" "$LOG_TAG" "$*" >&2; }

mqtt_sub(){  # subscribe inside the container
  docker exec -i "$MOSQ" sh -lc "exec mosquitto_sub -h 127.0.0.1 -u LasMariasAutomat -P "sBch9tj3QcC9w2" -v -t 'cloud/cmd/#' -R"
}
mqtt_pub(){  # publish inside the container
  local t="$1" m="${2-}"
  printf '%s' "$m" | docker exec -i mosquitto sh -lc "exec mosquitto_pub -h 127.0.0.1 -u LasMariasAutomat -P "sBch9tj3QcC9w2" -t \"$t\" -s"
  docker exec -i "$MOSQ" sh -lc "exec mosquitto_pub -h 127.0.0.1 -u LasMariasAutomat -P "sBch9tj3QcC9w2" -t \"$t\" -m \"$m\""
}

# Optional hooks (only used if present):
PTZ_HOOK=/usr/local/bin/ptz_preset.sh          # usage: ptz_preset.sh <camera> <preset_num>
CAPTURE_HOOK=/usr/local/bin/capture_last.sh    # usage: capture_last.sh <camera|ALL> <dur_sec>

# Dispatch: read cloud/cmd/# and act locally
log "starting; subscribing to cloud/cmd/#"
mqtt_sub | stdbuf -oL tr -d '\r' | while IFS= read -r line; do
  topic="${line%% *}"
  payload="${line#* }"
  case "$topic" in
    # cloud/cmd/zigbee2mqtt/<device>/set   ->   zigbee2mqtt/<device>/set  (payload passthrough)
    cloud/cmd/zigbee2mqtt/*/set)
      dev="${topic#cloud/cmd/zigbee2mqtt/}"; dev="${dev%/set}"
      log "Z2M set -> $dev : $payload"
      mqtt_pub "zigbee2mqtt/$dev/set" "$payload" || log "Z2M publish failed"
      ;;

    # Optional reads if you use them:
    cloud/cmd/zigbee2mqtt/*/get)
      dev="${topic#cloud/cmd/zigbee2mqtt/}"; dev="${dev%/get}"
      log "Z2M get -> $dev : $payload"
      mqtt_pub "zigbee2mqtt/$dev/get" "$payload" || log "Z2M publish failed"
      ;;

    # cloud/cmd/ptz/<camera>/preset   (payload is number "1..25")
    cloud/cmd/ptz/*/preset)
      cam="${topic#cloud/cmd/ptz/}"; cam="${cam%/preset}"
      log "PTZ preset -> $cam : $payload"
      if [[ -x "$PTZ_HOOK" ]]; then
        "$PTZ_HOOK" "$cam" "$payload" && log "PTZ hook OK" || log "PTZ hook FAILED"
      else
        log "PTZ hook missing ($PTZ_HOOK) — no-op"
      fi
      ;;

    # cloud/cmd/capture/<camera|ALL>/<dur>s  (e.g., .../entrance/30s)
    cloud/cmd/capture/*/*)
      rest="${topic#cloud/cmd/capture/}"
      cam="${rest%/*}"; dur="${rest##*/}"; dur="${dur%s}"
      log "CAPTURE -> $cam ${dur}s"
      if [[ -x "$CAPTURE_HOOK" ]]; then
        "$CAPTURE_HOOK" "$cam" "$dur" && log "CAPTURE hook OK" || log "CAPTURE hook FAILED"
      else
        log "CAPTURE hook missing ($CAPTURE_HOOK) — no-op"
      fi
      ;;

    # Placeholder for Atom Echo commands
    # cloud/cmd/atom_echo/<room>/tts   (payload = text)
    cloud/cmd/atom_echo/*/tts)
      room="${topic#cloud/cmd/atom_echo/}"; room="${room%/tts}"
      log "ATOM_ECHO tts -> $room : $payload"
      # TODO: add a hook (e.g., /usr/local/bin/atom_tts.sh "$room" "$payload")
      ;;

    # cloud/cmd/atom_echo/<room>/ir    (payload = JSON code or key)
    cloud/cmd/atom_echo/*/ir)
      room="${topic#cloud/cmd/atom_echo/}"; room="${room%/ir}"
      log "ATOM_ECHO IR -> $room : $payload"
      # TODO: add a hook for IR blasting via your Atom Echo/ESPHome
      ;;

    *)
      log "unhandled topic: $topic payload: $payload"
      ;;
  esac
done
