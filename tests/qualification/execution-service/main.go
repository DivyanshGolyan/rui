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
	Phase       string `json:"rui_test_phase"`
	At          string `json:"at_ns"`
	Operation   string `json:"operation"`
	Action      string `json:"action"`
	ControlKey  string `json:"control_key"`
	Deadline    string `json:"deadline_ns"`
	StoreQueued string `json:"store_queued_at_ns"`
	QueueWait   string `json:"queue_wait_ns"`
	at          uint64
	deadline    uint64
	accepted    uint64
}

type interval struct {
	Kind       string `json:"kind"`
	Subject    string `json:"subject"`
	StartNS    uint64 `json:"start_ns"`
	EndNS      uint64 `json:"end_ns"`
	DurationNS uint64 `json:"duration_ns"`
}

type metrics struct {
	Status                   string     `json:"status"`
	MaxLifecycleServiceGapNS *uint64    `json:"max_lifecycle_service_gap_ns"`
	LargestUninterruptedNS   *uint64    `json:"largest_uninterrupted_work_interval_ns"`
	StopToEffectNS           []uint64   `json:"stop_to_effect_ns"`
	DeadlineToServiceNS      []uint64   `json:"deadline_to_service_ns"`
	Preparation              []interval `json:"preparation_intervals"`
	Validation               []interval `json:"validation_intervals"`
	Settlement               []interval `json:"settlement_intervals"`
	Invalid                  []string   `json:"invalid_metrics,omitempty"`
}

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

