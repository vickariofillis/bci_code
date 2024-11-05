
modelName = 'speechBaseline4'

args = {}
# Original
#args['outputDir'] = '/oak/stanford/groups/henderj/stfan/logs/speech_logs/' + modelName
#args['datasetPath'] = '/oak/stanford/groups/henderj/fwillett/speech/ptDecoder_ctc'
# Local PC
args['outputDir'] = '/home/vic/OneDrive-UofT/Research/BCI/workload-data/id-20/logs/speech_logs' + modelName
args['datasetPath'] = '/home/vic/OneDrive-UofT/Research/BCI/workload-data/id-20/competitionData_conv/ptDecoder_ctc'
# Niagara
# args['outputDir'] = '/scratch/e/enright/vickario/research/bci/id-20/logs/speech_logs' + modelName
# args['datasetPath'] = '/scratch/e/enright/vickario/research/bci/id-20/competitionData_conv/ptDecoder_ctc'
args['seqLen'] = 150
args['maxTimeSeriesLen'] = 1200
args['batchSize'] = 64
args['lrStart'] = 0.02
args['lrEnd'] = 0.02
args['nUnits'] = 1024
args['nBatch'] = 10000 #3000
args['nLayers'] = 5
args['seed'] = 0
args['nClasses'] = 40
args['nInputFeatures'] = 256
args['dropout'] = 0.4
args['whiteNoiseSD'] = 0.8
args['constantOffsetSD'] = 0.2
args['gaussianSmoothWidth'] = 2.0
args['strideLen'] = 4
args['kernelLen'] = 32
args['bidirectional'] = True
args['l2_decay'] = 1e-5

# Fix for providing path
import sys
sys.path.append("/home/vic/OneDrive/University/Graduate/PhD/Research/BCI/bci_code/id-20/neural_seq_decoder/src/")
# Niagara
#sys.path.append("/home/e/enright/vickario/research/bci/bci_code/id-20/neural_seq_decoder/src/")

from neural_decoder.neural_decoder_trainer import trainModel

trainModel(args)