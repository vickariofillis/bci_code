import argparse
import os
import pickle
import re
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch

from neural_decoder.dataset import SpeechDataset
from neural_decoder.neural_decoder_trainer import getDatasetLoaders
from neural_decoder.neural_decoder_trainer import loadModel


start_time = time.time()


def log_phase(name, stage):
    now = time.time()
    rel = now - start_time
    print(f"PHASE {name} {stage} ABS:{now:.6f} REL:{rel:.6f}", flush=True)


def build_parser():
    parser = argparse.ArgumentParser(description="Run the ID-20 RNN model")
    parser.add_argument(
        "--datasetPath",
        type=str,
        help="Path to the post-processed dataset",
    )
    parser.add_argument(
        "--modelPath",
        type=str,
        help="Path to the pre-trained RNN model",
    )
    parser.add_argument(
        "--outputPath",
        type=str,
        default="rnn_results.pkl",
        help="Output path for the RNN results pickle",
    )
    parser.add_argument(
        "--workload-threads",
        type=int,
        default=1,
        help="CPU thread count for this RNN process (default: 1)",
    )
    parser.add_argument(
        "--dump-manifest",
        type=str,
        default="",
        help="Internal: write the ordered utterance manifest to this TSV path and exit",
    )
    parser.add_argument(
        "--shard-manifest",
        type=str,
        default="",
        help="Internal: process only the utterances listed in this TSV manifest",
    )
    parser.add_argument(
        "--merge-shards-dir",
        type=str,
        default="",
        help="Internal: merge worker partial pickles from this directory",
    )
    parser.add_argument(
        "--merge-manifest",
        type=str,
        default="",
        help="Internal: full manifest TSV describing the expected utterance order for merge mode",
    )
    return parser


def require_arg(value, name):
    if not value:
        raise ValueError(f"{name} is required for this mode")


def configure_runtime_threads(thread_count):
    if thread_count < 1:
        raise ValueError(f"--workload-threads must be >= 1, got {thread_count}")

    thread_vars = (
        "OMP_NUM_THREADS",
        "MKL_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
    )
    for var_name in thread_vars:
        os.environ[var_name] = str(thread_count)

    torch.set_num_threads(thread_count)
    torch.set_num_interop_threads(1)
    print(
        f"RNN runtime configuration: threads={thread_count}, interop_threads=1",
        flush=True,
    )


def load_loaded_data(dataset_path):
    batch_sz = 8
    _, _, loaded_data = getDatasetLoaders(dataset_path, batch_sz)
    return loaded_data


def get_partition_entries(loaded_data, partition):
    if partition == "competition":
        test_day_idxs = [4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16, 18, 19, 20]
    else:
        test_day_idxs = range(len(loaded_data[partition]))

    entries = []
    global_index = 0
    for partition_index, test_day_idx in enumerate(test_day_idxs):
        test_ds = SpeechDataset([loaded_data[partition][partition_index]])
        test_loader = torch.utils.data.DataLoader(
            test_ds, batch_size=1, shuffle=False, num_workers=0
        )
        for sample_index, _ in enumerate(test_loader):
            entries.append(
                {
                    "global_index": global_index,
                    "partition_index": partition_index,
                    "test_day_index": int(test_day_idx),
                    "sample_index": sample_index,
                }
            )
            global_index += 1
    return entries


def write_manifest(path, entries):
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(
                f"{entry['global_index']}\t{entry['partition_index']}\t"
                f"{entry['test_day_index']}\t{entry['sample_index']}\n"
            )


def load_manifest(path):
    entries = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                raise ValueError(f"Malformed manifest line: {line!r}")
            global_index, partition_index, test_day_index, sample_index = (
                int(parts[0]),
                int(parts[1]),
                int(parts[2]),
                int(parts[3]),
            )
            entries.append(
                {
                    "global_index": global_index,
                    "partition_index": partition_index,
                    "test_day_index": test_day_index,
                    "sample_index": sample_index,
                }
            )
    return entries


def normalize_transcript(raw_text):
    transcript = raw_text.strip()
    transcript = re.sub(r"[^a-zA-Z\- \']", "", transcript)
    transcript = transcript.replace("--", "").lower()
    return transcript


