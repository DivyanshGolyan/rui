/* THROWAWAY capacity experiment. Historical scratch schema, not production authority. */
#define _DARWIN_C_SOURCE 1
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { MAX_CAPACITY = 1000, IMPORT_WINDOW = 4096 };
static const char *program_path;

enum custody_kind { KIND_MODEL = 1, KIND_BASH = 2, KIND_PATCH = 3 };
enum custody_state {
    CUSTODY_FREE = 0,
    CUSTODY_RESERVED = 1,
    CUSTODY_DISPATCHABLE = 2,
    CUSTODY_ACTIVE = 3,
    CUSTODY_SEALED = 4,
};

struct Runtime;

/*
 * Content-free by construction: no byte array and no owned payload pointer.
 * `easy` is an opaque transport handle; descriptors identify disk-backed
 * custody. State publication transfers ownership between the fixed lanes.
 */
struct PhysicalCustody {
    _Atomic uint32_t state;
    uint8_t kind;
    uint8_t terminal_seen;
    uint8_t root_reaped;
    uint8_t flags;
    uint64_t attempt_id;
    uint64_t operation_id;
    uint64_t started_ns;
    uint64_t completed_ns;
    uint64_t bytes_a;
    uint64_t bytes_b;
    uint64_t callbacks;
    uint64_t deadline_ns;
    uint64_t grace_deadline_ns;
    CURL *easy;
    struct Runtime *runtime;
    int spool_a;
    int spool_b;
    int pipe_a;
    int pipe_b;
    pid_t root_pid;
    pid_t process_group;
    int wait_status;
};

enum {
    FLAG_CANCELLED = 1,
    FLAG_PREPARATION_FAILED = 2,
    FLAG_TERM_SENT = 4,
    FLAG_KILL_SENT = 8,
    FLAG_PIPE_GRACE_EXPIRED = 16,
    FLAG_TRANSPORT_FAILURE = 32,
    FLAG_STORAGE_FAILURE = 64,
    FLAG_OUTPUT_LIMIT = 128,
};

_Static_assert(sizeof(struct PhysicalCustody) == 128,
               "review every PhysicalCustody layout change");

struct Sample {
    uint64_t rss;
    uint64_t physical;
    uint64_t lifetime_physical;
    uint64_t virtual_size;
    uint32_t threads;
    uint32_t fds;
};

struct Runtime {
    struct PhysicalCustody cells[MAX_CAPACITY];
    int control_mode;
    _Atomic bool control_trigger;
    _Atomic uint64_t control_requested_ns;
    _Atomic uint64_t cancel_target;
    _Atomic uint64_t control_removed_ns;
    uint64_t control_committed_ns;
    uint64_t control_released_ns;
    uint64_t cancelled_bytes;
    int control_pending_results;
    uint64_t ordinary_finished_ns;
    int ordinary_settled;
    int capacity;
    int model_count;
    int bash_count;
    int patch_index;
    const char *url;
    const char *cafile;
    const char *scratch;
    const char *database_path;
    const char *self_path;
    const char *bash_fixture;
    uint64_t bash_cancel_after_ns;
    uint64_t bash_term_grace_ns;
    uint64_t bash_pipe_grace_ns;
    uint64_t effect_output_limit;
    uint64_t host_scratch_quota;
    _Atomic uint64_t scratch_logical_current;
    _Atomic uint64_t scratch_logical_highwater;
    _Atomic bool stop;
    _Atomic bool fatal;
    _Atomic bool reactor_ready;
    _Atomic bool patch_ready;
    _Atomic uint64_t reactor_loops;
    _Atomic uint64_t max_poll_ns;
    _Atomic uint64_t max_write_ns;
    _Atomic uint64_t max_live_spool_allocated;
    _Atomic uint64_t max_storage_allocated;
    _Atomic uint32_t validator_active;
    _Atomic uint32_t validator_max;
    _Atomic uint32_t bash_term_sent;
    _Atomic uint32_t bash_kill_sent;
    _Atomic uint32_t bash_reaped;
    _Atomic uint32_t bash_pipe_grace_expired;
    _Atomic uint64_t max_term_lateness_ns;
    _Atomic uint64_t max_kill_lateness_ns;
    _Atomic uint64_t max_signal_to_reap_ns;
    _Atomic uint64_t max_pipe_grace_lateness_ns;
    _Atomic uint64_t max_model_callback_gap_ns;
    _Atomic uint64_t first_model_sealed_ns;
    _Atomic uint64_t last_model_sealed_ns;
    uint64_t inject_reactor_fatal_after_loops;
    char patch_target[1024];
    pthread_mutex_t wake_mutex;
    pthread_cond_t wake_cond;
};

struct PatchArgs {
    struct Runtime *runtime;
    int index;
};

static int scalar_int(sqlite3 *db, const char *sql);
static void release_cell(struct PhysicalCustody *cell);

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void max_u64(_Atomic uint64_t *target, uint64_t value) {
    uint64_t old = atomic_load_explicit(target, memory_order_relaxed);
    while (value > old && !atomic_compare_exchange_weak_explicit(
               target, &old, value, memory_order_relaxed, memory_order_relaxed)) {}
}

static bool observe(struct Sample *out) {
    struct proc_taskinfo task = {0};
    int got = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, sizeof(task));
    struct rusage_info_v4 usage = {0};
    int usage_result = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage);
    struct proc_fdinfo fd_list[4096];
    int fd_bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fd_list, sizeof(fd_list));
    if (got != sizeof(task) || usage_result != 0 || fd_bytes < 0 || fd_bytes >= (int)sizeof(fd_list)) {
        fprintf(stderr, "process measurement failed: task=%d usage=%d fds=%d\n",
                got, usage_result, fd_bytes);
        return false;
    }
    if (task.pti_resident_size > out->rss) out->rss = task.pti_resident_size;
    if (task.pti_virtual_size > out->virtual_size) out->virtual_size = task.pti_virtual_size;
    if ((uint32_t)task.pti_threadnum > out->threads) out->threads = (uint32_t)task.pti_threadnum;
    if (usage.ri_phys_footprint > out->physical) out->physical = usage.ri_phys_footprint;
    if (usage.ri_lifetime_max_phys_footprint > out->lifetime_physical)
        out->lifetime_physical = usage.ri_lifetime_max_phys_footprint;
    if (fd_bytes > 0) {
        uint32_t fds = (uint32_t)(fd_bytes / (int)PROC_PIDLISTFD_SIZE);
        if (fds > out->fds) out->fds = fds;
    }
    return true;
}

static void memory_phase(const char *phase, int cycle) {
    malloc_statistics_t stats = {0};
    malloc_zone_statistics(NULL, &stats);
    struct Sample sample = {0};
    if (!observe(&sample)) abort();
    fprintf(stderr, "{\"memory_phase\":\"%s\",\"cycle\":%d,\"live_blocks\":%u,\"live_malloc_bytes\":%zu,\"allocator_reserved_bytes\":%zu,\"physical_bytes\":%llu,\"fds\":%u}\n",
        phase, cycle, stats.blocks_in_use, stats.size_in_use, stats.size_allocated, sample.physical, sample.fds);
}

static void *control_sender(void *opaque) {
    struct Runtime *runtime = opaque;
    while (!atomic_load(&runtime->control_trigger) && !atomic_load(&runtime->stop)) usleep(100);
    if (!atomic_load(&runtime->stop)) atomic_store(&runtime->control_requested_ns, now_ns());
    return NULL;
}

static int write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t wrote = write(fd, cursor, length);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        cursor += (size_t)wrote;
        length -= (size_t)wrote;
    }
    return 0;
}

