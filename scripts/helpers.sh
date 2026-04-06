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
  if declare -F restore_cpu_isolation >/dev/null; then
    restore_cpu_isolation || true
  fi
  if declare -F restore_llc_defaults >/dev/null; then
    [[ ${LLC_RESTORE_REGISTERED:-false} == true ]] && restore_llc_defaults || true
  fi
  if declare -F restore_idle_states_if_needed >/dev/null; then
    restore_idle_states_if_needed || true
  fi
  if declare -F cleanup_pcm_processes >/dev/null; then
    cleanup_pcm_processes || true
  fi
  if declare -F uncore_restore_snapshot >/dev/null; then
    uncore_restore_snapshot || true
  fi

  exit "$rc"
}


# bci_write_node_owner_metadata
#   Record the canonical non-root owner for later CloudLab follow-up commands.
#   Arguments:
#     $1 - owner user
#     $2 - owner group
#     $3 - optional metadata path (defaults to /local/.bci_node_owner.env)
bci_write_node_owner_metadata() {
  local owner_user="${1:-${SUDO_USER:-$(id -un)}}"
  local owner_group="${2:-$(id -gn "${owner_user}")}"
  local metadata_path="${3:-/local/.bci_node_owner.env}"
  local metadata_dir
  metadata_dir="$(dirname "${metadata_path}")"
  mkdir -p "${metadata_dir}"
  cat > "${metadata_path}" <<EOF
BCI_NODE_OWNER_USER=${owner_user}
BCI_NODE_OWNER_GROUP=${owner_group}
EOF
  chmod 0644 "${metadata_path}"
}


# bci_retry_command
#   Retry a command with linear backoff. Useful for transient network failures during startup.
#   Arguments:
#     $1 - number of attempts
#     $2 - base delay in seconds
#     $@ - command and arguments
bci_retry_command() {
  local attempts="${1:-5}"
  local delay_s="${2:-5}"
  shift 2 || true
  if (( $# == 0 )); then
    echo "ERROR: bci_retry_command requires a command" >&2
    return 2
  fi

  local try rc=0 sleep_s
  local rendered_cmd
  rendered_cmd="$(printf '%q ' "$@")"
  rendered_cmd="${rendered_cmd% }"

  for ((try=1; try<=attempts; try++)); do
    "$@" && return 0
    rc=$?
    if (( try == attempts )); then
      echo "[WARN] command failed after ${attempts} attempts (rc=${rc}): ${rendered_cmd}" >&2
      return "${rc}"
    fi
    sleep_s=$((delay_s * try))
    echo "[WARN] attempt ${try}/${attempts} failed (rc=${rc}); retrying in ${sleep_s}s: ${rendered_cmd}" >&2
    sleep "${sleep_s}"
  done

  return "${rc}"
}


# bci_detect_hw_model
#   Return the current DMI product name when available.
bci_detect_hw_model() {
  local hw_model="unknown"
  if [[ -r /sys/devices/virtual/dmi/id/product_name ]]; then
    hw_model="$(cat /sys/devices/virtual/dmi/id/product_name)"
  fi
  printf '%s\n' "${hw_model}"
}


# bci_root_mount_source
#   Return the device backing / when available.
bci_root_mount_source() {
  findmnt -n / -o SOURCE 2>/dev/null || true
}


# bci_root_backing_device
#   Return the whole-disk device that backs / when it can be resolved.
bci_root_backing_device() {
  local root_source parent
  root_source="$(bci_root_mount_source)"
  if [[ -z "${root_source}" || ! -b "${root_source}" ]]; then
    return 0
  fi
  parent="$(lsblk -ndo PKNAME "${root_source}" 2>/dev/null | head -n1 || true)"
  if [[ -n "${parent}" ]]; then
    printf '/dev/%s\n' "${parent}"
  fi
}


# bci_prepare_c220_c240_storage
#   Extend /local/data on known C220/C240-family nodes via /dev/sdb1.
bci_prepare_c220_c240_storage() {
  echo "→ Detected C220/C240 family: partitioning /dev/sdb → /local/data"

  local desired_gb=300
  local total_bytes total_gb partition_end mounted_source fs_type
  if [[ ! -b /dev/sdb1 ]]; then
    echo "Partition /dev/sdb1 missing, creating new on /dev/sdb…"
    total_bytes="$(sudo blockdev --getsize64 /dev/sdb)"
    total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))
    echo "Disk /dev/sdb is ${total_gb}GB"

    if (( total_gb >= desired_gb )); then
      partition_end="${desired_gb}GB"
    else
      partition_end="${total_gb}GB"
    fi
    echo "Creating partition 0–${partition_end}"

    sudo parted /dev/sdb --script mklabel gpt
    sudo parted /dev/sdb --script mkpart primary ext4 0GB "${partition_end}"
    sleep 5
  fi

  sudo mkdir -p /local/data
  mounted_source="$(findmnt -n /local/data -o SOURCE 2>/dev/null || true)"
  fs_type="$(blkid -o value -s TYPE /dev/sdb1 2>/dev/null || true)"
  if [[ "${mounted_source}" == "/dev/sdb1" ]]; then
    echo "→ /local/data already mounted from /dev/sdb1; reusing existing filesystem"
    return 0
  fi
  if [[ -n "${mounted_source}" ]]; then
    echo "ERROR: /local/data is already mounted from ${mounted_source}; expected /dev/sdb1" >&2
    return 1
  fi
  if [[ "${fs_type}" != "ext4" ]]; then
    echo "Formatting /dev/sdb1 as ext4…"
    sudo mkfs.ext4 -F /dev/sdb1
  else
    echo "→ /dev/sdb1 already has an ext4 filesystem; reusing it"
  fi

  echo "Mounting /dev/sdb1 at /local/data…"
  sudo mount /dev/sdb1 /local/data
}


# bci_prepare_xl170_storage
#   Extend /local/data on XL170-family nodes by growing /dev/sda3.
bci_prepare_xl170_storage() {
  echo "→ Detected XL170: expanding /dev/sda3 to fill SSD…"

  if ! command -v growpart >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y cloud-guest-utils
  fi

  echo "Running growpart /dev/sda 3"
  sudo growpart /dev/sda 3

  echo "Resizing ext4 on /dev/sda3"
  sudo resize2fs /dev/sda3

  echo "Ensuring /local/data exists"
  sudo mkdir -p /local/data
}


# bci_prepare_local_data_generic
#   Conservative fallback for unverified hardware families: use existing /local and
#   leave any additional devices untouched until the layout is validated.
bci_prepare_local_data_generic() {
  local hw_model="${1:-$(bci_detect_hw_model)}"
  local root_source root_backing mounted_source
  root_source="$(bci_root_mount_source)"
  root_backing="$(bci_root_backing_device)"

  echo "→ No verified storage-extension path for ${hw_model}; using the existing /local filesystem for now."
  [[ -n "${root_source}" ]] && echo "→ Root mount source: ${root_source}"
  [[ -n "${root_backing}" ]] && echo "→ Root backing device: ${root_backing}"
  echo "→ Current block layout:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL || true

  sudo mkdir -p /local/data
  mounted_source="$(findmnt -n /local/data -o SOURCE 2>/dev/null || true)"
  if [[ -n "${mounted_source}" ]]; then
    echo "→ /local/data already mounted from ${mounted_source}; reusing it"
  else
    echo "→ /local/data will share the existing /local filesystem until this hardware family is explicitly validated."
  fi
}


# bci_prepare_local_data_mount
#   Prepare /local/data using the verified per-family path when known, otherwise
#   degrade to the conservative shared-/local fallback.
bci_prepare_local_data_mount() {
  local hw_model="${1:-$(bci_detect_hw_model)}"
  echo "Hardware model: ${hw_model}"
  case "${hw_model}" in
    *c240g5*|*C240G5*|*c220g2*|*C220G2*|*C220*|*UCSC-C240*|*UCSC-C220*)
      bci_prepare_c220_c240_storage
      ;;
    *XL170*|*xl170*|*ProLiant\ XL170r*|*XL170r*)
      bci_prepare_xl170_storage
      ;;
    *C6620*|*c6620*)
      echo "→ Detected C6620 family; using the conservative /local fallback until tonight's layout validation closes."
      bci_prepare_local_data_generic "${hw_model}"
      ;;
    *)
      echo "→ Unrecognized hardware (${hw_model}); using the conservative /local fallback instead of failing startup."
      bci_prepare_local_data_generic "${hw_model}"
      ;;
  esac
}


# bci_report_local_data_mount
#   Emit a compact storage report for startup logs.
bci_report_local_data_mount() {
  echo "=== /local/data usage ==="
  df -h /local /local/data 2>/dev/null || true
  echo "--- findmnt ---"
  findmnt /local 2>/dev/null || true
  findmnt /local/data 2>/dev/null || true
  echo "========================="
}


