//go:build linux

package provider

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"rui.local/qualification/measurement"
)

func toolRequest(t *testing.T, client *http.Client, url, workspace, store, session string, input ...any) []map[string]any {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"instructions": measurement.ModelInstructions(workspace, store, session), "input": input})
	response, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var payload bytes.Buffer
	payload.ReadFrom(response.Body)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("%s: %s %s", session, response.Status, payload.String())
	}
	var items []map[string]any
	for _, line := range strings.Split(payload.String(), "\n") {
		data, ok := strings.CutPrefix(line, "data: ")
		if !ok || data == "[DONE]" {
			continue
		}
		var event struct {
			Type     string `json:"type"`
			Response struct {
				Output []map[string]any `json:"output"`
			} `json:"response"`
		}
		if json.Unmarshal([]byte(data), &event) == nil && event.Type == "response.completed" {
			items = event.Response.Output
		}
	}
	return items
}

// A coordinator gets one send per worker plus its own workload; a failed
// call output must count as failed, never as completed work.
func TestToolTurnCountsDispatchAndWorkloadSeparately(t *testing.T) {
	directory := t.TempDir()
	config := ToolConfig{Sessions: 3, Workload: "read", ReadFile: "/data/read fixture", DispatchDir: directory + "/dispatch", Workspace: "/workspace", Store: "/store", ArtifactDir: directory}
	server, err := StartTool(config)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	pool := x509.NewCertPool()
	pool.AddCert(server.providerTLS.Certificate())
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}, ForceAttemptHTTP2: true}}
	user := map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "seed"}}}
	for index := range 3 {
		if items := toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, index), user); len(items) != 1 || items[0]["type"] != "message" {
			t.Fatalf("seed answer for %d = %v", index, items)
		}
	}
	coordinator := toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, 0), user)
	if len(coordinator) != 3 {
		t.Fatalf("coordinator calls = %d, want 2 sends + 1 workload", len(coordinator))
	}
	for index, item := range coordinator {
		var arguments struct{ Cmd string }
		json.Unmarshal([]byte(item["arguments"].(string)), &arguments)
		isSend := strings.Contains(arguments.Cmd, "rui session send --store '/store'") && strings.Contains(arguments.Cmd, "--session '"+ToolSession(3, index+1)+"'")
		if (index < 2) != isSend || index == 2 && !strings.Contains(arguments.Cmd, "cat '/data/read fixture'") {
			t.Fatalf("call %d = %q", index, arguments.Cmd)
		}
	}
	outputs := []any{user}
	for index, item := range coordinator {
		text := "Bash succeeded. Exit code: 0.\nrui-measure-start 1700000000.000250"
		if index == 1 {
			text = "Bash failed. Exit code: 7."
		}
		outputs = append(outputs, item, map[string]any{"type": "function_call_output", "call_id": item["call_id"], "output": text})
	}
	toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, 0), outputs...)
	summary := server.Snapshot(true)
	if summary.DispatchCalls != 2 || summary.WorkloadCalls != 1 || summary.SucceededCalls != 2 || summary.FailedCalls != 1 || summary.Done != 1 || len(summary.Errors) != 1 {
		t.Fatalf("summary = %+v", summary)
	}
	for _, output := range summary.SessionFacts[0].Outputs {
		if output.Kind == "workload" && output.ShellStartNS != 1700000000000250000 {
			t.Fatalf("workload markers = %+v", output)
		}
	}
	if items := toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, 1), user); len(items) != 1 || !strings.Contains(fmt.Sprint(items[0]["arguments"]), "cat ") {
		t.Fatalf("worker calls = %v", items)
	}
}

