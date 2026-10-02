#!/usr/bin/env python3
"""Replay every mid-scan event frame (sim/m1/midscan.py) through k3_video
with the change applied at the beam position MAME logged, and show that the
RTL differs from MAME only above that position.

Inputs: targeted oracle runs sim/mame/out/mid_<run> holding frames S-1 and S
for each frame S with a visible buffer copy or scroll write.

For each such S:
  1. static: frames S-1 and S as dumped (the M1 gate rule) must match MAME.
  2. live: the frame starts with S-1's buffers and scroll (and S's palette,
     which MAME applies to the whole frame); at the first event's (line,
     hpos) the harness rewrites the CPU-side RAMs with S's contents, sets
     S's scroll and pulses the copy (as the core's system will on the
     0x3c0000 write), with the pixel enable stopped. Then:
       - every row from the first one the renderer draws after the change
         must equal MAME's frame S,
       - every row above the change must equal the old state rendered by
         k3_render.py (what a line renderer shows before the copy),
     so the only difference from MAME is the rows above the change. The
     report lists, per frame, the event, its line and the rows that differ.

Usage: midscan_replay.py <mid_run_dir>... [--csv OUT]
"""
import json
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "oracle"))
from k3_render import palette_rgb, render  # noqa: E402
from midscan import events  # noqa: E402
from replay import check, harness, load_rgbp, make_k3f  # noqa: E402

ARGS = {"lat": 9, "intv": 8, "num": 9, "den": 128}


def mame_native(fd, st):
    snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
    return snap if st["machine"] == "flagrall" else np.rot90(snap, -1)


def effective_palette(fd):
    """The frame's palette as MAME shows it: never-written entries use MAME's
    power-on pens (m0_findings 3)."""
    pal = palette_rgb((fd / "palette.bin").read_bytes())
    mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:0x200]
    written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:0x200].astype(bool)
    mame = np.stack([(mp >> 16) & 255, (mp >> 8) & 255, mp & 255], axis=-1).astype(np.uint8)
    pal[~written] = mame[~written]
    return pal


def main(argv):
    runs = [Path(a) for a in argv if not a.startswith("--")]
    csv_out = Path(argv[argv.index("--csv") + 1]) if "--csv" in argv else None
    if csv_out in runs:
        runs.remove(csv_out)
    rows_out = ["run,frame,event,line,hpos,static_prev,static_frame,live_rows_differ_from_mame,"
                "first_row_drawn_after,rows_after_equal_mame,rows_above_equal_old_state,verdict"]
    bad = 0
    for run in runs:
        frames = {int(p.name): p for p in (run / "frames").iterdir()}
        ev = events(run)
        byframe = {}
        for e in ev:
            byframe.setdefault(e["scan_frame"], []).append(e)
        setname = json.loads((next(iter(frames.values())) / "state.json").read_text())["set"]
        for S in sorted(byframe):
            if S not in frames or S - 1 not in frames:
                print(f"{run.name} {S}: frames not captured")
                bad += 1
                continue
            first = min(byframe[S], key=lambda e: (e["line"], e["hpos"]))
            kinds = "+".join(sorted({e["kind"] for e in byframe[S]}))
            fd_prev, fd = frames[S - 1], frames[S]
            st = json.loads((fd / "state.json").read_text())
            h = st["height"]
            with tempfile.TemporaryDirectory(prefix="k3mid_") as td:
                td = Path(td)
                # 1. static frames
                items = []
                for f in (fd_prev, fd):
                    make_k3f(f, td / f"{f.name}.k3f")
                    items.append((td / f"{f.name}.k3f", td / f"{f.name}.rgbp"))
                # 2. live frame: old buffers/scroll, S's palette, switch at the event
                old = td / "old"
                old.mkdir()
                for name in ("bgram_buf.bin", "spr0_buf.bin", "spr1_buf.bin", "state.json"):
                    shutil.copy(fd_prev / name, old / name)
                for name in ("palette.bin", "pens.bin", "palette_written.bin"):
                    shutil.copy(fd / name, old / name)
                make_k3f(old, td / "live.k3f", switch=(first["line"], first["hpos"], fd))
                items.append((td / "live.k3f", td / "live.rgbp"))
                rc, out, err, stats = harness(td, items, setname, ARGS)
                ok_prev, msg_prev = check(fd_prev, json.loads((fd_prev / "state.json").read_text()),
                                          td / f"{fd_prev.name}.rgbp", run / "m1_diffs")
                ok_s, msg_s = check(fd, st, td / f"{fd.name}.rgbp", run / "m1_diffs")
                _, pen = load_rgbp(td / "live.rgbp", h)
                mame = mame_native(fd, st)
                pal = effective_palette(fd)
                rgb = pal[pen & 0x1FF]          # never-written entries shown as MAME shows them
                _, old_pens, _ = render(old)
                old_rgb = pal[old_pens]
                differ = np.nonzero(np.any(rgb != mame, axis=-1).any(axis=1))[0]
                # the renderer draws line L+1 during line L: a change at
                # (L, hpos > 0) first shows on line L + 2
                after = first["line"] + 2
                rows_after_ok = bool(np.all(rgb[after:] == mame[after:]))
                rows_above_ok = bool(np.all(rgb[:after] == old_rgb[:after]))
                verdict = ok_prev and ok_s and rows_after_ok and rows_above_ok and stats["overruns"] == 0
                bad += not verdict
                span = f"{differ.min()}-{differ.max()}" if len(differ) else "none"
                print(f"{'OK  ' if verdict else 'FAIL'} {run.name} frame {S}: {kinds} at line {first['line']} "
                      f"hpos {first['hpos']}; static S-1 {msg_prev}, S {msg_s}; live rows differing from MAME: "
                      f"{len(differ)} ({span}); rows {after}+ = MAME: {rows_after_ok}; rows above = old state: "
                      f"{rows_above_ok}")
                rows_out.append(f"{run.name},{S},{kinds},{first['line']},{first['hpos']},{ok_prev},{ok_s},"
                                f"{len(differ)} ({span}),{after},{rows_after_ok},{rows_above_ok},"
                                f"{'OK' if verdict else 'FAIL'}")
    if csv_out:
        csv_out.write_text("\n".join(rows_out) + "\n")
    print(f"== {len(rows_out) - 1} event frames, {bad} failing")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