# bci_locate_intel_speed_select
#   Return the path to intel-speed-select when available.
bci_locate_intel_speed_select() {
  local candidate
  candidate="$(command -v intel-speed-select 2>/dev/null || true)"
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  shopt -s nullglob
  for candidate in \
    /usr/bin/intel-speed-select \
    /usr/sbin/intel-speed-select \
    /usr/lib/linux-tools*/intel-speed-select \
    /usr/lib/linux-tools/*/intel-speed-select
  do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}


# bci_probe_intel_speed_select
#   Log whether intel-speed-select is available after startup package installs.
bci_probe_intel_speed_select() {
  local iss_path help_line
  iss_path="$(bci_locate_intel_speed_select || true)"
  if [[ -n "${iss_path}" ]]; then
    echo "→ intel-speed-select detected at ${iss_path}"
    help_line="$("${iss_path}" --help 2>/dev/null | head -n1 || true)"
    [[ -n "${help_line}" ]] && echo "→ intel-speed-select help: ${help_line}"
  else
    echo "→ intel-speed-select not found after startup package install"
  fi
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

# cpu_mask_to_list
#   Convert a compact CPU mask/range string (e.g., "0,2-3") into one ID per line.
#   Strips stray backslashes that can appear from line continuations in parsed command text.
cpu_mask_to_list() {
  local mask="${1:-}"
  # Remove line-continuation artifacts
  mask="${mask//\\ / }"
  mask="${mask//\\}"
  mask="${mask//$'\n'/}"
  python3 - "$mask" <<'PY'
import sys
mask = sys.argv[1].strip() if len(sys.argv) > 1 else ""
if not mask:
    print("cpu_mask_to_list: empty mask", file=sys.stderr)
    sys.exit(1)

cpus = set()
for raw in mask.split(','):
    tok = raw.strip()
    if not tok:
        print(f"cpu_mask_to_list: empty token in '{mask}'", file=sys.stderr)
        sys.exit(1)
    if '-' in tok:
        parts = tok.split('-')
        if len(parts) != 2:
            print(f"cpu_mask_to_list: bad range '{tok}'", file=sys.stderr)
            sys.exit(1)
        try:
            a, b = map(int, parts)
        except ValueError:
            print(f"cpu_mask_to_list: non-integer in '{tok}'", file=sys.stderr)
            sys.exit(1)
        if a < 0 or b < 0:
            print(f"cpu_mask_to_list: negative CPU id in '{tok}'", file=sys.stderr)
            sys.exit(1)
        if a > b:
            print(f"cpu_mask_to_list: descending range '{tok}'", file=sys.stderr)
            sys.exit(1)
        for c in range(a, b + 1):
            cpus.add(c)
    else:
        try:
            c = int(tok)
        except ValueError:
            print(f"cpu_mask_to_list: non-integer token '{tok}'", file=sys.stderr)
            sys.exit(1)
        if c < 0:
            print(f"cpu_mask_to_list: negative CPU id '{tok}'", file=sys.stderr)
            sys.exit(1)
        cpus.add(c)

if not cpus:
    print("cpu_mask_to_list: mask resolved to no CPUs", file=sys.stderr)
    sys.exit(1)

for c in sorted(cpus):
    print(c)
PY
}


# normalize_cpu_mask
#   Normalize a CPU mask into a sorted, compact range string.
#   Arguments:
#     $1 - CPU mask/range string.
normalize_cpu_mask() {
  local mask="${1:-}"
  python3 - "$mask" <<'PY'
import sys

mask = sys.argv[1].strip() if len(sys.argv) > 1 else ""
if not mask:
    print("")
    raise SystemExit(0)

cpus = []
seen = set()
for line in sys.stdin:
    pass

def expand(mask_text):
    values = set()
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            if a > b:
                raise SystemExit(f"normalize_cpu_mask: descending range '{tok}'")
            for cpu in range(a, b + 1):
                values.add(cpu)
        else:
            values.add(int(tok))
    return sorted(values)

cpus = expand(mask)
if not cpus:
    print("")
    raise SystemExit(0)

parts = []
start = prev = cpus[0]
for cpu in cpus[1:]:
    if cpu == prev + 1:
        prev = cpu
        continue
    parts.append(f"{start}-{prev}" if start != prev else str(start))
    start = prev = cpu
parts.append(f"{start}-{prev}" if start != prev else str(start))
print(",".join(parts))
PY
}


# cpu_mask_count
#   Count the number of logical CPUs in a mask.
#   Arguments:
#     $1 - CPU mask/range string.
cpu_mask_count() {
  local mask="${1:-}"
  if [[ -z ${mask} ]]; then
    echo 0
    return 0
  fi
  local count
  count="$(cpu_mask_to_list "${mask}" | wc -l | tr -d '[:space:]')"
  echo "${count:-0}"
}


# cpu_mask_minus
#   Return a compact CPU mask for the first mask minus all subsequent masks.
#   Arguments:
#     $1 - base CPU mask.
#     $@ - one or more CPU masks to subtract.
cpu_mask_minus() {
  local base="${1:-}"
  shift || true
  python3 - "${base}" "$@" <<'PY'
import sys

def expand(mask_text: str) -> set[int]:
    values: set[int] = set()
    if not mask_text:
        return values
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            if a > b:
                raise SystemExit(f"cpu_mask_minus: descending range '{tok}'")
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return values

def compress(values: set[int]) -> str:
    if not values:
        return ""
    ordered = sorted(values)
    parts = []
    start = prev = ordered[0]
    for cpu in ordered[1:]:
        if cpu == prev + 1:
            prev = cpu
            continue
        parts.append(f"{start}-{prev}" if start != prev else str(start))
        start = prev = cpu
    parts.append(f"{start}-{prev}" if start != prev else str(start))
    return ",".join(parts)

base = expand(sys.argv[1] if len(sys.argv) > 1 else "")
for mask in sys.argv[2:]:
    base -= expand(mask)
print(compress(base))
PY
}


# cpu_masks_overlap
#   Return success when two CPU masks share at least one logical CPU.
#   Arguments:
#     $1 - first CPU mask.
#     $2 - second CPU mask.
cpu_masks_overlap() {
  local first="${1:-}"
  local second="${2:-}"
  python3 - "${first}" "${second}" <<'PY'
import sys

def expand(mask_text: str) -> set[int]:
    values: set[int] = set()
    if not mask_text:
        return values
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            if a > b:
                raise SystemExit(2)
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return values

first = expand(sys.argv[1] if len(sys.argv) > 1 else "")
second = expand(sys.argv[2] if len(sys.argv) > 2 else "")
raise SystemExit(0 if first.intersection(second) else 1)
PY
}


# cpu_topology_json
#   Emit the online CPU topology as JSON.
#   Arguments: none.
cpu_topology_json() {
  python3 <<'PY'
import json
from pathlib import Path

def expand(mask_text: str) -> list[int]:
    values: set[int] = set()
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return sorted(values)

online = Path("/sys/devices/system/cpu/online").read_text(encoding="utf-8").strip()
cpus = expand(online)
records = []
socket_map: dict[int, dict] = {}
for cpu in cpus:
    cpu_dir = Path(f"/sys/devices/system/cpu/cpu{cpu}")
    socket = int((cpu_dir / "topology/physical_package_id").read_text(encoding="utf-8").strip())
    core = int((cpu_dir / "topology/core_id").read_text(encoding="utf-8").strip())
    siblings_text = (cpu_dir / "topology/thread_siblings_list").read_text(encoding="utf-8").strip()
    siblings = expand(siblings_text)
    l3_id = None
    cache_id_path = cpu_dir / "cache/index3/id"
    if cache_id_path.exists():
        raw = cache_id_path.read_text(encoding="utf-8").strip()
        if raw:
            l3_id = int(raw)
    record = {
        "cpu": cpu,
        "socket": socket,
        "core": core,
        "siblings": siblings,
        "l3_id": l3_id,
    }
    records.append(record)
    sock = socket_map.setdefault(socket, {"socket": socket, "cpus": [], "cores": {}, "l3_ids": set()})
    sock["cpus"].append(cpu)
    core_entry = sock["cores"].setdefault(core, {"core_id": core, "cpus": []})
    core_entry["cpus"].append(cpu)
    if l3_id is not None:
        sock["l3_ids"].add(l3_id)

sockets = []
for socket_id in sorted(socket_map):
    sock = socket_map[socket_id]
    sockets.append({
        "socket": socket_id,
        "cpus": sorted(sock["cpus"]),
        "cores": [
            {
                "core_id": core_id,
                "cpus": sorted(entry["cpus"]),
            }
            for core_id, entry in sorted(sock["cores"].items())
        ],
        "l3_ids": sorted(sock["l3_ids"]),
    })

print(json.dumps({"online_mask": online, "cpus": records, "sockets": sockets}, sort_keys=True))
PY
}


# resolve_cpu_selection
#   Resolve workload/tool CPU masks for a single-socket run.
#   Arguments:
#     $1 - explicit workload CPUs mask or empty string.
#     $2 - workload CPU count or empty string.
#     $3 - workload SMT policy (off|spillover|pack).
#     $4 - explicit tools CPUs mask or empty string.
#     $5 - tools CPU count.
#     $6 - socket selector (auto|N).
#     $7 - reserved background CPU count.
resolve_cpu_selection() {
  local explicit_workload="${1:-}"
  local workload_count="${2:-}"
  local smt_policy="${3:-spillover}"
  local explicit_tools="${4:-}"
  local tools_count="${5:-1}"
  local socket_id="${6:-auto}"
  local reserved_background="${7:-1}"
  local topo_json
  topo_json="$(cpu_topology_json)"

  python3 - "${topo_json}" "${explicit_workload}" "${workload_count}" "${smt_policy}" "${explicit_tools}" "${tools_count}" "${socket_id}" "${reserved_background}" <<'PY'
import json
import shlex
import sys

topo = json.loads(sys.argv[1])
explicit_workload = (sys.argv[2] or "").strip()
workload_count_text = (sys.argv[3] or "").strip()
smt_policy = (sys.argv[4] or "spillover").strip().lower()
explicit_tools = (sys.argv[5] or "").strip()
tools_count_text = (sys.argv[6] or "1").strip()
socket_id_text = (sys.argv[7] or "auto").strip().lower()
reserved_background_text = (sys.argv[8] or "1").strip()

if smt_policy not in {"off", "spillover", "pack"}:
    raise SystemExit(f"Unsupported --workload-smt-policy '{smt_policy}'")

try:
    tools_count = int(tools_count_text)
except ValueError as exc:
    raise SystemExit(f"Invalid --tools-cpu-count '{tools_count_text}'") from exc
try:
    reserved_background = int(reserved_background_text)
except ValueError as exc:
    raise SystemExit(f"Invalid reserved background CPU count '{reserved_background_text}'") from exc
if tools_count < 0:
    raise SystemExit("--tools-cpu-count must be >= 0")
if reserved_background < 0:
    raise SystemExit("reserved background CPU count must be >= 0")

def expand(mask_text: str) -> list[int]:
    values: set[int] = set()
    if not mask_text:
        return []
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            if a > b:
                raise SystemExit(f"Descending CPU range '{tok}' is not allowed")
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return sorted(values)

def compress(values: list[int]) -> str:
    if not values:
        return ""
    ordered = sorted(dict.fromkeys(values))
    parts = []
    start = prev = ordered[0]
    for cpu in ordered[1:]:
        if cpu == prev + 1:
            prev = cpu
            continue
        parts.append(f"{start}-{prev}" if start != prev else str(start))
        start = prev = cpu
    parts.append(f"{start}-{prev}" if start != prev else str(start))
    return ",".join(parts)

cpu_records = {entry["cpu"]: entry for entry in topo["cpus"]}
online = set(cpu_records)

workload_explicit = expand(explicit_workload)
tools_explicit = expand(explicit_tools)
for cpu in workload_explicit + tools_explicit:
    if cpu not in online:
        raise SystemExit(f"CPU {cpu} is not online on this node")

socket_map: dict[int, dict] = {}
for sock in topo["sockets"]:
    groups = [sorted(core["cpus"]) for core in sock["cores"]]
    socket_map[int(sock["socket"])] = {
        "socket": int(sock["socket"]),
        "core_groups": groups,
        "cpus": sorted(sock["cpus"]),
    }

if not socket_map:
    raise SystemExit("No online CPUs were discovered")

def cpus_socket_set(cpus: list[int]) -> set[int]:
    return {cpu_records[cpu]["socket"] for cpu in cpus}

explicit_socket_sets = []
if workload_explicit:
    explicit_socket_sets.append(cpus_socket_set(workload_explicit))
if tools_explicit:
    explicit_socket_sets.append(cpus_socket_set(tools_explicit))
for sock_set in explicit_socket_sets:
    if len(sock_set) != 1:
        raise SystemExit("Explicit CPU masks must remain within a single socket")

chosen_socket = None
if socket_id_text != "auto":
    try:
        chosen_socket = int(socket_id_text)
    except ValueError as exc:
        raise SystemExit(f"Invalid --socket-id '{socket_id_text}'") from exc
    if chosen_socket not in socket_map:
        raise SystemExit(f"Socket {chosen_socket} is not present on this node")

for sock_set in explicit_socket_sets:
    explicit_socket = next(iter(sock_set))
    if chosen_socket is not None and chosen_socket != explicit_socket:
        raise SystemExit("Explicit CPU masks do not match the requested socket")
    chosen_socket = explicit_socket

def ordered_candidates(groups: list[list[int]], policy: str) -> list[int]:
    if policy == "off":
        return [group[0] for group in groups if group]
    if policy == "spillover":
        ordered: list[int] = []
        max_width = max((len(group) for group in groups), default=0)
        for idx in range(max_width):
            for group in groups:
                if idx < len(group):
                    ordered.append(group[idx])
        return ordered
    if policy == "pack":
        ordered = []
        for group in groups:
            ordered.extend(group)
        return ordered
    raise AssertionError(policy)

def reserve_from_groups(groups: list[list[int]], count: int) -> list[int]:
    if count <= 0:
        return []
    if len(groups) < count:
        return []
    selected_groups = list(reversed(groups[-count:]))
    return [group[0] for group in selected_groups]

def reserve_group_indices(groups: list[list[int]], count: int, used_indices: set[int] | None = None) -> list[int]:
    if count <= 0:
        return []
    blocked = set(used_indices or set())
    picks = []
    for idx in range(len(groups) - 1, -1, -1):
        if idx in blocked:
            continue
        picks.append(idx)
        if len(picks) == count:
            break
    return picks

def groups_for_cpus(groups: list[list[int]], cpus: list[int]) -> set[int]:
    cpu_set = set(cpus)
    return {
        idx
        for idx, group in enumerate(groups)
        if any(cpu in cpu_set for cpu in group)
    }

def explicit_reserve(cpus_in_use: list[int], groups: list[list[int]], count: int) -> list[int]:
    if count <= 0:
        return []
    used = set(cpus_in_use)
    untouched = []
    fallback = []
    for group in reversed(groups):
        if any(cpu in used for cpu in group):
            for cpu in reversed(group):
                if cpu not in used:
                    fallback.append(cpu)
        else:
            untouched.append(group[0])
    picks = untouched[:count]
    if len(picks) < count:
        for cpu in fallback:
            if cpu not in picks:
                picks.append(cpu)
            if len(picks) == count:
                break
    return picks

def policy_max(groups: list[list[int]], policy: str, reserve_count: int) -> int:
    if reserve_count > len(groups):
        return 0
    workload_groups = groups[: len(groups) - reserve_count]
    return len(ordered_candidates(workload_groups, policy))

topology_summary = {}
for socket, sock in socket_map.items():
    reserve_count = tools_count + reserved_background
    topology_summary[socket] = {
        "candidate_cpus": compress(sock["cpus"]),
        "max_workload_logical": {
            "off": policy_max(sock["core_groups"], "off", reserve_count),
            "spillover": policy_max(sock["core_groups"], "spillover", reserve_count),
            "pack": policy_max(sock["core_groups"], "pack", reserve_count),
        },
    }

def choose_socket_for_request() -> int:
    if chosen_socket is not None:
        return chosen_socket
    if workload_explicit or tools_explicit:
        return next(iter(cpus_socket_set(workload_explicit or tools_explicit)))
    request = None
    if workload_count_text:
        try:
            request = int(workload_count_text)
        except ValueError as exc:
            raise SystemExit(f"Invalid --workload-cpu-count '{workload_count_text}'") from exc
    for socket in sorted(socket_map):
        if request is None:
            return socket
        if topology_summary[socket]["max_workload_logical"][smt_policy] >= request:
            return socket
    raise SystemExit(
        f"No socket can satisfy workload count {request} with tools={tools_count}, "
        f"background={reserved_background}, policy={smt_policy}"
    )

selected_socket = choose_socket_for_request()
sock = socket_map[selected_socket]

if workload_explicit and cpus_socket_set(workload_explicit) != {selected_socket}:
    raise SystemExit("Explicit workload CPUs do not belong to the selected socket")
if tools_explicit and cpus_socket_set(tools_explicit) != {selected_socket}:
    raise SystemExit("Explicit tool CPUs do not belong to the selected socket")

reserve_total = tools_count + reserved_background

if workload_explicit:
    workload_cpus = workload_explicit
    auto_reserve = [] if tools_explicit else explicit_reserve(workload_cpus, sock["core_groups"], reserve_total)
    if not tools_explicit and len(auto_reserve) < reserve_total:
        raise SystemExit(
            "Explicit workload CPU mask leaves too few CPUs for tool/background reservation on the selected socket"
        )
else:
    if workload_count_text:
        try:
            workload_count = int(workload_count_text)
        except ValueError as exc:
            raise SystemExit(f"Invalid --workload-cpu-count '{workload_count_text}'") from exc
    else:
        workload_count = 0
    if workload_count < 0:
        raise SystemExit("--workload-cpu-count must be >= 0")
    if tools_explicit:
        tool_group_indices = groups_for_cpus(sock["core_groups"], tools_explicit)
        background_group_indices = reserve_group_indices(
            sock["core_groups"],
            reserved_background,
            tool_group_indices,
        )
        if len(background_group_indices) < reserved_background:
            raise SystemExit("Explicit tool CPUs leave too few physical cores for the reserved background CPU")
        tool_cpus = tools_explicit
        background_cpus = sorted(
            sock["core_groups"][idx][0] for idx in background_group_indices
        )
        reserved_group_indices = set(tool_group_indices) | set(background_group_indices)
        auto_reserve = []
    else:
        reserve_group_list = reserve_group_indices(sock["core_groups"], reserve_total)
        if len(reserve_group_list) < reserve_total:
            raise SystemExit("Not enough cores remain on the selected socket for tool/background reservation")
        tool_group_indices = reserve_group_list[:tools_count]
        background_group_indices = reserve_group_list[tools_count: tools_count + reserved_background]
        tool_cpus = sorted(sock["core_groups"][idx][0] for idx in tool_group_indices)
        background_cpus = sorted(
            sock["core_groups"][idx][0] for idx in background_group_indices
        )
        reserved_group_indices = set(reserve_group_list)
        auto_reserve = tool_cpus + background_cpus
    workload_groups = []
    for idx, group in enumerate(sock["core_groups"]):
        if idx in reserved_group_indices:
            continue
        workload_groups.append(group)
    candidates = ordered_candidates(workload_groups, smt_policy)
    if workload_count > len(candidates):
        raise SystemExit(
            f"Requested {workload_count} workload logical CPUs but only {len(candidates)} are available "
            f"on socket {selected_socket} under policy {smt_policy}"
        )
    workload_cpus = sorted(candidates[:workload_count])

if tools_explicit:
    if workload_explicit:
        tool_cpus = tools_explicit
        background_candidates = explicit_reserve(sorted(set(workload_cpus) | set(tool_cpus)), sock["core_groups"], reserved_background)
        if len(background_candidates) < reserved_background:
            raise SystemExit("Explicit tool CPUs leave too few CPUs for the reserved background CPU")
        background_cpus = background_candidates[:reserved_background]
else:
    if workload_explicit:
        tool_cpus = sorted(auto_reserve[:tools_count])
        background_cpus = sorted(auto_reserve[tools_count: tools_count + reserved_background])

if set(workload_cpus) & set(tool_cpus):
    raise SystemExit("Workload CPUs must not overlap tool CPUs")
if set(workload_cpus) & set(background_cpus):
    raise SystemExit("Workload CPUs must not overlap the reserved background CPU")
if set(tool_cpus) & set(background_cpus):
    raise SystemExit("Tool CPUs must not overlap the reserved background CPU")

resolved = {
    "selected_socket": selected_socket,
    "workload_cpus": compress(workload_cpus),
    "tools_cpus": compress(tool_cpus),
    "background_cpus": compress(background_cpus),
    "workload_count": len(workload_cpus),
    "tools_count": len(tool_cpus),
    "workload_used_smt": len(workload_cpus) > len({cpu_records[cpu]["core"] for cpu in workload_cpus}),
    "policy": smt_policy,
    "topology_summary": topology_summary,
}

for key, value in resolved.items():
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, (dict, list)):
        text = json.dumps(value, sort_keys=True)
    else:
        text = str(value)
    print(f"{key}={shlex.quote(text)}")
PY
}


# print_cpu_topology_report
#   Print a human-readable topology and auto-pick summary.
#   Arguments:
#     $1 - tools CPU count.
#     $2 - reserved background CPU count.
print_cpu_topology_report() {
  local tools_count="${1:-1}"
  local reserved_background="${2:-1}"
  local topo_json
  topo_json="$(cpu_topology_json)"
  python3 - "${topo_json}" "${tools_count}" "${reserved_background}" <<'PY'
import json
import sys

topo = json.loads(sys.argv[1])
tools_count = int(sys.argv[2])
reserved_background = int(sys.argv[3])

def compress(values: list[int]) -> str:
    if not values:
        return ""
    values = sorted(dict.fromkeys(values))
    parts = []
    start = prev = values[0]
    for cpu in values[1:]:
        if cpu == prev + 1:
            prev = cpu
            continue
        parts.append(f"{start}-{prev}" if start != prev else str(start))
        start = prev = cpu
    parts.append(f"{start}-{prev}" if start != prev else str(start))
    return ",".join(parts)

print("CPU topology:")
for sock in sorted(topo["sockets"], key=lambda item: item["socket"]):
    reserve = tools_count + reserved_background
    groups = [sorted(core["cpus"]) for core in sock["cores"]]
    workload_groups = groups[: len(groups) - reserve] if reserve <= len(groups) else []
    max_off = len(workload_groups)
    max_spill = sum(len(group) for group in workload_groups)
    max_pack = max_spill
    print(f"Socket {sock['socket']}: candidates={compress(sock['cpus'])}")
    print(
        f"  max workload logical CPUs (tools={tools_count}, background={reserved_background}) -> "
        f"off={max_off}, spillover={max_spill}, pack={max_pack}"
    )
    for core in sock["cores"]:
        print(
            f"  core {core['core_id']}: logical={compress(sorted(core['cpus']))}"
        )
PY
}


# log_workload_concurrency_state
#   Emit a consistent message describing how workload concurrency relates to
#   the resolved workload logical CPU count.
#   Arguments:
#     $1 - requested workload concurrency count.
#     $2 - resolved workload logical CPU count.
log_workload_concurrency_state() {
  local requested="${1:?missing requested workload concurrency}"
  local resolved="${2:?missing resolved workload logical CPU count}"

  if (( requested == resolved )); then
    log_info "Workload concurrency matches resolved workload logical CPUs (${requested})."
  elif (( requested < resolved )); then
    log_warn "Workload concurrency (${requested}) is lower than resolved workload logical CPUs (${resolved}); the workload will undersubscribe the selected CPUs."
  else
    log_warn "Workload concurrency (${requested}) exceeds resolved workload logical CPUs (${resolved}); the workload may oversubscribe the selected CPUs."
  fi
}


# others_list_csv
#   Return a comma-separated list of online CPUs excluding the provided IDs.
#   Arguments:
#     $@ - CPU IDs that must be omitted from the result.
others_list_csv() {
  local all
  all="$(cpu_online_list)"
  cpu_mask_minus "${all}" "$@"
}


# pqos_monitor_spec_all_groups
#   Build a grouped PQoS monitoring spec for one event across multiple CPU groups.
#   PQoS expects grouped syntax like all:[0],[3-5],[9] rather than repeated all:<group>.
#   Arguments:
#     $@ - CPU masks for the groups to monitor.
pqos_monitor_spec_all_groups() {
  local mask normalized joined=""
  local -A seen=()

  for mask in "$@"; do
    normalized="$(normalize_cpu_mask "${mask:-}")"
    [[ -n "${normalized}" ]] || continue
    if [[ -n "${seen["${normalized}"]+x}" ]]; then
      continue
    fi
    seen["${normalized}"]=1
    if [[ -n "${joined}" ]]; then
      joined+=","
    fi
    joined+="[${normalized}]"
  done

  [[ -n "${joined}" ]] || return 1
  printf 'all:%s\n' "${joined}"
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
      grep -Eo 'taskset -c[[:space:]]+[0-9,-]+' "$SCRIPT_FILE" 2>/dev/null | awk '{print $3}' || true
      grep -Eo 'cset[[:space:]]+(shield|set)[[:space:]]+--cpu[[:space:]]+[0-9,-]+' "$SCRIPT_FILE" 2>/dev/null | awk '{print $NF}' || true
    } | tr -d '[:space:]'
  )"

  local CPU_LIST_BUILT
  CPU_LIST_BUILT="$(normalize_cpu_mask "${candidates},${literals}")"

  if [ -z "${CPU_LIST_BUILT}" ]; then
    CPU_LIST_BUILT="$(normalize_cpu_mask "$(printf '%s' "${TOOLS_CPU}" | tr -d '[:space:]')")"
  fi

  printf '%s\n' "${CPU_LIST_BUILT}"
}


# ensure_workload_and_tools_cpus
#   Resolve a lightweight workload/tools CPU pair (or masks) for hardware
#   validation scripts that do not carry the full workload CLI surface.
ensure_workload_and_tools_cpus() {
  local requested_workload="${WORKLOAD_CPUS:-${WORKLOAD_CPU:-}}"
  local requested_tools="${TOOLS_CPUS:-${TOOLS_CPU:-}}"
  local workload_count="${WORKLOAD_CPU_COUNT:-}"
  local tools_count="${TOOLS_CPU_COUNT:-}"
  local smt_policy="${WORKLOAD_SMT_POLICY:-off}"
  local socket_id="${SOCKET_ID_REQUEST:-auto}"
  local reserved_background="${RESERVED_BACKGROUND_CPU_COUNT:-1}"
  local selection_assignments
  local resolved_workload_first resolved_tools_first

  if [[ -z "${requested_workload}" && -z "${workload_count}" ]]; then
    workload_count=1
  fi
  if [[ -z "${requested_tools}" && -z "${tools_count}" ]]; then
    tools_count=1
  fi

  selection_assignments="$(
    resolve_cpu_selection \
      "${requested_workload}" \
      "${workload_count}" \
      "${smt_policy}" \
      "${requested_tools}" \
      "${tools_count}" \
      "${socket_id}" \
      "${reserved_background}"
  )"
  eval "${selection_assignments}"

  WORKLOAD_CPUS="${workload_cpus}"
  TOOLS_CPUS="${tools_cpus}"
  BACKGROUND_CPUS="${background_cpus:-}"
  SELECTED_SOCKET_ID="${selected_socket}"
  WORKLOAD_CPU_COUNT_RESOLVED="${workload_count}"
  TOOLS_CPU_COUNT_RESOLVED="${tools_count}"
  WORKLOAD_USED_SMT="${workload_used_smt}"

  resolved_workload_first="$(cpu_mask_to_list "${WORKLOAD_CPUS}" | head -n1)"
  resolved_tools_first="$(cpu_mask_to_list "${TOOLS_CPUS}" | head -n1)"
  WORKLOAD_CPU="${resolved_workload_first}"
  TOOLS_CPU="${resolved_tools_first}"
  WORKLOAD_CORE_DEFAULT="${WORKLOAD_CPUS}"
  TOOLS_CORE_DEFAULT="${TOOLS_CPUS}"

  export WORKLOAD_CPUS TOOLS_CPUS WORKLOAD_CPU TOOLS_CPU BACKGROUND_CPUS \
    SELECTED_SOCKET_ID WORKLOAD_CPU_COUNT_RESOLVED TOOLS_CPU_COUNT_RESOLVED \
    WORKLOAD_USED_SMT WORKLOAD_CORE_DEFAULT TOOLS_CORE_DEFAULT

  log_info "Selected CPUs: workload=${WORKLOAD_CPUS} tools=${TOOLS_CPUS} socket=${SELECTED_SOCKET_ID} background=${BACKGROUND_CPUS:-<none>}"
}


# print_topology_preflight
#   Emit concise key=value topology facts for the selected workload/tools CPUs.
print_topology_preflight() {
  local label cpu_mask first_cpu package core die node siblings
  for label in workload tools; do
    if [[ "${label}" == "workload" ]]; then
      cpu_mask="${WORKLOAD_CPUS:-${WORKLOAD_CPU:-}}"
    else
      cpu_mask="${TOOLS_CPUS:-${TOOLS_CPU:-}}"
    fi
    [[ -n "${cpu_mask}" ]] || continue
    first_cpu="$(cpu_mask_to_list "${cpu_mask}" | head -n1)"
    package="$(cpu_package_id "${first_cpu}" 2>/dev/null || echo '?')"
    core="$(cpu_core_id "${first_cpu}" 2>/dev/null || echo '?')"
    die="$(cpu_die_id "${first_cpu}" 2>/dev/null || echo '?')"
    node="$(cpu_numa_node "${first_cpu}" 2>/dev/null || echo '?')"
    siblings="$(pf_thread_siblings_list "${first_cpu}" 2>/dev/null || echo '?')"
    echo "topology.${label}_cpus=${cpu_mask}"
    echo "topology.${label}_cpu0=${first_cpu}"
    echo "topology.${label}_package=${package}"
    echo "topology.${label}_die=${die}"
    echo "topology.${label}_node=${node}"
    echo "topology.${label}_core=${core}"
    echo "topology.${label}_siblings=${siblings}"
  done
  [[ -n "${SELECTED_SOCKET_ID:-}" ]] && echo "topology.selected_socket=${SELECTED_SOCKET_ID}"
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


# rapl_find_domain_path
#   Locate the sysfs path for a RAPL domain by logical name and package id.
rapl_find_domain_path() {
  local logical_name="${1:?missing logical name}"
  local package_id="${2:-}"
  python3 - "${logical_name}" "${package_id}" <<'PY'
import sys
from pathlib import Path

logical = sys.argv[1].strip().lower()
package_id = sys.argv[2].strip()
root = Path("/sys/class/powercap")
domains = []

for path in sorted(root.glob("intel-rapl:*")):
    if not path.is_dir():
        continue
    name_file = path / "name"
    if not name_file.exists():
        continue
    name = name_file.read_text().strip().lower()
    domains.append((path, name))
    for child in sorted(path.glob("intel-rapl:*")):
        if not child.is_dir():
            continue
        child_name_file = child / "name"
        if child_name_file.exists():
            domains.append((child, child_name_file.read_text().strip().lower()))

if logical == "package":
    exact = f"package-{package_id}" if package_id else ""
    for path, name in domains:
        if exact and name == exact:
            print(path)
            raise SystemExit(0)
    for path, name in domains:
        if name.startswith("package-"):
            print(path)
            raise SystemExit(0)
elif logical == "dram":
    if package_id:
        package_name = f"package-{package_id}"
        for path, name in domains:
            if name != "dram":
                continue
            parent_name_file = path.parent / "name"
            parent_name = parent_name_file.read_text().strip().lower() if parent_name_file.exists() else ""
            if parent_name == package_name:
                print(path)
                raise SystemExit(0)
    for path, name in domains:
        if name == "dram":
            print(path)
            raise SystemExit(0)

raise SystemExit(1)
PY
}


# rapl_discover_for_cpu
#   Populate RAPL package/DRAM paths for the package that owns a workload CPU.
rapl_discover_for_cpu() {
  local cpu="${1:?missing cpu id}"
  local package_id
  package_id="$(cpu_package_id "${cpu}" 2>/dev/null || echo "")"
  RAPL_PACKAGE_PATH="$(rapl_find_domain_path package "${package_id}" 2>/dev/null || true)"
  RAPL_DRAM_PATH="$(rapl_find_domain_path dram "${package_id}" 2>/dev/null || true)"
  export RAPL_PACKAGE_PATH RAPL_DRAM_PATH
}


# rapl_read_energy_uj
#   Read a RAPL domain cumulative energy counter when available.
rapl_read_energy_uj() {
  local path="${1:?missing path}"
  local energy_file="${path}/energy_uj"
  [[ -e "${energy_file}" ]] || return 1
  if [[ -r "${energy_file}" ]]; then
    cat "${energy_file}"
    return 0
  fi
  sudo cat "${energy_file}" 2>/dev/null
}


# rapl_snapshot_domain
#   Capture current sysfs RAPL limit state so it can be restored later.
rapl_snapshot_domain() {
  local path="${1:?missing path}"
  [[ -d "${path}" ]] || return 1
  local key
  key="$(printf '%s' "${path}" | tr -c 'A-Za-z0-9_' '_')"
  declare -gA __RAPL_SNAP_PRESENT __RAPL_SNAP_POWER __RAPL_SNAP_WINDOW __RAPL_SNAP_ENABLED
  __RAPL_SNAP_PRESENT["${key}"]=1
  [[ -r "${path}/constraint_0_power_limit_uw" ]] && __RAPL_SNAP_POWER["${key}"]="$(<"${path}/constraint_0_power_limit_uw")"
  [[ -r "${path}/constraint_0_time_window_us" ]] && __RAPL_SNAP_WINDOW["${key}"]="$(<"${path}/constraint_0_time_window_us")"
  [[ -r "${path}/enabled" ]] && __RAPL_SNAP_ENABLED["${key}"]="$(<"${path}/enabled")"
}


# rapl_restore_domain
#   Restore a previously snapped sysfs RAPL limit state.
rapl_restore_domain() {
  local path="${1:?missing path}"
  declare -p __RAPL_SNAP_PRESENT >/dev/null 2>&1 || return 0
  local key present
  key="$(printf '%s' "${path}" | tr -c 'A-Za-z0-9_' '_')"
  present="${__RAPL_SNAP_PRESENT[$key]-}"
  [[ "${present}" == "1" ]] || return 0
  if [[ -n "${__RAPL_SNAP_POWER[$key]-}" && -e "${path}/constraint_0_power_limit_uw" ]]; then
    echo "${__RAPL_SNAP_POWER[$key]}" | sudo tee "${path}/constraint_0_power_limit_uw" >/dev/null 2>&1 || true
  fi
  if [[ -n "${__RAPL_SNAP_WINDOW[$key]-}" && -e "${path}/constraint_0_time_window_us" ]]; then
    echo "${__RAPL_SNAP_WINDOW[$key]}" | sudo tee "${path}/constraint_0_time_window_us" >/dev/null 2>&1 || true
  fi
  if [[ -n "${__RAPL_SNAP_ENABLED[$key]-}" && -e "${path}/enabled" ]]; then
    echo "${__RAPL_SNAP_ENABLED[$key]}" | sudo tee "${path}/enabled" >/dev/null 2>&1 || true
  fi
}


# rapl_apply_power_limit_watts
#   Apply a constraint_0 limit in watts to a discovered RAPL domain.
rapl_apply_power_limit_watts() {
  local path="${1:?missing path}"
  local watts="${2:?missing watts}"
  local window_us="${3:-}"
  [[ -d "${path}" ]] || return 1
  local domain_name enabled now_power now_window
  domain_name="$(cat "${path}/name" 2>/dev/null || basename "${path}")"
  if [[ -r "${path}/enabled" ]]; then
    enabled="$(<"${path}/enabled")"
    if [[ "${enabled}" != "1" ]]; then
      log_warn "[RAPL] ${domain_name}: domain is disabled (enabled=${enabled}); skipping ${watts} W power-limit request."
      return 0
    fi
  fi
  if [[ ! -e "${path}/constraint_0_power_limit_uw" ]]; then
    log_warn "[RAPL] ${domain_name}: constraint_0_power_limit_uw is missing; skipping ${watts} W power-limit request."
    return 0
  fi
  local microwatts
  microwatts="$(awk -v w="${watts}" 'BEGIN{printf "%.0f", w * 1000000}')"
  echo "${microwatts}" | sudo tee "${path}/constraint_0_power_limit_uw" >/dev/null 2>&1 || true
  if [[ -n "${window_us}" && -e "${path}/constraint_0_time_window_us" ]]; then
    echo "${window_us}" | sudo tee "${path}/constraint_0_time_window_us" >/dev/null 2>&1 || true
  fi
  now_power="$(cat "${path}/constraint_0_power_limit_uw" 2>/dev/null || echo '?')"
  if [[ "${now_power}" != "${microwatts}" ]]; then
    log_warn "[RAPL] ${domain_name}: requested ${microwatts} uW but read back ${now_power}."
  else
    log_info "[RAPL] ${domain_name}: applied ${watts} W (${microwatts} uW)."
  fi
  if [[ -n "${window_us}" && -e "${path}/constraint_0_time_window_us" ]]; then
    now_window="$(cat "${path}/constraint_0_time_window_us" 2>/dev/null || echo '?')"
    if [[ "${now_window}" != "${window_us}" ]]; then
      log_warn "[RAPL] ${domain_name}: requested window ${window_us} us but read back ${now_window}."
    fi
  fi
}


rapl_domain_state_json() {
  local path="${1:-}"
  python3 - "${path}" <<'PY'
import json
import pathlib
import subprocess
import sys

path_text = sys.argv[1].strip()
if not path_text:
    print("null")
    raise SystemExit(0)

path = pathlib.Path(path_text)
if not path.exists():
    print("null")
    raise SystemExit(0)

def read_text(name: str):
    candidate = path / name
    if not candidate.exists():
        return None
    try:
        return candidate.read_text(encoding="utf-8").strip()
    except Exception:
        try:
            return subprocess.check_output(["sudo", "cat", str(candidate)], text=True).strip()
        except Exception:
            return None

parent_name = None
parent = path.parent
if parent != path and (parent / "name").exists():
    try:
        parent_name = (parent / "name").read_text(encoding="utf-8").strip()
    except Exception:
        parent_name = None

payload = {
    "path": str(path),
    "name": read_text("name"),
    "enabled": read_text("enabled"),
    "constraint_0_power_limit_uw": read_text("constraint_0_power_limit_uw"),
    "constraint_0_time_window_us": read_text("constraint_0_time_window_us"),
    "max_energy_range_uj": read_text("max_energy_range_uj"),
    "energy_uj": read_text("energy_uj"),
    "parent_name": parent_name,
}
print(json.dumps(payload, sort_keys=True))
PY
}


rapl_enable_domain() {
  local path="${1:-}"
  [[ -n "${path}" && -d "${path}" ]] || return 1
  [[ -e "${path}/enabled" ]] || return 1

  local current
  current="$(cat "${path}/enabled" 2>/dev/null || echo '')"
  if [[ "${current}" == "1" ]]; then
    return 0
  fi

  local parent
  parent="$(dirname "${path}")"
  if [[ "${parent}" != "${path}" && -e "${parent}/enabled" ]]; then
    rapl_enable_domain "${parent}" || true
  fi

  echo 1 | sudo tee "${path}/enabled" >/dev/null 2>&1 || true
  current="$(cat "${path}/enabled" 2>/dev/null || echo '')"
  if [[ "${current}" != "1" ]]; then
    sleep 1
    current="$(cat "${path}/enabled" 2>/dev/null || echo '')"
  fi

  if [[ "${current}" == "1" ]]; then
    log_info "[RAPL] Enabled domain $(cat "${path}/name" 2>/dev/null || basename "${path}") at ${path}."
    return 0
  fi

  log_warn "[RAPL] Failed to enable domain $(cat "${path}/name" 2>/dev/null || basename "${path}") at ${path}; enabled=${current:-?}."
  return 1
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


mba_discover_caps() {
  mount_resctrl
  local mb_line
  if ! mb_line="$(grep -E '^[[:space:]]*MB:' /sys/fs/resctrl/schemata 2>/dev/null | head -n1)"; then
    die "No MB line in /sys/fs/resctrl/schemata (MBA unsupported or disabled)"
  fi
  [[ -n "${mb_line}" ]] || die "No MB line in /sys/fs/resctrl/schemata (MBA unsupported or disabled)"

  MBA_IDS="$(
    python3 - "${mb_line}" <<'PY'
import sys
line = sys.argv[1].strip()
payload = line[3:] if line.startswith("MB:") else line
ids = []
for item in payload.split(";"):
    if "=" not in item:
        continue
    domain, _ = item.split("=", 1)
    domain = domain.strip()
    if domain:
        ids.append(domain)
print(" ".join(ids))
PY
  )"
  [[ -n "${MBA_IDS}" ]] || die "Failed to discover MBA domains"

  MBA_BANDWIDTH_GRAN="$(cat /sys/fs/resctrl/info/MB/bandwidth_gran 2>/dev/null || echo '')"
  MBA_MIN_BANDWIDTH="$(cat /sys/fs/resctrl/info/MB/min_bandwidth 2>/dev/null || echo '')"
  MBA_NUM_CLOSIDS="$(cat /sys/fs/resctrl/info/MB/num_closids 2>/dev/null || echo '')"

  export MBA_IDS MBA_BANDWIDTH_GRAN MBA_MIN_BANDWIDTH MBA_NUM_CLOSIDS
}


build_mb_schemata() {
  local percent="${1:?missing mba percent}"
  python3 - "${MBA_IDS:-}" "${percent}" <<'PY'
import sys

domain_text = sys.argv[1].strip()
percent = sys.argv[2].strip()
parts = []
for domain in [tok for tok in domain_text.split() if tok]:
    parts.append(f"{domain}={percent}")
print("MB:" + ";".join(parts))
PY
}


mba_group_state_json() {
  local group="${1:-}"
  local root="/sys/fs/resctrl"
  python3 - "${group}" "${root}" <<'PY'
import json
import pathlib
import sys

group = sys.argv[1].strip()
root = pathlib.Path(sys.argv[2])
group_path = root / group if group else None
last_cmd = (root / "info" / "last_cmd_status")

def read_text(path: pathlib.Path):
    if not path.exists():
        return None
    try:
        return path.read_text(encoding="utf-8").strip()
    except Exception:
        return None

payload = {
    "group": group or None,
    "group_exists": bool(group_path and group_path.exists()),
    "schemata": read_text(group_path / "schemata") if group_path else None,
    "cpus_list": read_text(group_path / "cpus_list") if group_path else None,
    "tasks": read_text(group_path / "tasks") if group_path else None,
    "last_cmd_status": read_text(last_cmd),
    "root_schemata": read_text(root / "schemata"),
}
print(json.dumps(payload, sort_keys=True))
PY
}


restore_mba_defaults() {
  if [[ ${MBA_RESTORE_REGISTERED:-false} != true ]]; then
    return
  fi
  local root="/sys/fs/resctrl"
  sudo rmdir "${root}/${RDT_GROUP_WL}" 2>/dev/null || true
  sudo rmdir "${root}/${RDT_GROUP_SYS}" 2>/dev/null || true
  if [[ -n "${MBA_IDS:-}" ]]; then
    local full_line
    full_line="$(build_mb_schemata 100)"
    echo "${full_line}" | sudo tee "${root}/schemata" >/dev/null || true
  fi
  umount_resctrl_if_empty
  MBA_RESTORE_REGISTERED=false
  MBA_ACTIVE_SCOPE=""
  MBA_ACTIVE_PERCENT=""
  echo "[MBA] Restored defaults."
}


mba_setup_once() {
  local MBA_PCT="off"
  local MBA_SCOPE="${MBA_SCOPE:-pid}"
  local WL_CPUS="${WORKLOAD_CORE_DEFAULT}"
  local TOOLS_CPUS="${TOOLS_CORE_DEFAULT}"
  local WL_GROUP="${RDT_GROUP_WL:-wl_core}"
  local SYS_GROUP="${RDT_GROUP_SYS:-sys_rest}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mba)
        MBA_PCT="$2"
        shift 2
        ;;
      --mba-scope)
        MBA_SCOPE="$2"
        shift 2
        ;;
      --wl-core|--wl-cpus)
        WL_CPUS="$2"
        shift 2
        ;;
      --tools-core|--tools-cpus)
        TOOLS_CPUS="$2"
        shift 2
        ;;
      *)
        echo "[MBA] Unknown arg $1"
        return 1
        ;;
    esac
  done

  [[ -n "${MBA_PCT}" ]] || MBA_PCT="off"
  if [[ "${MBA_PCT,,}" == "off" ]]; then
    return 0
  fi
  if ! [[ "${MBA_PCT}" =~ ^[0-9]+$ ]]; then
    die "MBA must be an integer percentage"
  fi

  mba_discover_caps
  if [[ -n "${MBA_MIN_BANDWIDTH:-}" && "${MBA_PCT}" -lt "${MBA_MIN_BANDWIDTH}" ]]; then
    die "MBA ${MBA_PCT}% is below platform minimum ${MBA_MIN_BANDWIDTH}%"
  fi
  if [[ -n "${MBA_BANDWIDTH_GRAN:-}" && "${MBA_BANDWIDTH_GRAN}" != "0" ]]; then
    if (( MBA_PCT % MBA_BANDWIDTH_GRAN != 0 )); then
      die "MBA ${MBA_PCT}% is not representable with granularity ${MBA_BANDWIDTH_GRAN}%"
    fi
  fi
  case "${MBA_SCOPE}" in
    pid|cpu) ;;
    *) die "MBA scope must be 'pid' or 'cpu'" ;;
  esac

  local root="/sys/fs/resctrl"
  local wl_schem sys_schem full_schem
  WL_CPUS="$(normalize_cpu_mask "${WL_CPUS}")"
  TOOLS_CPUS="$(normalize_cpu_mask "${TOOLS_CPUS}")"
  [[ -n "${WL_CPUS}" ]] || die "MBA workload CPU mask is empty"
  [[ -n "${TOOLS_CPUS}" ]] || die "MBA tools CPU mask is empty"

  full_schem="$(build_mb_schemata 100)"
  wl_schem="$(build_mb_schemata "${MBA_PCT}")"
  sys_schem="${full_schem}"

  RDT_GROUP_WL="${WL_GROUP}"
  RDT_GROUP_SYS="${SYS_GROUP}"
  export RDT_GROUP_WL RDT_GROUP_SYS

  make_groups "${RDT_GROUP_WL}" "${RDT_GROUP_SYS}"
  echo "${full_schem}" | sudo tee "${root}/schemata" >/dev/null || die "Failed to reset root MB schemata"
  echo "${WL_CPUS}" | sudo tee "${root}/${RDT_GROUP_WL}/cpus_list" >/dev/null
  echo "$(cpu_list_except "${WL_CPUS}")" | sudo tee "${root}/${RDT_GROUP_SYS}/cpus_list" >/dev/null
  echo "${wl_schem}" | sudo tee "${root}/${RDT_GROUP_WL}/schemata" >/dev/null || die "Failed to program MBA workload schemata"
  echo "${sys_schem}" | sudo tee "${root}/${RDT_GROUP_SYS}/schemata" >/dev/null || die "Failed to program MBA system schemata"

  MBA_RESTORE_REGISTERED=true
  MBA_ACTIVE_SCOPE="${MBA_SCOPE}"
  MBA_ACTIVE_PERCENT="${MBA_PCT}"
  export MBA_ACTIVE_SCOPE MBA_ACTIVE_PERCENT
  trap_add 'restore_mba_defaults' EXIT

  echo "[MBA] Configured ${MBA_PCT}% for workload group ${RDT_GROUP_WL} using ${MBA_SCOPE}-scoped mode."
}


mba_assign_tasks() {
  local group="${1:?missing group}"
  shift
  local pid
  for pid in "$@"; do
    [[ -n "${pid}" ]] || continue
    echo "${pid}" | sudo tee "/sys/fs/resctrl/${group}/tasks" >/dev/null || return 1
  done
}


mba_collect_task_ids() {
  local root_pid="${1:?missing root pid}"
  python3 - "${root_pid}" <<'PY'
import pathlib
import sys

root_pid = int(sys.argv[1])
proc_root = pathlib.Path("/proc")

children = {}
for entry in proc_root.iterdir():
    if not entry.name.isdigit():
        continue
    stat_path = entry / "stat"
    try:
        text = stat_path.read_text(encoding="utf-8")
    except Exception:
        continue
    try:
        after = text.rsplit(") ", 1)[1].split()
        ppid = int(after[1])
        pid = int(entry.name)
    except Exception:
        continue
    children.setdefault(ppid, []).append(pid)

seen = set()
stack = [root_pid]
while stack:
    pid = stack.pop()
    if pid in seen:
        continue
    if not (proc_root / str(pid)).exists():
        continue
    seen.add(pid)
    stack.extend(children.get(pid, []))

task_ids = set()
for pid in seen:
    task_dir = proc_root / str(pid) / "task"
    if not task_dir.exists():
        continue
    for task in task_dir.iterdir():
        if task.name.isdigit():
            task_ids.add(int(task.name))

for tid in sorted(task_ids):
    print(tid)
PY
}


# detect_hw_model
#   Return the local hardware model string from DMI when available.
#   Arguments: none.
detect_hw_model() {
  if [[ -r /sys/devices/virtual/dmi/id/product_name ]]; then
    cat /sys/devices/virtual/dmi/id/product_name
  else
    printf '%s\n' "unknown"
  fi
}


# is_c240g5_family
#   Check whether the local host matches the CloudLab C220/C240 family used by c240g5.
#   Arguments:
#     $1 - optional hardware model string (defaults to detect_hw_model).
is_c240g5_family() {
  local hw_model="${1:-$(detect_hw_model)}"
  case "${hw_model}" in
    *c240g5*|*C240G5*|*c220g2*|*C220G2*|*C220*|*UCSC-C240*|*UCSC-C220*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}


# enforce_c240g5_control_policy
#   Apply the c240g5-specific availability rules for hardware controls.
#   Arguments:
#     --pkgcap <watts|off>
#     --dramcap <watts|off>
#     --llc <percent|off>
enforce_c240g5_control_policy() {
  local pkgcap_request="off"
  local dramcap_request="off"
  local llc_request="100"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pkgcap)
        pkgcap_request="${2:-off}"
        shift 2
        ;;
      --dramcap)
        dramcap_request="${2:-off}"
        shift 2
        ;;
      --llc)
        llc_request="${2:-100}"
        shift 2
        ;;
      *)
        die "Unknown c240g5 control-policy arg: $1"
        ;;
    esac
  done

  local hw_model
  hw_model="$(detect_hw_model)"
  export HW_MODEL="${hw_model}"
  if ! is_c240g5_family "${hw_model}"; then
    return 0
  fi

  if [[ -n "${dramcap_request}" && "${dramcap_request,,}" != "off" ]]; then
    die "[c240g5] DRAM power capping is unavailable on this deployment."
  fi

  if [[ -n "${llc_request}" && "${llc_request,,}" != "off" && "${llc_request}" != "100" ]]; then
    die "[c240g5] LLC/CAT allocation is unavailable on this deployment."
  fi

  if [[ -n "${pkgcap_request}" && "${pkgcap_request,,}" != "off" && "${pkgcap_request}" =~ ^[0-9]+$ ]]; then
    if (( pkgcap_request < 25 )); then
      log_warn "[c240g5] Requested pkgcap ${pkgcap_request}W is below the validated 25W floor and enters the collapse regime on this node family."
    fi
  fi
}


# cpu_mask_first_cpu
#   Return the first logical CPU contained in a compact CPU mask/range string.
#   Arguments:
#     $1 - CPU mask/range string.
cpu_mask_first_cpu() {
  local mask="${1:-}"
  [[ -n "${mask}" ]] || return 1
  cpu_mask_to_list "${mask}" | head -n1
}


# energy_policy_probe_cpu
#   Resolve the runtime EPP/EPB control exposed for a representative CPU.
#   Arguments:
#     $1 - CPU ID.
energy_policy_probe_cpu() {
  local cpu="${1:?missing cpu}"
  local epp_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/energy_performance_preference"
  local epb_path="/sys/devices/system/cpu/cpu${cpu}/power/energy_perf_bias"

  ENERGY_POLICY_KIND=""
  ENERGY_POLICY_PATH=""
  if [[ -r "${epp_path}" ]]; then
    ENERGY_POLICY_KIND="epp"
    ENERGY_POLICY_PATH="${epp_path}"
  elif [[ -r "${epb_path}" ]]; then
    ENERGY_POLICY_KIND="epb"
    ENERGY_POLICY_PATH="${epb_path}"
  else
    return 1
  fi
  export ENERGY_POLICY_KIND ENERGY_POLICY_PATH
}


# energy_policy_read_value
#   Read the currently exposed EPP/EPB value for a representative CPU.
#   Arguments:
#     $1 - CPU ID.
energy_policy_read_value() {
  local cpu="${1:?missing cpu}"
  energy_policy_probe_cpu "${cpu}" || return 1
  cat "${ENERGY_POLICY_PATH}" 2>/dev/null
}


_energy_policy_monitor_loop() {
  local cpu="${1:?missing cpu}"
  local outfile="${2:?missing outfile}"
  local interval_sec="${3:-1}"
  local sample_ts value

  while true; do
    sample_ts="$(date +%s.%N)"
    value="$(energy_policy_read_value "${cpu}" 2>/dev/null || true)"
    printf '%s\t%s\n' "${sample_ts}" "${value}" >> "${outfile}"
    sleep "${interval_sec}"
  done
}


# start_energy_policy_monitor
#   Sample the workload CPU's EPP/EPB value throughout the run so stability can be verified later.
#   Arguments:
#     $1 - representative workload CPU.
#     $2 - samples file path.
#     $3 - summary JSON path.
#     $4 - optional interval in seconds.
#     $5 - optional variable name that should receive the monitor PID.
start_energy_policy_monitor() {
  local cpu="${1:?missing cpu}"
  local samples_path="${2:?missing samples path}"
  local summary_path="${3:?missing summary path}"
  local interval_sec="${4:-1}"
  local pid_var="${5:-ENERGY_POLICY_MONITOR_PID}"

  : > "${samples_path}"
  if ! energy_policy_probe_cpu "${cpu}"; then
    python3 - "${summary_path}" "${cpu}" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({
    "available": False,
    "cpu": sys.argv[2],
    "kind": None,
    "path": None,
    "sample_count": 0,
    "stable": None,
    "unique_values": [],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    return 0
  fi

  ENERGY_POLICY_MONITOR_CPU="${cpu}"
  ENERGY_POLICY_SAMPLES_PATH="${samples_path}"
  ENERGY_POLICY_SUMMARY_PATH="${summary_path}"
  export ENERGY_POLICY_MONITOR_CPU ENERGY_POLICY_SAMPLES_PATH ENERGY_POLICY_SUMMARY_PATH

  printf '%s\t%s\n' "$(date +%s.%N)" "$(cat "${ENERGY_POLICY_PATH}" 2>/dev/null || true)" >> "${samples_path}"
  _energy_policy_monitor_loop "${cpu}" "${samples_path}" "${interval_sec}" &
  local pid=$!
  printf -v "${pid_var}" '%s' "${pid}"
  export "${pid_var}"
}


# stop_energy_policy_monitor
#   Stop a previously started EPP/EPB monitor and summarize stability across the run.
#   Arguments:
#     $1 - monitor PID (optional).
#     $2 - samples file path.
#     $3 - summary JSON path.
stop_energy_policy_monitor() {
  local pid="${1:-}"
  local samples_path="${2:?missing samples path}"
  local summary_path="${3:?missing summary path}"

  if [[ -n "${pid}" ]]; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi

  python3 - "${samples_path}" "${summary_path}" "${ENERGY_POLICY_MONITOR_CPU:-}" "${ENERGY_POLICY_KIND:-}" "${ENERGY_POLICY_PATH:-}" <<'PY'
import json
import sys
from pathlib import Path

samples_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
cpu = sys.argv[3] or None
kind = sys.argv[4] or None
path = sys.argv[5] or None
samples = []
if samples_path.exists():
    for line in samples_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        samples.append({"timestamp": parts[0], "value": parts[1]})

values = [sample["value"] for sample in samples]
mid_sample = samples[len(samples) // 2] if samples else None
payload = {
    "available": kind is not None,
    "cpu": cpu,
    "kind": kind,
    "path": path,
    "sample_count": len(samples),
    "initial": samples[0]["value"] if samples else None,
    "start": samples[0] if samples else None,
    "mid": mid_sample,
    "end": samples[-1] if samples else None,
    "stable": len(set(values)) <= 1 if samples else None,
    "unique_values": sorted(set(values)),
}
summary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}


_mba_pid_tracker_loop() {
  local root_pid="${1:?missing root pid}"
  local group="${2:?missing group}"
  local assignments_path="${3:?missing assignments path}"
  local interval_sec="${4:-0.2}"
  local ids tid assigned_list sample_ts

  while kill -0 "${root_pid}" 2>/dev/null; do
    ids="$(mba_collect_task_ids "${root_pid}" 2>/dev/null || true)"
    assigned_list=()
    if [[ -n "${ids}" ]]; then
      while IFS= read -r tid; do
        [[ -n "${tid}" ]] || continue
        if mba_assign_tasks "${group}" "${tid}"; then
          assigned_list+=("${tid}")
        fi
      done <<< "${ids}"
    fi
    sample_ts="$(date +%s.%N)"
    printf '%s\t%s\t%s\n' "${sample_ts}" "${root_pid}" "$(IFS=,; echo "${assigned_list[*]}")" >> "${assignments_path}"
    sleep "${interval_sec}"
  done
}


# start_mba_pid_tracker
#   Continuously assign a workload PID tree into the configured MBA group.
#   Arguments:
#     $1 - root PID to monitor.
#     $2 - assignments log path.
#     $3 - optional interval in seconds.
#     $4 - optional variable name that should receive the tracker PID.
start_mba_pid_tracker() {
  local root_pid="${1:?missing root pid}"
  local assignments_path="${2:?missing assignments path}"
  local interval_sec="${3:-0.2}"
  local pid_var="${4:-MBA_TRACKER_PID}"

  if [[ "${MBA_ACTIVE_SCOPE:-}" != "pid" || "${MBA_ACTIVE_PERCENT:-off}" == "off" ]]; then
    return 0
  fi

  : > "${assignments_path}"
  _mba_pid_tracker_loop "${root_pid}" "${RDT_GROUP_WL:?missing RDT_GROUP_WL}" "${assignments_path}" "${interval_sec}" &
  local pid=$!
  printf -v "${pid_var}" '%s' "${pid}"
  export "${pid_var}"
}


# stop_mba_pid_tracker
#   Stop a previously started MBA PID tracker loop.
#   Arguments:
#     $1 - tracker PID (optional).
stop_mba_pid_tracker() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}


# run_command_with_optional_mba_pid_tracking
#   Run a foreground command, optionally tracking its descendant task IDs into the MBA workload group.
#   Arguments:
#     $1 - log path that should receive stdout/stderr.
#     $2... - command and arguments to execute.
run_command_with_optional_mba_pid_tracking() {
  local log_path="${1:?missing log path}"
  shift
  local root_pid status=0

  "$@" >> "${log_path}" 2>&1 &
  root_pid=$!
  if [[ "${MBA_ACTIVE_SCOPE:-}" == "pid" && "${MBA_ACTIVE_PERCENT:-off}" != "off" && -n "${MBA_ASSIGNMENTS_PATH:-}" ]]; then
    start_mba_pid_tracker "${root_pid}" "${MBA_ASSIGNMENTS_PATH}" "${MBA_TRACK_INTERVAL_SEC:-0.2}" "MBA_TRACKER_PID"
  fi
  wait "${root_pid}" || status=$?
  stop_mba_pid_tracker "${MBA_TRACKER_PID:-}"
  unset MBA_TRACKER_PID
  return "${status}"
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


# rapl_format_watts
#   Convert a micro-watt value into a human-readable watt string ("%.3f").
#   Arguments:
#     $1 - integer value in micro-watts.
rapl_format_watts() {
  local uw="$1"
  if [[ -z "$uw" ]]; then
    echo ""
    return 1
  fi
  awk -v x="$uw" 'BEGIN { printf "%.3f", x/1000000 }'
}


# rapl_summarize_sysfs_limits
#   Print the current/min/max RAPL limits for a given powercap domain when sysfs
#   exposes the constraint files (method #1 for validation).
#   Arguments:
#     $1 - display label (e.g. "Package").
#     $2 - sysfs directory (e.g. /sys/class/powercap/intel-rapl:0).
#     $3 - constraint prefix (default: constraint_0).
rapl_summarize_sysfs_limits() {
  local label="$1" path="$2" constraint="${3:-constraint_0}"
  local cur_file="${path}/${constraint}_power_limit_uw"
  local min_file="${path}/${constraint}_min_power_uw"
  local max_file="${path}/${constraint}_max_power_uw"
  local window_file="${path}/${constraint}_time_window_us"

  if [[ ! -d "$path" ]]; then
    echo "$label RAPL sysfs: path ${path} not present"
    return
  fi

  if [[ -r "$cur_file" ]]; then
    local cur
    cur=$(cat "$cur_file")
    printf "%s RAPL current limit = %s W\n" "$label" "$(rapl_format_watts "$cur")"
  else
    echo "$label RAPL current limit = <unavailable>"
  fi

  if [[ -r "$min_file" ]]; then
    local min
    min=$(cat "$min_file")
    printf "%s RAPL min allowed = %s W (sysfs)\n" "$label" "$(rapl_format_watts "$min")"
  fi
  if [[ -r "$max_file" ]]; then
    local max
    max=$(cat "$max_file")
    printf "%s RAPL max allowed = %s W (sysfs)\n" "$label" "$(rapl_format_watts "$max")"
  fi
  if [[ -r "$window_file" ]]; then
    local window
    window=$(cat "$window_file")
    printf "%s RAPL window      = %s µs\n" "$label" "$window"
  fi
}


# rapl_print_msr_info
#   Print min/thermal/max power derived from the MSR_*_POWER_INFO registers when
#   rdmsr is available (method #2 for validation).
#   Arguments:
#     $1 - display label (e.g. "Package").
#     $2 - MSR address (hex, e.g. 0x614).
rapl_print_msr_info() {
  local label="$1" msr_addr="$2" msr_disp="$2"
  if [[ "$msr_addr" == 0x* || "$msr_addr" == 0X* ]]; then
    printf -v msr_disp "0x%X" "$((msr_addr))"
  else
    printf -v msr_disp "0x%X" "$msr_addr"
  fi
  if [[ -z "$msr_addr" ]]; then
    return
  fi
  if ! command -v rdmsr >/dev/null 2>&1; then
    echo "$label RAPL (MSR): rdmsr not available"
    return
  fi
  local units_hex info_hex
  if ! units_hex=$(sudo rdmsr -p0 0x606 2>/dev/null); then
    echo "$label RAPL (MSR): unable to read MSR_RAPL_POWER_UNIT"
    return
  fi
  if ! info_hex=$(sudo rdmsr -p0 "$msr_addr" 2>/dev/null); then
    echo "$label RAPL (MSR): unable to read ${msr_disp}"
    return
  fi
  python3 - "$label" "$msr_addr" "$units_hex" "$info_hex" <<'PY'
import sys

label, msr_addr_hex, units_hex, info_hex = sys.argv[1:]
units_val = int(units_hex, 16)
power_units = 1.0 / (2 ** (units_val & 0xF))
info_val = int(info_hex, 16)

thermal = (info_val & 0x7FFF) * power_units
min_p = ((info_val >> 16) & 0x7FFF) * power_units
max_p = ((info_val >> 32) & 0x7FFF) * power_units
window_raw = (info_val >> 48) & 0xFFFF

print(
    f"{label} RAPL (MSR {int(msr_addr_hex, 0):#04x}): "
    f"thermal={thermal:.3f} W min={min_p:.3f} W max={max_p:.3f} W "
    f"(window raw=0x{window_raw:04x})"
)
PY
}


# rapl_report_combined_limits
#   Convenience wrapper used by run scripts to emit both sysfs and MSR readings
#   for the package/DRAM domains.
#   Arguments:
#     $1 - display label
#     $2 - sysfs path
#     $3 - constraint prefix
#     $4 - MSR address (optional; e.g. 0x614)
rapl_report_combined_limits() {
  local label="$1" path="$2" constraint="${3:-constraint_0}" msr_addr="$4"
  rapl_summarize_sysfs_limits "$label" "$path" "$constraint"
  if [[ -n "$msr_addr" ]]; then
    rapl_print_msr_info "$label" "$msr_addr"
  fi
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


# llc_choose_effective_allocation
#   Convert a requested LLC percentage into the nearest representable way count.
#   Arguments:
#     $1 - requested LLC percentage (integer).
llc_choose_effective_allocation() {
  local pct="$1"
  local exact_num floor_ways ceil_ways ways_req dist_floor dist_ceil
  exact_num=$(( pct * WAYS_TOTAL ))
  floor_ways=$(( exact_num / 100 ))
  ceil_ways=$(( (exact_num + 99) / 100 ))
  dist_floor=$(( exact_num - floor_ways * 100 ))
  dist_ceil=$(( ceil_ways * 100 - exact_num ))

  if (( dist_floor <= dist_ceil )); then
    ways_req=$floor_ways
  else
    ways_req=$ceil_ways
  fi

  LLC_EFFECTIVE_WAYS="$ways_req"
  LLC_EFFECTIVE_PERCENT="$(awk -v w="${ways_req}" -v t="${WAYS_TOTAL}" 'BEGIN{printf "%.2f", (100.0 * w) / t}')"
}


# percent_to_exclusive_mask
#   Convert the chosen exclusive LLC way count into a cache mask string.
#   Arguments: none. Uses LLC_EFFECTIVE_WAYS from llc_choose_effective_allocation.
percent_to_exclusive_mask() {
  local ways_req="${LLC_EFFECTIVE_WAYS:-}"
  [[ -n "${ways_req}" ]] || die "Internal LLC error: effective way count was not chosen before mask construction"

  # Respect min_cbm_bits and exclusive capacity
  if (( ways_req < MIN_BITS )); then
    die "Requested allocation -> ${ways_req} ways is below min_cbm_bits=${MIN_BITS}"
  fi
  if (( ways_req > WAYS_EXCL_MAX )); then
    die "Requested allocation -> ${ways_req} ways exceeds exclusive capacity (${WAYS_EXCL_MAX}/${WAYS_TOTAL})"
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
#   Produce a compact CPU range string for all online CPUs except the supplied mask.
#   Arguments:
#     $1 - CPU mask to exclude.
cpu_list_except() {
  local exclude="${1:-}"
  cpu_mask_minus "$(cpu_online_list)" "${exclude}"
}


# cpu_mask_l3_ids
#   Return the selected L3 cache ids for a workload CPU mask.
#   Arguments:
#     $1 - workload CPU mask.
cpu_mask_l3_ids() {
  local mask="${1:?missing CPU mask}"
  python3 - "${mask}" <<'PY'
import sys
from pathlib import Path

def expand(mask_text: str):
    values = set()
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return sorted(values)

l3_ids = set()
for cpu in expand(sys.argv[1]):
    path = Path(f"/sys/devices/system/cpu/cpu{cpu}/cache/index3/id")
    if path.exists():
        raw = path.read_text(encoding="utf-8").strip()
        if raw:
            l3_ids.add(raw)
print(" ".join(sorted(l3_ids, key=int)))
PY
}


# build_socket_aware_schemata
#   Build an L3 schemata line that only constrains the selected L3 ids.
#   Arguments:
#     $1 - selected-domain mask (hex, no 0x)
#     $2 - default mask for non-selected domains (hex, no 0x)
#     $3 - selected L3 ids (space-delimited)
build_socket_aware_schemata() {
  local selected_mask="${1:?missing selected mask}"
  local default_mask="${2:?missing default mask}"
  local selected_ids="${3:-}"
  python3 - "${L3_IDS:-}" "${selected_mask}" "${default_mask}" "${selected_ids}" <<'PY'
import sys

all_ids = [tok for tok in (sys.argv[1] if len(sys.argv) > 1 else "").split() if tok]
selected_mask = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()
default_mask = (sys.argv[3] if len(sys.argv) > 3 else "").strip().lower()
selected_ids = {tok for tok in (sys.argv[4] if len(sys.argv) > 4 else "").split() if tok}

parts = []
for l3_id in all_ids:
    mask = selected_mask if l3_id in selected_ids else default_mask
    parts.append(f"{l3_id}={mask}")
print("L3:" + ";".join(parts))
PY
}


# make_groups
#   Create workload and system resctrl groups, removing any stale directories first.
#   Arguments:
#     $1 - workload group name.
#     $2 - system/background group name.
reclaim_empty_resctrl_groups() {
  local keep_a="${1:-}"
  local keep_b="${2:-}"
  local dir name
  for dir in /sys/fs/resctrl/*; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    [[ "${name}" == "info" ]] && continue
    [[ -n "${keep_a}" && "${name}" == "${keep_a}" ]] && continue
    [[ -n "${keep_b}" && "${name}" == "${keep_b}" ]] && continue

    local tasks_text cpus_text
    tasks_text="$(cat "${dir}/tasks" 2>/dev/null || true)"
    cpus_text="$(cat "${dir}/cpus_list" 2>/dev/null || true)"
    if [[ -z "${tasks_text//[[:space:]]/}" && -z "${cpus_text//[[:space:]]/}" ]]; then
      sudo rmdir "${dir}" 2>/dev/null || true
    fi
  done
}

make_groups() {
  local wl="$1" sys="$2"
  sudo rmdir "/sys/fs/resctrl/${wl}" 2>/dev/null || true
  sudo rmdir "/sys/fs/resctrl/${sys}" 2>/dev/null || true
  if ! sudo mkdir "/sys/fs/resctrl/${wl}" 2>/dev/null; then
    reclaim_empty_resctrl_groups "${wl}" "${sys}"
    sudo mkdir "/sys/fs/resctrl/${wl}" || die "mkdir wl group failed"
  fi
  if ! sudo mkdir "/sys/fs/resctrl/${sys}" 2>/dev/null; then
    reclaim_empty_resctrl_groups "${wl}" "${sys}"
    sudo mkdir "/sys/fs/resctrl/${sys}" || die "mkdir sys group failed"
  fi
}


# program_groups
#   Program resctrl schemata and CPU lists for the workload and system groups.
#   Order matters: shrink root to REST, write WL/SYS, then set WL exclusive.
#   Arguments:
#     $1 - workload group name (e.g., wl_core)
#     $2 - system/background group name (e.g., sys_rest)
#     $3 - workload CPU mask (e.g., 6-9)
#     $4 - workload LLC mask (hex, no 0x, lowercase)
#     $5 - selected L3 ids (space-delimited)
program_groups() {
  local wl="$1"; local sys="$2"; local wl_cpus="$3"; local wl_mask="${4,,}"  # normalize to lowercase
  local selected_l3_ids="${5:-}"
  local cbm_mask="${CBM_MASK,,}"; local share_mask="${SHARE_MASK,,}"
  local root="/sys/fs/resctrl"
  local rest_mask_hex

  # Sanity: WL mask must not include shareable bits
  if (( ( 0x${wl_mask:-0} & 0x${share_mask:-0} ) != 0 )); then
    die "WL mask 0x${wl_mask} overlaps shareable bits 0x${share_mask}"
  fi

  # Compute REST = CBM_MASK & ~WL_MASK (width matches CBM_MASK)
  rest_mask_hex="$(printf "%0${#cbm_mask}x" $(( 0x${cbm_mask} & ~0x${wl_mask:-0} )))"

  local wl_schem sys_schem root_schem
  wl_schem="$(build_socket_aware_schemata "${wl_mask}" "${cbm_mask}" "${selected_l3_ids}")"
  sys_schem="$(build_socket_aware_schemata "${rest_mask_hex}" "${cbm_mask}" "${selected_l3_ids}")"
  root_schem="${sys_schem}"

  # Program root first so it relinquishes WL bits
  sudo tee "${root}/schemata" > /dev/null <<<"${root_schem}"     || die "Failed to program root schemata to REST mask (${root_schem})"

  # Assign CPUs
  echo "${wl_cpus}" | sudo tee "${root}/${wl}/cpus_list"  >/dev/null
  echo "$(cpu_list_except "${wl_cpus}")" | sudo tee "${root}/${sys}/cpus_list" >/dev/null

  # Program WL / SYS schemata
  sudo tee "${root}/${wl}/schemata"  > /dev/null <<<"${wl_schem}"      || die "Failed to program '${wl}' schemata (${wl_schem})"
  sudo tee "${root}/${sys}/schemata" > /dev/null <<<"${sys_schem}"     || die "Failed to program '${sys}' schemata (${sys_schem})"

  LLC_EXCLUSIVE_ACTIVE=false
  echo exclusive | sudo tee "${root}/${wl}/mode" > /dev/null || true

  if [[ -r "${root}/info/last_cmd_status" ]]; then
    local st
    st="$(<"${root}/info/last_cmd_status")"
    if [[ "${st}" == "ok" ]]; then
      LLC_EXCLUSIVE_ACTIVE=true
    else
      log_warn "[LLC] Exclusive mode rejected for '${wl}' (${st}); continuing with non-exclusive resctrl mode because schemata are already disjoint."
    fi
  fi
}



# verify_once
#   Validate that a workload resctrl group has the expected mask and CPU list.
#   Supported call forms:
#     (old) verify_once <wl_group> <wl_cpus> <wl_mask>
#     (new) verify_once <wl_group> <sys_group> <wl_mask> <wl_cpus> [wl_pids_csv]
verify_once() {
  set +u  # avoid nounset while we normalize args safely
  local root="/sys/fs/resctrl"
  local a1="$1" a2="$2" a3="$3" a4="$4" a5="$5"
  set -u

  local wl sys wl_mask wl_cpus wl_pids_csv
  if [[ -n "${a4:-}" || -n "${a5:-}" ]]; then
    # New signature: wl, sys, mask, core, [pids]
    wl="$a1"; sys="$a2"; wl_mask="${a3,,}"; wl_cpus="$a4"; wl_pids_csv="${a5:-}"
  else
    # Old signature: wl, core, mask
    wl="$a1"; wl_cpus="$a2"; wl_mask="${a3,,}"; sys="${RDT_GROUP_SYS:-sys_rest}"
  fi

  local schemata_json
  schemata_json="$(
    python3 - "${root}/${wl}/schemata" "${root}/${sys}/schemata" "${LLC_SELECTED_L3_IDS:-}" <<'PY'
import json
import pathlib
import sys

def parse(path_text: str):
    path = pathlib.Path(path_text)
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("L3:"):
            continue
        payload = line[3:]
        for item in payload.split(";"):
            if "=" not in item:
                continue
            domain, mask = item.split("=", 1)
            found[domain.strip()] = mask.strip().lower()
    return found

selected = [tok for tok in (sys.argv[3] if len(sys.argv) > 3 else "").split() if tok]
print(json.dumps({"wl": parse(sys.argv[1]), "sys": parse(sys.argv[2]), "selected": selected}, sort_keys=True))
PY
  )"

  if [[ -z "${schemata_json}" ]]; then
    local st="(unknown)"; [[ -r "${root}/info/last_cmd_status" ]] && st="$(<"${root}/info/last_cmd_status")"
    die "L3 lines not found in schemata. last_cmd_status: ${st}"
  fi

  local mismatch
  mismatch="$(
    python3 - "${schemata_json}" "${wl_mask,,}" "${CBM_MASK,,}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
wl_mask = sys.argv[2]
full_mask = sys.argv[3]
selected = set(payload.get("selected") or [])
errors = []
for domain, mask in payload["wl"].items():
    expected = wl_mask if domain in selected else full_mask
    if mask != expected:
        errors.append(f"wl:{domain}:{mask}:{expected}")
for domain, mask in payload["sys"].items():
    if domain in selected and mask == full_mask:
        errors.append(f"sys:{domain}:{mask}:selected domain unexpectedly left full")
print(";".join(errors))
PY
  )"
  if [[ -n "${mismatch}" ]]; then
    die "LLC schemata mismatch: ${mismatch}"
  fi

  # Optional: bit_usage visibility (E=exclusive)
  [[ -r "${root}/info/L3/bit_usage" ]] && log_debug "L3 bit_usage: $(<"${root}/info/L3/bit_usage")"

  # Check assigned CPUs & tasks
  local got_wl_cpus expected_wl_cpus
  got_wl_cpus="$(normalize_cpu_mask "$(<"${root}/${wl}/cpus_list")")"
  expected_wl_cpus="$(normalize_cpu_mask "${wl_cpus}")"
  [[ "${got_wl_cpus}" == "${expected_wl_cpus}" ]]     || die "WL CPUs not set as expected: wanted '${expected_wl_cpus}' in '${got_wl_cpus}'"

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
  LLC_SELECTED_L3_IDS=""
  echo "[LLC] Restored defaults."
}


# llc_core_setup_once
#   Parse LLC-related CLI options, optionally carve out exclusive cache capacity, and program resctrl groups.
#   Arguments:
#     $@ - option/value pairs consumed from the main CLI parser.
llc_core_setup_once() {
  local WL_CPUS="${WORKLOAD_CORE_DEFAULT}"
  local TOOLS_CPUS="${TOOLS_CORE_DEFAULT}"
  local LLC_PCT=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --llc)
        LLC_PCT="$2"
        shift 2
        ;;
      --wl-core|--wl-cpus)
        WL_CPUS="$2"
        shift 2
        ;;
      --tools-core|--tools-cpus)
        TOOLS_CPUS="$2"
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
  local ways_req
  local effective_pct
  # Enforce min_cbm_bits as a percentage threshold (ceil(MIN_BITS/WAYS_TOTAL*100))
  local min_pct_for_min_bits=$(( (100 * MIN_BITS + WAYS_TOTAL - 1) / WAYS_TOTAL ))
  llc_choose_effective_allocation "$LLC_PCT"
  ways_req="${LLC_EFFECTIVE_WAYS:-0}"
  effective_pct="${LLC_EFFECTIVE_PERCENT:-0.00}"
  if (( ways_req < MIN_BITS )); then
    die "LLC % too small: requested ${LLC_PCT}% -> nearest representable ${effective_pct}% (${ways_req} ways); need at least ${min_pct_for_min_bits}% (min_cbm_bits=${MIN_BITS})."
  fi
  if [[ "${effective_pct}" != "$(printf '%s.00' "${LLC_PCT}")" && "${effective_pct}" != "${LLC_PCT}" ]]; then
    log_warn "[LLC] Requested ${LLC_PCT}% on ${WAYS_TOTAL}-way LLC; using nearest representable allocation ${effective_pct}% -> ${ways_req}/${WAYS_TOTAL} ways (ties round down)."
  fi

  # (capacity limit is re-checked in percent_to_exclusive_mask)
  local WL_MASK
  WL_MASK="$(percent_to_exclusive_mask)"
  local RESERVED_WAYS
  RESERVED_WAYS="$(popcnt_hex "$WL_MASK")"
  WL_CPUS="$(normalize_cpu_mask "${WL_CPUS}")"
  TOOLS_CPUS="$(normalize_cpu_mask "${TOOLS_CPUS}")"
  [[ -n "${WL_CPUS}" ]] || die "Workload CPU mask is empty"
  [[ -n "${TOOLS_CPUS}" ]] || die "Tools CPU mask is empty"
  LLC_SELECTED_L3_IDS="$(cpu_mask_l3_ids "${WL_CPUS}")"
  [[ -n "${LLC_SELECTED_L3_IDS}" ]] || die "Unable to resolve workload L3 ids for CPU mask ${WL_CPUS}"
  make_groups "$RDT_GROUP_WL" "$RDT_GROUP_SYS"
  program_groups "$RDT_GROUP_WL" "$RDT_GROUP_SYS" "$WL_CPUS" "$WL_MASK" "${LLC_SELECTED_L3_IDS}"
  verify_once "$RDT_GROUP_WL" "$RDT_GROUP_SYS" "$WL_MASK" "$WL_CPUS"
  LLC_RESTORE_REGISTERED=true
  LLC_REQUESTED_PERCENT="$LLC_PCT"
  trap_add 'restore_llc_defaults' EXIT
  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    echo "[LLC] Reserved requested ${LLC_PCT}% as ${effective_pct}% -> ${RESERVED_WAYS}/${WAYS_TOTAL} ways (mask 0x$WL_MASK) for workload CPUs ${WL_CPUS}."
  else
    echo "[LLC] Reserved requested ${LLC_PCT}% as ${effective_pct}% -> ${RESERVED_WAYS}/${WAYS_TOTAL} ways (mask 0x$WL_MASK) for workload CPUs ${WL_CPUS} using non-exclusive resctrl mode."
  fi
  if (( WAYS_SHARE > 0 )); then
    echo "[LLC] Exclusive capacity available: ${WAYS_EXCL_MAX}/${WAYS_TOTAL} ways (shareable=${WAYS_SHARE})."
  fi
  echo "[LLC] Tools should run on a different CPU mask (e.g., ${TOOLS_CPUS})."
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
  echo
  echo "Prefetchers (core-side):"
  echo "  L2_streamer       - next-line/sequential stream prefetcher in the mid-level cache"
  echo "  L2_adjacent       - adjacent cache line fetcher paired with L2 streamer"
  echo "  L1D_streamer      - L1 data cache streamer (a.k.a. DCU prefetch)"
  echo "  L1D_IP            - L1D IP-based/stride prefetcher (per-PC stride detection)"
  echo
  echo "Pattern semantics: user input uses 1=enable, 0=disable. MSR 0x1A4 encodes the opposite (1=disable); the script converts automatically."
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
  if [[ ${debug_enabled:-false} == true ]]; then
    printf '[DEBUG] %s\n' "$*"
  fi
}


# log_debug_blank
#   Emit a blank line in debug logs when debug mode is active.
#   Arguments: none.
log_debug_blank() {
  if [[ ${debug_enabled:-false} == true ]]; then
    printf '\n'
  fi
}


if ! type ghz_to_khz >/dev/null 2>&1; then
  ghz_to_khz() { # "$1" like "2.3" -> echo kHz as integer
    awk -v g="${1:-0}" 'BEGIN{printf("%d", g*1000000)}'
  }
fi

# pf_log_warn (only if not already present)
if ! type log_warn >/dev/null 2>&1; then
  log_warn() { printf '[WARN] %s\n' "$*"; }
fi

# Expand a CPU list like "6,16" or "0-3,8" to space-delimited IDs.
expand_cpu_list_tokens() {
  local s="${1:-}"
  local out=() parts=()
  IFS=',' read -r -a parts <<< "$s"
  local p a b i
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      a=${p%-*}; b=${p#*-}
      for ((i=a; i<=b; i++)); do out+=("$i"); done
    elif [[ -n "$p" ]]; then
      out+=("$p")
    fi
  done
  printf "%s\n" "${out[@]}"
}

core_expand_scope_cpus() {
  local requested=("$@")
  local seen=" "
  local out=()
  local cpu scoped sib

  for cpu in "${requested[@]}"; do
    scoped="$(pf_thread_siblings_list "${cpu}" 2>/dev/null || true)"
    [[ -n "${scoped}" ]] || scoped="${cpu}"
    for sib in $(expand_cpu_list_tokens "${scoped}"); do
      [[ " ${seen} " == *" ${sib} "* ]] && continue
      out+=("${sib}")
      seen+=" ${sib}"
    done
  done

  printf '%s\n' "${out[@]}"
}

# cpu_mask_unique_core_representatives
#   Return one logical CPU per physical core represented in the supplied mask.
#   Arguments:
#     $1 - CPU mask/range string.
cpu_mask_unique_core_representatives() {
  local mask="${1:?missing CPU mask}"
  python3 - "${mask}" <<'PY'
import sys
from pathlib import Path

def expand(mask_text: str):
    values = set()
    for raw in mask_text.split(","):
        tok = raw.strip()
        if not tok:
            continue
        if "-" in tok:
            a_text, b_text = tok.split("-", 1)
            a = int(a_text)
            b = int(b_text)
            values.update(range(a, b + 1))
        else:
            values.add(int(tok))
    return sorted(values)

seen = set()
reps = []
for cpu in expand(sys.argv[1]):
    cpu_dir = Path(f"/sys/devices/system/cpu/cpu{cpu}")
    socket = (cpu_dir / "topology/physical_package_id").read_text(encoding="utf-8").strip()
    core = (cpu_dir / "topology/core_id").read_text(encoding="utf-8").strip()
    key = (socket, core)
    if key in seen:
        continue
    seen.add(key)
    reps.append(cpu)
for cpu in reps:
    print(cpu)
PY
}

# Return sibling threads for a physical core id: prints something like "6,16".
pf_thread_siblings_list() {
  local core="${1:?missing core id}"
  local path="/sys/devices/system/cpu/cpu${core}/topology/thread_siblings_list"
  [[ -r "$path" ]] || { echo ""; return 1; }
  cat "$path"
}

# Decode a 4-bit MSR value to human-readable status of the four prefetchers.
# Input must be the 64-bit hex rdmsr result (e.g., 0x...000f)
pf_normalize_hex64() {
  local hex="${1:?missing hex value}"
  hex="${hex//$'\n'/}"
  hex="${hex//[$'\t\r ']/}"
  hex="${hex#0x}"
  hex="${hex#0X}"
  hex="${hex,,}"
  [[ "${hex}" =~ ^[0-9a-f]+$ ]] || return 1
  while ((${#hex} < 16)); do
    hex="0${hex}"
  done
  printf '%s\n' "${hex}"
}

pf_decode_bits_to_text() {
  local hex="${1:?}"
  local low=$(( hex & 0xF ))
  # Remember: 1 means disabled in MSR
  local b0=$(( (low>>0) & 1 ))
  local b1=$(( (low>>1) & 1 ))
  local b2=$(( (low>>2) & 1 ))
  local b3=$(( (low>>3) & 1 ))
  printf "L2/MLC streamer:     %s\n" "$([[ $b0 -eq 1 ]] && echo disabled || echo enabled)"
  printf "L2 adjacent line:     %s\n" "$([[ $b1 -eq 1 ]] && echo disabled || echo enabled)"
  printf "L1D/DCU streamer:     %s\n" "$([[ $b2 -eq 1 ]] && echo disabled || echo enabled)"
  printf "L1D/DCU IP (stride):  %s\n" "$([[ $b3 -eq 1 ]] && echo disabled || echo enabled)"
}

# Parse user spec to an MSR disable mask (lower 4 bits).
# User-facing semantics:
#   - "on"  -> all enabled   -> MSR disable mask 0b0000
#   - "off" -> all disabled  -> MSR disable mask 0b1111
#   - "abcd" 4-bit pattern with 1=enable, 0=disable (order: L2_streamer L2_adjacent L1D_streamer L1D_IP)
#      example: 1011 means enable L2_streamer, disable L2_adjacent, enable L1D_streamer, enable L1D_IP
#      MSR uses 1=disable, so we invert each bit: disable_mask = (~pattern) & 0xF
pf_parse_spec_to_disable_mask() {
  local spec="${1:-}"
  local lc="${spec,,}"
  local mask
  case "$lc" in
    ""|on)  mask=0 ;;
    off)    mask=15 ;;
    *)
      if [[ "$lc" =~ ^[01]{4}$ ]]; then
        local p=$((2#${lc}))
        mask=$(( (~p) & 0xF ))
      else
        echo "[FATAL] --prefetcher expects 'on', 'off', or 4 bits like 1011" >&2
        return 2
      fi
      ;;
  esac
  printf "%d\n" "$mask"
}

# Global snapshot for a single core (its threads)
declare -A __PF_SNAP=()   # key "cpuN" -> hex string

# Snapshot MSR 0x1A4 for all sibling threads of the given core id.
pf_snapshot_for_core() {
  local core="${1:?missing core id}"
  sudo modprobe msr >/dev/null 2>&1 || true
  local sibs; sibs="$(pf_thread_siblings_list "$core")"
  [[ -n "$sibs" ]] || { log_warn "[PF] Cannot find thread_siblings for core ${core}"; return 1; }
  local cpu ok=0
  for cpu in $(expand_cpu_list_tokens "$sibs"); do
    local val
    if ! val="$(sudo rdmsr -p "$cpu" 0x1a4 2>/dev/null)"; then
      log_warn "[PF] rdmsr failed on cpu${cpu}"
      continue
    fi
    __PF_SNAP["cpu${cpu}"]="$val"
    ok=$((ok+1))
  done
  if (( ok == 0 )); then
    log_warn "[PF] rdmsr failed on every thread of core ${core}; check msr-tools, permissions, or kernel config"
    return 1
  fi
  return 0
}

# Apply disable mask to MSR 0x1A4 for all sibling threads of the given core id.
# disable_mask is an integer (0..15). We keep all other MSR bits intact.
pf_apply_for_core() {
  local core="${1:?missing core id}"
  local disable_mask="${2:?missing disable mask (0..15)}"
  sudo modprobe msr >/dev/null 2>&1 || true
  local sibs; sibs="$(pf_thread_siblings_list "$core")"
  [[ -n "$sibs" ]] || { log_warn "[PF] Cannot find thread_siblings for core ${core}"; return 1; }
  local cpu hex cur new
  for cpu in $(expand_cpu_list_tokens "$sibs"); do
    if ! hex="$(sudo rdmsr -p "$cpu" 0x1a4 -0 2>/dev/null)"; then
      log_warn "[PF] rdmsr failed on cpu${cpu}"
      continue
    fi
    cur=$((hex))
    new=$(( (cur & ~0xF) | (disable_mask & 0xF) ))
    if ! sudo wrmsr -p "$cpu" 0x1a4 "$new" 2>/dev/null; then
      log_warn "[PF] wrmsr failed on cpu${cpu}"
      continue
    fi
    if [[ ${debug_enabled:-false} == true ]]; then
      printf '[DEBUG] [PF] cpu%s: 0x%016x -> 0x%016x\n' "$cpu" "$cur" "$new"
    fi
  done
}

# Restore previously snapshotted MSR 0x1A4 values for the core's threads.
pf_restore_for_core() {
  local core="${1:?missing core id}"

  # No snapshot captured; nothing to restore.
  (( ${#__PF_SNAP[@]} > 0 )) || return 0

  local sibs; sibs="$(pf_thread_siblings_list "$core")"
  [[ -n "$sibs" ]] || return 0

  local cpu saved dec
  for cpu in $(expand_cpu_list_tokens "$sibs"); do
    # Use default expansion to avoid "unbound variable" with set -u when key is absent.
    saved="${__PF_SNAP["cpu${cpu}"]-}"
    [[ -n "${saved:-}" ]] || continue
    dec=$((16#${saved}))
    sudo wrmsr -p "$cpu" 0x1a4 "$dec" 2>/dev/null || true
  done
}

# Verify the applied MSR settings by reading back the first sibling thread.
pf_verify_for_core() {
  local core="${1:?missing core id}"
  local sibs; sibs="$(pf_thread_siblings_list "$core")"
  [[ -n "$sibs" ]] || { log_warn "[PF] verify: cannot find thread_siblings for core ${core}"; return 1; }
  local first_cpu
  read -r first_cpu < <(expand_cpu_list_tokens "$sibs" | head -n1)
  [[ -n "$first_cpu" ]] || { log_warn "[PF] verify: no sibling IDs for core ${core}"; return 1; }

  local hex
  if ! hex="$(sudo rdmsr -p "$first_cpu" 0x1a4 -0 2>/dev/null)"; then
    log_warn "[PF] verify: rdmsr failed on cpu${first_cpu}"
    return 1
  fi
  printf '[INFO] [PF] verify cpu%s: MSR[1A4]=%s\n' "$first_cpu" "$hex"
  if [[ ${debug_enabled:-false} == true ]]; then
    pf_decode_bits_to_text "$hex"
  fi
}

# Snapshot MSR 0x1A4 for every physical core represented in a CPU mask.
pf_snapshot_for_mask() {
  local mask="${1:?missing CPU mask}"
  local rep ok=0
  while IFS= read -r rep; do
    [[ -n ${rep} ]] || continue
    if pf_snapshot_for_core "${rep}"; then
      ok=$((ok+1))
    fi
  done < <(cpu_mask_unique_core_representatives "${mask}")
  (( ok > 0 ))
}

# Apply a prefetcher disable mask across all physical cores represented in a CPU mask.
pf_apply_for_mask() {
  local mask="${1:?missing CPU mask}"
  local disable_mask="${2:?missing disable mask}"
  local rep
  while IFS= read -r rep; do
    [[ -n ${rep} ]] || continue
    pf_apply_for_core "${rep}" "${disable_mask}"
  done < <(cpu_mask_unique_core_representatives "${mask}")
}

# Restore prefetcher state across all physical cores represented in a CPU mask.
pf_restore_for_mask() {
  local mask="${1:?missing CPU mask}"
  local rep
  while IFS= read -r rep; do
    [[ -n ${rep} ]] || continue
    pf_restore_for_core "${rep}"
  done < <(cpu_mask_unique_core_representatives "${mask}")
}

# Verify prefetcher state across all physical cores represented in a CPU mask.
pf_verify_for_mask() {
  local mask="${1:?missing CPU mask}"
  local rep ok=0
  while IFS= read -r rep; do
    [[ -n ${rep} ]] || continue
    if pf_verify_for_core "${rep}"; then
      ok=$((ok+1))
    fi
  done < <(cpu_mask_unique_core_representatives "${mask}")
  (( ok > 0 ))
}

# Print a short, one-line decode of the lower 4 bits for logging.
pf_bits_one_liner() {
  local mask="${1:?}"
  local b0=$(( (mask>>0) & 1 ))
  local b1=$(( (mask>>1) & 1 ))
  local b2=$(( (mask>>2) & 1 ))
  local b3=$(( (mask>>3) & 1 ))
  printf 'disable_mask=0x%x [L2_streamer=%s L2_adjacent=%s L1D_streamer=%s L1D_IP=%s]\n' \
    "$mask" \
    "$([[ $b0 -eq 1 ]] && echo off || echo on)" \
    "$([[ $b1 -eq 1 ]] && echo off || echo on)" \
    "$([[ $b2 -eq 1 ]] && echo off || echo on)" \
    "$([[ $b3 -eq 1 ]] && echo off || echo on)"
}


turbo_msr_available() {
  sudo modprobe msr >/dev/null 2>&1 || true
  command -v rdmsr >/dev/null 2>&1 && command -v wrmsr >/dev/null 2>&1
}

turbo_backend_available() {
  local backend="${1:-}"
  case "${backend}" in
    sysfs-intel_pstate)
      [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]
      ;;
    sysfs-cpufreq)
      [[ -r /sys/devices/system/cpu/cpufreq/boost ]]
      ;;
    msr)
      turbo_msr_available
      ;;
    *)
      return 1
      ;;
  esac
}

turbo_detect_backend() {
  if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    printf '%s\n' "sysfs-intel_pstate"
    return 0
  fi
  if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
    printf '%s\n' "sysfs-cpufreq"
    return 0
  fi
  if turbo_msr_available; then
    printf '%s\n' "msr"
    return 0
  fi
  return 1
}

turbo_online_cpus() {
  expand_cpu_list_tokens "$(cpu_online_list)"
}

turbo_read_msr_state_for_cpu() {
  local cpu="${1:?missing cpu id}"
  local raw hex
  raw="$(sudo rdmsr -p "${cpu}" 0x1a0 -0 2>/dev/null)" || return 1
  hex="$(pf_normalize_hex64 "${raw}")" || return 1
  if (( (16#${hex} & (1 << 38)) != 0 )); then
    printf '%s\n' "off"
  else
    printf '%s\n' "on"
  fi
}

turbo_read_state() {
  local backend="${1:-}"
  local first="" cpu state

  if [[ -z "${backend}" ]]; then
    backend="$(turbo_detect_backend)" || return 1
  fi

  case "${backend}" in
    sysfs-intel_pstate)
      [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]] || return 1
      case "$(< /sys/devices/system/cpu/intel_pstate/no_turbo)" in
        0) printf '%s\n' "on" ;;
        1) printf '%s\n' "off" ;;
        *) return 1 ;;
      esac
      ;;
    sysfs-cpufreq)
      [[ -r /sys/devices/system/cpu/cpufreq/boost ]] || return 1
      case "$(< /sys/devices/system/cpu/cpufreq/boost)" in
        1) printf '%s\n' "on" ;;
        0) printf '%s\n' "off" ;;
        *) return 1 ;;
      esac
      ;;
    msr)
      while read -r cpu; do
        [[ -n "${cpu}" ]] || continue
        state="$(turbo_read_msr_state_for_cpu "${cpu}")" || return 1
        if [[ -z "${first}" ]]; then
          first="${state}"
        elif [[ "${state}" != "${first}" ]]; then
          log_warn "[CPU] Mixed turbo MSR state across online CPUs (cpu${cpu}=${state}, first=${first})."
          return 1
        fi
      done < <(turbo_online_cpus)
      [[ -n "${first}" ]] || return 1
      printf '%s\n' "${first}"
      ;;
    *)
      return 1
      ;;
  esac
}

turbo_snapshot_current() {
  TURBO_SNAP_BACKEND=""
  TURBO_SNAP_STATE=""
  TURBO_SNAPSHOT_TAKEN=false
  TURBO_SNAP_BACKEND="$(turbo_detect_backend)" || return 1
  TURBO_SNAP_STATE="$(turbo_read_state "${TURBO_SNAP_BACKEND}")" || return 1
  TURBO_SNAPSHOT_TAKEN=true
  [[ "${TURBO_SNAPSHOT_TAKEN}" == true ]]
}

turbo_apply_state() {
  local requested="${1:-}"
  local backend="${2:-}"
  local desired_bit cpu raw current_hex new_hex verified_state

  requested="${requested,,}"
  case "${requested}" in
    on|off) ;;
    *) log_warn "[CPU] Invalid turbo request '${requested}'."; return 1 ;;
  esac

  if [[ -z "${backend}" ]]; then
    backend="$(turbo_detect_backend)" || {
      log_warn "[CPU] No turbo control backend available."
      return 1
    }
  fi
  turbo_backend_available "${backend}" || {
    log_warn "[CPU] Turbo backend '${backend}' is not available on this node."
    return 1
  }

  case "${backend}" in
    sysfs-intel_pstate)
      if [[ "${requested}" == "off" ]]; then
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || return 1
      else
        echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || return 1
      fi
      ;;
    sysfs-cpufreq)
      if [[ "${requested}" == "off" ]]; then
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || return 1
      else
        echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || return 1
      fi
      ;;
    msr)
      desired_bit=0
      [[ "${requested}" == "off" ]] && desired_bit=1
      while read -r cpu; do
        [[ -n "${cpu}" ]] || continue
        raw="$(sudo rdmsr -p "${cpu}" 0x1a0 -0 2>/dev/null)" || return 1
        current_hex="$(pf_normalize_hex64 "${raw}")" || return 1
        if (( desired_bit == 1 )); then
          new_hex="$(printf '%016x' "$((16#${current_hex} | (1 << 38)))")"
        else
          new_hex="$(printf '%016x' "$((16#${current_hex} & ~(1 << 38)))")"
        fi
        sudo wrmsr -p "${cpu}" 0x1a0 "0x${new_hex}" 2>/dev/null || return 1
      done < <(turbo_online_cpus)
      ;;
    *)
      return 1
      ;;
  esac

  verified_state="$(turbo_read_state "${backend}")" || return 1
  if [[ "${verified_state}" != "${requested}" ]]; then
    log_warn "[CPU] Turbo apply mismatch: requested=${requested}, backend=${backend}, verified=${verified_state}"
    return 1
  fi

  TURBO_ACTIVE_BACKEND="${backend}"
  TURBO_ACTIVE_STATE="${verified_state}"
  log_info "[CPU] Turbo requested=${requested}; backend=${backend}; verified state=${verified_state}."
  return 0
}

turbo_restore_snapshot() {
  [[ ${TURBO_SNAPSHOT_TAKEN:-false} == true ]] || return 0
  if ! turbo_apply_state "${TURBO_SNAP_STATE}" "${TURBO_SNAP_BACKEND}"; then
    log_warn "[CPU] Failed to restore turbo snapshot via backend=${TURBO_SNAP_BACKEND:-unknown}."
    return 0
  fi
  log_info "[CPU] Restored turbo state to snapshot (${TURBO_SNAP_STATE}) via ${TURBO_SNAP_BACKEND}."
}

turbo_report_state() {
  local requested="${1:-}"
  local backend="${TURBO_ACTIVE_BACKEND:-}"
  local effective_state="unknown"

  if [[ -z "${backend}" ]]; then
    backend="$(turbo_detect_backend 2>/dev/null || true)"
  fi
  if [[ -n "${backend}" ]]; then
    effective_state="$(turbo_read_state "${backend}" 2>/dev/null || echo 'unknown')"
  fi

  [[ -n "${requested}" ]] && echo "turbo.requested      = ${requested}"
  echo "turbo.backend        = ${backend:-unavailable}"
  echo "turbo.state          = ${effective_state}"

  if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo "intel_pstate.no_turbo = $(cat /sys/devices/system/cpu/intel_pstate/no_turbo) (1=disabled)"
  fi
  if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
    echo "cpufreq.boost        = $(cat /sys/devices/system/cpu/cpufreq/boost) (0=disabled)"
  fi

  if turbo_msr_available; then
    local cpu0 raw hex
    while IFS= read -r cpu0; do
      break
    done < <(turbo_online_cpus)
    if [[ -n "${cpu0}" ]]; then
      raw="$(sudo rdmsr -p "${cpu0}" 0x1a0 -0 2>/dev/null || true)"
      if [[ -n "${raw}" ]] && hex="$(pf_normalize_hex64 "${raw}" 2>/dev/null)"; then
        echo "msr.ia32_misc_enable.cpu${cpu0} = 0x${hex} (bit38=turbo_disable)"
      fi
    fi
  fi
}

UNC_PATH="/sys/devices/system/cpu/intel_uncore_frequency"
declare -a __UNC_DIES=()
declare -A __UNC_SNAP_MIN=()
declare -A __UNC_SNAP_MAX=()
declare -a __CORE_SNAP_CPUS=()
declare -A __CORE_SNAP_GOV=()
declare -A __CORE_SNAP_MIN=()
declare -A __CORE_SNAP_MAX=()
declare -A __CORE_SNAP_HWP_REQ=()

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

core_snapshot_current() {
  __CORE_SNAP_CPUS=()
  __CORE_SNAP_GOV=()
  __CORE_SNAP_MIN=()
  __CORE_SNAP_MAX=()
  __CORE_SNAP_HWP_REQ=()

  local requested=("$@")
  local expanded=()
  local cpu cpu_path
  while IFS= read -r cpu; do
    [[ -n "${cpu}" ]] && expanded+=("${cpu}")
  done < <(core_expand_scope_cpus "${requested[@]}")

  for cpu in "${expanded[@]}"; do
    cpu_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    [[ -d "${cpu_path}" ]] || continue
    __CORE_SNAP_CPUS+=("${cpu}")
    [[ -r "${cpu_path}/scaling_governor" ]] && __CORE_SNAP_GOV["${cpu}"]="$(<"${cpu_path}/scaling_governor")"
    [[ -r "${cpu_path}/scaling_min_freq" ]] && __CORE_SNAP_MIN["${cpu}"]="$(<"${cpu_path}/scaling_min_freq")"
    [[ -r "${cpu_path}/scaling_max_freq" ]] && __CORE_SNAP_MAX["${cpu}"]="$(<"${cpu_path}/scaling_max_freq")"
    if core_hwp_exact_backend_available "${cpu}"; then
      __CORE_SNAP_HWP_REQ["${cpu}"]="$(core_hwp_read_request_hex "${cpu}")"
    fi
  done

  ((${#__CORE_SNAP_CPUS[@]} > 0))
}

core_restore_snapshot() {
  ((${#__CORE_SNAP_CPUS[@]} > 0)) || return 0

  local cpu cpu_path now_min now_max now_gov
  for cpu in "${__CORE_SNAP_CPUS[@]}"; do
    cpu_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
    [[ -d "${cpu_path}" ]] || continue

    if [[ -n "${__CORE_SNAP_MIN[$cpu]+x}" ]]; then
      echo "${__CORE_SNAP_MIN[$cpu]}" | sudo tee "${cpu_path}/scaling_min_freq" >/dev/null 2>&1 || true
    fi
    if [[ -n "${__CORE_SNAP_MAX[$cpu]+x}" ]]; then
      echo "${__CORE_SNAP_MAX[$cpu]}" | sudo tee "${cpu_path}/scaling_max_freq" >/dev/null 2>&1 || true
    fi
    if [[ -n "${__CORE_SNAP_GOV[$cpu]+x}" && -e "${cpu_path}/scaling_governor" ]]; then
      sudo cpupower -c "$cpu" frequency-set -g "${__CORE_SNAP_GOV[$cpu]}" >/dev/null 2>&1 \
        || echo "${__CORE_SNAP_GOV[$cpu]}" | sudo tee "${cpu_path}/scaling_governor" >/dev/null 2>&1 \
        || true
    fi

    now_min="$(cat "${cpu_path}/scaling_min_freq" 2>/dev/null || echo '?')"
    now_max="$(cat "${cpu_path}/scaling_max_freq" 2>/dev/null || echo '?')"
    now_gov="$(cat "${cpu_path}/scaling_governor" 2>/dev/null || echo '?')"
    if [[ -n "${__CORE_SNAP_MIN[$cpu]+x}" && "${now_min}" != "${__CORE_SNAP_MIN[$cpu]}" ]]; then
      log_warn "[CPU] cpu${cpu}: failed to restore scaling_min_freq=${__CORE_SNAP_MIN[$cpu]} (now ${now_min})."
    fi
    if [[ -n "${__CORE_SNAP_MAX[$cpu]+x}" && "${now_max}" != "${__CORE_SNAP_MAX[$cpu]}" ]]; then
      log_warn "[CPU] cpu${cpu}: failed to restore scaling_max_freq=${__CORE_SNAP_MAX[$cpu]} (now ${now_max})."
    fi
    if [[ -n "${__CORE_SNAP_GOV[$cpu]+x}" && "${now_gov}" != "${__CORE_SNAP_GOV[$cpu]}" ]]; then
      log_warn "[CPU] cpu${cpu}: failed to restore governor=${__CORE_SNAP_GOV[$cpu]} (now ${now_gov})."
    fi

    if [[ -n "${__CORE_SNAP_HWP_REQ[$cpu]+x}" ]]; then
      if ! core_hwp_write_request_hex "${cpu}" "${__CORE_SNAP_HWP_REQ[$cpu]}"; then
        log_warn "[CPU] cpu${cpu}: failed to restore IA32_HWP_REQUEST=0x${__CORE_SNAP_HWP_REQ[$cpu]}."
      else
        local now_req
        now_req="$(core_hwp_read_request_hex "${cpu}" 2>/dev/null || echo '')"
        if [[ -n "${now_req}" && "${now_req,,}" != "${__CORE_SNAP_HWP_REQ[$cpu],,}" ]]; then
          log_warn "[CPU] cpu${cpu}: IA32_HWP_REQUEST restore mismatch (expected 0x${__CORE_SNAP_HWP_REQ[$cpu]}, now 0x${now_req})."
        fi
      fi
    fi
  done

  log_info "[CPU] Restored core frequency policy to snapshot."
}

core_hwp_exact_backend_available() {
  local cpu="${1:-0}"
  [[ -r /sys/devices/system/cpu/intel_pstate/status ]] || return 1
  [[ "$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo '')" == "active" ]] || return 1
  grep -qw hwp /proc/cpuinfo || return 1
  command -v rdmsr >/dev/null 2>&1 || return 1
  command -v wrmsr >/dev/null 2>&1 || return 1
  core_hwp_read_caps_hex "${cpu}" >/dev/null 2>&1 || return 1
}

core_hwp_read_caps_hex() {
  local cpu="${1:?missing cpu}"
  sudo rdmsr -p "${cpu}" 0x771 -0 2>/dev/null
}

core_hwp_read_request_hex() {
  local cpu="${1:?missing cpu}"
  sudo rdmsr -p "${cpu}" 0x774 -0 2>/dev/null
}

core_hwp_write_request_hex() {
  local cpu="${1:?missing cpu}"
  local hex="${2:?missing hwp request hex}"
  sudo wrmsr -p "${cpu}" 0x774 "0x${hex}" 2>/dev/null
}

core_hwp_perf_from_khz() {
  local cpu="${1:?missing cpu}"
  local khz="${2:?missing khz}"
  local cpu_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq"
  [[ -r "${cpu_path}/cpuinfo_max_freq" ]] || return 1

  local max_khz caps_hex caps_val highest_perf lowest_perf raw_perf
  max_khz="$(<"${cpu_path}/cpuinfo_max_freq")"
  caps_hex="$(core_hwp_read_caps_hex "${cpu}")" || return 1
  caps_val=$(( 16#${caps_hex,,} ))
  highest_perf=$(( caps_val & 0xff ))
  lowest_perf=$(( (caps_val >> 24) & 0xff ))

  if (( max_khz <= 0 || highest_perf <= 0 )); then
    return 1
  fi

  raw_perf="$(awk -v khz="${khz}" -v max_khz="${max_khz}" -v highest="${highest_perf}" 'BEGIN {
    perf = int((khz * highest / max_khz) + 0.5)
    if (perf < 1) perf = 1
    printf "%d", perf
  }')"

  if (( raw_perf < lowest_perf )); then
    raw_perf="${lowest_perf}"
  fi
  if (( raw_perf > highest_perf )); then
    raw_perf="${highest_perf}"
  fi

  printf '%s\n' "${raw_perf}"
}

core_hwp_apply_exact_khz() {
  local cpu="${1:?missing cpu}"
  local khz="${2:?missing khz}"
  local caps_hex req_hex caps_val req_val perf highest_perf guaranteed_perf efficient_perf lowest_perf

  caps_hex="$(core_hwp_read_caps_hex "${cpu}")" || return 1
  req_hex="$(core_hwp_read_request_hex "${cpu}")" || return 1
  perf="$(core_hwp_perf_from_khz "${cpu}" "${khz}")" || return 1

  caps_val=$(( 16#${caps_hex,,} ))
  req_val=$(( 16#${req_hex,,} ))
  highest_perf=$(( caps_val & 0xff ))
  guaranteed_perf=$(( (caps_val >> 8) & 0xff ))
  efficient_perf=$(( (caps_val >> 16) & 0xff ))
  lowest_perf=$(( (caps_val >> 24) & 0xff ))

  local preserved_upper new_val new_hex applied_hex applied_val applied_min applied_max applied_desired
  preserved_upper=$(( req_val & ~0xffffff ))
  new_val=$(( preserved_upper | (perf << 16) | (perf << 8) | perf ))
  printf -v new_hex '%016x' "${new_val}"
  core_hwp_write_request_hex "${cpu}" "${new_hex}" || return 1

  applied_hex="$(core_hwp_read_request_hex "${cpu}")" || return 1
  applied_val=$(( 16#${applied_hex,,} ))
  applied_min=$(( applied_val & 0xff ))
  applied_max=$(( (applied_val >> 8) & 0xff ))
  applied_desired=$(( (applied_val >> 16) & 0xff ))

  if (( applied_min != perf || applied_max != perf || applied_desired != perf )); then
    log_warn "[CPU] cpu${cpu}: exact HWP request did not stick (min=${applied_min} max=${applied_max} desired=${applied_desired}, wanted ${perf})."
    return 1
  fi

  log_info "[CPU] cpu${cpu}: exact HWP request active for ${khz} kHz (perf=${perf}; caps low=${lowest_perf} eff=${efficient_perf} guar=${guaranteed_perf} high=${highest_perf})."
}

core_apply_pin_khz_softcheck() {
  local khz="$1"
  shift
  local requested=("$@")
  local expanded=()
  local cpu
  while IFS= read -r cpu; do
    [[ -n "${cpu}" ]] && expanded+=("${cpu}")
  done < <(core_expand_scope_cpus "${requested[@]}")

  for cpu in "${expanded[@]}"; do
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

    local scaling_driver current_gov avail_govs
    scaling_driver="$(cat "${cpu_path}/scaling_driver" 2>/dev/null || echo '?')"
    current_gov="$(cat "${cpu_path}/scaling_governor" 2>/dev/null || echo '?')"
    avail_govs="$(cat "${cpu_path}/scaling_available_governors" 2>/dev/null || echo '')"

    if [[ -e "${cpu_path}/scaling_governor" ]]; then
      if grep -qw userspace <<<"${avail_govs}"; then
        sudo cpupower -c "$cpu" frequency-set -g userspace >/dev/null 2>&1 \
          || echo userspace | sudo tee "${cpu_path}/scaling_governor" >/dev/null 2>&1 \
          || true
      elif [[ "${scaling_driver}" == "intel_pstate" ]]; then
        log_info "[CPU] cpu${cpu}: keeping governor=${current_gov} because userspace mode is unavailable under scaling_driver=${scaling_driver}."
      fi
    fi

    echo "${khz}" | sudo tee "${cpu_path}/scaling_min_freq" >/dev/null 2>&1 || true
    echo "${khz}" | sudo tee "${cpu_path}/scaling_max_freq" >/dev/null 2>&1 || true

    local now_min now_max intel_pstate_status hwp_active hwp_exact_available
    now_min="$(<"${cpu_path}/scaling_min_freq")"
    now_max="$(<"${cpu_path}/scaling_max_freq")"
    intel_pstate_status="$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo '')"
    hwp_active=false
    if [[ "${scaling_driver}" == "intel_pstate" && "${intel_pstate_status}" == "active" ]] && grep -qw hwp /proc/cpuinfo; then
      hwp_active=true
    fi
    hwp_exact_available=false
    if core_hwp_exact_backend_available "${cpu}"; then
      hwp_exact_available=true
    fi

    if [[ "$now_min" == "$khz" && "$now_max" == "$khz" ]]; then
      log_info "[CPU] cpu${cpu}: pinned core at ${khz} kHz."
    elif $hwp_exact_available; then
      log_info "[CPU] cpu${cpu}: sysfs min/max read back as ${now_min}/${now_max} under HWP; verifying exact request through MSR instead."
    elif $hwp_active; then
      log_info "[CPU] cpu${cpu}: sysfs min/max read back as ${now_min}/${now_max} because active intel_pstate/HWP treats them as hints, not an exact lock."
    else
      log_warn "[CPU] cpu${cpu}: pin did not stick (now min=${now_min} max=${now_max})."
    fi

    if $hwp_exact_available; then
      if ! core_hwp_apply_exact_khz "${cpu}" "${khz}"; then
        log_warn "[CPU] cpu${cpu}: HWP exact pin failed; leaving sysfs min/max as best-effort hints."
      fi
    elif $hwp_active; then
      log_info "[CPU] cpu${cpu}: intel_pstate is active with HWP enabled; scaling_min/max are hardware-managed performance hints, not an exact frequency lock."
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


# cpu_mask_to_hex
#   Convert a CPU mask/range string into the kernel cpumask hexadecimal format
#   expected by affinity files such as /proc/irq/*/smp_affinity. For masks that
#   span more than 32 CPUs, emit comma-separated 32-bit groups from most
#   significant to least significant words.
#   Arguments:
#     $1 - CPU mask/range string.
cpu_mask_to_hex() {
  local mask="${1:?missing CPU mask}"
  python3 - "${mask}" <<'PY'
import sys

mask = sys.argv[1]
cpus: set[int] = set()
for raw in mask.split(","):
    tok = raw.strip()
    if not tok:
        continue
    if "-" in tok:
        a_text, b_text = tok.split("-", 1)
        a = int(a_text)
        b = int(b_text)
        if a > b:
            raise SystemExit(f"Descending CPU range '{tok}' is not allowed")
        cpus.update(range(a, b + 1))
    else:
        cpus.add(int(tok))

if not cpus:
    print("0")
    raise SystemExit(0)

value = 0
for cpu in cpus:
    value |= 1 << cpu

groups = []
while value:
    groups.append(f"{value & 0xffffffff:x}")
    value >>= 32

if not groups:
    groups = ["0"]

groups.reverse()
if len(groups) > 1:
    groups = [groups[0]] + [group.zfill(8) for group in groups[1:]]

print(",".join(groups))
PY
}


# ensure_cpu_isolation_state_dir
#   Lazily create the snapshot directory used to restore CPU isolation changes.
#   Arguments: none; updates CPU_ISOLATION_STATE_DIR.
ensure_cpu_isolation_state_dir() {
  if [[ -z ${CPU_ISOLATION_STATE_DIR:-} ]]; then
    CPU_ISOLATION_STATE_DIR="$(mktemp -d /tmp/bci_cpu_isolation.XXXXXX)"
  fi
}


# save_state_file
#   Save a single mutable kernel/sysfs file so it can be restored later.
#   Arguments:
#     $1 - absolute path to the file to snapshot.
save_state_file() {
  local path="${1:?missing path}"
  [[ -r "${path}" ]] || return 0
  ensure_cpu_isolation_state_dir
  local snapshot="${CPU_ISOLATION_STATE_DIR}${path}"
  if [[ -e "${snapshot}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${snapshot}")"
  cat "${path}" >"${snapshot}"
}


# restore_saved_state_files
#   Replay any saved kernel/sysfs file contents captured during CPU isolation setup.
#   Arguments: none.
restore_saved_state_files() {
  local state_dir="${CPU_ISOLATION_STATE_DIR:-}"
  [[ -n "${state_dir}" && -d "${state_dir}" ]] || return 0

  while IFS= read -r -d '' snapshot; do
    local target="${snapshot#${state_dir}}"
    [[ -n "${target}" ]] || continue
    sudo tee "${target}" >/dev/null 2>/dev/null <"${snapshot}" || true
  done < <(find "${state_dir}" -type f -print0 2>/dev/null)

  rm -rf "${state_dir}" || true
  CPU_ISOLATION_STATE_DIR=""
}


# write_cpu_mask_file
#   Write a CPU mask to either list-style or hex-style affinity files.
#   Arguments:
#     $1 - absolute path to the affinity file.
#     $2 - CPU mask/range string.
write_cpu_mask_file() {
  local path="${1:?missing path}"
  local mask="${2:?missing CPU mask}"
  local payload="${mask}"
  WRITE_CPU_MASK_LAST_REASON=""
  WRITE_CPU_MASK_LAST_ERROR=""
  if [[ ${path} == */smp_affinity && ${path} != */smp_affinity_list ]]; then
    payload="$(cpu_mask_to_hex "${mask}")"
  elif [[ ${path} == */workqueue/cpumask || ${path} == */workqueue/*/cpumask || ${path} == */workqueue/devices/*/cpumask ]]; then
    payload="$(cpu_mask_to_hex "${mask}")"
  fi

  local output="" rc=0
  output="$(printf '%s\n' "${payload}" | sudo tee "${path}" >/dev/null 2>&1)" || rc=$?
  WRITE_CPU_MASK_LAST_ERROR="${output}"
  if (( rc != 0 )); then
    if [[ "${output}" == *"Input/output error"* ]]; then
      WRITE_CPU_MASK_LAST_REASON="io_error"
      return 2
    fi
    WRITE_CPU_MASK_LAST_REASON="write_failed"
    return "${rc}"
  fi
  return 0
}


# pin_current_shell_to_mask
#   Restrict the current shell to a control CPU mask so future child processes
#   inherit non-workload affinity by default.
#   Arguments:
#     $1 - CPU mask to apply.
#     $2 - descriptive label for logging.
pin_current_shell_to_mask() {
  local mask="${1:-}"
  local label="${2:-current shell}"
  [[ -n "${mask}" ]] || return 0
  command -v taskset >/dev/null 2>&1 || return 0

  local output="" rc=0
  output="$(taskset -cp "${mask}" "$$" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_info "${label}: ${line}"
    done <<<"${output}"
  else
    log_warn "${label}: failed to pin shell to ${mask} (exit ${rc})"
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_warn "${label}: ${line}"
    done <<<"${output}"
  fi
}


# stop_irqbalance_for_isolation
#   Stop irqbalance while explicit IRQ affinity steering is active.
#   Arguments: none; updates IRQBALANCE_WAS_ACTIVE.
stop_irqbalance_for_isolation() {
  IRQBALANCE_WAS_ACTIVE=false
  command -v systemctl >/dev/null 2>&1 || return 0

  local state
  state="$(systemctl is-active irqbalance 2>/dev/null || true)"
  if [[ ${state} == active ]]; then
    if sudo systemctl stop irqbalance; then
      IRQBALANCE_WAS_ACTIVE=true
      log_info "Stopped irqbalance while workload isolation is active"
    else
      log_warn "Failed to stop irqbalance; continuing with manual IRQ affinity steering"
    fi
  fi
}


# apply_watchdog_cpumask
#   Move the NMI watchdog off workload CPUs when the runtime exposes a writable mask.
#   Arguments:
#     $1 - CPU mask/range string for non-workload CPUs.
apply_watchdog_cpumask() {
  local mask="${1:-}"
  local path="/proc/sys/kernel/watchdog_cpumask"
  [[ -n "${mask}" && -w "${path}" ]] || return 0

  save_state_file "${path}"
  if write_cpu_mask_file "${path}" "${mask}"; then
    log_info "Moved watchdog cpumask to ${mask}"
  else
    log_warn "Failed to update watchdog cpumask"
  fi
}


# steer_irqs_to_mask
#   Move writable IRQ affinities away from workload CPUs.
#   Arguments:
#     $1 - CPU mask/range string for non-workload CPUs.
steer_irqs_to_mask() {
  local mask="${1:-}"
  [[ -n "${mask}" ]] || return 0

  local updated=0 failed=0 skipped=0 path
  if [[ -w /proc/irq/default_smp_affinity_list ]]; then
    path="/proc/irq/default_smp_affinity_list"
    save_state_file "${path}"
    if write_cpu_mask_file "${path}" "${mask}"; then
      ((updated+=1))
    else
      ((failed+=1))
    fi
  elif [[ -w /proc/irq/default_smp_affinity ]]; then
    path="/proc/irq/default_smp_affinity"
    save_state_file "${path}"
    if write_cpu_mask_file "${path}" "${mask}"; then
      ((updated+=1))
    else
      ((failed+=1))
    fi
  fi

  local irq_path=""
  shopt -s nullglob
  for irq_path in /proc/irq/[0-9]*; do
    local target=""
    if [[ -w "${irq_path}/smp_affinity_list" ]]; then
      target="${irq_path}/smp_affinity_list"
    elif [[ -w "${irq_path}/smp_affinity" ]]; then
      target="${irq_path}/smp_affinity"
    fi
    [[ -n "${target}" ]] || continue
    save_state_file "${target}"
    if write_cpu_mask_file "${target}" "${mask}"; then
      ((updated+=1))
    elif [[ "${WRITE_CPU_MASK_LAST_REASON:-}" == "io_error" ]]; then
      ((skipped+=1))
    else
      ((failed+=1))
    fi
  done
  shopt -u nullglob

  log_info "Steered IRQ affinity away from workload CPUs -> mask=${mask} updated=${updated} skipped=${skipped} failed=${failed}"
}


# steer_unbound_workqueues_to_mask
#   Constrain writable unbound workqueues to non-workload CPUs.
#   Arguments:
#     $1 - CPU mask/range string for non-workload CPUs.
steer_unbound_workqueues_to_mask() {
  local mask="${1:-}"
  [[ -n "${mask}" ]] || return 0

  local updated=0 failed=0 path=""
  shopt -s nullglob
  for path in \
    /sys/devices/virtual/workqueue/cpumask \
    /sys/devices/virtual/workqueue/*/cpumask \
    /sys/bus/workqueue/devices/*/cpumask; do
    [[ -w "${path}" ]] || continue
    save_state_file "${path}"
    if write_cpu_mask_file "${path}" "${mask}"; then
      ((updated+=1))
    else
      ((failed+=1))
    fi
  done
  shopt -u nullglob

  if (( updated > 0 || failed > 0 )); then
    log_info "Steered workqueue cpumasks away from workload CPUs -> mask=${mask} updated=${updated} failed=${failed}"
  fi
}


# populate_cpu_isolation_state
#   Compute and export the common CPU-isolation masks used by the steering and
#   shielding helpers.
#   Arguments:
#     $1 - workload CPU mask.
#     $2 - tools CPU mask.
#     $3 - reserved background/control CPU mask (optional).
populate_cpu_isolation_state() {
  local workload_mask="${1:?missing workload CPU mask}"
  local tools_mask="${2:?missing tools CPU mask}"
  local background_mask="${3:-}"
  local control_mask="${background_mask:-${tools_mask}}"
  local shield_mask non_workload_mask

  shield_mask="$(normalize_cpu_mask "${tools_mask},${workload_mask}")"
  non_workload_mask="$(cpu_mask_minus "$(cpu_online_list)" "${workload_mask}")"
  if [[ -z "${non_workload_mask}" ]]; then
    non_workload_mask="${control_mask}"
  fi

  CONTROL_CPUS="${control_mask}"
  NON_WORKLOAD_CPUS="${non_workload_mask}"
  SHIELDED_CPUS="${shield_mask}"
  export CONTROL_CPUS NON_WORKLOAD_CPUS SHIELDED_CPUS
}


# prepare_cpu_steering
#   Steer IRQs/workqueues/background activity away from workload CPUs without
#   yet creating shielded cpusets or pinning the control shell.
#   Arguments:
#     $1 - workload CPU mask.
#     $2 - tools CPU mask.
#     $3 - reserved background/control CPU mask (optional).
prepare_cpu_steering() {
  local workload_mask="${1:?missing workload CPU mask}"
  local tools_mask="${2:?missing tools CPU mask}"
  local background_mask="${3:-}"

  populate_cpu_isolation_state "${workload_mask}" "${tools_mask}" "${background_mask}"
  stop_irqbalance_for_isolation
  apply_watchdog_cpumask "${NON_WORKLOAD_CPUS}"
  steer_irqs_to_mask "${NON_WORKLOAD_CPUS}"
  steer_unbound_workqueues_to_mask "${NON_WORKLOAD_CPUS}"
}


# apply_cpu_isolation
#   Reserve workload/tool CPUs in a shielded cpuset and steer the remaining
#   system activity away from workload CPUs as much as practical.
#   Arguments:
#     $1 - workload CPU mask.
#     $2 - tools CPU mask.
#     $3 - reserved background/control CPU mask (optional).
apply_cpu_isolation() {
  local workload_mask="${1:?missing workload CPU mask}"
  local tools_mask="${2:?missing tools CPU mask}"
  local background_mask="${3:-}"

  populate_cpu_isolation_state "${workload_mask}" "${tools_mask}" "${background_mask}"
  prepare_cpu_steering "${workload_mask}" "${tools_mask}" "${background_mask}"
  pin_current_shell_to_mask "${CONTROL_CPUS}" "control shell (pre-shield)"

  if command -v cset >/dev/null 2>&1; then
    sudo cset shield --reset >/dev/null 2>&1 || true
    sudo cset shield --cpu "${SHIELDED_CPUS}" --kthread=on
    ensure_named_cpuset "${WORKLOAD_CPUSET_NAME:-user/bci_workload}" "${workload_mask}"
    ensure_named_cpuset "${TOOLS_CPUSET_NAME:-user/bci_tools}" "${tools_mask}"
    CPU_ISOLATION_ACTIVE=true
    log_info "Shielded workload/tool CPUs: ${SHIELDED_CPUS}"
  fi

  pin_current_shell_to_mask "${CONTROL_CPUS}" "control shell (post-shield)"
}


# destroy_named_cpuset
#   Remove a named cpuset if it exists, forcing any tasks back to the parent.
#   Arguments:
#     $1 - cpuset name.
destroy_named_cpuset() {
  local name="${1:-}"
  [[ -n "${name}" ]] || return 0
  command -v cset >/dev/null 2>&1 || return 0

  sudo cset set --destroy --recurse --force --set "${name}" >/dev/null 2>&1 \
    || sudo cset set -d --recurse --force "${name}" >/dev/null 2>&1 \
    || sudo cset set -d "${name}" >/dev/null 2>&1 \
    || true
}


# ensure_named_cpuset
#   Recreate a named cpuset on the requested CPU mask.
#   Arguments:
#     $1 - cpuset name.
#     $2 - CPU mask/range string.
ensure_named_cpuset() {
  local name="${1:?missing cpuset name}"
  local mask="${2:?missing CPU mask}"
  destroy_named_cpuset "${name}"
  sudo cset set --cpu "${mask}" "${name}" >/dev/null
  log_info "Prepared cpuset ${name} on CPUs ${mask}"
}


# run_in_named_cpuset
#   Execute a shell command inside the specified cpuset.
#   Arguments:
#     $1 - cpuset name.
#     $2 - shell command string to run.
run_in_named_cpuset() {
  local set_name="${1:?missing cpuset name}"
  local cmd="${2:?missing command}"
  local launch_cmd=""
  printf -v launch_cmd 'cset proc --exec --set %q -- bash -lc %q' "${set_name}" "${cmd}"
  sudo -n bash -lc "${launch_cmd}"
}


# run_in_tools_cpuset
#   Execute a shell command inside the dedicated tools cpuset.
#   Arguments:
#     $1 - shell command string to run.
run_in_tools_cpuset() {
  run_in_named_cpuset "${TOOLS_CPUSET_NAME:?missing TOOLS_CPUSET_NAME}" "${1:?missing command}"
}


# move_pid_to_root_cpuset
#   Best-effort move of a process into the root cpuset so it is not constrained
#   by any inherited shield/system cpuset state.
#   Arguments:
#     $1 - PID to move.
move_pid_to_root_cpuset() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] || return 0
  command -v cset >/dev/null 2>&1 || return 0

  sudo -n cset proc --move --pid "${pid}" --threads --toset root --force >/dev/null 2>&1 \
    || sudo -n cset proc -m -p "${pid}" -k --toset=root --force >/dev/null 2>&1 \
    || true
}


# run_system_wide_tool_cmd
#   Execute a shell command without restricting the tool process affinity/cpuset.
#   Use this for PCM-family tools that need visibility across the full system.
#   Arguments:
#     $1 - shell command string to run.
run_system_wide_tool_cmd() {
  local cmd="${1:?missing command}"
  local wrapper=""
  printf -v wrapper 'cset proc --move --pid $$ --threads --toset root --force >/dev/null 2>&1 || cset proc -m -p $$ -k --toset=root --force >/dev/null 2>&1 || true; exec bash -lc %q' "${cmd}"
  sudo -n bash -lc "${wrapper}"
}


# start_background_system_tool
#   Launch a system-wide background tool command and capture its PID.
#   Arguments:
#     $1 - human-readable label for logs
#     $2 - shell command string to run in the background
#     $3 - variable name that should receive the PID
start_background_system_tool() {
  local label="${1:?missing label}" cmd="${2:?missing command}" varname="${3:?missing pid var}"
  local launch_cmd child pid
  printf -v launch_cmd 'cset proc --move --pid $$ --threads --toset root --force >/dev/null 2>&1 || cset proc -m -p $$ -k --toset=root --force >/dev/null 2>&1 || true; nohup bash -lc %q </dev/null >/dev/null 2>&1 & echo $!' "exec ${cmd}"
  child="$(sudo -n bash -lc "${launch_cmd}")" || return 1
  pid="$(echo "${child}" | tr -d '[:space:]')"
  [[ -n "${pid}" ]] || return 1
  sleep 0.5
  if ! process_is_alive "${pid}"; then
    echo "[ERROR] ${label}: pid=${pid} exited immediately after launch" >&2
    return 1
  fi
  export "${varname}=${pid}"
  echo "[INFO] ${label}: started pid=${pid}"
}


# run_in_workload_cpuset
#   Execute a shell command inside the dedicated workload cpuset.
#   Arguments:
#     $1 - shell command string to run.
run_in_workload_cpuset() {
  run_in_named_cpuset "${WORKLOAD_CPUSET_NAME:?missing WORKLOAD_CPUSET_NAME}" "${1:?missing command}"
}


# reset_stale_cpu_isolation
#   Force-clear any leftover shield/cpuset state from previous runs so a new
#   shell regains visibility of all online CPUs before profiling starts.
#   Arguments: none.
reset_stale_cpu_isolation() {
  destroy_named_cpuset "${TOOLS_CPUSET_NAME:-}"
  destroy_named_cpuset "${WORKLOAD_CPUSET_NAME:-}"

  if command -v cset >/dev/null 2>&1; then
    sudo cset shield --reset >/dev/null 2>&1 || true
  fi
  CPU_ISOLATION_ACTIVE=false

  restore_saved_state_files

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl start irqbalance >/dev/null 2>&1 || true
  fi
  IRQBALANCE_WAS_ACTIVE=false

  move_pid_to_root_cpuset "$$"
  pin_current_shell_to_mask "$(cpu_online_list)" "control shell (reset)"
}


# restore_cpu_isolation
#   Restore any affinity changes made by apply_cpu_isolation.
#   Arguments: none.
restore_cpu_isolation() {
  destroy_named_cpuset "${TOOLS_CPUSET_NAME:-}"
  destroy_named_cpuset "${WORKLOAD_CPUSET_NAME:-}"

  if command -v cset >/dev/null 2>&1; then
    sudo cset shield --reset >/dev/null 2>&1 || true
    CPU_ISOLATION_ACTIVE=false
  fi

  restore_saved_state_files

  if [[ ${IRQBALANCE_WAS_ACTIVE:-false} == true ]]; then
    sudo systemctl start irqbalance >/dev/null 2>&1 || true
    IRQBALANCE_WAS_ACTIVE=false
  fi
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
  local idle_states_modified_state="${idle_states_modified:-false}"
  local idle_state_snapshot_state="${idle_state_snapshot:-}"
  if ! $idle_states_modified_state; then
    return
  fi
  if command -v cpupower >/dev/null 2>&1; then
    if [[ -n "$idle_state_snapshot_state" ]]; then
      restore_idle_states_from_snapshot "$idle_state_snapshot_state"
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


# pqos_clear_stale_lock
#   Remove the stale libpqos lock when no pqos process is active so later PQoS commands can initialize cleanly.
#   Arguments: none.
pqos_clear_stale_lock() {
  local pqos_log="${LOGDIR}/pqos.log"
  local lock_path="/run/lock/libpqos"
  local active_pqos=""

  active_pqos="$(pgrep -x pqos 2>/dev/null || true)"
  if [[ -n "${active_pqos}" ]]; then
    if $pqos_logging_enabled; then
      mkdir -p "${LOGDIR}"
      printf '[%s] pqos_clear_stale_lock: leaving %s in place because pqos pid(s) %s are active\n' \
        "$(timestamp)" "${lock_path}" "${active_pqos}" >>"${pqos_log}"
    fi
    return 0
  fi

  if sudo test -e "${lock_path}"; then
    if $pqos_logging_enabled; then
      mkdir -p "${LOGDIR}"
      printf '[%s] pqos_clear_stale_lock: sudo rm -f %s\n' "$(timestamp)" "${lock_path}" >>"${pqos_log}"
      sudo rm -f "${lock_path}" >>"${pqos_log}" 2>&1 || true
    else
      sudo rm -f "${lock_path}" >/dev/null 2>&1 || true
    fi
  fi
}


# pqos_reset_os_best_effort
#   Reset PQoS through the OS interface after clearing any stale libpqos lock.
#   Arguments: none.
pqos_reset_os_best_effort() {
  local pqos_log="${LOGDIR}/pqos.log"
  local rc=0

  pqos_clear_stale_lock
  export RDT_IFACE=OS

  if $pqos_logging_enabled; then
    mkdir -p "${LOGDIR}"
    printf '[%s] pqos_reset_os_best_effort: sudo env RDT_IFACE=OS pqos -I -R\n' \
      "$(timestamp)" >>"${pqos_log}"
    if sudo env RDT_IFACE=OS pqos -I -R >>"${pqos_log}" 2>&1; then
      return 0
    fi
    rc=$?
    printf '[%s] pqos_reset_os_best_effort: reset failed rc=%d; continuing\n' \
      "$(timestamp)" "${rc}" >>"${pqos_log}"
  else
    sudo env RDT_IFACE=OS pqos -I -R >/dev/null 2>&1 || rc=$?
  fi

  log_warn "PQoS OS-interface reset failed (rc=${rc}); continuing."
  return 0
}


# pqos_reset_msr_best_effort
#   Reset PQoS monitoring through the MSR interface after clearing any stale libpqos lock.
#   Arguments: none.
pqos_reset_msr_best_effort() {
  local pqos_log="${LOGDIR}/pqos.log"
  local rc=0

  pqos_clear_stale_lock
  export RDT_IFACE=MSR

  if $pqos_logging_enabled; then
    mkdir -p "${LOGDIR}"
    printf '[%s] pqos_reset_msr_best_effort: timeout 5s sudo env RDT_IFACE=MSR pqos --iface msr --mon-reset\n' \
      "$(timestamp)" >>"${pqos_log}"
    timeout 5s sudo env RDT_IFACE=MSR pqos --iface msr --mon-reset >>"${pqos_log}" 2>&1 || rc=$?
    if (( rc != 0 && rc != 124 )); then
      printf '[%s] pqos_reset_msr_best_effort: reset failed rc=%d; continuing\n' \
        "$(timestamp)" "${rc}" >>"${pqos_log}"
    fi
  else
    timeout 5s sudo env RDT_IFACE=MSR pqos --iface msr --mon-reset >/dev/null 2>&1 || rc=$?
  fi

  pqos_clear_stale_lock

  if (( rc == 0 || rc == 124 )); then
    return 0
  fi

  log_warn "PQoS MSR-interface reset failed (rc=${rc}); continuing."
  return 0
}


# pqos_monitor_iface
#   Select the PQoS monitoring interface for the current node/runtime.
#   Arguments: none.
pqos_monitor_iface() {
  local hw_model="${HW_MODEL:-$(detect_hw_model)}"
  if is_c240g5_family "${hw_model}"; then
    if [[ "${MBA_ACTIVE_PERCENT:-off}" != "off" ]]; then
      printf 'none\n'
    else
      printf 'msr\n'
    fi
    return 0
  fi
  printf 'os\n'
}


# pqos_prepare_monitoring_runtime
#   Prepare the platform/runtime state for PQoS monitoring collection.
#   Arguments: none.
pqos_prepare_monitoring_runtime() {
  local iface
  iface="$(pqos_monitor_iface)"
  PQOS_MONITOR_IFACE="${iface}"
  export PQOS_MONITOR_IFACE

  case "${iface}" in
    os)
      mount_resctrl_and_reset
      export RDT_IFACE=OS
      return 0
      ;;
    msr)
      unmount_resctrl_quiet
      pqos_reset_msr_best_effort
      export RDT_IFACE=MSR
      return 0
      ;;
    none)
      log_warn "PQoS monitoring conflicts with active MBA allocation on this c240g5 run; skipping pass 3."
      return 1
      ;;
    *)
      log_warn "Unknown PQoS monitoring interface '${iface}'; skipping pass 3."
      return 1
      ;;
  esac
}


# pqos_finish_monitoring_runtime
#   Restore the platform/runtime state after PQoS monitoring collection.
#   Arguments: none.
pqos_finish_monitoring_runtime() {
  local iface="${PQOS_MONITOR_IFACE:-os}"
  case "${iface}" in
    msr)
      pqos_clear_stale_lock
      mount_resctrl_and_reset
      ;;
    os)
      unmount_resctrl_quiet
      ;;
    *)
      ;;
  esac
  unset PQOS_MONITOR_IFACE
}


# pqos_build_monitor_command
#   Build the PQoS monitoring command string for the prepared interface/runtime.
#   Arguments:
#     $1 - CSV output path
#     $2 - interval ticks
#     $3 - monitor specification
#     $4 - log path
#     $5 - optional tool CPU mask for taskset pinning
pqos_build_monitor_command() {
  local csv_path="${1:?missing csv output path}"
  local interval_ticks="${2:?missing pqos interval ticks}"
  local monitor_spec="${3:?missing pqos monitor spec}"
  local log_path="${4:?missing pqos log path}"
  local tool_cpu_mask="${5:-}"
  local iface="${PQOS_MONITOR_IFACE:-os}"

  case "${iface}" in
    msr)
      if [[ -n "${tool_cpu_mask}" ]]; then
        printf 'env RDT_IFACE=MSR taskset -c %q pqos --iface msr -u csv -o %q -i %q -m %q >>%q 2>&1\n' \
          "${tool_cpu_mask}" "${csv_path}" "${interval_ticks}" "${monitor_spec}" "${log_path}"
      else
        printf 'env RDT_IFACE=MSR pqos --iface msr -u csv -o %q -i %q -m %q >>%q 2>&1\n' \
          "${csv_path}" "${interval_ticks}" "${monitor_spec}" "${log_path}"
      fi
      ;;
    *)
      if [[ -n "${tool_cpu_mask}" ]]; then
        printf 'taskset -c %q pqos -I -u csv -o %q -i %q -m %q >>%q 2>&1\n' \
          "${tool_cpu_mask}" "${csv_path}" "${interval_ticks}" "${monitor_spec}" "${log_path}"
      else
        printf 'pqos -I -u csv -o %q -i %q -m %q >>%q 2>&1\n' \
          "${csv_path}" "${interval_ticks}" "${monitor_spec}" "${log_path}"
      fi
      ;;
  esac
}


# mount_resctrl_and_reset
#   Mount the resctrl filesystem and issue a best-effort PQoS OS-interface reset.
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
  else
    sudo umount /sys/fs/resctrl >/dev/null 2>&1 || true
    sudo mount -t resctrl resctrl /sys/fs/resctrl >/dev/null 2>&1
  fi
  pqos_reset_os_best_effort
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


# pqos_monitoring_probe
#   Probe whether PQoS MBM monitoring can actually start on the current platform/runtime.
#   Arguments:
#     $1 - CPU mask/range string to probe (first CPU is used).
#     $2 - optional PQoS event name (defaults to mbl).
pqos_monitoring_probe() {
  local probe_mask="${1:-}"
  local event="${2:-}"
  local probe_cpu=""
  local pqos_log="${LOGDIR}/pqos.log"
  local iface="${PQOS_MONITOR_IFACE:-os}"
  local probe_spec=""
  local rc=0

  probe_cpu="$(cpu_mask_first_cpu "${probe_mask}")"
  [[ -n "${probe_cpu}" ]] || probe_cpu=0

  pqos_clear_stale_lock
  case "${iface}" in
    msr)
      [[ -n "${event}" ]] || event="all"
      probe_spec="${event}:[${probe_cpu}]"
      export RDT_IFACE=MSR
      if $pqos_logging_enabled; then
        mkdir -p "${LOGDIR}"
        printf '[%s] pqos_monitoring_probe: timeout 3s sudo env RDT_IFACE=MSR pqos --iface msr -m %s -i 1\n' \
          "$(timestamp)" "${probe_spec}" >>"${pqos_log}"
        timeout 3s sudo env RDT_IFACE=MSR pqos --iface msr -m "${probe_spec}" -i 1 >>"${pqos_log}" 2>&1 || rc=$?
      else
        timeout 3s sudo env RDT_IFACE=MSR pqos --iface msr -m "${probe_spec}" -i 1 >/dev/null 2>&1 || rc=$?
      fi
      ;;
    none)
      log_warn "PQoS monitoring probe skipped because MBA is active on c240g5."
      return 1
      ;;
    *)
      [[ -n "${event}" ]] || event="mbl"
      probe_spec="${event}:[${probe_cpu}]"
      export RDT_IFACE=OS
      if $pqos_logging_enabled; then
        mkdir -p "${LOGDIR}"
        printf '[%s] pqos_monitoring_probe: timeout 3s sudo env RDT_IFACE=OS pqos -I -m %s -i 1\n' \
          "$(timestamp)" "${probe_spec}" >>"${pqos_log}"
        timeout 3s sudo env RDT_IFACE=OS pqos -I -m "${probe_spec}" -i 1 >>"${pqos_log}" 2>&1 || rc=$?
      else
        timeout 3s sudo env RDT_IFACE=OS pqos -I -m "${probe_spec}" -i 1 >/dev/null 2>&1 || rc=$?
      fi
      ;;
  esac

  pqos_clear_stale_lock

  if (( rc == 0 || rc == 124 )); then
    if $pqos_logging_enabled; then
      printf '[%s] pqos_monitoring_probe: monitoring available via iface=%s cpu=%s spec=%s (rc=%d)\n' \
        "$(timestamp)" "${iface}" "${probe_cpu}" "${probe_spec}" "${rc}" >>"${pqos_log}"
    fi
    return 0
  fi

  if $pqos_logging_enabled; then
    printf '[%s] pqos_monitoring_probe: monitoring unavailable via iface=%s cpu=%s spec=%s (rc=%d)\n' \
      "$(timestamp)" "${iface}" "${probe_cpu}" "${probe_spec}" "${rc}" >>"${pqos_log}"
  fi
  log_warn "PQoS monitoring probe failed via ${iface} on cpu ${probe_cpu} (rc=${rc}); pass 3 MBM collection unavailable."
  return 1
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
process_is_alive() {
  local pid="$1"
  local stat=""

  [[ -n ${pid:-} ]] || return 1

  if ! kill -0 "${pid}" 2>/dev/null; then
    if ! sudo -n kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
  fi

  stat="$(ps -o stat= -p "${pid}" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -z ${stat} ]]; then
    stat="$(sudo -n ps -o stat= -p "${pid}" 2>/dev/null | awk 'NR==1 {print $1}')"
  fi
  [[ -n ${stat} ]] || return 1
  [[ ${stat} == Z* ]] && return 1
  return 0
}


# wait_for_process_exit
#   Poll for a process to disappear, treating zombies as already stopped.
#   Arguments:
#     $1 - PID to watch.
#     $2 - maximum number of polling attempts.
#     $3 - sleep interval between attempts.
wait_for_process_exit() {
  local pid="$1"
  local attempts="$2"
  local interval="$3"
  local attempt

  for (( attempt=1; attempt<=attempts; attempt++ )); do
    if ! process_is_alive "${pid}"; then
      return 0
    fi
    sleep "${interval}"
  done

  return 1
}


send_signal_to_pid() {
  local signal="$1"
  local pid="$2"

  kill -s "${signal}" "${pid}" 2>/dev/null && return 0
  sudo -n kill -s "${signal}" "${pid}" 2>/dev/null && return 0
  return 1
}


stop_gently() {
  local name="$1"
  local pid="$2"
  local int_attempts=50
  local term_attempts=25
  local interval=0.2

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  if ! process_is_alive "${pid}"; then
    log_info "${name}: pid=${pid} already stopped"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGINT"
  send_signal_to_pid INT "${pid}" || true
  if wait_for_process_exit "${pid}" "${int_attempts}" "${interval}"; then
    log_info "${name}: pid=${pid} stopped after SIGINT"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGTERM"
  send_signal_to_pid TERM "${pid}" || true
  if wait_for_process_exit "${pid}" "${term_attempts}" "${interval}"; then
    log_info "${name}: pid=${pid} stopped after SIGTERM"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGKILL"
  send_signal_to_pid KILL "${pid}" || true
  sleep 1
  if process_is_alive "${pid}"; then
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

  if wait_for_process_exit "${pid}" 100 0.2; then
    log_info "${name}: pid=${pid} stopped after cleanup"
    return 0
  fi

  log_info "${name}: pid=${pid} still running after grace period; escalating"
  stop_gently "${name}" "${pid}"

  if process_is_alive "${pid}"; then
    log_info "${name}: pid=${pid} still running after escalation"
    echo "${name} is still running (pid=${pid}); aborting" >&2
    exit 1
  fi

  log_info "${name}: pid=${pid} stopped after escalation"
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
#     $3 - CPU mask for turbostat affinity.
#     $4 - output file path.
#     $5 - shell variable that should receive the PID.
start_turbostat() {
  local pass="$1" interval="$2" cpu="$3" outfile="$4" varname="$5"
  log_debug "Launching turbostat ${pass} (output=${outfile}, tool cpus=${cpu}, workload cpus=${WORKLOAD_CPU})"
  local turbostat_cmd
  printf -v turbostat_cmd 'turbostat --interval %q --quiet --show %q --out %q' \
    "$interval" "Time_Of_Day_Seconds,CPU,Busy%,Bzy_MHz,PkgWatt,RAMWatt" "$outfile"
  start_background_system_tool "turbostat ${pass}" "${turbostat_cmd}" "${varname}" || return 1
}


# stop_turbostat
#   Terminate a turbostat process with escalating signals and wait for exit.
#   Arguments:
#     $1 - PID to stop (ignored when empty).
stop_turbostat() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  stop_gently "turbostat" "$pid"
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
