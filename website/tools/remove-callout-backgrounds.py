"""Remove border-connected pale backgrounds, preserving enclosed white clothing.

Usage: python website/tools/remove-callout-backgrounds.py
Requires Pillow. Existing transparent PNGs are left intact.
"""
from collections import deque
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[1] / "public" / "brand" / "callouts"
for path in sorted(root.glob("*.png")):
    original = Image.open(path)
    if original.mode == "RGBA" and original.getextrema()[3][0] == 0:
        print(f"{path.name}: already transparent")
        continue
    image = original.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    seen = bytearray(width * height)
    pending = deque()

    def visit(x, y):
        index = y * width + x
        if seen[index]:
            return
        seen[index] = 1
        red, green, blue, _ = pixels[x, y]
        # Only pale, near-neutral pixels connected to the outside are removed.
        # Black outlines isolate the white shirt and gloves from this region.
        if min(red, green, blue) >= 160 and max(red, green, blue) - min(red, green, blue) <= 32:
            pending.append((x, y))

    for x in range(width):
        visit(x, 0)
        visit(x, height - 1)
    for y in range(height):
        visit(0, y)
        visit(width - 1, y)

    removed = 0
    while pending:
        x, y = pending.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        removed += 1
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height:
                visit(nx, ny)

    assert removed > width * height * .1, f"No substantial background found: {path}"
    image.save(path, optimize=True)
    print(f"{path.name}: removed {removed:,} background pixels; kept {width}x{height} canvas")

for path in sorted(root.glob("*.png")):
    with Image.open(path) as original:
        original.convert("RGBA").resize((152, 152), Image.Resampling.LANCZOS).save(
            path.with_suffix(".webp"), format="WEBP", quality=85, method=6
        )
    print(f"{path.stem}.webp: generated transparent 152px web asset")
