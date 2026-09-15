package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"latifa.local/research/measurement"
)

const capacity = 16
const operationsPerRound = 32
const rounds = 5

func discoveryStatus(milliseconds int64) string {
	if milliseconds > 2000 {
		return "target_miss"
	}
	return "passed"
}

func idleStatus(percentOneCore float64) string {
	if percentOneCore >= 1 {
		return "target_miss"
	}
	return "passed"
}

func retryStatus(results ...map[string]any) string {
	for _, result := range results {
		if result["status"] == "target_miss" {
			return "target_miss"
		}
	}
	return "passed"
}

type retryEndpoint struct {
	server   *http.Server
	listener net.Listener
	mu       sync.Mutex
	counts   map[string]int
	launches map[string][]int64
}

func startEndpoint() (*retryEndpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	e := &retryEndpoint{listener: listener, counts: map[string]int{}, launches: map[string][]int64{}}
	e.server = &http.Server{Handler: http.HandlerFunc(e.serve)}
	go e.server.Serve(listener)
	return e, nil
}

func requestMarker(body []byte) (string, error) {
	var value struct {
		Input []struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	if err := json.Unmarshal(body, &value); err != nil {
		return "", err
	}
	for _, item := range value.Input {
		if item.Role == "user" {
			for _, content := range item.Content {
				if content.Type == "input_text" {
					return content.Text, nil
				}
			}
		}
	}
	return "", errors.New("request marker unavailable")
}

func (e *retryEndpoint) serve(writer http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return
	}
	marker, err := requestMarker(body)
	if err != nil {
		http.Error(writer, err.Error(), 400)
		return
	}
	e.mu.Lock()
	ordinal := e.counts[marker] + 1
	e.counts[marker] = ordinal
	e.launches[marker] = append(e.launches[marker], time.Now().UnixMilli())
	e.mu.Unlock()
	status := http.StatusUnprocessableEntity
	if ordinal == 1 {
		status = http.StatusServiceUnavailable
	}
	payload := []byte(fmt.Sprintf("fixture-%d", status))
	writer.Header().Set("Connection", "close")
	writer.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	writer.WriteHeader(status)
	_, _ = writer.Write(payload)
}

func (e *retryEndpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *retryEndpoint) count(marker string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.counts[marker]
}
func (e *retryEndpoint) total(prefix string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	total := 0
	for marker, count := range e.counts {
		if strings.HasPrefix(marker, prefix) {
			total += count
		}
	}
	return total
}
func (e *retryEndpoint) launch(marker string, index int) int64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.launches[marker]) <= index {
		return 0
	}
	return e.launches[marker][index]
}
func (e *retryEndpoint) exact(prefix string, want int) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	for marker, count := range e.counts {
		if strings.HasPrefix(marker, prefix) && count != want {
			return false
		}
	}
	return true
}
func (e *retryEndpoint) Close() error { return e.server.Close() }

func startHost(deadline measurement.Deadline, binary, store, url, artifacts string, capacity int, extra ...string) (*measurement.Host, error) {
	arguments := []string{"--test-retry-waits-ms", "50,100,150"}
	arguments = append(arguments, extra...)
	return measurement.StartHost(binary, store, url, capacity, filepath.Join(artifacts, "host-stderr-"+strconv.FormatInt(time.Now().UnixNano(), 10)+".log"), deadline, arguments...)
}

func custodyZero(client measurement.Client, session string) (bool, error) {
	inspection, err := client.Inspect(session)
	if err != nil {
		return false, err
	}
	value, ok := measurement.IntStringField(inspection, "execution", "custody_occupied")
	return ok && value == 0, nil
}

func sql(deadline measurement.Deadline, store, query string) (string, error) {
	output, err := measurement.Run(deadline, "/usr/bin/sqlite3", "-noheader", filepath.Join(store, "latifa.sqlite3"), query)
	return strings.TrimSpace(string(output)), err
}

