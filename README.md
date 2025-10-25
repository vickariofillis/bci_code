# BCI Code Workloads

## Workload Index
- **ID1: Seizure Detection (Laelaps)** – C/OpenMP implementation that classifies intracranial EEG segments with hyperdimensional computing primitives.
- **ID3: Neuropixels Compression Benchmarks** – Python pipelines that compress Neuropixels recordings and optionally run spike-sorting evaluations to assess codec impact.
- **ID13: Movement Intent Analysis** – MATLAB workflow that prepares FieldTrip inputs, performs IRASA and spectral analysis, and summarizes motor imagery power spectra.
- **ID20: Speech Decoder (3-gram WFST + RNN + LLM variants)** – Python components that run the recurrent acoustic model, WFST language model, and optional LLM rescoring across dedicated run scripts (`run_20_3gram_{lm,llm,rnn}.sh`).

## Repository Layout
- `id_*/` – Source trees for the workloads listed above. Each subdirectory contains its own README with algorithm details and logging phases.
- `scripts/` – Provisioning (`startup_*.sh`), execution (`run_*.sh`), and orchestration (`super_run.sh`) helpers plus compressed archives for distribution to CloudLab nodes.
- `tools/maya/` – Microarchitectural profiling tool built during startup for workloads that request Maya instrumentation.
- `other/`, `help/`, and `tools/` – Shared utilities, documentation, and profiling dependencies referenced by the run scripts.

## Startup Scripts
The `scripts/startup_*.sh` helpers prepare a clean CloudLab node for a given workload. They take no arguments and must be run with root privileges:

```bash
sudo bash scripts/startup_1.sh   # replace suffix with 3, 13, or 20 as needed
```

Each startup script performs the same high-level tasks:
1. Claim `/local` for the invoking user, create `/local/logs`, and tee all stdout/stderr into `/local/logs/startup.log` for auditing.
2. Clone this repository into `/local/bci_code` and build the Maya profiler needed by the run scripts.
3. Detect the node’s hardware profile to expand local storage under `/local/data`, then install core packages such as `git`, `build-essential`, `cpuset`, `cmake`, and `intel-cmt-cat`.
4. Create `/local/tools` and `/local/data/results` so subsequent runs have a standardized workspace.

Compressed `startup_*.tar.gz` bundles mirror the shell scripts for offline deployment when cloning is not possible.

## Run Scripts
The `scripts/run_*.sh` entry points launch each workload and optional profilers. Invoke them under `sudo` so that CPU affinity, RAPL caps, and performance counters can be configured:

```bash
sudo bash scripts/run_1.sh [options]
```

Common features across the run scripts include:
- Automatic `tmux` relaunch when started outside a session, ensuring long profiling runs survive SSH drops.
- Shared environment knobs (`WORKLOAD_CPU`, `TOOLS_CPU`, `OUTDIR`, `LOGDIR`, and `IDTAG`) exported for child processes and logs consolidated in `/local/logs/run.log`.
- Unified CLI flags to select instrumentation: `--toplev-basic`, `--toplev-execution`, `--toplev-full`, `--maya`, and the PCM family (`--pcm`, `--pcm-memory`, `--pcm-power`, `--pcm-pcie`, `--pcm-all`). Shortcuts `--short` and `--long` enable curated tool bundles, while `--debug` surfaces verbose tracing.
- Power-management switches that control Turbo Boost, package and DRAM caps, and optional frequency pinning (`--turbo=on|off`, `--pkgcap=<watts>`, `--dramcap=<watts>`, `--corefreq=<GHz>`).
- Ten-second countdown, timezone-stamped start/stop logs, and helper functions to launch or stop sidecar profilers so experiments can be correlated with instrumentation traces.
- Workload-specific execution blocks that pin the main binary or Python module to the workload CPU, integrate Maya/PCM/Toplev logging, and write results into `/local/data/results/<id>_*`. Examples include calling `/local/bci_code/id_1/main` for seizure detection or staging Neuropixels datasets for compression benchmarks.

Each script prints `--help` output summarizing the options above without entering `tmux`, making it safe to inspect available flags before launching the full pipeline.

## Super Run Automation — Usage & Behavior Reference

`scripts/super_run.sh` is executable (`#!/usr/bin/env bash`) and may be launched directly after `chmod +x`. Run it from the repository root so it can find sibling scripts:

```bash
./scripts/super_run.sh [flags]
```

`super_run.sh` launches child `run_*.sh` with `sudo -E`, writes a consolidated `super_run.log` under `/local/data/results/super/`, and each variant folder includes `meta.json`, `transcript.log`, `logs/`, and `output/`.

Key runtime behaviors to keep in mind:

