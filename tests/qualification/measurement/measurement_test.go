package measurement

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"
)

func TestModelInstructionsMatchIndependentRequestOracle(t *testing.T) {
	fixtures, err := filepath.Abs("../../integration")
	if err != nil {
		t.Fatal(err)
	}
	workspace := "/workspace/quoted{} \"path\"\\雪\n<&\u2028"
	store, err := CanonicalStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	session := "k7m2qx"
	command := exec.Command("python3", "-c", `
import sys
sys.path.insert(0, sys.argv[1])
from model_fixture import model_instructions
sys.stdout.buffer.write(model_instructions(sys.argv[2] + "\0", store=sys.argv[3], session=sys.argv[4]).encode())
`, fixtures, workspace, store, session)
	// Process arguments cannot carry NUL; cover it inside each oracle instead.
	want, err := command.Output()
	if err != nil {
		var exited *exec.ExitError
		if errors.As(err, &exited) {
			t.Fatalf("independent Python request oracle: %v: %s", err, exited.Stderr)
		}
		t.Fatalf("independent Python request oracle: %v", err)
	}
	if got := ModelInstructions(workspace+"\x00", session); got != string(want) {
		t.Fatalf("Go request instructions differ from independent oracle:\ngot: %q\nwant: %q", got, want)
	}
}

func TestConfigurationSessionRequiresCanonicalAllocatedID(t *testing.T) {
	for _, session := range []string{"k7m2qx", "000000", "zzzzzz", "", "peer/name", "K7M2QX", "abcdefg", "abcde", "abcdei", "abcde\x00"} {
		reply := map[string]any{"answer": map[string]any{"session": session}}
		got, err := ConfigurationSession(reply)
		valid := session == "k7m2qx" || session == "000000" || session == "zzzzzz"
		if (err == nil) != valid || valid && got != session {
			t.Fatalf("configuration Session %q: %q, %v", session, got, err)
		}
	}
	if _, err := ConfigurationSession(map[string]any{"answer": map[string]any{"status": "accepted"}}); err == nil {
		t.Fatal("accepted configuration without allocated ID was accepted")
	}
}

func TestQualificationPublisherProcess(t *testing.T) {
	if os.Getenv("RUI_TEST_QUALIFICATION_CHILD") == "1" {
		status := os.Getenv("RUI_TEST_QUALIFICATION_STATUS")
		output := os.Getenv("RUI_TEST_QUALIFICATION_OUTPUT")
		result := map[string]any{"status": status, "marker": "published"}
		if err := PublishQualification(output, result); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		os.Exit(QualificationExitCode(result))
	}
	for _, test := range []struct {
		status string
		code   int
	}{
		{status: "passed", code: 0},
		{status: "smoke_passed", code: 0},
		{status: "failed", code: 1},
		{status: "incomplete", code: 1},
		{status: "target_miss", code: 1},
		{status: "", code: 1},
	} {
		t.Run(test.status, func(t *testing.T) {
			output := filepath.Join(t.TempDir(), "result.json")
			command := exec.Command(os.Args[0], "-test.run=^TestQualificationPublisherProcess$")
			command.Env = append(os.Environ(), "RUI_TEST_QUALIFICATION_CHILD=1", "RUI_TEST_QUALIFICATION_STATUS="+test.status, "RUI_TEST_QUALIFICATION_OUTPUT="+output)
			err := command.Run()
			if got := command.ProcessState.ExitCode(); got != test.code {
				t.Fatalf("exit code = %d, want %d: %v", got, test.code, err)
			}
			contents, readErr := os.ReadFile(output)
			if readErr != nil {
				t.Fatalf("published result unreadable: %v", readErr)
			}
			var result map[string]any
			if err := json.Unmarshal(contents, &result); err != nil {
				t.Fatalf("published result invalid: %v", err)
			}
			if result["status"] != test.status || result["marker"] != "published" {
				t.Fatalf("published result = %v", result)
			}
		})
	}
}

type closeErrorReader struct {
	io.Reader
	err error
}

func (r closeErrorReader) Close() error {
	return r.err
}

