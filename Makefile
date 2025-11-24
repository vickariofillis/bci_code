CC ?= gcc
CFLAGS ?= -std=c99 -fopenmp
LDFLAGS ?= -lm

# ID1 sources (main includes the auxiliary C files directly)
ID1_SRCS = id_1/main.c
ID1_OBJS = $(ID1_SRCS)

# ID1 executables for test and patient modes
ID1_TEST_CFLAGS    = $(CFLAGS)    -Iid_1 -Iid_1/test    -DID1_MINUTES=4
ID1_PATIENT_CFLAGS = $(CFLAGS)    -Iid_1 -Iid_1/patient -DID1_MINUTES=60

all: id_1/main_test id_1/main_patient

id_1/main: $(ID1_OBJS)
	$(CC) $(ID1_TEST_CFLAGS) -o $@ $(ID1_OBJS) $(LDFLAGS)

id_1/main_test: $(ID1_OBJS)
	$(CC) $(ID1_TEST_CFLAGS) -o $@ $(ID1_OBJS) $(LDFLAGS)

id_1/main_patient: $(ID1_OBJS)
	$(CC) $(ID1_PATIENT_CFLAGS) -o $@ $(ID1_OBJS) $(LDFLAGS)

.PHONY: all clean

clean:
	$(RM) id_1/main id_1/main_test id_1/main_patient id_1/*.o
