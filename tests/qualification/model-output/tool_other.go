//go:build !linux

package main

import (
	"errors"

	"rui.local/qualification/model-output/provider"
)

func toolMeasurementOptions(sessions int, workload, expectation string) error {
	return errors.New("--tool-sessions requires Linux process-tree PSS")
}

func runToolProviderChild(config provider.ToolConfig) error {
	return errors.New("--tool-sessions requires Linux")
}

func measureTools(binary, output string, sessions int, workload, trace, expectation string) (map[string]any, error) {
	return map[string]any{"format": "rui-tool-turn-v1", "status": "incomplete"}, errors.New("--tool-sessions requires Linux")
}
