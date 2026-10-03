#!/usr/bin/env python3
"""Compare two runs of the M2 output format over the frames both have
reached: io.txt line by line (up to the last complete frame of the shorter
run) and every capture file present in both. Used for the jt6295 patch-2
re-run (old M2 outputs vs new) and for partial board runs.
Usage: compare_runs_prefix.py <dir A> <dir B>"""
import os
import sys


def main(a, b):
    la = open(os.path.join(a, "io.txt")).read().split("\n")[:-1]
    lb = open(os.path.join(b, "io.txt")).read().split("\n")[:-1]
    last = min(int(la[-1].split()[0]) if la else 0, int(lb[-1].split()[0]) if lb else 0) - 1
    ka = [l for l in la if int(l.split()[0]) <= last]
    kb = [l for l in lb if int(l.split()[0]) <= last]
    first = next((i for i in range(min(len(ka), len(kb))) if ka[i] != kb[i]), None)
    va = [l.split()[3:] for l in ka]
    vb = [l.split()[3:] for l in kb]
    fv = next((i for i in range(min(len(va), len(vb))) if va[i] != vb[i]), None)
    print(f"  io.txt to frame {last}: {len(ka)} / {len(kb)} writes; "
          + ("identical, beam positions included" if first is None and len(ka) == len(kb) else
             f"first difference at write {first}: {ka[first] if first is not None else '-'} / {kb[first] if first is not None else '-'}; "
             + ("order and value equal" if fv is None and len(va) == len(vb) else f"order/value differ from write {fv}")))
    exts = ("rgbp", "wlog", "pal", "bgl", "bgb", "s0l", "s1l", "s0b", "s1b", "ram", "r8c")
    fa = {f for f in os.listdir(a) if f.split(".")[-1] in exts and f[:6].isdigit() and int(f[:6]) <= last}
    fb = {f for f in os.listdir(b) if f in fa}
    diff = sorted(f for f in fb if open(os.path.join(a, f), "rb").read() != open(os.path.join(b, f), "rb").read())
    print(f"  capture files to frame {last}: {len(fb)} compared, {len(fb) - len(diff)} identical"
          + (f", {len(diff)} differ, first {diff[:6]}" if diff else ""))
    return first is None and not diff


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1], sys.argv[2]) else 1)
