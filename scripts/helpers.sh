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
  LLC_EXCLUSIVE_ACTIVE=true
  LLC_REQUESTED_PERCENT="$LLC_PCT"
  trap_add 'restore_llc_defaults' EXIT
  echo "[LLC] Reserved ${LLC_PCT}% -> ${RESERVED_WAYS}/${WAYS_TOTAL} ways (mask 0x$WL_MASK) for workload CPUs ${WL_CPUS}."
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
    $debug_enabled && printf '[DEBUG] [PF] cpu%s: 0x%016x -> 0x%016x\n' "$cpu" "$cur" "$new"
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
    sudo tee "${target}" >/dev/null <"${snapshot}" || true
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
  if [[ ${path} == */smp_affinity && ${path} != */smp_affinity_list ]]; then
    payload="$(cpu_mask_to_hex "${mask}")"
  elif [[ ${path} == */workqueue/cpumask || ${path} == */workqueue/*/cpumask || ${path} == */workqueue/devices/*/cpumask ]]; then
    payload="$(cpu_mask_to_hex "${mask}")"
  fi
  printf '%s\n' "${payload}" | sudo tee "${path}" >/dev/null
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

  local updated=0 failed=0 path
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
    else
      ((failed+=1))
    fi
  done
  shopt -u nullglob

  log_info "Steered IRQ affinity away from workload CPUs -> mask=${mask} updated=${updated} failed=${failed}"
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
process_is_alive() {
  local pid="$1"
  local stat=""

  [[ -n ${pid:-} ]] || return 1

  if ! kill -0 "${pid}" 2>/dev/null; then
    return 1
  fi

  stat="$(ps -o stat= -p "${pid}" 2>/dev/null | awk 'NR==1 {print $1}')"
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
  kill -s INT "${pid}" 2>/dev/null || true
  if wait_for_process_exit "${pid}" "${int_attempts}" "${interval}"; then
    log_info "${name}: pid=${pid} stopped after SIGINT"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGTERM"
  kill -s TERM "${pid}" 2>/dev/null || true
  if wait_for_process_exit "${pid}" "${term_attempts}" "${interval}"; then
    log_info "${name}: pid=${pid} stopped after SIGTERM"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGKILL"
  kill -s KILL "${pid}" 2>/dev/null || true
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
    "$interval" "Time_Of_Day_Seconds,CPU,Busy%,Bzy_MHz" "$outfile"
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
