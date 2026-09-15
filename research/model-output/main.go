package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"latifa.local/research/measurement"
)

const memoryTarget = 256 * 1024 * 1024

var answerSizes = []int{1024, 1024 * 1024, 8 * 1024 * 1024}
var reasoningCounts = []int{1, 128, 1000}

func encodeSSE(responseID string, reasoningCount int, answer string) []byte {
	items := make([]any, 0, reasoningCount+1)
	events := make([]any, 0, reasoningCount*2+3)
	for index := range reasoningCount {
		item := map[string]any{"type": "reasoning", "id": fmt.Sprintf("%s-reasoning-%d", responseID, index), "summary": []any{}, "encrypted_content": fmt.Sprintf("private-%d", index), "extension": map[string]int{"ordinal": index}}
		items = append(items, item)
		events = append(events,
			map[string]any{"type": "response.output_item.added", "output_index": index, "item": map[string]any{"type": "reasoning", "id": item["id"]}},
			map[string]any{"type": "response.output_item.done", "output_index": index, "item": item})
	}
	message := map[string]any{"type": "message", "id": responseID + "-message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}}}
	items = append(items, message)
	events = append(events,
		map[string]any{"type": "response.output_item.added", "output_index": reasoningCount, "item": map[string]any{"type": "message", "id": message["id"]}},
		map[string]any{"type": "response.output_item.done", "output_index": reasoningCount, "item": message},
		map[string]any{"type": "response.completed", "response": map[string]any{"id": responseID, "status": "completed", "model": "model-a-served", "output": items, "usage": map[string]int{"input_tokens": 7, "output_tokens": 11, "total_tokens": 18}}})
	var output bytes.Buffer
	for _, event := range events {
		encoded, _ := json.Marshal(event)
		output.WriteString("data: ")
		output.Write(encoded)
		output.WriteString("\n\n")
	}
	output.WriteString("data: [DONE]\n\n")
	return output.Bytes()
}

type payloadEndpoint struct {
	server   *http.Server
	listener net.Listener
	mu       sync.Mutex
	payload  []byte
	requests []int
}

func startPayloadEndpoint() (*payloadEndpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	value := &payloadEndpoint{listener: listener}
	value.server = &http.Server{Handler: http.HandlerFunc(value.serve)}
	go value.server.Serve(listener)
	return value, nil
}

func (e *payloadEndpoint) serve(writer http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return
	}
	e.mu.Lock()
	payload := e.payload
	e.payload = nil
	e.requests = append(e.requests, len(body))
	e.mu.Unlock()
	if payload == nil {
		http.Error(writer, "missing payload", 500)
		return
	}
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("OpenAI-Model", "model-a-served")
	writer.Header().Set("X-Request-Id", fmt.Sprintf("measurement-%d", len(e.requests)))
	writer.Header().Set("Connection", "close")
	writer.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	_, _ = writer.Write(payload)
}

func (e *payloadEndpoint) URL() string        { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *payloadEndpoint) set(payload []byte) { e.mu.Lock(); e.payload = payload; e.mu.Unlock() }
func (e *payloadEndpoint) lastRequestBytes() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.requests[len(e.requests)-1]
}
func (e *payloadEndpoint) Close() error { return e.server.Close() }

func wholeLatifa(sample measurement.ProcessSample) map[string]any {
	if sample.LiveDescendantProcesses != 0 {
		return map[string]any{"status": "incomplete", "reason": "live descendants require aggregation", "descendant_processes": sample.LiveDescendantProcesses}
	}
	upper := sample.Footprint.LifetimePeakBytes + sample.Footprint.LifetimePeakTolerance
	return map[string]any{
		"status": "complete", "aggregate_equals_host": true, "host_processes": 1, "descendant_processes": 0,
		"rss_bytes": sample.RSSBytes, "physical_footprint_bytes": sample.Footprint.PhysicalBytes,
		"lifetime_peak_physical_footprint_bytes":             sample.Footprint.LifetimePeakBytes,
		"lifetime_peak_physical_footprint_upper_bound_bytes": upper,
		"within_256_mib_target":                              upper <= memoryTarget,
		"qualification_basis":                                "conservative upper bound of cumulative lifetime physical-footprint peak",
	}
}

func memoryStatus(aggregates ...map[string]any) string {
	for _, aggregate := range aggregates {
		if aggregate["status"] != "complete" {
			return "incomplete"
		}
	}
	for _, aggregate := range aggregates {
		if aggregate["within_256_mib_target"] != true {
			return "target_miss"
		}
	}
	return "passed"
}

