package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"latifa.local/research/measurement"
	"latifa.local/research/model-output/provider"
)

func TestReduceStatusesIncludesEveryFamilyAndPreservesPrecedence(t *testing.T) {
	families := 4
	for family := range families {
		for _, status := range []string{"target_miss", "incomplete", "failed"} {
			rows := make([][]map[string]any, families)
			for index := range rows {
				rows[index] = []map[string]any{{"status": "passed"}}
			}
			rows[family][0]["status"] = status
			if got := reduceStatuses(rows...); got != status {
				t.Fatalf("family %d status %s reduced to %s", family, status, got)
			}
		}
	}
	if got := reduceStatuses([]map[string]any{{"status": "target_miss"}}, []map[string]any{{"status": "incomplete"}}, []map[string]any{{"status": "failed"}}); got != "failed" {
		t.Fatalf("precedence reduced to %s", got)
	}
}

func TestMemoryStatusDistinguishesMissingAggregationFromTargetMiss(t *testing.T) {
	incomplete := wholeLatifa(measurement.ProcessSample{LiveDescendantProcesses: 1})
	if got := memoryStatus(incomplete); got != "incomplete" {
		t.Fatalf("live descendant reduced to %s", got)
	}
	miss := wholeLatifa(measurement.ProcessSample{Footprint: measurement.Footprint{LifetimePeakBytes: memoryTarget + 1}})
	if got := memoryStatus(miss); got != "target_miss" {
		t.Fatalf("memory miss reduced to %s", got)
	}
}

func TestExpectedCapacityRequestDigest(t *testing.T) {
	bytes, digest := expectedCapacityRequests([]string{"capacity-1-0"})
	if bytes != 244 || digest != "358881c8b33611579e786d84931f25c3d22b8289a4ed926d0bb5759c050ab89d" {
		t.Fatalf("unexpected independent request oracle: %d %s", bytes, digest)
	}
}

func TestResolveBinaryArgumentUsesLauncherWorkingDirectory(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repository := filepath.Dir(filepath.Dir(working))
	research := filepath.Join(repository, "research")
	if _, err := os.Stat(filepath.Join(research, "go.mod")); err != nil {
		t.Fatalf("test did not start below repository research directory: %v", err)
	}
	t.Chdir(research)
	resolved, err := resolveBinaryArgument("./.zig-cache/o/example/latifa")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(repository, ".zig-cache/o/example/latifa")
	if resolved != want {
		t.Fatalf("resolved binary = %q want %q", resolved, want)
	}
	absolute := "/synthetic/link/../latifa"
	resolved, err = resolveBinaryArgument(absolute)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != absolute {
		t.Fatalf("absolute binary = %q want unchanged %q", resolved, absolute)
	}
}

func TestOutputAuditQualifiesEverySemanticCount(t *testing.T) {
	valid := outputAudit{CanonicalOutputItems: 33, PrivateContentRows: 34, AssistantProjections: 1}
	if !outputAuditValid(valid, 32) || outputCaseStatus("passed", true) != "passed" {
		t.Fatal("valid output audit was rejected")
	}
	mutations := []outputAudit{
		{CanonicalOutputItems: 32, PrivateContentRows: 34, AssistantProjections: 1},
		{CanonicalOutputItems: 33, PrivateContentRows: 33, AssistantProjections: 1},
		{CanonicalOutputItems: 33, PrivateContentRows: 34, AssistantProjections: 2},
	}
	for _, audit := range mutations {
		if outputAuditValid(audit, 32) {
			t.Fatalf("mutated output audit was accepted: %+v", audit)
		}
	}
	if got := outputCaseStatus("incomplete", false); got != "failed" {
		t.Fatalf("semantic failure was hidden by memory status: %s", got)
	}
}

