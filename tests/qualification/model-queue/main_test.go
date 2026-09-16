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
		behaviorFailure bool
		statuses        []string
		wantStatus      string
		wantExit        bool
	}{
		{false, []string{"passed"}, "passed", false},
		{false, []string{"passed", "target_miss"}, "target_miss", false},
		{false, []string{"target_miss", "unavailable"}, "unavailable", false},
		{true, []string{"unavailable", "target_miss"}, "behavior_error", true},
	}
	for _, test := range tests {
		gotStatus, gotExit := classifyOutcome(test.behaviorFailure, test.statuses...)
		if gotStatus != test.wantStatus || gotExit != test.wantExit {
			t.Errorf("classifyOutcome(%v, %v) = (%q, %v), want (%q, %v)", test.behaviorFailure, test.statuses, gotStatus, gotExit, test.wantStatus, test.wantExit)
		}
	}
}
