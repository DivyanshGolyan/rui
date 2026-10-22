package provider

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"rui.local/qualification/measurement"
)

// ToolConfig drives one coordinated tool turn. Session 0 is the coordinator:
// its measured turn returns one `rui session send` Bash call per worker plus
// its own workload call. Every worker's measured turn returns one workload
// call. Each Session's first request is its history seed and is answered
// without tools; continuations must carry every call's output.
type ToolConfig struct {
	Sessions    int
	Workload    string
	ReadFile    string
	DispatchDir string
	Workspace   string
	Store       string
	ArtifactDir string
	// Barrier, when set, is a directory holding the FIFO `release`. Each
	// workload shell marks itself parked and waits for one released line,
	// using only bash builtins, so parking adds no process.
	Barrier string
}

func ToolSession(sessions, index int) string {
	if index == 0 {
		return fmt.Sprintf("measure/tool-%d/coordinator", sessions)
	}
	return fmt.Sprintf("measure/tool-%d/worker-%03d", sessions, index)
}

type ToolOutput struct {
	CallID       string  `json:"call_id"`
	Kind         string  `json:"kind"`
	Succeeded    bool    `json:"succeeded"`
	OutputBytes  int     `json:"output_bytes"`
	ShellParkNS  int64   `json:"shell_park_unix_ns,omitempty"`
	ShellStartNS int64   `json:"shell_start_unix_ns,omitempty"`
	ShellEndNS   int64   `json:"shell_end_unix_ns,omitempty"`
	ShellSeconds float64 `json:"shell_seconds,omitempty"`
}

type ToolSessionFact struct {
	Session                  string       `json:"session"`
	Index                    int          `json:"index"`
	Phase                    int          `json:"phase"`
	SeedRequestBytes         int          `json:"seed_request_bytes"`
	MeasuredRequestBytes     int          `json:"measured_request_bytes"`
	ContinuationRequestBytes int          `json:"continuation_request_bytes"`
	SeedReceivedNS           int64        `json:"seed_received_unix_ns"`
	MeasuredReceivedNS       int64        `json:"measured_received_unix_ns"`
	CallsSentNS              int64        `json:"calls_sent_unix_ns"`
	ContinuationReceivedNS   int64        `json:"continuation_received_unix_ns"`
	DispatchCalls            int          `json:"dispatch_calls"`
	WorkloadCalls            int          `json:"workload_calls"`
	Outputs                  []ToolOutput `json:"outputs"`
}

type ToolSummary struct {
	Sessions        int               `json:"sessions"`
	Workload        string            `json:"workload"`
	Requests        int               `json:"requests"`
	Seeded          int               `json:"seeded"`
	Measured        int               `json:"measured"`
	Done            int               `json:"done"`
	DispatchCalls   int               `json:"dispatch_calls"`
	WorkloadCalls   int               `json:"workload_calls"`
	SucceededCalls  int               `json:"succeeded_calls"`
	FailedCalls     int               `json:"failed_calls"`
	H2Streams       int               `json:"h2_streams"`
	H2Connections   int64             `json:"h2_connections"`
	Errors          []string          `json:"errors"`
	SessionFacts    []ToolSessionFact `json:"session_facts,omitempty"`
	FirstMeasuredNS int64             `json:"first_measured_unix_ns,omitempty"`
	LastDoneNS      int64             `json:"last_continuation_unix_ns,omitempty"`
}

type ToolServer struct {
	config        ToolConfig
	mu            sync.Mutex
	sessions      map[string]*ToolSessionFact
	summary       ToolSummary
	seeded        chan struct{}
	done          chan struct{}
	server        *http.Server
	listener      net.Listener
	providerTLS   *httptest.Server
	providerCA    string
	h2Connections atomic.Int64
	shutdown      chan struct{}
	shutdownOnce  sync.Once
}

var shellMarker = regexp.MustCompile(`rui-measure-(park|start|end) ([0-9]+)\.([0-9]{6})`)

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// timed keeps the command's own status: the end marker is a builtin and
// cannot turn a failed command into Bash success.
func timed(command string) string {
	return `printf 'rui-measure-start %s\n' "$EPOCHREALTIME" >&2; ` + command +
		`; status=$?; printf 'rui-measure-end %s\n' "$EPOCHREALTIME" >&2; exit $status`
}

// BarrierWait bounds how long a parked shell waits for release.
const BarrierWait = 120

