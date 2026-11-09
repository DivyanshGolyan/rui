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

	"rui.local/qualification/measurement"
)

var sessionCounts = []int{0, 100, 1_000, 10_000}
var peakCounter = regexp.MustCompile(`(?m)^\s*([0-9]+)\s+maximum resident set size\s*$`)

func clientPeak(binary, store, session string) (uint64, error) {
	var stderr bytes.Buffer
	command := exec.Command("/usr/bin/time", "-l", binary, "session", "inspect", "--store", store, "--session", session)
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

func run(binary string) (result map[string]any, resultError error) {
	started := time.Now()
	directory, err := os.MkdirTemp("/private/tmp", "rui-configuration-measure-")
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
	client := measurement.Client{Binary: binary, Artifacts: directory, Store: canonicalStore, Deadline: deadline}
	stages := make([]map[string]any, 0, len(sessionCounts))
	admitted := 0
	var firstSession string
	var record map[string]any
	for _, target := range sessionCounts {
		for admitted < target {
			identity := fmt.Sprintf("measure-%08d", admitted)
			if record == nil {
				// The CLI fills the creation defaults; the rest replay its record.
				if firstSession, err = client.Configure(identity, "", "--tools", "none"); err != nil {
					return nil, err
				}
				if record, err = client.ConfigureRecord(identity); err != nil {
					return nil, err
				}
				admitted++
				continue
			}
			record["key"] = identity
			var answer map[string]any
			if err := measurement.ExchangeUnix(deadline, socketPath, "/v1/configure", record, &answer); err != nil {
				return nil, err
			}
			if status, _ := measurement.StringField(answer, "answer", "status"); status != "accepted" {
				return nil, fmt.Errorf("configuration %s was %v", identity, answer)
			}
			if _, err := measurement.ConfigurationSession(answer); err != nil {
				return nil, err
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
	peak, err := clientPeak(binary, store, firstSession)
	if err != nil {
		return nil, err
	}
	result = map[string]any{
		"format":                       "rui-configuration-admission-v2-go",
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
		fmt.Fprintln(os.Stderr, "usage: measure-admission /absolute/path/to/rui")
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
