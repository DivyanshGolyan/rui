package measurement

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/shirou/gopsutil/v4/process"
)

func TestProcMemoryRequiresExactCountersAndUnits(t *testing.T) {
	const report = "VmPeak: 999 kB\nRss: 11 kB\nPss: 7 kB\nSwap: 0 kB\n"
	required := []string{"Rss", "Pss", "Swap"}
	values, err := parseProcMemory(report, required)
	if err != nil || values["Rss"] != 11264 || values["Pss"] != 7168 || values["Swap"] != 0 {
		t.Fatalf("parsed memory = %v, %v", values, err)
	}
	for _, mutated := range []string{
		strings.ReplaceAll(report, "Swap: 0 kB\n", ""),
		strings.ReplaceAll(report, "11 kB", "11 MB"),
		strings.ReplaceAll(report, "11 kB", "-1 kB"),
		strings.ReplaceAll(report, "11 kB", "18014398509481984 kB"),
		strings.ReplaceAll(report, "11 kB", "1.5 kB"),
		report + "Pss: 8 kB\n",
	} {
		if _, err := parseProcMemory(mutated, required); err == nil {
			t.Fatalf("accepted %q", mutated)
		}
	}
}

func TestLinuxSampleDoesNotSerializeUnavailableMacFootprint(t *testing.T) {
	sample := ProcessSample{RSSBytes: 11264, LinuxMemory: &LinuxMemory{RollupBytes: map[string]uint64{"Rss": 11264, "Pss": 7168}}}
	data, err := json.Marshal(sample)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	if _, present := fields["footprint"]; present {
		t.Fatalf("unavailable footprint serialized: %s", data)
	}
	if _, present := fields["open_descriptor_rows"]; present {
		t.Fatalf("unavailable lsof rows serialized: %s", data)
	}
	if fields["linux_memory"] == nil {
		t.Fatalf("Linux counters missing: %s", data)
	}
	if verdict := ClassifyFootprint(sample.Footprint, 25_000_000); verdict.Status != "unavailable" {
		t.Fatalf("missing footprint passed: %+v", verdict)
	}
}

func TestNativeLinuxProcessSnapshot(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux /proc integration")
	}
	target, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "sample")
	sample, err := SampleProcess(target, path)
	if err != nil {
		t.Fatal(err)
	}
	if sample.LinuxMemory == nil || sample.LinuxMemory.RollupBytes["Rss"] == 0 || sample.OpenDescriptors == 0 {
		t.Fatalf("incomplete native snapshot: %+v", sample)
	}
	for _, suffix := range []string{".smaps_rollup", ".status"} {
		if _, err := os.Stat(path + suffix); err != nil {
			t.Fatal(fmt.Errorf("raw evidence: %w", err))
		}
	}
}
