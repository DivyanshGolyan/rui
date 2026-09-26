#include "../../src/evaluator_parent.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct cancellation { int immediate; struct timespec start; };

static int cancelled(void *context) {
    struct cancellation *state = context;
    if (state->immediate) return 1;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - state->start.tv_sec) * 1000000000LL +
        now.tv_nsec - state->start.tv_nsec >= 100000000LL;
}

static int descriptor_count(void) {
    DIR *directory = opendir("/dev/fd");
    if (!directory) return -1;
    int count = -1; /* Exclude the directory's own descriptor. */
    while (readdir(directory)) count++;
    closedir(directory);
    return count;
}

static int stall_output(void *context, uint64_t amount) {
    (void)context;
    (void)amount;
    struct timespec delay = {6, 0};
    while (nanosleep(&delay, &delay) && errno == EINTR) {}
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 5 && argc != 6) return 2;
    int input = open(argv[2], O_RDONLY);
    char output_path[] = "/tmp/rui-evaluator-result-XXXXXX";
    int output = mkstemp(output_path);
    unlink(output_path);
    if (input < 0 || output < 0) return 3;
    int prepared = -1;
    if (!strcmp(argv[3], "run-input") || !strcmp(argv[3], "run-input-rw")) {
        if (argc != 6) return 2;
        prepared = open(argv[5], !strcmp(argv[3], "run-input-rw") ? O_RDWR : O_RDONLY);
        if (prepared < 0) return 3;
    } else if (strcmp(argv[3], "check") != 0) {
        char prepared_path[] = "/tmp/rui-evaluator-input-XXXXXX";
        int writer = mkstemp(prepared_path);
        if (writer < 0 || write(writer, "\5\0\0\0\0", 5) != 5 || close(writer)) return 3;
        prepared = open(prepared_path, O_RDONLY);
        unlink(prepared_path);
        if (prepared < 0) return 3;
    }
    int repeat = !strcmp(argv[3], "repeat") ? 1000 : 1;
    struct cancellation cancellation = {.immediate = !strcmp(argv[3], "cancel")};
    clock_gettime(CLOCK_MONOTONIC, &cancellation.start);
    int use_cancel = cancellation.immediate || !strcmp(argv[3], "live-cancel");
    int stall = !strcmp(argv[3], "stall-write");
    int baseline = descriptor_count();
    int result = 0;
    if (!strcmp(argv[3], "run-input-rw") && write(output, "partial", 7) != 7)
        return 4;
    char diagnostic[4096];
    size_t diagnostic_length = 0;
    int check = !strcmp(argv[3], "check");
    for (int i = 0; i < repeat && result == 0; i++)
        result = rui_evaluate(argv[1], input, prepared, output,
                              strtoull(argv[4], NULL, 10), check,
                              use_cancel ? cancelled : NULL, &cancellation,
                              stall ? stall_output : NULL, NULL,
                              check ? diagnostic : NULL, check ? sizeof(diagnostic) : 0,
                              check ? &diagnostic_length : NULL);
    if (use_cancel && result != 1) return 6;
    if (descriptor_count() != baseline) return 7;
    if (result && check && diagnostic_length &&
        write(STDERR_FILENO, diagnostic, diagnostic_length) != (ssize_t)diagnostic_length)
        return 4;
    struct stat output_stat;
    if (result != 0 && (!fstat(output, &output_stat) && output_stat.st_size != 0))
        return 5;
    if (result == 0) {
        char window[4096];
        lseek(output, 0, SEEK_SET);
        ssize_t n;
        while ((n = read(output, window, sizeof(window))) > 0) {
            if (write(STDOUT_FILENO, window, (size_t)n) != n) return 4;
        }
    }
    close(input);
    if (prepared >= 0) close(prepared);
    close(output);
    return result == 0 ? 0 : 1;
}
