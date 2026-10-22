"""Make the fork installer's wizard images from Plezy's own logo.

Usage (from the repo root): python -I windows/installer/make_wizard_images.py .
Writes windows/installer/wizard-{light,dark}-<w>x<h>.png and wizard-small-<n>.png.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = Path(sys.argv[1])
out = root / "windows" / "installer"
out.mkdir(parents=True, exist_ok=True)
logo = Image.open(root / "assets" / "plezy.png").convert("RGBA")


def fill_cutouts(img):
    """The waves are transparent holes; the app icon shows them white. Put a white
    layer under the triangle (holes included), pulled in from the outer edge so it
    never shows through the anti-aliased rim."""
    alpha = img.getchannel("A").point(lambda a: 255 if a > 8 else 0)
    # The triangle touches the image edges, splitting the outside into pieces; a
    # clear border joins them so one flood fill reaches all of it.
    solid = Image.new("L", (img.width + 4, img.height + 4), 0)
    solid.paste(alpha, (2, 2))
    ImageDraw.floodfill(solid, (0, 0), 128)
    solid = solid.crop((2, 2, img.width + 2, img.height + 2))
    inside = solid.point(lambda v: 0 if v == 128 else 255).filter(ImageFilter.MinFilter(7))
    under = Image.new("RGBA", img.size, (255, 255, 255, 0))
    under.putalpha(inside)
    under.alpha_composite(img)
    return under


logo = fill_cutouts(logo)
font_path = r"C:\Windows\Fonts\seguisb.ttf"

THEMES = {
    "light": {"top": (255, 247, 243), "bottom": (255, 228, 216), "text": (58, 40, 33)},
    "dark": {"top": (40, 33, 30), "bottom": (24, 22, 21), "text": (242, 230, 224)},
}
SIDE_SIZES = [(202, 386), (336, 643), (534, 1022)]
SMALL_SIZES = [58, 97, 159]


def gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(w):
            px[x, y] = row
    return img


def side(w, h, theme):
    img = gradient(w, h, theme["top"], theme["bottom"]).convert("RGBA")
    size = round(w * 0.58)
    mark = logo.resize((size, size), Image.LANCZOS)
    # The triangle points right, so its visual centre sits left of the box centre.
    x = (w - size) // 2 + round(w * 0.03)
    y = round(h * 0.30)
    img.alpha_composite(mark, (x, y))
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(font_path, round(w * 0.17))
    text = "Plezy"
    tw = draw.textlength(text, font=font)
    draw.text(((w - tw) / 2, y + size + round(h * 0.04)), text, font=font, fill=theme["text"])
    return img.convert("RGB")


for name, theme in THEMES.items():
    for w, h in SIDE_SIZES:
        side(w, h, theme).save(out / f"wizard-{name}-{w}x{h}.png", optimize=True)

for n in SMALL_SIZES:
    pad = round(n * 0.08)
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    mark = logo.resize((n - 2 * pad, n - 2 * pad), Image.LANCZOS)
    canvas.alpha_composite(mark, (pad, pad))
    canvas.save(out / f"wizard-small-{n}.png", optimize=True)

for f in sorted(out.glob("wizard-*.png")):
    print(f.name, f.stat().st_size)

