#!/usr/bin/env python3
"""M3: the core's M6295 output against MAME's, sample by sample and by level.

ours: m3/tb_snd.cpp +oki= raw (int16 OKI 1, int16 OKI 2 per M6295 sample,
      the jt6295 channel sum in 12-bit units).
mame: -wavwrite at -samplerate 7575 (MAME 0.288's M6295 stream rate), which
      MAME writes without resampling: every value is 16 x (OKI 1 + OKI 2) in
      12-bit units (gain 1.0 each into one speaker, L676/L687), clipped to
      16 bits (checked: all unclipped values are multiples of 16).

Sample comparison needs the core run at MAME's effective rate (build
OKI_HZ=999900, m2_findings 5.3), otherwise the streams drift by one sample
every 1.3 s. The streams are aligned on their first sound by an exact-match
search over +-400 samples; then:
  - exact: samples where clip(16 x ours) == MAME's value
  - runs of mismatching samples are reported with their start time, and
    each run is tested for a local shift of up to +-4 samples (a command
    that lands one M6295 sample earlier or later on one side: the write
    timing differs by a few pixels, m2_findings 5.1)
  - level: RMS in dB (ours unclipped vs MAME), over the run and per 5 s
  - clipping: MAME samples at the 16-bit limits, and how far ours exceed it
--hw RAW adds the hardware-rate run (1 MHz / 132 = 7,575.76 Hz): level and
envelope correlation against MAME (time scaled by the rate ratio).
--io / --mame-io: the OKI command streams (ours +io, MAME writes.csv) in
order and value.

Usage: compare_oki.py ours.raw mame.wav [--io io.txt --mame-io writes.csv]
                      [--hw hw.raw] [--max-runs N]
"""
import sys
import wave

import numpy as np

RATE_MAME = 7575.0
RATE_HW = 1000000.0 / 132.0


def load_ours(p):
    a = np.fromfile(p, dtype="<i2").astype(np.int64)
    a = ((a + 8192) & 16383) - 8192          # 14-bit two's complement (jt6295 "sound")
    return a[0::2], a[1::2]


def load_wav(p):
    w = wave.open(p)
    assert w.getsampwidth() == 2 and w.getframerate() == int(RATE_MAME), (w.getsampwidth(), w.getframerate())
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int64)
    if w.getnchannels() == 2:
        x = x.reshape(-1, 2)
        assert (x[:, 0] == x[:, 1]).all(), "MAME channels differ"
        x = x[:, 0]
    return x


def clip16(x):
    return np.clip(x, -32768, 32767)


def align(e, m, search=400, win=20000):
    """offset k such that e[i] ~ m[i + k]; exact-match count around the first sound"""
    nz = np.flatnonzero(m)
    if len(nz) == 0:
        return 0, 0
    s0 = max(0, nz[0] - 50)
    best, bestk = -1, 0
    for k in range(-search, search + 1):
        a0 = s0 - k
        if a0 < 0:
            continue
        n = min(win, len(e) - a0, len(m) - s0)
        if n <= 0:
            continue
        c = int((e[a0:a0 + n] == m[s0:s0 + n]).sum())
        if c > best:
            best, bestk = c, k
    return bestk, best


def db(a, b):
    ra, rb = np.sqrt((a.astype(float) ** 2).mean()), np.sqrt((b.astype(float) ** 2).mean())
    return 20 * np.log10(ra / rb) if ra > 0 and rb > 0 else float("nan")


def runs_of(mask):
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    return list(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)))


def chip_shift_ok(run, o1a, o2a, ma, tol, combos):
    r0, r1 = run
    idx = np.arange(r0, r1)
    for sh1, sh2 in combos:
        if r0 + min(sh1, sh2, 0) < 0 or r1 + max(sh1, sh2, 0) > len(o1a):
            continue
        dd = o1a[idx + sh1] + o2a[idx + sh2] - ma[idx] // 16
        if ((dd <= 0) & (dd >= -tol)).all():
            return True
    return False


def oki_stream(p, mame):
    out = []
    for ln in open(p):
        if mame:
            f = ln.strip().split(",")
            if f[0] == "frame" or not f[5].startswith("oki"):
                continue
            out.append((f[6], int(f[7], 16) & 0xFF))
        else:
            f = ln.split()
            if f[3] not in ("4c0000", "500000"):
                continue
            d, m = int(f[4], 16), int(f[5], 16)
            # k3 byte writes to the even address land on the high lane; the
            # chip sees the byte (m2_findings 2.4); flagrall word writes: low byte
            out.append((f[3], (d >> 8) & 0xFF if m == 0xFF00 else d & 0xFF))
    return out


