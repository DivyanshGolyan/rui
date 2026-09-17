package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"rui.local/qualification/measurement"
)

const physicalFootprintTargetBytes uint64 = 256 * 1024 * 1024

type call struct {
	ItemID    string
	Name      string
	ID        string
	Arguments string
}

type scenario struct {
	Name          string `json:"name"`
	Valid         int    `json:"valid_calls"`
	Rejected      int    `json:"rejected_calls"`
	ArgumentBytes int    `json:"argument_payload_bytes"`
	ReplayDenial  bool   `json:"restart_and_replay_denial"`
	FreezeCatalog bool   `json:"change_catalog_while_response_pending"`
}

type endpoint struct {
	server      *http.Server
	listener    net.Listener
	payload     []byte
	mu          sync.Mutex
	requests    int
	responseEnd time.Time
	release     chan struct{}
	releaseOnce sync.Once
}

func startEndpoint(payload []byte, held bool) (*endpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	e := &endpoint{listener: listener, payload: payload, release: make(chan struct{})}
	if !held {
		e.Release()
	}
	e.server = &http.Server{Handler: http.HandlerFunc(e.serve)}
	go func() { _ = e.server.Serve(listener) }()
	return e, nil
}

func (e *endpoint) serve(writer http.ResponseWriter, request *http.Request) {
	_, _ = io.Copy(io.Discard, request.Body)
	e.mu.Lock()
	e.requests++
	e.mu.Unlock()
	<-e.release
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("Content-Length", strconv.Itoa(len(e.payload)))
	writer.Header().Set("Connection", "close")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(e.payload)
	e.mu.Lock()
	e.responseEnd = time.Now()
	e.mu.Unlock()
}

func (e *endpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }

func (e *endpoint) Release() { e.releaseOnce.Do(func() { close(e.release) }) }

func (e *endpoint) facts() (int, time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.requests, e.responseEnd
}

func encodeCalls(responseID string, calls []call) []byte {
	items := make([]map[string]any, len(calls))
	var output bytes.Buffer
	write := func(value any) {
		encoded, _ := json.Marshal(value)
		output.WriteString("data: ")
		output.Write(encoded)
		output.WriteString("\n\n")
	}
	for index, candidate := range calls {
		item := map[string]any{
			"type": "function_call", "id": candidate.ItemID,
			"status": "completed", "name": candidate.Name, "call_id": candidate.ID, "arguments": candidate.Arguments,
		}
		items[index] = item
		write(map[string]any{"type": "response.output_item.added", "output_index": index, "item": map[string]any{"type": "function_call", "id": item["id"]}})
		write(map[string]any{"type": "response.function_call_arguments.delta", "output_index": index, "item_id": item["id"], "delta": "non-authoritative"})
		write(map[string]any{"type": "response.function_call_arguments.done", "output_index": index, "item_id": item["id"], "arguments": "non-authoritative"})
		write(map[string]any{"type": "response.output_item.done", "output_index": index, "item": item})
	}
	write(map[string]any{"type": "response.completed", "response": map[string]any{"id": responseID, "status": "completed", "output": items}})
	output.WriteString("data: [DONE]\n\n")
	return output.Bytes()
}

func scenarioCalls(value scenario, forbidden string) []call {
	calls := make([]call, 0, value.Valid+value.Rejected)
	padding := strings.Repeat("x", value.ArgumentBytes)
	for index := range value.Valid {
		command := fmt.Sprintf("touch %q # %s", forbidden, padding)
		arguments, _ := json.Marshal(map[string]string{"cmd": command})
		calls = append(calls, call{fmt.Sprintf("%s-item-%06d", value.Name, len(calls)), "bash", fmt.Sprintf("valid-%06d", index), string(arguments)})
	}
	for index := range value.Rejected {
		if index%2 == 0 {
			calls = append(calls, call{fmt.Sprintf("%s-item-%06d", value.Name, len(calls)), "unknown", fmt.Sprintf("unknown-%06d", index), "{}"})
		} else {
			calls = append(calls, call{fmt.Sprintf("%s-item-%06d", value.Name, len(calls)), "bash", fmt.Sprintf("malformed-%06d", index), "{"})
		}
	}
	return calls
}