func timing(binary, root string, e *retryEndpoint) (map[string]any, error) {
	directory := filepath.Join(root, "timing")
	_ = os.Mkdir(directory, 0o700)
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(2 * time.Minute)
	marker := "timing-operation"
	session := "measure/timing"
	host, err := startHost(deadline, binary, store, e.URL(), directory, 1, "--test-retry-waits-ms", "600000,600000,600000")
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	work := func() error {
		if err := client.Submit("timing", session, marker); err != nil {
			return err
		}
		if err := measurement.WaitFor(deadline, 10*time.Millisecond, "initial temporary response", func() (bool, error) { return e.count(marker) == 1, nil }); err != nil {
			return err
		}
		return measurement.WaitFor(deadline, 10*time.Millisecond, "initial cleanup", func() (bool, error) { return custodyZero(client, session) })
	}()
	if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
		return nil, err
	}
	row, err := sql(deadline, store, "SELECT operation_id||','||attempt_ordinal||','||allowance_used||','||uncertain||','||ifnull(resolution_code,'') FROM model_operation;")
	if err != nil {
		return nil, err
	}
	parts := strings.Split(row, ",")
	if len(parts) != 5 || strings.Join(parts[1:], ",") != "1,1,0," {
		return nil, fmt.Errorf("unexpected initial retry facts: %s", row)
	}
	due := time.Now().UnixMilli() + 250
	if _, err := sql(deadline, store, fmt.Sprintf("UPDATE model_operation SET retry_due_at_ms=%d WHERE operation_id=%s;", due, parts[0])); err != nil {
		return nil, err
	}
	started := time.Now().UnixMilli()
	host, err = startHost(deadline, binary, store, e.URL(), directory, 1, "--test-before-launch-delay-ms", "250", "--test-retry-waits-ms", "600000,600000,600000")
	if err != nil {
		return nil, err
	}
	client = measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	var admitted int64
	work = measurement.WaitFor(deadline, 10*time.Millisecond, "replacement admission", func() (bool, error) {
		zero, err := custodyZero(client, session)
		if err != nil {
			return false, err
		}
		if !zero {
			admitted = time.Now().UnixMilli()
			return true, nil
		}
		return false, nil
	})
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "replacement launch", func() (bool, error) { return e.count(marker) == 2, nil })
	}
	launched := e.launch(marker, 1)
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "replacement settlement", func() (bool, error) { return custodyZero(client, session) })
	}
	if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
		return nil, err
	}
	facts, err := sql(deadline, store, "SELECT attempt_ordinal||','||allowance_used||','||resolution_code FROM model_operation;")
	if err != nil || facts != "2,2,provider_http_422" {
		return nil, fmt.Errorf("unexpected timing retry facts: %s: %w", facts, err)
	}
	discoveryMS := admitted - due
	return map[string]any{"status": discoveryStatus(discoveryMS), "qualification_limit_ms": 2000, "retry_due_at_unix_ms": due, "host_started_at_unix_ms": started, "replacement_admitted_at_unix_ms": admitted, "replacement_launched_at_unix_ms": launched, "discovery_after_due_ms": discoveryMS, "launch_after_discovery_ms": launched - admitted, "configured_prelaunch_delay_ms": 250, "endpoint_attempts": e.count(marker)}, nil
}

func replaceDue(binary, directory, store, session, operation, marker string, modelOperations, future int, e *retryEndpoint, deadline measurement.Deadline) (map[string]any, error) {
	started := time.Now().UnixMilli()
	host, err := startHost(deadline, binary, store, e.URL(), directory, capacity, "--test-before-launch-delay-ms", "250", "--test-retry-waits-ms", "600000,600000,600000")
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	var admitted int64
	work := measurement.WaitFor(deadline, 10*time.Millisecond, "history replacement admission", func() (bool, error) {
		zero, err := custodyZero(client, session)
		if err != nil {
			return false, err
		}
		if !zero {
			admitted = time.Now().UnixMilli()
			return true, nil
		}
		return false, nil
	})
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "history replacement launch", func() (bool, error) { return e.count(marker) == 2, nil })
	}
	launched := e.launch(marker, 1)
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "history replacement settlement", func() (bool, error) { return custodyZero(client, session) })
	}
	if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
		return nil, err
	}
	facts, err := sql(deadline, store, "SELECT attempt_ordinal||','||allowance_used||','||resolution_code FROM model_operation WHERE operation_id="+operation+";")
	if err != nil || facts != "2,2,provider_http_422" {
		return nil, fmt.Errorf("unexpected replacement facts %s: %w", facts, err)
	}
	database, _ := os.Stat(filepath.Join(store, "latifa.sqlite3"))
	discoveryMS := admitted - started
	return map[string]any{"status": discoveryStatus(discoveryMS), "qualification_limit_ms": 2000, "model_operations": modelOperations, "older_unresolved_future_retries": future, "replacement_admitted_after_start_ms": discoveryMS, "replacement_launched_after_start_ms": launched - started, "database_bytes": database.Size()}, nil
}

