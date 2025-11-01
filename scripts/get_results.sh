#!/usr/bin/env bash
# get_results.sh
# - Auto-detect workload folder under /local/data/results/super (e.g., id1, id20_rnn, …)
# - Prompts you for ANY tag to append (e.g., "2", "2a", "my_notes")
#   → final tag = <workload>_<your_tag>
# - Renames super_run.log → super_run_<tag>.log (no overwrite)
# - Creates super_<tag>.tgz containing EXACTLY the 'super' directory (stable snapshot)
# - Prints a DIRECT download URL and serves /local so you can click it immediately

set -Eeuo pipefail

SUPER_DIR="/local/data/results/super"
BASE_DIR="/local/data/results"
SERVE_ROOT="/local"   # http server web root
PORT="8080"

# --- Sanity checks ----------------------------------------------------------
[[ -d "$SUPER_DIR" ]] || { echo "ERROR: Missing: $SUPER_DIR"; exit 1; }

reqs=(python3 tar awk hostname cp find)
for c in "${reqs[@]}"; do
  command -v "$c" >/dev/null || { echo "ERROR: '$c' not found. Ensure startup scripts/images provide it."; exit 2; }
done

# --- Discover workload folder(s) under 'super' ------------------------------
mapfile -t WORKLOADS < <(find "$SUPER_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

if (( ${#WORKLOADS[@]} == 0 )); then
  echo "ERROR: No workload folder found under $SUPER_DIR (e.g., id1, id20_rnn)."
  exit 3
elif (( ${#WORKLOADS[@]} == 1 )); then
  WORKLOAD="${WORKLOADS[0]}"
  echo "Detected workload: ${WORKLOAD}"
else
  echo "Multiple workloads detected:"
  for i in "${!WORKLOADS[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${WORKLOADS[$i]}"
  done
  read -rp "Select workload [1-${#WORKLOADS[@]}] (default 1): " CHOICE
  CHOICE="${CHOICE:-1}"
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#WORKLOADS[@]} )); then
    echo "Invalid selection."
    exit 4
  fi
  WORKLOAD="${WORKLOADS[$((CHOICE-1))]}"
  echo "Selected workload: ${WORKLOAD}"
fi

# --- Prompt for ANY tag text to append (not just numbers) -------------------
cd "$SUPER_DIR"
read -rp "Append tag (e.g., 2, 2a, my_notes): " SUFFIX_RAW
SUFFIX="${SUFFIX_RAW// /_}"
SUFFIX="${SUFFIX//\//_}"
[[ -n "$SUFFIX" ]] || { echo "ERROR: tag cannot be empty."; exit 5; }

TAG="${WORKLOAD}_${SUFFIX}"

# --- Rename super_run.log -> super_run_<tag>.log (no overwrite) ------------
if [[ -f "super_run.log" ]]; then
  TARGET="super_run_${TAG}.log"
  if [[ -e "$TARGET" ]]; then
    echo "ERROR: ${TARGET} already exists. Choose a different tag."
    exit 6
  fi
  echo "Renaming super_run.log -> ${TARGET}"
  sudo mv -v "super_run.log" "$TARGET"
else
  echo "INFO: super_run.log not found; proceeding without rename."
fi

# --- Create archive (WITHOUT timestamp) on a stable snapshot ----------------
ARCHIVE="super_${TAG}.tgz"
if [[ -e "$SUPER_DIR/$ARCHIVE" ]]; then
  read -rp "'$ARCHIVE' already exists. Overwrite? [y/N]: " OVER
  if [[ "${OVER,,}" != "y" ]]; then
    echo "Aborted to avoid overwrite."
    exit 7
  fi
  sudo rm -f -- "$SUPER_DIR/$ARCHIVE"
fi

# Snapshot /local/data/results/super to /tmp to avoid "file changed as we read it"
TMP_ROOT="$(mktemp -d /tmp/getres.XXXXXX)"
SNAP_DIR="${TMP_ROOT}/snap"
sudo mkdir -p "$SNAP_DIR"
sudo cp -a "$BASE_DIR/super" "$SNAP_DIR/"

TMP_ARCHIVE="${TMP_ROOT}/${ARCHIVE}"
echo "Packaging snapshot → ${SUPER_DIR}/${ARCHIVE} ..."
sudo tar -C "$SNAP_DIR" -czf "$TMP_ARCHIVE" super
sudo mv -f "$TMP_ARCHIVE" "$SUPER_DIR/$ARCHIVE"
sudo rm -rf "$TMP_ROOT"

# --- Serve from /local and print DIRECT URL --------------------------------
IP="$(hostname -I | awk '{print $1}')"
URL="http://${IP}:${PORT}/data/results/super/${ARCHIVE}"

echo
echo "Download → ${URL}"
echo "Press Ctrl-C after the download completes to stop the server."
echo

cd "$SERVE_ROOT"
python3 -m http.server "${PORT}"
