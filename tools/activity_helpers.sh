# tools/activity_helpers.sh
# shellcheck shell=bash

set -Eeuo pipefail

: "${BCI_HEARTBEAT_PERIOD_SECS:=${BCI_HB_SECS:-120}}"
: "${BCI_STATUS_PERIOD_SECS:=${BCI_SNAP_SECS:-600}}"

BCI_ACTIVITY_FAILURE=0

: "${ACTIVITY_DIR:=/local/activity}"
: "${STATUS_LOG:=${ACTIVITY_DIR}/status.log}"
: "${STATUS_CUR:=${ACTIVITY_DIR}/status.current}"
: "${STATUS_PID:=${ACTIVITY_DIR}/status.pid}"

GLOBAL_STATUS_HEADER="# bci global activity (rolling 50 lines) — key=value pairs: ts phase tmux pid sid tty load rss_mb free_gb cwd"
PER_ID_STATUS_HEADER="# bci per-id activity (rolling 50 lines) — key=value pairs: ts phase tmux pid sid tty load rss_mb free_gb cwd"

_tmux_display() {
  if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
    tmux display-message -p "$1" 2>/dev/null || echo "tmux-na"
  else
    echo "no-tmux"
  fi
}

_bci_write_status_files() {
  local log_file="$1" current_file="$2" header="$3" line="$4"

  mkdir -p "$(dirname "${log_file}")"
  [[ -f "${log_file}" ]] || printf '%s\n' "${header}" > "${log_file}"
  [[ -f "${current_file}" ]] || printf '%s\n' "${header}" > "${current_file}"

  printf '%s\n' "${line}" >> "${log_file}" 2>/dev/null || true

  local data_tmp
  data_tmp="$(mktemp "${log_file}.data.XXXXXX")" || return 0
  tail -n +2 "${log_file}" 2>/dev/null | tail -n 50 > "${data_tmp}" 2>/dev/null || true

  local tmp_log tmp_cur
  tmp_log="$(mktemp "${log_file}.XXXXXX")" || { rm -f "${data_tmp}"; return 0; }
  {
    printf '%s\n' "${header}"
    cat "${data_tmp}"
  } > "${tmp_log}"
  mv -f "${tmp_log}" "${log_file}" 2>/dev/null || true

  tmp_cur="$(mktemp "${current_file}.XXXXXX")" || { rm -f "${data_tmp}"; return 0; }
  {
    printf '%s\n' "${header}"
    cat "${data_tmp}"
  } > "${tmp_cur}"
  mv -f "${tmp_cur}" "${current_file}" 2>/dev/null || true

  rm -f "${data_tmp}"
  chmod 0644 "${log_file}" "${current_file}" || true
}

activity_dir_for_id() {
  local id="$1"
  echo "/local/activity/${id}"
}

ensure_activity_dirs() {
  local id="$1"
  local d; d="$(activity_dir_for_id "${id}")"
  mkdir -p "${d}"
  [[ -f "${d}/phase" ]] || : > "${d}/phase"
  if [[ ! -f "${d}/status.log" ]]; then
    printf '%s\n' "${PER_ID_STATUS_HEADER}" > "${d}/status.log"
  fi
  if [[ ! -f "${d}/status.current" ]]; then
    printf '%s\n' "${PER_ID_STATUS_HEADER}" > "${d}/status.current"
  fi
  chmod 0644 "${d}/phase" "${d}/status.log" "${d}/status.current" || true
}