type portablePeak struct {
	RSSBytes        uint64 `json:"rss_bytes"`
	VirtualBytes    uint64 `json:"virtual_bytes"`
	OpenDescriptors int32  `json:"open_descriptors"`
	Threads         int32  `json:"threads"`
}

type portableObservation struct {
	Status   string                     `json:"status"`
	Validity measurement.SampleValidity `json:"validity"`
	Peak     *portablePeak              `json:"peak,omitempty"`
}

type sampler struct {
	stop     chan struct{}
	done     chan struct{}
	mu       sync.Mutex
	peak     portablePeak
	validity measurement.SampleValidity
}

func startSampler(host *measurement.Host) *sampler {
	s := &sampler{stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(s.done)
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			sample, err := measurement.SamplePortableProcess(host.Process)
			s.mu.Lock()
			s.validity.Record(err)
			if err == nil {
				if sample.RSSBytes > s.peak.RSSBytes {
					s.peak.RSSBytes = sample.RSSBytes
				}
				if sample.VirtualBytes > s.peak.VirtualBytes {
					s.peak.VirtualBytes = sample.VirtualBytes
				}
				if sample.OpenDescriptors > s.peak.OpenDescriptors {
					s.peak.OpenDescriptors = sample.OpenDescriptors
				}
				if sample.Threads > s.peak.Threads {
					s.peak.Threads = sample.Threads
				}
			}
			s.mu.Unlock()
			select {
			case <-s.stop:
				return
			case <-ticker.C:
			}
		}
	}()
	return s
}

func (s *sampler) finish() portableObservation {
	close(s.stop)
	<-s.done
	s.mu.Lock()
	defer s.mu.Unlock()
	observation := portableObservation{Status: s.validity.Status(), Validity: s.validity}
	if s.validity.Succeeded > 0 {
		peak := s.peak
		observation.Peak = &peak
	}
	return observation
}

func actionIDs(inspection map[string]any) ([]string, error) {
	actions, ok := inspection["actions"].(map[string]any)
	if !ok {
		return nil, errors.New("inspection omitted actions")
	}
	rows, ok := actions["unresolved"].([]any)
	if !ok {
		return nil, errors.New("inspection omitted unresolved actions")
	}
	result := make([]string, 0, len(rows))
	for _, row := range rows {
		item, ok := row.(map[string]any)
		if !ok {
			return nil, errors.New("malformed unresolved action")
		}
		id, ok := item["action"].(string)
		if !ok {
			return nil, errors.New("action identity is not a string")
		}
		result = append(result, id)
	}
	return result, nil
}

func verifyActionContent(client measurement.Client, session string, inspection map[string]any, expected []call) (map[string]any, error) {
	actions, ok := inspection["actions"].(map[string]any)
	if !ok {
		return nil, errors.New("inspection omitted actions")
	}
	rows, ok := actions["unresolved"].([]any)
	if !ok || len(rows) != len(expected) {
		return nil, fmt.Errorf("got %d readable Actions, want %d", len(rows), len(expected))
	}
	actionIDs := make([]string, len(rows))
	for index, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("Action %d report is malformed", index)
		}
		action, actionOK := row["action"].(string)
		ordinal, ordinalOK := row["call_ordinal"].(string)
		if !actionOK || !ordinalOK || ordinal != strconv.Itoa(index) {
			return nil, fmt.Errorf("Action %d identity/order mismatch: %v", index, row)
		}
		actionIDs[index] = action
	}
	if err := verifyActionBytes(client, session, actionIDs, expected); err != nil {
		return nil, err
	}
	return map[string]any{"status": "passed", "actions_read": len(rows), "fields_per_action": 2}, nil
}

func verifyActionBytes(client measurement.Client, session string, actions []string, expected []call) error {
	if len(actions) != len(expected) {
		return fmt.Errorf("got %d Action identities, want %d", len(actions), len(expected))
	}
	for index, action := range actions {
		callID, err := client.ReadAction(session, action, "call-id")
		if err != nil {
			return fmt.Errorf("read Action %d call ID: %w", index, err)
		}
		arguments, err := client.ReadAction(session, action, "arguments")
		if err != nil {
			return fmt.Errorf("read Action %d arguments: %w", index, err)
		}
		if !bytes.Equal(callID, []byte(expected[index].ID)) || !bytes.Equal(arguments, []byte(expected[index].Arguments)) {
			return fmt.Errorf("Action %d public content differs from provider bytes", index)
		}
	}
	return nil
}

