package main

import (
	"strings"
	"testing"
)

func TestParseAndDeriveCompleteTrace(t *testing.T) {
	input := strings.Join([]string{
		`{"rui_test_phase":"control_timing","control_key":"stop","store_queued_at_ns":"120","queue_wait_ns":"20"}`,
		`{"rui_test_phase":"preparation_advance_started","at_ns":"110","operation":"1"}`,
		`{"rui_test_phase":"preparation_advance_completed","at_ns":"130","operation":"1"}`,
		`{"rui_test_phase":"effect_stop_requested","at_ns":"140","control_key":"stop","operation":"1"}`,
		`{"rui_test_phase":"validation_started","at_ns":"150","operation":"1"}`,
		`{"rui_test_phase":"validation_completed","at_ns":"180","operation":"1"}`,
		`{"rui_test_phase":"settlement_lock_requested","at_ns":"190","operation":"1"}`,
		`{"rui_test_phase":"settlement_complete","at_ns":"230","operation":"1"}`,
		`{"rui_test_phase":"bash_deadline_serviced","at_ns":"250","deadline_ns":"200","action":"9"}`,
	}, "\n")
	events, err := parseTraces([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(events)
	if m.Status != "passed" || len(m.StopToEffectNS) != 1 || m.StopToEffectNS[0] != 40 || len(m.DeadlineToServiceNS) != 1 || m.DeadlineToServiceNS[0] != 50 {
		t.Fatalf("metrics = %+v", m)
	}
	if m.MaxLifecycleServiceGapNS == nil || *m.MaxLifecycleServiceGapNS != 110 || m.LargestUninterruptedNS == nil || *m.LargestUninterruptedNS != 40 {
		t.Fatalf("interval metrics = %+v", m)
	}
}

func TestMissingEventsInvalidateAffectedMetrics(t *testing.T) {
	events, err := parseTraces([]byte(`{"rui_test_phase":"preparation_advance_started","at_ns":"10","operation":"1"}`))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(events)
	if m.Status != "invalid" || len(m.Invalid) < 3 || m.MaxLifecycleServiceGapNS != nil || m.LargestUninterruptedNS != nil {
		t.Fatalf("missing trace passed: %+v", m)
	}
}

func TestMalformedRelevantTraceRejected(t *testing.T) {
	for _, input := range []string{`{"rui_test_phase":"validation_started","at_ns":"bad"}`, `{"rui_test_phase":"control_timing","control_key":"x","store_queued_at_ns":"1","queue_wait_ns":"2"}`} {
		if _, err := parseTraces([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}

func TestFixtureFieldsVaryIndependently(t *testing.T) {
	a := encodeSSE(8, 1)
	b := encodeSSE(80, 1)
	c := encodeSSE(8, 100)
	if len(a) == len(b) || len(a) == len(c) || !strings.Contains(string(b), strings.Repeat("r", 80)) || !strings.Contains(string(c), strings.Repeat("d", 100)) {
		t.Fatal("fixture fields did not vary independently")
	}
}

func TestFinalOperationEventsExcludeHistory(t *testing.T) {
	events := []traceEvent{{Operation: "1"}, {Operation: "3"}, {Operation: "2"}, {Phase: "control_timing"}}
	selected := finalOperationEvents(events, 1)
	if len(selected) != 2 || selected[0].Operation != "3" || selected[1].Phase != "control_timing" {
		t.Fatalf("selected events = %+v", selected)
	}
}
