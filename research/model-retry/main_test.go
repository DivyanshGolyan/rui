package main

import "testing"

func TestRetryQualificationBoundaries(t *testing.T) {
	if discoveryStatus(2000) != "passed" || discoveryStatus(2001) != "target_miss" {
		t.Fatal("discovery boundary is not inclusive at 2000 ms")
	}
	if idleStatus(0.999) != "passed" || idleStatus(1.0) != "target_miss" {
		t.Fatal("idle boundary is not strict below one percent")
	}
	timing := map[string]any{"status": discoveryStatus(100), "launch_after_discovery_ms": int64(3000)}
	if retryStatus(timing) != "passed" {
		t.Fatal("diagnostic launch delay incorrectly failed discovery qualification")
	}
	if retryStatus(timing, map[string]any{"status": "target_miss"}) != "target_miss" {
		t.Fatal("scenario target miss did not reach the top-level result")
	}
}
