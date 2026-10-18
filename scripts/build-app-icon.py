#!/usr/bin/env python3
"""Build ControlWard.icns from the approved redraw.

The mark the app shows:
  native-crm/Sources/FollowUpOSNative/Resources/controlward-mark.svg
  native-crm/Sources/FollowUpOSNative/Resources/controlward-mark.png

Icon slots come from design/controlward/ (see scripts/check-app-icon.py):
  controlward-icon-small for 16, 16@2x, 32, and 32@2x (the 64px file)
  controlward-icon-512 for 256@2x and 512
  controlward-icon-1024 for 512@2x, and LANCZOS-downscaled for 128, 128@2x, and 256

The artwork is the approved files. This script does not redraw it.
Requires Pillow and icnsutil.
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from icnsutil import IcnsFile

ROOT = Path(__file__).resolve().parent.parent
MARK_PNG = ROOT / "native-crm/Sources/FollowUpOSNative/Resources/controlward-mark.png"
ICON_PATH = ROOT / "native-crm/Resources/ControlWard.icns"
PREVIEW_PATH = ROOT / "docs/controlward-app-icon-preview.png"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_app_icon", ROOT / "scripts/check-app-icon.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def slot_image(root: Path, source_rel: str, pixels: int) -> Image.Image:
    image = Image.open(root / source_rel).convert("RGBA")
    if image.size == (pixels, pixels):
        return image
    return image.resize((pixels, pixels), Image.Resampling.LANCZOS)


def write_icns(checker, destination: Path) -> None:
    staging = Path(tempfile.mkdtemp(prefix="controlward-iconset-"))
    try:
        icns = IcnsFile()
        for key, pixels, filename, source_rel in checker.SLOTS:
            path = staging / filename
            source = ROOT / source_rel
            image = Image.open(source).convert("RGBA")
            if image.size == (pixels, pixels):
                shutil.copyfile(source, path)
            else:
                image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(path, format="PNG")
            icns.add_media(key, file=str(path))
        destination.parent.mkdir(parents=True, exist_ok=True)
        icns.write(str(destination), toc=True)
    finally:
        shutil.rmtree(staging)


def _font(size: int) -> ImageFont.ImageFont:
    path = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
    if path.is_file():
        return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def write_preview(checker, destination: Path) -> None:
    margin = 48
    gap = 28
    slots = []
    for _key, pixels, label, source_rel in checker.SLOTS:
        short = label.removeprefix("icon_").removesuffix(".png")
        slots.append((pixels, short, source_rel))
    row_w = sum(pixels for pixels, _label, _source in slots) + gap * (len(slots) - 1)
    dock_h = 700
    width = max(row_w, 980) + margin * 2
    height = margin + 56 + dock_h + 48 + 1024 + 36 + margin
    canvas = Image.new("RGB", (width, height), (232, 228, 220))
    draw = ImageDraw.Draw(canvas)
    draw.text((margin, margin), "ControlWard app icon", fill=(27, 36, 48), font=_font(28))

    dock_top = margin + 56
    draw.rounded_rectangle((margin, dock_top, margin + 980, dock_top + dock_h), radius=28, fill=(196, 208, 214))
    icon = slot_image(ROOT, "design/controlward/controlward-icon-512.png", 512)
    icon_x = margin + (980 - 512) // 2
    icon_y = dock_top + 36
    bar_w, bar_h = 760, 128
    bar_mask = Image.new("L", (bar_w, bar_h), 0)
    ImageDraw.Draw(bar_mask).rounded_rectangle((0, 0, bar_w - 1, bar_h - 1), radius=36, fill=210)
    frost = Image.new("RGBA", (bar_w, bar_h), (255, 255, 255, 255))
    frost.putalpha(bar_mask)
    canvas.paste(frost, (margin + (980 - bar_w) // 2, icon_y + 512 - 78), frost)
    canvas.paste(icon, (icon_x, icon_y), icon)
    draw.text((margin + 24, dock_top + dock_h - 44), "512px Dock preview", fill=(27, 36, 48), font=_font(18))

    row_top = dock_top + dock_h + 48
    x = margin + max(0, (width - margin * 2 - row_w) // 2)
    label_font = _font(18)
    for pixels, label, source_rel in slots:
        icon = slot_image(ROOT, source_rel, pixels)
        y = row_top + (1024 - pixels)
        cell = max(1, pixels // 8)
        checker_bg = Image.new("RGB", (pixels, pixels), (214, 210, 202))
        cdraw = ImageDraw.Draw(checker_bg)
        for cy in range(0, pixels, cell):
            for cx in range(0, pixels, cell):
                if ((cx // cell) + (cy // cell)) % 2 == 0:
                    cdraw.rectangle((cx, cy, cx + cell - 1, cy + cell - 1), fill=(244, 242, 236))
        canvas.paste(checker_bg, (x, y))
        canvas.paste(icon, (x, y), icon)
        draw.text((x, row_top + 1024 + 8), label, fill=(27, 36, 48), font=label_font)
        x += pixels + gap
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, format="PNG", optimize=True)


def main() -> int:
    if not MARK_PNG.is_file():
        print(f"Missing source mark: {MARK_PNG}", file=sys.stderr)
        return 1
    checker = load_checker()
    for _key, _pixels, _label, source_rel in checker.SLOTS:
        path = ROOT / source_rel
        if not path.is_file():
            print(f"Missing icon source: {path}", file=sys.stderr)
            return 1
    write_icns(checker, ICON_PATH)
    write_preview(checker, PREVIEW_PATH)
    errors = checker.check(ROOT)
    print(f"Mark: {MARK_PNG}")
    print(f"Wrote {ICON_PATH} ({ICON_PATH.stat().st_size} bytes)")
    print(f"Wrote {PREVIEW_PATH} ({PREVIEW_PATH.stat().st_size} bytes)")
    for line in checker.list_icon_sizes(ICON_PATH):
        print(f"  {line}")
    if errors:
        print("icon check failed after build:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
