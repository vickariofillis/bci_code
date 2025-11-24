#!/usr/bin/env python3
import bisect
import csv
import datetime
import math
import os
import re
import statistics
import tempfile
import time
from pathlib import Path

EPS = 1e-9
DEFAULT_INTERVAL = 0.5
ALIGN_TOLERANCE_SEC = 0.40
DATETIME_FORMATS = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")


def read_interval(name, fallback):
    raw = os.environ.get(name)
    if raw is None:
        return fallback
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return fallback
    return value if value > EPS else fallback


PCM_POWER_INTERVAL_SEC = read_interval("PCM_POWER_INTERVAL_SEC", DEFAULT_INTERVAL)
PQOS_INTERVAL_SEC = read_interval("PQOS_INTERVAL_SEC", PCM_POWER_INTERVAL_SEC)
TURBOSTAT_INTERVAL_SEC = read_interval("TS_INTERVAL", DEFAULT_INTERVAL)
DELTA_T_SEC = PCM_POWER_INTERVAL_SEC


def log(msg):
    print(f"[attrib] {msg}")


def warn(msg):
    print(f"[attrib][WARN] {msg}")


def error(msg):
    print(f"[attrib][ERROR] {msg}")


def ok(msg):
    print(f"[attrib][OK] {msg}")


def parse_datetime(text):
    cleaned = text.strip()
    for fmt in DATETIME_FORMATS:
        try:
            dt = datetime.datetime.strptime(cleaned, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    raise ValueError(f"unable to parse datetime '{text}'")


def parse_pcm_timestamp(date_text, time_text, previous):
    combined = f"{date_text.strip()} {time_text.strip()}".strip()
    if not combined:
        if previous is not None:
            return previous + DELTA_T_SEC, True
        return 0.0, True
    try:
        return parse_datetime(combined), False
    except ValueError:
        if previous is not None:
            return previous + DELTA_T_SEC, True
        return 0.0, True


def try_parse_pqos_time(time_text):
    cleaned = time_text.strip()
    if not cleaned:
        return None
    try:
        return parse_datetime(cleaned)
    except ValueError:
        return None


def safe_float(value):
    if value is None:
        return math.nan
    text = str(value).strip()
    if not text:
        return math.nan
    try:
        return float(text)
    except ValueError:
        return math.nan


def clamp01(value):
    return max(0.0, min(1.0, value))


def compute_elapsed_series(values):
    if not values:
        return []
    origin = values[0]
    return [value - origin for value in values]


def atomic_write_csv(path, header, rows):
    parent = Path(path).parent
    parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=str(parent), newline="")
    try:
        with tmp:
            writer = csv.writer(tmp)
            writer.writerow(header)
            writer.writerows(rows)
        if os.path.getsize(tmp.name) == 0:
            raise IOError("temporary attrib file is empty")
        os.replace(tmp.name, path)
        with open(path, "r+") as f:
            os.fsync(f.fileno())
    finally:
        try:
            os.unlink(tmp.name)
        except FileNotFoundError:
            pass


def normalize_entry_times(entries, key):
    if not entries:
        return
    origin = entries[0].get(key)
    if origin is None:
        return
    for entry in entries:
        value = entry.get(key)
        if value is None:
            continue
        entry[key] = value - origin


def fill_series(raw_values):
    n = len(raw_values)
    if n == 0:
        return [], 0
    if all(v is None for v in raw_values):
        return [0.0] * n, 0
    forward = [None] * n
    prev = None
    for idx, value in enumerate(raw_values):
        if value is not None:
            prev = value
        forward[idx] = prev
    backward = [None] * n
    nxt = None
    for idx in range(n - 1, -1, -1):
        value = raw_values[idx]
        if value is not None:
            nxt = value
        backward[idx] = nxt
    result = []
    interpolated = 0
    for idx, value in enumerate(raw_values):
        if value is not None:
            result.append(max(0.0, value))
            continue
        fwd = forward[idx]
        bwd = backward[idx]
        if fwd is not None and bwd is not None:
            interpolated += 1
            result.append(max(0.0, 0.5 * (fwd + bwd)))
        elif fwd is not None:
            result.append(max(0.0, fwd))
        elif bwd is not None:
            result.append(max(0.0, bwd))
        else:
            result.append(0.0)
    return result, interpolated


def take_first(values, count=3):
    return [round(v, 3) for v in values[:count]]


def take_last(values, count=3):
    if not values:
        return []
    return [round(v, 3) for v in values[-count:]]


def is_numeric(cell):
    text = str(cell).strip()
    if not text:
        return False
    try:
        float(text)
        return True
    except ValueError:
        return False


def select_entry(times, entries, window_start, window_end, window_center, tolerance):
    if not times:
        return None, False, False
    idx = bisect.bisect_left(times, window_start)
    if idx < len(times) and times[idx] < window_end:
        return entries[idx], True, False
    candidates = []
    if idx < len(times):
        candidates.append(idx)
    if idx > 0:
        candidates.append(idx - 1)
    if not candidates:
        return None, False, False
    best_idx = None
    best_diff = None
    for candidate in candidates:
        diff = abs(times[candidate] - window_center)
        if best_diff is None or diff < best_diff:
            best_idx = candidate
            best_diff = diff
    if best_idx is not None and best_diff is not None and best_diff <= tolerance:
        return entries[best_idx], False, True
    return None, False, False


