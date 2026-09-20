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
	"syscall"
	"time"

	"rui.local/qualification/measurement"
)

type scenario struct {
	Name            string `json:"name"`
	Mode            string `json:"mode"`
	Capacity        int    `json:"active_capacity"`
	Burst           int    `json:"completion_burst"`
	HistoryBytes    int    `json:"history_bytes"`
	HistoryTurns    int    `json:"history_turns"`
	RetainedBytes   int    `json:"retained_field_bytes"`
	DiscardedBytes  int    `json:"discarded_field_bytes"`
	ResponseBytes   int    `json:"response_retained_field_bytes"`
	RequireDeadline bool   `json:"require_deadline_overlap"`
}

type invalidEvidence struct{ reason string }

func (e invalidEvidence) Error() string { return e.reason }
func invalid(err error) error           { return invalidEvidence{err.Error()} }

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
		"stop_to_effect_ns":                  value.StopToEffectNS, "deadline_to_service_ns": value.DeadlineToServiceNS,
		"preparation_advances": intervalSummary(value.Preparation), "preparation_lifetimes": intervalSummary(value.PreparationLifetime),
		"validation": intervalSummary(value.Validation), "settlement": intervalSummary(value.Settlement),
		"settlement_queue": intervalSummary(value.SettlementQueue), "settlement_service": intervalSummary(value.SettlementService),
		"service_interval_count":                      len(value.Service),
		"max_native_completions_queued_after_removal": value.MaxNativeCompletionsAfter,
		"invalid_metrics":                             value.Invalid,
	}
}

func summarizeRows(rows []map[string]any) []map[string]any {
	summary := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		selected := map[string]any{}
		for _, key := range []string{"parameters", "status", "error", "overlap", "resources", "trace_sha256", "trace_events", "trace_commit_sequence", "workload_bindings", "stop_binding", "bash_action", "service_interval_scope"} {
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
	return measurement.WriteJSON(path, summary)
}

func readEvents(path string, live bool) ([]traceEvent, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if stat.Size() > maxTraceBytes {
		return nil, errors.New("trace collection capacity exceeded")
	}
	// Read a bounded snapshot, including a concurrently appended tail only up
	// to the observed size. Live polling can ignore one incomplete final line;
	// final evidence cannot accept a truncated record.
	data := make([]byte, stat.Size())
	n, err := f.ReadAt(data, 0)
	if err != nil && n != len(data) {
		return nil, err
	}
	if live {
		if i := bytes.LastIndexByte(data, '\n'); i >= 0 {
			data = data[:i+1]
		} else {
			return nil, nil
		}
	}
	return parseTraces(data)
}
func readRecentEvents(path string) ([]traceEvent, error) {
	const window = 4 * 1024 * 1024
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return nil, err
	}
	start := max(int64(0), stat.Size()-window)
	data := make([]byte, stat.Size()-start)
	n, err := f.ReadAt(data, start)
	if err != nil && n != len(data) {
		return nil, err
	}
	if start != 0 {
		newline := bytes.IndexByte(data, '\n')
		if newline < 0 {
			return nil, nil
		}
		data = data[newline+1:]
	}
	if newline := bytes.LastIndexByte(data, '\n'); newline >= 0 {
		data = data[:newline+1]
	} else {
		return nil, nil
	}
	events := []traceEvent{}
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if !bytes.HasPrefix(line, []byte(`{"rui_test_phase"`)) {
			continue
		}
		var event traceEvent
		if err := json.Unmarshal(line, &event); err != nil {
			return nil, fmt.Errorf("malformed live trace: %w", err)
		}
		if event.TraceLost {
			return nil, errors.New("producer trace loss")
		}
		if event.AtText != "" {
			event.At, err = uintField(event.AtText, "at_ns")
			if err != nil {
				return nil, err
			}
		}
		if event.SequenceText != "" {
			event.Sequence, err = uintField(event.SequenceText, "sequence")
			if err != nil {
				return nil, err
			}
		}
		if event.QueuedAfterText != "" {
			event.QueuedAfter, err = uintField(event.QueuedAfterText, "queued_after")
			if err != nil {
				return nil, err
			}
		}
		events = append(events, event)
	}
	return events, nil
}
func waitEvent(path string, d measurement.Deadline, predicate func(traceEvent) bool) (traceEvent, error) {
	var found traceEvent
	err := measurement.WaitFor(d, time.Millisecond, "owner-visible event", func() (bool, error) {
		events, e := readRecentEvents(path)
		if e != nil {
			return false, e
		}
		for _, event := range events {
			if predicate(event) {
				found = event
				return true, nil
			}
		}
		return false, nil
	})
	return found, err
}
func observeID(client measurement.Client, key string, tracePath string) (executionID, error) {
	var id executionID
	err := measurement.WaitFor(client.Deadline, time.Millisecond, "processing binding", func() (bool, error) {
		v, e := client.Observe(key)
		if e != nil {
			return false, e
		}
		op, ok := measurement.StringField(v, "processing", "operation")
		if !ok {
			return false, nil
		}
		attempt, ok := measurement.StringField(v, "processing", "attempt")
		if !ok {
			return false, nil
		}
		turn, ok := measurement.StringField(v, "processing", "turn")
		if !ok {
			return false, nil
		}
		events, e := readRecentEvents(tracePath)
		if e != nil {
			return false, e
		}
		for _, event := range events {
			if event.Operation == op && event.Attempt == attempt && event.Turn == turn && event.Action == "" {
				id = event.executionID
				return id.valid(), nil
			}
		}
		return false, nil
	})
	return id, err
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
func expectCancelled(c measurement.Client, key string) error {
	v, e := c.WaitResult(key)
	if e != nil {
		return e
	}
	state, ok := measurement.StringField(v, "result", "status")
	if !ok || state != "cancelled" {
		return fmt.Errorf("%s did not retain its cancelled outcome: %v", key, v)
	}
	return nil
}

type sessionStopUnixRequest struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Key     string `json:"key"`
	Session string `json:"session"`
}

