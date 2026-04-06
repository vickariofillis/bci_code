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
    MODE_STRIDECHASE,
    MODE_PAIRCHASE,
    MODE_PAIRDELAY,
} bench_mode_t;

typedef struct {
    bench_mode_t mode;
    double seconds;
    uint64_t iterations;
    size_t size_bytes;
    size_t stride_bytes;
    int read_only;
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

static void build_random_order(uint32_t *order, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        order[i] = (uint32_t)i;
    }
    for (size_t i = count; i > 1; --i) {
        size_t j = (size_t)(mix64((uint64_t)i * 0x9e3779b97f4a7c15ULL) % i);
        uint32_t tmp = order[i - 1];
        order[i - 1] = order[j];
        order[j] = tmp;
    }
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
    } else if (ctx->mode == MODE_STRIDECHASE) {
        size_t node_bytes = stride_bytes < 64 ? 64 : stride_bytes;
        size_t count = size_bytes / node_bytes;
        if (count == 0) {
            count = 1;
        }
        unsigned char *buf = xaligned_alloc(64, count * node_bytes);
        if (buf == NULL) {
            fprintf(stderr, "posix_memalign failed for stridechase buffer\n");
            exit(2);
        }
        for (size_t i = 0; i < count; ++i) {
            uint32_t *node = (uint32_t *)(buf + i * node_bytes);
            node[0] = (uint32_t)((i + 1) % count);
            node[1] = (uint32_t)(i ^ 0x5a5a5a5aU);
        }
        uint32_t index = (uint32_t)(ctx->thread_index % count);
        uint64_t loops = 0;
        do {
            for (size_t i = 0; i < count; ++i) {
                uint32_t *node = (uint32_t *)(buf + ((size_t)index * node_bytes));
                index = node[0];
                checksum += (double)node[1];
            }
            work_units += (double)(count * node_bytes);
            ++loops;
        } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                 (ctx->seconds <= 0.0 && loops < iterations));
        free(buf);
    } else if (ctx->mode == MODE_PAIRCHASE || ctx->mode == MODE_PAIRDELAY) {
        const size_t line_bytes = 64;
        size_t sector_bytes = stride_bytes < (2 * line_bytes) ? (2 * line_bytes) : stride_bytes;
        size_t count = size_bytes / sector_bytes;
        if (count == 0) {
            count = 1;
        }
        unsigned char *buf = xaligned_alloc(128, count * sector_bytes);
        uint32_t *order = malloc(count * sizeof(*order));
        if (buf == NULL || order == NULL) {
            fprintf(stderr, "allocation failed for pairchase buffer\n");
            exit(2);
        }
        build_random_order(order, count);
        for (size_t i = 0; i < count; ++i) {
            size_t next_index = (i + 1) % count;
            uint32_t *first_line = (uint32_t *)(buf + ((size_t)order[i] * sector_bytes));
            double *second_line = (double *)(buf + ((size_t)order[i] * sector_bytes) + line_bytes);
            first_line[0] = order[next_index];
            second_line[0] = (double)(order[i] + 1U) * 1.5;
        }
        uint32_t index = order[ctx->thread_index % count];
        uint32_t prev_index = index;
        int have_prev = 0;
        uint64_t loops = 0;
        do {
            for (size_t i = 0; i < count; ++i) {
                unsigned char *sector = buf + ((size_t)index * sector_bytes);
                uint32_t *first_line = (uint32_t *)sector;
                uint32_t next = first_line[0];
                if (ctx->mode == MODE_PAIRCHASE) {
                    double *second_line = (double *)(sector + line_bytes);
                    checksum += second_line[0];
                } else {
                    if (have_prev) {
                        unsigned char *prev_sector = buf + ((size_t)prev_index * sector_bytes);
                        double *prev_second = (double *)(prev_sector + line_bytes);
                        checksum += prev_second[0];
                    }
                    prev_index = index;
                    have_prev = 1;
                }
                index = next;
            }
            if (ctx->mode == MODE_PAIRDELAY && have_prev) {
                unsigned char *prev_sector = buf + ((size_t)prev_index * sector_bytes);
                double *prev_second = (double *)(prev_sector + line_bytes);
                checksum += prev_second[0];
            }
            work_units += (double)(count * (2 * line_bytes));
            ++loops;
        } while ((ctx->seconds > 0.0 && now_seconds() < deadline) ||
                 (ctx->seconds <= 0.0 && loops < iterations));
        free(order);
        free(buf);
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
                    if (ctx->read_only) {
                        checksum += buf[i];
                    } else {
                        buf[i] = buf[i] * 1.0000001 + 1.0;
                        checksum += buf[i];
                    }
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
    if (strcmp(value, "stridechase") == 0) {
        return MODE_STRIDECHASE;
    }
    if (strcmp(value, "pairchase") == 0) {
        return MODE_PAIRCHASE;
    }
    if (strcmp(value, "pairdelay") == 0) {
        return MODE_PAIRDELAY;
    }
    fprintf(stderr, "Unknown mode: %s\n", value);
    exit(2);
}

int main(int argc, char **argv) {
    bench_mode_t mode = MODE_STREAM;
    double seconds = 1.0;
    uint64_t iterations = 0;
    size_t size_mb = 256;
    size_t size_kb = 0;
    size_t stride_bytes = 64;
    unsigned threads = 1;
    int read_only = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = parse_mode(argv[++i]);
        } else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
            parse_double_value("--seconds", argv[++i], &seconds);
        } else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
            parse_u64("--iterations", argv[++i], &iterations);
        } else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc) {
            parse_size_t_value("--size-mb", argv[++i], &size_mb);
        } else if (strcmp(argv[i], "--size-kb") == 0 && i + 1 < argc) {
            parse_size_t_value("--size-kb", argv[++i], &size_kb);
        } else if (strcmp(argv[i], "--stride-bytes") == 0 && i + 1 < argc) {
            parse_size_t_value("--stride-bytes", argv[++i], &stride_bytes);
        } else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            uint64_t tmp = 0;
            parse_u64("--threads", argv[++i], &tmp);
            threads = (unsigned)(tmp == 0 ? 1 : tmp);
        } else if (strcmp(argv[i], "--read-only") == 0) {
            read_only = 1;
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
        if (size_kb > 0) {
            ctxs[i].size_bytes = size_kb * 1024UL;
        } else {
            ctxs[i].size_bytes = size_mb * 1024UL * 1024UL;
        }
        ctxs[i].stride_bytes = stride_bytes;
        ctxs[i].read_only = read_only;
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
        case MODE_STRIDECHASE: mode_name = "stridechase"; break;
        case MODE_PAIRCHASE: mode_name = "pairchase"; break;
        case MODE_PAIRDELAY: mode_name = "pairdelay"; break;
    }

    printf(
        "{\"mode\":\"%s\",\"threads\":%u,\"read_only\":%s,\"elapsed_sec\":%.6f,\"work_units\":%.3f,"
        "\"throughput_mb_s\":%.3f,\"ops_per_sec\":%.3f,\"checksum\":%.6f}\n",
        mode_name,
        threads,
        read_only ? "true" : "false",
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
