package measurement

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type Client struct {
	Binary    string
	Artifacts string
	Store     string
	Deadline  Deadline
}

func JSONString(value string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, b := range []byte(value) {
		switch b {
		case '"', '\\':
			out.WriteByte('\\')
			out.WriteByte(b)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			if b < 0x20 {
				fmt.Fprintf(&out, `\u%04x`, b)
			} else {
				out.WriteByte(b)
			}
		}
	}
	out.WriteByte('"')
	return out.String()
}

// RequestSystemPrompt reads the baseline from any supported Responses codec.
func RequestSystemPrompt(body []byte) (string, error) {
	var request struct {
		Instructions json.RawMessage `json:"instructions"`
		Input        []struct {
			Role    string `json:"role"`
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"input"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return "", err
	}
	if request.Instructions != nil {
		var instructions string
		if string(request.Instructions) == "null" {
			return "", errors.New("invalid instructions")
		}
		if err := json.Unmarshal(request.Instructions, &instructions); err != nil {
			return "", err
		}
		return instructions, nil
	}
	if len(request.Input) == 0 || request.Input[0].Role != "developer" || len(request.Input[0].Content) == 0 {
		return "", errors.New("missing developer prompt")
	}
	return request.Input[0].Content[0].Text, nil
}

func CanonicalStore(store string) (string, error) {
	absolute, err := filepath.Abs(store)
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(absolute); err == nil {
		return resolved, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(absolute))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(absolute)), nil
}

var modelContextParts = func() []string {
	_, source, _, _ := runtime.Caller(0)
	text, err := os.ReadFile(filepath.Join(filepath.Dir(source), "../../../src/model_instructions.txt"))
	if err != nil {
		panic(err)
	}
	return strings.Split(string(text), "{}")
}()

func ModelInstructions(workspace, session, model string) string {
	workspace = JSONString(workspace)
	return modelContextParts[0] + workspace[1:len(workspace)-1] + modelContextParts[1] +
		session + modelContextParts[2] + builtinInstructions(model) + modelContextParts[3]
}

var builtinInstructionPaths = func() map[string]string {
	_, source, _, _ := runtime.Caller(0)
	text, err := os.ReadFile(filepath.Join(filepath.Dir(source), "../../../src/model_catalog.zig"))
	if err != nil {
		panic(err)
	}
	paths, err := instructionPaths(string(text))
	if err != nil {
		panic(err)
	}
	return paths
}()

func builtinInstructions(model string) string {
	path := builtinInstructionPaths[model]
	if path == "" {
		return ""
	}
	_, source, _, _ := runtime.Caller(0)
	text, err := os.ReadFile(filepath.Join(filepath.Dir(source), "../../../src", path))
	if err != nil {
		panic(err)
	}
	return string(text)
}

func InstructionsSession(instructions string) (string, bool) {
	_, rest, ok := strings.Cut(instructions, modelContextParts[1])
	if !ok {
		return "", false
	}
	session, _, _ := strings.Cut(rest, modelContextParts[2][:1])
	return session, true
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

func (c Client) Configure(key, session string, extra ...string) (string, error) {
	workspace, err := RepositoryRoot()
	if err != nil {
		return "", err
	}
	arguments := []string{
		"session", "configure", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+"-configure.json"),
		"--key", key + "-configure", "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-luna",
	}
	if session != "" {
		arguments = append(arguments, "--session", session)
	}
	arguments = append(arguments, extra...)
	var answer map[string]any
	if err := RunJSON(c.Deadline, &answer, c.Binary, arguments...); err != nil {
		return "", err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return "", fmt.Errorf("configuration was not accepted: %v", answer)
	}
	allocated, err := ConfigurationSession(answer)
	if err == nil && session != "" && allocated != session {
		err = fmt.Errorf("configuration changed Session: %q != %q", allocated, session)
	}
	return allocated, err
}

func (c Client) ConfigureRecord(key string) (map[string]any, error) {
	data, err := os.ReadFile(filepath.Join(c.Artifacts, key+"-configure.json"))
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var record map[string]any
	if err := decoder.Decode(&record); err != nil {
		return nil, fmt.Errorf("configure record %s: %w", key, err)
	}
	return record, nil
}

