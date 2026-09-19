package main

import (
	"bufio"
	"bytes"
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
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"

	"rui.local/qualification/measurement"
)

type traceEvent struct {
	Phase        string `json:"rui_test_phase"`
	At           string `json:"at_ns"`
	Operation    string `json:"operation"`
	Action       string `json:"action"`
	ControlKey   string `json:"control_key"`
	Subject      string `json:"subject"`
	Deadline     string `json:"deadline_ns"`
	StoreQueued  string `json:"store_queued_at_ns"`
	QueueWait    string `json:"queue_wait_ns"`
	QueuedAfter  string `json:"queued_after"`
	WorkBytes    string `json:"work_bytes"`
	WorkItems    string `json:"work_items"`
	RequestBytes string `json:"request_bytes"`
	MaximumGap   string `json:"maximum_gap_ns"`
	at           uint64
	deadline     uint64
	accepted     uint64
	queuedAfter  uint64
	workBytes    uint64
	workItems    uint64
	requestBytes uint64
	maximumGap   uint64
}

type interval struct {
	Kind       string `json:"kind"`
	Subject    string `json:"subject"`
	StartNS    uint64 `json:"start_ns"`
	EndNS      uint64 `json:"end_ns"`
	DurationNS uint64 `json:"duration_ns"`
}

type metrics struct {
	Status                    string     `json:"status"`
	MaxLifecycleServiceGapNS  *uint64    `json:"max_lifecycle_service_gap_ns"`
	LargestUninterruptedNS    *uint64    `json:"largest_uninterrupted_work_interval_ns"`
	StopToEffectNS            []uint64   `json:"stop_to_effect_ns"`
	DeadlineToServiceNS       []uint64   `json:"deadline_to_service_ns"`
	Preparation               []interval `json:"preparation_intervals"`
	Validation                []interval `json:"validation_intervals"`
	Settlement                []interval `json:"settlement_intervals"`
	MaxNativeCompletionsAfter uint64     `json:"max_native_completions_queued_after_removal"`
	PreparationAdvanceCount   uint64     `json:"preparation_advance_count"`
	PreparationWorkBytes      uint64     `json:"preparation_work_bytes_total"`
	PreparationWorkItems      uint64     `json:"preparation_work_items_total"`
	MaxPreparationWorkBytes   uint64     `json:"max_preparation_work_bytes_per_advance"`
	MaxPreparationWorkItems   uint64     `json:"max_preparation_work_items_per_advance"`
	FinalRequestBytes         uint64     `json:"final_request_bytes"`
	Invalid                   []string   `json:"invalid_metrics,omitempty"`
}

const preparationByteAllowance = 16 * 1024
const preparationItemAllowance = 64

func uintField(value, name string) (uint64, error) {
	if value == "" {
		return 0, fmt.Errorf("missing %s", name)
	}
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", name, err)
	}
	return n, nil
}

func parseTraces(data []byte) ([]traceEvent, error) {
	var result []traceEvent
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if !bytes.HasPrefix(line, []byte(`{"rui_test_phase"`)) {
			continue
		}
		var event traceEvent
		if err := json.Unmarshal(line, &event); err != nil {
			return nil, fmt.Errorf("malformed trace: %w", err)
		}
		if event.At != "" {
			value, err := uintField(event.At, "at_ns")
			if err != nil {
				return nil, err
			}
			event.at = value
		}
		if event.Deadline != "" {
			value, err := uintField(event.Deadline, "deadline_ns")
			if err != nil {
				return nil, err
			}
			event.deadline = value
		}
		if event.QueuedAfter != "" {
			value, err := uintField(event.QueuedAfter, "queued_after")
			if err != nil {
				return nil, err
			}
			event.queuedAfter = value
		}
		if event.Phase == "preparation_advance_completed" || event.Phase == "preparation_advance_failed" {
			var err error
			if event.workBytes, err = uintField(event.WorkBytes, "work_bytes"); err != nil {
				return nil, err
			}
			if event.workItems, err = uintField(event.WorkItems, "work_items"); err != nil {
				return nil, err
			}
			if event.requestBytes, err = uintField(event.RequestBytes, "request_bytes"); err != nil {
				return nil, err
			}
		}
		if event.Phase == "lifecycle_service_observation" {
			value, err := uintField(event.MaximumGap, "maximum_gap_ns")
			if err != nil {
				return nil, err
			}
			event.maximumGap = value
		}
		if event.Phase == "control_timing" {
			queued, err := uintField(event.StoreQueued, "store_queued_at_ns")
			if err != nil {
				return nil, err
			}
			wait, err := uintField(event.QueueWait, "queue_wait_ns")
			if err != nil || wait > queued {
				return nil, errors.New("invalid control acceptance timestamp")
			}
			event.accepted = queued - wait
		}
		result = append(result, event)
	}
	return result, scanner.Err()
}

