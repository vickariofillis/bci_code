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
Before Maya or Toplev profiling, they shield CPUs 5 and 6 for profiler/workload
isolation but leave the rest of the system online so measurement tools (e.g.,
Maya, pcm-pcie) see the expected topology.
Process placement is now verified without using the fragile `ps cpuset` column;
run scripts print the Maya PID, its current CPU and CPU affinity via `ps` and
`taskset`, followed by the cpuset or cgroup path from `/proc`.

## PCM-power attribution framework (override)

When `--pcm-power` is selected, the scripts run a three-pass measurement flow
anchored on pcm-power timestamps:

* **Pass A – pcm-power + turbostat:** pcm-power streams socket/package and DRAM
  power to `${RESULT_PREFIX}_pcm_power.csv` while turbostat samples CPU busy
  time and frequency for share estimation.
* **Pass B – pcm-memory:** `pcm-memory` collects system IMC bandwidth into
  `${OUTDIR}/${PFX}_pcm_memory_dram.csv` (logs land in `${LOGDIR}/pcm_memory_dram.log`).
* **Pass C – PQoS MBM:** `pqos -I` captures memory bandwidth monitoring (MBM)
  counters for workload and system scope at `${OUTDIR}/${PFX}_pqos.csv`.

pcm-power CSV files always contain two header rows; the scripts append
`Actual Watts` and `Actual DRAM Watts` (in that order, under the existing `S0`
group) without introducing trailing commas. `Actual Watts` is now inclusive of
the workload’s attributed DRAM power.

Attribution combines the three data sources using gray-area apportioning. For
each pcm-power sample we compute:

* `share_mbm = W / A` (clamped) where `W` is the workload MBM stream (prefer
  MBT, fall back to MBL) and `A` is the deduplicated all-core MBM total.
* `gray = max(S - A, 0)` using the system IMC bandwidth `S` from pcm-memory
  (falling back to `A` if pcm-memory is unavailable).
* `W_attr = W + share_mbm * gray` and
  `P_dram_attr = P_dram_total * (W_attr / S)` when `S` is available, otherwise
  `P_dram_attr = P_dram_total * share_mbm`. DRAM attribution is clamped to
  `[0, P_dram_total]`.
* `P_pkg_attr = max(P_pkg_total - P_dram_total, 0) * cpu_share + P_dram_attr`
  where `cpu_share` comes from turbostat busy% × Bzy_MHz weighting. This
  replaces the previous `P_pkg_total * cpu_share` formulation.

The per-sample breakdown is also written to `${PFX}_attrib.csv` with columns:

```
sample,pkg_watts_total,dram_watts_total,imc_bw_MBps_total,
mbm_workload_MBps,mbm_allcores_MBps,cpu_share,mbm_share,
gray_bw_MBps,workload_attrib_bw_MBps,pkg_attr_watts,dram_attr_watts
```

Robust parsing/alignment helpers remain unchanged: pcm-power headers are
flattened with the existing ghost-column cleanup; sampling intervals are
aligned using pcm-power timestamps with tolerance windows (anchored on
`ALIGN_TOLERANCE_SEC` and `DELTA_T_SEC`); PQoS sub-second samples continue to
use `try_parse_pqos_time()` with synthesized timestamps when needed and dedupe
duplicate (Time,Core) entries by taking the maximum. pcm-memory data still
passes through `try_parse_pcm_memory_timestamp()`,
`drop_initial_pcm_memory_outliers()`, and
`filter_pcm_memory_entries()` before filling.

We continue to prefer MBT counters over MBL (never summing MBR) and rely on the
Linux resctrl driver’s correction for the Broadwell-EP MBM erratum (BDF102).
`fill_series()` behavior is unchanged—forward/backward fill with at most one
interpolation per gap—and all existing coverage, `first3/last3`, and debug
logs remain.

Troubleshooting tips:

* Missing turbostat data forces `cpu_share` to zero, yielding zero package
  attribution (aside from any DRAM component).
* Missing PQoS data produces zero MBM bandwidth, so DRAM attribution drops to
  zero when pcm-memory is also absent.
* Missing pcm-memory data falls back to MBM totals for `S`, eliminating the
  gray-bandwidth term but still computing attribution from MBM shares.

The only completion marker emitted by the run scripts is `${OUTDIR}/done.log`.
