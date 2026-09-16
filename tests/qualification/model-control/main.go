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

const ordinaryClients = 10
const controlHeadroom = 2

type streamEndpoint struct {
	server      *http.Server
	listener    net.Listener
	mu          sync.Mutex
	requests    int
	disconnects int
	release     chan struct{}
}

func startStreamEndpoint() (*streamEndpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	e := &streamEndpoint{listener: listener, release: make(chan struct{})}
	e.server = &http.Server{Handler: http.HandlerFunc(e.serve)}
	go e.server.Serve(listener)
	return e, nil
}
func (e *streamEndpoint) serve(writer http.ResponseWriter, request *http.Request) {
	_, err := io.Copy(io.Discard, request.Body)
	if err != nil {
		return
	}
	e.mu.Lock()
	e.requests++
	e.mu.Unlock()
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("Connection", "close")
	writer.WriteHeader(200)
	controller := http.NewResponseController(writer)
	_ = controller.Flush()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-e.release:
			return
		case <-request.Context().Done():
			e.mu.Lock()
			e.disconnects++
			e.mu.Unlock()
			return
		case <-ticker.C:
			if _, err := io.WriteString(writer, ": keepalive\n\n"); err != nil {
				e.mu.Lock()
				e.disconnects++
				e.mu.Unlock()
				return
			}
			if err := controller.Flush(); err != nil {
				e.mu.Lock()
				e.disconnects++
				e.mu.Unlock()
				return
			}
		}
	}
}
func (e *streamEndpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *streamEndpoint) counts() (int, int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.requests, e.disconnects
}
func (e *streamEndpoint) Close() error {
	select {
	case <-e.release:
	default:
		close(e.release)
	}
	return e.server.Close()
}

func stopSession(client measurement.Client, key, session string) (map[string]any, error) {
	var reply map[string]any
	err := measurement.RunJSON(client.Deadline, &reply, client.Binary, "stop-session", "--store", client.Store, "--record", filepath.Join(client.Artifacts, key+".json"), "--key", key, "--session", session)
	return reply, err
}
func interrupt(client measurement.Client, key, session string, processing map[string]any) (map[string]any, error) {
	turn, turnOK := processing["turn"].(string)
	operation, operationOK := processing["operation"].(string)
	if !turnOK || !operationOK {
		return nil, fmt.Errorf("processing identity incomplete: %v", processing)
	}
	var reply map[string]any
	err := measurement.RunJSON(client.Deadline, &reply, client.Binary, "interrupt-model", "--store", client.Store, "--record", filepath.Join(client.Artifacts, key+".json"), "--key", key, "--session", session, "--turn", turn, "--operation", operation)
	return reply, err
}
func accepted(reply map[string]any) bool {
	value, ok := measurement.StringField(reply, "answer", "status")
	return ok && value == "accepted"
}
func p95(values []float64) float64 {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	return sorted[max(0, (95*len(sorted)+99)/100-1)]
}

func latencyStatus(limitMS float64, values ...float64) string {
	for _, value := range values {
		if value > limitMS {
			return "target_miss"
		}
	}
	return "passed"
}

func settlementQualificationStatus(overlapped bool, limitMS float64, values ...float64) string {
	if !overlapped {
		return "incomplete"
	}
	return latencyStatus(limitMS, values...)
}

func requireAcceptedIdleStop(reply map[string]any) error {
	status, ok := measurement.StringField(reply, "answer", "status")
	if !ok || status != "accepted" {
		return fmt.Errorf("idle stop was not accepted: %v", reply)
	}
	answer, ok := reply["answer"].(map[string]any)
	if !ok {
		return fmt.Errorf("idle stop answer missing: %v", reply)
	}
	selection, ok := answer["selection"].(map[string]any)
	if !ok {
		return fmt.Errorf("idle stop selection missing: %v", reply)
	}
	turn, exists := selection["turn"]
	if !exists || turn != nil {
		return fmt.Errorf("idle stop selection.turn was not explicit null: %v", reply)
	}
	return nil
}

func controlStatus(results ...map[string]any) string {
	for _, result := range results {
		if result["status"] == "failed" {
			return "failed"
		}
	}
	for _, result := range results {
		if result["status"] == "incomplete" {
			return "incomplete"
		}
	}
	for _, result := range results {
		if result["status"] == "target_miss" {
			return "target_miss"
		}
	}
	return "passed"
}

type expectedControlTiming struct {
	key  string
	kind string
}

type controlTimingEvidence struct {
	CommandKey        string `json:"command_key"`
	Kind              string `json:"kind"`
	StoreQueuedAtNS   string `json:"store_queued_at_ns"`
	LockAcquiredAtNS  string `json:"lock_acquired_at_ns"`
	StoreCompleteAtNS string `json:"store_complete_at_ns"`
	ReplyCompleteAtNS string `json:"reply_complete_at_ns"`
	QueueWaitNS       string `json:"queue_wait_ns"`
	StoreLockWaitNS   string `json:"store_lock_wait_ns"`
	StoreServiceNS    string `json:"store_service_ns"`
	PostCommitReplyNS string `json:"post_commit_reply_ns"`
	HostTotalNS       string `json:"host_total_ns"`
	storeQueued       uint64
	lockAcquired      uint64
	storeComplete     uint64
	replyComplete     uint64
}

func parseUintString(record map[string]any, field string) (string, uint64, error) {
	value, ok := record[field].(string)
	if !ok || value == "" {
		return "", 0, fmt.Errorf("%s missing string value", field)
	}
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return "", 0, fmt.Errorf("%s malformed: %q", field, value)
	}
	return value, parsed, nil
}