func subject(e traceEvent) string {
	if e.Action != "" {
		return "action:" + e.Action
	}
	return "operation:" + e.Operation
}

func deriveMetrics(events []traceEvent, requireDeadline bool) metrics {
	m := metrics{Status: "passed", StopToEffectNS: []uint64{}, DeadlineToServiceNS: []uint64{}, Preparation: []interval{}, Validation: []interval{}, Settlement: []interval{}}
	type start struct {
		at    uint64
		phase string
	}
	starts := map[string]start{}
	accepted := map[string]uint64{}
	var serviceObserved bool
	var maximumServiceGap uint64
	requestBytes := map[string]uint64{}
	var maxWork uint64
	for _, e := range events {
		if e.Phase == "control_durable_acceptance" && e.Subject != "" && e.at != 0 {
			accepted[e.Subject] = e.at
		}
		if e.at == 0 {
			continue
		}
		switch e.Phase {
		case "lifecycle_service_observation":
			serviceObserved = true
			maximumServiceGap = max(maximumServiceGap, e.maximumGap)
		case "provider_completion_removed":
			if e.queuedAfter > m.MaxNativeCompletionsAfter {
				m.MaxNativeCompletionsAfter = e.queuedAfter
			}
		case "effect_stop_requested":
			at, ok := accepted[e.ControlKey]
			if !ok || e.at < at {
				m.Invalid = append(m.Invalid, "stop_to_effect:"+e.ControlKey)
			} else {
				m.StopToEffectNS = append(m.StopToEffectNS, e.at-at)
			}
		case "bash_deadline_serviced":
			if e.deadline == 0 || e.at < e.deadline {
				m.Invalid = append(m.Invalid, "deadline_to_service:"+subject(e))
			} else {
				m.DeadlineToServiceNS = append(m.DeadlineToServiceNS, e.at-e.deadline)
			}
		case "preparation_advance_started", "validation_started", "settlement_lock_requested":
			key := subject(e) + ":" + e.Phase
			if _, exists := starts[key]; exists {
				m.Invalid = append(m.Invalid, "duplicate_start:"+key)
			} else {
				starts[key] = start{e.at, e.Phase}
			}
		case "preparation_advance_completed", "preparation_advance_failed", "validation_completed", "validation_failed", "settlement_complete", "model_settlement_superseded":
			begin := map[string]string{"preparation_advance_completed": "preparation_advance_started", "preparation_advance_failed": "preparation_advance_started", "validation_completed": "validation_started", "validation_failed": "validation_started", "settlement_complete": "settlement_lock_requested", "model_settlement_superseded": "settlement_lock_requested"}[e.Phase]
			key := subject(e) + ":" + begin
			s, ok := starts[key]
			if !ok || e.at < s.at {
				m.Invalid = append(m.Invalid, "incomplete_interval:"+key)
				continue
			}
			delete(starts, key)
			row := interval{begin, subject(e), s.at, e.at, e.at - s.at}
			if row.DurationNS > maxWork {
				maxWork = row.DurationNS
			}
			switch begin {
			case "preparation_advance_started":
				m.Preparation = append(m.Preparation, row)
				m.PreparationAdvanceCount++
				m.PreparationWorkBytes += e.workBytes
				m.PreparationWorkItems += e.workItems
				m.MaxPreparationWorkBytes = max(m.MaxPreparationWorkBytes, e.workBytes)
				m.MaxPreparationWorkItems = max(m.MaxPreparationWorkItems, e.workItems)
				m.FinalRequestBytes = max(m.FinalRequestBytes, e.requestBytes)
				if e.workBytes > preparationByteAllowance || e.workItems > preparationItemAllowance {
					m.Invalid = append(m.Invalid, "preparation_allowance_exceeded:"+subject(e))
				}
				if previous, exists := requestBytes[subject(e)]; exists && e.requestBytes < previous {
					m.Invalid = append(m.Invalid, "request_bytes_regressed:"+subject(e))
				}
				requestBytes[subject(e)] = e.requestBytes
			case "validation_started":
				m.Validation = append(m.Validation, row)
			default:
				m.Settlement = append(m.Settlement, row)
			}
		}
	}
	for key := range starts {
		m.Invalid = append(m.Invalid, "missing_end:"+key)
	}
	if serviceObserved {
		m.MaxLifecycleServiceGapNS = &maximumServiceGap
	} else {
		m.Invalid = append(m.Invalid, "max_lifecycle_service_gap")
	}
	if len(m.Preparation)+len(m.Validation)+len(m.Settlement) > 0 {
		m.LargestUninterruptedNS = &maxWork
	} else {
		m.Invalid = append(m.Invalid, "largest_uninterrupted_work_interval")
	}
	if len(m.Preparation) == 0 || m.PreparationWorkBytes == 0 || m.PreparationWorkItems == 0 || m.FinalRequestBytes == 0 {
		m.Invalid = append(m.Invalid, "preparation_work_evidence")
	}
	if len(m.StopToEffectNS) == 0 {
		m.Invalid = append(m.Invalid, "stop_to_effect")
	}
	if requireDeadline && len(m.DeadlineToServiceNS) == 0 {
		m.Invalid = append(m.Invalid, "deadline_to_service")
	}
	if len(m.Invalid) > 0 {
		m.Status = "invalid"
	}
	sort.Strings(m.Invalid)
	return m
}

