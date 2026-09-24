package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"rui.local/qualification/measurement"
)

const (
	discoveryTargetMS            int64  = 2000
	physicalFootprintTargetBytes uint64 = 25_000_000
)

type population struct {
	History    int `json:"history"`
	Ineligible int `json:"ineligible_stopped_pending"`
	Eligible   int `json:"eligible"`
}

type messageExecutionFact struct {
	CommandKey string `json:"command_key"`
	Session    string `json:"session"`
	TurnID     int64  `json:"turn_id"`
}

type turnExecutionFact struct {
	TurnID      int64  `json:"turn_id"`
	Session     string `json:"session"`
	OperationID int64  `json:"operation_id"`
	Outcome     string `json:"outcome"`
}

type operationExecutionFact struct {
	OperationID int64  `json:"operation_id"`
	TurnID      int64  `json:"turn_id"`
	Session     string `json:"session"`
	Resolution  string `json:"resolution"`
}

type executionFacts struct {
	Messages   []messageExecutionFact   `json:"messages"`
	Turns      []turnExecutionFact      `json:"turns"`
	Operations []operationExecutionFact `json:"operations"`
}

const executionAuditSQL = `WITH eligible_turn(turn_id) AS (
 SELECT turn_id FROM message_admission WHERE session_ref GLOB 'queue/eligible/[0-9]*' AND turn_id IS NOT NULL
 UNION SELECT turn_id FROM turn WHERE session_ref GLOB 'queue/eligible/[0-9]*'
 UNION SELECT turn_id FROM model_operation WHERE session_ref GLOB 'queue/eligible/[0-9]*'
)
SELECT row FROM (
 SELECT 1 AS kind,m.admission_id AS ordinal,'M|'||m.command_key||'|'||m.session_ref||'|'||coalesce(m.turn_id,'') AS row
 FROM message_admission m WHERE m.session_ref GLOB 'queue/eligible/[0-9]*' OR m.turn_id IN eligible_turn
 UNION ALL
 SELECT 2,t.turn_id,'T|'||t.turn_id||'|'||t.session_ref||'|'||t.operation_id||'|'||coalesce(t.outcome_code,'')
 FROM turn t WHERE t.session_ref GLOB 'queue/eligible/[0-9]*' OR t.turn_id IN eligible_turn
 UNION ALL
 SELECT 3,o.operation_id,'O|'||o.operation_id||'|'||o.turn_id||'|'||o.session_ref||'|'||coalesce(o.resolution_code,'')
 FROM model_operation o WHERE o.session_ref GLOB 'queue/eligible/[0-9]*' OR o.turn_id IN eligible_turn
) ORDER BY kind,ordinal;`

func discoveryStatus(milliseconds int64, available bool) string {
	if !available {
		return "unavailable"
	}
	if milliseconds > discoveryTargetMS {
		return "target_miss"
	}
	return "passed"
}

func overallStatus(statuses ...string) string {
	for _, status := range statuses {
		if status == "behavior_error" {
			return "behavior_error"
		}
	}
	for _, status := range statuses {
		if status == "unavailable" {
			return "unavailable"
		}
	}
	for _, status := range statuses {
		if status == "target_miss" {
			return "target_miss"
		}
	}
	return "passed"
}

func caseStatus(behaviorFailure, measurementAvailable bool, milliseconds int64) string {
	if behaviorFailure {
		return "behavior_error"
	}
	return discoveryStatus(milliseconds, measurementAvailable)
}

type endpoint struct {
	server   *http.Server
	listener net.Listener
	first    chan time.Time
	release  chan struct{}
	once     sync.Once
	requests atomic.Int64
}

func startEndpoint() (*endpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	e := &endpoint{listener: listener, first: make(chan time.Time, 1), release: make(chan struct{})}
	e.server = &http.Server{Handler: http.HandlerFunc(e.serve)}
	go e.server.Serve(listener)
	return e, nil
}

