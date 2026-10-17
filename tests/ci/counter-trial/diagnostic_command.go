package measurement

// Scratch-only adapter. This file is not part of published qualification.
import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"
)

func diagnosticFootprintCommand(command *exec.Cmd, rawPath string) ([]byte, error) {
	if command.Path == "/usr/sbin/lsof" {
		return command.Output()
	}
	probe := os.Getenv("RUI_COUNTER_PROBE")
	if probe == "" {
		return nil, errors.New("scratch counter probe not configured")
	}
	pid := command.Args[len(command.Args)-1]
	observe := func(phase string) error {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		query := exec.CommandContext(ctx, probe, pid)
		start := time.Now().UnixNano()
		raw, err := query.CombinedOutput()
		end := time.Now().UnixNano()
		code := -1
		if query.ProcessState != nil {
			code = query.ProcessState.ExitCode()
		}
		base := rawPath + ".rusage-" + phase
		writeError := os.WriteFile(base+".json", raw, 0o600)
		receipt := map[string]any{"command": query.Args, "begin_unix_ns": start, "end_unix_ns": end, "exit_code": code}
		if err != nil {
			receipt["error"] = err.Error()
		}
		return errors.Join(err, writeError, WriteJSON(base+"-command.json", receipt))
	}
	beforeError := observe("before")
	raw, commandError := command.CombinedOutput()
	afterError := observe("after")
	if err := errors.Join(beforeError, afterError); err != nil {
		// Keep the tool's real exit status independent of this diagnostic probe.
		// The scratch test separately requires every native-query receipt.
		fmt.Fprintln(os.Stderr, "counter diagnostic:", err)
	}
	return raw, commandError
}
