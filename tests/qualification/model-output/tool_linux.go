//go:build linux

package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"rui.local/qualification/measurement"
	"rui.local/qualification/model-output/provider"
)

const (
	toolSeedBytes      = 400 * 1024
	toolReadBytes      = 100 * 1024
	toolSampleInterval = 200 * time.Millisecond
	toolClockTicks     = 100 // Linux USER_HZ on every supported kernel
)

func toolMeasurementOptions(sessions int, workload, expectation string, sampleMS int) error {
	if sampleMS < 10 || sampleMS > 1000 {
		return errors.New("--tool-sample-ms must be 10 to 1000")
	}
	if sessions != 1 && sessions != 10 && sessions != 100 {
		return errors.New("--tool-sessions must be 1, 10 or 100")
	}
	if workload != "sleep" && workload != "read" {
		return errors.New("--tool-workload must be sleep or read")
	}
	if strings.TrimSpace(expectation) == "" || strings.ContainsAny(expectation, "\r\n") {
		return errors.New("--expectation requires one line with an estimated number and reasoning")
	}
	return nil
}

func runToolProviderChild(config provider.ToolConfig) error {
	server, err := provider.StartTool(config)
	if err != nil {
		return err
	}
	startup := fixtureStartup{ProviderURL: server.ProviderURL(), ProviderCA: server.ProviderCAFile(), ControlURL: server.ControlURL(), PID: os.Getpid()}
	if err := json.NewEncoder(os.Stdout).Encode(startup); err != nil {
		return errors.Join(err, server.Close())
	}
	<-server.ShutdownRequested()
	return server.Close()
}

func (f *childFixture) tool(deadline measurement.Deadline, route string) (provider.ToolSummary, error) {
	var summary provider.ToolSummary
	ctx, cancel, err := deadline.Context()
	if err != nil {
		return summary, err
	}
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, f.controlURL+route, nil)
	if err != nil {
		return summary, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return summary, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		return summary, fmt.Errorf("provider control %s returned %s: %s", route, response.Status, body)
	}
	return summary, json.NewDecoder(response.Body).Decode(&summary)
}

// Deterministic prose-like text; the token figure beside it is bytes/4, an
// estimate, not a tokenizer count.
func toolText(header string, size int, seed uint64) []byte {
	words := []string{"the", "build", "failed", "because", "a", "test", "reads", "stale", "cache", "entries", "from", "disk", "and", "we", "should", "check", "whether", "Host", "retries", "request", "before", "session", "config", "returns", "error", "path", "function", "value", "pointer", "loop", "commit", "branch"}
	var out bytes.Buffer
	out.WriteString(header)
	state := seed*6364136223846793005 + 1442695040888963407
	column := 0
	for out.Len() < size {
		state = state*6364136223846793005 + 1442695040888963407
		word := words[(state>>33)%uint64(len(words))]
		out.WriteString(word)
		column += len(word) + 1
		if column > 72 {
			out.WriteByte('\n')
			column = 0
		} else {
			out.WriteByte(' ')
		}
	}
	return out.Bytes()[:size]
}

type toolProc struct {
	pid, ppid int
	comm      string
	state     string
	start     uint64
	ticks     uint64
}

func readToolProc(pid int) (toolProc, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return toolProc{}, err
	}
	open, close := bytes.IndexByte(data, '('), bytes.LastIndexByte(data, ')')
	if open < 0 || close < open {
		return toolProc{}, errors.New("malformed stat")
	}
	fields := strings.Fields(string(data[close+2:]))
	if len(fields) < 20 {
		return toolProc{}, errors.New("short stat")
	}
	ppid, _ := strconv.Atoi(fields[1])
	utime, _ := strconv.ParseUint(fields[11], 10, 64)
	stime, _ := strconv.ParseUint(fields[12], 10, 64)
	start, _ := strconv.ParseUint(fields[19], 10, 64)
	return toolProc{pid: pid, ppid: ppid, comm: string(data[open+1 : close]), state: fields[0], start: start, ticks: utime + stime}, nil
}

// cpuTicks returns own user+system and reaped-children user+system ticks.
func cpuTicks(pid int) (self, children uint64, err error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, 0, err
	}
	fields := strings.Fields(string(data[bytes.LastIndexByte(data, ')')+2:]))
	value := func(index int) uint64 { number, _ := strconv.ParseUint(fields[index], 10, 64); return number }
	return value(11) + value(12), value(13) + value(14), nil
}

func readPSS(pid int) (uint64, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/smaps_rollup", pid))
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, "Pss:"); ok {
			fields := strings.Fields(rest)
			if len(fields) != 2 || fields[1] != "kB" {
				return 0, errors.New("malformed Pss")
			}
			value, err := strconv.ParseUint(fields[0], 10, 64)
			return value * 1024, err
		}
	}
	return 0, errors.New("missing Pss")
}

type toolProcessRecord struct {
	PID         int    `json:"pid"`
	PPID        int    `json:"ppid"`
	StartTicks  uint64 `json:"start_ticks"`
	Comm        string `json:"comm"`
	Category    string `json:"category"`
	FirstSeenNS int64  `json:"first_seen_unix_ns"`
	LastSeenNS  int64  `json:"last_seen_unix_ns"`
	Samples     int    `json:"samples"`
	PSSFailures int    `json:"pss_failures"`
	PSSReads    int    `json:"pss_reads"`
	MaxPSS      uint64 `json:"max_pss_bytes"`
	LastPSS     uint64 `json:"last_pss_bytes"`
	CPUTicks    uint64 `json:"last_cpu_ticks"`
	// DispatchShell marks a Bash shell seen with a `rui` send child.
	DispatchShell bool `json:"dispatch_shell"`
	// Transitions lists each distinct comm/category this identity showed, in
	// order: a Host child that execs its final command keeps its PID and
	// start time but changes from bash/bash_shell to, say, sleep/bash_exec.
	Transitions []string `json:"transitions"`
}

