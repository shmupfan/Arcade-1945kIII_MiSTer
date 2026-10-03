#!/usr/bin/env python3
"""Compare the cumulative ROM-area write count (run.log progress lines,
"vblank N ... romwr K") with MAME's romw taps (writes.csv rows with frame < N).
Usage: romw_check.py <cap_dir> <mame_run_dir>"""
import sys
from pathlib import Path
cap, run = Path(sys.argv[1]), Path(sys.argv[2])
frames = [int(l.split(",")[0]) for l in (run / "writes.csv").read_text().split("\n")[1:]
          if l.count(",") >= 8 and l.split(",")[5] == "romw"]
last = max(int(l.split(",")[0]) for l in (run / "writes.csv").read_text().split("\n")[1:] if l.count(",") >= 8)
ok = bad = 0
for ln in (cap / "run.log").read_text().split("\n"):
    if ln.startswith("vblank "):
        f = ln.split()
        n, k = int(f[1]), int(f[f.index("romwr") + 1])
        if n > last:
            continue
        m = sum(1 for x in frames if x < n)
        ok += m == k
        bad += m != k
        if m != k:
            print(f"vblank {n}: ours {k} MAME {m}")
print(f"romw: {ok} checkpoints equal, {bad} differ (MAME total {len(frames)} up to frame {last})")
sys.exit(1 if bad else 0)
