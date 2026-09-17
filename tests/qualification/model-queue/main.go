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
	"time"

	"rui.local/qualification/measurement"
)

const discoveryTargetMS int64 = 2000

type population struct {
	History    int `json:"history"`
	Ineligible int `json:"ineligible_stopped_pending"`
	Eligible   int `json:"eligible"`
}

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
INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position)
 SELECT 'queue/stopped',t.workspace,t.model,t.instructions_content_id,t.tools_mask,t.permission_mode,t.output_schema_content_id,1,1 FROM session t WHERE t.session_ref='queue/template' AND %[2]d>0;
INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id)
 SELECT 'queue/stopped',1,'s-config',t.workspace,t.model,t.instructions_content_id,0,t.tools_mask,t.permission_mode,t.output_schema_content_id FROM session t WHERE t.session_ref='queue/template' AND %[2]d>0;
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
INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position)
 SELECT 'queue/eligible/'||printf('%%06d',i),t.workspace,t.model,t.instructions_content_id,t.tools_mask,t.permission_mode,t.output_schema_content_id,1,1 FROM n CROSS JOIN session t WHERE t.session_ref='queue/template';
WITH RECURSIVE n(i) AS (SELECT 1 WHERE %[3]d>0 UNION ALL SELECT i+1 FROM n WHERE i<%[3]d)
INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id)
 SELECT 'queue/eligible/'||printf('%%06d',i),1,'e-config-'||i,t.workspace,t.model,t.instructions_content_id,0,t.tools_mask,t.permission_mode,t.output_schema_content_id FROM n CROSS JOIN session t WHERE t.session_ref='queue/template';
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

func settledOrder(rows string) ([]string, error) {
	result := []string{}
	if rows == "" {
		return result, nil
	}
	for _, row := range strings.Split(rows, "\n") {
		session, resolution, ok := strings.Cut(row, "|")
		if !ok || resolution != "provider_http_422" {
			return nil, fmt.Errorf("behavior failure: operation settlement %q", row)
		}
		result = append(result, session)
	}
	return result, nil
}

