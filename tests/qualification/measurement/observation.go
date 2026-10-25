package measurement

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	observationRecordBytes  = 512
	observationHeaderBytes  = 28
	observationStateBytes   = 40
	observationCountOffset  = 24 // Sequence count above the sticky loss bit.
	observationActiveOffset = 32
	observationSealed       = uint64(1) << 63
)

// The stable field IDs of src/TestObservation.zig.
var observationFields = [...]string{
	"rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation", "attempt", "action",
	"scratch_used_bytes", "command_key", "kind", "control_key", "store_queued_at_ns", "lock_acquired_at_ns",
	"store_complete_at_ns", "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
	"post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
	"new_connections", "replays", "work_bytes", "work_items", "request_bytes",
	"process_memory_current_bytes", "process_memory_highwater_bytes", "cache_used_bytes", "cache_spills",
	"hard_heap_limit_bytes", "page_size_bytes", "cache_size_setting", "cache_spill_threshold", "mmap_size_bytes",
	"synchronous", "temp_store", "busy_timeout_ms", "journal_mode",
}

// Observations is the Host's private test observation channel. Stderr phase
// traces are best effort and drop records when threads contend for stderr;
// this channel instead marks any selected record it cannot deliver as loss.
type Observations struct {
	shared  []byte // The Host's MAP_SHARED state, read and sealed atomically.
	process int
	done    chan struct{}
	mu      sync.Mutex
	records []map[string]any
	pending map[uint64]map[string]any
	err     error
}

// Launch adjusts how StartHostWith starts a Host process.
type Launch struct {
	// DescriptorLimit, when positive, is the Host's soft and hard
	// RLIMIT_NOFILE, so the Host cannot raise it and fits intake to it.
	DescriptorLimit int
	// ObservationPlan, when set, selects a src/TestObservation.zig plan and
	// returns its records through Observations.
	ObservationPlan string
}

func StartHostWith(
	launch Launch,
	binary string,
	store string,
	endpoint string,
	capacity int,
	stderrPath string,
	deadline Deadline,
	extra ...string,
) (*Host, *Observations, error) {
	arguments := hostArguments(store, endpoint, capacity, extra)
	var reader, writer, state *os.File
	if launch.ObservationPlan != "" {
		var err error
		if reader, writer, state, err = observationFiles(); err != nil {
			return nil, nil, err
		}
		defer writer.Close()
		// ExtraFiles become descriptors 3 and 4 in the Host.
		arguments = append(arguments, "--test-observation-fd", "3", "--test-observation-state-fd", "4",
			"--test-observation-plan", launch.ObservationPlan)
	}
	cmd := exec.Command(binary, arguments...)
	if launch.DescriptorLimit > 0 {
		cmd = exec.Command("/bin/sh", append([]string{"-c", `ulimit -n "$0" && exec "$@"`, strconv.Itoa(launch.DescriptorLimit), binary}, arguments...)...)
	}
	if state != nil {
		cmd.ExtraFiles = []*os.File{writer, state}
	}
	host, err := startHost(cmd, stderrPath, deadline)
	if err != nil {
		if state != nil {
			reader.Close()
			state.Close()
		}
		return nil, nil, err
	}
	if state == nil {
		return host, nil, nil
	}
	observations, err := newObservations(state, host.Cmd.Process.Pid)
	if err != nil {
		reader.Close()
		return nil, nil, errors.Join(err, host.Stop(TeardownAllowance))
	}
	go observations.read(reader)
	return host, observations, nil
}

// newObservations maps the state file and closes it.
func newObservations(state *os.File, process int) (*Observations, error) {
	defer state.Close()
	shared, err := syscall.Mmap(int(state.Fd()), 0, observationStateBytes, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return nil, err
	}
	return &Observations{shared: shared, process: process, done: make(chan struct{}), pending: map[uint64]map[string]any{}}, nil
}

func (o *Observations) word(offset int) *atomic.Uint64 {
	return (*atomic.Uint64)(unsafe.Pointer(&o.shared[offset]))
}

