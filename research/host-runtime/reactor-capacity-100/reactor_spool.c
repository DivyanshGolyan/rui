#define _DARWIN_C_SOURCE 1
#include <curl/curl.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct sample {
    uint64_t rss;
    uint64_t physical;
    uint64_t lifetime_physical;
    uint64_t virtual_size;
    uint32_t threads;
    uint32_t fds;
};

struct transfer {
    CURL *easy;
    const char *url;
    const char *cafile;
    int spool_fd;
    uint64_t bytes;
    uint64_t callbacks;
    uint64_t max_callback_bytes;
    uint64_t first_callback_ns;
    uint64_t last_callback_ns;
    uint64_t max_callback_gap_ns;
    uint64_t completed_ns;
    size_t upload_remaining;
    CURLcode result;
    bool done;
    bool in_multi;
    bool cancelled;
};

static uint64_t write_hist[64];
static uint64_t write_calls;
static uint64_t write_ns_total;
static uint64_t write_ns_max;
static uint64_t perform_calls;
static uint64_t perform_ns_total;
static uint64_t perform_ns_max;
static uint64_t poll_calls;
static uint64_t poll_ns_total;
static uint64_t max_socket_backlog;
static uint64_t cancellation_calls;
static uint64_t cancellation_ns_total;
static uint64_t cancellation_ns_max;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static unsigned log2_bucket(uint64_t value) {
    unsigned bucket = 0;
    while (value > 1 && bucket < 63) {
        value >>= 1;
        bucket++;
    }
    return bucket;
}

static uint64_t hist_quantile(double quantile) {
    if (!write_calls) return 0;
    uint64_t target = (uint64_t)(quantile * (double)(write_calls - 1)) + 1;
    uint64_t seen = 0;
    for (unsigned i = 0; i < 64; ++i) {
        seen += write_hist[i];
        if (seen >= target) return 1ULL << i;
    }
    return 1ULL << 63;
}

static void observe(struct sample *out) {
    struct proc_taskinfo task = {0};
    int got = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, sizeof(task));
    struct rusage_info_v4 usage = {0};
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage);
    struct proc_fdinfo fd_list[2048];
    int fd_bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fd_list, sizeof(fd_list));
    if (got == sizeof(task)) {
        if (task.pti_resident_size > out->rss) out->rss = task.pti_resident_size;
        if (task.pti_virtual_size > out->virtual_size) out->virtual_size = task.pti_virtual_size;
        if ((uint32_t)task.pti_threadnum > out->threads) out->threads = (uint32_t)task.pti_threadnum;
    }
    if (usage.ri_phys_footprint > out->physical) out->physical = usage.ri_phys_footprint;
    if (usage.ri_lifetime_max_phys_footprint > out->lifetime_physical)
        out->lifetime_physical = usage.ri_lifetime_max_phys_footprint;
    if (fd_bytes > 0) {
        uint32_t fds = (uint32_t)(fd_bytes / (int)PROC_PIDLISTFD_SIZE);
        if (fds > out->fds) out->fds = fds;
    }
}

static int write_all(int fd, const char *ptr, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t wrote = write(fd, ptr + offset, length - offset);
        if (wrote <= 0) return -1;
        offset += (size_t)wrote;
    }
    return 0;
}

static size_t spool_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct transfer *t = userdata;
    size_t length = size * nmemb;
    uint64_t started = now_ns();
    if (write_all(t->spool_fd, ptr, length) != 0) return 0;
    uint64_t elapsed = now_ns() - started;
    write_calls++;
    write_ns_total += elapsed;
    if (elapsed > write_ns_max) write_ns_max = elapsed;
    write_hist[log2_bucket(elapsed)]++;

    uint64_t at = now_ns();
    if (!t->first_callback_ns) t->first_callback_ns = at;
    if (t->last_callback_ns) {
        uint64_t gap = at - t->last_callback_ns;
        if (gap > t->max_callback_gap_ns) t->max_callback_gap_ns = gap;
    }
    t->last_callback_ns = at;
    t->bytes += length;
    t->callbacks++;
    if (length > t->max_callback_bytes) t->max_callback_bytes = length;
    return length;
}

static size_t read_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct transfer *t = userdata;
    size_t capacity = size * nmemb;
    size_t length = t->upload_remaining < capacity ? t->upload_remaining : capacity;
    memset(ptr, 'x', length);
    t->upload_remaining -= length;
    return length;
}

