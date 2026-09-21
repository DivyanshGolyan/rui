package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
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

func completeV4Rows() []map[string]any {
	return []map[string]any{
		event("lifecycle_boundary", 100, "start_ns", "10", "wait_ns", "0"),
		event("preparation_started", 110), event("preparation_advance_started", 120),
		event("preparation_advance_completed", 150, "work_bytes", "20", "work_items", "3", "request_bytes", "10"),
		event("preparation_completed", 155),
		event("validation_started", 200), event("validation_completed", 280),
		event("settlement_lock_requested", 280), event("settlement_complete", 360),
		event("lifecycle_boundary", 400, "start_ns", "100", "wait_ns", "0"),
	}
}

func TestParseRejectsIncompleteMeasurementIdentity(t *testing.T) {
	phases := []string{
		"preparation_started", "preparation_completed",
		"preparation_advance_started", "preparation_advance_completed", "preparation_advance_failed",
		"validation_started", "validation_completed", "validation_failed",
		"settlement_lock_requested", "settlement_complete",
	}
	mutatePhase := func(rows []map[string]any, phase string, mutate func(map[string]any)) {
		for _, row := range rows {
			if row["rui_test_phase"] == phase {
				mutate(row)
				return
			}
		}
		// Exercise *_failed endpoints by retargeting their completed counterpart.
		completed := phase
		switch phase {
		case "preparation_advance_failed":
			completed = "preparation_advance_completed"
		case "validation_failed":
			completed = "validation_completed"
		}
		for _, row := range rows {
			if row["rui_test_phase"] == completed {
				row["rui_test_phase"] = phase
				mutate(row)
				return
			}
		}
		t.Fatalf("phase %s not found in fixture", phase)
	}
	for _, phase := range phases {
		for _, field := range []string{"turn", "operation", "attempt"} {
			t.Run(phase+"/"+field, func(t *testing.T) {
				rows := completeV4Rows()
				mutatePhase(rows, phase, func(row map[string]any) { delete(row, field) })
				if _, err := parseTraces(encodeEvents(rows)); err == nil {
					t.Fatalf("%s with missing %s accepted", phase, field)
				}
			})
		}
		t.Run(phase+"/at_ns", func(t *testing.T) {
			rows := completeV4Rows()
			mutatePhase(rows, phase, func(row map[string]any) { delete(row, "at_ns") })
			if _, err := parseTraces(encodeEvents(rows)); err == nil {
				t.Fatalf("%s with missing at_ns accepted", phase)
			}
		})
	}
	t.Run("lifecycle_boundary/at_ns", func(t *testing.T) {
		rows := completeV4Rows()
		delete(rows[0], "at_ns")
		if _, err := parseTraces(encodeEvents(rows)); err == nil {
			t.Fatal("lifecycle_boundary with missing at_ns accepted")
		}
	})
}

func TestDeriveRejectsMissingPreparationEvidence(t *testing.T) {
	rows := completeV4Rows()
	kept := rows[:0]
	for _, row := range rows {
		phase := row["rui_test_phase"].(string)
		if phase == "preparation_started" || phase == "preparation_completed" ||
			phase == "preparation_advance_started" || phase == "preparation_advance_completed" ||
			phase == "preparation_advance_failed" {
			continue
		}
		kept = append(kept, row)
	}
	rows = kept
	es, err := parseTraces(encodeEvents(rows))
	if err != nil {
		t.Fatal(err)
	}
	m := deriveMetrics(es)
	if m.Status != "invalid" {
		t.Fatalf("run without preparation work passed: %+v", m)
	}
	found := false
	for _, reason := range m.Invalid {
		if reason == "preparation_work_evidence" {
			found = true
		}
	}
	if !found {
		t.Fatalf("missing preparation evidence marker: %+v", m.Invalid)
	}

	boundaries := []map[string]any{
		event("lifecycle_boundary", 100, "start_ns", "10", "wait_ns", "0"),
		event("lifecycle_boundary", 400, "start_ns", "100", "wait_ns", "0"),
	}
	es, err = parseTraces(encodeEvents(boundaries))
	if err != nil {
		t.Fatal(err)
	}
	if m = deriveMetrics(es); m.Status != "invalid" {
		t.Fatalf("boundaries-only run passed: %+v", m)
	}
}

func TestWriteEvidenceProducesReviewableSummaryAndLosslessRawArtifact(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.json")
	maximum := uint64(300)
	value := metrics{
		Status:                   "passed",
		MaxLifecycleServiceGapNS: &maximum,
		Preparation:              []interval{{Kind: "preparation_advance_started", DurationNS: 30}},
		PreparationLifetime:      []interval{{Kind: "preparation_started", DurationNS: 45}},
		Service:                  []serviceInterval{{StartNS: 10, EndNS: 100}},
	}
	rows := []map[string]any{{"status": "passed", "parameters": scenario{Name: "small"}, "metrics": value}}
	report := map[string]any{
		"format": "rui-execution-service-v4-go", "status": "passed", "cases": rows,
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
	cases, ok := summary["cases"].([]any)
	if !ok || len(cases) != 1 {
		t.Fatalf("wrong summary cases: %#v", summary)
	}
	metricsSummary, ok := cases[0].(map[string]any)["metrics"].(map[string]any)
	if !ok {
		t.Fatalf("missing metrics summary: %#v", cases[0])
	}
	if _, exists := metricsSummary["preparation_intervals"]; exists {
		t.Fatal("summary contains raw intervals")
	}
	preparation, ok := metricsSummary["preparation_advances"].(map[string]any)
	if !ok || preparation["count"] != float64(1) {
		t.Fatalf("wrong preparation summary: %#v", metricsSummary)
	}
	rawMetadata, ok := summary["raw_artifact"].(map[string]any)
	if !ok {
		t.Fatalf("missing raw artifact metadata: %#v", summary)
	}
	compressed, err := os.ReadFile(filepath.Join(dir, rawMetadata["path"].(string)))
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

func osRead(path string) ([]byte, error) {
	return os.ReadFile(path)
}