type toolSample struct {
	BeginNS     int64             `json:"begin_unix_ns"`
	EndNS       int64             `json:"end_unix_ns"`
	Phase       string            `json:"phase"`
	Counts      map[string]int    `json:"counts"`
	PSS         map[string]uint64 `json:"pss_bytes"`
	PSSFailures int               `json:"pss_failures"`
}

// toolSampler walks /proc and sums smaps_rollup PSS over the Host tree and
// the TUI tree. One sample reads processes one after another between
// begin_unix_ns and end_unix_ns, so its sum is a sequential-scan sum, not a
// simultaneous snapshot, and omits every process whose read failed. Every PID+start time appears once per sample under exactly
// one category; `rui` processes under a Bash shell are clients, not Bash.
type toolSampler struct {
	host, tui int
	active    time.Duration
	mu        sync.Mutex
	phase     string
	records   map[string]*toolProcessRecord
	samples   []toolSample
	stop      chan struct{}
	stopped   chan struct{}
	raw       *os.File
}

func columns(category string) string {
	switch category {
	case "host":
		return "host"
	case "tui", "tui_child", "send", "send_child":
		return "clients"
	case "unreaped":
		return "unreaped"
	default:
		return "bash"
	}
}

// isSend recognizes `rui session send` by argv, whether it runs under a
// shell or replaced the Host's Bash child; a Host fork before exec has the
// Host's argv.
func isSend(pid int) bool {
	data, _ := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	argv := strings.Split(string(data), "\x00")
	return len(argv) >= 3 && argv[1] == "session" && argv[2] == "send"
}

func (s *toolSampler) sample() {
	begin := time.Now()
	entries, _ := os.ReadDir("/proc")
	procs := map[int]toolProc{}
	children := map[int][]int{}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		row, err := readToolProc(pid)
		if err != nil {
			continue
		}
		procs[pid] = row
		children[row.ppid] = append(children[row.ppid], pid)
	}
	categories := map[int]string{}
	dispatchShells := map[int]bool{}
	var walk func(pid int, category string)
	walk = func(pid int, category string) {
		categories[pid] = category
		for _, child := range children[pid] {
			row := procs[child]
			next := "bash_child"
			switch {
			// An exited, unreaped process has no memory or argv left.
			case row.state == "Z":
				next = "unreaped"
			case category == "host" && row.comm == "bash":
				next = "bash_shell"
			case category == "host" && row.comm == "rui" && isSend(child):
				next = "send"
			case category == "host" && row.comm == "rui":
				next = "host_fork_pre_exec"
			case category == "host":
				next = "bash_exec"
			case category == "tui" || category == "tui_child":
				next = "tui_child"
			case category == "send" || category == "send_child":
				next = "send_child"
			case row.comm == "rui":
				next = "send"
				dispatchShells[pid] = true
			}
			walk(child, next)
		}
	}
	s.mu.Lock()
	phase, tui := s.phase, s.tui
	s.mu.Unlock()
	if _, ok := procs[s.host]; ok {
		walk(s.host, "host")
	}
	if _, ok := procs[tui]; ok && tui != 0 {
		walk(tui, "tui")
	}
	result := toolSample{Phase: phase, Counts: map[string]int{}, PSS: map[string]uint64{}}
	for pid, category := range categories {
		row := procs[pid]
		key := fmt.Sprintf("%d:%d", pid, row.start)
		s.mu.Lock()
		record := s.records[key]
		if record == nil {
			record = &toolProcessRecord{PID: pid, PPID: row.ppid, StartTicks: row.start, FirstSeenNS: begin.UnixNano()}
			s.records[key] = record
		}
		if transition := row.comm + "/" + category; len(record.Transitions) == 0 || record.Transitions[len(record.Transitions)-1] != transition {
			record.Transitions = append(record.Transitions, transition)
		}
		record.Comm, record.Category, record.LastSeenNS, record.CPUTicks = row.comm, category, begin.UnixNano(), row.ticks
		record.DispatchShell = record.DispatchShell || dispatchShells[pid]
		record.Samples++
		if category == "unreaped" {
			// Counted, never read: it has no PSS and is not a live process.
			s.mu.Unlock()
			result.Counts[category]++
			continue
		}
		pss, err := readPSS(pid)
		if err != nil {
			record.PSSFailures++
			result.PSSFailures++
		} else {
			record.PSSReads++
			record.LastPSS = pss
			record.MaxPSS = max(record.MaxPSS, pss)
			result.PSS[category] += pss
			if columns(category) != category {
				result.PSS[columns(category)] += pss
			}
			result.PSS["total"] += pss
		}
		s.mu.Unlock()
		result.Counts[category]++
		if columns(category) != category {
			result.Counts[columns(category)]++
		}
		result.Counts["total"]++
	}
	result.BeginNS, result.EndNS = begin.UnixNano(), time.Now().UnixNano()
	s.mu.Lock()
	s.samples = append(s.samples, result)
	s.mu.Unlock()
	encoded, _ := json.Marshal(result)
	s.raw.Write(append(encoded, '\n'))
}

func startToolSampler(host int, path string, active time.Duration) (*toolSampler, error) {
	raw, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	s := &toolSampler{host: host, active: active, phase: "setup", records: map[string]*toolProcessRecord{}, stop: make(chan struct{}), stopped: make(chan struct{}), raw: raw}
	go func() {
		defer close(s.stopped)
		for {
			s.sample()
			select {
			case <-s.stop:
				return
			case <-time.After(s.interval()):
			}
		}
	}()
	return s, nil
}

// The active phase may sample faster; every other phase keeps the default.
func (s *toolSampler) interval() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.phase == "active" {
		return s.active
	}
	return toolSampleInterval
}

