#include "aux_functions.h"

#define CORE 8


int min_dist_hamm(int distances[classes]){
/*************************************************************************
	DESCRIPTION: computes the maximum Hamming Distance.

	INPUTS:
		distances     : distances associated to each class
	OUTPUTS:
		min_index     : the class related to the minimum distance
**************************************************************************/
	int min = distances[0];
	int min_index = 0;
	int i;
	for(i = 0; i < classes; i++){

		if(min > distances[i]){

			min = distances[i];
			min_index = i;

		}

	}

	return min_index;
}


void hamming_dist(uint32_t q[bit_dim], uint32_t aM[bit_dim ][classes], int sims[classes]){
/**************************************************************************
	DESCRIPTION: computes the Hamming Distance for each class.

	INPUTS:
		q        : query hypervector
		aM		 : Associative Memory matrix

	OUTPUTS:
		sims	 : Distances' vector
***************************************************************************/
	
	int r_tmp = 0;
	#pragma omp parallel num_threads(CORE)
	{
	uint32_t tmp2 = 0;
	for(int i = 0; i < classes; i++){
		#pragma omp for reduction(+:r_tmp)
		for(int j = 0; j < bit_dim; j++){
			tmp2 = q[j] ^ aM[j][i];
			r_tmp += numberOfSetBits(tmp2);
		}
		#pragma omp master
		{
		sims[i] = r_tmp;
		r_tmp = 0;
		}
		#pragma omp barrier
	}
	}//omp
}

int numberOfSetBits(uint32_t i)
{
/*************************************************************************
	DESCRIPTION:   computes the number of 1's

	INPUTS:
		i        :  the i-th variable that composes the hypervector

**************************************************************************/

  i = i - ((i >> 1) & 0x55555555);
  i = (i & 0x33333333) + ((i >> 2) & 0x33333333);
  return (((i + (i >> 4)) & 0x0F0F0F0F) * 0x01010101) >> 24;
}

void temporal_encoder(uint32_t chT[N/2][bit_dim], uint32_t query[bit_dim])
{
/*************************************************************************
	DESCRIPTION:   compute the final encoded vector for a time window

	INPUTS:
		chT      :  Matrix with all the vectors of each single point inside the window
		query    :  output encoded vector of the window

**************************************************************************/

#pragma omp parallel num_threads(CORE)
{
int majority;
majority = 0;
#pragma omp for	
for (int i = 0; i < bit_dim; i++){
	query[i] = 0;

	for(int z = 31; z >= 0; z--){
		for (int j = 0; j < N/2; j++){
			majority = majority + ((chT[j][i] & ( 1 << z)) >> z);
		}
		if (majority > (float)N/4) query[i] = query[i] | ( 1 << z ) ;
			majority = 0;
	}
}

}
}

void LBP_Spatial_encoding(char LBP_buffer[channels], uint32_t chHV[CHANNELS_VOTING][bit_dim],uint32_t chT[N/2][bit_dim], float Test_EEG_old[channels], int ix, int wind)
/*************************************************************************
DESCRIPTION:   extract the LBP codes and encode the full vector representing a single point of iEEG recording.
			   Furthermore, computes the spatial vector and insert in the correct position in the matrix of the window.

	INPUTS:
		LBP_buffer  :  Matrix of LBP codes for each channel
		Test_EEG_old:  Previous value of EEG for each channel
		chHV        :  Matrix of the vectors of channels for a single point
		ix & wind   :  Indexes
		chT         :  Matrix where we encode a whole window

**************************************************************************/

{
	uint32_t spatialVector[bit_dim] = {0};
#pragma omp parallel num_threads(CORE)
{
	int j;
	uint32_t tmp = 0;		
	int majority = 0;
#pragma omp master
{
for(j = 0; j < channels; j++){
    LBP_buffer[j] = (LBP_buffer[j] << 1) & 0x3F;
    if (Test_EEG1[ix+wind][j] >Test_EEG_old[j])
		LBP_buffer[j] = LBP_buffer[j] | 0x01;
	Test_EEG_old[j] = Test_EEG1[ix+wind][j];
}
}
#pragma omp barrier
#pragma omp for
for(int i = 0; i < bit_dim ; i++){
	for(j = 0; j < channels; j++){
	tmp = iM[i][(int)LBP_buffer[j]] ^ ciM[i][j];
	chHV[j][i] = tmp;
	}
    for(int z = 31; z >= 0; z--){    
        for (int j = 0; j < CHANNELS_VOTING; j++){
            majority = majority + ((chHV[j][i] & ( 1 << z)) >> z);
        }
        if (majority > (float)channels/2) spatialVector[i] = spatialVector[i] | ( 1 << z ) ;
            majority = 0;
    }
	chT[wind][i] = spatialVector[i];
}
}//omp
}

int postprocess(int prediction, int predictions[DIM_WINDOW_POST], int ix){
/*************************************************************************
	DESCRIPTION:  gives the final prevision after the analysis of the last 5 seconds

	INPUTS:
		prediction          : prediction relative to the last window
		predictions	        : previsions of the previous 5 seconds
		threshold           : threshold to use inside this big window to assess a seizure onset
	OUYTPUTS:
		final_prediction    : classification result
**************************************************************************/

    int majority,i;
    int classpredicted;
	//Here because the ictal prototype, namely 1, is in position 0, so we have to revert the previsions (0-->1 1-->0)
	classpredicted = abs(prediction-1);
    majority = 0;
    for (i=0; i<9;i++){
		predictions[i]=predictions[i+1];
		majority = majority + predictions[i];
	}
    predictions[9]=classpredicted;
    majority = majority + predictions[9];
    if (majority > threshold)
		printf ("Ictal at time %f \n", (float)ix/N);
	else
		printf("This is the prevision before majority: %d, this one after: %d at time %f\n", classpredicted,majority, (float)ix/N);
    return 0;
}


int timeval_subtract(struct timeval *result, struct timeval *t2, struct timeval *t1)
{
    long int diff = (t2->tv_usec + 1000000 * t2->tv_sec) - (t1->tv_usec + 1000000 * t1->tv_sec);
    result->tv_sec = diff / 1000000;
    result->tv_usec = diff % 1000000;

    return (diff<0);
}
void tic(struct timeval *tvBegin)
{
    gettimeofday(tvBegin, NULL);
}
void toc(struct timeval tvBegin,struct timeval tvDiff,struct timeval tvEnd)
{
    gettimeofday(&tvEnd, NULL);
    timeval_subtract(&tvDiff, &tvEnd, &tvBegin);
    printf("%ld.%06ld\n", tvDiff.tv_sec, tvDiff.tv_usec);
}
