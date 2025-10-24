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


###############################################################################
# Always run child run_* scripts with sudo -E (preserve env, ensure root)
# - We still allow super_run.sh itself to be invoked however you like,
#   but children will be elevated explicitly with sudo -E.
###############################################################################
SUDO_BIN="$(command -v sudo || true)"
declare -a CHILD_SUDO_PREFIX=()
if [[ -n "${SUDO_BIN}" ]]; then
  CHILD_SUDO_PREFIX=("${SUDO_BIN}" -E)
fi

# Log what we’re doing so it’s visible in super_run.log
log_child_sudo_policy() {
  local who="$(id -un)"; local uid="$(id -u)"
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
REPEAT=1
SWEEPS=()
COMBOS=""
BASE_SET_LIST=()
DRY_RUN=false

declare -A base_kv=()

# ---- Allowed keys & helpers --------------------------------------------------
# EXACTLY your run_* flags (values: on/off/numbers/strings) + intervals.
ALLOWED_KEYS=(
  debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher
  toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all short long
  interval-toplev-basic interval-toplev-execution interval-toplev-full
  interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie
  interval-pqos interval-turbostat
)

# Run-script flags that are "bare" (present → enabled; no value when emitted)
BARE_FLAGS=( short long toplev-basic toplev-execution toplev-full maya pcm pcm-memory pcm-power pcm-pcie pcm-all )

# Run-script flags that take a value (accept both bare → "on" and explicit values)
VALUE_FLAGS=( debug turbo cstates pkgcap dramcap llc corefreq uncorefreq prefetcher \
              interval-toplev-basic interval-toplev-execution interval-toplev-full \
              interval-pcm interval-pcm-memory interval-pcm-power interval-pcm-pcie \
              interval-pqos interval-turbostat repeat )

# Truthy test used for bare flags and value flags when passed without a value.
_is_truthy(){ case "${1:-on}" in on|true|1|yes|enable|enabled) return 0;; *) return 1;; esac; }

# Normalize a flag token like "--pcm-power" → "pcm-power"
_normflag(){ printf '%s\n' "${1#--}"; }