func (s *toolSampler) setPhase(phase string) { s.mu.Lock(); s.phase = phase; s.mu.Unlock() }
func (s *toolSampler) setTUI(pid int)        { s.mu.Lock(); s.tui = pid; s.mu.Unlock() }

func (s *toolSampler) Stop() error {
	close(s.stop)
	<-s.stopped
	return s.raw.Close()
}

// summary reports observed sample peaks and per-phase medians; the true
// peak between samples, and processes that lived shorter than one sample
// interval, are unobserved.
func (s *toolSampler) summary() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	phases := map[string]any{}
	byPhase := map[string][]toolSample{}
	for _, sample := range s.samples {
		byPhase[sample.Phase] = append(byPhase[sample.Phase], sample)
	}
	for phase, samples := range byPhase {
		peak := samples[0]
		maxCounts := map[string]int{}
		for _, sample := range samples {
			if sample.PSS["total"] > peak.PSS["total"] {
				peak = sample
			}
			for name, count := range sample.Counts {
				maxCounts[name] = max(maxCounts[name], count)
			}
		}
		last := samples[len(samples)-1]
		phases[phase] = map[string]any{"samples": len(samples), "first_begin_unix_ns": samples[0].BeginNS, "last_end_unix_ns": last.EndNS,
			"observed_peak_total_sample": peak, "last_sample": last, "max_observed_counts": maxCounts}
	}
	categories := map[string]map[string]any{}
	records := make([]toolProcessRecord, 0, len(s.records))
	for _, record := range s.records {
		records = append(records, *record)
		entry := categories[record.Category]
		if entry == nil {
			entry = map[string]any{"processes": 0, "max_pss_values": []uint64{}}
			categories[record.Category] = entry
		}
		entry["processes"] = entry["processes"].(int) + 1
		if record.MaxPSS != 0 {
			entry["max_pss_values"] = append(entry["max_pss_values"].([]uint64), record.MaxPSS)
		}
	}
	for _, entry := range categories {
		values := entry["max_pss_values"].([]uint64)
		if len(values) != 0 {
			sorted := append([]uint64{}, values...)
			for i := range sorted {
				for j := i + 1; j < len(sorted); j++ {
					if sorted[j] < sorted[i] {
						sorted[i], sorted[j] = sorted[j], sorted[i]
					}
				}
			}
			entry["median_max_pss_bytes"] = sorted[len(sorted)/2]
			entry["min_max_pss_bytes"], entry["max_max_pss_bytes"] = sorted[0], sorted[len(sorted)-1]
		}
		delete(entry, "max_pss_values")
	}
	var sampleWall int64
	for _, sample := range s.samples {
		sampleWall += sample.EndNS - sample.BeginNS
	}
	return map[string]any{"interval_ns": toolSampleInterval.Nanoseconds(), "active_interval_ns": s.active.Nanoseconds(), "sampling_wall_seconds": float64(sampleWall) / 1e9, "samples": len(s.samples), "phases": phases, "observed_categories": categories, "processes": records}
}

func ioctl(fd uintptr, request uintptr, argument unsafe.Pointer) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(argument)); errno != 0 {
		return errno
	}
	return nil
}

func openPTY(rows, columns uint16) (*os.File, *os.File, error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, err
	}
	var unlock int32
	var number uint32
	if err := errors.Join(ioctl(master.Fd(), syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)), ioctl(master.Fd(), syscall.TIOCGPTN, unsafe.Pointer(&number))); err != nil {
		master.Close()
		return nil, nil, err
	}
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", number), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	size := [4]uint16{rows, columns, 0, 0}
	if err := ioctl(slave.Fd(), syscall.TIOCSWINSZ, unsafe.Pointer(&size)); err != nil {
		master.Close()
		slave.Close()
		return nil, nil, err
	}
	return master, slave, nil
}

// toolTerminal is one real `rui session resume` attached on a PTY.
type toolTerminal struct {
	cmd           *exec.Cmd
	master, slave *os.File
	mu            sync.Mutex
	tail          []byte
	bytes         int
	prompts       int
	drained       chan struct{}
	transcript    *os.File
}

func startToolTerminal(binary, store, session, transcriptPath string) (*toolTerminal, error) {
	master, slave, err := openPTY(50, 100)
	if err != nil {
		return nil, err
	}
	transcript, err := os.OpenFile(transcriptPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		master.Close()
		slave.Close()
		return nil, err
	}
	cmd := exec.Command(binary, "session", "resume", "--store", store, "--", session)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		master.Close()
		slave.Close()
		transcript.Close()
		return nil, err
	}
	t := &toolTerminal{cmd: cmd, master: master, slave: slave, drained: make(chan struct{}), transcript: transcript}
	go func() {
		defer close(t.drained)
		buffer := make([]byte, 64*1024)
		prompt := []byte("\u203a")
		for {
			count, err := master.Read(buffer)
			if count > 0 {
				t.mu.Lock()
				if t.bytes < 16*1024*1024 {
					transcript.Write(buffer[:count])
				}
				t.bytes += count
				t.tail = append(t.tail, buffer[:count]...)
				t.prompts += bytes.Count(t.tail, prompt)
				if len(t.tail) > len(prompt) {
					t.tail = append([]byte{}, t.tail[len(t.tail)-len(prompt)+1:]...)
				}
				t.mu.Unlock()
			}
			if err != nil {
				return
			}
		}
	}()
	return t, nil
}

func (t *toolTerminal) prompted() (int, int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.prompts, t.bytes
}

