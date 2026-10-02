#!/usr/bin/env python3
"""M1 video parity: replay oracle frame dumps through the k3_video RTL
(Verilator harness sim/m1/tb_video.cpp) and compare every frame.

Reference per frame:
  - MAME's snapshot (snap.png) when the frame dir has one: the M1 gate.
    Palette entries the game never wrote show MAME's power-on pen (spec 6,
    m0_findings 3); for those pixels the RTL pen is looked up in pens.bin,
    as sim/oracle/compare_frames.py does for the Python renderer.
  - otherwise (synthetic scenes) the Python reference renderer
    sim/oracle/k3_render.py through the frame's palette.
On every frame the RTL pen index is also checked against k3_render's pen.

Usage:
  replay.py <run_dir>... [--jobs N] [--batch N] [--lat N] [--intv N]
            [--num N] [--den N] [--limit N] [--quiet]
run_dir holds frames/NNNNNN/ (sim/mame/out/<run> or a synthetic scene dir).
Exit 0 only if every frame matches and no line overran its budget.
"""
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "oracle"))
from k3_render import palette_rgb, render  # noqa: E402

BIN = HERE.parent / "build" / "m1" / "obj_dir" / "Vk3_video"
REGIONS = ROOT / "sim" / "build" / "regions"
ROT0 = {"flagrall"}


def ram(fd, name, nbytes):
    p = fd / name
    return ((p.read_bytes() if p.exists() else b"") + bytes(nbytes))[:nbytes]


def state_bytes(fd, st):
    return (int(st["scrollx"]) & 0xFFFF).to_bytes(2, "little") + (int(st["scrolly"]) & 0xFFFF).to_bytes(2, "little")


def make_k3f(fd, path, switch=None):
    """switch = (line, hpos, frame_dir_after): optional mid-frame change."""
    st = json.loads((fd / "state.json").read_text())
    game = 1 if st["machine"] == "flagrall" else 0
    body = (b"K3F1" + bytes([game, 1 if switch else 0]) + state_bytes(fd, st)
            + ram(fd, "palette.bin", 1024) + ram(fd, "bgram_buf.bin", 2048)
            + ram(fd, "spr0_buf.bin", 4096) + ram(fd, "spr1_buf.bin", 4096))
    if switch:
        line, hpos, fd2 = switch
        st2 = json.loads((fd2 / "state.json").read_text())
        body += (line.to_bytes(2, "little") + hpos.to_bytes(2, "little") + state_bytes(fd2, st2)
                 + ram(fd2, "bgram_buf.bin", 2048) + ram(fd2, "spr0_buf.bin", 4096)
                 + ram(fd2, "spr1_buf.bin", 4096))
    path.write_bytes(body)
    return st


def load_rgbp(out_path, h):
    raw = np.frombuffer(out_path.read_bytes(), dtype=np.uint8)
    if raw.size != 320 * h * 5:
        return None, None
    raw = raw.reshape(h, 320, 5)
    return raw[..., :3].copy(), raw[..., 3].astype(np.int64) | (raw[..., 4].astype(np.int64) << 8)