func parseControlTiming(record map[string]any) (controlTimingEvidence, error) {
	commandKey, keyOK := record["command_key"].(string)
	kind, kindOK := record["kind"].(string)
	if !keyOK || commandKey == "" || !kindOK || kind == "" {
		return controlTimingEvidence{}, fmt.Errorf("control timing identity incomplete: %v", record)
	}
	values := make([]string, 9)
	numbers := make([]uint64, 9)
	fields := []string{"store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns", "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns", "post_commit_reply_ns", "host_total_ns"}
	for index, field := range fields {
		value, number, err := parseUintString(record, field)
		if err != nil {
			return controlTimingEvidence{}, fmt.Errorf("control %q: %w", commandKey, err)
		}
		values[index], numbers[index] = value, number
	}
	queued, locked, complete, reply := numbers[0], numbers[1], numbers[2], numbers[3]
	if queued > locked || locked > complete || complete > reply {
		return controlTimingEvidence{}, fmt.Errorf("control %q timestamps out of order", commandKey)
	}
	if numbers[5] != locked-queued || numbers[6] != complete-locked || numbers[7] != reply-complete {
		return controlTimingEvidence{}, fmt.Errorf("control %q phase durations differ from timestamps", commandKey)
	}
	phaseTotal := numbers[4]
	for _, value := range numbers[5:8] {
		if ^uint64(0)-phaseTotal < value {
			return controlTimingEvidence{}, fmt.Errorf("control %q duration total overflow", commandKey)
		}
		phaseTotal += value
	}
	if numbers[8] != phaseTotal {
		return controlTimingEvidence{}, fmt.Errorf("control %q host total differs from phases", commandKey)
	}
	return controlTimingEvidence{
		CommandKey: commandKey, Kind: kind,
		StoreQueuedAtNS: values[0], LockAcquiredAtNS: values[1], StoreCompleteAtNS: values[2], ReplyCompleteAtNS: values[3],
		QueueWaitNS: values[4], StoreLockWaitNS: values[5], StoreServiceNS: values[6], PostCommitReplyNS: values[7], HostTotalNS: values[8],
		storeQueued: queued, lockAcquired: locked, storeComplete: complete, replyComplete: reply,
	}, nil
}

func parseControlTimings(records []map[string]any, expected []expectedControlTiming) ([]controlTimingEvidence, error) {
	byKey := make(map[string]controlTimingEvidence, len(records))
	for _, record := range records {
		timing, err := parseControlTiming(record)
		if err != nil {
			return nil, err
		}
		if _, exists := byKey[timing.CommandKey]; exists {
			return nil, fmt.Errorf("duplicate control timing for %q", timing.CommandKey)
		}
		byKey[timing.CommandKey] = timing
	}
	result := make([]controlTimingEvidence, 0, len(expected))
	for _, want := range expected {
		timing, ok := byKey[want.key]
		if !ok {
			return nil, fmt.Errorf("missing control timing for %q", want.key)
		}
		if timing.Kind != want.kind {
			return nil, fmt.Errorf("control %q kind %q, want %q", want.key, timing.Kind, want.kind)
		}
		result = append(result, timing)
		delete(byKey, want.key)
	}
	if len(byKey) != 0 {
		return nil, fmt.Errorf("unexpected control timing keys: %v", byKey)
	}
	return result, nil
}

func settlementOverlap(lockAcquiredAt, completeAt uint64, timings []controlTimingEvidence) (bool, error) {
	if lockAcquiredAt == 0 || completeAt < lockAcquiredAt {
		return false, fmt.Errorf("invalid settlement interval %d..%d", lockAcquiredAt, completeAt)
	}
	overlapped := false
	for _, timing := range timings {
		if timing.storeQueued < lockAcquiredAt {
			return false, fmt.Errorf("control %q queued before settlement lock acquisition", timing.CommandKey)
		}
		if timing.storeQueued < completeAt && completeAt < timing.lockAcquired {
			overlapped = true
		}
	}
	return overlapped, nil
}

func operationPhaseTimestamp(records []map[string]any, phase, operation string) (uint64, error) {
	if len(records) == 0 {
		return 0, fmt.Errorf("missing %s record for operation %q", phase, operation)
	}
	var timestamp uint64
	found := false
	for _, record := range records {
		recordOperation, ok := record["operation"].(string)
		if !ok || recordOperation != operation {
			return 0, fmt.Errorf("%s record has unexpected operation: %v", phase, record)
		}
		if found {
			return 0, fmt.Errorf("duplicate %s record for operation %q", phase, operation)
		}
		_, value, err := parseUintString(record, "at_ns")
		if err != nil {
			return 0, fmt.Errorf("%s operation %q: %w", phase, operation, err)
		}
		timestamp, found = value, true
	}
	return timestamp, nil
}

func sample(host *measurement.Host, directory, name string) (measurement.ProcessSample, error) {
	return measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-"+name+".txt"))
}
func delta(before, after measurement.ProcessSample) map[string]any {
	return map[string]any{"rss_bytes": int64(after.RSSBytes) - int64(before.RSSBytes), "virtual_bytes": int64(after.VirtualBytes) - int64(before.VirtualBytes), "physical_footprint_bytes": int64(after.Footprint.PhysicalBytes) - int64(before.Footprint.PhysicalBytes), "open_descriptor_rows": after.OpenDescriptorRows - before.OpenDescriptorRows}
}

