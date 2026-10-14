package measurement

import (
	"bufio"
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
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"
)

const (
	GoVersion         = "go1.27.1"
	TeardownAllowance = 10 * time.Second
	readinessLimit    = 16 * 1024
)

type Deadline struct {
	at time.Time
}

func NewDeadline(duration time.Duration) Deadline {
	return Deadline{at: time.Now().Add(duration)}
}

func (d Deadline) Remaining() (time.Duration, error) {
	remaining := time.Until(d.at)
	if remaining <= 0 {
		return 0, errors.New("measurement run-wide deadline expired")
	}
	return remaining, nil
}

func (d Deadline) Context() (context.Context, context.CancelFunc, error) {
	remaining, err := d.Remaining()
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), remaining)
	return ctx, cancel, nil
}

func (d Deadline) SleepUntil(when time.Time) error {
	return sleepUntil(when, time.Now, time.Sleep, d.Remaining)
}

func sleepUntil(
	when time.Time,
	now func() time.Time,
	sleep func(time.Duration),
	remaining func() (time.Duration, error),
) error {
	for {
		delay := when.Sub(now())
		if delay <= 0 {
			return nil
		}
		budget, err := remaining()
		if err != nil {
			return err
		}
		if delay > budget {
			return errors.New("scheduled observation exceeds run-wide deadline")
		}
		sleep(delay)
	}
}

type FactLog struct {
	mu   sync.Mutex
	file *os.File
}

func JoinCleanup(result *error, cleanup func() error) {
	*result = errors.Join(*result, cleanup())
}

func NewFactLog(path string) (*FactLog, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &FactLog{file: file}, nil
}

func (l *FactLog) Write(event string, value any) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	record := map[string]any{
		"at_unix_ns": time.Now().UnixNano(),
		"event":      event,
		"value":      value,
	}
	if err := json.NewEncoder(l.file).Encode(record); err != nil {
		return err
	}
	return l.file.Sync()
}

func (l *FactLog) Close() error {
	return l.file.Close()
}

type Host struct {
	Cmd       *exec.Cmd
	Stdout    io.ReadCloser
	Stderr    *os.File
	Process   *process.Process
	Ready     map[string]string
	waitOnce  sync.Once
	waitError error
}

type HostExit struct {
	Exited         bool `json:"exited"`
	Code           int  `json:"code"`
	StopSignalSent bool `json:"stop_signal_sent"`
}

type HostExitError struct {
	Code int
}

func (e HostExitError) Error() string {
	return fmt.Sprintf("Host exited with status %d", e.Code)
}