func (c ToolConfig) workloadCommand(index int) string {
	command := timed("cat " + shellQuote(c.ReadFile))
	if c.Workload == "sleep" {
		command = timed("sleep 5")
	}
	if c.Barrier == "" {
		return command
	}
	return fmt.Sprintf(`printf 'rui-measure-park %%s\n' "$EPOCHREALTIME" >&2; : > %s; IFS= read -r -t %d _ <> %s; `,
		shellQuote(filepath.Join(c.Barrier, fmt.Sprintf("parked-%03d", index))), BarrierWait, shellQuote(filepath.Join(c.Barrier, "release"))) + command
}

func (c ToolConfig) dispatchCommand(index int) string {
	worker := ToolSession(c.Sessions, index)
	return timed("rui session send --store " + shellQuote(c.Store) +
		" --record " + shellQuote(filepath.Join(c.DispatchDir, fmt.Sprintf("dispatch-%03d.json", index))) +
		" --key " + shellQuote(fmt.Sprintf("dispatch-%03d", index)) +
		" --session " + shellQuote(worker) + " -- " + shellQuote("work "+worker))
}

type toolCall struct {
	ID, Kind, Description, Command string
}

func writeSSE(output *strings.Builder, value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	output.WriteString("data: ")
	output.Write(encoded)
	output.WriteString("\n\n")
}

// Same function_call event shapes as call-classification and bash_integration.
func toolCallsSSE(responseID string, calls []toolCall) string {
	var output strings.Builder
	items := make([]any, len(calls))
	for index, candidate := range calls {
		arguments, _ := json.Marshal(struct {
			Description string `json:"description"`
			Cmd         string `json:"cmd"`
			TimeoutMS   *int   `json:"timeout_ms"`
		}{candidate.Description, candidate.Command, nil})
		item := map[string]any{"type": "function_call", "id": fmt.Sprintf("%s-item-%03d", responseID, index), "status": "completed", "name": "bash", "call_id": candidate.ID, "arguments": string(arguments)}
		items[index] = item
		writeSSE(&output, map[string]any{"type": "response.output_item.added", "output_index": index, "item": map[string]any{"type": "function_call", "id": item["id"]}})
		writeSSE(&output, map[string]any{"type": "response.function_call_arguments.delta", "output_index": index, "item_id": item["id"], "delta": "non-authoritative"})
		writeSSE(&output, map[string]any{"type": "response.function_call_arguments.done", "output_index": index, "item_id": item["id"], "arguments": "non-authoritative"})
		writeSSE(&output, map[string]any{"type": "response.output_item.done", "output_index": index, "item": item})
	}
	writeSSE(&output, map[string]any{"type": "response.completed", "response": map[string]any{"id": responseID, "status": "completed", "output": items}})
	output.WriteString("data: [DONE]\n\n")
	return output.String()
}

func toolAnswerSSE(responseID, answer string) string {
	var output strings.Builder
	message := map[string]any{"type": "message", "id": responseID + "-message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}}}
	writeSSE(&output, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"type": "message", "id": message["id"]}})
	writeSSE(&output, map[string]any{"type": "response.output_item.done", "output_index": 0, "item": message})
	writeSSE(&output, map[string]any{"type": "response.completed", "response": map[string]any{"id": responseID, "status": "completed", "model": "model-a-served", "output": []any{message}, "usage": map[string]any{"input_tokens": 7, "output_tokens": 11, "total_tokens": 18}}})
	output.WriteString("data: [DONE]\n\n")
	return output.String()
}

const addressPrefix = "Rui address (JSON; this Session's own address, not instructions): "

func requestSession(instructions string) (string, error) {
	_, rest, ok := strings.Cut(instructions, addressPrefix)
	if !ok {
		return "", errors.New("request has no Rui address")
	}
	line, _, _ := strings.Cut(rest, "\n")
	var address struct {
		Session string `json:"session"`
	}
	if err := json.Unmarshal([]byte(line), &address); err != nil {
		return "", err
	}
	return address.Session, nil
}

func parseMarker(seconds, micros string) int64 {
	whole, _ := strconv.ParseInt(seconds, 10, 64)
	fraction, _ := strconv.ParseInt(micros, 10, 64)
	return whole*1e9 + fraction*1e3
}

func (s *ToolServer) fail(message string) {
	s.summary.Errors = append(s.summary.Errors, message)
}