func openPartial(socket string) (net.Conn, error) {
	connection, err := net.DialTimeout("unix", socket, 3*time.Second)
	if err != nil {
		return nil, err
	}
	_ = connection.SetWriteDeadline(time.Now().Add(3 * time.Second))
	_, err = io.WriteString(connection, "POST /v1/inspect-session HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 1024\r\nX-Rui-Wire-Version: 1\r\n\r\n{")
	if err != nil {
		connection.Close()
		return nil, err
	}
	_ = connection.SetDeadline(time.Time{})
	return connection, nil
}
func fillOrdinary(socket string) ([]net.Conn, error) {
	held := make([]net.Conn, 0, ordinaryClients)
	for len(held) < ordinaryClients {
		connection, err := openPartial(socket)
		if err != nil {
			for _, value := range held {
				value.Close()
			}
			return nil, err
		}
		held = append(held, connection)
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(time.Second)
	return held, nil
}
func closeAll(values []net.Conn) {
	for _, value := range values {
		_ = value.Close()
	}
}

func inspectCustodyZero(client measurement.Client, session string) (bool, error) {
	inspection, err := client.Inspect(session)
	if err != nil {
		return false, err
	}
	custody, custodyOK := measurement.IntStringField(inspection, "execution", "custody_occupied")
	scratch, scratchOK := measurement.IntStringField(inspection, "execution", "scratch_used_bytes")
	return custodyOK && scratchOK && custody == 0 && scratch == 0, nil
}

func headroom(binary, root, url string) (result map[string]any, resultError error) {
	directory := filepath.Join(root, "headroom")
	_ = os.Mkdir(directory, 0o700)
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(4 * time.Minute)
	host, err := measurement.StartHost(binary, store, url, 8, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	socket := host.Ready["socket"]
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	if err := client.Configure("headroom", "measure/headroom"); err != nil {
		return nil, err
	}
	idle, err := sample(host, directory, "idle")
	if err != nil {
		return nil, err
	}
	held, err := fillOrdinary(socket)
	if err != nil {
		return nil, err
	}
	defer closeAll(held)
	if err := ordinaryBusy(socket); err != nil {
		return nil, err
	}
	before, err := sample(host, directory, "before-controls")
	if err != nil {
		return nil, err
	}
	latencies := make([]float64, 0, 50)
	for index := range 50 {
		started := time.Now()
		reply, err := stopSession(client, fmt.Sprintf("headroom-stop-%d", index), "measure/headroom")
		if err != nil {
			return nil, err
		}
		latencies = append(latencies, float64(time.Since(started).Microseconds())/1000)
		if !accepted(reply) {
			return nil, fmt.Errorf("stop was not accepted: %v", reply)
		}
	}
	after, err := sample(host, directory, "after-controls")
	if err != nil {
		return nil, err
	}
	closeAll(held)
	held = nil
	time.Sleep(time.Second)
	drainedFirst, err := sample(host, directory, "drained-first")
	if err != nil {
		return nil, err
	}
	if drainedFirst.OpenDescriptorRows != idle.OpenDescriptorRows {
		return nil, fmt.Errorf("first drain retained %d descriptor rows over idle", drainedFirst.OpenDescriptorRows-idle.OpenDescriptorRows)
	}
	held, err = fillOrdinary(socket)
	if err != nil {
		return nil, err
	}
	if err := ordinaryBusy(socket); err != nil {
		return nil, err
	}
	secondSaturation, err := sample(host, directory, "second-saturation")
	if err != nil {
		return nil, err
	}
	closeAll(held)
	held = nil
	time.Sleep(time.Second)
	drainedSecond, err := sample(host, directory, "drained-second")
	if err != nil {
		return nil, err
	}
	if drainedSecond.OpenDescriptorRows != idle.OpenDescriptorRows {
		return nil, fmt.Errorf("second drain retained %d descriptor rows over idle", drainedSecond.OpenDescriptorRows-idle.OpenDescriptorRows)
	}
	p95MS := p95(latencies)
	return map[string]any{"scope": "two rounds of 10 ordinary clients stopped after partial request bodies", "status": latencyStatus(1000, p95MS), "ordinary_connections_per_round": ordinaryClients, "saturation_rounds": 2, "control_commands": len(latencies), "p95_acknowledgment_ms": p95MS, "maximum_acknowledgment_ms": slicesMax(latencies), "qualification_limit_ms": 1000, "idle": idle, "before_controls": before, "after_controls": after, "resource_delta_from_idle": delta(idle, before), "retained_after_first_drain": drainedFirst, "second_saturation_round": secondSaturation, "retained_after_second_drain": drainedSecond, "retained_delta_from_idle": delta(idle, drainedSecond), "second_drain_delta_from_first": delta(drainedFirst, drainedSecond)}, nil
}
func slicesMax(values []float64) float64 {
	maximum := values[0]
	for _, value := range values[1:] {
		if value > maximum {
			maximum = value
		}
	}
	return maximum
}

func activeCancellation(binary, root, url string, endpoint *streamEndpoint) (result map[string]any, resultError error) {
	const capacity = 100
	const measuredControls = 25
	directory := filepath.Join(root, "active")
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(4 * time.Minute)
	host, err := measurement.StartHost(binary, store, url, capacity, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	sessions := make([]string, capacity)
	keys := make([]string, capacity)
	for index := range capacity {
		sessions[index] = fmt.Sprintf("measure/active/%d", index)
		keys[index] = fmt.Sprintf("active-%d", index)
		if err := client.Submit(keys[index], sessions[index], keys[index]); err != nil {
			return nil, err
		}
	}
	// Refill after each measured cancellation, so every sample starts at 100
	// live transports rather than measuring a steadily declining population.
	waitFull := func() error {
		return measurement.WaitFor(deadline, 25*time.Millisecond, "100 live model streams", func() (bool, error) {
			requests, disconnects := endpoint.counts()
			if requests-disconnects != capacity {
				return false, nil
			}
			observation, err := client.Inspect(sessions[0])
			if err != nil {
				return false, err
			}
			occupied, ok := measurement.IntStringField(observation, "execution", "custody_occupied")
			return ok && occupied == capacity, nil
		})
	}
	if err := waitFull(); err != nil {
		return nil, err
	}
	before, err := sample(host, directory, "before-controls")
	if err != nil {
		return nil, err
	}
	stops := []float64{}
	samples := []map[string]any{}
	interruptionMS := 0.0
	for index := range measuredControls {
		if err := waitFull(); err != nil {
			return nil, err
		}
		observation, err := client.Observe(keys[index])
		if err != nil {
			return nil, err
		}
		processing, ok := observation["processing"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("processing identity unavailable: %v", observation)
		}
		requests, disconnects := endpoint.counts()
		if requests-disconnects != capacity {
			return nil, fmt.Errorf("live stream population changed before control: %d", requests-disconnects)
		}
		started := time.Now()
		var reply map[string]any
		kind := "session_stop"
		if index == 0 {
			kind = "model_interruption"
			reply, err = interrupt(client, "active-interrupt", sessions[index], processing)
		} else {
			reply, err = stopSession(client, fmt.Sprintf("active-stop-%d", index), sessions[index])
		}
		elapsed := float64(time.Since(started).Microseconds()) / 1000
		if err != nil || !accepted(reply) {
			return nil, fmt.Errorf("%s failed: %v: %w", kind, reply, err)
		}
		if index == 0 {
			interruptionMS = elapsed
		} else {
			stops = append(stops, elapsed)
		}
		samples = append(samples, map[string]any{"kind": kind, "active_streams_before": requests - disconnects, "acknowledgment_ms": elapsed})
		settled, err := client.WaitResult(keys[index])
		if err != nil {
			return nil, err
		}
		if status, _ := measurement.StringField(settled, "result", "status"); status != "cancelled" {
			return nil, fmt.Errorf("control did not cancel original work: %v", settled)
		}
		keys[index] = fmt.Sprintf("replacement-%d", index)
		if err := client.Message(keys[index], sessions[index], keys[index]); err != nil {
			return nil, err
		}
	}
	if err := waitFull(); err != nil {
		return nil, err
	}
	for index, session := range sessions {
		reply, err := stopSession(client, fmt.Sprintf("cleanup-stop-%d", index), session)
		if err != nil || !accepted(reply) {
			return nil, fmt.Errorf("cleanup stop failed: %v: %w", reply, err)
		}
	}
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "provider disconnects", func() (bool, error) { requests, disconnects := endpoint.counts(); return requests == disconnects, nil }); err != nil {
		return nil, err
	}
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "control cleanup", func() (bool, error) { return inspectCustodyZero(client, sessions[0]) }); err != nil {
		return nil, err
	}
	after, err := sample(host, directory, "after-cleanup")
	if err != nil {
		return nil, err
	}
	_, disconnects := endpoint.counts()
	stopP95 := p95(stops)
	return map[string]any{"status": latencyStatus(1000, interruptionMS, stopP95), "active_capacity": capacity, "active_model_streams": capacity, "control_samples": samples, "exact_interruption_acknowledgment_ms": interruptionMS, "session_stop_p95_acknowledgment_ms": stopP95, "qualification_limit_ms": 1000, "before_controls": before, "after_cleanup": after, "resource_delta_after_cleanup": delta(before, after), "provider_disconnects": disconnects}, nil
}

type successEndpoint struct {
	server      *http.Server
	listener    net.Listener
	mu          sync.Mutex
	requests    int
	release     chan struct{}
	answerBytes int
}

func startSuccessEndpoint(answerBytes int) (*successEndpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	endpoint := &successEndpoint{listener: listener, release: make(chan struct{}), answerBytes: answerBytes}
	endpoint.server = &http.Server{Handler: http.HandlerFunc(endpoint.serve)}
	go endpoint.server.Serve(listener)
	return endpoint, nil
}

func successfulSSE(index int, answer string) []byte {
	message := map[string]any{"type": "message", "id": fmt.Sprintf("message-%d", index), "status": "completed", "role": "assistant", "phase": "final_answer", "content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}}}
	events := []any{
		map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"type": "message", "id": message["id"]}},
		map[string]any{"type": "response.output_item.done", "output_index": 0, "item": message},
		map[string]any{"type": "response.completed", "response": map[string]any{"id": fmt.Sprintf("response-%d", index), "status": "completed", "model": "model-a", "output": []any{message}, "usage": map[string]int{"input_tokens": 7, "output_tokens": 11, "total_tokens": 18}}},
	}
	var result bytes.Buffer
	for _, event := range events {
		encoded, _ := json.Marshal(event)
		result.WriteString("event: response\ndata: ")
		result.Write(encoded)
		result.WriteString("\n\n")
	}
	return result.Bytes()
}