func finalOperationEvents(events []traceEvent, count int) []traceEvent {
	identities := map[uint64]struct{}{}
	for _, event := range events {
		if event.Operation == "" {
			continue
		}
		identity, err := strconv.ParseUint(event.Operation, 10, 64)
		if err == nil {
			identities[identity] = struct{}{}
		}
	}
	ordered := make([]uint64, 0, len(identities))
	for identity := range identities {
		ordered = append(ordered, identity)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] > ordered[j] })
	if len(ordered) > count {
		ordered = ordered[:count]
	}
	selected := map[string]struct{}{}
	for _, identity := range ordered {
		selected[strconv.FormatUint(identity, 10)] = struct{}{}
	}
	result := make([]traceEvent, 0, len(events))
	for _, event := range events {
		_, operationSelected := selected[event.Operation]
		if operationSelected || event.Operation == "" {
			result = append(result, event)
		}
	}
	return result
}

type endpoint struct {
	listener            net.Listener
	server              *http.Server
	mu                  sync.Mutex
	hold                bool
	waiting             int
	release             chan struct{}
	retained, discarded int
	bashNext            bool
}

func newEndpoint() (*endpoint, error) {
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return nil, e
	}
	x := &endpoint{listener: l, release: make(chan struct{})}
	x.server = &http.Server{Handler: http.HandlerFunc(x.serve)}
	go x.server.Serve(l)
	return x, nil
}
func (e *endpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *endpoint) serve(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, r.Body)
	e.mu.Lock()
	hold := e.hold
	bash := e.bashNext
	e.bashNext = false
	if hold {
		e.waiting++
	}
	retained, discarded := e.retained, e.discarded
	release := e.release
	e.mu.Unlock()
	if hold {
		<-release
	}
	payload := encodeSSE(retained, discarded)
	if bash {
		payload = encodeBashSSE()
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	_, _ = w.Write(payload)
}
func (e *endpoint) setFields(retained, discarded int) {
	e.mu.Lock()
	e.retained, e.discarded = retained, discarded
	e.mu.Unlock()
}
func (e *endpoint) arm() {
	e.mu.Lock()
	e.hold = true
	e.waiting = 0
	e.release = make(chan struct{})
	e.mu.Unlock()
}
func (e *endpoint) armBash() { e.mu.Lock(); e.bashNext = true; e.mu.Unlock() }
func (e *endpoint) wait(n int, d measurement.Deadline) error {
	return measurement.WaitFor(d, time.Millisecond, "ready completion burst", func() (bool, error) { e.mu.Lock(); defer e.mu.Unlock(); return e.waiting == n, nil })
}
func (e *endpoint) fire() {
	e.mu.Lock()
	if e.hold {
		close(e.release)
		e.hold = false
	}
	e.mu.Unlock()
}
func encodeSSE(retained, discarded int) []byte {
	item := map[string]any{"type": "reasoning", "id": "reasoning", "summary": []any{}, "encrypted_content": string(bytes.Repeat([]byte{'r'}, retained)), "created_by": string(bytes.Repeat([]byte{'d'}, discarded))}
	message := map[string]any{"type": "message", "id": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "ok", "annotations": []any{}}}}
	events := []any{map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"type": "reasoning", "id": "reasoning"}}, map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item}, map[string]any{"type": "response.output_item.added", "output_index": 1, "item": map[string]any{"type": "message", "id": "message"}}, map[string]any{"type": "response.output_item.done", "output_index": 1, "item": message}, map[string]any{"type": "response.completed", "response": map[string]any{"id": "response", "status": "completed", "model": "model-a", "output": []any{item, message}}}}
	var out bytes.Buffer
	for _, v := range events {
		b, _ := json.Marshal(v)
		fmt.Fprintf(&out, "data: %s\n\n", b)
	}
	out.WriteString("data: [DONE]\n\n")
	return out.Bytes()
}

