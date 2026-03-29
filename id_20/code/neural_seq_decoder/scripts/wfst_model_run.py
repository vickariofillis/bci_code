from kaldi.decoder import LatticeFasterDecoder, LatticeFasterDecoderOptions, DecodableMatrixScaled
from kaldi.fstext import SymbolTable, StdVectorFst, read_fst_kaldi, utils
from kaldi.util.table import SequentialMatrixReader
from kaldi.matrix import Matrix

from kaldi.fstext.utils import get_linear_symbol_sequence

import pickle
import numpy as np
import time

import torch.nn.functional as F

import os
import math
import argparse
import torch
import sys
import shutil
import multiprocessing
from pathlib import Path

start_time = time.time()
SHARED_RNN_OUTPUTS = None
SHARED_FST = None
SHARED_SYMBOL_TABLE = None

def log_phase(name, stage):
    now = time.time()
    rel = now - start_time
    print(f"PHASE {name} {stage} ABS:{now:.6f} REL:{rel:.6f}", flush=True)


parser = argparse.ArgumentParser(description="To Run WFST Model")
parser.add_argument("--lmDir", type=str, required=True, help="Path to pre-trained WFST model")
parser.add_argument("--rnnRes", type=str, required=True, help="Path to RNN results pkl file")
parser.add_argument(
    "--nbestPath",
    type=str,
    default="nbest_results.pkl",
    help="Optional path for saving WFST n-best outputs (default: nbest_results.pkl in CWD)",
)
parser.add_argument(
    "--workload-cpus",
    type=str,
    default="",
    help="Optional workload CPU mask/list for worker sharding (example: 0-3 or 0,1,2,10)",
)
parser.add_argument(
    "--workload-threads",
    type=int,
    default=1,
    help="WFST worker-job count; values > 1 enable utterance-level sharding",
)
parser.add_argument(
    "--shard-manifest",
    type=str,
    default="",
    help="Internal worker-mode manifest path; decodes only the listed utterance indices",
)

log_phase('SETUP','START')
args = parser.parse_args()

lmDir = args.lmDir
rnnRes = args.rnnRes
log_phase('SETUP','END')

# lmDir = "/home/iris/project_3_bci/workload_characterization/id20_neural_decode/model/languageModel"

class DecodableTensorScaled:
    def __init__(self):
        self.reset()
    def reset(self):
        self.num_frames_ready = 0
        self.logp = []
    def AcceptLoglikes(self, logp):
        self.num_frames_ready += 1
        self.logp.append(logp.numpy())

class CtcWfstBeamSearch:
    def __init__(self, fst_, opts: LatticeFasterDecoderOptions, symbol_table: SymbolTable, acoustic_scale, nbest):
        self.decodable = DecodableTensorScaled()
        self.decoder = LatticeFasterDecoder(fst_, opts) #LatticeFasterOnlineDecoder(fst_, opts)
        self.symbol_table = symbol_table
        self.opts = opts
        self.nbest = nbest
        self.blank_scale = 1
        self.blank_skip_thresh = 0.95
        self.blank = 1
        self.acoustic_scale = acoustic_scale
        self.reset()
        

    def reset(self):
        self.num_frames = 0
        self.decoded_frames_mapping = []
        self.last_best = 0
        self.inputs = []
        self.outputs = []
        self.likelihood = []
        self.times = []
        self.decodable.reset()
        self.is_last_frame_blank = False
        self.decoder.init_decoding()


    def decode_matrix(self):
        if self.decodable.num_frames_ready == 0:
            raise ValueError("No frames to decode!")
        m = Matrix(np.array(self.decodable.logp))
#         print("shape: ", m.numpy().shape)
        dms = DecodableMatrixScaled(m, self.acoustic_scale)
        assert(dms.num_indices() == 41)