func (e *successEndpoint) serve(writer http.ResponseWriter, request *http.Request) {
	_, err := io.Copy(io.Discard, request.Body)
	if err != nil {
		return
	}
	e.mu.Lock()
	e.requests++
	index := e.requests
	e.mu.Unlock()
	select {
	case <-e.release:
	case <-request.Context().Done():
		return
	}
	marker := "RUI_STREAMED_ANSWER_MARKER"
	body := successfulSSE(index, marker)
	parts := bytes.Split(body, []byte(marker))
	if e.answerBytes == 0 || index != 1 {
		parts = [][]byte{successfulSSE(index, fmt.Sprintf("answer-%d", index))}
	}
	contentLength := 0
	for _, part := range parts {
		contentLength += len(part)
	}
	if len(parts) == 3 {
		contentLength += 2 * e.answerBytes
	}
	writer.Header().Set("Content-Type", "text/event-stream")
	writer.Header().Set("Content-Length", strconv.Itoa(contentLength))
	writer.Header().Set("OpenAI-Model", "model-a")
	writer.Header().Set("X-Request-Id", fmt.Sprintf("request-%d", index))
	writer.Header().Set("Connection", "close")
	writer.WriteHeader(200)
	chunk := bytes.Repeat([]byte{'x'}, 64*1024)
	for partIndex, part := range parts {
		if _, err := writer.Write(part); err != nil {
			return
		}
		if partIndex == len(parts)-1 {
			continue
		}
		for remaining := e.answerBytes; remaining > 0; {
			count := min(remaining, len(chunk))
			if _, err := writer.Write(chunk[:count]); err != nil {
				return
			}
			remaining -= count
		}
	}
}

func (e *successEndpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *successEndpoint) count() int  { e.mu.Lock(); defer e.mu.Unlock(); return e.requests }
func (e *successEndpoint) releaseAll() {
	select {
	case <-e.release:
	default:
		close(e.release)
	}
}
func (e *successEndpoint) Close() error { e.releaseAll(); return e.server.Close() }

