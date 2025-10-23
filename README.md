# BCI Code Workloads

## Workload Index
- **ID1: Seizure Detection (Laelaps)** – C/OpenMP implementation that classifies intracranial EEG segments with hyperdimensional computing primitives.
- **ID3: Neuropixels Compression Benchmarks** – Python pipelines that compress Neuropixels recordings and optionally run spike-sorting evaluations to assess codec impact.
- **ID13: Movement Intent Analysis** – MATLAB workflow that prepares FieldTrip inputs, performs IRASA and spectral analysis, and summarizes motor imagery power spectra.
- **ID20: Speech Decoder (3-gram WFST + RNN + LLM variants)** – Python components that run the recurrent acoustic model, WFST language model, and optional LLM rescoring across dedicated run scripts (`run_20_3gram_{lm,llm,rnn}.sh`).

## Repository Layout
- `id_*/` – Source trees for the workloads listed above. Each subdirectory contains its own README with algorithm details and logging phases.
- `scripts/` – Provisioning (`startup_*.sh`) and execution (`run_*.sh`) helpers plus compressed archives for distribution to CloudLab nodes.
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

## Minimal Execution Flow
1. Run the matching `startup_*.sh` once per node to provision dependencies and workspace.
2. Copy any required datasets into `/local/data` as described in the workload-specific READMEs.
3. Launch the appropriate `run_*.sh` script with the desired profiling options. Result CSVs, logs, and profiler traces will appear under `/local/data/results` and `/local/logs` for post-processing.

For bespoke automation, `scripts/process_scripts.sh` can unpack the archived startup packages and re-sync them with the latest shell scripts.
