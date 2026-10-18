#!/usr/bin/env python3
"""Checks for the ControlWard macOS icon.

The planted old-state test builds a tree that still points at the previous
icon and asserts the checker rejects it.
"""

from __future__ import annotations

import hashlib
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("check_app_icon", ROOT / "scripts/check-app-icon.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def _png(size: int, rgba: bytes) -> bytes:
    raw = b"".join(b"\x00" + rgba[y * size * 4 : (y + 1) * size * 4] for y in range(size))
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(raw)) + _chunk(b"IEND", b"")


def _icns(parts: list[tuple[str, bytes]]) -> bytes:
    body = b"".join(key.encode("ascii") + struct.pack(">I", 8 + len(payload)) + payload for key, payload in parts)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


class AppIconCheckTests(unittest.TestCase):
    def test_planted_old_state_fails(self):
        """A tree still on the shipped 1.1.1 icon name and bytes must fail."""
        legacy = "Context" + "ward.icns"
        pixel = b"\xff\xff\xff\xff" * 256  # 16x16 white square, the old icon's field
        old_icon = _icns([("icp4", _png(16, pixel))])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resources = root / "native-crm" / "Resources"
            resources.mkdir(parents=True)
            plist = {
                "CFBundleIconFile": legacy,
                "CFBundleIconName": "Context" + "ward",
                "CFBundleName": "ControlWard",
                "CFBundleShortVersionString": "1.1.1",
            }
            (resources / "Info.plist").write_bytes(plistlib.dumps(plist))
            (resources / legacy).write_bytes(old_icon)
            # Same bytes under the new name: the rename-without-redraw failure.
            (resources / "ControlWard.icns").write_bytes(old_icon)
            (root / "bin" / "build-native-app").parent.mkdir()
            (root / "bin" / "build-native-app").write_text(
                'iconutil -c icns "$ICONSET" -o "$RESOURCES/' + legacy + '"\n'
            )

            errors = guard.check(root)
            print("\nPLANTED RED (old icon state):")
            for error in errors:
                print(f"  - {error}")

        blob = "\n".join(errors)
        self.assertGreaterEqual(len(errors), 4, blob)
        self.assertIn("CFBundleIconFile", blob)
        self.assertIn("CFBundleIconName", blob)
        self.assertIn("byte-identical", blob)
        self.assertIn("icon_16x16@2x.png", blob)
        self.assertIn("icon_512x512@2x.png", blob)
        self.assertIn("build-native-app", blob)
        self.assertNotIn("App icon OK", blob)

    def test_repo_plist_and_icon(self):
        plist_path = ROOT / "native-crm" / "Resources" / "Info.plist"
        plist = plistlib.loads(plist_path.read_bytes())
        self.assertEqual(plist["CFBundleIconFile"], "ControlWard")
        self.assertEqual(plist["CFBundleIconName"], "ControlWard")

        icon_path = ROOT / "native-crm" / "Resources" / "ControlWard.icns"
        self.assertTrue(icon_path.is_file(), f"missing {icon_path}")
        digest = hashlib.sha256(icon_path.read_bytes()).hexdigest()
        self.assertNotEqual(digest, guard.LEGACY_SHA256)
        self.assertEqual(
            guard.LEGACY_SHA256,
            "42601112016a0b77b7ee22a2ebdd4761b1abf7be93a27ca9a93730e64a226235",
        )

        errors = guard.check(ROOT)
        self.assertEqual(errors, [], "\n".join(errors))
        listing = guard.list_icon_sizes(icon_path)
        self.assertEqual(len([line for line in listing if line.startswith("ic") and "png" in line]), 10)
        parsed = {key: guard.png_size(payload) for key, payload in guard.parse_icns(icon_path.read_bytes())}
        for key, pixels, _label in guard.REQUIRED_SIZES:
            self.assertEqual(parsed[key], (pixels, pixels))


if __name__ == "__main__":
    unittest.main()
