# BCI Code Repository – Codex Agent Guide

## Purpose

This document tells GitHub Copilot‑powered agents ("Codex") **exactly** how to
work inside this repository. The repo aggregates several Brain‑Computer Interface
(BCI) research workloads written in C, C++, Python, MATLAB and Bash. Because the
workloads are intended to run on CloudLab nodes with hardware counters and
large datasets, Codex cannot execute end‑to‑end tests locally. Instead, Codex
should focus on safe refactors, small bug fixes, and script maintenance while
respecting the special constraints called out below.

## Repository Map (high level)

help/                  – usage notes for CloudLab + toplev
id\_1/                  – seizure‑detection workload (C99 + OpenMP)
id\_3/                  – Neuropixels compression benchmarks (Python)
id\_11/                 – placeholder directory
id\_13/                 – movement‑intent analysis (MATLAB + FieldTrip)
id\_20/                 – speech decoder (Python + PyTorch; WFST C++ code)
other/                 – misc helper scripts
scripts/               – run/startup wrappers for each workload
tools/maya/            – microarchitectural profiler (C++)
.gitignore             – build artefacts, data spills, etc.

## Languages & Quick Build Commands

* **C (id\_1):**  `gcc -std=c99 -fopenmp main.c associative_memory.c aux_functions.c -o id_1/main -lm`
* **Python (id\_3 & id\_20):**  all packages installed via `pip`; see `setup.sh`
* **MATLAB (id\_13):**  runs only under MATLAB with FieldTrip; Codex must not
  attempt to execute it.
* **C++ (tools/maya, LanguageModelDecoder):**  built with `make` or `cmake`.  On
  CI, compile with a single thread to stay within time limits.

## Agent Responsibilities

1. **Safe refactors** – rename variables, extract functions, modernise C code.
2. **Script updates** – keep `run_*.sh` and `startup_*.sh` in sync with source
   paths after code moves.
3. **Dependency bumps** – update `pyproject.toml`, `setup.cfg`, or
   `requirements.txt` only when wheels exist on PyPI.
4. **Light testing** – unit‑test pure Python utilities (e.g. id\_3/code/utils.py).
5. **Style clean‑up** – apply clang‑format or black where appropriate.

6. **Timestamp logging** – after the 10-second countdown, each run script must print `Experiment started at: YYYY-MM-DD - hh:mm` and when complete print `Experiment finished at: YYYY-MM-DD - hh:mm`.  Major profiling stages should also announce their start and end times.
   Each PCM tool (pcm, pcm-memory, pcm-power and pcm-pcie) reports its own start and finish times.
7. **User permissions** – before changing ownership of `/local`, run scripts must set:
   ```bash
   RUN_USER=${SUDO_USER:-$(id -un)}
   RUN_GROUP=$(id -gn "$RUN_USER")
   ```
   and then invoke `chown -R "$RUN_USER":"$RUN_GROUP" /local`.
8. **tmux relaunch** – if a run script isn't already inside tmux, it should use:
   ```bash
   session_name="$(basename "$0" .sh)"
   script_path="$(readlink -f "$0")"
   exec tmux new-session -s "$session_name" "$script_path" "$@"
   ```
   Scripts are unpacked in `/local`, so absolute paths ensure consistent relaunch.
9. **MATLAB quoting guardrail** – when editing run scripts, keep every MATLAB `-r`
   command's paths wrapped in single quotes (e.g., `cd('/path')`) so MATLAB sees
   character arguments instead of bare identifiers. Dropping the quotes turns
   `/local/...` into invalid syntax and raises the `Invalid use of operator.`
10. **CPU list builder** – run scripts must call the shared `build_cpu_list`
    helper to derive `CPU_LIST` from `TOOLS_CPU`, optional `WORKLOAD_CPU`, and any
    literal pinning lines. Optional grep scans must be guarded with `|| true` so
    missing matches never trip `set -euo pipefail`. Tool invocations pin to
    `TOOLS_CPU`; workloads use `WORKLOAD_CPU` when defined.