static int open_unlinked_spool(const char *directory) {
    char path[1024];
    int length = snprintf(path, sizeof(path), "%s/onepage-integrated.XXXXXX", directory);
    if (length <= 0 || (size_t)length >= sizeof(path)) return -1;
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) { close(fd); return -1; }
    if (getenv("ONEPAGE_PROOF_SPOOL_NOCACHE") && fcntl(fd, F_NOCACHE, 1) != 0) {
        close(fd);
        return -1;
    }
    if (unlink(path) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool charge_scratch(struct Runtime *runtime, struct PhysicalCustody *cell,
                           size_t length) {
    uint64_t cell_bytes = cell->bytes_a + cell->bytes_b;
    if ((uint64_t)length > runtime->effect_output_limit - cell_bytes) {
        cell->flags |= FLAG_OUTPUT_LIMIT;
        return false;
    }
    uint64_t current = atomic_load_explicit(&runtime->scratch_logical_current,
                                             memory_order_relaxed);
    if ((uint64_t)length > runtime->host_scratch_quota - current) {
        cell->flags |= FLAG_STORAGE_FAILURE;
        return false;
    }
    uint64_t next = atomic_fetch_add_explicit(&runtime->scratch_logical_current,
                                               length, memory_order_relaxed) + length;
    max_u64(&runtime->scratch_logical_highwater, next);
    return true;
}

static void discard_cell_output(struct Runtime *runtime, struct PhysicalCustody *cell) {
    uint64_t charge = cell->bytes_a + cell->bytes_b;
    if (charge) atomic_fetch_sub_explicit(&runtime->scratch_logical_current,
                                          charge, memory_order_relaxed);
    if (cell->spool_a >= 0) (void)ftruncate(cell->spool_a, 0);
    if (cell->spool_b >= 0) (void)ftruncate(cell->spool_b, 0);
    cell->bytes_a = cell->bytes_b = 0;
}

static uint64_t allocated_fd_bytes(int fd) {
    struct stat statbuf = {0};
    return fd >= 0 && fstat(fd, &statbuf) == 0
        ? (uint64_t)statbuf.st_blocks * 512ULL : 0;
}

static uint64_t live_spool_allocated(const struct Runtime *runtime) {
    uint64_t total = 0;
    for (int i = 0; i < runtime->capacity; ++i) {
        total += allocated_fd_bytes(runtime->cells[i].spool_a);
        total += allocated_fd_bytes(runtime->cells[i].spool_b);
    }
    return total;
}

static uint64_t allocated_path_bytes(const char *path) {
    struct stat statbuf = {0};
    return stat(path, &statbuf) == 0 ? (uint64_t)statbuf.st_blocks * 512ULL : 0;
}

static uint64_t sqlite_storage_allocated(const char *path) {
    char companion[1024];
    uint64_t total = allocated_path_bytes(path);
    int length = snprintf(companion, sizeof(companion), "%s-wal", path);
    if (length > 0 && (size_t)length < sizeof(companion)) total += allocated_path_bytes(companion);
    length = snprintf(companion, sizeof(companion), "%s-shm", path);
    if (length > 0 && (size_t)length < sizeof(companion)) total += allocated_path_bytes(companion);
    return total;
}

static size_t model_write(char *bytes, size_t size, size_t count, void *userdata) {
    struct PhysicalCustody *cell = userdata;
    size_t length = size * count;
    if (!charge_scratch(cell->runtime, cell, length)) {
        discard_cell_output(cell->runtime, cell);
        return 0;
    }
    uint64_t started = now_ns();
    if (write_all(cell->spool_a, bytes, length) != 0) {
        atomic_fetch_sub(&cell->runtime->scratch_logical_current, length);
        cell->flags |= FLAG_STORAGE_FAILURE;
        discard_cell_output(cell->runtime, cell);
        return 0;
    }
    max_u64(&cell->runtime->max_write_ns, now_ns() - started);
    cell->bytes_a += length;
    cell->callbacks++;
    uint64_t at = now_ns();
    if (cell->deadline_ns && at - cell->deadline_ns > cell->grace_deadline_ns)
        cell->grace_deadline_ns = at - cell->deadline_ns;
    cell->deadline_ns = at;
    return length;
}

static size_t model_read(char *bytes, size_t size, size_t count, void *userdata) {
    (void)userdata;
    size_t length = size * count;
    if (length > 4096) length = 4096;
    memset(bytes, 'x', length);
    return length;
}

static int configure_model(struct Runtime *runtime, struct PhysicalCustody *cell) {
    cell->spool_a = open_unlinked_spool(runtime->scratch);
    if (cell->spool_a < 0) return -1;
    cell->easy = curl_easy_init();
    if (!cell->easy) return -1;
#define SETOPT(option, value) \
    do { if (curl_easy_setopt(cell->easy, option, value) != CURLE_OK) return -1; } while (0)
    SETOPT(CURLOPT_VERBOSE, getenv("ONEPAGE_PROOF_VERBOSE") ? 1L : 0L);
    char request_url[2048];
    int url_length = snprintf(request_url, sizeof(request_url), "%s?operation=%llu", runtime->url, cell->operation_id);
    if (url_length < 0 || (size_t)url_length >= sizeof(request_url)) return -1;
    SETOPT(CURLOPT_URL, request_url);
    SETOPT(CURLOPT_CAINFO, runtime->cafile);
    SETOPT(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    SETOPT(CURLOPT_WRITEFUNCTION, model_write);
    SETOPT(CURLOPT_WRITEDATA, cell);
    SETOPT(CURLOPT_READFUNCTION, model_read);
    SETOPT(CURLOPT_READDATA, cell);
    SETOPT(CURLOPT_POST, 1L);
    SETOPT(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)4096);
    SETOPT(CURLOPT_NOSIGNAL, 1L);
    SETOPT(CURLOPT_NOPROXY, "*");
    SETOPT(CURLOPT_FRESH_CONNECT, 1L);
    SETOPT(CURLOPT_FORBID_REUSE, 1L);
    SETOPT(CURLOPT_TIMEOUT, 120L);
#undef SETOPT
    return 0;
}

static int nonblocking_pipe(int ends[2]) {
    if (pipe(ends) != 0) return -1;
    if (fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL) | O_NONBLOCK) != 0 ||
        fcntl(ends[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(ends[1], F_SETFD, FD_CLOEXEC) != 0) {
        close(ends[0]); close(ends[1]);
        return -1;
    }
    return 0;
}

static int marker_path(char out[1024], const char *target, const char *suffix) {
    int length = snprintf(out, 1024, "%s.%s", target, suffix);
    return length > 0 && length < 1024 ? 0 : -1;
}

static void remove_patch_markers(const char *target) {
    static const char *suffixes[] = {"prechecked", "interfered", "patched"};
    char path[1024];
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); ++i)
        if (marker_path(path, target, suffixes[i]) == 0) (void)unlink(path);
}

static int touch_marker(const char *target, const char *suffix) {
    char path[1024];
    if (marker_path(path, target, suffix) != 0) return -1;
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    return close(fd);
}

static int wait_marker(const char *target, const char *suffix) {
    char path[1024];
    if (marker_path(path, target, suffix) != 0) return -1;
    for (int i = 0; i < 2000; ++i) {
        if (access(path, F_OK) == 0) return 0;
        usleep(1000);
    }
    return -1;
}

static int run_bash_child(const char *fixture, const char *patch_target) {
    if (strcmp(fixture, "kill") == 0) signal(SIGTERM, SIG_IGN);
    if (strncmp(fixture, "interfere-", 10) == 0) {
        if (strcmp(fixture, "interfere-during") == 0 &&
            wait_marker(patch_target, "prechecked") != 0) return 9;
        if (strcmp(fixture, "interfere-after") == 0 &&
            wait_marker(patch_target, "patched") != 0) return 9;
        int target = open(patch_target, O_WRONLY | O_CLOEXEC);
        if (target < 0) return 6;
        uint8_t mutation[IMPORT_WINDOW];
        memset(mutation, 'b', sizeof(mutation));
        for (int i = 0; i < 4; ++i)
            if (pwrite(target, mutation, sizeof(mutation), (off_t)i * IMPORT_WINDOW) != IMPORT_WINDOW) {
                close(target);
                return 7;
            }
        if (fsync(target) != 0) { close(target); return 8; }
        close(target);
        if (touch_marker(patch_target, "interfered") != 0) return 9;
    }
    uint8_t window[IMPORT_WINDOW];
    memset(window, 'b', sizeof(window));
    for (int i = 0; i < 64; ++i) {
        if (write_all(STDOUT_FILENO, window, sizeof(window)) != 0) return 3;
        if (write_all(STDERR_FILENO, window, sizeof(window)) != 0) return 3;
        usleep(2000);
    }
    if (strcmp(fixture, "normal") == 0) return 0;
    if (strcmp(fixture, "term") == 0) {
        for (;;) pause();
    }
    if (strcmp(fixture, "kill") == 0) {
        for (;;) pause();
    }
    if (strcmp(fixture, "inherited") == 0 || strcmp(fixture, "escaped") == 0) {
        pid_t descendant = fork();
        if (descendant < 0) return 4;
        if (descendant == 0) {
            if (strcmp(fixture, "escaped") == 0) (void)setsid();
            usleep(strcmp(fixture, "escaped") == 0 ? 2000000 : 200000);
            _exit(0);
        }
        return 0;
    }
    return 5;
}

static int spawn_bash(struct Runtime *runtime, struct PhysicalCustody *cell) {
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    if (nonblocking_pipe(stdout_pipe) != 0) return -1;
    if (nonblocking_pipe(stderr_pipe) != 0) {
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return -1;
    }
    cell->spool_a = open_unlinked_spool(runtime->scratch);
    cell->spool_b = open_unlinked_spool(runtime->scratch);
    if (cell->spool_a < 0 || cell->spool_b < 0) {
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return -1;
    }
    if (pid == 0) {
        (void)setpgid(0, 0);
        (void)dup2(stdout_pipe[1], STDOUT_FILENO);
        (void)dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        execl(runtime->self_path, runtime->self_path, "child", runtime->bash_fixture,
              runtime->patch_target[0] ? runtime->patch_target : "unused",
              (char *)NULL);
        _exit(127);
    }
    (void)setpgid(pid, pid);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    cell->pipe_a = stdout_pipe[0];
    cell->pipe_b = stderr_pipe[0];
    cell->root_pid = pid;
    cell->process_group = pid;
    if (runtime->bash_cancel_after_ns)
        cell->deadline_ns = now_ns() + runtime->bash_cancel_after_ns;
    return 0;
}

static void signal_owner(struct Runtime *runtime) {
    pthread_mutex_lock(&runtime->wake_mutex);
    /* Two consumers share this hint. Broadcast avoids a consumptive wake
     * selecting the wrong lane; truth remains in the bounded cell scan. */
    pthread_cond_broadcast(&runtime->wake_cond);
    pthread_mutex_unlock(&runtime->wake_mutex);
}

static void seal_cell(struct Runtime *runtime, struct PhysicalCustody *cell) {
    cell->completed_ns = now_ns();
    if (cell->kind == KIND_MODEL) {
        uint64_t zero = 0;
        (void)atomic_compare_exchange_strong(&runtime->first_model_sealed_ns,
                                             &zero, cell->completed_ns);
        max_u64(&runtime->last_model_sealed_ns, cell->completed_ns);
    }
    atomic_store_explicit(&cell->state, CUSTODY_SEALED, memory_order_release);
    signal_owner(runtime);
}

