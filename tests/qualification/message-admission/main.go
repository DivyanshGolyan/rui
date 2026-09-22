package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"rui.local/qualification/measurement"
)

var payloadBytes = []int{0, 1_000, 10_000, 100_000}
var historyCounts = []int{0, 1, 10}

type optionalField struct {
	State string  `json:"state"`
	Value *string `json:"value,omitempty"`
}
type configurationFields struct {
	Workspace      optionalField `json:"workspace"`
	Provider       optionalField `json:"provider"`
	Model          optionalField `json:"model"`
	Instructions   optionalField `json:"instructions"`
	Tools          optionalField `json:"tools"`
	PermissionMode optionalField `json:"permission_mode"`
	OutputSchema   optionalField `json:"output_schema"`
}
type configurationCommand struct {
	Version       string              `json:"version"`
	Kind          string              `json:"kind"`
	Store         string              `json:"store"`
	Key           string              `json:"key"`
	Session       string              `json:"session"`
	Configuration configurationFields `json:"configuration"`
}
type messageCommand struct {
	Version string        `json:"version"`
	Kind    string        `json:"kind"`
	Store   string        `json:"store"`
	Key     string        `json:"key"`
	Session string        `json:"session"`
	Text    optionalField `json:"text"`
}
type observeCommand struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Key     string `json:"key"`
}
type inspectCommand struct {
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Store   string `json:"store"`
	Session string `json:"session"`
}

func field(value map[string]any, names ...string) any {
	current := any(value)
	for _, name := range names {
		object, ok := current.(map[string]any)
		if !ok {
			return nil
		}
		current = object[name]
	}
	return current
}

func configure(deadline measurement.Deadline, socket, store, workspace, session string) error {
	omitted := optionalField{State: "omitted"}
	provider := "codex"
	model := "measurement-model"
	value := configurationCommand{Version: "1", Kind: "configure", Store: store, Key: "configure-" + session, Session: session, Configuration: configurationFields{Workspace: optionalField{State: "value", Value: &workspace}, Provider: optionalField{State: "value", Value: &provider}, Model: optionalField{State: "value", Value: &model}, Instructions: omitted, Tools: omitted, PermissionMode: omitted, OutputSchema: omitted}}
	var response map[string]any
	if err := measurement.ExchangeUnix(deadline, socket, "/v1/configure", value, &response); err != nil {
		return err
	}
	if field(response, "answer", "status") != "accepted" {
		return fmt.Errorf("configuration failed: %v", response)
	}
	return nil
}

func messageValue(store, key, session, text string) messageCommand {
	return messageCommand{Version: "1", Kind: "message", Store: store, Key: key, Session: session, Text: optionalField{State: "value", Value: &text}}
}

func observeValue(store, key string) observeCommand {
	return observeCommand{Version: "1", Kind: "observe_command", Store: store, Key: key}
}

func inspectValue(store, session string) inspectCommand {
	return inspectCommand{Version: "1", Kind: "inspect_session", Store: store, Session: session}
}

func startHost(binary, directory string, deadline measurement.Deadline) (*measurement.Host, string, string, error) {
	store := filepath.Join(directory, "store")
	host, err := measurement.StartHost(binary, store, "", 1000, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, "", "", err
	}
	return host, host.Ready["store"], host.Ready["socket"], nil
}

func stageSample(host *measurement.Host, store, directory, name string) (map[string]any, error) {
	process, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-"+name+".txt"))
	if err != nil {
		return nil, err
	}
	database, err := measurement.DatabaseSize(store)
	if err != nil {
		return nil, err
	}
	return map[string]any{"process": process, "database": database}, nil
}

