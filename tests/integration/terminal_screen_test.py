"""Focused, offline tests for the shared committed-screen observer."""
import unittest

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
    unittest.main()
