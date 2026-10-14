//go:build !darwin || !cgo

package measurement

func readNativeFootprint(pid int32) nativeFootprintReport {
	return nativeFootprintReport{API: "proc_pid_rusage/RUSAGE_INFO_V4", PID: pid,
		Error: "native physical footprint requires macOS with cgo enabled"}
}
