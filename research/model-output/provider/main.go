package provider

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const event = "data: {\"type\":\"response.in_progress\"}\n\n"

type stream struct {
	id            string
	requestBytes  int
	requestSHA256 string
	completed     int
	missed        int
	offerBytes    int
	terminalBytes int
	maximumLateNS int64
	offerError    string
	terminalError string
}

type fixture struct {
	mu               sync.Mutex
	expected         int
	duration         time.Duration
	interval         time.Duration
	batches          int
	batch            string
	artifactDir      string
	facts            *os.File
	streams          map[string]*stream
	ready            int
	offerFinished    int
	terminalFinished int
	started          bool
	terminalReleased bool
	startAt          time.Time
	readyCh          chan struct{}
	startCh          chan struct{}
	offerCh          chan struct{}
	terminalCh       chan struct{}
	doneCh           chan struct{}
	cancelCh         chan struct{}
	cancelOnce       sync.Once
	handlers         sync.WaitGroup
}

type Config struct {
	Streams     int
	Duration    time.Duration
	ArtifactDir string
	Rounds      int
}

type Server struct {
	fixtureMu    sync.RWMutex
	resetMu      sync.Mutex
	fixture      *fixture
	config       Config
	round        int
	server       *http.Server
	listener     net.Listener
	facts        *os.File
	shutdown     chan struct{}
	shutdownOnce sync.Once
}