func contentReference(value string) map[string]string {
	domain := []byte("rui/content/v1")
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(domain)))
	hash := sha256.New()
	hash.Write(length[:])
	hash.Write(domain)
	hash.Write([]byte(value))
	return map[string]string{"type": "text", "bytes": strconv.Itoa(len(value)), "sha256": hex.EncodeToString(hash.Sum(nil))}
}

func verifyRejectedReferences(inspection map[string]any, expected []call, valid int) (map[string]any, error) {
	rejected, ok := inspection["rejected_calls"].(map[string]any)
	if !ok {
		return nil, errors.New("inspection omitted rejected calls")
	}
	rows, ok := rejected["items"].([]any)
	if !ok || len(rows) != len(expected)-valid {
		return nil, fmt.Errorf("got %d rejected-call references, want %d", len(rows), len(expected)-valid)
	}
	for index, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("rejected call %d report is malformed", index)
		}
		candidate := expected[valid+index]
		code := "unknown_tool"
		if index%2 == 1 {
			code = "invalid_arguments"
		}
		if row["call_ordinal"] != strconv.Itoa(valid+index) || row["code"] != code {
			return nil, fmt.Errorf("rejected call %d order/code mismatch: %v", index, row)
		}
		for field, text := range map[string]string{"item_id": candidate.ItemID, "name": candidate.Name, "call_id": candidate.ID, "arguments": candidate.Arguments} {
			actual, ok := row[field].(map[string]any)
			expectedReference := contentReference(text)
			if !ok || actual["type"] != expectedReference["type"] || actual["bytes"] != expectedReference["bytes"] || actual["sha256"] != expectedReference["sha256"] {
				return nil, fmt.Errorf("rejected call %d %s reference mismatch: %v", index, field, row[field])
			}
		}
	}
	return map[string]any{"status": "passed", "calls_checked": len(rows), "references_per_call": 4}, nil
}

func recordPortableSample(result map[string]any, name string, host *measurement.Host) {
	sample, err := measurement.SamplePortableProcess(host.Process)
	if err != nil {
		result[name] = map[string]any{"status": "unavailable", "error": err.Error()}
		result["portable_measurement_status"] = "unavailable"
		return
	}
	result[name] = map[string]any{"status": "diagnostic", "sample": sample}
	if result["portable_measurement_status"] == nil {
		result["portable_measurement_status"] = "diagnostic"
	}
}

func observedCounts(inspection map[string]any) (int, int, error) {
	actions, ok := inspection["actions"].(map[string]any)
	if !ok {
		return 0, 0, errors.New("inspection omitted actions")
	}
	rejected, ok := inspection["rejected_calls"].(map[string]any)
	if !ok {
		return 0, 0, errors.New("inspection omitted rejected calls")
	}
	validText, ok := actions["count"].(string)
	if !ok {
		return 0, 0, errors.New("action count is not a string")
	}
	rejectedText, ok := rejected["count"].(string)
	if !ok {
		return 0, 0, errors.New("rejected-call count is not a string")
	}
	valid, err := strconv.Atoi(validText)
	if err != nil {
		return 0, 0, err
	}
	invalid, err := strconv.Atoi(rejectedText)
	return valid, invalid, err
}

func latencySummary(samples []float64) map[string]any {
	result := map[string]any{"count": len(samples)}
	if len(samples) == 0 {
		return result
	}
	ordered := append([]float64(nil), samples...)
	sort.Float64s(ordered)
	percentile := func(numerator int) float64 {
		index := (len(ordered)*numerator + 99) / 100
		if index == 0 {
			index = 1
		}
		return ordered[index-1]
	}
	result["minimum_ms"] = ordered[0]
	result["p50_ms"] = percentile(50)
	result["p95_ms"] = percentile(95)
	result["maximum_ms"] = ordered[len(ordered)-1]
	return result
}

