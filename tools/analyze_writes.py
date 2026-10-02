#!/usr/bin/env python3
"""Summarise oracle write logs and sprite-list use for the M0 findings.

For each run directory (sim/mame/out/<run>):
  - scroll writes (0x340000/0x380000): beam lines, how many fall inside the
    visible area, and frames with more than one write (mid-frame changes)
  - 0x3c0000 control writes: data values, beam lines, rising edges of
    bit 0 (k3) / falling edges of bit 5 (flagrall), edges per frame
  - writes to 0x2c0800-0x2c0fff, 0x8c0000-0x8cffff and ROM space
  - OKI port writes
  - sprite list use from the buffered sprite RAM of every dumped frame:
    highest list index that draws a visible pixel, entries past the
    cycle budget that would have drawn, visible entries per frame

Usage: tools/analyze_writes.py <run_dir> [<run_dir> ...]
"""
import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sim" / "oracle"))
from k3_render import gfx, sprite_budget, words  # noqa: E402


NONBLANK = {}


def sprite_use(fd, setname):
    st = json.loads((fd / "state.json").read_text())
    w, h = st["width"], st["height"]
    s0, s1 = words(fd / "spr0_buf.bin"), words(fd / "spr1_buf.bin")
    spr = gfx(setname, "sprites")
    if setname not in NONBLANK:
        NONBLANK[setname] = spr.reshape(len(spr), -1).any(axis=1)
    nb = NONBLANK[setname]
    budget = sprite_budget(st["htotal"], st["vtotal"])
    vis_idx = []
    for i in range(2048):
        a, b = int(s0[i]), int(s1[i])
        x = (a >> 8) | ((b & 1) << 8)
        y = a & 0xff
        code = ((b & 0x7ffe) >> 1) % len(spr)
        if not nb[code]:
            continue
        on = any(ox < w and ox + 16 > 0 and oy < h and oy + 16 > 0
                 for ox, oy in ((x, y), (x, y - 256), (x - 512, y), (x - 512, y - 256)))
        if on:
            vis_idx.append(i)
    return budget, vis_idx


def analyze(run):
    run = Path(run)
    rows = list(csv.DictReader(open(run / "writes.csv")))
    summary = (run / "summary.txt").read_text().splitlines()
    setname = summary[0].split()[1]
    machine = summary[0].split()[3]
    vb = json.loads(next((run / "frames").iterdir()).joinpath("state.json").read_text())["height"] \
        if (run / "frames").exists() else (224 if machine == "k3" else 240)
    out = [f"== {run.name} ({setname}, {machine}, {summary[0].split()[-1]} frames)"]
    by = defaultdict(list)
    for r in rows:
        by[r["class"]].append(r)
    for cls in ("scrollx", "scrolly"):
        ws = by.get(cls, [])
        lines = Counter(int(r["line"]) for r in ws)
        per_frame = Counter(int(r["scan_frame"]) for r in ws)
        vis = sum(int(r["visible"]) for r in ws)
        multi = sum(1 for v in per_frame.values() if v > 1)
        out.append(f"{cls}: {len(ws)} writes, {vis} inside the visible area (lines < {vb}), "
                   f"frames with >1 write {multi}; beam lines {sorted(lines.items())[:12]}")
    ws = by.get("ctrl", [])
    vals = Counter(r["data"] for r in ws)
    out.append(f"ctrl 0x3c0000: {len(ws)} writes, values {dict(vals.most_common(8))}")
    prev = None
    edges = []
    for r in ws:
        d = int(r["data"], 16)
        bit = (d & 1) if machine == "k3" else ((~d >> 5) & 1)
        if prev is not None and prev == 0 and bit == 1:
            edges.append(r)
        prev = bit
    el = Counter(int(r["line"]) for r in edges)
    ef = Counter(int(r["frame"]) for r in edges)
    out.append(f"  buffer copy edges ({'rising bit 0' if machine == 'k3' else 'falling bit 5'}): {len(edges)}; "
               f"beam lines {sorted(el.items())[:16]}; frames with >1 edge {sum(1 for v in ef.values() if v > 1)}")
    if edges:
        fr = sorted(ef)
        gaps = Counter(b - a for a, b in zip(fr, fr[1:]))
        out.append(f"  frames between edges {dict(sorted(gaps.items())[:10])}")
    for cls in ("bgram_hi", "ram8c", "romw", "oki1", "oki2"):
        ws = by.get(cls, [])
        if not ws:
            out.append(f"{cls}: 0 writes")
            continue
        addrs = Counter(r["addr"] for r in ws)
        frames = sorted({int(r["frame"]) for r in ws})
        out.append(f"{cls}: {len(ws)} writes, {len(addrs)} addresses ({min(addrs)}-{max(addrs)}), "
                   f"frames {frames[0]}-{frames[-1]} ({len(frames)} distinct), data {Counter(r['data'] for r in ws).most_common(4)}")
    if (run / "frames").exists():
        maxi, maxn, over = -1, 0, 0
        maxn_frame = None
        for fd in sorted(p for p in (run / "frames").iterdir() if p.is_dir()):
            budget, vis = sprite_use(fd, setname)
            if vis and vis[-1] > maxi:
                maxi = vis[-1]
            if len(vis) > maxn:
                maxn, maxn_frame = len(vis), fd.name
            over += sum(1 for i in vis if i >= budget)
        out.append(f"sprites: budget {budget} entries; most visible entries in one frame {maxn} (frame {maxn_frame}); "
                   f"highest visible list index {maxi}; visible entries past the budget {over}")
    return "\n".join(out)


def main(argv):
    for r in argv:
        print(analyze(r))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
