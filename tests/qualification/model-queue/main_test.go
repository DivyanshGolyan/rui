package main

import "testing"

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