func sessionStopUnixValue(store, key, session string) sessionStopUnixRequest {
	return sessionStopUnixRequest{"1", "session_stop", store, key, session}
}

func stopSessionDirect(c measurement.Client, host *measurement.Host, socket, key, session string) error {
	store, err := host.CanonicalStore()
	if err != nil {
		return err
	}
	request := sessionStopUnixValue(store, key, session)
	var reply map[string]any
	if err := measurement.ExchangeUnix(c.Deadline, socket, "/v1/control/session-stop", request, &reply); err != nil {
		return err
	}
	status, ok := measurement.StringField(reply, "answer", "status")
	if !ok || status != "accepted" {
		return fmt.Errorf("session stop was not accepted: %v", reply)
	}
	return nil
}
func waitCount(ep *endpoint, text string, n int, d measurement.Deadline) error {
	return measurement.WaitFor(d, time.Millisecond, "complete request receipt", func() (bool, error) {
		count := ep.count(text)
		if count > n {
			return false, errors.New("duplicate provider request")
		}
		return count == n, nil
	})
}
func waitPrimed(ep *endpoint, text string, d measurement.Deadline) error {
	return measurement.WaitFor(d, time.Millisecond, "response prefix delivery", func() (bool, error) {
		return ep.isPrimed(text), nil
	})
}
func inspectWorkInFlight(v map[string]any) bool {
	status, ok := measurement.StringField(v, "work", "status")
	return ok && status == "in_flight"
}

func armSkipGate(path string) error {
	return os.WriteFile(path, nil, 0o600)
}

func releaseSkipGate(path string) error {
	err := os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func createParkGate(path string) (*os.File, error) {
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0)
}

func releaseParkGate(keeper *os.File) error {
	if keeper == nil {
		return nil
	}
	_, err := keeper.Write([]byte{1})
	return err
}

func createCommandFIFO(path string) (*os.File, error) {
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_RDWR, 0)
}

func ownerStillHeld(events []traceEvent, id executionID) bool {
	live := false
	for _, event := range events {
		if event.executionID != id {
			continue
		}
		switch event.Phase {
		case "transport_handoff_committed", "bash_handoff_committed":
			live = true
		case "cleanup_completed", "provider_completion_serviced":
			live = false
		}
	}
	return live
}

