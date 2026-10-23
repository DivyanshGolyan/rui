package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestConfigurationCaptureRequestsStoreAllocation(t *testing.T) {
	command := configuration("/store", "/workspace", "measure/00000000")
	encoded, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	if command.Key != "measure/00000000" || command.Session != "" ||
		!strings.Contains(string(encoded), `"key":"measure/00000000","session":"","configuration":`) {
		t.Fatalf("creation capture must preserve its key and encode the empty creation intent: %s", encoded)
	}
}
