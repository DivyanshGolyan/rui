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

const (
	event                        = "data: {\"type\":\"response.in_progress\"}\n\n"
	deliveryMethod               = "bounded_delivery_v1"
	eventsPerBatch               = 2
	batchInterval                = 20 * time.Millisecond
	allowedDeliveryVariation     = batchInterval
	maximumCompletionGap         = 2 * batchInterval
	maximumBatchesPerBurstWindow = 2
)

type stream struct {
	id            string
	requestBytes  int
	requestSHA256 string
	delivery      deliveryEvidence
	terminalBytes int
	offerError    string
	terminalError string
}

type fixture struct {
	mu               sync.Mutex
	expected         int
	duration         time.Duration
	batches          int
	batch            string
	perStreamWork    workExpectation
	totalWork        workExpectation
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
	ID            string               `json:"id"`
	RequestBytes  int                  `json:"request_bytes"`
	RequestSHA256 string               `json:"request_sha256"`
	Delivery      deliveryEvidenceFact `json:"delivery"`
	TerminalBytes int                  `json:"terminal_bytes"`
	OfferError    string               `json:"offer_error,omitempty"`
	TerminalError string               `json:"terminal_error,omitempty"`
}

type Summary struct {
	DeliveryMethod                string                   `json:"delivery_method"`
	DeliveryRule                  deliveryRule             `json:"delivery_rule"`
	ExpectedStreams               int                      `json:"expected_streams"`
	ReadyStreams                  int                      `json:"ready_streams"`
	OfferFinished                 int                      `json:"offer_finished_streams"`
	TerminalFinished              int                      `json:"terminal_finished_streams"`
	ValidOfferStreams             int                      `json:"valid_offer_streams"`
	TimingInvalidStreams          int                      `json:"timing_invalid_streams"`
	OfferFailedStreams            int                      `json:"offer_failed_streams"`
	TerminalFailedStreams         int                      `json:"terminal_failed_streams"`
	MinimumBatches                uint64                   `json:"minimum_completed_batches"`
	MaximumBatches                uint64                   `json:"maximum_completed_batches"`
	CompletedBatches              uint64                   `json:"completed_batches"`
	CompletedEvents               uint64                   `json:"completed_events"`
	OfferBytes                    uint64                   `json:"offer_bytes"`
	ExpectedBatches               uint64                   `json:"expected_batches"`
	ExpectedEvents                uint64                   `json:"expected_events"`
	ExpectedOfferBytes            uint64                   `json:"expected_offer_bytes"`
	EarlyCompletionViolations     uint64                   `json:"early_completion_violations"`
	LateCompletionViolations      uint64                   `json:"late_completion_violations"`
	CompletionGapViolations       uint64                   `json:"completion_gap_violations"`
	BurstWindowViolations         uint64                   `json:"burst_window_violations"`
	WorstEarlyCompletion          *summaryViolationWitness `json:"worst_early_completion,omitempty"`
	WorstLateCompletion           *summaryViolationWitness `json:"worst_late_completion,omitempty"`
	WorstCompletionGap            *summaryViolationWitness `json:"worst_completion_gap,omitempty"`
	WorstBurstWindow              *summaryViolationWitness `json:"worst_burst_window,omitempty"`
	MaximumCompletionDelay        *summaryTimingWitness    `json:"maximum_completion_delay,omitempty"`
	MaximumAdjacentGap            *summaryTimingWitness    `json:"maximum_adjacent_gap,omitempty"`
	MinimumTwoBackSpan            *summaryTimingWitness    `json:"minimum_two_back_span,omitempty"`
	EarliestFinalCompletionUnixNS int64                    `json:"earliest_final_completion_unix_ns,omitempty"`
	TerminalBytes                 int                      `json:"terminal_bytes"`
	RequestBytes                  int                      `json:"request_bytes"`
	RequestSetSHA256              string                   `json:"request_set_sha256"`
	StartUnixNS                   int64                    `json:"start_unix_ns,omitempty"`
	OfferHorizonUnixNS            int64                    `json:"offer_horizon_unix_ns,omitempty"`
	HardDeadlineUnixNS            int64                    `json:"hard_deadline_unix_ns,omitempty"`
	EventBytes                    int                      `json:"event_bytes"`
	EventsPerBatch                int                      `json:"events_per_batch"`
	BatchesPerStream              int                      `json:"batches_per_stream"`
	OfferSeconds                  float64                  `json:"offer_seconds"`
}

