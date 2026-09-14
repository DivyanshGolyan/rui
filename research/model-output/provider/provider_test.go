package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type shortWriter struct {
	limit int
}

func (w shortWriter) Write(value []byte) (int, error) {
	if len(value) < w.limit {
		return len(value), nil
	}
	return w.limit, nil
}

func TestPacedWriteCountsPartialBodyBytes(t *testing.T) {
	flushed := false
	written, finishedAt, err := writePacedBody(shortWriter{limit: 3}, func() error {
		flushed = true
		return nil
	}, "abcdef", time.Now)
	if written != 3 || !finishedAt.IsZero() || !errors.Is(err, io.ErrShortWrite) || flushed {
		t.Fatalf("partial write = bytes %d finished_at %s err %v flushed %t", written, finishedAt, err, flushed)
	}
}

type countingWriter struct {
	writes int
	body   bytes.Buffer
}

func (w *countingWriter) Write(value []byte) (int, error) {
	w.writes++
	return w.body.Write(value)
}

func (w *countingWriter) String() string { return w.body.String() }

func TestScheduledBatchClassifiesDeadlineBoundaries(t *testing.T) {
	origin := time.Unix(100, 0)
	slot := scheduledSlot{start: origin, end: origin.Add(20 * time.Millisecond)}
	for _, wakeAt := range []time.Time{slot.end, slot.end.Add(time.Nanosecond)} {
		writer := &countingWriter{}
		flushes := 0
		result, err := offerScheduledBatch(writer, func() error { flushes++; return nil }, "abcdef", slot, wakeAt, func() time.Time {
			t.Fatal("late wake sampled a write completion time")
			return time.Time{}
		})
		if err != nil || result.written != 0 || result.completed || result.missedStage != lateWake || result.overdue != wakeAt.Sub(slot.end) || writer.writes != 0 || flushes != 0 {
			t.Fatalf("late wake %s = result %+v writes %d flushes %d err %v", wakeAt, result, writer.writes, flushes, err)
		}
	}
	for _, test := range []struct {
		name      string
		finished  time.Time
		completed bool
		stage     missStage
		overdue   time.Duration
	}{
		{name: "at deadline", finished: slot.end, completed: true},
		{name: "after deadline", finished: slot.end.Add(time.Nanosecond), stage: lateFlush, overdue: time.Nanosecond},
	} {
		t.Run(test.name, func(t *testing.T) {
			writer := &countingWriter{}
			flushes := 0
			result, err := offerScheduledBatch(writer, func() error { flushes++; return nil }, "abcdef", slot, slot.start, func() time.Time { return test.finished })
			if err != nil || result.written != 6 || result.completed != test.completed || result.missedStage != test.stage || result.overdue != test.overdue || writer.String() != "abcdef" || writer.writes != 1 || flushes != 1 {
				t.Fatalf("scheduled write = result %+v body %q writes %d flushes %d err %v", result, writer.String(), writer.writes, flushes, err)
			}
		})
	}
}

func TestMissEvidenceOwnsExactBoundedAccounting(t *testing.T) {
	var evidence missEvidence
	if evidence.total() != 0 || evidence.fact().Witnesses == nil {
		t.Fatalf("zero evidence = %+v", evidence.fact())
	}
	evidence.record(2, lateWake, 3*time.Nanosecond)
	evidence.record(3, lateFlush, 5*time.Nanosecond)
	evidence.record(4, lateWake, 3*time.Nanosecond)
	if evidence.lateWake.MaximumOverdueOrdinal != 2 {
		t.Fatal("equal overdue duration replaced the earlier deterministic witness")
	}
	for ordinal := 5; ordinal <= 10; ordinal++ {
		evidence.record(ordinal, lateWake, time.Duration(ordinal)*time.Nanosecond)
	}
	fact := evidence.fact()
	if evidence.total() != 9 || evidence.total() != fact.LateWake.Count+fact.LateFlush.Count || fact.LateWake.Count != 8 || fact.LateFlush.Count != 1 {
		t.Fatalf("counts = total %d fact %+v", evidence.total(), fact)
	}
	if fact.LateWake.FirstOrdinal != 2 || fact.LateWake.LastOrdinal != 10 || fact.LateWake.MaximumOverdueOrdinal != 10 || fact.LateWake.MaximumOverdueNS != 10 || fact.LateFlush.FirstOrdinal != 3 || fact.LateFlush.LastOrdinal != 3 || fact.LateFlush.MaximumOverdueOrdinal != 3 || fact.LateFlush.MaximumOverdueNS != 5 {
		t.Fatalf("stage evidence = %+v", fact)
	}
	if len(fact.Witnesses) != missWitnessLimit || fact.WitnessesOmitted != 1 || fact.Witnesses[0].Ordinal != 2 || fact.Witnesses[7].Ordinal != 9 {
		t.Fatalf("bounded witnesses = %+v", fact)
	}
}