func exitedTestHost(t *testing.T, stdout io.ReadCloser) *Host {
	t.Helper()
	stderr, err := os.Create(filepath.Join(t.TempDir(), "stderr"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", "-c", "exit 7")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	host := &Host{Cmd: cmd, Stdout: stdout, Stderr: stderr}
	if err := host.wait(); err == nil {
		t.Fatal("nonzero subprocess unexpectedly succeeded")
	}
	return host
}

func TestStopWithExitSeparatesExpectedStatus(t *testing.T) {
	host := exitedTestHost(t, io.NopCloser(strings.NewReader("")))
	status, cleanupError := host.StopWithExit(time.Second)
	if cleanupError != nil || !status.Exited || status.Code != 7 || status.StopSignalSent {
		t.Fatalf("status = %+v cleanup = %v", status, cleanupError)
	}
}

func TestStopWithExitPreservesCleanupFailureBesideExpectedStatus(t *testing.T) {
	sentinel := errors.New("stdout close failed")
	host := exitedTestHost(t, closeErrorReader{Reader: strings.NewReader(""), err: sentinel})
	status, cleanupError := host.StopWithExit(time.Second)
	if !status.Exited || status.Code != 7 || !errors.Is(cleanupError, sentinel) {
		t.Fatalf("status = %+v cleanup = %v", status, cleanupError)
	}
}

func TestParseFootprintMixedUnitRounding(t *testing.T) {
	result, err := ParseFootprint("phys_footprint: 2 MB\nphys_footprint_peak: 2047 KB\n")
	if err != nil {
		t.Fatal(err)
	}
	if result.PhysicalBytes != 2*1024*1024 || result.LifetimePeakBytes != 2047*1024 {
		t.Fatalf("unexpected counters: %+v", result)
	}
}

func TestParseFootprintIntegralBytesAreExact(t *testing.T) {
	result, err := ParseFootprint("phys_footprint: 1 B\nphys_footprint_peak: 1 B\n")
	if err != nil {
		t.Fatal(err)
	}
	if result.PhysicalTolerance != 0 || result.LifetimePeakTolerance != 0 {
		t.Fatalf("byte counters were not exact: %+v", result)
	}
}

func TestClassifyFootprintDistinguishesPassMissAndRoundedUncertainty(t *testing.T) {
	target := uint64(100)
	tests := []struct {
		footprint Footprint
		status    string
		lower     uint64
		upper     uint64
	}{
		{Footprint{LifetimePeakBytes: 99, LifetimePeakTolerance: 1}, "passed", 98, 100},
		{Footprint{LifetimePeakBytes: 102, LifetimePeakTolerance: 1}, "target_miss", 101, 103},
		{Footprint{LifetimePeakBytes: 100, LifetimePeakTolerance: 1}, "unavailable", 99, 101},
		{Footprint{LifetimePeakBytes: ^uint64(0), LifetimePeakTolerance: 1}, "unavailable", ^uint64(0) - 1, ^uint64(0)},
	}
	for _, test := range tests {
		got := ClassifyFootprint(test.footprint, target)
		if got.Status != test.status || got.LowerBoundBytes != test.lower || got.UpperBoundBytes != test.upper {
			t.Errorf("ClassifyFootprint(%+v) = %+v", test.footprint, got)
		}
	}
}

func TestSampleValidityDoesNotTurnMissingSamplesIntoZeroEvidence(t *testing.T) {
	var validity SampleValidity
	validity.Record(errors.New("counter unavailable"))
	if validity.Status() != "unavailable" || validity.Attempts != 1 || validity.Succeeded != 0 || validity.Failed != 1 || validity.FirstError == "" {
		t.Fatalf("failed sample validity = %+v", validity)
	}
	validity.Record(nil)
	if validity.Status() != "unavailable" || validity.Succeeded != 1 || validity.Failed != 1 {
		t.Fatalf("mixed sample validity = %+v", validity)
	}
	validity = SampleValidity{}
	validity.Record(nil)
	if validity.Status() != "diagnostic" {
		t.Fatalf("complete sample validity = %+v", validity)
	}
}

func TestParseFootprintRejectsMissingMalformedNonpositiveAndInconsistent(t *testing.T) {
	reports := []string{
		"phys_footprint: 1 MB\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 1.2.3 MB\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 2 MB\nphys_footprint: malformed\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 2 MB\nphys_footprint: 1 MB\n",
		"phys_footprint: 0 B\nphys_footprint_peak: 1 B\n",
		"phys_footprint: 4 MB\nphys_footprint_peak: 1 KB\n",
		"phys_footprint: 5201 KB\nphys_footprint_peak: 5057 KB\n",
	}
	for _, report := range reports {
		if _, err := ParseFootprint(report); err == nil {
			t.Fatalf("accepted invalid report %q", report)
		}
	}
}

func TestCheckedCPUDelta(t *testing.T) {
	delta, err := CheckedCPUDelta(1.25, 2.75)
	if err != nil || delta != 1.5 {
		t.Fatalf("unexpected delta %.3f: %v", delta, err)
	}
	if _, err := CheckedCPUDelta(2, 1); err == nil {
		t.Fatal("accepted a decreasing CPU counter")
	}
}

func TestSleepUntilRechecksSerializedWallPostcondition(t *testing.T) {
	base := time.Unix(0, 0)
	readings := []time.Time{
		base.Add(90 * time.Second),
		base.Add(85 * time.Second),
		base.Add(100 * time.Second),
	}
	index := 0
	now := func() time.Time {
		if index >= len(readings) {
			t.Fatal("wall clock read past scripted values")
		}
		value := readings[index]
		index++
		return value
	}
	var sleeps []time.Duration
	err := sleepUntil(
		base.Add(100*time.Second),
		now,
		func(delay time.Duration) { sleeps = append(sleeps, delay) },
		func() (time.Duration, error) { return time.Minute, nil },
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []time.Duration{10 * time.Second, 15 * time.Second}
	if len(sleeps) != len(want) {
		t.Fatalf("sleep requests = %v, want %v", sleeps, want)
	}
	for index := range want {
		if sleeps[index] != want[index] {
			t.Fatalf("sleep request %d = %v, want %v", index, sleeps[index], want[index])
		}
	}
}

func TestSleepUntilBoundsRepeatedBackwardWallMovementByDeadline(t *testing.T) {
	base := time.Unix(0, 0)
	readings := []time.Time{
		base.Add(90 * time.Second),
		base.Add(85 * time.Second),
		base.Add(80 * time.Second),
	}
	readIndex := 0
	budgets := []time.Duration{30 * time.Second, 20 * time.Second, 10 * time.Second}
	budgetIndex := 0
	var sleeps []time.Duration
	err := sleepUntil(
		base.Add(100*time.Second),
		func() time.Time {
			value := readings[readIndex]
			readIndex++
			return value
		},
		func(delay time.Duration) { sleeps = append(sleeps, delay) },
		func() (time.Duration, error) {
			value := budgets[budgetIndex]
			budgetIndex++
			return value, nil
		},
	)
	if err == nil || !strings.Contains(err.Error(), "scheduled observation exceeds run-wide deadline") {
		t.Fatalf("error = %v", err)
	}
	want := []time.Duration{10 * time.Second, 15 * time.Second}
	if len(sleeps) != len(want) {
		t.Fatalf("sleep requests = %v, want %v", sleeps, want)
	}
	for index := range want {
		if sleeps[index] != want[index] {
			t.Fatalf("sleep request %d = %v, want %v", index, sleeps[index], want[index])
		}
	}
}

func TestSleepUntilHandlesAlreadyReachedForwardJumpAndDeadline(t *testing.T) {
	base := time.Unix(0, 0)
	tests := []struct {
		name      string
		readings  []time.Time
		remaining time.Duration
		wantSleep []time.Duration
		wantError string
	}{
		{name: "already reached", readings: []time.Time{base.Add(100 * time.Second)}},
		{name: "forward jump", readings: []time.Time{base.Add(90 * time.Second), base.Add(110 * time.Second)}, remaining: time.Minute, wantSleep: []time.Duration{10 * time.Second}},
		{name: "deadline", readings: []time.Time{base.Add(90 * time.Second)}, remaining: 5 * time.Second, wantError: "scheduled observation exceeds run-wide deadline"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			index := 0
			now := func() time.Time {
				value := test.readings[index]
				index++
				return value
			}
			var sleeps []time.Duration
			err := sleepUntil(
				base.Add(100*time.Second),
				now,
				func(delay time.Duration) { sleeps = append(sleeps, delay) },
				func() (time.Duration, error) { return test.remaining, nil },
			)
			if test.wantError == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("error = %v, want containing %q", err, test.wantError)
			}
			if len(sleeps) != len(test.wantSleep) {
				t.Fatalf("sleep requests = %v, want %v", sleeps, test.wantSleep)
			}
			for index := range test.wantSleep {
				if sleeps[index] != test.wantSleep[index] {
					t.Fatalf("sleep request %d = %v, want %v", index, sleeps[index], test.wantSleep[index])
				}
			}
		})
	}
}

func TestFactLogWriteReportsClosedArtifact(t *testing.T) {
	log, err := NewFactLog(filepath.Join(t.TempDir(), "facts.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := log.Close(); err != nil {
		t.Fatal(err)
	}
	if err := log.Write("after_close", map[string]any{}); err == nil {
		t.Fatal("write to closed fact log unexpectedly succeeded")
	}
}

func TestJoinCleanupPreservesWorkAndCleanupFailures(t *testing.T) {
	workError := errors.New("work")
	cleanupError := errors.New("cleanup")
	result := error(workError)
	calls := 0
	JoinCleanup(&result, func() error {
		calls++
		return cleanupError
	})
	if calls != 1 || !errors.Is(result, workError) || !errors.Is(result, cleanupError) {
		t.Fatalf("joined error = %v, calls=%d", result, calls)
	}
	result = nil
	JoinCleanup(&result, func() error { return cleanupError })
	if !errors.Is(result, cleanupError) {
		t.Fatalf("nil work did not retain cleanup error: %v", result)
	}
}

type shortWriter struct{}

func (shortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }

func TestWriteAllRejectsShortPublication(t *testing.T) {
	if err := WriteAll(shortWriter{}, []byte("evidence")); !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("short write = %v", err)
	}
}

func TestRuntimeManifestPropagatesPhysicalMemoryFailure(t *testing.T) {
	original := readVirtualMemory
	defer func() { readVirtualMemory = original }()
	sentinel := errors.New("virtual memory unavailable")
	readVirtualMemory = func() (*mem.VirtualMemoryStat, error) { return nil, sentinel }
	manifest, err := RuntimeManifest()
	if !errors.Is(err, sentinel) || manifest != nil {
		t.Fatalf("manifest=%v error=%v", manifest, err)
	}
}

func TestRequireGoRuntimeAcceptsPinnedRuntimeOnEveryOS(t *testing.T) {
	if err := RequireGoRuntime(); err != nil {
		t.Fatalf("RequireGoRuntime() on %s = %v", runtime.GOOS, err)
	}
}

func TestSamplePortableProcessReadsCurrentProcess(t *testing.T) {
	target, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	sample, err := SamplePortableProcess(target)
	if err != nil {
		t.Fatal(err)
	}
	if sample.RSSBytes == 0 || sample.Threads < 1 || sample.OpenDescriptors < 1 {
		t.Fatalf("incomplete portable sample: %+v", sample)
	}
}

type failingDescriptorCounters struct{ *process.Process }

func (failingDescriptorCounters) NumFDs() (int32, error) {
	return 0, errors.New("descriptor query failed")
}

func (failingDescriptorCounters) IOCounters() (*process.IOCountersStat, error) {
	return &process.IOCountersStat{DiskReadBytes: 1234, DiskWriteBytes: 5678}, nil
}

func TestCoreSamplingRetainsCountersOnBothSidesOfFailure(t *testing.T) {
	target, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	sample, err := sampleProcessCore(failingDescriptorCounters{target})
	if err == nil || sample.RSSBytes == 0 || sample.Threads < 1 || sample.DiskReadBytes != 1234 || sample.DiskWriteBytes != 5678 || strings.Join(sample.UnavailableCounters, ",") != "descriptors" {
		t.Fatalf("partial core sample=%+v err=%v", sample, err)
	}
}

func TestDarwinSampleRetainsIndependentEvidenceOnFailure(t *testing.T) {
	target, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"command", "parse", "capture", "command+capture", "lsof"} {
		t.Run(failure, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "footprint.txt")
			if strings.Contains(failure, "capture") {
				path = filepath.Join(path, "missing", "footprint.txt")
			}
			report := "phys_footprint: 1258291 B\nphys_footprint_peak: 1507328 B\n"
			if failure == "parse" {
				report = "phys_footprint: 5201 KB\nphys_footprint_peak: 5057 KB\n"
			}
			cause := errors.New("injected " + failure)
			sample, sampleError := sampleDarwinProcess(target, ProcessSample{RSSBytes: 1234, CPUUserSeconds: 2.5}, path, func(command *exec.Cmd) ([]byte, error) {
				if command.Path == "/usr/bin/footprint" {
					if strings.Contains(failure, "command") {
						return []byte(report), cause
					}
					return []byte(report), nil
				}
				return []byte("partial descriptor report"), cause
			})
			if sampleError == nil || sample.RSSBytes != 1234 || sample.CPUUserSeconds != 2.5 {
				t.Fatalf("lost partial sample: %+v err=%v", sample, sampleError)
			}
			if strings.Contains(failure, "command") || failure == "lsof" {
				if !errors.Is(sampleError, cause) {
					t.Fatalf("lost original error: %v", sampleError)
				}
			}
			if !strings.Contains(failure, "capture") {
				raw, err := os.ReadFile(path)
				if err != nil || string(raw) != report {
					t.Fatalf("raw failed observation lost: %q err=%v", raw, err)
				}
				capture := sample.FootprintCapture
				wantCommand := fmt.Sprintf("/usr/bin/footprint -f bytes -p %d", target.Pid)
				if capture.PID != target.Pid || capture.ProcessStartUnixMS <= 0 || !capture.IdentityUnchanged || capture.BeginUnixNS <= 0 || capture.EndUnixNS < capture.BeginUnixNS || strings.Join(capture.Command, " ") != wantCommand || capture.RawPath != path || capture.Error == "" {
					t.Fatalf("missing capture provenance: %+v", capture)
				}
			}
			if failure == "lsof" && sample.Footprint.LifetimePeakBytes != 1507328 {
				t.Fatalf("descriptor failure erased valid footprint: %+v", sample)
			}
		})
	}
}

