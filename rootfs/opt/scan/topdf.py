"""Combine scanned TIFF pages into one PDF, dropping blank pages.

Blank test: percent of pixels darker than DARK_LEVEL (0-255), ignoring a margin around the
edges (feeder shadows). Unlike Ghostscript inkcov this ignores off-white paper background.
Each page's score is logged so BLANK_THRESHOLD can be tuned from `docker logs brscan`.
"""
import io
import os
import sys

import img2pdf
from PIL import Image, ImageFilter

out, pages = sys.argv[1], sys.argv[2:]
res = int(os.environ.get("SCAN_RESOLUTION", "300"))
quality = int(os.environ.get("JPEG_QUALITY", "85"))
remove = os.environ.get("BLANK_REMOVAL", "true").lower() == "true"
threshold = float(os.environ.get("BLANK_THRESHOLD", "0.01"))
dark = int(os.environ.get("BLANK_DARK_LEVEL", "128"))
margin = float(os.environ.get("BLANK_MARGIN", "0.04"))


def score(im):
    g = im.convert("L")
    w, h = g.size
    mx, my = int(w * margin), int(h * margin)
    g = g.crop((mx, my, w - mx, h - my))
    g = g.filter(ImageFilter.MedianFilter(3))  # remove single-pixel scanner specks
    hist = g.histogram()
    return 100.0 * sum(hist[:dark]) / max(1, sum(hist))


images = []
for n, path in enumerate(pages, 1):
    im = Image.open(path)
    im.load()
    s = score(im)
    blank = remove and s < threshold
    print(f"  page {n}: {s:.3f}% dark -> {'BLANK, dropped' if blank else 'keep'}", flush=True)
    images.append((im, blank))

kept = [im for im, blank in images if not blank]
if not kept:
    print("  every page looked blank, keeping all", flush=True)
    kept = [im for im, _ in images]

blobs = []
for im in kept:
    dpi = tuple(int(round(float(v))) for v in im.info.get("dpi", (res, res)))
    buf = io.BytesIO()
    if im.mode == "1":
        im.save(buf, format="TIFF", compression="group4", dpi=dpi)
    else:
        if im.mode not in ("L", "RGB"):
            im = im.convert("RGB")
        im.save(buf, format="JPEG", quality=quality, optimize=True, dpi=dpi)
    blobs.append(buf.getvalue())

with open(out, "wb") as f:
    f.write(img2pdf.convert(blobs))
print(f"  {len(kept)} of {len(pages)} page(s) in PDF", flush=True)