func StartHost(
	binary string,
	store string,
	endpoint string,
	capacity int,
	stderrPath string,
	deadline Deadline,
	extra ...string,
) (*Host, error) {
	arguments := []string{
		"host", "serve", "--store", store,
		"--active-capacity", strconv.Itoa(capacity),
	}
	if endpoint != "" {
		arguments = append(arguments, "--provider-endpoint", endpoint)
	}
	arguments = append(arguments, extra...)
	cmd := exec.Command(binary, arguments...)
	// Tunable comparisons affect only the Host. Probe activation and collection
	// belong to the separate linux-memory diagnostic, not qualification.
	if value, set := os.LookupEnv("RUI_MEASURE_GLIBC_TUNABLES"); set {
		cmd.Env = append(os.Environ(), "GLIBC_TUNABLES="+value)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := os.OpenFile(stderrPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		stderr.Close()
		return nil, err
	}
	host := &Host{Cmd: cmd, Stdout: stdout, Stderr: stderr}
	ready := make(chan struct {
		fields map[string]string
		err    error
	}, 1)
	go func() {
		reader := bufio.NewReaderSize(stdout, readinessLimit+1)
		line, err := reader.ReadString('\n')
		if err != nil {
			ready <- struct {
				fields map[string]string
				err    error
			}{nil, fmt.Errorf("Host readiness: %w", err)}
			return
		}
		if len(line) > readinessLimit {
			ready <- struct {
				fields map[string]string
				err    error
			}{nil, errors.New("Host readiness exceeded 16 KiB")}
			return
		}
		parts := strings.Fields(line)
		if len(parts) == 0 || parts[0] != "ready" {
			ready <- struct {
				fields map[string]string
				err    error
			}{nil, fmt.Errorf("malformed Host readiness: %q", line)}
			return
		}
		fields := make(map[string]string, len(parts)-1)
		for _, part := range parts[1:] {
			name, value, ok := strings.Cut(part, "=")
			if !ok {
				ready <- struct {
					fields map[string]string
					err    error
				}{nil, fmt.Errorf("malformed Host readiness field: %q", part)}
				return
			}
			fields[name] = value
		}
		ready <- struct {
			fields map[string]string
			err    error
		}{fields, nil}
	}()
	remaining, err := deadline.Remaining()
	if err != nil {
		host.Stop(TeardownAllowance)
		return nil, err
	}
	if remaining > 10*time.Second {
		remaining = 10 * time.Second
	}
	select {
	case result := <-ready:
		if result.err != nil {
			host.Stop(TeardownAllowance)
			return nil, result.err
		}
		host.Ready = result.fields
	case <-time.After(remaining):
		host.Stop(TeardownAllowance)
		return nil, errors.New("Host readiness timed out")
	}
	proc, err := process.NewProcess(int32(cmd.Process.Pid))
	if err != nil {
		host.Stop(TeardownAllowance)
		return nil, err
	}
	host.Process = proc
	return host, nil
}

// CanonicalStore is the Host's exclusive Store selector from readiness.
// Unix JSON must send this exact string; a CLI alias that the OS resolves to
// the same directory is not identity on the wire.
func (h *Host) CanonicalStore() (string, error) {
	if h == nil {
		return "", errors.New("Host readiness omitted Store")
	}
	store, ok := h.Ready["store"]
	if !ok || store == "" {
		return "", errors.New("Host readiness omitted Store")
	}
	return store, nil
}

func (h *Host) wait() error {
	h.waitOnce.Do(func() { h.waitError = h.Cmd.Wait() })
	return h.waitError
}

func (h *Host) StopWithExit(allowance time.Duration) (HostExit, error) {
	stopSignalSent := false
	var killError error
	if h.Cmd.ProcessState == nil {
		killError = h.Cmd.Process.Kill()
		if killError == nil {
			stopSignalSent = true
		} else if errors.Is(killError, os.ErrProcessDone) {
			killError = nil
		}
	}
	done := make(chan error, 1)
	go func() { done <- h.wait() }()
	var waitError error
	select {
	case waitError = <-done:
	case <-time.After(allowance):
		waitError = errors.New("Host reap timed out")
	}
	var exitError *exec.ExitError
	if errors.As(waitError, &exitError) {
		waitError = nil
	}
	stdoutError := h.Stdout.Close()
	stderrError := h.Stderr.Close()
	if errors.Is(stdoutError, os.ErrClosed) {
		stdoutError = nil
	}
	if errors.Is(stderrError, os.ErrClosed) {
		stderrError = nil
	}
	status := HostExit{StopSignalSent: stopSignalSent}
	if h.Cmd.ProcessState != nil {
		status.Exited = true
		status.Code = h.Cmd.ProcessState.ExitCode()
	}
	return status, errors.Join(killError, waitError, stdoutError, stderrError)
}

func (h *Host) Stop(allowance time.Duration) error {
	status, cleanupError := h.StopWithExit(allowance)
	var statusError error
	if status.Exited && status.Code != 0 && !status.StopSignalSent {
		statusError = HostExitError{Code: status.Code}
	}
	return errors.Join(statusError, cleanupError)
}

func Run(deadline Deadline, command string, arguments ...string) ([]byte, error) {
	ctx, cancel, err := deadline.Context()
	if err != nil {
		return nil, err
	}
	defer cancel()
	cmd := exec.CommandContext(ctx, command, arguments...)
	output, runError := cmd.Output()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("%s exceeded run-wide deadline: %w", command, ctx.Err())
	}
	if runError != nil {
		var exitError *exec.ExitError
		if errors.As(runError, &exitError) {
			return nil, fmt.Errorf(
				"%s failed: %w; stderr=%q",
				command,
				runError,
				string(exitError.Stderr),
			)
		}
		return nil, runError
	}
	return output, nil
}

func RunJSON(deadline Deadline, destination any, command string, arguments ...string) error {
	output, err := Run(deadline, command, arguments...)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(output, destination); err != nil {
		return fmt.Errorf("decode %s output: %w; output=%q", command, err, output)
	}
	return nil
}