func reduceStatuses(rowFamilies ...[]map[string]any) string {
	precedence := map[string]int{"passed": 0, "target_miss": 1, "incomplete": 2, "failed": 3}
	status := "passed"
	for _, rows := range rowFamilies {
		for _, row := range rows {
			candidate, ok := row["status"].(string)
			if !ok {
				candidate = "failed"
			}
			candidateRank, known := precedence[candidate]
			if !known {
				candidate, candidateRank = "failed", precedence["failed"]
			}
			if candidateRank > precedence[status] {
				status = candidate
			}
		}
	}
	return status
}

func readResult(deadline measurement.Deadline, binary, store, key, destination string) (map[string]any, error) {
	remaining, err := deadline.Remaining()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), remaining)
	defer cancel()
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "/usr/bin/time", "-l", binary, "read-result", "--store", store, "--key", key)
	cmd.Stdout, cmd.Stderr = file, &stderr
	deliveryStarted := time.Now()
	runError := cmd.Run()
	closeError := file.Close()
	if err := errors.Join(runError, closeError); err != nil {
		return nil, fmt.Errorf("result delivery failed: %w; stderr=%s", err, stderr.String())
	}
	digest, err := measurement.SHA256File(destination)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(destination)
	if err != nil {
		return nil, err
	}
	return map[string]any{"delivery_and_verification_seconds": time.Since(deliveryStarted).Seconds(), "destination_bytes": info.Size(), "destination_sha256": digest, "time_stderr": stderr.String()}, nil
}

type outputAudit struct {
	PublicPayloadBytes   int64 `json:"public_payload_bytes"`
	ProjectionRows       int64 `json:"projection_rows"`
	DatabaseBytes        int64 `json:"database_bytes"`
	CanonicalOutputItems int   `json:"canonical_output_items"`
	PrivateContentRows   int   `json:"private_content_rows"`
	AssistantProjections int   `json:"assistant_projections"`
}

func readOutputAudit(deadline measurement.Deadline, store string) (outputAudit, error) {
	query := "SELECT (SELECT count(*) FROM model_output_item) AS canonical_output_items," +
		"(SELECT count(*) FROM content WHERE private=1) AS private_content_rows," +
		"(SELECT count(*) FROM conversation_entry WHERE entry_kind=3) AS assistant_projections," +
		"(SELECT coalesce(sum(length(payload)),0) FROM content WHERE private=0) AS public_payload_bytes," +
		"(SELECT count(*) FROM answer_text_projection) AS projection_rows;"
	encoded, err := measurement.Run(deadline, "/usr/bin/sqlite3", "-json", filepath.Join(store, "latifa.sqlite3"), query)
	if err != nil {
		return outputAudit{}, err
	}
	var rows []outputAudit
	if err := json.Unmarshal(encoded, &rows); err != nil || len(rows) != 1 {
		return outputAudit{}, fmt.Errorf("decode output audit: rows=%d: %w", len(rows), err)
	}
	info, err := os.Stat(filepath.Join(store, "latifa.sqlite3"))
	if err != nil {
		return outputAudit{}, err
	}
	rows[0].DatabaseBytes = info.Size()
	return rows[0], nil
}

func outputAuditValid(audit outputAudit, reasoning int) bool {
	return audit.CanonicalOutputItems == reasoning+1 && audit.PrivateContentRows == reasoning+2 && audit.AssistantProjections == 1
}

func outputCaseStatus(memory string, auditValid bool) string {
	if !auditValid {
		return "failed"
	}
	return memory
}

