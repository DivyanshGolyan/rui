package main

import (
	"bufio"
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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/process"
	"latifa.local/research/measurement"
	"latifa.local/research/model-output/provider"
)

const (
	memoryTarget                = 256 * 1024 * 1024
	capacityEventsPerBatch      = 1
	capacityEventBytes          = 260
	capacityMaximumAverageCores = 2.0
	capacityMaximumCPUSeconds   = 120.0
)

var answerSizes = []int{100_000}
var reasoningCounts = []int{1, 4, 32}

type capacityScenario struct {
	Capacity        int
	EventsPerSecond int
}

var capacityScenarios = []capacityScenario{
	{Capacity: 1, EventsPerSecond: 30},
	{Capacity: 8, EventsPerSecond: 30},
	{Capacity: 16, EventsPerSecond: 30},
	{Capacity: 100, EventsPerSecond: 100},
}

type childFixture struct {
	cmd         *exec.Cmd
	Process     *process.Process
	providerURL string
	controlURL  string
	stderr      *os.File
	closed      bool
}

type fixtureStartup struct {
	ProviderURL string `json:"provider_url"`
	ControlURL  string `json:"control_url"`
	PID         int    `json:"pid"`
}

func startChildFixture(deadline measurement.Deadline, streams, eventsPerSecond int, duration time.Duration, rounds int, artifactDir string) (*childFixture, error) {
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		return nil, err
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	stderr, err := os.OpenFile(filepath.Join(artifactDir, "provider-stderr.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable,
		"--provider-child",
		"--provider-streams", strconv.Itoa(streams),
		"--provider-events-per-second", strconv.Itoa(eventsPerSecond),
		"--provider-duration", duration.String(),
		"--provider-rounds", strconv.Itoa(rounds),
		"--provider-artifacts", artifactDir,
	)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stderr.Close()
		return nil, err
	}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		stderr.Close()
		return nil, err
	}
	line := make(chan struct {
		value []byte
		err   error
	}, 1)
	go func() {
		value, readError := bufio.NewReader(stdout).ReadBytes('\n')
		line <- struct {
			value []byte
			err   error
		}{value, readError}
	}()
	remaining, err := deadline.Remaining()
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		stderr.Close()
		return nil, err
	}
	var startupLine []byte
	select {
	case result := <-line:
		if result.err != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			stderr.Close()
			return nil, result.err
		}
		startupLine = result.value
	case <-time.After(remaining):
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		stderr.Close()
		return nil, errors.New("provider child startup timed out")
	}
	var startup fixtureStartup
	if err := json.Unmarshal(startupLine, &startup); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		stderr.Close()
		return nil, fmt.Errorf("decode provider child startup: %w", err)
	}
	if startup.PID != cmd.Process.Pid || startup.ProviderURL == "" || startup.ControlURL == "" {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		stderr.Close()
		return nil, fmt.Errorf("invalid provider child startup: %+v", startup)
	}
	childProcess, err := process.NewProcess(int32(startup.PID))
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		stderr.Close()
		return nil, err
	}
	return &childFixture{cmd: cmd, Process: childProcess, providerURL: startup.ProviderURL, controlURL: startup.ControlURL, stderr: stderr}, nil
}

func (f *childFixture) ProviderURL() string { return f.providerURL }

func (f *childFixture) request(deadline measurement.Deadline, route string) (provider.Summary, error) {
	remaining, err := deadline.Remaining()
	if err != nil {
		return provider.Summary{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), remaining)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, f.controlURL+route, nil)
	if err != nil {
		return provider.Summary{}, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return provider.Summary{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		return provider.Summary{}, fmt.Errorf("provider control %s returned %s: %s", route, response.Status, body)
	}
	var summary provider.Summary
	if err := json.NewDecoder(response.Body).Decode(&summary); err != nil {
		return provider.Summary{}, err
	}
	return summary, nil
}

func (f *childFixture) WaitReady(deadline measurement.Deadline) (provider.Summary, error) {
	return f.request(deadline, "/control/wait-ready")
}
func (f *childFixture) StartOffer(deadline measurement.Deadline) (provider.Summary, error) {
	return f.request(deadline, "/control/start-offer")
}
func (f *childFixture) WaitOffer(deadline measurement.Deadline) (provider.Summary, error) {
	return f.request(deadline, "/control/wait-offer")
}
func (f *childFixture) ReleaseTerminal(deadline measurement.Deadline) error {
	_, err := f.request(deadline, "/control/release-terminal")
	return err
}
func (f *childFixture) WaitCompletion(deadline measurement.Deadline) (provider.Summary, error) {
	return f.request(deadline, "/control/wait-completion")
}
func (f *childFixture) Reset(deadline measurement.Deadline) error {
	_, err := f.request(deadline, "/control/reset")
	return err
}

func (f *childFixture) Close() error {
	if f.closed {
		return nil
	}
	f.closed = true
	_, requestError := f.request(measurement.NewDeadline(5*time.Second), "/control/shutdown")
	waited := make(chan error, 1)
	go func() { waited <- f.cmd.Wait() }()
	var waitError error
	select {
	case waitError = <-waited:
	case <-time.After(10 * time.Second):
		killError := f.cmd.Process.Kill()
		waitError = errors.Join(errors.New("provider child did not stop"), killError, <-waited)
	}
	return errors.Join(requestError, waitError, f.stderr.Close())
}

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
func (e *payloadEndpoint) count() int         { e.mu.Lock(); defer e.mu.Unlock(); return len(e.requests) }
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
	return map[string]any{"destination_bytes": info.Size(), "destination_sha256": digest, "time_stderr": stderr.String()}, nil
}

type outputAudit struct {
	CanonicalOutputItems int `json:"canonical_output_items"`
	PrivateContentRows   int `json:"private_content_rows"`
	AssistantProjections int `json:"assistant_projections"`
}

