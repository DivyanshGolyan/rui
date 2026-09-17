package main

import (
	"errors"
	"flag"
	"path/filepath"
	"reflect"
	"testing"

	"rui.local/qualification/measurement"
)

var sqliteTestBinary = flag.String("sqlite", "", "pinned SQLite shell for query-level tests")

func TestDiscoveryStatusInclusiveBoundary(t *testing.T) {
	tests := []struct {
		milliseconds int64
		available    bool
		want         string
	}{{2000, true, "passed"}, {2001, true, "target_miss"}, {0, false, "unavailable"}}
	for _, test := range tests {
		if got := discoveryStatus(test.milliseconds, test.available); got != test.want {
			t.Errorf("discoveryStatus(%d, %v) = %q, want %q", test.milliseconds, test.available, got, test.want)
		}
	}
}

func TestOverallStatusPrecedence(t *testing.T) {
	tests := []struct {
		statuses   []string
		wantStatus string
	}{
		{[]string{"passed"}, "passed"},
		{[]string{"passed", "target_miss"}, "target_miss"},
		{[]string{"target_miss", "unavailable"}, "unavailable"},
		{[]string{"unavailable", "behavior_error"}, "behavior_error"},
	}
	for _, test := range tests {
		if got := overallStatus(test.statuses...); got != test.wantStatus {
			t.Errorf("overallStatus(%v) = %q, want %q", test.statuses, got, test.wantStatus)
		}
	}
}

func TestCaseStatusDistinguishesBehaviorAndMeasurementOutcomes(t *testing.T) {
	tests := []struct {
		behaviorFailure      bool
		measurementAvailable bool
		milliseconds         int64
		want                 string
	}{
		{true, false, 0, "behavior_error"},
		{false, false, 0, "unavailable"},
		{false, true, 2000, "passed"},
		{false, true, 2001, "target_miss"},
	}
	for _, test := range tests {
		if got := caseStatus(test.behaviorFailure, test.measurementAvailable, test.milliseconds); got != test.want {
			t.Errorf("caseStatus(%v, %v, %d) = %q, want %q", test.behaviorFailure, test.measurementAvailable, test.milliseconds, got, test.want)
		}
	}
}

func TestExecutionAuditRequiresOneSettledOperationAndRequestPerTurn(t *testing.T) {
	want := expectedOrder(2)
	valid := executionFacts{
		Messages:   []messageExecutionFact{{"e-msg-1", want[0], 1}, {"e-msg-2", want[1], 2}},
		Turns:      []turnExecutionFact{{1, want[0], 1, "provider_http_422"}, {2, want[1], 2, "provider_http_422"}},
		Operations: []operationExecutionFact{{1, 1, want[0], "provider_http_422"}, {2, 2, want[1], "provider_http_422"}},
	}
	if actual, err := auditExecutions(valid, want, 2); err != nil || !reflect.DeepEqual(actual, want) {
		t.Fatalf("auditExecutions(valid) = %v, %v; want %v", actual, err, want)
	}
	tests := []struct {
		name   string
		mutate func(*executionFacts)
	}{
		{"wrong turn outcome", func(facts *executionFacts) { facts.Turns[0].Outcome = "cancelled" }},
		{"wrong Message Session", func(facts *executionFacts) { facts.Messages[0].Session = want[1] }},
		{"wrong Turn Session", func(facts *executionFacts) { facts.Turns[0].Session = want[1] }},
		{"wrong Operation Session", func(facts *executionFacts) { facts.Operations[0].Session = want[1] }},
		{"wrong message binding", func(facts *executionFacts) { facts.Messages[0].TurnID = 2 }},
		{"wrong current operation binding", func(facts *executionFacts) { facts.Turns[0].OperationID = 2 }},
		{"wrong operation turn binding", func(facts *executionFacts) { facts.Operations[0].TurnID = 2 }},
		{"reversed admission order", func(facts *executionFacts) {
			facts.Operations[0], facts.Operations[1] = facts.Operations[1], facts.Operations[0]
		}},
	}
	for _, test := range tests {
		facts := cloneExecutionFacts(valid)
		test.mutate(&facts)
		if _, err := auditExecutions(facts, want, 2); err == nil {
			t.Errorf("%s passed execution audit", test.name)
		}
	}
	extraOperation := cloneExecutionFacts(valid)
	extraOperation.Operations = append(extraOperation.Operations, operationExecutionFact{3, 2, want[1], "provider_http_422"})
	if _, err := auditExecutions(extraOperation, want, 3); err == nil {
		t.Error("duplicate Operation passed execution audit")
	}
	extraTurn := cloneExecutionFacts(valid)
	extraTurn.Turns = append(extraTurn.Turns, turnExecutionFact{3, want[1], 3, "provider_http_422"})
	if _, err := auditExecutions(extraTurn, want, 2); err == nil {
		t.Error("Operation-less extra Turn passed execution audit")
	}
	if _, err := auditExecutions(valid, want, 3); err == nil {
		t.Error("duplicate provider request passed execution audit")
	}
}