func history(binary, root string, e *retryEndpoint) (map[string]any, error) {
	directory := filepath.Join(root, "history")
	_ = os.Mkdir(directory, 0o700)
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(8 * time.Minute)
	created := 0
	rows := []map[string]any{}
	for _, target := range []int{32, 128} {
		host, err := startHost(deadline, binary, store, e.URL(), directory, capacity, "--test-retry-waits-ms", "600000,600000,600000")
		if err != nil {
			return nil, err
		}
		client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
		work := func() error {
			for ordinal := created; ordinal < target; ordinal++ {
				session := fmt.Sprintf("measure/history-%d", ordinal)
				if err := client.Submit(fmt.Sprintf("history-%d", ordinal), session, fmt.Sprintf("history-operation-%d", ordinal)); err != nil {
					return err
				}
			}
			if err := measurement.WaitFor(deadline, 10*time.Millisecond, "initial history attempts", func() (bool, error) { return e.total("history-operation-") == target+len(rows), nil }); err != nil {
				return err
			}
			return measurement.WaitFor(deadline, 10*time.Millisecond, "history cleanup", func() (bool, error) { return custodyZero(client, fmt.Sprintf("measure/history-%d", target-1)) })
		}()
		if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
			return nil, err
		}
		operation, err := sql(deadline, store, fmt.Sprintf("SELECT operation_id FROM model_operation WHERE session_ref='measure/history-%d';", target-1))
		if err != nil {
			return nil, err
		}
		if _, err := sql(deadline, store, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id="+operation+";"); err != nil {
			return nil, err
		}
		futureText, err := sql(deadline, store, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER);")
		if err != nil {
			return nil, err
		}
		future, err := strconv.Atoi(futureText)
		if err != nil {
			return nil, fmt.Errorf("parse future retry count %q: %w", futureText, err)
		}
		row, err := replaceDue(binary, directory, store, fmt.Sprintf("measure/history-%d", target-1), operation, fmt.Sprintf("history-operation-%d", target-1), target, future, e, deadline)
		if err != nil {
			return nil, err
		}
		rows = append(rows, row)
		created = target
	}
	insert := "PRAGMA foreign_keys=OFF; WITH RECURSIVE sequence(value) AS (VALUES(129) UNION ALL SELECT value+1 FROM sequence WHERE value<10128) INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) SELECT value,value,printf('synthetic-future-%d',value),1,1,1,1,1,0,9223372036854775807 FROM sequence;"
	if _, err := sql(deadline, store, insert); err != nil {
		return nil, err
	}
	host, err := startHost(deadline, binary, store, e.URL(), directory, capacity, "--test-retry-waits-ms", "600000,600000,600000")
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	cpuBefore, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	idleStarted := time.Now()
	time.Sleep(5 * time.Second)
	cpuAfter, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	idleElapsed := time.Since(idleStarted).Seconds()
	idleDelta, err := measurement.CheckedCPUDelta(cpuBefore, cpuAfter)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	idleCPU := 100 * idleDelta / idleElapsed
	work := client.Submit("history-10128", "measure/history-10128", "history-operation-10128")
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "10000 row attempt", func() (bool, error) { return e.count("history-operation-10128") == 1, nil })
	}
	if work == nil {
		work = measurement.WaitFor(deadline, 10*time.Millisecond, "10000 row cleanup", func() (bool, error) { return custodyZero(client, "measure/history-10128") })
	}
	if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
		return nil, err
	}
	operation, err := sql(deadline, store, "SELECT operation_id FROM model_operation WHERE session_ref='measure/history-10128';")
	if err != nil {
		return nil, err
	}
	if _, err := sql(deadline, store, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id="+operation+";"); err != nil {
		return nil, err
	}
	futureText, err := sql(deadline, store, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER);")
	if err != nil {
		return nil, err
	}
	future, err := strconv.Atoi(futureText)
	if err != nil {
		return nil, fmt.Errorf("parse future retry count %q: %w", futureText, err)
	}
	countText, err := sql(deadline, store, "SELECT count(*) FROM model_operation;")
	if err != nil {
		return nil, err
	}
	count, err := strconv.Atoi(countText)
	if err != nil {
		return nil, fmt.Errorf("parse operation count %q: %w", countText, err)
	}
	row, err := replaceDue(binary, directory, store, "measure/history-10128", operation, "history-operation-10128", count, future, e, deadline)
	if err != nil {
		return nil, err
	}
	rows = append(rows, row)
	historyStatus := idleStatus(idleCPU)
	for _, row := range rows {
		if row["status"] == "target_miss" {
			historyStatus = "target_miss"
		}
	}
	return map[string]any{"status": historyStatus, "stages": rows, "future_only_idle_cpu_percent_one_core": idleCPU, "future_only_idle_cpu_sample_seconds": idleElapsed, "discovery_qualification_limit_ms": 2000, "idle_cpu_qualification_limit_percent_one_core": 1}, nil
}

