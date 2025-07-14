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

`benchmark-lossless.py` no longer aggregates individual CSV files. It appends
results to the path provided as an optional fourth command-line argument. Run
scripts set this to files such as `id_3_pcm.csv` or `id_3_toplev_basic.csv` so
each profiling tool keeps its own CSV. When no path is supplied, the script
creates `benchmark-lossless-<dataset>-<duration>-<compressor>.csv` inside
`results/`.