#         print("num indices: ", dms.num_indices())
        self.decoder.advance_decoding(dms)
        self.decoder.finalize_decoding()
            
    def search(self, logp):
        if(len(logp) == 0):
            return
        for i, frame_logp in enumerate(logp):
            blank_score = np.exp(frame_logp[self.blank])
            if blank_score > self.blank_skip_thresh * self.blank_scale:
                self.is_last_frame_blank = True
                self.last_frame_prob = frame_logp
            else:
                cur_best = np.argmax(frame_logp)
                if (cur_best != self.blank and self.is_last_frame_blank and cur_best == self.last_best):
                    self.decodable.AcceptLoglikes(self.last_frame_prob)
                    self.decoded_frames_mapping.append(self.num_frames - 1)
                self.last_best = cur_best
                self.decodable.AcceptLoglikes(frame_logp)
                self.decoded_frames_mapping.append(self.num_frames)
                self.is_last_frame_blank = False
            self.num_frames += 1   

        self.decode_matrix()
        self.inputs.clear()
        self.outputs.clear()
        self.likelihood.clear()
        # print("decoded frames length: ", len(self.decoded_frames_mapping))
        if len(self.decoded_frames_mapping) > 0:
            if self.nbest == 1:
                self.inputs.append([])
                self.outputs.append([])
                self.likelihood.append(0)
                lat = self.decoder.get_best_path()
                alignment, words, weight = utils.get_linear_symbol_sequence(lat)
                # print("words: ", words)
                self.convert_to_inputs(alignment)
                self.outputs[0] = words
                self.likelihood[0] = -(weight.value1 + weight.value2)
            else:
                lat2 = self.decoder.get_lattice()
                lat2_lat = utils.convert_compact_lattice_to_lattice(lat2)
                lat2_std = utils.convert_lattice_to_std(lat2_lat)
                nbest_fsts = utils.nbest_as_fsts(lat2_std, self.nbest)
                n = len(nbest_fsts)
                self.inputs = [[] for _ in range(n)]
                self.outputs = [[] for _ in range(n)]
                self.likelihood = [0.0 for _ in range(n)]
                self.times = [[] for _ in range(n)]
                for i, nbest_ in enumerate(nbest_fsts):
                    nbest_lat = utils.convert_std_to_lattice(nbest_)
                    alignment, words, weight = utils.get_linear_symbol_sequence(nbest_lat)
                    # print("words: ", words)
                    self.convert_to_inputs(alignment, i)
                    self.outputs[i] = words
                    self.likelihood[i] = -(weight.value1 + weight.value2)


    def convert_to_inputs(self, alignment, i=0, time = None):
        self.inputs[i].clear()
        if time is not None:
            time.clear()
        for cur in range(len(alignment)):
            if alignment[cur]-1 == self.blank:
                continue
            if cur > 0 and alignment[cur] == alignment[cur-1]:
                continue
            self.inputs[i].append(alignment[cur]-1)
            if time is not None:
                time.append(self.decoded_frames_mapping[cur])



class DecodeResult:
    def __init__(self):
        self.lm_score = 0.0
        self.ac_score = 0.0
        self.sentence = ""

class PyKaldiDecoder:
    def __init__(self, model_path, acoustic_scale=0.5, nbest=10, beam=18, fst=None, symbol_table=None):
        fst_path = os.path.join(model_path, "TLG.fst")
        if fst is None:
            if not os.path.exists(fst_path):
                raise ValueError(f"TLG.fst not found in {model_path}")
            fst = StdVectorFst.read(fst_path)
        if symbol_table is None:
            symbol_table = SymbolTable.read_text(os.path.join(model_path, "words.txt"))
        self.fst = fst
        self.acoustic_scale = acoustic_scale
        opts = LatticeFasterDecoderOptions()
        opts.beam = beam
        opts.max_active = 7000
        opts.min_active = 200
        opts.lattice_beam = 8
        self.symbol_table = symbol_table
        self.decoder = CtcWfstBeamSearch(self.fst, opts, self.symbol_table, acoustic_scale, nbest)
        self.results = []
    def decode(self, logp):
        self.decoder.reset()
        self.decoder.search(logp)
        self.updateResult()
        return
    
    def updateResult(self):
        hypothesis = self.decoder.outputs
        likelihood = self.decoder.likelihood
        self.results.clear()

        assert len(hypothesis) == len(likelihood)
        for i, hypothesis in enumerate(hypothesis):
            dr = DecodeResult()
            dr.lm_score = likelihood[i] # might need to double check this?
            dr.ac_score = likelihood[i] / self.acoustic_scale

            for token in hypothesis:
                dr.sentence += f' {self.symbol_table.find_symbol(token)}'#_symbol(token)

            dr.sentence = dr.sentence.strip()
            self.results.append(dr)

        if (len(self.results) > 0 and bool(self.results[0].sentence)):
            print(f"Partial CTC result: {self.results[0].sentence}")
        return

    def get_results(self):
        return self.results