type deliveryRule struct {
	BatchIntervalNS              int64 `json:"batch_interval_ns"`
	AllowedDeliveryVariationNS   int64 `json:"allowed_delivery_variation_ns"`
	MaximumCompletionGapNS       int64 `json:"maximum_completion_gap_ns"`
	BurstWindowNS                int64 `json:"burst_window_ns"`
	MaximumBatchesPerBurstWindow int   `json:"maximum_batches_per_burst_window"`
}

type workExpectation struct {
	Batches uint64 `json:"batches"`
	Events  uint64 `json:"events"`
	Bytes   uint64 `json:"bytes"`
}

type violationWitness struct {
	Ordinal     int   `json:"ordinal"`
	ViolationNS int64 `json:"violation_ns"`
}

type violationEvidence struct {
	Count uint64           `json:"count"`
	Worst violationWitness `json:"worst"`
}

type timingWitness struct {
	Ordinal    int   `json:"ordinal"`
	ObservedNS int64 `json:"observed_ns"`
}

type timingMaximum struct {
	set     bool
	witness timingWitness
}

func (m *timingMaximum) record(ordinal int, observed time.Duration) {
	if !m.set || observed.Nanoseconds() > m.witness.ObservedNS {
		m.set = true
		m.witness = timingWitness{Ordinal: ordinal, ObservedNS: observed.Nanoseconds()}
	}
}

type timingMinimum struct {
	set     bool
	witness timingWitness
}

func (m *timingMinimum) record(ordinal int, observed time.Duration) {
	if !m.set || observed.Nanoseconds() < m.witness.ObservedNS {
		m.set = true
		m.witness = timingWitness{Ordinal: ordinal, ObservedNS: observed.Nanoseconds()}
	}
}

type deliveryEvidence struct {
	completed       uint64
	offerBytes      uint64
	firstCompletion time.Time
	lastCompletion  time.Time
	completions     [2]time.Time
	early           violationEvidence
	late            violationEvidence
	gap             violationEvidence
	burst           violationEvidence
	maximumDelay    timingMaximum
	maximumGap      timingMaximum
	minimumTwoBack  timingMinimum
}

type deliveryEvidenceFact struct {
	CompletedBatches          uint64            `json:"completed_batches"`
	CompletedEvents           uint64            `json:"completed_events"`
	OfferBytes                uint64            `json:"offer_bytes"`
	FirstCompletionOffsetNS   int64             `json:"first_completion_offset_ns,omitempty"`
	LastCompletionOffsetNS    int64             `json:"last_completion_offset_ns,omitempty"`
	EarlyCompletionViolations violationEvidence `json:"early_completion_violations"`
	LateCompletionViolations  violationEvidence `json:"late_completion_violations"`
	CompletionGapViolations   violationEvidence `json:"completion_gap_violations"`
	BurstWindowViolations     violationEvidence `json:"burst_window_violations"`
	MaximumCompletionDelay    *timingWitness    `json:"maximum_completion_delay,omitempty"`
	MaximumAdjacentGap        *timingWitness    `json:"maximum_adjacent_gap,omitempty"`
	MinimumTwoBackSpan        *timingWitness    `json:"minimum_two_back_span,omitempty"`
	TimingValid               bool              `json:"timing_valid"`
}

type summaryViolationWitness struct {
	ID          string `json:"id"`
	Ordinal     int    `json:"ordinal"`
	ViolationNS int64  `json:"violation_ns"`
}

type summaryTimingWitness struct {
	ID         string `json:"id"`
	Ordinal    int    `json:"ordinal"`
	ObservedNS int64  `json:"observed_ns"`
}

func selectedDeliveryRule() deliveryRule {
	return deliveryRule{
		BatchIntervalNS:              batchInterval.Nanoseconds(),
		AllowedDeliveryVariationNS:   allowedDeliveryVariation.Nanoseconds(),
		MaximumCompletionGapNS:       maximumCompletionGap.Nanoseconds(),
		BurstWindowNS:                batchInterval.Nanoseconds(),
		MaximumBatchesPerBurstWindow: maximumBatchesPerBurstWindow,
	}
}

func checkedMultiply(values ...uint64) (uint64, error) {
	result := uint64(1)
	for _, value := range values {
		if value != 0 && result > ^uint64(0)/value {
			return 0, errors.New("work expectation overflows uint64")
		}
		result *= value
	}
	return result, nil
}

