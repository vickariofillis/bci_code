#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helper functions for run scripts.

# on_error
#   Trap handler for unexpected failures. Logs the failing command/line, runs cleanup hooks, and exits with the original status.
#   Arguments: none; relies on $?, BASH_LINENO, and BASH_COMMAND from the ERR trap context.
on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  echo "[FATAL] $(basename "$0"): line ${line}: '${cmd}' exited with ${rc}" >&2

  # Best-effort cleanups (only if available in this script)
  if declare -F restore_llc_defaults >/dev/null; then
    [[ ${LLC_RESTORE_REGISTERED:-false} == true ]] && restore_llc_defaults || true
  fi
  if declare -F restore_idle_states_if_needed >/dev/null; then
    restore_idle_states_if_needed || true
  fi
  if command -v cset >/dev/null 2>&1; then
    sudo cset shield --reset >/dev/null 2>&1 || true
  fi
  if declare -F cleanup_pcm_processes >/dev/null; then
    cleanup_pcm_processes || true
  fi
  if declare -F uncore_restore_snapshot >/dev/null; then
    uncore_restore_snapshot || true
  fi

  exit "$rc"
}


# expand_online
#   Convert the kernel's online CPU mask into a newline-delimited list of CPU IDs.
#   Arguments: none; reads /sys/devices/system/cpu/online.
expand_online() {
  local s; s="$(cat /sys/devices/system/cpu/online)"
  local out=() parts=()
  IFS=',' read -r -a parts <<< "$s"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      local a=${p%-*} b=${p#*-}
      for ((i=a; i<=b; i++)); do out+=("$i"); done
    else
      out+=("$p")
    fi
  done
  printf "%s\n" "${out[@]}"
}


# others_list_csv
#   Return a comma-separated list of online CPUs excluding the provided IDs.
#   Arguments:
#     $@ - CPU IDs that must be omitted from the result.
others_list_csv() {
  local exclude=("$@")
  local all=() out=()
  mapfile -t all < <(expand_online)
  for c in "${all[@]}"; do
    local skip=0
    for e in "${exclude[@]}"; do
      if [[ "$c" == "$e" ]]; then skip=1; break; fi
    done
    [[ $skip -eq 0 ]] && out+=("$c")
  done
  local IFS=,
  echo "${out[*]}"
}


# build_cpu_list
#   Merge TOOLS_CPU, WORKLOAD_CPU, and any literal masks in the script into a canonical CPU list.
#   Arguments: none; prints the deduplicated CPU list to stdout.
build_cpu_list() {
  local SCRIPT_FILE
  SCRIPT_FILE="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  local candidates
  candidates="$(printf '%s' "${TOOLS_CPU}" | tr -d '[:space:]')"
  if [ -n "${WORKLOAD_CPU-}" ]; then
    candidates="${candidates},$(printf '%s' "${WORKLOAD_CPU}" | tr -d '[:space:]')"
  fi

  local literals
  literals="$(
    {
      grep -Eo 'taskset -c[[:space:]]+[0-9,]+' "$SCRIPT_FILE" 2>/dev/null | awk '{print $3}' || true
      grep -Eo 'cset[[:space:]]+(shield|set)[[:space:]]+--cpu[[:space:]]+[0-9,]+' "$SCRIPT_FILE" 2>/dev/null | awk '{print $NF}' || true
    } | tr -d '[:space:]'
  )"

  local CPU_LIST_BUILT
  CPU_LIST_BUILT="$(
    printf '%s\n%s\n' "${candidates}" "${literals}" \
      | tr ',' '\n' \
      | awk '/^[0-9]+$/' \
      | sort -n \
      | uniq \
      | paste -sd, -
  )"

  if [ -z "${CPU_LIST_BUILT}" ]; then
    CPU_LIST_BUILT="$(printf '%s' "${TOOLS_CPU}" | tr -d '[:space:]')"
  fi

  printf '%s\n' "${CPU_LIST_BUILT}"
}


# trap_add
#   Append a command to an existing trap without overwriting the previous handler.
#   Arguments:
#     $1 - command snippet to append.
#     $2 - trap name to target (defaults to EXIT).
trap_add() {
  local cmd="$1" trap_name="${2:-EXIT}"
  local existing
  existing="$(trap -p "$trap_name" | awk -F"'" '{print $2}')"
  if [[ -n "$existing" ]]; then
    trap -- "$existing;$cmd" "$trap_name"
  else
    trap -- "$cmd" "$trap_name"
  fi
}


# die
#   Emit an LLC-prefixed error message and abort the script.
#   Arguments:
#     $* - message fragments to print to stderr before exiting.
die() {
  echo "[LLC] ERROR: $*" >&2
  exit 1
}


# mounted_resctrl
#   Check whether the resctrl filesystem is currently mounted.
#   Arguments: none; returns success when /sys/fs/resctrl is an active mountpoint.
mounted_resctrl() { mountpoint -q /sys/fs/resctrl; }


# mount_resctrl
#   Ensure the resctrl filesystem is mounted, terminating the script if the mount fails.
#   Arguments: none.
mount_resctrl() {
  if ! mounted_resctrl; then
    sudo mount -t resctrl resctrl /sys/fs/resctrl || die "mount resctrl failed"
  fi
}


# umount_resctrl_if_empty
#   Unmount the resctrl filesystem when no custom groups remain.
#   Arguments: none.
umount_resctrl_if_empty() {
  if [ -z "$(find /sys/fs/resctrl -mindepth 1 -maxdepth 1 -type d ! -name info -printf '%f\n' 2>/dev/null)" ]; then
    sudo umount /sys/fs/resctrl 2>/dev/null || true
  fi
}


# popcnt_hex
#   Count the number of set bits in a hexadecimal mask string.
#   Arguments:
#     $1 - hexadecimal mask to evaluate.
popcnt_hex() {
  local hex=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  local sum=0 n i
  for ((i=0;i<${#hex};i++)); do
    case "${hex:i:1}" in
      0) n=0;; 1) n=1;; 2) n=1;; 3) n=2;; 4) n=1;; 5) n=2;; 6) n=2;; 7) n=3;;
      8) n=1;; 9) n=2;; A) n=2;; B) n=3;; C) n=2;; D) n=3;; E) n=3;; F) n=4;;
      *) die "invalid hex in mask '$hex'";;
    esac
    sum=$((sum+n))
  done
  echo "$sum"
}


# build_low_mask
#   Build a hexadecimal mask where the lowest N ways are enabled.
#   Arguments:
#     $1 - number of contiguous ways to enable.
#     $2 - optional output width (hex digits) for zero-padding.
build_low_mask() {
  local ways=${1:-0}
  local width=${2:-0}
  local val=0
  if (( ways > 0 )); then
    val=$(( (1 << ways) - 1 ))
  fi
  if (( width > 0 )); then
    printf "%0${width}x" "$val"
  else
    printf "%x" "$val"
  fi
}