func cloneExecutionFacts(facts executionFacts) executionFacts {
	return executionFacts{
		Messages:   append([]messageExecutionFact(nil), facts.Messages...),
		Turns:      append([]turnExecutionFact(nil), facts.Turns...),
		Operations: append([]operationExecutionFact(nil), facts.Operations...),
	}
}

func TestExecutionAuditQueryRejectsHiddenEntities(t *testing.T) {
	if *sqliteTestBinary == "" {
		t.Skip("requires Rui's pinned SQLite shell")
	}
	sqliteBinary := *sqliteTestBinary
	if !filepath.IsAbs(sqliteBinary) {
		// go test runs this package from model-queue/, while Zig renders the
		// artifact relative to the tests/qualification command directory.
		sqliteBinary = filepath.Join("..", sqliteBinary)
	}
	tests := []struct {
		name           string
		fixture        string
		wantTurns      int
		wantOperations int
	}{
		{
			name: "duplicate Operation behind current pointer",
			fixture: `INSERT INTO message_admission VALUES(1,'e-msg-1','queue/eligible/000001',1);
INSERT INTO turn VALUES(1,'queue/eligible/000001',2,'provider_http_422');
INSERT INTO model_operation VALUES(1,1,'queue/eligible/000001','provider_http_422');
INSERT INTO model_operation VALUES(2,1,'queue/eligible/000001','provider_http_422');`,
			wantTurns: 1, wantOperations: 2,
		},
		{
			name: "extra Turn without Operation",
			fixture: `INSERT INTO message_admission VALUES(1,'e-msg-1','queue/eligible/000001',1);
INSERT INTO turn VALUES(1,'queue/eligible/000001',1,'provider_http_422');
INSERT INTO turn VALUES(2,'queue/eligible/000002',2,'provider_http_422');
INSERT INTO model_operation VALUES(1,1,'queue/eligible/000001','provider_http_422');`,
			wantTurns: 2, wantOperations: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store := t.TempDir()
			deadline := measurement.NewDeadline(measurement.TeardownAllowance)
			_, err := sql(deadline, sqliteBinary, store, `CREATE TABLE message_admission(admission_id INTEGER PRIMARY KEY,command_key TEXT,session_ref TEXT,turn_id INTEGER);
CREATE TABLE turn(turn_id INTEGER PRIMARY KEY,session_ref TEXT,operation_id INTEGER,outcome_code TEXT);
CREATE TABLE model_operation(operation_id INTEGER PRIMARY KEY,turn_id INTEGER,session_ref TEXT,resolution_code TEXT);`+test.fixture)
			if err != nil {
				t.Fatal(err)
			}
			rows, err := sql(deadline, sqliteBinary, store, executionAuditSQL)
			if err != nil {
				t.Fatal(err)
			}
			facts, err := parseExecutionFacts(rows)
			if err != nil {
				t.Fatal(err)
			}
			if len(facts.Turns) != test.wantTurns || len(facts.Operations) != test.wantOperations {
				t.Fatalf("query returned %d Turns and %d Operations, want %d and %d", len(facts.Turns), len(facts.Operations), test.wantTurns, test.wantOperations)
			}
			if _, err := auditExecutions(facts, expectedOrder(1), 1); err == nil {
				t.Fatal("invalid Store passed execution audit")
			}
		})
	}
}

