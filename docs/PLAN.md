# 1945k III MiSTer Core - Plan

Target: one MiSTer core (`Arcade-1945kIII` working name) running every set
of MAME's `promat/1945kiii.cpp`: 1945kiii, 1945kiiin, 1945kiiio,
1945kiiipt, slspirit (Solite Spirits) and flagrall ('96 Flag Rally).
Spec: `docs/k3_system_spec.md`. Method and tooling follow the Dooyong core
(`../dooyong-mister`, PLAN and findings M0-M5): MAME 0.288 is the oracle,
a Python reference renderer is checked pixel-exact against it, the RTL is
checked against both in Verilator, then the MiSTer shell and Quartus.

Accuracy rule: where MAME is unsure (spec 13) the core follows MAME for
parity and the item is logged as a research question; nothing is invented.
If PCB evidence later contradicts MAME, real hardware wins and the MAME
difference is logged.

## 1. Scope

- One RBF, game selected by a game ID byte in the MRA. Differences
  between the k3 and flagrall configs are a handful of muxes: raster
  (262 vs 315 lines, 224 vs 240 visible), buffer-copy edge (rising bit 0
  vs falling bit 5 of 0x3c0000), OKI count (2 vs 1) and bank decode,
  0x8c0000 RAM present, inputs/DSW layout, tile/sprite counts for the
  modulo. Rotation from the MRA (ROT270 for the k3 sets, ROT0 flagrall).
- No sound CPU, one 68000, two M6295, one tile layer, one sprite list.

## 2. Reuse

| Block | Source | Notes |
|---|---|---|
| fx68k (68000, cycle-exact) | `../dooyong-mister/rtl/vendor/fx68k` (from Hyper Duel), with its PROVENANCE.md | copy with provenance, no edits |
| jt6295 x2 | `../dooyong-mister/rtl/vendor/jt6295` (Hyper Duel copy, ramstyle patch, SOUND_PROVENANCE.md) | bank bit drives ROM address bit 18 |
| SDRAM controller, MiSTer shell, ioctl download, hiscore-free shell | `../dooyong-mister/rtl/dy_sdram.sv`, `Arcade-Dooyong.sv`, `dy_board.sv` | rename, re-parameterise the SDRAM layout (4.3) |
| MRA generator, region builder, deploy script | `../dooyong-mister/tools/make_mra.py`, `build_regions.py` (ported in M0), `deploy_mister.sh` | |
| Oracle, renderer, comparison | ported in M0 (`sim/mame/k3_oracle.lua`, `sim/oracle/k3_render.py`, `compare_frames.py`) | |

New RTL: the SPR800E video (tilemap pass, sprite engine, palette), the
system glue (memory map, IRQ4, control register, buffers, inputs).

## 3. Variant order

1. 1945kiii (parent, OPCX2 ROM layout) - M1 to M4.
2. 1945kiiin, 1945kiiio, 1945kiiipt, slspirit: same config, different ROMs
   and DSW tables. Covered by MRAs once 1945kiii works; each gets an M2
   boot comparison.
3. flagrall: second raster, one OKI with 3 banks, falling-edge buffer
   copy. Added after the k3 sets pass M3.

## 4. Architecture

### 4.1 Video

Two candidate structures; M1 decides with the oracle data in hand:

- **A. Line renderer** (as Dooyong): per line, fill a line buffer with the
  tilemap pixels, then walk the sprite list and draw the entries that hit
  the line. MAME draws up to 857 entries per frame; a line can in theory
  carry all of them. Observed worst case in every capture: 365 visible
  entries per frame, and the per-line count is far lower. Needs the list
  walk to finish within one line (432 pixels x 14.2 clocks at 96 MHz =
  6,144 clocks).
- **B. Sprite framebuffer** (what the two KM681000 SRAMs suggest, R1):
  during frame N, draw the sprite list into one 320 x 240 x 9-bit buffer
  (8-bit pen + flicker) under a cycle budget, display the other buffer;
  tilemap stays a line pass. 2 x 691 Kbit of M10K (about 135 blocks) or
  SDRAM/DDR3. Natural home for MAME's per-frame cycle budget.

For MAME parity the image of frame N must use the buffered RAMs and scroll
as they stand at the start of frame N's vblank (spec 9, oracle data:
copy and scroll writes land at line 257 of the previous vblank on all
but scene-change frames). Option A latches them at line 0; option B has
to draw frame N's sprites from the buffer copied at line 257 of frame
N-1 before line 0 of frame N, which needs either one frame of latency
(MAME shows no latency) or a draw fast enough to finish in the 38
vblank lines. M1 measures both against the oracle; default is A unless
the budget model (R2) forces B.

### 4.2 Clocks (proposal, as Dooyong)

