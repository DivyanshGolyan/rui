"""Focused, offline tests for the shared committed-screen observer."""
import pathlib
import subprocess
import sys
import unittest

import host_process

from terminal_screen import ScreenCapture, SgrStream, assert_details_unavailable


class SgrAdapterTests(unittest.TestCase):
    def test_protocol_translation_is_streaming_and_keeps_other_sequences(self):
        raw = ("ordinary:5 "
               "\x1b[1;38:5:123;48:5:234mX"
               "\x1b[38:2:12:34:56;48:2::78:90:123mY"
               "\x1b]8;;https://example.invalid/a:5:b\x1b\\link\x1b]8;;\x1b\\"
               "\x1b[2;4H\x1b[?25l\x1b[38:2:5H"
               "\x1b[0m")
        expected = ("ordinary:5 "
                    "\x1b[1;38;5;123;48;5;234mX"
                    "\x1b[38;2;12;34;56;48;2;78;90;123mY"
                    "\x1b]8;;https://example.invalid/a:5:b\x1b\\link\x1b]8;;\x1b\\"
                    "\x1b[2;4H\x1b[?25l\x1b[38:2:5H"
                    "\x1b[0m")
        for split in range(len(raw) + 1):
            adapter = SgrStream()
            self.assertEqual(expected, adapter.feed(raw[:split]) + adapter.feed(raw[split:]), split)
        adapter = SgrStream()
        self.assertEqual(expected, "".join(adapter.feed(char) for char in raw))
        self.assertIn("38:5:123", raw)  # caller's input is immutable

    def test_osc_payload_and_unknown_colon_sgr_are_unchanged(self):
        raw = "\x1b]8;;x\x1b[38:5:123m:literal\x1b\\\x1b[4:3mtext"
        adapter = SgrStream()
        self.assertEqual(raw, "".join(adapter.feed(char) for char in raw))

    def test_unbounded_csi_is_rejected(self):
        adapter = SgrStream()
        with self.assertRaisesRegex(AssertionError, "unbounded terminal CSI"):
            adapter.feed("\x1b[" + "1" * adapter.MAX_CSI)