func ExchangeUnix(deadline Deadline, socketPath string, route string, value any, destination any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	remaining, err := deadline.Remaining()
	if err != nil {
		return err
	}
	dialer := net.Dialer{Timeout: remaining}
	connection, err := dialer.Dial("unix", socketPath)
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(remaining)); err != nil {
		return err
	}
	header := fmt.Sprintf(
		"POST %s HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Rui-Wire-Version: 1\r\nConnection: close\r\n\r\n",
		route,
		len(body),
	)
	if _, err := io.WriteString(connection, header); err != nil {
		return err
	}
	if _, err := connection.Write(body); err != nil {
		return err
	}
	request, _ := http.NewRequest(http.MethodPost, "http://local"+route, nil)
	response, err := http.ReadResponse(bufio.NewReader(connection), request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s returned %s: %s", route, response.Status, responseBody)
	}
	if err := json.Unmarshal(responseBody, destination); err != nil {
		return fmt.Errorf("decode %s response: %w", route, err)
	}
	return nil
}

func TimedExchangeUnix(deadline Deadline, socketPath string, route string, value any, destination any) (float64, error) {
	started := time.Now()
	err := ExchangeUnix(deadline, socketPath, route, value, destination)
	return float64(time.Since(started).Microseconds()) / 1000, err
}

func DatabaseSize(store string) (map[string]uint64, error) {
	info, err := os.Stat(filepath.Join(store, "rui.sqlite3"))
	if err != nil {
		return nil, err
	}
	allocated := uint64(0)
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		allocated = uint64(stat.Blocks) * 512
	}
	return map[string]uint64{
		"database_logical_bytes":   uint64(info.Size()),
		"database_allocated_bytes": allocated,
	}, nil
}

type Footprint struct {
	PhysicalBytes         uint64 `json:"physical_footprint_bytes"`
	PhysicalTolerance     uint64 `json:"physical_footprint_rounding_tolerance_bytes"`
	LifetimePeakBytes     uint64 `json:"lifetime_peak_physical_footprint_bytes"`
	LifetimePeakTolerance uint64 `json:"lifetime_peak_physical_footprint_rounding_tolerance_bytes"`
}

// The kernel reads peak before current; this is a bracketed observation, not
// an atomic snapshot. Keep the untouched counters even when validation fails.
type nativeFootprintReport struct {
	API           string `json:"api"`
	PID           int32  `json:"pid"`
	BeginTicks    uint64 `json:"begin_mach_absolute_ticks"`
	EndTicks      uint64 `json:"end_mach_absolute_ticks"`
	TimebaseNumer uint32 `json:"timebase_numer"`
	TimebaseDenom uint32 `json:"timebase_denom"`
	ProcessStart  uint64 `json:"process_start_mach_absolute_ticks"`
	ProcessExit   uint64 `json:"process_exit_mach_absolute_ticks"`
	CurrentBytes  uint64 `json:"physical_footprint_bytes"`
	PeakBytes     uint64 `json:"lifetime_peak_physical_footprint_bytes"`
	Error         string `json:"error,omitempty"`
}

func (r nativeFootprintReport) footprint(pid int32) (Footprint, error) {
	if r.Error != "" {
		return Footprint{}, UnavailableMeasurement(fmt.Errorf("native footprint: %s", r.Error))
	}
	if r.PID != pid || r.ProcessStart == 0 || r.ProcessStart > r.BeginTicks || r.ProcessExit != 0 {
		return Footprint{}, InvalidMeasurement(errors.New("native footprint requires an identified live process"))
	}
	if r.BeginTicks == 0 || r.EndTicks < r.BeginTicks || r.TimebaseNumer == 0 || r.TimebaseDenom == 0 {
		return Footprint{}, InvalidMeasurement(errors.New("invalid native footprint clock bracket"))
	}
	if r.CurrentBytes == 0 || r.PeakBytes == 0 || r.PeakBytes < r.CurrentBytes {
		return Footprint{}, InvalidMeasurement(fmt.Errorf("invalid native footprint counters: current=%d peak=%d", r.CurrentBytes, r.PeakBytes))
	}
	return Footprint{PhysicalBytes: r.CurrentBytes, LifetimePeakBytes: r.PeakBytes}, nil
}

type FootprintVerdict struct {
	Status          string `json:"status"`
	TargetBytes     uint64 `json:"target_bytes"`
	LowerBoundBytes uint64 `json:"lifetime_peak_lower_bound_bytes"`
	UpperBoundBytes uint64 `json:"lifetime_peak_upper_bound_bytes"`
}

