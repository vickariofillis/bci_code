#!/usr/bin/env python3
"""Convert native resctrl monitor samples into a PQoS-compatible CSV."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import math
import re
from collections import defaultdict
from pathlib import Path


def parse_int(value: str) -> int | None:
    text = str(value or "").strip()
    if not text or not re.fullmatch(r"-?\d+", text):
        return None
    return int(text)


def normalize_cpu_mask(mask: str) -> str:
    cpus: set[int] = set()
    for token in str(mask or "").replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start = int(start_text)
            end = int(end_text)
            if end < start:
                raise ValueError(f"descending CPU range: {token}")
            cpus.update(range(start, end + 1))
        else:
            cpus.add(int(token))
    return ",".join(str(cpu) for cpu in sorted(cpus))


def format_timestamp(time_ns: int) -> str:
    return dt.datetime.fromtimestamp(time_ns / 1_000_000_000.0).strftime("%Y-%m-%d %H:%M:%S.%f")


def load_rows(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            time_ns = parse_int(raw.get("time_ns", ""))
            group = str(raw.get("group", "")).strip()
            domain = str(raw.get("l3_domain", "")).strip()
            llc = parse_int(raw.get("llc_occupancy_bytes", ""))
            total = parse_int(raw.get("mbm_total_bytes", ""))
            local = parse_int(raw.get("mbm_local_bytes", ""))
            if time_ns is None or not group or not domain:
                continue
            if llc is None or total is None or local is None:
                continue
            rows.append(
                {
                    "time_ns": time_ns,
                    "group": group,
                    "domain": domain,
                    "llc": max(llc, 0),
                    "total": max(total, 0),
                    "local": max(local, 0),
                }
            )
    return rows


def aggregate_intervals(rows: list[dict[str, object]]) -> dict[tuple[int, str], dict[str, float]]:
    by_key: dict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        by_key[(str(row["group"]), str(row["domain"]))].append(row)

    aggregate: dict[tuple[int, str], dict[str, float]] = defaultdict(
        lambda: {"llc_kb": 0.0, "mbt": 0.0, "mbl": 0.0}
    )

    for (group, _domain), group_rows in by_key.items():
        group_rows.sort(key=lambda row: int(row["time_ns"]))
        previous: dict[str, object] | None = None
        for row in group_rows:
            if previous is None:
                previous = row
                continue
            time_ns = int(row["time_ns"])
            previous_time_ns = int(previous["time_ns"])
            dt_sec = (time_ns - previous_time_ns) / 1_000_000_000.0
            if dt_sec <= 0:
                previous = row
                continue

            dtotal = int(row["total"]) - int(previous["total"])
            dlocal = int(row["local"]) - int(previous["local"])
            if dtotal < 0 or dlocal < 0:
                previous = row
                continue

            bucket = aggregate[(time_ns, group)]
            bucket["llc_kb"] += int(row["llc"]) / 1024.0
            bucket["mbt"] += dtotal / dt_sec / 1_000_000.0
            bucket["mbl"] += dlocal / dt_sec / 1_000_000.0
            previous = row

    return aggregate


def write_pqos_shim(
    output: Path,
    aggregate: dict[tuple[int, str], dict[str, float]],
    workload_cpus: str,
    system_cpus: str,
) -> int:
    output.parent.mkdir(parents=True, exist_ok=True)
    timestamps = sorted({time_ns for time_ns, _group in aggregate})
    rows_written = 0
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Time", "Core", "IPC", "LLC Misses", "LLC[KB]", "MBL[MB/s]", "MBR[MB/s]", "MBT[MB/s]", "Source"])
        for time_ns in timestamps:
            for group, cpus in (("workload", workload_cpus), ("system", system_cpus)):
                metrics = aggregate.get((time_ns, group))
                if not metrics:
                    continue
                mbt = max(float(metrics["mbt"]), 0.0)
                mbl = max(float(metrics["mbl"]), 0.0)
                mbr = max(mbt - mbl, 0.0)
                llc_kb = float(metrics["llc_kb"])
                if not all(math.isfinite(value) for value in (mbt, mbl, mbr, llc_kb)):
                    continue
                writer.writerow(
                    [
                        format_timestamp(time_ns),
                        cpus,
                        "NA",
                        "NA",
                        f"{llc_kb:.3f}",
                        f"{mbl:.6f}",
                        f"{mbr:.6f}",
                        f"{mbt:.6f}",
                        "resctrl",
                    ]
                )
                rows_written += 1
    return rows_written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workload-cpus", required=True)
    parser.add_argument("--system-cpus", required=True)
    args = parser.parse_args()

    workload_cpus = normalize_cpu_mask(args.workload_cpus)
    system_cpus = normalize_cpu_mask(args.system_cpus)
    rows = load_rows(args.input)
    aggregate = aggregate_intervals(rows)
    written = write_pqos_shim(args.output, aggregate, workload_cpus, system_cpus)
    if written == 0:
        raise SystemExit("no PQoS-compatible rows were generated from resctrl monitor data")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
