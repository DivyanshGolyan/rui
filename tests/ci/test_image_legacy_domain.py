"""The additive image domain must reconstruct the pinned pre-image contract."""
import base64
import hashlib
import json
import struct
import zlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Exact origin/main b081e467b268660e832bede4b6435efdb918f53e, before images.
ORIGINAL = {'src/codec_abi.zig': '076e874281a29852d24f2c3422a988ae3f9052ef5b717e726f3195b8ad364f6e', 'src/codecs/responses.zig': '8e95e1205211d38bfdfbe8c2c62533c8db4947c5202c6aaa6aac52d639ea6170'}


def remove_between(source, start, end):
    left = source.index(start)
    right = source.index(end, left)
    return source[:left] + source[right:]


def legacy_source(path, source):
    source = source.split("\ntest ", 1)[0]
    if path == "src/codecs/responses.zig":
        source = source.replace("    input_part_comma: bool = false,\n\n", "", 1)
        source = remove_between(source, "            .image_message_open =>", "            // Version two changes effort")
    else:
        source = remove_between(source, "    /// An image-bearing Message opens.", "    /// The items the Host resumes")
        source = source.replace(".image_message_open, .image_tool_open, ", "", 1)
        source = source.replace(".image_message_close, .image_tool_close, ", "", 1)
        left = source.index("    image_message_open: Author,")
        right = source.index("pub const max_handles", left)
        source = source[:left] + "};\n\npub const max_handles" + source[right + len("pub const max_handles"):]
        source = remove_between(source, "    /// One canonical raw Content handle,", "};\n\n/// The most pieces")
        source = remove_between(source, "    pub fn base64(self: *Pieces", "    fn push(self: *Pieces")
    return source


class ImageLegacyDomain(unittest.TestCase):
    def test_every_legacy_handler_tag_payload_carry_and_escape_is_unchanged(self):
        for path, expected in ORIGINAL.items():
            with self.subTest(path=path):
                source = legacy_source(path, (ROOT / path).read_text())
                self.assertEqual(expected, hashlib.sha256(source.encode()).hexdigest())

    def test_image_wire_fixtures_decode_to_complete_original_png(self):
        fixtures = ROOT / "src/codecs/fixtures/image-input"
        png = (fixtures / "pixel.png").read_bytes()
        self.assertEqual(b"\x89PNG\r\n\x1a\n", png[:8])
        offset = 8
        kinds = []
        while offset < len(png):
            length = struct.unpack_from(">I", png, offset)[0]
            kind = png[offset + 4:offset + 8]
            data = png[offset + 8:offset + 8 + length]
            crc = struct.unpack_from(">I", png, offset + 8 + length)[0]
            self.assertEqual(crc, zlib.crc32(kind + data))
            kinds.append(kind)
            offset += length + 12
        self.assertEqual(len(png), offset)
        self.assertEqual([b"IHDR", b"IDAT", b"IEND"], kinds)
        self.assertEqual(png, base64.b64decode((fixtures / "pixel.base64").read_bytes(), validate=True))
        for version in (1, 2, 3):
            request = json.loads((fixtures / f"{version}-image.json").read_text())
            user = request["input"][1]
            tool = request["input"][3]
            self.assertEqual("screenshot-call", tool["call_id"])
            for image in (user["content"][3], tool["output"][1]):
                self.assertEqual("input_image", image["type"])
                self.assertEqual("auto", image["detail"])
                prefix, data = image["image_url"].split(",", 1)
                self.assertEqual("data:image/png;base64", prefix)
                self.assertEqual(png, base64.b64decode(data, validate=True))

    def test_old_tool_string_change_is_detected(self):
        path = "src/codecs/responses.zig"
        source = legacy_source(path, (ROOT / path).read_text())
        changed = source.replace('out.content(1, .json_string_v1);', 'out.content(1, .verbatim);')
        self.assertNotEqual(source, changed)
        self.assertNotEqual(ORIGINAL[path], hashlib.sha256(changed.encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