func expectedWork(streams, batches, eventBytes, batchEvents uint64) (workExpectation, error) {
	totalBatches, err := checkedMultiply(streams, batches)
	if err != nil {
		return workExpectation{}, err
	}
	totalEvents, err := checkedMultiply(totalBatches, batchEvents)
	if err != nil {
		return workExpectation{}, err
	}
	totalBytes, err := checkedMultiply(totalBatches, eventBytes, batchEvents)
	if err != nil {
		return workExpectation{}, err
	}
	return workExpectation{Batches: totalBatches, Events: totalEvents, Bytes: totalBytes}, nil
}

func (e *violationEvidence) record(ordinal int, violation time.Duration) {
	e.Count++
	if e.Count == 1 || violation.Nanoseconds() > e.Worst.ViolationNS {
		e.Worst = violationWitness{Ordinal: ordinal, ViolationNS: violation.Nanoseconds()}
	}
}

func (e *deliveryEvidence) waitTarget(start time.Time, ordinal int) time.Time {
	target := start.Add(time.Duration(ordinal) * batchInterval)
	if ordinal >= 2 {
		burstTarget := e.completions[ordinal%2].Add(batchInterval)
		if burstTarget.After(target) {
			target = burstTarget
		}
	}
	return target
}

func (e *deliveryEvidence) addWritten(written int) {
	e.offerBytes += uint64(written)
}

func (e *deliveryEvidence) recordCompletion(start time.Time, ordinal int, completedAt time.Time) {
	release := start.Add(time.Duration(ordinal) * batchInterval)
	e.maximumDelay.record(ordinal, completedAt.Sub(release))
	if completedAt.Before(release) {
		e.early.record(ordinal, release.Sub(completedAt))
	}
	latest := release.Add(batchInterval + allowedDeliveryVariation)
	if completedAt.After(latest) {
		e.late.record(ordinal, completedAt.Sub(latest))
	}
	if ordinal > 0 {
		gap := completedAt.Sub(e.lastCompletion)
		e.maximumGap.record(ordinal, gap)
		if gap > maximumCompletionGap {
			e.gap.record(ordinal, gap-maximumCompletionGap)
		}
	}
	if ordinal >= 2 {
		span := completedAt.Sub(e.completions[ordinal%2])
		e.minimumTwoBack.record(ordinal, span)
		if span < batchInterval {
			e.burst.record(ordinal, batchInterval-span)
		}
	}
	if ordinal == 0 {
		e.firstCompletion = completedAt
	}
	e.lastCompletion = completedAt
	e.completions[ordinal%2] = completedAt
	e.completed++
}

func (e *deliveryEvidence) timingValid() bool {
	return e.early.Count == 0 && e.late.Count == 0 && e.gap.Count == 0 && e.burst.Count == 0
}

func (e *deliveryEvidence) fact(start time.Time) deliveryEvidenceFact {
	result := deliveryEvidenceFact{
		CompletedBatches:          e.completed,
		CompletedEvents:           e.completed * eventsPerBatch,
		OfferBytes:                e.offerBytes,
		EarlyCompletionViolations: e.early,
		LateCompletionViolations:  e.late,
		CompletionGapViolations:   e.gap,
		BurstWindowViolations:     e.burst,
		TimingValid:               e.timingValid(),
	}
	if e.completed != 0 {
		result.FirstCompletionOffsetNS = e.firstCompletion.Sub(start).Nanoseconds()
		result.LastCompletionOffsetNS = e.lastCompletion.Sub(start).Nanoseconds()
	}
	if e.maximumDelay.set {
		witness := e.maximumDelay.witness
		result.MaximumCompletionDelay = &witness
	}
	if e.maximumGap.set {
		witness := e.maximumGap.witness
		result.MaximumAdjacentGap = &witness
	}
	if e.minimumTwoBack.set {
		witness := e.minimumTwoBack.witness
		result.MinimumTwoBackSpan = &witness
	}
	return result
}