11. **Maya wrapper pinning** – inside the quoted `bash -lc` Maya wrappers, keep
    `taskset` CPU lists wrapped in plain double quotes (no nested single quotes)
    so `${TOOLS_CPU}` and `${WORKLOAD_CPU}` expand correctly. Add the guards
    `: "${TOOLS_CPU:?missing TOOLS_CPU}"`, `: "${WORKLOAD_CPU:?missing WORKLOAD_CPU}"`
    and log `echo "[debug] pinning: TOOLS_CPU=${TOOLS_CPU} WORKLOAD_CPU=${WORKLOAD_CPU}"`
    immediately after `set -euo pipefail` to fail fast when the variables are
    missing.
## Things Codex MUST NOT Do

* Try to run full workloads locally – they assume CloudLab, GPUs, or MATLAB.
* Commit large data files (>1 MB) or generated binaries.
* Break public APIs: keep command‑line flags and output file names stable.
* Modify external third‑party subtrees such as `LanguageModelDecoder/srilm‑*`.

## How to Smoke‑Test Changes Locally

* **Python:**  create a virtual env and `python -m pip install -e
  id_20/code/neural_seq_decoder`.  Run `python -m pytest -q` inside id\_3 scripts
  if you add tests.
* **C:**  compile `id_1/main.c` and run with a small synthetic input.
* **C++:**  build `tools/maya` in Debug and run `./Maya --mode Baseline --cycles
  1000` to verify no segfaults.

## Suggested Manual Test Matrix

| Path   | Build cmd         | Quick run                                  |
| ------ | ----------------- | ------------------------------------------ |
| id\_1  | make (see README) | ./main < sample.vec                        |
| id\_3  | pytest            | id\_3/scripts/benchmark-lossless.py --help |
| id\_20 | pip install -e .  | python scripts/rnn\_run.py --dry\_run      |

## Environment Setup

An example `setup.sh` lives at repo root and installs:

* GCC, make, cmake, ninja‑build
* Python3.10 + venv + scientific wheels (torch, numpy, scipy, numba, etc.)
* libomp‑dev for OpenMP
* (optional) clone FieldTrip for MATLAB users – *skip on CI*
  Total runtime fits within the 10‑minute constraint on a 4‑core Ubuntu 24.04 VM.

## Maintenance rule

After each change, update this document to reflect the current repository
structure or processes. The run scripts now support three Toplev profiling
modes: `toplev-basic`, `toplev-execution` and `toplev-full`. They can be
enabled via `--toplev-basic`, `--toplev-execution` or `--toplev-full` and are
automatically selected when invoking `--short` or `--long`.

PCM profiling flags follow the same pattern. Use `--pcm`, `--pcm-memory`,
`--pcm-power` or `--pcm-pcie` to run individual tools, or `--pcm-all` to run
them all (the default when no PCM options are provided).

`benchmark-lossless.py` no longer aggregates individual CSV files. It appends
results to the path provided as an optional fourth command-line argument.
Run scripts now supply dedicated workload files for each tool, e.g.,
`workload_pcm.csv` or `workload_toplev_basic.csv`, so compression metrics stay
separate from profiler outputs like `id_3_pcm.csv` or
`id_3_toplev_basic.csv`. When no path is supplied, the script creates
`benchmark-lossless-<dataset>-<duration>-<compressor>.csv` inside
`results/`.
CSV helpers in `id_3/code/utils.py` automatically return an empty DataFrame when
the file is missing or empty so repeated runs start with a clean slate.