static bool bash_terminal(struct Runtime *runtime, struct PhysicalCustody *cell) {
    uint64_t at = now_ns();
    if (cell->deadline_ns && at >= cell->deadline_ns && !(cell->flags & FLAG_TERM_SENT)) {
        max_u64(&runtime->max_term_lateness_ns, at - cell->deadline_ns);
        (void)kill(-cell->process_group, SIGTERM);
        cell->flags |= FLAG_CANCELLED | FLAG_TERM_SENT;
        cell->deadline_ns = at;
        cell->grace_deadline_ns = at + runtime->bash_term_grace_ns;
    }
    if ((cell->flags & FLAG_TERM_SENT) && !(cell->flags & FLAG_KILL_SENT) &&
        !cell->root_reaped && at >= cell->grace_deadline_ns) {
        max_u64(&runtime->max_kill_lateness_ns, at - cell->grace_deadline_ns);
        (void)kill(-cell->process_group, SIGKILL);
        cell->flags |= FLAG_KILL_SENT;
        cell->deadline_ns = at;
    }
    bool newly_reaped = false;
    if (!cell->root_reaped) {
        pid_t waited = waitpid(cell->root_pid, &cell->wait_status, WNOHANG);
        if (waited == cell->root_pid) {
            cell->root_reaped = 1;
            newly_reaped = true;
            if (cell->flags & FLAG_TERM_SENT)
                max_u64(&runtime->max_signal_to_reap_ns, at - cell->deadline_ns);
        }
    }
    if (newly_reaped && (cell->pipe_a >= 0 || cell->pipe_b >= 0))
        cell->grace_deadline_ns = at + runtime->bash_pipe_grace_ns;
    if (cell->root_reaped && (cell->pipe_a >= 0 || cell->pipe_b >= 0) &&
        cell->grace_deadline_ns && at >= cell->grace_deadline_ns) {
        max_u64(&runtime->max_pipe_grace_lateness_ns, at - cell->grace_deadline_ns);
        if (cell->pipe_a >= 0) { close(cell->pipe_a); cell->pipe_a = -1; }
        if (cell->pipe_b >= 0) { close(cell->pipe_b); cell->pipe_b = -1; }
        cell->flags |= FLAG_PIPE_GRACE_EXPIRED;
    }
    return cell->root_reaped && cell->pipe_a < 0 && cell->pipe_b < 0;
}

static void drain_pipe(struct Runtime *runtime, struct PhysicalCustody *cell, bool first) {
    uint8_t window[IMPORT_WINDOW];
    int *pipe_fd = first ? &cell->pipe_a : &cell->pipe_b;
    int spool_fd = first ? cell->spool_a : cell->spool_b;
    uint64_t *count = first ? &cell->bytes_a : &cell->bytes_b;
    for (;;) {
        ssize_t got = read(*pipe_fd, window, sizeof(window));
        if (got > 0) {
            if (cell->flags & (FLAG_STORAGE_FAILURE | FLAG_OUTPUT_LIMIT)) continue;
            if (!charge_scratch(runtime, cell, (size_t)got)) {
                discard_cell_output(runtime, cell);
                if (!(cell->flags & FLAG_TERM_SENT)) {
                    (void)kill(-cell->process_group, SIGTERM);
                    cell->flags |= FLAG_TERM_SENT;
                    cell->deadline_ns = now_ns();
                    cell->grace_deadline_ns = cell->deadline_ns + runtime->bash_term_grace_ns;
                }
                continue;
            }
            uint64_t started = now_ns();
            if (write_all(spool_fd, window, (size_t)got) != 0) {
                atomic_fetch_sub(&runtime->scratch_logical_current, (uint64_t)got);
                cell->flags |= FLAG_STORAGE_FAILURE;
                discard_cell_output(runtime, cell);
                if (!(cell->flags & FLAG_TERM_SENT)) {
                    (void)kill(-cell->process_group, SIGTERM);
                    cell->flags |= FLAG_TERM_SENT;
                    cell->deadline_ns = now_ns();
                    cell->grace_deadline_ns = cell->deadline_ns + runtime->bash_term_grace_ns;
                }
                continue;
            }
            max_u64(&runtime->max_write_ns, now_ns() - started);
            *count += (uint64_t)got;
            continue;
        }
        if (got == 0) {
            close(*pipe_fd);
            *pipe_fd = -1;
        }
        return;
    }
}

/* Prototype alternate wait backend. Fixed FD-indexed interests, one reactor. */
enum { SOCKET_BOUND = 8192 };
struct SocketPoll {
    short interest[SOCKET_BOUND];
    uint32_t generation[SOCKET_BOUND];
};
static int socket_interest(CURL *easy, curl_socket_t fd, int what, void *opaque, void *socketp) {
    (void)easy; (void)socketp;
    struct SocketPoll *p = opaque;
    if (fd < 0 || fd >= SOCKET_BOUND) return -1;
    p->interest[fd] = what == CURL_POLL_REMOVE ? 0 :
        (short)(((what == CURL_POLL_IN || what == CURL_POLL_INOUT) ? POLLIN : 0) |
                ((what == CURL_POLL_OUT || what == CURL_POLL_INOUT) ? POLLOUT : 0));
    p->generation[fd]++;
    return 0;
}
static CURLMcode socket_poll_step(CURLM *multi, struct SocketPoll *p, int *running) {
    CURLMcode result = curl_multi_socket_action(multi, CURL_SOCKET_TIMEOUT, 0, running);
    if (result != CURLM_OK) return result;
    struct pollfd fds[MAX_CAPACITY + 16];
    uint32_t generations[MAX_CAPACITY + 16];
    nfds_t count = 0;
    for (int fd = 0; fd < SOCKET_BOUND; ++fd) {
        if (!p->interest[fd]) continue;
        if (count >= MAX_CAPACITY + 16) return CURLM_OUT_OF_MEMORY;
        fds[count] = (struct pollfd){.fd=fd, .events=p->interest[fd]};
        generations[count++] = p->generation[fd];
    }
    long timeout = -1;
    result = curl_multi_timeout(multi, &timeout);
    if (result != CURLM_OK) return result;
    if (timeout < 0 || timeout > 10) timeout = 10;
    int ready = poll(fds, count, (int)timeout);
    if (ready < 0) return errno == EINTR ? CURLM_OK : CURLM_UNRECOVERABLE_POLL;
    for (nfds_t i = 0; i < count; ++i) {
        if (!fds[i].revents || generations[i] != p->generation[fds[i].fd]) continue;
        int events = ((fds[i].revents & POLLIN) ? CURL_CSELECT_IN : 0) |
                     ((fds[i].revents & POLLOUT) ? CURL_CSELECT_OUT : 0) |
                     ((fds[i].revents & (POLLERR|POLLHUP|POLLNVAL)) ? CURL_CSELECT_ERR : 0);
        result = curl_multi_socket_action(multi, fds[i].fd, events, running);
        if (result != CURLM_OK) return result;
    }
    return CURLM_OK;
}

