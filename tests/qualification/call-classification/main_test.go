package main

import (
	"bytes"
	"encoding/json"
	"math"
	"os"
	"os/exec"
	"testing"
	"time"

	"rui.local/qualification/measurement"
)

func TestScenarioCallsVaryClassificationAndPayloadIndependently(t *testing.T) {
	value := scenario{Name: "asymmetric", Valid: 2, Rejected: 3, ArgumentBytes: 37}
	calls := scenarioCalls(value, "/must/not/run")
	if len(calls) != 5 {
		t.Fatalf("got %d calls", len(calls))
	}
	for index := 0; index < 2; index++ {
		if calls[index].Name != "bash" {
			t.Fatalf("valid call %d classified by fixture as %q", index, calls[index].Name)
		}
		var descriptor struct {
			Cmd string `json:"cmd"`
		}
		if err := json.Unmarshal([]byte(calls[index].Arguments), &descriptor); err != nil {
			t.Fatal(err)
		}
		if !bytes.HasPrefix([]byte(descriptor.Cmd), []byte("touch \"/must/not/run\"")) {
			t.Fatalf("valid call does not create the forbidden-effect sentinel if launched: %q", descriptor.Cmd)
		}
		if !bytes.Contains([]byte(descriptor.Cmd), bytes.Repeat([]byte("x"), 37)) {
			t.Fatalf("valid descriptor omitted independent payload: %q", descriptor.Cmd)
		}
	}
	if calls[2].Name != "unknown" || calls[3].Name != "bash" || calls[3].Arguments != "{" || calls[4].Name != "unknown" {
		t.Fatalf("rejected population does not alternate unknown/malformed: %+v", calls[2:])
	}
}

func TestLatencySummaryUsesNearestRank(t *testing.T) {
	actual := latencySummary([]float64{100, 1, 2, 3, 4})
	if actual["minimum_ms"] != float64(1) || actual["p50_ms"] != float64(3) ||
		actual["p95_ms"] != float64(100) || actual["maximum_ms"] != float64(100) {
		t.Fatalf("unexpected summary: %v", actual)
	}
	if empty := latencySummary(nil); empty["count"] != 0 || len(empty) != 1 {
		t.Fatalf("unexpected empty summary: %v", empty)
	}
}

func TestObservedCountsRejectsMalformedReport(t *testing.T) {
	_, _, err := observedCounts(map[string]any{
		"actions":        map[string]any{"count": 1},
		"rejected_calls": map[string]any{"count": "0"},
	})
	if err == nil {
		t.Fatal("numeric action count must not be silently accepted")
	}
}

func TestCombineStatusPreservesVerdictPrecedence(t *testing.T) {
	if got := combineStatus("unavailable", "target_miss"); got != "target_miss" {
		t.Fatalf("target miss hidden by unavailable: %q", got)
	}
	if got := combineStatus("behavior_error", "passed"); got != "behavior_error" {
		t.Fatalf("behavior failure overwritten: %q", got)
	}
}

func TestAggregatePhysicalVerdictUsesCheckedLifetimePeakBounds(t *testing.T) {
	target := uint64(24 * 1024 * 1024)
	complete := func(peak, tolerance uint64) map[string]measurement.Footprint {
		result := map[string]measurement.Footprint{}
		for _, family := range requiredCLIFamilies {
			result[family] = measurement.Footprint{LifetimePeakBytes: peak, LifetimePeakTolerance: tolerance}
		}
		return result
	}
	tests := []struct {
		name         string
		host         *measurement.FootprintVerdict
		families     map[string]measurement.Footprint
		observed     uint64
		maximumCLIs  uint64
		helperCensus bool
		hostComplete bool
		want         string
		wantUpper    uint64
	}{
		{"pass at 24 MiB", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete(4<<20, 0), 23 << 20, 1, true, true, "passed", target},
		{"target miss", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete(4<<20, 0), target + 1, 1, true, true, "target_miss", target},
		{"target straddle from rounding", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete((4<<20)+1, 1), 23 << 20, 1, true, true, "unavailable", target + 2},
		{"missing command family", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, map[string]measurement.Footprint{"inspection": {LifetimePeakBytes: 4 << 20}}, 23 << 20, 1, true, true, "unavailable", math.MaxUint64},
		{"missing family preserves established miss", &measurement.FootprintVerdict{LowerBoundBytes: target + 1, UpperBoundBytes: target + 1}, map[string]measurement.Footprint{"inspection": {LifetimePeakBytes: 4 << 20}}, 23 << 20, 1, true, true, "target_miss", math.MaxUint64},
		{"missing Host scenario", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete(4<<20, 0), 23 << 20, 1, true, false, "unavailable", math.MaxUint64},
		{"maximum CLI population not one", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete(4<<20, 0), 23 << 20, 2, true, true, "unavailable", math.MaxUint64},
		{"helper omission", &measurement.FootprintVerdict{LowerBoundBytes: 20 << 20, UpperBoundBytes: 20 << 20}, complete(4<<20, 0), 23 << 20, 1, false, true, "unavailable", math.MaxUint64},
		{"checked addition overflow", &measurement.FootprintVerdict{LowerBoundBytes: math.MaxUint64 - 2, UpperBoundBytes: math.MaxUint64 - 1}, complete(2, 0), math.MaxUint64 - 2, 1, true, true, "target_miss", math.MaxUint64},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			verdict, reason := classifyAggregateFootprint(test.host, test.families, test.observed, test.maximumCLIs, test.helperCensus, test.hostComplete, target)
			if verdict.Status != test.want || reason == "" {
				t.Fatalf("verdict=%+v reason=%q", verdict, reason)
			}
			if verdict.UpperBoundBytes != test.wantUpper {
				t.Fatalf("upper bound=%d want %d: %+v", verdict.UpperBoundBytes, test.wantUpper, verdict)
			}
		})
	}
}

