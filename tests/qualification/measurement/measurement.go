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
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

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
	delay := time.Until(when)
	if delay <= 0 {
		return nil
	}
	remaining, err := d.Remaining()
	if err != nil {
		return err
	}
	if delay > remaining {
		return errors.New("scheduled observation exceeds run-wide deadline")
	}
	time.Sleep(delay)
	return nil
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
		"serve", "--store", store,
		"--active-capacity", strconv.Itoa(capacity),
	}
	if endpoint != "" {
		arguments = append(arguments, "--provider-endpoint", endpoint)
	}
	arguments = append(arguments, extra...)
	cmd := exec.Command(binary, arguments...)
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

var footprintCounter = regexp.MustCompile(`^\s*(phys_footprint|phys_footprint_peak):\s+([0-9]+(?:\.[0-9]+)?)\s+(B|KB|MB|GB)\s*$`)

func ParseFootprint(report string) (Footprint, error) {
	values := map[string]struct {
		bytes     uint64
		tolerance uint64
	}{}
	scales := map[string]uint64{"B": 1, "KB": 1024, "MB": 1024 * 1024, "GB": 1024 * 1024 * 1024}
	for _, line := range strings.Split(report, "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "phys_footprint") {
			continue
		}
		match := footprintCounter.FindStringSubmatch(line)
		if match == nil {
			return Footprint{}, fmt.Errorf("malformed footprint counter %q", line)
		}
		if _, duplicate := values[match[1]]; duplicate {
			return Footprint{}, fmt.Errorf("duplicate footprint counter %q", match[1])
		}
		number, err := strconv.ParseFloat(match[2], 64)
		if err != nil || number <= 0 {
			return Footprint{}, fmt.Errorf("invalid footprint counter %q", match[0])
		}
		scale := scales[match[3]]
		decimals := len(strings.SplitN(match[2], ".", 2))
		quantum := float64(scale)
		if decimals == 2 {
			quantum /= float64(pow10(len(strings.SplitN(match[2], ".", 2)[1])))
		}
		tolerance := uint64(0)
		if scale != 1 || decimals == 2 {
			tolerance = uint64(quantum/2 + 0.999999999)
		}
		values[match[1]] = struct {
			bytes     uint64
			tolerance uint64
		}{uint64(number*float64(scale) + 0.5), tolerance}
	}
	current, currentOK := values["phys_footprint"]
	peak, peakOK := values["phys_footprint_peak"]
	if !currentOK || !peakOK {
		return Footprint{}, fmt.Errorf("required footprint counters unavailable: %q", report)
	}
	currentLow := uint64(0)
	if current.bytes > current.tolerance {
		currentLow = current.bytes - current.tolerance
	}
	if peak.bytes+peak.tolerance < currentLow {
		return Footprint{}, fmt.Errorf("lifetime peak below current beyond rounding tolerance: %q", report)
	}
	return Footprint{
		PhysicalBytes:         current.bytes,
		PhysicalTolerance:     current.tolerance,
		LifetimePeakBytes:     peak.bytes,
		LifetimePeakTolerance: peak.tolerance,
	}, nil
}

func pow10(exponent int) uint64 {
	result := uint64(1)
	for range exponent {
		result *= 10
	}
	return result
}

type ProcessSample struct {
	RSSBytes                uint64    `json:"rss_bytes"`
	VirtualBytes            uint64    `json:"virtual_bytes"`
	CPUUserSeconds          float64   `json:"cpu_user_seconds"`
	CPUSystemSeconds        float64   `json:"cpu_system_seconds"`
	Threads                 int32     `json:"threads"`
	LiveDescendantProcesses int       `json:"live_descendant_processes"`
	OpenDescriptorRows      int       `json:"open_descriptor_rows"`
	DiskReadBytes           uint64    `json:"disk_read_bytes"`
	DiskWriteBytes          uint64    `json:"disk_write_bytes"`
	Footprint               Footprint `json:"footprint"`
}