bci_compose_status_line() {
  local ts
  ts="$(date -Is)"

  local phase="${BCI_STATUS_PHASE:-${BCI_PHASE:-${PHASE:-}}}"
  if [[ -z "${phase}" && -n "${BCI_STATUS_ID:-}" ]]; then
    local phase_file="${ACTIVITY_DIR}/${BCI_STATUS_ID}/phase"
    if [[ -f "${phase_file}" ]]; then
      local phase_line
      phase_line="$(cat "${phase_file}" 2>/dev/null || true)"
      if [[ -n "${phase_line}" ]]; then
        phase="$(printf "%s\n" "${phase_line}" | awk '{for(i=1;i<=NF;i++) if($i ~ /^phase=/){sub(/^phase=/,"",$i); print $i; exit}}')"
      fi
    fi
  fi

  local pid="${BCI_STATUS_CALLER_PID:-$$}"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    pid="$$"
  fi

  local sid="${BCI_STATUS_CALLER_SID:-}"
  if [[ -z "${sid}" && "${pid}" =~ ^[0-9]+$ ]]; then
    sid="$(ps -o sid= -p "${pid}" 2>/dev/null | awk '{print $1}' | tr -d ' ' || true)"
  fi
  local tty="${BCI_STATUS_CALLER_TTY:-}"
  [[ -n "${tty}" ]] || tty="$(ps -o tty= -p "${pid}" 2>/dev/null | awk '{print $1}' | tr -d ' ' || true)"
  [[ -n "${tty}" ]] || tty="n/a"

  local tmux_session tmux_pane
  tmux_session="$(_tmux_display '#S')"
  tmux_pane="$(_tmux_display '#S:#I.#P')"
  local tmux_field
  tmux_field="${tmux_session}:${tmux_pane}"

  local cwd
  cwd="${BCI_STATUS_CWD:-$(pwd)}"

  local load
  if load="$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)"; then
    :
  else
    load="n/a n/a n/a"
  fi

  local rss_mb=0
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    local rss_kb
    rss_kb="$(ps -o rss= -p "${pid}" 2>/dev/null | awk '{print $1}' | tr -d ' ' || true)"
    if [[ "${rss_kb}" =~ ^[0-9]+$ ]]; then
      rss_mb=$(( (10#${rss_kb} + 1023) / 1024 ))
    else
      rss_mb=0
    fi
  fi

  local free_gb
  free_gb="$(df -Pm /local 2>/dev/null | awk 'NR==2{printf("%.1f", $4/1024)}')"
  [[ -n "${free_gb}" ]] || free_gb="0.0"

  printf 'ts=%s\tphase=%s\ttmux=%s\tpid=%s\tsid=%s\ttty=%s\tload=%s\trss_mb=%s\tfree_gb=%s\tcwd=%s' \
    "${ts}" \
    "${phase:-unknown}" \
    "${tmux_field}" \
    "${pid}" \
    "${sid:-n/a}" \
    "${tty}" \
    "${load}" \
    "${rss_mb}" \
    "${free_gb}" \
    "${cwd}"
}

# Overwrite with a single, human-readable line
# usage: write_phase <id> <phase> <label> <rep>
write_phase() {
  local id="$1" phase="$2" label="$3" rep="$4"
  local d; d="$(activity_dir_for_id "${id}")"
  printf "%s  phase=%s  label=%s  rep=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${phase}" "${label}" "${rep}" \
    > "${d}/phase"
}

# Run a command immune to TTY/SIGHUP loss; wait for completion
# usage: run_in_new_session -- <cmd> [args...]
run_in_new_session() {
  [ "${1:-}" = "--" ] && shift
  if setsid -w true >/dev/null 2>&1; then
    setsid -w "$@"
  else
    setsid "$@" </dev/null >/dev/null 2>&1 &
    local pid="$!"; wait "${pid}"
  fi
}

# Background detached (rarely needed)
# usage: run_detached <pidfile> -- <cmd> [args...]
run_detached() {
  local pidfile="$1"; shift
  [ "${1:-}" = "--" ] && shift
  nohup setsid "$@" </dev/null >/dev/null 2>&1 &
  echo "$!" > "${pidfile}"
}

# Heartbeat: zero growth, only mtime changes
# Heartbeat period (secs): BCI_HEARTBEAT_PERIOD_SECS (fallback: BCI_HB_SECS)
start_heartbeat() {
  local tag="$1"
  [[ -z "${tag:-}" ]] && return 0

  mkdir -p "${ACTIVITY_DIR}"
  local log="${ACTIVITY_DIR}/heartbeat.${tag}.log"
  local pidfile="${ACTIVITY_DIR}/heartbeat.${tag}.pid"
  touch "${log}"

  if [[ -f "${pidfile}" ]]; then
    local existing
    existing="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${existing}" && -d "/proc/${existing}" ]]; then
      if tr '\0' '\n' < "/proc/${existing}/environ" 2>/dev/null | grep -q '^BCI_HEARTBEAT_LOOP=1$'; then
        return 0
      fi
    fi
  fi
  rm -f "${pidfile}"

  local d=""
  if [[ -n "${tag}" ]]; then
    d="$(activity_dir_for_id "${tag}")"
    mkdir -p "${d}"
  fi

  (
    BCI_HEARTBEAT_LOOP=1
    export BCI_HEARTBEAT_LOOP
    while :; do
      printf '%s\talive\t%s\n' "$(date -Is)" "${tag}" >> "${log}" 2>/dev/null || true
      tmp="$(mktemp "${log}.XXXXXX")" || exit 0
      tail -n 50 "${log}" > "${tmp}" 2>/dev/null || true
      mv -f "${tmp}" "${log}" 2>/dev/null || true
      sleep "${BCI_HEARTBEAT_PERIOD_SECS}"
    done
  ) >/dev/null 2>&1 &
  local loop_pid=$!
  echo "${loop_pid}" > "${pidfile}"
  [[ -n "${d}" ]] && echo "${loop_pid}" > "${d}/heartbeat.pid"
  disown || true
  chmod 0644 "${log}" || true
}

# Rolling snapshots: keep header + last 50 lines by default
# Status snapshot period (secs): BCI_STATUS_PERIOD_SECS (fallback: BCI_SNAP_SECS)
start_status_snapshots() {
  local id="$1" label="${2:-}" rep="${3:-}"
  local d=""
  if [[ -n "${id:-}" ]]; then
    ensure_activity_dirs "${id}"
    d="$(activity_dir_for_id "${id}")"
  fi

  mkdir -p "${ACTIVITY_DIR}"

  if [[ -f "${STATUS_PID}" ]]; then
    local existing
    existing="$(cat "${STATUS_PID}" 2>/dev/null || true)"
    if [[ -n "${existing}" && -d "/proc/${existing}" ]]; then
      if tr '\0' '\n' < "/proc/${existing}/environ" 2>/dev/null | grep -q '^BCI_STATUS_SNAPSHOT_LOOP=1$'; then
        return 0
      fi
    fi
  fi
  rm -f "${STATUS_PID}"

  local caller_pid="$$"
  local caller_sid
  caller_sid="$(ps -o sid= -p "${caller_pid}" 2>/dev/null | awk '{print $1}' || true)"
  local caller_tty
  caller_tty="$(ps -o tty= -p "${caller_pid}" 2>/dev/null | awk '{print $1}' || true)"

  (
    BCI_STATUS_SNAPSHOT_LOOP=1
    export BCI_STATUS_SNAPSHOT_LOOP
    BCI_STATUS_ID="${id}"
    BCI_STATUS_CALLER_PID="${caller_pid}"
    BCI_STATUS_CALLER_SID="${caller_sid}"
    BCI_STATUS_CALLER_TTY="${caller_tty}"
    while :; do
      local line
      line="$(bci_compose_status_line)"
      _bci_write_status_files "${STATUS_LOG}" "${STATUS_CUR}" "${GLOBAL_STATUS_HEADER}" "${line}"
      if [[ -n "${d}" ]]; then
        _bci_write_status_files "${d}/status.log" "${d}/status.current" "${PER_ID_STATUS_HEADER}" "${line}"
      fi
      sleep "${BCI_STATUS_PERIOD_SECS}"
    done
  ) >/dev/null 2>&1 &
  local loop_pid=$!
  echo "${loop_pid}" > "${STATUS_PID}"
  [[ -n "${d}" ]] && echo "${loop_pid}" > "${d}/status.pid"
  disown || true
}

status_snapshot() {
  local id="$1" label="${2:-}" rep="${3:-}"
  mkdir -p "${ACTIVITY_DIR}"
  local d=""
  if [[ -n "${id:-}" ]]; then
    ensure_activity_dirs "${id}"
    d="$(activity_dir_for_id "${id}")"
  fi

  local caller_pid="$$"
  local caller_sid
  caller_sid="$(ps -o sid= -p "${caller_pid}" 2>/dev/null | awk '{print $1}' || true)"
  local caller_tty
  caller_tty="$(ps -o tty= -p "${caller_pid}" 2>/dev/null | awk '{print $1}' || true)"

  local line
  line="$(
    BCI_STATUS_ID="${id}" \
    BCI_STATUS_CALLER_PID="${caller_pid}" \
    BCI_STATUS_CALLER_SID="${caller_sid}" \
    BCI_STATUS_CALLER_TTY="${caller_tty}" \
    bci_compose_status_line
  )"

  _bci_write_status_files "${STATUS_LOG}" "${STATUS_CUR}" "${GLOBAL_STATUS_HEADER}" "${line}"
  if [[ -n "${d}" ]]; then
    _bci_write_status_files "${d}/status.log" "${d}/status.current" "${PER_ID_STATUS_HEADER}" "${line}"
  fi
}

