package main

// This file deliberately uses only the standard library. Its negative tests
// can run without a Rui binary or native measurement dependencies.
import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
)

const preparationByteAllowance = 16 * 1024
const preparationItemAllowance = 64
const maxTraceBytes = 64 * 1024 * 1024

type executionID struct {
	Run       string `json:"run"`
	Process   string `json:"process"`
	Clock     string `json:"clock"`
	Turn      string `json:"turn"`
	Operation string `json:"operation"`
	Action    string `json:"action,omitempty"`
	Attempt   string `json:"attempt"`
}

func (id executionID) valid() bool {
	if id.Clock != "awake_ns" {
		return false
	}
	for _, field := range []string{id.Run, id.Process, id.Turn, id.Operation, id.Attempt} {
		n, e := strconv.ParseUint(field, 10, 64)
		if e != nil || n == 0 {
			return false
		}
	}
	if id.Action != "" {
		n, e := strconv.ParseUint(id.Action, 10, 64)
		if e != nil || n == 0 {
			return false
		}
	}
	return true
}

type traceEvent struct {
	executionID
	Phase                                                                                string `json:"rui_test_phase"`
	AtText                                                                               string `json:"at_ns"`
	SequenceText                                                                         string `json:"sequence"`
	StartText                                                                            string `json:"start_ns"`
	WaitText                                                                             string `json:"wait_ns"`
	DeadlineText                                                                         string `json:"deadline_ns"`
	QueuedAfterText                                                                      string `json:"queued_after"`
	WorkBytesText                                                                        string `json:"work_bytes"`
	WorkItemsText                                                                        string `json:"work_items"`
	RequestBytesText                                                                     string `json:"request_bytes"`
	ControlKey                                                                           string `json:"control_key"`
	Subject                                                                              string `json:"subject"`
	TraceLost                                                                            bool   `json:"trace_lost"`
	Failed                                                                               bool   `json:"failed"`
	At, Sequence, Start, Wait, Deadline, QueuedAfter, WorkBytes, WorkItems, RequestBytes uint64 `json:"-"`
}

type interval struct {
	Kind       string      `json:"kind"`
	Owner      executionID `json:"owner"`
	StartNS    uint64      `json:"start_ns"`
	EndNS      uint64      `json:"end_ns"`
	DurationNS uint64      `json:"duration_ns"`
}

type serviceInterval struct {
	StartNS uint64 `json:"start_ns"`
	EndNS   uint64 `json:"end_ns"`
	WaitNS  uint64 `json:"wait_ns"`
	WorkNS  uint64 `json:"work_ns"`
}

type metrics struct {
	Status                    string            `json:"status"`
	MaxLifecycleServiceGapNS  *uint64           `json:"max_lifecycle_service_gap_ns"`
	LargestUninterruptedNS    *uint64           `json:"largest_active_service_interval_ns"`
	StopToEffectNS            []uint64          `json:"stop_to_effect_ns"`
	DeadlineToServiceNS       []uint64          `json:"deadline_to_service_ns"`
	Preparation               []interval        `json:"preparation_intervals"`
	PreparationLifetime       []interval        `json:"preparation_lifetimes"`
	Validation                []interval        `json:"validation_intervals"`
	Settlement                []interval        `json:"settlement_intervals"`
	SettlementQueue           []interval        `json:"settlement_queue_intervals"`
	SettlementService         []interval        `json:"settlement_service_intervals"`
	Service                   []serviceInterval `json:"service_intervals"`
	MaxNativeCompletionsAfter uint64            `json:"max_native_completions_queued_after_removal"`
	Invalid                   []string          `json:"invalid_metrics,omitempty"`
}