func TestSpillVerdictRequiresEverySuccessPredicate(t *testing.T) {
	attempt := 1
	resolution := "completed"
	zero := 0
	validFacts := spillFacts{IntegrityCheck: "ok", CompletedTurns: 1, CanonicalOutputItems: 2, AssistantProjections: 1, OperationCount: 1, AttemptOrdinal: &attempt, ResolutionCode: &resolution, Uncertain: &zero}
	completeMemory := map[string]any{"status": "complete", "within_256_mib_target": true}
	validExecution := map[string]any{"dispatch_fenced": false, "custody_occupied": "0", "scratch_used_bytes": "0"}
	if status, _, _ := spillVerdict(true, true, false, 1, completeMemory, completeMemory, validExecution, validFacts, "", "observed"); status != "passed" {
		t.Fatalf("valid spill success reduced to %s", status)
	}
	checks := []struct {
		name      string
		requests  int
		execution map[string]any
		facts     spillFacts
		write     string
	}{
		{"request count", 0, validExecution, validFacts, "observed"},
		{"dispatch fence", 1, map[string]any{"dispatch_fenced": true, "custody_occupied": "0", "scratch_used_bytes": "0"}, validFacts, "observed"},
		{"retained scratch", 1, map[string]any{"dispatch_fenced": false, "custody_occupied": "0", "scratch_used_bytes": "1"}, validFacts, "observed"},
		{"offline facts", 1, validExecution, spillFacts{IntegrityCheck: "ok", CompletedTurns: 1, CanonicalOutputItems: 1, AssistantProjections: 1, OperationCount: 1, AttemptOrdinal: &attempt, ResolutionCode: &resolution}, "observed"},
		{"decreasing write counter", 1, validExecution, validFacts, "invalid"},
	}
	for _, check := range checks {
		if status, _, _ := spillVerdict(true, true, false, check.requests, completeMemory, completeMemory, check.execution, check.facts, "", check.write); status != "failed" {
			t.Fatalf("%s negative control reduced to %s", check.name, status)
		}
	}
	priorFailure := "provider_http_503"
	withPriorFailure := validFacts
	withPriorFailure.LastFailureCode = &priorFailure
	if status, _, _ := spillVerdict(true, true, false, 1, completeMemory, completeMemory, validExecution, withPriorFailure, "", "observed"); status != "failed" {
		t.Fatalf("completed attempt with prior failure reduced to %s", status)
	}
	if status, _, _ := spillVerdict(true, true, false, 1, completeMemory, completeMemory, validExecution, validFacts, "", "unavailable"); status != "incomplete" {
		t.Fatalf("missing write evidence reduced to %s", status)
	}
}

func TestSpillVerdictRequiresExactCleanRollback(t *testing.T) {
	attempt := 1
	uncertain := 1
	retryDue := int64(0)
	rollback := spillFacts{IntegrityCheck: "ok", PartialTurns: 1, OperationCount: 1, AttemptOrdinal: &attempt, Uncertain: &uncertain, RetryDueAtMS: &retryDue}
	completeMemory := map[string]any{"status": "complete", "within_256_mib_target": true}
	message := "dispatch fenced after model output import failure: OutOfMemory"
	if status, clean, expected := spillVerdict(false, false, true, 1, completeMemory, nil, nil, rollback, message, "unavailable"); status != "expected_memory_failure" || !clean || !expected {
		t.Fatalf("valid rollback = %s clean=%t expected=%t", status, clean, expected)
	}
	if status, clean, expected := spillVerdict(false, false, false, 1, completeMemory, nil, nil, rollback, message, "unavailable"); status != "failed" || !clean || expected {
		t.Fatalf("controller-stopped rollback = %s clean=%t expected=%t", status, clean, expected)
	}
	rollback.CanonicalOutputItems = 1
	if status, _, _ := spillVerdict(false, false, true, 1, completeMemory, nil, nil, rollback, message, "unavailable"); status != "failed" {
		t.Fatalf("dirty rollback reduced to %s", status)
	}
	rollback.CanonicalOutputItems = 0
	if status, _, _ := spillVerdict(false, false, true, 1, completeMemory, nil, nil, rollback, "OutOfMemory", "unavailable"); status != "failed" {
		t.Fatalf("non-specific OOM reduced to %s", status)
	}
	retryable := rollback
	retryableUncertain := 0
	futureDue := int64(123)
	failure := "response_capture_failed"
	retryable.Uncertain = &retryableUncertain
	retryable.RetryDueAtMS = &futureDue
	retryable.LastFailureCode = &failure
	if status, _, _ := spillVerdict(false, false, true, 1, completeMemory, nil, nil, retryable, message, "unavailable"); status != "failed" {
		t.Fatalf("scheduled retry reduced to %s", status)
	}
}