func rawUnixRequest(socketPath, route string, body []byte, receiveBuffer int) (net.Conn, error) {
	connection, err := net.DialTimeout("unix", socketPath, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if receiveBuffer != 0 {
		if unixConnection, ok := connection.(*net.UnixConn); ok {
			if err := unixConnection.SetReadBuffer(receiveBuffer); err != nil {
				connection.Close()
				return nil, err
			}
		}
	}
	request := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n", route, len(body))
	if _, err := io.WriteString(connection, request); err != nil {
		connection.Close()
		return nil, err
	}
	if _, err := connection.Write(body); err != nil {
		connection.Close()
		return nil, err
	}
	return connection, nil
}

type preparedRequest struct {
	connection net.Conn
	request    []byte
}

func prepareUnixRequest(deadline measurement.Deadline, socketPath, route string, body []byte) (preparedRequest, error) {
	connection, err := net.DialTimeout("unix", socketPath, 5*time.Second)
	if err != nil {
		return preparedRequest{}, err
	}
	remaining, err := deadline.Remaining()
	if err != nil {
		connection.Close()
		return preparedRequest{}, err
	}
	if err := connection.SetDeadline(time.Now().Add(remaining)); err != nil {
		connection.Close()
		return preparedRequest{}, err
	}
	header := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n", route, len(body))
	return preparedRequest{connection: connection, request: append([]byte(header), body...)}, nil
}

func submitPreparedControls(prepared []preparedRequest) []controlResult {
	results := make([]controlResult, len(prepared))
	var group sync.WaitGroup
	group.Add(len(prepared))
	for index := range prepared {
		go func(index int) {
			defer group.Done()
			defer prepared[index].connection.Close()
			started := time.Now()
			if _, err := prepared[index].connection.Write(prepared[index].request); err != nil {
				results[index] = controlResult{index: index, err: err}
				return
			}
			request, _ := http.NewRequest(http.MethodPost, "http://local", nil)
			response, err := http.ReadResponse(bufio.NewReader(prepared[index].connection), request)
			if err != nil {
				results[index] = controlResult{index: index, err: err}
				return
			}
			body, readErr := io.ReadAll(response.Body)
			response.Body.Close()
			if readErr != nil {
				results[index] = controlResult{index: index, err: readErr}
				return
			}
			if response.StatusCode != http.StatusOK {
				results[index] = controlResult{index: index, err: fmt.Errorf("control returned %s: %s", response.Status, body)}
				return
			}
			var reply map[string]any
			if err := json.Unmarshal(body, &reply); err != nil {
				results[index] = controlResult{index: index, err: err}
				return
			}
			results[index] = controlResult{index: index, reply: reply, latencyMS: float64(time.Since(started).Microseconds()) / 1000}
		}(index)
	}
	group.Wait()
	return results
}

type inspectRequest struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Session string `json:"session"`
}
type readResultRequest struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Key     string `json:"key"`
}
type sessionStopRequest struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Key     string `json:"key"`
	Session string `json:"session"`
}
type interruptionTarget struct {
	Session   string `json:"session"`
	Turn      string `json:"turn"`
	Operation string `json:"operation"`
}
type modelInterruptionRequest struct {
	Version string             `json:"version"`
	Kind    string             `json:"kind"`
	Store   string             `json:"store"`
	Key     string             `json:"key"`
	Target  interruptionTarget `json:"target"`
}