func measureCase(binary, root string, endpoint *payloadEndpoint, name string, reasoning int, answer string) (result map[string]any, resultError error) {
	directory := filepath.Join(root, name)
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	store := filepath.Join(directory, "store")
	payload := encodeSSE(name, reasoning, answer)
	endpoint.set(payload)
	deadline := measurement.NewDeadline(3 * time.Minute)
	host, err := measurement.StartHost(binary, store, endpoint.URL(), 1, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	cold, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-cold.txt"))
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	importStarted := time.Now()
	if err := client.Submit(name, "measure/"+name, "measure"); err != nil {
		return nil, err
	}
	observation, err := client.WaitResult(name)
	if err != nil {
		return nil, err
	}
	importSeconds := time.Since(importStarted).Seconds()
	delivery, err := readResult(deadline, binary, store, name, filepath.Join(directory, "answer.bin"))
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256([]byte(answer))
	expectedDigest := hex.EncodeToString(digest[:])
	if delivery["destination_bytes"] != int64(len(answer)) || delivery["destination_sha256"] != expectedDigest {
		return nil, errors.New("saved result differs from response")
	}
	var inspection map[string]any
	err = measurement.WaitFor(deadline, 25*time.Millisecond, "post-result resource cleanup", func() (bool, error) {
		var err error
		inspection, err = client.Inspect("measure/" + name)
		if err != nil {
			return false, err
		}
		scratch, scratchOK := measurement.IntStringField(inspection, "execution", "scratch_used_bytes")
		custody, custodyOK := measurement.IntStringField(inspection, "execution", "custody_occupied")
		if !scratchOK || !custodyOK {
			return false, fmt.Errorf("missing resource observation: %v", inspection)
		}
		return scratch == 0 && custody == 0, nil
	})
	if err != nil {
		return nil, err
	}
	retained, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-retained.txt"))
	if err != nil {
		return nil, err
	}
	audit, err := readOutputAudit(deadline, store)
	if err != nil {
		return nil, err
	}
	coldWhole := wholeLatifa(cold)
	retainedWhole := wholeLatifa(retained)
	status := outputCaseStatus(memoryStatus(coldWhole, retainedWhole), outputAuditValid(audit, reasoning))
	return map[string]any{
		"completion_seconds": importSeconds, "status": status, "answer_bytes": len(answer), "reasoning_items": reasoning, "total_output_items": reasoning + 1,
		"sse_bytes": len(payload), "request_bytes": endpoint.lastRequestBytes(), "scratch_limit_bytes": host.Ready["scratch_limit_bytes"],
		"offline_audit": audit, "cold": map[string]any{"host": cold, "whole_latifa": coldWhole},
		"retained_idle": map[string]any{"host": retained, "whole_latifa": retainedWhole}, "client_delivery": delivery,
		"execution_after_completion": inspection["execution"], "observation": observation, "answer_sha256": expectedDigest,
	}, nil
}

func main() {
	projection := flag.Bool("projection", false, "measure 1/4/8 KiB and 100 KB plain and escaped answer projections")
	output := flag.String("output", "", "write the final JSON to this path")
	flag.Parse()
	if *projection {
		answerSizes = []int{1024, 4096, 8192, 100000}
		reasoningCounts = nil
	}
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-output [--output path] /absolute/path/to/latifa")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, err := filepath.Abs(flag.Arg(0))
	if err != nil {
		panic(err)
	}
	root, err := os.MkdirTemp("/private/tmp", "latifa-output-measure-")
	if err != nil {
		panic(err)
	}
	facts, err := measurement.NewFactLog(filepath.Join(root, "facts.jsonl"))
	if err != nil {
		panic(err)
	}
	factsOpen := true
	defer func() {
		if factsOpen {
			_ = facts.Close()
		}
	}()
	started := time.Now()
	endpoint, err := startPayloadEndpoint()
	if err != nil {
		panic(err)
	}
	defer endpoint.Close()
	byteRows := make([]map[string]any, 0, len(answerSizes))
	for _, size := range answerSizes {
		row, err := measureCase(binary, root, endpoint, fmt.Sprintf("bytes-%d", size), 1, strings.Repeat("x", size))
		if err != nil {
			panic(err)
		}
		byteRows = append(byteRows, row)
		if *projection {
			escaped, err := measureCase(binary, root, endpoint, fmt.Sprintf("escaped-%d", size), 1, strings.Repeat("\n", size))
			if err != nil {
				panic(err)
			}
			escaped["escaped"] = true
			byteRows = append(byteRows, escaped)
		}
		if err := facts.Write("answer_growth", row); err != nil {
			panic(err)
		}
	}
	itemRows := make([]map[string]any, 0, len(reasoningCounts))
	for _, count := range reasoningCounts {
		row, err := measureCase(binary, root, endpoint, fmt.Sprintf("items-%d", count), count, "answer")
		if err != nil {
			panic(err)
		}
		itemRows = append(itemRows, row)
		if err := facts.Write("item_growth", row); err != nil {
			panic(err)
		}
	}
	if err := facts.Close(); err != nil {
		panic(err)
	}
	factsOpen = false
	result := map[string]any{
		"format":             "latifa-model-output-v2-go",
		"scope":              "issue-173 production model output bytes and item counts",
		"status":             reduceStatuses(byteRows, itemRows),
		"artifacts":          root,
		"active_capacity":    1,
		"answer_byte_growth": byteRows,
		"item_count_growth":  itemRows,
		"elapsed_seconds":    time.Since(started).Seconds(),
		"limits": []string{
			"macOS Apple Silicon runtime evidence only; Linux and x86 targets are compile-only",
			"deterministic loopback HTTP qualifies no TLS trust or live-provider behavior",
			"answer bytes and item counts grow independently in fresh Stores",
			"retry of interrupted Attempts and power loss remain outside this slice",
		},
	}
	evidence, err := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, *output)
	if err != nil {
		panic(err)
	}
	for name, value := range evidence {
		result[name] = value
	}
	if *output != "" {
		if err := measurement.WriteJSON(*output, result); err != nil {
			panic(err)
		}
	} else {
		if err := measurement.EncodeJSON(os.Stdout, result); err != nil {
			panic(err)
		}
	}
}
