package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"latifa.local/research/measurement"
)

var sessionCounts = []int{0, 100, 1_000, 10_000}
var peakCounter = regexp.MustCompile(`(?m)^\s*([0-9]+)\s+maximum resident set size\s*$`)

func clientPeak(binary, store string) (uint64, error) {
	var stderr bytes.Buffer
	command := exec.Command("/usr/bin/time", "-l", binary, "inspect-session", "--store", store, "--session", "measure/00000000")
	command.Stdout = io.Discard
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return 0, fmt.Errorf("direct client measurement: %w: %s", err, stderr.String())
	}
	match := peakCounter.FindStringSubmatch(stderr.String())
	if match == nil {
		return 0, errors.New("direct client peak RSS counter unavailable")
	}
	return strconv.ParseUint(match[1], 10, 64)
}

type optionalField struct {
	State string  `json:"state"`
	Value *string `json:"value,omitempty"`
}
type configurationFields struct {
	Workspace      optionalField `json:"workspace"`
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

func configuration(store, workspace, identity string) configurationCommand {
	omitted := optionalField{State: "omitted"}
	model := "measurement-model"
	return configurationCommand{Version: "1", Kind: "configure", Store: store, Key: identity, Session: identity, Configuration: configurationFields{Workspace: optionalField{State: "value", Value: &workspace}, Model: optionalField{State: "value", Value: &model}, Instructions: omitted, Tools: omitted, PermissionMode: omitted, OutputSchema: omitted}}
}

func run(binary string) (result map[string]any, resultError error) {
	started := time.Now()
	directory, err := os.MkdirTemp("/private/tmp", "latifa-configuration-measure-")
	if err != nil {
		return nil, err
	}
	store := filepath.Join(directory, "store")
	deadline := measurement.NewDeadline(10 * time.Minute)
	host, err := measurement.StartHost(binary, store, "", 1000, filepath.Join(directory, "host-stderr.log"), deadline)
	if err != nil {
		return nil, err
	}
	defer func() {
		measurement.JoinCleanup(&resultError, func() error { return host.Stop(measurement.TeardownAllowance) })
	}()
	canonicalStore, storeOK := host.Ready["store"]
	socketPath, socketOK := host.Ready["socket"]
	if !storeOK || !socketOK {
		return nil, errors.New("Host readiness omitted Store or socket")
	}
	workspace, err := measurement.RepositoryRoot()
	if err != nil {
		return nil, err
	}
	stages := make([]map[string]any, 0, len(sessionCounts))
	admitted := 0
	for _, target := range sessionCounts {
		for admitted < target {
			identity := fmt.Sprintf("measure/%08d", admitted)
			var answer struct {
				Answer struct {
					Status string `json:"status"`
				} `json:"answer"`
			}
			if err := measurement.ExchangeUnix(deadline, socketPath, "/v1/configure", configuration(canonicalStore, workspace, identity), &answer); err != nil {
				return nil, err
			}
			if answer.Answer.Status != "accepted" {
				return nil, fmt.Errorf("configuration %s was %s", identity, answer.Answer.Status)
			}
			admitted++
		}
		time.Sleep(100 * time.Millisecond)
		sample, err := measurement.SampleProcess(host.Process, filepath.Join(directory, fmt.Sprintf("footprint-%d.txt", admitted)))
		if err != nil {
			return nil, err
		}
		database, err := measurement.DatabaseSize(store)
		if err != nil {
			return nil, err
		}
		stage := map[string]any{"dormant_sessions": admitted, "process": sample, "database": database}
		stages = append(stages, stage)
	}
	peak, err := clientPeak(binary, store)
	if err != nil {
		return nil, err
	}
	result = map[string]any{
		"format":                       "latifa-configuration-admission-v2-go",
		"scope":                        "issue-170 production Host configuration admission",
		"status":                       "passed",
		"artifacts":                    directory,
		"active_capacity":              1000,
		"stages":                       stages,
		"direct_client_peak_rss_bytes": peak,
		"elapsed_seconds":              time.Since(started).Seconds(),
		"limits": []string{
			"macOS physical-footprint evidence only",
			"sequential configuration then idle sampling; not concurrent connection qualification",
			"driver work is excluded from Host counters",
		},
	}
	evidence, err := measurement.EnvironmentEvidence(deadline, binary, "")
	if err != nil {
		return nil, err
	}
	for name, value := range evidence {
		result[name] = value
	}
	return result, nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: measure-admission /absolute/path/to/latifa")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result, err := run(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		panic(err)
	}
}