func ClassifyFootprint(footprint Footprint, target uint64) FootprintVerdict {
	lower := uint64(0)
	if footprint.LifetimePeakBytes > footprint.LifetimePeakTolerance {
		lower = footprint.LifetimePeakBytes - footprint.LifetimePeakTolerance
	}
	upper := ^uint64(0)
	overflow := footprint.LifetimePeakBytes > upper-footprint.LifetimePeakTolerance
	if !overflow {
		upper = footprint.LifetimePeakBytes + footprint.LifetimePeakTolerance
	}
	status := "unavailable"
	if overflow || footprint.LifetimePeakBytes == 0 {
		status = "unavailable"
	} else if upper <= target {
		status = "passed"
	} else if lower > target {
		status = "target_miss"
	}
	return FootprintVerdict{Status: status, TargetBytes: target, LowerBoundBytes: lower, UpperBoundBytes: upper}
}

type SampleValidity struct {
	Attempts   uint64 `json:"attempts"`
	Succeeded  uint64 `json:"succeeded"`
	Failed     uint64 `json:"failed"`
	FirstError string `json:"first_error,omitempty"`
}

func (v *SampleValidity) Record(err error) {
	v.Attempts++
	if err == nil {
		v.Succeeded++
		return
	}
	v.Failed++
	if v.FirstError == "" {
		v.FirstError = err.Error()
	}
}

func (v SampleValidity) Status() string {
	if v.Succeeded == 0 || v.Failed != 0 {
		return "unavailable"
	}
	return "diagnostic"
}

// QualificationStatus reduces required evidence only. Optional diagnostic rows
// must stay outside this boundary; missing or unknown verdicts cannot pass.
func QualificationStatus(rowFamilies ...[]map[string]any) string {
	precedence := map[string]int{"passed": 0, "target_miss": 1, "incomplete": 2, "unavailable": 3, "invalid_measurement": 4, "failed": 5}
	status := "passed"
	count := 0
	for _, rows := range rowFamilies {
		for _, row := range rows {
			count++
			candidate, ok := row["status"].(string)
			rank, known := precedence[candidate]
			if !ok || !known {
				return "failed"
			}
			if rank > precedence[status] {
				status = candidate
			}
		}
	}
	if count == 0 {
		return "incomplete"
	}
	return status
}

type ProcessSample struct {
	RSSBytes                uint64       `json:"rss_bytes"`
	VirtualBytes            uint64       `json:"virtual_bytes"`
	CPUUserSeconds          float64      `json:"cpu_user_seconds"`
	CPUSystemSeconds        float64      `json:"cpu_system_seconds"`
	Threads                 int32        `json:"threads"`
	LiveDescendantProcesses int          `json:"live_descendant_processes"`
	OpenDescriptorRows      int          `json:"open_descriptor_rows,omitempty"`
	OpenDescriptors         int32        `json:"open_descriptors"`
	DiskReadBytes           uint64       `json:"disk_read_bytes"`
	DiskWriteBytes          uint64       `json:"disk_write_bytes"`
	Footprint               Footprint    `json:"footprint,omitzero"`
	LinuxMemory             *LinuxMemory `json:"linux_memory,omitempty"`
}

type PortableProcessSample struct {
	RSSBytes                uint64  `json:"rss_bytes"`
	VirtualBytes            uint64  `json:"virtual_bytes"`
	CPUUserSeconds          float64 `json:"cpu_user_seconds"`
	CPUSystemSeconds        float64 `json:"cpu_system_seconds"`
	Threads                 int32   `json:"threads"`
	LiveDescendantProcesses int     `json:"live_descendant_processes"`
	OpenDescriptors         int32   `json:"open_descriptors"`
	DiskReadBytes           uint64  `json:"disk_read_bytes"`
	DiskWriteBytes          uint64  `json:"disk_write_bytes"`
}

type processSampleCore struct {
	memory      *process.MemoryInfoStat
	times       *cpu.TimesStat
	threads     int32
	children    []*process.Process
	descriptors int32
	ioCounters  *process.IOCountersStat
}

