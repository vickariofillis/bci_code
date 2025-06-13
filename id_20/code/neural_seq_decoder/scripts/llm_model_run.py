import torch
import huggingface_hub
from transformers import AutoTokenizer, AutoModelForCausalLM

import torch.nn.functional as F
import os
import numpy as np
import math

import pickle
import time

start_time = time.time()

def log_phase(name, stage):
    now = time.time()
    rel = now - start_time
    print(f"PHASE {name} {stage} ABS:{now:.6f} REL:{rel:.6f}", flush=True)

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


def build_opt(modelName='facebook/opt-6.7b', cacheDir=None, device='cpu', load_in_8bit=False):
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(modelName, cache_dir=cacheDir)
    model = AutoModelForCausalLM.from_pretrained(modelName, cache_dir=cacheDir,
                                                 device_map=device, load_in_8bit=load_in_8bit)

    tokenizer.padding_side = "right"
    tokenizer.pad_token = tokenizer.eos_token

    return model, tokenizer


def rescore_with_gpt2(model, tokenizer, hypotheses, lengthPenalty):
    model_class = type(model).__name__
    if model_class.startswith('TF'):
        inputs = tokenizer(hypotheses, return_tensors='tf', padding=True)
        outputs = model(inputs)
        logProbs = tf.math.log(tf.nn.softmax(outputs['logits'], -1))
        logProbs = logProbs.numpy()
    else:
        import torch
        inputs = tokenizer(hypotheses, return_tensors='pt', padding=True)
        with torch.no_grad():
            outputs = model(**inputs)
            logProbs = torch.nn.functional.log_softmax(outputs['logits'].float(), -1).numpy()

    newLMScores = []
    B, T, _ = logProbs.shape
    for i in range(B):
        n_tokens = np.sum(inputs['attention_mask'][i].numpy())

        newLMScore = 0.
        for j in range(1, n_tokens):
            newLMScore += logProbs[i, j - 1, inputs['input_ids'][i, j].numpy()]

        newLMScores.append(newLMScore - n_tokens * lengthPenalty)

    return newLMScores


def gpt2_lm_decode(model, tokenizer, nbest, acousticScale, lengthPenlaty, alpha,
                   returnConfidence=False):
    hypotheses = []
    acousticScores = []
    oldLMScores = []
    for out in nbest:
        hyp = out[0].strip()
        if len(hyp) == 0:
            continue
        hyp = hyp.replace('>', '')
        hyp = hyp.replace('  ', ' ')
        hyp = hyp.replace(' ,', ',')
        hyp = hyp.replace(' .', '.')
        hyp = hyp.replace(' ?', '?')
        hypotheses.append(hyp)
        acousticScores.append(out[1])
        oldLMScores.append(out[2])

    if len(hypotheses) == 0:
        return "" if not returnConfidence else ("", 0.)

    acousticScores = np.array(acousticScores)
    newLMScores = np.array(rescore_with_gpt2(model, tokenizer, hypotheses, lengthPenlaty))
    oldLMScores = np.array(oldLMScores)

    totalScores = alpha * newLMScores + (1 - alpha) * oldLMScores + acousticScale * acousticScores
    maxIdx = np.argmax(totalScores)
    bestHyp = hypotheses[maxIdx]
    if not returnConfidence:
        return bestHyp
    else:
        totalScores = totalScores - np.max(totalScores)
        probs = np.exp(totalScores)
        return bestHyp, probs[maxIdx] / np.sum(probs)


def cer_with_gpt2_decoder(model, tokenizer, nbestOutputs, acousticScale,
                          inferenceOut, outputType='handwriting',
                          returnCI=False,
                          lengthPenalty=0.0,
                          alpha=1.0):
    decodedSentences = []
    confidences = []
    for i in range(len(nbestOutputs)):
        # print("it: ", i)
        decoded, confidence = gpt2_lm_decode(model, tokenizer, nbestOutputs[i], acousticScale, lengthPenalty, alpha, returnConfidence=True)
        decodedSentences.append(decoded.lower())
        # print("decoded: ", decoded)
        confidences.append(confidence)

    if outputType == 'handwriting':
        trueSentences = _extract_true_sentences(inferenceOut)
    elif outputType == 'speech' or outputType == 'speech_sil':
        trueSentences = inferenceOut['transcriptions']
    trueSentencesProcessed = []
    for trueSent in trueSentences:
        if outputType == 'handwriting':
            trueSent = trueSent.replace('>',' ')
            trueSent = trueSent.replace('~','.')
            trueSent = trueSent.replace('#','')
        if outputType == 'speech' or outputType == 'speech_sil':
            trueSent = trueSent.lower().strip()
        trueSentencesProcessed.append(trueSent)

    cer, wer = _cer_and_wer(decodedSentences, trueSentencesProcessed, outputType, returnCI)

    return {
        'cer': cer,
        'wer': wer,
        'decoded_transcripts': decodedSentences,
        'confidences': confidences
    }



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



def _extract_true_sentences(inferenceOut):
    charMarks = ['a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z',
                 '>',',',"'",'~','?']

    trueSentences = []
    for i in range(len(inferenceOut['trueSeqs'])):
        trueSent = ''
        endIdx = np.argwhere(inferenceOut['trueSeqs'][i] == -1)
        endIdx = endIdx[0,0]
        for c in range(endIdx):
            trueSent += charMarks[inferenceOut['trueSeqs'][i][c]]
        trueSentences.append(trueSent)

    return trueSentences


import argparse
parser = argparse.ArgumentParser(description="To Run LLM Model")
parser.add_argument("--rnnRes", type=str, required=True, help="Path to RNN results pkl file")
parser.add_argument("--nbRes", type=str, required=True, help="Path to WFST results pkl file")

log_phase('LOAD','START')
args = parser.parse_args()

rnnRes = args.rnnRes
nbRes = args.nbRes
# read rnn_ouputs and nbest_outputs if doing llm separately
with open(rnnRes, "rb") as f:
    rnn_outputs = pickle.load(f)
with open(nbRes, "rb") as f:
    nbest_outputs = pickle.load(f)
log_phase('LOAD','END')

log_phase('SETUP','START')
llm, llm_tokenizer = build_opt()
log_phase('SETUP','END')

log_phase('RESCORE','START')
llm_out = cer_with_gpt2_decoder(
    llm,
    llm_tokenizer,
    nbest_outputs[:],
    0.5,
    rnn_outputs,
    outputType="speech_sil",
    returnCI=False,
    lengthPenalty=0,
    alpha=0.5,
)
log_phase('RESCORE','END')

print("Error rates: ", llm_out['cer'], llm_out['wer'])


for i in range(len(nbest_outputs)):
    real = rnn_outputs['transcriptions'][i]
    lm = nbest_outputs[i][0][0]
    llm = llm_out['decoded_transcripts'][i]
    print("Real:\n\t", real)
    print("Outputs:")
    print("\t LM: ", lm)
    print("\t LLM: ", llm)

