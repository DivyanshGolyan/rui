#include <mach/mach.h>
#include <stdint.h>
#include <sys/resource.h>

uint64_t probe_rss(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.resident_size : 0;
}
uint64_t probe_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint : 0;
}
uint64_t probe_peak_rss(void) {
    struct rusage r;
    return getrusage(RUSAGE_SELF, &r) == 0 ? (uint64_t)r.ru_maxrss : 0;
}
