#!/usr/bin/env bash
# Strict mode + propagate ERR into functions, subshells, and pipelines
set -Eeuo pipefail
# --- Root + tmux (bci) auto-wrap (safe attach-or-create) ---
# Absolute path to this script for safe re-exec
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REAL="${SCRIPT_DIR}/$(basename "$0")"

# Ensure root so the tmux server/session are root-owned
if [[ $EUID -ne 0 ]]; then
  exec sudo -E env -u TMUX BCI_TMUX_AUTOWRAP=1 "$SCRIPT_REAL" "$@"
fi

# tmux must be available before we try to use it
command -v tmux >/dev/null || { echo "ERROR: tmux not installed/in PATH"; exit 2; }

# If not already inside tmux, enter/prepare the 'bci' session
if [[ -z ${TMUX:-} && -n ${BCI_TMUX_AUTOWRAP:-} ]]; then
  if tmux has-session -t bci 2>/dev/null; then
    # Session exists: create a new window running THIS script, then attach
    win="bci-$(basename "$0")-$$"
    tmux new-window -t bci -n "$win" "$SCRIPT_REAL" "$@"
    if [[ -t 1 ]]; then
      exec tmux attach -t bci \; select-window -t "$win"
    else
      # Non-interactive caller (e.g., CI/cron): do not attach
      exit 0
    fi
  else
    # No session: create it and run THIS script as the first window
    if [[ -t 1 ]]; then
      exec tmux new-session -s bci -n "bci-$(basename "$0")" "$SCRIPT_REAL" "$@"
    else
      tmux new-session -d -s bci -n "bci-$(basename "$0")" "$SCRIPT_REAL" "$@"
      exit 0
    fi
  fi
fi
unset BCI_TMUX_AUTOWRAP || true
# --- end auto-wrap ---
set -o errtrace

# Resolve script directory (for sourcing helpers.sh colocated with the script)

# Source helpers if available; otherwise provide a minimal fallback on_error
if [[ -f "${SCRIPT_DIR}/helpers.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/helpers.sh"
else
  on_error() {
    local ec=$?
    # ${BASH_LINENO[0]} is the line in caller; ${BASH_SOURCE[1]} is the caller file.
    echo "ERROR: '${BASH_COMMAND}' failed (exit ${ec}) at ${BASH_SOURCE[1]}:${BASH_LINENO[0]}" >&2
    exit "${ec}"
  }
fi

# Install error trap
trap on_error ERR

# Lightweight guard for required executables
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command '$1' not found"; exit 1; }; }

# Example prereq checks (adjust per script needs)
require_cmd git
require_cmd sudo
require_cmd tee
require_cmd make

BCI_REPO_URL=${BCI_REPO_URL:-https://github.com/vickariofillis/bci_code.git}
BCI_REPO_REF=${BCI_REPO_REF:-main}
BCI_REPO_DIR=${BCI_REPO_DIR:-/local/bci_code}
BCI_SKIP_CLONE=${BCI_SKIP_CLONE:-0}
BCI_CANONICAL_REPO_LINK=/local/bci_code
BCI_ID13_CONFIG_FILE=${BCI_ID13_CONFIG_FILE:-}
ID13_RUNTIME_ENV_FILE=${ID13_RUNTIME_ENV_FILE:-/local/config/id13_runtime.env}

STARTUP_LOG_DIR=/local/logs
STARTUP_LOG_PATH=${STARTUP_LOG_DIR}/startup.log
STARTUP_DONE_PATH=${STARTUP_LOG_DIR}/startup.done
STARTUP_FAILED_PATH=${STARTUP_LOG_DIR}/startup.failed

mkdir -p "${STARTUP_LOG_DIR}"
rm -f "${STARTUP_DONE_PATH}" "${STARTUP_FAILED_PATH}"
exec > >(tee -a "${STARTUP_LOG_PATH}") 2>&1

startup_on_error() {
  local ec=$?
  echo "ERROR: '${BASH_COMMAND}' failed (exit ${ec}) at ${BASH_SOURCE[1]}:${BASH_LINENO[0]}" >&2
  touch "${STARTUP_FAILED_PATH}" 2>/dev/null || true
  exit "${ec}"
}

trap startup_on_error ERR

is_truthy() {
  case "${1:-}" in
    1|on|true|yes|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_bci_repo() {
  local repo_dir="${BCI_REPO_DIR}"
  local repo_parent
  repo_parent="$(dirname "${repo_dir}")"
  mkdir -p "${repo_parent}"

  if is_truthy "${BCI_SKIP_CLONE}"; then
    [[ -d "${repo_dir}/.git" ]] || {
      echo "ERROR: BCI_SKIP_CLONE is set but ${repo_dir} is not a git checkout" >&2
      exit 1
    }
    echo "Using existing BCI checkout at ${repo_dir} (BCI_SKIP_CLONE=${BCI_SKIP_CLONE})"
  else
    if [[ -d "${repo_dir}/.git" ]]; then
      echo "Refreshing existing BCI checkout at ${repo_dir}"
      git -C "${repo_dir}" fetch --tags origin "${BCI_REPO_REF}" || git -C "${repo_dir}" fetch --tags origin
    else
      echo "Cloning ${BCI_REPO_URL} into ${repo_dir}"
      git clone "${BCI_REPO_URL}" "${repo_dir}"
    fi

    if ! git -C "${repo_dir}" checkout "${BCI_REPO_REF}"; then
      git -C "${repo_dir}" checkout -B "${BCI_REPO_REF}" "origin/${BCI_REPO_REF}"
    fi
  fi

  if [[ "${repo_dir}" != "${BCI_CANONICAL_REPO_LINK}" ]]; then
    ln -sfn "${repo_dir}" "${BCI_CANONICAL_REPO_LINK}"
  fi
}

# Ensure required variables will be defined later in this script.
tracked_vars=(
  ID13_LICENSE_MODE
  USERNAME
  PASSWORD
  VPN_SERVER
  LICENSE_SERVER
  MLM_PORT
  ID13_LICENSE_PROXY_HOST
  ID13_LICENSE_PROXY_PORT
  ID13_LICENSE_RELAY_HOST
)
missing=()
declare -A final_assignments

if [[ -n "${BCI_ID13_CONFIG_FILE}" ]]; then
  if [[ ! -f "${BCI_ID13_CONFIG_FILE}" ]]; then
    echo "ERROR: BCI_ID13_CONFIG_FILE=${BCI_ID13_CONFIG_FILE} does not exist" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${BCI_ID13_CONFIG_FILE}"
fi

id13_resolve_license_mode() {
  local requested="${1:-auto}"
  local hw_model="${2:-unknown}"

  requested="$(printf '%s' "${requested}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${requested}" ]] && requested="auto"

  case "${requested}" in
    auto)
      if is_c6620_family "${hw_model}"; then
        if [[ -n "${ID13_LICENSE_RELAY_HOST:-}" ]]; then
          printf 'relay\n'
        elif [[ -n "${ID13_LICENSE_PROXY_HOST:-}" || -n "${ID13_LICENSE_PROXY_PORT:-}" ]]; then
          printf 'proxy\n'
        else
          echo "ID13_LICENSE_MODE=auto on ${hw_model} requires ID13_LICENSE_RELAY_HOST or explicit ID13_LICENSE_MODE=pptp/proxy." >&2
          return 2
        fi
      else
        printf 'pptp\n'
      fi
      ;;
    pptp|proxy|relay)
      printf '%s\n' "${requested}"
      ;;
    *)
      echo "Unsupported ID13_LICENSE_MODE='${requested}'. Expected auto, pptp, proxy, or relay." >&2
      return 2
      ;;
  esac
}

id13_required_vars_for_mode() {
  case "${1:-pptp}" in
    proxy)
      printf '%s\n' "ID13_LICENSE_PROXY_HOST ID13_LICENSE_PROXY_PORT"
      ;;
    relay)
      printf '%s\n' "LICENSE_SERVER MLM_PORT ID13_LICENSE_RELAY_HOST"
      ;;
    *)
      printf '%s\n' "USERNAME PASSWORD VPN_SERVER LICENSE_SERVER MLM_PORT"
      ;;
  esac
}

