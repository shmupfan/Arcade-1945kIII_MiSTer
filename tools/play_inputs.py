#!/usr/bin/env python3
"""Print an INPUTS string for k3_oracle.lua that plays a real game: coin,
start, then fire held while the ship sweeps left/right and up/down, with a
bomb every ~10 s. Deterministic, so the capture is reproducible.

Usage: tools/play_inputs.py <machine> <start_frame> <end_frame>
"""
import sys


def main(argv):
    machine, start, end = argv[0], int(argv[1]), int(argv[2])
    ev = []
    def press(f, port, field, dur=6):
        ev.append(f"{f}:{port}:{field}:1")
        ev.append(f"{f + dur}:{port}:{field}:0")
    press(start, "SYSTEM", "Coin 1")
    press(start + 60, "SYSTEM", "Coin 1")
    press(start + 120, "SYSTEM", "1 Player Start")
    # ship select / confirm screens: tap fire a few times
    for k in range(6):
        press(start + 240 + 60 * k, "INPUTS", "P1 Button 1")
    f0 = start + 640
    ev.append(f"{f0}:INPUTS:P1 Button 1:1")
    dirs = ["P1 Left", "P1 Up", "P1 Right", "P1 Down"] if machine == "k3" else ["P1 Left", "P1 Right"]
    f, i = f0 + 30, 0
    while f < end - 60:
        d = dirs[i % len(dirs)]
        ev.append(f"{f}:INPUTS:{d}:1")
        ev.append(f"{f + 45}:INPUTS:{d}:0")
        if machine == "k3" and i % 12 == 11:
            press(f + 50, "INPUTS", "P1 Button 2")
        if i % 30 == 29:   # coin + start again in case the game ended
            press(f + 52, "SYSTEM", "Coin 1")
            press(f + 70, "SYSTEM", "1 Player Start")
        f += 60
        i += 1
    print(";".join(ev))


if __name__ == "__main__":
    main(sys.argv[1:])
