#!/usr/bin/env bash
set -Eeuo pipefail

CLIPS_DIR="${HOMEAUTO_DIR}/frigate/clips"

docker exec -i mosquitto mosquitto_sub -t 'cloud/cmd/event_clip' |
while IFS= read -r payload; do
  # Parse event_id & camera with host python (no jq)
  python3 - "$CLIPS_DIR" <<'PY'
import sys, os, json, time, glob, subprocess
CLIPS_DIR = sys.argv[1]
try:
    req = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

eid = req.get("event_id")
cam = req.get("camera")
if not eid or not cam:
    sys.exit(0)

# Try to find existing clip
import glob
cands = glob.glob(os.path.join(CLIPS_DIR, cam, f"*{eid}*.mp4")) + glob.glob(os.path.join(CLIPS_DIR, f"*{eid}*.mp4"))
path = cands[0] if cands else ""

# If missing, fetch via Frigate API inside container
if not path:
    out_host = os.path.join(CLIPS_DIR, cam, f"{eid}.mp4")
    os.makedirs(os.path.dirname(out_host), exist_ok=True)
    url  = f"http://127.0.0.1:5000/api/events/{eid}/clip.mp4"
    dstc = f"/media/frigate/clips/{cam}/{eid}.mp4"
    subprocess.run(["docker","exec","frigate","python3","-c",
                    f"import urllib.request,os; os.makedirs(os.path.dirname('{dstc}'),exist_ok=True); "
                    f"urllib.request.urlretrieve('{url}','{dstc}')"], check=False)
    path = out_host if os.path.exists(out_host) else ""

if not path:
    sys.exit(0)

size = os.path.getsize(path)
msg = json.dumps({"type":"frigate_clip","camera":cam,"event_id":eid,"path":path,"size":size,"ts":int(time.time())})
subprocess.run(["docker","exec","mosquitto","mosquitto_pub","-t","edge/media/new","-m",msg], check=False)
PY
done