func TestDarwinSampleRejectsTargetRetirementDuringCapture(t *testing.T) {
	child := exec.Command("sleep", "10")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		// Kill is expected to report an already retired process after the probe.
		_ = child.Process.Kill()
		_ = child.Wait()
	}()
	target, err := process.NewProcess(int32(child.Process.Pid))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "footprint.txt")
	sample, err := sampleDarwinProcess(target, ProcessSample{RSSBytes: 1000}, path, func(*exec.Cmd) ([]byte, error) {
		if err := child.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		_ = child.Wait()
		return []byte("phys_footprint: 100 B\nphys_footprint_peak: 200 B\n"), nil
	})
	if err == nil || sample.Footprint.LifetimePeakBytes != 0 || sample.FootprintCapture.IdentityUnchanged || sample.RSSBytes != 1000 {
		t.Fatalf("retired identity accepted or partial sample lost: %+v err=%v", sample, err)
	}
}

func TestProcessSamplePortableProjection(t *testing.T) {
	full := ProcessSample{
		RSSBytes: 1, VirtualBytes: 2, CPUUserSeconds: 3, CPUSystemSeconds: 4,
		Threads: 5, LiveDescendantProcesses: 6, OpenDescriptorRows: 70,
		OpenDescriptors: 7, DiskReadBytes: 8, DiskWriteBytes: 9,
	}
	got := full.Portable()
	want := PortableProcessSample{
		RSSBytes: 1, VirtualBytes: 2, CPUUserSeconds: 3, CPUSystemSeconds: 4,
		Threads: 5, LiveDescendantProcesses: 6, OpenDescriptors: 7,
		DiskReadBytes: 8, DiskWriteBytes: 9,
	}
	if got != want {
		t.Fatalf("Portable() = %+v, want %+v", got, want)
	}
}