func SampleProcess(target *process.Process, rawFootprintPath string) (ProcessSample, error) {
	memory, err := target.MemoryInfo()
	if err != nil {
		return ProcessSample{}, err
	}
	times, err := target.Times()
	if err != nil {
		return ProcessSample{}, err
	}
	threads, err := target.NumThreads()
	if err != nil {
		return ProcessSample{}, err
	}
	children, err := target.Children()
	if err != nil {
		return ProcessSample{}, err
	}
	ioCounters, err := target.IOCounters()
	if err != nil {
		return ProcessSample{}, err
	}
	pid := strconv.Itoa(int(target.Pid))
	footprintCommand := exec.Command("/usr/bin/footprint", "-p", pid)
	report, err := footprintCommand.CombinedOutput()
	if err != nil {
		return ProcessSample{}, fmt.Errorf("footprint failed: %w; output=%q", err, report)
	}
	if err := os.WriteFile(rawFootprintPath, report, 0o600); err != nil {
		return ProcessSample{}, err
	}
	footprint, err := ParseFootprint(string(report))
	if err != nil {
		return ProcessSample{}, err
	}
	lsof, err := exec.Command("/usr/sbin/lsof", "-n", "-P", "-p", pid).Output()
	if err != nil {
		return ProcessSample{}, fmt.Errorf("lsof failed: %w", err)
	}
	rows := strings.Count(string(lsof), "\n") - 1
	if rows < 0 {
		rows = 0
	}
	return ProcessSample{
		RSSBytes:                memory.RSS,
		VirtualBytes:            memory.VMS,
		CPUUserSeconds:          times.User,
		CPUSystemSeconds:        times.System,
		Threads:                 threads,
		LiveDescendantProcesses: len(children),
		OpenDescriptorRows:      rows,
		DiskReadBytes:           ioCounters.DiskReadBytes,
		DiskWriteBytes:          ioCounters.DiskWriteBytes,
		Footprint:               footprint,
	}, nil
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

func RequireRuntime() error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("measurement requires macOS; got %s", runtime.GOOS)
	}
	if runtime.Version() != GoVersion {
		return fmt.Errorf("measurement requires %s; got %s", GoVersion, runtime.Version())
	}
	return nil
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
	root, err := RepositoryRoot()
	if err != nil {
		return nil, err
	}
	revision, dirty, err := SourceProvenance(deadline, root, output)
	if err != nil {
		return nil, err
	}
	binaryHash, err := SHA256File(binary)
	if err != nil {
		return nil, err
	}
	sumHash, err := SHA256File(filepath.Join(root, "tests", "qualification", "go.sum"))
	if err != nil {
		return nil, err
	}
	zig, err := Run(deadline, "zig", "version")
	if err != nil {
		return nil, err
	}
	platform, err := Run(deadline, "uname", "-a")
	if err != nil {
		return nil, err
	}
	runtimeManifest, err := RuntimeManifest()
	if err != nil {
		return nil, err
	}
	return map[string]any{"tested_revision": revision, "working_tree_dirty": dirty, "binary": binary, "binary_sha256": binaryHash, "zig": strings.TrimSpace(string(zig)), "platform": strings.TrimSpace(string(platform)), "measurement_go_sum_sha256": sumHash, "measurement_runtime": runtimeManifest}, nil
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

var readVirtualMemory = mem.VirtualMemory

func RuntimeManifest() (map[string]any, error) {
	virtual, err := readVirtualMemory()
	if err != nil {
		return nil, err
	}
	manifest := map[string]any{
		"go_version":            runtime.Version(),
		"go_os":                 runtime.GOOS,
		"go_arch":               runtime.GOARCH,
		"logical_cpus":          runtime.NumCPU(),
		"physical_memory_bytes": virtual.Total,
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		manifest["module_path"] = info.Main.Path
		for _, dependency := range info.Deps {
			if dependency.Path == "github.com/shirou/gopsutil/v4" {
				manifest["gopsutil_version"] = dependency.Version
			}
		}
	}
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