func observationFiles() (reader, writer, state *os.File, err error) {
	var descriptors [2]int
	syscall.ForkLock.RLock()
	if err := syscall.Pipe(descriptors[:]); err != nil {
		syscall.ForkLock.RUnlock()
		return nil, nil, nil, err
	}
	syscall.CloseOnExec(descriptors[0])
	syscall.CloseOnExec(descriptors[1])
	syscall.ForkLock.RUnlock()
	reader = os.NewFile(uintptr(descriptors[0]), "observation-reader")
	// Wrap the writer while it is blocking, so exec does not reset it; the
	// Host requires a nonblocking writer and the flag is shared with it.
	writer = os.NewFile(uintptr(descriptors[1]), "observation-writer")
	if err := syscall.SetNonblock(descriptors[1], true); err != nil {
		reader.Close()
		writer.Close()
		return nil, nil, nil, err
	}
	if state, err = os.CreateTemp("", "rui-observation-state-"); err == nil {
		os.Remove(state.Name())
		if err = state.Truncate(observationStateBytes); err != nil {
			state.Close()
		}
	}
	if err != nil {
		reader.Close()
		writer.Close()
		return nil, nil, nil, err
	}
	return reader, writer, state, nil
}

func (o *Observations) read(reader *os.File) {
	defer close(o.done)
	defer reader.Close()
	frame := make([]byte, observationRecordBytes)
	for {
		if _, err := io.ReadFull(reader, frame[:2]); err != nil {
			if !errors.Is(err, io.EOF) {
				o.fail(err)
			}
			return
		}
		length := int(binary.LittleEndian.Uint16(frame))
		if length < observationHeaderBytes || length > observationRecordBytes {
			o.fail(fmt.Errorf("invalid observation frame length %d", length))
			return
		}
		if _, err := io.ReadFull(reader, frame[2:length]); err != nil {
			o.fail(fmt.Errorf("incomplete observation frame: %w", err))
			return
		}
		sequence, record, err := decodeObservation(frame[:length])
		if err != nil {
			o.fail(err)
			return
		}
		o.mu.Lock()
		if _, duplicate := o.pending[sequence]; duplicate || sequence <= uint64(len(o.records)) {
			o.mu.Unlock()
			o.fail(fmt.Errorf("duplicate observation sequence %d", sequence))
			return
		}
		// Arrival may be reordered; expose only the complete sequence prefix.
		o.pending[sequence] = record
		for next := uint64(len(o.records)) + 1; o.pending[next] != nil; next++ {
			o.records = append(o.records, o.pending[next])
			delete(o.pending, next)
		}
		o.mu.Unlock()
	}
}

func decodeObservation(frame []byte) (uint64, map[string]any, error) {
	if frame[2] != 1 {
		return 0, nil, fmt.Errorf("observation version %d", frame[2])
	}
	if frame[3] != 0 {
		return 0, nil, errors.New("native observation loss invalidates evidence")
	}
	sequence := binary.LittleEndian.Uint64(frame[4:12])
	record := map[string]any{
		"sequence": strconv.FormatUint(sequence, 10),
		"run":      strconv.FormatUint(binary.LittleEndian.Uint64(frame[12:20]), 10),
		"process":  strconv.FormatUint(binary.LittleEndian.Uint64(frame[20:28]), 10),
	}
	for offset := observationHeaderBytes; offset < len(frame); {
		if offset+3 > len(frame) {
			return 0, nil, errors.New("incomplete observation field")
		}
		field, size := int(frame[offset]), int(binary.LittleEndian.Uint16(frame[offset+1:]))
		offset += 3
		if field >= len(observationFields) || offset+size > len(frame) {
			return 0, nil, fmt.Errorf("invalid observation field %d", field)
		}
		name := observationFields[field]
		if _, duplicate := record[name]; duplicate {
			return 0, nil, fmt.Errorf("duplicate observation field %s", name)
		}
		record[name] = string(frame[offset : offset+size])
		offset += size
	}
	if _, ok := record["rui_test_phase"]; !ok {
		return 0, nil, errors.New("missing observation phase")
	}
	return sequence, record, nil
}

func (o *Observations) fail(err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.err == nil {
		o.err = err
	}
}

// Records returns every delivered record in sequence order, failing once the
// Host has recorded a loss. It remains readable after Stop.
func (o *Observations) Records() ([]map[string]any, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.err != nil {
		return nil, o.err
	}
	// After Stop the state is unmapped and its final loss already failed Stop.
	if o.shared != nil && o.word(observationCountOffset).Load()&1 != 0 {
		return nil, errors.New("native observation loss invalidates evidence")
	}
	return append([]map[string]any{}, o.records...), nil
}