// Only exactly one output per issued call, each with ordered markers and no
// end marker, counts.
func TestToolOutputsRequireExactIssuedCalls(t *testing.T) {
	issued := []toolCall{{ID: "tool-000-dispatch-001", Kind: "dispatch"}, {ID: "tool-000-workload", Kind: "workload"}}
	output := func(id, text string) json.RawMessage {
		encoded, _ := json.Marshal(map[string]any{"type": "function_call_output", "call_id": id, "output": text})
		return encoded
	}
	good := "Bash succeeded. Exit code: 0.\nrui-measure-park 1.000000\nrui-measure-start 2.000000"
	send := "Bash succeeded. Exit code: 0.\nrui-measure-start 2.000000"
	for _, test := range []struct {
		name    string
		barrier bool
		input   []json.RawMessage
		valid   int
	}{
		{"dispatch must not park", true, []json.RawMessage{output("tool-000-dispatch-001", good), output("tool-000-workload", good)}, 1},
		{"exact", true, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", good)}, 2},
		{"unissued same-prefix ID replaces workload", false, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-never-issued", send)}, 1},
		{"missing workload output", false, []json.RawMessage{output("tool-000-dispatch-001", send)}, 1},
		{"duplicate output", false, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", send), output("tool-000-workload", send)}, 1},
		{"missing start marker", false, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", "Bash succeeded. Exit code: 0.")}, 1},
		{"end marker kept Bash resident", false, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", "Bash succeeded. Exit code: 0.\nrui-measure-start 2.000000\nrui-measure-end 3.000000")}, 1},
		{"park after start", true, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", "Bash succeeded. Exit code: 0.\nrui-measure-park 3.000000\nrui-measure-start 2.000000")}, 1},
		{"barrier workload without park", true, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", "Bash succeeded. Exit code: 0.\nrui-measure-start 2.000000")}, 1},
		{"failed command", false, []json.RawMessage{output("tool-000-dispatch-001", send), output("tool-000-workload", "Bash failed. Exit code: 124.")}, 1},
	} {
		rows, failures := validateOutputs(issued, test.input, test.barrier)
		valid := 0
		for _, row := range rows {
			if row.Succeeded {
				valid++
			}
		}
		if valid != test.valid || (test.valid == len(issued)) != (len(failures) == 0) {
			t.Errorf("%s: valid=%d failures=%v rows=%+v", test.name, valid, failures, rows)
		}
	}
}

// A barrier read that times out must fail the call without running the
// workload; only a released line lets it run.
func TestBarrierTimeoutFailsWithoutWorkload(t *testing.T) {
	directory := t.TempDir()
	if err := syscall.Mkfifo(directory+"/release", 0o600); err != nil {
		t.Fatal(err)
	}
	config := ToolConfig{Sessions: 1, Workload: "read", ReadFile: directory + "/data", Barrier: directory, BarrierWait: "0.05"}
	if err := os.WriteFile(config.ReadFile, []byte("READ_WITHOUT_RELEASE"), 0o600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command("bash", "-c", config.workloadCommand(0)).CombinedOutput()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 124 || strings.Contains(string(output), "READ_WITHOUT_RELEASE") {
		t.Fatalf("unreleased barrier: %v %q", err, output)
	}
}

func TestTimedCommandKeepsFailureStatus(t *testing.T) {
	command := exec.Command("bash", "-c", timed("sh -c 'exit 3'"))
	var stderr bytes.Buffer
	command.Stderr = &stderr
	err := command.Run()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 3 {
		t.Fatalf("exit = %v", err)
	}
	if markers := shellMarker.FindAllStringSubmatch(stderr.String(), -1); len(markers) != 1 || markers[0][1] != "start" {
		t.Fatalf("markers in %q", stderr.String())
	}
}

// The workload is the shell's final simple command, so `bash -c` (5.1 and
// later) execs it in place, with and without the barrier prefix: `cat
// /proc/self/stat` then reports this test as its parent, not a Bash shell.
func TestWorkloadIsExecutedInPlaceByBash(t *testing.T) {
	for _, barrier := range []bool{false, true} {
		directory := t.TempDir()
		config := ToolConfig{Sessions: 1, Workload: "read", ReadFile: "/proc/self/stat"}
		if barrier {
			if err := syscall.Mkfifo(directory+"/release", 0o600); err != nil {
				t.Fatal(err)
			}
			config.Barrier = directory
			writer, err := os.OpenFile(directory+"/release", os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Close()
			writer.Write([]byte("\n"))
		}
		output, err := exec.Command("bash", "-c", config.workloadCommand(0)).Output()
		if err != nil {
			t.Fatalf("barrier=%v: %v", barrier, err)
		}
		fields := strings.Fields(string(output[bytes.LastIndexByte(output, ')')+1:]))
		if len(fields) < 2 || fields[1] != fmt.Sprint(os.Getpid()) {
			t.Fatalf("barrier=%v: workload parent in %q, want %d", barrier, output, os.Getpid())
		}
	}
}

// A parked workload neither runs nor exits before release, then runs once.
func TestBarrierHoldsWorkloadUntilRelease(t *testing.T) {
	directory := t.TempDir()
	if err := syscall.Mkfifo(directory+"/release", 0o600); err != nil {
		t.Fatal(err)
	}
	config := ToolConfig{Sessions: 1, Workload: "read", ReadFile: directory + "/data", Barrier: directory}
	if err := os.WriteFile(config.ReadFile, []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	// File-backed stdout: the test reads it while the shell may write, so it
	// must not share an unsynchronized buffer with os/exec's copier.
	stdout, err := os.Create(directory + "/stdout")
	if err != nil {
		t.Fatal(err)
	}
	defer stdout.Close()
	output := func() string { data, _ := os.ReadFile(stdout.Name()); return string(data) }
	command := exec.Command("bash", "-c", config.workloadCommand(4))
	var stderr bytes.Buffer
	command.Stdout, command.Stderr = stdout, &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	for start := time.Now(); ; time.Sleep(5 * time.Millisecond) {
		if _, err := os.Stat(directory + "/parked-004"); err == nil {
			break
		}
		if time.Since(start) > 5*time.Second {
			t.Fatal("shell never parked")
		}
	}
	time.Sleep(200 * time.Millisecond)
	if output() != "" {
		t.Fatalf("workload ran before release: %q", output())
	}
	writer, err := os.OpenFile(directory+"/release", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	writer.Write([]byte("\n"))
	if err := command.Wait(); err != nil || output() != "payload" {
		t.Fatalf("after release: %v %q", err, output())
	}
	if markers := shellMarker.FindAllStringSubmatch(stderr.String(), -1); len(markers) != 2 || markers[0][1] != "park" || markers[1][1] != "start" {
		t.Fatalf("markers in %q", stderr.String())
	}
}