def rearrange_speech_logits(logits, has_sil=False):
    if not has_sil:
        logits = np.concatenate([logits[:, :, -1:], logits[:, :, :-1]], axis=-1)
    else:
        logits = np.concatenate([logits[:, :, -1:], logits[:, :, -2:-1], logits[:, :, :-2]], axis=-1)
    return logits

def lm_decode(pydecoder, logits, returnNBest=False, rescore=False, blankPenalty=0.0, logPriors=None):
    assert len(logits.shape) == 2
    logPriors = torch.from_numpy(np.zeros([1, logits.shape[1]]))
    log_probs = F.log_softmax(torch.from_numpy(logits), dim=-1)
    log_probs = log_probs - logPriors
    # apply blank penalty
    blank_log_probs = log_probs[:, 0:1]
    log_probs[:, 0:1] = blank_log_probs - blankPenalty
    pydecoder.decode(log_probs)
    results = pydecoder.results
    if returnNBest:
        decoded = []
        for r in results:
            decoded.append((r.sentence, r.ac_score, r.lm_score))
        return decoded
    else:
        return results[0].sentence #?


def wer_(r, h):
    """
    Calculation of WER with Levenshtein distance.
    Works only for iterables up to 254 elements (uint8).
    O(nm) time ans space complexity.
    Parameters
    ----------
    r : list
    h : list
    Returns
    -------
    int
    Examples
    --------
    >>> wer("who is there".split(), "is there".split())
    1
    >>> wer("who is there".split(), "".split())
    3
    >>> wer("".split(), "who is there".split())
    3
    """
    # initialisation
    import numpy
    d = numpy.zeros((len(r)+1)*(len(h)+1), dtype=numpy.uint8)
    d = d.reshape((len(r)+1, len(h)+1))
    for i in range(len(r)+1):
        for j in range(len(h)+1):
            if i == 0:
                d[0][j] = j
            elif j == 0:
                d[i][0] = i

    # computation
    for i in range(1, len(r)+1):
        for j in range(1, len(h)+1):
            if r[i-1] == h[j-1]:
                d[i][j] = d[i-1][j-1]
            else:
                substitution = d[i-1][j-1] + 1
                insertion    = d[i][j-1] + 1
                deletion     = d[i-1][j] + 1
                d[i][j] = min(substitution, insertion, deletion)

    return d[len(r)][len(h)]


def _cer_and_wer(decodedSentences, trueSentences, outputType='handwriting',
                 returnCI=False):
    allCharErr = []
    allChar = []
    allWordErr = []
    allWord = []
    for x in range(len(decodedSentences)):
        decSent = decodedSentences[x]
        trueSent = trueSentences[x]

        nCharErr = wer_([c for c in trueSent], [c for c in decSent])
        if outputType == 'handwriting':
            trueWords = trueSent.replace(">", " > ").split(" ")
            decWords = decSent.replace(">", " > ").split(" ")
        elif outputType == 'speech' or outputType == 'speech_sil':
            trueWords = trueSent.split(" ")
            decWords = decSent.split(" ")
        nWordErr = wer_(trueWords, decWords)

        allCharErr.append(nCharErr)
        allWordErr.append(nWordErr)
        allChar.append(len(trueSent))
        allWord.append(len(trueWords))

    cer = np.sum(allCharErr) / np.sum(allChar)
    wer = np.sum(allWordErr) / np.sum(allWord)

    if not returnCI:
        return cer, wer
    else:
        allChar = np.array(allChar)
        allCharErr = np.array(allCharErr)
        allWord = np.array(allWord)
        allWordErr = np.array(allWordErr)

        nResamples = 10000
        resampledCER = np.zeros([nResamples,])
        resampledWER = np.zeros([nResamples,])
        for n in range(nResamples):
            resampleIdx = np.random.randint(0, allChar.shape[0], [allChar.shape[0]])
            resampledCER[n] = np.sum(allCharErr[resampleIdx]) / np.sum(allChar[resampleIdx])
            resampledWER[n] = np.sum(allWordErr[resampleIdx]) / np.sum(allWord[resampleIdx])
        cerCI = np.percentile(resampledCER, [2.5, 97.5])
        werCI = np.percentile(resampledWER, [2.5, 97.5])

        return (cer, cerCI[0], cerCI[1]), (wer, werCI[0], werCI[1])