build_exclusive_run_mask() {
  # args: ways_req, base_hex, hex_width, bit_width
  local ways_req="$1"
  local base_hex="$2"
  local hex_width="$3"
  local bit_width="$4"

  local base_dec=$(( 0x${base_hex} ))
  (( ways_req > 0 )) || { printf "%0${hex_width}x" 0; return; }

  # contiguous run of 'ways_req' bits anchored at some offset
  local run_mask_dec=$(( (1 << ways_req) - 1 ))

  local start=0
  while (( start + ways_req <= bit_width )); do
    local shifted=$(( run_mask_dec << start ))
    # must be fully contained by base_dec (i.e., not touch shareable bits)
    if (( (shifted & ~base_dec) == 0 )); then
      printf "%0${hex_width}x" "${shifted}"
      return
    fi
    (( start++ ))
  done

  die "Cannot carve ${ways_req} contiguous exclusive ways inside base=0x${base_hex}"
}


# discover_llc_caps
#   Query resctrl sysfs files to populate LLC capability globals (L3 IDs, masks, way counts).
#   Arguments: none; updates L3_IDS, CBM_MASK, SHARE_MASK, MIN_BITS, WAYS_* variables.
discover_llc_caps() {
  mount_resctrl

  # Accept leading spaces/tabs before 'L3:' (some kernels/tools indent this line)
  local schem
  if ! schem="$(grep -E '^[[:space:]]*L3:' /sys/fs/resctrl/schemata 2>/dev/null)"; then
    die "No L3 line in /sys/fs/resctrl/schemata (CAT unsupported or disabled)"
  fi

  # Extract all L3 IDs robustly (domain ids before '=') regardless of indentation
  L3_IDS=$(
    awk -F'[=;]' '
      /^[[:space:]]*L3:/ {
        sub(/^[[:space:]]*L3:[[:space:]]*/,"",$0);
        n=split($0,a,";");
        for(i=1;i<=n;i++){ split(a[i],b,"="); print b[1] }
      }' /sys/fs/resctrl/schemata | xargs
  )

  CBM_MASK=$(< /sys/fs/resctrl/info/L3/cbm_mask)
  SHARE_MASK=$(< /sys/fs/resctrl/info/L3/shareable_bits)
  MIN_BITS=$(< /sys/fs/resctrl/info/L3/min_cbm_bits)

  WAYS_TOTAL=$(popcnt_hex "$CBM_MASK")
  WAYS_SHARE=$(popcnt_hex "$SHARE_MASK")
  WAYS_EXCL_MAX=$(( WAYS_TOTAL - WAYS_SHARE ))
  PCT_STEP=$(( 100 / WAYS_TOTAL ))

  # Widths
  CBM_HEX_WIDTH=${#CBM_MASK}               # hex digits
  CBM_BIT_WIDTH=$(( CBM_HEX_WIDTH * 4 ))   # bits

  # Exclusive base = all cache bits minus shareable bits
  local _cbm_dec=$(( 0x${CBM_MASK} ))
  local _shr_dec=$(( 0x${SHARE_MASK} ))
  local _excl_dec=$(( _cbm_dec & ~_shr_dec ))
  EXCL_BASE_HEX=$(printf "%0${CBM_HEX_WIDTH}x" "${_excl_dec}")

  # Sanity: if nothing exclusive remains, fail fast
  if (( _excl_dec == 0 )); then
    die "No exclusive L3 ways available (all ways are shareable on this system)"
  fi
}


# percent_to_exclusive_mask
#   Convert a percentage of the LLC into an exclusive cache mask string.
#   Arguments:
#     $1 - requested LLC percentage (integer).
percent_to_exclusive_mask() {
  local pct="$1"
  local ways_req=$(( pct * WAYS_TOTAL / 100 ))

  # Respect min_cbm_bits and exclusive capacity
  if (( ways_req < MIN_BITS )); then
    die "Requested ${pct}% -> ${ways_req} ways is below min_cbm_bits=${MIN_BITS}"
  fi
  if (( ways_req > WAYS_EXCL_MAX )); then
    die "Requested ${pct}% -> ${ways_req} ways exceeds exclusive capacity (${WAYS_EXCL_MAX}/${WAYS_TOTAL})"
  fi

  # Build a contiguous run that stays strictly within EXCL_BASE_HEX (i.e., avoids shareable bits)
  local mask_hex
  mask_hex="$(build_exclusive_run_mask "${ways_req}" "${EXCL_BASE_HEX}" "${CBM_HEX_WIDTH}" "${CBM_BIT_WIDTH}")"
  echo "$mask_hex"
}


# cpu_online_list
#   Return the kernel-reported online CPU mask string.
#   Arguments: none.
cpu_online_list() { cat /sys/devices/system/cpu/online; }


# cpu_list_except
#   Produce a compact CPU range string for all online CPUs except the supplied ID.
#   Arguments:
#     $1 - CPU ID to exclude.
cpu_list_except() {
  local exclude="$1"
  python3 - "$exclude" <<'PYCORE'
import sys
exc = int(sys.argv[1])
with open('/sys/devices/system/cpu/online') as fh:
    rng = fh.read().strip()

def expand(r):
    for part in r.split(','):
        if '-' in part:
            a, b = map(int, part.split('-'))
            yield from range(a, b + 1)
        else:
            yield int(part)
cpus = [c for c in expand(rng) if c != exc]
if not cpus:
    print('')
    raise SystemExit
out = []
start = None
prev = None
for c in cpus:
    if start is None:
        start = prev = c
        continue
    if c == prev + 1:
        prev = c
        continue
    out.append(f"{start}-{prev}" if start != prev else f"{start}")
    start = prev = c
if start is not None:
    out.append(f"{start}-{prev}" if start != prev else f"{start}")
print(','.join(out))
PYCORE
}


# make_groups
#   Create workload and system resctrl groups, removing any stale directories first.
#   Arguments:
#     $1 - workload group name.
#     $2 - system/background group name.
make_groups() {
  local wl="$1" sys="$2"
  sudo rmdir "/sys/fs/resctrl/${wl}" 2>/dev/null || true
  sudo rmdir "/sys/fs/resctrl/${sys}" 2>/dev/null || true
  sudo mkdir "/sys/fs/resctrl/${wl}" || die "mkdir wl group failed"
  sudo mkdir "/sys/fs/resctrl/${sys}" || die "mkdir sys group failed"
}


# program_groups
#   Program resctrl schemata and CPU lists for the workload and system groups.
#   Order matters: shrink root to REST, write WL/SYS, then set WL exclusive.
#   Arguments:
#     $1 - workload group name (e.g., wl_core)
#     $2 - system/background group name (e.g., sys_rest)
#     $3 - workload CPU id (e.g., 6)
#     $4 - workload LLC mask (hex, no 0x, lowercase)
program_groups() {
  local wl="$1"; local sys="$2"; local wl_core="$3"; local wl_mask="${4,,}"  # normalize to lowercase
  local cbm_mask="${CBM_MASK,,}"; local share_mask="${SHARE_MASK,,}"
  local root="/sys/fs/resctrl"
  local rest_mask_hex

  # Sanity: WL mask must not include shareable bits
  if (( ( 0x${wl_mask:-0} & 0x${share_mask:-0} ) != 0 )); then
    die "WL mask 0x${wl_mask} overlaps shareable bits 0x${share_mask}"
  fi

  # Compute REST = CBM_MASK & ~WL_MASK (width matches CBM_MASK)
  rest_mask_hex="$(printf "%0${#cbm_mask}x" $(( 0x${cbm_mask} & ~0x${wl_mask:-0} )))"

  # Build schemata strings using the global L3 domain list discovered earlier
  # (discover_llc_caps populates L3_IDS).
  local ids="${L3_IDS:?L3_IDS not set; ensure discover_llc_caps ran}"
  local wl_schem sys_schem root_schem
  wl_schem="$(echo "${ids}" | sed -E "s/ /=${wl_mask};/g; s/^/L3:/; s/$/=${wl_mask}/")"
  sys_schem="$(echo "${ids}" | sed -E "s/ /=${rest_mask_hex};/g; s/^/L3:/; s/$/=${rest_mask_hex}/")"
  root_schem="${sys_schem}"

  # Program root first so it relinquishes WL bits
  sudo tee "${root}/schemata" > /dev/null <<<"${root_schem}"     || die "Failed to program root schemata to REST mask (${root_schem})"

  # Assign CPUs
  echo "${wl_core}" | sudo tee "${root}/${wl}/cpus_list"  >/dev/null
  echo "$(cpu_list_except "${wl_core}")" | sudo tee "${root}/${sys}/cpus_list" >/dev/null

  # Program WL / SYS schemata
  sudo tee "${root}/${wl}/schemata"  > /dev/null <<<"${wl_schem}"      || die "Failed to program '${wl}' schemata (${wl_schem})"
  sudo tee "${root}/${sys}/schemata" > /dev/null <<<"${sys_schem}"     || die "Failed to program '${sys}' schemata (${sys_schem})"

  # Now request exclusivity for WL group
  echo exclusive | sudo tee "${root}/${wl}/mode" > /dev/null || true

  # Surface kernel status if anything went sideways
  if [[ -r "${root}/info/last_cmd_status" ]]; then
    local st; st="$(<"${root}/info/last_cmd_status")"
    [[ "${st}" == "ok" ]] || die "Kernel rejected exclusive mode for '${wl}': ${st}"
  fi
}



# verify_once
#   Validate that a workload resctrl group has the expected mask and CPU list.
#   Supported call forms:
#     (old) verify_once <wl_group> <wl_core> <wl_mask>
#     (new) verify_once <wl_group> <sys_group> <wl_mask> <wl_core> [wl_pids_csv]
verify_once() {
  set +u  # avoid nounset while we normalize args safely
  local root="/sys/fs/resctrl"
  local a1="$1" a2="$2" a3="$3" a4="$4" a5="$5"
  set -u

  local wl sys wl_mask wl_core wl_pids_csv
  if [[ -n "${a4:-}" || -n "${a5:-}" ]]; then
    # New signature: wl, sys, mask, core, [pids]
    wl="$a1"; sys="$a2"; wl_mask="${a3,,}"; wl_core="$a4"; wl_pids_csv="${a5:-}"
  else
    # Old signature: wl, core, mask
    wl="$a1"; wl_core="$a2"; wl_mask="${a3,,}"; sys="${RDT_GROUP_SYS:-sys_rest}"
  fi

  # Be tolerant to whitespace and multi-domain entries; take the last mask
  local got_wl_mask got_sys_mask
  got_wl_mask="$(sed -nE 's/^[[:space:]]*L3:.*=([0-9a-fA-F]+)[[:space:]]*$/\1/p' "${root}/${wl}/schemata" | tail -n1)"     || die "Unable to read WL schemata at ${root}/${wl}/schemata"
  got_sys_mask="$(sed -nE 's/^[[:space:]]*L3:.*=([0-9a-fA-F]+)[[:space:]]*$/\1/p' "${root}/${sys}/schemata" | tail -n1)"     || die "Unable to read SYS schemata at ${root}/${sys}/schemata"

  if [[ -z "${got_wl_mask}" || -z "${got_sys_mask}" ]]; then
    local st="(unknown)"; [[ -r "${root}/info/last_cmd_status" ]] && st="$(<"${root}/info/last_cmd_status")"
    die "L3 lines not found in schemata (wl='${got_wl_mask:-<empty>}', sys='${got_sys_mask:-<empty>}'). last_cmd_status: ${st}"
  fi

  # Check WL got the expected mask
  if [[ "${got_wl_mask,,}" != "${wl_mask,,}" ]]; then
    die "WL mask mismatch: expected 0x${wl_mask}, got 0x${got_wl_mask}"
  fi

  # Optional: bit_usage visibility (E=exclusive)
  [[ -r "${root}/info/L3/bit_usage" ]] && log_debug "L3 bit_usage: $(<"${root}/info/L3/bit_usage")"

  # Check assigned CPUs & tasks
  local got_wl_cpus; got_wl_cpus="$(<"${root}/${wl}/cpus_list")"
  [[ "${got_wl_cpus}" =~ (^|,)${wl_core}($|,) ]]     || die "WL CPUs not set as expected: wanted core ${wl_core} in '${got_wl_cpus}'"

  if [[ -n "${wl_pids_csv:-}" ]]; then
    for pid in ${wl_pids_csv//,/ } ; do
      grep -qE "(^|[[:space:]])${pid}([[:space:]]|$)" "${root}/${wl}/tasks"         || die "PID ${pid} not present in ${root}/${wl}/tasks"
    done
  fi
}




# restore_llc_defaults
#   Remove custom resctrl groups and restore default cache allocation policy.
#   Arguments: none; respects LLC_RESTORE_REGISTERED and related globals.
restore_llc_defaults() {
  if [[ ${LLC_RESTORE_REGISTERED:-false} != true ]]; then
    return
  fi
  sudo rmdir "/sys/fs/resctrl/${RDT_GROUP_WL}" 2>/dev/null || true
  sudo rmdir "/sys/fs/resctrl/${RDT_GROUP_SYS}" 2>/dev/null || true
  if [[ -n "${L3_IDS:-}" && -n "${CBM_MASK:-}" ]]; then
    local full_line="L3:$(echo "$L3_IDS" | sed "s/ /=${CBM_MASK};/g")=${CBM_MASK}"
    echo "$full_line" | sudo tee /sys/fs/resctrl/schemata >/dev/null || true
  fi
  umount_resctrl_if_empty
  LLC_RESTORE_REGISTERED=false
  LLC_EXCLUSIVE_ACTIVE=false
  echo "[LLC] Restored defaults."
}


# llc_core_setup_once
#   Parse LLC-related CLI options, optionally carve out exclusive cache capacity, and program resctrl groups.
#   Arguments:
#     $@ - option/value pairs consumed from the main CLI parser.
llc_core_setup_once() {
  local WL_CORE="${WORKLOAD_CORE_DEFAULT}"
  local TOOLS_CORE="${TOOLS_CORE_DEFAULT}"
  local LLC_PCT=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --llc)
        LLC_PCT="$2"
        shift 2
        ;;
      --wl-core)
        WL_CORE="$2"
        shift 2
        ;;
      --tools-core)
        TOOLS_CORE="$2"
        shift 2
        ;;
      *)
        echo "[LLC] Unknown arg $1"
        return 1
        ;;
    esac
  done
  if [ "$LLC_PCT" = "" ]; then
    LLC_PCT=100
  fi
  if ! [[ "$LLC_PCT" =~ ^[0-9]+$ ]]; then
    die "LLC % must be an integer"
  fi
  if [ "$LLC_PCT" -eq 100 ]; then
    echo "[LLC] Using full LLC (no restriction)."
    LLC_REQUESTED_PERCENT=100
    return 0
  fi
  discover_llc_caps
  # Validate that LLC_PCT maps to an integer number of ways
  # and that it satisfies min_cbm_bits.
  local _int_check=$(( (LLC_PCT * WAYS_TOTAL) % 100 ))
  if (( _int_check != 0 )); then
    local _step_pct=$(( 100 / $(gcd 100 "${WAYS_TOTAL}") ))
    die "LLC % must yield an integer number of ways on this system (WAYS_TOTAL=${WAYS_TOTAL}). Try multiples of ${_step_pct}%."
  fi

  local ways_req=$(( LLC_PCT * WAYS_TOTAL / 100 ))
  # Enforce min_cbm_bits as a percentage threshold (ceil(MIN_BITS/WAYS_TOTAL*100))
  local min_pct_for_min_bits=$(( (100 * MIN_BITS + WAYS_TOTAL - 1) / WAYS_TOTAL ))
  if (( ways_req < MIN_BITS )); then
    die "LLC % too small: ${LLC_PCT}% -> ${ways_req} ways; need at least ${min_pct_for_min_bits}% (min_cbm_bits=${MIN_BITS})."
  fi

  # (capacity limit is re-checked in percent_to_exclusive_mask)
  local WL_MASK
  WL_MASK="$(percent_to_exclusive_mask "$LLC_PCT")"
  local RESERVED_WAYS
  RESERVED_WAYS="$(popcnt_hex "$WL_MASK")"
  make_groups "$RDT_GROUP_WL" "$RDT_GROUP_SYS"
  program_groups "$RDT_GROUP_WL" "$RDT_GROUP_SYS" "$WL_CORE" "$WL_MASK"
  verify_once "$RDT_GROUP_WL" "$WL_CORE" "$WL_MASK"
  LLC_RESTORE_REGISTERED=true
  LLC_EXCLUSIVE_ACTIVE=true
  LLC_REQUESTED_PERCENT="$LLC_PCT"
  trap_add 'restore_llc_defaults' EXIT
  echo "[LLC] Reserved ${LLC_PCT}% -> ${RESERVED_WAYS}/${WAYS_TOTAL} ways (mask 0x$WL_MASK) exclusively for core ${WL_CORE}."
  if (( WAYS_SHARE > 0 )); then
    echo "[LLC] Exclusive capacity available: ${WAYS_EXCL_MAX}/${WAYS_TOTAL} ways (shareable=${WAYS_SHARE})."
  fi
  echo "[LLC] Tools should run on a different core (e.g., ${TOOLS_CORE})."
}


