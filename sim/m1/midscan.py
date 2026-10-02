#!/usr/bin/env python3
"""Find every frame whose buffer copy or scroll write lands in the visible
lines, from the oracle write logs (sim/mame/out/<run>/writes.csv).

MAME draws frame N at vblank from the buffers and scroll as they stand
then (spec 9, m0_findings 5), so a change during frame N's scan-out shows on
every line of frame N. k3_video reads the buffers and scroll live, line by
line, so on the PCB-like timing such a frame shows the old state above the
change and the new state below it. These frames are the expected
divergences between the core and MAME (research item R3); every other frame
must match MAME exactly.

Copy edges (spec 9): k3 sets copy on a rising edge of bit 0 of the 0x3c0000
write (m_refresh starts at 0, 1945kiii.cpp:160, 343); flagrall copies when
bit 5 of (data & mask) falls (BIT(~data, 5) rising, L363).

Usage: midscan.py <run_dir>... [--csv OUT] [--frames]
  --frames  print a DUMP_FRAMES list (scan frame and the one before) for a
            targeted oracle capture of every event
"""
import csv
import json
import sys
from pathlib import Path


def events(run):
    """Visible copy and scroll events of one run: dicts with scan_frame,
    kind, line, hpos, data."""
    st = None
    frames_dir = run / "frames"
    first = next(iter(sorted(frames_dir.iterdir())), None) if frames_dir.exists() else None
    if first is not None:
        st = json.loads((first / "state.json").read_text())
    flag = st is not None and st["machine"] == "flagrall"
    refresh = 0
    out = []
    with open(run / "writes.csv") as f:
        for r in csv.DictReader(f):
            cls = r["class"]
            if cls not in ("ctrl", "scrollx", "scrolly"):
                continue
            data, mask = int(r["data"], 16), int(r["mask"], 16)
            ev = None
            if cls == "ctrl":
                new = (((data & mask) >> 5) & 1) ^ 1 if flag else data & 1
                if new and not refresh:
                    ev = "copy"
                refresh = new
            else:
                ev = cls
            if ev and r["visible"] == "1":
                out.append({"run": run.name, "scan_frame": int(r["scan_frame"]), "kind": ev,
                            "line": int(r["line"]), "hpos": int(r["hpos"]), "data": data})
    return out


def main(argv):
    runs = [Path(a) for a in argv if not a.startswith("--")]
    csv_out = Path(argv[argv.index("--csv") + 1]) if "--csv" in argv else None
    if csv_out in runs:
        runs.remove(csv_out)
    allev = []
    for run in runs:
        ev = events(run)
        dumped = {int(p.name) for p in (run / "frames").iterdir()} if (run / "frames").exists() else set()
        for e in ev:
            e["captured"] = e["scan_frame"] in dumped
            e["prev_captured"] = (e["scan_frame"] - 1) in dumped
        allev += ev
        frames = sorted({e["scan_frame"] for e in ev})
        print(f"{run.name}: {len(ev)} visible events in {len(frames)} frames "
              f"({sum(e['kind'] == 'copy' for e in ev)} copies); captured frames among them: "
              f"{sorted({e['scan_frame'] for e in ev if e['captured']})}")
        if "--frames" in argv:
            print("  DUMP_FRAMES=" + ",".join(f"{f - 1}-{f}" for f in frames))
    if csv_out:
        with open(csv_out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["run", "scan_frame", "kind", "line", "hpos", "data",
                                              "captured", "prev_captured"])
            w.writeheader()
            w.writerows(allev)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
