package main

import (
	"encoding/json"
	"errors"
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

	"rui.local/qualification/measurement"
)

var inputBytes = []int{100_000, 500_000, 1_000_000, 4_000_000}
var capacities = []int{1, 8, 16, 100}

type endpoint struct {
	server   *http.Server
	listener net.Listener
	mu       sync.Mutex
	requests []int
	release  chan struct{}
}

func newEndpoint() (*endpoint, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	fixture := &endpoint{listener: listener, release: make(chan struct{})}
	fixture.server = &http.Server{Handler: http.HandlerFunc(fixture.serve)}
	go fixture.server.Serve(listener)
	return fixture, nil
}

func (e *endpoint) serve(writer http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return
	}
	e.mu.Lock()
	e.requests = append(e.requests, len(body))
	release := e.release
	e.mu.Unlock()
	select {
	case <-release:
	case <-time.After(20 * time.Second):
		return
	}
	response := []byte(`{"error":"measured failure"}`)
	writer.Header().Set("Connection", "close")
	writer.WriteHeader(http.StatusUnprocessableEntity)
	_, _ = writer.Write(response)
}

func (e *endpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }

func (e *endpoint) reset() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.requests = nil
	e.release = make(chan struct{})
}

func (e *endpoint) releaseAll() {
	e.mu.Lock()
	defer e.mu.Unlock()
	select {
	case <-e.release:
	default:
		close(e.release)
	}
}

func (e *endpoint) count() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.requests)
}

func (e *endpoint) requestBytes() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.requests[0]
}

func (e *endpoint) Close() error {
	e.releaseAll()
	return e.server.Close()
}

func runJSON(deadline measurement.Deadline, binary string, destination any, arguments ...string) error {
	return measurement.RunJSON(deadline, destination, binary, arguments...)
}

func configure(deadline measurement.Deadline, binary, parent, store, key, session string) error {
	workspace, err := os.Getwd()
	if err != nil {
		return err
	}
	var answer map[string]any
	err = runJSON(deadline, binary, &answer,
		"configure", "--store", store, "--record", filepath.Join(parent, key+".json"),
		"--key", key, "--session", session, "--workspace", workspace, "--provider", "codex", "--model", "model-a")
	if err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("configuration was not accepted: %v", answer)
	}
	return nil
}

func message(deadline measurement.Deadline, binary, parent, store, key, session string, size int) error {
	path := filepath.Join(parent, key+".txt")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	block := strings.Repeat("m", 64*1024)
	for remaining := size; remaining > 0; {
		count := min(remaining, len(block))
		if _, err := io.WriteString(file, block[:count]); err != nil {
			file.Close()
			return err
		}
		remaining -= count
	}
	if err := file.Close(); err != nil {
		return err
	}
	var answer map[string]any
	err = runJSON(deadline, binary, &answer,
		"message", "--store", store, "--record", filepath.Join(parent, key+".json"),
		"--key", key, "--session", session, "--text", path)
	if err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("message was not accepted: %v", answer)
	}
	return nil
}