def main(argv):
    o1, o2 = load_ours(argv[0])
    m = load_wav(argv[1])
    opt = {argv[i]: argv[i + 1] for i in range(2, len(argv) - 1, 2) if argv[i].startswith("--")}
    s = o1 + o2
    e = clip16(16 * s)
    print(f"ours {len(s)} samples ({len(s) / RATE_MAME:.1f} s at MAME's rate), MAME {len(m)} ({len(m) / RATE_MAME:.1f} s)")
    if "--io" in opt and "--mame-io" in opt:
        a, b = oki_stream(opt["--io"], False), oki_stream(opt["--mame-io"], True)
        n = min(len(a), len(b))
        first = next((i for i in range(n) if a[i] != b[i]), None)
        print(f"OKI command stream: ours {len(a)} writes, MAME {len(b)}; "
              + ("identical over the common length" if first is None else f"first difference at write {first}: ours {a[first]} MAME {b[first]}"))
    k, c = align(e, m)
    print(f"alignment: ours[i] = MAME[i + {k}] ({c} exact in the alignment window)")
    a0 = max(0, -k)
    b0 = a0 + k
    n = min(len(e) - a0, len(m) - b0)
    ea, ma, sa = e[a0:a0 + n], m[b0:b0 + n], s[a0:a0 + n]
    ex = ea == ma
    sound = (ma != 0) | (ea != 0)
    print(f"compared {n} samples ({n / RATE_MAME:.1f} s), {int(sound.sum())} with sound on either side")
    print(f"exact: {int(ex.sum())} of {n} ({100 * ex.mean():.4f}%); of the samples with sound: "
          f"{int((ex & sound).sum())} of {int(sound.sum())} ({100 * (ex & sound).sum() / max(1, sound.sum()):.4f}%)")
    # Rounding class: MAME passes each channel's float product (signal x
    # volume) to add_int's s32 sample argument, truncating toward zero
    # (okim6295.cpp L352); jt6295 takes mul[16:5], floor. They differ by one
    # LSB on a negative product with a fraction: ours - MAME in [-TOL, 0],
    # TOL = 4 channels per chip.
    tol = 4 if not (o2 != 0).any() else 8
    d = sa - ma // 16
    clipped = (ma == 32767) | (ma == -32768)
    rnd = (~ex) & (d < 0) & (d >= -tol) & ~clipped
    print(f"rounding class (ours - MAME in [-{tol}, -1] LSB): {int(rnd.sum())} samples; "
          f"distribution {dict(zip(*[a.tolist() for a in np.unique(d[rnd], return_counts=True)]))}")
    other = ~ex & ~rnd & ~clipped
    bad = runs_of(other)
    print(f"other mismatching samples: {int(other.sum())} in {len(bad)} runs")
    explained = 0
    maxruns = int(opt.get("--max-runs", "12"))
    o1a, o2a = o1[a0:a0 + n], o2[a0:a0 + n]
    combos = [(0, b) for b in (1, -1, 2, -2)] + [(a, 0) for a in (1, -1, 2, -2)] + \
             [(a, b) for a in (1, -1, 2, -2) for b in (1, -1, 2, -2)]
    for j, (r0, r1) in enumerate(bad):
        shifted = None
        for sh1, sh2 in combos:
            lo, hi = r0 - 2, r1 + 2
            if lo + min(sh1, sh2, 0) < 0 or hi + max(sh1, sh2, 0) > len(o1a):
                continue
            idx = np.arange(r0, r1)
            dd = o1a[idx + sh1] + o2a[idx + sh2] - ma[idx] // 16
            if ((dd <= 0) & (dd >= -tol)).all():
                shifted = (sh1, sh2)
                break
        if shifted is not None:
            explained += 1
        if j < maxruns:
            print(f"  run {j}: samples {r0}..{r1 - 1} (t = {r0 / RATE_MAME:.3f} s, {r1 - r0} samples)"
                  + (f": equal within rounding with OKI 1 {shifted[0]:+d} and OKI 2 {shifted[1]:+d} samples "
                     "(a command in a different M6295 sample period)" if shifted is not None else ": NOT explained by a shift"))
    print(f"other runs explained by a command on one chip landing one or two M6295 samples apart: {explained} of {len(bad)}")
    left = [rr for rr in bad if not chip_shift_ok(rr, o1a, o2a, ma, tol, combos)]
    if "--ch" in opt:
        # per channel: each channel's phrase may start one sample apart
        # independently (its command landed in a different sample period)
        ch = np.fromfile(opt["--ch"], dtype="<i2").astype(np.int64).reshape(-1, 8)
        # group g sums to the chip output one sample later (checked here)
        g1 = ch[:, :4].sum(1)
        n1 = min(len(g1) - 1, len(o1) - 1)
        assert (o1[1:n1 + 1] == g1[:n1]).all() and (o2[1:n1 + 1] == ch[:n1, 4:].sum(1)).all(), "channel groups do not sum to the chip output"
        cha = np.zeros((n, 8), dtype=np.int64)
        src = np.arange(a0, a0 + n) - 1
        okm = (src >= 0) & (src < len(ch))
        cha[okm] = ch[src[okm]]
        # rounding check per sample: floor and truncation differ only on a
        # negative channel value, so ours - MAME >= -(negative channels)
        negs = (cha < 0).sum(1)
        viol = rnd & (-d > negs)
        print(f"rounding check: {int(rnd.sum())} rounding-class samples, {int(viol.sum())} with a deficit larger "
              f"than their count of negative channels (must be 0 for the truncation explanation)")
        left2 = []
        import itertools
        for (r0, r1) in left:
            lo, hi = max(2, r0 - 2), min(n - 2, r1 + 2)
            act = [j for j in range(8) if np.abs(cha[lo - 2:hi + 2, j]).max() > 0]
            idx = np.arange(r0, r1)
            ok = False
            target = ma[idx] // 16
            for shs in itertools.product((0, 1, -1), repeat=len(act)):
                tot = np.zeros(len(idx), dtype=np.int64)
                for j, sh in zip(act, shs):
                    tot += cha[np.clip(idx + sh, 0, n - 1), j]
                dd = tot - target
                if ((dd <= 0) & (dd >= -len(act))).all():
                    ok = True
                    break
            if not ok:
                left2.append((r0, r1))
        print(f"runs explained per channel (each channel's phrase one sample apart): {len(left) - len(left2)} of {len(left)}")
        for (r0, r1) in left2[:maxruns]:
            print(f"  UNEXPLAINED: samples {r0}..{r1 - 1} (t = {r0 / RATE_MAME:.3f} s, {r1 - r0} samples)")
        left = left2
    print(f"UNEXPLAINED runs: {len(left)}")
    clipm = int(((ma == 32767) | (ma == -32768)).sum())
    over = int(((16 * sa > 32767) | (16 * sa < -32768)).sum())
    print(f"clipping: MAME {clipm} samples at the 16-bit limit; ours exceeds it on {over} samples "
          f"(peak |sum| {int(np.abs(sa).max()) if n else 0} of 2,048 = MAME full scale)")
    print(f"level: ours (unclipped x16) vs MAME: {db(16 * sa, ma):+.3f} dB; clipped like MAME: {db(ea, ma):+.3f} dB")
    seg = int(5 * RATE_MAME)
    segs = []
    for i in range(0, n - seg + 1, seg):
        if np.abs(ma[i:i + seg]).max() > 0:
            segs.append(db(ea[i:i + seg], ma[i:i + seg]))
    if segs:
        print(f"level per 5 s segment with sound: {len(segs)} segments, {min(segs):+.3f} .. {max(segs):+.3f} dB")
    if "--hw" in opt:
        h1, h2 = load_ours(opt["--hw"])
        hs = h1 + h2
        # time scale hardware-rate samples onto MAME's sample grid
        t = np.arange(len(m)) / RATE_MAME
        idx = np.minimum((t * RATE_HW).astype(np.int64), len(hs) - 1)
        hr = clip16(16 * hs[idx])
        nn = min(len(hr), len(m))
        win = 151   # 20 ms
        def env(x):
            q = len(x) // win
            return np.sqrt((x[:q * win].astype(float).reshape(q, win) ** 2).mean(axis=1))
        ea2, em2 = env(hr[:nn]), env(m[:nn])
        cc = np.corrcoef(ea2, em2)[0, 1] if ea2.std() > 0 and em2.std() > 0 else float("nan")
        print(f"hardware rate (7,575.76 Hz): {len(hs)} samples; level vs MAME {db(hr[:nn], m[:nn]):+.3f} dB; "
              f"20 ms envelope correlation {cc:.4f}")


if __name__ == "__main__":
    main(sys.argv[1:])