func newFixture(expected int, duration time.Duration, artifactDir string, facts *os.File) (*fixture, error) {
	batches := uint64(duration / batchInterval)
	perStreamWork, err := expectedWork(1, batches, uint64(len(event)), eventsPerBatch)
	if err != nil {
		return nil, err
	}
	totalWork, err := expectedWork(uint64(expected), batches, uint64(len(event)), eventsPerBatch)
	if err != nil {
		return nil, err
	}
	return &fixture{
		expected:      expected,
		duration:      duration,
		batches:       int(batches),
		batch:         event + event,
		perStreamWork: perStreamWork,
		totalWork:     totalWork,
		artifactDir:   artifactDir,
		facts:         facts,
		streams:       make(map[string]*stream, expected),
		readyCh:       make(chan struct{}),
		startCh:       make(chan struct{}),
		offerCh:       make(chan struct{}),
		terminalCh:    make(chan struct{}),
		doneCh:        make(chan struct{}),
		cancelCh:      make(chan struct{}),
	}, nil
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

func writePacedBody(writer io.Writer, flush func() error, body string, now func() time.Time) (int, time.Time, error) {
	written, err := writeBody(writer, body)
	if err != nil {
		return written, time.Time{}, err
	}
	if err := flush(); err != nil {
		return written, time.Time{}, err
	}
	return written, now(), nil
}

func waitForSlot(timer *time.Timer, delay time.Duration, done <-chan struct{}) bool {
	if delay <= 0 {
		return true
	}
	timer.Reset(delay)
	select {
	case <-timer.C:
		return true
	case <-done:
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		return false
	}
}

var errOfferHardDeadline = errors.New("offer hard deadline expired")

func offerBatches(start time.Time, duration time.Duration, batches int, now func() time.Time, waitUntil func(time.Time) error, write func() (int, time.Time, error)) (deliveryEvidence, error) {
	var delivery deliveryEvidence
	hardDeadline := start.Add(duration + maximumCompletionGap)
	for ordinal := 0; ordinal < batches; ordinal++ {
		if !now().Before(hardDeadline) {
			return delivery, errOfferHardDeadline
		}
		target := delivery.waitTarget(start, ordinal)
		if target.After(hardDeadline) {
			return delivery, errors.New("offer target exceeds hard deadline")
		}
		if err := waitUntil(target); err != nil {
			return delivery, err
		}
		if !now().Before(hardDeadline) {
			return delivery, errOfferHardDeadline
		}
		written, completedAt, err := write()
		delivery.addWritten(written)
		if err != nil {
			return delivery, err
		}
		delivery.recordCompletion(start, ordinal, completedAt)
	}
	return delivery, nil
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

	hardDeadline := f.startAt.Add(f.duration + maximumCompletionGap)
	timer := time.NewTimer(time.Hour)
	if !timer.Stop() {
		<-timer.C
	}
	defer timer.Stop()
	var delivery deliveryEvidence
	var offerErr error
	if err := controller.SetWriteDeadline(hardDeadline); err != nil {
		offerErr = err
	} else {
		delivery, offerErr = offerBatches(f.startAt, f.duration, f.batches, time.Now, func(target time.Time) error {
			if waitForSlot(timer, max(target.Sub(time.Now()), 0), r.Context().Done()) {
				return nil
			}
			if err := r.Context().Err(); err != nil {
				return err
			}
			return errors.New("offer wait canceled")
		}, func() (int, time.Time, error) {
			return writePacedBody(w, controller.Flush, f.batch, time.Now)
		})
	}
	_ = controller.SetWriteDeadline(time.Time{})

	f.mu.Lock()
	current.delivery = delivery
	if offerErr != nil {
		current.offerError = offerErr.Error()
	}
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
			Delivery:      value.delivery.fact(f.startAt),
			TerminalBytes: value.terminalBytes,
			OfferError:    value.offerError,
			TerminalError: value.terminalError,
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
	result := Summary{
		DeliveryMethod:     deliveryMethod,
		DeliveryRule:       selectedDeliveryRule(),
		ExpectedStreams:    f.expected,
		ReadyStreams:       f.ready,
		OfferFinished:      f.offerFinished,
		TerminalFinished:   f.terminalFinished,
		MinimumBatches:     f.perStreamWork.Batches,
		ExpectedBatches:    f.totalWork.Batches,
		ExpectedEvents:     f.totalWork.Events,
		ExpectedOfferBytes: f.totalWork.Bytes,
		EventBytes:         len(event),
		EventsPerBatch:     eventsPerBatch,
		BatchesPerStream:   f.batches,
		OfferSeconds:       f.duration.Seconds(),
	}
	if len(rows) == 0 {
		result.MinimumBatches = 0
	}
	requestSet := sha256.New()
	for _, row := range rows {
		result.RequestBytes += row.RequestBytes
		fmt.Fprintf(requestSet, "%s\n", row.RequestSHA256)
		result.CompletedBatches += row.Delivery.CompletedBatches
		result.CompletedEvents += row.Delivery.CompletedEvents
		result.OfferBytes += row.Delivery.OfferBytes
		result.TerminalBytes += row.TerminalBytes
		result.EarlyCompletionViolations += row.Delivery.EarlyCompletionViolations.Count
		result.LateCompletionViolations += row.Delivery.LateCompletionViolations.Count
		result.CompletionGapViolations += row.Delivery.CompletionGapViolations.Count
		result.BurstWindowViolations += row.Delivery.BurstWindowViolations.Count
		updateMaximumViolation(&result.WorstEarlyCompletion, row.ID, row.Delivery.EarlyCompletionViolations)
		updateMaximumViolation(&result.WorstLateCompletion, row.ID, row.Delivery.LateCompletionViolations)
		updateMaximumViolation(&result.WorstCompletionGap, row.ID, row.Delivery.CompletionGapViolations)
		updateMaximumViolation(&result.WorstBurstWindow, row.ID, row.Delivery.BurstWindowViolations)
		updateMaximumTiming(&result.MaximumCompletionDelay, row.ID, row.Delivery.MaximumCompletionDelay)
		updateMaximumTiming(&result.MaximumAdjacentGap, row.ID, row.Delivery.MaximumAdjacentGap)
		updateMinimumTiming(&result.MinimumTwoBackSpan, row.ID, row.Delivery.MinimumTwoBackSpan)
		if row.Delivery.CompletedBatches < result.MinimumBatches {
			result.MinimumBatches = row.Delivery.CompletedBatches
		}
		if row.Delivery.CompletedBatches > result.MaximumBatches {
			result.MaximumBatches = row.Delivery.CompletedBatches
		}
		if !row.Delivery.TimingValid {
			result.TimingInvalidStreams++
		}
		if row.OfferError != "" {
			result.OfferFailedStreams++
		}
		if row.TerminalError != "" {
			result.TerminalFailedStreams++
		}
		exact := row.Delivery.CompletedBatches == f.perStreamWork.Batches &&
			row.Delivery.CompletedEvents == f.perStreamWork.Events &&
			row.Delivery.OfferBytes == f.perStreamWork.Bytes
		if exact && row.Delivery.TimingValid && row.OfferError == "" {
			result.ValidOfferStreams++
			completion := f.streams[row.ID].delivery.lastCompletion.UnixNano()
			if result.EarliestFinalCompletionUnixNS == 0 || completion < result.EarliestFinalCompletionUnixNS {
				result.EarliestFinalCompletionUnixNS = completion
			}
		}
	}
	result.RequestSetSHA256 = hex.EncodeToString(requestSet.Sum(nil))
	if f.started {
		result.StartUnixNS = f.startAt.UnixNano()
		result.OfferHorizonUnixNS = f.startAt.Add(f.duration + allowedDeliveryVariation).UnixNano()
		result.HardDeadlineUnixNS = f.startAt.Add(f.duration + maximumCompletionGap).UnixNano()
	}
	return rows, result
}

func updateMaximumViolation(current **summaryViolationWitness, id string, evidence violationEvidence) {
	if evidence.Count == 0 || (*current != nil && evidence.Worst.ViolationNS <= (*current).ViolationNS) {
		return
	}
	*current = &summaryViolationWitness{
		ID:          id,
		Ordinal:     evidence.Worst.Ordinal,
		ViolationNS: evidence.Worst.ViolationNS,
	}
}

func updateMaximumTiming(current **summaryTimingWitness, id string, witness *timingWitness) {
	if witness == nil || (*current != nil && witness.ObservedNS <= (*current).ObservedNS) {
		return
	}
	*current = &summaryTimingWitness{ID: id, Ordinal: witness.Ordinal, ObservedNS: witness.ObservedNS}
}

func updateMinimumTiming(current **summaryTimingWitness, id string, witness *timingWitness) {
	if witness == nil || (*current != nil && witness.ObservedNS >= (*current).ObservedNS) {
		return
	}
	*current = &summaryTimingWitness{ID: id, Ordinal: witness.Ordinal, ObservedNS: witness.ObservedNS}
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
	prepared, err := newFixture(s.config.Streams, s.config.Duration, artifactDir, facts)
	if err != nil {
		facts.Close()
		return err
	}
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
	fixture, err := newFixture(config.Streams, config.Duration, fixtureDir, facts)
	if err != nil {
		facts.Close()
		return nil, err
	}
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
