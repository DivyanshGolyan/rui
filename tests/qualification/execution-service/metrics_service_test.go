package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"
)

// These fixtures describe owner transitions, not a timing threshold. Two fast
// completions without lifecycle service are just as invalid as two slow ones.
func serviceContractEvents() []traceEvent {
	id := executionID{Run: "1000", Process: "7", Clock: "awake_ns", Turn: "1", Operation: "1", Attempt: "1"}
	second := id
	second.Operation = "2"
	return []traceEvent{
		{Phase: "lifecycle_boundary", Start: 10, At: 100},
		{executionID: id, Phase: "preparation_started", At: 110},
		{executionID: id, Phase: "preparation_advance_started", At: 120},
		{executionID: id, Phase: "preparation_advance_completed", At: 150, WorkBytes: 20, WorkItems: 3, RequestBytes: 10},
		{executionID: id, Phase: "preparation_completed", At: 155},
		{Phase: "lifecycle_boundary", Start: 100, At: 160},
		{executionID: id, Phase: "provider_completion_removed", At: 200, QueuedAfter: 1},
		{executionID: id, Phase: "provider_completion_serviced", At: 220},
		{Phase: "control_durable_acceptance", At: 225, Subject: "stop"},
		{executionID: second, Phase: "effect_stop_requested", At: 230, ControlKey: "stop"},
		{executionID: second, Phase: "provider_completion_removed", At: 250},
		{executionID: second, Phase: "provider_completion_serviced", At: 260},
		{Phase: "lifecycle_boundary", Start: 160, At: 400},
	}
}

func servicedContractEvents() []traceEvent {
	events := serviceContractEvents()
	events[len(events)-1].Start = 240
	events = append(events, traceEvent{Phase: "lifecycle_boundary", Start: 160, At: 240})
	sort.SliceStable(events, func(i, j int) bool { return events[i].At < events[j].At })
	return events
}

func requireServiceViolation(t *testing.T, events []traceEvent, reason string) {
	t.Helper()
	sort.SliceStable(events, func(i, j int) bool { return events[i].At < events[j].At })
	m := deriveMetrics(events, false)
	if m.Status != "invalid" || !strings.Contains(strings.Join(m.Invalid, "\n"), reason) {
		t.Fatalf("expected %q, got status=%s invalid=%v", reason, m.Status, m.Invalid)
	}
}

func TestServiceContractRejectsUnboundedCompletionDrain(t *testing.T) {
	requireServiceViolation(t, serviceContractEvents(), "work_without_lifecycle_service")
}

func TestServiceContractAcceptsOneUnitPerTurn(t *testing.T) {
	m := deriveMetrics(servicedContractEvents(), false)
	if m.Status != "passed" {
		t.Fatalf("valid finite drain rejected: %+v", m)
	}
}

func TestServiceContractRejectsUnpairedCompletion(t *testing.T) {
	for _, change := range []string{"missing_end", "wrong_attempt", "wrong_operation", "wrong_turn", "wrong_action", "end_without_start"} {
		t.Run(change, func(t *testing.T) {
			events := servicedContractEvents()
			for i := range events {
				if events[i].Phase == "provider_completion_serviced" && events[i].At == 220 {
					switch change {
					case "missing_end":
						events = append(events[:i], events[i+1:]...)
					case "wrong_attempt":
						events[i].Attempt = "2"
					case "wrong_operation":
						events[i].Operation = "99"
					case "wrong_turn":
						events[i].Turn = "99"
					case "wrong_action":
						events[i].Action = "99"
					}
					break
				}
			}
			if change == "end_without_start" {
				for i := range events {
					if events[i].Phase == "provider_completion_removed" && events[i].At == 200 {
						events = append(events[:i], events[i+1:]...)
						break
					}
				}
			}
			requireServiceViolation(t, events, "service_turn:")
		})
	}
}

func TestServiceContractRejectsReplayedCompletion(t *testing.T) {
	events := servicedContractEvents()
	for i := range events {
		if events[i].Operation == "2" && strings.HasPrefix(events[i].Phase, "provider_completion_") {
			events[i].Operation = "1"
		}
	}
	requireServiceViolation(t, events, "duplicate_completion")
}

func TestServiceContractRejectsRepeatedPreparationWithoutService(t *testing.T) {
	events := servicedContractEvents()
	id := events[2].executionID
	events = append(events,
		traceEvent{executionID: id, Phase: "preparation_advance_started", At: 151},
		traceEvent{executionID: id, Phase: "preparation_advance_completed", At: 152, WorkBytes: 2, WorkItems: 1, RequestBytes: 11},
	)
	requireServiceViolation(t, events, "work_without_lifecycle_service")
}

func TestServiceContractRejectsBoundaryInsideWork(t *testing.T) {
	events := servicedContractEvents()
	events = append(events, traceEvent{Phase: "lifecycle_boundary", Start: 100, At: 130})
	for i := range events {
		if events[i].Phase == "lifecycle_boundary" && events[i].At == 160 {
			events[i].Start = 130
		}
	}
	requireServiceViolation(t, events, "boundary_inside_work")
}

func TestServiceContractRejectsUncoveredWork(t *testing.T) {
	t.Run("missing_final_boundary", func(t *testing.T) {
		events := servicedContractEvents()
		requireServiceViolation(t, events[:len(events)-1], "missing_boundary_after_work")
	})
	t.Run("missing_initial_coverage", func(t *testing.T) {
		events := servicedContractEvents()[1:]
		for i := range events {
			if events[i].Phase == "lifecycle_boundary" && events[i].At == 160 {
				events[i].Start = 140
			}
		}
		requireServiceViolation(t, events, "work_outside_service_interval")
	})
}

func TestCompletionTraceRequiresExecutionIdentity(t *testing.T) {
	for _, phase := range []string{"provider_completion_removed", "provider_completion_serviced"} {
		for _, field := range []string{"turn", "operation", "attempt"} {
			t.Run(phase+"/"+field, func(t *testing.T) {
				row := map[string]any{
					"at_ns": "200", "sequence": "1", "run": "1000", "process": "7", "clock": "awake_ns",
					"turn": "1", "operation": "1", "attempt": "1", "queued_after": "0",
				}
				delete(row, field)
				body, err := json.Marshal(row)
				if err != nil {
					t.Fatal(err)
				}
				var encoded bytes.Buffer
				fmt.Fprintf(&encoded, "{\"rui_test_phase\":%q,%s\n", phase, body[1:])
				if _, err := parseTraces(encoded.Bytes()); err == nil {
					t.Fatal("completion with incomplete identity was accepted")
				}
			})
		}
	}
}