static int open_unlinked_spool(const char *directory) {
    char path[1024];
    int length = snprintf(path, sizeof(path), "%s/onepage-spool.XXXXXX", directory);
    if (length <= 0 || (size_t)length >= sizeof(path)) return -1;
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    if (unlink(path) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int configure(struct transfer *t, const char *spool_directory) {
    t->spool_fd = open_unlinked_spool(spool_directory);
    if (t->spool_fd < 0) return 1;
    t->easy = curl_easy_init();
    if (!t->easy) return 1;
    curl_easy_setopt(t->easy, CURLOPT_URL, t->url);
    curl_easy_setopt(t->easy, CURLOPT_CAINFO, t->cafile);
    curl_easy_setopt(t->easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(t->easy, CURLOPT_WRITEFUNCTION, spool_cb);
    curl_easy_setopt(t->easy, CURLOPT_WRITEDATA, t);
    curl_easy_setopt(t->easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(t->easy, CURLOPT_NOPROXY, "*");
    curl_easy_setopt(t->easy, CURLOPT_FRESH_CONNECT, 1L);
    curl_easy_setopt(t->easy, CURLOPT_FORBID_REUSE, 1L);
    curl_easy_setopt(t->easy, CURLOPT_ACCEPT_ENCODING, NULL);
    curl_easy_setopt(t->easy, CURLOPT_BUFFERSIZE, 16384L);
    curl_easy_setopt(t->easy, CURLOPT_POST, 1L);
    curl_easy_setopt(t->easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)4096);
    curl_easy_setopt(t->easy, CURLOPT_READFUNCTION, read_cb);
    curl_easy_setopt(t->easy, CURLOPT_READDATA, t);
    curl_easy_setopt(t->easy, CURLOPT_UPLOAD_BUFFERSIZE, 16384L);
    curl_easy_setopt(t->easy, CURLOPT_TIMEOUT, 120L);
    t->upload_remaining = 4096;
    return 0;
}

static void sample_socket_backlog(struct transfer *transfers, int count) {
    for (int i = 0; i < count; ++i) {
        if (transfers[i].done) continue;
        curl_socket_t socket_fd = CURL_SOCKET_BAD;
        if (curl_easy_getinfo(transfers[i].easy, CURLINFO_ACTIVESOCKET, &socket_fd) != CURLE_OK)
            continue;
        if (socket_fd == CURL_SOCKET_BAD) continue;
        int pending = 0;
        if (ioctl(socket_fd, FIONREAD, &pending) == 0 && pending > 0 && (uint64_t)pending > max_socket_backlog)
            max_socket_backlog = (uint64_t)pending;
    }
}

static int compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static uint64_t array_quantile(uint64_t *values, int count, double quantile) {
    qsort(values, (size_t)count, sizeof(*values), compare_u64);
    int index = (int)(quantile * (double)(count - 1));
    return values[index];
}

static void print_sample(const char *name, const struct sample *sample) {
    printf("\"%s\":{\"rss\":%llu,\"physical\":%llu,\"lifetime_physical\":%llu,\"virtual\":%llu,\"threads\":%u,\"fds\":%u}",
           name,
           sample->rss,
           sample->physical,
           sample->lifetime_physical,
           sample->virtual_size,
           sample->threads,
           sample->fds);
}

static double rusage_seconds(const struct rusage *usage) {
    return (double)usage->ru_utime.tv_sec + (double)usage->ru_utime.tv_usec / 1e6
         + (double)usage->ru_stime.tv_sec + (double)usage->ru_stime.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    if (argc != 5 && argc != 7) {
        fprintf(stderr, "usage: %s count url cafile spool-directory [cancel-after-seconds cancel-count]\n", argv[0]);
        return 2;
    }
    int count = atoi(argv[1]);
    double cancel_after_seconds = argc == 7 ? atof(argv[5]) : 0.0;
    int cancel_count = argc == 7 ? atoi(argv[6]) : 0;
    if (count <= 0 || count > 1000) return 2;
    if (cancel_count < 0 || cancel_count > count) return 2;
    if (curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK) return 1;

    struct sample baseline = {0}, configured = {0}, active = {0}, settled = {0}, retained = {0};
    observe(&baseline);
    struct transfer *transfers = calloc((size_t)count, sizeof(*transfers));
    if (!transfers) return 1;
    for (int i = 0; i < count; ++i) {
        transfers[i].url = argv[2];
        transfers[i].cafile = argv[3];
        transfers[i].spool_fd = -1;
        if (configure(&transfers[i], argv[4])) return 1;
    }
    observe(&configured);

    CURLM *multi = curl_multi_init();
    if (!multi) return 1;
    curl_multi_setopt(multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long)count);
    for (int i = 0; i < count; ++i) {
        curl_multi_add_handle(multi, transfers[i].easy);
        transfers[i].in_multi = true;
    }

    struct rusage usage_before = {0}, usage_after = {0};
    getrusage(RUSAGE_SELF, &usage_before);
    uint64_t wall_started = now_ns();
    int running = 0;
    uint64_t perform_started = now_ns();
    CURLMcode multi_result = curl_multi_perform(multi, &running);
    uint64_t perform_elapsed = now_ns() - perform_started;
    perform_calls++;
    perform_ns_total += perform_elapsed;
    if (perform_elapsed > perform_ns_max) perform_ns_max = perform_elapsed;

    uint64_t last_backlog_sample = 0;
    uint64_t last_process_sample = 0;
    const char *backlog_interval_text = getenv("ONEPAGE_BACKLOG_SAMPLE_MS");
    uint64_t backlog_interval_ns = backlog_interval_text
        ? (uint64_t)(atof(backlog_interval_text) * 1000000.0)
        : 0;
    bool cancellation_done = false;
    while (running && multi_result == CURLM_OK) {
        int numfds = 0;
        uint64_t poll_started = now_ns();
        multi_result = curl_multi_poll(multi, NULL, 0, 10, &numfds);
        poll_ns_total += now_ns() - poll_started;
        poll_calls++;
        uint64_t at = now_ns();
        if (!cancellation_done && cancel_count > 0
            && (double)(at - wall_started) / 1e9 >= cancel_after_seconds) {
            for (int i = 0; i < cancel_count; ++i) {
                uint64_t cancel_started = now_ns();
                CURLMcode cancel_result = curl_multi_remove_handle(multi, transfers[i].easy);
                uint64_t cancel_elapsed = now_ns() - cancel_started;
                if (cancel_result != CURLM_OK) {
                    fprintf(stderr, "curl_multi_remove_handle failed: %s\n", curl_multi_strerror(cancel_result));
                    return 1;
                }
                cancellation_calls++;
                cancellation_ns_total += cancel_elapsed;
                if (cancel_elapsed > cancellation_ns_max) cancellation_ns_max = cancel_elapsed;
                transfers[i].in_multi = false;
                transfers[i].cancelled = true;
                transfers[i].done = true;
                transfers[i].completed_ns = now_ns();
            }
            cancellation_done = true;
        }
        if (backlog_interval_ns && at - last_backlog_sample >= backlog_interval_ns) {
            sample_socket_backlog(transfers, count);
            last_backlog_sample = at;
        }
        perform_started = now_ns();
        multi_result = curl_multi_perform(multi, &running);
        perform_elapsed = now_ns() - perform_started;
        perform_calls++;
        perform_ns_total += perform_elapsed;
        if (perform_elapsed > perform_ns_max) perform_ns_max = perform_elapsed;
        if (at - last_process_sample >= 50000000ULL) {
            observe(&active);
            last_process_sample = at;
        }

        int remaining = 0;
        CURLMsg *message;
        while ((message = curl_multi_info_read(multi, &remaining))) {
            if (message->msg != CURLMSG_DONE) continue;
            for (int i = 0; i < count; ++i) {
                if (transfers[i].easy == message->easy_handle) {
                    transfers[i].result = message->data.result;
                    transfers[i].done = true;
                    transfers[i].completed_ns = now_ns();
                    break;
                }
            }
        }
    }
    uint64_t wall_finished = now_ns();
    getrusage(RUSAGE_SELF, &usage_after);
    observe(&settled);

    uint64_t total_bytes = 0, total_callbacks = 0, max_callback_bytes = 0;
    uint64_t spool_blocks = 0;
    int failures = 0;
    uint64_t *gaps = calloc((size_t)count, sizeof(*gaps));
    uint64_t *completion_spread = calloc((size_t)count, sizeof(*completion_spread));
    if (!gaps || !completion_spread) return 1;
    uint64_t first_completion = UINT64_MAX;
    for (int i = 0; i < count; ++i)
        if (transfers[i].completed_ns && transfers[i].completed_ns < first_completion)
            first_completion = transfers[i].completed_ns;
    for (int i = 0; i < count; ++i) {
        total_bytes += transfers[i].bytes;
        total_callbacks += transfers[i].callbacks;
        if (transfers[i].max_callback_bytes > max_callback_bytes)
            max_callback_bytes = transfers[i].max_callback_bytes;
        if (!transfers[i].cancelled && transfers[i].result != CURLE_OK) failures++;
        gaps[i] = transfers[i].max_callback_gap_ns;
        completion_spread[i] = transfers[i].completed_ns - first_completion;
        struct stat statbuf = {0};
        if (fstat(transfers[i].spool_fd, &statbuf) == 0)
            spool_blocks += (uint64_t)statbuf.st_blocks * 512ULL;
        if (transfers[i].in_multi) curl_multi_remove_handle(multi, transfers[i].easy);
        curl_easy_cleanup(transfers[i].easy);
        close(transfers[i].spool_fd);
    }
    curl_multi_cleanup(multi);
    free(transfers);
    observe(&retained);

    double wall_seconds = (double)(wall_finished - wall_started) / 1e9;
    double cpu_seconds = rusage_seconds(&usage_after) - rusage_seconds(&usage_before);
    printf("{");
    printf("\"count\":%d,\"curl_version\":\"%s\",\"failures\":%d,", count, curl_version(), failures);
    printf("\"wall_seconds\":%.6f,\"cpu_seconds\":%.6f,\"cpu_one_core_fraction\":%.6f,", wall_seconds, cpu_seconds, cpu_seconds / wall_seconds);
    printf("\"bytes\":%llu,\"callbacks\":%llu,\"callbacks_per_second\":%.3f,\"bytes_per_second\":%.3f,", total_bytes, total_callbacks, (double)total_callbacks / wall_seconds, (double)total_bytes / wall_seconds);
    printf("\"max_callback_bytes\":%llu,\"max_socket_backlog\":%llu,\"spool_allocated_bytes\":%llu,", max_callback_bytes, max_socket_backlog, spool_blocks);
    printf("\"cancellation\":{\"count\":%llu,\"mean_ns\":%.3f,\"max_ns\":%llu},", cancellation_calls, cancellation_calls ? (double)cancellation_ns_total / (double)cancellation_calls : 0.0, cancellation_ns_max);
    printf("\"write_ns\":{\"mean\":%.3f,\"p50_upper\":%llu,\"p90_upper\":%llu,\"p99_upper\":%llu,\"max\":%llu},", write_calls ? (double)write_ns_total / (double)write_calls : 0.0, hist_quantile(0.50), hist_quantile(0.90), hist_quantile(0.99), write_ns_max);
    printf("\"perform_ns\":{\"calls\":%llu,\"mean\":%.3f,\"max\":%llu},", perform_calls, perform_calls ? (double)perform_ns_total / (double)perform_calls : 0.0, perform_ns_max);
    printf("\"poll_ns\":{\"calls\":%llu,\"total\":%llu},", poll_calls, poll_ns_total);
    printf("\"max_callback_gap_ns\":{\"p50\":%llu,\"p90\":%llu,\"p99\":%llu,\"max\":%llu},", array_quantile(gaps, count, 0.50), array_quantile(gaps, count, 0.90), array_quantile(gaps, count, 0.99), gaps[count - 1]);
    printf("\"completion_spread_ns\":{\"p50\":%llu,\"p90\":%llu,\"p99\":%llu,\"max\":%llu},", array_quantile(completion_spread, count, 0.50), array_quantile(completion_spread, count, 0.90), array_quantile(completion_spread, count, 0.99), completion_spread[count - 1]);
    print_sample("baseline", &baseline); printf(",");
    print_sample("configured", &configured); printf(",");
    print_sample("active", &active); printf(",");
    print_sample("settled", &settled); printf(",");
    print_sample("retained", &retained); printf("}\n");

    free(gaps);
    free(completion_spread);
    curl_global_cleanup();
    return multi_result != CURLM_OK || failures ? 1 : 0;
}