func deriveMetrics(events []traceEvent) metrics {
	m := metrics{Status: "passed", StopToEffectNS: []uint64{}, DeadlineToServiceNS: []uint64{}, Preparation: []interval{}, Validation: []interval{}, Settlement: []interval{}}
	type start struct {
		at    uint64
		phase string
	}
	starts := map[string]start{}
	accepted := map[string]uint64{}
	serviceTimes := []uint64{}
	var maxWork uint64
	for _, e := range events {
		if e.Phase == "control_timing" && e.ControlKey != "" {
			accepted[e.ControlKey] = e.accepted
		}
		if e.at == 0 {
			continue
		}
		switch e.Phase {
		case "effect_stop_requested":
			at, ok := accepted[e.ControlKey]
			if !ok || e.at < at {
				m.Invalid = append(m.Invalid, "stop_to_effect:"+e.ControlKey)
			} else {
				m.StopToEffectNS = append(m.StopToEffectNS, e.at-at)
			}
			serviceTimes = append(serviceTimes, e.at)
		case "bash_deadline_serviced":
			if e.deadline == 0 || e.at < e.deadline {
				m.Invalid = append(m.Invalid, "deadline_to_service:"+subject(e))
			} else {
				m.DeadlineToServiceNS = append(m.DeadlineToServiceNS, e.at-e.deadline)
			}
			serviceTimes = append(serviceTimes, e.at)
		case "preparation_advance_started", "validation_started", "settlement_lock_requested":
			key := subject(e) + ":" + e.Phase
			if _, exists := starts[key]; exists {
				m.Invalid = append(m.Invalid, "duplicate_start:"+key)
			} else {
				starts[key] = start{e.at, e.Phase}
			}
			if e.Phase == "preparation_advance_started" {
				serviceTimes = append(serviceTimes, e.at)
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
	sort.Slice(serviceTimes, func(i, j int) bool { return serviceTimes[i] < serviceTimes[j] })
	if len(serviceTimes) >= 2 {
		var gap uint64
		for i := 1; i < len(serviceTimes); i++ {
			if d := serviceTimes[i] - serviceTimes[i-1]; d > gap {
				gap = d
			}
		}
		m.MaxLifecycleServiceGapNS = &gap
	} else {
		m.Invalid = append(m.Invalid, "max_lifecycle_service_gap")
	}
	if len(m.Preparation)+len(m.Validation)+len(m.Settlement) > 0 {
		m.LargestUninterruptedNS = &maxWork
	} else {
		m.Invalid = append(m.Invalid, "largest_uninterrupted_work_interval")
	}
	if len(m.StopToEffectNS) == 0 {
		m.Invalid = append(m.Invalid, "stop_to_effect")
	}
	if len(m.DeadlineToServiceNS) == 0 {
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

type scenario struct {
	Name           string `json:"name"`
	Burst          int    `json:"ready_completion_burst"`
	HistoryBytes   int    `json:"selected_history_bytes"`
	HistoryItems   int    `json:"selected_history_items"`
	RetainedBytes  int    `json:"retained_replay_field_bytes"`
	DiscardedBytes int    `json:"discarded_replay_field_bytes"`
	ActiveOwners   int    `json:"active_owner_population"`
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
	host, e := measurement.StartHost(binary, store, ep.URL(), s.ActiveOwners, stderr, d, "--test-phase-trace")
	if e != nil {
		return nil, e
	}
	defer func() { err = errors.Join(err, host.Stop(measurement.TeardownAllowance)) }()
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
	ep.arm()
	burst := min(s.Burst, s.ActiveOwners)
	for i := 0; i < burst; i++ {
		if e = client.Message(fmt.Sprintf("burst-%d", i), fmt.Sprintf("execution/%d", i), "burst"); e != nil {
			return nil, e
		}
	}
	if e = ep.wait(burst, d); e != nil {
		return nil, e
	}
	ep.fire()
	for i := 0; i < burst; i++ {
		if _, e = client.WaitResult(fmt.Sprintf("burst-%d", i)); e != nil {
			return nil, e
		}
	}
	if e = host.Stop(measurement.TeardownAllowance); e != nil {
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
	events = finalOperationEvents(events, burst)
	digest := sha256.Sum256(data)
	m := deriveMetrics(events)
	return map[string]any{"parameters": s, "status": m.Status, "metrics": m, "trace_events": len(events), "trace_sha256": hex.EncodeToString(digest[:]), "unrelated_bash_owner": map[string]any{"status": "unavailable", "reason": "public CLI cannot independently admit an unrelated Bash Action without first deriving a provider Tool Call; fabricating durable rows would not be production-path authority"}}, nil
}

func main() {
	output := flag.String("output", "execution-service-results.json", "result JSON")
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
	scenarios := []scenario{{"baseline", 1, 1024, 1, 64, 64, 1}, {"completion-burst", 8, 1024, 1, 64, 64, 8}, {"history-bytes", 1, 256 * 1024, 1, 64, 64, 1}, {"history-items", 1, 64 * 1024, 16, 64, 64, 1}, {"retained-field", 1, 1024, 1, 256 * 1024, 64, 1}, {"discarded-field", 1, 1024, 1, 64, 256 * 1024, 1}, {"active-owners", 1, 1024, 1, 64, 64, 8}}
	rows := []map[string]any{}
	status := "passed"
	for _, s := range scenarios {
		row, e := runScenario(binary, root, s)
		if e != nil {
			row = map[string]any{"parameters": s, "status": "failed", "error": e.Error()}
			status = "failed"
		}
		rows = append(rows, row)
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
	for _, name := range []string{"build.zig", "src/server.zig", "src/provider.zig", "tests/qualification/execution-service/main.go", "tests/qualification/execution-service/main_test.go"} {
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
	report := map[string]any{"format": "rui-execution-service-v1-go", "scope": "issues #238/#244/#245 production execution-service qualification", "status": status, "artifacts": root, "cases": rows, "provenance": provenance, "provenance_error": provenanceError, "source_sha256": sourceHashes, "structural_memory": map[string]any{"shared_preparation_owners": 1, "preparation_advance_window_bytes": 16 * 1024, "per_active_slot_preparation_window_bytes": 0, "known_window_total_bytes": 1 * 16 * 1024, "opaque_owner_storage": "not externally measurable from the production binary and therefore not guessed", "payload_storage": "charged disk-backed scratch; selected history and replay bytes do not create a second resident payload queue", "calculation": "1 shared owner * 16 KiB advance window + active owners * 0 per-slot preparation windows = 16 KiB known window storage"}, "limits": []string{"deterministic loopback HTTP does not qualify a live provider", "unavailable metrics are invalid, never zero or passing", "monotonic Host traces are authority; client scheduling and polling are not", "Bash coexistence is explicitly unavailable through the public fixture path"}}
	if e := measurement.WriteJSON(*output, report); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	if status == "failed" {
		os.Exit(1)
	}
}