func (t *toolTerminal) Close(deadline measurement.Deadline) (map[string]any, error) {
	result := map[string]any{}
	_, writeError := t.master.Write([]byte("/exit\n"))
	exited := make(chan error, 1)
	go func() { exited <- t.cmd.Wait() }()
	var waitError error
	select {
	case waitError = <-exited:
	case <-time.After(10 * time.Second):
		waitError = errors.Join(errors.New("TUI did not exit after /exit"), t.cmd.Process.Kill(), <-exited)
	}
	result["exit_code"] = t.cmd.ProcessState.ExitCode()
	t.slave.Close()
	t.master.Close()
	<-t.drained
	_, result["transcript_bytes"] = t.prompted()
	return result, errors.Join(writeError, waitError, t.transcript.Close())
}

func storeUsage(store string) map[string]any {
	entries := map[string]map[string]int64{}
	err := filepath.WalkDir(store, func(path string, entry fs.DirEntry, walkError error) error {
		if walkError != nil || entry.IsDir() {
			return walkError
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(store, path)
		top := strings.SplitN(filepath.ToSlash(relative), "/", 2)[0]
		if entries[top] == nil {
			entries[top] = map[string]int64{}
		}
		entries[top]["files"]++
		entries[top]["apparent_bytes"] += info.Size()
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			entries[top]["allocated_bytes"] += stat.Blocks * 512
		}
		return nil
	})
	result := map[string]any{"entries": entries}
	if err != nil {
		result["error"] = err.Error()
	}
	var files []string
	filepath.WalkDir(store, func(path string, entry fs.DirEntry, walkError error) error {
		if walkError == nil && !entry.IsDir() {
			files = append(files, path)
		}
		return nil
	})
	if len(files) != 0 {
		// fincore reports page-cache residency per file; it is system cache,
		// not process PSS, and is never added to the PSS columns.
		output, err := exec.Command("fincore", append([]string{"--bytes", "--noheadings", "--raw", "--output", "RES,SIZE,FILE"}, files...)...).CombinedOutput()
		result["fincore_raw"] = string(output)
		if err != nil {
			result["fincore_error"] = err.Error()
		}
	}
	return result
}

func meminfo() map[string]uint64 {
	result := map[string]uint64{}
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return result
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		name, rest, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		switch name {
		case "MemFree", "MemAvailable", "Buffers", "Cached", "Dirty", "Writeback", "Shmem", "Active(file)", "Inactive(file)":
			fields := strings.Fields(rest)
			value, _ := strconv.ParseUint(fields[0], 10, 64)
			result[name+"_bytes"] = value * 1024
		}
	}
	return result
}

func toolPoint(name string, store string, host, tui int) map[string]any {
	point := map[string]any{"name": name, "unix_ns": time.Now().UnixNano(), "store": storeUsage(store), "meminfo_system": meminfo()}
	for label, pid := range map[string]int{"host": host, "tui": tui} {
		if pid == 0 {
			continue
		}
		self, children, err := cpuTicks(pid)
		if err != nil {
			point[label+"_cpu_error"] = err.Error()
			continue
		}
		point[label+"_cpu_self_ticks"], point[label+"_cpu_reaped_children_ticks"] = self, children
		if pss, err := readPSS(pid); err == nil {
			point[label+"_pss_bytes"] = pss
		}
	}
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) == nil {
		point["observer_cpu_ns"] = usage.Utime.Nano() + usage.Stime.Nano()
	}
	return point
}

func tickDelta(points []map[string]any, from, to int, field string) (float64, bool) {
	first, ok1 := points[from][field].(uint64)
	second, ok2 := points[to][field].(uint64)
	if !ok1 || !ok2 || second < first {
		return 0, false
	}
	return float64(second-first) / toolClockTicks, true
}