func readOutputAudit(deadline measurement.Deadline, store string) (outputAudit, error) {
	query := "SELECT (SELECT count(*) FROM model_output_item) AS canonical_output_items," +
		"(SELECT count(*) FROM content WHERE private=1) AS private_content_rows," +
		"(SELECT count(*) FROM conversation_entry WHERE entry_kind=3) AS assistant_projections;"
	encoded, err := measurement.Run(deadline, "/usr/bin/sqlite3", "-json", filepath.Join(store, "latifa.sqlite3"), query)
	if err != nil {
		return outputAudit{}, err
	}
	var rows []outputAudit
	if err := json.Unmarshal(encoded, &rows); err != nil || len(rows) != 1 {
		return outputAudit{}, fmt.Errorf("decode output audit: rows=%d: %w", len(rows), err)
	}
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

type spillFacts struct {
	IntegrityCheck       string  `json:"integrity_check"`
	CompletedTurns       int     `json:"completed_turns"`
	PartialTurns         int     `json:"partial_turns"`
	CanonicalOutputItems int     `json:"canonical_output_items"`
	AssistantProjections int     `json:"assistant_projections"`
	OperationCount       int     `json:"operation_count"`
	AttemptOrdinal       *int    `json:"attempt_ordinal"`
	ResolutionCode       *string `json:"resolution_code"`
	Uncertain            *int    `json:"uncertain"`
	RetryDueAtMS         *int64  `json:"retry_due_at_ms"`
	LastFailureCode      *string `json:"last_failure_code"`
}

func readSpillFacts(deadline measurement.Deadline, store string) (spillFacts, error) {
	query := "SELECT (SELECT integrity_check FROM pragma_integrity_check LIMIT 1) AS integrity_check," +
		"(SELECT count(*) FROM turn WHERE outcome_code='completed') AS completed_turns," +
		"(SELECT count(*) FROM turn WHERE outcome_code IS NULL) AS partial_turns," +
		"(SELECT count(*) FROM model_output_item) AS canonical_output_items," +
		"(SELECT count(*) FROM conversation_entry WHERE entry_kind=3) AS assistant_projections," +
		"(SELECT count(*) FROM model_operation) AS operation_count," +
		"(SELECT attempt_ordinal FROM model_operation ORDER BY operation_id LIMIT 1) AS attempt_ordinal," +
		"(SELECT resolution_code FROM model_operation ORDER BY operation_id LIMIT 1) AS resolution_code," +
		"(SELECT uncertain FROM model_operation ORDER BY operation_id LIMIT 1) AS uncertain," +
		"(SELECT retry_due_at_ms FROM model_operation ORDER BY operation_id LIMIT 1) AS retry_due_at_ms," +
		"(SELECT last_failure_code FROM model_operation ORDER BY operation_id LIMIT 1) AS last_failure_code;"
	output, err := measurement.Run(deadline, "/usr/bin/sqlite3", "-json", filepath.Join(store, "latifa.sqlite3"), query)
	if err != nil {
		return spillFacts{}, err
	}
	var rows []spillFacts
	if err := json.Unmarshal(output, &rows); err != nil || len(rows) != 1 {
		return spillFacts{}, fmt.Errorf("decode spill facts: rows=%d: %w", len(rows), err)
	}
	return rows[0], nil
}

type sqliteDiagnostic struct {
	Phase                     string  `json:"latifa_test_phase"`
	AtNS                      string  `json:"at_ns"`
	Subject                   string  `json:"subject"`
	ProcessMemoryScope        string  `json:"process_memory_scope"`
	ProcessMemoryCurrentBytes *uint64 `json:"process_memory_current_bytes"`
	ProcessMemoryHighwater    *uint64 `json:"process_memory_highwater_bytes"`
	CacheUsedBytes            *uint64 `json:"cache_used_bytes"`
	CacheUsedScope            string  `json:"cache_used_scope"`
	CacheSpills               *uint64 `json:"cache_spills"`
	CacheSpillsScope          string  `json:"cache_spills_scope"`
	HardHeapLimitBytes        *uint64 `json:"hard_heap_limit_bytes"`
	PageSizeBytes             *uint64 `json:"page_size_bytes"`
	CacheSizeSetting          *int64  `json:"cache_size_setting"`
	CacheSizeSettingScope     string  `json:"cache_size_setting_scope"`
	CacheSpillThreshold       *int64  `json:"cache_spill_threshold"`
	MmapSizeBytes             *uint64 `json:"mmap_size_bytes"`
	Synchronous               *int64  `json:"synchronous"`
	TempStore                 *int64  `json:"temp_store"`
	BusyTimeoutMS             *uint64 `json:"busy_timeout_ms"`
	JournalMode               *string `json:"journal_mode"`
}

func rejectDuplicateJSONKeys(encoded []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return errors.New("diagnostic is not a JSON object")
	}
	seen := map[string]struct{}{}
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return err
		}
		key, ok := keyToken.(string)
		if !ok {
			return errors.New("diagnostic key is not a string")
		}
		if _, duplicate := seen[key]; duplicate {
			return fmt.Errorf("duplicate diagnostic field %q", key)
		}
		seen[key] = struct{}{}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	if token, err := decoder.Token(); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("unexpected trailing diagnostic token %v", token)
	}
	return nil
}

func sqliteDiagnosticRecords(report []byte) ([]sqliteDiagnostic, error) {
	result := []sqliteDiagnostic{}
	scanner := bufio.NewScanner(bytes.NewReader(report))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		var envelope struct {
			Phase string `json:"latifa_test_phase"`
		}
		if err := json.Unmarshal(line, &envelope); err != nil {
			if bytes.Contains(line, []byte("sqlite_diagnostic")) {
				return nil, fmt.Errorf("malformed SQLite diagnostic: %w", err)
			}
			continue
		}
		if envelope.Phase != "sqlite_diagnostic" {
			continue
		}
		if err := rejectDuplicateJSONKeys(line); err != nil {
			return nil, err
		}
		var record sqliteDiagnostic
		decoder := json.NewDecoder(bytes.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&record); err != nil {
			return nil, fmt.Errorf("decode SQLite diagnostic: %w", err)
		}
		result = append(result, record)
	}
	return result, scanner.Err()
}

func spillDiagnosticsValid(records []sqliteDiagnostic, enabled, completed bool) bool {
	expectedRecords := 1
	if completed {
		expectedRecords = 2
	}
	if len(records) != expectedRecords {
		return false
	}
	for _, record := range records {
		if record.Subject != "measure/spill" || record.HardHeapLimitBytes == nil || *record.HardHeapLimitBytes != 16*1024*1024 || record.Synchronous == nil || *record.Synchronous != 3 || record.JournalMode == nil || *record.JournalMode != "delete" || record.CacheSizeSetting == nil || *record.CacheSizeSetting != -32 || record.CacheSizeSettingScope != "raw PRAGMA cache_size; negative magnitude is suggested KiB, positive value is suggested pages" || record.CacheSpillThreshold == nil || record.CacheSpills == nil {
			return false
		}
		if (enabled && *record.CacheSpillThreshold <= 0) || (!enabled && *record.CacheSpillThreshold != 0) {
			return false
		}
	}
	if !enabled {
		for _, record := range records {
			if *record.CacheSpills != 0 {
				return false
			}
		}
		return true
	}
	if completed {
		initial := *records[0].CacheSpills
		final := *records[1].CacheSpills
		return final > 0 && final > initial
	}
	return true
}

func spillWriteEvidence(initial measurement.ProcessSample, final *measurement.ProcessSample) (map[string]any, string) {
	if final == nil {
		return map[string]any{"status": "unavailable", "reason": "Host exited before a final process sample"}, "unavailable"
	}
	if final.DiskWriteBytes < initial.DiskWriteBytes {
		return map[string]any{"status": "invalid", "initial_bytes": initial.DiskWriteBytes, "final_bytes": final.DiskWriteBytes, "reason": "process disk-write counter decreased"}, "invalid"
	}
	delta := final.DiskWriteBytes - initial.DiskWriteBytes
	status := "observed"
	if delta == 0 {
		status = "unavailable"
	}
	return map[string]any{"status": status, "initial_bytes": initial.DiskWriteBytes, "final_bytes": final.DiskWriteBytes, "delta_bytes": delta}, status
}

