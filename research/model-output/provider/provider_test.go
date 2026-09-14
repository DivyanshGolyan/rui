package provider

import (
	"bytes"
	"context"
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
	written, onTime, err := writePacedBody(shortWriter{limit: 3}, func() error {
		flushed = true
		return nil
	}, "abcdef", time.Now().Add(time.Second), time.Now)
	if written != 3 || onTime || !errors.Is(err, io.ErrShortWrite) || flushed {
		t.Fatalf("partial write = bytes %d on_time %t err %v flushed %t", written, onTime, err, flushed)
	}
}

func TestPacedWriteCountsFullBodyThatFinishesLate(t *testing.T) {
	var destination bytes.Buffer
	slotEnd := time.Now()
	written, onTime, err := writePacedBody(&destination, func() error { return nil }, "abcdef", slotEnd, func() time.Time {
		return slotEnd.Add(time.Nanosecond)
	})
	if err != nil || written != 6 || onTime || destination.String() != "abcdef" {
		t.Fatalf("late write = bytes %d on_time %t err %v body %q", written, onTime, err, destination.String())
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
