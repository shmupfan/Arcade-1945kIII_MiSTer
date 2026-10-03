#!/usr/bin/env python3
"""M3: explain every sample of the core's M6295 output against MAME's.

Inputs (one run): the core's per-channel values (tb_snd +okich), its busy
log (+okibusy), and MAME's WAV at -samplerate 7575 (16 x the sum of both
chips in 12-bit units, unresampled). The core must run at MAME's rate
(OKI_HZ=999900 build) for a sample-by-sample comparison.

Model: MAME's sample = the sum, over every phrase the core played, of that
phrase's channel values shifted by a whole number of M6295 samples (a
command lands in a different sample period when the write is a few pixels
apart or the two sample clocks have a different phase; each phrase gets its
own shift), minus a rounding term: MAME truncates each attenuated channel
value toward zero (okim6295.cpp L352, a float product passed as s32), the
core floors it (jt6295 mul[16:5]), so each negative channel value can be
one LSB lower in the core and nothing else may differ.

Phrases: per channel, from busy rising to busy falling in the core (plus a
16-sample margin for the decoder pipeline). Shifts are fitted per phrase in
time order, three passes, each phrase taking the shift in -2..+2 that
minimises the residual over its span. A sample is EXPLAINED when
0 <= MAME - model <= (negative channel values in that sample), and is not
a MAME clip. Every unexplained sample is reported.

Usage: decompose_oki.py okich.raw okibusy.txt mame.wav [--flagrall]
"""
import sys
import wave

import numpy as np

RATE = 7575.0


def load_wav(p):
    w = wave.open(p)
    assert w.getsampwidth() == 2 and w.getframerate() == int(RATE)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int64)
    return x if w.getnchannels() == 1 else x.reshape(-1, 2)[:, 0]