def cer_pre_opt(nbestOutputs, inferenceOut):
    decoded_sentences = []
    true_sentences_processed = []
    true_sentences = inferenceOut['transcriptions'] #_extract_transcriptions(inferenceOut)
    for i in range(len(nbestOutputs)):
        sentence = nbestOutputs[i][0][0]
        hyp = sentence.lower().strip()
        hyp = hyp.replace('>', '')
        hyp = hyp.replace('  ', ' ')
        hyp = hyp.replace(' ,', ',')
        hyp = hyp.replace(' .', '.')
        hyp = hyp.replace(' ?', '?')
        decoded_sentences.append(hyp)
        trueSent = true_sentences[i].lower().strip()
        true_sentences_processed.append(trueSent)
    cer, wer = _cer_and_wer(decoded_sentences, true_sentences_processed, "speech_sil")
    return cer, wer


def parse_cpu_list(cpu_spec):
    cpus = []
    for part in cpu_spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            start_i = int(start)
            end_i = int(end)
            step = 1 if end_i >= start_i else -1
            cpus.extend(range(start_i, end_i + step, step))
        else:
            cpus.append(int(part))
    return cpus


def load_rnn_outputs(path):
    log_phase('LOAD', 'START')
    with open(path, "rb") as f:
        rnn_outputs = pickle.load(f)
    log_phase('LOAD', 'END')
    return rnn_outputs


def configure_single_thread_runtime():
    os.environ["OMP_NUM_THREADS"] = "1"
    os.environ["MKL_NUM_THREADS"] = "1"
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    os.environ["NUMEXPR_NUM_THREADS"] = "1"
    try:
        torch.set_num_threads(1)
    except RuntimeError:
        pass
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass


def load_decoder_assets(model_path):
    fst_path = os.path.join(model_path, "TLG.fst")
    if not os.path.exists(fst_path):
        raise ValueError(f"TLG.fst not found in {model_path}")
    symbol_table_path = os.path.join(model_path, "words.txt")
    if not os.path.exists(symbol_table_path):
        raise ValueError(f"words.txt not found in {model_path}")
    return StdVectorFst.read(fst_path), SymbolTable.read_text(symbol_table_path)


def write_index_manifest(path, indices):
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        for index in indices:
            handle.write(f"{index}\n")


def load_index_manifest(path):
    indices = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line:
                indices.append(int(line))
    return indices


def split_indices_contiguous(indices, shard_count):
    total = len(indices)
    if shard_count < 1:
        raise ValueError(f"Invalid shard_count: {shard_count}")
    if total == 0:
        return []
    shard_count = min(shard_count, total)
    shards = []
    for shard_index in range(shard_count):
        start = (total * shard_index) // shard_count
        end = (total * (shard_index + 1)) // shard_count
        if start < end:
            shards.append(indices[start:end])
    return shards


def decode_selected_indices(pydecoder, rnn_outputs, selected_indices, blank_penalty):
    nbest_entries = []
    log_phase('DECODE', 'START')
    for utterance_index in selected_indices:
        logits = rnn_outputs["logits"][utterance_index]
        logits = np.concatenate(
            [logits[:, 1:], logits[:, 0:1]], axis=-1
        )  # Blank is last token
        logits = rearrange_speech_logits(logits[None, :, :], has_sil=True)
        nbest = lm_decode(
            pydecoder,
            logits[0],
            blankPenalty=blank_penalty,
            returnNBest=True,
            rescore=True,
        )
        nbest_entries.append({"global_index": utterance_index, "nbest": nbest})
    log_phase('DECODE', 'END')
    return nbest_entries


