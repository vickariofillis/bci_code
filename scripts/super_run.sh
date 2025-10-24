#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

###############################################################################
# super_run.sh
#
# Orchestrates one or more run_* scripts across sweeps and/or combos.
# Writes:
#   - one super-run log (super_run.log) with run_* style formatting
#   - one meta.json per sub-run (knobs + timestamps + git rev + replicate idx)
# Collects per-run artifacts into:
#   <OUT>/run_<id>/<variant>/[<replicate>/]{logs/,output/,meta.json,transcript.log}
#
# Key behavior:
#   • Default OUTDIR: /local/data/results/super   (no timestamp)
#   • Sweeps are SEPARATE (not a cross-product).
#   • Combos (explicit rows) run AFTER sweeps.
#   • If sweeps/combos exist ⇒ no "base" variant. If only --set ⇒ one "base".
#   • Conflicts between --set and sweeps/combos are shown; prompt Y/N to proceed.
#   • Global repeat with --repeat N; per-combo repeat via repeat=N in that row.
#   • Boolean flags can be set via --set "short=on,pcm=1,..." and are emitted as
#     bare flags to run scripts.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

# ---- CLI --------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  super_run.sh \
    --runs "<id|name>[,<id|name>...]" \
    [--set "k=v,k2=v2,..."] \
    [--sweep "k=v1|v2|v3"] [--sweep "k2=x|y"] \
    [--combos "k=a,k2=b[,...][,repeat=N]; k=a2,k2=c[,...][,repeat=M]"] \
    [--repeat N] \
    [--outdir /path/to/out] \
    [--dry-run] [-h|--help]

Notes:
  * --runs accepts:
      1,3,13,
      20-rnn | 20-lm | 20-llm,
      or basenames like run_1.sh, run_20_3gram_rnn.sh
    Also accepts synonyms id1,id3,id13.
  * --set accepts comma-separated key=value pairs for baseline config.
    Exactly the run_* flags + intervals (see list below).
  * --sweep declares a SINGLE parameter with multiple choices (use multiple
    --sweep flags). Sweeps run SEPARATELY (not a cross-product).
  * --combos declares explicit rows separated by semicolons; each row is a
    comma-separated k=v list. Combos execute AFTER sweeps.
    Per-row repeat override supported: append ",repeat=N".
  * --repeat N sets the global replicate count (default 1).
  * Conflicts between --set and sweeps/combos are shown and require Y/N.

Allowed --set keys (exact):
  debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher
  toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all short long
  interval-toplev-basic interval-toplev-execution interval-toplev-full
  interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie
  interval-pqos interval-turbostat
USAGE
}

RUNS=()
BASE_SET=""        # "k=v,k2=v2"
SWEEPS=()          # ["k=v1|v2", "k2=x|y"]
COMBOS=""          # "k=a,k2=b; k=a,k2=c"
DRY_RUN=false
GLOBAL_REPEAT=1

while (($#)); do
  case "$1" in
    --runs)   IFS=',' read -r -a RUNS <<< "$2"; shift 2;;
    --set)    BASE_SET="$2"; shift 2;;
    --sweep)  SWEEPS+=("$2"); shift 2;;
    --combos) COMBOS="$2"; shift 2;;
    --repeat) GLOBAL_REPEAT="$2"; shift 2;;
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

# ---- Allowed keys & helpers --------------------------------------------------
# EXACTLY your run_* flags (values: on/off/numbers/strings) + intervals.
ALLOWED_KEYS=(
  debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher
  toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all short long
  interval-toplev-basic interval-toplev-execution interval-toplev-full
  interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie
  interval-pqos interval-turbostat
)

# Boolean-only flags that should be emitted as bare "--flag" (no value) when true-ish.
BOOLEAN_BARE_FLAGS=(
  toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all short long
)

declare -A allowed=()
for k in "${ALLOWED_KEYS[@]}"; do allowed["$k"]=1; done
declare -A bare_bool=()
for k in "${BOOLEAN_BARE_FLAGS[@]}"; do bare_bool["$k"]=1; done

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

parse_combo_rows() { # "$1" -> prints one NUL-separated kv block per row + a newline as delimiter
  local s="${1:-}"; [[ -z "$s" ]] && return 0
  local IFS=';'
  for row in $s; do
    row="$(echo "$row" | xargs)" # trim
    [[ -z "$row" ]] && continue
    parse_kv_csv "$row"
    printf '\n'
  done
}

git_rev() {
  ( git -C "${SCRIPT_DIR}" describe --dirty --always --tags 2>/dev/null ||
    git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null ) || echo "unknown"
}

