#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
# --- Root + tmux (bci) auto-wrap (safe attach-or-create) ---
# Absolute path to this script for safe re-exec
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REAL="${SCRIPT_DIR}/$(basename "$0")"

# Ensure we always bounce through the tmux auto-wrapper, even when the user
# invoked the script via sudo directly.
if [[ -z ${BCI_TMUX_AUTOWRAP:-} ]]; then
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E env -u TMUX BCI_TMUX_AUTOWRAP=1 "$SCRIPT_REAL" "$@"
  else
    exec env -u TMUX BCI_TMUX_AUTOWRAP=1 "$SCRIPT_REAL" "$@"
  fi
fi

# Ensure root so the tmux server/session are root-owned
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: super_run.sh must run with sudo (auto-wrapper failed)" >&2
  exit 1
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
# ensure downstream commands do not inherit the sentinel
unset BCI_TMUX_AUTOWRAP || true
# --- end auto-wrap ---

###############################################################################
# super_run.sh
#
# Orchestrates one or more run_* scripts across sweeps and/or combos.
# Writes:
#   - one super-run log (super_run.log) with run_* style formatting
#   - one meta.json per sub-run (knobs + timestamps + git rev + replicate idx)
# Collects per-run artifacts into:
#   <OUT>/<run_label>/<mode>/<variant>/<replicate>/{logs/,output/,meta.json,transcript.log}
#     • ID3: mode from --id3-compressor ("flac" → flac, "blosc-zstd" → zstd; default flac)
#     • Others (id1, id13, id20_*): mode "default" for now (extensible later)
#
# Key behavior (current repo behavior, not historical):
#   • Default OUTDIR: /local/data/results/super   (no timestamp)
#   • Sweeps are SEPARATE (not a cross-product).
#   • Combos (explicit rows) run AFTER sweeps.
#   • If sweeps/combos exist ⇒ no "base" variant. If only --set ⇒ one "base".
#   • Conflicts between --set and sweeps/combos are shown; prompt Y/N to proceed.
#     (If not running on a TTY, we auto-proceed and log a warning.)
#   • Global repeat with --repeat N; per-combo repeat via "repeat N" in that row.
#   • Boolean flags can be set via --set and are emitted as bare flags.
#   • Child run_* scripts are ALWAYS launched via "sudo -E" (env preserved).
#
# CLI GRAMMAR (no quotes, no commas, no pipes, no semicolons):
#   --runs 1 3 13
#   --set --debug --short --pkgcap 15
#   --sweep pkgcap 8 15 30
#   --sweep corefreq 0.75 2.4
#   --combos combo pkgcap 8 dramcap 10 combo llc 80 prefetcher 0011 repeat 2
#   --repeat 3
#   --outdir /path
#   --dry-run
#
# Notes:
# - Everything after each top-level flag belongs to that flag until the next
#   top-level flag arrives. Top-level flags are:
#     --runs, --set, --sweep, --combos, --repeat, --outdir, --dry-run, -h, --help
# - For --set: pass the run_* flags exactly as you would to run_*.sh.
#   (Bare boolean value flags like --debug/--turbo/--cstates are accepted.)
# - For --sweep: first token is the key, remaining tokens are values.
# - For --combos: use "combo" to start each row, followed by k v pairs;
#   repeat N inside a row overrides global --repeat for that row.
###############################################################################

cd "${SCRIPT_DIR}"

# Optional helpers.sh for timestamp/log helpers; fall back if missing.
if [[ -f "${SCRIPT_DIR}/helpers.sh" ]]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/helpers.sh"
else
  log_info(){ printf '[INFO] %s\n' "$*"; }
  log_debug(){ printf '[DEBUG] %s\n' "$*"; }
  log_warn(){ printf '[WARN] %s\n' "$*"; }
  timestamp(){ date '+%Y-%m-%d - %H:%M:%S'; }
fi

# ---- Super log setup --------------------------------------------------------
SUPER_OUTDIR="/local/data/results/super"
SUPER_LOG="${SUPER_OUTDIR}/super_run.log"
mkdir -p "${SUPER_OUTDIR}"