func TestCanonicalStoreUsesHostReadiness(t *testing.T) {
	host := &Host{Ready: map[string]string{"store": "/private/var/folders/x/store"}}
	got, err := host.CanonicalStore()
	if err != nil || got != "/private/var/folders/x/store" {
		t.Fatalf("CanonicalStore() = %q, %v", got, err)
	}
}

func TestCanonicalStoreRejectsMissingReadiness(t *testing.T) {
	cases := []*Host{nil, {}, {Ready: map[string]string{}}, {Ready: map[string]string{"store": ""}}}
	for _, host := range cases {
		if _, err := host.CanonicalStore(); err == nil {
			t.Fatalf("CanonicalStore(%+v) succeeded", host)
		}
	}
}

func TestCanonicalStoreDoesNotUseUnresolvedTempDirJoin(t *testing.T) {
	dir := t.TempDir()
	joined := filepath.Join(dir, "store")
	if err := os.Mkdir(joined, 0o700); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(joined)
	if err != nil {
		t.Fatal(err)
	}
	if canonical == joined {
		t.Skip("this platform's TempDir is already the canonical Store selector")
	}
	host := &Host{Ready: map[string]string{"store": canonical}}
	got, err := host.CanonicalStore()
	if err != nil {
		t.Fatal(err)
	}
	if got != canonical {
		t.Fatalf("CanonicalStore() = %q, want Host readiness %q", got, canonical)
	}
	if got == joined {
		t.Fatalf("CanonicalStore() used the unresolved join %q", joined)
	}
}