// measureTools runs one coordinated Bash tool turn. Every Session first gets
// ~400 KiB of history through an ordinary Message. One real TUI attaches to
// the coordinator and submits its request; the coordinator's Bash calls run
// the actual `rui session send` for each worker, and every Session, the
// coordinator included, runs exactly one workload call.
func measureTools(binary, output string, sessions int, workload, trace, expectation string, barrier bool, activeInterval time.Duration) (result map[string]any, resultError error) {
	result = map[string]any{"format": "rui-tool-turn-v1", "status": "incomplete", "fixture": true, "sessions": sessions, "workload": workload, "active_capacity": 100,
		"topology": map[string]any{"coordinator_tui": 1, "dispatch_calls_expected": sessions - 1, "workload_calls_expected": sessions}, "instrumented": trace != "", "barrier": barrier, "active_sample_interval_ns": activeInterval.Nanoseconds()}
	if err := measurement.RequireProcessRuntime(); err != nil {
		return result, err
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		return result, err
	}
	directory, err := os.MkdirTemp("", "rui-tool-turn-")
	if err != nil {
		return result, err
	}
	result["artifacts"] = directory
	if err := os.WriteFile(filepath.Join(directory, "run-notes.txt"), []byte("estimated: "+expectation+"\n"), 0o600); err != nil {
		return result, err
	}
	result["expectation"] = expectation
	evidence, err := measurement.EnvironmentEvidence(measurement.NewDeadline(time.Minute), binary, output)
	if err != nil {
		return result, err
	}
	result["measurement_checkout"], result["measurement_revision"] = evidence, evidence["tested_revision"]
	controller, err := os.Executable()
	if err != nil {
		return result, err
	}
	if result["harness_sha256"], err = measurement.SHA256File(controller); err != nil {
		return result, err
	}
	result["argv"] = os.Args
	workspace, err := measurement.RepositoryRoot()
	if err != nil {
		return result, err
	}
	sourceEvidence, err := sessionSourceEvidence(workspace, binary)
	if err != nil {
		return result, err
	}
	for name, value := range sourceEvidence {
		result[name] = value
	}
	home := filepath.Join(directory, "home")
	if err := os.MkdirAll(filepath.Join(home, ".config", "rui"), 0o700); err != nil {
		return result, err
	}
	// Host, Bash tools, TUI and sends share this private HOME, not the user's.
	if err := os.Setenv("HOME", home); err != nil {
		return result, err
	}
	store, err := measurement.CanonicalStore(filepath.Join(directory, "store"))
	if err != nil {
		return result, err
	}
	records := filepath.Join(directory, "records")
	dispatch := filepath.Join(directory, "dispatch")
	seeds := filepath.Join(directory, "seed-scratch")
	for _, path := range []string{records, dispatch, seeds} {
		if err := os.Mkdir(path, 0o700); err != nil {
			return result, err
		}
	}
	barrierDir := ""
	if barrier {
		barrierDir = filepath.Join(directory, "barrier")
		if err := os.Mkdir(barrierDir, 0o700); err != nil {
			return result, err
		}
		if err := syscall.Mkfifo(filepath.Join(barrierDir, "release"), 0o600); err != nil {
			return result, err
		}
	}
	readFile := filepath.Join(directory, "read-fixture.txt")
	readText := toolText("read fixture\n", toolReadBytes, 7)
	if err := os.WriteFile(readFile, readText, 0o600); err != nil {
		return result, err
	}
	readDigest := sha256.Sum256(readText)
	result["read_fixture"] = map[string]any{"path": readFile, "bytes": len(readText), "sha256": hex.EncodeToString(readDigest[:])}
	deadline := measurement.NewDeadline(15 * time.Minute)
	fixture, err := startChildFixture(deadline, 2, 30, 120*time.Second, 1, false, filepath.Join(directory, "provider"), workspace, store,
		"--provider-tool-sessions", strconv.Itoa(sessions), "--provider-tool-workload", workload, "--provider-tool-read-file", readFile, "--provider-tool-dispatch-dir", dispatch, "--provider-tool-barrier", barrierDir)
	if err != nil {
		return result, err
	}
	defer measurement.JoinCleanup(&resultError, fixture.Close)
	host, err := measurement.StartHost(binary, store, fixture.ProviderURL(), 100, filepath.Join(directory, "host-stderr.log"), deadline, "--provider-ca-file", fixture.providerCA)
	if err != nil {
		return result, err
	}
	defer func() {
		exit, err := host.StopWithExit(measurement.TeardownAllowance)
		result["host_exit"] = exit
		resultError = errors.Join(resultError, err)
	}()
	hostPID := host.Cmd.Process.Pid
	result["host_pid"], result["provider_pid"], result["host_ready"] = hostPID, fixture.cmd.Process.Pid, host.Ready
	sampler, err := startToolSampler(hostPID, filepath.Join(directory, "tree-samples.jsonl"), activeInterval)
	if err != nil {
		return result, err
	}
	samplerStopped := false
	defer func() {
		if !samplerStopped {
			resultError = errors.Join(resultError, sampler.Stop())
		}
		result["process_tree"] = sampler.summary()
	}()
	points := []map[string]any{toolPoint("host_started", store, hostPID, 0)}
	defer func() { result["points"] = points }()
	client := measurement.Client{Binary: binary, Store: store, Artifacts: records, Deadline: deadline}
	names := make([]string, sessions)
	for index := range sessions {
		names[index] = provider.ToolSession(sessions, index)
		if err := client.Configure(fmt.Sprintf("configure-%03d", index), names[index], "--tools", "bash", "--permission-mode", "bypass"); err != nil {
			return result, err
		}
	}
	points = append(points, toolPoint("configured", store, hostPID, 0))
	sampler.setPhase("seed")
	seedRows := make([]map[string]any, sessions)
	seedStart := time.Now()
	for index, name := range names {
		text := toolText("seed "+name+"\n", toolSeedBytes, uint64(index)+11)
		path := filepath.Join(seeds, fmt.Sprintf("seed-%03d.txt", index))
		if err := os.WriteFile(path, text, 0o600); err != nil {
			return result, err
		}
		digest := sha256.Sum256(text)
		seedRows[index] = map[string]any{"session": name, "bytes": len(text), "sha256": hex.EncodeToString(digest[:]), "estimated_tokens_bytes_div_4": len(text) / 4}
		key := fmt.Sprintf("seed-%03d", index)
		var answer map[string]any
		if err := measurement.RunJSON(deadline, &answer, binary, "session", "send", "--store", store, "--record", filepath.Join(records, key+".json"), "--key", key, "--session", name, "--text", path); err != nil {
			return result, err
		}
	}
	result["seed"] = map[string]any{"method": "one ordinary `rui session send --text` Message per Session, answered without tools", "token_estimate_method": "bytes/4; no tokenizer was run", "rows": seedRows}
	if _, err := fixture.tool(deadline, "/control/tool-wait-seeded"); err != nil {
		return result, err
	}
	for index := range names {
		if _, err := client.WaitResult(fmt.Sprintf("seed-%03d", index)); err != nil {
			return result, err
		}
	}
	result["seed_seconds"] = time.Since(seedStart).Seconds()
	if err := os.RemoveAll(seeds); err != nil {
		return result, err
	}
	points = append(points, toolPoint("seeded", store, hostPID, 0))
	sampler.setPhase("tui_attach")
	terminal, err := startToolTerminal(binary, store, names[0], filepath.Join(directory, "tui-transcript.raw"))
	if err != nil {
		return result, err
	}
	tuiPID := terminal.cmd.Process.Pid
	sampler.setTUI(tuiPID)
	result["tui_pid"] = tuiPID
	terminalClosed := false
	defer func() {
		if !terminalClosed {
			_, err := terminal.Close(deadline)
			resultError = errors.Join(resultError, err)
		}
	}()
	if err := measurement.WaitFor(deadline, 50*time.Millisecond, "coordinator TUI composer", func() (bool, error) {
		prompts, _ := terminal.prompted()
		return prompts > 0, nil
	}); err != nil {
		return result, err
	}
	if err := deadline.SleepUntil(time.Now().Add(time.Second)); err != nil {
		return result, err
	}
	sampler.setPhase("idle_before")
	if err := deadline.SleepUntil(time.Now().Add(10 * time.Second)); err != nil {
		return result, err
	}
	points = append(points, toolPoint("before_submit", store, hostPID, tuiPID))
	var tracer *exec.Cmd
	if trace != "" {
		tracer = exec.Command(trace, "-f", "-ttt", "-e", "trace=clone,clone3,fork,vfork,execve", "-o", filepath.Join(directory, "host-forks.strace"), "-p", strconv.Itoa(hostPID))
		tracer.Stderr = io.Discard
		if err := tracer.Start(); err != nil {
			return result, err
		}
		defer func() {
			if tracer != nil {
				tracer.Process.Signal(os.Interrupt)
				tracer.Wait()
			}
		}()
		if err := deadline.SleepUntil(time.Now().Add(2 * time.Second)); err != nil {
			return result, err
		}
	}
	sampler.setPhase("active")
	submitted := time.Now()
	result["submit_unix_ns"] = submitted.UnixNano()
	if _, err := terminal.master.Write([]byte("coordinate the tool run\n")); err != nil {
		return result, err
	}
	if barrier {
		facts, release, err := releaseBarrier(deadline, barrierDir, sessions, 60*time.Second)
		result["barrier_release"] = facts
		if err != nil {
			return result, err
		}
		defer release.Close()
	}
	done, err := fixture.tool(deadline, "/control/tool-wait-done")
	result["provider"] = done
	if err != nil {
		return result, err
	}
	result["provider_done_unix_ns"] = time.Now().UnixNano()
	// A fixed tail lets the Host commit the final answers it was just sent.
	if err := deadline.SleepUntil(time.Now().Add(3 * time.Second)); err != nil {
		return result, err
	}
	points = append(points, toolPoint("active_end", store, hostPID, tuiPID))
	sampler.setPhase("verify")
	if tracer != nil {
		tracer.Process.Signal(os.Interrupt)
		result["tracer_exit"] = fmt.Sprint(tracer.Wait())
		tracer = nil
	}
	// Every Session's original request must reach a completed result whose
	// saved answer is exactly the provider's final text. The provider's
	// done count only says it received the continuation.
	originals := make([]map[string]any, sessions)
	var originalFailures []string
	for index, name := range names {
		key := fmt.Sprintf("dispatch-%03d", index)
		if index == 0 {
			coordinator, err := client.Inspect(name)
			if err != nil {
				return result, err
			}
			key = toolCoordinatorKey(coordinator)
		}
		observation, err := client.WaitResult(key)
		if err != nil {
			return result, err
		}
		text, readError := measurement.Run(deadline, binary, "request", "read-result", "--store", store, "--key", key)
		inspection, err := client.Inspect(name)
		if err != nil {
			return result, err
		}
		row := map[string]any{"session": name, "key": key, "result": observation["result"], "answer_bytes": len(text)}
		if index == 0 {
			result["coordinator_inspection"] = inspection
		}
		if failure := toolOriginalFailure(sessions, index, key, inspection, observation, text, readError); failure != nil {
			row["failure"], row["observation"], row["inspection"] = failure.Error(), observation, inspection
			originalFailures = append(originalFailures, failure.Error())
		}
		originals[index] = row
	}
	result["original_requests"] = originals
	sampler.setPhase("idle_after")
	if err := deadline.SleepUntil(time.Now().Add(10 * time.Second)); err != nil {
		return result, err
	}
	points = append(points, toolPoint("idle_after", store, hostPID, tuiPID))
	samplerStopped = true
	if err := sampler.Stop(); err != nil {
		return result, err
	}
	terminalClosed = true
	tui, err := terminal.Close(deadline)
	result["tui"] = tui
	if err != nil {
		return result, err
	}
	result["sample_coverage"] = toolCoverage(sampler, sessions)
	hostCPU, hostOK := tickDelta(points, 3, 4, "host_cpu_self_ticks")
	childCPU, childOK := tickDelta(points, 3, 4, "host_cpu_reaped_children_ticks")
	tuiCPU, tuiOK := tickDelta(points, 3, 4, "tui_cpu_self_ticks")
	activeSeconds := float64(points[4]["unix_ns"].(int64)-points[3]["unix_ns"].(int64)) / 1e9
	completed := done.SucceededCalls + done.FailedCalls
	requests := toolRequestPhases(done.SessionFacts, points[3]["unix_ns"].(int64), points[4]["unix_ns"].(int64))
	inWindow := requests["measured_in_window"] + requests["continuation_in_window"] + requests["seed_in_window"]
	cpu := map[string]any{"window": "before_submit point to active_end point (provider done + 3 s tail)", "window_seconds": activeSeconds,
		"host_self_cpu_seconds": hostCPU, "host_reaped_descendants_cpu_seconds": childCPU, "tui_cpu_seconds": tuiCPU,
		"workload_calls_completed": done.WorkloadCalls, "dispatch_calls_completed": done.DispatchCalls, "model_requests": requests, "model_requests_in_window": inWindow,
		"basis": "Linux utime+stime at 10 ms ticks; reaped descendants include Bash shells, workload children and dispatched sends, inseparably"}
	if hostOK && childOK && tuiOK && completed > 0 {
		cpu["host_self_cpu_seconds_per_workload_call"] = hostCPU / float64(done.WorkloadCalls)
		cpu["host_self_cpu_seconds_per_tool_call_including_dispatch"] = hostCPU / float64(completed)
		cpu["host_self_cpu_seconds_per_model_request_in_window"] = hostCPU / float64(inWindow)
	} else {
		cpu["status"] = "unavailable"
	}
	result["cpu"] = cpu
	result["concurrency"] = toolConcurrency(done, workload)
	release, _ := result["barrier_release"].(map[string]any)
	overlap, _ := result["concurrency"].(map[string]any)["workload"].(map[string]any)["max_overlapping"].(int)
	if failures := append(originalFailures, toolAcceptance(sessions, done, requests, barrier, release, overlap)...); len(failures) != 0 {
		result["acceptance_failures"] = failures
		return result, fmt.Errorf("tool turn not accepted: %d failures, first: %s", len(failures), failures[0])
	}
	result["limits"] = []string{
		"PSS columns are sequential-scan sums of smaps_rollup over the processes read during each sample's [begin, end] span, not simultaneous snapshots; failed reads are counted per sample and omitted from sums; processes shorter than one interval plus scan are missed; the true peak is unobserved",
		"send processes are counted once, as clients, whether they run under a shell or replaced it; Bash = shells, their non-rui children, Host children that replaced their shell with the final command, and Host forks seen before exec; exited, unreaped processes are counted as unreaped, with no PSS read",
		"page cache is system-wide meminfo plus per-file fincore residency; it is not process PSS and is never added to PSS columns",
		"in-shell timestamps use bash $EPOCHREALTIME builtins before each command; no marker follows the command, so end times are not observed and overlap is a lower bound; they exclude fork/exec of the shell itself",
		"fixture/controller excluded from Rui counters; observer CPU is reported separately and not subtracted",
	}
	result["status"] = "passed"
	return result, nil
}