# Sets for quick membership tests
is_bare_flag(){ local f; f="$(_normflag "$1")"; for x in "${BARE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }
is_value_flag(){ local f; f="$(_normflag "$1")"; for x in "${VALUE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }

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

collect_artifacts() { # $1 = replicate_dir (…/variant/{N})
  local out_dir="$1"
  [[ -n "$out_dir" ]] || return 0
  mkdir -p "${out_dir}/logs" "${out_dir}/output"

  # Copy run outputs (results)
  if [[ -d /local/data/results ]]; then
    shopt -s nullglob
    # Typical files: id_* from child run scripts
    for f in /local/data/results/id_*; do
      cp -f -- "$f" "${out_dir}/output/"
    done
    shopt -u nullglob
  fi

  # Copy logs from /local/logs except startup.log
  if [[ -d /local/logs ]]; then
    shopt -s nullglob
    for f in /local/logs/*.log; do
      [[ "$(basename "$f")" == "startup.log" ]] && continue
      cp -f -- "$f" "${out_dir}/logs/"
    done
    shopt -u nullglob
  fi
}

emit_child_argv() { # $1 = CSV override (k=v,k2=v2)
  local row_csv="$1"
  declare -A kv=()

  # 2a. Seed from baseline --set and any run-style flags parsed from CLI
  #     (base_kv must already exist where the parser stores run-style flags)
  for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done

  # 2b. Apply row overrides
  if [[ -n "$row_csv" ]]; then
    local IFS=,
    for pair in $row_csv; do
      [[ -z "$pair" ]] && continue
      local k="${pair%%=*}"
      local v="${pair#*=}"
      kv["$k"]="$v"
    done
  fi

  # 2c. Emit exactly once per logical flag
  declare -A printed=()
  # Emit bare flags first if truthy
  for k in "${BARE_FLAGS[@]}"; do
    [[ -n "${kv[$k]:-}" ]] || continue
    _is_truthy "${kv[$k]}" || continue
    printf -- '--%s\0' "$k"
    printed["$k"]=1
  done
  # Emit value flags (including "debug") with a single value
  for k in "${VALUE_FLAGS[@]}"; do
    [[ -n "${kv[$k]:-}" ]] || continue
    [[ -n "${printed[$k]:-}" ]] && continue
    local v="${kv[$k]}"
    if _is_truthy "$v" && ! is_bare_flag "--$k"; then
      # bare usage of a value flag → treat as "on"
      v="on"
    fi
    printf -- '--%s\0%s\0' "$k" "$v"
    printed["$k"]=1
  done

  # Emit any other keys (if present in baseline) as value flags once
  # (keeps forward compatibility with new keys that are not listed above)
  for k in "${!kv[@]}"; do
    [[ -n "${printed[$k]:-}" ]] && continue
    # Default to value-style emission
    printf -- '--%s\0%s\0' "$k" "${kv[$k]}"
    printed["$k"]=1
  done
}

apply_runstyle_arg() { # returns: 0=consumed flag only, 1=also consumed next value, 255=not run-style
  local tok="${1:-}"; shift || true
  [[ "$tok" == --* ]] || return 255
  local key="$(_normflag "$tok")"

  # --set/--sweep/--combos/--runs/--outdir/--repeat/--dry-run/--help are handled elsewhere
  case "$key" in
    set|sweep|combos|runs|outdir|dry-run|help) return 255;;
    repeat)
      # Prefer dedicated --repeat handler, but accept run-style too
      if [[ "$1" != "" && "$1" != --* ]]; then REPEAT="$1"; return 1; fi
      REPEAT=1; return 0;;
  esac

  # Known bare flag
  if is_bare_flag "--$key"; then
    base_kv["$key"]=on
    return 0
  fi
  # Known value flag
  if is_value_flag "--$key"; then
    if [[ "$1" != "" && "$1" != --* ]]; then
      base_kv["$key"]="$1"
      return 1
    else
      # value omitted (bare usage) → "on"
      base_kv["$key"]=on
      return 0
    fi
  fi
  return 255
}

while (($#)); do
  case "$1" in
    --runs)    IFS=',' read -r -a RUNS <<< "$2"; shift 2;;
    --sweep)   SWEEPS+=("$2"); shift 2;;
    --combos)  COMBOS="$2"; shift 2;;
    --outdir)  SUPER_OUTDIR="$2"; SUPER_LOG="$2/super_run.log"; mkdir -p "$2"; shift 2;;
    --repeat)  REPEAT="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --set)
      BASE_SET_LIST+=("$2")
      shift 2
      ;;
    -h|--help) usage; exit 0;;

    --*)
      set +e
      apply_runstyle_arg "$1" "${2:-}"
      rc=$?
      set -e
      case "$rc" in
        1) shift 2;;
        0) shift;;
        255)
             echo "[FATAL] Unknown arg: $1" | tee -a "${SUPER_LOG:-/dev/stderr}" >&2
             usage; exit 2;;
        *)
             echo "[FATAL] Unknown arg: $1" | tee -a "${SUPER_LOG:-/dev/stderr}" >&2
             usage; exit 2;;
      esac
      ;;

    *)
      echo "[FATAL] Unknown arg: $1" | tee -a "${SUPER_LOG:-/dev/stderr}" >&2
      usage; exit 2;;
  esac
done

if ((${#BASE_SET_LIST[@]})); then
  BASE_SET="$(IFS=,; printf '%s' "${BASE_SET_LIST[*]}")"
else
  BASE_SET=""
fi

if ((${#RUNS[@]}==0)); then
  log_f "You must provide --runs"
  exit 2
fi

# ---- Parse base set & sweeps -------------------------------------------------
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
log_d "  repeat (global): ${REPEAT}"
log_d "  outdir: ${SUPER_OUTDIR}"
log_d "  effective user: $(id -un) (uid=$(id -u))"
log_d "  effective group: $(id -gn) (gid=$(id -g))"
log_d ""
log_d "Configuration summary (baseline):"
log_line "$(log_child_sudo_policy)"
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
    row_repeat="${REPEAT}"
    declare -a row_pairs_filtered=()
    if [[ -n "$row" ]]; then
      while IFS= read -r -d '' k && IFS= read -r -d '' v; do
        if [[ "$k" == "repeat" ]]; then
          row_repeat="$v"
          continue
        fi
        row_pairs_filtered+=("${k}=${v}")
      done < <(parse_kv_csv "$row")
    fi
    # strip any repeat= from label
    label="${label//repeat-*/}" ; label="$(echo "$label" | sed 's/__$//; s/__+/_/g')"

    # Prepare argv
    args=()
    if ((${#row_pairs_filtered[@]})); then
      row_args_csv="$(IFS=,; printf '%s' "${row_pairs_filtered[*]}")"
    else
      row_args_csv=""
    fi
    while IFS= read -r -d '' word; do args+=("$word"); done < <(emit_child_argv "$row_args_csv")

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

        
if [[ -n "${SUDO_BIN}" ]]; then
  log_d "Launching (sudo -E) ${script} ${args[*]}"
  CHILD_CMD=("${CHILD_SUDO_PREFIX[@]}" "./${script}" "${args[@]}")
else
  log_w "sudo not found; launching without elevation: ${script} ${args[*]}"
  CHILD_CMD=("./${script}" "${args[@]}")
fi
(
  cd "${SCRIPT_DIR}"
  "${CHILD_CMD[@]}"
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
        replicate_dir="${subdir}"
        collect_artifacts "${replicate_dir}"
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