def partial_entries_to_nbest(entries):
    return [entry["nbest"] for entry in entries]


def save_pickle(path, payload):
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as handle:
        pickle.dump(payload, handle)


def run_worker_mode(shard_manifest_path):
    configure_single_thread_runtime()
    rnn_outputs = load_rnn_outputs(rnnRes)
    log_phase('DECODER_INIT', 'START')
    ngramDecoder = PyKaldiDecoder(lmDir, acoustic_scale=0.5, nbest=10)
    log_phase('DECODER_INIT', 'END')
    blank_penalty = np.log(7)
    selected_indices = load_index_manifest(shard_manifest_path)
    entries = decode_selected_indices(
        ngramDecoder,
        rnn_outputs,
        selected_indices,
        blank_penalty,
    )
    log_phase('SAVE', 'START')
    save_pickle(args.nbestPath, {"entries": entries})
    log_phase('SAVE', 'END')
    print(f"Worker decoded {len(entries)} utterances into {args.nbestPath}", flush=True)


def run_forked_worker(cpu, shard_indices, partial_output_path, worker_log_path, blank_penalty):
    configure_single_thread_runtime()
    if hasattr(os, "sched_setaffinity"):
        os.sched_setaffinity(0, {cpu})

    with open(worker_log_path, "w", encoding="utf-8", buffering=1) as handle:
        sys.stdout = handle
        sys.stderr = handle
        print(f"Worker pinned to cpu {cpu}", flush=True)
        if SHARED_RNN_OUTPUTS is None:
            raise RuntimeError("Shared RNN outputs were not initialized before forking")
        if SHARED_FST is None or SHARED_SYMBOL_TABLE is None:
            raise RuntimeError("Shared decoder assets were not initialized before forking")
        log_phase('DECODER_INIT', 'START')
        ngramDecoder = PyKaldiDecoder(
            lmDir,
            acoustic_scale=0.5,
            nbest=10,
            fst=SHARED_FST,
            symbol_table=SHARED_SYMBOL_TABLE,
        )
        log_phase('DECODER_INIT', 'END')
        entries = decode_selected_indices(
            ngramDecoder,
            SHARED_RNN_OUTPUTS,
            shard_indices,
            blank_penalty,
        )
        log_phase('SAVE', 'START')
        save_pickle(partial_output_path, {"entries": entries})
        log_phase('SAVE', 'END')
        print(
            f"Worker decoded {len(entries)} utterances into {partial_output_path}",
            flush=True,
        )


def merge_partial_outputs(partials_dir, expected_count, output_path):
    partial_dir = Path(partials_dir)
    partial_paths = sorted(partial_dir.glob("worker_*.pkl"))
    if not partial_paths:
        raise RuntimeError(f"No worker partial outputs found under {partials_dir}")

    merged_entries = []
    for partial_path in partial_paths:
        with partial_path.open("rb") as handle:
            payload = pickle.load(handle)
        entries = payload.get("entries")
        if entries is None:
            raise RuntimeError(f"Partial pickle missing 'entries': {partial_path}")
        merged_entries.extend(entries)

    if len(merged_entries) != expected_count:
        raise RuntimeError(
            "Merged shard count does not match expected utterance count: "
            f"{len(merged_entries)} != {expected_count}"
        )

    merged_entries.sort(key=lambda entry: entry["global_index"])
    for expected_index, entry in enumerate(merged_entries):
        if entry["global_index"] != expected_index:
            raise RuntimeError(
                "Merged shard ordering mismatch: expected global index "
                f"{expected_index}, saw {entry['global_index']}"
            )

    log_phase('MERGE', 'START')
    save_pickle(output_path, partial_entries_to_nbest(merged_entries))
    log_phase('MERGE', 'END')
    print(
        f"Merged {len(partial_paths)} partial n-best pickles into {output_path}",
        flush=True,
    )


