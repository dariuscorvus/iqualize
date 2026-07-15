#!/usr/bin/env python3
"""Generate the iQualize app icon as a macOS .icns file.

The icon is the "Signal Glow" design — a blue EQ curve with a node handle
over a dark grid. `iqualize-icon.svg` is the vector master; this script
rasterizes it and packs the standard iconset ladder into an .icns.

Rasterizing is done with QuickLook (qlmanage, WebKit-backed) so the SVG's
gradient glows render faithfully. QuickLook can't emit an alpha channel,
though — it composites transparent regions onto an opaque background — so
the SVG is rendered twice, on white and on black, and the true straight
alpha is recovered from the pair. Without this the rounded-corner icon
ships with opaque (white) corners.
"""

import os
import re
import subprocess
import tempfile

from PIL import Image, ImageMath

HERE = os.path.dirname(os.path.abspath(__file__))
SVG_PATH = os.path.join(HERE, "iqualize-icon.svg")
ICNS_PATH = os.path.join(HERE, "Sources", "iQualize", "AppIcon.icns")

# (iconset slot name, pixel size). 1024 is the master; the rest are downscales.
SLOTS = [
    ("16x16", 16),
    ("16x16@2x", 32),
    ("32x32", 32),
    ("32x32@2x", 64),
    ("128x128", 128),
    ("128x128@2x", 256),
    ("256x256", 256),
    ("256x256@2x", 512),
    ("512x512", 512),
    ("512x512@2x", 1024),
]


def _render_on(svg_text, bg_hex, size, out_dir, tag):
    """Render the SVG via QuickLook onto an opaque `bg_hex` background."""
    # Inject a full-canvas rect behind everything so the transparent regions
    # composite onto a known color we can back out later.
    variant = re.sub(
        r"(<svg\b[^>]*>)",
        r'\1<rect width="512" height="512" fill="%s"/>' % bg_hex,
        svg_text,
        count=1,
    )
    svg_file = os.path.join(out_dir, f"variant_{tag}.svg")
    with open(svg_file, "w") as f:
        f.write(variant)
    subprocess.run(
        ["qlmanage", "-t", "-s", str(size), "-o", out_dir, svg_file],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    png = svg_file + ".png"
    if not os.path.exists(png):
        raise RuntimeError(f"qlmanage did not produce {png}")
    return Image.open(png).convert("RGB")


def rasterize_rgba(svg_text, size, out_dir):
    """Rasterize the SVG to a straight-alpha RGBA image at `size`x`size`.

    From two opaque renders (per channel, 0..255):
        white = a*color + (1 - a)*255
        black = a*color
    so  a = 1 - (white - black)/255  and  color = black / a.
    """
    white = _render_on(svg_text, "#ffffff", size, out_dir, "w")
    black = _render_on(svg_text, "#000000", size, out_dir, "b")
    wr, wg, wb = white.split()
    br, bg, bb = black.split()
    alpha = ImageMath.unsafe_eval("255 - (w - b)", w=wg, b=bg).convert("L")

    def unpremult(channel):
        return ImageMath.unsafe_eval(
            "convert(min(c * 255 / max(a, 1), 255), 'L')", c=channel, a=alpha
        ).convert("L")

    return Image.merge("RGBA", (unpremult(br), unpremult(bg), unpremult(bb), alpha))


def main():
    if not os.path.exists(SVG_PATH):
        raise SystemExit(f"Missing vector master: {SVG_PATH}")

    svg_text = open(SVG_PATH).read()
    with tempfile.TemporaryDirectory() as tmp:
        master = rasterize_rgba(svg_text, 1024, tmp)
        if master.size != (1024, 1024):
            master = master.resize((1024, 1024), Image.LANCZOS)

        iconset_dir = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset_dir, exist_ok=True)
        for name, px in SLOTS:
            img = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
            img.save(os.path.join(iconset_dir, f"icon_{name}.png"))

        subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", ICNS_PATH], check=True
        )

    print(f"Created {ICNS_PATH} from {os.path.basename(SVG_PATH)}")


if __name__ == "__main__":
    main()
