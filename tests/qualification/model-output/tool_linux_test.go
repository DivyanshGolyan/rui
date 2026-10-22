//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"

	"rui.local/qualification/model-output/provider"
	"time"
)

// A `rui` under a Host shell is a client, never Bash; every process lands in
// exactly one column, so the columns sum to the total.
func TestToolSamplerCountsSendOnceAsClient(t *testing.T) {
	directory := t.TempDir()
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("sleep unavailable")
	}
	data, err := os.ReadFile(sleep)
	if err != nil {
		t.Fatal(err)
	}
	send := filepath.Join(directory, "rui")
	if err := os.WriteFile(send, data, 0o700); err != nil {
		t.Fatal(err)
	}
	host := exec.Command("bash", "-c", "bash -c '"+sleep+" 30 & "+send+" 30 & wait' & wait")
	host.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := host.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { syscall.Kill(-host.Process.Pid, syscall.SIGKILL); host.Wait() }()
	sampler := &toolSampler{host: host.Process.Pid, phase: "test", records: map[string]*toolProcessRecord{}}
	if sampler.raw, err = os.Create(filepath.Join(directory, "samples.jsonl")); err != nil {
		t.Fatal(err)
	}
	var sample toolSample
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		sampler.sample()
		sample = sampler.samples[len(sampler.samples)-1]
		if sample.Counts["send"] == 1 && sample.Counts["bash_child"] == 1 {
			break
		}
	}
	want := map[string]int{"host": 1, "bash_shell": 1, "bash_child": 1, "send": 1, "bash": 2, "clients": 1, "total": 4}
	for name, count := range want {
		if sample.Counts[name] != count {
			t.Fatalf("counts = %v, want %v", sample.Counts, want)
		}
	}
	if sample.PSSFailures == 0 && sample.PSS["host"]+sample.PSS["bash"]+sample.PSS["clients"] != sample.PSS["total"] {
		t.Fatalf("columns do not sum to total: %v", sample.PSS)
	}
}

// Only requests the provider received inside the CPU window count toward
// its denominator; seeds before it and a late continuation do not.
func TestToolRequestPhasesUseReceivedTimes(t *testing.T) {
	facts := []provider.ToolSessionFact{
		{SeedReceivedNS: 5, MeasuredReceivedNS: 20, ContinuationReceivedNS: 30},
		{SeedReceivedNS: 6, MeasuredReceivedNS: 21, ContinuationReceivedNS: 41},
		{SeedReceivedNS: 7},
	}
	got := toolRequestPhases(facts, 10, 40)
	want := map[string]int{"seed_total": 3, "seed_in_window": 0, "measured_total": 2, "measured_in_window": 2, "continuation_total": 2, "continuation_in_window": 1}
	if len(got) != len(want) {
		t.Fatalf("phases = %v, want %v", got, want)
	}
	for name, value := range want {
		if got[name] != value {
			t.Fatalf("phases = %v, want %v", got, want)
		}
	}
}