func encodeBashSSE() []byte {
	item := map[string]any{"type": "function_call", "id": "bash-item", "status": "completed", "name": "bash", "call_id": "bash-call", "arguments": `{"cmd":"sleep 1","timeout_ms":null}`}
	events := []any{
		map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"type": "function_call", "id": "bash-item"}},
		map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item},
		map[string]any{"type": "response.completed", "response": map[string]any{"id": "bash-response", "status": "completed", "model": "model-a", "output": []any{item}}},
	}
	var out bytes.Buffer
	for _, value := range events {
		encoded, _ := json.Marshal(value)
		fmt.Fprintf(&out, "data: %s\n\n", encoded)
	}
	out.WriteString("data: [DONE]\n\n")
	return out.Bytes()
}

func waitForTrace(path, phase string, deadline measurement.Deadline) error {
	needle := []byte(`"rui_test_phase":"` + phase + `"`)
	return measurement.WaitFor(deadline, time.Millisecond, phase, func() (bool, error) {
		data, err := os.ReadFile(path)
		if err != nil {
			return false, err
		}
		return bytes.Contains(data, needle), nil
	})
}

type scenario struct {
	Name           string `json:"name"`
	Burst          int    `json:"ready_completion_burst"`
	HistoryBytes   int    `json:"selected_history_bytes"`
	HistoryItems   int    `json:"selected_history_items"`
	RetainedBytes  int    `json:"retained_replay_field_bytes"`
	DiscardedBytes int    `json:"discarded_replay_field_bytes"`
	ActiveOwners   int    `json:"active_owner_population"`
	Bash           bool   `json:"bash_owner"`
}

