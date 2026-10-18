#!/usr/bin/env python3
"""Build ControlWard.icns from the in-app logo raster.

Source (largest UI raster; the SwiftUI logo view loads this file):
  native-crm/Sources/FollowUpOSNative/Resources/logoContextWard.png

The mark is placed on a macOS-style rounded square. The artwork is not redrawn.
Requires Pillow and icnsutil.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont
from icnsutil import IcnsFile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "native-crm/Sources/FollowUpOSNative/Resources/logoContextWard.png"
ICON_PATH = ROOT / "native-crm/Resources/ControlWard.icns"
PREVIEW_PATH = ROOT / "docs/controlward-app-icon-preview.png"

# Darker than the logo's own teal glow (about rgb 15,33,47) so the glow stays visible.
PLATE = (6, 12, 18)
CORNER_RATIO = 0.225
# Fraction of the icon occupied by the mark's longest side.
MARK_FIT = 0.90

SIZES = (
    ("icp4", 16, "icon_16x16.png"),
    ("ic11", 32, "icon_16x16@2x.png"),
    ("icp5", 32, "icon_32x32.png"),
    ("ic12", 64, "icon_32x32@2x.png"),
    ("ic07", 128, "icon_128x128.png"),
    ("ic13", 256, "icon_128x128@2x.png"),
    ("ic08", 256, "icon_256x256.png"),
    ("ic14", 512, "icon_256x256@2x.png"),
    ("ic09", 512, "icon_512x512.png"),
    ("ic10", 1024, "icon_512x512@2x.png"),
)


def content_crop(source: Image.Image) -> Image.Image:
    alpha = source.getchannel("A")
    # Keep the faint outer glow; ignore fully clear padding.
    mask = alpha.point(lambda value: 255 if value > 8 else 0)
    bbox = mask.getbbox()
    if not bbox:
        raise SystemExit(f"{SOURCE} has no opaque pixels")
    pad = 4
    left = max(0, bbox[0] - pad)
    top = max(0, bbox[1] - pad)
    right = min(source.width, bbox[2] + pad)
    bottom = min(source.height, bbox[3] + pad)
    return source.crop((left, top, right, bottom))


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    radius = max(1, round(size * CORNER_RATIO))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def render_icon(mark: Image.Image, size: int) -> Image.Image:
    mask = rounded_mask(size)
    plate = Image.new("RGBA", (size, size), PLATE + (255,))
    plate.putalpha(mask)
    longest = max(mark.width, mark.height)
    target = max(1, round(size * MARK_FIT))
    scale = target / longest
    resized = mark.resize(
        (max(1, round(mark.width * scale)), max(1, round(mark.height * scale))),
        Image.Resampling.LANCZOS,
    )
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(plate)
    origin = ((size - resized.width) // 2, (size - resized.height) // 2)
    canvas.alpha_composite(resized, origin)
    # Clip the mark to the rounded square so the corners stay transparent.
    clipped = ImageChops.multiply(canvas.getchannel("A"), mask)
    canvas.putalpha(clipped)
    return canvas


def write_icns(icons: dict[int, Image.Image], destination: Path) -> None:
    staging = destination.parent / ".controlward-iconset"
    if staging.exists():
        for child in staging.iterdir():
            child.unlink()
    else:
        staging.mkdir(parents=True)
    icns = IcnsFile()
    seen: set[int] = set()
    for key, pixels, filename in SIZES:
        path = staging / filename
        # 16@2x and 32x32 are both 32px images with different icns keys.
        image = icons[pixels]
        if pixels in seen:
            image = icons[pixels].copy()
        image.save(path, format="PNG", optimize=True)
        icns.add_media(key, file=str(path))
        seen.add(pixels)
    destination.parent.mkdir(parents=True, exist_ok=True)
    icns.write(str(destination), toc=True)
    for child in staging.iterdir():
        child.unlink()
    staging.rmdir()


def _font(size: int) -> ImageFont.ImageFont:
    for name in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",):
        path = Path(name)
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def write_preview(icons: dict[int, Image.Image], destination: Path) -> None:
    margin = 48
    gap = 28
    label_h = 36
    # Show both 32px slots (16@2x and 32) and both 256/512 pairs by repeating pixels.
    slots = (
        (16, "16"),
        (32, "16@2x"),
        (32, "32"),
        (64, "32@2x"),
        (128, "128"),
        (256, "128@2x"),
        (256, "256"),
        (512, "256@2x"),
        (512, "512"),
        (1024, "512@2x"),
    )
    row_w = sum(pixels for pixels, _label in slots) + gap * (len(slots) - 1)
    dock_h = 700
    width = max(row_w, 980) + margin * 2
    height = margin + 56 + dock_h + 48 + 1024 + label_h + margin
    canvas = Image.new("RGB", (width, height), (232, 228, 220))
    draw = ImageDraw.Draw(canvas)
    title_font = _font(28)
    label_font = _font(18)
    draw.text((margin, margin), "ControlWard app icon", fill=(27, 36, 48), font=title_font)

    dock_top = margin + 56
    dock_box = (margin, dock_top, margin + 980, dock_top + dock_h)
    # Desktop behind the dock so the rounded corners and glow read clearly.
    draw.rounded_rectangle(dock_box, radius=28, fill=(196, 208, 214))
    icon = icons[512]
    icon_x = dock_box[0] + (980 - 512) // 2
    icon_y = dock_top + 36
    canvas.paste(icon, (icon_x, icon_y), icon)
    bar_w, bar_h = 760, 128
    bar = Image.new("RGBA", (bar_w, bar_h), (0, 0, 0, 0))
    bar_mask = Image.new("L", (bar_w, bar_h), 0)
    ImageDraw.Draw(bar_mask).rounded_rectangle((0, 0, bar_w - 1, bar_h - 1), radius=36, fill=210)
    frost = Image.new("RGBA", (bar_w, bar_h), (255, 255, 255, 255))
    frost.putalpha(bar_mask)
    bar.alpha_composite(frost)
    bar_x = dock_box[0] + (980 - bar_w) // 2
    bar_y = icon_y + 512 - 78
    canvas.paste(bar, (bar_x, bar_y), bar)
    # Re-paste the icon so it sits on top of the dock, the way Dock does.
    canvas.paste(icon, (icon_x, icon_y), icon)
    draw.text((margin + 24, dock_top + dock_h - 44), "512px Dock preview", fill=(27, 36, 48), font=label_font)

    row_top = dock_top + dock_h + 48
    x = margin + max(0, (width - margin * 2 - row_w) // 2)
    for pixels, label in slots:
        icon = icons[pixels]
        y = row_top + (1024 - pixels)
        # Checker underlay so transparent corners are obvious.
        checker = Image.new("RGB", (pixels, pixels), (214, 210, 202))
        cell = max(1, pixels // 8)
        cdraw = ImageDraw.Draw(checker)
        for cy in range(0, pixels, cell):
            for cx in range(0, pixels, cell):
                if ((cx // cell) + (cy // cell)) % 2 == 0:
                    cdraw.rectangle((cx, cy, cx + cell - 1, cy + cell - 1), fill=(244, 242, 236))
        canvas.paste(checker, (x, y))
        canvas.paste(icon, (x, y), icon)
        draw.text((x, row_top + 1024 + 8), label, fill=(27, 36, 48), font=label_font)
        x += pixels + gap
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, format="PNG", optimize=True)


def main() -> int:
    if not SOURCE.is_file():
        print(f"Missing source logo: {SOURCE}", file=sys.stderr)
        return 1
    source = Image.open(SOURCE).convert("RGBA")
    mark = content_crop(source)
    icons = {pixels: render_icon(mark, pixels) for pixels in sorted({pixels for _key, pixels, _name in SIZES})}
    write_icns(icons, ICON_PATH)
    write_preview(icons, PREVIEW_PATH)
    small = icons[16]
    gold = teal = 0
    for r, g, b, a in small.get_flattened_data():
        if a <= 200:
            continue
        if r > 140 and g > 90 and r > b + 30:
            gold += 1
        elif g > 60 and b > 60 and r < 100 and g > r + 15:
            teal += 1
    print(f"Source: {SOURCE} {source.size[0]}x{source.size[1]}")
    print(f"Mark crop: {mark.size[0]}x{mark.size[1]}")
    print(f"Wrote {ICON_PATH} ({ICON_PATH.stat().st_size} bytes)")
    print(f"Wrote {PREVIEW_PATH} ({PREVIEW_PATH.stat().st_size} bytes)")
    print(f"16px opaque gold samples: {gold}; teal samples: {teal}")
    if gold < 2 or teal < 4:
        print("16px mark lost too much of the logo", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