func spillVerdict(enabled, completed, naturalHostFailure bool, providerRequests int, initialWhole, finalWhole map[string]any, execution map[string]any, offline spillFacts, stderr, writeStatus string) (string, bool, bool) {
	resolution := ""
	if offline.ResolutionCode != nil {
		resolution = *offline.ResolutionCode
	}
	attemptOne := offline.AttemptOrdinal != nil && *offline.AttemptOrdinal == 1
	if completed {
		scratch, scratchOK := measurement.IntStringField(map[string]any{"execution": execution}, "execution", "scratch_used_bytes")
		custody, custodyOK := measurement.IntStringField(map[string]any{"execution": execution}, "execution", "custody_occupied")
		unfenced, fencedOK := execution["dispatch_fenced"].(bool)
		settledAttempt := offline.Uncertain != nil && *offline.Uncertain == 0 && offline.RetryDueAtMS == nil && offline.LastFailureCode == nil
		semanticSuccess := offline.IntegrityCheck == "ok" && offline.CompletedTurns == 1 && offline.PartialTurns == 0 && offline.CanonicalOutputItems == 2 && offline.AssistantProjections == 1 && offline.OperationCount == 1 && attemptOne && resolution == "completed" && settledAttempt && providerRequests == 1 && scratchOK && custodyOK && scratch == 0 && custody == 0 && fencedOK && !unfenced
		if !semanticSuccess || writeStatus == "invalid" {
			return "failed", false, false
		}
		memoryVerdict := memoryStatus(initialWhole, finalWhole)
		if writeStatus != "observed" || memoryVerdict == "incomplete" {
			return "incomplete", false, false
		}
		return memoryVerdict, false, false
	}
	unresolvedAttempt := offline.Uncertain != nil && *offline.Uncertain == 1 && offline.RetryDueAtMS != nil && *offline.RetryDueAtMS == 0 && offline.LastFailureCode == nil
	cleanRollback := offline.IntegrityCheck == "ok" && offline.CompletedTurns == 0 && offline.PartialTurns == 1 && offline.CanonicalOutputItems == 0 && offline.AssistantProjections == 0 && offline.OperationCount == 1 && attemptOne && offline.ResolutionCode == nil && unresolvedAttempt && providerRequests == 1
	expectedMemoryFailure := !enabled && naturalHostFailure && strings.Contains(stderr, "dispatch fenced after model output import failure: OutOfMemory") && cleanRollback
	if !expectedMemoryFailure {
		return "failed", cleanRollback, false
	}
	initialMemory := memoryStatus(initialWhole)
	if initialMemory != "passed" {
		return initialMemory, cleanRollback, true
	}
	return "expected_memory_failure", cleanRollback, true
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
	if err := client.Submit(name, "measure/"+name, "measure"); err != nil {
		return nil, err
	}
	observation, err := client.WaitResult(name)
	if err != nil {
		return nil, err
	}
	delivery, err := readResult(deadline, binary, store, name, filepath.Join(directory, "answer.bin"))
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256([]byte(answer))
	expectedDigest := hex.EncodeToString(digest[:])
	if delivery["destination_bytes"] != int64(len(answer)) || delivery["destination_sha256"] != expectedDigest {
		return nil, errors.New("saved result differs from response")
	}
	inspection, err := client.Inspect("measure/" + name)
	if err != nil {
		return nil, err
	}
	scratch, scratchOK := measurement.IntStringField(inspection, "execution", "scratch_used_bytes")
	custody, custodyOK := measurement.IntStringField(inspection, "execution", "custody_occupied")
	if !scratchOK || !custodyOK || scratch != 0 || custody != 0 {
		return nil, fmt.Errorf("retained resources after completion: %v", inspection)
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
		"status": status, "answer_bytes": len(answer), "reasoning_items": reasoning, "total_output_items": reasoning + 1,
		"sse_bytes": len(payload), "request_bytes": endpoint.lastRequestBytes(), "scratch_limit_bytes": host.Ready["scratch_limit_bytes"],
		"offline_audit": audit, "cold": map[string]any{"host": cold, "whole_latifa": coldWhole},
		"retained_idle": map[string]any{"host": retained, "whole_latifa": retainedWhole}, "client_delivery": delivery,
		"execution_after_completion": inspection["execution"], "observation": observation, "answer_sha256": expectedDigest,
	}, nil
}

