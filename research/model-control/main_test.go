package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func timingRecord(key, kind, queued, locked, complete, reply, queueWait, lockWait, service, postReply, total string) map[string]any {
	return map[string]any{
		"command_key":          key,
		"kind":                 kind,
		"store_queued_at_ns":   queued,
		"lock_acquired_at_ns":  locked,
		"store_complete_at_ns": complete,
		"reply_complete_at_ns": reply,
		"queue_wait_ns":        queueWait,
		"store_lock_wait_ns":   lockWait,
		"store_service_ns":     service,
		"post_commit_reply_ns": postReply,
		"host_total_ns":        total,
	}
}

func TestControlTimingEvidenceProvesSettlementOverlap(t *testing.T) {
	expected := []expectedControlTiming{
		{key: "settlement-later-interrupt", kind: "model_interruption"},
		{key: "settlement-later-stop-1", kind: "session_stop"},
	}
	records := []map[string]any{
		timingRecord("settlement-later-interrupt", "model_interruption", "150", "250", "260", "265", "10", "100", "10", "5", "125"),
		timingRecord("settlement-later-stop-1", "session_stop", "210", "220", "230", "235", "10", "10", "10", "5", "35"),
	}
	timings, err := parseControlTimings(records, expected)
	if err != nil {
		t.Fatal(err)
	}
	overlapped, err := settlementOverlap(100, 200, timings)
	if err != nil {
		t.Fatal(err)
	}
	if !overlapped {
		t.Fatal("valid queue-before-completion and lock-after-completion evidence did not overlap")
	}
}

func TestControlTimingEvidenceRejectsMissingWrongMalformedAndDuplicateRecords(t *testing.T) {
	expected := []expectedControlTiming{
		{key: "settlement-later-interrupt", kind: "model_interruption"},
		{key: "settlement-later-stop-1", kind: "session_stop"},
	}
	validInterrupt := timingRecord("settlement-later-interrupt", "model_interruption", "150", "250", "260", "265", "10", "100", "10", "5", "125")
	validStop := timingRecord("settlement-later-stop-1", "session_stop", "210", "220", "230", "235", "10", "10", "10", "5", "35")
	tests := []struct {
		name    string
		records []map[string]any
		want    string
	}{
		{name: "missing", records: []map[string]any{validInterrupt}, want: "missing control timing"},
		{name: "wrong key", records: []map[string]any{validInterrupt, timingRecord("other-stop", "session_stop", "210", "220", "230", "235", "10", "10", "10", "5", "35")}, want: "missing control timing"},
		{name: "malformed", records: []map[string]any{validInterrupt, timingRecord("settlement-later-stop-1", "session_stop", "not-a-number", "220", "230", "235", "10", "10", "10", "5", "35")}, want: "malformed"},
		{name: "duplicate", records: []map[string]any{validInterrupt, validStop, validStop}, want: "duplicate control timing"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseControlTimings(test.records, expected)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestSettlementQualificationRequiresObservedOverlap(t *testing.T) {
	timings, err := parseControlTimings(
		[]map[string]any{timingRecord("stop", "session_stop", "210", "220", "230", "235", "10", "10", "10", "5", "35")},
		[]expectedControlTiming{{key: "stop", kind: "session_stop"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	overlapped, err := settlementOverlap(100, 200, timings)
	if err != nil {
		t.Fatal(err)
	}
	if overlapped {
		t.Fatal("nonoverlapping timing qualified")
	}
	if got := settlementQualificationStatus(overlapped, 1000, 10, 20); got != "incomplete" {
		t.Fatalf("nonoverlap status = %s", got)
	}
	if got := controlStatus(map[string]any{"status": "passed"}, map[string]any{"status": "incomplete"}); got != "incomplete" {
		t.Fatalf("top-level nonoverlap status = %s", got)
	}
}

func TestSettlementOverlapValidatesEveryControlLowerBound(t *testing.T) {
	timings, err := parseControlTimings(
		[]map[string]any{
			timingRecord("overlap", "session_stop", "150", "250", "260", "265", "10", "100", "10", "5", "125"),
			timingRecord("too-early", "session_stop", "90", "110", "120", "125", "10", "20", "10", "5", "45"),
		},
		[]expectedControlTiming{{key: "overlap", kind: "session_stop"}, {key: "too-early", kind: "session_stop"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := settlementOverlap(100, 200, timings); err == nil {
		t.Fatal("later control queued before settlement lock was skipped after earlier overlap")
	}
}

func TestAcceptedIdleStopRequiresExplicitNullSelectionTurn(t *testing.T) {
	valid := map[string]any{"answer": map[string]any{"status": "accepted", "selection": map[string]any{"turn": nil}}}
	if err := requireAcceptedIdleStop(valid); err != nil {
		t.Fatal(err)
	}
	for _, reply := range []map[string]any{
		{"answer": map[string]any{"status": "accepted"}},
		{"answer": map[string]any{"status": "accepted", "selection": map[string]any{}}},
		{"answer": map[string]any{"status": "accepted", "selection": map[string]any{"turn": "turn-1"}}},
	} {
		if err := requireAcceptedIdleStop(reply); err == nil {
			t.Fatalf("invalid idle stop qualified: %v", reply)
		}
	}
}

func TestOperationPhaseTimestampRequiresOneExactRecord(t *testing.T) {
	record := map[string]any{"latifa_test_phase": "settlement_complete", "operation": "operation-1", "at_ns": "200"}
	value, err := operationPhaseTimestamp([]map[string]any{record}, "settlement_complete", "operation-1")
	if err != nil {
		t.Fatal(err)
	}
	if value != 200 {
		t.Fatalf("timestamp = %d", value)
	}
	for _, test := range []struct {
		name    string
		records []map[string]any
		want    string
	}{
		{name: "missing", records: nil, want: "missing"},
		{name: "wrong operation", records: []map[string]any{{"operation": "operation-2", "at_ns": "200"}}, want: "unexpected operation"},
		{name: "malformed", records: []map[string]any{{"operation": "operation-1", "at_ns": "bad"}}, want: "malformed"},
		{name: "duplicate", records: []map[string]any{record, record}, want: "duplicate"},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := operationPhaseTimestamp(test.records, "settlement_complete", "operation-1")
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestOrderedRawRequestBodies(t *testing.T) {
	inspection, err := json.Marshal(inspectRequest{Version: "1", Kind: "inspect_session", Store: "store", Session: "session"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(inspection), `{"version":"1","kind":"inspect_session","store":"store","session":"session"}`; got != want {
		t.Fatalf("inspection = %s, want %s", got, want)
	}
	result, err := json.Marshal(readResultRequest{Version: "1", Kind: "read_result", Store: "store", Key: "key"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(result), `{"version":"1","kind":"read_result","store":"store","key":"key"}`; got != want {
		t.Fatalf("read result = %s, want %s", got, want)
	}
}

func TestLatencyStatusBoundaryAndTopLevelReduction(t *testing.T) {
	if got := latencyStatus(1000, 1000); got != "passed" {
		t.Fatalf("limit boundary reduced to %s", got)
	}
	if got := latencyStatus(1000, 1000.001); got != "target_miss" {
		t.Fatalf("above-limit latency reduced to %s", got)
	}
	if got := controlStatus(map[string]any{"status": "passed"}, map[string]any{"status": "target_miss"}); got != "target_miss" {
		t.Fatalf("top-level control status reduced to %s", got)
	}
}