# tee-like logging helpers (prefix aligns with run_* style)
log_line(){ printf '%s\n' "$*" | tee -a "${SUPER_LOG}"; }
log_d(){ printf '[DEBUG] %s\n' "$*" | tee -a "${SUPER_LOG}"; }
log_i(){ printf '[INFO] %s\n' "$*" | tee -a "${SUPER_LOG}"; }
log_w(){ printf '[WARN] %s\n' "$*" | tee -a "${SUPER_LOG}"; }
log_f(){ printf '[FATAL] %s\n' "$*" | tee -a "${SUPER_LOG}"; }

# Trap to catch unexpected failures (mirrors helpers.on_error tone)
on_error_super() {
  local rc=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  log_f "$(basename "$0"): line ${line}: '${cmd}' exited with ${rc}"
  exit "$rc"
}
trap on_error_super ERR

###############################################################################
# Always run child run_* scripts with sudo -E (preserve env, ensure root).
# super_run.sh itself may be invoked as you wish; children are elevated here.
###############################################################################
SUDO_BIN="$(command -v sudo || true)"
declare -a CHILD_SUDO_PREFIX=()
if [[ -n "${SUDO_BIN}" ]]; then
  CHILD_SUDO_PREFIX=("${SUDO_BIN}" -E)
fi

# Log what we’re doing so it’s visible in super_run.log
log_child_sudo_policy() {
  local who; who="$(id -un)" || who="unknown"
  local uid; uid="$(id -u)" || uid="?"
  if [[ -n "${SUDO_BIN}" ]]; then
    printf '[DEBUG] Child sudo policy: ALWAYS (using "sudo -E"); super_run.sh user: %s (uid=%s)\n' "$who" "$uid"
  else
    printf '[WARN] sudo not found; child runs will NOT be elevated. super_run.sh user: %s (uid=%s)\n' "$who" "$uid"
  fi
}

# ---- CLI --------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  super_run.sh \
    --runs <id|name> [<id|name> ...] \
    [--set <run-flags...>] \
    [--sweep <key> <v1> [<v2> ...]] \
    [--combos combo <k1> <v1> [<k2> <v2> ...] [repeat <N>] [combo ...]] \
    [--repeat <N>] \
    [--outdir /path/to/out] \
    [--dry-run] [-h|--help]

Examples:
  --runs 1 3 13
  --set --debug --short --pkgcap 15
  --sweep pkgcap 8 15 30
  --sweep corefreq 0.75 2.4
  --combos combo pkgcap 8 dramcap 10 combo llc 80 prefetcher 0011 repeat 2
USAGE
}

# Top-level parser state
RUNS=()
REPEAT=1
SWEEPS_ROWS=()   # array of CSV strings: "key=val"
COMBO_ROWS=()    # array of CSV strings: "k=v,k2=v2[,repeat=N]"
DRY_RUN=false
BASE_OUTDIR_SET=false

# Baseline settings collected from --set (exact run_* flags)
declare -A base_kv=()

# ---- Allowed keys & helpers --------------------------------------------------
# EXACTLY your run_* flags (values: on/off/numbers/strings) + intervals.
ALLOWED_KEYS=(
  debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher id1-mode id1-channels id3-compressor
  toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all short long
  interval-toplev-basic interval-toplev-execution interval-toplev-full
  interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie
  interval-pqos interval-turbostat
)

# Run-script flags that are "bare" (present → enabled; no value when emitted)
BARE_FLAGS=( short long toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all )

# Value flags (some of these accept bare as "on" if no value is provided)
VALUE_FLAGS=( debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher \
              id1-mode id1-channels id3-compressor \
              interval-toplev-basic interval-toplev-execution interval-toplev-full \
              interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie \
              interval-pqos interval-turbostat repeat )

# Which value-flags can be safely treated as boolean when passed bare:
BOOLY_VALUE_FLAGS=( debug turbo cstates )

# Truthy test used for bare flags and value flags when passed without a value.
_is_truthy(){ case "${1:-on}" in on|true|1|yes|enable|enabled) return 0;; *) return 1;; esac; }

# Normalize a flag token like "--pcm-power" → "pcm-power"
_normflag(){ printf '%s\n' "${1#--}"; }

