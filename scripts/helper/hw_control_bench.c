#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef enum {
    MODE_COMPUTE,
    MODE_STREAM,
    MODE_STRIDE,
    MODE_PTRCHASE,
    MODE_CACHEFIT,
    MODE_ADJACENT,
} bench_mode_t;

typedef struct {
    bench_mode_t mode;
    double seconds;
    uint64_t iterations;
    size_t size_bytes;
    size_t stride_bytes;
    unsigned thread_index;
    unsigned thread_count;
    double elapsed_seconds;
    double checksum;
    double work_units;
} worker_ctx_t;

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void *xaligned_alloc(size_t alignment, size_t size) {
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) {
        return NULL;
    }
    memset(ptr, 0, size);
    return ptr;
}

static void parse_u64(const char *label, const char *value, uint64_t *out) {
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        fprintf(stderr, "Invalid value for %s: %s\n", label, value);
        exit(2);
    }
    *out = (uint64_t)parsed;
}

static void parse_size_t_value(const char *label, const char *value, size_t *out) {
    uint64_t tmp = 0;
    parse_u64(label, value, &tmp);
    *out = (size_t)tmp;
}

static void parse_double_value(const char *label, const char *value, double *out) {
    char *end = NULL;
    errno = 0;
    double parsed = strtod(value, &end);
    if (errno != 0 || end == value || *end != '\0') {
        fprintf(stderr, "Invalid value for %s: %s\n", label, value);
        exit(2);
    }
    *out = parsed;
}

static uint64_t mix64(uint64_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static void build_ptrchase_ring(uint32_t *next, size_t count) {
    if (count == 0) {
        return;
    }
    uint32_t *order = malloc(count * sizeof(*order));
    if (order == NULL) {
        fprintf(stderr, "malloc failed while building ptrchase ring\n");
        exit(2);
    }
    for (size_t i = 0; i < count; ++i) {
        order[i] = (uint32_t)i;
    }
    for (size_t i = count; i > 1; --i) {
        size_t j = (size_t)(mix64((uint64_t)i * 0x9e3779b97f4a7c15ULL) % i);
        uint32_t tmp = order[i - 1];
        order[i - 1] = order[j];
        order[j] = tmp;
    }
    for (size_t i = 0; i + 1 < count; ++i) {
        next[order[i]] = order[i + 1];
    }
    next[order[count - 1]] = order[0];
    free(order);
}

static void *worker_main(void *arg) {
    worker_ctx_t *ctx = (worker_ctx_t *)arg;
    const size_t min_bytes = 64 * 1024;
    size_t size_bytes = ctx->size_bytes < min_bytes ? min_bytes : ctx->size_bytes;
    size_t stride_bytes = ctx->stride_bytes == 0 ? 64 : ctx->stride_bytes;
    uint64_t iterations = ctx->iterations == 0 ? 1 : ctx->iterations;
    double checksum = 0.0;
    double work_units = 0.0;
    double start = now_seconds();
    double deadline = ctx->seconds > 0.0 ? start + ctx->seconds : 0.0;

    if (ctx->mode == MODE_COMPUTE) {
        uint64_t loops = 0;
        double a = 1.0000001 + (double)ctx->thread_index;
        double b = 0.9999993 + (double)(ctx->thread_index + 1);
        do {
            for (uint64_t i = 0; i < 2000000ULL; ++i) {
                a = a * 1.00000011920928955078125 + b;
                b = b * 0.999999940395355224609375 + a;
            }
            checksum += a + b;
            work_units += 4000000.0;
            ++loops;
        } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                 (ctx->seconds <= 0.0 && loops < iterations));
    } else if (ctx->mode == MODE_PTRCHASE) {
        size_t entries = size_bytes / sizeof(uint32_t);
        uint32_t *next = xaligned_alloc(64, entries * sizeof(*next));
        if (next == NULL) {
            fprintf(stderr, "posix_memalign failed for ptrchase buffer\n");
            exit(2);
        }
        build_ptrchase_ring(next, entries);
        uint32_t index = (uint32_t)(ctx->thread_index % (entries == 0 ? 1 : entries));
        uint64_t loops = 0;
        do {
            for (size_t i = 0; i < entries; ++i) {
                index = next[index];
                checksum += (double)index;
            }
            work_units += (double)(entries * sizeof(uint32_t));
            ++loops;
        } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                 (ctx->seconds <= 0.0 && loops < iterations));
        free(next);
    } else {
        size_t doubles = size_bytes / sizeof(double);
        if (doubles == 0) {
            doubles = 1;
        }
        double *buf = xaligned_alloc(64, doubles * sizeof(*buf));
        if (buf == NULL) {
            fprintf(stderr, "posix_memalign failed for data buffer\n");
            exit(2);
        }
        for (size_t i = 0; i < doubles; ++i) {
            buf[i] = (double)i * 0.5 + (double)ctx->thread_index;
        }
        size_t stride = stride_bytes / sizeof(double);
        if (stride == 0) {
            stride = 1;
        }
        if (ctx->mode == MODE_STREAM) {
            stride = 1;
        }
        if (ctx->mode == MODE_CACHEFIT) {
            stride = 8;
        }

        uint64_t loops = 0;
        if (ctx->mode == MODE_ADJACENT) {
            const size_t line_doubles = 64 / sizeof(double);
            size_t sector_stride = stride_bytes / sizeof(double);
            if (sector_stride < (2 * line_doubles)) {
                sector_stride = 2 * line_doubles;
            }
            do {
                for (size_t i = 0; i + line_doubles < doubles; i += sector_stride) {
                    const double first = buf[i];
                    const double second = buf[i + line_doubles];
                    checksum += first + second;
                    work_units += 2.0 * sizeof(double);
                }
                ++loops;
            } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                     (ctx->seconds <= 0.0 && loops < iterations));
        } else {
            do {
                for (size_t i = 0; i < doubles; i += stride) {
                    buf[i] = buf[i] * 1.0000001 + 1.0;
                    checksum += buf[i];
                    work_units += sizeof(double);
                }
                ++loops;
            } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                     (ctx->seconds <= 0.0 && loops < iterations));
        }
        free(buf);
    }

    ctx->elapsed_seconds = now_seconds() - start;
    ctx->checksum = checksum;
    ctx->work_units = work_units;
    return NULL;
}

