package main

// Scratch-only one-wave diagnostic, never 20-wave acceptance.
import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"rui.local/qualification/measurement"
)

func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "--provider-child" {
		main()
		return
	}
	os.Exit(m.Run())
}

func TestCounterDiagnostic(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("actual Darwin counters required")
	}
	binary, root := os.Getenv("RUI_COUNTER_BINARY"), os.Getenv("RUI_COUNTER_OUTPUT")
	if binary == "" || root == "" || os.Getenv("RUI_COUNTER_PROBE") == "" {
		t.Fatal("missing explicit private binary, output, or counter probe")
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	digest, err := measurement.SHA256File(binary)
	if err != nil {
		t.Fatal(err)
	}
	result, runError := measureCapacity(binary, root, capacityScenario{Capacity: 100, EventsPerSecond: 100}, 6*time.Second, 1, true, false)
	receipt := map[string]any{"diagnostic_only": true, "not_canonical_repeat_acceptance": true,
		"phase_trace": false, "sqlite_diagnostics": false, "binary_sha256": digest, "result": result}
	if runError != nil {
		receipt["error"] = runError.Error()
	}
	var counterErrors []string
	for _, process := range []string{"host", "provider"} {
		for _, phase := range []string{"initial", "retained"} {
			base := filepath.Join(root, "capacity-100", "round-1", process+"-footprint-"+phase+".txt")
			var sample measurement.ProcessSample
			raw, err := os.ReadFile(base + ".json")
			if err == nil {
				err = json.Unmarshal(raw, &sample)
			}
			if err != nil || sample.FootprintCapture == nil || !sample.FootprintCapture.IdentityUnchanged {
				counterErrors = append(counterErrors, fmt.Sprintf("%s/%s missing or invalid tool identity: %v", process, phase, err))
				continue
			}
			var startTicks uint64
			for _, side := range []string{"before", "after"} {
				var status struct {
					ExitCode int `json:"exit_code"`
				}
				var query struct {
					PID       int32  `json:"pid"`
					RC        int    `json:"rusage_rc"`
					Same      bool   `json:"identity_unchanged"`
					StartSec  uint64 `json:"before_start_sec"`
					StartUsec uint64 `json:"before_start_usec"`
					Ticks     uint64 `json:"proc_start_abstime"`
				}
				prefix := base + ".rusage-" + side
				statusRaw, statusError := os.ReadFile(prefix + "-command.json")
				queryRaw, queryError := os.ReadFile(prefix + ".json")
				if statusError == nil {
					statusError = json.Unmarshal(statusRaw, &status)
				}
				if queryError == nil {
					queryError = json.Unmarshal(queryRaw, &query)
				}
				if statusError != nil || queryError != nil || status.ExitCode != 0 || query.RC != 0 || !query.Same ||
					query.PID != sample.FootprintCapture.PID || query.Ticks == 0 ||
					int64(query.StartSec*1000+query.StartUsec/1000) != sample.FootprintCapture.ProcessStartUnixMS ||
					(side == "after" && startTicks != query.Ticks) {
					counterErrors = append(counterErrors, fmt.Sprintf("%s/%s/%s native query/identity unavailable: status=%+v query=%+v errors=%v/%v", process, phase, side, status, query, statusError, queryError))
				}
				startTicks = query.Ticks
			}
		}
	}
	receipt["counter_errors"] = counterErrors
	if err := measurement.WriteJSON(filepath.Join(root, "diagnostic-result.json"), receipt); err != nil {
		t.Fatal(err)
	}
	if runError != nil {
		t.Fatal(runError)
	}
	if len(counterErrors) != 0 {
		t.Fatal(counterErrors)
	}
	if result == nil {
		t.Fatal("diagnostic did not publish a workload result")
	}
	rows, ok := result["rounds"].([]map[string]any)
	if !ok || len(rows) != 1 || rows[0]["all_results_audited"] != true || rows[0]["offline_audit_after_host_reaped"] != true {
		t.Fatalf("completed single wave not independently audited: %+v", result)
	}
	t.Logf("diagnostic-only single wave audited; unmodified workload verdict=%v; artifacts=%s", result["status"], root)
}