type requestBody struct {
	Input []struct {
		Role    string `json:"role"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"input"`
}

type streamFact struct {
	ID            string  `json:"id"`
	RequestBytes  int     `json:"request_bytes"`
	RequestSHA256 string  `json:"request_sha256"`
	Completed     int     `json:"completed_batches"`
	Missed        int     `json:"missed_batches"`
	OfferBytes    int     `json:"offer_bytes"`
	TerminalBytes int     `json:"terminal_bytes"`
	MaximumLateMS float64 `json:"maximum_lateness_ms"`
	OfferError    string  `json:"offer_error,omitempty"`
	TerminalError string  `json:"terminal_error,omitempty"`
}

type Summary struct {
	ExpectedStreams   int     `json:"expected_streams"`
	ReadyStreams      int     `json:"ready_streams"`
	OfferFinished     int     `json:"offer_finished_streams"`
	TerminalFinished  int     `json:"terminal_finished_streams"`
	ExactStreams      int     `json:"exact_streams"`
	FailedStreams     int     `json:"failed_streams"`
	MinimumBatches    int     `json:"minimum_completed_batches"`
	MaximumBatches    int     `json:"maximum_completed_batches"`
	CompletedBatches  int     `json:"completed_batches"`
	MissedBatches     int     `json:"missed_batches"`
	OfferBytes        int     `json:"offer_bytes"`
	TerminalBytes     int     `json:"terminal_bytes"`
	MaximumLatenessMS float64 `json:"maximum_lateness_ms"`
	RequestBytes      int     `json:"request_bytes"`
	RequestSetSHA256  string  `json:"request_set_sha256"`
	StartUnixNS       int64   `json:"start_unix_ns,omitempty"`
	DeadlineUnixNS    int64   `json:"deadline_unix_ns,omitempty"`
	EventBytes        int     `json:"event_bytes"`
	EventsPerBatch    int     `json:"events_per_batch"`
	BatchesPerStream  int     `json:"batches_per_stream"`
	OfferSeconds      float64 `json:"offer_seconds"`
}

func newFixture(expected int, duration time.Duration, artifactDir string, facts *os.File) *fixture {
	interval := 20 * time.Millisecond
	return &fixture{
		expected:    expected,
		duration:    duration,
		interval:    interval,
		batches:     int(duration / interval),
		batch:       event + event,
		artifactDir: artifactDir,
		facts:       facts,
		streams:     make(map[string]*stream, expected),
		readyCh:     make(chan struct{}),
		startCh:     make(chan struct{}),
		offerCh:     make(chan struct{}),
		terminalCh:  make(chan struct{}),
		doneCh:      make(chan struct{}),
		cancelCh:    make(chan struct{}),
	}
}

func (f *fixture) cancel() {
	f.cancelOnce.Do(func() { close(f.cancelCh) })
}

func (f *fixture) record(kind string, value any) {
	record := map[string]any{
		"at_unix_ns": time.Now().UnixNano(),
		"event":      kind,
		"value":      value,
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		panic(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.facts.Write(append(encoded, '\n')); err != nil {
		panic(err)
	}
	if err := f.facts.Sync(); err != nil {
		panic(err)
	}
}

func requestID(body []byte) (string, error) {
	var value requestBody
	if err := json.Unmarshal(body, &value); err != nil {
		return "", err
	}
	for _, item := range value.Input {
		if item.Role != "user" {
			continue
		}
		for _, content := range item.Content {
			if content.Type == "input_text" && content.Text != "" {
				return content.Text, nil
			}
		}
	}
	return "", errors.New("request has no nonempty user input_text")
}

func terminal(id string) string {
	answer := "capacity answer " + id
	responseID := "capacity-response-" + id
	events := []any{
		map[string]any{
			"type":         "response.output_item.added",
			"output_index": 0,
			"item":         map[string]any{"type": "message", "id": responseID + "-message"},
		},
		map[string]any{
			"type":         "response.output_item.done",
			"output_index": 0,
			"item": map[string]any{
				"type": "message", "id": responseID + "-message", "role": "assistant",
				"content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}},
			},
		},
		map[string]any{
			"type": "response.completed",
			"response": map[string]any{
				"id": responseID, "status": "completed", "model": "model-a-served",
				"output": []any{map[string]any{
					"type": "message", "id": responseID + "-message", "role": "assistant",
					"content": []any{map[string]any{"type": "output_text", "text": answer, "annotations": []any{}}},
				}},
				"usage": map[string]any{"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
			},
		},
	}
	var result strings.Builder
	for _, value := range events {
		encoded, err := json.Marshal(value)
		if err != nil {
			panic(err)
		}
		result.WriteString("data: ")
		result.Write(encoded)
		result.WriteString("\n\n")
	}
	result.WriteString("data: [DONE]\n\n")
	return result.String()
}

func writeBody(writer io.Writer, body string) (int, error) {
	written, err := io.WriteString(writer, body)
	if err == nil && written != len(body) {
		err = io.ErrShortWrite
	}
	return written, err
}

func writePacedBody(writer io.Writer, flush func() error, body string, slotEnd time.Time, now func() time.Time) (int, bool, error) {
	written, err := writeBody(writer, body)
	if err != nil {
		return written, false, err
	}
	if err := flush(); err != nil {
		return written, false, err
	}
	return written, !now().After(slotEnd), nil
}

func (f *fixture) serveResponse(w http.ResponseWriter, r *http.Request) {
	f.handlers.Add(1)
	defer f.handlers.Done()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024+1))
	if err != nil || len(body) > 1024*1024 {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	id, err := requestID(body)
	if err != nil {
		http.Error(w, "invalid request identity", http.StatusBadRequest)
		return
	}
	digest := sha256.Sum256(body)
	current := &stream{id: id, requestBytes: len(body), requestSHA256: hex.EncodeToString(digest[:])}
	f.mu.Lock()
	if f.started || len(f.streams) >= f.expected || f.streams[id] != nil {
		f.mu.Unlock()
		http.Error(w, "unexpected request", http.StatusConflict)
		return
	}
	f.streams[id] = current
	f.mu.Unlock()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("OpenAI-Model", "model-a-served")
	w.Header().Set("X-Request-Id", "capacity-"+id)
	w.Header().Set("Connection", "close")
	w.WriteHeader(http.StatusOK)
	controller := http.NewResponseController(w)
	if err := controller.Flush(); err != nil {
		current.offerError = err.Error()
		return
	}

	f.mu.Lock()
	f.ready++
	if f.ready == f.expected {
		close(f.readyCh)
	}
	f.mu.Unlock()

	select {
	case <-f.startCh:
	case <-f.cancelCh:
		return
	case <-r.Context().Done():
		f.mu.Lock()
		current.offerError = r.Context().Err().Error()
		f.offerFinished++
		if f.offerFinished == f.expected {
			close(f.offerCh)
		}
		f.terminalFinished++
		if f.terminalFinished == f.expected {
			close(f.doneCh)
		}
		f.mu.Unlock()
		return
	}

	completed := 0
	missed := 0
	offerBytes := 0
	maximumLateNS := int64(0)
	offerError := ""
	for ordinal := 0; ordinal < f.batches; ordinal++ {
		slotStart := f.startAt.Add(time.Duration(ordinal) * f.interval)
		slotEnd := slotStart.Add(f.interval)
		if delay := time.Until(slotStart); delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-timer.C:
			case <-r.Context().Done():
				timer.Stop()
				offerError = r.Context().Err().Error()
				ordinal = f.batches
				continue
			}
		}
		if !time.Now().Before(slotEnd) {
			missed++
			continue
		}
		if err := controller.SetWriteDeadline(slotEnd); err != nil {
			offerError = err.Error()
			break
		}
		written, onTime, err := writePacedBody(w, controller.Flush, f.batch, slotEnd, time.Now)
		offerBytes += written
		if err != nil {
			offerError = err.Error()
			break
		}
		finished := time.Now()
		if !onTime {
			missed++
			continue
		}
		completed++
		lateness := finished.Sub(slotStart).Nanoseconds()
		if lateness > maximumLateNS {
			maximumLateNS = lateness
		}
	}
	_ = controller.SetWriteDeadline(time.Time{})

	f.mu.Lock()
	current.completed = completed
	current.missed = missed
	current.offerBytes = offerBytes
	current.maximumLateNS = maximumLateNS
	current.offerError = offerError
	f.offerFinished++
	if f.offerFinished == f.expected {
		close(f.offerCh)
	}
	f.mu.Unlock()

	select {
	case <-f.terminalCh:
	case <-f.cancelCh:
		return
	case <-r.Context().Done():
		f.mu.Lock()
		current.terminalError = r.Context().Err().Error()
		f.terminalFinished++
		if f.terminalFinished == f.expected {
			close(f.doneCh)
		}
		f.mu.Unlock()
		return
	}
	_ = controller.SetWriteDeadline(time.Now().Add(30 * time.Second))
	terminalBytes, terminalWriteError := writeBody(w, terminal(id))
	if terminalWriteError != nil {
		f.mu.Lock()
		current.terminalBytes = terminalBytes
		current.terminalError = terminalWriteError.Error()
		f.mu.Unlock()
	} else if err := controller.Flush(); err != nil {
		f.mu.Lock()
		current.terminalBytes = terminalBytes
		current.terminalError = err.Error()
		f.mu.Unlock()
	} else {
		f.mu.Lock()
		current.terminalBytes = terminalBytes
		f.mu.Unlock()
	}

	f.mu.Lock()
	f.terminalFinished++
	if f.terminalFinished == f.expected {
		close(f.doneCh)
	}
	f.mu.Unlock()
}

func (f *fixture) factsSnapshot() ([]streamFact, Summary) {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := make([]streamFact, 0, len(f.streams))
	for _, value := range f.streams {
		rows = append(rows, streamFact{
			ID:            value.id,
			RequestBytes:  value.requestBytes,
			RequestSHA256: value.requestSHA256,
			Completed:     value.completed,
			Missed:        value.missed,
			OfferBytes:    value.offerBytes,
			TerminalBytes: value.terminalBytes,
			MaximumLateMS: float64(value.maximumLateNS) / float64(time.Millisecond),
			OfferError:    value.offerError,
			TerminalError: value.terminalError,
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
	result := Summary{
		ExpectedStreams:  f.expected,
		ReadyStreams:     f.ready,
		OfferFinished:    f.offerFinished,
		TerminalFinished: f.terminalFinished,
		MinimumBatches:   f.batches,
		EventBytes:       len(event),
		EventsPerBatch:   2,
		BatchesPerStream: f.batches,
		OfferSeconds:     f.duration.Seconds(),
	}
	requestSet := sha256.New()
	for _, row := range rows {
		result.RequestBytes += row.RequestBytes
		fmt.Fprintf(requestSet, "%s\n", row.RequestSHA256)
		result.CompletedBatches += row.Completed
		result.MissedBatches += row.Missed
		result.OfferBytes += row.OfferBytes
		result.TerminalBytes += row.TerminalBytes
		if row.Completed < result.MinimumBatches {
			result.MinimumBatches = row.Completed
		}
		if row.Completed > result.MaximumBatches {
			result.MaximumBatches = row.Completed
		}
		if row.Completed == f.batches && row.Missed == 0 && row.OfferError == "" {
			result.ExactStreams++
		}
		if row.OfferError != "" || row.TerminalError != "" {
			result.FailedStreams++
		}
		if row.MaximumLateMS > result.MaximumLatenessMS {
			result.MaximumLatenessMS = row.MaximumLateMS
		}
	}
	result.RequestSetSHA256 = hex.EncodeToString(requestSet.Sum(nil))
	if f.started {
		result.StartUnixNS = f.startAt.UnixNano()
		result.DeadlineUnixNS = f.startAt.Add(f.duration).UnixNano()
	}
	return rows, result
}

func writeJSON(path string, value any) error {
	temporary := path + ".tmp"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

func waitFor(ctx context.Context, channel <-chan struct{}) error {
	select {
	case <-channel:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Server) ProviderURL() string {
	return "http://" + s.listener.Addr().String() + "/responses"
}

func (s *Server) currentFixture() *fixture {
	s.fixtureMu.RLock()
	defer s.fixtureMu.RUnlock()
	return s.fixture
}

func (s *Server) ControlURL() string {
	return "http://" + s.listener.Addr().String()
}

func (s *Server) ShutdownRequested() <-chan struct{} { return s.shutdown }

func (s *Server) Snapshot() Summary {
	_, result := s.currentFixture().factsSnapshot()
	return result
}

func (s *Server) WaitReady(ctx context.Context) (Summary, error) {
	f := s.currentFixture()
	if err := waitFor(ctx, f.readyCh); err != nil {
		return Summary{}, err
	}
	rows, result := f.factsSnapshot()
	if err := writeJSON(filepath.Join(f.artifactDir, "requests.json"), rows); err != nil {
		return Summary{}, err
	}
	f.record("ready", result)
	return result, nil
}

func (s *Server) StartOffer() (Summary, error) {
	f := s.currentFixture()
	f.mu.Lock()
	if f.started || f.ready != f.expected {
		f.mu.Unlock()
		return Summary{}, errors.New("fixture is not ready for release")
	}
	f.started = true
	f.startAt = time.Now().Add(500 * time.Millisecond)
	close(f.startCh)
	f.mu.Unlock()
	_, result := f.factsSnapshot()
	f.record("offer_started", result)
	return result, nil
}

func (s *Server) WaitOffer(ctx context.Context) (Summary, error) {
	f := s.currentFixture()
	if err := waitFor(ctx, f.offerCh); err != nil {
		return Summary{}, err
	}
	rows, result := f.factsSnapshot()
	if err := writeJSON(filepath.Join(f.artifactDir, "offer-streams.json"), rows); err != nil {
		return Summary{}, err
	}
	f.record("offer_complete", result)
	return result, nil
}

func (s *Server) ReleaseTerminal() error {
	f := s.currentFixture()
	f.mu.Lock()
	if f.terminalReleased || f.offerFinished != f.expected {
		f.mu.Unlock()
		return errors.New("offer is not complete")
	}
	f.terminalReleased = true
	close(f.terminalCh)
	f.mu.Unlock()
	f.record("terminal_released", map[string]any{})
	return nil
}

func (s *Server) WaitCompletion(ctx context.Context) (Summary, error) {
	f := s.currentFixture()
	if err := waitFor(ctx, f.doneCh); err != nil {
		return Summary{}, err
	}
	rows, result := f.factsSnapshot()
	if err := writeJSON(filepath.Join(f.artifactDir, "completion-streams.json"), rows); err != nil {
		return Summary{}, err
	}
	f.record("provider_complete", result)
	return result, nil
}

func (s *Server) Reset() error {
	s.resetMu.Lock()
	defer s.resetMu.Unlock()
	old := s.currentFixture()
	old.mu.Lock()
	complete := old.terminalFinished == old.expected
	old.mu.Unlock()
	if !complete {
		return errors.New("fixture round is not complete")
	}
	if s.round >= s.config.Rounds {
		return errors.New("fixture has no remaining rounds")
	}
	nextRound := s.round + 1
	artifactDir := s.config.ArtifactDir
	if s.config.Rounds > 1 {
		artifactDir = filepath.Join(artifactDir, fmt.Sprintf("round-%d", nextRound))
	}
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		return err
	}
	facts, err := os.OpenFile(filepath.Join(artifactDir, "provider-facts.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	prepared := newFixture(s.config.Streams, s.config.Duration, artifactDir, facts)
	s.fixtureMu.Lock()
	defer s.fixtureMu.Unlock()
	old.handlers.Wait()
	if err := old.facts.Close(); err != nil {
		facts.Close()
		return err
	}
	s.fixture = prepared
	s.facts = facts
	s.round = nextRound
	s.fixture.record("round_ready", map[string]any{"round": nextRound})
	return nil
}

func Start(config Config) (*Server, error) {
	if config.Rounds == 0 {
		config.Rounds = 1
	}
	if config.Streams <= 0 || config.Duration <= 0 || config.Duration%(20*time.Millisecond) != 0 || config.ArtifactDir == "" || config.Rounds <= 0 {
		return nil, errors.New("invalid fixture configuration")
	}
	if err := os.MkdirAll(config.ArtifactDir, 0o700); err != nil {
		return nil, err
	}
	fixtureDir := config.ArtifactDir
	if config.Rounds > 1 {
		fixtureDir = filepath.Join(config.ArtifactDir, "round-1")
		if err := os.MkdirAll(fixtureDir, 0o700); err != nil {
			return nil, err
		}
	}
	facts, err := os.OpenFile(filepath.Join(fixtureDir, "provider-facts.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	fixture := newFixture(config.Streams, config.Duration, fixtureDir, facts)
	mux := http.NewServeMux()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		facts.Close()
		return nil, err
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	result := &Server{fixture: fixture, config: config, round: 1, server: server, listener: listener, facts: facts, shutdown: make(chan struct{})}
	mux.HandleFunc("/responses", func(writer http.ResponseWriter, request *http.Request) {
		result.fixtureMu.RLock()
		defer result.fixtureMu.RUnlock()
		result.fixture.serveResponse(writer, request)
	})
	writeSummary := func(writer http.ResponseWriter, summary Summary, err error) {
		writer.Header().Set("Content-Type", "application/json")
		if err != nil {
			http.Error(writer, err.Error(), http.StatusConflict)
			return
		}
		if encodeError := json.NewEncoder(writer).Encode(summary); encodeError != nil {
			fixture.record("control_encode_error", map[string]any{"error": encodeError.Error()})
		}
	}
	mux.HandleFunc("/control/snapshot", func(writer http.ResponseWriter, _ *http.Request) {
		writeSummary(writer, result.Snapshot(), nil)
	})
	mux.HandleFunc("/control/wait-ready", func(writer http.ResponseWriter, request *http.Request) {
		summary, waitError := result.WaitReady(request.Context())
		writeSummary(writer, summary, waitError)
	})
	mux.HandleFunc("/control/start-offer", func(writer http.ResponseWriter, _ *http.Request) {
		summary, startError := result.StartOffer()
		writeSummary(writer, summary, startError)
	})
	mux.HandleFunc("/control/wait-offer", func(writer http.ResponseWriter, request *http.Request) {
		summary, waitError := result.WaitOffer(request.Context())
		writeSummary(writer, summary, waitError)
	})
	mux.HandleFunc("/control/release-terminal", func(writer http.ResponseWriter, _ *http.Request) {
		writeSummary(writer, result.Snapshot(), result.ReleaseTerminal())
	})
	mux.HandleFunc("/control/reset", func(writer http.ResponseWriter, _ *http.Request) {
		resetError := result.Reset()
		writeSummary(writer, result.Snapshot(), resetError)
	})
	mux.HandleFunc("/control/wait-completion", func(writer http.ResponseWriter, request *http.Request) {
		summary, waitError := result.WaitCompletion(request.Context())
		writeSummary(writer, summary, waitError)
	})
	mux.HandleFunc("/control/shutdown", func(writer http.ResponseWriter, _ *http.Request) {
		result.shutdownOnce.Do(func() { close(result.shutdown) })
		writeSummary(writer, result.Snapshot(), nil)
	})
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fixture.record("server_error", map[string]any{"error": err.Error()})
		}
	}()
	fixture.record("server_ready", map[string]any{"provider_url": result.ProviderURL()})
	return result, nil
}

func (s *Server) Close() error {
	f := s.currentFixture()
	f.cancel()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	shutdownError := s.server.Shutdown(shutdown)
	if shutdownError != nil {
		shutdownError = errors.Join(shutdownError, s.server.Close())
	}
	f.handlers.Wait()
	return errors.Join(shutdownError, s.facts.Close())
}