static void *reactor_main(void *opaque) {
    struct Runtime *runtime = opaque;
    struct SocketPoll socket_poll = {0};
    bool native_poll = getenv("ONEPAGE_PROOF_NATIVE_POLL") != NULL;
    CURLM *multi = curl_multi_init();
    if (!multi) {
        atomic_store(&runtime->fatal, true);
        signal_owner(runtime);
        return NULL;
    }
    if (curl_multi_setopt(multi, CURLMOPT_MAX_TOTAL_CONNECTIONS,
                          (long)runtime->capacity) != CURLM_OK) {
        curl_multi_cleanup(multi);
        atomic_store(&runtime->fatal, true);
        signal_owner(runtime);
        return NULL;
    }
    if (native_poll && (curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_interest) != CURLM_OK ||
        curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, &socket_poll) != CURLM_OK)) {
        curl_multi_cleanup(multi); atomic_store(&runtime->fatal, true); signal_owner(runtime); return NULL;
    }
    atomic_store_explicit(&runtime->reactor_ready, true, memory_order_release);
    signal_owner(runtime);

    while (!atomic_load_explicit(&runtime->stop, memory_order_acquire)) {
        int live = 0;
        for (int i = 0; i < runtime->capacity; ++i) {
            struct PhysicalCustody *cell = &runtime->cells[i];
            uint32_t expected = CUSTODY_DISPATCHABLE;
            if (cell->kind != KIND_PATCH && atomic_compare_exchange_strong_explicit(
                    &cell->state, &expected, CUSTODY_ACTIVE,
                    memory_order_acq_rel, memory_order_acquire)) {
                cell->started_ns = now_ns();
                int result = cell->kind == KIND_MODEL
                    ? configure_model(runtime, cell)
                    : spawn_bash(runtime, cell);
                if (result != 0) {
                    cell->flags |= FLAG_PREPARATION_FAILED;
                    seal_cell(runtime, cell);
                    continue;
                }
                if (cell->kind == KIND_MODEL && curl_multi_add_handle(multi, cell->easy) != CURLM_OK) {
                    cell->flags |= FLAG_PREPARATION_FAILED;
                    seal_cell(runtime, cell);
                }
            }
            if (atomic_load_explicit(&cell->state, memory_order_acquire) == CUSTODY_ACTIVE)
                live++;
        }
        if (!live) {
            pthread_mutex_lock(&runtime->wake_mutex);
            if (!atomic_load_explicit(&runtime->stop, memory_order_relaxed))
                pthread_cond_wait(&runtime->wake_cond, &runtime->wake_mutex);
            pthread_mutex_unlock(&runtime->wake_mutex);
            continue;
        }

        struct curl_waitfd extra[MAX_CAPACITY * 2];
        int owners[MAX_CAPACITY * 2];
        bool first_pipe[MAX_CAPACITY * 2];
        unsigned extra_count = 0;
        for (int i = 0; i < runtime->capacity; ++i) {
            struct PhysicalCustody *cell = &runtime->cells[i];
            if (cell->kind != KIND_BASH ||
                atomic_load_explicit(&cell->state, memory_order_acquire) != CUSTODY_ACTIVE) continue;
            if (cell->pipe_a >= 0) {
                extra[extra_count] = (struct curl_waitfd){.fd = cell->pipe_a, .events = CURL_WAIT_POLLIN};
                owners[extra_count] = i; first_pipe[extra_count++] = true;
            }
            if (cell->pipe_b >= 0) {
                extra[extra_count] = (struct curl_waitfd){.fd = cell->pipe_b, .events = CURL_WAIT_POLLIN};
                owners[extra_count] = i; first_pipe[extra_count++] = false;
            }
        }

        int numfds = 0;
        uint64_t poll_started = now_ns();
        CURLMcode polled = native_poll ? CURLM_OK : curl_multi_poll(multi, extra, extra_count, 10, &numfds);
        max_u64(&runtime->max_poll_ns, now_ns() - poll_started);
        if (polled != CURLM_OK) { fprintf(stderr, "curl_multi_poll: %s errno=%d\n", curl_multi_strerror(polled), errno); atomic_store(&runtime->fatal, true); break; }
        uint64_t loops = atomic_fetch_add_explicit(
            &runtime->reactor_loops, 1, memory_order_relaxed) + 1;
        if (runtime->inject_reactor_fatal_after_loops &&
            loops >= runtime->inject_reactor_fatal_after_loops) {
            atomic_store(&runtime->fatal, true);
            break;
        }

        for (unsigned i = 0; i < extra_count; ++i)
            if (extra[i].revents & (CURL_WAIT_POLLIN | CURL_WAIT_POLLPRI))
                drain_pipe(runtime, &runtime->cells[owners[i]], first_pipe[i]);

        int running = 0;
        CURLMcode performed = native_poll ? socket_poll_step(multi, &socket_poll, &running) : curl_multi_perform(multi, &running);
        if (performed != CURLM_OK) {
            fprintf(stderr, "curl_multi_perform: %s errno=%d\n", curl_multi_strerror(performed), errno);
            atomic_store(&runtime->fatal, true);
            break;
        }
        int remaining = 0;
        CURLMsg *message;
        while ((message = curl_multi_info_read(multi, &remaining))) {
            if (message->msg != CURLMSG_DONE) continue;
            if (message->data.result != CURLE_OK) fprintf(stderr, "curl transfer: %d %s\n", message->data.result, curl_easy_strerror(message->data.result));
            for (int i = 0; i < runtime->capacity; ++i) {
                struct PhysicalCustody *cell = &runtime->cells[i];
                if (cell->easy != message->easy_handle) continue;
                if (message->data.result != CURLE_OK)
                    cell->flags |= FLAG_TRANSPORT_FAILURE;
                (void)curl_multi_remove_handle(multi, cell->easy);
                curl_easy_cleanup(cell->easy);
                cell->easy = NULL;
                seal_cell(runtime, cell);
                break;
            }
        }
        uint64_t cancel_target = atomic_load(&runtime->cancel_target);
        if (cancel_target && !atomic_load(&runtime->control_removed_ns)) {
            struct PhysicalCustody *cell = &runtime->cells[runtime->capacity - 1];
            if (cell->operation_id != cancel_target || atomic_load(&cell->state) != CUSTODY_ACTIVE || !cell->easy) {
                atomic_store(&runtime->fatal, true); break;
            }
            if (curl_multi_remove_handle(multi, cell->easy) != CURLM_OK) {
                atomic_store(&runtime->fatal, true); break;
            }
            curl_easy_cleanup(cell->easy); cell->easy = NULL;
            cell->flags |= FLAG_CANCELLED;
            atomic_store(&runtime->control_removed_ns, now_ns());
            seal_cell(runtime, cell);
        }
        for (int i = 0; i < runtime->capacity; ++i) {
            struct PhysicalCustody *cell = &runtime->cells[i];
            if (cell->kind == KIND_BASH &&
                atomic_load_explicit(&cell->state, memory_order_acquire) == CUSTODY_ACTIVE &&
                bash_terminal(runtime, cell)) seal_cell(runtime, cell);
        }
    }
    if (atomic_load(&runtime->fatal)) {
        for (int i = 0; i < runtime->capacity; ++i) {
            struct PhysicalCustody *cell = &runtime->cells[i];
            if (cell->kind == KIND_MODEL && cell->easy) {
                (void)curl_multi_remove_handle(multi, cell->easy);
                curl_easy_cleanup(cell->easy);
                cell->easy = NULL;
                release_cell(cell);
            } else if (cell->kind == KIND_BASH && cell->root_pid > 0) {
                (void)kill(-cell->process_group, SIGKILL);
                (void)waitpid(cell->root_pid, &cell->wait_status, 0);
                cell->root_pid = 0;
                release_cell(cell);
            }
        }
        signal_owner(runtime);
    }
    curl_multi_cleanup(multi);
    return NULL;
}

