package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"rui.local/qualification/measurement"
)

func TestConfigurationCaptureReturnsAllocatedIdentity(t *testing.T) {
	// Keep the socket below macOS's path limit, independent of the test name.
	directory, err := os.MkdirTemp("", "rui-wire-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "host.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	captured := make(chan map[string]any, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var command map[string]any
		if err := json.NewDecoder(request.Body).Decode(&command); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		captured <- command
		writer.Write([]byte(`{"answer":{"status":"accepted","session":"k7m2qx"}}`))
	})}
	defer server.Close()
	go server.Serve(listener)
	session, err := configure(measurement.NewDeadline(time.Second), socket, "/store", "/workspace", "measure/payload")
	if err != nil {
		t.Fatal(err)
	}
	command := <-captured
	if command["session"] != "" || command["key"] != "configure-measure/payload" || session != "k7m2qx" {
		t.Fatalf("creation capture=%v, allocated Session=%q", command, session)
	}
	message := messageValue("/store", "payload-1000", session, "text")
	inspection := inspectValue("/store", session)
	if message.Session != "k7m2qx" || inspection.Session != "k7m2qx" || message.Key != "payload-1000" {
		t.Fatalf("allocated identity not forwarded: message=%+v inspection=%+v", message, inspection)
	}
}