func runCase(binary, sqliteBinary, root, name string, p population, resources bool) (map[string]any, error) {
	directory := filepath.Join(root, name)
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(5 * time.Minute)
	if err := initializeTemplate(binary, sqliteBinary, directory, store, deadline); err != nil {
		return nil, err
	}
	if err := populate(deadline, sqliteBinary, store, p); err != nil {
		return nil, err
	}
	maximumText, err := sql(deadline, sqliteBinary, store, "SELECT coalesce(max(operation_id),0) FROM model_operation;")
	if err != nil {
		return nil, err
	}
	launchFloor, err := strconv.ParseInt(maximumText, 10, 64)
	if err != nil {
		return nil, err
	}
	e, err := startEndpoint()
	if err != nil {
		return nil, err
	}
	defer e.server.Close()
	started := time.Now()
	host, err := measurement.StartHost(binary, store, e.URL(), 1, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		e.Release()
		return nil, err
	}
	result := map[string]any{"population": p, "capacity": 1, "discovery_target_ms": discoveryTargetMS, "target_inclusive": true}
	var first time.Time
	select {
	case first = <-e.first:
	case <-time.After(10 * time.Second):
		e.Release()
		if err := host.Stop(measurement.TeardownAllowance); err != nil {
			return nil, err
		}
		result["status"] = caseStatus(true, false, 0)
		result["behavior_failure"] = "missing_first_provider_request"
		return result, nil
	}
	discoveryMS := first.Sub(started).Milliseconds()
	result["discovery_ms"] = discoveryMS
	result["status"] = caseStatus(false, true, discoveryMS)
	if resources {
		var sample measurement.PortableProcessSample
		var sampleErr error
		if runtime.GOOS == "darwin" {
			macOSSample, macOSSampleErr := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-held.txt"))
			sampleErr = macOSSampleErr
			if macOSSampleErr != nil {
				result["macos_physical_footprint"] = map[string]any{"status": "unavailable", "error": macOSSampleErr.Error()}
			} else {
				sample = macOSSample.Portable()
				result["macos_physical_footprint"] = map[string]any{"status": "passed", "process": macOSSample}
			}
		} else {
			sample, sampleErr = measurement.SamplePortableProcess(host.Process)
			result["macos_physical_footprint"] = map[string]any{"status": "unavailable", "reason": "requires macOS footprint(1)"}
		}
		if sampleErr != nil {
			result["resource_status"] = "unavailable"
			result["resource_error"] = sampleErr.Error()
			result["status"] = overallStatus(result["status"].(string), "unavailable")
		} else {
			database, databaseErr := measurement.DatabaseSize(store)
			if databaseErr != nil {
				e.Release()
				return nil, errors.Join(databaseErr, host.Stop(measurement.TeardownAllowance))
			}
			result["resource_status"] = "passed"
			result["held_first_request_resources"] = map[string]any{"process": sample, "ready_record": host.Ready, "database": database}
		}
	}
	e.Release()
	settlementStarted := time.Now()
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	_, err = client.WaitResult(fmt.Sprintf("e-msg-%d", p.Eligible))
	err = errors.Join(err, host.Stop(measurement.TeardownAllowance))
	if err != nil {
		return nil, err
	}
	result["terminal_observation_ms"] = time.Since(settlementStarted).Milliseconds()
	rows, err := sql(deadline, sqliteBinary, store, fmt.Sprintf("SELECT session_ref||'|'||coalesce(resolution_code,'') FROM model_operation WHERE operation_id>%d ORDER BY operation_id;", launchFloor))
	if err != nil {
		return nil, err
	}
	actual, err := settledOrder(rows)
	if err != nil {
		return nil, err
	}
	expected := expectedOrder(p.Eligible)
	result["operation_launch_order"] = actual
	result["expected_oldest_first_order"] = expected
	if len(actual) != len(expected) {
		return nil, fmt.Errorf("behavior failure: operation order count=%d want=%d", len(actual), len(expected))
	}
	for i := range expected {
		if actual[i] != expected[i] {
			return nil, fmt.Errorf("behavior failure: operation order[%d]=%q want=%q", i, actual[i], expected[i])
		}
	}
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
		value, caseErr := runCase(binary, sqliteBinary, root, requestedCase.name, requestedCase.population, false)
		if caseErr != nil {
			panic(caseErr)
		}
		cases[requestedCase.name] = value
		byPopulation[requestedCase.population] = requestedCase.name
		statuses = append(statuses, value["status"].(string))
	}
	mixed, err := runCase(binary, sqliteBinary, root, "maximum-mixed", population{10000, 1000, 100}, true)
	if err != nil {
		panic(err)
	}
	statuses = append(statuses, mixed["status"].(string))
	status := overallStatus(statuses...)
	result := map[string]any{
		"format": "rui-model-queue-v1-go", "scope": "issue-202 production model-only queue discovery, order, settlement, and resource observation",
		"status": status, "cases": cases, "maximum_mixed": mixed, "artifacts": root,
		"classification_legend": map[string]string{"behavior_failure": "runner exits nonzero", "unavailable": "required discovery timestamp/counter could not be validly measured", "target_miss": "valid discovery exceeds the inclusive 2000 ms target", "passed": "behavior passed and valid discovery is at most 2000 ms", "diagnostic": "reported observation such as terminal-observation duration; not a qualification target"},
		"limits":                []string{"model-only qualification; Bash composition remains GitHub issue #168", "Linux runtime results are development evidence under the current platform contract; macOS physical footprint is reported only when available", "deterministic loopback HTTP; no TLS or live-provider behavior", "Rui's pinned SQLite builds controlled populations in stopped Stores, but subsequent Host discovery, admission, launch, and settlement are authoritative", "process termination is not power-loss qualification", "population sizes are qualification workloads, not product quotas"},
	}
	evidence, err := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, *output)
	if err != nil {
		panic(err)
	}
	for key, value := range evidence {
		result[key] = value
	}
	sqliteHash, err := measurement.SHA256File(sqliteBinary)
	if err != nil {
		panic(err)
	}
	result["sqlite_binary"] = sqliteBinary
	result["sqlite_binary_sha256"] = sqliteHash
	if *output != "" {
		err = measurement.WriteJSON(*output, result)
	} else {
		err = measurement.EncodeJSON(os.Stdout, result)
	}
	if err != nil {
		panic(err)
	}
	if status == "behavior_error" {
		os.Exit(1)
	}
}
