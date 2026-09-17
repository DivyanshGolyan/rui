package main

import (
	"errors"
	"reflect"
	"testing"

	"rui.local/qualification/measurement"
)

func TestDiscoveryStatusInclusiveBoundary(t *testing.T) {
	tests := []struct {
		milliseconds int64
		available    bool
		want         string
	}{{2000, true, "passed"}, {2001, true, "target_miss"}, {0, false, "unavailable"}}
	for _, test := range tests {
		if got := discoveryStatus(test.milliseconds, test.available); got != test.want {
			t.Errorf("discoveryStatus(%d, %v) = %q, want %q", test.milliseconds, test.available, got, test.want)
		}
	}
}

func TestOverallStatusPrecedence(t *testing.T) {
	tests := []struct {
		statuses   []string
		wantStatus string
	}{
		{[]string{"passed"}, "passed"},
		{[]string{"passed", "target_miss"}, "target_miss"},
		{[]string{"target_miss", "unavailable"}, "unavailable"},
		{[]string{"unavailable", "behavior_error"}, "behavior_error"},
	}
	for _, test := range tests {
		if got := overallStatus(test.statuses...); got != test.wantStatus {
			t.Errorf("overallStatus(%v) = %q, want %q", test.statuses, got, test.wantStatus)
		}
	}
}

func TestCaseStatusDistinguishesBehaviorAndMeasurementOutcomes(t *testing.T) {
	tests := []struct {
		behaviorFailure      bool
		measurementAvailable bool
		milliseconds         int64
		want                 string
	}{
		{true, false, 0, "behavior_error"},
		{false, false, 0, "unavailable"},
		{false, true, 2000, "passed"},
		{false, true, 2001, "target_miss"},
	}
	for _, test := range tests {
		if got := caseStatus(test.behaviorFailure, test.measurementAvailable, test.milliseconds); got != test.want {
			t.Errorf("caseStatus(%v, %v, %d) = %q, want %q", test.behaviorFailure, test.measurementAvailable, test.milliseconds, got, test.want)
		}
	}
}

func TestSettledOrderRequiresEveryExpectedResolution(t *testing.T) {
	want := expectedOrder(2)
	valid := []settlementFact{
		{CommandKey: "e-msg-1", MessageSession: want[0], TurnID: 1, TurnSession: want[0], OperationID: 1, TurnOutcome: "provider_http_422", OperationSession: want[0], OperationResolution: "provider_http_422"},
		{CommandKey: "e-msg-2", MessageSession: want[1], TurnID: 2, TurnSession: want[1], OperationID: 2, TurnOutcome: "provider_http_422", OperationSession: want[1], OperationResolution: "provider_http_422"},
	}
	if actual, err := auditSettlementFacts(valid, want); err != nil || !reflect.DeepEqual(actual, want) {
		t.Fatalf("auditSettlementFacts(valid) = %v, %v; want %v", actual, err, want)
	}
	tests := []struct {
		name   string
		mutate func([]settlementFact)
	}{
		{"wrong turn outcome", func(facts []settlementFact) { facts[0].TurnOutcome = "cancelled" }},
		{"unresolved earlier turn", func(facts []settlementFact) { facts[0].TurnOutcome = "" }},
		{"wrong message binding", func(facts []settlementFact) { facts[0].TurnSession = want[1] }},
	}
	for _, test := range tests {
		facts := append([]settlementFact(nil), valid...)
		test.mutate(facts)
		if _, err := auditSettlementFacts(facts, want); err == nil {
			t.Errorf("%s passed settlement audit", test.name)
		}
	}
}

func TestPhysicalFootprintStatusUsesConservativeUpperBound(t *testing.T) {
	tests := []struct {
		footprint  measurement.Footprint
		wantStatus string
		wantUpper  uint64
	}{
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes}, "passed", physicalFootprintTargetBytes},
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes - 1, LifetimePeakTolerance: 1}, "passed", physicalFootprintTargetBytes},
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes, LifetimePeakTolerance: 1}, "target_miss", physicalFootprintTargetBytes + 1},
	}
	for _, test := range tests {
		status, upper := physicalFootprintStatus(test.footprint)
		if status != test.wantStatus || upper != test.wantUpper {
			t.Errorf("physicalFootprintStatus(%+v) = %q, %d; want %q, %d", test.footprint, status, upper, test.wantStatus, test.wantUpper)
		}
	}
}

func TestBehaviorFailureRetainsOrderEvidence(t *testing.T) {
	result := map[string]any{"status": "passed"}
	actual := []string{"queue/eligible/000002", "queue/eligible/000001"}
	expected := []string{"queue/eligible/000001", "queue/eligible/000002"}
	recordAdmissionOrder(result, actual, expected, nil)
	if result["status"] != "behavior_error" || result["behavior_failure"] == nil {
		t.Fatalf("wrong-order result = %v", result)
	}
	if !reflect.DeepEqual(result["operation_admission_order"], actual) || !reflect.DeepEqual(result["expected_oldest_first_admission_order"], expected) {
		t.Fatalf("order evidence was not retained: %v", result)
	}
}

func TestTerminalObservationFailuresRemainSerializable(t *testing.T) {
	result := map[string]any{"status": "passed", "discovery_ms": int64(7)}
	recordTerminalObservation(result, nil, errors.New("terminal observation timed out"))
	if result["status"] != "behavior_error" || result["behavior_failure"] == nil || result["discovery_ms"] != int64(7) {
		t.Fatalf("terminal failure result = %v", result)
	}
	wrong := map[string]any{"result": map[string]any{"status": "failed", "code": "cancelled"}}
	result = map[string]any{"status": "passed"}
	recordTerminalObservation(result, wrong, nil)
	if result["status"] != "behavior_error" {
		t.Fatalf("wrong terminal observation passed: %v", result)
	}
}
