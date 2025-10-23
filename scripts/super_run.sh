#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

###############################################################################
# super_run.sh
#
# Orchestrates multiple run_* scripts across sweeps/combos. Writes:
#   - one super-run log (super_run.log) with the run_* style formatting
#   - one meta.json per sub-run (knobs + timestamps + git rev)
# Collects and MOVE+VERIFYs per-run artifacts into an outdir.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Try to source helpers for timestamp/log helpers; fall back if missing.
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
SUPER_OUTDIR_DEFAULT="${SCRIPT_DIR}/data/super_runs/$(date +'%Y%m%d_%H%M%S')"
SUPER_OUTDIR="${SUPER_OUTDIR_DEFAULT}"
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

# ---- Allowed keys for --set (validated) -------------------------------------
# EXACTLY the knobs your run scripts accept, plus intervals.
ALLOWED_KEYS=(
  debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher
  interval-toplev-basic interval-toplev-execution interval-toplev-full
  interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie
  interval-pqos interval-turbostat
)

usage() {
  cat <<'USAGE'
Usage:
  super_run.sh --runs "<id1,id2,...|file1,file2,...>" \
               [--set "k=v,k2=v2,..."] \
               [--sweep "k=v1|v2|v3"] [--sweep "k2=x|y"] \
               [--combos "k=a,k2=b; k=a,k2=c; ..."] \
               [--outdir /path/to/out] [--dry-run]

Notes:
  * --runs accepts numeric IDs (e.g., 1,3,13,20_3gram_rnn) which map to run_<ID>.sh,
    OR explicit script basenames (e.g., run_1.sh, run_20_3gram_rnn.sh).
  * --set accepts comma-separated key=value pairs for baseline config.
    Allowed keys (exact):
      debug, turbo, cstates, pkgcap, dramcap, llc, corefreq, uncorefreq, prefetcher,
      interval-toplev-basic, interval-toplev-execution, interval-toplev-full,
      interval-pcm, interval-pcm-memory, interval-pcm-power, interval-pcm-pcie,
      interval-pqos, interval-turbostat
  * --sweep declares a single parameter with multiple choices (use multiple
    --sweep flags for multiple parameters). Cross-product is used across sweeps.
  * --combos declares explicit combo rows separated by semicolons; each row is
    a comma-separated k=v list. If --combos is present, --sweep is ignored.
  * Conflicts: If --set defines a key, neither --sweep nor --combos may change it.
    The script validates this up front and aborts with a clear error.
  * A per-run meta.json is written beside collected artifacts; a single
    super_run.log captures the orchestration with run-style formatting.
USAGE
}

RUNS=()
BASE_SET=""           # "k=v,k2=v2"
SWEEPS=()             # ["k=v1|v2", "k2=x|y"]
COMBOS=""             # "k=a,k2=b; k=a,k2=c"
DRY_RUN=false

