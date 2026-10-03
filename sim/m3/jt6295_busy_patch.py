#!/usr/bin/env python3
"""Patch a copy of jt6295_serial.v so that a start command for a channel
that is still playing is ignored (MSM6295 behaviour as MAME models it,
okim6295.cpp: "Requested to play sample on non-stopped voice"; m3_findings 3).
The start request is still acknowledged so jt6295_ctrl clears it.
Usage: jt6295_busy_patch.py <path to jt6295_serial.v>"""
import sys

p = sys.argv[1]
s = open(p).read()
subs = [
    ("assign update   = up_start | up_stop;",
     "// A start for a channel that is still playing is ignored (MSM6295; MAME\n"
     "// okim6295.cpp). The start request is still acknowledged so the control\n"
     "// block clears it.\n"
     "wire   start_ok = up_start & ~busy_out;\n"
     "assign update   = start_ok | up_stop;"),
    ("assign stop_in  = up_start  ? stop_addr : stop_out;", "assign stop_in  = start_ok  ? stop_addr : stop_out;"),
    ("assign cnt_in   = up_start  ? {start_addr, 1'b0} : cnt_next;", "assign cnt_in   = start_ok  ? {start_addr, 1'b0} : cnt_next;"),
    ("assign att_in   = up_start  ? att : att_out;", "assign att_in   = start_ok  ? att : att_out;"),
    ("assign busy_in  = update    ? (up_start & ~up_stop) : cont;", "assign busy_in  = update    ? (start_ok & ~up_stop) : cont;"),
]
for a, b in subs:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(p, "w").write(s)