// Phase returns every delivered record of phase.
func (o *Observations) Phase(phase string) ([]map[string]any, error) {
	records, err := o.Records()
	if err != nil {
		return nil, err
	}
	result := []map[string]any{}
	for _, record := range records {
		if record["rui_test_phase"] == phase {
			result = append(result, record)
		}
	}
	return result, nil
}

// Settle waits until every publication the Host has begun is delivered, so
// Records covers all work whose replies the caller has already received.
func (o *Observations) Settle(deadline Deadline) error {
	return WaitFor(deadline, time.Millisecond, "observation delivery", func() (bool, error) {
		active, count := o.word(observationActiveOffset).Load(), o.word(observationCountOffset).Load()
		o.mu.Lock()
		delivered, err := uint64(len(o.records)), o.err
		o.mu.Unlock()
		if err == nil && count&1 != 0 {
			err = errors.New("native observation loss invalidates evidence")
		}
		return active == 0 && count>>1 == delivered, err
	})
}

// Wait returns the records of phase once at least count have arrived.
func (o *Observations) Wait(deadline Deadline, phase string, count int) ([]map[string]any, error) {
	var records []map[string]any
	err := WaitFor(deadline, 25*time.Millisecond, phase, func() (bool, error) {
		value, err := o.Phase(phase)
		records = value
		return len(records) >= count, err
	})
	return records, err
}

// Stop revokes new publications, drains those in flight, stops the Host and
// then requires the final state to account for every record: a loss or a
// publication cut by the stop fails the evidence.
func (o *Observations) Stop(host *Host, allowance time.Duration) error {
	return o.StopWith(func() error { return host.Stop(allowance) }, allowance)
}

// StopWith is Stop with the caller's Host stop, such as one that keeps the
// exit status.
func (o *Observations) StopWith(stop func() error, allowance time.Duration) error {
	o.mu.Lock()
	stopped := o.shared == nil
	o.mu.Unlock()
	if stopped { // A retried stop after a failed one only retries the Host.
		return stop()
	}
	defer func() {
		o.mu.Lock()
		defer o.mu.Unlock()
		syscall.Munmap(o.shared)
		o.shared = nil
	}()
	var drainErr error
	o.word(observationActiveOffset).Or(observationSealed)
	for drained := time.Now().Add(allowance / 2); ; time.Sleep(time.Millisecond) {
		active, count := o.word(observationActiveOffset).Load(), o.word(observationCountOffset).Load()
		o.mu.Lock()
		delivered, readErr := uint64(len(o.records)), o.err
		o.mu.Unlock()
		if readErr != nil || count&1 != 0 || active == observationSealed && count>>1 == delivered {
			break
		}
		if time.Now().After(drained) {
			drainErr = errors.New("observation custody did not retire before Host stop")
			break
		}
	}
	stopErr := stop()
	select {
	case <-o.done:
	case <-time.After(3 * time.Second):
		return errors.Join(drainErr, stopErr, errors.New("observation channel did not drain after reap"))
	}
	return errors.Join(drainErr, stopErr, o.validateFinal())
}

func (o *Observations) validateFinal() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.err != nil {
		return o.err
	}
	version := binary.LittleEndian.Uint64(o.shared[0:])
	process := binary.LittleEndian.Uint64(o.shared[8:])
	run := strconv.FormatUint(binary.LittleEndian.Uint64(o.shared[16:]), 10)
	count, active := o.word(observationCountOffset).Load(), o.word(observationActiveOffset).Load()
	switch {
	case version != 1 || process != uint64(o.process) || run == "0":
		return errors.New("missing or foreign final observation state")
	case active != observationSealed:
		return errors.New("Host exited during observation publication")
	case count&1 != 0:
		return errors.New("final native observation loss invalidates evidence")
	case count>>1 != uint64(len(o.records)) || len(o.pending) != 0:
		return fmt.Errorf("final observation sequence %d, delivered %d", count>>1, len(o.records))
	}
	for _, record := range o.records {
		if record["run"] != run || record["process"] != strconv.Itoa(o.process) {
			return errors.New("foreign final observation record")
		}
	}
	return nil
}
