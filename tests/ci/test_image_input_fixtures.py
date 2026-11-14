"""Independent raw image and typed-wire fixture integrity checks."""
import base64
import json
from pathlib import Path
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]


class ImageInputFixtures(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