static int prepare_patch_target(struct Runtime *runtime) {
    if (!runtime->patch_target[0]) {
        int length = snprintf(runtime->patch_target, sizeof(runtime->patch_target),
                              "%s/onepage-patch-target-%d", runtime->scratch, getpid());
        if (length <= 0 || (size_t)length >= sizeof(runtime->patch_target)) return -1;
    }
    (void)unlink(runtime->patch_target);
    remove_patch_markers(runtime->patch_target);
    int fd = open(runtime->patch_target, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    uint8_t window[IMPORT_WINDOW];
    memset(window, 'a', sizeof(window));
    for (int i = 0; i < 256; ++i)
        if (write_all(fd, window, sizeof(window)) != 0) { close(fd); return -1; }
    if (fsync(fd) != 0) { close(fd); return -1; }
    return close(fd);
}

static int run_patch_quantum(struct Runtime *runtime, struct PhysicalCustody *cell) {
    cell->started_ns = now_ns();
    int fd = open(runtime->patch_target, O_RDWR | O_CLOEXEC);
    if (fd < 0) return -1;
    if (strcmp(runtime->bash_fixture, "interfere-before") == 0 &&
        wait_marker(runtime->patch_target, "interfered") != 0) {
        close(fd); return -1;
    }
    uint8_t window[IMPORT_WINDOW];
    for (int i = 0; i < 4; ++i) {
        ssize_t got = pread(fd, window, sizeof(window), (off_t)i * IMPORT_WINDOW);
        if (got != IMPORT_WINDOW) { close(fd); cell->wait_status = 3; return 0; }
        for (size_t j = 0; j < sizeof(window); ++j)
            if (window[j] != 'a') { close(fd); cell->wait_status = 2; return 0; }
    }
    if (strncmp(runtime->bash_fixture, "interfere-", 10) == 0) {
        if (touch_marker(runtime->patch_target, "prechecked") != 0) {
            close(fd); return -1;
        }
        if (strcmp(runtime->bash_fixture, "interfere-during") == 0 &&
            wait_marker(runtime->patch_target, "interfered") != 0) {
            close(fd); return -1;
        }
    }
    memset(window, 'p', sizeof(window));
    for (int i = 0; i < 4; ++i)
        if (pwrite(fd, window, sizeof(window), (off_t)i * IMPORT_WINDOW) != IMPORT_WINDOW) {
            close(fd); cell->wait_status = 3; return 0;
        }
    if (fsync(fd) != 0) { close(fd); cell->wait_status = 3; return 0; }
    for (int i = 0; i < 4; ++i) {
        ssize_t got = pread(fd, window, sizeof(window), (off_t)i * IMPORT_WINDOW);
        if (got != IMPORT_WINDOW) { close(fd); cell->wait_status = 3; return 0; }
        for (size_t j = 0; j < sizeof(window); ++j)
            if (window[j] != 'p') { close(fd); cell->wait_status = 3; return 0; }
    }
    cell->wait_status = 1;
    if (strncmp(runtime->bash_fixture, "interfere-", 10) == 0 &&
        touch_marker(runtime->patch_target, "patched") != 0) {
        close(fd); return -1;
    }
    return close(fd);
}

static void *patch_main(void *opaque) {
    struct PatchArgs *args = opaque;
    struct PhysicalCustody *cell = &args->runtime->cells[args->index];
    atomic_store_explicit(&args->runtime->patch_ready, true, memory_order_release);
    signal_owner(args->runtime);
    while (!atomic_load_explicit(&args->runtime->stop, memory_order_acquire)) {
        uint32_t expected = CUSTODY_DISPATCHABLE;
        if (atomic_compare_exchange_strong_explicit(&cell->state, &expected, CUSTODY_ACTIVE,
                memory_order_acq_rel, memory_order_acquire)) {
            if (run_patch_quantum(args->runtime, cell) != 0)
                cell->flags |= FLAG_PREPARATION_FAILED;
            seal_cell(args->runtime, cell);
            continue;
        }
        pthread_mutex_lock(&args->runtime->wake_mutex);
        if (!atomic_load_explicit(&args->runtime->stop, memory_order_relaxed))
            pthread_cond_wait(&args->runtime->wake_cond, &args->runtime->wake_mutex);
        pthread_mutex_unlock(&args->runtime->wake_mutex);
    }
    return NULL;
}

static int sql_exec(sqlite3 *db, const char *sql) {
    char *error = NULL;
    int result = sqlite3_exec(db, sql, NULL, NULL, &error);
    if (result != SQLITE_OK) {
        fprintf(stderr, "sqlite: %s\n", error ? error : sqlite3_errmsg(db));
        sqlite3_free(error);
        return -1;
    }
    return 0;
}

static int open_database(const char *path, sqlite3 **out) {
    if (sqlite3_open_v2(path, out, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK)
        return -1;
    return sql_exec(*out,
        "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"
        "PRAGMA mmap_size=0; PRAGMA cache_size=-256;"
        "CREATE TABLE operation(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL);"
        "CREATE TABLE attempt(id INTEGER PRIMARY KEY, operation_id INTEGER NOT NULL UNIQUE REFERENCES operation(id));"
        "CREATE TABLE artifact(id INTEGER PRIMARY KEY, attempt_id INTEGER NOT NULL REFERENCES attempt(id), part INTEGER NOT NULL, bytes BLOB NOT NULL, UNIQUE(attempt_id,part));"
        "CREATE TABLE completion(attempt_id INTEGER PRIMARY KEY REFERENCES attempt(id), class TEXT NOT NULL, evidence_digest TEXT NOT NULL);"
        "CREATE TABLE resolution(operation_id INTEGER PRIMARY KEY REFERENCES operation(id), completion_attempt_id INTEGER NOT NULL UNIQUE REFERENCES completion(attempt_id));");
}

static int service_control(sqlite3 *db, struct Runtime *runtime, int pending) {
    if (!runtime->control_mode || runtime->control_committed_ns || !atomic_load(&runtime->control_requested_ns)) return 0;
    char sql[256];
    snprintf(sql, sizeof(sql), "BEGIN IMMEDIATE; INSERT INTO probe_stop(operation_id) VALUES(%d); COMMIT;", runtime->capacity);
    if (sql_exec(db, sql) != 0) return -1;
    runtime->control_pending_results = pending;
    runtime->control_committed_ns = now_ns();
    atomic_store(&runtime->cancel_target, (uint64_t)runtime->capacity);
    signal_owner(runtime);
    return 0;
}

static int admit(sqlite3 *db, struct PhysicalCustody *cell, int id) {
    char sql[256];
    uint32_t expected = CUSTODY_FREE;
    if (!atomic_compare_exchange_strong_explicit(&cell->state, &expected, CUSTODY_RESERVED,
            memory_order_acq_rel, memory_order_acquire)) return -1;
    if (sql_exec(db, "BEGIN IMMEDIATE") != 0) {
        atomic_store_explicit(&cell->state, CUSTODY_FREE, memory_order_release);
        return -1;
    }
    int length = snprintf(sql, sizeof(sql),
        "INSERT INTO operation(id,kind) VALUES(%d,%u);"
        "INSERT INTO attempt(id,operation_id) VALUES(%d,%d);",
        id, cell->kind, id, id);
    if (length <= 0 || (size_t)length >= sizeof(sql) || sql_exec(db, sql) != 0) {
        (void)sql_exec(db, "ROLLBACK");
        atomic_store_explicit(&cell->state, CUSTODY_FREE, memory_order_release);
        return -1;
    }
    if (sql_exec(db, "COMMIT") != 0) {
        atomic_store_explicit(&cell->state, CUSTODY_FREE, memory_order_release);
        return -1;
    }
    cell->attempt_id = (uint64_t)id;
    cell->operation_id = (uint64_t)id;
    atomic_store_explicit(&cell->state, CUSTODY_DISPATCHABLE, memory_order_release);
    return 0;
}

static bool contains_synthetic_terminal(int fd, uint8_t window[IMPORT_WINDOW]) {
    const char needle[] =
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    size_t carry = 0;
    if (lseek(fd, 0, SEEK_SET) < 0) return false;
    for (;;) {
        ssize_t got = read(fd, window + carry, IMPORT_WINDOW - carry);
        if (got < 0) { if (errno == EINTR) continue; return false; }
        size_t total = carry + (size_t)got;
        if (total >= sizeof(needle) - 1) {
            for (size_t i = 0; i + sizeof(needle) - 1 <= total; ++i)
                if (memcmp(window + i, needle, sizeof(needle) - 1) == 0) return true;
        }
        if (got == 0) return false;
        carry = total < sizeof(needle) - 2 ? total : sizeof(needle) - 2;
        memmove(window, window + total - carry, carry);
    }
}

static int import_part(sqlite3 *db, uint64_t attempt_id, int part, int fd,
                       uint64_t length, uint8_t window[IMPORT_WINDOW]) {
    sqlite3_stmt *insert = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO artifact(attempt_id,part,bytes) VALUES(?1,?2,zeroblob(?3))",
            -1, &insert, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_int64(insert, 1, (sqlite3_int64)attempt_id);
    sqlite3_bind_int(insert, 2, part);
    sqlite3_bind_int64(insert, 3, (sqlite3_int64)length);
    int stepped = sqlite3_step(insert);
    sqlite3_finalize(insert);
    if (stepped != SQLITE_DONE) return -1;
    sqlite3_int64 rowid = sqlite3_last_insert_rowid(db);
    sqlite3_blob *blob = NULL;
    if (sqlite3_blob_open(db, "main", "artifact", "bytes", rowid, 1, &blob) != SQLITE_OK)
        return -1;
    if (lseek(fd, 0, SEEK_SET) < 0) { sqlite3_blob_close(blob); return -1; }
    uint64_t offset = 0;
    while (offset < length) {
        size_t wanted = length - offset < IMPORT_WINDOW ? (size_t)(length - offset) : IMPORT_WINDOW;
        ssize_t got = read(fd, window, wanted);
        if (got <= 0 || sqlite3_blob_write(blob, window, (int)got, (int)offset) != SQLITE_OK) {
            sqlite3_blob_close(blob);
            return -1;
        }
        offset += (uint64_t)got;
    }
    return sqlite3_blob_close(blob) == SQLITE_OK ? 0 : -1;
}

static int settle(sqlite3 *db, struct Runtime *runtime, struct PhysicalCustody *cell,
                  uint8_t window[IMPORT_WINDOW], uint64_t *max_overlap,
                  uint64_t *max_settle_ns) {
    uint32_t active = atomic_fetch_add_explicit(&runtime->validator_active, 1, memory_order_acq_rel) + 1;
    uint32_t old = atomic_load_explicit(&runtime->validator_max, memory_order_relaxed);
    while (active > old && !atomic_compare_exchange_weak(&runtime->validator_max, &old, active)) {}
    bool valid = !(cell->flags & (FLAG_PREPARATION_FAILED | FLAG_STORAGE_FAILURE |
                                  FLAG_OUTPUT_LIMIT | FLAG_TRANSPORT_FAILURE)) &&
        (cell->kind != KIND_MODEL || contains_synthetic_terminal(cell->spool_a, window));
    cell->terminal_seen = valid;
    atomic_fetch_sub_explicit(&runtime->validator_active, 1, memory_order_release);

    uint64_t started = now_ns();
    if (sql_exec(db, "BEGIN IMMEDIATE") != 0) return -1;
    bool import_content = valid || (cell->kind == KIND_BASH &&
        (cell->flags & FLAG_CANCELLED) &&
        !(cell->flags & (FLAG_STORAGE_FAILURE | FLAG_OUTPUT_LIMIT)));
    if (import_content && cell->spool_a >= 0 && import_part(db, cell->attempt_id, 0, cell->spool_a,
                                         cell->bytes_a, window) != 0) goto rollback;
    if (import_content && cell->spool_b >= 0 && import_part(db, cell->attempt_id, 1, cell->spool_b,
                                         cell->bytes_b, window) != 0) goto rollback;
    uint64_t overlap = allocated_fd_bytes(cell->spool_a) + allocated_fd_bytes(cell->spool_b);
    if (overlap > *max_overlap) *max_overlap = overlap;


    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO completion(attempt_id,class,evidence_digest) VALUES(?1,?2,?3);"
            , -1, &statement, NULL) != SQLITE_OK) goto rollback;
    sqlite3_bind_int64(statement, 1, (sqlite3_int64)cell->attempt_id);
    const char *completion_class = (cell->flags & FLAG_PREPARATION_FAILED) ? "preparation_failure"
        : ((cell->flags & FLAG_STORAGE_FAILURE) ? "local_resource_failure"
        : ((cell->flags & FLAG_OUTPUT_LIMIT) ? "output_limit"
        : ((cell->flags & FLAG_TRANSPORT_FAILURE) ? "transport_failure"
        : ((cell->flags & FLAG_CANCELLED) ? (cell->kind == KIND_MODEL ? "model_cancelled" : "bash_cancelled")
        : ((cell->kind == KIND_PATCH && cell->wait_status == 2) ? "patch_conflict"
        : ((cell->kind == KIND_PATCH && cell->wait_status != 1) ? "patch_indeterminate"
        : (valid ? "success" : "protocol_error")))))));
    sqlite3_bind_text(statement, 2, completion_class, -1, SQLITE_STATIC);
    sqlite3_bind_text(statement, 3, "integrated-artifact", -1, SQLITE_STATIC);
    int stepped = sqlite3_step(statement);
    sqlite3_finalize(statement);
    if (stepped != SQLITE_DONE) goto rollback;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO resolution(operation_id,completion_attempt_id) VALUES(?1,?2)",
            -1, &statement, NULL) != SQLITE_OK) goto rollback;
    sqlite3_bind_int64(statement, 1, (sqlite3_int64)cell->operation_id);
    sqlite3_bind_int64(statement, 2, (sqlite3_int64)cell->attempt_id);
    stepped = sqlite3_step(statement);
    sqlite3_finalize(statement);
    if (stepped != SQLITE_DONE || sql_exec(db, "COMMIT") != 0) goto rollback;
    if (cell->kind == KIND_BASH) {
        if (cell->flags & FLAG_TERM_SENT) atomic_fetch_add(&runtime->bash_term_sent, 1);
        if (cell->flags & FLAG_KILL_SENT) atomic_fetch_add(&runtime->bash_kill_sent, 1);
        if (cell->root_reaped) atomic_fetch_add(&runtime->bash_reaped, 1);
        if (cell->flags & FLAG_PIPE_GRACE_EXPIRED)
            atomic_fetch_add(&runtime->bash_pipe_grace_expired, 1);
    } else if (cell->kind == KIND_MODEL) {
        max_u64(&runtime->max_model_callback_gap_ns, cell->grace_deadline_ns);
    }
    uint64_t elapsed = now_ns() - started;
    if (elapsed > *max_settle_ns) *max_settle_ns = elapsed;
    return 0;
rollback:
    if (!sqlite3_get_autocommit(db)) (void)sql_exec(db, "ROLLBACK");
    return -1;
}