func ConfigurationSession(reply map[string]any) (string, error) {
	session, ok := StringField(reply, "answer", "session")
	if !ok || len(session) != 6 || strings.Trim(session, "0123456789abcdefghjkmnpqrstvwxyz") != "" {
		return "", fmt.Errorf("configuration omitted canonical Session ID: %v", reply)
	}
	return session, nil
}

func (c Client) Message(key, session, text string) error {
	source := filepath.Join(c.Artifacts, key+".txt")
	if err := os.WriteFile(source, []byte(text), 0o600); err != nil {
		return err
	}
	var answer map[string]any
	if err := RunJSONInput(c.Deadline, strings.NewReader(text), &answer, c.Binary,
		"session", "send", "--store", c.Store, "--to", session, "--record", filepath.Join(c.Artifacts, key+".json"),
		"--key", key); err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("message was not accepted: %v", answer)
	}
	return nil
}

func (c Client) StopSession(key, session string) error {
	var answer map[string]any
	if err := RunJSON(c.Deadline, &answer, c.Binary,
		"session", "stop", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+".json"),
		"--key", key, "--session", session); err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("session stop was not accepted: %v", answer)
	}
	return nil
}

func (c Client) WaitAction(session string) (string, error) {
	var action string
	err := WaitFor(c.Deadline, 25*time.Millisecond, "unresolved Action for "+session, func() (bool, error) {
		report, err := c.Inspect(session)
		if err != nil {
			return false, err
		}
		actions, ok := nested(report, "actions", "unresolved").([]any)
		if !ok || len(actions) != 1 {
			return false, nil
		}
		row, ok := actions[0].(map[string]any)
		if !ok {
			return false, errors.New("malformed unresolved Action")
		}
		action, ok = row["action"].(string)
		return ok && action != "", nil
	})
	return action, err
}

func (c Client) AllowAction(key, session, action string) error {
	var answer map[string]any
	if err := RunJSON(c.Deadline, &answer, c.Binary,
		"action", "allow", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+".json"),
		"--key", key, "--session", session, "--action", action); err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("Action allowance was not accepted: %v", answer)
	}
	return nil
}

func (c Client) Observe(key string) (map[string]any, error) {
	var result struct {
		Observation map[string]any `json:"observation"`
	}
	if err := RunJSON(c.Deadline, &result, c.Binary, "request", "inspect", "--store", c.Store, "--key", key); err != nil {
		return nil, err
	}
	return result.Observation, nil
}

func (c Client) Inspect(session string) (map[string]any, error) {
	var result map[string]any
	if err := RunJSON(c.Deadline, &result, c.Binary, "session", "inspect", "--store", c.Store, "--session", session); err != nil {
		return nil, err
	}
	return result, nil
}

func (c Client) ReadAction(session, action, field string) ([]byte, error) {
	command := "read-" + field
	if field != "call-id" && field != "arguments" {
		return nil, fmt.Errorf("unsupported Action field %q", field)
	}
	return Run(c.Deadline, c.Binary, "action", command, "--store", c.Store, "--session", session, "--action", action)
}

func (c Client) WaitResult(key string) (map[string]any, error) {
	var result map[string]any
	err := WaitFor(c.Deadline, 25*time.Millisecond, "terminal result for "+key, func() (bool, error) {
		observation, err := c.Observe(key)
		if err != nil {
			return false, err
		}
		candidate, ok := observation["result"].(map[string]any)
		if ok && candidate["status"] != nil {
			result = observation
			return true, nil
		}
		return false, nil
	})
	return result, err
}

func StringField(value map[string]any, names ...string) (string, bool) {
	field := nested(value, names...)
	text, ok := field.(string)
	return text, ok
}

func IntStringField(value map[string]any, names ...string) (uint64, bool) {
	text, ok := StringField(value, names...)
	if !ok {
		return 0, false
	}
	var number uint64
	_, err := fmt.Sscan(strings.TrimSpace(text), &number)
	return number, err == nil
}

func (c Client) Submit(key, session, text string) (string, error) {
	session, err := c.Configure(key, session, "--tools", "none")
	if err != nil {
		return "", err
	}
	return session, c.Message(key, session, text)
}

func (c Client) RecordJSON(name string, value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	return os.WriteFile(filepath.Join(c.Artifacts, name), encoded, 0o600)
}
