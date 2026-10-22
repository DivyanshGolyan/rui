package provider

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"testing"

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
		text := "Bash succeeded. Exit code: 0.\nrui-measure-start 1700000000.000250\nrui-measure-end 1700000001.500000"
		if index == 1 {
			text = "Bash failed. Exit code: 7."
		}
		outputs = append(outputs, item, map[string]any{"type": "function_call_output", "call_id": item["call_id"], "output": text})
	}
	toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, 0), outputs...)
	summary := server.Snapshot(true)
	if summary.DispatchCalls != 2 || summary.WorkloadCalls != 1 || summary.SucceededCalls != 2 || summary.FailedCalls != 1 || summary.Done != 1 || len(summary.Errors) != 0 {
		t.Fatalf("summary = %+v", summary)
	}
	for _, output := range summary.SessionFacts[0].Outputs {
		if output.Kind == "workload" && (output.ShellStartNS != 1700000000000250000 || output.ShellSeconds != 1.49975) {
			t.Fatalf("workload markers = %+v", output)
		}
	}
	if items := toolRequest(t, client, server.ProviderURL(), "/workspace", "/store", ToolSession(3, 1), user); len(items) != 1 || !strings.Contains(fmt.Sprint(items[0]["arguments"]), "cat ") {
		t.Fatalf("worker calls = %v", items)
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
	if markers := shellMarker.FindAllStringSubmatch(stderr.String(), -1); len(markers) != 2 || markers[0][1] != "start" || markers[1][1] != "end" {
		t.Fatalf("markers in %q", stderr.String())
	}
}
