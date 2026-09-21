package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"rui.local/qualification/measurement"
)

type scenario struct {
	Name         string `json:"name"`
	Capacity     int    `json:"active_capacity"`
	HistoryBytes int    `json:"history_bytes"`
	HistoryTurns int    `json:"history_turns"`
}

func intervalSummary(values []interval) map[string]any {
	var total, maximum uint64
	for _, value := range values {
		total += value.DurationNS
		maximum = max(maximum, value.DurationNS)
	}
	return map[string]any{"count": len(values), "total_ns": total, "maximum_ns": maximum}
}

func summarizeMetrics(value metrics) map[string]any {
	return map[string]any{
		"status": value.Status, "max_lifecycle_service_gap_ns": value.MaxLifecycleServiceGapNS,
		"largest_active_service_interval_ns": value.LargestUninterruptedNS,
		"preparation_advances":               intervalSummary(value.Preparation),
		"preparation_lifetimes":              intervalSummary(value.PreparationLifetime),
		"validation":                         intervalSummary(value.Validation),
		"settlement":                         intervalSummary(value.Settlement),
		"service_interval_count":             len(value.Service),
		"invalid_metrics":                    value.Invalid,
	}
}

func summarizeRows(rows []map[string]any) []map[string]any {
	summary := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		selected := map[string]any{}
		for _, key := range []string{"parameters", "status", "error", "resources", "trace_sha256", "trace_events"} {
			if value, ok := row[key]; ok {
				selected[key] = value
			}
		}
		if value, ok := row["metrics"].(metrics); ok {
			selected["metrics"] = summarizeMetrics(value)
		}
		summary = append(summary, selected)
	}
	return summary
}

func writeEvidence(path string, report map[string]any, rows []map[string]any) error {
	raw, err := json.Marshal(report)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	var compressed bytes.Buffer
	zipper, err := gzip.NewWriterLevel(&compressed, gzip.BestCompression)
	if err != nil {
		return err
	}
	if _, err = zipper.Write(raw); err != nil {
		return err
	}
	if err = zipper.Close(); err != nil {
		return err
	}
	rawPath := strings.TrimSuffix(path, filepath.Ext(path)) + ".raw.json.gz"
	if err = os.MkdirAll(filepath.Dir(rawPath), 0o700); err != nil {
		return err
	}
	temporary := rawPath + ".tmp"
	if err = os.WriteFile(temporary, compressed.Bytes(), 0o600); err != nil {
		return err
	}
	defer os.Remove(temporary)
	if err = os.Rename(temporary, rawPath); err != nil {
		return err
	}
	rawHash := sha256.Sum256(raw)
	compressedHash := sha256.Sum256(compressed.Bytes())
	summary := map[string]any{
		"format": report["format"], "status": report["status"], "cases": summarizeRows(rows),
		"provenance": report["provenance"], "source_sha256": report["source_sha256"], "limits": report["limits"],
		"raw_artifact": map[string]any{
			"path": filepath.Base(rawPath), "compression": "gzip", "uncompressed_bytes": len(raw),
			"uncompressed_sha256": hex.EncodeToString(rawHash[:]), "compressed_bytes": compressed.Len(),
			"compressed_sha256": hex.EncodeToString(compressedHash[:]),
		},
	}
	if value, ok := report["provenance_error"]; ok {
		summary["provenance_error"] = value
	}
	encoded, err := json.MarshalIndent(summary, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(encoded, '\n'), 0o600)
}

func expectAnswer(c measurement.Client, key, answer string) error {
	v, e := c.WaitResult(key)
	if e != nil {
		return e
	}
	state, ok := measurement.StringField(v, "result", "status")
	if !ok || state != "completed" {
		return fmt.Errorf("%s did not complete: %v", key, v)
	}
	actual, e := measurement.Run(c.Deadline, c.Binary, "read-result", "--store", c.Store, "--key", key)
	if e != nil {
		return e
	}
	if !bytes.Equal(actual, []byte(answer)) {
		return fmt.Errorf("wrong answer bytes for %s", key)
	}
	return nil
}

func awaitDrain(c measurement.Client, session string) error {
	return measurement.WaitFor(c.Deadline, time.Millisecond, "custody and scratch release", func() (bool, error) {
		v, e := c.Inspect(session)
		if e != nil {
			return false, e
		}
		occupied, a := measurement.IntStringField(v, "execution", "custody_occupied")
		scratch, b := measurement.IntStringField(v, "execution", "scratch_used_bytes")
		if !a || !b {
			return false, errors.New("missing resource observation")
		}
		return occupied == 0 && scratch == 0, nil
	})
}