func sampleProcessCore(target *process.Process) (processSampleCore, error) {
	memory, err := target.MemoryInfo()
	if err != nil {
		return processSampleCore{}, err
	}
	times, err := target.Times()
	if err != nil {
		return processSampleCore{}, err
	}
	threads, err := target.NumThreads()
	if err != nil {
		return processSampleCore{}, err
	}
	children, err := target.Children()
	if err != nil {
		return processSampleCore{}, err
	}
	descriptors, err := target.NumFDs()
	if err != nil {
		return processSampleCore{}, err
	}
	ioCounters, err := target.IOCounters()
	if err != nil {
		return processSampleCore{}, err
	}
	return processSampleCore{
		memory:      memory,
		times:       times,
		threads:     threads,
		children:    children,
		descriptors: descriptors,
		ioCounters:  ioCounters,
	}, nil
}

func SamplePortableProcess(target *process.Process) (PortableProcessSample, error) {
	core, err := sampleProcessCore(target)
	if err != nil {
		return PortableProcessSample{}, err
	}
	return PortableProcessSample{
		RSSBytes:                core.memory.RSS,
		VirtualBytes:            core.memory.VMS,
		CPUUserSeconds:          core.times.User,
		CPUSystemSeconds:        core.times.System,
		Threads:                 core.threads,
		LiveDescendantProcesses: len(core.children),
		OpenDescriptors:         core.descriptors,
		DiskReadBytes:           core.ioCounters.DiskReadBytes,
		DiskWriteBytes:          core.ioCounters.DiskWriteBytes,
	}, nil
}

func SampleProcess(target *process.Process, rawFootprintPath string) (ProcessSample, error) {
	core, err := sampleProcessCore(target)
	if err != nil {
		return ProcessSample{}, UnavailableMeasurement(err)
	}
	result := ProcessSample{
		RSSBytes: core.memory.RSS, VirtualBytes: core.memory.VMS,
		CPUUserSeconds: core.times.User, CPUSystemSeconds: core.times.System,
		Threads: core.threads, LiveDescendantProcesses: len(core.children),
		OpenDescriptors: core.descriptors,
		DiskReadBytes:   core.ioCounters.DiskReadBytes, DiskWriteBytes: core.ioCounters.DiskWriteBytes,
	}
	if runtime.GOOS == "linux" {
		result.LinuxMemory, err = sampleLinuxMemory(target.Pid, rawFootprintPath)
		return result, err
	}
	if runtime.GOOS != "darwin" {
		return ProcessSample{}, UnavailableMeasurement(fmt.Errorf("unsupported process sampling platform %s", runtime.GOOS))
	}
	pid := strconv.Itoa(int(target.Pid))
	native := readNativeFootprint(target.Pid)
	report, err := json.Marshal(native)
	if err != nil {
		return ProcessSample{}, err
	}
	footprint, validationError := native.footprint(target.Pid)
	// Preserve the raw report even on an API or consistency failure. No retry,
	// clamping or RSS fallback may turn missing evidence into qualification.
	if err := errors.Join(validationError, os.WriteFile(rawFootprintPath, append(report, '\n'), 0o600)); err != nil {
		return ProcessSample{}, err
	}
	lsofContext, cancelLsof := context.WithTimeout(context.Background(), TeardownAllowance)
	defer cancelLsof()
	lsof, err := exec.CommandContext(lsofContext, "/usr/sbin/lsof", "-n", "-P", "-p", pid).Output()
	if err != nil {
		return ProcessSample{}, UnavailableMeasurement(fmt.Errorf("lsof failed: %w", err))
	}
	rows := strings.Count(string(lsof), "\n") - 1
	if rows < 0 {
		rows = 0
	}
	result.OpenDescriptorRows, result.Footprint = rows, footprint
	return result, nil
}

func (s ProcessSample) Portable() PortableProcessSample {
	return PortableProcessSample{
		RSSBytes:                s.RSSBytes,
		VirtualBytes:            s.VirtualBytes,
		CPUUserSeconds:          s.CPUUserSeconds,
		CPUSystemSeconds:        s.CPUSystemSeconds,
		Threads:                 s.Threads,
		LiveDescendantProcesses: s.LiveDescendantProcesses,
		OpenDescriptors:         s.OpenDescriptors,
		DiskReadBytes:           s.DiskReadBytes,
		DiskWriteBytes:          s.DiskWriteBytes,
	}
}

func CPUSeconds(target *process.Process) (float64, error) {
	times, err := target.Times()
	if err != nil {
		return 0, err
	}
	return times.User + times.System, nil
}

func CheckedCPUDelta(before, after float64) (float64, error) {
	if after < before {
		return 0, fmt.Errorf("process CPU counter decreased from %.9f to %.9f", before, after)
	}
	return after - before, nil
}

