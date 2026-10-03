#!/usr/bin/env python3
"""M2: compare a k3_sys boot run (m2/tb_sys.cpp) with a MAME oracle run.

Three checks:

1. I/O write stream (+io log vs MAME writes.csv): every write to scroll X/Y,
   control and the OKIs, in order. Values and order must match; the beam
   position of each write is compared (delta in pixels, 1 pixel = 2.37 CPU
   clocks). The first value or order mismatch is the first divergence.

2. Images: our displayed frame N (pixels between vblank N and N+1) is MAME
   frame N+1 (MAME draws frame M at vblank M, from the state the scan-out
   before it used). Exact against MAME's snapshot (rotated, MAME's power-on
   pens for palette entries never written, as m1/replay.py), or else
   pixel-exact against a line-accurate model of the live reads (section
   below); anything else fails.

3. RAM at vblank N against MAME frame N: palette, tilemap and sprite RAMs
   (live and buffered) from the M0 captures, and work RAM / 0x8c0000 RAM
   from MAINRAM runs (k3_oracle.lua MAINRAM=1) when given with --ram.
   A difference is transient if the next dumped vblank matches again.

Live reads (m1_findings 6, m2_findings): the renderer draws row y during
line y-1 reading the buffers and scroll as they stand, and scans row y out
reading the palette as it stands; MAME draws the whole frame at vblank from
the final values. The model starts from our dumps at vblank N, applies our
logged writes (.wlog) in beam order (a copy edge, decoded per machine as
k3_sys does, moves the live tilemap/sprite RAM into the buffers), and draws
each row from the states inside its windows; a write inside a window may
land either side of the reads, so every state inside the window is
accepted.

Usage: compare.py <cap_dir> <mame_run_dir> [--ram <mame_mainram_run_dir>]
  [--io] [--quiet] [--diff DIR]
Exit 0 only if no image or I/O stream failure and no persistent RAM difference.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "oracle"))
from k3_render import bg_layer, draw_sprites, palette_rgb, sprite_budget  # noqa: E402

ROT0 = {"flagrall"}
CLASSES = {0x340000: "scrollx", 0x380000: "scrolly", 0x3c0000: "ctrl", 0x4c0000: "oki1", 0x500000: "oki2"}


# ---------------------------------------------------------------- I/O stream
def load_io_ours(p):
    out = []
    for ln in p.read_text().split("\n"):
        if len(ln.split()) != 6:          # a run still writing ends mid-line
            continue
        f, line, h, a, d, m = ln.split()
        out.append((int(f), int(line), int(h), int(a, 16), int(d, 16), int(m, 16)))
    return out


def load_io_mame(run):
    out = []
    lines = (run / "writes.csv").read_text().split("\n")
    for ln in lines[1:]:
        f = ln.split(",")
        if len(f) < 9 or f[5] not in CLASSES.values():
            continue
        out.append((int(f[0]), int(f[1]), int(f[2]), int(f[6], 16), int(f[7], 16), int(f[8], 16)))
    return out


def io_compare(ours, mame, vact, vtotal, last_frame):
    """Compare the two streams up to last_frame. Returns a dict."""
    mame = [w for w in mame if w[0] < last_frame]
    ours = [w for w in ours if w[0] < last_frame]
    res = {"ours": len(ours), "mame": len(mame), "first_mismatch": None, "deltas": []}
    for i, (a, b) in enumerate(zip(ours, mame)):
        if a[3:] != b[3:]:
            res["first_mismatch"] = (i, a, b)
            break

        def pos(w):   # absolute pixel time from power-on: vblank f is line vact of frame f
            return (w[0] * vtotal + (w[1] - vact) % vtotal) * 432 + w[2]
        res["deltas"].append((a[0], pos(a) - pos(b)))
    if res["first_mismatch"] is None and len(ours) != len(mame):
        n = min(len(ours), len(mame))
        res["first_mismatch"] = (n, ours[n] if n < len(ours) else None, mame[n] if n < len(mame) else None)
    return res


# ---------------------------------------------------------------- images
def load_rgbp(p, h):
    raw = np.frombuffer(p.read_bytes(), dtype=np.uint8)
    if raw.size != 320 * h * 5:
        return None, None
    raw = raw.reshape(h, 320, 5)
    return raw[..., :3].copy(), raw[..., 3].astype(np.int64) | (raw[..., 4].astype(np.int64) << 8)


def mame_view(fd, rgb, pen, machine):
    mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:0x200]
    written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:0x200].astype(bool)
    view = rgb
    unw = ~written[pen & 0x1FF]
    if unw.any():
        c = mp[pen[unw] & 0x1FF]
        view = rgb.copy()
        view[unw] = np.stack([(c >> 16) & 255, (c >> 8) & 255, c & 255], axis=-1)
    return view if machine in ROT0 else np.rot90(view, 1)


def scroll_at(io, frame, line, h, vact, vtotal):
    """Scroll registers in effect at beam (frame, line, h), from our io log
    (power-on value 0, k3_video reset)."""
    sx = sy = 0
    t = (frame * vtotal + (line - vact) % vtotal) * 432 + h
    for w in io:
        tw = (w[0] * vtotal + (w[1] - vact) % vtotal) * 432 + w[2]
        if tw >= t:
            break
        if w[3] == 0x340000:
            sx = w[4]
        elif w[3] == 0x380000:
            sy = w[4]
    return sx, sy


def refresh_at(io, frame, line, h, vact, vtotal, flagrall):
    """Control flip-flop state at a beam position (power-on 0)."""
    r = 0
    t = (frame * vtotal + (line - vact) % vtotal) * 432 + h
    for w in io:
        tw = (w[0] * vtotal + (w[1] - vact) % vtotal) * 432 + w[2]
        if tw >= t:
            break
        if w[3] == 0x3c0000:
            r = new_refresh(w[4], w[5], flagrall)
    return r


def new_refresh(d, m, flagrall):
    if flagrall:
        return 0 if (d & m) & 0x20 else 1
    return d & 1


def line_check(cap, n, rgb, st, io, setname):
    """Pixels of displayed frame n matching no allowed live-read state."""
    machine = st["machine"]
    flag = machine == "flagrall"
    vact, vtotal, w_, h_ = (240, 315, 320, 240) if flag else (224, 262, 320, 224)
    base = cap / f"{n:06d}"
    pal0 = bytearray(Path(f"{base}.pal").read_bytes())
    live = {k: bytearray(Path(f"{base}.{e}").read_bytes()) for k, e in (("bg", "bgl"), ("s0", "s0l"), ("s1", "s1l"))}
    buf = {k: bytearray(Path(f"{base}.{e}").read_bytes()) for k, e in (("bg", "bgb"), ("s0", "s0b"), ("s1", "s1b"))}
    sx, sy = scroll_at(io, n, vact, 0, vact, vtotal)
    ref = refresh_at(io, n, vact, 0, vact, vtotal, flag)
    # events in beam order from vblank n: (t, kind, ...)
    ev = []
    wl = Path(f"{base}.wlog")
    for ln in (wl.read_text().split("\n") if wl.exists() else []):
        if not ln:
            continue
        line, h, a, d, m = ln.split()
        line, h, a, d, m = int(line), int(h), int(a, 16), int(d, 16), int(m, 16)
        ev.append((((line - vact) % vtotal) * 432 + h, a, d, m))
    budget = sprite_budget(432, vtotal)

    def wr(b, off, d, m):
        if m & 0xFF00:
            b[off] = d >> 8
        if m & 0x00FF:
            b[off + 1] = d & 0xFF

    # snapshots of (bg/sprite buffers + scroll) and palette after each event
    vstates = [(bytes(buf["bg"]), bytes(buf["s0"]), bytes(buf["s1"]), sx, sy)]
    vtimes = [-1]
    pstates = [bytes(pal0)]
    ptimes = [-1]
    for t, a, d, m in ev:
        vchange = pchange = False
        if 0x200000 <= a < 0x200400:
            wr(pal0, a - 0x200000, d, m)
            pchange = True
        elif 0x240000 <= a < 0x241000:
            wr(live["s0"], a - 0x240000, d, m)
        elif 0x280000 <= a < 0x281000:
            wr(live["s1"], a - 0x280000, d, m)
        elif 0x2c0000 <= a < 0x2c0800:
            wr(live["bg"], a - 0x2c0000, d, m)
        elif a == 0x340000:
            sx = d
            vchange = True
        elif a == 0x380000:
            sy = d
            vchange = True
        elif a == 0x3c0000:
            nv = new_refresh(d, m, flag)
            if not ref and nv:
                for k in buf:
                    buf[k] = bytearray(live[k])
                vchange = True
            ref = nv
        if vchange:
            vstates.append((bytes(buf["bg"]), bytes(buf["s0"]), bytes(buf["s1"]), sx, sy))
            vtimes.append(t)
        if pchange:
            pstates.append(bytes(pal0))
            ptimes.append(t)

    def idx_range(times, lo, hi):
        """States in effect at some point of [lo, hi]."""
        first = max(i for i, tt in enumerate(times) if tt < lo) if lo >= 0 else 0
        last = max(i for i, tt in enumerate(times) if tt < hi)
        return range(first, last + 1)

    pen_cache, pal_cache = {}, {}

    def pens_of(i):
        if i not in pen_cache:
            bg, s0, s1, x, y = vstates[i]
            p = bg_layer(setname, np.frombuffer(bg, dtype=">u2").astype(np.int64), x, y, w_, h_)
            draw_sprites(setname, np.frombuffer(s0, dtype=">u2").astype(np.int64),
                         np.frombuffer(s1, dtype=">u2").astype(np.int64), p, budget)
            pen_cache[i] = p
        return pen_cache[i]

    def pal_of(j):
        if j not in pal_cache:
            pal_cache[j] = palette_rgb(pstates[j])
        return pal_cache[j]

    bad = 0
    for y in range(h_):
        # row y drawn during line y-1 (row 0 during the last vblank line),
        # scanned out during line y; times from vblank n
        draw_lo = ((y - 1 - vact) % vtotal) * 432
        draw_hi = draw_lo + 432
        scan_lo = ((y - vact) % vtotal) * 432
        scan_hi = scan_lo + 432
        ok = np.zeros(w_, dtype=bool)
        for i in idx_range(vtimes, draw_lo, draw_hi):
            for j in idx_range(ptimes, scan_lo, scan_hi):
                ok |= np.all(pal_of(j)[pens_of(i)[y]] == rgb[y], axis=-1)
                if ok.all():
                    break
            if ok.all():
                break
        bad += int((~ok).sum())
    return bad, len(pen_cache), len(ev)


def stack_base(ramrun):
    """Work RAM offset where the stack region starts: the 68000 stack grows
    down from 0x10fffe (reset SSP, all sets); below it the games leave a gap
    that is zero in every MAME dump. The region is the block of bytes that
    are ever non-zero above the largest such gap."""
    nz = np.zeros(0x10000, dtype=bool)
    for f in sorted((ramrun / "frames").iterdir()):
        p = f / "mainram.bin"
        if p.exists():
            nz |= np.frombuffer(p.read_bytes(), dtype=np.uint8) != 0
    used = np.nonzero(nz)[0]
    if len(used) < 2:
        return 0x10000
    gaps = np.diff(used)
    k = int(np.argmax(gaps))
    return int(used[k + 1])


# ---------------------------------------------------------------- main
def main(argv):
    cap, run = Path(argv[0]), Path(argv[1])
    quiet = "--quiet" in argv
    ramrun = Path(argv[argv.index("--ram") + 1]) if "--ram" in argv else None
    diffdir = Path(argv[argv.index("--diff") + 1]) if "--diff" in argv else None
    frames = run / "frames"
    first = next(p for p in sorted(frames.iterdir()) if (p / "state.json").exists())
    st0 = json.loads((first / "state.json").read_text())
    machine, setname = st0["machine"], st0["set"]
    flag = machine == "flagrall"
    vact, vtotal, h = (240, 315, 240) if flag else (224, 262, 224)
    io = load_io_ours(cap / "io.txt") if (cap / "io.txt").exists() else []
    caps = sorted(cap.glob("*.rgbp"))
    last = int(caps[-1].stem) + 1 if caps else 0
    rc = 0

    # 1. I/O stream
    # bound by the last frame our log reached (a run still writing has not
    # flushed its log up to its last capture)
    io_last = max((w[0] for w in io), default=0)
    mio = load_io_mame(run)
    mame_last = max((w[0] for w in mio), default=0)       # MAME's run may end earlier
    r = io_compare(io, mio, vact, vtotal, min(last + 1, io_last, mame_last))
    d = [x for _, x in r["deltas"]]
    if d:
        da = np.array(d)
        print(f"io: {r['ours']} writes ours, {r['mame']} MAME up to frame {last}; beam delta (ours - MAME, pixels): "
              f"min {da.min()} median {int(np.median(da))} max {da.max()}")
    if r["first_mismatch"]:
        i, a, b = r["first_mismatch"]
        print(f"io: FIRST DIVERGENCE at write {i}: ours {a} MAME {b}")
    else:
        print("io: every write equal in order and value")
    io_ok_until = r["first_mismatch"][1][0] if r["first_mismatch"] and r["first_mismatch"][1] else None

    # 2. images (a frame after the first I/O divergence is not explained by
    # the live-read model: the two runs no longer execute the same program)
    io_div_frame = None
    if r["first_mismatch"] and r["first_mismatch"][1] and r["first_mismatch"][2]:
        io_div_frame = min(r["first_mismatch"][1][0], r["first_mismatch"][2][0])
    after_div = 0
    state_diff = 0
    state_list = []
    ok_img = expl = bad_img = 0
    bad_list = []
    for p in caps:
        n = int(p.stem)
        fd = frames / f"{n + 1:06d}"
        if not (fd / "snap.png").exists():
            continue
        st = json.loads((fd / "state.json").read_text())
        rgb, pen = load_rgbp(p, h)
        if rgb is None:
            print(f"SHORT {n}")
            bad_img += 1
            continue
        view = mame_view(fd, rgb, pen, machine)
        snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
        nd = int(np.any(view != snap, axis=-1).sum()) if view.shape == snap.shape else -1
        if nd == 0:
            ok_img += 1
            continue
        if io_div_frame is not None and n >= io_div_frame:
            after_div += 1
            continue
        # the live-read model starts from our video RAM at vblank n, so it
        # only explains a frame if that state is MAME's too
        fdn = frames / f"{n:06d}"
        if fdn.exists() and any((cap / f"{n:06d}.{e}").exists() and (cap / f"{n:06d}.{e}").read_bytes() != (fdn / nm).read_bytes()
                               for e, nm in (("pal", "palette.bin"), ("bgl", "bgram_live.bin"), ("bgb", "bgram_buf.bin"),
                                             ("s0l", "spr0_live.bin"), ("s1l", "spr1_live.bin"),
                                             ("s0b", "spr0_buf.bin"), ("s1b", "spr1_buf.bin"))):
            state_diff += 1
            state_list.append(n)
            continue
        lc, nst, nev = line_check(cap, n, rgb, st, io, setname)
        if lc == 0:
            expl += 1
            if not quiet:
                print(f"EXPL  disp {n}: {nd} px vs MAME frame {n + 1}, line-exact against the live-read model "
                      f"({nev} writes, {nst} states)")
            continue
        bad_img += 1
        bad_list.append(n)
        print(f"DIFF  disp {n}: {nd} px vs MAME frame {n + 1}; live-read model leaves {lc} px")
        if diffdir:
            diffdir.mkdir(parents=True, exist_ok=True)
            neq = np.any(view != snap, axis=-1)
            vis = np.concatenate([snap, view, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
            Image.fromarray(vis.astype(np.uint8), "RGB").save(diffdir / f"{n:06d}.png")
    print(f"images: {ok_img} exact vs MAME, {expl} differ only by live reads (line-exact against the model), "
          f"{bad_img} unexplained" + (f" (first {bad_list[0]})" if bad_list else "")
          + (f"; {after_div} differing frames after the I/O divergence at frame {io_div_frame}" if after_div else "")
          + (f"; {state_diff} differing frames whose video RAM at vblank N already differs from MAME's (first {state_list[0]})" if state_diff else ""))
    rc |= state_diff != 0
    rc |= bad_img != 0

    # 3. RAM
    pairs = (("pal", "palette.bin"), ("bgl", "bgram_live.bin"), ("bgb", "bgram_buf.bin"),
             ("s0l", "spr0_live.bin"), ("s1l", "spr1_live.bin"), ("s0b", "spr0_buf.bin"), ("s1b", "spr1_buf.bin"))
    res = []
    dead_stack = []
    sbase = stack_base(ramrun) if ramrun is not None else 0x10000
    if ramrun is not None:
        print(f"RAM: stack region 0x{0x100000 + sbase:06x}-0x10ffff (above the largest always-zero gap in MAME's dumps)")
    for p in sorted(cap.glob("*.pal")):
        n = int(p.stem)
        out = []
        fd = frames / f"{n:06d}"
        if fd.exists():
            for ext, name in pairs:
                a, b = (cap / f"{n:06d}.{ext}").read_bytes(), (fd / name).read_bytes()
                out.append((ext, sum(x != y for x, y in zip(a, b))))
        if ramrun is not None:
            fr = ramrun / "frames" / f"{n:06d}"
            sp = json.loads((fr / "cpu.json").read_text())["sp"] if (fr / "cpu.json").exists() else None
            for ext, name in (("ram", "mainram.bin"), ("r8c", "ram8c.bin")):
                if (fr / name).exists() and (cap / f"{n:06d}.{ext}").exists():
                    a, b = (cap / f"{n:06d}.{ext}").read_bytes(), (fr / name).read_bytes()
                    diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
                    if ext == "ram":
                        # the stack region (stack_base(), from MAME's own
                        # dumps): bytes below MAME's stack pointer are dead,
                        # bytes above it are the live frames (return
                        # addresses, saved registers), which differ when the
                        # vblank catches the CPU at another point of the same
                        # program (m2_findings 5.2). Both are reported, not
                        # gated; the rest of work RAM is.
                        stk = [i for i in diff if i >= sbase]
                        dead = [i for i in stk if sp is not None and 0x100000 + i < sp]
                        dead_stack.append((n, len(dead), len(stk) - len(dead)))
                        diff = [i for i in diff if i < sbase]
                    out.append((ext, len(diff)))
        if out:
            res.append((n, out))
    transient = persistent = 0
    first_persist = None
    files_ok = files_bad = 0
    for i, (n, out) in enumerate(res):
        nbad = [(e, k) for e, k in out if k]
        files_ok += len(out) - len(nbad)
        files_bad += len(nbad)
        if not nbad:
            continue
        nxt_ok = i + 1 < len(res) and all(k == 0 for _, k in res[i + 1][1])
        if nxt_ok:
            transient += 1
        else:
            persistent += 1
            first_persist = first_persist or n
        if not quiet or not nxt_ok:
            print(f"RAM   vblank {n}: " + " ".join(f"{e}:{k}" for e, k in nbad) + (" (transient)" if nxt_ok else " (PERSISTS)"))
    print(f"RAM: {len(res)} vblanks, {files_ok} dumps equal, {files_bad} differ; "
          f"{transient} vblanks transient, {persistent} persistent" + (f" (first {first_persist})" if first_persist else ""))
    nd = [k for _, k, _ in dead_stack if k]
    nl = [k for _, _, k in dead_stack if k]
    if dead_stack:
        print(f"RAM: stack region: dead bytes (below MAME's SP) differ at {len(nd)} of {len(dead_stack)} vblanks"
              + (f" (at most {max(nd)})" if nd else "")
              + f"; live frame bytes differ at {len(nl)}" + (f" (at most {max(nl)})" if nl else ""))
    rc |= persistent != 0
    rc |= r["first_mismatch"] is not None
    if io_ok_until is not None:
        print(f"io stream identical up to frame {io_ok_until}")
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