Run scripts now print the applied turbo state, RAPL power limits and frequency
settings after configuration to help verify the environment before execution.
Turbo Boost, package and DRAM power caps, and frequency pinning can now be
configured directly from the CLI. Pass `--turbo=on|off`, `--cpu-cap=<watts>`,
`--dram-cap=<watts>` or `--freq=<GHz>` to override the default `off`, `15`, `5`
and `1.2` values respectively. The help output documents these flags alongside
the profiling controls.
Every workload/tool combination must emit a `[DEBUG] Launching ...` message
that identifies the tool core and workload core before the command starts.
When adding a new workload, tool, or pairing, replicate the existing debug
format so `run.log` always captures the CPU affinities (tool core=X, workload
core=Y, plus any auxiliary cores such as `others`).
Before Maya or Toplev profiling, they shield CPUs 5 and 6 for profiler/workload
isolation but leave the rest of the system online so measurement tools (e.g.,
Maya, pcm-pcie) see the expected topology.
Process placement is now verified without using the fragile `ps cpuset` column;
run scripts print the Maya PID, its current CPU and CPU affinity via `ps` and
`taskset`, followed by the cpuset or cgroup path from `/proc`.

## Sampling & Orchestration (MANDATORY, NO EXCEPTIONS)

We run **three** separate passes to avoid tool conflicts and resctrl contention:

1. **Pass 1 — Power + CPU share:**  
   - `pcm-power` (CSV) pinned to `TOOLS_CPU`  
   - `turbostat` (text) pinned to `TOOLS_CPU`  
   - After an idle prelude, run the workload pinned to `WORKLOAD_CPU`.  
   - On completion, stop `turbostat`.

2. **Pass 2 — iMC (system DRAM bandwidth) + CPU share:**  
   - `pcm-memory -nc` (CSV) pinned to `TOOLS_CPU`  
   - `turbostat` (text) pinned to `TOOLS_CPU`  
   - After an idle prelude, run the workload pinned to `WORKLOAD_CPU`.  
   - On completion, stop `turbostat`.

3. **Pass 3 — PQoS MBM only:**  
   - `pqos -I -u csv -m "all:${WORKLOAD_CPU};all:${OTHERS}"` pinned to `TOOLS_CPU`  
   - Build `OTHERS` as all online CPUs except `{TOOLS_CPU, WORKLOAD_CPU}`.  
   - If `OTHERS` is empty, use only `all:${WORKLOAD_CPU}` (omit the second group).  
   - After an idle prelude, run the workload pinned to `WORKLOAD_CPU`.  
   - On completion, stop `pqos`.

**Resctrl policy:**  
- Use the OS/resctrl interface (`pqos -I`).  
- Reset resctrl state between passes: `pqos -I -R`.  
- Never run `pqos` concurrently with `pcm-power` or `pcm-memory`.

**Turbostat files:**  
- We produce two turbostat text chunks (`*_pass1.txt`, `*_pass2.txt`) and then  
  concatenate them to the legacy `*_turbostat.txt`. Conversion to CSV is applied  
  after concatenation to keep downstream parsers unchanged.

**Guardrails:**  
- Before starting `pcm-power` or `pcm-memory`, assert no `pqos` is running.  
- Before starting `pqos`, assert no `pcm-power` or `pcm-memory` is running.  
- Fail fast if any sampler fails to start, or if a previous sampler is still alive.  
- Log these markers (grep in CI):  
  - `Pass 1: pcm-power + turbostat`  
  - `Pass 2: pcm-memory + turbostat`  
  - `Pass 3: pqos MBM only`

**Why three passes?**
- `pcm-power`/`pcm-memory` program uncore PMUs; `pqos` uses resctrl. Running them
  together can produce undefined behavior and data corruption. Separating passes,
  with resctrl resets in between, ensures stable measurements.

## Power & Bandwidth Attribution (MBM-aware)

We anchor every attribution window on the `pcm-power` samples produced in Pass 1
and reuse the tolerance-based alignment helpers already in the repo. The
following behaviors are **mandatory**:

- Preserve the two-row `pcm-power` headers (top row domains, bottom row labels)
  and continue appending the columns `Actual Watts` and `Actual DRAM Watts`.
- Keep the PQoS handling unchanged: reconstruct sub-second timestamps, deduplicate
  by `(Time, Core)` using max semantics, and prefer MBT over MBL (never add MBR).
- Retain the turbostat CPU-share calculation (`Busy% × Bzy_MHz`), pcm-memory
  outlier drop/trim, and ghost-column protection when writing the CSV back.
