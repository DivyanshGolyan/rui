// Diagnostic only: query an explicitly owned PID without task-port access.
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static uint64_t nanoseconds(struct timespec value) {
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    long parsed = strcmp(argv[1], "--self") == 0 ? getpid() : strtol(argv[1], &end, 10);
    if (errno != 0 || parsed <= 0 || parsed > INT_MAX ||
        (end != NULL && (*end != '\0' || end == argv[1]))) return 2;
    int pid = (int)parsed;
    struct proc_bsdinfo before = {0}, after = {0};
    struct rusage_info_v4 usage = {0};
    struct timespec wall_begin = {0}, wall_end = {0}, mono_begin = {0}, mono_end = {0};
    if (clock_gettime(CLOCK_REALTIME, &wall_begin) != 0 ||
        clock_gettime(CLOCK_MONOTONIC, &mono_begin) != 0) return 3;
    errno = 0;
    int before_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before));
    int before_errno = errno;
    errno = 0;
    int usage_rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage);
    int usage_errno = errno;
    errno = 0;
    int after_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after));
    int after_errno = errno;
    if (clock_gettime(CLOCK_MONOTONIC, &mono_end) != 0 ||
        clock_gettime(CLOCK_REALTIME, &wall_end) != 0) return 3;
    bool same = before_bytes == (int)sizeof(before) && after_bytes == (int)sizeof(after) &&
        before.pbi_pid == (uint32_t)pid && after.pbi_pid == (uint32_t)pid &&
        before.pbi_start_tvsec == after.pbi_start_tvsec &&
        before.pbi_start_tvusec == after.pbi_start_tvusec;
    printf("{\"pid\":%d,\"flavor\":%d,\"buffer_bytes\":%zu,"
           "\"begin_unix_ns\":%" PRIu64 ",\"end_unix_ns\":%" PRIu64 ","
           "\"query_duration_ns\":%" PRIu64 ","
           "\"before_bsd_bytes\":%d,\"before_bsd_errno\":%d,"
           "\"after_bsd_bytes\":%d,\"after_bsd_errno\":%d,"
           "\"bsd_expected_bytes\":%zu,\"rusage_rc\":%d,\"rusage_errno\":%d,"
           "\"identity_unchanged\":%s,"
           "\"before_start_sec\":%" PRIu64 ",\"before_start_usec\":%" PRIu64 ","
           "\"after_start_sec\":%" PRIu64 ",\"after_start_usec\":%" PRIu64 ","
           "\"proc_start_abstime\":%" PRIu64 ","
           "\"current_bytes\":%" PRIu64 ",\"lifetime_peak_bytes\":%" PRIu64 ","
           "\"interval_peak_bytes\":%" PRIu64 "}\n",
           pid, RUSAGE_INFO_V4, sizeof(usage), nanoseconds(wall_begin), nanoseconds(wall_end),
           nanoseconds(mono_end) - nanoseconds(mono_begin),
           before_bytes, before_errno, after_bytes, after_errno, sizeof(before), usage_rc, usage_errno,
           same ? "true" : "false", before.pbi_start_tvsec, before.pbi_start_tvusec,
           after.pbi_start_tvsec, after.pbi_start_tvusec, usage.ri_proc_start_abstime,
           usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint, usage.ri_interval_max_phys_footprint);
    return usage_rc == 0 && same ? 0 : 1;
}
