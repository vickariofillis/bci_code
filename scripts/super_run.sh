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
# Key behavior (current repo behavior, not historical):
#   • Default OUTDIR: /local/data/results/super   (no timestamp)
#   • Sweeps are SEPARATE (not a cross-product).
#   • Combos (explicit rows) run AFTER sweeps.
#   • If sweeps/combos exist ⇒ no "base" variant. If only --set ⇒ one "base".
#   • Conflicts between --set and sweeps/combos are shown; prompt Y/N to proceed.
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
# - For --sweep: first token is the key, remaining tokens are values.
# - For --combos: use "combo" to start each row, followed by k v pairs;
#   repeat N inside a row overrides global --repeat for that row.
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

# Membership helpers
is_bare_flag(){ local f; f="$(_normflag "$1")"; for x in "${BARE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }
is_value_flag(){ local f; f="$(_normflag "$1")"; for x in "${VALUE_FLAGS[@]}"; do [[ "$x" == "$f" ]] && return 0; done; return 1; }

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

# ---- Artifact collection (results + logs) -----------------------------------
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
  local tok_in="${1-}"
  local s="$tok_in"
  if [[ "$s" =~ \.sh$ ]]; then
    [[ -x "${SCRIPT_DIR}/${s}" ]] || { log_f "Missing run script: ${s}"; exit 2; }
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
  tok="${argv[$i]:-}"
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
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}"; do
        RUNS+=("${argv[$i]}")
        ((++i))
      done
      ;;

    --set)
      ((++i))
      # Accept run_* style flags exactly as you would pass to run scripts.
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}"; do
        t="${argv[$i]}"
        if [[ "$t" == --* ]]; then
          key="$(_normflag "$t")"
          ((++i))
          if is_bare_flag "--$key"; then
            base_kv["$key"]="on"
            continue
          fi
          if is_value_flag "--$key"; then
            # If next token looks like a value, consume it; else implicit "on"
            if (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}" && [[ "${argv[$i]}" != --* ]]; then
              val="${argv[$i]}"; ((++i))
            else
              val="on"
            fi
            base_kv["$key"]="$val"
            continue
          fi
          # Unknown run_* flag -> allow passthrough with optional value
          if (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}" && [[ "${argv[$i]}" != --* ]]; then
            val="${argv[$i]}"; ((++i))
          else
            val="on"
          fi
          base_kv["$key"]="$val"
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
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}"; do
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
      while (( i < ${#argv[@]} )) && ! is_top_flag "${argv[$i]:-}"; do
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

# Require --runs
if ((${#RUNS[@]}==0)); then
  log_f "You must provide --runs"
  exit 2
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
  printf "[QUERY] Proceed anyway? [y/N]: "
  read -r ans
  case "${ans:-}" in
    y|Y|yes|YES) log_i "Proceeding despite conflicts." ;;
    *) log_f "Aborted by user due to conflicts." ; exit 3 ;;
  esac
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
have_script="$(command -v script || true)"

for run_token in "${RUNS[@]}"; do
  script="$(resolve_script "$run_token")"
  run_label="${script%.sh}"

  for row in "${plan_rows[@]}"; do
    label="$(label_for_csv "$row")"
    row_repeat="${REPEAT}"
    if [[ -n "$row" ]]; then
      while IFS= read -r -d '' k && IFS= read -r -d '' v; do
        if [[ "$k" == "repeat" ]]; then row_repeat="$v"; fi
      done < <(parse_kv_csv "$row")
    fi
    # Clean repeat from label
    label="${label//repeat-*/}"; label="$(echo "$label" | sed 's/__$//; s/__+/_/g')"

    # Child argv
    args=()
    while IFS= read -r -d '' word; do args+=("$word"); done < <(emit_child_argv "$row")

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
        # Path layout: <OUT>/run_1/<label>/[ri]/...
        variant_dir="${SUPER_OUTDIR}/${run_label}/${label}"
        [[ -n "$label" ]] || variant_dir="${SUPER_OUTDIR}/${run_label}/base"
        if (( row_repeat > 1 )); then
          subdir="${variant_dir}/${ri}"
        else
          subdir="${variant_dir}"
        fi
        mkdir -p "${subdir}"
        transcript="${subdir}/transcript.log"

        # Build child command (with sudo if available)
        if [[ -n "${SUDO_BIN}" ]]; then
          log_d "Launching (sudo -E) ${script} ${args[*]}"
          CHILD_CMD=("${CHILD_SUDO_PREFIX[@]}" "./${script}" "${args[@]}")
        else
          log_w "sudo not found; launching without elevation: ${script} ${args[*]}"
          CHILD_CMD=("./${script}" "${args[@]}")
        fi

        # Hint to disable color/ANSI if not interactive (child may ignore).
        CHILD_ENV=(env NO_COLOR=1 CLICOLOR=0 CLICOLOR_FORCE=0)

        if [[ -n "$have_script" ]]; then
          # Use a PTY so tmux (inside run_* scripts) sees a terminal.
          if command -v stdbuf >/dev/null 2>&1; then
            (
              cd "${SCRIPT_DIR}"
              cmd_str=""
              printf -v cmd_str '%q ' "${CHILD_CMD[@]}"
              "${CHILD_ENV[@]}" script -qfec "$cmd_str" /dev/null
            ) | stdbuf -oL -eL tee "${transcript}"
          else
            (
              cd "${SCRIPT_DIR}"
              cmd_str=""
              printf -v cmd_str '%q ' "${CHILD_CMD[@]}"
              "${CHILD_ENV[@]}" script -qfec "$cmd_str" /dev/null
            ) | tee "${transcript}"
          fi
          rc="${PIPESTATUS[0]}"
        else
          # Fallback: plain pipe (tmux may fail without TTY).
          if command -v stdbuf >/dev/null 2>&1; then
            (
              cd "${SCRIPT_DIR}"
              "${CHILD_ENV[@]}" "${CHILD_CMD[@]}"
            ) | stdbuf -oL -eL tee "${transcript}"
          else
            (
              cd "${SCRIPT_DIR}"
              "${CHILD_ENV[@]}" "${CHILD_CMD[@]}"
            ) | tee "${transcript}"
          fi
          rc="${PIPESTATUS[0]}"
        fi
      fi
      set -e

      end_ts="$(timestamp)"
      end_epoch="$(date +%s)"
      dur=$(( end_epoch - start_epoch ))
      log_d "${run_label} (${label}) exit code: ${rc}"

      # meta.json
      if ! $DRY_RUN; then
        # Reconstruct effective kvs for meta
        declare -A kv=()
        for k in "${!base_kv[@]}"; do kv["$k"]="${base_kv[$k]}"; done
        while IFS= read -r -d '' k && IFS= read -r -d '' v; do
          [[ "$k" == "repeat" ]] && continue
          kv["$k"]="$v"
        done < <(parse_kv_csv "$row")

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
            printf '    "%s": "%s"' "$k" "${kv[$k]}"
          done
          printf '\n  }\n'
          printf '}\n'
        } > "${meta}"
        log_d "Wrote ${meta}"
        collect_artifacts "${subdir}"
      fi

      # Summarize
      if (( rc==0 )); then
        log_i "${run_label} (${label}) replicate ${ri}/${row_repeat} completed in $(printf '%dm %ds' $((dur/60)) $((dur%60)))"
      else
        log_w "${run_label} (${label}) replicate ${ri}/${row_repeat} FAILED (rc=${rc}) after ${dur}s"
        overall_rc=$rc
      fi
    done
  done
done

log_line ""
log_line "All done. Super run output: ${SUPER_OUTDIR}"
exit "${overall_rc}"
