#!/usr/bin/env python3
"""Check that the macOS bundle icon is the ControlWard icon set.

The checker uses only the Python standard library. It parses Info.plist with
plistlib and reads the icns container back, including every PNG size.
"""

from __future__ import annotations

import hashlib
import plistlib
import struct
import sys
from pathlib import Path

# Stem and filename of the icon shipped in ControlWard 1.1.1 (build 103).
# Split so a search for the old filename does not match this source file.
LEGACY_STEM = "Context" + "ward"
LEGACY_FILENAME = LEGACY_STEM + ".icns"
# SHA-256 of that icon inside the v1.1.1 macOS release archive.
LEGACY_SHA256 = "42601112016a0b77b7ee22a2ebdd4761b1abf7be93a27ca9a93730e64a226235"

ICON_STEM = "ControlWard"
ICON_FILENAME = ICON_STEM + ".icns"

# iconutil's ten slots. Slots whose source PNG is a different size are
# LANCZOS-downscaled from that source (the approved 1024 icon).
# key, pixels, iconset name, source path relative to the repo root.
SLOTS = (
    ("icp4", 16, "icon_16x16.png", "design/controlward/controlward-icon-small-16.png"),
    ("ic11", 32, "icon_16x16@2x.png", "design/controlward/controlward-icon-small-32.png"),
    ("icp5", 32, "icon_32x32.png", "design/controlward/controlward-icon-small-32.png"),
    ("ic12", 64, "icon_32x32@2x.png", "design/controlward/controlward-icon-small-64.png"),
    ("ic07", 128, "icon_128x128.png", "design/controlward/controlward-icon-1024.png"),
    ("ic13", 256, "icon_128x128@2x.png", "design/controlward/controlward-icon-1024.png"),
    ("ic08", 256, "icon_256x256.png", "design/controlward/controlward-icon-1024.png"),
    ("ic14", 512, "icon_256x256@2x.png", "design/controlward/controlward-icon-512.png"),
    ("ic09", 512, "icon_512x512.png", "design/controlward/controlward-icon-512.png"),
    ("ic10", 1024, "icon_512x512@2x.png", "design/controlward/controlward-icon-1024.png"),
)
REQUIRED_SIZES = tuple((key, pixels, label) for key, pixels, label, _source in SLOTS)

SKIP_DIRS = {
    ".git",
    ".build",
    "node_modules",
    "dist",
    "release",
    "coverage",
    "__pycache__",
    "build",
}


def resources_dir(root: Path) -> Path:
    return root / "native-crm" / "Resources"


def parse_icns(data: bytes) -> list[tuple[str, bytes]]:
    """Return (type, payload) chunks. Raises ValueError if the container is invalid."""
    if len(data) < 8 or data[:4] != b"icns":
        raise ValueError("not an icns file")
    declared = struct.unpack(">I", data[4:8])[0]
    if declared != len(data):
        raise ValueError(f"icns length {declared} does not match file size {len(data)}")
    chunks: list[tuple[str, bytes]] = []
    offset = 8
    while offset + 8 <= len(data):
        key = data[offset : offset + 4].decode("latin1")
        length = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        if length < 8 or offset + length > len(data):
            raise ValueError(f"icns chunk {key!r} has invalid length {length}")
        chunks.append((key, data[offset + 8 : offset + length]))
        offset += length
    if offset != len(data):
        raise ValueError("icns chunks do not fill the file")
    return chunks


def png_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def expected_image(root: Path, source_rel: str, pixels: int):
    """Approved artwork for one slot. Smaller sizes of the 1024 icon are downscaled."""
    from PIL import Image

    image = Image.open(root / source_rel).convert("RGBA")
    if image.size != (pixels, pixels):
        image = image.resize((pixels, pixels), Image.Resampling.LANCZOS)
    return image


def payload_matches(payload: bytes, root: Path, source_rel: str, pixels: int) -> tuple[bool, str]:
    """Pixel-compare an icns PNG chunk with the approved source for that slot."""
    from PIL import Image
    import io

    source = root / source_rel
    if not source.is_file():
        return False, f"missing source {source_rel}"
    try:
        actual = Image.open(io.BytesIO(payload)).convert("RGBA")
    except Exception as exc:
        return False, f"slot PNG could not be read ({exc})"
    if actual.size != (pixels, pixels):
        return False, f"slot is {actual.size[0]}x{actual.size[1]}, expected {pixels}x{pixels}"
    expected = expected_image(root, source_rel, pixels)
    if actual.size != expected.size:
        return False, f"source {source_rel} became {expected.size}"
    if list(actual.get_flattened_data()) != list(expected.get_flattened_data()):
        return False, f"pixels do not match {source_rel}"
    return True, source_rel