# print_help
#   Render the command-line help table based on the CLI_OPTIONS metadata.
#   Arguments: none.
print_help() {
  local script_name="$(basename "$0")"
  echo "Usage: ${script_name} [options]"
  echo
  echo "Options:"
  local entry flag value desc display_flag max_width=0
  for entry in "${CLI_OPTIONS[@]}"; do
    [[ $entry == __GROUP_BREAK__ ]] && continue
    IFS='|' read -r flag value desc <<< "$entry"
    display_flag="$flag"
    if [[ -n $value ]]; then
      display_flag+=" <${value}>"
    fi
    if (( ${#display_flag} > max_width )); then
      max_width=${#display_flag}
    fi
  done

  local blank_pending=0
  for entry in "${CLI_OPTIONS[@]}"; do
    if [[ $entry == __GROUP_BREAK__ ]]; then
      blank_pending=1
      continue
    fi
    if (( blank_pending )); then
      echo
      blank_pending=0
    fi
    IFS='|' read -r flag value desc <<< "$entry"
    display_flag="$flag"
    if [[ -n $value ]]; then
      display_flag+=" <${value}>"
    fi
    printf '  %-*s %s\n' "$max_width" "$display_flag" "$desc"
  done
  echo
  echo "Options that require values will display the value name in angle brackets."
  echo "If no options are provided, all profilers run by default."
}


# log_info
#   Emit an informational log line with an [INFO] prefix.
#   Arguments:
#     $* - message to print.
log_info() {
  printf '[INFO] %s\n' "$*"
}


# log_debug
#   Emit a debug log line when debug_enabled is true.
#   Arguments:
#     $* - message to print.
log_debug() {
  $debug_enabled && printf '[DEBUG] %s\n' "$*"
}


# log_debug_blank
#   Emit a blank line in debug logs when debug mode is active.
#   Arguments: none.
log_debug_blank() {
  $debug_enabled && printf '\n'
}


if ! type ghz_to_khz >/dev/null 2>&1; then
  ghz_to_khz() { # "$1" like "2.3" -> echo kHz as integer
    awk -v g="${1:-0}" 'BEGIN{printf("%d", g*1000000)}'
  }
fi

if ! type log_warn >/dev/null 2>&1; then
  log_warn() { printf '[WARN] %s\n' "$*"; }
fi


UNC_PATH="/sys/devices/system/cpu/intel_uncore_frequency"
declare -a __UNC_DIES=()
declare -A __UNC_SNAP_MIN=()
declare -A __UNC_SNAP_MAX=()

uncore_available() {
  sudo modprobe intel_uncore_frequency >/dev/null 2>&1 || true
  [[ -d "${UNC_PATH}" ]] || return 1
  return 0
}

uncore_discover_dies() {
  __UNC_DIES=()
  uncore_available || return 1
  local d
  for d in "${UNC_PATH}"/package_*_die_*; do
    [[ -d "$d" ]] && __UNC_DIES+=("$d")
  done
  ((${#__UNC_DIES[@]} > 0)) || return 1
  return 0
}

uncore_snapshot_current() {
  uncore_discover_dies || return 1
  local d
  for d in "${__UNC_DIES[@]}"; do
    __UNC_SNAP_MIN["$d"]="$(<"$d/min_freq_khz")"
    __UNC_SNAP_MAX["$d"]="$(<"$d/max_freq_khz")"
  done
  return 0
}

uncore_restore_snapshot() {
  ((${#__UNC_SNAP_MIN[@]})) || return 0
  local d old_min old_max now_min now_max
  for d in "${!__UNC_SNAP_MIN[@]}"; do
    old_min="${__UNC_SNAP_MIN[$d]}"
    old_max="${__UNC_SNAP_MAX[$d]}"
    echo "${old_min}"  | sudo tee "$d/min_freq_khz" >/dev/null 2>&1 || true
    echo "${old_max}"  | sudo tee "$d/max_freq_khz" >/dev/null 2>&1 || true
    now_min="$(<"$d/min_freq_khz")"
    now_max="$(<"$d/max_freq_khz")"
    if [[ "$now_min" != "$old_min" || "$now_max" != "$old_max" ]]; then
      log_warn "[UNC] Restore mismatch for $(basename "$d"): wanted min=${old_min} max=${old_max}, got min=${now_min} max=${now_max}"
    fi
  done
  log_info "[UNC] Restored uncore limits to snapshot."
}

uncore_apply_pin_ghz() {
  local ghz="${1:-}"
  [[ -n "$ghz" ]] || return 0
  uncore_discover_dies || { log_warn "[UNC] intel_uncore_frequency sysfs not present; skipping uncore pin"; return 0; }

  local khz
  khz="$(ghz_to_khz "$ghz")"
  log_debug "[UNC] Requesting uncore min=max pin: ${ghz} GHz (${khz} kHz)"

  uncore_snapshot_current || true

  local d init_min init_max now_min now_max die_name
  for d in "${__UNC_DIES[@]}"; do
    die_name="$(basename "$d")"
    init_min="$(<"$d/initial_min_freq_khz")"
    init_max="$(<"$d/initial_max_freq_khz")"

    if (( khz < init_min || khz > init_max )); then
      log_warn "[UNC] ${die_name}: requested ${khz} kHz is outside platform range ${init_min}..${init_max} kHz; not applying to this die."
      continue
    fi

    echo "${khz}" | sudo tee "$d/min_freq_khz" >/dev/null 2>&1 || true
    echo "${khz}" | sudo tee "$d/max_freq_khz" >/dev/null 2>&1 || true

    now_min="$(<"$d/min_freq_khz")"
    now_max="$(<"$d/max_freq_khz")"
    if [[ "$now_min" != "$khz" || "$now_max" != "$khz" ]]; then
      log_warn "[UNC] ${die_name}: pin did not stick (now min=${now_min} max=${now_max}); continuing."
    else
      log_info "[UNC] ${die_name}: pinned uncore at ${ghz} GHz (${khz} kHz)."
    fi
  done
}

core_apply_pin_khz_softcheck() {
  local khz="$1"
  shift
  local cpu
  for cpu in "$@"; do
    local cpu_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    if [[ ! -d "${cpu_path}" ]]; then
      log_warn "[CPU] cpu${cpu}: cpufreq sysfs missing; skipping core pin"
      continue
    fi

    local min_hw max_hw
    min_hw="$(<"${cpu_path}/cpuinfo_min_freq")"
    max_hw="$(<"${cpu_path}/cpuinfo_max_freq")"

    if (( khz < min_hw || khz > max_hw )); then
      log_warn "[CPU] cpu${cpu}: requested ${khz} kHz outside ${min_hw}..${max_hw}; will attempt write but it may be clamped."
    fi

    if [[ -w "${cpu_path}/scaling_governor" ]]; then
      echo userspace | sudo tee "${cpu_path}/scaling_governor" >/dev/null 2>&1 || true
    fi

    echo "${khz}" | sudo tee "${cpu_path}/scaling_min_freq" >/dev/null 2>&1 || true
    echo "${khz}" | sudo tee "${cpu_path}/scaling_max_freq" >/dev/null 2>&1 || true

    local now_min now_max
    now_min="$(<"${cpu_path}/scaling_min_freq")"
    now_max="$(<"${cpu_path}/scaling_max_freq")"
    if [[ "$now_min" != "$khz" || "$now_max" != "$khz" ]]; then
      log_warn "[CPU] cpu${cpu}: pin did not stick (now min=${now_min} max=${now_max})."
    else
      log_info "[CPU] cpu${cpu}: pinned core at ${khz} kHz."
    fi
  done
}


# write_done_status
#   Emit an aligned status line for done logs.
#   Arguments:
#     $1 - label (tool name).
#     $2 - status text.
#     $3 - destination file path.
write_done_status() {
  local label="$1"
  local status="$2"
  local path="$3"
  printf '%-20s %s\n' "$label" "$status" > "$path"
}


# write_done_skipped
#   Convenience wrapper for skipped tools.
write_done_skipped() {
  local label="$1"
  local path="$2"
  write_done_status "$label" "Skipped" "$path"
}


# write_done_runtime
#   Convenience wrapper for runtime completions.
write_done_runtime() {
  local label="$1"
  local runtime="$2"
  local path="$3"
  write_done_status "$label" "Runtime: $runtime" "$path"
}


# print_section
#   Print a banner separator for major script sections.
#   Arguments:
#     $1 - section title.
print_section() {
  local title="$1"
  echo
  echo "################################################################################"
  printf '### %s\n' "$title"
  echo "################################################################################"
  echo
}


# print_tool_header
#   Print a banner separator for individual profiling tools.
#   Arguments:
#     $1 - tool description.
print_tool_header() {
  local title="$1"
  echo
  echo "--------------------------------------------------------------------------------"
  printf '### %s\n' "$title"
  echo "--------------------------------------------------------------------------------"
  echo
}


# require_positive_number
#   Validate that a CLI interval value is a positive number.
#   Arguments:
#     $1 - label used in error messages.
#     $2 - value to validate.
require_positive_number() {
  local label="$1"
  local value="$2"
  if [[ ! $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Invalid interval for ${label}: '$value' (expected positive number)" >&2
    exit 1
  fi
  if ! awk -v v="$value" 'BEGIN{exit (v > 0 ? 0 : 1)}'; then
    echo "Interval for ${label} must be greater than zero" >&2
    exit 1
  fi
}


# set_interval_value
#   Validate and assign a CLI interval value to the requested variable.
#   Arguments:
#     $1 - shell variable name to update.
#     $2 - label used in error messages.
#     $3 - value supplied by the user.
set_interval_value() {
  local var_name="$1"
  local label="$2"
  local value="$3"
  require_positive_number "$label" "$value"
  printf -v "$var_name" '%s' "$value"
}


# format_interval_for_display
#   Format an interval in seconds to four decimal places for consistent logs.
#   Arguments:
#     $1 - interval value in seconds.
format_interval_for_display() {
  awk -v v="$1" 'BEGIN{printf "%.4f", v + 0}'
}


# gcd
gcd() { local a=$1 b=$2 t; while (( b )); do t=$((a % b)); a=$b; b=$t; done; echo "$a"; }


# normalize_interval_var
#   Replace an interval variable's value with a normalized formatted string.
#   Arguments:
#     $1 - variable name to update.
#     $2 - raw interval value.
normalize_interval_var() {
  local var_name="$1"
  local value="$2"
  local formatted
  formatted=$(format_interval_for_display "$value")
  printf -v "$var_name" '%s' "$formatted"
}


# timestamp
#   Emit a timezone-stable timestamp for log records.
#   Arguments: none; outputs 'YYYY-MM-DD - HH:MM:SS'.
timestamp() {
  TZ=America/Toronto date '+%Y-%m-%d - %H:%M:%S'
}


# capture_idle_state_snapshot
#   Capture the current cpuidle disable states so they can be restored later.
#   Arguments: none; prints name:disable pairs for each CPU idle state.
capture_idle_state_snapshot() {
  local cpu0_cpuidle="/sys/devices/system/cpu/cpu0/cpuidle"
  if [[ ! -d "$cpu0_cpuidle" ]]; then
    echo ""
    return
  fi
  local state_dir name disable_value
  for state_dir in "$cpu0_cpuidle"/state*; do
    [[ -d "$state_dir" ]] || continue
    if [[ -f "$state_dir/name" && -f "$state_dir/disable" ]]; then
      name=$(<"$state_dir/name")
      disable_value=$(<"$state_dir/disable")
      printf '%s:%s\n' "$name" "$disable_value"
    fi
  done
}


# restore_idle_states_from_snapshot
#   Restore cpuidle disable values from a snapshot string.
#   Arguments:
#     $1 - snapshot emitted by capture_idle_state_snapshot.
restore_idle_states_from_snapshot() {
  local snapshot="$1"
  [[ -n "$snapshot" ]] || return
  local line state_name disable_value cpu_dir state_dir name_file disable_file current_name
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    state_name="${line%%:*}"
    disable_value="${line#*:}"
    [[ -n "$state_name" && -n "$disable_value" ]] || continue
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
      [[ -d "$cpu_dir/cpuidle" ]] || continue
      for state_dir in "$cpu_dir"/cpuidle/state*; do
        [[ -d "$state_dir" ]] || continue
        name_file="$state_dir/name"
        disable_file="$state_dir/disable"
        [[ -f "$name_file" && -f "$disable_file" ]] || continue
        current_name=$(<"$name_file")
        if [[ "$current_name" == "$state_name" ]]; then
          echo "$disable_value" | sudo tee "$disable_file" >/dev/null 2>&1 || true
        fi
      done
    done
  done <<< "$snapshot"
}


# ensure_idle_states_disabled
#   Disable deep CPU idle states when requested, recording the previous settings.
#   Arguments: none; updates idle_state_snapshot/idle_states_modified.
ensure_idle_states_disabled() {
  if ! $disable_idle_states; then
    log_debug "Idle state modification skipped by user request"
    return
  fi
  if ! command -v cpupower >/dev/null 2>&1; then
    log_info "cpupower not available; skipping idle state adjustments"
    return
  fi
  idle_state_snapshot="$(capture_idle_state_snapshot)"
  if sudo cpupower idle-set --disable-by-latency 3 >/dev/null 2>&1; then
    idle_states_modified=true
    log_info "Disabled CPU idle states deeper than C1 (latency > 3 µs)"
  else
    log_info "Failed to disable deeper CPU idle states via cpupower"
  fi
}


# restore_idle_states_if_needed
#   Re-enable CPU idle states if they were disabled earlier in the run.
#   Arguments: none.
restore_idle_states_if_needed() {
  if ! $idle_states_modified; then
    return
  fi
  if command -v cpupower >/dev/null 2>&1; then
    if [[ -n "$idle_state_snapshot" ]]; then
      restore_idle_states_from_snapshot "$idle_state_snapshot"
      log_info "Restored CPU idle states to their previous configuration"
    else
      if sudo cpupower idle-set --enable-all >/dev/null 2>&1; then
        log_info "Re-enabled all CPU idle states"
      else
        log_info "Attempted to re-enable CPU idle states via cpupower, but the command failed"
      fi
    fi
  fi
}


# mount_resctrl_and_reset
#   Mount the resctrl filesystem and issue a pqos reset, logging commands when pqos logging is enabled.
#   Arguments: none.
mount_resctrl_and_reset() {
  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    log_debug "LLC exclusive partition active; skipping resctrl reset"
    export RDT_IFACE=OS
    return
  fi
  local pqos_log="${LOGDIR}/pqos.log"
  mkdir -p "${LOGDIR}"
  if $pqos_logging_enabled; then
    printf '[%s] mount_resctrl_and_reset: sudo umount /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
    sudo umount /sys/fs/resctrl >>"${pqos_log}" 2>&1 || true
    printf '[%s] mount_resctrl_and_reset: sudo mount -t resctrl resctrl /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
    sudo mount -t resctrl resctrl /sys/fs/resctrl >>"${pqos_log}" 2>&1
    printf '[%s] mount_resctrl_and_reset: sudo pqos -R\n' "$(timestamp)" >>"${pqos_log}"
    sudo pqos -R >>"${pqos_log}" 2>&1
  else
    sudo umount /sys/fs/resctrl >/dev/null 2>&1 || true
    sudo mount -t resctrl resctrl /sys/fs/resctrl >/dev/null 2>&1
    sudo pqos -R >/dev/null 2>&1
  fi
  export RDT_IFACE=OS
  if $pqos_logging_enabled; then
    printf '[%s] mount_resctrl_and_reset: export RDT_IFACE=OS\n' "$(timestamp)" >>"${pqos_log}"
  fi
}


# unmount_resctrl_quiet
#   Attempt to unmount resctrl unless an exclusive LLC partition is still active.
#   Arguments: none.
unmount_resctrl_quiet() {
  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    log_debug "LLC exclusive partition active; skipping resctrl unmount"
    return
  fi
  local pqos_log="${LOGDIR}/pqos.log"
  mkdir -p "${LOGDIR}"
  if $pqos_logging_enabled; then
    printf '[%s] unmount_resctrl_quiet: sudo umount /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
    sudo umount /sys/fs/resctrl >>"${pqos_log}" 2>&1 || true
  else
    sudo umount /sys/fs/resctrl >/dev/null 2>&1 || true
  fi
}


# secs_to_dhm
#   Format a duration in seconds as days/hours/minutes.
#   Arguments:
#     $1 - duration in seconds (negative values are treated as absolute).
secs_to_dhm() {
  local total=${1:-0}
  if (( total < 0 )); then
    total=$((-total))
  fi
  if (( total < 60 )); then
    printf '%ds' "${total}"
  elif (( total < 3600 )); then
    local minutes=$((total / 60))
    local seconds=$((total % 60))
    printf '%dm %ds' "${minutes}" "${seconds}"
  elif (( total < 86400 )); then
    local hours=$((total / 3600))
    local minutes=$(((total % 3600) / 60))
    printf '%dh %dm' "${hours}" "${minutes}"
  else
    local days=$((total / 86400))
    local hours=$(((total % 86400) / 3600))
    local minutes=$(((total % 3600) / 60))
    printf '%dd %dh %dm' "${days}" "${hours}" "${minutes}"
  fi
}


# prefix_lines
#   Read lines from stdin and log them with a fixed prefix.
#   Arguments:
#     $1 - prefix string to apply to each logged line.
prefix_lines() {
  local prefix="$1"
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    log_info "${prefix}: ${line}"
  done
}


# spawn_sidecar
#   Launch a background helper under sudo, capture its PID, and stream output to a log file.
#   Arguments:
#     $1 - human-readable helper name.
#     $2 - command to execute.
#     $3 - log file path.
#     $4 - shell variable that receives the child PID.
spawn_sidecar() {
  local name="$1"
  local cmd="$2"
  local logfile="$3"
  local pid_var="$4"

  log_info "Launching ${name} at $(timestamp): ${cmd}"
  local child
  if ! child="$(sudo -n bash -lc "exec ${cmd} </dev/null >>'${logfile}' 2>&1 & echo \\$!")"; then
    log_info "${name}: failed to launch (sudo exit $?)"
    printf -v "${pid_var}" ''
    return 1
  fi

  local pid
  pid="$(echo "${child}" | tr -d '[:space:]')"
  if [[ -z ${pid} ]]; then
    log_info "${name}: failed to capture pid"
    printf -v "${pid_var}" ''
    return 1
  fi

  log_info "${name}: started pid=${pid} at $(timestamp)"

  local proc_ready=false
  local attempt
  for attempt in {1..6}; do
    if [[ -e "/proc/${pid}" ]]; then
      proc_ready=true
      break
    fi
    sleep 0.05
  done
  if [[ ${proc_ready} != true ]]; then
    log_info "${name}: WARNING /proc/${pid} not available after wait"
  fi

  local pin_output=""
  local pin_rc=0
  pin_output="$(sudo -n taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)" || pin_rc=$?
  if (( pin_rc == 0 )); then
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_info "${name}: taskset -cp ${TOOLS_CPU} ${pid}: ${line}"
    done <<<"${pin_output}"
  else
    log_info "${name}: WARNING taskset -cp ${TOOLS_CPU} ${pid} failed (exit ${pin_rc})"
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_info "${name}: WARNING ${line}"
    done <<<"${pin_output}"
  fi

  ps -o pid,psr,comm -p "${pid}" 2>&1 | prefix_lines "${name}"
  taskset -cp "${pid}" 2>&1 | prefix_lines "${name}"
  printf -v "${pid_var}" '%s' "${pid}"
  return 0
}


# spawn_tstat
#   Start turbostat in its own session, record its PID, and pin it to TOOLS_CPU.
#   Arguments:
#     $1 - turbostat command line.
#     $2 - temporary pidfile path.
#     $3 - log file path.
spawn_tstat() {
  local cmd="$1" pidfile="$2" logfile="$3"
  local pid=""
  : >"${pidfile}"
  setsid bash -lc 'echo $$ > '"${pidfile}"'; exec '"${cmd}"'' </dev/null >>"${logfile}" 2>&1 &
  for i in {1..20}; do
    if [[ -s "${pidfile}" ]] && pid="$(<"${pidfile}")" && [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
      local pin_output="" pin_rc=0
      if pin_output="$(taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)"; then
        pin_rc=0
      else
        pin_rc=$?
        pin_output="$(sudo -n taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)" || pin_rc=$?
      fi
      if [[ -n ${pin_output} ]]; then
        printf '%s\n' "${pin_output}" >>"${logfile}"
      fi
      if (( pin_rc == 0 )); then
        while IFS= read -r line; do
          [[ -z ${line} ]] && continue
          log_info "turbostat: taskset -cp ${TOOLS_CPU} ${pid}: ${line}"
        done <<<"${pin_output}"
      else
        log_info "turbostat: WARNING taskset -cp ${TOOLS_CPU} ${pid} failed (exit ${pin_rc})"
        while IFS= read -r line; do
          [[ -z ${line} ]] && continue
          log_info "turbostat: WARNING ${line}"
        done <<<"${pin_output}"
      fi
      ps -o pid,psr,comm -p "${pid}" 2>&1 | tee -a "${logfile}" | prefix_lines "turbostat"
      taskset -cp "${pid}" 2>&1 | tee -a "${logfile}" | prefix_lines "turbostat"
      printf -v TURBOSTAT_PID '%s' "${pid}"
      return 0
    fi
    sleep 0.05
  done
  echo "[turbostat] failed to start" >>"${logfile}"
  return 1
}


# stop_gently
#   Attempt to stop a background process with escalating signals before giving up.
#   Arguments:
#     $1 - process label for logging.
#     $2 - PID to terminate.
stop_gently() {
  local name="$1"
  local pid="$2"

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} already stopped"
    return 0
  fi

  local wait_between=0.2

  log_info "Stopping ${name} pid=${pid} with SIGINT"
  kill -s INT "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} stopped after SIGINT"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGTERM"
  kill -s TERM "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} stopped after SIGTERM"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGKILL"
  kill -s KILL "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} still running after SIGKILL"
  else
    log_info "${name}: pid=${pid} stopped after SIGKILL"
  fi
}


# ensure_background_stopped
#   Verify that a background helper has exited; abort if the PID is still running.
#   Arguments:
#     $1 - process label for logging.
#     $2 - PID that should be stopped.
ensure_background_stopped() {
  local name="$1"
  local pid="$2"

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  if kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} still running after cleanup"
    echo "${name} is still running (pid=${pid}); aborting" >&2
    exit 1
  fi
}


# guard_no_pqos_active
#   Ensure no pqos process is already running before launching a new sampler.
#   Arguments: none.
guard_no_pqos_active() {
  local existing=""

  if [[ -n ${PQOS_PID:-} ]] && kill -0 "${PQOS_PID}" 2>/dev/null; then
    existing="${PQOS_PID}"
  fi

  if [[ -z ${existing} ]]; then
    existing="$(pgrep -x pqos 2>/dev/null || true)"
  fi

  if [[ -n ${existing} ]]; then
    log_info "Guardrail: pqos already running (pid(s): ${existing})"
    echo "pqos must not be running before starting this pass" >&2
    exit 1
  fi
}


# pids_pcm_power
#   Enumerate the PIDs of active pcm-power processes.
#   Arguments: none; prints a space-separated PID list.
pids_pcm_power() {
  local pids=""
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local comm
    comm="$(sudo cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "pcm-power" ]]; then
      pids+="${pids:+ }$pid"
    fi
  done < <(sudo pgrep -d$'\n' -f '(^|/| )pcm-power( |$)' 2>/dev/null || true)
  echo "$pids"
}


# pids_pcm_memory
#   Enumerate the PIDs of active pcm-memory processes.
#   Arguments: none; prints a space-separated PID list.
pids_pcm_memory() {
  local pids=""
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local comm
    comm="$(sudo cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "pcm-memory" ]]; then
      pids+="${pids:+ }$pid"
    fi
  done < <(sudo pgrep -d$'\n' -f '(^|/| )pcm-memory( |$)' 2>/dev/null || true)
  echo "$pids"
}


# debug_list_pcm_procs
#   Dump ps output for any live pcm-power or pcm-memory processes to aid debugging.
#   Arguments: none.
debug_list_pcm_procs() {
  local pp
  pp="$( {
      for p in $(pids_pcm_power); do echo "$p"; done
      for p in $(pids_pcm_memory); do echo "$p"; done
    } | tr ' ' '\n' | sort -u )"
  [[ -z "$pp" ]] && return 0
  echo "[DEBUG] Live PCM processes:"
  while IFS= read -r pid; do
    sudo ps -o pid,ppid,user,stat,etime,cmd= -p "$pid" 2>/dev/null || true
  done <<< "$pp"
}


# cleanup_pcm_processes
#   Send INT/TERM/KILL to lingering pcm-power and pcm-memory processes.
#   Arguments: none.
cleanup_pcm_processes() {
  local targets
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  [[ -z "$targets" ]] && return 0

  echo "[INFO] Cleaning up stray PCM processes: $targets"
  while IFS= read -r pid; do sudo kill -INT "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 1
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  while IFS= read -r pid; do sudo kill -TERM "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 1
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  while IFS= read -r pid; do sudo kill -KILL "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 0.3
}


# guard_no_pcm_active
#   Abort if any pcm-power or pcm-memory process is already running.
#   Arguments: none.
guard_no_pcm_active() {
  local pp
  pp="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  if [[ -n "$pp" ]]; then
    log_info "Guardrail: pcm tools still running (pid(s): $pp)"
    debug_list_pcm_procs
    echo "pcm-power/pcm-memory must be stopped before launching pqos" >&2
    exit 1
  fi
}


# start_turbostat
#   Launch turbostat pinned to the tools CPU and record its PID in an exported variable.
#   Arguments:
#     $1 - pass label for logging.
#     $2 - sampling interval in seconds.
#     $3 - CPU ID for turbostat affinity.
#     $4 - output file path.
#     $5 - shell variable that should receive the PID.
start_turbostat() {
  local pass="$1" interval="$2" cpu="$3" outfile="$4" varname="$5"
  log_debug "Launching turbostat ${pass} (output=${outfile}, tool core=${cpu}, workload core=${WORKLOAD_CPU})"
  taskset -c "$cpu" turbostat \
    --interval "$interval" \
    --quiet \
    --show Time_Of_Day_Seconds,CPU,Busy%,Bzy_MHz \
    --out "$outfile" &

  local ts_pid=$!
  export "$varname"="$ts_pid"
  echo "[INFO] turbostat ${pass}: started pid=${ts_pid}"
}


# stop_turbostat
#   Terminate a turbostat process with escalating signals and wait for exit.
#   Arguments:
#     $1 - PID to stop (ignored when empty).
stop_turbostat() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -INT "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -TERM "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}


# idle_wait
#   Pause the run until the system cools to a target temperature or a timeout elapses.
#   Arguments: none; honours IDLE_* environment overrides.
idle_wait() {
  local MIN_SLEEP="${IDLE_MIN_SLEEP:-45}"
  local TEMP_TARGET_MC="${IDLE_TEMP_TARGET_MC:-50000}"
  local TEMP_PATH="${IDLE_TEMP_PATH:-/sys/class/thermal/thermal_zone0/temp}"
  local MAX_WAIT="${IDLE_MAX_WAIT:-600}"
  local SLEEP_STEP=3
  local waited=0
  local message="minimum sleep ${MIN_SLEEP}s elapsed"

  log_debug "Idle wait parameters: min=${MIN_SLEEP}s target=${TEMP_TARGET_MC}mc path=${TEMP_PATH}"
  sleep "${MIN_SLEEP}"
  waited=$((waited+MIN_SLEEP))
  if [ -r "${TEMP_PATH}" ]; then
    while :; do
      t=$(cat "${TEMP_PATH}" 2>/dev/null || echo "")
      if [ -n "$t" ] && [ "$t" -le "$TEMP_TARGET_MC" ]; then
        message="temperature ${t}mc ≤ ${TEMP_TARGET_MC}mc"
        break
      fi
      if [ "$waited" -ge "$MAX_WAIT" ]; then
        message="timeout at ${waited}s; temperature ${t:-unknown}mc"
        break
      fi
      sleep "$SLEEP_STEP"
      waited=$((waited+SLEEP_STEP))
    done
  else
    message="temperature sensor unavailable"
  fi
  echo "Idle wait complete after ${waited}s (${message})"
  log_debug "Idle wait complete after ${waited}s (${message})"
  echo
}
