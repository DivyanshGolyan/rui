#include <stdint.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif
uint64_t physical_footprint(void) {
#ifdef __APPLE__
 struct task_vm_info t; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&t,&n)!=KERN_SUCCESS)return 0;
 return t.phys_footprint;
#else
 return 0;
#endif
}
