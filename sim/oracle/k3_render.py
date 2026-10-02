#!/usr/bin/env python3
"""1945k III / Solite Spirits / Flag Rally reference renderer (PLAN M0.5).

Implements spec sections 5-8 (docs/k3_system_spec.md) from a MAME oracle
frame dump (sim/mame/k3_oracle.lua) plus the region images from
tools/build_regions.py, and reproduces MAME's frame pixel for pixel. It is
the model the M1 video RTL is checked against, so it is written from the
spec and the driver (reference/mame/1945kiii.cpp), not from MAME internals
beyond those the spec cites.

Usage:
  k3_render.py <frame_dir> [--out out.png]
Frame dirs hold state.json, palette.bin, bgram_buf.bin, spr0_buf.bin,
spr1_buf.bin (16-bit words, high byte first).
"""
import json
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent.parent
REGIONS = ROOT / "sim" / "build" / "regions"

TILE_BYTES = 16 * 16          # gfx_16x16x8_raw (1945kiii.cpp:651-652)
SPRITE_CYCLES = 4 + 128       # per sprite list entry (1945kiii.cpp:279)
BG_PALBASE = 0x000            # tilemap colour 0 (1945kiii.cpp:172, 652)
SPR_PALBASE = 0x100           # sprite colour 1, granularity 256 (1945kiii.cpp:288, 195)


@lru_cache(maxsize=None)
def gfx(setname, tag):
    """(count, 16, 16) uint8 pens of an 8bpp raw 16x16 region."""
    data = np.frombuffer((REGIONS / setname / f"{tag}.bin").read_bytes(), dtype=np.uint8)
    return data.reshape(-1, 16, 16)


def words(path):
    return np.frombuffer(Path(path).read_bytes(), dtype=">u2").astype(np.int64)


def palette_rgb(pal_bytes, entries=0x200):
    """xBGR_555 (1945kiii.cpp:671): R bits 0-4, G 5-9, B 10-14, pal5bit."""
    w = np.frombuffer(pal_bytes, dtype=">u2")[:entries].astype(np.int64)
    r, g, b = w & 31, (w >> 5) & 31, (w >> 10) & 31
    c = np.stack([r, g, b], axis=-1)
    return ((c << 3) | (c >> 2)).astype(np.uint8)


def bg_layer(setname, bgram, scrollx, scrolly, w, h):
    """Opaque 32x32 tilemap of 16x16 tiles, TILEMAP_SCAN_ROWS, tile code =
    the full buffered word (1945kiii.cpp:169-177), code modulo the tile
    count (tilemap gfx lookup); scrolled with wrap at 512 x 512."""
    tiles = gfx(setname, "tiles")
    codes = bgram[:1024] % len(tiles)
    pix = tiles[codes].reshape(32, 32, 16, 16).transpose(0, 2, 1, 3).reshape(512, 512)
    ys = (np.arange(h) + scrolly) & 511
    xs = (np.arange(w) + scrollx) & 511
    return BG_PALBASE + pix[np.ix_(ys, xs)].astype(np.int64)


def sprite_budget(htotal, vtotal):
    """Number of list entries draw_sprites reaches before cycle > max_cycle
    (1945kiii.cpp:270-281): entry i is drawn while (i+1)*132 <= w*h."""
    return min(2048, (htotal * vtotal) // SPRITE_CYCLES)


def draw_sprites(setname, s0, s1, bitmap, budget):
    """Sprite list (1945kiii.cpp:268-296): entry i uses word i of both
    buffered RAMs; drawn in list order, later entries on top, pen 0
    transparent, four wrap copies; flicker bit -> pen 0xff of colour 1."""
    spr = gfx(setname, "sprites")
    h, w = bitmap.shape
    drawn = 0
    for i in range(budget):
        a, b = int(s0[i]), int(s1[i])
        xpos = (a >> 8) | ((b & 1) << 8)
        ypos = a & 0xff
        code = ((b & 0x7ffe) >> 1) % len(spr)
        flicker = bool(b & 0x8000)
        tile = spr[code]
        mask = tile != 0
        if not mask.any():
            continue
        src = np.full(tile.shape, SPR_PALBASE | 0xff, dtype=np.int64) if flicker \
            else SPR_PALBASE + tile.astype(np.int64)
        hit = False
        for ox, oy in ((xpos, ypos), (xpos, ypos - 0x100), (xpos - 0x200, ypos), (xpos - 0x200, ypos - 0x100)):
            x0, y0 = max(ox, 0), max(oy, 0)
            x1, y1 = min(ox + 16, w), min(oy + 16, h)
            if x1 <= x0 or y1 <= y0:
                continue
            sub_m = mask[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
            sub_s = src[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
            region = bitmap[y0:y1, x0:x1]
            region[sub_m] = sub_s[sub_m]
            hit = True
        drawn += hit
    return drawn


def render(frame_dir, regions_set=None):
    """Return (rgb uint8 (h, w, 3), pens int (h, w), stats) of one frame."""
    d = Path(frame_dir)
    st = json.loads((d / "state.json").read_text())
    setname = regions_set or st["set"]
    w, h = st["width"], st["height"]
    pens = bg_layer(setname, words(d / "bgram_buf.bin"), st["scrollx"], st["scrolly"], w, h)
    budget = sprite_budget(st["htotal"], st["vtotal"])
    drawn = draw_sprites(setname, words(d / "spr0_buf.bin"), words(d / "spr1_buf.bin"), pens, budget)
    pal = palette_rgb((d / "palette.bin").read_bytes())
    return pal[pens], pens, {"budget": budget, "sprites_visible": drawn}


def main(argv):
    from PIL import Image
    rgb, _, stats = render(argv[0])
    out = argv[argv.index("--out") + 1] if "--out" in argv else "render.png"
    Image.fromarray(rgb, "RGB").save(out)
    print(out, stats)


if __name__ == "__main__":
    main(sys.argv[1:])
