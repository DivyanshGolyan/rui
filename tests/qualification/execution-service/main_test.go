package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"rui.local/qualification/measurement"
)

func TestSessionStopUnixValueUsesHostCanonicalStore(t *testing.T) {
	joined := "/var/folders/x/store"
	canonical := "/private/var/folders/x/store"
	host := &measurement.Host{Ready: map[string]string{"store": canonical, "socket": "/tmp/rui.sock"}}
	store, err := host.CanonicalStore()
	if err != nil {
		t.Fatal(err)
	}
	request := sessionStopUnixValue(store, "stop-during-work", "execution/stop")
	if request.Store != canonical {
		t.Fatalf("store = %q, want Host readiness %q", request.Store, canonical)
	}
	if request.Store == joined {
		t.Fatalf("Unix session-stop used the unresolved join %q", joined)
	}
	if request.Kind != "session_stop" || request.Key != "stop-during-work" || request.Session != "execution/stop" {
		t.Fatalf("unexpected request: %+v", request)
	}
}

func event(phase string, at int, extra ...string) map[string]any {
	m := map[string]any{"rui_test_phase": phase, "at_ns": fmt.Sprint(at), "process": "7", "run": "1000", "clock": "awake_ns", "turn": "1", "operation": "1", "attempt": "1"}
	for i := 0; i < len(extra); i += 2 {
		m[extra[i]] = extra[i+1]
	}
	return m
}
func encodeEvents(rows []map[string]any) []byte {
	var b bytes.Buffer
	for i, row := range rows {
		row["sequence"] = fmt.Sprint(i + 1)
		// Keep the same prefix as the existing Host trace contract.
		phase := row["rui_test_phase"]
		delete(row, "rui_test_phase")
		encoded, _ := json.Marshal(row)
		fmt.Fprintf(&b, "{\"rui_test_phase\":%q,%s\n", phase, encoded[1:])
		row["rui_test_phase"] = phase
	}
	return b.Bytes()
}
func completeRows() []map[string]any {
	return []map[string]any{
		event("lifecycle_boundary", 100, "start_ns", "10", "wait_ns", "0"),
		event("bash_deadline_established", 105, "operation", "2", "action", "9", "deadline_ns", "300"),
		event("preparation_started", 110), event("preparation_advance_started", 120),
		event("preparation_advance_completed", 150, "work_bytes", "20", "work_items", "3", "request_bytes", "10"), event("preparation_completed", 155),
		event("validation_started", 200), event("control_durable_acceptance", 250, "subject", "stop"), event("validation_completed", 280),
		event("settlement_lock_requested", 280), event("settlement_lock_acquired", 290), event("settlement_complete", 360),
		event("effect_stop_requested", 370, "control_key", "stop"),
		event("bash_deadline_serviced", 380, "operation", "2", "action", "9", "deadline_ns", "300"),
		event("lifecycle_boundary", 400, "start_ns", "100", "wait_ns", "0"),
	}
}
func TestCompleteMetricIntervals(t *testing.T) {
	es, err := parseTraces(encodeEvents(completeRows()))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(es, true)
	if m.Status != "passed" {
		t.Fatalf("%+v", m)
	}
	if *m.LargestUninterruptedNS != 300 || *m.MaxLifecycleServiceGapNS != 300 {
		t.Fatalf("sub-phase maximum was used: %+v", m)
	}
	if m.SettlementQueue[0].DurationNS != 10 || m.SettlementService[0].DurationNS != 70 || m.Settlement[0].DurationNS != 80 {
		t.Fatalf("wrong settlement attribution: %+v", m)
	}
	if m.StopToEffectNS[0] != 120 || m.DeadlineToServiceNS[0] != 80 {
		t.Fatalf("wrong owner intervals: %+v", m)
	}
}
func TestUntracedWorkAndIdleWait(t *testing.T) {
	rows := completeRows()
	rows[len(rows)-1]["at_ns"] = "900"
	rows[len(rows)-1]["wait_ns"] = "100"
	es, err := parseTraces(encodeEvents(rows))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(es, true)
	if m.Status != "passed" || *m.LargestUninterruptedNS != 700 || *m.MaxLifecycleServiceGapNS != 800 {
		t.Fatalf("untraced work disappeared: %+v", m)
	}
}
func TestMismatchedAttemptDoesNotPair(t *testing.T) {
	rows := completeRows()
	rows[4]["attempt"] = "2"
	es, e := parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "invalid" {
		t.Fatalf("cross-Attempt interval passed: %+v", m)
	}
}
func TestReplacementAttemptHasIndependentRequestBytes(t *testing.T) {
	rows := completeRows()
	rows = append(rows, event("preparation_started", 410, "attempt", "2"), event("preparation_advance_started", 420, "attempt", "2"), event("preparation_advance_completed", 430, "attempt", "2", "work_bytes", "10", "work_items", "1", "request_bytes", "5"), event("preparation_completed", 440, "attempt", "2"), event("lifecycle_boundary", 500, "start_ns", "400", "wait_ns", "0"))
	es, e := parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "passed" {
		t.Fatalf("legitimate retry byte reset rejected: %+v", m)
	}
}
func TestProvenanceAndTraceLossAreRejected(t *testing.T) {
	for _, field := range []string{"run", "process", "clock", "attempt"} {
		rows := completeRows()
		rows[4][field] = ""
		if _, e := parseTraces(encodeEvents(rows)); e == nil {
			t.Errorf("missing %s accepted", field)
		}
	}
	for _, field := range []string{"run", "process", "clock"} {
		rows := completeRows()
		rows[4][field] = "2222"
		if _, e := parseTraces(encodeEvents(rows)); e == nil {
			t.Errorf("mixed %s accepted", field)
		}
	}
	raw := encodeEvents(completeRows())
	lines := bytes.Split(raw, []byte{'\n'})
	lines = append(lines[:4], lines[5:]...)
	if _, e := parseTraces(bytes.Join(lines, []byte{'\n'})); e == nil {
		t.Error("missing trace record accepted")
	}
	if _, e := parseTraces(raw[:len(raw)-1]); e == nil {
		t.Error("truncated tail accepted")
	}
	rows := completeRows()
	rows[4]["trace_lost"] = true
	if _, e := parseTraces(encodeEvents(rows)); e == nil {
		t.Error("producer loss accepted")
	}
}
func TestMissingBoundaryOrDeadlineInvalidatesEvidence(t *testing.T) {
	rows := completeRows()
	rows[len(rows)-1]["start_ns"] = "200"
	es, e := parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "invalid" {
		t.Error("missing service boundary passed")
	}
	rows = completeRows()
	rows[13]["deadline_ns"] = "299"
	es, e = parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "invalid" {
		t.Error("mismatched deadline passed")
	}
}
func TestAllowanceViolationInvalidatesEvidence(t *testing.T) {
	rows := completeRows()
	rows[4]["work_bytes"] = "16385"
	es, e := parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "invalid" {
		t.Error("allowance violation passed")
	}
}
func TestSupersessionIsNotASecondSettlementEnd(t *testing.T) {
	rows := completeRows()
	rows = append(rows, event("model_settlement_superseded", 365))
	es, e := parseTraces(encodeEvents(rows))
	if e != nil {
		t.Fatal(e)
	}
	if m := deriveMetrics(es, true); m.Status != "passed" {
		t.Fatalf("semantic note confused with a second end: %+v", m)
	}
}
func TestInvalidEvidenceHasNonzeroProcessExit(t *testing.T) {
	if os.Getenv("RUI_METRIC_EXIT_CHILD") == "1" {
		os.Exit(exitCode(deriveMetrics(nil, true).Status))
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestInvalidEvidenceHasNonzeroProcessExit$")
	cmd.Env = append(os.Environ(), "RUI_METRIC_EXIT_CHILD=1")
	err := cmd.Run()
	exit, ok := err.(*exec.ExitError)
	if !ok || exit.ExitCode() != 1 {
		t.Fatalf("invalid evidence exit=%v", err)
	}
	for _, status := range []string{"invalid", "failed", "unavailable", "target_miss", "unknown"} {
		if exitCode(status) == 0 {
			t.Errorf("%s exits successfully", status)
		}
	}
	if exitCode("passed") != 0 {
		t.Fatal("passed failed")
	}
}
func TestInspectWorkInFlight(t *testing.T) {
	if inspectWorkInFlight(map[string]any{"work": map[string]any{"status": "in_flight"}}) != true {
		t.Fatal("in_flight not recognized")
	}
	if inspectWorkInFlight(map[string]any{"work": map[string]any{"status": "idle"}}) {
		t.Fatal("idle treated as live")
	}
}

func TestOwnerStillHeldUsesHandoffAndRelease(t *testing.T) {
	id := executionID{Run: "1", Process: "2", Clock: "awake_ns", Turn: "3", Operation: "4", Attempt: "1"}
	events := []traceEvent{
		{executionID: id, Phase: "transport_handoff_committed"},
	}
	if !ownerStillHeld(events, id) {
		t.Fatal("handoff should keep the owner live")
	}
	events = append(events, traceEvent{executionID: id, Phase: "cleanup_completed"})
	if ownerStillHeld(events, id) {
		t.Fatal("cleanup should release the owner")
	}
}

func TestCompletionOverlapWithoutDeadlineIsSchedulingOnly(t *testing.T) {
	id := executionID{Run: "1", Process: "2", Clock: "awake_ns", Turn: "3", Operation: "4", Attempt: "1"}
	events := []traceEvent{
		{executionID: id, Phase: "provider_completion_removed", At: 10, QueuedAfter: 1},
		{Phase: "control_durable_acceptance", Subject: "stop", At: 12},
		{Phase: "effect_stop_requested", ControlKey: "stop", At: 14},
		{executionID: id, Phase: "provider_completion_serviced", At: 20},
	}
	if _, e := proveOverlap(events, "completion", "stop", executionID{}, []executionID{id}, false); e != nil {
		t.Fatal(e)
	}
	if _, e := proveOverlap(events, "completion", "stop", executionID{}, []executionID{id}, true); e == nil {
		t.Fatal("missing deadline accepted")
	}
}

func TestOverlapCannotUseIdleStopOrUnrelatedCompletion(t *testing.T) {
	id := executionID{Run: "1", Process: "2", Clock: "awake_ns", Turn: "3", Operation: "4", Attempt: "1"}
	other := id
	other.Operation = "5"
	events := []traceEvent{
		{executionID: id, Phase: "preparation_started", At: 10},
		{executionID: id, Phase: "preparation_completed", At: 20},
		{Phase: "control_durable_acceptance", Subject: "stop", At: 30},
		{Phase: "effect_stop_requested", ControlKey: "stop", At: 35},
		{executionID: id, Phase: "provider_completion_removed", At: 11, QueuedAfter: 2},
		{executionID: id, Phase: "provider_completion_serviced", At: 20},
		{executionID: other, Phase: "provider_completion_serviced", At: 100},
	}
	if _, e := proveOverlap(events, "preparation", "stop", id, nil, false); e == nil {
		t.Fatal("post-preparation stop accepted")
	}
	if _, e := proveOverlap(events, "completion", "stop", executionID{}, []executionID{id}, false); e == nil {
		t.Fatal("unrelated completion extended pressure")
	}
	events[2].At = 15
	events[3].At = 17
	if _, e := proveOverlap(events, "preparation", "stop", id, nil, false); e != nil {
		t.Fatal(e)
	}
	if _, e := proveOverlap(events, "completion", "stop", executionID{}, []executionID{id}, true); e == nil {
		t.Fatal("missing deadline accepted")
	}
}
func TestProviderAuditRejectsCorruptionAndDuplicateRequests(t *testing.T) {
	for _, corrupt := range []bool{false, true} {
		ep, e := newEndpoint()
		if e != nil {
			t.Fatal(e)
		}
		input := wireRequest([][]byte{userItem("test")})
		response, _ := answerSSE("test", "ok", 10, 20)
		ep.add("test", &requestPlan{Expected: input, Response: response})
		body := input
		if corrupt {
			body = bytes.Replace(body, []byte("model-a"), []byte("wrong-model"), 1)
		}
		resp, e := http.Post(ep.URL(), "application/json", bytes.NewReader(body))
		if e != nil {
			ep.close()
			t.Fatal(e)
		}
		resp.Body.Close()
		audit := ep.audit()
		if corrupt && audit == nil {
			t.Error("corrupt request passed")
		}
		if !corrupt && audit != nil {
			t.Fatal(audit)
		}
		resp, e = http.Post(ep.URL(), "application/json", bytes.NewReader(input))
		if e != nil {
			ep.close()
			t.Fatal(e)
		}
		resp.Body.Close()
		if ep.audit() == nil {
			t.Error("duplicate request passed")
		}
		ep.close()
	}
}
func TestReplayExpectationRemovesOnlyTopLevelCreatedBy(t *testing.T) {
	response, replay := answerSSE("test", "ok", 16, 32)
	if !bytes.Contains(response, []byte(`"created_by"`)) {
		t.Fatal("fixture no longer exercises discarded content")
	}
	if bytes.Contains(replay[0], []byte(`"created_by"`)) || !bytes.Contains(replay[0], []byte(strings.Repeat("r", 16))) {
		t.Fatal("wrong replay expectation")
	}
}

func TestSummarizeMetricsReplacesIntervalPopulations(t *testing.T) {
	maximum := uint64(13)
	value := metrics{
		Status:                   "passed",
		MaxLifecycleServiceGapNS: &maximum,
		Preparation: []interval{
			{DurationNS: 3},
			{DurationNS: 7},
		},
		Service: []serviceInterval{{}, {}, {}},
	}
	summary := summarizeMetrics(value)
	preparation, ok := summary["preparation_advances"].(map[string]any)
	if !ok || preparation["count"] != 2 || preparation["total_ns"] != uint64(10) || preparation["maximum_ns"] != uint64(7) {
		t.Fatalf("wrong interval summary: %#v", summary)
	}
	if summary["service_interval_count"] != 3 || summary["max_lifecycle_service_gap_ns"] != &maximum {
		t.Fatalf("important metrics lost: %#v", summary)
	}
	encoded, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte("preparation_intervals")) || bytes.Contains(encoded, []byte("service_intervals")) {
		t.Fatalf("raw intervals leaked into summary: %s", encoded)
	}
}