def list_icon_sizes(path: Path) -> list[str]:
    """Human-readable size listing parsed back out of an icns file."""
    lines = []
    for key, payload in parse_icns(path.read_bytes()):
        size = png_size(payload)
        if size:
            lines.append(f"{key}: png {size[0]}x{size[1]} ({len(payload)} bytes)")
        else:
            lines.append(f"{key}: {len(payload)} bytes")
    return lines


def _scan_legacy_references(root: Path) -> list[str]:
    needle = LEGACY_FILENAME.lower().encode("ascii")
    found: list[str] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        relative = path.relative_to(root).as_posix()
        if path.name.lower() == LEGACY_FILENAME.lower():
            found.append(f"{relative}: file is still named {LEGACY_FILENAME}")
        try:
            blob = path.read_bytes()
        except OSError as exc:
            found.append(f"{relative}: unreadable ({exc})")
            continue
        if needle in blob.lower():
            found.append(f"{relative}: still mentions {LEGACY_FILENAME}")
    return found


def check(root: Path) -> list[str]:
    """Return a list of problems. An empty list means the tree is acceptable."""
    errors: list[str] = []
    res = resources_dir(root)
    plist_path = res / "Info.plist"
    icon_path = res / ICON_FILENAME

    if not plist_path.is_file():
        return [f"missing {plist_path}"]

    try:
        plist = plistlib.loads(plist_path.read_bytes())
    except Exception as exc:  # plistlib raises several error types
        return [f"{plist_path}: invalid plist ({exc})"]

    icon_file = plist.get("CFBundleIconFile")
    if icon_file != ICON_STEM:
        errors.append(
            f"CFBundleIconFile is {icon_file!r}; expected {ICON_STEM!r} "
            f"(resolved file {ICON_FILENAME})"
        )
    if "CFBundleIconName" in plist and plist.get("CFBundleIconName") != ICON_STEM:
        errors.append(
            f"CFBundleIconName is {plist.get('CFBundleIconName')!r}; expected {ICON_STEM!r}"
        )

    if not icon_path.is_file():
        errors.append(f"missing {icon_path}")
        errors.extend(_scan_legacy_references(root))
        return errors

    icon_bytes = icon_path.read_bytes()
    digest = hashlib.sha256(icon_bytes).hexdigest()
    if digest == LEGACY_SHA256:
        errors.append(
            f"{ICON_FILENAME} is byte-identical to the icon shipped in ControlWard 1.1.1 "
            f"(sha256 {LEGACY_SHA256})"
        )

    legacy_path = res / LEGACY_FILENAME
    if legacy_path.is_file() and legacy_path.read_bytes() == icon_bytes:
        errors.append(
            f"{ICON_FILENAME} is byte-identical to {LEGACY_FILENAME} in {res.as_posix()}"
        )

    try:
        chunks = parse_icns(icon_bytes)
    except ValueError as exc:
        errors.append(f"{ICON_FILENAME}: {exc}")
        errors.extend(_scan_legacy_references(root))
        return errors

    by_key = {key: payload for key, payload in chunks}
    for key, pixels, label, source_rel in SLOTS:
        payload = by_key.get(key)
        if payload is None:
            errors.append(f"{ICON_FILENAME} is missing {label} ({key}, {pixels}x{pixels})")
            continue
        size = png_size(payload)
        if size != (pixels, pixels):
            errors.append(
                f"{ICON_FILENAME} {label} ({key}) is {size}, expected png {pixels}x{pixels}"
            )
            continue
        matches, detail = payload_matches(payload, root, source_rel, pixels)
        if not matches:
            errors.append(f"{ICON_FILENAME} {label} ({key}) {detail}")

    errors.extend(_scan_legacy_references(root))
    return errors


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parent.parent
    errors = check(root)
    icon_path = resources_dir(root) / ICON_FILENAME
    if icon_path.is_file():
        print(f"Icon: {icon_path}")
        try:
            for line in list_icon_sizes(icon_path):
                print(f"  {line}")
        except ValueError as exc:
            print(f"  (could not list sizes: {exc})")
    if errors:
        print(f"{len(errors)} icon check failure(s) under {root}:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(f"App icon OK ({len(REQUIRED_SIZES)} sizes) under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