func uintField(s, name string) (uint64, error) {
	if s == "" {
		return 0, fmt.Errorf("missing %s", name)
	}
	n, e := strconv.ParseUint(s, 10, 64)
	if e != nil {
		return 0, fmt.Errorf("invalid %s: %w", name, e)
	}
	return n, nil
}
func parseTraces(data []byte) ([]traceEvent, error) {
	if len(data) > maxTraceBytes {
		return nil, errors.New("trace collection capacity exceeded")
	}
	if len(data) > 0 && data[len(data)-1] != '\n' {
		return nil, errors.New("incomplete final trace line")
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	events := []traceEvent{}
	var run, process, clock string
	var sequence uint64
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if !bytes.HasPrefix(line, []byte(`{"rui_test_phase"`)) {
			continue
		}
		var e traceEvent
		if err := json.Unmarshal(line, &e); err != nil {
			return nil, fmt.Errorf("malformed trace: %w", err)
		}
		if e.Run == "" || e.Process == "" || e.Clock != "awake_ns" || e.TraceLost {
			return nil, errors.New("missing provenance or producer trace loss")
		}
		if run == "" {
			run, process, clock = e.Run, e.Process, e.Clock
		}
		if e.Run != run || e.Process != process || e.Clock != clock {
			return nil, errors.New("mixed Host runs or clock domains")
		}
		var err error
		e.Sequence, err = uintField(e.SequenceText, "sequence")
		if err != nil {
			return nil, err
		}
		if e.Sequence != sequence+1 {
			return nil, errors.New("missing, duplicate, or reordered trace record")
		}
		sequence = e.Sequence
		// Some existing summary records have named timestamps instead of At.
		if e.AtText != "" {
			e.At, err = uintField(e.AtText, "at_ns")
			if err != nil {
				return nil, err
			}
		}
		switch e.Phase {
		case "lifecycle_boundary":
			e.Start, err = uintField(e.StartText, "start_ns")
			if err != nil {
				return nil, err
			}
			e.Wait, err = uintField(e.WaitText, "wait_ns")
			if err != nil {
				return nil, err
			}
		case "provider_completion_removed":
			e.QueuedAfter, err = uintField(e.QueuedAfterText, "queued_after")
			if err != nil {
				return nil, err
			}
		case "bash_deadline_established", "bash_deadline_serviced":
			e.Deadline, err = uintField(e.DeadlineText, "deadline_ns")
			if err != nil {
				return nil, err
			}
		case "preparation_advance_completed", "preparation_advance_failed":
			e.WorkBytes, err = uintField(e.WorkBytesText, "work_bytes")
			if err != nil {
				return nil, err
			}
			e.WorkItems, err = uintField(e.WorkItemsText, "work_items")
			if err != nil {
				return nil, err
			}
			e.RequestBytes, err = uintField(e.RequestBytesText, "request_bytes")
			if err != nil {
				return nil, err
			}
		}
		switch e.Phase {
		case "lifecycle_boundary", "provider_completion_removed", "provider_completion_serviced", "control_durable_acceptance":
			if e.At == 0 {
				return nil, fmt.Errorf("missing event time: %s", e.Phase)
			}
		case "preparation_started", "preparation_completed", "preparation_advance_started", "preparation_advance_completed", "preparation_advance_failed", "validation_started", "validation_completed", "validation_failed", "settlement_lock_requested", "settlement_lock_acquired", "settlement_complete", "model_settlement_superseded", "effect_stop_requested", "bash_deadline_established", "bash_deadline_serviced":
			if e.At == 0 || !e.executionID.valid() {
				return nil, fmt.Errorf("incomplete execution identity: %s", e.Phase)
			}
		}
		events = append(events, e)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	// Logging has a serial sequence, but timestamps originate at their owners
	// before acquiring the logging mutex. Pair in owner-time order.
	sort.SliceStable(events, func(i, j int) bool { return events[i].At < events[j].At })
	return events, nil
}

type intervalKey struct {
	ID    executionID
	Phase string
}

func deriveMetrics(events []traceEvent, requireDeadline bool) metrics {
	m := metrics{Status: "passed", StopToEffectNS: []uint64{}, DeadlineToServiceNS: []uint64{}, Preparation: []interval{}, PreparationLifetime: []interval{}, Validation: []interval{}, Settlement: []interval{}, SettlementQueue: []interval{}, SettlementService: []interval{}, Service: []serviceInterval{}}
	starts := map[intervalKey]uint64{}
	accepted := map[string]uint64{}
	deadlines := map[executionID]uint64{}
	requestBytes := map[executionID]uint64{}
	var previousBoundary, maxGap, maxWork uint64
	invalid := func(s string) { m.Invalid = append(m.Invalid, s) }
	begin := func(e traceEvent, p string) {
		k := intervalKey{e.executionID, p}
		if _, ok := starts[k]; ok {
			invalid("duplicate_start:" + p)
		} else {
			starts[k] = e.At
		}
	}
	end := func(e traceEvent, p string, dst *[]interval) {
		k := intervalKey{e.executionID, p}
		a, ok := starts[k]
		if !ok || e.At < a {
			invalid("missing_or_mismatched_start:" + p)
			return
		}
		delete(starts, k)
		*dst = append(*dst, interval{p, e.executionID, a, e.At, e.At - a})
	}
	for _, e := range events {
		switch e.Phase {
		case "control_durable_acceptance":
			if _, ok := accepted[e.Subject]; ok {
				invalid("duplicate_control_acceptance:" + e.Subject)
			} else {
				accepted[e.Subject] = e.At
			}
		case "effect_stop_requested":
			a, ok := accepted[e.ControlKey]
			if !ok || e.At < a {
				invalid("stop_to_effect:" + e.ControlKey)
			} else {
				m.StopToEffectNS = append(m.StopToEffectNS, e.At-a)
			}
		case "bash_deadline_established":
			if _, ok := deadlines[e.executionID]; ok {
				invalid("duplicate_deadline")
			}
			deadlines[e.executionID] = e.Deadline
		case "bash_deadline_serviced":
			due, ok := deadlines[e.executionID]
			if !ok || due != e.Deadline || e.At < due || e.Failed {
				invalid("deadline_to_service")
			} else {
				m.DeadlineToServiceNS = append(m.DeadlineToServiceNS, e.At-due)
			}
		case "lifecycle_boundary":
			if e.Start == 0 || e.At < e.Start || e.Wait > e.At-e.Start || (previousBoundary != 0 && e.Start != previousBoundary) {
				invalid("invalid_or_missing_service_boundary")
				continue
			}
			previousBoundary = e.At
			gap := e.At - e.Start
			work := gap - e.Wait
			maxGap = max(maxGap, gap)
			maxWork = max(maxWork, work)
			m.Service = append(m.Service, serviceInterval{e.Start, e.At, e.Wait, work})
		case "provider_completion_removed":
			m.MaxNativeCompletionsAfter = max(m.MaxNativeCompletionsAfter, e.QueuedAfter)
		case "preparation_started", "preparation_advance_started", "validation_started":
			begin(e, e.Phase)
		case "settlement_lock_requested":
			begin(e, "settlement_total")
			begin(e, "settlement_queue")
		case "settlement_lock_acquired":
			end(e, "settlement_queue", &m.SettlementQueue)
			begin(e, "settlement_service")
		case "preparation_completed":
			end(e, "preparation_started", &m.PreparationLifetime)
		case "preparation_advance_completed", "preparation_advance_failed":
			end(e, "preparation_advance_started", &m.Preparation)
			if e.WorkBytes > preparationByteAllowance || e.WorkItems > preparationItemAllowance {
				invalid("preparation_allowance_exceeded")
			}
			if prior, ok := requestBytes[e.executionID]; ok && e.RequestBytes < prior {
				invalid("request_bytes_regressed")
			}
			requestBytes[e.executionID] = e.RequestBytes
		case "validation_completed", "validation_failed":
			end(e, "validation_started", &m.Validation)
		case "settlement_complete":
			end(e, "settlement_total", &m.Settlement)
			end(e, "settlement_service", &m.SettlementService)
		}
	}
	for k := range starts {
		invalid("missing_end:" + k.Phase + ":" + k.ID.Operation + ":" + k.ID.Attempt)
	}
	if len(m.Service) == 0 {
		invalid("lifecycle_boundaries")
	} else {
		m.MaxLifecycleServiceGapNS = &maxGap
		m.LargestUninterruptedNS = &maxWork
	}
	if len(m.Preparation) == 0 || len(m.PreparationLifetime) == 0 {
		invalid("preparation_work_evidence")
	}
	if len(m.StopToEffectNS) == 0 {
		invalid("stop_to_effect")
	}
	if requireDeadline && len(m.DeadlineToServiceNS) == 0 {
		invalid("deadline_to_service")
	}
	if len(m.Invalid) > 0 {
		m.Status = "invalid"
	}
	sort.Strings(m.Invalid)
	return m
}

// No verdict string can silently acquire a successful command exit code.
func exitCode(status string) int {
	if status == "passed" {
		return 0
	}
	return 1
}

type overlapProof struct {
	Mode               string `json:"mode"`
	StopAcceptedNS     uint64 `json:"stop_accepted_ns"`
	EffectRequestedNS  uint64 `json:"effect_requested_ns"`
	WorkStartNS        uint64 `json:"work_start_ns"`
	WorkEndNS          uint64 `json:"work_end_ns"`
	DeadlineDueNS      uint64 `json:"deadline_due_ns"`
	DeadlineServicedNS uint64 `json:"deadline_serviced_ns"`
}

func proveOverlap(events []traceEvent, mode, stopKey string, target executionID, burst []executionID, requireDeadline bool) (overlapProof, error) {
	p := overlapProof{Mode: mode}
	var finalCompletion, firstBacklog uint64
	selected := map[executionID]bool{}
	for _, id := range burst {
		selected[id] = true
	}
	for _, e := range events {
		if e.Phase == "control_durable_acceptance" && e.Subject == stopKey {
			p.StopAcceptedNS = e.At
		}
		if e.Phase == "effect_stop_requested" && e.ControlKey == stopKey {
			p.EffectRequestedNS = e.At
		}
		if e.executionID == target {
			if e.Phase == "preparation_started" {
				p.WorkStartNS = e.At
			}
			if e.Phase == "preparation_completed" {
				p.WorkEndNS = e.At
			}
		}
		if selected[e.executionID] && e.Phase == "provider_completion_removed" && e.QueuedAfter > 0 && firstBacklog == 0 {
			firstBacklog = e.At
		}
		if selected[e.executionID] && e.Phase == "provider_completion_serviced" {
			finalCompletion = e.At
		}
	}
	if mode == "completion" {
		p.WorkStartNS, p.WorkEndNS = firstBacklog, finalCompletion
	}
	// Both acceptance and effect handling must occur while the pressure is
	// actually present. A successful idle stop is not overlap evidence.
	if p.WorkStartNS == 0 || p.WorkEndNS <= p.WorkStartNS || p.StopAcceptedNS < p.WorkStartNS || p.StopAcceptedNS >= p.WorkEndNS || p.EffectRequestedNS < p.StopAcceptedNS || p.EffectRequestedNS >= p.WorkEndNS {
		return p, errors.New("required stop/work overlap was not observed")
	}
	if requireDeadline {
		for _, e := range events {
			if e.Phase == "bash_deadline_serviced" && e.Deadline >= p.WorkStartNS && e.Deadline < p.WorkEndNS && e.At >= e.Deadline && e.At < p.WorkEndNS && !e.Failed {
				p.DeadlineDueNS, p.DeadlineServicedNS = e.Deadline, e.At
				break
			}
		}
		if p.DeadlineDueNS == 0 {
			return p, errors.New("required Bash deadline/work overlap was not observed")
		}
	}
	return p, nil
}
