package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
)

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
	WorkBytesText                                                                        string `json:"work_bytes"`
	WorkItemsText                                                                        string `json:"work_items"`
	RequestBytesText                                                                     string `json:"request_bytes"`
	TraceLost                                                                            bool   `json:"trace_lost"`
	At, Sequence, Start, Wait, WorkBytes, WorkItems, RequestBytes uint64 `json:"-"`
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
	Status                   string            `json:"status"`
	MaxLifecycleServiceGapNS *uint64           `json:"max_lifecycle_service_gap_ns"`
	LargestUninterruptedNS   *uint64           `json:"largest_active_service_interval_ns"`
	Preparation              []interval        `json:"preparation_intervals"`
	PreparationLifetime      []interval        `json:"preparation_lifetimes"`
	Validation               []interval        `json:"validation_intervals"`
	Settlement               []interval        `json:"settlement_intervals"`
	Service                  []serviceInterval `json:"service_intervals"`
	Invalid                  []string          `json:"invalid_metrics,omitempty"`
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
		events = append(events, e)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].At < events[j].At })
	return events, nil
}

type intervalKey struct {
	ID    executionID
	Phase string
}

func deriveMetrics(events []traceEvent) metrics {
	m := metrics{
		Status: "passed", Preparation: []interval{}, PreparationLifetime: []interval{},
		Validation: []interval{}, Settlement: []interval{}, Service: []serviceInterval{},
	}
	starts := map[intervalKey]uint64{}
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
		case "preparation_started", "preparation_advance_started", "validation_started":
			begin(e, e.Phase)
		case "settlement_lock_requested":
			begin(e, "settlement_total")
		case "preparation_completed":
			end(e, "preparation_started", &m.PreparationLifetime)
		case "preparation_advance_completed", "preparation_advance_failed":
			end(e, "preparation_advance_started", &m.Preparation)
		case "validation_completed", "validation_failed":
			end(e, "validation_started", &m.Validation)
		case "settlement_complete":
			end(e, "settlement_total", &m.Settlement)
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
	if len(m.Invalid) > 0 {
		m.Status = "invalid"
	}
	sort.Strings(m.Invalid)
	return m
}