func WaitFor(deadline Deadline, interval time.Duration, description string, predicate func() (bool, error)) error {
	for {
		ready, err := predicate()
		if err != nil {
			return err
		}
		if ready {
			return nil
		}
		remaining, err := deadline.Remaining()
		if err != nil {
			return fmt.Errorf("timed out waiting for %s: %w", description, err)
		}
		if interval > remaining {
			interval = remaining
		}
		time.Sleep(interval)
	}
}

func RequireGoRuntime() error {
	if runtime.Version() != GoVersion {
		return fmt.Errorf("measurement requires %s; got %s", GoVersion, runtime.Version())
	}
	return nil
}

func RequireRuntime() error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("measurement requires macOS; got %s", runtime.GOOS)
	}
	return RequireGoRuntime()
}

func RequireProcessRuntime() error {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return fmt.Errorf("measurement requires macOS or Linux; got %s", runtime.GOOS)
	}
	return RequireGoRuntime()
}

func SourceProvenance(deadline Deadline, root, ignoredOutput string) (string, *bool, error) {
	top, err := Run(deadline, "git", "-C", root, "rev-parse", "--show-toplevel")
	if err != nil || filepath.Clean(strings.TrimSpace(string(top))) != filepath.Clean(root) {
		return "", nil, nil
	}
	revision, err := Run(deadline, "git", "-C", root, "rev-parse", "HEAD")
	if err != nil {
		return "", nil, err
	}
	status, err := Run(deadline, "git", "-C", root, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return "", nil, err
	}
	ignored := ""
	if ignoredOutput != "" {
		if relative, relativeError := filepath.Rel(root, ignoredOutput); relativeError == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			ignored = filepath.ToSlash(relative)
		}
	}
	dirty := false
	for _, line := range strings.Split(strings.TrimSpace(string(status)), "\n") {
		if line == "" {
			continue
		}
		path := ""
		if len(line) >= 4 {
			path = strings.TrimSpace(line[3:])
		}
		if path != ignored {
			dirty = true
			break
		}
	}
	return strings.TrimSpace(string(revision)), &dirty, nil
}

func SHA256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func RepositoryRoot() (string, error) {
	working, err := os.Getwd()
	if err != nil {
		return "", err
	}
	if filepath.Base(working) == "qualification" && filepath.Base(filepath.Dir(working)) == "tests" {
		if _, err := os.Stat(filepath.Join(working, "go.mod")); err == nil {
			return filepath.Dir(filepath.Dir(working)), nil
		}
	}
	return working, nil
}

func EnvironmentEvidence(deadline Deadline, binary, output string) (map[string]any, error) {
	runtimeManifest, err := RuntimeManifest()
	result := map[string]any{"binary": binary, "measurement_runtime": runtimeManifest}
	if err != nil {
		return result, err
	}
	root, err := RepositoryRoot()
	if err != nil {
		return result, err
	}
	revision, dirty, err := SourceProvenance(deadline, root, output)
	if err != nil {
		return result, err
	}
	result["tested_revision"], result["working_tree_dirty"] = revision, dirty
	binaryHash, err := SHA256File(binary)
	if err != nil {
		return result, err
	}
	result["binary_sha256"] = binaryHash
	sumHash, err := SHA256File(filepath.Join(root, "tests", "qualification", "go.sum"))
	if err != nil {
		return result, err
	}
	result["measurement_go_sum_sha256"] = sumHash
	// These identify the files present at observation time, not an assertion
	// that a previously built collector used this checkout.
	sources := map[string]string{}
	module := filepath.Join(root, "tests", "qualification")
	if err := filepath.WalkDir(module, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !(strings.HasSuffix(path, ".go") || entry.Name() == "go.mod" || entry.Name() == "go.sum") {
			return nil
		}
		digest, err := SHA256File(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		sources[relative] = digest
		return nil
	}); err != nil {
		return result, err
	}
	runtimeManifest["source_files_at_observation_sha256"] = sources
	zig, err := Run(deadline, "zig", "version")
	if err != nil {
		return result, err
	}
	result["zig"] = strings.TrimSpace(string(zig))
	platform, err := Run(deadline, "uname", "-a")
	if err != nil {
		return result, err
	}
	result["platform"] = strings.TrimSpace(string(platform))
	return result, nil
}

