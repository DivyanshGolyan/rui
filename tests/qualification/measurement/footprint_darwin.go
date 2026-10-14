//go:build darwin && cgo

package measurement

/*
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func readNativeFootprint(pid int32) nativeFootprintReport {
	report := nativeFootprintReport{API: "proc_pid_rusage/RUSAGE_INFO_V4", PID: pid}
	var clock C.mach_timebase_info_data_t
	if status := C.mach_timebase_info(&clock); status != C.KERN_SUCCESS {
		report.Error = fmt.Sprintf("mach_timebase_info: %d", status)
		return report
	}
	report.TimebaseNumer, report.TimebaseDenom = uint32(clock.numer), uint32(clock.denom)
	var usage C.struct_rusage_info_v4
	report.BeginTicks = uint64(C.mach_absolute_time())
	status, err := C.proc_pid_rusage(C.int(pid), C.RUSAGE_INFO_V4, (*C.rusage_info_t)(unsafe.Pointer(&usage)))
	report.EndTicks = uint64(C.mach_absolute_time())
	if status != 0 {
		report.Error = fmt.Sprintf("proc_pid_rusage: %v", err)
		return report
	}
	report.ProcessStart, report.ProcessExit = uint64(usage.ri_proc_start_abstime), uint64(usage.ri_proc_exit_abstime)
	report.CurrentBytes, report.PeakBytes = uint64(usage.ri_phys_footprint), uint64(usage.ri_lifetime_max_phys_footprint)
	return report
}