func TestRepositoryRootFromQualificationModule(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	module := filepath.Join(root, "tests", "qualification")
	if err := os.MkdirAll(module, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(module, "go.mod"), []byte("module fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(module)
	got, err := RepositoryRoot()
	if err != nil || got != root {
		t.Fatalf("RepositoryRoot() = %q, %v; want %q", got, err, root)
	}
	t.Chdir(root)
	got, err = RepositoryRoot()
	if err != nil || got != root {
		t.Fatalf("RepositoryRoot() from root = %q, %v; want %q", got, err, root)
	}
	alias := filepath.Join(t.TempDir(), "source-alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	moduleAlias := filepath.Join(t.TempDir(), "module-alias")
	if err := os.Symlink(module, moduleAlias); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{filepath.Join(alias, "tests", "qualification"), alias, moduleAlias} {
		t.Chdir(directory)
		t.Setenv("PWD", directory)
		got, err = RepositoryRoot()
		if err != nil || got != root {
			t.Fatalf("RepositoryRoot() from alias %q = %q, %v; want canonical Workspace %q", directory, got, err, root)
		}
	}
}

func TestQualificationStatusRequiresEvidenceAndPreservesPrecedence(t *testing.T) {
	if got := QualificationStatus(nil, []map[string]any{}); got != "incomplete" {
		t.Fatalf("empty evidence = %s", got)
	}
	statuses := []string{"passed", "target_miss", "incomplete", "failed"}
	for left, a := range statuses {
		for right, b := range statuses {
			want := a
			if right > left {
				want = b
			}
			if got := QualificationStatus(nil, []map[string]any{{"status": a}}, []map[string]any{{"status": b}}); got != want {
				t.Errorf("%s + %s = %s, want %s", a, b, got, want)
			}
		}
		for _, bad := range []map[string]any{nil, {}, {"status": nil}, {"status": "unavailable"}, {"status": "unknown"}, {"status": 0}} {
			for _, rows := range [][]map[string]any{{bad, {"status": a}}, {{"status": a}, bad}} {
				if got := QualificationStatus(rows); got != "failed" {
					t.Errorf("invalid evidence reduced to %s", got)
				}
			}
		}
	}
}

func TestCanonicalStoreResolvesExistingPrefixAndKeepsMissingLeaf(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "real"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	got, err := CanonicalStore(filepath.Join(root, "link", "store"))
	if err != nil || got != filepath.Join(root, "real", "store") {
		t.Fatalf("missing leaf = %q, %v", got, err)
	}
	if err := os.Mkdir(filepath.Join(root, "real", "store"), 0o700); err != nil {
		t.Fatal(err)
	}
	got, err = CanonicalStore(filepath.Join(root, "link", "store"))
	if err != nil || got != filepath.Join(root, "real", "store") {
		t.Fatalf("existing Store = %q, %v", got, err)
	}
}