func earlyResponse(connection net.Conn, wait time.Duration) (*http.Response, bool, error) {
	if err := connection.SetReadDeadline(time.Now().Add(wait)); err != nil {
		return nil, false, err
	}
	reader := bufio.NewReader(connection)
	_, err := reader.Peek(1)
	if networkError, ok := err.(net.Error); ok && networkError.Timeout() {
		_ = connection.SetReadDeadline(time.Time{})
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	request, _ := http.NewRequest(http.MethodPost, "http://local", nil)
	response, err := http.ReadResponse(reader, request)
	return response, true, err
}

func openInspections(socketPath, store, session string) ([]net.Conn, error) {
	body, err := json.Marshal(inspectRequest{Version: "1", Kind: "inspect_session", Store: store, Session: session})
	if err != nil {
		return nil, err
	}
	connections := make([]net.Conn, 0, ordinaryClients)
	for attempts := 0; len(connections) < ordinaryClients && attempts < ordinaryClients*5; attempts++ {
		connection, err := rawUnixRequest(socketPath, "/v1/inspect-session", body, 0)
		if err != nil {
			closeAll(connections)
			return nil, err
		}
		time.Sleep(10 * time.Millisecond)
		response, early, probeError := earlyResponse(connection, time.Millisecond)
		if probeError != nil {
			connection.Close()
			closeAll(connections)
			return nil, probeError
		}
		if !early {
			connections = append(connections, connection)
			continue
		}
		responseBody, _ := io.ReadAll(response.Body)
		response.Body.Close()
		connection.Close()
		if response.StatusCode != http.StatusServiceUnavailable {
			closeAll(connections)
			return nil, fmt.Errorf("inspection admission returned %s: %s", response.Status, responseBody)
		}
	}
	if len(connections) != ordinaryClients {
		closeAll(connections)
		return nil, fmt.Errorf("inspection admission stopped at %d", len(connections))
	}
	stable := make([]net.Conn, 0, len(connections))
	for _, connection := range connections {
		response, early, probeError := earlyResponse(connection, time.Millisecond)
		if probeError != nil {
			connection.Close()
			closeAll(stable)
			return nil, probeError
		}
		if !early {
			stable = append(stable, connection)
			continue
		}
		responseBody, _ := io.ReadAll(response.Body)
		response.Body.Close()
		connection.Close()
		closeAll(stable)
		return nil, fmt.Errorf("inspection completed before the final saturation sweep: %s: %s", response.Status, responseBody)
	}
	connections = stable
	return connections, nil
}

func drainResponses(connections []net.Conn, timeout time.Duration) error {
	errorsFound := make(chan error, len(connections))
	for _, connection := range connections {
		go func(connection net.Conn) {
			defer connection.Close()
			_ = connection.SetReadDeadline(time.Now().Add(timeout))
			request, _ := http.NewRequest(http.MethodPost, "http://local", nil)
			response, err := http.ReadResponse(bufio.NewReader(connection), request)
			if err == nil && response.StatusCode != 200 {
				err = fmt.Errorf("inspection returned %s", response.Status)
			}
			if err == nil {
				_, err = io.Copy(io.Discard, response.Body)
				response.Body.Close()
			}
			errorsFound <- err
		}(connection)
	}
	var result error
	for range connections {
		result = errors.Join(result, <-errorsFound)
	}
	return result
}

func phaseRecords(path, phase string) ([]map[string]any, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	result := []map[string]any{}
	scanner := bufio.NewScanner(file)
	buffer := make([]byte, 64*1024)
	scanner.Buffer(buffer, 1024*1024)
	for scanner.Scan() {
		var record map[string]any
		if json.Unmarshal(scanner.Bytes(), &record) == nil && record["rui_test_phase"] == phase {
			result = append(result, record)
		}
	}
	return result, scanner.Err()
}

func waitPhase(deadline measurement.Deadline, path, phase string, count int) ([]map[string]any, error) {
	var records []map[string]any
	err := measurement.WaitFor(deadline, 25*time.Millisecond, phase, func() (bool, error) {
		value, err := phaseRecords(path, phase)
		if err != nil {
			return false, err
		}
		records = value
		return len(records) >= count, nil
	})
	return records, err
}

type controlResult struct {
	index     int
	reply     map[string]any
	latencyMS float64
	err       error
}

func concurrentStops(client measurement.Client, sessions []string, processing map[string]any) []controlResult {
	start := make(chan struct{})
	results := make(chan controlResult, len(sessions))
	for index, session := range sessions {
		go func(index int, session string) {
			<-start
			started := time.Now()
			var reply map[string]any
			var err error
			if index == 0 && processing != nil {
				reply, err = interrupt(client, "settlement-later-interrupt", session, processing)
			} else {
				reply, err = stopSession(client, fmt.Sprintf("contention-stop-%d", index), session)
			}
			results <- controlResult{index: index, reply: reply, latencyMS: float64(time.Since(started).Microseconds()) / 1000, err: err}
		}(index, session)
	}
	close(start)
	answer := make([]controlResult, 0, len(sessions))
	for range sessions {
		answer = append(answer, <-results)
	}
	return answer
}

func controlFirst(binary, root string) (result map[string]any, resultError error) {
	directory := filepath.Join(root, "control-first")
	_ = os.Mkdir(directory, 0o700)
	endpoint, err := startSuccessEndpoint(0)
	if err != nil {
		return nil, err
	}
	defer endpoint.Close()
	deadline := measurement.NewDeadline(4 * time.Minute)
	store := filepath.Join(directory, "store")
	stderrPath := filepath.Join(directory, "host-stderr.log")
	host, err := measurement.StartHost(binary, store, endpoint.URL(), controlHeadroom, stderrPath, deadline, "--test-phase-trace", "--test-inspection-reply-delay-ms", "8000", "--test-before-result-delay-ms", "1200")
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	sessions := make([]string, controlHeadroom)
	for index := range controlHeadroom {
		sessions[index] = fmt.Sprintf("contention/%d", index)
		if err := client.Submit(fmt.Sprintf("contention-%d", index), sessions[index], fmt.Sprintf("contention %d", index)); err != nil {
			return nil, err
		}
	}
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "successful requests for both control places", func() (bool, error) { return endpoint.count() == controlHeadroom, nil }); err != nil {
		return nil, err
	}
	inspections, err := openInspections(host.Ready["socket"], store, sessions[0])
	if err != nil {
		return nil, err
	}
	defer closeAll(inspections)
	if _, err := waitPhase(deadline, stderrPath, "inspection_captured", ordinaryClients); err != nil {
		return nil, err
	}
	endpoint.releaseAll()
	if _, err := waitPhase(deadline, stderrPath, "sealed_before_settlement", 1); err != nil {
		return nil, err
	}
	controls := concurrentStops(client, sessions, nil)
	latencies := make([]float64, 0, controlHeadroom)
	for _, control := range controls {
		if control.err != nil || !accepted(control.reply) {
			return nil, fmt.Errorf("control-first stop failed: %v: %w", control.reply, control.err)
		}
		latencies = append(latencies, control.latencyMS)
	}
	if _, err := waitPhase(deadline, stderrPath, "model_settlement_superseded", 1); err != nil {
		return nil, err
	}
	if err := drainResponses(inspections, 15*time.Second); err != nil {
		return nil, err
	}
	inspections = nil
	for index := range controlHeadroom {
		observation, err := client.WaitResult(fmt.Sprintf("contention-%d", index))
		if err != nil {
			return nil, err
		}
		status, _ := measurement.StringField(observation, "result", "status")
		if status != "cancelled" {
			return nil, fmt.Errorf("control-first result %d was %s", index, status)
		}
	}
	p95MS := p95(latencies)
	return map[string]any{"scope": "10 fully captured reports held during delivery while two controls commit before sealed settlement", "status": latencyStatus(1000, p95MS), "ordinary_connections": ordinaryClients, "concurrent_control_commands": controlHeadroom, "qualification_limit_ms": 1000, "model_settlement_superseded": true, "total_durable_acknowledgment": map[string]any{"p95_ms": p95MS, "maximum_ms": slicesMax(latencies)}}, nil
}

