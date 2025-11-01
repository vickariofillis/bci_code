#!/usr/bin/env bash
# get_results.sh
# Packages EXACTLY /local/data/results/super, after renaming super_run.log -> super_run_<tag>.log,
# and serves a DIRECT download URL: http://<IP>:8080/data/results/super/super_<tag>.tgz

set -Eeuo pipefail

SUPER_DIR="/local/data/results/super"
BASE_DIR="/local/data/results"
SERVE_ROOT="/local"   # web root for python http.server
PORT="8080"

# --- Sanity checks ----------------------------------------------------------
[[ -d "$SUPER_DIR" ]] || { echo "ERROR: Missing: $SUPER_DIR"; exit 1; }

reqs=(python3 tar awk hostname)
for c in "${reqs[@]}"; do
  command -v "$c" >/dev/null || { echo "ERROR: '$c' not found. Ensure startup scripts install it."; exit 2; }
done

# --- Prompt for tag and sanitize --------------------------------------------
cd "$SUPER_DIR"
read -rp "Append tag for super_run.log (e.g., id1_2): " TAG_RAW
TAG="${TAG_RAW// /_}"
TAG="${TAG//\//_}"
TAG="${TAG:-untagged}"

# --- Rename super_run.log -> super_run_<tag>.log (no overwrite) -------------
if [[ -f "super_run.log" ]]; then
  TARGET="super_run_${TAG}.log"
  if [[ -e "$TARGET" ]]; then
    echo "ERROR: ${TARGET} already exists. Choose a different tag."
    exit 3
  fi
  echo "Renaming super_run.log -> ${TARGET}"
  sudo mv -v "super_run.log" "$TARGET"
else
  echo "INFO: super_run.log not found; proceeding without rename."
fi

# --- Create archive inside SUPER_DIR (NO TIMESTAMP in name) -----------------
ARCHIVE="super_${TAG}.tgz"
if [[ -e "$ARCHIVE" ]]; then
  read -rp "'$ARCHIVE' exists. Overwrite? [y/N]: " OVER
  if [[ "${OVER,,}" != "y" ]]; then
    echo "Aborted to avoid overwrite."
    exit 4
  fi
  sudo rm -f -- "$ARCHIVE"
fi

echo "Packaging ${SUPER_DIR} → ${SUPER_DIR}/${ARCHIVE} ..."
sudo tar -C "$BASE_DIR" -czf "${SUPER_DIR}/${ARCHIVE}" super

# --- Serve from /local and print DIRECT URL ---------------------------------
IP="$(hostname -I | awk '{print $1}')"
URL="http://${IP}:${PORT}/data/results/super/${ARCHIVE}"

echo
echo "Download → ${URL}"
echo "Press Ctrl-C after the download completes to stop the server."
echo

cd "$SERVE_ROOT"
python3 -m http.server "${PORT}"