safe_val_for_label() { # "7.5" -> "7_5"
  printf '%s' "$1" | sed -E 's/[^[:alnum:]\-\.]/_/g; s/\./_/g; s/_+/_/g; s/_$//'
}

label_for_csv() { # "k=v,k2=w" -> "k-v__k2-w" (order preserved)
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

# ---- Parse base set & sweeps -------------------------------------------------
declare -A base_kv=()
while IFS= read -r -d '' k && IFS= read -r -d '' v; do
  [[ -n "${allowed[$k]:-}" ]] || { log_f "Unknown --set key '$k'"; exit 2; }
  base_kv["$k"]="$v"
done < <(parse_kv_csv "$BASE_SET")

# SWEEPS are stored as (key -> array of values)
declare -A sweep_vals=()
declare -a sweep_keys=()
for spec in "${SWEEPS[@]}"; do
  local_key="${spec%%=*}"
  local_vals="${spec#*=}"
  [[ -n "${allowed[$local_key]:-}" ]] || { log_f "Unknown --sweep key '$local_key'"; exit 2; }
  IFS='|' read -r -a arr <<< "$local_vals"
  sweep_keys+=("$local_key")
  sweep_vals["$local_key"]="${arr[*]}"
done

# ---- Plan rows (SEPARATE sweeps, then combos) --------------------------------
# Each plan row is a CSV "k=v[,k2=v2...]"; sweeps create one-key rows only.
plan_rows=()

# 1) Sweeps: one row per value, each touching just that key
for k in "${sweep_keys[@]}"; do
  IFS=' ' read -r -a vals <<< "${sweep_vals[$k]}"
  for v in "${vals[@]}"; do
    v="$(echo "$v" | xargs)"
    plan_rows+=("${k}=${v}")
  done
done

# 2) Combos: append explicit rows (can include multiple k=v and repeat=N)
declare -a combo_rows_csv=()
if [[ -n "${COMBOS}" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    combo_rows_csv+=("$line")
  done < <(parse_combo_rows "$COMBOS")
  # Normalize formatting (remove accidental spaces around commas)
  for i in "${!combo_rows_csv[@]}"; do
    combo_rows_csv[$i]="$(echo "${combo_rows_csv[$i]}" | tr -s ' ' | sed 's/, /,/g')"
    plan_rows+=("${combo_rows_csv[$i]}")
  done
fi

# 3) Base row ONLY when there are no sweeps and no combos
if ((${#plan_rows[@]}==0)); then
  plan_rows+=("")
fi

# ---- Conflicts check (set vs overrides) -------------------------------------
# For combos we allow conflicts, but we must prompt Y/N. For sweeps too.
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
  printf "[QUERY] Proceed anyway? [y/N]: "
  read -r ans
  case "${ans:-}" in
    y|Y|yes|YES) log_i "Proceeding despite conflicts.";;
    *) log_f "Aborted by user due to conflicts."; exit 3;;
  esac
fi

# ---- Build argv for run_* ----------------------------------------------------
truthy() { [[ "${1,,}" =~ ^(1|true|on|yes)$ ]]; }

build_args() { # "$1" csv -> prints argv words (NUL-separated)
  local row="$1"
  declare -A kv=()
  for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do kv["$k"]="$v"; done < <(parse_kv_csv "$row")

  # --debug, --turbo, --cstates take explicit values (on/off)
  if [[ -n "${kv[debug]:-}" ]]; then printf -- '--debug\0%s\0' "${kv[debug]}"; fi
  if [[ -n "${kv[turbo]:-}" ]]; then printf -- '--turbo\0%s\0' "${kv[turbo]}"; fi
  if [[ -n "${kv[cstates]:-}" ]]; then printf -- '--cstates\0%s\0' "${kv[cstates]}"; fi

  # Emit booleans as bare flags when true-ish
  for key in "${!bare_bool[@]}"; do
    if [[ -n "${kv[$key]:-}" ]] && truthy "${kv[$key]}"; then
      printf -- '--%s\0' "$key"
      unset 'kv[$key]'
    fi
  done

  # Remaining keys as "--key value"
  for key in "${ALLOWED_KEYS[@]}"; do
    [[ -z "${kv[$key]:-}" ]] && continue
    printf -- '--%s\0%s\0' "$key" "${kv[$key]}"
  done
}

# ---- Script resolver ---------------------------------------------------------
resolve_script() { # prints script filename or exits 2
  local token="$1"
  local s="$token"

  # If explicit .sh given
  if [[ "$s" =~ \.sh$ ]]; then
    [[ -x "${SCRIPT_DIR}/${s}" ]] || { log_f "Missing run script: ${s}"; exit 2; }
    printf '%s\n' "$s"; return
  fi

  # synonyms idN -> N
  if [[ "$s" =~ ^id([0-9]+)$ ]]; then s="${BASH_REMATCH[1]}"; fi

  # plain numbers
  case "$s" in
    1|3|13) s="run_${s}.sh";;
    20-rnn) s="run_20_3gram_rnn.sh";;
    20-lm)  s="run_20_3gram_lm.sh";;
    20-llm) s="run_20_3gram_llm.sh";;
    *) s="run_${s}.sh";; # last resort (kept for compatibility)
  esac

  [[ -x "${SCRIPT_DIR}/${s}" ]] || { log_f "Missing run script: ${s}"; exit 2; }
  printf '%s\n' "$s"
}

