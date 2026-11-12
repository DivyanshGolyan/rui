package main

import "testing"

func TestParseRejectsMixedHostRuns(t *testing.T) {
	rows := completeV4Rows()
	rows[len(rows)-1]["run"] = "1001"
	if _, err := parseObservations(encodeEvents(rows)); err == nil {
		t.Fatal("records from two Host runs accepted")
	}
}
