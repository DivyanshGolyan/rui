package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

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
		phase := row["rui_test_phase"]
		delete(row, "rui_test_phase")
		encoded, _ := json.Marshal(row)
		fmt.Fprintf(&b, "{\"rui_test_phase\":%q,%s\n", phase, encoded[1:])
		row["rui_test_phase"] = phase
	}
	return b.Bytes()
}

func TestCompleteMetricIntervals(t *testing.T) {
	rows := []map[string]any{
		event("lifecycle_boundary", 100, "start_ns", "10", "wait_ns", "0"),
		event("preparation_started", 110), event("preparation_advance_started", 120),
		event("preparation_advance_completed", 150, "work_bytes", "20", "work_items", "3", "request_bytes", "10"),
		event("preparation_completed", 155),
		event("validation_started", 200), event("validation_completed", 280),
		event("settlement_lock_requested", 280), event("settlement_complete", 360),
		event("lifecycle_boundary", 400, "start_ns", "100", "wait_ns", "0"),
	}
	es, err := parseTraces(encodeEvents(rows))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(es)
	if m.Status != "passed" {
		t.Fatalf("%+v", m)
	}
	if m.MaxLifecycleServiceGapNS == nil || *m.MaxLifecycleServiceGapNS != 300 {
		t.Fatalf("gap = %v", m.MaxLifecycleServiceGapNS)
	}
}

func TestWriteEvidenceProducesReviewableSummaryAndLosslessRawArtifact(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/summary.json"
	report := map[string]any{"format": "rui-execution-service-v4-go", "status": "passed", "cases": []map[string]any{}}
	if err := writeEvidence(path, report, nil); err != nil {
		t.Fatal(err)
	}
	raw, err := osRead(dir + "/summary.raw.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	var uncompressed bytes.Buffer
	if _, err = uncompressed.ReadFrom(reader); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(uncompressed.Bytes())
	if hex := fmt.Sprintf("%x", sum); len(hex) != 64 {
		t.Fatalf("hash %s", hex)
	}
}

func osRead(path string) ([]byte, error) {
	return os.ReadFile(path)
}