func measureSpillCase(binary, root string, endpoint *payloadEndpoint, enabled bool) (map[string]any, error) {
	name := "spill-on"
	if !enabled {
		name = "spill-off"
	}
	directory := filepath.Join(root, name)
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	store := filepath.Join(directory, "store")
	answer := strings.Repeat("s", 100_000)
	payload := encodeSSE("spill-comparison", 1, answer)
	endpoint.set(payload)
	requestBefore := endpoint.count()
	deadline := measurement.NewDeadline(4 * time.Minute)
	extra := []string{"--test-phase-trace", "--test-sqlite-diagnostics", "--test-sqlite-cache-kib", "32"}
	if !enabled {
		extra = append(extra, "--test-sqlite-cache-spill-off")
	}
	host, err := measurement.StartHost(binary, store, endpoint.URL(), 1, filepath.Join(directory, "host-stderr.log"), deadline, extra...)
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	if err := client.Configure("spill", "measure/spill", "--tools", "none"); err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	initialInspection, err := client.Inspect("measure/spill")
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	initial, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-initial.txt"))
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	started := time.Now()
	if err := client.Message("spill", "measure/spill", "spill comparison"); err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	outcome := "timeout"
	var observation map[string]any
	waitUntil := time.Now().Add(120 * time.Second)
	for time.Now().Before(waitUntil) {
		running, runError := host.Process.IsRunning()
		if runError == nil && !running {
			outcome = "host_exit"
			break
		}
		value, observeError := client.Observe("spill")
		if observeError == nil {
			if _, ok := value["result"].(map[string]any); ok {
				observation = value
				outcome = "result"
				break
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	duration := time.Since(started).Seconds()
	completed := false
	if result, ok := observation["result"].(map[string]any); ok {
		completed = result["status"] == "completed"
	}
	var final *measurement.ProcessSample
	var delivery map[string]any
	var inspection map[string]any
	if completed {
		delivery, err = readResult(deadline, binary, store, "spill", filepath.Join(directory, "answer.bin"))
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		digest := sha256.Sum256([]byte(answer))
		if delivery["destination_bytes"] != int64(len(answer)) || delivery["destination_sha256"] != hex.EncodeToString(digest[:]) {
			host.Stop(measurement.TeardownAllowance)
			return nil, errors.New("spill result differed")
		}
		inspection, err = client.Inspect("measure/spill")
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		value, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-final.txt"))
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		final = &value
	}
	hostExit, stopError := host.StopWithExit(measurement.TeardownAllowance)
	stderr, readStderrError := os.ReadFile(filepath.Join(directory, "host-stderr.log"))
	offline, offlineError := readSpillFacts(deadline, store)
	if err := errors.Join(stopError, readStderrError, offlineError); err != nil {
		return nil, err
	}
	if outcome == "host_exit" && (!hostExit.Exited || hostExit.Code == 0) {
		return nil, fmt.Errorf("observed Host exit lacks expected nonzero status: %+v", hostExit)
	}
	databaseSize := int64(0)
	if info, statError := os.Stat(filepath.Join(store, "latifa.sqlite3")); statError == nil {
		databaseSize = info.Size()
	}
	diagnostics, err := sqliteDiagnosticRecords(stderr)
	if err != nil {
		return nil, err
	}
	initialWhole := wholeLatifa(initial)
	finalWhole := map[string]any(nil)
	if final != nil {
		finalWhole = wholeLatifa(*final)
	}
	execution := map[string]any(nil)
	if inspection != nil {
		execution, _ = inspection["execution"].(map[string]any)
	}
	writeEvidence, writeStatus := spillWriteEvidence(initial, final)
	providerRequests := endpoint.count() - requestBefore
	naturalHostFailure := outcome == "host_exit" && hostExit.Exited && hostExit.Code != 0
	status, cleanRollback, expectedMemoryFailure := spillVerdict(enabled, completed, naturalHostFailure, providerRequests, initialWhole, finalWhole, execution, offline, string(stderr), writeStatus)
	diagnosticsValid := spillDiagnosticsValid(diagnostics, enabled, completed)
	if !diagnosticsValid {
		status = "failed"
	}
	return map[string]any{"status": status, "cache_spill_requested": enabled, "test_cache_kib": 32, "answer_bytes": len(answer), "sse_bytes": len(payload), "provider_requests": providerRequests, "duration_seconds": duration, "initial": map[string]any{"host": initial, "whole_latifa": initialWhole, "execution": initialInspection["execution"]}, "final": map[string]any{"host": final, "whole_latifa": finalWhole}, "client_delivery": delivery, "execution": execution, "observed_outcome": outcome, "offline_after_host_reaped": offline, "database_bytes_after_host_reaped": databaseSize, "host_stderr_tail": string(stderr), "host_exit_after_reap": hostExit, "process_disk_write_evidence": writeEvidence, "host_sqlite_diagnostics": diagnostics, "effective_sqlite_configuration_valid": diagnosticsValid, "clean_transaction_rollback": cleanRollback, "expected_spill_off_memory_failure": expectedMemoryFailure}, nil
}

func spillComparison(binary, root string, endpoint *payloadEndpoint) (map[string]any, error) {
	on, err := measureSpillCase(binary, root, endpoint, true)
	if err != nil {
		return nil, err
	}
	off, err := measureSpillCase(binary, root, endpoint, false)
	if err != nil {
		return nil, err
	}
	status := spillComparisonStatus(on["status"], off["status"])
	return map[string]any{"status": status, "rows": []map[string]any{on, off}, "write_sync_qualification": map[string]any{"status": "unavailable", "sync_calls": nil, "reason": "Darwin exposes per-process disk-write bytes but no direct per-process sync-call oracle; effective Host SQLite settings are recorded separately in Host diagnostics"}}, nil
}

func spillComparisonStatus(on, off any) string {
	normalized := []map[string]any{{"status": on}, {"status": off}}
	if normalized[1]["status"] == "expected_memory_failure" {
		normalized[1]["status"] = "passed"
	}
	return reduceStatuses(normalized)
}

func expectedCapacityRequests(keys []string) (int, string) {
	type keyedDigest struct {
		key    string
		digest string
	}
	rows := make([]keyedDigest, 0, len(keys))
	totalBytes := 0
	for _, key := range keys {
		body := []byte(`{"model":"model-a","store":false,"stream":true,"include":["reasoning.encrypted_content"],"input":[{"role":"system","content":[{"type":"input_text","text":""}]},{"role":"user","content":[{"type":"input_text","text":` + strconv.Quote(key) + `}]}],"tools":[]}`)
		digest := sha256.Sum256(body)
		rows = append(rows, keyedDigest{key: key, digest: hex.EncodeToString(digest[:])})
		totalBytes += len(body)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].key < rows[j].key })
	set := sha256.New()
	for _, row := range rows {
		fmt.Fprintf(set, "%s\n", row.digest)
	}
	return totalBytes, hex.EncodeToString(set.Sum(nil))
}

type capacityWork struct {
	Batches uint64 `json:"batches"`
	Events  uint64 `json:"events"`
	Bytes   uint64 `json:"bytes"`
}

func checkedCapacityMultiply(values ...uint64) (uint64, error) {
	result := uint64(1)
	for _, value := range values {
		if value != 0 && result > ^uint64(0)/value {
			return 0, errors.New("capacity work expectation overflows uint64")
		}
		result *= value
	}
	return result, nil
}

func checkedCapacityAdd(left, right uint64) (uint64, error) {
	if left > ^uint64(0)-right {
		return 0, errors.New("capacity work expectation overflows uint64")
	}
	return left + right, nil
}

func expectedCapacityWork(capacity int, duration time.Duration, eventsPerSecond int) (capacityWork, error) {
	if capacity <= 0 || duration <= 0 || duration%time.Second != 0 || eventsPerSecond <= 0 {
		return capacityWork{}, errors.New("invalid capacity work dimensions")
	}
	batches, err := checkedCapacityMultiply(uint64(capacity), uint64(duration/time.Second), uint64(eventsPerSecond))
	if err != nil {
		return capacityWork{}, err
	}
	events, err := checkedCapacityMultiply(batches, capacityEventsPerBatch)
	if err != nil {
		return capacityWork{}, err
	}
	bytes, err := checkedCapacityMultiply(events, capacityEventBytes)
	if err != nil {
		return capacityWork{}, err
	}
	return capacityWork{Batches: batches, Events: events, Bytes: bytes}, nil
}

type capacityAuditRow struct {
	Key                  string  `json:"key"`
	Session              string  `json:"session"`
	InputText            string  `json:"input_text"`
	TurnOutcome          string  `json:"turn_outcome"`
	OperationSession     string  `json:"operation_session"`
	AttemptOrdinal       int     `json:"attempt_ordinal"`
	AllowanceUsed        int     `json:"allowance_used"`
	Uncertain            int     `json:"uncertain"`
	ResolutionCode       string  `json:"resolution_code"`
	ResponseID           string  `json:"response_id"`
	BodyModel            string  `json:"body_model"`
	OpenAIModel          string  `json:"openai_model"`
	RequestID            string  `json:"request_id"`
	OutputItems          int     `json:"output_items"`
	PrivateOutputItems   int     `json:"private_output_items"`
	AssistantProjections int     `json:"assistant_projections"`
	LastFailureCode      *string `json:"last_failure_code"`
}

type capacityAuditRequest struct {
	keys     []string
	sessions []string
}

type capacityAuditResult struct {
	rows     []capacityAuditRow
	complete bool
}

type capacityAuditor func(measurement.Deadline, string, []string, []string) ([]capacityAuditRow, bool, error)

func offlineCapacityAudits(stopHost func() error, requests []capacityAuditRequest, audit capacityAuditor, deadline measurement.Deadline, store string) ([]capacityAuditResult, error) {
	if err := stopHost(); err != nil {
		return nil, fmt.Errorf("stop and reap Host before capacity audits: %w", err)
	}
	results := make([]capacityAuditResult, 0, len(requests))
	for index, request := range requests {
		rows, complete, err := audit(deadline, store, request.keys, request.sessions)
		if err != nil {
			return nil, fmt.Errorf("offline capacity audit round %d: %w", index+1, err)
		}
		results = append(results, capacityAuditResult{rows: rows, complete: complete})
	}
	return results, nil
}

func capacityAuditRowsValid(rows []capacityAuditRow, keys, sessions []string) bool {
	if len(rows) != len(keys) {
		return false
	}
	for index, row := range rows {
		key := keys[index]
		if row.Key != key || row.Session != sessions[index] || row.InputText != key || row.TurnOutcome != "completed" || row.OperationSession != sessions[index] || row.AttemptOrdinal != 1 || row.AllowanceUsed != 1 || row.Uncertain != 0 || row.ResolutionCode != "completed" || row.ResponseID != "capacity-response-"+key || row.BodyModel != "model-a-served" || row.OpenAIModel != "model-a-served" || row.RequestID != "capacity-"+key || row.OutputItems != 1 || row.PrivateOutputItems != 1 || row.AssistantProjections != 1 || row.LastFailureCode != nil {
			return false
		}
	}
	return true
}

func auditCapacity(deadline measurement.Deadline, store string, keys, sessions []string) ([]capacityAuditRow, bool, error) {
	if len(keys) == 0 {
		return nil, false, errors.New("capacity audit requires at least one key")
	}
	prefixEnd := strings.LastIndex(keys[0], "-") + 1
	prefix := strings.ReplaceAll(keys[0][:prefixEnd], "'", "''")
	query := "SELECT ma.command_key AS key,ma.session_ref AS session,CAST(c.payload AS TEXT) AS input_text," +
		"t.outcome_code AS turn_outcome,mo.session_ref AS operation_session,mo.attempt_ordinal,mo.allowance_used,mo.uncertain," +
		"mo.resolution_code,mo.response_id,mo.body_model,mo.openai_model,mo.request_id,mo.last_failure_code," +
		"(SELECT count(*) FROM model_output_item oi WHERE oi.operation_id=mo.operation_id) AS output_items," +
		"(SELECT count(*) FROM model_output_item oi JOIN content private_content ON private_content.content_id=oi.content_id WHERE oi.operation_id=mo.operation_id AND private_content.private=1) AS private_output_items," +
		"(SELECT count(*) FROM conversation_entry ce WHERE ce.source_operation_id=mo.operation_id AND ce.entry_kind=3) AS assistant_projections " +
		"FROM message_admission ma JOIN content c ON c.content_id=ma.content_id JOIN turn t ON t.turn_id=ma.turn_id " +
		"JOIN model_operation mo ON mo.operation_id=t.operation_id WHERE ma.command_key GLOB '" + prefix + "*' ORDER BY ma.admission_id;"
	output, err := measurement.Run(deadline, "/usr/bin/sqlite3", "-json", filepath.Join(store, "latifa.sqlite3"), query)
	if err != nil {
		return nil, false, err
	}
	var rows []capacityAuditRow
	if err := json.Unmarshal(output, &rows); err != nil {
		return nil, false, err
	}
	return rows, capacityAuditRowsValid(rows, keys, sessions), nil
}

func processDelta(firstValue, secondValue any) map[string]any {
	firstOuter, firstOuterOK := firstValue.(map[string]any)
	secondOuter, secondOuterOK := secondValue.(map[string]any)
	first, firstOK := firstOuter["host"].(measurement.ProcessSample)
	second, secondOK := secondOuter["host"].(measurement.ProcessSample)
	if !firstOuterOK || !secondOuterOK || !firstOK || !secondOK {
		return map[string]any{"status": "unavailable"}
	}
	return map[string]any{
		"status":                   "observed",
		"rss_bytes":                int64(second.RSSBytes) - int64(first.RSSBytes),
		"virtual_bytes":            int64(second.VirtualBytes) - int64(first.VirtualBytes),
		"physical_footprint_bytes": int64(second.Footprint.PhysicalBytes) - int64(first.Footprint.PhysicalBytes),
		"open_descriptor_rows":     second.OpenDescriptorRows - first.OpenDescriptorRows,
	}
}

type capacityVerdictInput struct {
	Capacity               int
	EventsPerSecond        int
	Duration               time.Duration
	Offer                  provider.Summary
	Completion             provider.Summary
	ExpectedWork           capacityWork
	CaptureStatus          string
	CleanupStatus          string
	RequestIntegrityStatus string
	ResultDeliveryStatus   string
	DurableAuditStatus     string
	MemoryStatus           string
	SustainedCPUStatus     string
	SustainedAverageCores  float64
	CompleteWorkCPUSeconds float64
}

func providerOfferWorkComplete(summary provider.Summary, capacity int, expected capacityWork) bool {
	return summary.ExpectedStreams == capacity &&
		summary.ReadyStreams == capacity &&
		summary.OfferFinished == capacity &&
		summary.OfferFailedStreams == 0 &&
		summary.CompletedBatches == expected.Batches &&
		summary.CompletedEvents == expected.Events &&
		summary.OfferBytes == expected.Bytes
}

// Qualification establishes concurrent complete work, not a per-event deadline.
// The provider retains pacing violations for diagnosis and reports actual duration.
func providerOfferQualified(summary provider.Summary, capacity, eventsPerSecond int, duration time.Duration, expected capacityWork) bool {
	if duration <= 0 || duration%time.Second != 0 || eventsPerSecond <= 0 {
		return false
	}
	perStreamBatches := uint64(duration/time.Second) * uint64(eventsPerSecond)
	return providerOfferWorkComplete(summary, capacity, expected) &&
		summary.EventsPerSecond == eventsPerSecond &&
		summary.DeliveryMethod == "rational_pacing_v1" &&
		summary.MinimumBatches == perStreamBatches &&
		summary.MaximumBatches == perStreamBatches &&
		summary.ExpectedBatches == expected.Batches &&
		summary.ExpectedEvents == expected.Events &&
		summary.ExpectedOfferBytes == expected.Bytes &&
		summary.EventBytes == capacityEventBytes &&
		summary.EventsPerBatch == capacityEventsPerBatch &&
		summary.BatchesPerStream == int(perStreamBatches) &&
		summary.OfferSeconds == duration.Seconds() &&
		summary.StartUnixNS != 0 &&
		summary.EarliestFinalCompletionUnixNS > summary.StartUnixNS &&
		summary.LatestFinalCompletionUnixNS >= summary.EarliestFinalCompletionUnixNS &&
		summary.LatestFinalCompletionUnixNS <= summary.HardDeadlineUnixNS &&
		summary.HardDeadlineUnixNS == time.Unix(0, summary.StartUnixNS).Add(2*duration).UnixNano()
}

func providerTerminalComplete(summary provider.Summary, capacity int) bool {
	return summary.TerminalFinished == capacity && summary.TerminalFailedStreams == 0
}

func capacityVerdict(input capacityVerdictInput) string {
	statuses := []string{input.CaptureStatus, input.CleanupStatus, input.RequestIntegrityStatus, input.ResultDeliveryStatus, input.DurableAuditStatus, input.MemoryStatus, input.SustainedCPUStatus}
	for _, status := range statuses {
		if status == "failed" {
			return "failed"
		}
	}
	providerValid := providerOfferQualified(input.Offer, input.Capacity, input.EventsPerSecond, input.Duration, input.ExpectedWork) && providerTerminalComplete(input.Completion, input.Capacity)
	if !providerValid {
		return "incomplete"
	}
	for _, status := range statuses {
		if status == "incomplete" || status == "unavailable" || status == "" {
			return "incomplete"
		}
	}
	if input.MemoryStatus == "target_miss" || input.SustainedCPUStatus == "target_miss" || input.SustainedAverageCores > capacityMaximumAverageCores || input.CompleteWorkCPUSeconds > capacityMaximumCPUSeconds {
		return "target_miss"
	}
	for _, status := range statuses {
		if status != "passed" {
			return "incomplete"
		}
	}
	return "passed"
}

func observationStatus(available, valid bool) string {
	if !available {
		return "unavailable"
	}
	if !valid {
		return "failed"
	}
	return "passed"
}

func dependentObservationStatus(prerequisite, available, valid bool) string {
	if !prerequisite {
		return "unavailable"
	}
	return observationStatus(available, valid)
}

type bracketedCPUSample struct {
	CPUSeconds float64   `json:"host_cpu_seconds"`
	QueryStart time.Time `json:"query_start"`
	QueryEnd   time.Time `json:"query_finish"`
}

func sampleCPU(target *process.Process) (bracketedCPUSample, error) {
	result := bracketedCPUSample{QueryStart: time.Now()}
	value, err := measurement.CPUSeconds(target)
	result.QueryEnd = time.Now()
	if err != nil {
		return bracketedCPUSample{}, err
	}
	result.CPUSeconds = value
	return result, nil
}

func capacityAuditIdentity(capacity, round int) capacityAuditRequest {
	keys := make([]string, capacity)
	sessions := make([]string, capacity)
	for index := range capacity {
		keys[index] = fmt.Sprintf("capacity-%d-round-%d-%d", capacity, round, index)
		sessions[index] = fmt.Sprintf("measure/capacity-%d/%d/%d", capacity, round, index)
	}
	return capacityAuditRequest{keys: keys, sessions: sessions}
}

func capacityCPUWindowValid(offerStart time.Time, first, second bracketedCPUSample, earliestFinalCompletion time.Time) bool {
	return !first.QueryStart.Before(offerStart.Add(10*time.Second)) &&
		!second.QueryStart.Before(offerStart.Add(50*time.Second)) &&
		second.QueryStart.Sub(first.QueryEnd) >= 40*time.Second &&
		!earliestFinalCompletion.IsZero() &&
		!second.QueryEnd.After(earliestFinalCompletion)
}

func sustainedCPUQualificationStatus(offerQualified, windowValid bool, averageCores float64) string {
	if !offerQualified || !windowValid {
		return "unavailable"
	}
	if averageCores > capacityMaximumAverageCores {
		return "target_miss"
	}
	return "passed"
}

func measureCapacityRound(binary, directory, store string, round, capacity, eventsPerSecond int, duration time.Duration, deadline measurement.Deadline, host *measurement.Host, fixture *childFixture, facts *measurement.FactLog) (map[string]any, error) {
	roundDirectory := filepath.Join(directory, fmt.Sprintf("round-%d", round))
	if err := os.Mkdir(roundDirectory, 0o700); err != nil {
		return nil, err
	}
	if round > 1 {
		if err := fixture.Reset(deadline); err != nil {
			return nil, err
		}
	}
	expectedWork, err := expectedCapacityWork(capacity, duration, eventsPerSecond)
	if err != nil {
		return nil, err
	}
	fixtureInitial, err := measurement.SampleProcess(fixture.Process, filepath.Join(roundDirectory, "provider-footprint-initial.txt"))
	if err != nil {
		return nil, err
	}
	initial, err := measurement.SampleProcess(host.Process, filepath.Join(roundDirectory, "host-footprint-initial.txt"))
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: roundDirectory, Store: store, Deadline: deadline}
	identity := capacityAuditIdentity(capacity, round)
	keys := identity.keys
	sessions := identity.sessions
	for index := range capacity {
		if err := client.Configure(keys[index], sessions[index], "--tools", "none"); err != nil {
			return nil, err
		}
	}
	cpuAdmissionStart, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		return nil, err
	}
	for index := range capacity {
		if err := client.Message(keys[index], sessions[index], keys[index]); err != nil {
			return nil, err
		}
	}
	ready, err := fixture.WaitReady(deadline)
	if err != nil {
		return nil, err
	}
	baselineInspection, err := client.Inspect(sessions[0])
	if err != nil {
		return nil, err
	}
	baselineScratch, baselineOK := measurement.IntStringField(baselineInspection, "execution", "scratch_used_bytes")
	if !baselineOK {
		return nil, fmt.Errorf("retained request scratch unavailable: %v", baselineInspection)
	}
	started, err := fixture.StartOffer(deadline)
	if err != nil {
		return nil, err
	}
	offerStart := time.Unix(0, started.StartUnixNS)
	if err := deadline.SleepUntil(offerStart.Add(10 * time.Second)); err != nil {
		return nil, err
	}
	cpu10, err := sampleCPU(host.Process)
	if err != nil {
		return nil, err
	}
	secondTarget := offerStart.Add(50 * time.Second)
	if afterFirst := cpu10.QueryEnd.Add(40 * time.Second); afterFirst.After(secondTarget) {
		secondTarget = afterFirst
	}
	if err := deadline.SleepUntil(secondTarget); err != nil {
		return nil, err
	}
	cpu50, err := sampleCPU(host.Process)
	if err != nil {
		return nil, err
	}
	offer, err := fixture.WaitOffer(deadline)
	if err != nil {
		return nil, err
	}
	if err := facts.Write("cpu_window_and_offer", map[string]any{"round": round, "first": cpu10, "second": cpu50, "provider_offer": offer}); err != nil {
		return nil, err
	}
	responseScratch := expectedWork.Bytes
	expectedScratch, err := checkedCapacityAdd(baselineScratch, responseScratch)
	if err != nil {
		return nil, err
	}
	heldInspection, err := client.Inspect(sessions[0])
	if err != nil {
		return nil, err
	}
	heldScratch, heldScratchOK := measurement.IntStringField(heldInspection, "execution", "scratch_used_bytes")
	captureComplete := heldScratchOK && heldScratch == expectedScratch
	if err := fixture.ReleaseTerminal(deadline); err != nil {
		return nil, err
	}
	completion, err := fixture.WaitCompletion(deadline)
	if err != nil {
		return nil, err
	}
	if err := facts.Write("provider_complete", map[string]any{"round": round, "summary": completion}); err != nil {
		return nil, err
	}
	resultDeliveryComplete := true
	for index, key := range keys {
		observation, err := client.WaitResult(key)
		if err != nil {
			return nil, err
		}
		resultStatus, _ := measurement.StringField(observation, "result", "status")
		if resultStatus != "completed" {
			resultDeliveryComplete = false
			continue
		}
		answer, err := measurement.Run(deadline, binary, "read-result", "--store", store, "--key", key)
		if err != nil {
			return nil, err
		}
		if string(answer) != "capacity answer "+keys[index] {
			resultDeliveryComplete = false
		}
	}
	finalInspection, err := client.Inspect(sessions[0])
	if err != nil {
		return nil, err
	}
	finalScratch, finalScratchOK := measurement.IntStringField(finalInspection, "execution", "scratch_used_bytes")
	finalCustody, finalCustodyOK := measurement.IntStringField(finalInspection, "execution", "custody_occupied")
	cleanupComplete := finalScratchOK && finalCustodyOK && finalScratch == 0 && finalCustody == 0
	cpuEnd, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		return nil, err
	}
	if err := facts.Write("host_complete", map[string]any{"round": round, "host_cpu_seconds": cpuEnd, "inspection": finalInspection}); err != nil {
		return nil, err
	}
	retained, err := measurement.SampleProcess(host.Process, filepath.Join(roundDirectory, "host-footprint-retained.txt"))
	if err != nil {
		return nil, err
	}
	fixtureRetained, err := measurement.SampleProcess(fixture.Process, filepath.Join(roundDirectory, "provider-footprint-retained.txt"))
	if err != nil {
		return nil, err
	}
	sustainedCPU, err := measurement.CheckedCPUDelta(cpu10.CPUSeconds, cpu50.CPUSeconds)
	if err != nil {
		return nil, err
	}
	minimumSampleWindow := cpu50.QueryStart.Sub(cpu10.QueryEnd)
	maximumSampleWindow := cpu50.QueryEnd.Sub(cpu10.QueryStart)
	sustainedCores := 0.0
	if minimumSampleWindow > 0 {
		sustainedCores = sustainedCPU / minimumSampleWindow.Seconds()
	}
	var earliestFinalCompletion time.Time
	if offer.EarliestFinalCompletionUnixNS != 0 {
		earliestFinalCompletion = time.Unix(0, offer.EarliestFinalCompletionUnixNS)
	}
	offerQualified := providerOfferQualified(offer, capacity, eventsPerSecond, duration, expectedWork)
	bracketValid := capacityCPUWindowValid(offerStart, cpu10, cpu50, earliestFinalCompletion)
	cpuWindowValid := offerQualified && bracketValid
	sustainedCPUStatus := sustainedCPUQualificationStatus(offerQualified, bracketValid, sustainedCores)
	completeCPU, err := measurement.CheckedCPUDelta(cpuAdmissionStart, cpuEnd)
	if err != nil {
		return nil, err
	}
	expectedRequestBytes, expectedRequestDigest := expectedCapacityRequests(keys)
	requestComplete := offer.RequestBytes == expectedRequestBytes && offer.RequestSetSHA256 == expectedRequestDigest
	offerWorkComplete := providerOfferWorkComplete(offer, capacity, expectedWork)
	terminalComplete := providerTerminalComplete(completion, capacity)
	auditPrerequisite := offerWorkComplete && terminalComplete
	captureStatus := dependentObservationStatus(offerWorkComplete, heldScratchOK, captureComplete)
	resultDeliveryStatus := dependentObservationStatus(offerWorkComplete && terminalComplete, true, resultDeliveryComplete)
	successfulAuditStatus := dependentObservationStatus(auditPrerequisite, true, true)
	cleanupStatus := observationStatus(finalScratchOK && finalCustodyOK, cleanupComplete)
	requestIntegrityStatus := observationStatus(true, requestComplete)
	initialWhole := wholeLatifa(initial)
	retainedWhole := wholeLatifa(retained)
	memoryVerdict := memoryStatus(initialWhole, retainedWhole)
	status := capacityVerdict(capacityVerdictInput{
		Capacity:               capacity,
		EventsPerSecond:        eventsPerSecond,
		Duration:               duration,
		Offer:                  offer,
		Completion:             completion,
		ExpectedWork:           expectedWork,
		CaptureStatus:          captureStatus,
		CleanupStatus:          cleanupStatus,
		RequestIntegrityStatus: requestIntegrityStatus,
		ResultDeliveryStatus:   resultDeliveryStatus,
		DurableAuditStatus:     successfulAuditStatus,
		MemoryStatus:           memoryVerdict,
		SustainedCPUStatus:     sustainedCPUStatus,
		SustainedAverageCores:  sustainedCores,
		CompleteWorkCPUSeconds: completeCPU,
	})
	observedOffer := map[string]any{"status": "unavailable"}
	if offerWorkComplete && offer.LatestFinalCompletionUnixNS > offer.StartUnixNS {
		seconds := time.Duration(offer.LatestFinalCompletionUnixNS - offer.StartUnixNS).Seconds()
		observedOffer = map[string]any{"status": "observed", "seconds": seconds, "events_per_second": float64(offer.CompletedEvents) / seconds}
	}
	return map[string]any{
		"status": status, "round": round, "active_capacity": capacity, "events_per_second_per_stream": eventsPerSecond, "offer_seconds": duration.Seconds(), "fixture_ready": ready, "paced_offer": offer, "fixture_completion": completion,
		"retained_request_baseline": baselineInspection, "capture_before_terminal": heldInspection, "completion_inspection": finalInspection,
		"cpu": map[string]any{
			"status": sustainedCPUStatus, "provider_offer_qualified": offerQualified, "bracket_valid": bracketValid, "cpu_seconds": sustainedCPU,
			"first_query":                   map[string]any{"start_unix_ns": cpu10.QueryStart.UnixNano(), "finish_unix_ns": cpu10.QueryEnd.UnixNano(), "host_cpu_seconds": cpu10.CPUSeconds},
			"second_query":                  map[string]any{"start_unix_ns": cpu50.QueryStart.UnixNano(), "finish_unix_ns": cpu50.QueryEnd.UnixNano(), "host_cpu_seconds": cpu50.CPUSeconds},
			"minimum_sample_window_seconds": minimumSampleWindow.Seconds(), "maximum_sample_window_seconds": maximumSampleWindow.Seconds(), "earliest_stream_final_completion_unix_ns": offer.EarliestFinalCompletionUnixNS,
			"average_cores_conservative": sustainedCores, "at_most_2_average_cores": cpuWindowValid && sustainedCores <= capacityMaximumAverageCores, "complete_work_cpu_seconds": completeCPU, "complete_work_at_most_120_cpu_seconds": completeCPU <= capacityMaximumCPUSeconds,
		},
		"initial": map[string]any{"host": initial, "whole_latifa": initialWhole}, "retained": map[string]any{"host": retained, "whole_latifa": retainedWhole},
		"provider_process":               map[string]any{"pid": fixture.cmd.Process.Pid, "initial": fixtureInitial, "retained": fixtureRetained},
		"host_dimensions":                map[string]any{"capture": captureStatus, "cleanup": cleanupStatus, "request_integrity": requestIntegrityStatus, "result_delivery": resultDeliveryStatus},
		"durable_audit_prerequisite_met": auditPrerequisite, "result_delivery_complete": resultDeliveryComplete, "retained_request_scratch_bytes": baselineScratch, "expected_response_scratch_delta_bytes": responseScratch, "expected_retained_scratch_bytes": expectedScratch, "capture_observation_complete": captureComplete, "cleanup_observation_complete": cleanupComplete,
		"expected_provider_work": expectedWork,
		"observed_offer":         observedOffer,
		"request_integrity":      map[string]any{"status": requestIntegrityStatus, "expected_bytes": expectedRequestBytes, "observed_bytes": offer.RequestBytes, "expected_set_sha256": expectedRequestDigest, "observed_set_sha256": offer.RequestSetSHA256},
	}, nil
}