func combineStatus(current, next string) string {
	rank := map[string]int{"passed": 0, "unavailable": 1, "target_miss": 2, "behavior_error": 3}
	if rank[next] > rank[current] {
		return next
	}
	return current
}

func deny(client measurement.Client, directory, session, action string, index int) (float64, error) {
	started := time.Now()
	var answer map[string]any
	err := measurement.RunJSON(client.Deadline, &answer, client.Binary,
		"deny-action", "--store", client.Store, "--record", filepath.Join(directory, fmt.Sprintf("deny-%d.json", index)),
		"--key", fmt.Sprintf("deny-%d", index), "--session", session, "--action", action)
	if err == nil {
		status, _ := measurement.StringField(answer, "answer", "status")
		if status != "accepted" {
			err = fmt.Errorf("denial was not accepted: %v", answer)
		}
	}
	return float64(time.Since(started).Microseconds()) / 1000, err
}

func namedScratchPopulation(store string) (map[string]uint64, error) {
	entries, err := os.ReadDir(filepath.Join(store, "scratch"))
	if err != nil {
		return nil, err
	}
	var bytes uint64
	for _, entry := range entries {
		info, statError := entry.Info()
		if statError != nil {
			return nil, statError
		}
		bytes += uint64(info.Size())
	}
	return map[string]uint64{"named_files": uint64(len(entries)), "named_logical_bytes": bytes}, nil
}

type auditedCall struct {
	CallOrdinal   int     `json:"call_ordinal"`
	ItemOrdinal   int     `json:"item_ordinal"`
	Rejection     *string `json:"rejection"`
	ActionID      *int    `json:"action_id"`
	Permission    *int    `json:"permission"`
	ActionOutcome *string `json:"action_outcome"`
}

func audit(deadline measurement.Deadline, sqliteBinary, store string, expected scenario) (map[string]any, error) {
	query := `SELECT printf('%d|%d|%d|%d|%d|%d|%d|%d|%d',` +
		`(SELECT count(*) FROM model_tool_call),(SELECT count(*) FROM action_operation),` +
		`(SELECT count(*) FROM model_tool_call WHERE rejection_code IS NOT NULL),` +
		`(SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool'),` +
		`(SELECT count(*) FROM model_tool_call WHERE rejection_code='invalid_arguments'),` +
		`(SELECT count(*) FROM action_operation WHERE resolution_code='denied'),` +
		`(SELECT count(*) FROM action_operation WHERE resolution_code IS NULL),` +
		`(SELECT count(*) FROM permission_decision_command),(SELECT count(*) FROM pragma_foreign_key_check));`
	output, err := measurement.Run(deadline, sqliteBinary, "-noheader", filepath.Join(store, "rui.sqlite3"), query)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(string(output)), "|")
	if len(parts) != 9 {
		return nil, fmt.Errorf("unexpected audit output %q", output)
	}
	names := []string{"calls", "actions", "rejections", "unknown", "invalid_arguments", "denied", "pending", "decisions", "foreign_key_failures"}
	counts := map[string]int{}
	for index, name := range names {
		value, parseError := strconv.Atoi(parts[index])
		if parseError != nil {
			return nil, parseError
		}
		counts[name] = value
	}
	expectedUnknown := (expected.Rejected + 1) / 2
	expectedInvalid := expected.Rejected / 2
	if counts["calls"] != expected.Valid+expected.Rejected || counts["actions"] != expected.Valid ||
		counts["rejections"] != expected.Rejected || counts["unknown"] != expectedUnknown ||
		counts["invalid_arguments"] != expectedInvalid || counts["denied"] != expected.Valid ||
		counts["pending"] != 0 || counts["decisions"] != expected.Valid || counts["foreign_key_failures"] != 0 {
		return map[string]any{"counts": counts}, fmt.Errorf("audit mismatch for %+v: %v", expected, counts)
	}
	rowsQuery := `SELECT call.call_ordinal,call.item_ordinal,` +
		`call.rejection_code AS rejection,action.action_id AS action_id,action.permission_state AS permission,` +
		`action.resolution_code AS action_outcome FROM model_tool_call call ` +
		`LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal ` +
		`ORDER BY call.call_ordinal;`
	encoded, err := measurement.Run(deadline, sqliteBinary, "-json", filepath.Join(store, "rui.sqlite3"), rowsQuery)
	if err != nil {
		return map[string]any{"counts": counts}, err
	}
	var rows []auditedCall
	if err := json.Unmarshal(encoded, &rows); err != nil {
		return map[string]any{"counts": counts}, fmt.Errorf("decode ordered call audit: %w", err)
	}
	if len(rows) != expected.Valid+expected.Rejected {
		return map[string]any{"counts": counts, "ordered_calls": rows}, fmt.Errorf("got %d audited calls, want %d", len(rows), expected.Valid+expected.Rejected)
	}
	for index, row := range rows {
		if row.CallOrdinal != index || row.ItemOrdinal != index {
			return map[string]any{"counts": counts, "ordered_calls": rows}, fmt.Errorf("call %d relational order mismatch: %+v", index, row)
		}
		if index < expected.Valid {
			if row.Rejection != nil || row.ActionID == nil || row.Permission == nil || *row.Permission != 2 || row.ActionOutcome == nil || *row.ActionOutcome != "denied" {
				return map[string]any{"counts": counts, "ordered_calls": rows}, fmt.Errorf("valid call %d authority mismatch: %+v", index, row)
			}
		} else {
			expectedRejection := "unknown_tool"
			if (index-expected.Valid)%2 == 1 {
				expectedRejection = "invalid_arguments"
			}
			if row.Rejection == nil || *row.Rejection != expectedRejection || row.ActionID != nil || row.Permission != nil || row.ActionOutcome != nil {
				return map[string]any{"counts": counts, "ordered_calls": rows}, fmt.Errorf("rejected call %d acquired authority or wrong result: %+v", index, row)
			}
		}
	}
	return map[string]any{"counts": counts, "ordered_calls": rows}, nil
}