stop_activity_loops() {
  local id="$1"
  local d; d="$(activity_dir_for_id "${id}")"
  local pidfiles=("${d}/heartbeat.pid" "${d}/status.pid")
  if [[ -n "${id:-}" ]]; then
    pidfiles+=("${ACTIVITY_DIR}/heartbeat.${id}.pid")
  fi
  pidfiles+=("${STATUS_PID}")
  for pf in "${pidfiles[@]}"; do
    [[ -f "${pf}" ]] || continue
    local pid
    pid="$(cat "${pf}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
    fi
    rm -f "${pf}"
  done
}

# On error: capture small, human-readable dump
# usage: setup_error_traps <id> <label> <rep>
setup_error_traps() {
  local id="$1" label="$2" rep="$3"
  # shellcheck disable=SC2154
  trap '_rc=$?; on_error "${_rc}" "'"${id}"'" "'"${label}"'" "'"${rep}"'"' ERR SIGINT SIGHUP SIGTERM SIGPIPE
  trap 'on_exit "'"${id}"'" "'"${label}"'" "'"${rep}"'"' EXIT
}

on_error() {
  local rc="${1:-1}" id="${2:-unknown}" label="${3:-unknown}" rep="${4:-unknown}"
  [[ "${rc}" -eq 0 ]] && return 0
  BCI_ACTIVITY_FAILURE=1
  local d; d="$(activity_dir_for_id "${id}")"
  local f="${d}/fail_dump.log"
  status_snapshot "${id}" "${label}" "${rep}" || true
  {
    echo "=== FAIL DUMP ==="
    echo "ts_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "id: ${id}  label: ${label}  rep: ${rep}"
    echo "-- env (key vars) --"
    env | grep -Ei '^(TMUX|SHELL|USER|PWD|WORKLOAD_|TOOLS_|BCI_)' || true
    echo "-- tmux sessions --"
    tmux list-sessions 2>/dev/null || echo "(no tmux)"
    echo "-- ps tree --"
    pstree -alp $$ 2>/dev/null || ps -eo pid,ppid,pgid,sid,tty,cmd --forest
    echo "-- df -h . --"
    df -h . || true
    echo "-- dmesg (tail 80) --"
    dmesg | tail -n 80 || true
  } >> "${f}"
  chmod 0644 "${f}" || true
  stop_activity_loops "${id}" "${label}" "${rep}" || true
  return "${rc}"
}

on_exit() {
  local id="${1:-unknown}" label="${2:-unknown}" rep="${3:-unknown}"
  if [[ "${BCI_ACTIVITY_FAILURE:-0}" -ne 0 ]]; then
    return 0
  fi
  if [[ -n "${id}" && "${id}" != "unknown" ]]; then
    write_phase "${id}" "exit-ok" "${label}" "${rep}" || true
  fi
  status_snapshot "${id}" "${label}" "${rep}" || true
  stop_activity_loops "${id}" "${label}" "${rep}" || true
}
