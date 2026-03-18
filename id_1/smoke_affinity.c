#define _GNU_SOURCE

#include <errno.h>
#include <omp.h>
#include <sched.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static int parse_positive_arg(const char *name, const char *value) {
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0) {
        fprintf(stderr, "ERROR: %s must be a positive integer, got '%s'\n", name, value);
        exit(1);
    }
    return (int)parsed;
}

int main(int argc, char *argv[]) {
    int thread_count = 1;
    int duration_sec = 5;

    for (int argi = 1; argi < argc; ++argi) {
        if (strcmp(argv[argi], "--threads") == 0) {
            if (argi + 1 >= argc) {
                fprintf(stderr, "ERROR: --threads requires an integer value\n");
                return 1;
            }
            thread_count = parse_positive_arg("--threads", argv[++argi]);
        } else if (strcmp(argv[argi], "--duration") == 0) {
            if (argi + 1 >= argc) {
                fprintf(stderr, "ERROR: --duration requires an integer value\n");
                return 1;
            }
            duration_sec = parse_positive_arg("--duration", argv[++argi]);
        } else if (strcmp(argv[argi], "--channels") == 0) {
            if (argi + 1 >= argc) {
                fprintf(stderr, "ERROR: --channels requires an integer value\n");
                return 1;
            }
            ++argi;
        }
    }

    int cpu_slots = (int)sysconf(_SC_NPROCESSORS_CONF);
    if (cpu_slots <= 0) {
        cpu_slots = 1024;
    }

    bool *seen = calloc((size_t)thread_count * (size_t)cpu_slots, sizeof(bool));
    int *samples = calloc((size_t)thread_count, sizeof(int));
    int *first_cpu = calloc((size_t)thread_count, sizeof(int));
    if (!seen || !samples || !first_cpu) {
        fprintf(stderr, "ERROR: failed to allocate smoke benchmark buffers\n");
        free(seen);
        free(samples);
        free(first_cpu);
        return 1;
    }

    for (int i = 0; i < thread_count; ++i) {
        first_cpu[i] = -1;
    }

    omp_set_num_threads(thread_count);
    const double deadline = monotonic_seconds() + (double)duration_sec;

    printf("SMOKE runtime configuration: threads=%d duration=%d\n", thread_count, duration_sec);
    fflush(stdout);

    #pragma omp parallel
    {
        const int tid = omp_get_thread_num();
        volatile unsigned long sink = (unsigned long)tid + 1UL;
        while (monotonic_seconds() < deadline) {
            int cpu = sched_getcpu();
            if (cpu >= 0) {
                if (first_cpu[tid] < 0) {
                    first_cpu[tid] = cpu;
                }
                if (cpu < cpu_slots) {
                    seen[(size_t)tid * (size_t)cpu_slots + (size_t)cpu] = true;
                }
                samples[tid] += 1;
            }
            sink = sink * 1103515245UL + 12345UL;
        }
        if (sink == 0UL) {
            fprintf(stderr, "unreachable\n");
        }
    }

    for (int tid = 0; tid < thread_count; ++tid) {
        printf("AFFINITY_SUMMARY tid=%d first_cpu=%d samples=%d cpus=", tid, first_cpu[tid], samples[tid]);
        int emitted = 0;
        for (int cpu = 0; cpu < cpu_slots; ++cpu) {
            if (!seen[(size_t)tid * (size_t)cpu_slots + (size_t)cpu]) {
                continue;
            }
            if (emitted++) {
                putchar(',');
            }
            printf("%d", cpu);
        }
        if (emitted == 0) {
            printf("none");
        }
        putchar('\n');
    }
    printf("Workload finished successfully\n");

    free(seen);
    free(samples);
    free(first_cpu);
    return 0;
}