- Children are forced through `sudo -E` so the orchestrator can be started as any user while each `run_*.sh` still gains root privileges with the original environment preserved. If `sudo` is missing the script logs a warning and proceeds without elevation.
- Every child inherits `TMUX=1`, `TERM=dumb`, and `NO_COLOR=1` so non-interactive logging stays tidy even when launched outside `tmux`.
- `--dry-run` plans the run matrix, logs the would-be invocations, and exits without touching datasets or launching workloads.
- After each sub-run, the orchestrator moves workload artifacts from `/local/data/results/id_*` (excluding the `super/` folder) into the variant's `output/` directory and collates `/local/logs/*.log` files—except `startup.log`—into the variant's `logs/` directory.
- When an override conflicts with `--set`, the script prints a summary and, on interactive terminals, prompts before continuing. In non-interactive contexts it auto-continues but emits a warning so CI logs capture the mismatch.

The parser uses **whitespace-separated tokens**—no quotes, commas, pipes, or semicolons. After each top-level flag (`--runs`, `--set`, `--sweep`, `--combos`, `--repeat`, `--outdir`, `--dry-run`) every following argument is consumed until the next top-level flag appears. Boolean run-script flags become bare tokens (for example `--short`), while value flags consume the next token (`--pkgcap 15`).

## What it runs
- **Required**: You must pass `--runs …` (e.g., `--runs 1`, `--runs 3 13`, `--runs 20-llm`, or explicit filenames like `--runs run_1.sh run_20_3gram_llm.sh`). There is no automatic selection and no ID-20 mode prompt.
- **Explicit selection**: Use numeric IDs or script names:
  - `--runs 1` → `run_1.sh`
  - `--runs 3 13` → `run_3.sh` and `run_13.sh`
  - `--runs 20-rnn` → `run_20_3gram_rnn.sh`
  - `--runs run_1.sh run_20_3gram_llm.sh` → those exact files

## Where results go
- **Default outdir**: `/local/data/results/super/`
  - You can override via `--outdir /path/to/dir`
- **Layout**:  
  `/local/data/results/super/<run_label>/<variant>[/<n>/]{logs/,output/,meta.json,transcript.log}`  
  Examples:
  - Sweep variant: `/local/data/results/super/run_1/corefreq-0_75/1/`
  - Combo variant: `/local/data/results/super/run_1/pkgcap-7_5__dramcap-10/`

### Variant folder naming
- Each variant gets a folder named from its overrides (no trailing underscores).  
  Examples: `pkgcap-7_5`, `llc-40`, `prefetcher-0011`, or a combo `pkgcap-7_5__dramcap-10`.
- Dots become underscores to be filesystem-safe (e.g., `7.5` → `7_5`).

## Base vs. Sweeps vs. Combos

### `--set`
- Baseline key/value pairs applied to every run.
  Format: `--set --debug --short --pkgcap 15` (any run-script flag is accepted).
- **Allowed keys** (mirrors run scripts):
  `debug, turbo, cstates, pkgcap, dramcap, llc, corefreq, uncorefreq, prefetcher, toplev-basic, toplev-execution, toplev-full, maya, pcm, pcm-memory, pcm-power, pcm-pcie, pcm-all, short, long, interval-toplev-basic, interval-toplev-execution, interval-toplev-full, interval-pcm, interval-pcm-memory, interval-pcm-power, interval-pcm-pcie, interval-pqos, interval-turbostat`
- **Boolean flags** (e.g., `short`, `toplev-basic`, `maya`, etc.): pass the bare flag to emit it (`--set --debug --short`).
  Provide a value token to override defaults (`--set --debug off`).

### `--sweep`
- A **sweep** changes one key across multiple values, with **all other knobs at their defaults + your `--set`**.
- **Sweeps are independent** (not cross-product).
  Use multiple `--sweep` flags; each produces its own series of runs.
- Format: `--sweep pkgcap 7.5 15 30` (first token is the key, remaining tokens are values).

### `--combos`
- A **combo** is one explicit variant made from key/value pairs.
  Start each row with the literal token `combo`, then list `key value` pairs.
- Format:
  - **One combo**: `--combos combo k1 v1 k2 v2`
  - **Many combos**: `--combos combo k1 v1 k2 v2 combo k3 v3 k4 v4`
- Add `repeat N` within a row to override the global repeat.
- **Order of execution**: all **sweeps first**, then all **combos**.
- **Conflicts with `--set`**: allowed. You’ll get a summary and Y/N prompt to proceed.
  - On non-interactive stdin (CI, cron, etc.) the prompt is skipped and execution continues after logging a warning.

### Repeats
- **Global**: `--repeat N` runs every variant N times, creating `1/`, `2/`, … subfolders under the variant.
- **Per-combo**: add `repeat N` inside a combo row to override global repeat for that combo.
  Example: `--combos combo pkgcap 7.5 dramcap 10 repeat 2`

### When a “base/” run appears
- A `base/` variant (just `--set`, nothing else) is **only created when you pass no sweeps and no combos**.
- If you do provide sweeps and/or combos, **no** `base/` run is created.

