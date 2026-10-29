#!/usr/bin/env python3
import os, time, json, requests, shutil, hashlib

FRIGATE = "http://127.0.0.1:5000"
BUS_ROOT = "/mnt/ssd/ipc"
OUT = os.path.join(BUS_ROOT, "out")
TMP = os.path.join(BUS_ROOT, "tmp")
MEDIA = os.path.join(BUS_ROOT, "media")

os.makedirs(OUT, exist_ok=True)
os.makedirs(TMP, exist_ok=True)
os.makedirs(MEDIA, exist_ok=True)

seen = set()  # track event ids we've exported this boot

def atomic_write(path, data_bytes):
    tmp_path = os.path.join(TMP, os.path.basename(path) + ".part")
    with open(tmp_path, "wb") as f:
        f.write(data_bytes)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)  # atomic

def fetch(url, dest):
    r = requests.get(url, timeout=5, stream=True)
    if not r.ok: return None
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        for chunk in r.iter_content(65536):
            if chunk: f.write(chunk)
    os.replace(tmp, dest)
    return dest

def loop():
    global seen
    last_ts = int(time.time()) - 60  # start with “last minute”
    while True:
        try:
            # pull recent events (limit up to you). You can filter per camera/label/zone.
            r = requests.get(f"{FRIGATE}/api/events?limit=25", timeout=5)
            if not r.ok:
                time.sleep(1); continue
            events = r.json()
            # newest first; we’ll process from oldest to newest for stable ordering
            for ev in reversed(events):
                ev_id = ev.get("id")
                if not ev_id or ev_id in seen: continue
                ts = int(ev.get("start_time", 0))
                if ts <= last_ts: continue

                cam = ev.get("camera")
                lbl = ev.get("label")
                zones = (ev.get("entered_zones") or
                         (ev.get("after") or {}).get("entered_zones") or [])
                top_score = (ev.get("top_score") or
                             (ev.get("after") or {}).get("top_score") or 0)

                # Decide if this is “serious” enough to export; adjust to taste
                serious = (lbl in ("person","car","dog")) and (top_score >= 0.7)

                # assemble media
                snap_rel = f"{ev_id}_snap.jpg"
                clip_rel = f"{ev_id}.mp4"
                snap_abs = os.path.join(MEDIA, snap_rel)
                clip_abs = os.path.join(MEDIA, clip_rel)

                # snapshot (bbox=1 draws the box)
                fetch(f"{FRIGATE}/api/events/{ev_id}/snapshot.jpg?bbox=1", snap_abs)

                # clip (may not exist if clip not ready or disabled)
                if ev.get("has_clip") or (ev.get("after") or {}).get("has_clip"):
                    fetch(f"{FRIGATE}/api/events/{ev_id}/clip.mp4", clip_abs)

                envelope = {
                    "type": "frigate_event",
                    "id": ev_id,
                    "camera": cam,
                    "label": lbl,
                    "zones": zones,
                    "top_score": top_score,
                    "serious": serious,
                    "start_time": ev.get("start_time"),
                    "end_time": ev.get("end_time"),
                    "snapshot": f"media/{snap_rel}" if os.path.exists(snap_abs) else None,
                    "clip": f"media/{clip_rel}" if os.path.exists(clip_abs) else None,
                }

                # filename: timestamp-id.json (atomic)
                name = f"{ts}-{ev_id}.json"
                atomic_write(os.path.join(OUT, name), json.dumps(envelope, ensure_ascii=False).encode())

                seen.add(ev_id)
                last_ts = max(last_ts, ts)

        except Exception as e:
            # keep going
            pass
        time.sleep(1)

if __name__ == "__main__":
    loop()
