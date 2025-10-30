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
8. **MATLAB quoting guardrail** – when editing run scripts, keep every MATLAB `-r`
   command's paths wrapped in single quotes (e.g., `cd('/path')`) so MATLAB sees
   character arguments instead of bare identifiers. Dropping the quotes turns
   `/local/...` into invalid syntax and raises the `Invalid use of operator.`
9. **CPU list builder** – run scripts must call the shared `build_cpu_list`
    helper to derive `CPU_LIST` from `TOOLS_CPU`, optional `WORKLOAD_CPU`, and any
    literal pinning lines. Optional grep scans must be guarded with `|| true` so
    missing matches never trip `set -euo pipefail`. Tool invocations pin to
    `TOOLS_CPU`; workloads use `WORKLOAD_CPU` when defined.
10. **Maya wrapper pinning** – inside the quoted `bash -lc` Maya wrappers, keep
    `taskset` CPU lists wrapped in plain double quotes (no nested single quotes)
    so `${TOOLS_CPU}` and `${WORKLOAD_CPU}` expand correctly. Add the guards
    `: "${TOOLS_CPU:?missing TOOLS_CPU}"`, `: "${WORKLOAD_CPU:?missing WORKLOAD_CPU}"`
    and log `echo "[debug] pinning: TOOLS_CPU=${TOOLS_CPU} WORKLOAD_CPU=${WORKLOAD_CPU}"`
    immediately after `set -euo pipefail` to fail fast when the variables are
    missing.
11. **Super-run distribution** – the batch orchestrator `scripts/super_run.sh`
    must stay in lockstep with the `run_*.sh` CLI surface. When archiving
    startup bundles, `scripts/process_scripts.sh` is responsible for copying
    `super_run.sh` alongside the run scripts and `helpers.sh`; update that
    script whenever the distribution list changes so offline users retain the
    orchestrator.
12. **Super-run behavior parity** – keep the README and orchestrator aligned on
    these invariants whenever you touch `super_run.sh`:
    - default output lives in `/local/data/results/super/` with a shared
      `super_run.log`.
    - children launch via `sudo -E` (warn if unavailable) and inherit
      `TERM=dumb NO_COLOR=1` for non-interactive logging.
    - `--dry-run` is planning-only and must not touch workloads or datasets.
    - sweeps stay independent (no cross product), combos run afterward, and a
      `base/` variant appears only when no sweeps or combos are scheduled.
    - artifact collation moves `/local/data/results/id_*` payloads into each
      variant's `output/` and moves `/local/logs/*.log` (except `startup.log`)
      into `logs/`.
    - conflicting overrides emit the same warnings/prompt behavior described in
      the README (interactive prompt, auto-continue on non-interactive stdin).

## Operational safeguards for automation agents

1) **Do not overwrite artifacts.** The tool moves child outputs/logs into
   per-variant/per-replicate folders **immediately after each run**. If you
   change run order, keep the artifact move call intact.
2) **Force non-interactive child runs.** Children can emit ANSI/TUI
   (countdowns, cursor codes). Preserve:
   - `TERM=dumb`, `NO_COLOR=1`
   - `stdbuf -oL -eL` when available
   - STDIN from `/dev/null`
3) **Run ordering.** The scheduler is replicate-first → runs → rows. If you
   change this, verify artifacts still move per run.
4) **No legacy sweep grammars.** Only space-separated values are supported.
5) **Conflicts.** Keep the TTY prompt; auto-proceed w/ warning in non-TTY.
6) **No-`--runs` logic.** When missing:
   - Auto-detect single run script in the directory.
   - **ID-20 with multiple segments present:** prompt on TTY for `rnn|lm|llm`;
     error in non-TTY unless `--runs 20-*` is supplied.

## Agent checklist

- [ ] Preserve artifact **move** step after each run.
- [ ] Keep `TERM=dumb NO_COLOR=1` and `stdbuf` usage.
- [ ] Avoid reintroducing ANSI/TUI in non-interactive contexts.
- [ ] Maintain replicate-first ordering unless explicitly requested to change.
- [ ] Accept only space-delimited `--sweep` values.
- [ ] Support no-`--runs` autodetection and the ID-20 prompt/error behavior as
      documented.

### Run script argument defaults

All run scripts (`scripts/run_*.sh`) share the same CLI surface. When no flag is
provided, they resolve each argument to the following defaults:

| Argument | Default | Notes |
| --- | --- | --- |
| `--help` | Disabled | Prints usage and exits when invoked. |
| `--debug` | `off` | Accepts `on/off`; turns on verbose logging. |
| `--turbo` | `off` | Enables or disables CPU Turbo Boost. |
| `--cstates` | `on` | Controls whether the script requests deeper C-state disablement. |
| `--pkgcap` | `off` | CPU package RAPL cap (watts) or `off` to leave uncapped. |
| `--dramcap` | `off` | DRAM RAPL cap (watts) or `off` to leave uncapped. |
| `--llc` | `100` | Percentage of LLC reserved for the workload. |
| `--corefreq` | `2.4` | Requested core frequency in GHz; use `off` to skip pinning. |
| `--uncorefreq` | `off` | Uncore/ring frequency in GHz; `off` keeps the platform default. |
| `--prefetcher` | Unchanged | Leaving it unset preserves the host prefetcher state. |
| `--toplev-basic` | Disabled | Shortform for running Intel toplev (basic metrics). |
| `--toplev-execution` | Disabled | Enables toplev execution-pipeline metrics. |
| `--toplev-full` | Disabled | Enables the full toplev metric set. |
| `--maya` | Disabled | Runs the Maya microarchitectural profiler. |
| `--pcm` | Disabled | Enables PCM core/socket counters. |
| `--pcm-memory` | Disabled | Enables pcm-memory bandwidth sampling. |
| `--pcm-power` | Disabled | Enables pcm-power energy sampling. |
| `--pcm-pcie` | Disabled | Enables pcm-pcie bandwidth sampling. |
| `--pcm-all` | Disabled | Explicit shortcut that turns on every PCM profiler. |
| `--short` | Disabled | Shortcut that runs toplev basic & execution, Maya, and all PCM tools. |
| `--long` | Disabled | Shortcut that enables the full profiling suite. |
| `--interval-toplev-basic` | `0.5` seconds | Sampling cadence for toplev basic mode. |
| `--interval-toplev-execution` | `0.5` seconds | Sampling cadence for toplev execution mode. |
| `--interval-toplev-full` | `0.5` seconds | Sampling cadence for toplev full mode. |
| `--interval-pcm` | `0.5` seconds | Sampling cadence for pcm. |
| `--interval-pcm-memory` | `0.5` seconds | Sampling cadence for pcm-memory. |
| `--interval-pcm-power` | `0.5` seconds | Sampling cadence for pcm-power. |
| `--interval-pcm-pcie` | `0.5` seconds | Sampling cadence for pcm-pcie. |
| `--interval-pqos` | `0.5` seconds | Sampling cadence for pqos. |
| `--interval-turbostat` | `0.5` seconds | Sampling cadence for turbostat. |

When no profiling toggles (`--toplev-*`, `--maya`, or any `--pcm*`) are explicitly provided, the scripts enable the **full profiling suite**: toplev (basic, execution, full), Maya, and **all** PCM tools (equivalent to `--toplev-basic --toplev-execution --toplev-full --maya --pcm-all`).

### Super-run orchestrator

The helper `scripts/super_run.sh` fans out across multiple `run_*.sh` variants
with shared knob sweeps. Its CLI accepts **whitespace-separated tokens** (no
quoted CSV strings):

* `--runs` consumes IDs or script names until the next top-level flag.
* `--set` ingests run-script flags exactly as you would pass them to `run_*.sh`
  (bare booleans like `--short` or value pairs such as `--pkgcap 15`).
* `--sweep` takes a key followed by one or more values (`--sweep pkgcap 8 15`).
* `--combos` is encoded as `--combos combo key value [key value ...] [repeat N]
  [combo ...]`.

Allowed keys mirror the run-script CLI:
`debug, turbo, cstates, pkgcap, dramcap, llc, corefreq, uncorefreq, prefetcher, toplev-basic, toplev-execution, toplev-full, maya, pcm, pcm-memory, pcm-power, pcm-pcie, pcm-all, short, long, interval-toplev-basic, interval-toplev-execution, interval-toplev-full, interval-pcm, interval-pcm-memory, interval-pcm-power, interval-pcm-pcie, interval-pqos, interval-turbostat`

Every child run is launched through `sudo -E` so the orchestrator itself may run
unprivileged. It writes one transcript per sub-run plus a `super_run.log`
summary. Each variant folder also includes a `meta.json` alongside
`transcript.log`, `logs/`, and `output/`. Keep its argument validation synced
with new CLI flags, and ensure
packaging workflows (`scripts/process_scripts.sh`) include it so batch
automation is available even when nodes only receive the tarballs.
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
configured directly from the CLI. Pass `--turbo=on|off`, `--pkgcap=<watts>`,
`--dramcap=<watts>` or `--corefreq=<GHz>` to override the default `off`, `15`, `5`
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
