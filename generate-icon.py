#!/usr/bin/env python3
"""Generate the iQualize app icon as a macOS .icns file.

The icon is the "Signal Glow" design — a blue EQ curve with a node handle
over a dark grid. `iqualize-icon.svg` is the vector master; this script
rasterizes it and packs the standard iconset ladder into an .icns.

The SVG uses filter glows, so it's rasterized with QuickLook (qlmanage,
WebKit-backed) rather than a Python SVG library — WebKit renders the SVG
filters faithfully, matching the design's soft glow.
"""

import os
import subprocess
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SVG_PATH = os.path.join(HERE, "iqualize-icon.svg")
ICNS_PATH = os.path.join(HERE, "Sources", "iQualize", "AppIcon.icns")

# (iconset slot name, pixel size). 1024 comes straight from the raster;
# everything else is a high-quality downscale.
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


def rasterize_svg(svg_path, size, out_dir):
    """Render the SVG to a `size`x`size` PNG via QuickLook, return its path."""
    subprocess.run(
        ["qlmanage", "-t", "-s", str(size), "-o", out_dir, svg_path],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # qlmanage writes "<basename>.png" into out_dir.
    png_path = os.path.join(out_dir, os.path.basename(svg_path) + ".png")
    if not os.path.exists(png_path):
        raise RuntimeError(f"qlmanage did not produce {png_path}")
    return png_path


def main():
    if not os.path.exists(SVG_PATH):
        raise SystemExit(f"Missing vector master: {SVG_PATH}")

    with tempfile.TemporaryDirectory() as tmp:
        raster_path = rasterize_svg(SVG_PATH, 1024, tmp)
        master = Image.open(raster_path).convert("RGBA")
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
