package measurement

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// LinuxMemory contains sequential /proc observations, not macOS footprint or
// allocation-live bytes. PSS proportions shared pages; RSS counts them in full.
type LinuxMemory struct {
	RollupBytes       map[string]uint64 `json:"smaps_rollup_bytes"`
	RSSHighWaterBytes uint64            `json:"status_rss_high_water_bytes"`
	// Linux documents VmHWM as approximate; it is not a PSS high-water mark.
	RequestedGlibcTunables string `json:"requested_glibc_tunables"`
	RequestedPreload       string `json:"requested_ld_preload,omitempty"`
	PreloadMapped          bool   `json:"preload_mapped,omitempty"`
}

var rollupFields = []string{
	"Rss", "Pss", "Pss_Anon", "Pss_File", "Pss_Shmem",
	"Private_Clean", "Private_Dirty", "Shared_Clean", "Shared_Dirty",
	"Anonymous", "AnonHugePages", "Swap", "SwapPss",
}

func parseProcMemory(report string, required []string) (map[string]uint64, error) {
	wanted := make(map[string]bool, len(required))
	for _, key := range required {
		wanted[key] = true
	}
	values := make(map[string]uint64, len(required))
	for _, line := range strings.Split(report, "\n") {
		key, raw, ok := strings.Cut(line, ":")
		if !ok || !wanted[key] {
			continue
		}
		if _, duplicate := values[key]; duplicate {
			return nil, fmt.Errorf("duplicate /proc counter %s", key)
		}
		fields := strings.Fields(raw)
		if len(fields) != 2 || fields[1] != "kB" {
			return nil, fmt.Errorf("invalid /proc counter %s", line)
		}
		kb, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil || kb > ^uint64(0)/1024 {
			return nil, fmt.Errorf("invalid /proc size %s", line)
		}
		values[key] = kb * 1024
	}
	for _, key := range required {
		if _, present := values[key]; !present {
			return nil, fmt.Errorf("missing /proc counter %s", key)
		}
	}
	return values, nil
}

func sampleLinuxMemory(pid int32, rawPath string) (*LinuxMemory, error) {
	root := fmt.Sprintf("/proc/%d/", pid)
	rollup, err := os.ReadFile(root + "smaps_rollup")
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(rawPath+".smaps_rollup", rollup, 0o600); err != nil {
		return nil, err
	}
	values, err := parseProcMemory(string(rollup), rollupFields)
	if err != nil {
		return nil, err
	}
	status, err := os.ReadFile(root + "status")
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(rawPath+".status", status, 0o600); err != nil {
		return nil, err
	}
	hwm, err := parseProcMemory(string(status), []string{"VmHWM"})
	if err != nil {
		return nil, err
	}
	environ, err := os.ReadFile(root + "environ")
	if err != nil {
		return nil, err
	}
	result := &LinuxMemory{RollupBytes: values, RSSHighWaterBytes: hwm["VmHWM"]}
	// Never retain the full environment: a managed Host may hold credentials.
	for _, entry := range strings.Split(string(environ), "\x00") {
		if value, ok := strings.CutPrefix(entry, "GLIBC_TUNABLES="); ok {
			result.RequestedGlibcTunables = value
		}
		if value, ok := strings.CutPrefix(entry, "LD_PRELOAD="); ok {
			result.RequestedPreload = value
		}
	}
	if result.RequestedPreload != "" {
		// This diagnostic accepts explicit absolute objects, not loader search
		// tokens: a failed preload must not masquerade as an instrumented run.
		maps, err := os.ReadFile(root + "maps")
		if err != nil {
			return nil, err
		}
		libraries := strings.FieldsFunc(result.RequestedPreload, func(r rune) bool { return r == ':' || r == ' ' })
		if len(libraries) == 0 {
			return nil, fmt.Errorf("requested preload contains no objects")
		}
		for _, library := range libraries {
			if !filepath.IsAbs(library) {
				return nil, fmt.Errorf("preload evidence requires an absolute object: %s", library)
			}
			canonical, err := filepath.EvalSymlinks(library)
			if err != nil {
				return nil, err
			}
			found := false
			for _, line := range strings.Split(string(maps), "\n") {
				fields := strings.Fields(line)
				if len(fields) == 6 && fields[5] == canonical {
					found = true
				}
			}
			if !found {
				return nil, fmt.Errorf("requested preload not mapped: %s", library)
			}
		}
		result.PreloadMapped = true
	}
	return result, nil
}