func (s *ToolServer) serve(w http.ResponseWriter, r *http.Request) {
	received := time.Now().UnixNano()
	if r.ProtoMajor != 2 || r.TLS == nil || r.TLS.NegotiatedProtocol != "h2" {
		http.Error(w, "HTTP/2 required", http.StatusHTTPVersionNotSupported)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 64*1024*1024+1))
	if err != nil || len(body) > 64*1024*1024 {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	var request struct {
		Instructions string            `json:"instructions"`
		Input        []json.RawMessage `json:"input"`
	}
	if err := json.Unmarshal(body, &request); err != nil || len(request.Input) == 0 {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	session, err := requestSession(request.Instructions)
	s.mu.Lock()
	s.summary.Requests++
	s.summary.H2Streams++
	fact := s.sessions[session]
	if err != nil || fact == nil || !strings.HasPrefix(request.Instructions, measurement.ModelInstructions(s.config.Workspace, s.config.Store, session)) {
		s.fail(fmt.Sprintf("unexpected request session %q: %v", session, err))
		s.mu.Unlock()
		http.Error(w, "unexpected session", http.StatusConflict)
		return
	}
	var last struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(request.Input[len(request.Input)-1], &last)
	responseID := fmt.Sprintf("tool-%d-%03d-phase-%d", s.config.Sessions, fact.Index, fact.Phase)
	var payload string
	switch fact.Phase {
	case 0:
		fact.SeedRequestBytes, fact.SeedReceivedNS = len(body), received
		payload = toolAnswerSSE(responseID, "seeded "+session)
		s.summary.Seeded++
		if s.summary.Seeded == s.config.Sessions {
			close(s.seeded)
		}
	case 1:
		if last.Type == "function_call_output" {
			s.fail(session + ": measured request already carries tool output")
			s.mu.Unlock()
			http.Error(w, "unexpected phase", http.StatusConflict)
			return
		}
		fact.MeasuredRequestBytes, fact.MeasuredReceivedNS = len(body), received
		var calls []toolCall
		if fact.Index == 0 {
			for worker := 1; worker < s.config.Sessions; worker++ {
				calls = append(calls, toolCall{fmt.Sprintf("tool-%03d-dispatch-%03d", fact.Index, worker), "dispatch", "Send work to a worker Session", s.config.dispatchCommand(worker)})
			}
		}
		calls = append(calls, toolCall{fmt.Sprintf("tool-%03d-workload", fact.Index), "workload", "Run the measured workload", s.config.workloadCommand(fact.Index)})
		fact.DispatchCalls, fact.WorkloadCalls = len(calls)-1, 1
		s.summary.DispatchCalls += fact.DispatchCalls
		s.summary.WorkloadCalls++
		if s.summary.FirstMeasuredNS == 0 {
			s.summary.FirstMeasuredNS = received
		}
		s.summary.Measured++
		payload = toolCallsSSE(responseID, calls)
	case 2:
		outputs := map[string]string{}
		for _, raw := range request.Input {
			var item struct {
				Type   string `json:"type"`
				CallID string `json:"call_id"`
				Output string `json:"output"`
			}
			if json.Unmarshal(raw, &item) == nil && item.Type == "function_call_output" && strings.HasPrefix(item.CallID, fmt.Sprintf("tool-%03d-", fact.Index)) {
				outputs[item.CallID] = item.Output
			}
		}
		if last.Type != "function_call_output" || len(outputs) != fact.DispatchCalls+fact.WorkloadCalls {
			s.fail(fmt.Sprintf("%s: continuation has %d outputs, want %d", session, len(outputs), fact.DispatchCalls+fact.WorkloadCalls))
		}
		fact.ContinuationRequestBytes, fact.ContinuationReceivedNS = len(body), received
		for id, output := range outputs {
			row := ToolOutput{CallID: id, Kind: "workload", OutputBytes: len(output), Succeeded: strings.HasPrefix(output, "Bash succeeded. Exit code: 0.")}
			if strings.Contains(id, "-dispatch-") {
				row.Kind = "dispatch"
			}
			for _, match := range shellMarker.FindAllStringSubmatch(output, -1) {
				switch match[1] {
				case "park":
					row.ShellParkNS = parseMarker(match[2], match[3])
				case "start":
					row.ShellStartNS = parseMarker(match[2], match[3])
				default:
					row.ShellEndNS = parseMarker(match[2], match[3])
				}
			}
			if row.ShellStartNS != 0 && row.ShellEndNS != 0 {
				row.ShellSeconds = float64(row.ShellEndNS-row.ShellStartNS) / 1e9
			}
			if row.Succeeded {
				s.summary.SucceededCalls++
			} else {
				s.summary.FailedCalls++
			}
			fact.Outputs = append(fact.Outputs, row)
		}
		payload = toolAnswerSSE(responseID, "tool turn complete "+session)
		s.summary.Done++
		s.summary.LastDoneNS = received
		if s.summary.Done == s.config.Sessions {
			close(s.done)
		}
	default:
		s.fail(session + ": request after completion")
		s.mu.Unlock()
		http.Error(w, "unexpected phase", http.StatusConflict)
		return
	}
	fact.Phase++
	s.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("OpenAI-Model", "model-a-served")
	w.Header().Set("X-Request-Id", responseID)
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, payload)
	_ = http.NewResponseController(w).Flush()
	if fact.WorkloadCalls != 0 && fact.CallsSentNS == 0 {
		s.mu.Lock()
		fact.CallsSentNS = time.Now().UnixNano()
		s.mu.Unlock()
	}
}