// toolConcurrency derives in-flight counts from in-shell timestamps. A call
// is known alive over [park or start, start + minimum]: its shell exists from
// the park marker, and `sleep 5` cannot finish sooner than 5 s after its start
// marker; other commands get no minimum. The maximum overlap of these
// intervals is a lower bound on calls simultaneously alive. It also reports
// the delay from the provider's tool-call response to each shell's start.
func toolConcurrency(summary provider.ToolSummary, workload string) map[string]any {
	result := map[string]any{"basis": "bash $EPOCHREALTIME park/start markers inside each shell plus the workload's minimum duration (sleep 5: 5 s; otherwise 0); excludes shell fork/exec; a lower bound, not observed end times"}
	type event struct {
		at    int64
		delta int
	}
	for _, kind := range []string{"workload", "dispatch"} {
		minimum := int64(0)
		if kind == "workload" && workload == "sleep" {
			minimum = 5 * int64(time.Second)
		}
		var events []event
		var latencies, parks []float64
		missing := 0
		for _, fact := range summary.SessionFacts {
			for _, output := range fact.Outputs {
				if output.Kind != kind {
					continue
				}
				if output.ShellStartNS == 0 {
					missing++
					continue
				}
				begin := output.ShellStartNS
				if output.ShellParkNS != 0 {
					begin = output.ShellParkNS
					parks = append(parks, float64(output.ShellStartNS-output.ShellParkNS)/1e9)
				}
				events = append(events, event{begin, 1}, event{output.ShellStartNS + minimum, -1})
				latencies = append(latencies, float64(output.ShellStartNS-fact.CallsSentNS)/1e9)
			}
		}
		sort.Slice(events, func(i, j int) bool {
			return events[i].at < events[j].at || events[i].at == events[j].at && events[i].delta < events[j].delta
		})
		current, peak := 0, 0
		for _, item := range events {
			current += item.delta
			peak = max(peak, current)
		}
		sort.Float64s(latencies)
		row := map[string]any{"intervals": len(events) / 2, "missing_markers": missing, "max_overlapping": peak, "minimum_workload_ns": minimum}
		if len(latencies) != 0 {
			row["call_response_to_shell_start_seconds"] = map[string]float64{"min": latencies[0], "median": latencies[len(latencies)/2], "max": latencies[len(latencies)-1]}
		}
		if len(parks) != 0 {
			sort.Float64s(parks)
			row["park_to_start_seconds"] = map[string]float64{"min": parks[0], "median": parks[len(parks)/2], "max": parks[len(parks)-1]}
		}
		result[kind] = row
	}
	return result
}