96 MHz system clock; 68000 enable at 16 MHz (/6); pixel enable 6.75 MHz
(27/4 MHz, from a fractional enable or a dedicated PLL output: 96 MHz
cannot divide to 6.75 MHz exactly, so the PLL gets a 27 MHz or 54 MHz
output); OKI enables at 1 MHz.

### 4.3 SDRAM layout (fixed in tools/build_regions.py)

| Region | Base | Capacity |
|---|---|---|
| maincpu | 0x000000 | 1 MB |
| sprites | 0x100000 | 4 MB |
| tiles | 0x500000 | 2 MB |
| oki1 | 0x700000 | 1 MB (flagrall 3 x 256 KB banks) |
| oki2 | 0x800000 | 512 KB |
| end | 0x880000 | 8.5 MB of 32 MB |

### 4.4 On-chip RAM (estimate)

Main RAM 64 KB, 0x8c0000 RAM (at least the 4 KB the game tests; MAME maps
64 KB), palette 1 KB, sprite RAM 2 x 4 KB plus 2 x 4 KB buffers, tile RAM
4 KB (including 0x2c0800-0x2c0fff) plus 2 KB buffer: about 100 M10K of
553 without a framebuffer, about 235 with option B in M10K.

## 5. Milestones

### M0. ROM validation and MAME oracle bootstrap (DONE, see m0_findings.md)

Gate: all 6 sets pass CRC/SHA1/size against the table generated from the
driver; regions rebuilt byte-identical to MAME's own dumps; the Python
renderer pixel-exact against MAME on every captured frame (attract and
real gameplay for 1945kiii, attract for slspirit and flagrall, gameplay
for flagrall, 300 frames of each other clone); write-log findings on
scroll, buffer timing, sprite use and the questioned RAM ranges.

### M1. Video RTL parity (DONE, see m1_findings.md)

Verilator frame replay of every M0 capture through the video RTL, fed
the dumped buffers, scroll and palette; RTL vs MAME pixel-exact. Plus
synthetic scenes vs k3_render.py: sprites at every wrap position, 857+
entry lists (budget edge), flicker bit, tile codes past the region end
(modulo), all-palette sweeps, flagrall raster. Gate: 100% of frames.
Decide architecture A or B (4.1) here. Decided: A (line renderer reading the
buffers live), with a sprite tile flag table so parked entries on the
blank tile cost nothing (m1_findings 2.2, 6).

### M2. Full-system boot in Verilator

fx68k + memory map + IRQ4 + control register + buffers + inputs, ROMs
from the region images. Boot 1945kiii from power-on through the whole
attract capture and the gameplay capture (inputs replayed); compare
frames and RAM dumps with MAME. Expect fx68k interrupt-acknowledge
timing differences against MAME (Dooyong R16); unexplained divergences
fail the gate.

### M3. Sound

Two jt6295 with banking; compare the OKI command streams with the
oracle's oki1/oki2 write logs and the audio level with MAME WAVs.

### M4. MiSTer shell, SDRAM, Quartus

Board harness (MRA stream into the SDRAM model), MRAs from
`tools/make_mra.py` for all 6 sets (DSW defaults per spec 11), rotation,
inputs, Quartus build on the compile PC (E-core schtasks pattern), timing
closed on every clock. First RBF deployed to the MiSTer.

### M5. Hardware QA and release

All six sets on hardware, DIPs, long play, sound by ear; release into the
shmupfan Distribution database.

## 6. Research questions needing PCB evidence

| # | Question | Source |
|---|---|---|
| R1 | Are the two KM681000 a double-buffered sprite or screen framebuffer? Does sprite output lag the tilemap by a frame on the PCB? | spec 2, 8.4 |
| R2 | Sprite budget: cost per entry, whether the limit is per frame or per line, and what happens past it (MAME: list cut at entry 857/1,030) | spec 8.4, L266-279 |
| R3 | The control "VRAM access flip-flop": copy or bank swap, and what a mid-frame toggle looks like (6 per 12,000 attract frames do it) | spec 9, L341 |
| R4 | 0x8c0000 RAM: real RAM, a mirror of main RAM, or open bus that happens to pass the boot test | spec 4, L399 |
| R5 | Blanking/sync position and exact 59.64 Hz on the PCB | spec 5 |
| R6 | 68000 and OKI clocks on the OPCX1 board (4 MHz crystal) | spec 2, 10 |

## 7. Risks

- Sprite budget (R2) only matters when a game draws more than ~857
  entries; no capture comes within half of that, so parity risk is low.
- The 6.75 MHz pixel clock is not a divisor of 96 MHz (4.2).
- Compile PC instability (memory note `compile_pc_instability.md`): use
  the E-core-only build task; treat a crashed fit as untrusted.
