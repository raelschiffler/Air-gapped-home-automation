#!/usr/bin/env bash
set -euo pipefail

LIST="${1:-${LIST:-./missing_ids.txt}}"
OUT_DIR="${2:-${OUT_DIR:-./thumbs_from_frigate}}"
FRIGATE_CONTAINER="${FRIGATE_CONTAINER:-frigate}"

# Remote destination for fetched thumbnails
PI4_HOST="${PI4_HOST:?Set PI4_HOST for your deployment}"
PI4_THUMBS_DIR="${PI4_THUMBS_DIR:?Set PI4_THUMBS_DIR for your deployment}"

mkdir -p "$OUT_DIR"

count=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  [ -s "$OUT_DIR/$id.jpg" ] && continue
  if docker exec "$FRIGATE_CONTAINER" sh -lc \
      "curl -fsS http://127.0.0.1:5000/api/events/$id/thumbnail.jpg" \
      > "$OUT_DIR/$id.jpg" 2>/dev/null; then
    count=$((count+1))
  else
    rm -f "$OUT_DIR/$id.jpg"
  fi
done < "$LIST"

echo "Fetched $count thumbs to $OUT_DIR"
if ls "$OUT_DIR"/*.jpg >/dev/null 2>&1; then
  scp -q "$OUT_DIR"/*.jpg "${PI4_HOST}:${PI4_THUMBS_DIR}/"
  echo "Pushed to ${PI4_HOST}:${PI4_THUMBS_DIR}/"
fi
