"""Focused, offline tests for the shared committed-screen observer."""
import unittest

import host_process

from terminal_screen import ScreenCapture, SgrStream


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


if __name__ == "__main__":
    host_process.enter()
    unittest.main()
