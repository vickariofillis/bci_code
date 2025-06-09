#ifndef AUX_FUNCTIONS_H_
#define AUX_FUNCTIONS_H_

#include "init.h"

void hamming_dist(uint32_t q[bit_dim], uint32_t aM[bit_dim][classes], int sims[classes]);
int min_dist_hamm(int distances[classes]);
int numberOfSetBits(uint32_t i);
void temporal_encoder(uint32_t chT[N/2][bit_dim], uint32_t query[bit_dim]);
void LBP_Spatial_encoding(char LBP_buffer[channels], uint32_t chHV[CHANNELS_VOTING][bit_dim],uint32_t chT[N/2][bit_dim], float Test_EEG_old[channels], int ix, int wind);
int postprocess(int prediction, int predictions[DIM_WINDOW_POST], int ix);
int timeval_subtract(struct timeval *result, struct timeval *t2, struct timeval *t1);
void tic(struct timeval *tvBegin);
void toc(struct timeval tvBegin,struct timeval tvDiff,struct timeval tvEnd);
#endif