# ---- File movers -------------------------------------------------------------
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
    log_w "MOVE VERIFY MISMATCH for $(basename "$dst"): size/head/tail differ; marking as suspect"
  fi
}

collect_into_tree() { # dest_dir
  local dest="$1"
  mkdir -p "${dest}/logs" "${dest}/output"

  # Results (id_* and other outputs)
  if [[ -d /local/data/results ]]; then
    shopt -s nullglob
    for f in /local/data/results/*; do
      move_with_verify "$f" "${dest}/output/$(basename "$f")"
    done
  fi

  # Logs
  if [[ -d /local/logs ]]; then
    shopt -s nullglob
    for f in /local/logs/*.log; do
      move_with_verify "$f" "${dest}/logs/$(basename "$f")"
    done
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
log_d "  repeat (global): ${GLOBAL_REPEAT}"
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

for run_token in "${RUNS[@]}"; do
  script="$(resolve_script "$run_token")"
  run_label="${script%.sh}"

  # Build concrete rows with their own repeat counts
  for row in "${plan_rows[@]}"; do
    # Determine label and repeat count
    label="$(label_for_csv "$row")"
    # Per-row repeat override (only for combos typically)
    row_repeat="${GLOBAL_REPEAT}"
    if [[ -n "$row" ]]; then
      while IFS= read -r -d '' k && IFS= read -r -d '' v; do
        if [[ "$k" == "repeat" ]]; then
          row_repeat="$v"
        fi
      done < <(parse_kv_csv "$row")
    fi
    # strip any repeat= from label
    label="${label//repeat-*/}" ; label="$(echo "$label" | sed 's/__$//; s/__+/_/g')"

    # Prepare argv
    args=()
    while IFS= read -r -d '' word; do args+=("$word"); done < <(build_args "$row")

    # Repeat loop
    for ((ri=1; ri<=row_repeat; ri++)); do
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
      else
        # Path layout:
        #   <OUT>/run_1/<label>/[ri]/...
        variant_dir="${SUPER_OUTDIR}/${run_label}/${label}"
        [[ -n "$label" ]] || variant_dir="${SUPER_OUTDIR}/${run_label}/base"
        if (( row_repeat > 1 )); then
          subdir="${variant_dir}/${ri}"
        else
          subdir="${variant_dir}"
        fi
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

      # meta.json (knobs + timestamps + git rev + replicate index)
      if ! $DRY_RUN; then
        # Recreate kv for meta
        declare -A kv=()
        for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
        while IFS= read -r -d '' k && IFS= read -r -d '' v; do kv["$k"]="$v"; done < <(parse_kv_csv "$row")

        meta="${subdir}/meta.json"
        {
          printf '{\n'
          printf '  "run_label": "%s",\n' "${run_label}"
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
            # For bare booleans we stored truthy strings; just record the value
            printf '    "%s": "%s"' "$k" "${kv[$k]}"
          done
          printf '\n  }\n'
          printf '}\n'
        } > "${meta}"
        log_d "Wrote ${meta}"
      fi

      # Collect artifacts into logs/ and output/ (no extra artifacts/ layer)
      if ! $DRY_RUN; then
        collect_into_tree "${subdir}"
      fi

      # Summarize to super log
      if (( rc==0 )); then
        log_i "${run_label} (${label}) replicate ${ri}/${row_repeat} completed in $(printf '%dm %ds' $((dur/60)) $((dur%60)))"
      else
        log_w "${run_label} (${label}) replicate ${ri}/${row_repeat} FAILED (rc=${rc}) after ${dur}s"
        overall_rc=$rc
      fi
    done # repeat loop
  done   # plan rows
done     # runs

log_line ""
log_line "All done. Super run output: ${SUPER_OUTDIR}"
exit "${overall_rc}"
