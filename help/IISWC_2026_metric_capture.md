# IISWC 2026 Metric Capture Plan

This note documents the explicit no-multiplex collector plan implemented in the
run/orchestration scripts for the IISWC 2026 campaign.

## Explicit collector set

Request these collectors explicitly:

- `toplev-execution`
- `perf-stat`
- `pcm`
- `pcm-memory`
- `pcm-power`
- `pcm-pcie`

`--short` expands to the same set plus `toplev-basic`.

`--long` expands to all tools: `toplev-basic`, `toplev-execution`,
`toplev-full`, `perf-stat`, `maya`, `pcm`, `pcm-memory`, `pcm-power`, and
`pcm-pcie`.

The legacy default remains unchanged when no profiling flags are provided:
`toplev-basic`, `toplev-execution`, `toplev-full`, `maya`, and all PCM tools.

## Metric availability map

| Target evidence | Already captured | Current / added source | Consolidated without multiplexing | Extra workload execution | c6620 validation |
| --- | --- | --- | --- | --- | --- |
| Runtime, throughput basis | Yes | Existing workload phase/runtime logs and `phases.log` | Yes | No | Existing path preserved |
| Parallel efficiency inputs | Yes | Existing thread-count metadata plus runtime logs | Yes | No | Metadata updated |
| Top-down shift | Yes | `toplev-execution` (`Frontend Bound`, `Bad Speculation`, `Backend Bound`, `Retiring`) | Yes | No | `toplev -l1` one pass, `MUX=100.0` |
| Backend / memory subcomponents | Yes when the rich metric set is available | `toplev-basic` rich metric output | Yes | No additional collector beyond `toplev-basic` | c6620 rich metric set validated via `--force-cpu spr` |
| Memory read / write pressure | Yes | `pcm-memory` bandwidth fields | Yes | No | Existing PCM path preserved |
| Store pressure | Yes | `toplev-basic` rich metric `Store_Bound` / `IpStore`; added `perf-stat` `mem_inst_retired.all_stores` as extra density evidence | Yes | One shared `perf-stat` pass | Both sources validated on c6620 |
| Branch density / misses | Partial | Existing `IpBranch` for density; added `perf-stat` `br_inst_retired.all_branches` and `br_misp_retired.all_branches` | Yes | One shared `perf-stat` pass | Branch microbench produced large retired-branch and mispredict counts |
| DTLB / ITLB page walks | No | Added `perf-stat` `dtlb_load_misses.walk_completed`, `dtlb_store_misses.walk_completed`, `itlb_misses.walk_completed` | Yes | One shared `perf-stat` pass | Load/store page-walk microbenches responded strongly |
| Scalar vs vector FP evidence | No | Added `perf-stat` `fp_arith_inst_retired.scalar`, `fp_arith_inst_retired.vector` | Yes | One shared `perf-stat` pass | Scalar bench raised scalar counts; vector bench raised vector counts |
| Prefetch regularity | Partial | Existing `--prefetcher` A/B control + runtime/topdown/bandwidth; prefetch state now logged in sidecar | Yes | No new pass by default | Prefetch state set/restore path retained and logged |
| CPU / uncore frequency, package / DRAM energy, power, thermal | Yes | Existing `pcm` and `pcm-power` outputs | Yes | No | Existing PCM path preserved |
| PCIe sanity | Yes | Existing `pcm-pcie` outputs | Yes | No | Existing PCM path preserved |

## Added perf-stat collector

`perf-stat` runs one non-multiplexed raw `perf stat -x,` pass with:

- `instructions`
- `br_inst_retired.all_branches`
- `br_misp_retired.all_branches`
- `mem_inst_retired.all_stores`
- `dtlb_load_misses.walk_completed`
- `dtlb_store_misses.walk_completed`
- `itlb_misses.walk_completed`
- `fp_arith_inst_retired.scalar`
- `fp_arith_inst_retired.vector`

Immediately after that collector run finishes, the run scripts:

1. summarize unsupported, dropped, missing, and runtime-coverage status into
   `${RESULT_PREFIX}_perf_stat_summary.env`
2. convert `${RESULT_PREFIX}_perf_stat_raw.csv` into
   `${RESULT_PREFIX}_perf_stat.csv`

The enriched `${RESULT_PREFIX}_perf_stat.csv` contains these derived columns:

- `branch_mpki`
- `branch_miss_rate`
- `branch_density`
- `store_density`
- `dtlb_load_walks_per_million_instructions`
- `dtlb_store_walks_per_million_instructions`
- `itlb_walks_per_million_instructions`
- `fp_scalar_density`
- `fp_vector_density`
- `fp_vector_to_scalar_ratio`

The run scripts fail the collector if the pass reports unsupported events,
missing events, dropped events, or multiplexed / indeterminate runtime coverage.

## Workload run count per collector

| Collector | Workload executions per invocation | Notes |
| --- | --- | --- |
| `toplev-execution` | 1 | Validated one-pass on c6620 with `MUX=100.0` |
| `perf-stat` | 1 | Validated one-pass on c6620 with `100.00` runtime coverage for every requested event |
| `pcm` | 1 | Existing single workload pass |
| `pcm-memory` | 1 | Existing single workload pass |
| `pcm-power` | 3 | Existing pass 1 = `pcm-power`, pass 2 = `pcm-memory -nc`, pass 3 = `pqos` MBM attribution |
| `pcm-pcie` | 1 | Existing single workload pass |
| `maya` | 1 | Existing single workload pass |
| `toplev-basic` | Platform-dependent; validate the actual Toplev mode | On nodes where Toplev recognizes the CPU model directly, the configured rich mode uses the normal rich collector path and the scripts record the observed internal run count from the CSV. On c6620, the validated rich metric path uses `FORCEHT=1`, `--force-cpu spr`, `-a`, `-A`, `--per-thread`, and `--columns`, and relaunches the workload 4 times internally with `Multiplex=100.0` while emitting wide per-CPU `C*` / `C*-T*` columns |
| `toplev-full` | Tool-dependent multi-pass / remeasurement | Diagnostic only; not part of the default campaign shorthand |

Current `--short` run count on c6620:

- `toplev-basic`: 4
- `toplev-execution`: 1
- `perf-stat`: 1
- `pcm`: 1
- `pcm-memory`: 1
- `pcm-power`: 3
- `pcm-pcie`: 1
- total `--short` workload launches on c6620: 12

## c6620 validation summary

Validation was run on c6620-class Intel hardware (`Intel Xeon Gold 5512U`,
CloudLab experiment `c6s20xk5`, node `er102.utah.cloudlab.us`).

- `toplev-execution` (`-l1`) completed in one pass and exposed the required
  top-down columns with `MUX=100.0`.
- `toplev-basic` rich metrics are available on c6620 through a different
  Toplev invocation than the older nodes use. The validated working form is:
  `FORCEHT=1 --force-cpu spr -l3 -v --no-multiplex -a -A --per-thread --columns --nodes
  !Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore -m -x,`
  attached to the workload command.
- That c6620 `toplev-basic` rich path relaunched the workload 4 times and
  emitted the same richer metric family, including `Instructions`, `CPI`,
  `L1MPKI`, `L2MPKI`, `L3MPKI`, `IpLoad`, `IpStore`, `IpBranch`, `IpCall`,
  `Backend_Bound.Memory_Bound`, `DRAM_Bound`, `L1_Bound`, `L2_Bound`,
  `L3_Bound`, and `Store_Bound`, in a wide per-CPU CSV with `C*` / `C*-T*`
  columns compatible with the existing cleaning pipeline.
- The successful c6620 rich `toplev-basic` CSV reported `Multiplex=100.0` /
  `[100.0%]` across the emitted metrics.
- SST-enabled validation on c6620 still produced the expected wide per-CPU
  CSV shape while distinguishing high-priority and low-priority CPUs in the
  underlying system configuration.
- The `perf-stat` collector collected all requested events together in
  one pass with `100.00` runtime coverage per event.
- Branch validation: a branch-heavy microbenchmark produced high
  `br_inst_retired.all_branches` and `br_misp_retired.all_branches`.
- TLB validation: load- and store-heavy page-walk microbenchmarks produced high
  `dtlb_load_misses.walk_completed` and `dtlb_store_misses.walk_completed`.
- FP/vector validation: scalar arithmetic raised
  `fp_arith_inst_retired.scalar`; vector arithmetic raised
  `fp_arith_inst_retired.vector`.

## Metadata recorded per run

Each run now emits `${RESULT_PREFIX}_collector_metadata.json` with:

- platform / hostname
- workload id and mode
- hardware configuration label
- thread count
- workload and tool CPU masks
- SMT policy
- collector selection mode
- placement metadata pointer
- prefetch-state pointer when used
- requested metric families
- per-collector tool version, command summary, output files, computed derived metrics,
  unsupported metrics, dropped metrics, and multiplexing status