def main(argv):
    ch = np.fromfile(argv[0], dtype="<i2").astype(np.int64).reshape(-1, 8)
    m = load_wav(argv[2])
    G = len(ch)
    # busy log -> per (chip, channel) intervals in sample index
    ev = [tuple(int(x, 16) if i == 2 else int(x) for i, x in enumerate(l.split())) for l in open(argv[1])]
    intervals = {(c, k): [] for c in (1, 2) for k in range(4)}
    prev = {1: 0, 2: 0}
    t_on = {}
    for s, chip, b in ev:
        for k in range(4):
            was, now = (prev[chip] >> k) & 1, (b >> k) & 1
            if now and not was:
                t_on[(chip, k)] = s
            if was and not now:
                intervals[(chip, k)].append((t_on.pop((chip, k)), s))
        prev[chip] = b
    for key, s in t_on.items():
        intervals[key].append((s, G))
    # slot <-> channel: the slot whose nonzero values fall inside the
    # channel's busy intervals
    # jt6295 serves its channels in a fixed rotation, so one offset maps
    # every channel to its slot; take the offset that puts the most nonzero
    # slot values inside their channel's busy intervals, per chip
    slot_of = {}
    for chip in (1, 2):
        masks = {}
        for k in range(4):
            mk = np.zeros(G, dtype=bool)
            for a, b in intervals[(chip, k)]:
                mk[max(0, a - 16):min(G, b + 16)] = True
            masks[k] = mk
        best, brot = -1, 0
        for rot in range(4):
            inside = tot_nz = 0
            for k in range(4):
                col = ch[:, (chip - 1) * 4 + (k + rot) % 4]
                nzc = col != 0
                inside += int((nzc & masks[k]).sum())
                tot_nz += int(nzc.sum())
            if inside > best:
                best, brot = inside, rot
        for k in range(4):
            col = ch[:, (chip - 1) * 4 + (k + brot) % 4]
            nzc = col != 0
            share = (nzc & masks[k]).sum() / nzc.sum() if nzc.sum() else 1.0
            slot_of[(chip, k)] = ((chip - 1) * 4 + (k + brot) % 4, share)
    print("slot map (chip, channel) -> (column, share of its nonzero values inside the channel's busy intervals): "
          + ", ".join(f"{k}->{v[0]} {v[1]:.4f}" for k, v in sorted(slot_of.items())))
    # phrases: (column, start, end) with margins; the core's output o[g+1]
    # is the sum of group g; MAME index = g + 1 + off (alignment below)
    phrases = []
    for key, ivs in intervals.items():
        if key not in slot_of:
            continue
        col = slot_of[key][0]
        ivs = sorted(ivs)
        for j, (a, b) in enumerate(ivs):
            # the decoder pipeline outputs a phrase a few samples after busy
            # rises and keeps it a few samples after busy falls; never run
            # into the channel's next phrase
            nxt = ivs[j + 1][0] if j + 1 < len(ivs) else G
            phrases.append((max(a, 0), col, max(0, a - 2), min(G, b + 16, nxt)))
    phrases.sort()
    print(f"phrases: {len(phrases)}")
    # alignment of the core's group index to MAME's sample index
    tot = ch.sum(1)
    mm = m // 16
    best, off = -1, 0
    nz = np.flatnonzero(mm)
    s0 = nz[0] if len(nz) else 0
    for k in range(-40, 41):
        lo = s0 - k
        if lo < 0:
            continue
        n = min(20000, G - lo, len(mm) - s0)
        c = int((tot[lo:lo + n] == mm[s0:s0 + n]).sum())
        if c > best:
            best, off = c, k
    print(f"alignment: core group g = MAME sample g + {off}")
    N = min(G, len(m) - max(off, 0)) - 4
    idx = np.arange(N)
    target = mm[np.clip(idx + off, 0, len(mm) - 1)]
    clipped = np.abs(m[np.clip(idx + off, 0, len(m) - 1)]) >= 32767
    # contribution of each phrase with a shift
    contrib = [None] * len(phrases)
    shifts = [0] * len(phrases)

    def piece(i, sh, trim=0):
        # phrase i moved by sh samples; trim > 0 drops its last trim samples
        # (MAME stopped it earlier), trim < 0 is not used: a phrase that runs
        # longer in MAME shows as the core dropping samples, i.e. trim on MAME
        _, col, a, b = phrases[i]
        a, b = min(a, N), min(b, N)
        vals = ch[a:b, col].copy()
        if trim > 0:
            nzi = np.flatnonzero(vals)
            if len(nzi):
                vals[max(0, nzi[-1] + 1 - trim):] = 0
        lo, hi = max(0, a + sh), min(N, b + sh)
        v = np.zeros(N, dtype=np.int64)
        if hi > lo:
            v[lo:hi] = vals[lo - (a + sh):hi - (a + sh)]
        return v, lo, hi

    model = np.zeros(N, dtype=np.int64)
    for i in range(len(phrases)):
        v, lo, hi = piece(i, 0)
        contrib[i] = (v, lo, hi)
        model += v
    for _ in range(3):
        for i in range(len(phrases)):
            v0, lo0, hi0 = contrib[i]
            base = model - v0
            bestc, bests, bestv = None, 0, None
            for sh, trim in [(x, t) for x in (0, 1, -1, 2, -2) for t in (0, 1, 2)]:
                v, lo, hi = piece(i, sh, trim)
                L, H = max(0, min(lo, lo0) - 2), min(N, max(hi, hi0) + 2)
                r = target[L:H] - (base[L:H] + v[L:H])
                cost = int((np.abs(np.clip(r, None, 0)) * 4 + np.clip(r - 4, 0, None)).sum())
                if bestc is None or cost < bestc:
                    bestc, bests, bestv = cost, (sh, trim), (v, lo, hi)
            model = base + bestv[0]
            contrib[i] = bestv
            shifts[i] = bests
    # second pass: a phrase still wrong after +-2 is one the game started at
    # a different time (e.g. music restarted when a busy poll saw the channel
    # idle in another frame): find its shift within +-1 s by correlating its
    # values with the residual, then refine
    def explained_mask(mdl, ngs):
        rr = target - mdl
        return (rr >= 0) & (rr <= ngs)

    negs = np.zeros(N, dtype=np.int64)
    for v, lo, hi in contrib:
        negs += (v < 0)
    far = 0
    for i in range(len(phrases)):
        v0, lo0, hi0 = contrib[i]
        if hi0 <= lo0:
            continue
        ok = explained_mask(model, negs)[lo0:hi0]
        if ok.all():
            continue
        base = model - v0
        _, col, a, b = phrases[i]
        a, b = min(a, N), min(b, N)
        vals = ch[a:b, col].astype(float)
        W = 7575
        L0, H0 = max(0, a - W), min(N, b + W)
        res = (target[L0:H0] - base[L0:H0]).astype(float)
        if len(vals) < 8 or len(res) < len(vals):
            continue
        nfft = 1 << int(np.ceil(np.log2(len(res) + len(vals))))
        xc = np.fft.irfft(np.fft.rfft(res, nfft) * np.conj(np.fft.rfft(vals, nfft)), nfft)[:len(res) - len(vals) + 1]
        cand = np.argsort(xc)[::-1][:5] + L0 - a
        best = None
        for sh0 in cand:
            for sh in range(int(sh0) - 2, int(sh0) + 3):
                for trim in (0, 1, 2):
                    v, lo, hi = piece(i, sh, trim)
                    trial = base + v
                    tn = negs - (v0 < 0) + (v < 0)
                    span = slice(max(0, min(lo, lo0) - 2), min(N, max(hi, hi0) + 2))
                    bad_n = int((~explained_mask(trial[span], tn[span])).sum()) if False else int((~((target[span] - trial[span] >= 0) & (target[span] - trial[span] <= tn[span]))).sum())
                    if best is None or bad_n < best[0]:
                        best = (bad_n, sh, trim, v, lo, hi, tn)
        cur_bad = int((~ok).sum())
        if best is not None and best[0] < cur_bad:
            _, sh, trim, v, lo, hi, tn = best
            model = base + v
            negs = tn
            contrib[i] = (v, lo, hi)
            shifts[i] = (sh, trim)
            far += 1
    print(f"phrases moved by more than 2 samples (started at another time): {far}")
    r = target - model
    expl = (r >= 0) & (r <= negs)
    sound = (target != 0) | (model != 0)
    bad = ~expl & ~clipped
    from collections import Counter
    sh_c = Counter(x[0] if isinstance(x, tuple) else x for x in shifts)
    tr_c = Counter(x[1] if isinstance(x, tuple) else 0 for x in shifts)
    print(f"phrase start shifts (core phrase moved by s samples to match MAME): {dict(sorted(sh_c.items()))}; "
          f"phrases ending earlier in MAME by t samples (a stop command in an earlier sample period): {dict(sorted(tr_c.items()))}")
    print(f"samples compared: {N} ({N / RATE:.1f} s), with sound {int(sound.sum())}, MAME clips {int(clipped.sum())}")
    print(f"exact without any rounding: {int((r == 0).sum())}; rounding (0 < MAME - model <= negative channels): "
          f"{int(((r > 0) & expl).sum())}")
    print(f"UNEXPLAINED samples: {int(bad.sum())}")
    if bad.any():
        runs = np.flatnonzero(np.diff(np.concatenate(([0], bad.astype(np.int8), [0]))) == 1)
        for g in runs[:10]:
            print(f"  at core group {g} (t = {g / RATE:.3f} s): MAME {target[g]} model {model[g]} negatives {negs[g]}")
    return int(bad.sum())


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1:]) else 0)
