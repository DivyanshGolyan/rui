package measurement

import (
	"errors"
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

func TestParseFootprintRejectsMissingMalformedNonpositiveAndInconsistent(t *testing.T) {
	reports := []string{
		"phys_footprint: 1 MB\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 1.2.3 MB\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 2 MB\nphys_footprint: malformed\n",
		"phys_footprint: 1 MB\nphys_footprint_peak: 2 MB\nphys_footprint: 1 MB\n",
		"phys_footprint: 0 B\nphys_footprint_peak: 1 B\n",
		"phys_footprint: 4 MB\nphys_footprint_peak: 1 KB\n",
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

func TestProcessSamplePortableProjection(t *testing.T) {
	full := ProcessSample{
		RSSBytes: 1, VirtualBytes: 2, CPUUserSeconds: 3, CPUSystemSeconds: 4,
		Threads: 5, LiveDescendantProcesses: 6, OpenDescriptorRows: 7,
		DiskReadBytes: 8, DiskWriteBytes: 9,
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

func TestRepositoryRootFromQualificationModule(t *testing.T) {
	root := t.TempDir()
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
}