func payloadProfile(binary, workspace, parent string) ([]map[string]any, error) {
	var rows []map[string]any
	for _, size := range payloadBytes {
		row, err := payloadCase(binary, workspace, parent, size)
		if err != nil {
			return nil, err
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func payloadCase(binary, workspace, parent string, size int) (row map[string]any, resultError error) {
	directory := filepath.Join(parent, fmt.Sprintf("payload-%d", size))
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	deadline := measurement.NewDeadline(10 * time.Minute)
	host, store, socket, err := startHost(binary, directory, deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	session := "measure/payload"
	if err := configure(deadline, socket, store, workspace, session); err != nil {
		return nil, err
	}
	key := fmt.Sprintf("payload-%d", size)
	var answer map[string]any
	admissionMS, err := measurement.TimedExchangeUnix(
		deadline, socket, "/v1/message", messageValue(store, key, session, strings.Repeat("p", size)), &answer,
	)
	if err != nil {
		return nil, err
	}
	if field(answer, "answer", "status") != "accepted" || field(answer, "input", "bytes") != fmt.Sprint(size) {
		return nil, fmt.Errorf("payload admission differed: %v", answer)
	}
	var observation map[string]any
	observationMS, err := measurement.TimedExchangeUnix(
		deadline, socket, "/v1/observe-command", observeValue(store, key), &observation,
	)
	if err != nil {
		return nil, err
	}
	if field(observation, "observation", "queue", "status") != "queued" {
		return nil, fmt.Errorf("payload observation differed: %v", observation)
	}
	var inspection map[string]any
	if err := measurement.ExchangeUnix(deadline, socket, "/v1/inspect-session", inspectValue(store, session), &inspection); err != nil {
		return nil, err
	}
	if inspection["pending_messages"] != "1" {
		return nil, fmt.Errorf("payload pending count differed: %v", inspection)
	}
	time.Sleep(50 * time.Millisecond)
	sample, err := stageSample(host, store, directory, fmt.Sprint(size))
	if err != nil {
		return nil, err
	}
	row = map[string]any{
		"payload_bytes": size, "queued_messages": 1,
		"admission_elapsed_ms": admissionMS, "observation_elapsed_ms": observationMS,
		"sample": sample,
	}
	return row, nil
}

func historyProfile(binary, workspace, parent string) (rows []map[string]any, resultError error) {
	directory := filepath.Join(parent, "history")
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	deadline := measurement.NewDeadline(10 * time.Minute)
	host, store, socket, err := startHost(binary, directory, deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	session := "measure/history"
	if err := configure(deadline, socket, store, workspace, session); err != nil {
		return nil, err
	}
	admitted := 0
	lastAdmissionMS := any(nil)
	for _, target := range historyCounts {
		for admitted < target {
			key := fmt.Sprintf("history-%08d", admitted)
			var answer map[string]any
			elapsed, err := measurement.TimedExchangeUnix(deadline, socket, "/v1/message", messageValue(store, key, session, ""), &answer)
			if err != nil {
				return nil, err
			}
			if field(answer, "answer", "status") != "accepted" {
				return nil, fmt.Errorf("history admission differed: %v", answer)
			}
			lastAdmissionMS = elapsed
			admitted++
		}
		var inspection map[string]any
		inspectionMS, err := measurement.TimedExchangeUnix(deadline, socket, "/v1/inspect-session", inspectValue(store, session), &inspection)
		if err != nil {
			return nil, err
		}
		if inspection["pending_messages"] != fmt.Sprint(admitted) {
			return nil, fmt.Errorf("history pending count differed: %v", inspection)
		}
		row := map[string]any{
			"queued_messages":                admitted,
			"last_admission_elapsed_ms":      lastAdmissionMS,
			"session_observation_elapsed_ms": inspectionMS,
		}
		if admitted > 0 {
			for name, key := range map[string]string{
				"oldest_observation_elapsed_ms": "history-00000000",
				"newest_observation_elapsed_ms": fmt.Sprintf("history-%08d", admitted-1),
			} {
				var observation map[string]any
				elapsed, err := measurement.TimedExchangeUnix(deadline, socket, "/v1/observe-command", observeValue(store, key), &observation)
				if err != nil {
					return nil, err
				}
				if field(observation, "observation", "queue", "status") != "queued" {
					return nil, fmt.Errorf("history queue changed: %v", observation)
				}
				row[name] = elapsed
			}
		}
		time.Sleep(50 * time.Millisecond)
		sample, err := stageSample(host, store, directory, fmt.Sprint(admitted))
		if err != nil {
			return nil, err
		}
		row["sample"] = sample
		rows = append(rows, row)
	}
	return rows, nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: measure-message-admission /absolute/path/to/rui")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	started := time.Now()
	parent, err := os.MkdirTemp("/private/tmp", "rui-message-measure-")
	if err != nil {
		panic(err)
	}
	workspace, err := measurement.RepositoryRoot()
	if err != nil {
		panic(err)
	}
	payload, err := payloadProfile(os.Args[1], workspace, parent)
	if err != nil {
		panic(err)
	}
	history, err := historyProfile(os.Args[1], workspace, parent)
	if err != nil {
		panic(err)
	}
	result := map[string]any{
		"format": "rui-message-admission-v3-go",
		"scope":  "issue-171 production Host message admission and observation",
		"status": "passed", "artifacts": parent,
		"active_capacity":      1000,
		"client_capacity":      map[string]int{"total": 12, "ordinary": 10, "control_headroom": 2},
		"content_window_bytes": 4096, "sqlite_heap_limit_bytes": 16 * 1024 * 1024,
		"payload_growth": payload, "queued_history_growth": history,
		"elapsed_seconds": time.Since(started).Seconds(),
		"limits": []string{
			"macOS physical-footprint evidence only",
			"each payload size uses a fresh Host/Store with one verified queued message; history grows separately",
			"driver payload construction is excluded from Host counters",
			"model processing is intentionally unavailable in this experiment",
		},
	}
	evidence, err := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), os.Args[1], "")
	if err != nil {
		panic(err)
	}
	for name, value := range evidence {
		result[name] = value
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		panic(err)
	}
}
