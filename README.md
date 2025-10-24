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

## What it runs
- **Automatic detection**: If only one `run_*.sh` is present in the same folder, `super_run.sh` will run that workload by default.
  - Special case: if it detects the three ID20 variants (`run_20_3gram_rnn.sh`, `run_20_3gram_lm.sh`, `run_20_3gram_llm.sh`), it prompts you to choose `{rnn|lm|llm}` unless you specify `--runs` explicitly.
- **Explicit selection**: Use numeric IDs or script names:
  - `--runs "1"` → `run_1.sh`
  - `--runs "3,13"` → `run_3.sh` and `run_13.sh`
  - `--runs "20-rnn"` → `run_20_3gram_rnn.sh`
  - `--runs "run_1.sh,run_20_3gram_llm.sh"` → those exact files

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
  Format: `--set "k=v,k2=v2,..."`.
- **Allowed keys** (mirrors run scripts):  
  `debug, turbo, cstates, pkgcap, dramcap, llc, corefreq, uncorefreq, prefetcher, toplev-basic, toplev-execution, toplev-full, maya, pcm, pcm-memory, pcm-power, pcm-pcie, pcm-all, short, long, interval-toplev-basic, interval-toplev-execution, interval-toplev-full, interval-pcm, interval-pcm-memory, interval-pcm-power, interval-pcm-pcie, interval-pqos, interval-turbostat`
- **Boolean flags** (e.g., `short`, `toplev-basic`, `maya`, etc.): pass `on/true/1` to emit the bare flag to the run script.  
  Example: `--set "debug=on,short=on,toplev-basic=1"`

### `--sweep`
- A **sweep** changes one key across multiple values, with **all other knobs at their defaults + your `--set`**.
- **Sweeps are independent** (not cross-product).  
  Use multiple `--sweep` flags; each produces its own series of runs.
- Format: `--sweep "k=v1|v2|v3"`.
  - Example: `--sweep "pkgcap=7.5|15|30"`

### `--combos`
- A **combo** is one explicit variant made from comma-separated `k=v` pairs.  
  **Semicolons** separate multiple combos.
- Format:
  - **One combo**: `--combos "k1=v1,k2=v2,k3=v3"`
  - **Many combos**: `--combos "k1=v1,k2=v2; k3=v3,k4=v4"`
- **Order of execution**: all **sweeps first**, then all **combos**.
- **Conflicts with `--set`**: allowed. You’ll get a summary and Y/N prompt to proceed.

### Repeats
- **Global**: `--repeat N` runs every variant N times, creating `1/`, `2/`, … subfolders under the variant.
- **Per-combo**: add `repeat=N` inside a combo row to override global repeat for that combo.  
  Example: `--combos "pkgcap=7.5,dramcap=10,repeat=2"`

### When a “base/” run appears
- A `base/` variant (just `--set`, nothing else) is **only created when you pass no sweeps and no combos**.
- If you do provide sweeps and/or combos, **no** `base/` run is created.

## Quick examples

### Independent sweeps with common flags
```bash
./super_run.sh \
  --runs "1" \
  --set "debug=on,short=on" \
  --sweep "pkgcap=7.5|15|30" \
  --sweep "dramcap=5|10|20" \
  --sweep "llc=15|40|80" \
  --sweep "corefreq=0.75|1.4|2.4" \
  --sweep "uncorefreq=0.75|1.5|2.5" \
  --sweep "prefetcher=0000|0011|1111"
```

## Minimal Execution Flow
1. Run the matching `startup_*.sh` once per node to provision dependencies and workspace.
2. Copy any required datasets into `/local/data` as described in the workload-specific READMEs.
3. Launch the appropriate `run_*.sh` script with the desired profiling options. Result CSVs, logs, and profiler traces will appear under `/local/data/results` and `/local/logs` for post-processing.

For bespoke automation, `scripts/process_scripts.sh` can unpack the archived startup packages and re-sync them with the latest shell scripts, helper utilities, and the `super_run.sh` orchestrator so offline nodes stay current.
