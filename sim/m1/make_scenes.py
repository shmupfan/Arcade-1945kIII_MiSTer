#!/usr/bin/env python3
"""Synthetic M1 scenes for k3_video, checked against sim/oracle/k3_render.py.

They cover what the game captures do not (m0_findings 3, 6): sprite tile
codes past the end of the region, the sprite budget edge, very dense lines,
every wrap position, scroll extremes, flicker on many sprites, and random
lists, palettes and maps, for both rasters (k3 and flagrall).

Usage: make_scenes.py <out_dir> [--seed N]
Writes <out_dir>/<run>/frames/NNNNNN/{state.json, palette.bin,
bgram_buf.bin, spr0_buf.bin, spr1_buf.bin}.
"""
import json
import random
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "oracle"))
from k3_render import gfx  # noqa: E402

CFG = {
    "1945kiii": {"machine": "k3", "width": 320, "height": 224, "htotal": 432, "vtotal": 262,
                 "budget": 857, "spr_tiles": 16384, "bg_tiles": 8192},
    "flagrall": {"machine": "flagrall", "width": 320, "height": 240, "htotal": 432, "vtotal": 315,
                 "budget": 1030, "spr_tiles": 12288, "bg_tiles": 4096},
}


class Scene:
    def __init__(self, setname, rng):
        self.set = setname
        self.c = CFG[setname]
        self.rng = rng
        self.pal = np.array([rng.randrange(0x8000) for _ in range(0x200)], dtype=np.uint16)
        self.bg = np.array([rng.randrange(self.c["bg_tiles"]) for _ in range(1024)], dtype=np.uint16)
        # unused entries parked on the blank tile 0, as the games do
        self.s0 = np.zeros(2048, dtype=np.uint16)
        self.s1 = np.zeros(2048, dtype=np.uint16)
        for i in range(2048):
            self.s0[i] = rng.randrange(256)          # anywhere: blank tiles draw nothing
        self.sx = 0
        self.sy = 0

    def spr(self, i, x, y, code, flick=False):
        self.s0[i] = ((x & 0xFF) << 8) | (y & 0xFF)
        self.s1[i] = (0x8000 if flick else 0) | ((code & 0x3FFF) << 1) | ((x >> 8) & 1)

    def write(self, d, name):
        fd = d / "frames" / name
        fd.mkdir(parents=True, exist_ok=True)
        st = {"set": self.set, "machine": self.c["machine"], "frame": int(name), "width": self.c["width"],
              "height": self.c["height"], "htotal": self.c["htotal"], "vtotal": self.c["vtotal"],
              "scrollx": int(self.sx) & 0xFFFF, "scrolly": int(self.sy) & 0xFFFF}
        (fd / "state.json").write_text(json.dumps(st, indent=1))
        (fd / "palette.bin").write_bytes(self.pal.astype(">u2").tobytes())
        bgfull = np.concatenate([self.bg, np.zeros(1024, dtype=np.uint16)])
        (fd / "bgram_buf.bin").write_bytes(bgfull[:1024].astype(">u2").tobytes())
        (fd / "spr0_buf.bin").write_bytes(self.s0.astype(">u2").tobytes())
        (fd / "spr1_buf.bin").write_bytes(self.s1.astype(">u2").tobytes())


def nonblank_codes(setname):
    t = gfx(setname, "sprites")
    nz = np.nonzero((t != 0).reshape(len(t), -1).any(axis=1))[0]
    # prefer tiles that also have transparent pixels (overlap order shows)
    part = [int(c) for c in nz if (t[c] == 0).any()]
    full = [int(c) for c in nz if not (t[c] == 0).any()]
    return part, full


