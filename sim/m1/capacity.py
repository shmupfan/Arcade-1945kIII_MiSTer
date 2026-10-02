#!/usr/bin/env python3
"""Sprites-per-line probe for k3_video (not a gate): N non-blank sprites on
the same 16 lines, N = 144 .. 192, for both rasters. With the pessimistic
ROM port (one 32-bit read per 8 clocks) a line holds about 160 sprites on
the k3 raster; the most any game frame uses is 63 (m0_findings 6).

Usage: capacity.py <out_dir>
"""
import random
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_scenes import Scene, nonblank_codes  # noqa: E402

out = Path(sys.argv[1])
shutil.rmtree(out, ignore_errors=True)
for s in ("1945kiii", "flagrall"):
    rng = random.Random(7)
    part, _ = nonblank_codes(s)
    for n, cnt in enumerate((144, 160, 168, 176, 192), 1):
        sc = Scene(s, rng)
        for k in range(cnt):
            sc.spr(k, (k * 5) % 330, 100, rng.choice(part))
        sc.write(out / f"{s}_cap{cnt}", f"{n:06d}")