// releaseBarrier waits until every workload shell has parked, at most wait,
// then releases one line per Session. The writer stays open until the turn
// ends so a late shell still finds its line. A partial release is recorded
// as timed_out and fails toolAcceptance; the turn still runs to the end so
// its evidence is kept.
func releaseBarrier(deadline measurement.Deadline, directory string, sessions int, wait time.Duration) (map[string]any, *os.File, error) {
	begin := time.Now()
	parked := 0
	for {
		entries, err := os.ReadDir(directory)
		if err != nil {
			return nil, nil, err
		}
		parked = len(entries) - 1
		if parked >= sessions || time.Since(begin) > wait {
			break
		}
		if _, err := deadline.Remaining(); err != nil {
			return nil, nil, err
		}
		time.Sleep(5 * time.Millisecond)
	}
	facts := map[string]any{"wait_begin_unix_ns": begin.UnixNano(), "parked_at_release": parked, "expected": sessions, "timed_out": parked < sessions}
	writer, err := os.OpenFile(filepath.Join(directory, "release"), os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return facts, nil, err
	}
	facts["release_unix_ns"] = time.Now().UnixNano()
	if _, err := writer.Write(bytes.Repeat([]byte{'\n'}, sessions)); err != nil {
		writer.Close()
		return facts, nil, err
	}
	return facts, writer, nil
}

