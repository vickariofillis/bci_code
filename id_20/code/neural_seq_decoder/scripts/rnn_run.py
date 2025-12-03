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

log_phase('SETUP','START')
args = parser.parse_args()


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
    testDayIdxs = range(len(loadedData[partition]))

log_phase('INFER','START')
for i, testDayIdx in enumerate(testDayIdxs):
    test_ds = SpeechDataset([loadedData[partition][i]])
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

        transcript = loadedData[partition][i]["transcriptions"][j].strip()
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
