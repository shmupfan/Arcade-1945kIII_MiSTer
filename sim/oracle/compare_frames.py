#!/usr/bin/env python3
"""Render oracle frame dumps with k3_render.py and diff them against MAME,
pixel for pixel.

Primary check: snap.png, MAME's snapshot of frame N (rotated like the game:
ROT270 snap = numpy.rot90(native, 1); flagrall is ROT0).
Secondary check: screen.argb (screen:pixels() captured one notifier later,
same pens, converted with palette_next.bin), which confirms the pens
independently of the snapshot path.

Palette: MAME shows a power-on default colour for every pen until the game
first writes that entry (real boards have undefined SRAM instead), so for
entries the oracle marks as never written (palette_written.bin) the
comparison takes MAME's pen colour from pens.bin and counts the frames that
showed such pens. Every written entry must decode to MAME's pen exactly.

Usage: compare_frames.py <run_dir> [--diffdir DIR] [--quiet] [--stats CSV]
Exit status 0 only if every frame matches on both checks.
"""
import csv
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent / "mame"))
from k3_render import render, palette_rgb  # noqa: E402
from frame_tools import load_argb  # noqa: E402

ROT0 = {"flagrall"}


def diff_report(tag, name, ours, ref, diffdir):
    neq = np.any(ours != ref, axis=-1)
    n = int(neq.sum())
    if n:
        ys, xs = np.nonzero(neq)
        print(f"DIFF  {name} [{tag}]: {n} px, first (x={xs[0]},y={ys[0]}) mame={tuple(int(v) for v in ref[ys[0], xs[0]])} "
              f"ours={tuple(int(v) for v in ours[ys[0], xs[0]])}, bbox x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()}")
        diffdir.mkdir(parents=True, exist_ok=True)
        vis = np.concatenate([ref, ours, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis, "RGB").save(diffdir / f"{name}_{tag}.png")
    return n


def main(argv):
    run = Path(argv[0])
    diffdir = Path(argv[argv.index("--diffdir") + 1]) if "--diffdir" in argv else run / "diffs"
    statpath = Path(argv[argv.index("--stats") + 1]) if "--stats" in argv else run / "render_stats.csv"
    quiet = "--quiet" in argv
    frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
    if not frames:
        print(f"no frames in {run}")
        return 1
    bad = 0
    checked = {"snap": 0, "pixels": 0}
    unwritten_frames = 0
    px = 0
    rows = []
    for fd in frames:
        st = json.loads((fd / "state.json").read_text())
        rgb, pens, stats = render(fd)
        fail = 0
        ours_pal = palette_rgb((fd / "palette.bin").read_bytes())
        mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:0x200]
        mame_pal = np.stack([(mp >> 16) & 255, (mp >> 8) & 255, mp & 255], axis=-1).astype(np.uint8)
        written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:0x200].astype(bool)
        bad_dec = np.nonzero(np.any(ours_pal[written] != mame_pal[written], axis=-1))[0]
        if len(bad_dec):
            print(f"PALDEC {fd.name}: {len(bad_dec)} written entries decode differently from MAME's pens")
            fail += 1
        eff = ours_pal.copy()
        eff[~written] = mame_pal[~written]
        rgb = eff[pens]
        unwritten_visible = int(np.isin(pens, np.nonzero(~written)[0]).sum())
        unwritten_frames += bool(unwritten_visible)
        snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
        view = rgb if st["machine"] in ROT0 else np.rot90(rgb, 1)
        if view.shape != snap.shape:
            print(f"SHAPE {fd.name}: ours {view.shape} snap {snap.shape}")
            fail += 1
        else:
            fail += bool(diff_report("snap", fd.name, view, snap, diffdir))
            checked["snap"] += 1
            px += snap.shape[0] * snap.shape[1]
        if not unwritten_visible and (fd / "screen.argb").exists():
            pal = palette_rgb((fd / "palette_next.bin").read_bytes())
            fail += bool(diff_report("pixels", fd.name, pal[pens], load_argb(fd), diffdir))
            checked["pixels"] += 1
        bad += bool(fail)
        rows.append([fd.name, stats["budget"], stats["sprites_visible"], int(fail == 0)])
        if not fail and not quiet:
            print(f"MATCH {fd.name}")
    with open(statpath, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["frame", "budget", "sprites_visible", "match"])
        wr.writerows(rows)
    print(f"{len(frames) - bad}/{len(frames)} frames pixel-exact "
          f"(snap checks {checked['snap']}, pixels() checks {checked['pixels']}, {px} snapshot px; "
          f"{unwritten_frames} frames showed never-written palette entries = MAME power-on pens, "
          f"their pixels() check skipped)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
