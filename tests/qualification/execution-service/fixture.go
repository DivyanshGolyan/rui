package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
)

const maxFixtureRequestBytes = 128 * 1024 * 1024

type requestPlan struct {
	Expected         []byte
	Response         []byte
	Group            string
	BashContinuation bool
	Hash             string
	Calls            int
	primed           chan struct{}
}
type endpoint struct {
	listener net.Listener
	server   *http.Server
	mu       sync.Mutex
	plans    map[string][]*requestPlan
	releases map[string]chan struct{}
	faults   []string
}

func newEndpoint() (*endpoint, error) {
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return nil, e
	}
	x := &endpoint{listener: l, plans: map[string][]*requestPlan{}, releases: map[string]chan struct{}{}}
	x.server = &http.Server{Handler: http.HandlerFunc(x.serve)}
	go func() {
		if err := x.server.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
			x.mu.Lock()
			x.faults = append(x.faults, err.Error())
			x.mu.Unlock()
		}
	}()
	return x, nil
}
func (e *endpoint) URL() string { return "http://" + e.listener.Addr().String() + "/responses" }
func (e *endpoint) add(text string, p *requestPlan) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if p.Group == "work" {
		p.primed = make(chan struct{})
	}
	e.plans[text] = append(e.plans[text], p)
	if p.Group != "" {
		if _, ok := e.releases[p.Group]; !ok {
			e.releases[p.Group] = make(chan struct{})
		}
	}
}
func (e *endpoint) fire(group string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if ch := e.releases[group]; ch != nil {
		close(ch)
		e.releases[group] = nil
	}
}
func (e *endpoint) close() {
	e.mu.Lock()
	for name, ch := range e.releases {
		if ch != nil {
			close(ch)
			e.releases[name] = nil
		}
	}
	e.mu.Unlock()
	_ = e.server.Close()
}
func (e *endpoint) count(text string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	n := 0
	for _, p := range e.plans[text] {
		n += p.Calls
	}
	return n
}
func (e *endpoint) isPrimed(text string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, p := range e.plans[text] {
		if p.primed == nil {
			continue
		}
		select {
		case <-p.primed:
			return true
		default:
		}
	}
	return false
}
func (e *endpoint) audit() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.faults) > 0 {
		return errors.New(strings.Join(e.faults, "; "))
	}
	for name, plans := range e.plans {
		for i, p := range plans {
			if p.Calls != 1 {
				return fmt.Errorf("request %s/%d count=%d, expected one", name, i, p.Calls)
			}
		}
	}
	return nil
}
func (e *endpoint) serve(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, maxFixtureRequestBytes+1))
	if err != nil || len(body) > maxFixtureRequestBytes {
		e.mu.Lock()
		e.faults = append(e.faults, "incomplete or oversized request")
		e.mu.Unlock()
		http.Error(w, "bad request", 400)
		return
	}
	var envelope struct {
		Model string `json:"model"`
		Input []struct {
			Role    string `json:"role"`
			Type    string `json:"type"`
			Output  string `json:"output"`
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	if err = json.Unmarshal(body, &envelope); err != nil {
		e.mu.Lock()
		e.faults = append(e.faults, "malformed request JSON")
		e.mu.Unlock()
		http.Error(w, "JSON", 400)
		return
	}
	text := ""
	for _, item := range envelope.Input {
		if item.Role == "user" && len(item.Content) == 1 {
			text = item.Content[0].Text
		}
	}
	e.mu.Lock()
	var p *requestPlan
	for _, candidate := range e.plans[text] {
		if candidate.Calls == 0 {
			p = candidate
			break
		}
	}
	if p == nil {
		e.faults = append(e.faults, "unexpected or duplicate request")
		e.mu.Unlock()
		http.Error(w, "unexpected request", 409)
		return
	}
	p.Calls++
	sum := sha256.Sum256(body)
	p.Hash = hex.EncodeToString(sum[:])
	if envelope.Model != "model-a" {
		e.faults = append(e.faults, "wrong model")
	}
	if p.Expected != nil && !bytes.Equal(body, p.Expected) {
		e.faults = append(e.faults, "request bytes differ from independent fixture for "+shortName(text))
	}
	if p.BashContinuation {
		results := 0
		for _, item := range envelope.Input {
			if item.Type == "function_call_output" {
				results++
				if !strings.HasPrefix(item.Output, "Bash timed_out. ") {
					e.faults = append(e.faults, "wrong Bash timeout outcome")
				}
			}
		}
		if results != 1 {
			e.faults = append(e.faults, "missing or duplicated Bash Tool Result")
		}
	}
	release := e.releases[p.Group]
	response := p.Response
	primed := p.primed
	e.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Content-Length", fmt.Sprint(len(response)))
	if primed != nil {
		const terminator = "data: [DONE]\n\n"
		cut := bytes.LastIndex(response, []byte(terminator))
		if cut < 0 {
			e.mu.Lock()
			e.faults = append(e.faults, "work response lacks terminal event")
			e.mu.Unlock()
			http.Error(w, "fixture", 500)
			return
		}
		if _, err = w.Write(response[:cut]); err != nil {
			e.mu.Lock()
			e.faults = append(e.faults, "provider response prefix write: "+err.Error())
			e.mu.Unlock()
			return
		}
		if flush, ok := w.(http.Flusher); ok {
			flush.Flush()
		}
		close(primed)
		response = response[cut:]
	}
	if release != nil {
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
	}
	if _, err = w.Write(response); err != nil && r.Context().Err() == nil {
		e.mu.Lock()
		e.faults = append(e.faults, "provider response write: "+err.Error())
		e.mu.Unlock()
	}
}
func shortName(s string) string {
	if len(s) > 64 {
		return s[:64]
	}
	return s
}
func marshal(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
func userItem(text string) []byte {
	return []byte(`{"role":"user","content":[{"type":"input_text","text":` + string(marshal(text)) + `}]}`)
}
func wireRequest(input [][]byte) []byte {
	prefix := []byte(`{"model":"model-a","store":false,"stream":true,"include":["reasoning.encrypted_content"],"input":[{"role":"system","content":[{"type":"input_text","text":""}]}`)
	for _, item := range input {
		prefix = append(prefix, ',')
		prefix = append(prefix, item...)
	}
	return append(prefix, []byte(`],"tools":[]}`)...)
}
func answerSSE(name, answer string, retained, discarded int) ([]byte, [][]byte) {
	reason := map[string]any{"type": "reasoning", "id": "r-" + name, "status": "completed", "summary": []any{}, "encrypted_content": strings.Repeat("r", retained), "created_by": strings.Repeat("d", discarded)}
	message := map[string]any{"type": "message", "id": "m-" + name, "status": "completed", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}}}
	items := []any{reason, message}
	var out bytes.Buffer
	for index, item := range items {
		fmt.Fprintf(&out, "data: %s\n\n", marshal(map[string]any{"type": "response.output_item.done", "output_index": index, "item": item}))
	}
	fmt.Fprintf(&out, "data: %s\n\n", marshal(map[string]any{"type": "response.completed", "response": map[string]any{"id": "response-" + name, "status": "completed", "model": "model-a", "output": items}}))
	out.WriteString("data: [DONE]\n\n")
	delete(reason, "created_by")
	return out.Bytes(), [][]byte{marshal(reason), marshal(message)}
}
func bashSSE() []byte {
	item := map[string]any{"type": "function_call", "id": "bash-item", "status": "completed", "name": "bash", "call_id": "bash-call", "arguments": `{"cmd":"sleep 30","timeout_ms":null}`}
	var out bytes.Buffer
	fmt.Fprintf(&out, "data: %s\n\n", marshal(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item}))
	fmt.Fprintf(&out, "data: %s\n\n", marshal(map[string]any{"type": "response.completed", "response": map[string]any{"id": "bash-response", "status": "completed", "model": "model-a", "output": []any{item}}}))
	out.WriteString("data: [DONE]\n\n")
	return out.Bytes()
}