# Membership helpers
is_bare_flag(){ local f; f="$(_normflag "$1")"; for x in "${BARE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }
is_value_flag(){ local f; f="$(_normflag "$1")"; for x in "${VALUE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }
is_booly_value(){ local f; f="$(_normflag "$1")"; for x in "${BOOLY_VALUE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }

declare -A allowed=()
for k in "${ALLOWED_KEYS[@]}"; do allowed["$k"]=1; done

# Utility: safe value for labels
safe_val_for_label() { # "7.5" -> "7_5"
  printf '%s' "$1" | sed -E 's/[^[:alnum:]\-\.]/_/g; s/\./_/g; s/_+/_/g; s/_$//'
}

# Utility: label builder from CSV "k=v[,k2=v2...]"
label_for_csv() {
  local csv="$1"
  [[ -z "$csv" ]] && { echo "base"; return; }
  local IFS=, out=() pair k v
  for pair in $csv; do
    k="${pair%%=*}"; v="${pair#*=}"
    out+=("${k}-$(safe_val_for_label "$v")")
  done
  local joined
  IFS='__'; joined="${out[*]}"
  printf '%s\n' "$joined"
}

# Map script names to result directory labels.
run_label_for_script() {
  case "$(basename "$1")" in
    run_1.sh)            printf 'id1' ;;
    run_3.sh)            printf 'id3' ;;
    run_13.sh)           printf 'id13' ;;
    run_20_3gram_rnn.sh) printf 'id20_rnn' ;;
    run_20_3gram_lm.sh)  printf 'id20_lm' ;;
    run_20_3gram_llm.sh) printf 'id20_llm' ;;
    *)                   printf '%s' "${1%.sh}" ;;
  esac
}

# Derive a filesystem-safe mode string for one run.
# Extension points:
#   - When ID1 adds feature-stripping modes, branch on run_label "id1" and
#     inspect the chosen ID1 knob(s) here to map them into stable mode names.
#   - When ID20 RNN/LM/LLM introduce model-selection knobs, add branches for
#     run_label "id20_rnn"/"id20_lm"/"id20_llm" that convert those knobs into
#     descriptive mode strings.
mode_for_run() {
  local run_label="$1"
  local row_csv="${2:-}"

  # Effective knobs = baseline (--set) overlaid with row overrides.
  declare -A kv_effective=()
  local k v
  for k in "${!base_kv[@]}"; do kv_effective["$k"]="${base_kv[$k]}"; done
  if [[ -n "$row_csv" ]]; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [[ "$k" == "repeat" ]] && continue
      kv_effective["$k"]="$v"
    done < <(parse_kv_csv "$row_csv")
  fi

  local mode_raw="default"
  case "$run_label" in
    id3)
      local compressor="${kv_effective[id3-compressor]:-}"
      if [[ -n "$compressor" ]]; then
        compressor="$(echo "${compressor}" | tr '[:upper:]' '[:lower:]')"
        case "$compressor" in
          flac) mode_raw="flac" ;;
          blosc-zstd) mode_raw="zstd" ;;
          *) mode_raw="${compressor}" ;; # future-proof passthrough
        esac
      else
        mode_raw="flac"
      fi
      ;;
    *)
      mode_raw="default"
      ;;
  esac

  local mode_clean
  mode_clean="$(safe_val_for_label "$(echo "${mode_raw}" | tr '[:upper:]' '[:lower:]')")"
  [[ -n "${mode_clean}" ]] || mode_clean="default"
  printf '%s\n' "${mode_clean}"
}

# Utility: parse "k=v,k2=v2" → print "k\0v\0k2\0v2\0"
parse_kv_csv() {
  local s="${1:-}"; [[ -z "$s" ]] && return 0
  local IFS=,
  for pair in $s; do
    [[ -z "$pair" ]] && continue
    local key="${pair%%=*}"
    local val="${pair#*=}"
    printf '%s\0%s\0' "$key" "$val"
  done
}

