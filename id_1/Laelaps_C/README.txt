In this folder we present Laelaps algorithm, implemented with C programming language and parallelized using OpenMP.
The reported version works with data of Patient 12 of the dataset, but it is general and adaptable to any patient.
List of files:
- associative_memory.h: function interface of the corresponding .c file.
- associative_memory.c: contains the function to classify the query vector, comparing it with the associative memory.
- aux_functions.h: function interface of the corresponding .c file.
- aux_functions.c: It contains all the principal functions of the algorithm: (1) LBP_Spatial_encoding, (2) temporal_encoder, (3) postprocess. All the functions are parallelized among multiple threads.
- data.h: it holds the item memories and the associative_memory 
- data2.h: it contains the test sample of the iEEG segment of Patient 12: seizure starts approximately after second 220.
- init.h: contains all the initialization, from frequency to number of channel or dimension of hypervectors.
- main.c: it call the previous functions to calssify an iEEG segment.
The commands to compile and then execute the program on a Linux shell are:
gcc -std=c99 -fopenmp main.c -o main -lm command
./main