for var in "${tracked_vars[@]}"; do
  if [[ -n ${!var:-} ]]; then
    final_assignments["$var"]="${var}=$(printf '%q' "${!var}")"
  fi
done

# Determine the line after which user configuration should appear. We
# look for the marker comment and search only within the explicit user
# configuration stanza, stopping before the normal script constants.
# This avoids treating later runtime-env assignments as saved config.
script_path="${BASH_SOURCE[0]}"
start_line=$(grep -n '^# === User configuration ===' "$script_path" | cut -d: -f1 | head -n1)
start_line=${start_line:-1}

for var in "${tracked_vars[@]}"; do
  if [[ -n ${final_assignments[$var]:-} ]]; then
    continue
  fi
  assignment=$(awk -v start="$start_line" '
    NR <= start { next }
    /^DOWNLOAD_DIR=/ { exit }
    { print }
  ' "$script_path" | \
    grep -E "^[[:space:]]*${var}=" | head -n1 | sed 's/^[[:space:]]*//') || true
  if [[ -n ${assignment:-} ]]; then
    final_assignments["$var"]="$assignment"
  else
    missing+=("$var")
  fi
done

for var in "${tracked_vars[@]}"; do
  if [[ -n ${final_assignments[$var]:-} ]]; then
    eval "${final_assignments[$var]}"
  fi
done

ID13_HW_MODEL="$(detect_hw_model)"
license_mode_requested=""
mode_resolution_error=""
if ! license_mode_requested="$(id13_resolve_license_mode "${ID13_LICENSE_MODE:-auto}" "${ID13_HW_MODEL}" 2>&1)"; then
  mode_resolution_error="${license_mode_requested}"
  license_mode_requested=""
fi

required_vars=()
if [[ -z "${mode_resolution_error}" ]]; then
  read -r -a required_vars <<<"$(id13_required_vars_for_mode "${license_mode_requested}")"
fi

missing=()
for var in "${required_vars[@]}"; do
  if [[ -z ${!var:-} ]]; then
    missing+=("$var")
  fi
done

if [[ -n "${mode_resolution_error}" || ${#missing[@]} -gt 0 ]]; then
  if [[ ! -t 0 ]]; then
    [[ -n "${mode_resolution_error}" ]] && echo "ERROR: ${mode_resolution_error}" >&2
    if (( ${#missing[@]} )); then
      echo "ERROR: Missing ID13 startup configuration: ${missing[*]}" >&2
    fi
    echo "Provide USERNAME, PASSWORD, VPN_SERVER, LICENSE_SERVER, and MLM_PORT for PPTP mode; LICENSE_SERVER, MLM_PORT, and ID13_LICENSE_RELAY_HOST for relay mode; or ID13_LICENSE_PROXY_HOST and ID13_LICENSE_PROXY_PORT for proxy mode." >&2
    exit 1
  fi

  [[ -n "${mode_resolution_error}" ]] && echo "Configuration error: ${mode_resolution_error}"
  echo "The ID13 license configuration values are missing or incomplete. Please provide them."
  echo "Enter each value as VAR=VALUE and paste them all at once."
  echo "Use a trailing \\ at the end of a line to continue input if desired."

  config_lines=()
  while true; do
    if ! IFS= read -r line; then
      break
    fi
    config_lines+=("$line")
    [[ "$line" == *\\ ]] || break
  done

  if (( ${#config_lines[@]} == 0 )); then
    echo "No configuration input received. Aborting." >&2
    exit 1
  fi

  for raw_line in "${config_lines[@]}"; do
    sanitized=$(printf '%s\n' "$raw_line" |
      sed -E 's/[[:space:]]*\\[[:space:]]*$//' |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$sanitized" ]] && continue

    if [[ "$sanitized" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      var_name="${BASH_REMATCH[1]}"
      value_part="${BASH_REMATCH[2]}"
      assignment="${var_name}=${value_part}"
      final_assignments["$var_name"]="$assignment"
    else
      echo "Invalid assignment provided: $sanitized" >&2
      exit 1
    fi
  done

  for var in "${tracked_vars[@]}"; do
    if [[ -n ${final_assignments[$var]:-} ]]; then
      eval "${final_assignments[$var]}"
    fi
  done

  license_mode_requested=""
  mode_resolution_error=""
  if ! license_mode_requested="$(id13_resolve_license_mode "${ID13_LICENSE_MODE:-auto}" "${ID13_HW_MODEL}" 2>&1)"; then
    mode_resolution_error="${license_mode_requested}"
    license_mode_requested=""
  fi

  required_vars=()
  if [[ -z "${mode_resolution_error}" ]]; then
    read -r -a required_vars <<<"$(id13_required_vars_for_mode "${license_mode_requested}")"
  fi

  if [[ -n "${mode_resolution_error}" ]]; then
    echo "${mode_resolution_error}" >&2
    exit 1
  fi

  for var in "${required_vars[@]}"; do
    if [[ -z ${final_assignments[$var]:-} ]]; then
      echo "Missing assignment for $var. Please try again." >&2
      exit 1
    fi
  done

  config_block=""
  for var in "${tracked_vars[@]}"; do
    if [[ -n ${final_assignments[$var]:-} ]]; then
      config_block+="${final_assignments[$var]}"$'\n'
    fi
  done

  if [[ -z "$config_block" ]]; then
    echo "Failed to construct configuration block." >&2
    exit 1
  fi

  export CONFIG_BLOCK="$config_block"
  required_csv=$(IFS=,; echo "${required_vars[*]}")
  python3 - "$script_path" "$required_csv" <<'PY'
import os
import re
import sys

path = sys.argv[1]
required = [name for name in sys.argv[2].split(',') if name]
block_lines = [line for line in os.environ.get("CONFIG_BLOCK", "").splitlines() if line]

with open(path, encoding="utf-8") as fh:
    data = fh.read()

marker_pattern = re.compile(r'^# === User configuration ===\s*$', re.MULTILINE)
match = marker_pattern.search(data)
if not match:
    sys.exit("User configuration marker not found.")

line_end = match.end()
if line_end < len(data) and data[line_end] == '\n':
    line_end += 1

prefix = data[:line_end]
rest = data[line_end:]

lines = rest.splitlines(True)

i = 0
while i < len(lines) and lines[i].strip() == "":
    i += 1
start = i

j = i
while j < len(lines):
    stripped = lines[j].strip()
    if stripped == "":
        j += 1
        continue
    if any(stripped.startswith(f"{name}=") for name in required):
        lines.pop(j)
        continue
    break

insert_lines = [line + "\n" for line in block_lines]
if insert_lines:
    if start < len(lines) and lines[start].strip():
        insert_lines.append("\n")
    lines[start:start] = insert_lines

new_content = prefix + "".join(lines)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_content)
PY
  unset CONFIG_BLOCK

  echo "Configuration saved to $(basename "$script_path")."
  echo "Restarting with saved configuration..."
  exec "$script_path" "$@"
fi

for var in "${tracked_vars[@]}"; do
  if [[ -n ${final_assignments[$var]:-} ]]; then
    eval "export ${final_assignments[$var]}"
  fi
done

ID13_LICENSE_MODE_REQUESTED="${ID13_LICENSE_MODE:-auto}"
if ! ID13_LICENSE_MODE="$(id13_resolve_license_mode "${ID13_LICENSE_MODE_REQUESTED}" "${ID13_HW_MODEL}" 2>&1)"; then
  echo "ERROR: ${ID13_LICENSE_MODE}" >&2
  exit 1
fi

ID13_LICENSE_SERVER_TARGET="${LICENSE_SERVER:-}"
ID13_MLM_PORT_TARGET="${MLM_PORT:-}"
ID13_EFFECTIVE_LICENSE_SERVER="${LICENSE_SERVER:-}"
ID13_EFFECTIVE_MLM_PORT="${MLM_PORT:-}"

if [[ "${ID13_LICENSE_MODE}" == "proxy" ]]; then
  ID13_EFFECTIVE_LICENSE_SERVER="${ID13_LICENSE_PROXY_HOST}"
  ID13_EFFECTIVE_MLM_PORT="${ID13_LICENSE_PROXY_PORT}"
fi

ID13_SUPPORT_BUNDLE_ROOT=${ID13_SUPPORT_BUNDLE_ROOT:-/local/logs/id13_support}
ID13_PPTP_DIAG_ROOT=${ID13_PPTP_DIAG_ROOT:-/local/logs/id13_pptp_diag}
ID13_BUNDLE_STAMP="$(date +%Y%m%d_%H%M%S)"
ID13_SUPPORT_BUNDLE_DIR="${ID13_SUPPORT_BUNDLE_ROOT}/${ID13_BUNDLE_STAMP}_${ID13_LICENSE_MODE}"
ID13_PPTP_DIAG_DIR=""
ID13_PPTP_EGRESS_IFACE=""
ID13_PPTP_ROUTE_SRC=""
ID13_PPTP_VPN_IP=""
ID13_PPTP_TCP_1723_STATUS="not_checked"
ID13_PPTP_GRE_TX="unknown"
ID13_PPTP_GRE_RX="unknown"
ID13_PPTP_PPP0_PRESENT="0"
ID13_PPTP_PPP0_IPV4="0"
ID13_PPTP_TCPDUMP_PID=""
ID13_PPTP_FAILURE_REASON=""

mkdir -p "${ID13_SUPPORT_BUNDLE_DIR}"

id13_write_support_context() {
  cat >"${ID13_SUPPORT_BUNDLE_DIR}/license_context.env" <<EOF
ID13_HW_MODEL=$(printf '%q' "${ID13_HW_MODEL}")
ID13_LICENSE_MODE_REQUESTED=$(printf '%q' "${ID13_LICENSE_MODE_REQUESTED}")
ID13_LICENSE_MODE=$(printf '%q' "${ID13_LICENSE_MODE}")
ID13_EFFECTIVE_LICENSE_SERVER=$(printf '%q' "${ID13_EFFECTIVE_LICENSE_SERVER}")
ID13_EFFECTIVE_MLM_PORT=$(printf '%q' "${ID13_EFFECTIVE_MLM_PORT}")
ID13_LICENSE_SERVER_TARGET=$(printf '%q' "${ID13_LICENSE_SERVER_TARGET}")
ID13_MLM_PORT_TARGET=$(printf '%q' "${ID13_MLM_PORT_TARGET}")
ID13_LICENSE_PROXY_HOST=$(printf '%q' "${ID13_LICENSE_PROXY_HOST:-}")
ID13_LICENSE_PROXY_PORT=$(printf '%q' "${ID13_LICENSE_PROXY_PORT:-}")
ID13_LICENSE_RELAY_HOST=$(printf '%q' "${ID13_LICENSE_RELAY_HOST:-}")
ID13_SUPPORT_BUNDLE_DIR=$(printf '%q' "${ID13_SUPPORT_BUNDLE_DIR}")
ID13_PPTP_DIAG_DIR=$(printf '%q' "${ID13_PPTP_DIAG_DIR}")
EOF
}

id13_write_result_summary() {
  local result="$1"
  local message="$2"
  cat >"${ID13_SUPPORT_BUNDLE_DIR}/result.env" <<EOF
ID13_RESULT=$(printf '%q' "${result}")
ID13_RESULT_MESSAGE=$(printf '%q' "${message}")
ID13_LICENSE_MODE=$(printf '%q' "${ID13_LICENSE_MODE}")
ID13_HW_MODEL=$(printf '%q' "${ID13_HW_MODEL}")
ID13_PPTP_DIAG_DIR=$(printf '%q' "${ID13_PPTP_DIAG_DIR}")
EOF
}

id13_stop_pptp_tcpdump() {
  [[ -z "${ID13_PPTP_TCPDUMP_PID}" ]] && return 0
  kill "${ID13_PPTP_TCPDUMP_PID}" >/dev/null 2>&1 || true
  wait "${ID13_PPTP_TCPDUMP_PID}" 2>/dev/null || true
  ID13_PPTP_TCPDUMP_PID=""
}

id13_prepare_pptp_diag_bundle() {
  ID13_PPTP_DIAG_DIR="${ID13_PPTP_DIAG_ROOT}/${ID13_BUNDLE_STAMP}_${ID13_LICENSE_MODE}"
  mkdir -p "${ID13_PPTP_DIAG_DIR}"
  id13_write_support_context
  echo "→ ID13 PPTP diagnostics bundle: ${ID13_PPTP_DIAG_DIR}"

  uname -a >"${ID13_PPTP_DIAG_DIR}/uname.txt" 2>&1 || true
  printf '%s\n' "${ID13_HW_MODEL}" >"${ID13_PPTP_DIAG_DIR}/hardware_model.txt"
  ip addr >"${ID13_PPTP_DIAG_DIR}/ip_addr.txt" 2>&1 || true
  ip route >"${ID13_PPTP_DIAG_DIR}/ip_route.txt" 2>&1 || true
  ip -4 route get "${VPN_SERVER}" >"${ID13_PPTP_DIAG_DIR}/ip_route_get_vpn.txt" 2>&1 || true

  ID13_PPTP_EGRESS_IFACE="$(bci_detect_egress_interface "${VPN_SERVER}" || true)"
  ID13_PPTP_ROUTE_SRC="$(bci_detect_route_source_ipv4 "${VPN_SERVER}" || true)"
  ID13_PPTP_VPN_IP="$(getent ahostsv4 "${VPN_SERVER}" | awk 'NR==1{print $1}' || true)"

  if command -v nc >/dev/null 2>&1; then
    if timeout 8 nc -vz "${VPN_SERVER}" 1723 >"${ID13_PPTP_DIAG_DIR}/tcp_1723_check.txt" 2>&1; then
      ID13_PPTP_TCP_1723_STATUS="ok"
    else
      ID13_PPTP_TCP_1723_STATUS="failed"
    fi
  else
    ID13_PPTP_TCP_1723_STATUS="nc_unavailable"
    echo "nc unavailable" >"${ID13_PPTP_DIAG_DIR}/tcp_1723_check.txt"
  fi

  if [[ -n "${ID13_PPTP_EGRESS_IFACE}" ]]; then
    if command -v ethtool >/dev/null 2>&1; then
      ethtool -i "${ID13_PPTP_EGRESS_IFACE}" >"${ID13_PPTP_DIAG_DIR}/ethtool_i.txt" 2>&1 || true
      ethtool -k "${ID13_PPTP_EGRESS_IFACE}" >"${ID13_PPTP_DIAG_DIR}/ethtool_k.txt" 2>&1 || true
      ethtool -c "${ID13_PPTP_EGRESS_IFACE}" >"${ID13_PPTP_DIAG_DIR}/ethtool_c.txt" 2>&1 || true
      ethtool -S "${ID13_PPTP_EGRESS_IFACE}" >"${ID13_PPTP_DIAG_DIR}/ethtool_S.txt" 2>&1 || true
      bci_collect_ice_ddp_snapshot "${ID13_PPTP_EGRESS_IFACE}" "${ID13_PPTP_DIAG_DIR}/ice_ddp"
    fi
    if command -v tcpdump >/dev/null 2>&1; then
      timeout 45 tcpdump -nn -i "${ID13_PPTP_EGRESS_IFACE}" 'tcp port 1723 or ip proto 47' \
        >"${ID13_PPTP_DIAG_DIR}/tcpdump.txt" \
        2>"${ID13_PPTP_DIAG_DIR}/tcpdump.stderr" &
      ID13_PPTP_TCPDUMP_PID=$!
    fi
  fi
}

id13_finalize_pptp_diag_bundle() {
  id13_stop_pptp_tcpdump

  if ip link show ppp0 >"${ID13_PPTP_DIAG_DIR}/ppp0_link.txt" 2>&1; then
    ID13_PPTP_PPP0_PRESENT="1"
  fi
  if ip -4 addr show dev ppp0 >"${ID13_PPTP_DIAG_DIR}/ppp0_ipv4.txt" 2>&1; then
    if grep -q 'inet ' "${ID13_PPTP_DIAG_DIR}/ppp0_ipv4.txt"; then
      ID13_PPTP_PPP0_IPV4="1"
    fi
  fi

  if [[ -f "${ID13_PPTP_DIAG_DIR}/tcpdump.txt" && -n "${ID13_PPTP_ROUTE_SRC}" && -n "${ID13_PPTP_VPN_IP}" ]]; then
    ID13_PPTP_GRE_TX="$(grep -Fc "IP ${ID13_PPTP_ROUTE_SRC} > ${ID13_PPTP_VPN_IP}: GRE" "${ID13_PPTP_DIAG_DIR}/tcpdump.txt" || true)"
    ID13_PPTP_GRE_RX="$(grep -Fc "IP ${ID13_PPTP_VPN_IP} > ${ID13_PPTP_ROUTE_SRC}: GRE" "${ID13_PPTP_DIAG_DIR}/tcpdump.txt" || true)"
  fi

  cat >"${ID13_PPTP_DIAG_DIR}/summary.env" <<EOF
ID13_HW_MODEL=$(printf '%q' "${ID13_HW_MODEL}")
ID13_PPTP_EGRESS_IFACE=$(printf '%q' "${ID13_PPTP_EGRESS_IFACE}")
ID13_PPTP_ROUTE_SRC=$(printf '%q' "${ID13_PPTP_ROUTE_SRC}")
ID13_PPTP_VPN_IP=$(printf '%q' "${ID13_PPTP_VPN_IP}")
ID13_PPTP_TCP_1723_STATUS=$(printf '%q' "${ID13_PPTP_TCP_1723_STATUS}")
ID13_PPTP_GRE_TX=$(printf '%q' "${ID13_PPTP_GRE_TX}")
ID13_PPTP_GRE_RX=$(printf '%q' "${ID13_PPTP_GRE_RX}")
ID13_PPTP_PPP0_PRESENT=$(printf '%q' "${ID13_PPTP_PPP0_PRESENT}")
ID13_PPTP_PPP0_IPV4=$(printf '%q' "${ID13_PPTP_PPP0_IPV4}")
ID13_PPTP_FAILURE_REASON=$(printf '%q' "${ID13_PPTP_FAILURE_REASON}")
EOF
  id13_write_support_context
}

id13_fail_pptp_mode() {
  local message="$1"
  ID13_PPTP_FAILURE_REASON="${message}"
  id13_finalize_pptp_diag_bundle
  if is_c6620_family "${ID13_HW_MODEL}"; then
    echo "ERROR: ${message}. This likely indicates a native PPTP/GRE path issue on ${ID13_HW_MODEL}; see ${ID13_PPTP_DIAG_DIR}. Prefer ID13 relay/proxy mode on c6620." >&2
  else
    echo "ERROR: ${message}. See diagnostics bundle at ${ID13_PPTP_DIAG_DIR}." >&2
  fi
  id13_write_result_summary "failed" "${message}"
  exit 1
}

id13_write_support_context

echo "→ ID13 support bundle: ${ID13_SUPPORT_BUNDLE_DIR}"

################################################################################

### Log keeping

# Get ownership of /local and grant read and execute permissions to everyone
ORIG_USER=${SUDO_USER:-$(id -un)}
ORIG_GROUP=$(id -gn "$ORIG_USER")
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod -R a+rx /local
bci_write_node_owner_metadata "$ORIG_USER" "$ORIG_GROUP"

################################################################################

### Prepare bci_code repo

# Move to proper directory
cd /local
ensure_bci_repo
# Make Maya tool
cd "${BCI_CANONICAL_REPO_LINK}/tools/maya"
make CONF=Release

################################################################################

### Function for setting a title to the terminal tab

bashrc="$HOME/.bashrc"

# Don’t add it twice
if ! grep -q 'function set-title' "$bashrc"; then
  cat <<'EOF' >> "$bashrc"

# Set Title to a terminal tab
function set-title() {
    if [[ -z "$orig" ]]; then
        orig=$PS1
    fi
    title="\[\e]2;$*\a\]"
    PS1=${orig}${title}
}
EOF

  echo "✅ set-title() added to $bashrc"
else
  echo "ℹ️  set-title() already present in $bashrc"
fi

# Reload ~/.bashrc so you can use it immediately
# (you can also just open a new shell)
source "$bashrc"

################################################################################

### Increase storage

bci_prepare_local_data_mount
bci_report_local_data_mount

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential ppp pptp-linux cpuset cmake intel-cmt-cat msr-tools numactl ethtool tcpdump netcat-openbsd

################################################################################

### Create general directories
cd /local; mkdir -p tools; mkdir -p data;
cd data/; mkdir -p results;

################################################################################

### Installing pmu-tools

# Change directories
cd /local/tools/;
if [[ -d pmu-tools/.git ]]; then
  echo "→ Reusing existing pmu-tools checkout"
else
  # git clone https://github.com/andikleen/pmu-tools.git
  # Cloning modified pmu-tools repository (includes run information in results csv)
  git clone https://github.com/vickariofillis/pmu-tools.git
fi
cd pmu-tools/
# Install python3-pip and then install the required Python packages.
sudo apt-get install -y python3-pip
bci_install_pip_requirements requirements.txt
# Adjust kernel parameters to enable performance measurements.
sudo sysctl -w 'kernel.perf_event_paranoid=-1'
sudo sysctl -w 'kernel.nmi_watchdog=0'
# Install perf tools.
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-$(uname -r)
bci_prepare_intel_speed_select
bci_probe_intel_speed_select
# Download events (for toplev)
sudo /local/tools/pmu-tools/event_download.py

################################################################################

### Installing intel-pcm

# Move to the directory that holds all tool source
cd /local/tools
if [[ -d pcm/.git ]]; then
  echo "→ Reusing existing intel-pcm checkout"
else
  git clone --recursive https://github.com/intel/pcm
fi
# Enter the repository
cd pcm
# Create a build directory
mkdir -p build
# Switch into build directory
cd build
# Configure the build with cmake
cmake ..
# Compile PCM using all cores
cmake --build . --parallel

################################################################################

### Install ECE VPN

# === User configuration ===


DOWNLOAD_DIR="/local/tools/matlab_download"
INSTALL_DIR="/local/tools/matlab"
MPM_PATH="/usr/local/bin/mpm"
MATLAB_BIN="${INSTALL_DIR}/bin/matlab"

if [[ "${ID13_LICENSE_MODE}" == "proxy" ]]; then
  echo "→ Using ID13 proxy license mode via ${ID13_LICENSE_PROXY_HOST}:${ID13_LICENSE_PROXY_PORT}"
  if command -v nc >/dev/null 2>&1; then
    if timeout 8 nc -vz "${ID13_LICENSE_PROXY_HOST}" "${ID13_LICENSE_PROXY_PORT}"; then
      echo "✅ License proxy reachable"
    else
      id13_write_result_summary "failed" "License proxy ${ID13_LICENSE_PROXY_HOST}:${ID13_LICENSE_PROXY_PORT} is unreachable"
      echo "ERROR: License proxy ${ID13_LICENSE_PROXY_HOST}:${ID13_LICENSE_PROXY_PORT} is unreachable" >&2
      exit 1
    fi
  else
    echo "⚠️  nc is unavailable; skipping explicit proxy reachability check"
  fi
  id13_write_support_context
elif [[ "${ID13_LICENSE_MODE}" == "relay" ]]; then
  echo "→ Using ID13 relay license mode via ${ID13_LICENSE_RELAY_HOST} for ${LICENSE_SERVER}:${MLM_PORT}"
  ID13_LICENSE_RELAY_IP="$(getent ahostsv4 "${ID13_LICENSE_RELAY_HOST}" | awk 'NR==1{print $1}' || true)"
  if [[ -z "${ID13_LICENSE_RELAY_IP}" ]]; then
    id13_write_result_summary "failed" "Could not resolve relay host ${ID13_LICENSE_RELAY_HOST}"
    echo "ERROR: Could not resolve relay host ${ID13_LICENSE_RELAY_HOST} to an IPv4 address" >&2
    exit 1
  fi
  sudo cp /etc/hosts /etc/hosts.bak_id13 2>/dev/null || true
  sudo cp /etc/hosts "${ID13_SUPPORT_BUNDLE_DIR}/etc_hosts.before" 2>/dev/null || true
  python3 - "${LICENSE_SERVER}" "${ID13_LICENSE_RELAY_IP}" <<'PY'
import pathlib
import sys

license_server = sys.argv[1]
relay_ip = sys.argv[2]
hosts_path = pathlib.Path("/etc/hosts")
lines = hosts_path.read_text(encoding="utf-8", errors="replace").splitlines()
new_lines = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        new_lines.append(line)
        continue
    parts = stripped.split()
    if len(parts) >= 2 and license_server in parts[1:]:
        continue
    new_lines.append(line)
new_lines.append(f"{relay_ip} {license_server}")
hosts_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
PY
  sudo cp /etc/hosts "${ID13_SUPPORT_BUNDLE_DIR}/etc_hosts.after" 2>/dev/null || true
  printf '%s\n' \
    "relay_host=${ID13_LICENSE_RELAY_HOST}" \
    "relay_ip=${ID13_LICENSE_RELAY_IP}" \
    "license_server=${LICENSE_SERVER}" \
    >"${ID13_SUPPORT_BUNDLE_DIR}/relay_mapping.env"
  if command -v nc >/dev/null 2>&1; then
    if timeout 8 nc -vz "${LICENSE_SERVER}" "${MLM_PORT}"; then
      echo "✅ License relay reachable"
    else
      id13_write_result_summary "failed" "License relay path to ${LICENSE_SERVER}:${MLM_PORT} is unreachable"
      echo "ERROR: License relay path to ${LICENSE_SERVER}:${MLM_PORT} is unreachable" >&2
      exit 1
    fi
  else
    echo "⚠️  nc is unavailable; skipping explicit relay reachability check"
  fi
  id13_write_support_context
else
  if is_c6620_family "${ID13_HW_MODEL}"; then
    echo "⚠️  Native PPTP mode on ${ID13_HW_MODEL} is diagnostic-only; relay mode is the preferred production path."
  fi
  id13_prepare_pptp_diag_bundle
  # 1. Install & configure PPTP VPN client
  sudo tee /etc/ppp/options.pptp >/dev/null << 'EOF'
noauth
nodefaultroute
EOF

  sudo tee /etc/ppp/chap-secrets >/dev/null << EOF
${USERNAME} PPTP ${PASSWORD} *
PPTP ${USERNAME} ${PASSWORD} *
EOF
  sudo chmod 600 /etc/ppp/chap-secrets

  sudo tee /etc/ppp/peers/ecevpn >/dev/null << EOF
pty "pptp ${VPN_SERVER} --nolaunchpppd"
name ${USERNAME}
remotename PPTP
require-mschap-v2
require-mppe-128
file /etc/ppp/options.pptp
ipparam ecevpn
EOF

  sudo tee /etc/ppp/ip-up.d/static_route >/dev/null << 'EOF'
#!/bin/bash
if [ "\${PPP_IPPARAM}" = "ecevpn" ]; then
  for net in 128.100.7.0/24 128.100.9.0/24 128.100.10.0/24 \
             128.100.11.0/24 128.100.12.0/24 128.100.15.0/24 \
             128.100.23.0/24 128.100.24.0/24 128.100.51.0/24 \
             128.100.138.0/24 128.100.221.0/24 128.100.244.0/24; do
    route add -net \$net gw \${PPP_REMOTE} dev \${PPP_IFACE}
  done
fi
EOF
  sudo chmod 755 /etc/ppp/ip-up.d/static_route

  # 2. Bring up the VPN
  sudo poff ecevpn 2>/dev/null || true
  sudo pon ecevpn

  # 3. Wait for ppp0 to exist
  echo "Waiting for ppp0 interface…"
  for i in {1..8}; do
    if ip link show ppp0 &>/dev/null; then
      echo "  ppp0 is present"
      break
    fi
    sleep 3
  done
  if ! ip link show ppp0 &>/dev/null; then
    id13_fail_pptp_mode "ppp0 did not appear after pon ecevpn"
  fi

  # 4. Wait for ppp0 to receive an IP address
  echo "Waiting for ppp0 IP assignment…"
  for i in {1..8}; do
    if ip -4 addr show dev ppp0 | grep -q 'inet '; then
      echo "  ppp0 IP: $(ip -4 addr show dev ppp0 | grep inet)"
      break
    fi
    sleep 3
  done
  if ! ip -4 addr show dev ppp0 | grep -q 'inet '; then
    id13_fail_pptp_mode "ppp0 never got an IPv4 address"
  fi

  # 5. Add host route for license server via ppp0
  LICENSE_IP=$(getent hosts "${ID13_EFFECTIVE_LICENSE_SERVER}" | awk '{print $1}')
  sudo ip route replace "${LICENSE_IP}/32" dev ppp0
  echo "Route to ${LICENSE_IP}: $(ip route get "${LICENSE_IP}" | head -n1)"
  id13_finalize_pptp_diag_bundle
fi

################################################################################

### Install and license Matlab

# 6. Install MATLAB prerequisites & mpm
sudo apt-get install -y curl unzip libxmu6 libxt6 libx11-6 libglib2.0-0
# sudo curl -fsSL https://www.mathworks.com/mpm/glnxa64/mpm -o "${MPM_PATH}"
bci_retry_command 8 15 \
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
  -o "${MPM_PATH}" \
  https://www.mathworks.com/mpm/glnxa64/mpm
sudo chmod 755 "${MPM_PATH}"

# 7. Download MATLAB R2024b
mkdir -p "${DOWNLOAD_DIR}"
"${MPM_PATH}" download \
  --release R2024b \
  --products MATLAB Curve_Fitting_Toolbox Statistics_and_Machine_Learning_Toolbox \
  --destination "${DOWNLOAD_DIR}"

# 8a. Install MATLAB
mkdir -p "${INSTALL_DIR}"
"${MPM_PATH}" install \
  --source "${DOWNLOAD_DIR}" \
  --destination "${INSTALL_DIR}" \
  --products MATLAB Curve_Fitting_Toolbox Statistics_and_Machine_Learning_Toolbox

# 8b. Redirect MATLAB prefs into a writable folder under /local
MATLAB_PREFROOT="/local/tools/matlab_prefs"
MATLAB_PREFDIR="$MATLAB_PREFROOT/R2024b"

sudo mkdir -p   "$MATLAB_PREFDIR"
sudo chown -R   "$ORIG_USER:$ORIG_GROUP" "$MATLAB_PREFROOT"
sudo chmod -R a+rwX "$MATLAB_PREFROOT"

echo "→ MATLAB_PREFDIR set to $MATLAB_PREFDIR"

# 9. License checkout verification
export MLM_LICENSE_FILE="${ID13_EFFECTIVE_MLM_PORT}@${ID13_EFFECTIVE_LICENSE_SERVER}"
export LM_LICENSE_FILE="$MLM_LICENSE_FILE"

echo "→ Testing MATLAB license checkout via ${ID13_EFFECTIVE_LICENSE_SERVER}:${ID13_EFFECTIVE_MLM_PORT}…"
echo "→ Effective MLM_LICENSE_FILE=${MLM_LICENSE_FILE}"
sudo -u "$ORIG_USER" env \
    MLM_LICENSE_FILE="$MLM_LICENSE_FILE" \
    LM_LICENSE_FILE="$LM_LICENSE_FILE" \
    MATLAB_PREFDIR="$MATLAB_PREFDIR" \
  "${MATLAB_BIN}" -nodisplay -nosplash -nodesktop \
    -batch "\
      fprintf('PREFDIR=%s\n',prefdir); \
      s=license('test','MATLAB') && license('test','Curve_Fitting_Toolbox'); \
      fprintf('Core MATLAB licensed? %d\n', license('test','MATLAB')); \
      fprintf('Curve Fitting Toolbox licensed? %d\n', license('test','Curve_Fitting_Toolbox')); \
      exit(~s);"

if [ $? -eq 0 ]; then
  echo "✅ MATLAB R2024b installed and licensed successfully."
  id13_write_result_summary "licensed" "MATLAB license checkout succeeded"
else
  echo "❌ MATLAB license checkout failed." >&2
  id13_write_result_summary "failed" "MATLAB license checkout failed"
  exit 1
fi

install -d -m 700 "$(dirname "${ID13_RUNTIME_ENV_FILE}")"
cat > "${ID13_RUNTIME_ENV_FILE}" <<EOF
LICENSE_SERVER=$(printf '%q' "${ID13_EFFECTIVE_LICENSE_SERVER}")
MLM_PORT=$(printf '%q' "${ID13_EFFECTIVE_MLM_PORT}")
ID13_MLM_LICENSE_FILE=$(printf '%q' "${MLM_LICENSE_FILE}")
ID13_MATLAB_PREFDIR=$(printf '%q' "${MATLAB_PREFDIR}")
ID13_LICENSE_MODE=$(printf '%q' "${ID13_LICENSE_MODE}")
ID13_LICENSE_PROXY_HOST=$(printf '%q' "${ID13_LICENSE_PROXY_HOST:-}")
ID13_LICENSE_PROXY_PORT=$(printf '%q' "${ID13_LICENSE_PROXY_PORT:-}")
ID13_LICENSE_RELAY_HOST=$(printf '%q' "${ID13_LICENSE_RELAY_HOST:-}")
ID13_LICENSE_SERVER_TARGET=$(printf '%q' "${ID13_LICENSE_SERVER_TARGET}")
ID13_MLM_PORT_TARGET=$(printf '%q' "${ID13_MLM_PORT_TARGET}")
EOF
chmod 600 "${ID13_RUNTIME_ENV_FILE}"
echo "→ Wrote ID13 runtime environment to ${ID13_RUNTIME_ENV_FILE}"

################################################################################

### Setting up ID-13 (Movement Intent)

# Ensure repo is present in case the earlier setup path was skipped
cd /local
ensure_bci_repo

# Create directories
mkdir -p tools
cd tools

# Download Fieldtrip
bci_retry_command 6 10 \
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
  -o fieldtrip-20240916.zip \
  "https://drive.usercontent.google.com/download?id={1KVb_tsA1KzC7AhaZUKvR0wuR9Ob9bTJe}&confirm=xxx"
# Unzip Fieldtrip
echo "Extracting fieldtrip-20240916.zip"
if unzip -oq "fieldtrip-20240916.zip" -d fieldtrip/; then
  rm "fieldtrip-20240916.zip"
else
  echo "Extraction failed, archive not removed."
fi

# Create directories
cd /local/data;

# Download data files (patient 4)
bci_retry_command 8 15 \
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
  -o S4_raw_segmented.mat \
  https://osf.io/download/mgn6y/
# Download data files (patient 5)
bci_retry_command 8 15 \
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
  -o S5_raw_segmented.mat \
  https://osf.io/download/qmsc4/
# Download data files (patient 5)
bci_retry_command 8 15 \
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
  -o S6_raw_segmented.mat \
  https://osf.io/download/dtqky/

################################################################################

# Get ownership of /local and grant read and execute permissions to everyone
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
sudo chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod    -R a+rx                  /local

# Ensure MATLAB preference directories are owned by the original user
echo "→ Will set $MATLAB_PREFROOT → $ORIG_USER:$ORIG_GROUP …"
sudo chown -R "$ORIG_USER":"$ORIG_GROUP" "$MATLAB_PREFROOT"
chmod    -R a+rwX                 "$MATLAB_PREFROOT"

###  Final verification of /local ownership & permissions
# Determine who *should* own /local (the user who invoked sudo, or yourself if not using sudo)
EXPECTED_USER=${SUDO_USER:-$(id -un)}
EXPECTED_GROUP=$(id -gn "$EXPECTED_USER")
echo "Verifying that everything under /local is owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and has a+rx..."

# 1) Any file not owned by EXPECTED_USER:EXPECTED_GROUP?
bad_owner=$(find /local \
    ! -user "$EXPECTED_USER" -o ! -group "$EXPECTED_GROUP" \
    -print -quit 2>/dev/null || true)

# 2) Any entry missing read for all? (i.e. not -r--r--r--)
bad_read=$(find /local \
    ! -perm -444 \
    -print -quit 2>/dev/null || true)

# 3) Any entry missing exec for all? (i.e. not --x--x--x--)
bad_exec=$(find /local \
    ! -perm -111 \
    -print -quit 2>/dev/null || true)

if [[ -z "$bad_owner" && -z "$bad_read" && -z "$bad_exec" ]]; then
    echo "✅ All files under /local are owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and have a+rx"
else
    [[ -n "$bad_owner" ]] && echo "❌ Ownership mismatch example: $bad_owner"
    [[ -n "$bad_read"  ]] && echo "❌ Missing read bit example:  $bad_read"
    [[ -n "$bad_exec"  ]] && echo "❌ Missing exec bit example:  $bad_exec"
    exit 1
fi

###  Final verification of $MATLAB_PREFROOT ownership & permissions
echo "Verifying that everything under $MATLAB_PREFROOT is owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and writable..."

bad_owner=$(find "$MATLAB_PREFROOT" \
    ! -user "$EXPECTED_USER" -o ! -group "$EXPECTED_GROUP" \
    -print -quit 2>/dev/null || true)
bad_write=$(find "$MATLAB_PREFROOT" \
    ! -perm -222 \
    -print -quit 2>/dev/null || true)

if [[ -z "$bad_owner" && -z "$bad_write" ]]; then
    echo "✅ $MATLAB_PREFROOT is owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and writable"
else
    [[ -n "$bad_owner" ]] && echo "❌ Ownership mismatch example: $bad_owner"
    [[ -n "$bad_write" ]] && echo "❌ Missing write bit example: $bad_write"
    exit 1
fi

bci_write_node_owner_metadata "$EXPECTED_USER" "$EXPECTED_GROUP"
id13_write_result_summary "completed" "startup_13.sh completed successfully"
touch "${STARTUP_DONE_PATH}"
rm -f "${STARTUP_FAILED_PATH}"
echo "✅ startup_13.sh completed successfully"