def run_sharded_mode():
    global SHARED_RNN_OUTPUTS, SHARED_FST, SHARED_SYMBOL_TABLE
    if args.workload_threads < 1:
        raise ValueError("--workload-threads must be >= 1")
    if not args.workload_cpus:
        raise ValueError("--workload-cpus is required when --workload-threads > 1")

    cpu_list = parse_cpu_list(args.workload_cpus)

    configure_single_thread_runtime()
    SHARED_RNN_OUTPUTS = load_rnn_outputs(rnnRes)
    total_utterances = len(SHARED_RNN_OUTPUTS["logits"])
    shard_count = min(args.workload_threads, total_utterances)
    if shard_count < 1:
        raise ValueError("No utterances available to decode")
    SHARED_FST, SHARED_SYMBOL_TABLE = load_decoder_assets(lmDir)

    all_indices = list(range(total_utterances))
    shard_lists = split_indices_contiguous(all_indices, shard_count)

    output_path = Path(args.nbestPath)
    shard_dir = output_path.parent / f"{output_path.stem}_wfst_shards"
    if shard_dir.exists():
        shutil.rmtree(shard_dir)
    shard_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = shard_dir / "manifest.tsv"
    write_index_manifest(manifest_path, all_indices)
    worker_cpu_sequence = [cpu_list[worker_index % len(cpu_list)] for worker_index in range(shard_count)]
    print(
        f"WFST shard coordinator started: requested_workers={args.workload_threads} "
        f"workload_cpus={' '.join(str(cpu) for cpu in worker_cpu_sequence)} "
        f"output={args.nbestPath}",
        flush=True,
    )

    ctx = multiprocessing.get_context("fork")
    worker_procs = []
    worker_logs = []
    blank_penalty = np.log(7)
    for worker_index, shard_indices in enumerate(shard_lists):
        cpu = worker_cpu_sequence[worker_index]
        shard_manifest = shard_dir / f"manifest_shard_{worker_index:04d}.tsv"
        partial_output = shard_dir / f"worker_{worker_index:04d}.pkl"
        worker_log = shard_dir / f"worker_{worker_index:04d}.log"
        write_index_manifest(shard_manifest, shard_indices)
        worker_logs.append(worker_log)
        print(
            f"Launching WFST worker {worker_index} on cpu {cpu} with shard {shard_manifest.name}",
            flush=True,
        )
        proc = ctx.Process(
            target=run_forked_worker,
            args=(cpu, shard_indices, str(partial_output), str(worker_log), blank_penalty),
            name=f"wfst-shard-{worker_index:04d}",
        )
        proc.start()
        worker_procs.append(proc)

    worker_status = 0
    for worker_index, proc in enumerate(worker_procs):
        proc.join()
        returncode = proc.exitcode
        if returncode != 0:
            print(
                f"WFST worker {worker_index} failed; see {worker_logs[worker_index]}",
                flush=True,
            )
            worker_status = returncode
    if worker_status != 0:
        raise RuntimeError(f"WFST shard worker failure (status={worker_status})")

    merge_partial_outputs(shard_dir, total_utterances, args.nbestPath)
    nbest_outputs = pickle.load(open(args.nbestPath, "rb"))
    print("Error rates: ", cer_pre_opt(nbest_outputs, rnn_outputs))
    print("Workload finished successfully", flush=True)


def run_single_process_mode():
    log_phase('DECODER_INIT', 'START')
    ngramDecoder = PyKaldiDecoder(lmDir, acoustic_scale=0.5, nbest=10)
    log_phase('DECODER_INIT', 'END')
    rnn_outputs = load_rnn_outputs(rnnRes)

    blank_penalty = np.log(7)
    selected_indices = list(range(len(rnn_outputs["logits"])))
    entries = decode_selected_indices(
        ngramDecoder,
        rnn_outputs,
        selected_indices,
        blank_penalty,
    )
    nbest_outputs = partial_entries_to_nbest(entries)

    log_phase('SAVE', 'START')
    save_pickle(args.nbestPath, nbest_outputs)
    log_phase('SAVE', 'END')

    print("Error rates: ", cer_pre_opt(nbest_outputs, rnn_outputs))
    print("Workload finished successfully", flush=True)


if args.shard_manifest:
    run_worker_mode(args.shard_manifest)
elif args.workload_threads > 1:
    run_sharded_mode()
else:
    run_single_process_mode()