func TestSpillVerdictFailurePrecedesMemoryQualification(t *testing.T) {
	attempt := 1
	badFacts := spillFacts{IntegrityCheck: "bad", OperationCount: 1, AttemptOrdinal: &attempt}
	for _, memory := range []map[string]any{
		{"status": "incomplete"},
		{"status": "complete", "within_256_mib_target": false},
	} {
		if status, _, _ := spillVerdict(true, true, false, 1, memory, memory, map[string]any{}, badFacts, "", "observed"); status != "failed" {
			t.Fatalf("bad completed facts with memory %v reduced to %s", memory, status)
		}
		if status, _, _ := spillVerdict(true, false, false, 1, memory, nil, nil, badFacts, "unexpected", "unavailable"); status != "failed" {
			t.Fatalf("unexpected failure with memory %v reduced to %s", memory, status)
		}
	}
	zero := 0
	resolution := "completed"
	validFacts := spillFacts{IntegrityCheck: "ok", CompletedTurns: 1, CanonicalOutputItems: 2, AssistantProjections: 1, OperationCount: 1, AttemptOrdinal: &attempt, ResolutionCode: &resolution, Uncertain: &zero}
	execution := map[string]any{"dispatch_fenced": false, "custody_occupied": "0", "scratch_used_bytes": "0"}
	overTarget := map[string]any{"status": "complete", "within_256_mib_target": false}
	if status, _, _ := spillVerdict(true, true, false, 1, overTarget, overTarget, execution, validFacts, "", "unavailable"); status != "incomplete" {
		t.Fatalf("missing write evidence did not precede target miss: %s", status)
	}
}

func TestSpillComparisonUsesSharedFailurePrecedence(t *testing.T) {
	if got := spillComparisonStatus("failed", "incomplete"); got != "failed" {
		t.Fatalf("failed plus incomplete reduced to %s", got)
	}
	if got := spillComparisonStatus("passed", "expected_memory_failure"); got != "passed" {
		t.Fatalf("expected memory failure reduced to %s", got)
	}
}

func TestSpillWriteEvidenceRejectsMissingAndDecreasingCounters(t *testing.T) {
	initial := measurement.ProcessSample{DiskWriteBytes: 100}
	if _, status := spillWriteEvidence(initial, nil); status != "unavailable" {
		t.Fatalf("missing final sample reduced to %s", status)
	}
	decreasing := measurement.ProcessSample{DiskWriteBytes: 99}
	if _, status := spillWriteEvidence(initial, &decreasing); status != "invalid" {
		t.Fatalf("decreasing counter reduced to %s", status)
	}
	increasing := measurement.ProcessSample{DiskWriteBytes: 101}
	if evidence, status := spillWriteEvidence(initial, &increasing); status != "observed" || evidence["delta_bytes"] != uint64(1) {
		t.Fatalf("increasing counter = %s %v", status, evidence)
	}
}