func runScenario(binary, sqliteBinary, root string, value scenario) (result map[string]any, returnedError error) {
	result = map[string]any{"inputs": value, "status": "behavior_error"}
	directory := filepath.Join(root, value.Name)
	store := filepath.Join(directory, "store")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return result, err
	}
	forbidden := filepath.Join(directory, "must-not-launch")
	calls := scenarioCalls(value, forbidden)
	payload := encodeCalls(value.Name, calls)
	result["provider_response_bytes"] = len(payload)
	endpoint, err := startEndpoint(payload, value.FreezeCatalog)
	if err != nil {
		return result, err
	}
	defer measurement.JoinCleanup(&returnedError, func() error {
		endpoint.Release()
		return endpoint.server.Close()
	})
	deadline := measurement.NewDeadline(2 * time.Minute)
	host, err := measurement.StartHost(binary, store, endpoint.URL(), 1, filepath.Join(directory, "host-stderr.log"), deadline, "--test-cleanup-delay-ms", "500")
	if err != nil {
		return result, err
	}
	hostRunning := true
	defer func() {
		if hostRunning {
			measurement.JoinCleanup(&returnedError, func() error { return host.Stop(measurement.TeardownAllowance) })
		}
	}()
	samples := startSampler(host)
	samplersRunning := true
	defer func() {
		if samplersRunning {
			result["portable_observed_peak"] = samples.finish()
		}
	}()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	if err := client.Configure(value.Name, "qualification/"+value.Name, "--tools", "bash"); err != nil {
		return result, err
	}
	recordPortableSample(result, "retained_idle_before", host)
	admissionStarted := time.Now()
	if err := client.Message(value.Name, "qualification/"+value.Name, "classify raw provider calls"); err != nil {
		return result, err
	}
	if value.FreezeCatalog {
		if err := measurement.WaitFor(deadline, 5*time.Millisecond, "held provider request", func() (bool, error) {
			requests, _ := endpoint.facts()
			return requests == 1, nil
		}); err != nil {
			return result, err
		}
		if err := client.Configure(value.Name+"-remove-tools", "qualification/"+value.Name, "--tools", "none"); err != nil {
			return result, err
		}
		endpoint.Release()
	}
	var inspection map[string]any
	var classifiedAt time.Time
	err = measurement.WaitFor(deadline, 10*time.Millisecond, "complete call classification", func() (bool, error) {
		candidate, inspectError := client.Inspect("qualification/" + value.Name)
		if inspectError != nil {
			return false, inspectError
		}
		valid, rejected, countError := observedCounts(candidate)
		if countError != nil {
			return false, countError
		}
		if valid == value.Valid && rejected == value.Rejected {
			inspection = candidate
			classifiedAt = time.Now()
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		return result, err
	}
	requests, responseEnd := endpoint.facts()
	if requests != 1 || responseEnd.IsZero() {
		return result, fmt.Errorf("provider requests=%d response_end=%v", requests, responseEnd)
	}
	result["classification_admission_ms"] = float64(classifiedAt.Sub(admissionStarted).Microseconds()) / 1000
	if classifiedAt.Before(responseEnd) {
		result["response_end_to_classification_status"] = "unavailable"
		result["response_end_to_classification_reason"] = "fixture write completion raced committed classification"
	} else {
		result["response_end_to_classification_status"] = "diagnostic"
		result["response_end_to_classification_ms"] = float64(classifiedAt.Sub(responseEnd).Microseconds()) / 1000
	}
	inspectStarted := time.Now()
	inspection, err = client.Inspect("qualification/" + value.Name)
	if err != nil {
		return result, err
	}
	result["inspection_ms"] = float64(time.Since(inspectStarted).Microseconds()) / 1000
	recordPortableSample(result, "delayed_cleanup_sample", host)
	result["delayed_cleanup_execution"] = inspection["execution"]
	execution, ok := inspection["execution"].(map[string]any)
	if !ok || execution["custody_occupied"] != "1" {
		return result, fmt.Errorf("delayed cleanup did not retain one custody slot: %v", inspection["execution"])
	}
	if population, populationError := namedScratchPopulation(store); populationError == nil {
		result["delayed_cleanup_named_scratch"] = population
	} else {
		return result, populationError
	}
	contentEvidence, err := verifyActionContent(client, "qualification/"+value.Name, inspection, calls[:value.Valid])
	result["public_action_content"] = contentEvidence
	if err != nil {
		return result, err
	}
	rejectedEvidence, err := verifyRejectedReferences(inspection, calls, value.Valid)
	result["public_rejected_references"] = rejectedEvidence
	if err != nil {
		return result, err
	}
	actions, err := actionIDs(inspection)
	if err != nil {
		return result, err
	}
	if len(actions) != value.Valid {
		return result, fmt.Errorf("got %d unresolved actions, want %d", len(actions), value.Valid)
	}
	denialLatencies := make([]float64, 0, len(actions))
	for index, action := range actions {
		latency, denialError := deny(client, directory, "qualification/"+value.Name, action, index)
		if denialError != nil {
			return result, denialError
		}
		denialLatencies = append(denialLatencies, latency)
		if value.ReplayDenial {
			afterDenial, inspectError := client.Inspect("qualification/" + value.Name)
			if inspectError != nil {
				return result, inspectError
			}
			remaining, identityError := actionIDs(afterDenial)
			if identityError != nil {
				return result, identityError
			}
			expectedRemaining := actions[index+1:]
			if strings.Join(remaining, ",") != strings.Join(expectedRemaining, ",") {
				return result, fmt.Errorf("denial %d rewrote siblings: got %v want %v", index, remaining, expectedRemaining)
			}
		}
	}
	result["denial_latency"] = latencySummary(denialLatencies)
	err = measurement.WaitFor(deadline, 10*time.Millisecond, "physical cleanup", func() (bool, error) {
		candidate, inspectError := client.Inspect("qualification/" + value.Name)
		if inspectError != nil {
			return false, inspectError
		}
		execution, ok := candidate["execution"].(map[string]any)
		if !ok {
			return false, errors.New("inspection omitted execution")
		}
		return execution["custody_occupied"] == "0" && execution["scratch_used_bytes"] == "0", nil
	})
	if err != nil {
		return result, err
	}
	recordPortableSample(result, "retained_idle_after", host)
	result["database"], err = measurement.DatabaseSize(store)
	if err != nil {
		return result, err
	}
	result["retained_named_scratch"], err = namedScratchPopulation(store)
	if err != nil {
		return result, err
	}
	if runtime.GOOS == "darwin" {
		physical, physicalError := measurement.SampleProcess(host.Process, filepath.Join(directory, "retained-footprint.txt"))
		if physicalError != nil {
			result["physical_footprint_status"] = "unavailable"
			result["physical_footprint_error"] = physicalError.Error()
		} else {
			verdict := measurement.ClassifyFootprint(physical.Footprint, physicalFootprintTargetBytes)
			result["physical_footprint_status"] = verdict.Status
			result["physical_footprint"] = map[string]any{"lifecycle": "same Host cold through work, drain, and retained idle", "verdict": verdict, "retained_sample": physical}
		}
	} else {
		result["physical_footprint_status"] = "unavailable"
		result["physical_footprint_error"] = "accepted physical-footprint counter requires macOS /usr/bin/footprint"
	}
	portablePeak := samples.finish()
	result["portable_observed_peak"] = portablePeak
	if portablePeak.Status == "unavailable" {
		result["portable_measurement_status"] = "unavailable"
	}
	samplersRunning = false
	if _, statError := os.Stat(forbidden); !errors.Is(statError, os.ErrNotExist) {
		return result, fmt.Errorf("forbidden Bash effect exists: %v", statError)
	}
	result["forbidden_bash_launch_absent"] = true
	if err := host.Stop(measurement.TeardownAllowance); err != nil {
		return result, err
	}
	hostRunning = false
	if value.ReplayDenial && len(actions) > 0 {
		host, err = measurement.StartHost(binary, store, endpoint.URL(), 1, filepath.Join(directory, "restart-stderr.log"), deadline)
		if err != nil {
			return result, err
		}
		hostRunning = true
		var replay map[string]any
		if err := measurement.RunJSON(deadline, &replay, binary, "retry", "--store", store,
			"--record", filepath.Join(directory, "deny-0.json"), "--kind", "permission-decision"); err != nil {
			return result, err
		}
		status, _ := measurement.StringField(replay, "answer", "status")
		replayed, _ := replay["answer"].(map[string]any)["replayed"].(bool)
		if status != "accepted" || !replayed {
			return result, fmt.Errorf("denial replay mismatch: %v", replay)
		}
		result["denial_replay"] = replay
		recovered, inspectError := client.Inspect("qualification/" + value.Name)
		if inspectError != nil {
			return result, inspectError
		}
		valid, rejected, countError := observedCounts(recovered)
		if countError != nil || valid != value.Valid || rejected != value.Rejected {
			return result, fmt.Errorf("restart changed classified populations: actions=%d rejected=%d error=%v", valid, rejected, countError)
		}
		if _, referenceError := verifyRejectedReferences(recovered, calls, value.Valid); referenceError != nil {
			return result, fmt.Errorf("restart changed rejected call references: %w", referenceError)
		}
		if contentError := verifyActionBytes(client, "qualification/"+value.Name, actions, calls[:value.Valid]); contentError != nil {
			return result, fmt.Errorf("restart changed denied Action content: %w", contentError)
		}
		result["restart_exact_content"] = map[string]any{"status": "passed", "denied_actions_read": len(actions), "rejected_references_checked": value.Rejected * 4}
		remaining, identityError := actionIDs(recovered)
		if identityError != nil || len(remaining) != 0 {
			return result, fmt.Errorf("restart changed denial outcomes: unresolved=%v error=%v", remaining, identityError)
		}
		if err := host.Stop(measurement.TeardownAllowance); err != nil {
			return result, err
		}
		hostRunning = false
	}
	facts, err := audit(deadline, sqliteBinary, store, value)
	result["durable_audit"] = facts
	if err != nil {
		return result, err
	}
	result["status"] = "passed"
	return result, nil
}

func main() {
	output := flag.String("output", "", "write JSON to path")
	flag.Parse()
	if flag.NArg() != 2 {
		fmt.Fprintln(os.Stderr, "usage: measure-call-classification [--output path] /absolute/path/to/rui /absolute/path/to/pinned-sqlite3")
		os.Exit(2)
	}
	if err := measurement.RequireGoRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, _ := filepath.Abs(flag.Arg(0))
	sqliteBinary, _ := filepath.Abs(flag.Arg(1))
	root, err := os.MkdirTemp("", "rui-call-classification-")
	if err != nil {
		panic(err)
	}
	scenarios := []scenario{
		{Name: "mixed-restart", Valid: 2, Rejected: 2, ArgumentBytes: 16, ReplayDenial: true, FreezeCatalog: true},
		{Name: "valid-1", Valid: 1, ArgumentBytes: 16},
		{Name: "valid-32", Valid: 32, ArgumentBytes: 16},
		{Name: "valid-256", Valid: 256, ArgumentBytes: 16},
		{Name: "rejected-1", Rejected: 1, ArgumentBytes: 16},
		{Name: "rejected-32", Rejected: 32, ArgumentBytes: 16},
		{Name: "rejected-256", Rejected: 256, ArgumentBytes: 16},
		{Name: "payload-4096", Valid: 1, ArgumentBytes: 4096},
		{Name: "payload-100000", Valid: 1, ArgumentBytes: 100000},
	}
	cases := map[string]any{}
	status := "passed"
	for _, candidate := range scenarios {
		value, caseError := runScenario(binary, sqliteBinary, root, candidate)
		if caseError != nil {
			value["status"] = "behavior_error"
			value["error"] = caseError.Error()
			status = combineStatus(status, "behavior_error")
		}
		if physicalStatus, ok := value["physical_footprint_status"].(string); ok {
			status = combineStatus(status, physicalStatus)
		}
		if portableStatus, ok := value["portable_measurement_status"].(string); ok && portableStatus == "unavailable" {
			status = combineStatus(status, portableStatus)
		}
		cases[candidate.Name] = value
	}
	result := map[string]any{
		"format": "rui-call-classification-v2-go", "scope": "GitHub issue #228 production raw-provider call classification, exact denial, restart recovery, and independent population scaling",
		"status": status, "cases": cases, "artifacts": root,
		"classification_legend": map[string]string{"behavior_error": "a provider/Store/server/client invariant failed", "unavailable": "a required measurement was absent or its uncertainty interval crossed the target", "target_miss": "the lower bound of a valid macOS lifetime-peak interval exceeded 256 MiB", "passed": "behavior and required measurements passed", "diagnostic": "portable RSS, latency, database, named scratch, CPU and descriptor observations have no independent acceptance threshold"},
		"limits":                []string{"Linux execution is deterministic production-path development evidence; macOS runtime and physical footprint remain unavailable in this orb", "loopback deterministic provider; no live provider, TLS, filesystem power-loss, or Bash execution qualification", "Bash launch is intentionally forbidden: denial qualification ends before the later execution slice", "population and payload values are workloads, not product quotas", "process-crash and restart evidence does not certify power loss"},
	}
	evidence, evidenceError := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, *output)
	if evidenceError != nil {
		result["environment_evidence_status"] = "unavailable"
		result["environment_evidence_error"] = evidenceError.Error()
		status = combineStatus(status, "unavailable")
	} else {
		result["environment_evidence_status"] = "passed"
		for key, value := range evidence {
			result[key] = value
		}
	}
	sqliteHash, sqliteError := measurement.SHA256File(sqliteBinary)
	if sqliteError != nil {
		result["sqlite_binary_status"] = "unavailable"
		result["sqlite_binary_error"] = sqliteError.Error()
		status = combineStatus(status, "unavailable")
	} else {
		result["sqlite_binary_status"] = "passed"
		result["sqlite_binary"] = sqliteBinary
		result["sqlite_binary_sha256"] = sqliteHash
	}
	result["status"] = status
	if *output != "" {
		err = measurement.WriteJSON(*output, result)
	} else {
		err = measurement.EncodeJSON(os.Stdout, result)
	}
	if err != nil {
		panic(err)
	}
	if status == "behavior_error" || status == "target_miss" {
		os.Exit(1)
	}
}