class ScreenCaptureTests(unittest.TestCase):
    def test_private_dsr_fragmentation_keeps_normal_dsr_csi_and_osc(self):
        raw = ("\x1b[?2026h\x1b[1;1HX\x1b[5n\x1b[?996n"
               "\x1b[6n\x1b]0;observer-title\x07\x1b[2;3HY\x1b[?2026l").encode()
        for split in range(len(raw) + 1):
            capture = ScreenCapture(20, 4)
            replies = []
            capture.screen.write_process_input = replies.append
            capture.feed(raw[:split])
            capture.feed(raw[split:])
            self.assertEqual(["\x1b[0n", "\x1b[1;2R"], replies, split)
            self.assertEqual("X", capture.screen.display[0].rstrip(), split)
            self.assertEqual("  Y", capture.screen.display[1].rstrip(), split)
            self.assertEqual("observer-title", capture.screen.title, split)
            self.assertEqual((3, 1), (capture.screen.cursor.x, capture.screen.cursor.y), split)
            self.assertEqual(1, capture.generation, split)
        capture = ScreenCapture(20, 4)
        replies = []
        capture.screen.write_process_input = replies.append
        for byte in raw:
            capture.feed(bytes([byte]))
        self.assertEqual(["\x1b[0n", "\x1b[1;2R"], replies)
        self.assertEqual("  Y", capture.screen.display[1].rstrip())

    def test_split_indexed_and_rgb_frame_preserves_exact_draft_cursor_and_styles(self):
        frame = ("\x1b[?2026h\x1b[2J\x1b[2;1H"
                 " › \x1b[38:5:123;48:5:234m/upgrade"
                 "\x1b[38:2:12:34:56;48:2:78:90:123mXYQZ"
                 "\x1b[0m\x1b[2;15H\x1b[?2026l").encode()
        for split in range(len(frame) + 1):
            capture = ScreenCapture(80, 4)
            capture.feed(frame[:split])
            capture.feed(frame[split:])
            self.assertTrue(capture.draft("/upgradeXYQZ", 14, prompt=" › "), split)
            self.assertFalse(capture.draft("/upgradeXYQZ", 13, prompt=" › "), split)
            self.assertFalse(capture.draft("/upgradeXYQ", 14, prompt=" › "), split)
            self.assertEqual((14, 1), (capture.screen.cursor.x, capture.screen.cursor.y))
            self.assertEqual(" › /upgradeXYQZ", capture.screen.display[1].rstrip())
            self.assertEqual("0c2238", capture.style("XYQZ").fg)
            self.assertEqual("4e5a7b", capture.style("XYQZ").bg)
            self.assertEqual(capture.style("/upgrade").fg, "87ffff")
            self.assertEqual(capture.style("/upgrade").bg, "1c1c1c")

    def test_zero_width_marks_keep_the_complete_title_and_following_cells(self):
        frame = ("\x1b[?2026h\x1b[1;1H"
                 " रुई rui  /workspace\x1b[2;1H"
                 "e\u0301\u0327 next\x1b[3;1H"
                 "plain\x1b[4;4H\x1b[?2026l").encode()
        for split in range(len(frame) + 1):
            capture = ScreenCapture(80, 4)
            capture.feed(frame[:split])
            capture.feed(frame[split:])
            self.assertEqual(" रुई rui  /workspace", capture.screen.display[0].rstrip(), split)
            self.assertEqual("ȩ́ next", capture.screen.display[1].rstrip(), split)
            self.assertEqual("plain", capture.screen.display[2].rstrip(), split)
            self.assertEqual((3, 3), (capture.screen.cursor.x, capture.screen.cursor.y), split)
        self.assertEqual("रु", capture.completed_cells[0][1].data)
        self.assertEqual("ई", capture.completed_cells[0][2].data)
        self.assertEqual("r", capture.completed_cells[0][4].data)
        leading = ScreenCapture(80, 2)
        leading.feed("\x1b[?2026h\u0941plain\x1b[?2026l".encode())
        self.assertEqual("plain", leading.screen.display[0].rstrip())

    def test_variation_selector_keeps_wide_cells_and_following_erasure(self):
        frame = ("\x1b[?2026h\x1b[1;1H"
                 " › Type a task to start a Session\x1b[1;4H"
                 "A❤️B\x1b[38:5:249m" + " " * 26 +
                 "\x1b[1;8H\x1b[?2026l").encode()
        retry = ("\x1b[?2026h\x1b[1;4H/upgrade"
                 "\x1b[1;12H\x1b[?2026l").encode()
        for split in range(len(frame) + 1):
            capture = ScreenCapture(80, 2)
            capture.feed(frame[:split])
            capture.feed(frame[split:])
            self.assertEqual(" › A❤️B", capture.screen.display[0].rstrip(), split)
            self.assertEqual((7, 0), (capture.screen.cursor.x, capture.screen.cursor.y), split)
            self.assertEqual("A", capture.completed_cells[0][3].data, split)
            self.assertEqual("❤️", capture.completed_cells[0][4].data, split)
            self.assertEqual("", capture.completed_cells[0][5].data, split)
            self.assertEqual("B", capture.completed_cells[0][6].data, split)
            self.assertTrue(all(cell.data == " " for cell in capture.completed_cells[0][7:33]), split)
            capture.feed(retry)
            self.assertEqual(" › /upgrade", capture.screen.display[0].rstrip(), split)
            self.assertEqual((11, 0), (capture.screen.cursor.x, capture.screen.cursor.y), split)

    def test_mark_after_a_wide_cell_keeps_its_owner_and_style(self):
        capture = ScreenCapture(80, 2)
        capture.feed("\x1b[?2026h\x1b[31m界\x1b[32m\u0301X\x1b[?2026l".encode())
        self.assertEqual("界́X", capture.screen.display[0].rstrip())
        self.assertEqual("界́", capture.completed_cells[0][0].data)
        self.assertEqual("red", capture.completed_cells[0][0].fg)
        self.assertEqual("", capture.completed_cells[0][1].data)
        self.assertEqual("X", capture.completed_cells[0][2].data)
        self.assertEqual("green", capture.completed_cells[0][2].fg)
        self.assertEqual((3, 0), (capture.screen.cursor.x, capture.screen.cursor.y))

    def test_non_mark_zero_width_character_keeps_stock_draw_boundary(self):
        capture = ScreenCapture(80, 2)
        capture.feed("\x1b[?2026hbefore\u200bdiscarded\x1b[?2026l".encode())
        self.assertEqual("before", capture.screen.display[0].rstrip())

    def test_osc8_and_literal_colons_survive_and_frame_is_coalesced(self):
        capture = ScreenCapture(80, 4)
        raw = ("\x1b[?2026h\x1b[1;1H\x1b[38:5:123m"
               "first:5\x1b[?2026l"
               "\x1b[?2026h\x1b[2;1H"
               "\x1b]8;;https://example.invalid/a:5\x1b\\"
               "link:ok\x1b]8;;\x1b\\\x1b[2;4H\x1b[?2026l").encode()
        for byte in raw:
            capture.feed(bytes([byte]))
        self.assertEqual(2, capture.generation)
        self.assertEqual("first:5", capture.screen.display[0].rstrip())
        self.assertEqual("link:ok", capture.screen.display[1].rstrip())
        self.assertEqual((3, 1), (capture.screen.cursor.x, capture.screen.cursor.y))
        self.assertEqual(len(raw), capture.received_bytes)