def check(fd, st, out_path, diffdir):
    """Return (ok, message)."""
    h = st["height"]
    rgb, pen = load_rgbp(out_path, h)
    if rgb is None:
        return False, f"size {out_path.stat().st_size}"
    _, ref_pens, _ = render(fd)
    msgs = []
    npen = int((pen != ref_pens).sum())
    if npen:
        ys, xs = np.nonzero(pen != ref_pens)
        msgs.append(f"pen {npen} px, first x={xs[0]} y={ys[0]} rtl={pen[ys[0], xs[0]]:#x} ref={ref_pens[ys[0], xs[0]]:#x}")
    snap_p = fd / "snap.png"
    if snap_p.exists():
        view = rgb
        mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:0x200]
        written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:0x200].astype(bool)
        unw = ~written[pen & 0x1FF]
        if unw.any():
            c = mp[pen[unw] & 0x1FF]
            view = rgb.copy()
            view[unw] = np.stack([(c >> 16) & 255, (c >> 8) & 255, c & 255], axis=-1)
        if st["machine"] not in ROT0:
            view = np.rot90(view, 1)
        ref = np.array(Image.open(snap_p).convert("RGB"))
        tag = "snap"
    else:
        ref = palette_rgb((fd / "palette.bin").read_bytes())[ref_pens]
        view = rgb
        tag = "model"
    if view.shape != ref.shape:
        return False, f"shape {view.shape} vs {ref.shape}"
    neq = np.any(view != ref, axis=-1)
    n = int(neq.sum())
    if n:
        ys, xs = np.nonzero(neq)
        msgs.append(f"{tag} {n} px, first x={xs[0]} y={ys[0]} ref={tuple(int(v) for v in ref[ys[0], xs[0]])} "
                    f"rtl={tuple(int(v) for v in view[ys[0], xs[0]])}")
        diffdir.mkdir(parents=True, exist_ok=True)
        vis = np.concatenate([ref, view, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis, "RGB").save(diffdir / f"{fd.name}_{tag}.png")
    return (not msgs), ("; ".join(msgs) if msgs else tag)


def harness(td, items, setname, args):
    """items: list of (in_path, out_path). Returns (rc, stdout, stderr, stats)."""
    (td / "list.txt").write_text("".join(f"{a} {b}\n" for a, b in items))
    cmd = [str(BIN), f"+sdram={REGIONS / setname / 'sdram.bin'}", f"+list={td / 'list.txt'}",
           f"+lat={args['lat']}", f"+intv={args['intv']}", f"+num={args['num']}", f"+den={args['den']}"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    stats = {"overruns": 0, "maxcyc": 0}
    for ln in p.stdout.splitlines():
        if ln.startswith("FRAME"):
            f = ln.split()
            stats["overruns"] += int(f[3])
            stats["maxcyc"] = max(stats["maxcyc"], int(f[5]))
    return p.returncode, p.stdout, p.stderr, stats


def run_batch(batch, setname, args, diffdir):
    with tempfile.TemporaryDirectory(prefix="k3m1_") as td:
        td = Path(td)
        items, states = [], []
        for fd in batch:
            inp, outp = td / f"{fd.name}.k3f", td / f"{fd.name}.rgbp"
            states.append(make_k3f(fd, inp))
            items.append((inp, outp))
        rc, _, err, stats = harness(td, items, setname, args)
        if rc not in (0, 1):
            return [(fd, False, f"harness rc {rc}: {err[-300:]}") for fd in batch], stats
        res = []
        for fd, st, (_, outp) in zip(batch, states, items):
            if not outp.exists():
                res.append((fd, False, "no output"))
                continue
            ok, msg = check(fd, st, outp, diffdir)
            res.append((fd, ok, msg))
        return res, stats


def budget_clocks(args):
    return 432 * args["den"] // args["num"]


def main(argv):
    opts = {"jobs": os.cpu_count() or 4, "batch": 40, "lat": 9, "intv": 8, "num": 9, "den": 128, "limit": 0}
    runs, quiet = [], False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--quiet":
            quiet = True
        elif a.startswith("--"):
            opts[a[2:]] = int(argv[i + 1])
            i += 1
        else:
            runs.append(Path(a))
        i += 1
    if not BIN.exists():
        sys.exit(f"missing {BIN}; run make m1-build")
    rc = 0
    total = good_all = 0
    for run in runs:
        frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
        if opts["limit"]:
            frames = frames[:opts["limit"]]
        setname = json.loads((frames[0] / "state.json").read_text())["set"]
        batches = [frames[k:k + opts["batch"]] for k in range(0, len(frames), opts["batch"])]
        diffdir = run / "m1_diffs"
        good = over = maxcyc = 0
        tags = {}
        with ThreadPoolExecutor(max_workers=opts["jobs"]) as ex:
            for res, stats in ex.map(lambda b: run_batch(b, setname, opts, diffdir), batches):
                over += stats["overruns"]
                maxcyc = max(maxcyc, stats["maxcyc"])
                for fd, ok, msg in res:
                    good += ok
                    if ok:
                        tags[msg] = tags.get(msg, 0) + 1
                    if not ok or not quiet:
                        print(f"{'MATCH' if ok else 'DIFF '} {run.name}/{fd.name}: {msg}")
        print(f"== {run.name}: {good}/{len(frames)} frames exact ({tags}); line overruns {over}; "
              f"max render clocks/line {maxcyc} (budget {budget_clocks(opts)}; "
              f"ROM 1 req / {opts['intv']} clk, latency {opts['lat']})", flush=True)
        total += len(frames)
        good_all += good
        if good != len(frames) or over:
            rc = 1
    if len(runs) > 1:
        print(f"== total {good_all}/{total}")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