func runScenario(binary, root string, s scenario) (row map[string]any, err error) {
	d := measurement.NewDeadline(180 * time.Second)
	dir := filepath.Join(root, s.Name)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	ep, err := newEndpoint()
	if err != nil {
		return nil, err
	}
	defer ep.close()
	store := filepath.Join(dir, "store")
	tracePath := filepath.Join(dir, "host-stderr.log")
	host, err := measurement.StartHost(
		binary, store, ep.URL(), s.Capacity, tracePath, d,
		"--test-phase-trace",
	)
	if err != nil {
		return nil, err
	}
	stopped := false
	defer func() {
		if !stopped {
			err = errors.Join(err, host.Stop(measurement.TeardownAllowance))
		}
	}()
	c := measurement.Client{Binary: binary, Artifacts: dir, Store: store, Deadline: d}
	row = map[string]any{"parameters": s, "trace_path": tracePath, "status": "failed"}

	targetInputs := [][]byte{}
	if err = c.Configure("target-config", "execution/target", "--tools", "none"); err != nil {
		return row, err
	}
	for i := 0; i < s.HistoryTurns; i++ {
		text := fmt.Sprintf("history-%d:", i) + strings.Repeat("h", s.HistoryBytes/max(1, s.HistoryTurns))
		targetInputs = append(targetInputs, userItem(text))
		response, replay := answerSSE(fmt.Sprintf("history-%d", i), "history-ok", 64, 64)
		ep.add(text, &requestPlan{Expected: wireRequest(targetInputs), Response: response})
		key := fmt.Sprintf("history-%d", i)
		if err = c.Message(key, "execution/target", text); err != nil {
			return row, err
		}
		if err = expectAnswer(c, key, "history-ok"); err != nil {
			return row, err
		}
		targetInputs = append(targetInputs, replay...)
	}
	work := "work-0"
	input := append(append([][]byte{}, targetInputs...), userItem(work))
	payload, _ := answerSSE(work, "answer-"+work, 64, 64)
	ep.add(work, &requestPlan{Expected: wireRequest(input), Response: payload})
	if err = c.Message(work, "execution/target", work); err != nil {
		return row, err
	}
	if err = expectAnswer(c, work, "answer-"+work); err != nil {
		return row, err
	}
	if err = awaitDrain(c, "execution/target"); err != nil {
		return row, err
	}
	if err = ep.audit(); err != nil {
		return row, err
	}
	err = host.Stop(measurement.TeardownAllowance)
	stopped = true
	if err != nil {
		return row, err
	}
	data, e := os.ReadFile(tracePath)
	if e != nil {
		return row, e
	}
	events, err := parseTraces(data)
	if err != nil {
		return row, err
	}
	m := deriveMetrics(events)
	sum := sha256.Sum256(data)
	slotBytes, e1 := strconv.Atoi(host.Ready["execution_slot_bytes"])
	prepBytes, e2 := strconv.Atoi(host.Ready["model_preparation_bytes"])
	if e1 != nil || e2 != nil {
		return row, errors.Join(e1, e2)
	}
	row["status"] = m.Status
	row["metrics"] = m
	row["trace_sha256"] = hex.EncodeToString(sum[:])
	row["trace_events"] = len(events)
	row["resources"] = map[string]any{
		"custody_and_scratch_drained": true,
		"execution_slot_bytes":        slotBytes,
		"shared_preparation_bytes":    prepBytes,
		"whole_process_memory":        "not measured by this runner",
	}
	return row, nil
}

func main() {
	output := flag.String("output", "execution-service-results.json", "evidence output")
	selected := flag.String("case", "", "one named case")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: execution-service [flags] RUI_BINARY")
		os.Exit(2)
	}
	binary, err := filepath.Abs(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	root, err := os.MkdirTemp("", "rui-execution-service-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	scenarios := []scenario{
		{"history-1k", 2, 1024, 1},
		{"history-items", 2, 1024, 8},
	}
	rows := []map[string]any{}
	status := "passed"
	for _, s := range scenarios {
		if *selected != "" && *selected != s.Name {
			continue
		}
		row, e := runScenario(binary, root, s)
		if row == nil {
			row = map[string]any{"parameters": s}
		}
		if e != nil {
			row["status"] = "failed"
			row["error"] = e.Error()
		}
		if row["status"] != "passed" {
			status = "failed"
		}
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, "unknown case:", *selected)
		os.Exit(2)
	}
	provenance, pErr := measurement.EnvironmentEvidence(measurement.NewDeadline(20*time.Second), binary, *output)
	sourceHashes := map[string]string{}
	sourceRoot, sourceErr := measurement.RepositoryRoot()
	if sourceErr == nil {
		for _, name := range []string{
			"src/server.zig", "src/execution_turn.zig", "src/provider.zig", "src/cli.zig",
			"tests/qualification/execution-service/main.go", "tests/qualification/execution-service/metrics.go",
			"tests/qualification/execution-service/fixture.go",
		} {
			hash, hashErr := measurement.SHA256File(filepath.Join(sourceRoot, name))
			if hashErr != nil {
				sourceErr = errors.Join(sourceErr, hashErr)
			} else {
				sourceHashes[name] = hash
			}
		}
	}
	pErr = errors.Join(pErr, sourceErr)
	if pErr != nil && status == "passed" {
		status = "invalid"
	}
	report := map[string]any{
		"format": "rui-execution-service-v4-go", "status": status, "artifacts": root, "cases": rows,
		"provenance": provenance, "source_sha256": sourceHashes,
		"limits": []string{
			"ungated empirical service gaps only; turn ordering is proved by zig build test-logic",
			"exact request bytes remain fixture-audited, not a schedule-independence matrix",
			"source/native validation and platform/resource qualification still require their owning gates",
			"loopback is not live-provider, TLS, power-loss, or whole-product qualification",
			"structural sizes are not whole-process footprint",
		},
	}
	if pErr != nil {
		report["provenance_error"] = pErr.Error()
	}
	if err = writeEvidence(*output, report, rows); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if status != "passed" {
		os.Exit(1)
	}
}