func applyOfflineCapacityAudit(row map[string]any, audit capacityAuditResult) error {
	prerequisite, ok := row["durable_audit_prerequisite_met"].(bool)
	if !ok {
		return errors.New("capacity round lacks durable audit prerequisite evidence")
	}
	status := dependentObservationStatus(prerequisite, true, audit.complete)
	dimensions, ok := row["host_dimensions"].(map[string]any)
	if !ok {
		return errors.New("capacity round lacks Host dimensions")
	}
	dimensions["durable_audit"] = status
	row["all_results_audited"] = audit.complete
	row["audit_rows"] = audit.rows
	row["offline_audit_after_host_reaped"] = true
	if status == "failed" {
		row["status"] = "failed"
	} else if status == "unavailable" && row["status"] == "passed" {
		return errors.New("capacity round passed without durable audit prerequisites")
	}
	return nil
}

func measureCapacity(binary, root string, scenario capacityScenario, duration time.Duration) (result map[string]any, resultError error) {
	capacity := scenario.Capacity
	directory := filepath.Join(root, fmt.Sprintf("capacity-%d", capacity))
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	facts, err := measurement.NewFactLog(filepath.Join(directory, "controller-facts.jsonl"))
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, facts.Close)
	}()
	fixture, err := startChildFixture(measurement.NewDeadline(time.Minute), capacity, scenario.EventsPerSecond, duration, 2, filepath.Join(directory, "provider"))
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, fixture.Close)
	}()
	deadline := measurement.NewDeadline(2*duration + 8*time.Minute)
	store := filepath.Join(directory, "store")
	host, err := measurement.StartHost(binary, store, fixture.ProviderURL(), capacity, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, err
	}
	hostNeedsStop := true
	defer func() {
		if hostNeedsStop {
			measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
		}
	}()
	if os.Getpid() == fixture.cmd.Process.Pid || host.Cmd.Process.Pid == fixture.cmd.Process.Pid || os.Getpid() == host.Cmd.Process.Pid {
		return nil, errors.New("controller, provider fixture and Host must have distinct process identities")
	}
	rounds := make([]map[string]any, 0, 2)
	for round := 1; round <= 2; round++ {
		row, err := measureCapacityRound(binary, directory, store, round, capacity, scenario.EventsPerSecond, duration, deadline, host, fixture, facts)
		if err != nil {
			return nil, err
		}
		rounds = append(rounds, row)
	}
	auditRequests := []capacityAuditRequest{
		capacityAuditIdentity(capacity, 1),
		capacityAuditIdentity(capacity, 2),
	}
	audits, err := offlineCapacityAudits(func() error {
		err := host.Stop(measurement.TeardownAllowance)
		if err == nil {
			hostNeedsStop = false
		}
		return err
	}, auditRequests, auditCapacity, deadline, store)
	if err != nil {
		return nil, err
	}
	for index, audit := range audits {
		if err := applyOfflineCapacityAudit(rounds[index], audit); err != nil {
			return nil, err
		}
		if err := facts.Write("offline_capacity_audit", map[string]any{"round": index + 1, "host_reaped": true, "complete": audit.complete, "rows": audit.rows}); err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"status": reduceStatuses(rounds), "active_capacity": capacity, "events_per_second_per_stream": scenario.EventsPerSecond, "same_host_rounds": 2, "rounds": rounds,
		"process_identity":                 map[string]any{"controller_pid": os.Getpid(), "provider_pid": fixture.cmd.Process.Pid, "host_pid": host.Cmd.Process.Pid, "all_distinct": true},
		"second_retained_delta_from_first": processDelta(rounds[0]["retained"], rounds[1]["retained"]),
	}, nil
}