def targeted(setname, out, rng):
    c = CFG[setname]
    part, full = nonblank_codes(setname)
    pick = lambda: rng.choice(part if part else full)  # noqa: E731
    run = out / f"{setname}_targeted"
    n = 0

    def emit(sc):
        nonlocal n
        n += 1
        sc.write(run, f"{n:06d}")

    H = c["height"]
    # 1. every x wrap position, one row of sprites per y band
    for xs in (range(480, 512), range(296, 328), range(0, 32)):
        sc = Scene(setname, rng)
        i = 0
        for k, x in enumerate(xs):
            sc.spr(i, x, (k * 7) % 200 + 8, pick())
            i += 1
        emit(sc)
    # 2. y wrap: straddling the top (Y 241-255 draw at Y - 256) and the bottom
    for ys in (range(236, 256), range(H - 16, H + 16 if H + 16 < 256 else 256)):
        sc = Scene(setname, rng)
        for k, y in enumerate(ys):
            sc.spr(k, 10 + k * 15, y, pick())
        emit(sc)
    # 3. corner wrap: X > 496 and Y > 240 together
    sc = Scene(setname, rng)
    for k in range(16):
        sc.spr(k, 497 + k, 241 + k, pick())
    emit(sc)
    # 4. budget edge: entries around the cut, only those below it draw
    for base in (c["budget"] - 3, c["budget"] - 1, 2040):
        sc = Scene(setname, rng)
        for k in range(8):
            sc.spr(min(base + k, 2047), 40 + k * 30, 100, pick())
        emit(sc)
    # 5. sprite tile codes past the end of the region (flagrall: 12,288-16,383)
    sc = Scene(setname, rng)
    for k in range(64):
        sc.spr(k, (k * 37) % 320, (k * 53) % H, c["spr_tiles"] - 32 + k if c["spr_tiles"] < 16384 else 16383 - k)
    emit(sc)
    # 6. flicker on every sprite, overlapping
    sc = Scene(setname, rng)
    for k in range(200):
        sc.spr(k, rng.randrange(512), rng.randrange(256), pick(), flick=rng.random() < 0.7)
    emit(sc)
    # 7. tile map codes past the region end, scroll extremes
    for sx, sy in ((0, 0), (1, 1), (15, 15), (16, 16), (495, 497), (511, 511), (0xFFFF, 0xFFFF),
                   (0x8000, 0x7FFF), (0x1F0, 0x00F), (0x00F, 0x1F0)):
        sc = Scene(setname, rng)
        sc.bg = np.array([rng.randrange(0x10000) for _ in range(1024)], dtype=np.uint16)
        sc.sx, sc.sy = sx, sy
        for k in range(32):
            sc.spr(k, rng.randrange(512), rng.randrange(256), pick())
        emit(sc)
    # 8. dense lines: 64, 96 and 128 non-blank sprites on the same 16 lines,
    # overlapping (later entries on top)
    for cnt in (64, 96, 128):
        sc = Scene(setname, rng)
        for k in range(cnt):
            sc.spr(k * 3, (k * 5) % 330, 100 + (k % 3), pick(), flick=k % 11 == 0)
        emit(sc)
    # 9. same tile stacked: list order decides
    sc = Scene(setname, rng)
    for k in range(40):
        sc.spr(k, 150 + (k % 4), 100 + (k % 4), part[k % len(part)] if part else full[0])
    emit(sc)
    # 10. palette sweep: map covers many pens, sprites all over
    sc = Scene(setname, rng)
    for k in range(300):
        sc.spr(k, rng.randrange(512), rng.randrange(256), pick())
    emit(sc)
    return run, n


def random_scenes(setname, out, rng, count):
    c = CFG[setname]
    part, full = nonblank_codes(setname)
    allnz = part + full
    run = out / f"{setname}_random"
    for n in range(1, count + 1):
        sc = Scene(setname, rng)
        sc.sx, sc.sy = rng.randrange(0x10000), rng.randrange(0x10000)
        if rng.random() < 0.3:
            sc.bg = np.array([rng.randrange(0x10000) for _ in range(1024)], dtype=np.uint16)
        nspr = rng.choice((0, 10, 60, 200, 400, c["budget"]))
        idx = rng.sample(range(2048), min(nspr, 2048))
        for i in idx:
            code = rng.choice(allnz) if rng.random() < 0.95 else rng.randrange(16384)
            sc.spr(i, rng.randrange(512), rng.randrange(256), code, flick=rng.random() < 0.1)
        sc.write(run, f"{n:06d}")
    return run, count


def main(argv):
    out = Path(argv[0])
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 1945
    rng = random.Random(seed)
    if out.exists():
        shutil.rmtree(out)
    for s in CFG:
        r, n = targeted(s, out, rng)
        print(f"{r.name}: {n} scenes")
        r, n = random_scenes(s, out, rng, 60)
        print(f"{r.name}: {n} scenes")


if __name__ == "__main__":
    main(sys.argv[1:])