while (($#)); do
  case "$1" in
    --runs)   IFS=',' read -r -a RUNS <<< "$2"; shift 2;;
    --set)    BASE_SET="$2"; shift 2;;
    --sweep)  SWEEPS+=("$2"); shift 2;;
    --combos) COMBOS="$2"; shift 2;;
    --outdir) SUPER_OUTDIR="$2"; SUPER_LOG="$2/super_run.log"; mkdir -p "$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_f "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ((${#RUNS[@]}==0)); then
  log_f "You must provide --runs"
  exit 2
fi

# ---- Helpers: parsing & validation ------------------------------------------
declare -A base_kv=()
declare -A allowed=()
for k in "${ALLOWED_KEYS[@]}"; do allowed["$k"]=1; done

parse_kv_csv() { # "$1" -> prints "key\0value\0" for each pair
  local s="${1:-}"; [[ -z "$s" ]] && return 0
  local IFS=,
  for pair in $s; do
    [[ -z "$pair" ]] && continue
    local key="${pair%%=*}"
    local val="${pair#*=}"
    printf '%s\0%s\0' "$key" "$val"
  done
}

parse_combo_rows() { # "$1" -> prints one NUL-separated kv block per row
  local s="${1:-}"; [[ -z "$s" ]] && return 0
  local IFS=';'
  for row in $s; do
    row="$(echo "$row" | xargs)" # trim
    [[ -z "$row" ]] && continue
    parse_kv_csv "$row"
    printf '\n' # row delimiter
  done
}

declare -A sweep_map=()    # key -> "v1|v2|..."
declare -a sweep_keys=()

# Fill base_kv
while IFS= read -r -d '' k && IFS= read -r -d '' v; do
  [[ -n "${allowed[$k]:-}" ]] || { log_f "Unknown --set key '$k'"; exit 2; }
  base_kv["$k"]="$v"
done < <(parse_kv_csv "$BASE_SET")

# Parse sweeps
for spec in "${SWEEPS[@]}"; do
  local_key="${spec%%=*}"
  local_vals="${spec#*=}"
  [[ -n "${allowed[$local_key]:-}" ]] || { log_f "Unknown --sweep key '$local_key'"; exit 2; }
  sweep_map["$local_key"]="$local_vals"
  sweep_keys+=("$local_key")
done

# Build plan rows (array of "k=v,k2=v2")
plan_rows=()
if [[ -n "${COMBOS}" ]]; then
  # explicit combos; ignore sweeps
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    row_csv=""
    # shellcheck disable=SC2046
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [[ -n "${allowed[$k]:-}" ]] || { log_f "Unknown --combos key '$k'"; exit 2; }
      row_csv+="${row_csv:+,}${k}=${v}"
    done < <(printf '%s' "$line")
    plan_rows+=("$row_csv")
  done < <(parse_combo_rows "$COMBOS")
else
  # Cartesian product of sweeps (possibly zero sweeps -> single empty row)
  if ((${#sweep_keys[@]}==0)); then
    plan_rows+=("")
  else
    rows=('')
    for k in "${sweep_keys[@]}"; do
      IFS='|' read -r -a vals <<< "${sweep_map[$k]}"
      new_rows=()
      for r in "${rows[@]}"; do
        for v in "${vals[@]}"; do
          v="$(echo "$v" | xargs)"
          new_rows+=("${r}${r:+,}${k}=${v}")
        done
      done
      rows=("${new_rows[@]}")
    done
    plan_rows=("${rows[@]}")
  fi
fi

# Validate conflicts: no override may change a --set value.
conflicts=()
for row in "${plan_rows[@]}"; do
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    if [[ -n "${base_kv[$k]:-}" && "${base_kv[$k]}" != "$v" ]]; then
      conflicts+=("$k: base='${base_kv[$k]}' vs override='${v}'")
    fi
  done < <(parse_kv_csv "$row")
done
if ((${#conflicts[@]})); then
  log_f "Configuration conflict(s) between --set and sweep/combo overrides:"
  for c in "${conflicts[@]}"; do log_f "  - ${c}"; done
  exit 2
fi

label_for_row() { # "$1" csv -> safe label
  local csv="$1"
  if [[ -z "$csv" ]]; then echo "base"; return; fi
  echo "$csv" | tr ',' '__' | tr '=' '-' | tr -c '[:alnum:]_:-' '_'
}

build_args() { # "$1" csv -> prints argv words (NUL-separated)
  local row="$1"
  declare -A kv=()
  for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do kv["$k"]="$v"; done < <(parse_kv_csv "$row")

  # debug=on -> --debug on (your runners expect a value)
  if [[ -n "${kv[debug]:-}" ]]; then printf -- '--debug\0%s\0' "${kv[debug]}"; fi

  # materialize the rest as --key value
  for key in "${ALLOWED_KEYS[@]}"; do
    [[ "$key" == "debug" ]] && continue
    if [[ -n "${kv[$key]:-}" ]]; then
      printf -- '--%s\0%s\0' "$key" "${kv[$key]}"
    fi
  done
}

git_rev() {
  ( git -C "${SCRIPT_DIR}" describe --dirty --always --tags 2>/dev/null ||
    git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null ) || echo "unknown"
}

move_with_verify() { # src dst
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  local sz_src head_src tail_src
  sz_src=$(stat -c '%s' "$src" 2>/dev/null || echo 0)
  head_src="$(head -n 20 "$src" 2>/dev/null || true)"
  tail_src="$(tail -n 20 "$src" 2>/dev/null || true)"
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  local sz_dst head_dst tail_dst
  sz_dst=$(stat -c '%s' "$dst" 2>/dev/null || echo 0)
  head_dst="$(head -n 20 "$dst" 2>/dev/null || true)"
  tail_dst="$(tail -n 20 "$dst" 2>/dev/null || true)"
  if [[ "$sz_src" != "$sz_dst" || "$head_src" != "$head_dst" || "$tail_src" != "$tail_dst" ]]; then
    log_w "MOVE VERIFY MISMATCH for $(basename "$dst"): size/head/tail differ; leaving file in place but marking as suspect"
  fi
}

# ---- Banner & context --------------------------------------------------------
log_d "Debug logging enabled (state=$( [[ "${base_kv[debug]:-off}" == "on" ]] && echo on || echo off ))"
log_d "Disable deeper idle states request: $( [[ "${base_kv[cstates]:-on}" == "on" ]] && echo on || echo off )"
log_d ""
log_d "Invocation context:"
log_d "  script path: ${SCRIPT_DIR}/super_run.sh"
log_d "  runs: ${RUNS[*]}"
log_d "  base --set: ${BASE_SET:-<empty>}"
((${#SWEEPS[@]})) && log_d "  sweeps: ${SWEEPS[*]}"
[[ -n "${COMBOS}" ]] && log_d "  combos: ${COMBOS}"
log_d "  outdir: ${SUPER_OUTDIR}"
log_d "  effective user: $(id -un) (uid=$(id -u))"
log_d "  effective group: $(id -gn) (gid=$(id -g))"
log_d ""
log_d "Configuration summary (baseline):"
log_d "  $(printf '%s\n' "${BASE_SET:-<none>}")"
log_d ""

$DRY_RUN && log_i "DRY RUN: planning only; no commands will be executed."

# ---- Execute plan ------------------------------------------------------------
overall_rc=0
rev="$(git_rev)"

for run_id in "${RUNS[@]}"; do
  script="${run_id}"
  if [[ ! "$script" =~ \.sh$ ]]; then
    script="run_${run_id}.sh"
  fi
  if [[ ! -x "${SCRIPT_DIR}/${script}" ]]; then
    log_f "Missing run script: ${script}"
    exit 2
  fi

  run_label="${script%.sh}"

  for row in "${plan_rows[@]}"; do
    label="$(label_for_row "$row")"
    args=()
    while IFS= read -r -d '' word; do args+=("$word"); done < <(build_args "$row")

    log_line ""
    log_line "################################################################################"
    log_line "### Executing ${run_label} (${label})"
    log_line "################################################################################"
    log_line ""

    start_ts="$(timestamp)"
    start_epoch="$(date +%s)"

    set +e
    if $DRY_RUN; then
      log_d "DRY RUN: would invoke: ${script} ${args[*]}"
      rc=0
    else
      subdir="${SUPER_OUTDIR}/${run_label}/${label}"
      mkdir -p "${subdir}"
      transcript="${subdir}/transcript.log"
      log_d "Launching ${script} ${args[*]}"
      (
        cd "${SCRIPT_DIR}"
        "./${script}" "${args[@]}"
      ) | tee "${transcript}"
      rc="${PIPESTATUS[0]}"
    fi
    set -e

    end_ts="$(timestamp)"
    end_epoch="$(date +%s)"
    dur=$(( end_epoch - start_epoch ))
    log_d "${run_label} (${label}) exit code: ${rc}"

    # meta.json (knobs + timestamps + git rev)
    if ! $DRY_RUN; then
      declare -A kv=()
      for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
      while IFS= read -r -d '' k && IFS= read -r -d '' v; do kv["$k"]="$v"; done < <(parse_kv_csv "$row")

      meta="${subdir}/meta.json"
      {
        printf '{\n'
        printf '  "run_label": "%s",\n' "${run_label}"
        printf '  "variant_label": "%s",\n' "${label}"
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
    fi

    # Collect artifacts from /local/data/results and /local/logs (if present)
    if ! $DRY_RUN; then
      dest="${SUPER_OUTDIR}/${run_label}/${label}/artifacts"
      mkdir -p "${dest}"
      if [[ -d /local/data/results ]]; then
        shopt -s nullglob
        for f in /local/data/results/id_*; do
          move_with_verify "$f" "${dest}/$(basename "$f")"
        done
      fi
      if [[ -d /local/logs ]]; then
        mkdir -p "${dest}/logs"
        shopt -s nullglob
        for f in /local/logs/*.log; do
          move_with_verify "$f" "${dest}/logs/$(basename "$f")"
        done
      fi
    fi

    # Summarize to super log; include tail of transcript on error
    if (( rc==0 )); then
      log_i "${run_label} (${label}) completed in $(printf '%dm %ds' $((dur/60)) $((dur%60)))"
    else
      log_w "${run_label} (${label}) FAILED (rc=${rc}) after ${dur}s"
      overall_rc=$rc
    fi
  done
done

log_line ""
log_line "All done. Super run output: ${SUPER_OUTDIR}"
exit "${overall_rc}"
