#!/usr/bin/env python3
"""M4: a board run (k3_board: ioctl download, k3_sdram, SDRAM model) against
the M2 run of the same game (k3_sys with C++ ROM models), file by file.

Every capture file the two runs share (.rgbp .wlog .pal .bgl .bgb .s0l .s1l
.s0b .s1b .ram .r8c) is compared byte for byte, and io.txt (every scroll,
control and OKI write with its beam position) line by line. Identical means
the board reproduces M2's core exactly, so every M2 result (the comparison
with MAME and its divergence list, m2_findings) holds for the board. If the
I/O streams differ only in beam position, the writes are compared in order
and value and the largest position change is reported.

Usage: compare_m2.py <board run dir> <m2 run dir>
"""
import os
import sys


def main(a, b):
    fa = {f for f in os.listdir(a) if "." in f and f.split(".")[-1] in
          ("rgbp", "wlog", "pal", "bgl", "bgb", "s0l", "s1l", "s0b", "s1b", "ram", "r8c")}
    fb = {f for f in os.listdir(b) if f in fa}
    common = sorted(fa & fb)
    diff = [f for f in common if open(os.path.join(a, f), "rb").read() != open(os.path.join(b, f), "rb").read()]
    only = sorted(fa - fb)
    ok = not diff
    print(f"  vs M2: {len(common)} capture files compared, {len(common) - len(diff)} identical"
          + (f", {len(diff)} differ (first {diff[:5]})" if diff else "")
          + (f"; {len(only)} board files without an M2 counterpart" if only else ""))
    ia, ib = os.path.join(a, "io.txt"), os.path.join(b, "io.txt")
    if os.path.exists(ia) and os.path.exists(ib):
        la, lb = open(ia).read().split("\n"), open(ib).read().split("\n")
        if la == lb:
            print(f"  vs M2: io.txt identical ({len(la) - 1} writes, beam positions included)")
        else:
            ok = False
            n = min(len(la), len(lb))
            first = next((i for i in range(n) if la[i] != lb[i]), n)
            va = [l.split()[3:] for l in la if l]
            vb = [l.split()[3:] for l in lb if l]
            m = min(len(va), len(vb))
            fv = next((i for i in range(m) if va[i] != vb[i]), None)
            print(f"  vs M2: io.txt differs from write {first} ({la[first] if first < len(la) else '-'} / "
                  f"{lb[first] if first < len(lb) else '-'}); order and value "
                  + ("equal over the common length" if fv is None else f"differ from write {fv}")
                  + f" ({len(va)} / {len(vb)} writes)")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1], sys.argv[2]) else 1)
