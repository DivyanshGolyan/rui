package main

import (
	"encoding/json"
	"testing"
)

func TestSQLiteRequiredEvidenceMutations(t *testing.T) {
	// Independent fixture of every required configuration and usage field.
	const fixture = `{"page_size_bytes":4096,"cache_size_setting":-1024,"hard_heap_limit_bytes":16777216,"cache_spill_threshold":247,"synchronous":3,"journal_mode":"delete","mmap_size_bytes":0,"temp_store":1,"busy_timeout_ms":0,"process_memory_current_bytes":0,"process_memory_highwater_bytes":0,"cache_used_bytes":0,"cache_spills":0,"subject":"measure/spill","cache_size_setting_scope":"raw PRAGMA cache_size; negative magnitude is suggested KiB, positive value is suggested pages"}`
	wrongSettings := map[string]any{
		"page_size_bytes": 8192, "cache_size_setting": -4096,
		"hard_heap_limit_bytes": 33554432, "cache_spill_threshold": -1,
		"synchronous": 2, "journal_mode": "wal", "mmap_size_bytes": 4096,
		"temp_store": 2, "busy_timeout_ms": 100,
	}
	for _, spill := range []bool{false, true} {
		decode := func(field, mutation string) sqliteDiagnostic {
			t.Helper()
			var fields map[string]any
			if err := json.Unmarshal([]byte(fixture), &fields); err != nil {
				t.Fatal(err)
			}
			if spill {
				fields["cache_size_setting"] = -32
			}
			switch mutation {
			case "omit":
				delete(fields, field)
			case "null":
				fields[field] = nil
			case "wrong":
				fields[field] = wrongSettings[field]
			}
			encoded, err := json.Marshal(fields)
			if err != nil {
				t.Fatal(err)
			}
			var record sqliteDiagnostic
			if err := json.Unmarshal(encoded, &record); err != nil {
				t.Fatal(err)
			}
			return record
		}
		status := func(record sqliteDiagnostic) string {
			if !spill {
				return productionDiagnosticsStatus([]sqliteDiagnostic{record})
			}
			if spillDiagnosticsValid([]sqliteDiagnostic{record}, true, false) {
				return "passed"
			}
			return "failed"
		}
		if status(decode("", "")) != "passed" {
			t.Fatal("complete zero-usage fixture rejected")
		}
		for field := range wrongSettings {
			for _, mutation := range []string{"omit", "null", "wrong"} {
				if got := status(decode(field, mutation)); qualificationExitCode(got) == 0 {
					t.Errorf("spill=%v accepted %s %s", spill, mutation, field)
				}
			}
		}
		for _, field := range []string{"process_memory_current_bytes", "process_memory_highwater_bytes", "cache_used_bytes", "cache_spills"} {
			for _, mutation := range []string{"omit", "null"} {
				if got := status(decode(field, mutation)); qualificationExitCode(got) == 0 {
					t.Errorf("spill=%v accepted %s %s", spill, mutation, field)
				}
			}
		}
	}
}
