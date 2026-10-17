"""Temporary hosted diagnostic: no qualification or product changes."""
import importlib
import json
import os
import pathlib
import sys
import traceback

READ_OBSERVATION = r'''
#ifdef __APPLE__
static unsigned long input_total = 0, ctrl_u = 0, line_feed = 0, command_matches = 0;
static size_t command_offset = 0;
static void report_input(void) {
    if (!input_total) return;
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "INPUT total=%lu ctrl_u=%lu lf=%lu command=%lu\n",
        input_total, ctrl_u, line_feed, command_matches);
    record(buffer);
}
__attribute__((constructor)) static void register_input_report(void) { atexit(report_input); }
static ssize_t observed_read(int fd, void *bytes, size_t count) {
    ssize_t result = read(fd, bytes, count);
    if (fd == 0 && result > 0) {
        const char *command = "/configure --permission-mode ask\n";
        for (ssize_t i = 0; i < result; ++i) {
            unsigned char byte = ((unsigned char *)bytes)[i];
            ++input_total;
            if (byte == 21) { ++ctrl_u; report_input(); }
            if (byte == '\n') { ++line_feed; report_input(); }
            command_offset = byte == command[command_offset] ? command_offset + 1 : (byte == command[0] ? 1 : 0);
            if (!command[command_offset]) { ++command_matches; command_offset = 0; report_input(); }
            if (input_total % 1024 == 0) report_input();
        }
    }
    return result;
}
INTERPOSE(observed_read, read)
#endif
'''


def run(mode):
    module = importlib.import_module("terminal_restoration_integration" if mode == "old" else "terminal_restoration_corrected")
    module.PROBE += READ_OBSERVATION
    roots = []
    original_root = module.canonical_fixture_root
    def remember(raw):
        root = original_root(raw)
        roots.append(root)
        return root
    module.canonical_fixture_root = remember
    failure = None
    try:
        module.main("renderer-backpressure")
    except BaseException as error:
        failure = repr(error)
        traceback.print_exc()
    finally:
        for root in roots:
            log = root / "renderer-backpressure.log"
            if log.exists():
                print("EXACT PROBE OBSERVATIONS\n" + log.read_text(), flush=True)
    print(json.dumps({"mode": mode, "failure": failure}), flush=True)
    if mode == "new" and failure is not None:
        raise RuntimeError("corrected witness failed: " + failure)
    if mode == "mutation" and (failure is None or "main-screen command return" not in failure):
        raise RuntimeError("mutation did not fail intended command return assertion: " + str(failure))