func churn(binary, root string, e *retryEndpoint) (map[string]any, error) {
	directory := filepath.Join(root, "churn")
	_ = os.Mkdir(directory, 0o700)
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(8 * time.Minute)
	host, err := startHost(deadline, binary, store, e.URL(), directory, capacity, "--test-cleanup-delay-ms", "250")
	if err != nil {
		return nil, err
	}
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: store, Deadline: deadline}
	baseline, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-baseline.txt"))
	if err != nil {
		return nil, err
	}
	rows := []map[string]any{}
	work := func() error {
		for round := 0; round < rounds; round++ {
			for index := 0; index < operationsPerRound; index++ {
				ordinal := round*operationsPerRound + index
				session := fmt.Sprintf("measure/churn-%d", ordinal)
				if err := client.Submit(fmt.Sprintf("churn-%d", ordinal), session, fmt.Sprintf("churn-operation-%d", ordinal)); err != nil {
					return err
				}
			}
			expected := (round + 1) * operationsPerRound
			if err := measurement.WaitFor(deadline, 10*time.Millisecond, "churn attempts", func() (bool, error) { return e.total("churn-operation-") == expected*2, nil }); err != nil {
				return err
			}
			if err := measurement.WaitFor(deadline, 10*time.Millisecond, "churn cleanup", func() (bool, error) { return custodyZero(client, fmt.Sprintf("measure/churn-%d", expected-1)) }); err != nil {
				return err
			}
			sample, err := measurement.SampleProcess(host.Process, filepath.Join(directory, fmt.Sprintf("footprint-round-%d.txt", round+1)))
			if err != nil {
				return err
			}
			database, _ := os.Stat(filepath.Join(store, "latifa.sqlite3"))
			rows = append(rows, map[string]any{"round": round + 1, "terminal_operations": expected, "database_bytes": database.Size(), "process": sample})
		}
		return nil
	}()
	if work == nil && !e.exact("churn-operation-", 2) {
		work = errors.New("a churn operation did not launch exactly twice")
	}
	cpuBefore, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	idleStarted := time.Now()
	time.Sleep(2 * time.Second)
	cpuAfter, err := measurement.CPUSeconds(host.Process)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	idleElapsed := time.Since(idleStarted).Seconds()
	idleDelta, err := measurement.CheckedCPUDelta(cpuBefore, cpuAfter)
	if err != nil {
		host.Stop(measurement.TeardownAllowance)
		return nil, err
	}
	retained, sampleErr := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-retained.txt"))
	if err := errors.Join(work, sampleErr, host.Stop(measurement.TeardownAllowance)); err != nil {
		return nil, err
	}
	groups, err := sql(deadline, store, "SELECT attempt_ordinal||','||allowance_used||','||resolution_code||','||count(*) FROM model_operation GROUP BY attempt_ordinal,allowance_used,resolution_code;")
	if err != nil || groups != fmt.Sprintf("2,2,provider_http_422,%d", rounds*operationsPerRound) {
		return nil, fmt.Errorf("unexpected churn facts: %s: %w", groups, err)
	}
	idleCPU := 100 * idleDelta / idleElapsed
	return map[string]any{"status": idleStatus(idleCPU), "active_capacity": capacity, "operations_per_round": operationsPerRound, "rounds": rows, "baseline": baseline, "custody_record_bytes": host.Ready["custody_record_bytes"], "execution_slot_bytes": host.Ready["execution_slot_bytes"], "idle_cpu_percent_one_core": idleCPU, "idle_cpu_sample_seconds": idleElapsed, "idle_cpu_qualification_limit_percent_one_core": 1, "retained_idle": retained, "attempt_fact_groups": groups}, nil
}

func main() {
	output := flag.String("output", "", "write JSON to path")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-retry [--output path] /absolute/path/to/latifa")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, _ := filepath.Abs(flag.Arg(0))
	root, err := os.MkdirTemp("/private/tmp", "latifa-retry-measure-")
	if err != nil {
		panic(err)
	}
	e, err := startEndpoint()
	if err != nil {
		panic(err)
	}
	defer e.Close()
	started := time.Now()
	timingResult, err := timing(binary, root, e)
	if err != nil {
		panic(err)
	}
	historyResult, err := history(binary, root, e)
	if err != nil {
		panic(err)
	}
	churnResult, err := churn(binary, root, e)
	if err != nil {
		panic(err)
	}
	result := map[string]any{"format": "latifa-model-retry-v2-go", "scope": "issue-174 production retry discovery and custody churn", "status": retryStatus(timingResult, historyResult, churnResult), "artifacts": root, "timing": timingResult, "unresolved_history": historyResult, "churn_and_delayed_cleanup": churnResult, "elapsed_seconds": time.Since(started).Seconds(), "limits": []string{"macOS Apple Silicon runtime evidence only", "deterministic loopback HTTP classifies no live-provider behavior", "a 250 ms fixture delay separates committed retry discovery from provider launch", "process termination evidence is not power-loss qualification"}}
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