func awaitOccupied(c measurement.Client, n int, owners []executionID, tracePath string) error {
	var last map[string]any
	err := measurement.WaitFor(c.Deadline, time.Millisecond, fmt.Sprintf("occupied population %d", n), func() (bool, error) {
		v, e := c.Inspect("execution/stop")
		if e != nil {
			return false, e
		}
		last = v
		occupied, ok := measurement.IntStringField(v, "execution", "custody_occupied")
		if !ok {
			return false, errors.New("missing resource observation")
		}
		if occupied != uint64(n) {
			return false, nil
		}
		if !inspectWorkInFlight(v) {
			return false, invalidEvidence{fmt.Sprintf("occupied %d without live stop-target work: %v", n, v)}
		}
		events, e := readRecentEvents(tracePath)
		if e != nil {
			return false, e
		}
		for _, id := range owners {
			if !ownerStillHeld(events, id) {
				return false, invalidEvidence{fmt.Sprintf("occupied %d after controlled owner %v left: %v", n, id, v)}
			}
		}
		return true, nil
	})
	if err != nil {
		if _, ok := err.(invalidEvidence); ok {
			return err
		}
		if last != nil {
			return invalidEvidence{fmt.Sprintf("required occupied population %d was not observed: %v", n, last)}
		}
		return err
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
func scopeService(m *metrics, p overlapProof) {
	inside := func(values []interval) []interval {
		selected := values[:0]
		for _, span := range values {
			if span.EndNS > p.WorkStartNS && span.StartNS < p.WorkEndNS {
				selected = append(selected, span)
			}
		}
		return selected
	}
	m.Preparation = inside(m.Preparation)
	m.PreparationLifetime = inside(m.PreparationLifetime)
	m.Validation = inside(m.Validation)
	m.Settlement = inside(m.Settlement)
	m.SettlementQueue = inside(m.SettlementQueue)
	m.SettlementService = inside(m.SettlementService)
	selected := []serviceInterval{}
	var gap, work uint64
	for _, span := range m.Service {
		if span.EndNS > p.WorkStartNS && span.StartNS < p.WorkEndNS {
			selected = append(selected, span)
			gap = max(gap, span.EndNS-span.StartNS)
			work = max(work, span.WorkNS)
		}
	}
	m.Service = selected
	if len(selected) == 0 {
		m.Status = "invalid"
		m.Invalid = append(m.Invalid, "no_service_interval_intersecting_workload")
		return
	}
	m.MaxLifecycleServiceGapNS = &gap
	m.LargestUninterruptedNS = &work
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
	completionGate := filepath.Join(dir, "completion.skip")
	preparationGate := filepath.Join(dir, "preparation.skip")
	handoffPath := filepath.Join(dir, "handoff.fifo")
	stopFifoPath := filepath.Join(dir, "stop.fifo")
	deadlineFifoPath := filepath.Join(dir, "deadline.fifo")
	hostArgs := []string{
		"--test-execution-service-boundaries",
		"--test-completion-consumption-gate-path", completionGate,
		"--test-preparation-advance-gate-path", preparationGate,
		"--test-bash-handoff-gate-path", handoffPath,
	}
	if !s.RequireDeadline {
		hostArgs = append([]string{"--bash-timeout-ms", "600000"}, hostArgs...)
	}
	host, err := measurement.StartHost(
		binary, store, ep.URL(), s.Capacity, tracePath, d,
		hostArgs...,
	)
	if err != nil {
		return nil, err
	}
	var handoffKeeper, stopFifo, deadlineFifo *os.File
	defer func() {
		err = errors.Join(err, releaseSkipGate(completionGate), releaseSkipGate(preparationGate), releaseParkGate(handoffKeeper))
		if handoffKeeper != nil {
			handoffKeeper.Close()
		}
		if stopFifo != nil {
			stopFifo.Close()
		}
		if deadlineFifo != nil {
			deadlineFifo.Close()
		}
	}()
	stopped := false
	defer func() {
		if !stopped {
			err = errors.Join(err, host.Stop(measurement.TeardownAllowance))
		}
	}()
	c := measurement.Client{Binary: binary, Artifacts: dir, Store: store, Deadline: d}
	row = map[string]any{"parameters": s, "trace_path": tracePath, "status": "failed"}

	// Every target is configured with no tools. The independent fixture owns
	// both the complete expected request bytes and the expected saved answer.
	targetInputs := [][]byte{}
	if err = c.Configure("target-config", "execution/target", "--tools", "none"); err != nil {
		return row, err
	}
	for i := 0; i < s.HistoryTurns; i++ {
		text := fmt.Sprintf("history-%d:", i) + strings.Repeat("h", s.HistoryBytes/max(1, s.HistoryTurns))
		targetInputs = append(targetInputs, userItem(text))
		retained, discarded := 64, 64
		if i == s.HistoryTurns-1 {
			retained, discarded = s.RetainedBytes, s.DiscardedBytes
		}
		response, replay := answerSSE(fmt.Sprintf("history-%d", i), "history-ok", retained, discarded)
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
	if err = awaitDrain(c, "execution/target"); err != nil {
		return row, err
	}

	workCount := 1
	if s.Mode == "completion" {
		workCount = s.Burst
	}
	fixedOwners := 1 // Stop target S is a live Bash in its own Session.
	if s.RequireDeadline {
		fixedOwners++ // Deadline owner D is independent of S and the selected work.
	}
	fillers := s.Capacity - workCount - fixedOwners
	if fillers < 0 {
		return row, errors.New("scenario exceeds active capacity")
	}
	stopFifo, err = createCommandFIFO(stopFifoPath)
	if err != nil {
		return row, err
	}
	startBash := func(session, message, name, cmd string, timeoutMs *int, continuation bool) (string, traceEvent, error) {
		plan := &requestPlan{Response: bashSSE(name, cmd, timeoutMs)}
		ep.add(message, plan)
		if continuation {
			payload, _ := answerSSE(name+"-final", name+"-final-ok", 64, 64)
			ep.add(message, &requestPlan{Response: payload, BashContinuation: true})
		}
		if e := c.Configure(name+"-config", session, "--tools", "bash"); e != nil {
			return "", traceEvent{}, e
		}
		if e := c.Message(name+"-message", session, message); e != nil {
			return "", traceEvent{}, e
		}
		action, waitErr := c.WaitAction(session)
		if waitErr != nil {
			return "", traceEvent{}, waitErr
		}
		return action, traceEvent{}, nil
	}
	launchAllowed := func(session, key, action string) (traceEvent, error) {
		if e := c.AllowAction(key, session, action); e != nil {
			return traceEvent{}, e
		}
		return waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "bash_handoff_committed" && e.Action == action
		})
	}
	stopAction, _, err := startBash("execution/stop", "stop-owner", "stop", "cat "+stopFifoPath, nil, false)
	if err != nil {
		return row, err
	}
	stopStart, err := launchAllowed("execution/stop", "stop-allow", stopAction)
	if err != nil {
		return row, invalid(err)
	}
	stopID := stopStart.executionID
	if !stopID.valid() {
		return row, invalid(errors.New("stop target launched without complete execution identity"))
	}
	fillerIDs := []executionID{}
	for i := 0; i < fillers; i++ {
		text := fmt.Sprintf("filler-%d", i)
		payload, _ := answerSSE(text, "filler-ok", 64, 64)
		ep.add(text, &requestPlan{Expected: wireRequest([][]byte{userItem(text)}), Response: payload, Group: "fillers"})
		if err = c.Submit(text, "execution/"+text, text); err != nil {
			return row, err
		}
		if err = waitCount(ep, text, 1, d); err != nil {
			return row, err
		}
		id, e := observeID(c, text, tracePath)
		if e != nil {
			return row, e
		}
		fillerIDs = append(fillerIDs, id)
	}

	workIDs := []executionID{}
	workKeys := []string{}
	submitWork := func(i int) error {
		key := fmt.Sprintf("work-%d", i)
		session := "execution/target"
		input := targetInputs
		if i != 0 {
			session = "execution/" + key
			input = nil
			if e := c.Configure(key, session, "--tools", "none"); e != nil {
				return e
			}
		}
		input = append(append([][]byte{}, input...), userItem(key))
		payload, _ := answerSSE(key, "answer-"+key, s.ResponseBytes, 64)
		ep.add(key, &requestPlan{Expected: wireRequest(input), Response: payload, Group: "work"})
		if e := c.Message(key, session, key); e != nil {
			return e
		}
		workKeys = append(workKeys, key)
		return nil
	}
	if s.Mode == "completion" {
		for i := 0; i < workCount; i++ {
			if err = submitWork(i); err != nil {
				return row, err
			}
			if err = waitCount(ep, workKeys[i], 1, d); err != nil {
				return row, err
			}
			id, e := observeID(c, workKeys[i], tracePath)
			if e != nil {
				return row, e
			}
			workIDs = append(workIDs, id)
		}
		for _, key := range workKeys {
			if err = waitPrimed(ep, key, d); err != nil {
				return row, err
			}
		}
	}

	var deadlineAction string
	var deadlineStart traceEvent
	if s.RequireDeadline {
		deadlineFifo, err = createCommandFIFO(deadlineFifoPath)
		if err != nil {
			return row, err
		}
		timeoutMs := 1
		deadlineAction, _, err = startBash("execution/deadline", "deadline-owner", "deadline", "cat "+deadlineFifoPath, &timeoutMs, true)
		if err != nil {
			return row, err
		}
	}

	var target executionID
	owners := []executionID{stopID}
	owners = append(owners, fillerIDs...)
	owners = append(owners, workIDs...)
	occupied := s.Capacity
	if s.Mode == "preparation" || s.RequireDeadline {
		occupied--
	}
	if s.Mode == "preparation" {
		if err = awaitOccupied(c, occupied, owners, tracePath); err != nil {
			return row, err
		}
		recent, readErr := readRecentEvents(tracePath)
		if readErr != nil {
			return row, invalid(readErr)
		}
		var beforeSubmit uint64
		for _, event := range recent {
			beforeSubmit = max(beforeSubmit, event.Sequence)
		}
		if err = armSkipGate(preparationGate); err != nil {
			return row, err
		}
		if err = submitWork(0); err != nil {
			return row, err
		}
		started, waitErr := waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Sequence > beforeSubmit && e.Phase == "preparation_started"
		})
		if waitErr != nil {
			return row, invalid(waitErr)
		}
		target = started.executionID
		if !target.valid() {
			return row, invalid(errors.New("preparation started without complete execution identity"))
		}
		workIDs = append(workIDs, target)
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			if e.executionID == target && e.Phase == "preparation_completed" {
				return true
			}
			return e.Phase == "preparation_advance_held"
		}); err != nil {
			return row, invalid(err)
		}
		heldEvents, readErr := readRecentEvents(tracePath)
		if readErr != nil {
			return row, invalid(readErr)
		}
		held := false
		for _, event := range heldEvents {
			if event.Phase == "preparation_advance_held" {
				held = true
			}
			if event.executionID == target && event.Phase == "preparation_completed" && !held {
				return row, invalid(errors.New("preparation finished before the next-advance latch"))
			}
		}
		if !held {
			return row, invalid(errors.New("preparation advance latch was not observed"))
		}
	} else {
		if err = awaitOccupied(c, occupied, owners, tracePath); err != nil {
			return row, err
		}
		if err = armSkipGate(completionGate); err != nil {
			return row, err
		}
		ep.fire("work")
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "native_completions_unprocessed" && e.QueuedAfter >= uint64(len(workIDs))
		}); err != nil {
			return row, invalid(err)
		}
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "completion_consumption_held"
		}); err != nil {
			return row, invalid(err)
		}
	}

	if s.RequireDeadline {
		handoffKeeper, err = createParkGate(handoffPath)
		if err != nil {
			return row, err
		}
		deadlineStart, err = launchAllowed("execution/deadline", "deadline-allow", deadlineAction)
		if err != nil {
			return row, invalid(err)
		}
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "bash_handoff_parked" && e.Action == deadlineAction
		}); err != nil {
			return row, invalid(err)
		}
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "bash_deadline_established" && e.Action == deadlineAction
		}); err != nil {
			return row, invalid(err)
		}
	}

	if err = stopSessionDirect(c, host, host.Ready["socket"], "stop-during-work", "execution/stop"); err != nil {
		return row, err
	}
	if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
		return e.Phase == "control_durable_acceptance" && e.Subject == "stop-during-work"
	}); err != nil {
		return row, invalid(err)
	}
	if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
		return e.Phase == "control_hint_published" && e.Subject == "stop-during-work"
	}); err != nil {
		return row, invalid(err)
	}

	if err = releaseParkGate(handoffKeeper); err != nil {
		return row, err
	}
	if err = releaseSkipGate(completionGate); err != nil {
		return row, err
	}
	if err = releaseSkipGate(preparationGate); err != nil {
		return row, err
	}
	if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
		return e.Phase == "effect_stop_requested" && e.ControlKey == "stop-during-work" && e.executionID == stopID
	}); err != nil {
		return row, invalid(err)
	}
	if s.RequireDeadline {
		if _, err = waitEvent(tracePath, d, func(e traceEvent) bool {
			return e.Phase == "bash_deadline_serviced" && e.Action == deadlineAction
		}); err != nil {
			return row, invalid(err)
		}
	}
	ep.fire("work")
	for _, key := range workKeys {
		if err = expectAnswer(c, key, "answer-"+key); err != nil {
			return row, err
		}
	}
	if err = expectCancelled(c, "stop-message"); err != nil {
		return row, err
	}
	if s.RequireDeadline {
		if err = expectAnswer(c, "deadline-message", "deadline-final-ok"); err != nil {
			return row, err
		}
	}
	ep.fire("fillers")
	for i := 0; i < fillers; i++ {
		if err = expectAnswer(c, fmt.Sprintf("filler-%d", i), "filler-ok"); err != nil {
			return row, err
		}
	}
	if err = awaitDrain(c, "execution/target"); err != nil {
		return row, err
	}
	if err = awaitDrain(c, "execution/stop"); err != nil {
		return row, err
	}
	if s.RequireDeadline {
		if err = awaitDrain(c, "execution/deadline"); err != nil {
			return row, err
		}
	}
	// Require a service boundary after the last measured preparation or
	// completion, rather than accepting a stream truncated before that gap.
	events, e := readEvents(tracePath, true)
	if e != nil {
		return row, invalid(e)
	}
	lastWork := uint64(0)
	lastEvidence := uint64(0)
	for _, event := range events {
		for _, id := range workIDs {
			if event.executionID == id && (event.Phase == "provider_completion_serviced" || event.Phase == "preparation_completed") {
				lastWork = max(lastWork, event.At)
			}
		}
		if event.executionID == stopID && event.Phase == "effect_stop_requested" && event.ControlKey == "stop-during-work" {
			lastEvidence = max(lastEvidence, event.At)
		}
		if event.Action == deadlineAction && (event.Phase == "cleanup_completed" || event.Phase == "bash_deadline_serviced") {
			lastEvidence = max(lastEvidence, event.At)
		}
		if event.Phase == "inspection_captured" && (event.Subject == "execution/target" || event.Subject == "execution/stop" || event.Subject == "execution/deadline") {
			lastEvidence = max(lastEvidence, event.At)
		}
	}
	if lastWork == 0 || lastEvidence == 0 {
		return row, invalid(errors.New("measured work or Bash/control completion evidence is missing"))
	}
	lastEvidence = max(lastEvidence, lastWork)
	traceCommit, commitErr := waitEvent(tracePath, d, func(e traceEvent) bool {
		return e.Phase == "lifecycle_boundary" && e.At > lastEvidence
	})
	if commitErr != nil {
		return row, invalid(commitErr)
	}
	if traceCommit.Sequence == 0 || traceCommit.TraceLost {
		return row, invalid(errors.New("invalid trace commitment"))
	}
	row["trace_commit_sequence"] = traceCommit.Sequence
	if traceCommit.At <= lastEvidence {
		return row, invalid(errors.New("trace commitment does not cover measured work"))
	}
	if err = ep.audit(); err != nil {
		return row, err
	}
	err = host.Stop(measurement.TeardownAllowance)
	stopped = true
	if err != nil {
		return row, err
	}
	events, err = readEvents(tracePath, false)
	if err != nil {
		return row, invalid(err)
	}
	committed := events[:0]
	commitFound := false
	for _, event := range events {
		if event.Sequence <= traceCommit.Sequence {
			committed = append(committed, event)
			commitFound = commitFound || event.Sequence == traceCommit.Sequence
		}
	}
	if !commitFound {
		return row, invalid(errors.New("trace commitment is absent from final collection"))
	}
	events = committed
	m := deriveMetrics(events, s.RequireDeadline)
	expectedNative := uint64(0)
	if s.Mode == "completion" {
		expectedNative = uint64(len(workIDs))
	}
	proof, e := proveReadyObligations(events, s.Mode, "stop-during-work", target, deadlineStart.executionID, workIDs, expectedNative, s.RequireDeadline)
	if e != nil {
		m.Status = "invalid"
		m.Invalid = append(m.Invalid, e.Error())
	} else {
		scopeService(&m, proof)
	}
	if s.RequireDeadline && !deadlineStart.executionID.valid() {
		m.Status = "invalid"
		m.Invalid = append(m.Invalid, "deadline Bash owner was not launched")
	}
	data, e := os.ReadFile(tracePath)
	if e != nil {
		return row, invalid(e)
	}
	sum := sha256.Sum256(data)
	slotBytes, e1 := strconv.Atoi(host.Ready["execution_slot_bytes"])
	prepBytes, e2 := strconv.Atoi(host.Ready["model_preparation_bytes"])
	if e1 != nil || e2 != nil {
		return row, invalid(errors.Join(e1, e2))
	}
	row["status"] = m.Status
	row["metrics"] = m
	row["overlap"] = proof
	row["trace_sha256"] = hex.EncodeToString(sum[:])
	row["trace_events"] = len(events)
	row["workload_bindings"] = workIDs
	row["stop_binding"] = stopID
	row["bash_action"] = deadlineAction
	row["resources"] = map[string]any{"custody_and_scratch_drained": true, "execution_slot_bytes": slotBytes, "shared_preparation_bytes": prepBytes, "whole_process_memory": "not measured by this runner"}
	row["service_interval_scope"] = "complete lifecycle intervals intersecting the measured workload after one-shot gate release; gated intervals are perturbed and not production latency"
	return row, nil
}