class CanonicalDetailsConsumerTests(unittest.TestCase):
    """Exercise the canonical fixture's actual assertion against committed cells."""

    def capture(self, rows=None, columns=80):
        if rows is None:
            rows = self.rows()
        screen = ScreenCapture(columns, len(rows))
        frame = "\x1b[?2026h\x1b[2J" + "".join(
            f"\x1b[{index + 1};1H{row}" for index, row in enumerate(rows)
        ) + "\x1b[49;2H\x1b[?2026l"
        screen.feed(frame.encode())
        return screen

    def rows(self):
        transcript = ["" for _ in range(47)]
        transcript[1] = "! Details unavailable; draft retained. HTTP 503; type: busy; code:"
        transcript[2] = "  host_busy"
        transcript[3] = "literal │ and ▐ in source"
        return [row.ljust(79) + "│" for row in transcript] + [
            "─" * 80, "›", "! Details unavailable; draft retained."
        ]

    def check(self, screen):
        assert_details_unavailable(screen, columns=80, rows=50)

    def test_screen_assertion_import_without_actor_argument(self):
        # A fresh interpreter with no positional actor must load the real owner.
        probe = subprocess.run(
            [sys.executable, "-B", "-c",
             "import sys; from terminal_screen import assert_details_unavailable; "
             "assert len(sys.argv) == 1; assert callable(assert_details_unavailable); "
             "assert 'model_fixture' not in sys.modules"],
            cwd=pathlib.Path(__file__).resolve().parent, capture_output=True, text=True,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)

    def test_exact_diagnostic_and_footer_on_committed_physical_screen(self):
        screen = self.capture()
        before, cells = screen.completed, screen.completed_cells
        self.check(screen)
        self.assertIn("literal │ and ▐ in source", screen.completed)
        self.assertEqual(before, screen.completed)
        self.assertIs(cells, screen.completed_cells)

    def test_corrupt_diagnostic_chrome_and_geometry_are_rejected(self):
        for fault in ("status", "type", "code", "missing continuation", "separated continuation",
                      "footer only", "literal rail in diagnostic", "rail missing", "rail moved", "rail thumb",
                      "diagnostic edge track", "diagnostic edge thumb", "footer edge track", "footer edge thumb",
                      "footer", "rule", "draft", "geometry"):
            with self.subTest(fault=fault):
                rows = self.rows()
                if fault == "status": rows[1] = rows[1].replace("503", "500")
                elif fault == "type": rows[1] = rows[1].replace("busy", "idle")
                elif fault == "code": rows[2] = rows[2].replace("host_busy", "host_idle")
                elif fault == "missing continuation": rows[2] = "".ljust(79) + "│"
                elif fault == "separated continuation": rows[3], rows[2] = rows[2], rows[3]
                elif fault == "footer only":
                    rows[1] = "".ljust(79) + "│"
                    rows[2] = "".ljust(79) + "│"
                    rows[-1] = "! Details unavailable; draft retained. HTTP 503; type: busy; code: host_busy"
                elif fault == "literal rail in diagnostic": rows[2] = rows[2].replace("  host_busy", "  ▐ host_busy")
                elif fault == "rail missing": rows[1] = rows[1][:-1] + " "
                elif fault == "rail moved": rows[1] = rows[1][:-2] + "│ "
                elif fault == "rail thumb": rows[20] = rows[20][:-1] + "▐"
                elif fault == "diagnostic edge track": rows[1] = rows[1][:78] + "││"
                elif fault == "diagnostic edge thumb": rows[2] = rows[2][:78] + "▐│"
                elif fault == "footer edge track": rows[-1] = rows[-1].ljust(79) + "│"
                elif fault == "footer edge thumb": rows[-2] = rows[-2].ljust(79) + "▐"
                elif fault == "footer": rows[-1] = "! Details unavailable."
                elif fault == "rule": rows[-3] = "─" * 79
                elif fault == "draft": rows[-2] = "› draft"
                elif fault == "geometry": rows.pop(3)
                with self.assertRaises(AssertionError):
                    self.check(self.capture(rows))

    def test_old_or_uncommitted_frame_is_not_current_evidence(self):
        with self.assertRaises(AssertionError):
            self.check(ScreenCapture(80, 50))
        screen = self.capture()
        bad = self.rows()
        bad[2] = "".ljust(79) + "│"
        next_frame = "\x1b[?2026h\x1b[2J" + "".join(
            f"\x1b[{index + 1};1H{row}" for index, row in enumerate(bad)
        )
        screen.feed(next_frame.encode())
        with self.assertRaises(AssertionError):
            self.check(screen)
        screen.feed(b"\x1b[?2026l")
        with self.assertRaises(AssertionError):
            self.check(screen)

if __name__ == "__main__":
    host_process.enter()
    unittest.main()