func TestSpillDiagnosticsRequireEffectiveConfiguration(t *testing.T) {
	u64 := func(value uint64) *uint64 { return &value }
	i64 := func(value int64) *int64 { return &value }
	text := func(value string) *string { return &value }
	diagnostic := func(spills uint64, threshold int64) sqliteDiagnostic {
		return sqliteDiagnostic{Subject: "measure/spill", HardHeapLimitBytes: u64(16 * 1024 * 1024), Synchronous: i64(3), JournalMode: text("delete"), CacheSpillThreshold: i64(threshold), CacheSpills: u64(spills)}
	}
	valid := []sqliteDiagnostic{diagnostic(0, 991), diagnostic(1, 991)}
	if !spillDiagnosticsValid(valid, true, true) {
		t.Fatal("valid spill-on diagnostics were rejected")
	}
	invalid := append([]sqliteDiagnostic(nil), valid...)
	invalid[1].Synchronous = i64(2)
	if spillDiagnosticsValid(invalid, true, true) {
		t.Fatal("mismatched synchronous setting was accepted")
	}
	if spillDiagnosticsValid(nil, true, true) {
		t.Fatal("missing diagnostics were accepted")
	}
	if spillDiagnosticsValid(valid[:1], true, true) || spillDiagnosticsValid(append(valid, valid[1]), true, true) {
		t.Fatal("wrong diagnostic population was accepted")
	}
	zero := []sqliteDiagnostic{diagnostic(0, 991), diagnostic(0, 991)}
	if spillDiagnosticsValid(zero, true, true) {
		t.Fatal("zero spill-on counter was accepted")
	}
	decreasing := []sqliteDiagnostic{diagnostic(2, 991), diagnostic(1, 991)}
	if spillDiagnosticsValid(decreasing, true, true) {
		t.Fatal("decreasing spill-on counter was accepted")
	}
	spillOff := []sqliteDiagnostic{diagnostic(0, 0), diagnostic(0, 0)}
	if !spillDiagnosticsValid(spillOff, false, true) {
		t.Fatal("valid spill-off diagnostics were rejected")
	}
	spillOff[1].CacheSpills = u64(1)
	if spillDiagnosticsValid(spillOff, false, true) {
		t.Fatal("nonzero spill-off counter was accepted")
	}
	if !spillDiagnosticsValid([]sqliteDiagnostic{diagnostic(0, 0)}, false, false) {
		t.Fatal("expected-exit initial diagnostic was rejected")
	}
}

func TestSpillDiagnosticDecoderRejectsMalformedAndDuplicateFields(t *testing.T) {
	malformed := []byte(`{"latifa_test_phase":"sqlite_diagnostic"`)
	if _, err := sqliteDiagnosticRecords(malformed); err == nil {
		t.Fatal("malformed diagnostic was accepted")
	}
	duplicate := []byte(`{"latifa_test_phase":"sqlite_diagnostic","subject":"measure/spill","cache_spills":0,"cache_spills":1}`)
	if _, err := sqliteDiagnosticRecords(duplicate); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate diagnostic error = %v", err)
	}
}