func TestWaitOfferPersistsMissEvidenceAndResetClearsIt(t *testing.T) {
	root := t.TempDir()
	roundOne := filepath.Join(root, "round-1")
	if err := os.Mkdir(roundOne, 0o700); err != nil {
		t.Fatal(err)
	}
	facts, err := os.OpenFile(filepath.Join(roundOne, "provider-facts.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	fixture := newFixture(1, 40*time.Millisecond, roundOne, facts)
	var misses missEvidence
	misses.record(7, lateWake, 11*time.Nanosecond)
	misses.record(8, lateFlush, 13*time.Nanosecond)
	fixture.streams["stream-a"] = &stream{id: "stream-a", completed: 0, misses: misses, offerBytes: len(event) * 2}
	fixture.ready = 1
	fixture.offerFinished = 1
	fixture.terminalFinished = 1
	fixture.started = true
	fixture.startAt = time.Unix(100, 0)
	close(fixture.offerCh)
	server := &Server{
		fixture: fixture,
		facts:   facts,
		config:  Config{Streams: 1, Duration: 40 * time.Millisecond, ArtifactDir: root, Rounds: 2},
		round:   1,
	}
	summary, err := server.WaitOffer(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if summary.MissedBatches != 2 || summary.LateWakeMissedBatches != 1 || summary.LateFlushMissedBatches != 1 || summary.MaximumLateWake == nil || summary.MaximumLateWake.ID != "stream-a" || summary.MaximumLateWake.Ordinal != 7 || summary.MaximumLateWake.OverdueNS != 11 || summary.MaximumLateFlush == nil || summary.MaximumLateFlush.Ordinal != 8 || summary.MaximumLateFlush.OverdueNS != 13 {
		t.Fatalf("summary = %+v", summary)
	}
	encodedSummary, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encodedSummary, []byte("maximum_lateness_ms")) || !bytes.Contains(encodedSummary, []byte("late_wake_missed_batches")) {
		t.Fatalf("summary JSON = %s", encodedSummary)
	}
	encodedRows, err := os.ReadFile(filepath.Join(roundOne, "offer-streams.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rows []streamFact
	if err := json.Unmarshal(encodedRows, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Missed != 2 || len(rows[0].MissEvidence.Witnesses) != 2 || rows[0].MissEvidence.Witnesses[0].Ordinal != 7 || rows[0].MissEvidence.Witnesses[1].Stage != lateFlush {
		t.Fatalf("offer-streams.json = %+v", rows)
	}
	if err := server.Reset(); err != nil {
		t.Fatal(err)
	}
	defer server.facts.Close()
	reset := server.Snapshot()
	if reset.MissedBatches != 0 || reset.LateWakeMissedBatches != 0 || reset.LateFlushMissedBatches != 0 || reset.MaximumLateWake != nil || reset.MaximumLateFlush != nil {
		t.Fatalf("reset summary retained miss evidence: %+v", reset)
	}
}

func TestAbsoluteSlotsDoNotReplayExpiredWork(t *testing.T) {
	origin := time.Unix(100, 0)
	interval := 20 * time.Millisecond
	before := absoluteSlot(origin, interval, 0, origin.Add(-5*time.Millisecond))
	if before.start != origin || before.end != origin.Add(interval) || before.wait != 5*time.Millisecond || slotExpired(origin.Add(-5*time.Millisecond), before.end) {
		t.Fatalf("before slot = %+v", before)
	}
	within := absoluteSlot(origin, interval, 0, origin.Add(5*time.Millisecond))
	if within.wait != 0 || slotExpired(origin.Add(5*time.Millisecond), within.end) {
		t.Fatalf("within slot = %+v", within)
	}
	atEnd := absoluteSlot(origin, interval, 0, origin.Add(interval))
	if !slotExpired(origin.Add(interval), atEnd.end) {
		t.Fatalf("slot-end equality was not expired: %+v", atEnd)
	}
	jumpedAt := origin.Add(65 * time.Millisecond)
	for ordinal := 1; ordinal <= 2; ordinal++ {
		if slot := absoluteSlot(origin, interval, ordinal, jumpedAt); !slotExpired(jumpedAt, slot.end) {
			t.Fatalf("expired slot %d would be replayed: %+v", ordinal, slot)
		}
	}
	later := absoluteSlot(origin, interval, 3, jumpedAt)
	if later.start != origin.Add(60*time.Millisecond) || later.end != origin.Add(80*time.Millisecond) || later.wait != 0 || slotExpired(jumpedAt, later.end) {
		t.Fatalf("later absolute slot moved after jump: %+v", later)
	}
}

func TestReusableTimerCancelsAndRunsAgainWithoutStaleTick(t *testing.T) {
	timer := time.NewTimer(time.Hour)
	if !timer.Stop() {
		<-timer.C
	}
	defer timer.Stop()
	cancelled := make(chan struct{})
	close(cancelled)
	if waitForSlot(timer, time.Hour, cancelled) {
		t.Fatal("cancelled long timer reported completion")
	}
	if !waitForSlot(timer, time.Millisecond, make(chan struct{})) {
		t.Fatal("reused timer did not complete")
	}
	select {
	case <-timer.C:
		t.Fatal("reused timer retained a stale tick")
	default:
	}
}

func TestExactPacedOfferAndTerminal(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	requestBody := []byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"test-stream"}]}]}`)
	response := make(chan struct {
		body []byte
		err  error
	}, 1)
	go func() {
		reply, err := http.Post(server.ProviderURL(), "application/json", bytes.NewReader(requestBody))
		if err != nil {
			response <- struct {
				body []byte
				err  error
			}{nil, err}
			return
		}
		defer reply.Body.Close()
		body, err := io.ReadAll(reply.Body)
		response <- struct {
			body []byte
			err  error
		}{body, err}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := server.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := server.StartOffer(); err != nil {
		t.Fatal(err)
	}
	offer, err := server.WaitOffer(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if offer.ExactStreams != 1 || offer.MissedBatches != 0 {
		t.Fatalf("offer = %+v", offer)
	}
	if err := server.ReleaseTerminal(); err != nil {
		t.Fatal(err)
	}
	complete, err := server.WaitCompletion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if complete.TerminalFinished != 1 || complete.FailedStreams != 0 {
		t.Fatalf("completion = %+v", complete)
	}
	result := <-response
	if result.err != nil {
		t.Fatal(result.err)
	}
	if !bytes.Contains(result.body, []byte("capacity answer test-stream")) {
		t.Fatalf("body omitted terminal answer: %q", result.body)
	}
}

func TestDisconnectedStreamCompletesFixtureAccounting(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ctxRequest, cancelRequest := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctxRequest, http.MethodPost, server.ProviderURL(), bytes.NewReader([]byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"cancelled"}]}]}`)))
	if err != nil {
		t.Fatal(err)
	}
	go http.DefaultClient.Do(request)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := server.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := server.StartOffer(); err != nil {
		t.Fatal(err)
	}
	// StartOffer arms the reusable timer for the first absolute slot 500 ms later.
	time.Sleep(50 * time.Millisecond)
	cancelRequest()
	if _, err := server.WaitOffer(ctx); err != nil {
		t.Fatal(err)
	}
	completion, err := server.WaitCompletion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if completion.TerminalFinished != 1 || completion.FailedStreams != 1 || completion.OfferBytes != 0 || completion.CompletedBatches != 0 {
		t.Fatalf("completion = %+v", completion)
	}
}

