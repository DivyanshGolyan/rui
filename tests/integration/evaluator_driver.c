#define _GNU_SOURCE
#include "../../src/evaluator_parent.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "evaluator_race.h"

struct cancellation {
    int immediate;
    const char *ready;
    const char *gate_entered;
    atomic_int output_seen;
    pthread_t caller;
    const char *watchdog_gate;
};

static int cancelled(void *context) {
    struct cancellation *state = context;
    if (state->watchdog_gate && !pthread_equal(pthread_self(), state->caller)) {
        int fd;
        do { fd = open(state->watchdog_gate, O_RDONLY); } while (fd < 0 && errno == EINTR);
        if (fd < 0) return 1;
        int entered = open(state->gate_entered, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (entered < 0 || close(entered)) { close(fd); return 1; }
        char release;
        ssize_t count;
        do { count = read(fd, &release, 1); } while (count < 0 && errno == EINTR);
        close(fd);
        if (count != 1 || release != 'r') return 1;
        state->watchdog_gate = NULL;
    }
    return state->immediate || atomic_load(&state->output_seen) ||
        (state->ready && access(state->ready, F_OK) == 0);
}

static void child_notice(int number) { (void)number; }

static int descriptor_count(void) {
    DIR *directory = opendir("/dev/fd");
    if (!directory) return -1;
    int count = -1; /* Exclude the directory's own descriptor. */
    while (readdir(directory)) count++;
    closedir(directory);
    return count;
}

struct output_sink {
    int fd; uint64_t budget, length;
    const char *append_gate;
    const char *gate_entered;
    struct cancellation *cancel_on_output;
};

static int append_output(void *context, const unsigned char *bytes, size_t length) {
    struct output_sink *sink = context;
    if (sink->append_gate) {
        int fd;
        do { fd = open(sink->append_gate, O_RDONLY); } while (fd < 0 && errno == EINTR);
        if (fd < 0) return -1;
        int entered = open(sink->gate_entered, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (entered < 0 || close(entered)) { close(fd); return -1; }
        char release;
        ssize_t count;
        do { count = read(fd, &release, 1); } while (count < 0 && errno == EINTR);
        close(fd);
        if (count != 1 || release != 'r') return -1;
        sink->append_gate = NULL;
    }
    if (length > sink->budget - sink->length) return -1;
    size_t remaining = length;
    while (remaining) {
        ssize_t count = write(sink->fd, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        remaining -= (size_t)count;
    }
    sink->length += length;
    if (length && sink->cancel_on_output)
        atomic_store(&sink->cancel_on_output->output_seen, 1);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "terminal-decisions"))
        return check_terminal_decisions();
    if (argc != 5 && argc != 6 && argc != 7) return 2;
    int ignored_child = !strcmp(argv[3], "check-ignored-sigchld");
    int no_child_wait = !strcmp(argv[3], "check-no-cldwait");
    int handled_child = !strcmp(argv[3], "check-handled-sigchld");
    race.mode = !strcmp(argv[3], "stale-watchdog");
    race.caller = pthread_self();
    int signal_case = ignored_child || no_child_wait || handled_child;
    int check = !strcmp(argv[3], "check") || signal_case;
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
    } else if (!check) {
        char prepared_path[] = "/tmp/rui-evaluator-input-XXXXXX";
        int writer = mkstemp(prepared_path);
        if (writer < 0 || close(writer)) return 3;
        prepared = open(prepared_path, O_RDONLY);
        unlink(prepared_path);
        if (prepared < 0) return 3;
    }
    int repeat = !strcmp(argv[3], "churn") ? 1000 : !strcmp(argv[3], "repeat") ? 10 : race.mode ? 2 : 1;
    struct cancellation cancellation = {
        .immediate = !strcmp(argv[3], "cancel"), .caller = pthread_self(),
    };
    atomic_init(&cancellation.output_seen, 0);
    if (!strcmp(argv[3], "delayed-watchdog")) {
        if (argc != 7) return 2;
        cancellation.watchdog_gate = argv[5];
        cancellation.gate_entered = argv[6];
    }
    if (!strcmp(argv[3], "live-cancel")) {
        if (argc != 6 || access(argv[5], F_OK) == 0) return 2;
        cancellation.ready = argv[5];
    }
    int cancel_on_output = !strcmp(argv[3], "output-cancel");
    int use_cancel = cancellation.immediate || cancellation.ready || cancel_on_output;
    int use_callback = use_cancel || cancellation.watchdog_gate;
    int stall = !strcmp(argv[3], "stall-write");
    if (stall && argc != 7) return 2;
    struct output_sink sink = {
        .fd = output, .budget = strtoull(argv[4], NULL, 10),
        .append_gate = stall ? argv[5] : NULL,
        .gate_entered = stall ? argv[6] : NULL,
        .cancel_on_output = cancel_on_output ? &cancellation : NULL,
    };
    int baseline = descriptor_count();
    if (baseline < 0) return 7;
    int result = 0;
    if (!strcmp(argv[3], "run-input-rw") && write(output, "partial", 7) != 7)
        return 4;
    char diagnostic[4096];
    size_t diagnostic_length = 0;
    struct sigaction previous, child_action = {0};
    if (signal_case) {
        child_action.sa_handler = ignored_child ? SIG_IGN : handled_child ? child_notice : SIG_DFL;
        child_action.sa_flags = no_child_wait ? SA_NOCLDWAIT : 0;
        sigemptyset(&child_action.sa_mask);
        if (sigaction(SIGCHLD, &child_action, &previous)) return 10;
    }
    for (int i = 0; i < repeat && result == 0; i++) {
        if (ftruncate(output, 0) || lseek(output, 0, SEEK_SET) < 0) return 4;
        sink.length = 0;
        result = (race.mode && i == 0 ? race_evaluate : rui_evaluate)(argv[1], input, prepared, check,
                              use_callback ? cancelled : NULL, &cancellation,
                              append_output, &sink,
                              check ? diagnostic : NULL, check ? sizeof(diagnostic) : 0,
                              check ? &diagnostic_length : NULL);
        if (race.mode && i == 0) {
            int status;
            if (!race.child || waitpid(race.child, &status, WNOHANG) != -1 || errno != ECHILD)
                return 11;
            if (atomic_load(&race.signals)) return 12;
        }
        if (descriptor_count() != baseline) return 7;
        if (repeat > 1 && result == 0) {
            /* Both reuse witnesses evaluate 2+3; a later success must not hide
               corrupt output from an earlier lifecycle. */
            struct stat state;
            char value;
            if (fstat(output, &state) || state.st_size != 1 ||
                pread(output, &value, 1, 0) != 1 || value != '5') return 8;
        }
    }
    if (signal_case) {
        struct sigaction observed;
        if (sigaction(SIGCHLD, NULL, &observed) ||
            observed.sa_handler != child_action.sa_handler ||
            (no_child_wait && !(observed.sa_flags & SA_NOCLDWAIT))) return 10;
        if (sigaction(SIGCHLD, &previous, NULL)) return 10;
    }
    if (result && ftruncate(output, 0)) return 4;
    if (use_cancel && result != 1) return 6;
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