# Utility: render base_kv to a stable CSV string for logging
render_base_csv() {
  local acc=()
  for k in "${ALLOWED_KEYS[@]}"; do
    if [[ -n "${base_kv[$k]:-}" ]]; then
      acc+=("${k}=${base_kv[$k]}")
    fi
  done
  if ((${#acc[@]}==0)); then
    echo "<none>"
  else
    local IFS=,
    echo "${acc[*]}"
  fi
}

# ---- Artifact collation (results + logs) ------------------------------------
collect_artifacts() { # $1 = replicate_dir (…/variant/{N})
  local out_dir="$1"
  [[ -n "$out_dir" ]] || return 0
  mkdir -p "${out_dir}/logs" "${out_dir}/output"

  # Results from /local/data/results (e.g., id_1_* files)
  if [[ -d /local/data/results ]]; then
    shopt -s nullglob
    # move both extension-less and with extensions
    for f in /local/data/results/id_*; do
      [[ "$(basename "$f")" == "super" ]] && continue
      mv -f -- "$f" "${out_dir}/output/" 2>/dev/null || true
    done
    shopt -u nullglob
  fi

  # Logs from /local/logs (avoid startup.log)
  if [[ -d /local/logs ]]; then
    shopt -s nullglob
    for f in /local/logs/*.log; do
      [[ "$(basename "$f")" == "startup.log" ]] && continue
      mv -f -- "$f" "${out_dir}/logs/" 2>/dev/null || true
    done
    shopt -u nullglob
  fi
}

# ---- Child argv emission (de-dup, correct shapes) ---------------------------
emit_child_argv() { # $1 = CSV override (k=v,k2=v2)
  local row_csv="$1"
  declare -A kv=()

  # Seed with baseline (--set) then apply row overrides
  for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done

  # Apply row overrides
  if [[ -n "$row_csv" ]]; then
    local IFS=,
    for pair in $row_csv; do
      [[ -z "$pair" ]] && continue
      local k="${pair%%=*}"
      local v="${pair#*=}"
      [[ "$k" == "repeat" ]] && continue
      kv["$k"]="$v"
    done
  fi

  # Emit flags once
  declare -A printed=()
  # Bare flags first
  for k in "${BARE_FLAGS[@]}"; do
    [[ -n "${kv[$k]:-}" ]] || continue
    _is_truthy "${kv[$k]}" || continue
    printf -- '--%s\0' "$k"
    printed["$k"]=1
  done
  # Value flags
  for k in "${VALUE_FLAGS[@]}"; do
    [[ "$k" == "repeat" ]] && continue
    [[ -n "${kv[$k]:-}" ]] || continue
    [[ -n "${printed[$k]:-}" ]] && continue
    local v="${kv[$k]}"
    if _is_truthy "$v" && ! is_bare_flag "--$k"; then v="on"; fi
    printf -- '--%s\0%s\0' "$k" "$v"
    printed["$k"]=1
  done
  # Any other keys
  for k in "${!kv[@]}"; do
    [[ -n "${printed[$k]:-}" ]] && continue
    printf -- '--%s\0%s\0' "$k" "${kv[$k]}"
    printed["$k"]=1
  done
}

# ---- Script resolver ---------------------------------------------------------
resolve_script() {
  local token="$1"
  local s="$token"
  if ([[ "$s" =~ \.sh$ ]] && [[ -x "${SCRIPT_DIR}/${s}" ]]); then
    printf '%s\n' "$s"; return
  fi
  if [[ "$s" =~ ^id([0-9]+)$ ]]; then s="${BASH_REMATCH[1]}"; fi
  case "$s" in
    1|3|13) s="run_${s}.sh";;
    20-rnn) s="run_20_3gram_rnn.sh";;
    20-lm)  s="run_20_3gram_lm.sh";;
    20-llm) s="run_20_3gram_llm.sh";;
    *) s="run_${s}.sh";;
  esac
  [[ -x "${SCRIPT_DIR}/${s}" ]] || { log_f "Missing run script: ${s}"; exit 2; }
  printf '%s\n' "$s"
}

# ---- Top-level flag identification ------------------------------------------
is_top_flag() {
  case "${1:-}" in
    --runs|--set|--sweep|--combos|--repeat|--outdir|--dry-run|-h|--help) return 0;;
    *) return 1;;
  esac
}

# ---- Parse argv (quote-free grammar) ----------------------------------------
OUTDIR="${SUPER_OUTDIR}"
argv=("$@")
i=0
while (( i < ${#argv[@]} )); do
  tok="${argv[$i]}"
  case "$tok" in
    -h|--help) usage; exit 0;;

    --outdir)
      ((++i)); [[ $i -lt ${#argv[@]} ]] || { log_f "--outdir needs a path"; exit 2; }
      OUTDIR="${argv[$i]}"
      SUPER_OUTDIR="${OUTDIR}"; SUPER_LOG="${OUTDIR}/super_run.log"
      BASE_OUTDIR_SET=true
      mkdir -p "${OUTDIR}"
      ((++i))
      ;;

    --dry-run)
      DRY_RUN=true
      ((++i))
      ;;

    --repeat)
      ((++i)); [[ $i -lt ${#argv[@]} ]] || { log_f "--repeat needs a number"; exit 2; }
      REPEAT="${argv[$i]}"
      ((++i))
      ;;

    --runs)
      ((++i))
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]}"; do
        RUNS+=("${argv[$i]}")
        ((++i))
      done
      ;;

    --set)
      ((++i))
      # Accept run_* style flags exactly as you would pass to run scripts.
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]}"; do
        t="${argv[$i]}"
        if [[ "$t" == --* ]]; then
          key="$(_normflag "$t")"
          if is_bare_flag "$t"; then
            base_kv["$key"]="on"
            ((++i)); continue
          fi
          if is_value_flag "$t"; then
            # If next is missing, next is another flag, or next is a top flag:
            if (( i+1 >= ${#argv[@]} )) || [[ "${argv[$((i+1))]}" == --* ]] || is_top_flag "${argv[$((i+1))]}"; then
              if is_booly_value "$t"; then
                base_kv["$key"]="on"
                ((++i)); continue
              else
                log_f "--$key needs a value"
              fi
            fi
            ((++i)); val="${argv[$i]}"
            base_kv["$key"]="$val"
            ((++i)); continue
          fi
          # Unknown run_* flag -> treat as needs a value
          if (( i+1 >= ${#argv[@]} )) || [[ "${argv[$((i+1))]}" == --* ]] || is_top_flag "${argv[$((i+1))]}"; then
            log_f "Unknown flag '--$key' needs a value"
          fi
          ((++i)); val="${argv[$i]}"
          base_kv["$key"]="$val"
          ((++i))
        else
          log_f "Unexpected token in --set: '${t}'. Use run_* flags like --debug, --short, --pkgcap 15."
        fi
      done
      ;;

    --sweep)
      ((++i)); [[ $i -lt ${#argv[@]} ]] || { log_f "--sweep needs a key"; exit 2; }
      sweep_key="${argv[$i]}"
      [[ -n "${allowed[$sweep_key]:-}" ]] || { log_f "Unknown --sweep key '${sweep_key}'"; exit 2; }
      ((++i)); added=0
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]}"; do
        v="$(echo "${argv[$i]}" | xargs)"
        SWEEPS_ROWS+=("${sweep_key}=${v}")
        added=1
        ((++i))
      done
      (( added == 1 )) || { log_f "--sweep ${sweep_key} needs at least one value"; exit 2; }
      ;;

    --combos)
      ((++i))
      # Grammar: combo k v [k v ...] [repeat N] [combo ...]
      have_row=0
      row_pairs=()
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]}"; do
        t="${argv[$i]}"
        if [[ "$t" == "combo" ]]; then
          # finish previous row if any
          if (( have_row )); then
            COMBO_ROWS+=("$(IFS=,; echo "${row_pairs[*]}")")
            row_pairs=()
          fi
          have_row=1
          ((++i)); continue
        fi
        # expect key value pairs
        key="$t"; ((++i)); [[ $i -lt ${#argv[@]} ]] || { log_f "--combos: key '${key}' missing value"; exit 2; }
        val="${argv[$i]}"
        if [[ "$key" == "repeat" ]]; then
          row_pairs+=("repeat=${val}")
        else
          [[ -n "${allowed[$key]:-}" ]] || { log_f "Unknown combo key '${key}'"; exit 2; }
          row_pairs+=("${key}=${val}")
        fi
        ((++i))
      done
      if (( have_row )); then
        COMBO_ROWS+=("$(IFS=,; echo "${row_pairs[*]}")")
      fi
      ;;

    *)
      log_f "Unknown arg: $tok"
      ;;
  esac
done

# If --runs not provided, auto-detect the run script in this directory.
if ((${#RUNS[@]}==0)); then
  candidates=()
  [[ -x "${SCRIPT_DIR}/run_1.sh" ]]  && candidates+=("1")
  [[ -x "${SCRIPT_DIR}/run_3.sh" ]]  && candidates+=("3")
  [[ -x "${SCRIPT_DIR}/run_13.sh" ]] && candidates+=("13")
  # ID-20 segments
  id20_candidates=()
  [[ -x "${SCRIPT_DIR}/run_20_3gram_rnn.sh" ]]  && { candidates+=("20-rnn"); id20_candidates+=("20-rnn"); }
  [[ -x "${SCRIPT_DIR}/run_20_3gram_lm.sh"  ]]  && { candidates+=("20-lm");  id20_candidates+=("20-lm"); }
  [[ -x "${SCRIPT_DIR}/run_20_3gram_llm.sh" ]] && { candidates+=("20-llm"); id20_candidates+=("20-llm"); }

  if ((${#candidates[@]}==0)); then
    log_f "No --runs and no run_* scripts found in ${SCRIPT_DIR}. Please provide --runs."
    exit 2
  fi

  if ((${#id20_candidates[@]}>=2)) && ((${#id20_candidates[@]}==${#candidates[@]})); then
    # Multiple ID-20 variants present → prompt for segment on TTY
    if [[ -t 0 ]]; then
      printf "[QUERY] Detected ID-20 workload with multiple segments. Choose one [rnn|lm|llm]: "
      read -r seg
      case "${seg}" in
        rnn) RUNS=("20-rnn");;
        lm)  RUNS=("20-lm");;
        llm) RUNS=("20-llm");;
        *) log_f "Invalid segment '${seg}'. Please run with --runs 20-rnn|20-lm|20-llm."; exit 2;;
      esac
      log_i "Auto-selected run: ${RUNS[*]} (by prompt)"
    else
      log_f "Detected multiple ID-20 segments but no TTY to prompt. Run with --runs 20-rnn|20-lm|20-llm."
      exit 2
    fi
  elif ((${#candidates[@]}==1)); then
    RUNS=("${candidates[0]}")
    log_i "No --runs provided; auto-detected run '${RUNS[*]}' from present run_* script(s)."
  else
    # Multiple but not the ID-20-only case → require explicit --runs
    log_f "Multiple run_* scripts present (${candidates[*]}) but no --runs. Please specify --runs."
    exit 2
  fi
fi

# ---- Plan rows (SEPARATE sweeps, then combos; base only if none) -------------
plan_rows=()
for s in "${SWEEPS_ROWS[@]}"; do plan_rows+=("$s"); done
for c in "${COMBO_ROWS[@]}"; do plan_rows+=("$c"); done
if ((${#plan_rows[@]}==0)); then plan_rows+=(""); fi

# ---- Conflicts check (set vs overrides) -------------------------------------
declare -a conflicts=()
for row in "${plan_rows[@]}"; do
  [[ -z "$row" ]] && continue
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    [[ "$k" == "repeat" ]] && continue
    if [[ -n "${base_kv[$k]:-}" && "${base_kv[$k]}" != "$v" ]]; then
      conflicts+=("  - ${k}: base='${base_kv[$k]}' vs override='${v}' (row='${row}')")
    fi
  done < <(parse_kv_csv "$row")
done
if ((${#conflicts[@]})); then
  log_w "Configuration conflict(s) detected between --set and overrides:"
  for c in "${conflicts[@]}"; do log_w "$c"; done
  if [[ -t 0 ]]; then
    printf "[QUERY] Proceed anyway? [y/N]: "
    read -r ans
    case "${ans:-}" in
      y|Y|yes|YES) log_i "Proceeding despite conflicts." ;;
      *) log_f "Aborted by user due to conflicts." ; exit 3 ;;
    esac
  else
    log_w "Non-interactive context: proceeding despite conflicts."
  fi
fi

# ---- Banner & context --------------------------------------------------------
log_d "Debug logging enabled (state=$( [[ "${base_kv[debug]:-off}" == "on" ]] && echo on || echo off ))"
log_d "Disable deeper idle states request: $( [[ "${base_kv[cstates]:-on}" == "on" ]] && echo on || echo off )"
log_d ""
log_d "Invocation context:"
log_d "  script path: ${SCRIPT_DIR}/super_run.sh"
log_d "  runs: ${RUNS[*]}"
log_d "  base --set: $(render_base_csv)"
((${#SWEEPS_ROWS[@]})) && log_d "  sweeps: ${SWEEPS_ROWS[*]}"
((${#COMBO_ROWS[@]}))  && log_d "  combos: ${COMBO_ROWS[*]}"
log_d "  repeat (global): ${REPEAT}"
log_d "  outdir: ${SUPER_OUTDIR}"
log_d "  effective user: $(id -un) (uid=$(id -u))"
log_d "  effective group: $(id -gn) (gid=$(id -g))"
log_d ""
log_line "$(log_child_sudo_policy)"
log_d "Configuration summary (baseline):"
log_d "  $(render_base_csv)"
log_d ""
$DRY_RUN && log_i "DRY RUN: planning only; no commands will be executed."

# ---- Execute plan ------------------------------------------------------------
overall_rc=0
git_rev() {
  ( git -C "${SCRIPT_DIR}" describe --dirty --always --tags 2>/dev/null ||
    git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null ) || echo "unknown"
}
rev="$(git_rev)"

# Guard: ensure emit_child_argv exists before first use (catch broken merges)
if ! declare -F emit_child_argv >/dev/null; then
  log_f "Internal error: missing emit_child_argv"; exit 2
fi

# Optional stdbuf to keep tee lines tidy
STDBUF_BIN="$(command -v stdbuf || true)"

# Precompute per-row repeat and the global max repeat across rows.
declare -A row_repeat_for=()
max_repeat="${REPEAT}"
for row in "${plan_rows[@]}"; do
  row_rep="${REPEAT}"
  if [[ -n "$row" ]]; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [[ "$k" == "repeat" ]] && row_rep="$v"
    done < <(parse_kv_csv "$row")
  fi
  row_key="${row:-__base__}"
  row_repeat_for["$row_key"]="$row_rep"
  (( row_rep > max_repeat )) && max_repeat="$row_rep"
done

# NEW ORDER: replicate first → then runs → then rows (sweeps first, then combos).
for ((ri=1; ri<=max_repeat; ri++)); do
  for run_token in "${RUNS[@]}"; do
    script="$(resolve_script "$run_token")"
    run_label="$(run_label_for_script "${script}")"

    for row in "${plan_rows[@]}"; do
      row_key="${row:-__base__}"
      row_repeat="${row_repeat_for[$row_key]}"
      # Skip this row for replicates beyond its repeat count (honors per-row repeat N).
      (( ri > row_repeat )) && continue

      label="$(label_for_csv "$row")"
      # Clean "repeat=…" from label if present.
      label="${label//repeat-*/}"
      label="$(echo "$label" | sed 's/__$//; s/__+/_/g')"

      mode="$(mode_for_run "${run_label}" "${row}")"
      [[ -n "${mode}" ]] || mode="default"

      # Child argv for this row (merge --set with row overrides, emit bare/value flags).
      args=()
      while IFS= read -r -d '' word; do args+=("$word"); done < <(emit_child_argv "$row")

      log_line ""
      log_line "################################################################################"
      if (( row_repeat > 1 )); then
        log_line "### Executing ${run_label} (${label}) [replicate ${ri}/${row_repeat}]"
      else
        log_line "### Executing ${run_label} (${label})"
      fi
      log_line "################################################################################"
      log_line ""

      start_ts="$(timestamp)"
      start_epoch="$(date +%s)"

      set +e
      if $DRY_RUN; then
        log_d "DRY RUN: would invoke: ${script} ${args[*]}"
        rc=0
        dest_dir=""
      else
        # Layout: <OUT>/<run_label>/<mode>/<variant>/<ri>/...
        label_or_base="${label:-base}"
        variant_dir="${SUPER_OUTDIR}/${run_label}/${mode}/${label_or_base}"
        dest_dir="${variant_dir}/${ri}"
        mkdir -p "${dest_dir}"
        transcript="${dest_dir}/transcript.log"

        # Force non-interactive behavior in child:
        CHILD_ENV=(env TERM=dumb NO_COLOR=1)
        script_abs="${SCRIPT_DIR}/${script}"

        if [[ -n "${SUDO_BIN}" ]]; then
          log_d "Launching (sudo -E) ${script} ${args[*]}"
          CHILD_CMD=("${CHILD_SUDO_PREFIX[@]}" "${CHILD_ENV[@]}" "${script_abs}" "${args[@]}")
        else
          log_w "sudo not found; launching without elevation: ${script} ${args[*]}"
          CHILD_CMD=("${CHILD_ENV[@]}" "${script_abs}" "${args[@]}")
        fi

        (
          cd "${SCRIPT_DIR}"
          if [[ -n "${STDBUF_BIN}" ]]; then
            "${STDBUF_BIN}" -oL -eL "${CHILD_CMD[@]}" < /dev/null
          else
            "${CHILD_CMD[@]}" < /dev/null
          fi
        ) | tee "${transcript}"
        rc="${PIPESTATUS[0]}"
      fi
      set -e

      end_ts="$(timestamp)"
      end_epoch="$(date +%s)"
      dur=$(( end_epoch - start_epoch ))
      log_d "${run_label} (${label}) exit code: ${rc}"

      if ! $DRY_RUN; then
        # meta.json reflecting effective knobs and replicate index
        declare -A kv=()
        for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
        while IFS= read -r -d '' k && IFS= read -r -d '' v; do
          [[ "$k" == "repeat" ]] && continue
          kv["$k"]="$v"
        done < <(parse_kv_csv "$row")

        meta="${dest_dir}/meta.json"
        {
          printf '{\n'
          printf '  "run_label": "%s",\n' "${run_label}"
          printf '  "mode": "%s",\n' "${mode}"
          printf '  "variant_label": "%s",\n' "${label:-base}"
          printf '  "replicate_index": %d,\n' "${ri}"
          printf '  "script": "%s",\n' "${script}"
          printf '  "git_rev": "%s",\n' "${rev}"
          printf '  "started_at": "%s",\n' "${start_ts}"
          printf '  "finished_at": "%s",\n' "${end_ts}"
          printf '  "duration_sec": %d,\n' "${dur}"
          printf '  "exit_code": %d,\n' "${rc}"
          printf '  "knobs": {\n'
          first=1
          for k in "${ALLOWED_KEYS[@]}"; do
            [[ -z "${kv[$k]:-}" ]] && continue
            if (( first )); then first=0; else printf ',\n'; fi
            printf '    "%s": "%s"' "$k" "${kv[$k]}"
          done
          printf '\n  }\n'
          printf '}\n'
        } > "${meta}"
        log_d "Wrote ${meta}"

        # Collect artifacts into logs/ and output/
        collect_artifacts "${dest_dir}"

        # Summarize human-readable duration for this run variant
        log_i "${run_label} (${label}) replicate ${ri}/${row_repeat} completed in $(printf '%dm %ds' $((dur/60)) $((dur%60)))"
      else
        log_i "DRY RUN: ${run_label} (${label}) replicate ${ri}/${row_repeat} planned"
      fi

      # Bubble up non-zero RC but do not abort the remaining plan.
      if (( rc != 0 )); then
        log_w "${run_label} (${label}) replicate ${ri}/${row_repeat} FAILED (rc=${rc}) after ${dur}s"
        overall_rc=$rc
      fi

    done  # rows
  done    # runs
done      # replicates

log_line ""
log_line "All done. Super run output: ${SUPER_OUTDIR}"
exit "${overall_rc}"
