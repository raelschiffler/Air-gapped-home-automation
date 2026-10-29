#!/usr/bin/env bash
set -Eeuo pipefail

CLIPS_DIR="${HOMEAUTO_DIR}/frigate/clips"

# Subscribe to frigate/events using mosquitto client *inside* the mosquitto container
docker exec -i mosquitto mosquitto_sub -t 'frigate/events' |
while IFS= read -r line; do
  # Payload is the whole line if mosquitto_sub wasn't run with -v; if it has "topic payload", strip topic
  case "$line" in
    *\ {*) payload="${line#* }" ;;  # "topic payload" -> keep payload
    *) payload="$line" ;;           # payload only
  esac

  # Use host python3 (already on Debian) – no extra packages – to parse JSON and publish
  python3 - "$CLIPS_DIR" <<'PY'
import sys, os, json, time, glob, subprocess
payload = sys.stdin.read()
CLIPS_DIR = sys.argv[1]

try:
    ev = json.loads(payload)
except Exception:
    sys.exit(0)

typ  = ev.get('type')
after = ev.get('after') or {}
has  = after.get('has_clip') or ev.get('has_clip')
cam  = after.get('camera')   or ev.get('camera')
eid  = after.get('id')       or ev.get('id')

# Only act when a clip is confirmed at the end of an event
if typ not in ('end','update') or not has or not cam or not eid:
    sys.exit(0)

# Try to locate the clip on disk by ID (robust across naming variants)
cands = []
cands += glob.glob(os.path.join(CLIPS_DIR, cam, f"*{eid}*.mp4"))
cands += glob.glob(os.path.join(CLIPS_DIR, f"*{eid}*.mp4"))
path = cands[0] if cands else ""

# If not found yet, fetch via Frigate API *inside* the frigate container using Python stdlib
if not path:
    out_host = os.path.join(CLIPS_DIR, cam, f"{eid}.mp4")
    os.makedirs(os.path.dirname(out_host), exist_ok=True)
    url  = f"http://127.0.0.1:5000/api/events/{eid}/clip.mp4"
    dstc = f"/media/frigate/clips/{cam}/{eid}.mp4"
    # Run a tiny urllib fetch inside the frigate container (no curl needed)
    cmd = [
        "docker","exec","frigate","python3","-c",
        f"import urllib.request,os; os.makedirs(os.path.dirname('{dstc}'),exist_ok=True); "
        f"urllib.request.urlretrieve('{url}','{dstc}')"
    ]
    subprocess.run(cmd, check=False)
    path = out_host if os.path.exists(out_host) else ""

if not path:
    sys.exit(0)

size = os.path.getsize(path)
msg = json.dumps({"type":"frigate_clip","camera":cam,"event_id":eid,"path":path,"size":size,"ts":int(time.time())})

# Publish via mosquitto client inside container
subprocess.run(["docker","exec","mosquitto","mosquitto_pub","-t","edge/media/new","-m",msg], check=False)
PY
done
