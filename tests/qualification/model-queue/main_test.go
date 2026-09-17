package main

import (
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
	got, err := settledOrder("queue/eligible/000001|provider_http_422\nqueue/eligible/000002|provider_http_422")
	want := []string{"queue/eligible/000001", "queue/eligible/000002"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("settledOrder() = %v, %v; want %v", got, err, want)
	}
	if _, err := settledOrder("queue/eligible/000001|temporary"); err == nil {
		t.Fatal("settledOrder accepted a nonterminal expected resolution")
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
	recordOrder(result, actual, expected, nil)
	if result["status"] != "behavior_error" || result["behavior_failure"] == nil {
		t.Fatalf("wrong-order result = %v", result)
	}
	if !reflect.DeepEqual(result["operation_launch_order"], actual) || !reflect.DeepEqual(result["expected_oldest_first_order"], expected) {
		t.Fatalf("order evidence was not retained: %v", result)
	}
}