// toolCoverage compares processes the sampler saw with the processes the
// turn must have created. Unseen processes have no PSS observation at all.
func toolCoverage(s *toolSampler, sessions int) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen, read := map[string]int{}, map[string]int{}
	for _, record := range s.records {
		var classes []string
		for _, transition := range record.Transitions {
			comm, category, _ := strings.Cut(transition, "/")
			if category == "bash_shell" || category == "send" {
				classes = append(classes, category)
			}
			if record.PPID == s.host && (category == "bash_shell" || category == "bash_exec" || category == "send") {
				classes = append(classes, "host_tool_child")
			}
			if (category == "bash_child" || category == "bash_exec") && (comm == "sleep" || comm == "cat") {
				classes = append(classes, "workload_process")
			}
		}
		slices.Sort(classes)
		for _, class := range slices.Compact(classes) {
			seen[class]++
			if record.PSSReads != 0 {
				read[class]++
			}
		}
	}
	row := func(category string, expected int) map[string]any {
		value := map[string]any{"seen": seen[category], "pss_read": read[category], "expected": expected}
		if expected > 0 {
			value["pss_read_fraction"] = float64(read[category]) / float64(expected)
		}
		return value
	}
	return map[string]any{
		"basis":            "identities (PID+start time) seen in at least one sample, and those with at least one successful PSS read, versus the minimum the turn creates; seen can exceed expected when shells fork subshells. An identity that execs is one identity in every class it showed",
		"bash_shell":       row("bash_shell", 2*sessions-1),
		"host_tool_child":  row("host_tool_child", 2*sessions-1),
		"workload_process": row("workload_process", sessions),
		"send":             row("send", sessions-1),
	}
}

// toolRequestPhases classifies each Session's three provider requests by
// phase and by whether the provider received them inside the CPU window
// [begin, end]. Seeds precede the window; the measured turn should place
// every measured request and continuation inside it.
func toolRequestPhases(facts []provider.ToolSessionFact, begin, end int64) map[string]int {
	result := map[string]int{"seed_in_window": 0, "measured_in_window": 0, "continuation_in_window": 0}
	count := func(phase string, at int64) {
		if at == 0 {
			return
		}
		result[phase+"_total"]++
		if at >= begin && at <= end {
			result[phase+"_in_window"]++
		}
	}
	for _, fact := range facts {
		count("seed", fact.SeedReceivedNS)
		count("measured", fact.MeasuredReceivedNS)
		count("continuation", fact.ContinuationReceivedNS)
	}
	return result
}

// toolCoordinatorKey is the coordinator's one non-seed Message: the request
// the attached TUI submitted.
func toolCoordinatorKey(inspection map[string]any) string {
	messages, _ := inspection["recent_messages"].([]any)
	for _, raw := range messages {
		message, _ := raw.(map[string]any)
		if key, _ := message["message"].(string); key != "" && key != "seed-000" {
			return key
		}
	}
	return ""
}

// toolOriginalFailure accepts one Session only when it has exactly its seed
// and its original request, both completed, the worker request is the
// coordinator's dispatch key, and the saved result is exactly the fixture's
// final answer for that Session.
func toolOriginalFailure(sessions, index int, key string, inspection, observation map[string]any, text []byte, readError error) error {
	name := provider.ToolSession(sessions, index)
	messages, _ := inspection["recent_messages"].([]any)
	outcomes := map[string]any{}
	for _, raw := range messages {
		message, _ := raw.(map[string]any)
		outcomes[fmt.Sprint(message["message"])] = message["outcome"]
	}
	seed := fmt.Sprintf("seed-%03d", index)
	switch {
	case key == "" || index > 0 && key != fmt.Sprintf("dispatch-%03d", index):
		return fmt.Errorf("%s: original request key %q", name, key)
	case len(outcomes) != 2 || outcomes[seed] != "completed" || outcomes[key] != "completed":
		return fmt.Errorf("%s: Messages %v, want %s and %s completed", name, outcomes, seed, key)
	}
	if status, _ := measurement.StringField(observation, "result", "status"); status != "completed" {
		return fmt.Errorf("%s: request %s result %q", name, key, status)
	}
	if want := "tool turn complete " + name; readError != nil || string(text) != want {
		return fmt.Errorf("%s: saved answer %q (%v), want %q", name, text, readError, want)
	}
	return nil
}

// toolAcceptance lists every provider, phase and barrier reason a run must
// not pass. Counts come from validated outputs. The configured barrier mode,
// not the presence of release facts, decides: a barrier run must have
// release facts showing all N shells parked and must reach N overlapping
// intervals; a run without a barrier must have no release facts.
func toolAcceptance(sessions int, done provider.ToolSummary, requests map[string]int, barrier bool, release map[string]any, overlap int) []string {
	var failures []string
	failures = append(failures, done.Errors...)
	if done.Done != sessions || done.WorkloadCalls != sessions || done.DispatchCalls != sessions-1 || done.FailedCalls != 0 || done.SucceededCalls != 2*sessions-1 {
		failures = append(failures, fmt.Sprintf("calls done=%d workload=%d dispatch=%d succeeded=%d failed=%d, want %d sessions and %d succeeded", done.Done, done.WorkloadCalls, done.DispatchCalls, done.SucceededCalls, done.FailedCalls, sessions, 2*sessions-1))
	}
	if requests["seed_in_window"] != 0 || requests["measured_in_window"] != sessions || requests["continuation_in_window"] != sessions {
		failures = append(failures, fmt.Sprintf("model requests outside the CPU window: %v", requests))
	}
	switch {
	case barrier && release == nil:
		failures = append(failures, "barrier run has no release facts")
	case !barrier && release != nil:
		failures = append(failures, "release facts on a run without a barrier")
	case barrier:
		if parked, _ := release["parked_at_release"].(int); parked != sessions || release["timed_out"] != false {
			failures = append(failures, fmt.Sprintf("barrier released %v of %d parked", release["parked_at_release"], sessions))
		}
		if overlap != sessions {
			failures = append(failures, fmt.Sprintf("barrier overlap %d of %d", overlap, sessions))
		}
	}
	return failures
}