func repeatedDigest(value byte, count int) string {
	digest := sha256.New()
	chunk := bytes.Repeat([]byte{value}, 64*1024)
	for remaining := count; remaining > 0; {
		used := min(remaining, len(chunk))
		digest.Write(chunk[:used])
		remaining -= used
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func ordinaryBusy(socketPath string) error {
	connection, err := net.DialTimeout("unix", socketPath, 3*time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(connection, "POST /v1/inspect-session HTTP/1.1\r\n"); err != nil {
		return err
	}
	request, _ := http.NewRequest(http.MethodPost, "http://local", nil)
	response, err := http.ReadResponse(bufio.NewReader(connection), request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusServiceUnavailable || !bytes.Contains(body, []byte("ordinary_capacity_exhausted")) {
		return fmt.Errorf("11th ordinary request returned %s: %s", response.Status, body)
	}
	return nil
}

func openBlockedResults(socketPath, store, key string) ([]net.Conn, error) {
	body, err := json.Marshal(readResultRequest{Version: "1", Kind: "read_result", Store: store, Key: key})
	if err != nil {
		return nil, err
	}
	connections := make([]net.Conn, 0, ordinaryClients)
	for attempts := 0; len(connections) < ordinaryClients && attempts < ordinaryClients*5; attempts++ {
		connection, err := rawUnixRequest(socketPath, "/v1/read-result", body, 4096)
		if err != nil {
			closeAll(connections)
			return nil, err
		}
		_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
		prefix := make([]byte, len("HTTP/1.1 200 "))
		if _, err := io.ReadFull(connection, prefix); err != nil {
			connection.Close()
			closeAll(connections)
			return nil, err
		}
		if string(prefix) == "HTTP/1.1 200 " {
			_ = connection.SetReadDeadline(time.Time{})
			connections = append(connections, connection)
			continue
		}
		connection.Close()
		closeAll(connections)
		return nil, fmt.Errorf("read-result admission returned %q", prefix)
	}
	if len(connections) != ordinaryClients {
		closeAll(connections)
		return nil, fmt.Errorf("read-result admission stopped at %d", len(connections))
	}
	if err := ordinaryBusy(socketPath); err != nil {
		closeAll(connections)
		return nil, err
	}
	// Every response has started, yet the rejected 11th ordinary request proves
	// all ten handlers remain occupied until these readers resume or disconnect.
	return connections, nil
}

func realSettlement(binary, root string) (result map[string]any, resultError error) {
	directory := filepath.Join(root, "real-settlement")
	_ = os.Mkdir(directory, 0o700)
	const large = 100_000
	endpoint, err := startSuccessEndpoint(large)
	if err != nil {
		return nil, err
	}
	defer endpoint.Close()
	deadline := measurement.NewDeadline(6 * time.Minute)
	store := filepath.Join(directory, "store")
	stderrPath := filepath.Join(directory, "host-stderr.log")
	host, err := measurement.StartHost(binary, store, endpoint.URL(), 1, stderrPath, deadline, "--test-phase-trace", "--test-inspection-reply-delay-ms", "20000", "--test-cleanup-delay-ms", "1500", "--test-client-send-buffer-bytes", "4096")
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	session := "contention/real-settlement"
	if err := client.Submit("real-settlement-message", session, "large committed output"); err != nil {
		return nil, err
	}
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "large provider request", func() (bool, error) { return endpoint.count() == 1, nil }); err != nil {
		return nil, err
	}
	var processing map[string]any
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "processing identity", func() (bool, error) {
		observation, err := client.Observe("real-settlement-message")
		if err != nil {
			return false, err
		}
		value, ok := observation["processing"].(map[string]any)
		if ok {
			processing = value
		}
		return ok, nil
	}); err != nil {
		return nil, err
	}
	inspections, err := openInspections(host.Ready["socket"], store, session)
	if err != nil {
		return nil, err
	}
	defer closeAll(inspections)
	if _, err := waitPhase(deadline, stderrPath, "inspection_captured", ordinaryClients); err != nil {
		return nil, err
	}
	idle, err := sample(host, directory, "reports-captured")
	if err != nil {
		return nil, err
	}
	preparedControls := make([]preparedRequest, 0, controlHeadroom)
	defer func() {
		for _, prepared := range preparedControls {
			_ = prepared.connection.Close()
		}
	}()
	turn, turnOK := processing["turn"].(string)
	operation, operationOK := processing["operation"].(string)
	if !turnOK || !operationOK {
		return nil, fmt.Errorf("processing identity incomplete: %v", processing)
	}
	interruptBody, err := json.Marshal(modelInterruptionRequest{
		Version: "1",
		Kind:    "model_interruption",
		Store:   store,
		Key:     "settlement-later-interrupt",
		Target: interruptionTarget{
			Session:   session,
			Turn:      turn,
			Operation: operation,
		},
	})
	if err != nil {
		return nil, err
	}
	prepared, err := prepareUnixRequest(deadline, host.Ready["socket"], "/v1/control/model-interruption", interruptBody)
	if err != nil {
		return nil, err
	}
	preparedControls = append(preparedControls, prepared)
	for index := 1; index < controlHeadroom; index++ {
		stopBody, err := json.Marshal(sessionStopRequest{Version: "1", Kind: "session_stop", Store: store, Key: fmt.Sprintf("settlement-later-stop-%d", index), Session: session})
		if err != nil {
			return nil, err
		}
		prepared, err := prepareUnixRequest(deadline, host.Ready["socket"], "/v1/control/session-stop", stopBody)
		if err != nil {
			return nil, err
		}
		preparedControls = append(preparedControls, prepared)
	}
	endpoint.releaseAll()
	lockRecords, err := waitPhase(deadline, stderrPath, "settlement_lock_acquired", 1)
	if err != nil {
		return nil, err
	}
	controls := submitPreparedControls(preparedControls)
	idleStopSelectionTurns := map[string]any{}
	for _, control := range controls {
		if control.err != nil {
			return nil, control.err
		}
		status, _ := measurement.StringField(control.reply, "answer", "status")
		if control.index == 0 {
			code, _ := measurement.StringField(control.reply, "answer", "code")
			if status != "rejected" || code != "operation_resolved" {
				return nil, fmt.Errorf("exact interruption differed: %v", control.reply)
			}
		} else {
			if err := requireAcceptedIdleStop(control.reply); err != nil {
				return nil, err
			}
			idleStopSelectionTurns["settlement-later-stop-1"] = nil
		}
	}
	completeRecords, err := waitPhase(deadline, stderrPath, "settlement_complete", 1)
	if err != nil {
		return nil, err
	}
	controlTimingRecords, err := waitPhase(deadline, stderrPath, "control_timing", controlHeadroom)
	if err != nil {
		return nil, err
	}
	expectedTimings := []expectedControlTiming{
		{key: "settlement-later-interrupt", kind: "model_interruption"},
		{key: "settlement-later-stop-1", kind: "session_stop"},
	}
	controlTimings, err := parseControlTimings(controlTimingRecords, expectedTimings)
	if err != nil {
		return nil, err
	}
	settlementLockAt, err := operationPhaseTimestamp(lockRecords, "settlement_lock_acquired", operation)
	if err != nil {
		return nil, err
	}
	settlementCompleteAt, err := operationPhaseTimestamp(completeRecords, "settlement_complete", operation)
	if err != nil {
		return nil, err
	}
	overlapped, err := settlementOverlap(settlementLockAt, settlementCompleteAt, controlTimings)
	if err != nil {
		return nil, err
	}
	if err := drainResponses(inspections, 30*time.Second); err != nil {
		return nil, err
	}
	inspections = nil
	observation, err := client.WaitResult("real-settlement-message")
	if err != nil {
		return nil, err
	}
	status, _ := measurement.StringField(observation, "result", "status")
	if status != "completed" {
		return nil, fmt.Errorf("large result was %s", status)
	}
	blockedSession := "contention/blocked-result-control"
	if err := client.Configure("blocked-result", blockedSession); err != nil {
		return nil, err
	}
	blocked, err := openBlockedResults(host.Ready["socket"], store, "real-settlement-message")
	if err != nil {
		return nil, err
	}
	blockedSample, err := sample(host, directory, "blocked-results")
	if err != nil {
		closeAll(blocked)
		return nil, err
	}
	started := time.Now()
	reply, err := stopSession(client, "blocked-result-stop", blockedSession)
	controlMS := float64(time.Since(started).Microseconds()) / 1000
	if err != nil {
		closeAll(blocked)
		return nil, fmt.Errorf("protected control failed: %v: %w", reply, err)
	}
	if err := requireAcceptedIdleStop(reply); err != nil {
		closeAll(blocked)
		return nil, err
	}
	idleStopSelectionTurns["blocked-result-stop"] = nil
	closeAll(blocked)
	destination := filepath.Join(directory, "large-answer.bin")
	output, err := measurement.Run(deadline, binary, "read-result", "--store", store, "--key", "real-settlement-message")
	if err != nil {
		return nil, err
	}
	if len(output) != large {
		return nil, fmt.Errorf("large reread length %d", len(output))
	}
	digest := sha256.Sum256(output)
	digestText := hex.EncodeToString(digest[:])
	if digestText != repeatedDigest('x', large) {
		return nil, errors.New("large reread digest differed")
	}
	if err := os.WriteFile(destination, output, 0o600); err != nil {
		return nil, err
	}
	inspection, err := client.Inspect(session)
	if err != nil {
		return nil, err
	}
	fenced, ok := inspection["execution"].(map[string]any)["dispatch_fenced"].(bool)
	if !ok || fenced {
		return nil, fmt.Errorf("dispatch fenced after blocked readers: %v", inspection)
	}
	if err := measurement.WaitFor(deadline, 25*time.Millisecond, "physical release", func() (bool, error) { return inspectCustodyZero(client, session) }); err != nil {
		return nil, err
	}
	cleanupRecords, err := waitPhase(deadline, stderrPath, "cleanup_completed", 1)
	if err != nil {
		return nil, err
	}
	cleanupCompleteAt, err := operationPhaseTimestamp(cleanupRecords, "cleanup_completed", operation)
	if err != nil {
		return nil, err
	}
	if cleanupCompleteAt < settlementCompleteAt {
		return nil, fmt.Errorf("cleanup completed before settlement: %d < %d", cleanupCompleteAt, settlementCompleteAt)
	}
	released, err := sample(host, directory, "physically-released")
	if err != nil {
		return nil, err
	}
	latencies := make([]float64, 0, controlHeadroom)
	latencySamples := make(map[string]float64, controlHeadroom)
	for _, control := range controls {
		latencies = append(latencies, control.latencyMS)
		latencySamples[expectedTimings[control.index].key] = control.latencyMS
	}
	p95MS := p95(latencies)
	return map[string]any{
		"scope":  "10 fully captured reports held during real Store import of one streamed 100,000-byte answer, two later controls, then 10 result deliveries blocked by a 4 KiB test-only socket send buffer",
		"status": settlementQualificationStatus(overlapped, 1000, p95MS, controlMS), "ordinary_connections": ordinaryClients, "active_model_responses": 1, "concurrent_control_commands": controlHeadroom, "qualification_limit_ms": 1000,
		"large_answer_bytes": large, "test_client_send_buffer_bytes": 4096, "large_answer_sha256": digestText, "blocked_result_clients": ordinaryClients, "blocked_result_delivery_observed": true,
		"blocked_result_control_acknowledgment_ms": controlMS, "blocked_result_clean_reread": true, "post_disconnect_dispatch_fenced": fenced,
		"settlement_lock_acquired_at_ns": strconv.FormatUint(settlementLockAt, 10), "settlement_complete_at_ns": strconv.FormatUint(settlementCompleteAt, 10),
		"settlement_control_overlap_observed": overlapped, "host_control_timing": controlTimings,
		"physical_cleanup_completed_at_ns": strconv.FormatUint(cleanupCompleteAt, 10), "physical_cleanup_after_settlement_ms": float64(cleanupCompleteAt-settlementCompleteAt) / 1_000_000,
		"idle_stop_selection_turns": idleStopSelectionTurns,
		"total_durable_acknowledgment": map[string]any{
			"sample_count": len(latencies), "samples_ms": latencySamples, "p95_ms": p95MS, "maximum_ms": slicesMax(latencies),
			"interpretation": "two observations only; nearest-rank p95 equals the maximum and does not describe a general latency distribution",
		},
		"resources": map[string]any{"reports_captured_before_settlement": idle, "blocked_result_delivery": blockedSample, "physically_released": released, "custody_occupied_after_cleanup": 0, "scratch_used_bytes_after_cleanup": 0},
	}, nil
}

func main() {
	output := flag.String("output", "", "write JSON to path")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-control [--output path] /absolute/path/to/rui")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, _ := filepath.Abs(flag.Arg(0))
	root, err := os.MkdirTemp("/private/tmp", "rui-control-measure-")
	if err != nil {
		panic(err)
	}
	endpoint, err := startStreamEndpoint()
	if err != nil {
		panic(err)
	}
	started := time.Now()
	headroomResult, err := headroom(binary, root, endpoint.URL())
	if err != nil {
		panic(err)
	}
	activeResult, err := activeCancellation(binary, root, endpoint.URL(), endpoint)
	if err != nil {
		panic(err)
	}
	_ = endpoint.Close()
	controlFirstResult, err := controlFirst(binary, root)
	if err != nil {
		panic(err)
	}
	realSettlementResult, err := realSettlement(binary, root)
	if err != nil {
		panic(err)
	}
	result := map[string]any{"format": "rui-model-control-v4-go", "scope": "issue-175 production Session stop and exact model interruption", "status": controlStatus(headroomResult, activeResult, controlFirstResult, realSettlementResult), "artifacts": root, "configurations": map[string]any{"stalled_incomplete_ingress_diagnostic": headroomResult, "live_model_cancellation": activeResult, "control_first_settlement_race": controlFirstResult, "real_settlement_import_contention_qualification": realSettlementResult}, "elapsed_seconds": time.Since(started).Seconds()}
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
