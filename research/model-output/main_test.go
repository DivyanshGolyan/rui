package main

import (
	"testing"

	"latifa.local/research/measurement"
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

func TestOutputAuditQualifiesEverySemanticCount(t *testing.T) {
	valid := outputAudit{CanonicalOutputItems: 129, PrivateContentRows: 130, AssistantProjections: 1}
	if !outputAuditValid(valid, 128) || outputCaseStatus("passed", true) != "passed" {
		t.Fatal("valid output audit was rejected")
	}
	mutations := []outputAudit{
		{CanonicalOutputItems: 128, PrivateContentRows: 130, AssistantProjections: 1},
		{CanonicalOutputItems: 129, PrivateContentRows: 129, AssistantProjections: 1},
		{CanonicalOutputItems: 129, PrivateContentRows: 130, AssistantProjections: 2},
	}
	for _, audit := range mutations {
		if outputAuditValid(audit, 128) {
			t.Fatalf("mutated output audit was accepted: %+v", audit)
		}
	}
	if got := outputCaseStatus("incomplete", false); got != "failed" {
		t.Fatalf("semantic failure was hidden by memory status: %s", got)
	}
}
