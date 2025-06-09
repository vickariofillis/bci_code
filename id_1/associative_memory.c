#include "associative_memory.h"
#include "aux_functions.h"


int associative_memory_32bit(uint32_t q_32[bit_dim], uint32_t aM_32[bit_dim][classes]){
/*************************************************************************
	DESCRIPTION:  tests the accuracy based on input testing queries

	INPUTS:
		q_32        : query hypervector
		aM_32		: Trained associative memory
	OUYTPUTS:
		class       : classification result
**************************************************************************/

	int sims[classes] = {0};
	int class;


	//Computes Hamming Distances
	hamming_dist(q_32, aM_32, sims);

	//Classification with Hamming Metric
	class = min_dist_hamm(sims);
	printf("Interictal distance: %d Ictal distance %d\n", sims[1], sims[0]);


	return class;

}