func (e *endpoint) serve(writer http.ResponseWriter, request *http.Request) {
	e.requests.Add(1)
	_, _ = io.Copy(io.Discard, request.Body)
	e.once.Do(func() {
		e.first <- time.Now()
		<-e.release
	})
	payload := []byte("deterministic permanent failure")
	writer.Header().Set("Connection", "close")
	writer.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	writer.WriteHeader(http.StatusUnprocessableEntity)
	_, _ = writer.Write(payload)
}

func (e *endpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *endpoint) Release()    { close(e.release) }
func (e *endpoint) Requests() int64 {
	return e.requests.Load()
}

func sql(deadline measurement.Deadline, sqliteBinary, store, query string) (string, error) {
	output, err := measurement.Run(deadline, sqliteBinary, "-noheader", filepath.Join(store, "rui.sqlite3"), query)
	return strings.TrimSpace(string(output)), err
}

func initializeTemplate(binary, sqliteBinary, directory, store string, deadline measurement.Deadline) error {
	e, err := startEndpoint()
	if err != nil {
		return err
	}
	e.Release()
	host, err := measurement.StartHost(binary, store, e.URL(), 1, filepath.Join(directory, "template-host-stderr.log"), deadline)
	if err != nil {
		_ = e.server.Close()
		return err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	work := client.Configure("template", "queue/template", "--tools", "none")
	if work == nil {
		work = client.Message("template-message", "queue/template", "queue qualification")
	}
	if work == nil {
		_, work = client.WaitResult("template-message")
	}
	if err := errors.Join(work, host.Stop(measurement.TeardownAllowance), e.server.Close()); err != nil {
		return err
	}
	_, err = sql(deadline, sqliteBinary, store, "BEGIN; DELETE FROM conversation_entry; DELETE FROM model_operation; DELETE FROM turn; DELETE FROM message_admission; DELETE FROM core_command WHERE command_key='template-message'; COMMIT;")
	return err
}

func populate(deadline measurement.Deadline, sqliteBinary, store string, p population) error {
	// Production initialization above owns schema and content creation. This SQL only
	// expands controlled durable populations while no Host is running.
	query := fmt.Sprintf(`PRAGMA foreign_keys=ON; BEGIN;
CREATE TEMP TABLE q(v INTEGER);
INSERT INTO q SELECT content_id FROM content WHERE byte_length>0 ORDER BY content_id DESC LIMIT 1;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[1]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[1]d)
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 'h-msg-'||i,2,'queue/template',randomblob(32),(SELECT v FROM q),NULL,1,'accepted',1,0 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[1]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[1]d)
INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id)
 SELECT 100+i,'queue/template','h-msg-'||i,(SELECT v FROM q),100+i FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[1]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[1]d)
INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id)
 SELECT 100+i,'queue/template',100+i,100+i,100+i,'provider_http_422',NULL FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[1]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[1]d)
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,resolution_code)
 SELECT 100+i,100+i,'queue/template',1,100+i,2*i,1,1,0,NULL,'provider_http_422' FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[1]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[1]d)
INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id)
 SELECT 'queue/template',i,2*i-1,1,100+i,100+i,NULL,NULL,(SELECT v FROM q) FROM n;
UPDATE session SET next_position=2*%[1]d+1 WHERE session_ref='queue/template';
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 's-config',1,'queue/stopped',randomblob(32),NULL,NULL,1,'accepted',1,1 WHERE %[2]d>0;
INSERT INTO session(session_ref,workspace,provider,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position)
 SELECT 'queue/stopped',t.workspace,t.provider,t.model,t.instructions_content_id,t.tools_mask,t.permission_mode,t.output_schema_content_id,1,1 FROM session t WHERE t.session_ref='queue/template' AND %[2]d>0;
INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id)
 SELECT 'queue/stopped',1,'s-config',t.workspace,t.provider,t.model,t.instructions_content_id,0,t.tools_mask,t.permission_mode,t.output_schema_content_id FROM session t WHERE t.session_ref='queue/template' AND %[2]d>0;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[2]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[2]d)
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 's-msg-'||i,2,'queue/stopped',randomblob(32),(SELECT v FROM q),NULL,1,'accepted',1,0 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[2]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[2]d)
INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id)
 SELECT 1000100+i,'queue/stopped','s-msg-'||i,(SELECT v FROM q),NULL FROM n;
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 's-stop',3,'queue/stopped',randomblob(32),NULL,NULL,1,'accepted',1,0 WHERE %[2]d>0;
INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff)
 SELECT 's-stop','queue/stopped',NULL,1000100+%[2]d WHERE %[2]d>0;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 'e-config-'||i,1,'queue/eligible/'||printf('%%06d',i),randomblob(32),NULL,NULL,1,'accepted',1,1 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO session(session_ref,workspace,provider,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position)
 SELECT 'queue/eligible/'||printf('%%06d',i),t.workspace,t.provider,t.model,t.instructions_content_id,t.tools_mask,t.permission_mode,t.output_schema_content_id,1,1 FROM n CROSS JOIN session t WHERE t.session_ref='queue/template';
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id)
 SELECT 'queue/eligible/'||printf('%%06d',i),1,'e-config-'||i,t.workspace,t.provider,t.model,t.instructions_content_id,0,t.tools_mask,t.permission_mode,t.output_schema_content_id FROM n CROSS JOIN session t WHERE t.session_ref='queue/template';
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created)
 SELECT 'e-msg-'||i,2,'queue/eligible/'||printf('%%06d',i),randomblob(32),(SELECT v FROM q),NULL,1,'accepted',1,0 FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id)
 SELECT 2000100+i,'queue/eligible/'||printf('%%06d',i),'e-msg-'||i,(SELECT v FROM q),NULL FROM n;
DROP TABLE q; COMMIT;`, p.History, p.Ineligible, p.Eligible)
	if _, err := sql(deadline, sqliteBinary, store, query); err != nil {
		return err
	}
	check, err := sql(deadline, sqliteBinary, store, `SELECT 'foreign-key:'||count(*) FROM pragma_foreign_key_check HAVING count(*)!=0
UNION ALL SELECT 'history:'||count(*) FROM model_operation WHERE session_ref='queue/template' HAVING count(*)!=`+strconv.Itoa(p.History)+`
UNION ALL SELECT 'ineligible:'||count(*) FROM message_admission WHERE session_ref='queue/stopped' HAVING count(*)!=`+strconv.Itoa(p.Ineligible)+`
UNION ALL SELECT 'eligible:'||count(*) FROM message_admission WHERE session_ref LIKE 'queue/eligible/%' HAVING count(*)!=`+strconv.Itoa(p.Eligible)+`
UNION ALL SELECT 'history-projection:'||count(*) FROM conversation_entry WHERE session_ref='queue/template' HAVING count(*)!=`+strconv.Itoa(p.History)+`
UNION ALL SELECT 'history-position:'||next_position FROM session WHERE session_ref='queue/template' AND next_position!=`+strconv.Itoa(2*p.History+1)+`
UNION ALL SELECT 'history-resolution:'||count(*) FROM model_operation o JOIN turn t ON t.turn_id=o.turn_id WHERE o.session_ref='queue/template' AND (o.resolution_code!='provider_http_422' OR t.outcome_code!=o.resolution_code) HAVING count(*)!=0;`)
	if err != nil {
		return err
	}
	if check != "" {
		return fmt.Errorf("invalid controlled population: %s", check)
	}
	return nil
}

func expectedOrder(count int) []string {
	result := make([]string, count)
	for i := range result {
		result[i] = fmt.Sprintf("queue/eligible/%06d", i+1)
	}
	return result
}

func parseExecutionFacts(rows string) (executionFacts, error) {
	result := executionFacts{Messages: []messageExecutionFact{}, Turns: []turnExecutionFact{}, Operations: []operationExecutionFact{}}
	if rows == "" {
		return result, nil
	}
	for _, row := range strings.Split(rows, "\n") {
		fields := strings.Split(row, "|")
		if len(fields) == 4 && fields[0] == "M" {
			turnID, err := parseOptionalIdentity(fields[3])
			if err != nil {
				return result, fmt.Errorf("malformed message execution fact %q", row)
			}
			result.Messages = append(result.Messages, messageExecutionFact{fields[1], fields[2], turnID})
			continue
		}
		if len(fields) == 5 && fields[0] == "T" {
			turnID, turnErr := parseOptionalIdentity(fields[1])
			operationID, operationErr := parseOptionalIdentity(fields[3])
			if turnErr != nil || operationErr != nil {
				return result, fmt.Errorf("malformed Turn execution fact %q", row)
			}
			result.Turns = append(result.Turns, turnExecutionFact{turnID, fields[2], operationID, fields[4]})
			continue
		}
		if len(fields) == 5 && fields[0] == "O" {
			operationID, operationErr := parseOptionalIdentity(fields[1])
			turnID, turnErr := parseOptionalIdentity(fields[2])
			if operationErr != nil || turnErr != nil {
				return result, fmt.Errorf("malformed Operation execution fact %q", row)
			}
			result.Operations = append(result.Operations, operationExecutionFact{operationID, turnID, fields[3], fields[4]})
			continue
		}
		return result, fmt.Errorf("malformed execution fact %q", row)
	}
	return result, nil
}

func parseOptionalIdentity(value string) (int64, error) {
	if value == "" {
		return 0, nil
	}
	return strconv.ParseInt(value, 10, 64)
}

func auditExecutions(facts executionFacts, expected []string, providerRequests int64) ([]string, error) {
	actual := make([]string, 0, len(facts.Operations))
	for _, operation := range facts.Operations {
		actual = append(actual, operation.Session)
	}
	if len(facts.Messages) != len(expected) || len(facts.Turns) != len(expected) || len(facts.Operations) != len(expected) {
		return actual, fmt.Errorf("eligible execution counts messages=%d turns=%d Operations=%d want=%d", len(facts.Messages), len(facts.Turns), len(facts.Operations), len(expected))
	}
	if providerRequests != int64(len(expected)) {
		return actual, fmt.Errorf("provider request count=%d want=%d", providerRequests, len(expected))
	}
	for index := range expected {
		if actual[index] != expected[index] {
			return actual, fmt.Errorf("Operation admission order[%d]=%q want=%q", index, actual[index], expected[index])
		}
	}
	turns := make(map[int64]turnExecutionFact, len(facts.Turns))
	for _, turn := range facts.Turns {
		turns[turn.TurnID] = turn
	}
	operations := make(map[int64]operationExecutionFact, len(facts.Operations))
	for _, operation := range facts.Operations {
		operations[operation.OperationID] = operation
	}
	if len(turns) != len(facts.Turns) || len(operations) != len(facts.Operations) {
		return actual, errors.New("duplicate Turn or Operation identity")
	}
	for index, message := range facts.Messages {
		expectedKey := fmt.Sprintf("e-msg-%d", index+1)
		turn, turnOK := turns[message.TurnID]
		operation, operationOK := operations[turn.OperationID]
		if message.CommandKey != expectedKey || message.Session != expected[index] || message.TurnID <= 0 || !turnOK ||
			turn.Session != expected[index] || turn.Outcome != "provider_http_422" || turn.OperationID <= 0 || !operationOK ||
			operation.TurnID != turn.TurnID || operation.Session != expected[index] || operation.Resolution != "provider_http_422" {
			return actual, fmt.Errorf("execution[%d] message=%+v turn=%+v operation=%+v", index, message, turn, operation)
		}
	}
	return actual, nil
}

func physicalFootprintStatus(footprint measurement.Footprint) (string, uint64) {
	upper := footprint.LifetimePeakBytes + footprint.LifetimePeakTolerance
	if upper > physicalFootprintTargetBytes {
		return "target_miss", upper
	}
	return "passed", upper
}

func recordBehaviorFailure(result map[string]any, failure string) {
	if failure == "" {
		return
	}
	failures, _ := result["behavior_failures"].([]string)
	failures = append(failures, failure)
	result["behavior_failures"] = failures
	result["behavior_failure"] = failures[0]
	result["status"] = overallStatus(result["status"].(string), "behavior_error")
}

func recordTerminalObservation(result map[string]any, observation map[string]any, observationError error) {
	if observation != nil {
		result["last_message_observation"] = observation
	}
	if observationError != nil {
		recordBehaviorFailure(result, "terminal observation: "+observationError.Error())
		return
	}
	status, statusOK := measurement.StringField(observation, "result", "status")
	code, codeOK := measurement.StringField(observation, "result", "code")
	if !statusOK || !codeOK || status != "failed" || code != "provider_http_422" {
		recordBehaviorFailure(result, fmt.Sprintf("last message result status=%q code=%q", status, code))
	}
}

func recordAdmissionOrder(result map[string]any, actual, expected []string, settlementError error) {
	result["operation_admission_order"] = actual
	result["expected_oldest_first_admission_order"] = expected
	failure := ""
	if settlementError != nil {
		failure = settlementError.Error()
	} else if len(actual) != len(expected) {
		failure = fmt.Sprintf("operation order count=%d want=%d", len(actual), len(expected))
	} else {
		for i := range expected {
			if actual[i] != expected[i] {
				failure = fmt.Sprintf("operation order[%d]=%q want=%q", i, actual[i], expected[i])
				break
			}
		}
	}
	recordBehaviorFailure(result, failure)
}

func retainCaseFailure(result map[string]any, p population, caseError error) map[string]any {
	if result == nil {
		result = map[string]any{"population": p, "capacity": 1, "discovery_target_ms": discoveryTargetMS, "target_inclusive": true}
	}
	if _, ok := result["status"]; !ok {
		result["status"] = "passed"
	}
	result["case_error"] = caseError.Error()
	recordBehaviorFailure(result, "case execution: "+caseError.Error())
	return result
}

func failureExitCode(status string, provenanceErrors ...error) int {
	if status == "behavior_error" || errors.Join(provenanceErrors...) != nil {
		return 1
	}
	return 0
}

func runCase(binary, sqliteBinary, root, name string, p population, resources bool) (map[string]any, error) {
	result := map[string]any{"population": p, "capacity": 1, "discovery_target_ms": discoveryTargetMS, "target_inclusive": true}
	directory := filepath.Join(root, name)
	if err := os.Mkdir(directory, 0o700); err != nil {
		return result, fmt.Errorf("create case directory: %w", err)
	}
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(5 * time.Minute)
	if err := initializeTemplate(binary, sqliteBinary, directory, store, deadline); err != nil {
		return result, fmt.Errorf("initialize template: %w", err)
	}
	if err := populate(deadline, sqliteBinary, store, p); err != nil {
		return result, fmt.Errorf("populate Store: %w", err)
	}
	e, err := startEndpoint()
	if err != nil {
		return result, fmt.Errorf("start provider endpoint: %w", err)
	}
	defer e.server.Close()
	started := time.Now()
	host, err := measurement.StartHost(binary, store, e.URL(), 1, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		e.Release()
		return result, fmt.Errorf("start Host: %w", err)
	}
	var first time.Time
	select {
	case first = <-e.first:
	case <-time.After(10 * time.Second):
		e.Release()
		result["status"] = caseStatus(true, false, 0)
		recordBehaviorFailure(result, "missing_first_provider_request")
		if stopError := host.Stop(measurement.TeardownAllowance); stopError != nil {
			result["host_stop_error"] = stopError.Error()
			recordBehaviorFailure(result, "Host stop after missing first request: "+stopError.Error())
		}
		return result, nil
	}
	discoveryMS := first.Sub(started).Milliseconds()
	result["discovery_ms"] = discoveryMS
	result["status"] = caseStatus(false, true, discoveryMS)
	if resources {
		var sample measurement.PortableProcessSample
		var sampleErr error
		physicalStatus := "unavailable"
		if runtime.GOOS == "darwin" {
			macOSSample, macOSSampleErr := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-held.txt"))
			sampleErr = macOSSampleErr
			if macOSSampleErr != nil {
				result["macos_physical_footprint"] = map[string]any{"status": "unavailable", "error": macOSSampleErr.Error()}
			} else {
				sample = macOSSample.Portable()
				var upper uint64
				physicalStatus, upper = physicalFootprintStatus(macOSSample.Footprint)
				result["macos_physical_footprint"] = map[string]any{"status": physicalStatus, "target_bytes": physicalFootprintTargetBytes, "lifetime_peak_upper_bound_bytes": upper, "process": macOSSample}
			}
		} else {
			sample, sampleErr = measurement.SamplePortableProcess(host.Process)
			result["macos_physical_footprint"] = map[string]any{"status": "unavailable", "target_bytes": physicalFootprintTargetBytes, "reason": "requires macOS footprint(1)"}
		}
		if sampleErr != nil {
			result["resource_collection_status"] = "unavailable"
			result["resource_error"] = sampleErr.Error()
		} else {
			database, databaseErr := measurement.DatabaseSize(store)
			if databaseErr != nil {
				e.Release()
				return result, fmt.Errorf("sample database: %w", errors.Join(databaseErr, host.Stop(measurement.TeardownAllowance)))
			}
			result["resource_collection_status"] = "passed"
			result["held_first_request_resources"] = map[string]any{"process": sample, "ready_record": host.Ready, "database": database}
		}
		result["resource_status"] = physicalStatus
		result["status"] = overallStatus(result["status"].(string), physicalStatus)
	}
	e.Release()
	settlementStarted := time.Now()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	observation, observationError := client.WaitResult(fmt.Sprintf("e-msg-%d", p.Eligible))
	stopError := host.Stop(measurement.TeardownAllowance)
	result["terminal_observation_ms"] = time.Since(settlementStarted).Milliseconds()
	recordTerminalObservation(result, observation, observationError)
	if stopError != nil {
		result["host_stop_error"] = stopError.Error()
		recordBehaviorFailure(result, "Host stop after settlement observation: "+stopError.Error())
	}
	auditDeadline := measurement.NewDeadline(15 * time.Second)
	// Enumerate the closure of Messages, Turns and Operations touching the
	// controlled Sessions so no entity can hide behind another's current pointer.
	rows, auditQueryError := sql(auditDeadline, sqliteBinary, store, executionAuditSQL)
	expected := expectedOrder(p.Eligible)
	providerRequests := e.Requests()
	result["provider_request_count"] = providerRequests
	result["expected_provider_request_count"] = p.Eligible
	if auditQueryError != nil {
		result["execution_audit_error"] = auditQueryError.Error()
		recordAdmissionOrder(result, []string{}, expected, fmt.Errorf("execution audit query: %w", auditQueryError))
		return result, nil
	}
	facts, parseError := parseExecutionFacts(rows)
	result["execution_facts"] = facts
	actual, executionError := auditExecutions(facts, expected, providerRequests)
	recordAdmissionOrder(result, actual, expected, errors.Join(parseError, executionError))
	return result, nil
}

func main() {
	output := flag.String("output", "", "write JSON to path")
	flag.Parse()
	if flag.NArg() != 2 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-queue [--output path] /absolute/path/to/rui /absolute/path/to/pinned-sqlite3")
		os.Exit(2)
	}
	if err := measurement.RequireGoRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, _ := filepath.Abs(flag.Arg(0))
	sqliteBinary, _ := filepath.Abs(flag.Arg(1))
	root, err := os.MkdirTemp("", "rui-model-queue-")
	if err != nil {
		panic(err)
	}
	type namedPopulation struct {
		name       string
		population population
	}
	requested := []namedPopulation{
		{"baseline", population{0, 0, 1}}, {"history-1000", population{1000, 0, 1}}, {"history-10000", population{10000, 0, 1}},
		{"ineligible-0", population{0, 0, 1}}, {"ineligible-100", population{0, 100, 1}}, {"ineligible-1000", population{0, 1000, 1}},
		{"eligible-1", population{0, 0, 1}}, {"eligible-10", population{0, 0, 10}}, {"eligible-100", population{0, 0, 100}},
	}
	cases := map[string]any{}
	byPopulation := map[population]string{}
	statuses := []string{}
	for _, requestedCase := range requested {
		if existing, ok := byPopulation[requestedCase.population]; ok {
			cases[requestedCase.name] = map[string]any{"same_measurement_as": existing, "population": requestedCase.population}
			continue
		}
		value, caseErr := runCase(binary, sqliteBinary, root, requestedCase.name, requestedCase.population, true)
		if caseErr != nil {
			value = retainCaseFailure(value, requestedCase.population, caseErr)
		}
		cases[requestedCase.name] = value
		byPopulation[requestedCase.population] = requestedCase.name
		statuses = append(statuses, value["status"].(string))
	}
	mixed, err := runCase(binary, sqliteBinary, root, "maximum-mixed", population{10000, 1000, 100}, true)
	if err != nil {
		mixed = retainCaseFailure(mixed, population{10000, 1000, 100}, err)
	}
	statuses = append(statuses, mixed["status"].(string))
	status := overallStatus(statuses...)
	result := map[string]any{
		"format": "rui-model-queue-v1-go", "scope": "issue-202 production model-only queue discovery, Operation admission order, settlement, and resource observation",
		"status": status, "cases": cases, "maximum_mixed": mixed, "artifacts": root,
		"classification_legend": map[string]string{"behavior_failure": "runner exits nonzero", "unavailable": "a required measurement could not be validly collected", "target_miss": "a valid required measurement exceeds its target", "passed": "behavior and every valid required measurement pass their targets", "diagnostic": "reported observation such as terminal-observation duration; not a qualification target"},
		"limits":                []string{"model-only qualification; Bash composition remains GitHub issue #168", "Linux runtime results are development evidence under the current platform contract; macOS physical footprint is reported only when available", "deterministic loopback HTTP; no TLS or live-provider behavior", "Rui's pinned SQLite builds controlled populations in stopped Stores, but subsequent Host discovery, Operation admission, provider request, and settlement are authoritative", "Operation IDs prove admission order, not independent provider-request launch identity", "process termination is not power-loss qualification", "population sizes are qualification workloads, not product quotas"},
	}
	evidence, environmentError := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, *output)
	if environmentError != nil {
		result["environment_evidence_status"] = "unavailable"
		result["environment_evidence_error"] = environmentError.Error()
		status = overallStatus(status, "unavailable")
		result["status"] = status
	} else {
		result["environment_evidence_status"] = "passed"
		for key, value := range evidence {
			result[key] = value
		}
	}
	sqliteHash, sqliteHashError := measurement.SHA256File(sqliteBinary)
	if sqliteHashError != nil {
		result["sqlite_binary_status"] = "unavailable"
		result["sqlite_binary_error"] = sqliteHashError.Error()
		status = overallStatus(status, "unavailable")
		result["status"] = status
	} else {
		result["sqlite_binary_status"] = "passed"
		result["sqlite_binary"] = sqliteBinary
		result["sqlite_binary_sha256"] = sqliteHash
	}
	if *output != "" {
		err = measurement.WriteJSON(*output, result)
	} else {
		err = measurement.EncodeJSON(os.Stdout, result)
	}
	if err != nil {
		panic(err)
	}
	if exitCode := failureExitCode(status, environmentError, sqliteHashError); exitCode != 0 {
		os.Exit(exitCode)
	}
}