def flatten_headers(header1, header2):
    width = max(len(header1), len(header2))
    result = []
    for idx in range(width):
        top = header1[idx].strip() if idx < len(header1) and header1[idx] else ""
        bottom = header2[idx].strip() if idx < len(header2) and header2[idx] else ""
        pieces = [piece for piece in (top, bottom) if piece]
        label = " ".join(pieces).strip()
        if not label:
            result.append("")
            continue
        label = re.sub(r"\s+", " ", label)
        if label.lower().startswith("system "):
            label = re.sub(r"\s*\(.*?\)\s*$", "", label)
        result.append(label)
    return result


def try_parse_pcm_memory_timestamp(date_text, time_text):
    combined = f"{date_text.strip()} {time_text.strip()}".strip()
    if not combined:
        return None
    for fmt in DATETIME_FORMATS:
        try:
            dt = datetime.datetime.strptime(combined, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    return None


def drop_initial_pcm_memory_outliers(entries):
    if len(entries) < 2:
        return entries
    result = entries[:]
    dropped = 0
    while len(result) >= 2 and dropped < 2:
        tail_values = [entry["value"] for entry in result[1:] if entry["value"] > 0.0]
        if len(tail_values) < 4:
            break
        tail_values.sort()
        perc_index = max(0, min(len(tail_values) - 1, math.ceil(0.95 * len(tail_values)) - 1))
        perc95 = tail_values[perc_index]
        if perc95 <= 0.0:
            break
        first_value = result[0]["value"]
        if first_value > 50.0 * perc95:
            log(
                "pcm-memory: dropping initial outlier sample value={:.3f}, threshold={:.3f}".format(
                    first_value, perc95
                )
            )
            result.pop(0)
            dropped += 1
            continue
        break
    return result


def filter_pcm_memory_entries(entries, turbostat_times, pqos_times):
    if not entries:
        return entries
    bounds = []
    if turbostat_times:
        bounds.append((min(turbostat_times), max(turbostat_times)))
    if pqos_times:
        bounds.append((min(pqos_times), max(pqos_times)))
    if len(bounds) < 2:
        return entries
    start = max(b[0] for b in bounds)
    end = min(b[1] for b in bounds)
    if start > end:
        return entries
    lower = start - ALIGN_TOLERANCE_SEC
    upper = end + ALIGN_TOLERANCE_SEC
    filtered = [entry for entry in entries if lower <= entry["time"] <= upper]
    if len(filtered) != len(entries):
        log(
            "pcm-memory: trimmed samples to active window (before={}, after={})".format(
                len(entries), len(filtered)
            )
        )
    return filtered


def pqos_entries_for_window(times, entries, window_start, window_end, interval):
    if not entries:
        return []
    left = bisect.bisect_left(times, window_start)
    right = bisect.bisect_right(times, window_end)
    idx_start = max(0, left - 1)
    idx_end = min(len(entries), right + 1)
    selected = []
    for idx in range(idx_start, idx_end):
        sample = entries[idx]
        sigma = sample.get("sigma")
        if sigma is None:
            continue
        sample_start = sigma - interval
        sample_end = sigma
        if sample_end > window_start and sample_start < window_end:
            selected.append(sample)
    if not selected and left < len(entries):
        sample = entries[left]
        sigma = sample.get("sigma")
        if sigma is not None:
            sample_start = sigma - interval
            sample_end = sigma
            if sample_end > window_start and sample_start < window_end:
                selected.append(sample)
    return selected


def average_mbl_components(samples, workload_core_set):
    if not samples:
        return 0.0, 0.0, 0
    core_total = 0.0
    bandwidth_total = 0.0
    count = 0
    for sample in samples:
        core_sum = 0.0
        total_sum = 0.0
        for entry in sample.get("rows", []):
            value = max(entry.get("mb", 0.0), 0.0)
            total_sum += value
            if entry["core"] == workload_core_set:
                core_sum += value
        core_total += core_sum
        bandwidth_total += total_sum
        count += 1
    if count == 0:
        return 0.0, 0.0, 0
    return core_total / count, bandwidth_total / count, count


def main():
    outdir = os.environ.get("OUTDIR")
    idtag = os.environ.get("IDTAG")
    workload_cpu_str = os.environ.get("WORKLOAD_CPU", "0")
    try:
        workload_cpu = int(workload_cpu_str)
    except ValueError:
        workload_cpu = 0
    workload_core_set = frozenset({workload_cpu})

    if not outdir or not idtag:
        error("OUTDIR or IDTAG not set; skipping attribution step")
        return

    base_dir = Path(outdir)
    result_prefix = os.environ.get("RESULT_PREFIX")
    pfx_source = result_prefix or idtag or "id_X"
    pfx = os.path.basename(pfx_source)

    def build_prefix_path(suffix: str) -> Path:
        if result_prefix:
            return Path(f"{result_prefix}{suffix}")
        return base_dir / f"{idtag}{suffix}"

    pcm_path = build_prefix_path("_pcm_power.csv")
    turbostat_path = build_prefix_path("_turbostat.csv")
    pqos_path = base_dir / f"{pfx}_pqos.csv"
    pcm_memory_path = base_dir / f"{pfx}_pcm_memory_dram.csv"
    attrib_path = build_prefix_path("_attrib.csv")

    log(
        "files: pcm={} ({}), turbostat={} ({}), pqos={} ({}), pcm-memory={} ({})".format(
            pcm_path,
            "exists" if pcm_path.exists() else "missing",
            turbostat_path,
            "exists" if turbostat_path.exists() else "missing",
            pqos_path,
            "exists" if pqos_path.exists() else "missing",
            pcm_memory_path,
            "exists" if pcm_memory_path.exists() else "missing",
        )
    )
    log(
        "intervals: pcm={:.4f}s, pqos={:.4f}s, turbostat={:.4f}s, pcm-memory(sidecar)={:.4f}s".format(
            PCM_POWER_INTERVAL_SEC,
            PQOS_INTERVAL_SEC,
            TURBOSTAT_INTERVAL_SEC,
            PCM_POWER_INTERVAL_SEC,
        )
    )

    if not pcm_path.exists():
        error(f"pcm-power CSV missing at {pcm_path}; aborting attribution")
        return

    with open(pcm_path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        error("pcm-power CSV missing headers or data; aborting attribution")
        return

    header1 = list(rows[0])
    header2 = list(rows[1])
    data_rows = [list(row) for row in rows[2:]]
    row_count = len(data_rows)

    log(f"header lengths: top={len(header1)}, bottom={len(header2)}")
    tail_preview = header2[-4:] if len(header2) >= 4 else header2[:]
    log(f"header2 last4: {tail_preview}")
    watts_idx_pre = [idx for idx, name in enumerate(header2) if name.strip() == "Watts"]
    dram_idx_pre = [idx for idx, name in enumerate(header2) if name.strip() == "DRAM Watts"]
    log(
        "header index pre: Watts={}, DRAM Watts={}".format(
            watts_idx_pre[-1] if watts_idx_pre else "NA",
            dram_idx_pre[-1] if dram_idx_pre else "NA",
        )
    )

    ghost_ratio = 0.0
    ghost = False
    if header1 and header2 and header1[-1] == "" and header2[-1] == "":
        empty_cells = 0
        for row in data_rows:
            if not row or row[-1] == "":
                empty_cells += 1
        ghost_ratio = empty_cells / row_count if row_count else 1.0
        ghost = ghost_ratio >= 0.95
    log(f"ghost column detected: {'yes' if ghost else 'no'} (empty_ratio={ghost_ratio:.3f})")

    if ghost:
        header1 = header1[:-1]
        header2 = header2[:-1]
        data_rows = [row[:-1] if row else [] for row in data_rows]

    target_len = max(len(header1), len(header2))
    if len(header1) < target_len:
        header1.extend([""] * (target_len - len(header1)))
    if len(header2) < target_len:
        header2.extend([""] * (target_len - len(header2)))
    target_len = len(header2)
    for row in data_rows:
        if len(row) < target_len:
            row.extend([""] * (target_len - len(row)))
        elif len(row) > target_len:
            del row[target_len:]

    existing_actual_indices = [idx for idx, name in enumerate(header2) if name.strip() in ("Actual Watts", "Actual DRAM Watts")]
    removed_existing = len(existing_actual_indices)
    if removed_existing:
        for idx in sorted(existing_actual_indices, reverse=True):
            del header1[idx]
            del header2[idx]
            for row in data_rows:
                if len(row) > idx:
                    del row[idx]

    target_len = len(header2)
    for row in data_rows:
        if len(row) < target_len:
            row.extend([""] * (target_len - len(row)))
        elif len(row) > target_len:
            del row[target_len:]

    power_header1 = header1[:]
    power_header2 = header2[:]
    power_data = [row[:] for row in data_rows]

    watts_indices = [idx for idx, name in enumerate(header2) if name.strip() == "Watts"]
    dram_indices = [idx for idx, name in enumerate(header2) if name.strip() == "DRAM Watts"]
    if not watts_indices or not dram_indices:
        error("required Watts or DRAM Watts column missing after normalization; aborting attribution")
        return
    watts_idx = watts_indices[-1]
    dram_idx = dram_indices[-1]

    def find_column(name):
        for idx, value in enumerate(header2):
            if value == name:
                return idx
        return None

    date_idx = find_column("Date")
    time_idx = find_column("Time")
    if date_idx is None or time_idx is None:
        error("Date/Time columns not found in pcm-power CSV; aborting attribution")
        return

    log(f"writeback: watts_idx={watts_idx}, dram_idx={dram_idx}, removed_existing={removed_existing}")

    pcm_times = []
    pkg_powers = []
    dram_powers = []
    timestamp_fallbacks = 0
    previous_timestamp = None
    for row in data_rows:
        date_value = row[date_idx] if date_idx < len(row) else ""
        time_value = row[time_idx] if time_idx < len(row) else ""
        timestamp, used_fallback = parse_pcm_timestamp(date_value, time_value, previous_timestamp)
        if used_fallback:
            timestamp_fallbacks += 1
        pcm_times.append(timestamp)
        previous_timestamp = timestamp
        pkg_value = safe_float(row[watts_idx]) if watts_idx < len(row) else math.nan
        dram_value = safe_float(row[dram_idx]) if dram_idx < len(row) else math.nan
        pkg_powers.append(0.0 if math.isnan(pkg_value) else max(pkg_value, 0.0))
        dram_powers.append(0.0 if math.isnan(dram_value) else max(dram_value, 0.0))

    if timestamp_fallbacks:
        log(f"pcm timestamp fallbacks applied={timestamp_fallbacks}")

    pcm_times = compute_elapsed_series(pcm_times)

    turbostat_blocks = []
    if turbostat_path.exists():
        with open(turbostat_path, newline="") as f:
            reader = csv.DictReader(f)
            tstat_rows = []
            for row in reader:
                try:
                    cpu = int((row.get("CPU") or "").strip())
                    busy = float((row.get("Busy%") or "").strip())
                    bzy = float((row.get("Bzy_MHz") or "").strip())
                    tod = float((row.get("Time_Of_Day_Seconds") or "").strip())
                except (ValueError, AttributeError):
                    continue
                tstat_rows.append({"cpu": cpu, "busy": busy, "bzy": bzy, "time": tod})
        if tstat_rows:
            cpu_ids = sorted({entry["cpu"] for entry in tstat_rows})
            n_cpus = len(cpu_ids)
            if n_cpus:
                index = 0
                total_rows = len(tstat_rows)
                while index + n_cpus <= total_rows:
                    block_rows = tstat_rows[index : index + n_cpus]
                    index += n_cpus
                    cpu_in_block = {entry["cpu"] for entry in block_rows}
                    if len(cpu_in_block) < max(1, math.ceil(0.8 * n_cpus)):
                        continue
                    tau = statistics.median(entry["time"] for entry in block_rows)
                    turbostat_blocks.append({"tau": tau, "rows": block_rows})

    if turbostat_blocks:
        normalize_entry_times(turbostat_blocks, "tau")

    pqos_entries_raw = []
    pqos_field = None
    pcm_memory_entries = []
    if pqos_path.exists():
        with open(pqos_path, newline="") as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames or []
            mbt_pattern = re.compile(r"mbt.*mb/s", re.IGNORECASE)
            mbl_pattern = re.compile(r"mbl.*mb/s", re.IGNORECASE)
            for name in fieldnames:
                if mbt_pattern.search(name):
                    pqos_field = name
                    break
            if pqos_field is None:
                for name in fieldnames:
                    if mbl_pattern.search(name):
                        pqos_field = name
                        break
            if pqos_field is None:
                error("pqos MB* column not found; skipping pqos attribution")
            else:
                log(f"pqos bandwidth column selected: {pqos_field}")
                for row in reader:
                    time_value = row.get("Time")
                    core_value = row.get("Core")
                    if time_value is None or core_value is None:
                        continue
                    mb_value = safe_float(row.get(pqos_field))
                    if math.isnan(mb_value):
                        continue
                    core_clean = core_value.replace('"', "").strip()
                    core_clean = core_clean.replace("[", "").replace("]", "")
                    core_clean = core_clean.replace("{", "").replace("}", "")
                    if not core_clean:
                        continue
                    core_set = set()
                    for part in core_clean.split(","):
                        part = part.strip()
                        if not part:
                            continue
                        if ":" in part:
                            part = part.split(":", 1)[1].strip()
                        if not part:
                            continue
                        if "-" in part:
                            start_str, end_str = part.split("-", 1)
                            try:
                                start = int(start_str.strip())
                                end = int(end_str.strip())
                            except ValueError:
                                continue
                            if start <= end:
                                core_set.update(range(start, end + 1))
                            else:
                                core_set.update(range(end, start + 1))
                        else:
                            try:
                                core_set.add(int(part))
                            except ValueError:
                                continue
                    if not core_set:
                        continue
                    pqos_entries_raw.append({
                        "time": time_value.strip(),
                        "core": frozenset(core_set),
                        "mb": max(mb_value, 0.0),
                    })

    if pcm_memory_path.exists():
        with open(pcm_memory_path, newline="") as f:
            pcm_rows = list(csv.reader(f))
        if len(pcm_rows) >= 2:
            mem_header_top = pcm_rows[0]
            mem_header_bot = pcm_rows[1] if len(pcm_rows) > 1 else []
            flat_headers = flatten_headers(mem_header_top, mem_header_bot)
            multi_header_detected = any(cell.strip() for cell in mem_header_top) and any(
                cell.strip() for cell in mem_header_bot
            )
            system_idx = None
            system_label = None
            for idx, name in enumerate(flat_headers):
                if name.strip().lower() == "system memory":
                    system_idx = idx
                    system_label = name.strip() or "System Memory"
                    break
            if system_idx is None:
                for idx, name in enumerate(flat_headers):
                    lowered = name.strip().lower()
                    if not lowered:
                        continue
                    if "system" in lowered and "memory" in lowered and "skt" not in lowered:
                        system_idx = idx
                        system_label = name.strip() or "System Memory"
                        break
            date_idx = next(
                (idx for idx, name in enumerate(flat_headers) if name.strip().lower() == "date"),
                None,
            )
            time_idx = next(
                (idx for idx, name in enumerate(flat_headers) if name.strip().lower() == "time"),
                None,
            )
            if system_idx is None:
                warn("pcm-memory System Memory column not found")
            elif date_idx is None or time_idx is None:
                warn("pcm-memory Date/Time columns not found")
            else:
                if multi_header_detected and system_label:
                    log(f"pcm-memory: multi-row header detected; using '{system_label}'")
                parsed_entries = []
                for row in pcm_rows[2:]:
                    if len(row) <= system_idx:
                        continue
                    raw_value = row[system_idx] if system_idx < len(row) else ""
                    value = safe_float(raw_value)
                    if math.isnan(value):
                        continue
                    date_value = row[date_idx] if date_idx < len(row) else ""
                    time_value = row[time_idx] if time_idx < len(row) else ""
                    sigma = try_parse_pcm_memory_timestamp(date_value, time_value)
                    if sigma is None:
                        continue
                    parsed_entries.append({"time": sigma, "value": max(value, 0.0)})
                parsed_entries.sort(key=lambda entry: entry["time"])
                pcm_memory_entries.extend(drop_initial_pcm_memory_outliers(parsed_entries))
        log(f"pcm-memory samples parsed: {len(pcm_memory_entries)}")

    if pcm_memory_entries:
        pcm_memory_entries.sort(key=lambda entry: entry["time"])
        normalize_entry_times(pcm_memory_entries, "time")

    pqos_samples = []
    current_sample = None
    current_time = None
    seen_cores = set()
    for entry in pqos_entries_raw:
        time_value = entry["time"]
        core_set = entry["core"]
        if current_sample is None:
            current_sample = {"time": time_value, "rows": []}
            current_time = time_value
            seen_cores = set()
        else:
            if time_value != current_time:
                pqos_samples.append(current_sample)
                current_sample = {"time": time_value, "rows": []}
                current_time = time_value
                seen_cores = set()
            elif core_set in seen_cores:
                pqos_samples.append(current_sample)
                current_sample = {"time": time_value, "rows": []}
                current_time = time_value
                seen_cores = set()
        current_sample["rows"].append(entry)
        seen_cores.add(core_set)
    if current_sample is not None:
        pqos_samples.append(current_sample)

    has_subseconds = any("." in sample["time"].split()[-1] for sample in pqos_samples) if pqos_samples else False
    if pqos_samples:
        if has_subseconds:
            for sample in pqos_samples:
                sample["sigma"] = try_parse_pqos_time(sample["time"])
        else:
            base_time = try_parse_pqos_time(pqos_samples[0]["time"])
            if base_time is None:
                base_time = 0.0
            for idx, sample in enumerate(pqos_samples):
                sample["sigma"] = base_time + idx * PQOS_INTERVAL_SEC

    pqos_entries = [sample for sample in pqos_samples if sample.get("sigma") is not None]
    if pqos_entries:
        normalize_entry_times(pqos_entries, "sigma")
    pqos_times = [sample["sigma"] for sample in pqos_entries]
    turbostat_times = [block["tau"] for block in turbostat_blocks]
    if pcm_memory_entries:
        pcm_memory_entries = filter_pcm_memory_entries(pcm_memory_entries, turbostat_times, pqos_times)
    pcm_memory_times = [entry["time"] for entry in pcm_memory_entries]
    pcm_memory_values = [entry["value"] for entry in pcm_memory_entries]

    cpu_share_raw = []
    pqos_core_raw = []
    pqos_total_raw = []
    system_memory_raw = []
    ts_in_window = ts_near = ts_miss = 0
    pqos_in_window = pqos_near = pqos_miss = 0
    system_in_window = system_near = system_miss = 0
    pqos_bandwidth_core_sum = 0.0
    pqos_bandwidth_other_sum = 0.0
    pqos_bandwidth_total_sum = 0.0
    pqos_bandwidth_sample_count = 0
    pqos_data_available = False
    system_data_available = False
    force_pkg_zero = not turbostat_times
    force_pqos_zero = not pqos_times
    force_system_zero = not pcm_memory_times

    ts_tolerance = max(PCM_POWER_INTERVAL_SEC, TURBOSTAT_INTERVAL_SEC) * 0.80
    pqos_tolerance = ALIGN_TOLERANCE_SEC
    pcm_memory_tolerance = ALIGN_TOLERANCE_SEC

    for idx, window_start in enumerate(pcm_times):
        window_end = window_start + DELTA_T_SEC
        window_center = window_start + 0.5 * DELTA_T_SEC

        if force_pkg_zero:
            cpu_share_raw.append(0.0)
            ts_miss += 1
        else:
            block, in_window, near = select_entry(
                turbostat_times,
                turbostat_blocks,
                window_start,
                window_end,
                window_center,
                ts_tolerance,
            )
            if block is None:
                cpu_share_raw.append(None)
                ts_miss += 1
            else:
                if in_window:
                    ts_in_window += 1
                elif near:
                    ts_near += 1
                total_busy = 0.0
                workload_busy = 0.0
                for entry in block["rows"]:
                    busy = max(entry["busy"], 0.0)
                    total_busy += busy
                    if entry["cpu"] == workload_cpu:
                        workload_busy = busy
                fraction = clamp01(workload_busy / total_busy) if total_busy > EPS else 0.0
                cpu_share_raw.append(fraction)

        if force_pqos_zero:
            pqos_core_raw.append(0.0)
            pqos_total_raw.append(0.0)
            pqos_miss += 1
        else:
            selected_samples = pqos_entries_for_window(
                pqos_times,
                pqos_entries,
                window_start,
                window_end,
                PQOS_INTERVAL_SEC,
            )
            sample_entries = None
            if selected_samples:
                pqos_in_window += 1
                sample_entries = selected_samples
            else:
                sample, in_window, near = select_entry(
                    pqos_times,
                    pqos_entries,
                    window_start,
                    window_end,
                    window_center,
                    pqos_tolerance,
                )
                if sample is None:
                    pqos_core_raw.append(None)
                    pqos_total_raw.append(None)
                    pqos_miss += 1
                else:
                    if in_window:
                        pqos_in_window += 1
                    elif near:
                        pqos_near += 1
                    sample_entries = [sample]
            if sample_entries is not None:
                core_bandwidth, total_bandwidth, sample_count = average_mbl_components(
                    sample_entries, workload_core_set
                )
                if sample_count:
                    pqos_data_available = True
                    core_bandwidth = max(core_bandwidth, 0.0)
                    total_bandwidth = max(total_bandwidth, 0.0)
                    other_bandwidth = max(total_bandwidth - core_bandwidth, 0.0)
                    pqos_core_raw.append(core_bandwidth)
                    pqos_total_raw.append(total_bandwidth)
                    pqos_bandwidth_core_sum += core_bandwidth * sample_count
                    pqos_bandwidth_other_sum += other_bandwidth * sample_count
                    pqos_bandwidth_total_sum += total_bandwidth * sample_count
                    pqos_bandwidth_sample_count += sample_count
                else:
                    pqos_core_raw.append(None)
                    pqos_total_raw.append(None)
                    pqos_miss += 1

        if force_system_zero:
            system_memory_raw.append(None)
            system_miss += 1
        else:
            sample_value, in_window, near = select_entry(
                pcm_memory_times,
                pcm_memory_values,
                window_start,
                window_end,
                window_center,
                pcm_memory_tolerance,
            )
            if sample_value is None:
                system_memory_raw.append(None)
                system_miss += 1
            else:
                if in_window:
                    system_in_window += 1
                elif near:
                    system_near += 1
                system_data_available = True
                system_memory_raw.append(max(sample_value, 0.0))

    log(f"alignment turbostat: in_window={ts_in_window}, near={ts_near}, miss={ts_miss}")
    log(f"alignment pqos: in_window={pqos_in_window}, near={pqos_near}, miss={pqos_miss}")
    log(
        f"alignment pcm-memory: in_window={system_in_window}, near={system_near}, miss={system_miss}"
    )
    if pqos_bandwidth_sample_count:
        avg_core_bandwidth = pqos_bandwidth_core_sum / pqos_bandwidth_sample_count
        avg_other_bandwidth = pqos_bandwidth_other_sum / pqos_bandwidth_sample_count
        avg_total_bandwidth = pqos_bandwidth_total_sum / pqos_bandwidth_sample_count
    else:
        avg_core_bandwidth = avg_other_bandwidth = avg_total_bandwidth = 0.0
    log(
        "average pqos bandwidth: workload_core={:.2f} MB/s, complementary_cores={:.2f} MB/s, all_cores={:.2f} MB/s".format(
            avg_core_bandwidth,
            avg_other_bandwidth,
            avg_total_bandwidth,
        )
    )
    if row_count:
        ts_coverage = ts_in_window / row_count
        pqos_coverage = pqos_in_window / row_count
        system_coverage = system_in_window / row_count
        if ts_coverage < 0.95:
            warn(f"turbostat in-window coverage = {ts_in_window}/{row_count} = {ts_coverage * 100:.1f}% (<95%)")
        if pqos_coverage < 0.95:
            warn(f"pqos in-window coverage = {pqos_in_window}/{row_count} = {pqos_coverage * 100:.1f}% (<95%)")
        if pcm_memory_times and system_coverage < 0.95:
            warn(
                f"pcm-memory in-window coverage = {system_in_window}/{row_count} = {system_coverage * 100:.1f}% (<95%)"
            )

    cpu_share_filled, cpu_share_interpolated = fill_series(cpu_share_raw)
    pqos_core_filled, pqos_core_interpolated = fill_series(pqos_core_raw)
    pqos_total_filled, pqos_total_interpolated = fill_series(pqos_total_raw)
    system_memory_filled, system_memory_interpolated = fill_series(system_memory_raw)

    if not pqos_data_available:
        pqos_core_filled = [0.0] * row_count
        pqos_total_filled = [0.0] * row_count
        pqos_core_interpolated = pqos_total_interpolated = 0

    if not pcm_memory_times or not system_data_available:
        system_memory_filled = pqos_total_filled[:]
        system_memory_interpolated = 0

    def has_none(values):
        return any(v is None for v in values)

    if has_none(cpu_share_raw) or has_none(pqos_core_raw) or has_none(pqos_total_raw) or has_none(system_memory_raw):
        log("raw series contained missing entries prior to fill")

    cpu_share_missing_after = sum(1 for value in cpu_share_filled if value is None)
    core_missing_after = sum(1 for value in pqos_core_filled if value is None)
    total_missing_after = sum(1 for value in pqos_total_filled if value is None)
    system_missing_after = sum(1 for value in system_memory_filled if value is None)
    if cpu_share_missing_after or core_missing_after or total_missing_after or system_missing_after:
        error(
            "missing values remain after fill (cpu_share_missing={}, core_missing={}, total_missing={}, system_missing={})".format(
                cpu_share_missing_after,
                core_missing_after,
                total_missing_after,
                system_missing_after,
            )
        )

    log(
        f"fill cpu share: interpolated={cpu_share_interpolated}, first3={take_first(cpu_share_filled)}, last3={take_last(cpu_share_filled)}"
    )
    log(
        f"fill pqos workload: interpolated={pqos_core_interpolated}, first3={take_first(pqos_core_filled)}, last3={take_last(pqos_core_filled)}"
    )
    log(
        f"fill pqos total: interpolated={pqos_total_interpolated}, first3={take_first(pqos_total_filled)}, last3={take_last(pqos_total_filled)}"
    )
    log(
        f"fill system memory: interpolated={system_memory_interpolated}, first3={take_first(system_memory_filled)}, last3={take_last(system_memory_filled)}"
    )

    pkg_attr_values = []
    dram_attr_values = []
    non_dram_totals = []
    cpu_share_values = []
    mbm_share_values = []
    gray_values = []
    summary_rows = []

    for idx in range(row_count):
        pkg_total = pkg_powers[idx] if idx < len(pkg_powers) else 0.0
        dram_total = dram_powers[idx] if idx < len(dram_powers) else 0.0
        cpu_share_value = cpu_share_filled[idx] if idx < len(cpu_share_filled) else 0.0
        cpu_share_value = clamp01(cpu_share_value)
        workload_mb = pqos_core_filled[idx] if idx < len(pqos_core_filled) else 0.0
        total_mb = pqos_total_filled[idx] if idx < len(pqos_total_filled) else 0.0
        system_mb = system_memory_filled[idx] if idx < len(system_memory_filled) else total_mb
        if not math.isfinite(system_mb):
            system_mb = total_mb
        pkg_total = max(pkg_total, 0.0)
        workload_mb = max(workload_mb, 0.0)
        total_mb = max(total_mb, 0.0)
        system_mb = max(system_mb, 0.0)
        gray_mb = max(system_mb - total_mb, 0.0)
        share_mbm = (workload_mb / total_mb) if total_mb > EPS else 0.0
        share_mbm = clamp01(share_mbm)
        workload_attributed = workload_mb + share_mbm * gray_mb
        dram_total = max(dram_total, 0.0)
        non_dram_total = max(pkg_total - dram_total, 0.0)
        if system_mb > EPS:
            dram_attr = dram_total * (workload_attributed / system_mb)
        else:
            dram_attr = dram_total * share_mbm
        max_dram = max(dram_total, 0.0)
        dram_attr = max(0.0, min(dram_attr, max_dram))
        pkg_attr = non_dram_total * cpu_share_value
        max_pkg_non_dram = max(non_dram_total, 0.0)
        pkg_attr = max(0.0, min(pkg_attr, max_pkg_non_dram))

        pkg_attr_values.append(pkg_attr)
        dram_attr_values.append(dram_attr)
        non_dram_totals.append(non_dram_total)
        cpu_share_values.append(cpu_share_value)
        mbm_share_values.append(share_mbm)
        gray_values.append(gray_mb)
        summary_rows.append(
            [
                str(idx),
                f"{pkg_total:.6f}",
                f"{dram_total:.6f}",
                f"{system_mb:.6f}",
                f"{workload_mb:.6f}",
                f"{total_mb:.6f}",
                f"{cpu_share_value:.6f}",
                f"{share_mbm:.6f}",
                f"{gray_mb:.6f}",
                f"{workload_attributed:.6f}",
                f"{pkg_attr:.6f}",
                f"{dram_attr:.6f}",
            ]
        )

    if cpu_share_values:
        max_cpu_share = max(cpu_share_values)
        min_cpu_share = min(cpu_share_values)
        if min_cpu_share < -EPS:
            warn(f"cpu_share below 0 (min={min_cpu_share:.6f})")
        if max_cpu_share > 1.0 + EPS:
            warn(f"cpu_share above 1 (max={max_cpu_share:.6f})")

    if mbm_share_values:
        max_mbm_share = max(mbm_share_values)
        min_mbm_share = min(mbm_share_values)
        if min_mbm_share < -EPS:
            warn(f"mbm_share below 0 (min={min_mbm_share:.6f})")
        if max_mbm_share > 1.0 + EPS:
            warn(f"mbm_share above 1 (max={max_mbm_share:.6f})")

    if gray_values and min(gray_values) < -EPS:
        warn(f"gray bandwidth below 0 (min={min(gray_values):.6f})")

    pkg_attr_excess = []
    dram_attr_excess = []
    for idx in range(min(len(pkg_attr_values), len(pkg_powers))):
        limit_pkg = pkg_powers[idx]
        limit_non_dram = non_dram_totals[idx] if idx < len(non_dram_totals) else limit_pkg
        effective_limit = min(limit_pkg, limit_non_dram)
        if pkg_attr_values[idx] > effective_limit + EPS:
            pkg_attr_excess.append(pkg_attr_values[idx] - effective_limit)
    for idx in range(min(len(dram_attr_values), len(dram_powers))):
        if dram_attr_values[idx] > dram_powers[idx] + EPS:
            dram_attr_excess.append(dram_attr_values[idx] - dram_powers[idx])
    if pkg_attr_excess:
        warn(f"pkg_attr exceeds non-DRAM limit (max_excess={max(pkg_attr_excess):.6f})")
    if dram_attr_excess:
        warn(f"dram_attr exceeds dram_total (max_excess={max(dram_attr_excess):.6f})")

    mean_pkg_total = statistics.mean(pkg_powers) if pkg_powers else 0.0
    mean_dram_total = statistics.mean(dram_powers) if dram_powers else 0.0
    mean_non_dram_total = statistics.mean(non_dram_totals) if non_dram_totals else 0.0
    mean_pkg_attr = statistics.mean(pkg_attr_values) if pkg_attr_values else 0.0
    mean_dram_attr = statistics.mean(dram_attr_values) if dram_attr_values else 0.0
    mean_gray = statistics.mean(gray_values) if gray_values else 0.0
    if mean_pkg_attr > mean_pkg_total + EPS:
        warn(
            f"mean Actual_Watts ({mean_pkg_attr:.3f}) exceeds mean pcm-power Watts ({mean_pkg_total:.3f})"
        )
    if mean_pkg_attr > mean_non_dram_total + EPS:
        warn(
            f"mean Actual_Watts ({mean_pkg_attr:.3f}) exceeds mean non-DRAM power ({mean_non_dram_total:.3f})"
        )
    if mean_dram_attr > mean_dram_total + EPS:
        warn(
            f"mean Actual_DRAM_Watts ({mean_dram_attr:.3f}) exceeds mean pcm-power DRAM Watts ({mean_dram_total:.3f})"
        )
    log(
        "ATTRIB mean: pkg_total={:.3f}, dram_total={:.3f}, pkg_attr(Actual Watts)={:.3f}, "
        "dram_attr(Actual DRAM Watts)={:.3f}, gray_MBps={:.3f}".format(
            mean_pkg_total,
            mean_dram_total,
            mean_pkg_attr,
            mean_dram_attr,
            mean_gray,
        )
    )

    log(
        f"fill pkg attribution: first3={take_first(pkg_attr_values)}, last3={take_last(pkg_attr_values)}"
    )
    log(
        f"fill dram attribution: first3={take_first(dram_attr_values)}, last3={take_last(dram_attr_values)}"
    )

    summary_header = [
        "sample",
        "pkg_watts_total",
        "dram_watts_total",
        "imc_bw_MBps_total",
        "mbm_workload_MBps",
        "mbm_allcores_MBps",
        "cpu_share",
        "mbm_share",
        "gray_bw_MBps",
        "workload_attrib_bw_MBps",
        "pkg_attr_watts",
        "dram_attr_watts",
    ]
    atomic_write_csv(attrib_path, summary_header, summary_rows)
    log(
        f"wrote attribution summary: rows={len(summary_rows)} path={attrib_path} size={os.path.getsize(attrib_path)}B"
    )

    cols_before = len(power_header2)

    power_header1.extend(["S0", "S0"])
    power_header2.extend(["Actual Watts", "Actual DRAM Watts"])
    appended_headers = ["Actual Watts", "Actual DRAM Watts"]
    for idx in range(len(power_data)):
        non_dram_total = non_dram_totals[idx] if idx < len(non_dram_totals) else 0.0
        share_value = cpu_share_filled[idx] if idx < len(cpu_share_filled) else 0.0
        share_value = 0.0 if share_value is None else clamp01(share_value)
        max_non_dram = max(non_dram_total, 0.0)
        pkg_value = max(0.0, min(non_dram_total * share_value, max_non_dram))
        dram_value = dram_attr_values[idx] if idx < len(dram_attr_values) else 0.0
        dram_value = max(0.0, dram_value)
        if idx < len(pkg_attr_values):
            pkg_attr_values[idx] = pkg_value
        else:
            pkg_attr_values.append(pkg_value)
        if idx < len(dram_attr_values):
            dram_attr_values[idx] = dram_value
        else:
            dram_attr_values.append(dram_value)
        power_data[idx].append(f"{pkg_value:.6f}")
        power_data[idx].append(f"{dram_value:.6f}")

    cols_after = len(power_header2)
    log(f"writeback: pre_shape={len(power_data)}x{cols_before}, post_shape={len(power_data)}x{cols_after}")
    log(f"writeback: appended_headers={appended_headers}")
    log(
        "writeback: ghost_readded={}".format(
            "no (dropped empty column)" if ghost else "not needed"
        )
    )
    header2_tail_after = power_header2[-6:] if len(power_header2) >= 6 else power_header2[:]
    log(f"header2 tail after write: {header2_tail_after}")

    try:
        stat_info = os.stat(pcm_path)
    except FileNotFoundError:
        stat_info = None
        warn("pcm-power CSV missing when capturing permissions; skipping restore")
    tmp_file = tempfile.NamedTemporaryFile("w", delete=False, dir=str(pcm_path.parent), newline="")
    try:
        with tmp_file:
            writer = csv.writer(tmp_file)
            writer.writerow(power_header1)
            writer.writerow(power_header2)
            writer.writerows(power_data)
        if os.path.getsize(tmp_file.name) == 0:
            raise IOError("temporary power file is empty")
        os.replace(tmp_file.name, pcm_path)
    finally:
        try:
            os.unlink(tmp_file.name)
        except FileNotFoundError:
            pass
    if stat_info is not None:
        try:
            os.chmod(pcm_path, stat_info.st_mode & 0o777)
            if os.geteuid() == 0:
                os.chown(pcm_path, stat_info.st_uid, stat_info.st_gid)
        except OSError as exc:
            warn(f"failed to restore pcm-power CSV permissions: {exc}")

    with open(pcm_path, "r", newline="") as f:
        raw_lines = f.read().splitlines()
    audit_rows = list(csv.reader(raw_lines))
    audit_ok = True
    if len(audit_rows) < 2:
        error("write-back audit failed: insufficient header rows")
        audit_ok = False
    else:
        audit_header1 = list(audit_rows[0])
        audit_header2 = list(audit_rows[1])
        audit_data_rows = [list(row) for row in audit_rows[2:]]
        trimmed_header1 = audit_header1[:]
        trimmed_header2 = audit_header2[:]
        trimmed_data = [row[:] for row in audit_data_rows]
        while trimmed_header1 and trimmed_header2 and trimmed_header1[-1] == "" and trimmed_header2[-1] == "":
            trimmed_header1 = trimmed_header1[:-1]
            trimmed_header2 = trimmed_header2[:-1]
            trimmed_data = [row[:-1] if row else [] for row in trimmed_data]
        tail = trimmed_header2[-2:] if len(trimmed_header2) >= 2 else []
        header2_raw_line = raw_lines[1] if len(raw_lines) > 1 else ""
        if tail != ["Actual Watts", "Actual DRAM Watts"]:
            error(f"write-back audit failed: tail(header2)={trimmed_header2[-6:] if len(trimmed_header2) >= 6 else trimmed_header2}")
            error(f"header2_raw: {header2_raw_line}")
            audit_ok = False
        if audit_ok and trimmed_data:
            total_rows = len(trimmed_data)
            numeric_count = 0
            for row in trimmed_data:
                if len(row) < len(trimmed_header2):
                    row = row + [""] * (len(trimmed_header2) - len(row))
                if is_numeric(row[-2]) and is_numeric(row[-1]):
                    numeric_count += 1
            if total_rows:
                numeric_ratio = numeric_count / total_rows
            else:
                numeric_ratio = 1.0
            if numeric_ratio < 0.99:
                error(f"write-back audit failed: non-numeric cells found (count={total_rows - numeric_count})")
                error(f"header2_raw: {header2_raw_line}")
                audit_ok = False
    if audit_ok:
        ok(f"appended columns: Actual Watts, Actual DRAM Watts (rows={row_count}, cols={cols_after})")


if __name__ == "__main__":
    main()