// AttachEnvironmentEvidence preserves partial provenance even when a later
// probe fails. Call from the runner's finalizer, including failed workloads.
func AttachEnvironmentEvidence(result map[string]any, binary, output string) error {
	evidence, err := EnvironmentEvidence(NewDeadline(time.Minute), binary, output)
	for name, value := range evidence {
		result[name] = value
	}
	if err != nil {
		result["environment_evidence_status"], result["environment_evidence_error"] = "unavailable", err.Error()
		return UnavailableMeasurement(err)
	}
	result["environment_evidence_status"] = "passed"
	return nil
}

func WriteJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
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

// PublishQualification writes the complete verdict before its caller
// decides the process exit status.
func PublishQualification(path string, result map[string]any) error {
	if path != "" {
		return WriteJSON(path, result)
	}
	return EncodeJSON(os.Stdout, result)
}

type measurementError struct {
	status string
	cause  error
}

func (e measurementError) Error() string { return e.cause.Error() }
func (e measurementError) Unwrap() error { return e.cause }

// Wrap only collection/validation failures, never a joined cleanup error.
func UnavailableMeasurement(err error) error {
	return measurementError{status: "unavailable", cause: err}
}

func InvalidMeasurement(err error) error {
	return measurementError{status: "invalid_measurement", cause: err}
}

// FailureStatus checks every joined branch. Finding one measurement error
// with errors.As would incorrectly hide a sibling behavior/disposal failure.
func FailureStatus(err error) string {
	switch e := err.(type) {
	case nil:
		return "passed"
	case measurementError:
		return e.status
	case interface{ Unwrap() []error }:
		children := e.Unwrap()
		if len(children) == 0 {
			return "failed"
		}
		status := "unavailable"
		for _, child := range children {
			switch FailureStatus(child) {
			case "failed", "passed":
				return "failed"
			case "invalid_measurement":
				status = "invalid_measurement"
			}
		}
		return status
	case interface{ Unwrap() error }:
		if cause := e.Unwrap(); cause != nil {
			return FailureStatus(cause)
		}
		return "failed"
	default:
		return "failed"
	}
}

// FinishQualification runs after owned resources have been disposed. Partial
// rows and artifact locations survive collection, behavior and cleanup errors.
func FinishQualification(path string, result map[string]any, runError error) int {
	if runError != nil {
		if result["status"] != "failed" && result["status"] != "behavior_error" {
			result["status"] = FailureStatus(runError)
		}
		result["error"] = runError.Error()
	}
	if err := PublishQualification(path, result); err != nil {
		fmt.Fprintln(os.Stderr, "publish qualification:", err)
		return 1
	}
	return QualificationExitCode(result)
}

// QualificationExitCode keeps process success as strict as the published
// qualification reducers. Smoke-only runners use their established success
// vocabulary; every missing or non-success verdict fails the process.
func QualificationExitCode(result map[string]any) int {
	status, ok := result["status"].(string)
	if ok && (status == "passed" || status == "smoke_passed") {
		return 0
	}
	return 1
}

var readVirtualMemory = mem.VirtualMemory

func RuntimeManifest() (map[string]any, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	digest, err := SHA256File(executable)
	if err != nil {
		return nil, err
	}
	manifest := map[string]any{
		"collector_executable_sha256": digest,
		"go_version":                  runtime.Version(),
		"go_os":                       runtime.GOOS,
		"go_arch":                     runtime.GOARCH,
		"logical_cpus":                runtime.NumCPU(),
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		manifest["module_path"] = info.Main.Path
		settings := map[string]string{}
		for _, setting := range info.Settings {
			switch setting.Key {
			case "CGO_ENABLED", "CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS", "GOOS", "GOARCH", "GOAMD64", "GOARM64", "-compiler", "-buildmode", "-tags", "vcs.revision", "vcs.modified":
				settings[setting.Key] = setting.Value
			}
		}
		manifest["collector_build_settings"] = settings
		for _, dependency := range info.Deps {
			if dependency.Path == "github.com/shirou/gopsutil/v4" {
				manifest["gopsutil_version"] = dependency.Version
			}
		}
	}
	virtual, err := readVirtualMemory()
	if err != nil {
		return manifest, err
	}
	manifest["physical_memory_bytes"] = virtual.Total
	return manifest, nil
}

func WriteAll(writer io.Writer, value []byte) error {
	written, err := writer.Write(value)
	if err != nil {
		return err
	}
	if written != len(value) {
		return io.ErrShortWrite
	}
	return nil
}

func EncodeJSON(writer io.Writer, value any) error {
	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}