func runProviderChild(streams, eventsPerSecond int, duration time.Duration, rounds int, artifacts string) error {
	server, err := provider.Start(provider.Config{Streams: streams, EventsPerSecond: eventsPerSecond, Duration: duration, Rounds: rounds, ArtifactDir: artifacts})
	if err != nil {
		return err
	}
	startup := fixtureStartup{ProviderURL: server.ProviderURL(), ControlURL: server.ControlURL(), PID: os.Getpid()}
	if err := json.NewEncoder(os.Stdout).Encode(startup); err != nil {
		return errors.Join(err, server.Close())
	}
	<-server.ShutdownRequested()
	return server.Close()
}

func main() {
	projection := flag.Bool("projection", false, "measure 1/4/8 KiB and 100 KB plain and escaped answer projections")
	output := flag.String("output", "", "write the final JSON to this path")
	capacityOnly := flag.Int("capacity", 0, "measure one active capacity")
	growthOnly := flag.Bool("growth-only", false, "run growth and spill smoke without capacity qualification")
	providerChild := flag.Bool("provider-child", false, "run the owned provider fixture child")
	providerStreams := flag.Int("provider-streams", 0, "provider child stream count")
	providerEventsPerSecond := flag.Int("provider-events-per-second", 0, "provider child events per second per stream")
	providerDuration := flag.Duration("provider-duration", 0, "provider child offer duration")
	providerRounds := flag.Int("provider-rounds", 1, "provider child round count")
	providerArtifacts := flag.String("provider-artifacts", "", "provider child artifact directory")
	flag.Parse()
	if *providerChild {
		if err := measurement.RequireRuntime(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := runProviderChild(*providerStreams, *providerEventsPerSecond, *providerDuration, *providerRounds, *providerArtifacts); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *projection {
		answerSizes = []int{1024, 4096, 8192, 100_000}
		reasoningCounts = nil
		*growthOnly = true
	}
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-output [--output path] [--capacity N | --growth-only | --projection] /absolute/path/to/latifa")
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
	byteRows := []map[string]any{}
	itemRows := []map[string]any{}
	var spillRows map[string]any
	if *capacityOnly == 0 {
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
				if err := facts.Write("answer_growth", escaped); err != nil {
					panic(err)
				}
			}
			if err := facts.Write("answer_growth", row); err != nil {
				panic(err)
			}
		}
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
		if !*projection {
			spillRows, err = spillComparison(binary, root, endpoint)
			if err != nil {
				panic(err)
			}
			if err := facts.Write("spill", spillRows); err != nil {
				panic(err)
			}
		}
	}
	scenarios := capacityScenarios
	if *capacityOnly > 0 {
		scenarios = nil
		for _, scenario := range capacityScenarios {
			if scenario.Capacity == *capacityOnly {
				scenarios = append(scenarios, scenario)
			}
		}
		if len(scenarios) == 0 {
			panic(fmt.Errorf("unsupported capacity %d", *capacityOnly))
		}
	}
	if *growthOnly {
		scenarios = nil
	}
	capacityRows := make([]map[string]any, 0, len(scenarios))
	for _, scenario := range scenarios {
		row, err := measureCapacity(binary, root, scenario, 60*time.Second)
		if err != nil {
			panic(err)
		}
		capacityRows = append(capacityRows, row)
		if err := facts.Write("capacity", row); err != nil {
			panic(err)
		}
	}
	if err := facts.Close(); err != nil {
		panic(err)
	}
	factsOpen = false
	spillStatusRows := []map[string]any{}
	if spillRows != nil {
		spillStatusRows = append(spillStatusRows, spillRows)
	}
	overallStatus := reduceStatuses(byteRows, itemRows, spillStatusRows, capacityRows)
	result := map[string]any{"format": "latifa-model-output-v7-go", "scope": "issue-176 assembled model-path capacity, capture, import and retained-idle qualification", "status": overallStatus, "artifacts": root, "answer_byte_growth": byteRows, "item_count_growth": itemRows, "sqlite_cache_spill_comparison": spillRows, "active_capacity_growth": capacityRows, "elapsed_seconds": time.Since(started).Seconds(), "limits": []string{"macOS Apple Silicon runtime evidence only; Linux and x86 targets are compile-only", "deterministic loopback HTTP qualifies no live-provider behavior", "ordinary 1/8/16-capacity scenarios offer 30 realistic 260-byte SSE records per second per stream for 60 seconds; the 100-capacity stress scenario offers 100 per second", "rational target scheduling aims at 60 seconds and emits exactly 1,800 or 6,000 events per stream; per-event pacing is diagnostic, collection stops at 120 seconds, and measured rate is not maximum sustainable throughput", "Host CPU uses conservative query brackets spanning at least 40 seconds wholly inside simultaneous complete offer work; the result must average at most two cores and complete work must consume at most 120 CPU seconds", "live result delivery and exact answer reads remain inside each round; private durable-row audits run only after both rounds and confirmed Host stop/reap", "spill rows force and verify SQLite cache spill with a test-only 32 KiB cache; production retains its 4 MiB cache"}}
	evidence, err := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, *output)
	if err != nil {
		panic(err)
	}
	for name, value := range evidence {
		result[name] = value
	}
	if *growthOnly && result["status"] == "passed" {
		result["status"] = "smoke_passed"
	}
	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		panic(err)
	}
	encoded = append(encoded, '\n')
	if *output != "" {
		if err := measurement.WriteJSON(*output, result); err != nil {
			panic(err)
		}
	} else {
		if err := measurement.WriteAll(os.Stdout, encoded); err != nil {
			panic(err)
		}
	}
}