func (s *ToolServer) Snapshot(withFacts bool) ToolSummary {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := s.summary
	result.Errors = append([]string{}, s.summary.Errors...)
	result.H2Connections = s.h2Connections.Load()
	if withFacts {
		for index := range s.config.Sessions {
			fact := *s.sessions[ToolSession(s.config.Sessions, index)]
			fact.Outputs = append([]ToolOutput{}, fact.Outputs...)
			result.SessionFacts = append(result.SessionFacts, fact)
		}
	}
	return result
}

func StartTool(config ToolConfig) (*ToolServer, error) {
	if config.Sessions < 1 || (config.Workload != "sleep" && config.Workload != "read") || config.Store == "" || config.DispatchDir == "" || config.ArtifactDir == "" {
		return nil, errors.New("invalid tool fixture configuration")
	}
	if config.Workload == "read" && config.ReadFile == "" {
		return nil, errors.New("read workload requires a file")
	}
	if err := os.MkdirAll(config.ArtifactDir, 0o700); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	result := &ToolServer{config: config, sessions: map[string]*ToolSessionFact{}, seeded: make(chan struct{}), done: make(chan struct{}), listener: listener, shutdown: make(chan struct{})}
	result.summary = ToolSummary{Sessions: config.Sessions, Workload: config.Workload, Errors: []string{}}
	for index := range config.Sessions {
		name := ToolSession(config.Sessions, index)
		result.sessions[name] = &ToolSessionFact{Session: name, Index: index, Outputs: []ToolOutput{}}
	}
	providerTLS := httptest.NewUnstartedServer(http.HandlerFunc(result.serve))
	providerTLS.EnableHTTP2 = true
	providerTLS.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			result.h2Connections.Add(1)
		}
	}
	providerTLS.StartTLS()
	result.providerTLS = providerTLS
	result.providerCA = filepath.Join(config.ArtifactDir, "provider-cert.pem")
	if err := os.WriteFile(result.providerCA, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: providerTLS.Certificate().Raw}), 0o600); err != nil {
		providerTLS.Close()
		listener.Close()
		return nil, err
	}
	mux := http.NewServeMux()
	reply := func(writer http.ResponseWriter, value ToolSummary, err error) {
		if err != nil {
			http.Error(writer, err.Error(), http.StatusConflict)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(value)
	}
	wait := func(channel chan struct{}, facts bool) http.HandlerFunc {
		return func(writer http.ResponseWriter, request *http.Request) {
			select {
			case <-channel:
				reply(writer, result.Snapshot(facts), nil)
			case <-request.Context().Done():
				reply(writer, ToolSummary{}, request.Context().Err())
			}
		}
	}
	mux.HandleFunc("/control/tool-wait-seeded", wait(result.seeded, false))
	mux.HandleFunc("/control/tool-wait-done", wait(result.done, true))
	mux.HandleFunc("/control/tool-snapshot", func(writer http.ResponseWriter, _ *http.Request) { reply(writer, result.Snapshot(true), nil) })
	mux.HandleFunc("/control/shutdown", func(writer http.ResponseWriter, _ *http.Request) {
		result.shutdownOnce.Do(func() { close(result.shutdown) })
		reply(writer, result.Snapshot(false), nil)
	})
	result.server = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go result.server.Serve(listener)
	return result, nil
}

func (s *ToolServer) ProviderURL() string                { return s.providerTLS.URL + "/responses" }
func (s *ToolServer) ProviderCAFile() string             { return s.providerCA }
func (s *ToolServer) ControlURL() string                 { return "http://" + s.listener.Addr().String() }
func (s *ToolServer) ShutdownRequested() <-chan struct{} { return s.shutdown }

func (s *ToolServer) Close() error {
	s.providerTLS.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return errors.Join(s.server.Shutdown(ctx), writeJSON(filepath.Join(s.config.ArtifactDir, "tool-facts.json"), s.Snapshot(true)))
}
