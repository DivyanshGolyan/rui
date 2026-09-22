package measurement

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Client struct {
	Binary    string
	Artifacts string
	Store     string
	Deadline  Deadline
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

func (c Client) Configure(key, session string, extra ...string) error {
	workspace, err := RepositoryRoot()
	if err != nil {
		return err
	}
	arguments := []string{
		"configure", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+"-configure.json"),
		"--key", key + "-configure", "--session", session, "--workspace", workspace, "--provider", "codex", "--model", "model-a",
	}
	arguments = append(arguments, extra...)
	var answer map[string]any
	if err := RunJSON(c.Deadline, &answer, c.Binary, arguments...); err != nil {
		return err
	}
	if nested(answer, "answer", "status") != "accepted" {
		return fmt.Errorf("configuration was not accepted: %v", answer)
	}
	return nil
}

func (c Client) Message(key, session, text string) error {
	source := filepath.Join(c.Artifacts, key+".txt")
	if err := os.WriteFile(source, []byte(text), 0o600); err != nil {
		return err
	}
	var answer map[string]any
	if err := RunJSON(c.Deadline, &answer, c.Binary,
		"message", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+".json"),
		"--key", key, "--session", session, "--text", source); err != nil {
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
		"stop-session", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+".json"),
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
		"allow-action", "--store", c.Store, "--record", filepath.Join(c.Artifacts, key+".json"),
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
	if err := RunJSON(c.Deadline, &result, c.Binary, "observe-command", "--store", c.Store, "--key", key); err != nil {
		return nil, err
	}
	return result.Observation, nil
}

func (c Client) Inspect(session string) (map[string]any, error) {
	var result map[string]any
	if err := RunJSON(c.Deadline, &result, c.Binary, "inspect-session", "--store", c.Store, "--session", session); err != nil {
		return nil, err
	}
	return result, nil
}

func (c Client) ReadAction(session, action, field string) ([]byte, error) {
	command := "read-action-" + field
	if field != "call-id" && field != "arguments" {
		return nil, fmt.Errorf("unsupported Action field %q", field)
	}
	return Run(c.Deadline, c.Binary, command, "--store", c.Store, "--session", session, "--action", action)
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

func (c Client) Submit(key, session, text string) error {
	if err := c.Configure(key, session, "--tools", "none"); err != nil {
		return err
	}
	return c.Message(key, session, text)
}

func (c Client) RecordJSON(name string, value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	return os.WriteFile(filepath.Join(c.Artifacts, name), encoded, 0o600)
}