func runScenario(binary, root string, s scenario) (result map[string]any, err error) {
	d := measurement.NewDeadline(90 * time.Second)
	dir := filepath.Join(root, s.Name)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return
	}
	ep, e := newEndpoint()
	if e != nil {
		return nil, e
	}
	defer ep.server.Close()
	ep.setFields(s.RetainedBytes, s.DiscardedBytes)
	store := filepath.Join(dir, "store")
	stderr := filepath.Join(dir, "host-stderr.log")
	host, e := measurement.StartHost(binary, store, ep.URL(), s.ActiveOwners, stderr, d, "--test-phase-trace", "--bash-timeout-ms", "50")
	if e != nil {
		return nil, e
	}
	hostStopped := false
	defer func() {
		if !hostStopped {
			err = errors.Join(err, host.Stop(measurement.TeardownAllowance))
		}
	}()
	client := measurement.Client{Binary: binary, Artifacts: dir, Store: store, Deadline: d}
	for i := 0; i < s.ActiveOwners; i++ {
		session := fmt.Sprintf("execution/%d", i)
		if e = client.Configure(fmt.Sprintf("config-%d", i), session, "--tools", "none"); e != nil {
			return nil, e
		}
		text := string(bytes.Repeat([]byte{'h'}, max(1, s.HistoryBytes/max(1, s.HistoryItems))))
		for j := 0; j < s.HistoryItems; j++ {
			key := fmt.Sprintf("history-%d-%d", i, j)
			if e = client.Message(key, session, text); e != nil {
				return nil, e
			}
			if _, e = client.WaitResult(key); e != nil {
				return nil, e
			}
		}
	}
	if s.Bash {
		ep.armBash()
		if e = client.Configure("bash-config", "execution/bash", "--tools", "bash"); e != nil {
			return nil, e
		}
		if e = client.Message("bash-message", "execution/bash", "run"); e != nil {
			return nil, e
		}
		action, actionErr := client.WaitAction("execution/bash")
		if actionErr != nil {
			return nil, actionErr
		}
		if e = client.AllowAction("bash-allow", "execution/bash", action); e != nil {
			return nil, e
		}
		if e = waitForTrace(stderr, "bash_handoff_committed", d); e != nil {
			return nil, e
		}
	}
	ep.arm()
	burst := min(s.Burst, s.ActiveOwners)
	if s.Bash {
		burst = min(burst, s.ActiveOwners-1)
	}
	for i := 0; i < burst; i++ {
		if e = client.Message(fmt.Sprintf("burst-%d", i), fmt.Sprintf("execution/%d", i), "burst"); e != nil {
			return nil, e
		}
	}
	if s.Bash {
		if e = waitForTrace(stderr, "bash_deadline_serviced", d); e != nil {
			return nil, e
		}
	}
	if e = ep.wait(burst, d); e != nil {
		return nil, e
	}
	if burst != 0 {
		if e = client.StopSession("stop-burst", "execution/0"); e != nil {
			return nil, e
		}
		if e = waitForTrace(stderr, "effect_stop_requested", d); e != nil {
			return nil, e
		}
	}
	ep.fire()
	for i := 0; i < burst; i++ {
		if _, e = client.WaitResult(fmt.Sprintf("burst-%d", i)); e != nil {
			return nil, e
		}
	}
	e = host.Stop(measurement.TeardownAllowance)
	hostStopped = true
	if e != nil {
		return nil, e
	}
	data, e := os.ReadFile(stderr)
	if e != nil {
		return nil, e
	}
	events, e := parseTraces(data)
	if e != nil {
		return nil, e
	}
	if !s.Bash {
		events = finalOperationEvents(events, burst)
	}
	digest := sha256.Sum256(data)
	m := deriveMetrics(events, s.Bash)
	slotBytes, slotErr := strconv.Atoi(host.Ready["execution_slot_bytes"])
	preparationBytes, preparationErr := strconv.Atoi(host.Ready["model_preparation_bytes"])
	if slotErr != nil || preparationErr != nil {
		return nil, errors.Join(slotErr, preparationErr)
	}
	const precedingSlotBytes = 1264
	bashEvidence := map[string]any{"status": "not_present", "reason": "this factorial case isolates another input dimension"}
	if s.Bash {
		bashEvidence = map[string]any{"status": "present", "path": "production provider Tool Call, public inspection and permission, native Bash owner, timeout action, and retained cleanup"}
	}
	return map[string]any{
		"parameters": s, "status": m.Status, "metrics": m, "trace_events": len(events),
		"trace_sha256": hex.EncodeToString(digest[:]),
		"structural_memory": map[string]any{
			"execution_slot_bytes": slotBytes, "preceding_execution_slot_bytes": precedingSlotBytes,
			"slot_change_times_capacity_bytes":   (slotBytes - precedingSlotBytes) * s.ActiveOwners,
			"shared_preparation_workspace_bytes": preparationBytes,
			"total_structural_change_bytes":      (slotBytes-precedingSlotBytes)*s.ActiveOwners + preparationBytes,
		},
		"unrelated_bash_owner": bashEvidence,
	}, nil
}

