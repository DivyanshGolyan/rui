//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
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
