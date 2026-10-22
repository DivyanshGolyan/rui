//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"

	"time"

	"rui.local/qualification/measurement"
	"rui.local/qualification/model-output/provider"
)

// A `rui` under a Host shell is a client, never Bash, and so is a `rui
// session send` that replaced the Host's shell; a Host child that execed
// another command is Bash. Every process lands in exactly one column, so the
// columns sum to the total.
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
	// The direct send is a `cat` copy named rui; it blocks opening the FIFO
	// named `session`, so its argv is `./rui session send`.
	direct := filepath.Join(directory, "direct")
	cat, err := exec.LookPath("cat")
	if err != nil {
		t.Skip("cat unavailable")
	}
	if data, err = os.ReadFile(cat); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(direct, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(direct, "rui"), data, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(direct, "session"), 0o600); err != nil {
		t.Fatal(err)
	}
	host := exec.Command("bash", "-c", "bash -c '"+sleep+" 30 & "+send+" 30 & wait' & "+sleep+" 30 & (cd "+direct+" && exec ./rui session send) & wait")
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
		if sample.Counts["send"] == 2 && sample.Counts["bash_child"] == 1 && sample.Counts["bash_exec"] == 1 {
			break
		}
	}
	want := map[string]int{"host": 1, "bash_shell": 1, "bash_child": 1, "bash_exec": 1, "send": 2, "bash": 3, "clients": 2, "total": 6}
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

// A Session passes only with its seed and original request completed and the
// exact saved answer; a failed final result after valid tool outputs fails.
func TestToolOriginalFailureRequiresCompletedExactAnswer(t *testing.T) {
	inspection := func(key string, outcome string) map[string]any {
		return map[string]any{"recent_messages": []any{map[string]any{"message": key, "outcome": outcome}, map[string]any{"message": "seed-002", "outcome": "completed"}}}
	}
	completed := map[string]any{"result": map[string]any{"status": "completed"}}
	failed := map[string]any{"result": map[string]any{"status": "failed"}}
	answer := []byte("tool turn complete " + provider.ToolSession(10, 2))
	for _, test := range []struct {
		name        string
		key         string
		inspection  map[string]any
		observation map[string]any
		text        []byte
		ok          bool
	}{
		{"completed exact", "dispatch-002", inspection("dispatch-002", "completed"), completed, answer, true},
		{"failed final result", "dispatch-002", inspection("dispatch-002", "failed"), failed, nil, false},
		{"completed Message but failed request", "dispatch-002", inspection("dispatch-002", "completed"), failed, answer, false},
		{"wrong answer", "dispatch-002", inspection("dispatch-002", "completed"), completed, []byte("tool turn complete " + provider.ToolSession(10, 3)), false},
		{"not the dispatch key", "other", inspection("other", "completed"), completed, answer, false},
		{"extra Message", "dispatch-002", map[string]any{"recent_messages": append(inspection("dispatch-002", "completed")["recent_messages"].([]any), map[string]any{"message": "x", "outcome": "completed"})}, completed, answer, false},
	} {
		if err := toolOriginalFailure(10, 2, test.key, test.inspection, test.observation, test.text, nil); (err == nil) != test.ok {
			t.Errorf("%s: %v", test.name, err)
		}
	}
	coordinator := map[string]any{"recent_messages": []any{map[string]any{"message": "tui-key", "outcome": "completed"}, map[string]any{"message": "seed-000", "outcome": "completed"}}}
	if key := toolCoordinatorKey(coordinator); key != "tui-key" || toolOriginalFailure(10, 0, key, coordinator, completed, []byte("tool turn complete "+provider.ToolSession(10, 0)), nil) != nil {
		t.Fatalf("coordinator key %q", key)
	}
}

// Validated counts, request phases and, in barrier mode, release facts for a
// complete park and N overlapping intervals are each required.
func TestToolAcceptanceFailsClosed(t *testing.T) {
	done := provider.ToolSummary{Done: 3, WorkloadCalls: 3, DispatchCalls: 2, SucceededCalls: 5}
	requests := map[string]int{"seed_in_window": 0, "measured_in_window": 3, "continuation_in_window": 3}
	release := map[string]any{"parked_at_release": 3, "timed_out": false}
	if failures := toolAcceptance(3, done, requests, true, release, 3); len(failures) != 0 {
		t.Fatalf("complete run rejected: %v", failures)
	}
	if failures := toolAcceptance(3, done, requests, false, nil, 1); len(failures) != 0 {
		t.Fatalf("natural run needs no overlap: %v", failures)
	}
	short := done
	short.SucceededCalls = 4
	for name, failures := range map[string][]string{
		"barrier without release": toolAcceptance(3, done, requests, true, nil, 1),
		"release without barrier": toolAcceptance(3, done, requests, false, release, 3),
		"partial barrier":         toolAcceptance(3, done, requests, true, map[string]any{"parked_at_release": 2, "timed_out": true}, 3),
		"overlap below N":         toolAcceptance(3, done, requests, true, release, 2),
		"one call invalid":        toolAcceptance(3, short, requests, false, nil, 3),
		"provider error":          toolAcceptance(3, provider.ToolSummary{Done: 3, WorkloadCalls: 3, DispatchCalls: 2, SucceededCalls: 5, Errors: []string{"x"}}, requests, false, nil, 3),
		"request off window":      toolAcceptance(3, done, map[string]int{"measured_in_window": 3, "continuation_in_window": 2}, false, nil, 3),
	} {
		if len(failures) == 0 {
			t.Errorf("%s accepted", name)
		}
	}
}

// A controller that times out with shells missing records a partial release.
func TestReleaseBarrierRecordsPartialPark(t *testing.T) {
	directory := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(directory, "release"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "parked-000"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := os.OpenFile(filepath.Join(directory, "release"), os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	facts, writer, err := releaseBarrier(measurement.NewDeadline(10*time.Second), directory, 2, 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	writer.Close()
	if facts["parked_at_release"] != 1 || facts["timed_out"] != true || len(toolAcceptance(2, provider.ToolSummary{Done: 2, WorkloadCalls: 2, DispatchCalls: 1, SucceededCalls: 3}, map[string]int{"measured_in_window": 2, "continuation_in_window": 2}, true, facts, 2)) == 0 {
		t.Fatalf("facts = %v", facts)
	}
}