static bench_mode_t parse_mode(const char *value) {
    if (strcmp(value, "compute") == 0) {
        return MODE_COMPUTE;
    }
    if (strcmp(value, "stream") == 0) {
        return MODE_STREAM;
    }
    if (strcmp(value, "stride") == 0) {
        return MODE_STRIDE;
    }
    if (strcmp(value, "ptrchase") == 0) {
        return MODE_PTRCHASE;
    }
    if (strcmp(value, "cachefit") == 0) {
        return MODE_CACHEFIT;
    }
    if (strcmp(value, "adjacent") == 0) {
        return MODE_ADJACENT;
    }
    fprintf(stderr, "Unknown mode: %s\n", value);
    exit(2);
}

int main(int argc, char **argv) {
    bench_mode_t mode = MODE_STREAM;
    double seconds = 1.0;
    uint64_t iterations = 0;
    size_t size_mb = 256;
    size_t stride_bytes = 64;
    unsigned threads = 1;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = parse_mode(argv[++i]);
        } else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
            parse_double_value("--seconds", argv[++i], &seconds);
        } else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
            parse_u64("--iterations", argv[++i], &iterations);
        } else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc) {
            parse_size_t_value("--size-mb", argv[++i], &size_mb);
        } else if (strcmp(argv[i], "--stride-bytes") == 0 && i + 1 < argc) {
            parse_size_t_value("--stride-bytes", argv[++i], &stride_bytes);
        } else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            uint64_t tmp = 0;
            parse_u64("--threads", argv[++i], &tmp);
            threads = (unsigned)(tmp == 0 ? 1 : tmp);
        } else {
            fprintf(stderr, "Unknown or incomplete argument: %s\n", argv[i]);
            return 2;
        }
    }

    pthread_t *thread_ids = calloc(threads, sizeof(*thread_ids));
    worker_ctx_t *ctxs = calloc(threads, sizeof(*ctxs));
    if (thread_ids == NULL || ctxs == NULL) {
        fprintf(stderr, "Allocation failure for thread state\n");
        return 2;
    }

    double wall_start = now_seconds();
    for (unsigned i = 0; i < threads; ++i) {
        ctxs[i].mode = mode;
        ctxs[i].seconds = seconds;
        ctxs[i].iterations = iterations;
        ctxs[i].size_bytes = size_mb * 1024UL * 1024UL;
        ctxs[i].stride_bytes = stride_bytes;
        ctxs[i].thread_index = i;
        ctxs[i].thread_count = threads;
        if (pthread_create(&thread_ids[i], NULL, worker_main, &ctxs[i]) != 0) {
            fprintf(stderr, "pthread_create failed for thread %u\n", i);
            return 2;
        }
    }

    double checksum = 0.0;
    double work_units = 0.0;
    double max_elapsed = 0.0;
    for (unsigned i = 0; i < threads; ++i) {
        pthread_join(thread_ids[i], NULL);
        checksum += ctxs[i].checksum;
        work_units += ctxs[i].work_units;
        if (ctxs[i].elapsed_seconds > max_elapsed) {
            max_elapsed = ctxs[i].elapsed_seconds;
        }
    }
    double wall_elapsed = now_seconds() - wall_start;
    double effective_elapsed = max_elapsed > wall_elapsed ? max_elapsed : wall_elapsed;
    double throughput_mb_s = effective_elapsed > 0.0 ? (work_units / (1024.0 * 1024.0)) / effective_elapsed : 0.0;
    double ops_per_sec = effective_elapsed > 0.0 ? work_units / effective_elapsed : 0.0;

    const char *mode_name = "stream";
    switch (mode) {
        case MODE_COMPUTE: mode_name = "compute"; break;
        case MODE_STREAM: mode_name = "stream"; break;
        case MODE_STRIDE: mode_name = "stride"; break;
        case MODE_PTRCHASE: mode_name = "ptrchase"; break;
        case MODE_CACHEFIT: mode_name = "cachefit"; break;
        case MODE_ADJACENT: mode_name = "adjacent"; break;
    }

    printf(
        "{\"mode\":\"%s\",\"threads\":%u,\"elapsed_sec\":%.6f,\"work_units\":%.3f,"
        "\"throughput_mb_s\":%.3f,\"ops_per_sec\":%.3f,\"checksum\":%.6f}\n",
        mode_name,
        threads,
        effective_elapsed,
        work_units,
        throughput_mb_s,
        ops_per_sec,
        checksum
    );

    free(thread_ids);
    free(ctxs);
    return 0;
}