static void release_cell(struct PhysicalCustody *cell) {
    uint64_t charge = cell->bytes_a + cell->bytes_b;
    if (charge) atomic_fetch_sub_explicit(&cell->runtime->scratch_logical_current,
                                          charge, memory_order_relaxed);
    if (cell->easy) curl_easy_cleanup(cell->easy);
    if (cell->spool_a >= 0) close(cell->spool_a);
    if (cell->spool_b >= 0) close(cell->spool_b);
    if (cell->pipe_a >= 0) close(cell->pipe_a);
    if (cell->pipe_b >= 0) close(cell->pipe_b);
    cell->easy = NULL;
    cell->spool_a = cell->spool_b = cell->pipe_a = cell->pipe_b = -1;
    cell->terminal_seen = 0;
    cell->root_reaped = 0;
    cell->flags = 0;
    cell->attempt_id = 0;
    cell->operation_id = 0;
    cell->started_ns = 0;
    cell->completed_ns = 0;
    cell->bytes_a = 0;
    cell->bytes_b = 0;
    cell->callbacks = 0;
    cell->deadline_ns = 0;
    cell->grace_deadline_ns = 0;
    cell->root_pid = 0;
    cell->process_group = 0;
    cell->wait_status = 0;
    atomic_store_explicit(&cell->state, CUSTODY_FREE, memory_order_release);
}

static int wait_lanes_ready(struct Runtime *runtime, bool patch_lane) {
    uint64_t deadline = now_ns() + 5000000000ULL;
    pthread_mutex_lock(&runtime->wake_mutex);
    while ((!atomic_load_explicit(&runtime->reactor_ready, memory_order_acquire) ||
            (patch_lane && !atomic_load_explicit(&runtime->patch_ready, memory_order_acquire))) &&
           !atomic_load_explicit(&runtime->fatal, memory_order_acquire)) {
        if (now_ns() >= deadline) {
            pthread_mutex_unlock(&runtime->wake_mutex);
            return -1;
        }
        struct timespec wait_until;
        clock_gettime(CLOCK_REALTIME, &wait_until);
        wait_until.tv_nsec += 10000000;
        if (wait_until.tv_nsec >= 1000000000) {
            wait_until.tv_sec++;
            wait_until.tv_nsec -= 1000000000;
        }
        (void)pthread_cond_timedwait(&runtime->wake_cond, &runtime->wake_mutex, &wait_until);
    }
    bool ready = atomic_load_explicit(&runtime->reactor_ready, memory_order_acquire) &&
        (!patch_lane || atomic_load_explicit(&runtime->patch_ready, memory_order_acquire));
    pthread_mutex_unlock(&runtime->wake_mutex);
    return ready ? 0 : -1;
}

static void print_sample(const char *name, const struct Sample *sample) {
    printf("\"%s\":{\"rss\":%llu,\"physical\":%llu,\"lifetime_physical\":%llu,\"virtual\":%llu,\"threads\":%u,\"fds\":%u}",
           name, sample->rss, sample->physical, sample->lifetime_physical,
           sample->virtual_size, sample->threads, sample->fds);
}

static int scalar_int(sqlite3 *db, const char *sql) {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) return -1;
    int value = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
    sqlite3_finalize(statement);
    return value;
}