func main() {
	output := flag.String("output", "execution-service-results.json", "evidence output")
	selected := flag.String("case", "", "one named case; unavailable overlap is not retried")
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
	const mib = 1024 * 1024
	scenarios := []scenario{
		{"history-8m", "preparation", 10, 1, 8 * mib, 1, 64, 64, 64, false},
		{"history-32m", "preparation", 10, 1, 32 * mib, 1, 64, 64, 64, false},
		{"history-items", "preparation", 10, 1, 8 * mib, 64, 64, 64, 64, false},
		{"retained-4m", "preparation", 10, 1, 1024, 1, 4 * mib, 64, 64, false},
		{"retained-32m", "preparation", 10, 1, 1024, 1, 32 * mib, 64, 64, false},
		{"discarded-4m", "preparation", 10, 1, 1024, 1, 64, 4 * mib, 64, false},
		{"discarded-32m", "preparation", 10, 1, 1024, 1, 64, 32 * mib, 64, false},
		{"completion-2", "completion", 11, 2, 1024, 1, 64, 64, 512 * 1024, false},
		{"completion-8", "completion", 11, 8, 1024, 1, 64, 64, 512 * 1024, true},
		{"active-4", "preparation", 4, 1, 4 * mib, 1, 64, 64, 64, false},
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
			var bad invalidEvidence
			if errors.As(e, &bad) {
				row["status"] = "invalid"
			} else {
				row["status"] = "failed"
			}
			row["error"] = e.Error()
		}
		if row["status"] != "passed" {
			if row["status"] == "failed" {
				status = "failed"
			} else if status == "passed" {
				status = "invalid"
			}
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
			"src/server.zig", "src/provider.zig", "src/cli.zig",
			"tests/qualification/execution-service/main.go", "tests/qualification/execution-service/metrics.go",
			"tests/qualification/execution-service/fixture.go", "tests/qualification/execution-service/main_test.go",
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
	report := map[string]any{"format": "rui-execution-service-v3-go", "status": status, "artifacts": root, "cases": rows, "provenance": provenance, "source_sha256": sourceHashes, "limits": []string{"no automatic reruns or timing allowances conceal absent readiness", "gated intervals are perturbed and not production latency", "source/native validation and platform/resource qualification still require their owning gates", "loopback is not live-provider, TLS, power-loss, or whole-product qualification", "structural sizes are not whole-process footprint"}}
	if pErr != nil {
		report["provenance_error"] = pErr.Error()
	}
	if err = writeEvidence(*output, report, rows); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(exitCode(status))
}
