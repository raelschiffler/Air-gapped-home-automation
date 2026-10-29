#!/usr/bin/env bash
# Config — supply deployment-specific values through the environment.
FRIGATE="${FRIGATE:-http://127.0.0.1:5000}"
CAMERA="${CAMERA:-entrance}"
QUIET_SECS="${QUIET_SECS:-8}"           # how long with no in-progress events before return
CHECK_EVERY="${CHECK_EVERY:-2}"
CAM_IP="${CAM_IP:?Set CAM_IP in the service environment}"
USER="${CAM_USER:?Set CAM_USER in the service environment}"
PASS="${CAM_PASSWORD:?Set CAM_PASSWORD in the service environment}"

GOTO_URL="http://${CAM_IP}/cgi-bin/ptz.cgi?action=start&channel=1&code=GotoPreset&arg1=0&arg2=1&arg3=0"

idle_for=0
while true; do
  # Are there any in-progress events for this camera?
  inprog=$(curl -s "${FRIGATE}/api/events?camera=${CAMERA}&in_progress=true&limit=1" | jq 'length')
  if [[ "$inprog" -eq 0 ]]; then
    idle_for=$((idle_for + CHECK_EVERY))
    if [[ "$idle_for" -ge "$QUIET_SECS" ]]; then
      # Return to preset
      curl --digest -s -u "${USER}:${PASS}" "${GOTO_URL}" >/dev/null
      idle_for=0
    fi
  else
    idle_for=0
  fi
  sleep "$CHECK_EVERY"
done
