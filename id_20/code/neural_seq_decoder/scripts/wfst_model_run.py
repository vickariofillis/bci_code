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


parser = argparse.ArgumentParser(description="To Run WFST Model")
parser.add_argument("--lmDir", type=str, required=True, help="Path to pre-trained WFST model")
parser.add_argument("--rnnRes", type=str, required=True, help="Path to RNN results pkl file")

args = parser.parse_args()

lmDir = args.lmDir
rnnRes = args.rnnRes

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
    def __init__(self, model_path, acoustic_scale=0.5, nbest=10, beam=18):
        fst_path = os.path.join(model_path, "TLG.fst")
        if not os.path.exists(fst_path):
            raise ValueError(f"TLG.fst not found in {model_path}")
        self.fst = StdVectorFst.read(fst_path)
        self.acoustic_scale = acoustic_scale
        opts = LatticeFasterDecoderOptions()
        opts.beam = beam
        opts.max_active = 7000
        opts.min_active = 200
        opts.lattice_beam = 8
        self.symbol_table = SymbolTable.read_text(os.path.join(model_path, "words.txt"))
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
        

ngramDecoder = PyKaldiDecoder(lmDir, acoustic_scale=0.5, nbest=10)

# read rnn_ouputs and nbest_outputs if doing llm separately
#with open("rnn_results.pkl", "rb") as f:
with open(rnnRes, "rb") as f:
    rnn_outputs = pickle.load(f)


# LM decoding hyperparameters
acoustic_scale = 0.5
blank_penalty = np.log(7)
llm_weight = 0.5

llm_outputs = []
# Generate nbest outputs from 5gram LM
start_t = time.time()
nbest_outputs = []
for j in range(len(rnn_outputs["logits"])):
# for j in range(1):
    logits = rnn_outputs["logits"][j]
    logits = np.concatenate(
        [logits[:, 1:], logits[:, 0:1]], axis=-1
    )  # Blank is last token
    logits = rearrange_speech_logits(logits[None, :, :], has_sil=True)
    nbest = lm_decode(
        ngramDecoder,
        logits[0],
        blankPenalty=blank_penalty,
        returnNBest=True,
        rescore=True,
    )
    nbest_outputs.append(nbest)
# time_per_sample = (time.time() - start_t) / len(rnn_outputs["logits"])
# print(f"decoding took {time_per_sample} seconds per sample")

# write to pkl object if doing llm separately
with open("nbest_results.pkl", "wb") as f:
    pickle.dump(nbest_outputs, f)

print("Error rates: ", cer_pre_opt(nbest_outputs, rnn_outputs))