func TestPhysicalFootprintStatusUsesConservativeUpperBound(t *testing.T) {
	if physicalFootprintTargetBytes != 24*1024*1024 {
		t.Fatalf("physical footprint target = %d, want 24 MiB", physicalFootprintTargetBytes)
	}
	tests := []struct {
		footprint  measurement.Footprint
		wantStatus string
		wantUpper  uint64
	}{
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes}, "passed", physicalFootprintTargetBytes},
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes - 1, LifetimePeakTolerance: 1}, "passed", physicalFootprintTargetBytes},
		{measurement.Footprint{LifetimePeakBytes: physicalFootprintTargetBytes, LifetimePeakTolerance: 1}, "target_miss", physicalFootprintTargetBytes + 1},
	}
	for _, test := range tests {
		status, upper := physicalFootprintStatus(test.footprint)
		if status != test.wantStatus || upper != test.wantUpper {
			t.Errorf("physicalFootprintStatus(%+v) = %q, %d; want %q, %d", test.footprint, status, upper, test.wantStatus, test.wantUpper)
		}
	}
}

func TestBehaviorFailureRetainsOrderEvidence(t *testing.T) {
	result := map[string]any{"status": "passed"}
	actual := []string{"queue/eligible/000002", "queue/eligible/000001"}
	expected := []string{"queue/eligible/000001", "queue/eligible/000002"}
	recordAdmissionOrder(result, actual, expected, nil)
	if result["status"] != "behavior_error" || result["behavior_failure"] == nil {
		t.Fatalf("wrong-order result = %v", result)
	}
	if !reflect.DeepEqual(result["operation_admission_order"], actual) || !reflect.DeepEqual(result["expected_oldest_first_admission_order"], expected) {
		t.Fatalf("order evidence was not retained: %v", result)
	}
}

func TestTerminalObservationFailuresRemainSerializable(t *testing.T) {
	result := map[string]any{"status": "passed", "discovery_ms": int64(7)}
	recordTerminalObservation(result, nil, errors.New("terminal observation timed out"))
	if result["status"] != "behavior_error" || result["behavior_failure"] == nil || result["discovery_ms"] != int64(7) {
		t.Fatalf("terminal failure result = %v", result)
	}
	wrong := map[string]any{"result": map[string]any{"status": "failed", "code": "cancelled"}}
	result = map[string]any{"status": "passed"}
	recordTerminalObservation(result, wrong, nil)
	if result["status"] != "behavior_error" {
		t.Fatalf("wrong terminal observation passed: %v", result)
	}
}

func TestLaterCaseFailureRetainsEarlierBehaviorEvidence(t *testing.T) {
	cases := map[string]any{
		"baseline": map[string]any{"status": "behavior_error", "behavior_failure": "missing settlement"},
	}
	later := retainCaseFailure(nil, population{History: 1000, Eligible: 1}, errors.New("template failed"))
	cases["history-1000"] = later
	if cases["baseline"].(map[string]any)["behavior_failure"] != "missing settlement" {
		t.Fatalf("earlier evidence was discarded: %v", cases)
	}
	if later["status"] != "behavior_error" || later["case_error"] != "template failed" {
		t.Fatalf("later case failure was not serializable: %v", later)
	}
}

func TestProvenanceFailuresExitNonzeroAfterPublication(t *testing.T) {
	if got := failureExitCode("unavailable"); got != 0 {
		t.Fatalf("intentional unavailable measurement exit = %d, want 0", got)
	}
	if got := failureExitCode("passed", errors.New("environment evidence")); got != 1 {
		t.Fatalf("environment provenance failure exit = %d, want 1", got)
	}
	if got := failureExitCode("passed", nil, errors.New("sqlite hash")); got != 1 {
		t.Fatalf("SQLite provenance failure exit = %d, want 1", got)
	}
}
