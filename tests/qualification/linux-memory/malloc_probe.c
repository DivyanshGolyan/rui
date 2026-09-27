/* Diagnostic preload only. Its worker/stdio allocations perturb the process;
 * never use this library for uninstrumented memory or CPU qualification. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <malloc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char directory[PATH_MAX];
static char fifo_path[PATH_MAX];

static void *collect(void *unused) {
    (void)unused;
    int fifo = open(fifo_path, O_RDWR | O_CLOEXEC);
    if (fifo < 0) _exit(90);
    unsigned sequence = 0;
    for (;;) {
        char command;
        ssize_t count = read(fifo, &command, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count != 1 || (command != 's' && command != 't')) _exit(91);
        struct timespec before, after;
        if (clock_gettime(CLOCK_MONOTONIC, &before)) _exit(92);
        int trimmed = command == 't' ? malloc_trim(0) : 0;
        if (clock_gettime(CLOCK_MONOTONIC, &after)) _exit(92);
        struct mallinfo2 info = mallinfo2();
        char xml[PATH_MAX], temporary[PATH_MAX], final[PATH_MAX];
        ++sequence;
        if (snprintf(xml, sizeof(xml), "%s/%ld-%u.xml", directory, (long)getpid(), sequence) >= (int)sizeof(xml) ||
            snprintf(temporary, sizeof(temporary), "%s/%ld-%u.tmp", directory, (long)getpid(), sequence) >= (int)sizeof(temporary) ||
            snprintf(final, sizeof(final), "%s/%ld-%u.json", directory, (long)getpid(), sequence) >= (int)sizeof(final)) _exit(93);
        FILE *output = fopen(xml, "w");
        if (!output) _exit(94);
        if (malloc_info(0, output) || fclose(output)) _exit(95);
        output = fopen(temporary, "w");
        if (!output) _exit(94);
        long long elapsed = (after.tv_sec - before.tv_sec) * 1000000000LL + after.tv_nsec - before.tv_nsec;
        if (fprintf(output,
                    "{\"arena_bytes\":%zu,\"mmap_bytes\":%zu,\"in_use_bytes\":%zu,"
                    "\"free_arena_bytes\":%zu,\"top_releasable_bytes\":%zu,"
                    "\"trim_requested\":%s,\"trim_return\":%d,\"trim_elapsed_ns\":%lld}\n",
                    info.arena, info.hblkhd, info.uordblks, info.fordblks, info.keepcost,
                    command == 't' ? "true" : "false", trimmed, elapsed) < 0 || fclose(output)) _exit(95);
        if (rename(temporary, final)) _exit(96);
    }
}

__attribute__((constructor)) static void start(void) {
    const char *path = getenv("RUI_MALLOC_AUDIT_DIR");
    if (!path) return;
    if (snprintf(directory, sizeof(directory), "%s", path) >= (int)sizeof(directory) ||
        snprintf(fifo_path, sizeof(fifo_path), "%s/%ld.command", path, (long)getpid()) >= (int)sizeof(fifo_path)) _exit(97);
    if (mkfifo(fifo_path, 0600)) _exit(98);
    pthread_t thread;
    if (pthread_create(&thread, NULL, collect, NULL) || pthread_detach(thread)) _exit(99);
}