## Quick examples

### Independent sweeps with common flags

```bash
### 0) Baseline only (creates `base/` because there are no sweeps/combos)
$ ./scripts/super_run.sh --runs 1 --set --debug --short
# Equivalent:
# $ ./scripts/super_run.sh --runs id1 --debug --short
→ /local/data/results/super/run_1/base/{transcript.log,meta.json,logs/,output/}

### 1) Independent sweeps with common flags (NO cross product)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --sweep pkgcap 8 15 30 \
    --sweep dramcap 5 10 20 \
    --sweep llc 15 40 80 \
    --sweep corefreq 0.75 1.4 2.4 \
    --sweep uncorefreq 0.75 1.5 2.5 \
    --sweep prefetcher 0000 0011 1111
# Equivalent (run-style flags instead of --set):
# $ ./scripts/super_run.sh --runs run_1.sh --debug --short ...same --sweep lines...
→ Variants: pkgcap-8, pkgcap-15, pkgcap-30, dramcap-5, dramcap-10, dramcap-20,
            llc-15, llc-40, llc-80, corefreq-0_75, corefreq-1_4, corefreq-2_4,
            uncorefreq-0_75, uncorefreq-1_5, uncorefreq-2_5,
            prefetcher-0000, prefetcher-0011, prefetcher-1111
→ Each variant gets /1/ because default repeat is 1 (no `base/` is created since sweeps exist)

### 2) Single combo (explicit settings merged with --set)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --combos combo pkgcap 8 dramcap 10 llc 40
# Equivalent:
# $ ./scripts/super_run.sh --runs 1 --debug --short --combos combo pkgcap 8 dramcap 10 llc 40
→ /local/data/results/super/run_1/pkgcap-8__dramcap-10__llc-40/1/

### 3) Multiple combos (multiple `combo` rows)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --combos combo pkgcap 8 dramcap 10 combo llc 80 prefetcher 0011
# Equivalent mixed style:
# $ ./scripts/super_run.sh --runs id1 --debug --short \
#     --combos combo pkgcap 8 dramcap 10 combo llc 80 prefetcher 0011
→ /local/data/results/super/run_1/pkgcap-8__dramcap-10/1/
→ /local/data/results/super/run_1/llc-80__prefetcher-0011/1/

### 4) Per-combo repeat (overrides global repeat)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --combos combo pkgcap 8 dramcap 10 repeat 2 combo llc 80
→ /local/data/results/super/run_1/pkgcap-8__dramcap-10/1/
→ /local/data/results/super/run_1/pkgcap-8__dramcap-10/2/
→ /local/data/results/super/run_1/llc-80/1/

### 5) Global repeat for all variants (sweeps and combos)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --sweep pkgcap 8 15 \
    --combos combo dramcap 10 llc 40 \
    --repeat 3
# Equivalent:
# $ ./scripts/super_run.sh --runs 1 --debug --short \
#     --sweep pkgcap 8 15 --combos combo dramcap 10 llc 40 --repeat 3
→ /local/data/results/super/run_1/pkgcap-8/1,2,3/
→ /local/data/results/super/run_1/pkgcap-15/1,2,3/
→ /local/data/results/super/run_1/dramcap-10__llc-40/1,2,3/

### 6) Mix sweeps + combos together (sweeps run first, then combos)
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short \
    --sweep corefreq 0.75 2.4 \
    --combos combo pkgcap 8 dramcap 10 combo llc 80
→ /local/data/results/super/run_1/corefreq-0_75/1/
→ /local/data/results/super/run_1/corefreq-2_4/1/
→ /local/data/results/super/run_1/pkgcap-8__dramcap-10/1/
→ /local/data/results/super/run_1/llc-80/1/

### 7) Combos may conflict with --set; you’ll be prompted Y/N
$ ./scripts/super_run.sh \
    --runs 1 \
    --set --debug --short --pkgcap 10 \
    --combos combo pkgcap 8 dramcap 10
# Equivalent:
# $ ./scripts/super_run.sh --runs 1 --debug --short --pkgcap 10 \
#     --combos combo pkgcap 8 dramcap 10
→ Script shows a conflict summary and asks to proceed (Y/N). If Y:
   /local/data/results/super/run_1/pkgcap-8__dramcap-10/1/
```

## Minimal Execution Flow
1. Run the matching `startup_*.sh` once per node to provision dependencies and workspace.
2. Copy any required datasets into `/local/data` as described in the workload-specific READMEs.
3. Launch the appropriate `run_*.sh` script with the desired profiling options. Result CSVs, logs, and profiler traces will appear under `/local/data/results` and `/local/logs` for post-processing.

For bespoke automation, `scripts/process_scripts.sh` can unpack the archived startup packages and re-sync them with the latest shell scripts, helper utilities, and the `super_run.sh` orchestrator so offline nodes stay current.