func TestCompletedAndReleasedRequiresOutcomeBeforeEmptyCustody(t *testing.T) {
	transientlyEmpty := map[string]any{
		"work":      map[string]any{"status": "runnable", "latest_outcome": nil},
		"execution": map[string]any{"custody_occupied": "0", "scratch_used_bytes": "0"},
	}
	if ready, err := completedAndReleased(transientlyEmpty); err != nil || ready {
		t.Fatalf("transient empty custody qualified completion: ready=%v error=%v", ready, err)
	}
	completed := map[string]any{
		"work": map[string]any{"status": "completed", "latest_outcome": map[string]any{"code": "completed"}},
		"execution": map[string]any{
			"custody_occupied": "0", "scratch_used_bytes": "0",
		},
	}
	if ready, err := completedAndReleased(completed); err != nil || !ready {
		t.Fatalf("completed drained work did not qualify: ready=%v error=%v", ready, err)
	}
	completed["execution"].(map[string]any)["scratch_used_bytes"] = "1"
	if ready, err := completedAndReleased(completed); err != nil || ready {
		t.Fatalf("live scratch qualified retained idle: ready=%v error=%v", ready, err)
	}
}

func TestCLIMeasurementPopulationRejectsOverlapAndReleases(t *testing.T) {
	var population cliMeasurementPopulation
	if err := population.begin(); err != nil {
		t.Fatal(err)
	}
	if err := population.begin(); err == nil {
		t.Fatal("overlapping ordinary CLI measurement was accepted")
	}
	population.end()
	if err := population.begin(); err != nil {
		t.Fatalf("released CLI measurement did not permit reuse: %v", err)
	}
	population.end()
	if population.maximum != 1 || population.live != 0 {
		t.Fatalf("population=%+v", population)
	}
}

func TestWaitCommandKillsChildThatIgnoresInterrupt(t *testing.T) {
	command := exec.Command("sh", "-c", "trap '' INT; exec sleep 30")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	if err := command.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := waitCommand(command, 50*time.Millisecond); err == nil {
		t.Fatal("timed-out child cleanup reported success")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("child cleanup exceeded bound: %v", elapsed)
	}
}

func TestKillCommandTreatsIntentionalTerminationAsCleanup(t *testing.T) {
	command := exec.Command("sleep", "30")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	if err := killCommand(command); err != nil {
		t.Fatalf("intentional child termination = %v", err)
	}
}

func TestAggregateFootprintRequiresHostAndCLIInEverySample(t *testing.T) {
	complete := footprintSamples{Samples: []footprintSample{{
		Processes:      []footprintProcess{{PID: 10, Footprint: 70}, {PID: 20, Footprint: 40}},
		TotalFootprint: 100,
	}}}
	got, err := summarizeAggregateFootprint(complete, 10, 20)
	if err != nil || got.HostComponentPeakBytes != 70 || got.CLIComponentPeakBytes != 40 || got.CLIIncrementPeakBytes != 30 || got.ObservedAggregatePeakBytes != 100 {
		t.Fatalf("summary=%+v error=%v", got, err)
	}
	omitted := footprintSamples{Samples: []footprintSample{{
		Processes:      []footprintProcess{{PID: 10, Footprint: 70}},
		TotalFootprint: 70,
	}}}
	if _, err := summarizeAggregateFootprint(omitted, 10, 20); err == nil {
		t.Fatal("Host-only sample did not report omitted CLI")
	}
}