func nested(value map[string]any, names ...string) any {
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

func execution(deadline measurement.Deadline, binary, store, session string) (any, error) {
	var result map[string]any
	if err := runJSON(deadline, binary, &result, "inspect-session", "--store", store, "--session", session); err != nil {
		return nil, err
	}
	return result["execution"], nil
}

func startHost(deadline measurement.Deadline, binary, store, endpointURL, artifacts string, capacity, cleanupMS int) (*measurement.Host, error) {
	extra := []string{}
	if cleanupMS != 0 {
		extra = append(extra, "--test-cleanup-delay-ms", strconv.Itoa(cleanupMS))
	}
	return measurement.StartHost(binary, store, endpointURL, capacity, filepath.Join(artifacts, "host-stderr.log"), deadline, extra...)
}

func sample(host *measurement.Host, directory, name string) (map[string]any, error) {
	value, err := measurement.SampleProcess(host.Process, filepath.Join(directory, "footprint-"+name+".txt"))
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	result := map[string]any{}
	if err := json.Unmarshal(encoded, &result); err != nil {
		return nil, err
	}
	lsof, err := measurement.Run(measurement.NewDeadline(15*time.Second), "/usr/sbin/lsof", "-n", "-P", "-p", strconv.Itoa(host.Cmd.Process.Pid))
	if err != nil {
		return nil, err
	}
	result["open_request_file_descriptors"] = strings.Count(string(lsof), "request-")
	return result, nil
}

func idleCapacity(binary, root string, fixture *endpoint) ([]map[string]any, error) {
	rows := make([]map[string]any, 0, len(capacities))
	for _, capacity := range capacities {
		directory := filepath.Join(root, fmt.Sprintf("idle-%d", capacity))
		if err := os.Mkdir(directory, 0o700); err != nil {
			return nil, err
		}
		deadline := measurement.NewDeadline(45 * time.Second)
		host, err := startHost(deadline, binary, directory, fixture.URL(), directory, capacity, 0)
		if err != nil {
			return nil, err
		}
		before, err := measurement.CPUSeconds(host.Process)
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		started := time.Now()
		time.Sleep(2 * time.Second)
		elapsed := time.Since(started).Seconds()
		after, err := measurement.CPUSeconds(host.Process)
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		cpuDelta, err := measurement.CheckedCPUDelta(before, after)
		if err != nil {
			host.Stop(measurement.TeardownAllowance)
			return nil, err
		}
		cpuPercent := 100 * cpuDelta / elapsed
		process, sampleError := sample(host, directory, "idle")
		stopError := host.Stop(measurement.TeardownAllowance)
		if err := errors.Join(sampleError, stopError); err != nil {
			return nil, err
		}
		if cpuPercent >= 1 {
			return nil, fmt.Errorf("idle capacity %d consumed %.3f%% of one core", capacity, cpuPercent)
		}
		rows = append(rows, map[string]any{
			"active_capacity": capacity, "custody_record_bytes": host.Ready["custody_record_bytes"],
			"execution_slot_bytes": host.Ready["execution_slot_bytes"], "idle_cpu_percent_one_core": cpuPercent,
			"idle_cpu_sample_seconds": elapsed, "process": process,
		})
	}
	return rows, nil
}

func requestGrowth(binary, root string, fixture *endpoint) ([]map[string]any, error) {
	rows := make([]map[string]any, 0, len(inputBytes))
	for _, size := range inputBytes {
		fixture.reset()
		directory := filepath.Join(root, fmt.Sprintf("payload-%d", size))
		if err := os.Mkdir(directory, 0o700); err != nil {
			return nil, err
		}
		deadline := measurement.NewDeadline(60 * time.Second)
		host, err := startHost(deadline, binary, directory, fixture.URL(), directory, 1, 3000)
		if err != nil {
			return nil, err
		}
		session := fmt.Sprintf("measure/payload-%d", size)
		work := func() error {
			if err := configure(deadline, binary, directory, directory, fmt.Sprintf("config-%d", size), session); err != nil {
				return err
			}
			if err := message(deadline, binary, directory, directory, fmt.Sprintf("message-%d", size), session, size); err != nil {
				return err
			}
			if err := measurement.WaitFor(deadline, 25*time.Millisecond, "request materialization", func() (bool, error) {
				if host.Cmd.ProcessState != nil && host.Cmd.ProcessState.Exited() {
					return false, errors.New("Host exited during dispatch")
				}
				return fixture.count() == 1, nil
			}); err != nil {
				return err
			}
			inFlightExecution, err := execution(deadline, binary, directory, session)
			if err != nil {
				return err
			}
			inFlight, err := sample(host, directory, "in-flight")
			if err != nil {
				return err
			}
			fixture.releaseAll()
			time.Sleep(150 * time.Millisecond)
			delayedExecution, err := execution(deadline, binary, directory, session)
			if err != nil {
				return err
			}
			delayed, err := sample(host, directory, "delayed")
			if err != nil {
				return err
			}
			rows = append(rows, map[string]any{
				"input_bytes": size, "endpoint_request_bytes": fixture.requestBytes(), "scratch_limit_bytes": host.Ready["scratch_limit_bytes"],
				"in_flight_execution": inFlightExecution, "in_flight": inFlight,
				"saved_failure_delayed_cleanup_execution": delayedExecution, "saved_failure_delayed_cleanup": delayed,
			})
			return nil
		}()
		fixture.releaseAll()
		if err := errors.Join(work, host.Stop(measurement.TeardownAllowance)); err != nil {
			return nil, err
		}
	}
	return rows, nil
}

func overlap(binary, root string, fixture *endpoint) (map[string]any, error) {
	fixture.reset()
	directory := filepath.Join(root, "overlap")
	if err := os.Mkdir(directory, 0o700); err != nil {
		return nil, err
	}
	deadline := measurement.NewDeadline(90 * time.Second)
	host, err := startHost(deadline, binary, directory, fixture.URL(), directory, 8, 0)
	if err != nil {
		return nil, err
	}
	result, workError := func() (map[string]any, error) {
		for index := range 8 {
			session := fmt.Sprintf("measure/overlap-%d", index)
			if err := configure(deadline, binary, directory, directory, fmt.Sprintf("overlap-config-%d", index), session); err != nil {
				return nil, err
			}
			if err := message(deadline, binary, directory, directory, fmt.Sprintf("overlap-message-%d", index), session, 64*1024); err != nil {
				return nil, err
			}
		}
		if err := measurement.WaitFor(deadline, 25*time.Millisecond, "overlapping transfers", func() (bool, error) { return fixture.count() == 8, nil }); err != nil {
			return nil, err
		}
		exec, err := execution(deadline, binary, directory, "measure/overlap-0")
		if err != nil {
			return nil, err
		}
		process, err := sample(host, directory, "overlap")
		if err != nil {
			return nil, err
		}
		return map[string]any{"active_capacity": 8, "endpoint_requests": fixture.count(), "execution": exec,
			"custody_record_bytes": host.Ready["custody_record_bytes"], "execution_slot_bytes": host.Ready["execution_slot_bytes"], "process": process}, nil
	}()
	fixture.releaseAll()
	return result, errors.Join(workError, host.Stop(measurement.TeardownAllowance))
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: measure-model-dispatch /absolute/path/to/rui")
		os.Exit(2)
	}
	if err := measurement.RequireRuntime(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	started := time.Now()
	root, err := os.MkdirTemp("/private/tmp", "rui-dispatch-measure-")
	if err != nil {
		panic(err)
	}
	fixture, err := newEndpoint()
	if err != nil {
		panic(err)
	}
	defer fixture.Close()
	idle, err := idleCapacity(os.Args[1], root, fixture)
	if err != nil {
		panic(err)
	}
	growth, err := requestGrowth(os.Args[1], root, fixture)
	if err != nil {
		panic(err)
	}
	overlapping, err := overlap(os.Args[1], root, fixture)
	if err != nil {
		panic(err)
	}
	result := map[string]any{
		"format": "rui-model-dispatch-v3-go", "scope": "issue-172 production frozen-request dispatch", "status": "passed",
		"artifacts":            root,
		"transport":            map[string]string{"curl": "8.22.0", "openssl": "3.6.3", "resolver": "threaded"},
		"idle_capacity_growth": idle, "request_growth_and_delayed_cleanup": growth, "overlapping_transport": overlapping,
		"elapsed_seconds": time.Since(started).Seconds(),
		"limits":          []string{"macOS Apple Silicon runtime evidence only; supported Linux and x86 targets are compile-only", "endpoint is deterministic loopback HTTP and qualifies no TLS trust store or live provider behavior", "request cases size aggregate context input; endpoint_request_bytes reports the complete serialized request including envelope", "idle CPU is process CPU-time growth over a two-second quiet interval and must remain below 1% of one core", "process termination is crash evidence, not power-loss qualification"},
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