func TestCloseCancelsHandlerBeforeOffer(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
	if err != nil {
		t.Fatal(err)
	}
	go http.Post(server.ProviderURL(), "application/json", bytes.NewReader([]byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"before-offer"}]}]}`)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := server.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > time.Second {
		t.Fatalf("close before offer took %s", time.Since(started))
	}
}

func TestCloseCancelsHandlerBeforeTerminal(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
	if err != nil {
		t.Fatal(err)
	}
	go http.Post(server.ProviderURL(), "application/json", bytes.NewReader([]byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"before-terminal"}]}]}`)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := server.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := server.StartOffer(); err != nil {
		t.Fatal(err)
	}
	if _, err := server.WaitOffer(ctx); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > time.Second {
		t.Fatalf("close before terminal took %s", time.Since(started))
	}
}

func TestResetRunsSecondRoundOnSameListener(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, Rounds: 2, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	providerURL := server.ProviderURL()
	runRound := func(id string) {
		finished := make(chan error, 1)
		go func() {
			response, err := http.Post(providerURL, "application/json", bytes.NewReader([]byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"`+id+`"}]}]}`)))
			if err == nil {
				_, err = io.Copy(io.Discard, response.Body)
				response.Body.Close()
			}
			finished <- err
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := server.WaitReady(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := server.StartOffer(); err != nil {
			t.Fatal(err)
		}
		if _, err := server.WaitOffer(ctx); err != nil {
			t.Fatal(err)
		}
		if err := server.ReleaseTerminal(); err != nil {
			t.Fatal(err)
		}
		if _, err := server.WaitCompletion(ctx); err != nil {
			t.Fatal(err)
		}
		if err := <-finished; err != nil {
			t.Fatal(err)
		}
	}
	runRound("round-one")
	if err := server.Reset(); err != nil {
		t.Fatal(err)
	}
	if server.ProviderURL() != providerURL {
		t.Fatal("reset changed provider listener")
	}
	runRound("round-two")
	if err := server.Reset(); err == nil {
		t.Fatal("exhausted reset unexpectedly succeeded")
	}
	if server.Snapshot().TerminalFinished != 1 {
		t.Fatal("exhausted reset damaged the completed round")
	}
}

func TestFailedResetLeavesCurrentFixtureOwnedAndClosable(t *testing.T) {
	root := filepath.Join(t.TempDir(), "provider")
	server, err := Start(Config{Streams: 1, Duration: 40 * time.Millisecond, Rounds: 2, ArtifactDir: root})
	if err != nil {
		t.Fatal(err)
	}
	requestDone := make(chan struct{})
	go func() {
		response, _ := http.Post(server.ProviderURL(), "application/json", bytes.NewReader([]byte(`{"input":[{"role":"user","content":[{"type":"input_text","text":"failed-reset"}]}]}`)))
		if response != nil {
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
		}
		close(requestDone)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := server.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := server.StartOffer(); err != nil {
		t.Fatal(err)
	}
	if _, err := server.WaitOffer(ctx); err != nil {
		t.Fatal(err)
	}
	if err := server.ReleaseTerminal(); err != nil {
		t.Fatal(err)
	}
	if _, err := server.WaitCompletion(ctx); err != nil {
		t.Fatal(err)
	}
	<-requestDone
	blockedPath := filepath.Join(root, "round-2", "provider-facts.jsonl")
	if err := os.MkdirAll(blockedPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := server.Reset(); err == nil {
		t.Fatal("artifact-open failure reset unexpectedly succeeded")
	}
	server.currentFixture().record("after_failed_reset", map[string]any{})
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
}