func TestWriteEvidenceProducesReviewableSummaryAndLosslessRawArtifact(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "evidence.json")
	value := metrics{Status: "passed", Preparation: []interval{{DurationNS: 11}}}
	rows := []map[string]any{{"status": "passed", "parameters": scenario{Name: "small"}, "metrics": value}}
	report := map[string]any{
		"format": "test-format", "status": "passed", "cases": rows,
		"provenance": map[string]any{"revision": "abc"}, "source_sha256": map[string]string{"source": "def"},
		"limits": []string{"test limit"},
	}
	if err := writeEvidence(path, report, rows); err != nil {
		t.Fatal(err)
	}
	summaryBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var summary map[string]any
	if err = json.Unmarshal(summaryBytes, &summary); err != nil {
		t.Fatal(err)
	}
	if summary["status"] != "passed" {
		t.Fatalf("wrong summary: %#v", summary)
	}
	cases := summary["cases"].([]any)
	metricsSummary := cases[0].(map[string]any)["metrics"].(map[string]any)
	if _, exists := metricsSummary["preparation_intervals"]; exists {
		t.Fatal("summary contains raw intervals")
	}
	rawMetadata := summary["raw_artifact"].(map[string]any)
	compressedPath := filepath.Join(directory, rawMetadata["path"].(string))
	compressed, err := os.ReadFile(compressedPath)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err = reader.Close(); err != nil {
		t.Fatal(err)
	}
	expected, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	expected = append(expected, '\n')
	if !bytes.Equal(raw, expected) {
		t.Fatal("compressed artifact does not reproduce the full report")
	}
	rawHash := fmt.Sprintf("%x", sha256.Sum256(raw))
	compressedHash := fmt.Sprintf("%x", sha256.Sum256(compressed))
	if rawMetadata["uncompressed_sha256"] != rawHash || rawMetadata["compressed_sha256"] != compressedHash {
		t.Fatalf("artifact hashes do not verify: %#v", rawMetadata)
	}
}
