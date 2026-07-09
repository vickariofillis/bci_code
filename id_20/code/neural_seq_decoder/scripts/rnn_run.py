from edit_distance import SequenceMatcher
import torch
from neural_decoder.dataset import SpeechDataset

# import matplotlib.pyplot as plt

from neural_decoder.neural_decoder_trainer import getDatasetLoaders
from neural_decoder.neural_decoder_trainer import loadModel

import torch

import torch.nn.functional as F
import os
import numpy as np
import math
import pickle
import re
import argparse
import time

start_time = time.time()

def log_phase(name, stage):
    now = time.time()
    rel = now - start_time
    print(f"PHASE {name} {stage} ABS:{now:.6f} REL:{rel:.6f}", flush=True)

parser = argparse.ArgumentParser(description="To Run rnn_model")
parser.add_argument("--datasetPath", type=str, required=True, help="Path to the post-processed dataset")
parser.add_argument("--modelPath", type=str, required=True, help="Path to pre-trained RNN model")
parser.add_argument(
    "--outputPath",
    type=str,
    default="rnn_results.pkl",
    help="Optional path for the RNN outputs pickle (default: rnn_results.pkl in the current directory)",
)
parser.add_argument(
    "--workload-threads",
    type=int,
    default=1,
    help="CPU thread count for the RNN workload (default: 1)",
)
parser.add_argument(
    "--test-day-indices",
    type=str,
    default="all",
    help=(
        "Comma-separated test day indices, a range such as 4-18, "
        "'source_paper' for 4-18, or 'all' for every converted test day."
    ),
)

log_phase('SETUP','START')
args = parser.parse_args()


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


configure_runtime_threads(args.workload_threads)


def parse_day_indices(spec, available_count):
    spec = (spec or "all").strip().lower()
    if spec in {"", "all"}:
        return list(range(available_count))
    if spec in {"source", "source_paper", "paper", "release", "4-18"}:
        indices = list(range(4, 19))
    else:
        indices = []
        for chunk in spec.split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            if "-" in chunk:
                start, end = chunk.split("-", 1)
                start_i = int(start)
                end_i = int(end)
                step = 1 if end_i >= start_i else -1
                indices.extend(range(start_i, end_i + step, step))
            else:
                indices.append(int(chunk))
    invalid = [idx for idx in indices if idx < 0 or idx >= available_count]
    if invalid:
        raise ValueError(
            f"--test-day-indices contains invalid indices {invalid}; "
            f"available test days are 0-{available_count - 1}"
        )
    return indices


# args['datasetPath'] = '/home/iris/project_3_bci/workload_characterization/id20_neural_decode/data/competition_data/ptDecoder_ctc'


batch_sz = 8
trainLoaders, testLoaders, loadedData = getDatasetLoaders(
    args.datasetPath, batch_sz
)

# modelPath = '/home/iris/project_3_bci/workload_characterization/id20_neural_decode/model/speechBaseline4'
modelPath = args.modelPath
model = loadModel(modelPath, device="cpu")
device = "cpu"
model.eval()
log_phase('SETUP','END')

rnn_outputs = {
    "logits": [],
    "logitLengths": [],
    "trueSeqs": [],
    "transcriptions": [],
}

# partition = "competition" 
partition =  "test"
# partition =  "train"
if partition == "competition":
    testDayIdxs = [4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16, 18, 19, 20]
# elif partition == "test":
else:
    testDayIdxs = parse_day_indices(args.test_day_indices, len(loadedData[partition]))

rnn_outputs["metadata"] = {
    "partition": partition,
    "test_day_indices": list(testDayIdxs),
    "test_day_index_mode": args.test_day_indices,
}

log_phase('INFER','START')
for testDayIdx in testDayIdxs:
    test_ds = SpeechDataset([loadedData[partition][testDayIdx]])
    test_loader = torch.utils.data.DataLoader(
        test_ds, batch_size=1, shuffle=False, num_workers=0
    )
    for j, (X, y, X_len, y_len, _) in enumerate(test_loader):
        X, y, X_len, y_len, dayIdx = (
            X.to(device),
            y.to(device),
            X_len.to(device),
            y_len.to(device),
            torch.tensor([testDayIdx], dtype=torch.int64).to(device),
        )
        pred = model.forward(X, dayIdx)
        adjustedLens = ((X_len - model.kernelLen) / model.strideLen).to(torch.int32)

        for iterIdx in range(pred.shape[0]):
            trueSeq = np.array(y[iterIdx][0 : y_len[iterIdx]].cpu().detach())

            rnn_outputs["logits"].append(pred[iterIdx].cpu().detach().numpy())
            rnn_outputs["logitLengths"].append(
                adjustedLens[iterIdx].cpu().detach().item()
            )
            rnn_outputs["trueSeqs"].append(trueSeq)

        transcript = loadedData[partition][testDayIdx]["transcriptions"][j].strip()
        transcript = re.sub(r"[^a-zA-Z\- \']", "", transcript)
        transcript = transcript.replace("--", "").lower()
        rnn_outputs["transcriptions"].append(transcript)
log_phase('INFER','END')

log_phase('SAVE','START')
# write to pkl object if doing llm separately
with open(args.outputPath, "wb") as f:
    pickle.dump(rnn_outputs, f)
log_phase('SAVE','END')

print("Workload finished successfully", flush=True)
