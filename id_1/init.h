#ifndef INIT_H_
#define INIT_H_

#include <stdint.h>
#include <math.h>
#include "omp.h"

//All these data refer to a specific patient, i.e. the patient n.16.
//dimension of the hypervectors
#define dimension 10000
//number of classes to be classify
#define classes 2
//number of acquisition's channels
#define channels 56
//dimension of the hypervectors after compression (dimension/32 rounded to the smallest integer)
#define bit_dim 312
//CHANNELS_VOTING for the componentwise majority must be odd
#define CHANNELS_VOTING channels + 1
//Frequency of the signal, used to divide the input data.
#define fs      512

// Allow the number of minutes of data to be changed at compile time.
// Default is 4 minutes for the original short test data.
#ifndef ID1_MINUTES
#define ID1_MINUTES 4
#endif
#define minutes ID1_MINUTES

#define seconds 60
//Number of seizures
#define SEIZ 9
//Small window dimension
#define N fs
//threshold for the post processing
#define threshold 9
//dimension of window of postprocessing: 5 seconds, 10 window of 0.5 seconds without overlap
#define DIM_WINDOW_POST 10

#endif
