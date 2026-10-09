#!/usr/bin/env python3
"""
Package icons for DSM: PACKAGE_ICON.PNG (64), PACKAGE_ICON_256.PNG (256) and
the window's ui/images/<size>.png — a rounded tile, because DSM draws icons
exactly as supplied and every native app is a rounded square.

    icon.py <out dir> [--ui <dir>] [--sizes 16,24,...] [--mark logo.png | --letter M]
            [--top '#5BC7B8'] [--bottom '#2E8C80']

Drawn at 1024 px and downsampled, so the small sizes stay crisp. Give it the
app's mark as a transparent PNG (--mark) or fall back to a letter.
"""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
RADIUS = 0.22   # of the side: DSM's own tiles are about this


def rgba(hex_colour, alpha=255):
    h = hex_colour.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def tile(top, bottom):
    """A vertical gradient, clipped to a rounded square with transparent corners."""
    grad = Image.new("RGBA", (SIZE, SIZE))
    t, b = rgba(top), rgba(bottom)
    px = grad.load()
    for y in range(SIZE):
        f = y / (SIZE - 1)
        row = tuple(round(t[i] + (b[i] - t[i]) * f) for i in range(4))
        for x in range(SIZE):
            px[x, y] = row
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=int(SIZE * RADIUS), fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(grad, mask=mask)
    return out


def with_mark(base, mark_path):
    mark = Image.open(mark_path).convert("RGBA")
    inner = int(SIZE * 0.62)
    mark.thumbnail((inner, inner), Image.LANCZOS)
    base.alpha_composite(mark, ((SIZE - mark.width) // 2, (SIZE - mark.height) // 2))
    return base


def with_letter(base, letter, colour="#FFFFFF"):
    draw = ImageDraw.Draw(base)
    font = None
    for name in ("DejaVuSans-Bold.ttf", "Arial Bold.ttf", "arialbd.ttf"):
        try:
            font = ImageFont.truetype(name, int(SIZE * 0.6)); break
        except OSError:
            continue
    font = font or ImageFont.load_default()
    box = draw.textbbox((0, 0), letter, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text(((SIZE - w) / 2 - box[0], (SIZE - h) / 2 - box[1]), letter, font=font, fill=rgba(colour))
    return base


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="where PACKAGE_ICON.PNG and PACKAGE_ICON_256.PNG go")
    ap.add_argument("--ui", help="also write <size>.png icons for the package window here")
    ap.add_argument("--sizes", default="16,24,32,48,64,72,128,256")
    ap.add_argument("--mark", help="the app's mark, a transparent PNG, centred on the tile")
    ap.add_argument("--letter", default="M", help="drawn when there's no --mark")
    ap.add_argument("--top", default="#5BC7B8"); ap.add_argument("--bottom", default="#2E8C80")
    a = ap.parse_args()

    master = tile(a.top, a.bottom)
    master = with_mark(master, a.mark) if a.mark else with_letter(master, a.letter[:1])

    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    master.resize((64, 64), Image.LANCZOS).save(out / "PACKAGE_ICON.PNG")
    master.resize((256, 256), Image.LANCZOS).save(out / "PACKAGE_ICON_256.PNG")
    if a.ui:
        ui = Path(a.ui); ui.mkdir(parents=True, exist_ok=True)
        for s in (int(x) for x in a.sizes.split(",") if x.strip()):
            master.resize((s, s), Image.LANCZOS).save(ui / f"{s}.png")


if __name__ == "__main__":
    main()