static int run_integrated(int argc, char **argv) {
    if (argc != 8 && argc != 9 && argc != 10) {
        fprintf(stderr, "usage: %s capacity url cafile scratch db-path patch-mode(owner|lane) timeout-seconds [mixed|bash-only|patch-race] [normal|term|kill|inherited|escaped|interfere-before|interfere-during|interfere-after]\n", argv[0]);
        return 2;
    }
    int capacity = atoi(argv[1]);
    int timeout_seconds = atoi(argv[7]);
    if (capacity < 1 || capacity > MAX_CAPACITY || timeout_seconds < 1) return 2;
    bool patch_lane = strcmp(argv[6], "lane") == 0;
    bool patch_owner = strcmp(argv[6], "owner") == 0;
    if (!patch_lane && !patch_owner) return 2;
    if (curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK) return 1;

    struct Runtime runtime = {0};
    runtime.capacity = capacity;
    const char *control_text = getenv("ONEPAGE_PROOF_CONTROL");
    runtime.control_mode = control_text ? atoi(control_text) : 0;
    if (runtime.control_mode < 0 || runtime.control_mode > 3) return 2;
    runtime.url = argv[2]; runtime.cafile = argv[3]; runtime.scratch = argv[4];
    runtime.database_path = argv[5];
    runtime.self_path = program_path;
    runtime.bash_fixture = argc == 10 ? argv[9] : "normal";
    const char *profile = argc >= 9 ? argv[8] : "mixed";
    bool fixture_valid = strcmp(runtime.bash_fixture, "normal") == 0 ||
        strcmp(runtime.bash_fixture, "term") == 0 ||
        strcmp(runtime.bash_fixture, "kill") == 0 ||
        strcmp(runtime.bash_fixture, "inherited") == 0 ||
        strcmp(runtime.bash_fixture, "escaped") == 0 ||
        strcmp(runtime.bash_fixture, "interfere-before") == 0 ||
        strcmp(runtime.bash_fixture, "interfere-during") == 0 ||
        strcmp(runtime.bash_fixture, "interfere-after") == 0;
    if (!fixture_valid || (strcmp(profile, "mixed") != 0 &&
        strcmp(profile, "model-only") != 0 && strcmp(profile, "bash-only") != 0 && strcmp(profile, "patch-race") != 0)) return 2;
    runtime.bash_term_grace_ns = 250000000ULL;
    runtime.bash_pipe_grace_ns = 500000000ULL;
    const char *effect_limit_text = getenv("ONEPAGE_PROOF_EFFECT_OUTPUT_LIMIT");
    const char *host_quota_text = getenv("ONEPAGE_PROOF_HOST_SCRATCH_QUOTA");
    const char *fatal_loops_text = getenv("ONEPAGE_PROOF_INJECT_REACTOR_FATAL_AFTER_LOOPS");
    const char *cycles_text = getenv("ONEPAGE_PROOF_CYCLES");
    runtime.effect_output_limit = effect_limit_text ? strtoull(effect_limit_text, NULL, 10) : UINT64_MAX;
    runtime.host_scratch_quota = host_quota_text ? strtoull(host_quota_text, NULL, 10) : UINT64_MAX;
    runtime.inject_reactor_fatal_after_loops = fatal_loops_text
        ? strtoull(fatal_loops_text, NULL, 10) : 0;
    int cycles = cycles_text ? atoi(cycles_text) : 1;
    if (cycles < 1 || cycles > 1000 || (runtime.control_mode && cycles != 1)) return 2;
    if (strcmp(runtime.bash_fixture, "term") == 0 || strcmp(runtime.bash_fixture, "kill") == 0)
        runtime.bash_cancel_after_ns = 100000000ULL;
    bool bash_only = strcmp(profile, "bash-only") == 0;
    bool patch_race = strcmp(profile, "patch-race") == 0;
    if (strcmp(profile, "model-only") == 0) {
        runtime.patch_index = -1;
        runtime.bash_count = 0;
        runtime.model_count = capacity;
    } else if (bash_only) {
        runtime.patch_index = -1;
        runtime.bash_count = capacity;
        runtime.model_count = 0;
    } else if (patch_race) {
        if (capacity != 2) return 2;
        runtime.patch_index = 1;
        runtime.bash_count = 1;
        runtime.model_count = 0;
    } else {
        runtime.patch_index = capacity >= 10 ? capacity - 1 : -1;
        runtime.bash_count = capacity > 1 ? capacity / 4 : 0;
        runtime.model_count = capacity - runtime.bash_count - (runtime.patch_index >= 0 ? 1 : 0);
    }
    if (getenv("ONEPAGE_PROOF_NATIVE_POLL") && strcmp(profile, "model-only") != 0) return 2;
    if (pthread_mutex_init(&runtime.wake_mutex, NULL) != 0) return 1;
    if (pthread_cond_init(&runtime.wake_cond, NULL) != 0) {
        (void)pthread_mutex_destroy(&runtime.wake_mutex);
        return 1;
    }
    for (int i = 0; i < capacity; ++i) {
        runtime.cells[i].spool_a = runtime.cells[i].spool_b = -1;
        runtime.cells[i].pipe_a = runtime.cells[i].pipe_b = -1;
        runtime.cells[i].runtime = &runtime;
        runtime.cells[i].kind = i < runtime.model_count ? KIND_MODEL
            : (i == runtime.patch_index ? KIND_PATCH : KIND_BASH);
    }

    struct Sample unopened = {0}, store_open = {0}, lanes_idle = {0}, active = {0};
    struct Sample first_cycle_idle = {0}, final_cycle_idle = {0}, idle = {0};
    if (!observe(&unopened)) return 1;
    sqlite3 *db = NULL;
    if (open_database(argv[5], &db) != 0) return 1;
    if (!observe(&store_open)) return 1;
    if (sql_exec(db, "CREATE TABLE probe_stop(operation_id INTEGER PRIMARY KEY REFERENCES operation(id))") != 0) return 1;

    pthread_attr_t reactor_attr;
    if (pthread_attr_init(&reactor_attr) != 0) return 1;
    size_t reactor_stack = 256 * 1024;
    if (pthread_attr_setstacksize(&reactor_attr, reactor_stack) != 0) {
        (void)pthread_attr_destroy(&reactor_attr);
        return 1;
    }
    pthread_t reactor;
    if (pthread_create(&reactor, &reactor_attr, reactor_main, &runtime) != 0) return 1;
    if (pthread_attr_destroy(&reactor_attr) != 0) return 1;

    pthread_t patch_thread = 0;
    struct PatchArgs patch_args = {.runtime = &runtime, .index = runtime.patch_index};
    size_t patch_stack = 0;
    if (runtime.patch_index >= 0) {
        if (patch_lane) {
            pthread_attr_t patch_attr;
            if (pthread_attr_init(&patch_attr) != 0) return 1;
            patch_stack = 128 * 1024;
            if (pthread_attr_setstacksize(&patch_attr, patch_stack) != 0) {
                (void)pthread_attr_destroy(&patch_attr);
                return 1;
            }
            if (pthread_create(&patch_thread, &patch_attr, patch_main, &patch_args) != 0) return 1;
            if (pthread_attr_destroy(&patch_attr) != 0) return 1;
        }
    }
    if (wait_lanes_ready(&runtime, patch_lane && runtime.patch_index >= 0) != 0) return 1;
    if (!observe(&lanes_idle)) return 1;
    memory_phase("host_idle", 0);
    pthread_t control_thread = 0;
    if (runtime.control_mode) {
        pthread_attr_t attr;
        if (pthread_attr_init(&attr) != 0 || pthread_attr_setstacksize(&attr, 128 * 1024) != 0) return 1;
        if (pthread_create(&control_thread, &attr, control_sender, &runtime) != 0) return 1;
        if (pthread_attr_destroy(&attr) != 0) return 1;
    }

    uint8_t import_window[IMPORT_WINDOW];
    int settled = 0;
    uint64_t max_overlap = 0, max_settle_ns = 0, max_owner_scan_ns = 0;
    uint64_t received_bytes = 0;
    struct rusage usage_before = {0}, usage_after = {0};
    if (getrusage(RUSAGE_SELF, &usage_before) != 0) return 1;
    uint64_t wall_started = now_ns();
    int completed_cycles = 0;
    for (int cycle = 0; cycle < cycles &&
         !atomic_load_explicit(&runtime.fatal, memory_order_acquire); ++cycle) {
        if (runtime.patch_index >= 0 && prepare_patch_target(&runtime) != 0) return 1;
        atomic_store_explicit(&runtime.first_model_sealed_ns, 0, memory_order_relaxed);
        atomic_store_explicit(&runtime.last_model_sealed_ns, 0, memory_order_relaxed);
        for (int i = 0; i < capacity; ++i) {
            int id = cycle * capacity + i + 1;
            if (admit(db, &runtime.cells[i], id) != 0) return 1;
        }
        signal_owner(&runtime);
        if (runtime.patch_index >= 0 && patch_owner) {
            struct PhysicalCustody *cell = &runtime.cells[runtime.patch_index];
            uint32_t expected = CUSTODY_DISPATCHABLE;
            if (!atomic_compare_exchange_strong(&cell->state, &expected, CUSTODY_ACTIVE))
                return 1;
            if (run_patch_quantum(&runtime, cell) != 0)
                cell->flags |= FLAG_PREPARATION_FAILED;
            seal_cell(&runtime, cell);
        }

        int cycle_settled = 0;
        uint64_t deadline = now_ns() + (uint64_t)timeout_seconds * 1000000000ULL;
        while (cycle_settled < capacity && now_ns() < deadline &&
               !atomic_load_explicit(&runtime.fatal, memory_order_acquire)) {
            if (service_control(db, &runtime, capacity - cycle_settled) != 0) return 1;
            uint64_t scan_started = now_ns();
            uint64_t live_spools = live_spool_allocated(&runtime);
            max_u64(&runtime.max_live_spool_allocated, live_spools);
            max_u64(&runtime.max_storage_allocated,
                    live_spools + sqlite_storage_allocated(runtime.database_path));
            bool progressed = false;
            for (int i = 0; i < capacity; ++i) {
                struct PhysicalCustody *cell = &runtime.cells[i];
                if (atomic_load_explicit(&cell->state, memory_order_acquire) != CUSTODY_SEALED)
                    continue;
                if (runtime.control_mode) atomic_store(&runtime.control_trigger, true);
                if (settle(db, &runtime, cell, import_window, &max_overlap, &max_settle_ns) != 0)
                    return 1;
                received_bytes += cell->bytes_a + cell->bytes_b;
                bool is_cancelled_target = runtime.control_mode && cell->operation_id == (uint64_t)capacity;
                if (is_cancelled_target) runtime.cancelled_bytes = cell->bytes_a + cell->bytes_b;
                release_cell(cell);
                if (is_cancelled_target) runtime.control_released_ns = now_ns();
                else if (++runtime.ordinary_settled == capacity - 1) runtime.ordinary_finished_ns = now_ns();
                cycle_settled++;
                settled++;
                progressed = true;
                if (runtime.control_mode >= 2 && service_control(db, &runtime, capacity - cycle_settled) != 0) return 1;
                if (runtime.control_mode == 3 && i != capacity - 1) {
                    struct PhysicalCustody *target = &runtime.cells[capacity - 1];
                    if (atomic_load_explicit(&target->state, memory_order_acquire) == CUSTODY_SEALED &&
                        (target->flags & FLAG_CANCELLED)) {
                        if (settle(db, &runtime, target, import_window, &max_overlap, &max_settle_ns) != 0) return 1;
                        runtime.cancelled_bytes = target->bytes_a + target->bytes_b;
                        received_bytes += runtime.cancelled_bytes;
                        release_cell(target);
                        runtime.control_released_ns = now_ns();
                        cycle_settled++; settled++;
                    }
                }
            }
            uint64_t scan_elapsed = now_ns() - scan_started;
            if (scan_elapsed > max_owner_scan_ns) max_owner_scan_ns = scan_elapsed;
            if (!observe(&active)) {
                atomic_store_explicit(&runtime.fatal, true, memory_order_release);
                signal_owner(&runtime);
                break;
            }
            if (!progressed) {
                struct timespec wait_until;
                clock_gettime(CLOCK_REALTIME, &wait_until);
                wait_until.tv_nsec += 10000000;
                if (wait_until.tv_nsec >= 1000000000) {
                    wait_until.tv_sec++;
                    wait_until.tv_nsec -= 1000000000;
                }
                pthread_mutex_lock(&runtime.wake_mutex);
                (void)pthread_cond_timedwait(&runtime.wake_cond, &runtime.wake_mutex,
                                             &wait_until);
                pthread_mutex_unlock(&runtime.wake_mutex);
            }
        }
        if (cycle_settled != capacity) break;
        struct Sample cycle_idle = {0};
        if (!observe(&cycle_idle)) {
            atomic_store_explicit(&runtime.fatal, true, memory_order_release);
            signal_owner(&runtime);
            break;
        }
        if (cycle == 0) first_cycle_idle = cycle_idle;
        final_cycle_idle = cycle_idle;
        memory_phase("cycle_idle", cycle + 1);
        fprintf(stderr, "{\"cycle\":%d,\"idle_physical\":%llu,\"idle_fds\":%u,\"scratch\":%llu}\n",
                cycle + 1, cycle_idle.physical, cycle_idle.fds,
                atomic_load(&runtime.scratch_logical_current));
        completed_cycles++;
    }
    uint64_t wall_finished = now_ns();
    if (getrusage(RUSAGE_SELF, &usage_after) != 0)
        atomic_store_explicit(&runtime.fatal, true, memory_order_release);

    if (control_thread) {
        atomic_store(&runtime.control_trigger, true);
        if (pthread_join(control_thread, NULL) != 0) return 1;
    }
    size_t allocator_relief_return = 0;

    if (!observe(&idle)) atomic_store_explicit(&runtime.fatal, true, memory_order_release);
    const char *idle_hold_text = getenv("ONEPAGE_PROOF_IDLE_HOLD_SECONDS");
    int idle_hold_seconds = idle_hold_text ? atoi(idle_hold_text) : 0;
    if (idle_hold_seconds > 0) {
        fprintf(stderr, "phase=idle pid=%d seconds=%d\n", getpid(), idle_hold_seconds);
        sleep((unsigned)idle_hold_seconds);
        if (!observe(&idle)) atomic_store_explicit(&runtime.fatal, true, memory_order_release);
    }
    atomic_store_explicit(&runtime.stop, true, memory_order_release);
    signal_owner(&runtime);
    if (pthread_join(reactor, NULL) != 0)
        atomic_store_explicit(&runtime.fatal, true, memory_order_release);
    if (patch_thread && pthread_join(patch_thread, NULL) != 0)
        atomic_store_explicit(&runtime.fatal, true, memory_order_release);
    if (atomic_load(&runtime.fatal)) {
        for (int i = 0; i < capacity; ++i)
            if (atomic_load(&runtime.cells[i].state) != CUSTODY_FREE)
                release_cell(&runtime.cells[i]);
    }
    memory_phase("transport_closed", cycles);
    sqlite3_int64 sqlite_current = 0, sqlite_highwater = 0;
    int sqlite_heap_status = sqlite3_status64(
        SQLITE_STATUS_MEMORY_USED, &sqlite_current, &sqlite_highwater, 0);
    int sqlite_cache_current = 0, sqlite_cache_highwater = 0;
    int sqlite_cache_status = sqlite3_db_status(
        db, SQLITE_DBSTATUS_CACHE_USED, &sqlite_cache_current, &sqlite_cache_highwater, 0);
    int rows = 0;
    sqlite3_stmt *count = NULL;
    if (sqlite3_prepare_v2(db, "SELECT count(*) FROM resolution", -1, &count, NULL) == SQLITE_OK &&
        sqlite3_step(count) == SQLITE_ROW) rows = sqlite3_column_int(count, 0);
    sqlite3_finalize(count);
    int success_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='success'");
    int protocol_error_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='protocol_error'");
    int preparation_failure_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='preparation_failure'");
    int bash_cancelled_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='bash_cancelled'");
    int transport_failure_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='transport_failure'");
    int local_resource_failure_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='local_resource_failure'");
    int output_limit_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='output_limit'");
    int patch_conflict_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='patch_conflict'");
    int patch_indeterminate_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='patch_indeterminate'");
    int artifact_rows = scalar_int(db, "SELECT count(*) FROM artifact");
    int model_cancelled_rows = scalar_int(db, "SELECT count(*) FROM completion WHERE class='model_cancelled'");
    int stop_rows = scalar_int(db, "SELECT count(*) FROM probe_stop");
    if (sqlite3_close(db) != SQLITE_OK)
        atomic_store_explicit(&runtime.fatal, true, memory_order_release);
    memory_phase("database_closed", cycles);
    curl_global_cleanup();
    memory_phase("libraries_closed", cycles);
    if (getenv("ONEPAGE_PROOF_MEMORY_DETAIL")) {
        sleep(2);
        memory_phase("natural_idle_2s", cycles);
        allocator_relief_return = malloc_zone_pressure_relief(NULL, 0);
        memory_phase("after_relief", cycles);
    }
    struct Sample closed = {0};
    if (!observe(&closed)) return 1;
    int patch_final_relation = 0;
    if (runtime.patch_target[0]) {
        int target = open(runtime.patch_target, O_RDONLY | O_CLOEXEC);
        uint8_t value = 0;
        if (target >= 0 && read(target, &value, 1) == 1)
            patch_final_relation = value == 'p' ? 1 : (value == 'a' ? 2 : 3);
        if (target >= 0) close(target);
    }

    uint64_t requested = atomic_load(&runtime.control_requested_ns);
    uint64_t removed = atomic_load(&runtime.control_removed_ns);
    printf("{\"control\":{\"mode\":%d,\"request_ns\":%llu,\"commit_ns\":%llu,\"removed_ns\":%llu,\"released_ns\":%llu,\"ordinary_finished_ns\":%llu,\"pending_at_commit\":%d,\"stop_rows\":%d,\"cancelled_rows\":%d,\"discarded_bytes\":%llu},",
        runtime.control_mode, requested, runtime.control_committed_ns, removed, runtime.control_released_ns,
        runtime.ordinary_finished_ns, runtime.control_pending_results, stop_rows, model_cancelled_rows, runtime.cancelled_bytes);
    printf("\"native_poll\":%s,", getenv("ONEPAGE_PROOF_NATIVE_POLL") ? "true" : "false");
    printf("\"received_bytes\":%llu,\"max_owner_scan_ns\":%llu,\"custody_array_reserved_bytes\":%zu,\"curl_version\":\"%s\",\"sqlite_version\":\"%s\",",
           received_bytes, max_owner_scan_ns, sizeof(runtime.cells), curl_version(), sqlite3_libversion());
    int expected_attempts = capacity * cycles;
    printf("\"capacity\":%d,\"cycles\":%d,\"completed_cycles\":%d,\"model\":%d,\"bash\":%d,\"patch\":%d,\"patch_mode\":\"%s\",",
           capacity, cycles, completed_cycles,
           runtime.model_count, runtime.bash_count, runtime.patch_index >= 0,
           patch_lane ? "lane" : "owner");
    printf("\"custody_bytes_each\":%zu,\"custody_bytes_capacity\":%zu,",
           sizeof(struct PhysicalCustody), sizeof(struct PhysicalCustody) * (size_t)capacity);
    printf("\"custody_offsets\":{\"state\":%zu,\"attempt_id\":%zu,\"easy\":%zu,\"runtime\":%zu,\"spool_a\":%zu},",
           offsetof(struct PhysicalCustody, state),
           offsetof(struct PhysicalCustody, attempt_id),
           offsetof(struct PhysicalCustody, easy),
           offsetof(struct PhysicalCustody, runtime),
           offsetof(struct PhysicalCustody, spool_a));
    printf("\"reactor_stack_configured\":%zu,\"patch_stack_configured\":%zu,",
           reactor_stack, patch_stack);
    printf("\"settled\":%d,\"resolution_rows\":%d,\"validator_max\":%u,",
           settled, rows, atomic_load(&runtime.validator_max));
    printf("\"host_fatal\":%s,\"unresolved_attempts\":%d,",
           atomic_load(&runtime.fatal) ? "true" : "false", expected_attempts - rows);
    printf("\"artifact_rows\":%d,", artifact_rows);
    printf("\"completion_classes\":{\"success\":%d,\"protocol_error\":%d,\"preparation_failure\":%d,\"transport_failure\":%d,\"local_resource_failure\":%d,\"output_limit\":%d,\"bash_cancelled\":%d,\"patch_conflict\":%d,\"patch_indeterminate\":%d},",
           success_rows, protocol_error_rows, preparation_failure_rows,
           transport_failure_rows, local_resource_failure_rows, output_limit_rows,
           bash_cancelled_rows, patch_conflict_rows, patch_indeterminate_rows);
    printf("\"bash_evidence\":{\"term_sent\":%u,\"kill_sent\":%u,\"reaped\":%u,\"pipe_grace_expired\":%u},",
           atomic_load(&runtime.bash_term_sent), atomic_load(&runtime.bash_kill_sent),
           atomic_load(&runtime.bash_reaped), atomic_load(&runtime.bash_pipe_grace_expired));
    printf("\"bash_timing_ns\":{\"term_lateness_max\":%llu,\"kill_lateness_max\":%llu,\"signal_to_reap_max\":%llu,\"pipe_grace_lateness_max\":%llu},",
           atomic_load(&runtime.max_term_lateness_ns),
           atomic_load(&runtime.max_kill_lateness_ns),
           atomic_load(&runtime.max_signal_to_reap_ns),
           atomic_load(&runtime.max_pipe_grace_lateness_ns));
    printf("\"reactor_loops\":%llu,\"max_poll_ns\":%llu,\"max_write_ns\":%llu,",
           atomic_load(&runtime.reactor_loops), atomic_load(&runtime.max_poll_ns),
           atomic_load(&runtime.max_write_ns));
    double cpu_before = (double)usage_before.ru_utime.tv_sec + usage_before.ru_utime.tv_usec / 1e6 +
        (double)usage_before.ru_stime.tv_sec + usage_before.ru_stime.tv_usec / 1e6;
    double cpu_after = (double)usage_after.ru_utime.tv_sec + usage_after.ru_utime.tv_usec / 1e6 +
        (double)usage_after.ru_stime.tv_sec + usage_after.ru_stime.tv_usec / 1e6;
    double wall_seconds = (double)(wall_finished - wall_started) / 1e9;
    printf("\"wall_seconds\":%.6f,\"cpu_seconds\":%.6f,\"cpu_one_core_fraction\":%.6f,",
           wall_seconds, cpu_after - cpu_before, (cpu_after - cpu_before) / wall_seconds);
    printf("\"max_model_callback_gap_ns\":%llu,",
           atomic_load(&runtime.max_model_callback_gap_ns));
    uint64_t first_model_sealed = atomic_load(&runtime.first_model_sealed_ns);
    uint64_t last_model_sealed = atomic_load(&runtime.last_model_sealed_ns);
    printf("\"model_terminal_spread_ns\":%llu,",
           first_model_sealed && last_model_sealed >= first_model_sealed
               ? last_model_sealed - first_model_sealed : 0);
    printf("\"max_single_raw_spool_allocated\":%llu,\"max_settle_ns\":%llu,",
           max_overlap, max_settle_ns);
    printf("\"max_live_spool_allocated\":%llu,\"max_storage_allocated\":%llu,",
           atomic_load(&runtime.max_live_spool_allocated),
           atomic_load(&runtime.max_storage_allocated));
    printf("\"scratch_logical_highwater\":%llu,\"scratch_logical_final\":%llu,",
           atomic_load(&runtime.scratch_logical_highwater),
           atomic_load(&runtime.scratch_logical_current));
    printf("\"sqlite_heap_supported\":%s,\"sqlite_heap_current\":%lld,\"sqlite_heap_highwater\":%lld,",
           sqlite_heap_status == SQLITE_OK && sqlite_highwater > 0 ? "true" : "false",
           sqlite_current, sqlite_highwater);
    printf("\"sqlite_cache_supported\":%s,\"sqlite_cache_current\":%d,",
           sqlite_cache_status == SQLITE_OK ? "true" : "false", sqlite_cache_current);
    printf("\"spool_nocache\":%s,\"allocator_relief_return\":%zu,",
           getenv("ONEPAGE_PROOF_SPOOL_NOCACHE") ? "true" : "false",
           allocator_relief_return);
    long long idle_physical_drift = (long long)final_cycle_idle.physical -
        (long long)first_cycle_idle.physical;
    long long post_relief_physical_drift = (long long)idle.physical -
        (long long)first_cycle_idle.physical;
    printf("\"idle_physical_drift\":%lld,\"post_relief_physical_drift\":%lld,",
           idle_physical_drift, post_relief_physical_drift);
    printf("\"patch_final_relation\":%d,", patch_final_relation);
    print_sample("unopened", &unopened); printf(",");
    print_sample("store_open", &store_open); printf(",");
    print_sample("lanes_idle", &lanes_idle); printf(",");
    print_sample("active", &active); printf(",");
    print_sample("first_cycle_idle", &first_cycle_idle); printf(",");
    print_sample("final_cycle_idle", &final_cycle_idle); printf(",");
    print_sample("idle", &idle); printf(",");
    print_sample("closed", &closed); printf("}\n");

    bool synchronization_destroyed = pthread_cond_destroy(&runtime.wake_cond) == 0 &&
        pthread_mutex_destroy(&runtime.wake_mutex) == 0;
    if (runtime.patch_target[0]) {
        remove_patch_markers(runtime.patch_target);
        (void)unlink(runtime.patch_target);
    }
    return synchronization_destroyed && !atomic_load(&runtime.fatal) && completed_cycles == cycles &&
        settled == expected_attempts && rows == expected_attempts ? 0 : 1;
}

int main(int argc, char **argv) {
    program_path = argv[0];
    if (argc == 4 && strcmp(argv[1], "child") == 0)
        return run_bash_child(argv[2], argv[3]);
    if (argc >= 2 && strcmp(argv[1], "integrated") == 0)
        return run_integrated(argc - 1, argv + 1);
    fprintf(stderr, "usage: %s integrated capacity url cafile scratch db-path patch-mode timeout-seconds [mixed|bash-only|patch-race] [normal|term|kill|inherited|escaped|interfere-before|interfere-during|interfere-after]\n",
            argv[0]);
    return 2;
}