func TestExpectedCapacityWorkUsesIndependentCheckedArithmetic(t *testing.T) {
	work, err := expectedCapacityWork(1000, 60*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if work != (capacityWork{Batches: 3_000_000, Events: 6_000_000, Bytes: 234_000_000}) {
		t.Fatalf("work = %+v", work)
	}
	if _, err := checkedCapacityMultiply(^uint64(0), 2); err == nil {
		t.Fatal("overflow unexpectedly accepted")
	}
	if _, err := checkedCapacityAdd(^uint64(0), 1); err == nil {
		t.Fatal("addition overflow unexpectedly accepted")
	}
}

func validProviderSummary(t *testing.T) provider.Summary {
	t.Helper()
	encoded := `{
		"delivery_method":"bounded_delivery_v1",
		"delivery_rule":{"batch_interval_ns":20000000,"allowed_delivery_variation_ns":20000000,"maximum_completion_gap_ns":40000000,"burst_window_ns":20000000,"maximum_batches_per_burst_window":2},
		"expected_streams":1,"ready_streams":1,"offer_finished_streams":1,"terminal_finished_streams":1,
		"valid_offer_streams":1,"timing_invalid_streams":0,"offer_failed_streams":0,"terminal_failed_streams":0,
		"minimum_completed_batches":3000,"maximum_completed_batches":3000,
		"completed_batches":3000,"completed_events":6000,"offer_bytes":234000,
		"expected_batches":3000,"expected_events":6000,"expected_offer_bytes":234000,
		"maximum_completion_delay":{"id":"stream","ordinal":7,"observed_ns":40000000},
		"maximum_adjacent_gap":{"id":"stream","ordinal":8,"observed_ns":40000000},
		"minimum_two_back_span":{"id":"stream","ordinal":9,"observed_ns":20000000},
		"start_unix_ns":100000000000,"offer_horizon_unix_ns":160020000000,"hard_deadline_unix_ns":160040000000,
		"earliest_final_completion_unix_ns":159980000000,
		"event_bytes":39,"events_per_batch":2,"batches_per_stream":3000,"offer_seconds":60
	}`
	var summary provider.Summary
	if err := json.Unmarshal([]byte(encoded), &summary); err != nil {
		t.Fatal(err)
	}
	return summary
}

func TestCapacityVerdictKeepsInvalidProviderEvidenceIncomplete(t *testing.T) {
	offer := validProviderSummary(t)
	valid := capacityVerdictInput{
		Capacity: 1, Duration: 60 * time.Second, Offer: offer, Completion: offer,
		ExpectedWork:  capacityWork{Batches: 3000, Events: 6000, Bytes: 234000},
		CaptureStatus: "passed", CleanupStatus: "passed", RequestIntegrityStatus: "passed",
		ResultDeliveryStatus: "passed", DurableAuditStatus: "passed", MemoryStatus: "passed", SustainedCPUStatus: "passed",
	}
	if got := capacityVerdict(valid); got != "passed" {
		t.Fatalf("valid capacity reduced to %s", got)
	}
	incomplete := valid
	incomplete.Offer.CompletedBatches--
	if got := capacityVerdict(incomplete); got != "incomplete" {
		t.Fatalf("incomplete provider work reduced to %s", got)
	}
	terminalFailure := valid
	terminalFailure.Completion.TerminalFailedStreams = 1
	if got := capacityVerdict(terminalFailure); got != "incomplete" {
		t.Fatalf("terminal fixture failure reduced to %s", got)
	}
	hostFailure := valid
	hostFailure.DurableAuditStatus = "failed"
	hostFailure.Offer.CompletedBatches--
	if got := capacityVerdict(hostFailure); got != "failed" {
		t.Fatalf("Host semantic failure did not precede incomplete provider evidence: %s", got)
	}
	for name, mutate := range map[string]func(*provider.Summary){
		"early":           func(summary *provider.Summary) { summary.EarlyCompletionViolations = 1 },
		"late":            func(summary *provider.Summary) { summary.LateCompletionViolations = 1 },
		"gap":             func(summary *provider.Summary) { summary.CompletionGapViolations = 1 },
		"burst":           func(summary *provider.Summary) { summary.BurstWindowViolations = 1 },
		"minimum batches": func(summary *provider.Summary) { summary.MinimumBatches-- },
		"event bytes":     func(summary *provider.Summary) { summary.EventBytes++ },
		"maximum delay": func(summary *provider.Summary) {
			summary.MaximumCompletionDelay.ObservedNS = (40 * time.Millisecond).Nanoseconds() + 1
		},
		"maximum gap": func(summary *provider.Summary) {
			summary.MaximumAdjacentGap.ObservedNS = (40 * time.Millisecond).Nanoseconds() + 1
		},
		"two-back span": func(summary *provider.Summary) {
			summary.MinimumTwoBackSpan.ObservedNS = (20 * time.Millisecond).Nanoseconds() - 1
		},
		"missing delay":    func(summary *provider.Summary) { summary.MaximumCompletionDelay = nil },
		"missing gap":      func(summary *provider.Summary) { summary.MaximumAdjacentGap = nil },
		"missing two-back": func(summary *provider.Summary) { summary.MinimumTwoBackSpan = nil },
	} {
		changed := valid
		changed.Offer = validProviderSummary(t)
		mutate(&changed.Offer)
		if got := capacityVerdict(changed); got != "incomplete" {
			t.Fatalf("inconsistent %s evidence reduced to %s", name, got)
		}
	}
}

func TestTerminalFixtureFailureLeavesDependentHostFactsUnavailable(t *testing.T) {
	offer := validProviderSummary(t)
	completion := offer
	completion.TerminalFailedStreams = 1
	input := capacityVerdictInput{
		Capacity: 1, Duration: 60 * time.Second, Offer: offer, Completion: completion,
		ExpectedWork:  capacityWork{Batches: 3000, Events: 6000, Bytes: 234000},
		CaptureStatus: "passed", CleanupStatus: "passed", RequestIntegrityStatus: "passed",
		ResultDeliveryStatus: dependentObservationStatus(providerTerminalComplete(completion, 1), true, false),
		DurableAuditStatus:   dependentObservationStatus(providerTerminalComplete(completion, 1), true, false),
		MemoryStatus:         "passed", SustainedCPUStatus: "passed",
	}
	if input.ResultDeliveryStatus != "unavailable" || input.DurableAuditStatus != "unavailable" {
		t.Fatalf("terminal prerequisite produced result %s audit %s", input.ResultDeliveryStatus, input.DurableAuditStatus)
	}
	if got := capacityVerdict(input); got != "incomplete" {
		t.Fatalf("terminal fixture failure reduced to %s", got)
	}
	input.CleanupStatus = "failed"
	if got := capacityVerdict(input); got != "failed" {
		t.Fatalf("independent Host contradiction reduced to %s", got)
	}
	if got := dependentObservationStatus(true, true, false); got != "failed" {
		t.Fatalf("available dependent contradiction reduced to %s", got)
	}
}

func TestCapacityCPUWindowUsesConservativeQueryBrackets(t *testing.T) {
	start := time.Unix(100, 0)
	first := bracketedCPUSample{QueryStart: start.Add(10 * time.Second), QueryEnd: start.Add(10*time.Second + 5*time.Millisecond)}
	second := bracketedCPUSample{QueryStart: first.QueryEnd.Add(40 * time.Second), QueryEnd: first.QueryEnd.Add(40*time.Second + 5*time.Millisecond)}
	final := second.QueryEnd
	if !capacityCPUWindowValid(start, first, second, final) {
		t.Fatal("inclusive 40-second and final-completion boundaries were rejected")
	}
	tooShort := second
	tooShort.QueryStart = first.QueryEnd.Add(40*time.Second - time.Nanosecond)
	if capacityCPUWindowValid(start, first, tooShort, final) {
		t.Fatal("short conservative interval was accepted")
	}
	afterWork := second
	afterWork.QueryEnd = final.Add(time.Nanosecond)
	if capacityCPUWindowValid(start, first, afterWork, final) {
		t.Fatal("query extending past simultaneous work was accepted")
	}
	if capacityCPUWindowValid(start, first, second, time.Time{}) {
		t.Fatal("missing provider completion boundary was accepted")
	}
	if status := sustainedCPUQualificationStatus(false, true, 1); status != "unavailable" {
		t.Fatalf("partial valid-stream subset labeled CPU %s", status)
	}
}

func TestCapacityAuditRejectsAttemptOneWithPriorFailure(t *testing.T) {
	key := "capacity-1-round-1-0"
	session := "measure/capacity-1/1/0"
	row := capacityAuditRow{Key: key, Session: session, InputText: key, TurnOutcome: "completed", OperationSession: session, AttemptOrdinal: 1, AllowanceUsed: 1, ResolutionCode: "completed", ResponseID: "capacity-response-" + key, BodyModel: "model-a-served", OpenAIModel: "model-a-served", RequestID: "capacity-" + key, OutputItems: 1, PrivateOutputItems: 1, AssistantProjections: 1}
	if !capacityAuditRowsValid([]capacityAuditRow{row}, []string{key}, []string{session}) {
		t.Fatal("valid capacity audit row was rejected")
	}
	failure := "provider_http_503"
	row.LastFailureCode = &failure
	if capacityAuditRowsValid([]capacityAuditRow{row}, []string{key}, []string{session}) {
		t.Fatal("attempt one with prior failure was accepted")
	}
	row.LastFailureCode = nil
	for name, mutate := range map[string]func(*capacityAuditRow){
		"output items":          func(row *capacityAuditRow) { row.OutputItems = 2 },
		"private output items":  func(row *capacityAuditRow) { row.PrivateOutputItems = 0 },
		"assistant projections": func(row *capacityAuditRow) { row.AssistantProjections = 2 },
	} {
		changed := row
		mutate(&changed)
		if capacityAuditRowsValid([]capacityAuditRow{changed}, []string{key}, []string{session}) {
			t.Fatalf("mutated %s was accepted", name)
		}
	}
}
