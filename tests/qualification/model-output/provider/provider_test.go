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

const (
	testFixtureDuration = time.Second
	testFixtureRate     = 3
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

func TestExpectedWorkUsesCheckedArithmetic(t *testing.T) {
	work, err := expectedWork(100, 6000, uint64(len(event)), eventsPerBatch)
	if err != nil {
		t.Fatal(err)
	}
	if work != (workExpectation{Batches: 600_000, Events: 600_000, Bytes: 156_000_000}) {
		t.Fatalf("work = %+v", work)
	}
	if _, err := expectedWork(^uint64(0), 2, 1, 1); err == nil {
		t.Fatal("overflow unexpectedly accepted")
	}
}

func directBurstWindowValid(completions []time.Time, interval time.Duration) bool {
	for index, start := range completions {
		if index > 0 && start.Equal(completions[index-1]) {
			continue
		}
		count := 0
		end := start.Add(interval)
		for _, completion := range completions {
			if !completion.Before(start) && completion.Before(end) {
				count++
			}
		}
		if count > maximumBatchesPerBurstWindow {
			return false
		}
	}
	return true
}

func productionBurstWindowValid(start time.Time, duration time.Duration, completions []time.Time, interval time.Duration) bool {
	var evidence deliveryEvidence
	for ordinal, completion := range completions {
		evidence.recordCompletion(start, duration, len(completions), interval, ordinal, completion)
	}
	return evidence.burst.Count == 0
}

func TestBurstRuleMatchesIndependentHalfOpenWindowOracle(t *testing.T) {
	origin := time.Unix(100, 0)
	duration := 60 * time.Millisecond
	batches := 3
	interval := ceilingInterval(duration, batches)
	explicit := [][]time.Time{
		{origin, origin, origin.Add(interval), origin.Add(interval)},
		{origin, origin, origin.Add(interval - time.Nanosecond)},
		{origin, origin, origin},
		{origin, origin.Add(interval), origin.Add(2 * interval)},
		{origin, origin.Add(interval + time.Nanosecond), origin.Add(2 * interval)},
	}
	for _, completions := range explicit {
		if got, want := productionBurstWindowValid(origin, duration, completions, interval), directBurstWindowValid(completions, interval); got != want {
			t.Fatalf("explicit completions %v: production %t oracle %t", completions, got, want)
		}
	}
	var generate func([]time.Time, int)
	generate = func(prefix []time.Time, minimumTick int) {
		if len(prefix) >= 3 {
			if got, want := productionBurstWindowValid(origin, duration, prefix, interval), directBurstWindowValid(prefix, interval); got != want {
				t.Fatalf("generated completions %v: production %t oracle %t", prefix, got, want)
			}
		}
		if len(prefix) == 6 {
			return
		}
		for tick := minimumTick; tick <= 8; tick++ {
			next := append(append([]time.Time(nil), prefix...), origin.Add(time.Duration(tick)*5*time.Millisecond))
			generate(next, tick)
		}
	}
	generate(nil, 0)
}

func TestDeliveryTimingBoundaries(t *testing.T) {
	origin := time.Unix(100, 0)
	duration := 60 * time.Millisecond
	batches := 3
	interval := ceilingInterval(duration, batches)
	var boundary deliveryEvidence
	boundary.recordCompletion(origin, duration, batches, interval, 0, origin.Add(2*interval))
	boundary.recordCompletion(origin, duration, batches, interval, 1, origin.Add(3*interval))
	if !boundary.timingValid() {
		t.Fatalf("inclusive late and gap boundaries rejected: %+v", boundary)
	}
	var gapBoundary deliveryEvidence
	gapBoundary.recordCompletion(origin, duration, batches, interval, 0, origin)
	gapBoundary.recordCompletion(origin, duration, batches, interval, 1, origin.Add(2*interval))
	if gapBoundary.gap.Count != 0 || gapBoundary.maximumGap.witness.ObservedNS != (2*interval).Nanoseconds() {
		t.Fatalf("inclusive gap boundary rejected: %+v", gapBoundary)
	}

	var late deliveryEvidence
	late.recordCompletion(origin, duration, batches, interval, 0, origin.Add(2*interval+time.Nanosecond))
	if late.late.Count != 1 || late.late.Worst.ViolationNS != 1 {
		t.Fatalf("late evidence = %+v", late.late)
	}

	var early deliveryEvidence
	early.recordCompletion(origin, duration, batches, interval, 1, origin.Add(interval-time.Nanosecond))
	if early.early.Count != 1 || early.early.Worst.ViolationNS != 1 {
		t.Fatalf("early evidence = %+v", early.early)
	}

	var gap deliveryEvidence
	gap.recordCompletion(origin, duration, batches, interval, 0, origin)
	gap.recordCompletion(origin, duration, batches, interval, 1, origin.Add(2*interval+time.Nanosecond))
	if gap.gap.Count != 1 || gap.gap.Worst.ViolationNS != 1 {
		t.Fatalf("gap evidence = %+v", gap.gap)
	}
}

func TestRationalTargetsDeliverExactWholeMinutePopulation(t *testing.T) {
	for _, scenario := range []struct {
		rate, count int
		interval    time.Duration
	}{
		{rate: 30, count: 1800, interval: 33_333_334 * time.Nanosecond},
		{rate: 100, count: 6000, interval: 10 * time.Millisecond},
	} {
		if got := ceilingInterval(time.Minute, scenario.count); got != scenario.interval {
			t.Fatalf("rate %d interval = %s", scenario.rate, got)
		}
		last := rationalOffset(time.Minute, scenario.count, scenario.count-1)
		if last >= time.Minute || last != time.Minute-scenario.interval {
			t.Fatalf("rate %d last target = %s", scenario.rate, last)
		}
		for ordinal := 1; ordinal < scenario.count; ordinal++ {
			if rationalOffset(time.Minute, scenario.count, ordinal) <= rationalOffset(time.Minute, scenario.count, ordinal-1) {
				t.Fatalf("rate %d target %d was not monotonic", scenario.rate, ordinal)
			}
		}
	}
	if len(event) != eventRecordBytes || eventsPerBatch != 1 {
		t.Fatalf("event shape = %d bytes, %d events/batch", len(event), eventsPerBatch)
	}
}

func runDeterministicOffer(start time.Time, duration time.Duration, completions []time.Time, failureOrdinal int) (deliveryEvidence, error, []time.Time, int) {
	interval := ceilingInterval(duration, len(completions))
	now := start
	targets := make([]time.Time, 0, len(completions))
	writes := 0
	delivery, err := offerBatches(start, duration, len(completions), interval, func() time.Time { return now }, func(target time.Time) error {
		targets = append(targets, target)
		if target.After(now) {
			now = target
		}
		return nil
	}, func() (int, time.Time, error) {
		ordinal := writes
		writes++
		if ordinal == failureOrdinal {
			return 3, time.Time{}, io.ErrUnexpectedEOF
		}
		now = completions[ordinal]
		return 6, now, nil
	})
	return delivery, err, targets, writes
}

func TestOfferLoopUsesRationalTargetsWithoutSkippingLateWork(t *testing.T) {
	start := time.Unix(100, 0)
	completions := []time.Time{start.Add(25 * time.Millisecond), start.Add(40 * time.Millisecond), start.Add(55 * time.Millisecond)}
	delivery, err, targets, writes := runDeterministicOffer(start, 60*time.Millisecond, completions, -1)
	if err != nil || writes != 3 || delivery.completed != 3 || delivery.offerBytes != 18 || !delivery.timingValid() {
		t.Fatalf("allowed late offer = delivery %+v writes %d err %v", delivery, writes, err)
	}
	wantTargets := []time.Time{start, start.Add(20 * time.Millisecond), start.Add(45 * time.Millisecond)}
	for index := range wantTargets {
		if !targets[index].Equal(wantTargets[index]) {
			t.Fatalf("target %d = %s want %s", index, targets[index], wantTargets[index])
		}
	}

	invalidCompletions := []time.Time{start.Add(40*time.Millisecond + time.Nanosecond), start.Add(42 * time.Millisecond), start.Add(61*time.Millisecond + time.Nanosecond)}
	invalid, err, invalidTargets, writes := runDeterministicOffer(start, 60*time.Millisecond, invalidCompletions, -1)
	if err != nil || writes != 3 || invalid.completed != 3 || invalid.late.Count == 0 || !invalidTargets[2].Equal(invalidCompletions[0].Add(20*time.Millisecond)) {
		t.Fatalf("timing-invalid work = delivery %+v targets %v writes %d err %v", invalid, invalidTargets, writes, err)
	}
}

func TestOfferLoopStopsOnTransportFailureAndHardDeadline(t *testing.T) {
	start := time.Unix(100, 0)
	completions := []time.Time{start, start.Add(20 * time.Millisecond), start.Add(40 * time.Millisecond)}
	delivery, err, _, writes := runDeterministicOffer(start, 60*time.Millisecond, completions, 1)
	if !errors.Is(err, io.ErrUnexpectedEOF) || writes != 2 || delivery.completed != 1 || delivery.offerBytes != 9 {
		t.Fatalf("transport failure = delivery %+v writes %d err %v", delivery, writes, err)
	}

	for _, offset := range []time.Duration{40 * time.Millisecond, 40*time.Millisecond + time.Nanosecond} {
		writes := 0
		_, err := offerBatches(start, 20*time.Millisecond, 1, 20*time.Millisecond, func() time.Time { return start.Add(offset) }, func(time.Time) error { return nil }, func() (int, time.Time, error) {
			writes++
			return 6, start.Add(offset), nil
		})
		if !errors.Is(err, errOfferHardDeadline) || writes != 0 {
			t.Fatalf("hard deadline offset %s = writes %d err %v", offset, writes, err)
		}
	}

	now := start
	writes = 0
	_, err = offerBatches(start, 20*time.Millisecond, 1, 20*time.Millisecond, func() time.Time { return now }, func(time.Time) error {
		now = start.Add(40 * time.Millisecond)
		return nil
	}, func() (int, time.Time, error) {
		writes++
		return 6, now, nil
	})
	if !errors.Is(err, errOfferHardDeadline) || writes != 0 {
		t.Fatalf("deadline reached while waiting = writes %d err %v", writes, err)
	}
}

func TestWaitOfferPersistsBoundedDeliveryEvidenceAndResetClearsIt(t *testing.T) {
	root := t.TempDir()
	roundOne := filepath.Join(root, "round-1")
	if err := os.Mkdir(roundOne, 0o700); err != nil {
		t.Fatal(err)
	}
	facts, err := os.OpenFile(filepath.Join(roundOne, "provider-facts.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := newFixture(1, testFixtureDuration, testFixtureRate, roundOne, facts)
	if err != nil {
		t.Fatal(err)
	}
	var delivery deliveryEvidence
	delivery.addWritten(len(event) * eventsPerBatch)
	interval := ceilingInterval(testFixtureDuration, testFixtureRate)
	delivery.recordCompletion(time.Unix(100, 0), testFixtureDuration, testFixtureRate, interval, 0, time.Unix(100, 0).Add(2*interval+11*time.Nanosecond))
	fixture.streams["stream-a"] = &stream{id: "stream-a", delivery: delivery}
	fixture.ready = 1
	fixture.offerFinished = 1
	fixture.terminalFinished = 1
	fixture.started = true
	fixture.startAt = time.Unix(100, 0)
	close(fixture.offerCh)
	server := &Server{
		fixture: fixture,
		facts:   facts,
		config:  Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, ArtifactDir: root, Rounds: 2},
		round:   1,
	}
	summary, err := server.WaitOffer(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if summary.DeliveryMethod != deliveryMethod || summary.LateCompletionViolations != 1 || summary.WorstLateCompletion == nil || summary.WorstLateCompletion.ID != "stream-a" || summary.WorstLateCompletion.Ordinal != 0 || summary.WorstLateCompletion.ViolationNS != 11 {
		t.Fatalf("summary = %+v", summary)
	}
	encodedSummary, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encodedSummary, []byte("missed_batches")) || !bytes.Contains(encodedSummary, []byte(deliveryMethod)) {
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
	if len(rows) != 1 || rows[0].Delivery.CompletedBatches != 1 || rows[0].Delivery.LateCompletionViolations.Count != 1 {
		t.Fatalf("offer-streams.json = %+v", rows)
	}
	if err := server.Reset(); err != nil {
		t.Fatal(err)
	}
	defer server.facts.Close()
	reset := server.Snapshot()
	if reset.LateCompletionViolations != 0 || reset.WorstLateCompletion != nil || reset.CompletedBatches != 0 {
		t.Fatalf("reset summary retained delivery evidence: %+v", reset)
	}
}

func TestFactsSnapshotAggregatesPassingTimingHeadroom(t *testing.T) {
	fixture, err := newFixture(2, testFixtureDuration, testFixtureRate, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	fixture.started = true
	fixture.startAt = time.Unix(100, 0)
	fixture.ready = 2
	fixture.offerFinished = 2
	interval := ceilingInterval(testFixtureDuration, testFixtureRate)
	for id, offsets := range map[string][]time.Duration{
		"stream-a": {interval, rationalOffset(testFixtureDuration, testFixtureRate, 1) + interval, rationalOffset(testFixtureDuration, testFixtureRate, 2) + interval},
		"stream-b": {0, rationalOffset(testFixtureDuration, testFixtureRate, 1), rationalOffset(testFixtureDuration, testFixtureRate, 2)},
	} {
		var delivery deliveryEvidence
		for ordinal, offset := range offsets {
			delivery.addWritten(len(event) * eventsPerBatch)
			delivery.recordCompletion(fixture.startAt, testFixtureDuration, testFixtureRate, interval, ordinal, fixture.startAt.Add(offset))
		}
		fixture.streams[id] = &stream{id: id, delivery: delivery}
	}
	_, summary := fixture.factsSnapshot()
	if summary.ValidOfferStreams != 2 {
		t.Fatalf("passing streams = %d summary %+v", summary.ValidOfferStreams, summary)
	}
	if summary.MaximumCompletionDelay == nil || summary.MaximumCompletionDelay.ID != "stream-a" || summary.MaximumCompletionDelay.Ordinal != 0 || summary.MaximumCompletionDelay.ObservedNS != interval.Nanoseconds() {
		t.Fatalf("maximum completion delay = %+v", summary.MaximumCompletionDelay)
	}
	if summary.MaximumAdjacentGap == nil || summary.MaximumAdjacentGap.ObservedNS != rationalOffset(testFixtureDuration, testFixtureRate, 1).Nanoseconds() {
		t.Fatalf("maximum adjacent gap = %+v", summary.MaximumAdjacentGap)
	}
	if summary.MinimumTwoBackSpan == nil || summary.MinimumTwoBackSpan.Ordinal != 2 || summary.MinimumTwoBackSpan.ObservedNS != rationalOffset(testFixtureDuration, testFixtureRate, 2).Nanoseconds() {
		t.Fatalf("minimum two-back span = %+v", summary.MinimumTwoBackSpan)
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
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
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
	if offer.ValidOfferStreams != 1 || offer.TimingInvalidStreams != 0 || offer.CompletedBatches != testFixtureRate || offer.CompletedEvents != testFixtureRate || offer.OfferBytes != uint64(testFixtureRate*len(event)) {
		t.Fatalf("offer = %+v", offer)
	}
	if err := server.ReleaseTerminal(); err != nil {
		t.Fatal(err)
	}
	complete, err := server.WaitCompletion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if complete.TerminalFinished != 1 || complete.TerminalFailedStreams != 0 {
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
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
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
	time.Sleep(50 * time.Millisecond)
	cancelRequest()
	if _, err := server.WaitOffer(ctx); err != nil {
		t.Fatal(err)
	}
	completion, err := server.WaitCompletion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if completion.TerminalFinished != 1 || completion.OfferFailedStreams != 1 || completion.TerminalFailedStreams != 1 || completion.CompletedBatches >= testFixtureRate {
		t.Fatalf("completion = %+v", completion)
	}
}

func TestCloseCancelsHandlerBeforeOffer(t *testing.T) {
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
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
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
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
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, Rounds: 2, ArtifactDir: filepath.Join(t.TempDir(), "provider")})
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
	server, err := Start(Config{Streams: 1, Duration: testFixtureDuration, EventsPerSecond: testFixtureRate, Rounds: 2, ArtifactDir: root})
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

func TestCompleteOfferMayOutliveNominalCadence(t *testing.T) {
	start := time.Unix(100, 0)
	completions := make([]time.Time, 100)
	for i := range completions {
		completions[i] = start.Add(time.Duration(i)*10*time.Millisecond + 100*time.Millisecond)
	}
	delivery, err, _, writes := runDeterministicOffer(start, time.Second, completions, -1)
	if err != nil || writes != 100 || delivery.completed != 100 || delivery.late.Count == 0 {
		t.Fatalf("late but complete offer: %+v writes=%d err=%v", delivery, writes, err)
	}
	fixture, err := newFixture(1, time.Second, 100, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	fixture.startAt = start
	fixture.started = true
	var streamed deliveryEvidence
	for i, completed := range completions {
		streamed.addWritten(len(event))
		streamed.recordCompletion(start, time.Second, 100, 10*time.Millisecond, i, completed)
	}
	fixture.streams["late"] = &stream{id: "late", delivery: streamed}
	_, summary := fixture.factsSnapshot()
	if summary.ValidOfferStreams != 0 || summary.TimingInvalidStreams != 1 || summary.EarliestFinalCompletionUnixNS != completions[99].UnixNano() || summary.LatestFinalCompletionUnixNS != completions[99].UnixNano() {
		t.Fatalf("jitter discarded actual completion evidence: %+v", summary)
	}
}
