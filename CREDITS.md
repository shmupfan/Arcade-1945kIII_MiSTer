# Credits and third-party components

This core combines new RTL with proven open-source components. Every
third-party component retains its own license and copyright headers in
place; the combined work is distributed under GPL-3.0-or-later (see
LICENSE). Local modifications to vendored cores are documented in each
component's `PROVENANCE.md`.

## New work in this repository

- Video (`rtl/k3_video.sv`, `rtl/k3_fifo.sv`, `rtl/k3_dpram.sv`): line
  renderer for the tile layer and the sprite list, with the sprite and
  tile RAM buffers. GPL-3.0-or-later.
- System glue (`rtl/k3_sys.sv`), SDRAM controller (`rtl/k3_sdram.sv`),
  board wrapper (`rtl/k3_board.sv`), MiSTer shell (`Arcade-1945kIII.sv`),
  simulation and verification harness (`sim/`), tooling (`tools/`).
  GPL-3.0-or-later.

## Vendored cores (`rtl/vendor/`)

| Component | Author | License | Upstream |
|---|---|---|---|
| fx68k (68000, cycle-accurate) | Jorge Cwik | GPL-3.0 | https://github.com/ijor/fx68k |
| jt6295 (OKI MSM6295) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt6295 |

Local changes:

- fx68k carries the Verilator portability patches from the Hyper Duel
  core (no functional change; `rtl/vendor/fx68k/PROVENANCE.md`).
- jt6295 carries Hyper Duel's Quartus RAM-inference workaround and
  simulation-only Verilator annotations, neither changing behaviour, plus
  three behaviour fixes that match MAME's M6295 model: a phrase plays
  through the second nibble of its stop byte; a start command to a
  channel that is still playing is ignored; and the busy status is timed
  as the MSM6295 datasheet describes, a start never cancels a stop, and
  the decoder resets on every start (`rtl/vendor/jt6295/PROVENANCE.md`). The same patched jt6295 is used in
  the shmupfan Tecmo 16 and Dooyong cores and in Hyper Duel.

The sound comes from Jose Tejada's jt6295. If you enjoy this core,
consider supporting him: https://www.patreon.com/jotego

## MiSTer framework (`sys/`)

The MiSTer template and framework files are copyright their respective
authors (Sorgelig and MiSTer-devel contributors), GPL-2.0-or-later.
https://github.com/MiSTer-devel

## Reference material

- MAME's `promat/1945kiii.cpp` (BSD-3-Clause, copyright David Haywood and
  contributors) is vendored under `reference/mame/` as the behavioural
  documentation of record. This core would not exist without that work.
  https://github.com/mamedev/mame

## The games

The games are copyright Oriental Soft and Promat. This repository
contains no game ROM data in any form; the core loads a user-supplied
MAME ROM set at runtime via the MRA files.