- Continue writing results atomically (tempfile + `os.replace`) and restoring
  file permissions when possible.

### Per-sample attribution math

For each aligned sample `i`:

```
P_pkg_total(i)  := pcm-power Watts
P_dram_total(i) := pcm-power DRAM Watts
cpu_share(i)    := turbostat share on WORKLOAD_CPU
W(i)            := PQoS workload MBM (MBT preferred; else MBL)
A(i)            := PQoS all-core MBM sum
S(i)            := pcm-memory System Memory bandwidth (MB/s)

total_mb(i)  = max(A(i), 0)
system_mb(i) = isfinite(S(i)) ? S(i) : total_mb(i)
gray(i)      = max(system_mb(i) - total_mb(i), 0)
share_mbm(i) = (A(i) > EPS) ? clamp01(W(i) / A(i)) : 0
W_attr(i)    = W(i) + share_mbm(i) * gray(i)

if system_mb(i) > EPS:
    P_dram_attr(i) = P_dram_total(i) * (W_attr(i) / system_mb(i))
else:
    P_dram_attr(i) = P_dram_total(i) * share_mbm(i)
P_dram_attr(i) = clamp(P_dram_attr(i), 0, max(P_dram_total(i), 0))

non_dram(i)   = max(P_pkg_total(i) - P_dram_total(i), 0)
P_pkg_attr(i) = non_dram(i) * cpu_share(i)
P_pkg_attr(i) = clamp(P_pkg_attr(i), 0, non_dram(i))
```

Fallbacks follow the existing philosophy:

- Missing PQoS window → `W = A = 0`, so `share_mbm = 0`, `gray = system_mb`, and
  both attributed powers drop to zero.
- Missing pcm-memory sample → `system_mb = A`, `gray = 0`, so DRAM attribution
  relies solely on MBM share.
- Missing DRAM RAPL domain → `P_dram_total = 0`, so `P_dram_attr = 0` and
  package attribution reduces to `cpu_share × P_pkg_total` (the non-DRAM term).
- Missing turbostat block → `cpu_share = 0` (already enforced by the fill logic).

Apply the usual clamps to prevent negative values or NaNs. Emit warnings if any
of these sanity checks fail: `0 ≤ mbm_share ≤ 1`, `0 ≤ cpu_share ≤ 1`,
`gray ≥ 0`, `pkg_attr ≤ pkg_total + ε`, `dram_attr ≤ dram_total + ε`.

### Outputs

- Append the attributed powers back into the same `pcm-power` CSV as `Actual Watts`
  (package-only attribution) and `Actual DRAM Watts` (MBM gray-area attribution).
- Emit `${OUT}/${ID}_attrib.csv` with this header (exact order):

  ```
  sample,pkg_watts_total,dram_watts_total,imc_bw_MBps_total,mbm_workload_MBps,mbm_allcores_MBps,cpu_share,mbm_share,gray_bw_MBps,workload_attrib_bw_MBps,pkg_attr_watts,dram_attr_watts
  ```

- Log the attribution summary means:
  `ATTRIB mean: pkg_total=..., dram_total=..., pkg_attr(Actual Watts)=..., dram_attr(Actual DRAM Watts)=..., gray_MBps=...`.
- Socket-level attribution is available by summing the two columns in `${ID}_attrib.csv`;
  we do **not** add a separate socket column to the `pcm-power` CSV.

### Notes

- `Actual Watts` in the `pcm-power` CSV equals `(Package Watts − DRAM Watts) × CPU share`,
  i.e., the package domain after removing DRAM. `Actual DRAM Watts` is the MBM-informed
  DRAM attribution. Summing them yields the
  socket view reported in `${ID}_attrib.csv` when needed.
- We still rely on the OS/resctrl (`pqos -I`) interface and never run PQoS
  alongside `pcm-power` or `pcm-memory`.
- The Intel Broadwell-EP MBM erratum is handled in the driver; any residual
  mismatch is reconciled through the gray-bandwidth apportioning above.