def run_selected_entries(dataset_path, model_path, selected_entries):
    device = "cpu"
    partition = "test"

    log_phase("SETUP", "START")
    loaded_data = load_loaded_data(dataset_path)
    model = loadModel(model_path, device=device)
    model.eval()
    log_phase("SETUP", "END")

    selected_by_partition = defaultdict(dict)
    partition_order = []
    for entry in selected_entries:
        partition_index = entry["partition_index"]
        if partition_index not in selected_by_partition:
            partition_order.append(partition_index)
        selected_by_partition[partition_index][entry["sample_index"]] = entry

    partial_entries = []

    log_phase("INFER", "START")
    for partition_index in partition_order:
        sample_map = selected_by_partition[partition_index]
        test_ds = SpeechDataset([loaded_data[partition][partition_index]])
        test_loader = torch.utils.data.DataLoader(
            test_ds, batch_size=1, shuffle=False, num_workers=0
        )
        seen_samples = set()
        for sample_index, (X, y, X_len, y_len, _) in enumerate(test_loader):
            entry = sample_map.get(sample_index)
            if entry is None:
                continue

            seen_samples.add(sample_index)
            day_idx = torch.tensor(
                [entry["test_day_index"]], dtype=torch.int64
            ).to(device)
            X = X.to(device)
            y = y.to(device)
            X_len = X_len.to(device)
            y_len = y_len.to(device)
            pred = model.forward(X, day_idx)
            adjusted_lens = ((X_len - model.kernelLen) / model.strideLen).to(
                torch.int32
            )

            for iter_index in range(pred.shape[0]):
                true_seq = np.array(y[iter_index][0 : y_len[iter_index]].cpu().detach())
                transcript = normalize_transcript(
                    loaded_data[partition][partition_index]["transcriptions"][
                        sample_index
                    ]
                )
                partial_entries.append(
                    {
                        "global_index": entry["global_index"],
                        "logits": pred[iter_index].cpu().detach().numpy(),
                        "logitLength": adjusted_lens[iter_index].cpu().detach().item(),
                        "trueSeq": true_seq,
                        "transcription": transcript,
                    }
                )

        missing_samples = sorted(set(sample_map) - seen_samples)
        if missing_samples:
            raise RuntimeError(
                "Manifest referenced missing samples for partition "
                f"{partition_index}: {missing_samples}"
            )
    log_phase("INFER", "END")

    partial_entries.sort(key=lambda entry: entry["global_index"])
    return partial_entries


def partial_entries_to_output(entries):
    rnn_outputs = {
        "logits": [],
        "logitLengths": [],
        "trueSeqs": [],
        "transcriptions": [],
    }
    for entry in entries:
        rnn_outputs["logits"].append(entry["logits"])
        rnn_outputs["logitLengths"].append(entry["logitLength"])
        rnn_outputs["trueSeqs"].append(entry["trueSeq"])
        rnn_outputs["transcriptions"].append(entry["transcription"])
    return rnn_outputs


def write_pickle(path, payload):
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as handle:
        pickle.dump(payload, handle)


def run_manifest_dump(dataset_path, manifest_path):
    log_phase("MANIFEST", "START")
    loaded_data = load_loaded_data(dataset_path)
    entries = get_partition_entries(loaded_data, partition="test")
    write_manifest(manifest_path, entries)
    log_phase("MANIFEST", "END")
    print(f"Wrote manifest with {len(entries)} utterances to {manifest_path}", flush=True)


def run_merge(partials_dir, manifest_path, output_path):
    manifest_entries = load_manifest(manifest_path)
    expected_count = len(manifest_entries)
    partial_dir_path = Path(partials_dir)
    partial_paths = sorted(partial_dir_path.glob("worker_*.pkl"))
    if not partial_paths:
        raise RuntimeError(f"No worker partial pickles found under {partials_dir}")

    merged_entries = []
    for partial_path in partial_paths:
        with partial_path.open("rb") as handle:
            partial_payload = pickle.load(handle)
        entries = partial_payload.get("entries")
        if entries is None:
            raise RuntimeError(f"Partial pickle missing 'entries': {partial_path}")
        merged_entries.extend(entries)

    if len(merged_entries) != expected_count:
        raise RuntimeError(
            "Merged shard count does not match manifest count: "
            f"{len(merged_entries)} != {expected_count}"
        )

    merged_entries.sort(key=lambda entry: entry["global_index"])
    for expected_index, entry in enumerate(merged_entries):
        if entry["global_index"] != expected_index:
            raise RuntimeError(
                "Merged shard ordering mismatch: expected global index "
                f"{expected_index}, saw {entry['global_index']}"
            )

    log_phase("MERGE", "START")
    write_pickle(output_path, partial_entries_to_output(merged_entries))
    log_phase("MERGE", "END")
    print(
        f"Merged {len(partial_paths)} partial pickles into {output_path}",
        flush=True,
    )


def run_inference_mode(dataset_path, model_path, output_path, shard_manifest):
    if shard_manifest:
        selected_entries = load_manifest(shard_manifest)
    else:
        loaded_data = load_loaded_data(dataset_path)
        selected_entries = get_partition_entries(loaded_data, partition="test")
    partial_entries = run_selected_entries(dataset_path, model_path, selected_entries)

    log_phase("SAVE", "START")
    if shard_manifest:
        payload = {"entries": partial_entries}
    else:
        payload = partial_entries_to_output(partial_entries)
    write_pickle(output_path, payload)
    log_phase("SAVE", "END")
    print("Workload finished successfully", flush=True)


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.dump_manifest:
        require_arg(args.datasetPath, "--datasetPath")
        run_manifest_dump(args.datasetPath, args.dump_manifest)
        return

    if args.merge_shards_dir or args.merge_manifest:
        require_arg(args.merge_shards_dir, "--merge-shards-dir")
        require_arg(args.merge_manifest, "--merge-manifest")
        run_merge(args.merge_shards_dir, args.merge_manifest, args.outputPath)
        return

    require_arg(args.datasetPath, "--datasetPath")
    require_arg(args.modelPath, "--modelPath")
    configure_runtime_threads(args.workload_threads)
    run_inference_mode(
        args.datasetPath,
        args.modelPath,
        args.outputPath,
        args.shard_manifest,
    )


if __name__ == "__main__":
    main()
