#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <sys/time.h>
//the data.h and data2.h file can be created directly in MATLAB (after the simulation)
//using the function "data_creation_PULP.m"
//it holds the item memories and the associative_memory 
#include "data.h"
//it contains the test sample of the iEEG segment
#include "data2.h"
//it contains all the constant needed from the algorithm (tuned by patient)
#include "init.h"
//it contains a single function, to compare the test vector with the associative memory.
#include "associative_memory.c"
//It contains all the principal functions of the algorithm: 
//(1) LBP_Spatial_encoding
//(2) temporal_encoder
//(3) postprocess
#include "aux_functions.c"
//gcc -std=c99 -fopenmp main.c -o main -lm command to compile on the shell
//./main to execute it
//The numbers inside TestSeizure1 are of Seizure 1 pat 12 and the 3 minutes of interictal segment before
//THE NUMBER OF CORES (1, 2, 4 OR 8) USED FOR THE EXECUTION CAN BE SET IN THE aux_function.c file



int main(){
    char LBP_buffer[channels] = {0};
    float Test_EEG_old[channels];
    uint32_t chHV[CHANNELS_VOTING][bit_dim] = {0};
    uint32_t chT[N/2][bit_dim] = {0};
    uint32_t tmp = 0;
    int classpredicted,ix, wind;
    int predictions[10]= {0};
    uint32_t query[bit_dim]= {0};
    struct timeval tvBegin, tvEnd, tvDiff;
	int i,j,z, majority;
	uint32_t spatialVector[bit_dim] = {0};
    for(i = 0; i < bit_dim ; i++){
    	tmp = iM[i][0] ^ iM[i][1];
        chHV[channels][i] = tmp;
    }
    for(ix = 0; ix < minutes*seconds*fs; ix = ix + N/2){
		tic(&tvBegin);
		for(wind = 0; wind < N/2; wind++){
			LBP_Spatial_encoding(LBP_buffer,chHV,chT,Test_EEG_old,ix,wind);
		}
		temporal_encoder(chT,query);	
        classpredicted = associative_memory_32bit(query, aM_32);	
        postprocess(classpredicted, predictions, ix);
		toc(tvBegin, tvDiff, tvEnd);
    }
    return 0;
}