func main() {
	output := flag.String("output", "execution-service-results.json", "result JSON")
	selectedCase := flag.String("case", "", "run one named case")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: execution-service [flags] RUI_BINARY")
		os.Exit(2)
	}
	binary, _ := filepath.Abs(flag.Arg(0))
	root, err := os.MkdirTemp("", "rui-execution-service-")
	if err != nil {
		panic(err)
	}
	scenarios := []scenario{
		{"baseline", 1, 1024, 1, 64, 64, 1, false},
		{"completion-burst", 8, 1024, 1, 64, 64, 8, false},
		{"history-bytes", 1, 256 * 1024, 1, 64, 64, 1, false},
		{"history-items", 1, 64 * 1024, 16, 64, 64, 1, false},
		{"retained-field", 1, 1024, 1, 256 * 1024, 64, 1, false},
		{"discarded-field", 1, 1024, 1, 64, 256 * 1024, 1, false},
		{"active-owners", 1, 1024, 1, 64, 64, 8, false},
		{"mixed-bash", 8, 8 * 1024, 1, 64, 64, 8, true},
	}
	rows := []map[string]any{}
	status := "passed"
	for _, s := range scenarios {
		if *selectedCase != "" && s.Name != *selectedCase {
			continue
		}
		row, e := runScenario(binary, root, s)
		if e != nil {
			row = map[string]any{"parameters": s, "status": "failed", "error": e.Error()}
			status = "failed"
		}
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		fmt.Fprintf(os.Stderr, "unknown case %q\n", *selectedCase)
		os.Exit(2)
	}
	provenance, pErr := measurement.EnvironmentEvidence(measurement.NewDeadline(20*time.Second), binary, *output)
	if pErr != nil {
		status = "failed"
	}
	for _, row := range rows {
		if row["status"] != "passed" && status == "passed" {
			status = "invalid"
		}
	}
	rootPath, rootErr := measurement.RepositoryRoot()
	sourceHashes := map[string]string{}
	for _, name := range []string{
		"ARCHITECTURE.md", "VERIFICATION.md", "build.zig",
		"src/bash.zig", "src/cli.zig", "src/provider.zig", "src/provider_output.zig", "src/server.zig", "src/store.zig",
		"tests/integration/dispatch_integration.py", "tests/qualification/execution-service/main.go", "tests/qualification/execution-service/main_test.go",
	} {
		hash, hashErr := measurement.SHA256File(filepath.Join(rootPath, name))
		if hashErr != nil {
			rootErr = errors.Join(rootErr, hashErr)
			continue
		}
		sourceHashes[name] = hash
	}
	if rootErr != nil {
		status = "failed"
	}
	provenanceError := any(nil)
	if joined := errors.Join(pErr, rootErr); joined != nil {
		provenanceError = joined.Error()
	}
	report := map[string]any{"format": "rui-execution-service-v1-go", "scope": "issues #238/#244/#245 production execution-service qualification", "status": status, "artifacts": root, "cases": rows, "provenance": provenance, "provenance_error": provenanceError, "source_sha256": sourceHashes, "structural_memory": map[string]any{"shared_preparation_owners": 1, "per_active_slot_preparation_window_bytes": 0, "payload_storage": "charged disk-backed scratch; selected history and replay bytes do not create a second resident payload queue", "calculation": "(execution slot size - preceding 1264-byte Linux x86-64 slot) * configured capacity + one readiness-reported shared Preparation workspace"}, "limits": []string{"deterministic loopback HTTP does not qualify a live provider", "unavailable metrics are invalid, never zero or passing", "monotonic Host traces are authority; client scheduling and polling are not", "only the mixed-bash case includes a Bash owner and deadline; factorial cases isolate their named input dimension"}}
	if e := measurement.WriteJSON(*output, report); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	if status == "failed" {
		os.Exit(1)
	}
}
