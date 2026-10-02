# M1 findings: video RTL parity

Date: 2026-10-02. Scope: all six sets (1945kiii, 1945kiiin, 1945kiiio,
1945kiiipt, slspirit on the k3 raster; flagrall on its own raster), one
video module for both.

Reproduce: `cd sim && make m1` (needs `make regions` and the M0 captures in
`sim/mame/out`). About 2 minutes on this Mac for `m1-verify`; `m1-midscan` adds
a 3-minute targeted MAME run.

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| Pixel-exact on every M0 capture frame, all sets | PASS | `make m1-verify`: 7,821/7,821 frames, every one against MAME's snapshot (section 3) |
| Synthetic scenes vs the reference renderer | PASS | `make m1-synth`: 172/172 scenes (section 4) |
| No line over its budget | PASS | 0 overruns in all of the above; worst game line 2,846 of 6,144 clocks (section 5) |
| Mid-scan copies and scroll writes identified and explained | PASS | `make m1-midscan`: 39 event frames found automatically, 39/39 behave as a line renderer must; 24 of them differ from MAME, only above the change (section 6) |
| Lint | PASS | Verilator `-Wall` clean (no waivers beyond the build's -Wno-UNUSEDSIGNAL, -Wno-UNUSEDPARAM, -Wno-WIDTHEXPAND) |

Each frame is checked twice: the RTL's RGB against the MAME snapshot
(rotated for ROT270; palette entries the game never wrote are shown as
MAME's power-on pens, the rule `compare_frames.py` uses), and the RTL's pen
index against `k3_render.py`'s pen.

## 2. What was built

| File | Content |
|---|---|
| `rtl/k3_video.sv` | raster counters, CPU-side RAMs (palette, tilemap RAM 0x800 words, sprite RAMs 1 and 2), the buffers and their copy engine, scroll registers, line renderer, scan-out, vblank IRQ pulse, gate counters |
| `rtl/k3_fifo.sv` | small flop FIFO (hit queue, request tags, returned words) |
| `rtl/k3_dpram.sv` | `dy_dpram` from the Dooyong core, renamed (Verilator arrays, altsyncram in Quartus) |
| `sim/m1/tb_video.cpp` | Verilator harness: loads each frame through the CPU ports with the pixel enable stopped at the first vblank line, pulses the copy, runs one frame, captures the pixels; optional mid-frame switch at a given beam position |
| `sim/m1/replay.py` | frame dirs to harness input, batches in parallel, checks every frame |
| `sim/m1/make_scenes.py` | synthetic scenes (section 4) |
| `sim/m1/midscan.py` | finds visible copy and scroll events in the oracle write logs |
| `sim/m1/midscan_replay.py` | replays each event frame with the change at MAME's beam position |
| `sim/m1/capacity.py` | sprites-per-line probe |

### 2.1 Per line

During line L-1, line L is built in one half of a double line buffer:

1. Tile pass: the 21 tiles that cover the 320 visible pixels (scroll fine
   x up to 15), each one tilemap buffer read and four 32-bit graphics ROM
   reads; all 320 pixels written opaque (pens 0x000-0x0FF).
2. Sprite pass, overlapped with 1: a walker reads list entry i from both
   sprite buffers (one entry per clock, entries 0 to 856 on k3 and 0 to
   1,029 on flagrall, MAME's budget), tests the line, looks up the tile's
   "has pixels" flag and queues hits. A fetcher reads each hit's tile row
   (four 32-bit reads) once the tile pass has issued all its requests.
3. One writer drains the returned words in request order at one pixel per
   clock, so sprites land over the tilemap and later entries over earlier
   ones. Pen 0 is transparent; the flicker bit writes 0x1FF.

Scan-out reads the other half and the palette at the pixel enable (one
pixel of pipeline delay on every output).

The graphics ROM port is the Dooyong one: pipelined, accepted on
req && gnt, data returned in order with a valid strobe.

### 2.2 Blank sprite tiles

The first build overran badly (28,104 clocks on one line): the games park
every unused list entry on tile 0, which is blank, at a fixed Y, so up to
827 entries hit the same line (1945kiii boot and attract frames). MAME
draws them all; they change no pixel. The walker now skips entries whose
tile has no non-zero pixel, using a 16,384-bit flag table (1,024 x 16)
that the loader fills while the sprite ROM streams in (M4: OR of each
256-byte tile in the download; in the harness, computed from the SDRAM
image). Tile 0 is blank in every set's sprite ROM; 1945kiii, 1945kiiio and
flagrall have no other blank tile, slspirit, 1945kiiin and 1945kiiipt have
15 or 16 more (16,367 or 16,368 of 16,384 have pixels). This is an
implementation shortcut with no visible effect: a fully transparent tile
cannot change a pixel.

### 2.3 Buffers and the copy

The CPU-side RAMs are what the CPU reads and writes; the renderer only
reads the buffers. `i_copy` (one clock, issued by the system on the
0x3c0000 edge, spec 9) copies the 2,048 words of each sprite RAM and the
1,024 tilemap words, one word of each per clock (2,048 clocks, about 21 us
at 96 MHz). The renderer reads the buffers and the scroll registers live,
line by line (section 6).

### 2.4 Clocks and raster

96 MHz system clock. The pixel enable is a 9/128 fractional enable: 6.75
MHz on average (27 MHz / 4, spec 5), 14 or 15 clocks per pixel, exactly
6,144 clocks per 432-pixel line. The 68000 will run at /6 (16 MHz) and the
OKIs at /96 (1 MHz) in M2/M3. The counters start at the first vblank line
(224 or 240) and the first vblank IRQ comes one frame later, as MAME (the
Dooyong oracle measured this). Sync positions are not in the driver: hsync
pixels 352-383, vsync three lines from line 232 (k3) or 248 (flagrall),
research item R5.

## 3. Captures

| Run | Frames | Exact | Worst line (clocks) |
|---|---|---|---|
| k3_attract (1945kiii) | 2,025 | 2,025 | 2,846 |
| k3_play (1945kiii gameplay) | 1,111 | 1,111 | 2,631 |
| slspirit_attract | 1,387 | 1,387 | 2,234 |
| flagrall_attract | 1,387 | 1,387 | 1,980 |
| flagrall_play | 1,011 | 1,011 | 2,166 |
| clone_1945kiiin | 300 | 300 | 2,552 |
| clone_1945kiiio | 300 | 300 | 2,583 |
| clone_1945kiiipt | 300 | 300 | 2,199 |
| **Total** | **7,821** | **7,821** | |

## 4. Synthetic scenes

`sim/m1/make_scenes.py`, seed 1945, checked against `k3_render.py`, both
rasters (1945kiii and flagrall regions):

| Run | Scenes | Content |
|---|---|---|
| *_targeted | 26 each | every X wrap position (480-511, 296-327, 0-31), Y straddling the top (236-255, drawn at Y-256) and the bottom, corner wrap, the budget edge (entries 854-861 on k3, 1,027-1,034 on flagrall, and 2,040-2,047: only those below the budget draw), sprite codes past the end of the region (flagrall 12,256-12,319, modulo 12,288), flicker on 200 overlapping sprites, map codes past the region (full 16-bit words) with scroll 0, 1, 15, 16, 495/497, 511, 0xFFFF, 0x8000/0x7FFF, 0x1F0/0x00F, 0x00F/0x1F0, 64/96/128 non-blank sprites on the same lines, the same tile stacked 40 deep (list order), 300 sprites over a random palette |
| *_random | 60 each | random scroll, palette, map (30% with full 16-bit codes), 0 to budget entries at random indices, 5% random codes (blank or past the region), 10% flicker; every scene also parks the other entries on tile 0 at random Y |

172/172 exact, no overruns.

## 5. Line budget

Harness ROM model as Dooyong M1: one 32-bit read accepted every 8 clocks,
data 9 clocks later (a close-page 16-bit SDRAM at 96 MHz with no bank
overlap, i.e. pessimistic). Budget 6,144 clocks per line.

| Case | Worst line |
|---|---|
| every game capture | 2,846 (46%) |
| synthetic, 128 non-blank sprites on one line | 5,028 (82%) |
| probe: 144 / 160 sprites on one line, k3 | 5,607 / 6,101 |
| probe: 168 sprites on one line, k3 | 6,351: overrun |
| probe: 144 / 160 sprites on one line, flagrall | 5,780 / 6,274: overrun at 160 |

A sprite costs about 31 clocks at this port (four reads), the tile pass
about 700, the walk 857 or 1,030 clocks overlapped with the fetches. So a
line holds about 160 sprites (k3) or about 150 (flagrall); the most any
game frame puts on one line is 63 (m0_findings 9). MAME has no per-line
limit at all (R2): a list with more than about 160 non-blank sprites on
one line would show missing sprites on the core and not in MAME. A burst
read port in M4 (16 bytes per tile row in one burst) would raise the
limit roughly threefold if that ever matters.

## 6. Mid-scan copies and scroll writes (R3)

MAME draws the whole frame at vblank, so a buffer copy or scroll write
during the visible lines of frame N shows on every line of frame N. A line
renderer that reads the buffers live, which is what k3_video does and what
a board without a frame of latency must do, shows the old image above the
change and the new one below it.

`m1/midscan.py` finds every visible copy edge (k3: bit 0 rising; flagrall:
bit 5 falling) and scroll write in the oracle write logs; `make m1-midscan`
captures each such frame S and S-1 from MAME and replays S with the change
applied at MAME's logged (line, hpos), the pixel enable stopped while the
harness rewrites the RAMs and pulses the copy. Results
(`build/m1/midscan_replay.csv`):

| Set / run | Event | Line | Frames | Rows that differ from MAME |
|---|---|---|---|---|
| 1945kiii attract (and 1945kiiin, 1945kiiio) | copy at a scene change | 115 | 6 in 12,000 (4 in 9,000) | 85 rows, 32-116 |
| slspirit attract (and 1945kiiipt) | copy at a scene change | 115 | 4 in 9,000 | 62 rows, 50-116 |
| 1945kiii gameplay | copy (late handler) | 176 | 1 in 5,200 | 69 rows, 38-177 |
| 1945kiii gameplay | copy + scroll (lag frame) | 4 | 1 | 6 rows, 0-5 |
| 1945kiii gameplay | copy + scroll (lag frame) | 4-5 | 3 | none (same image) |
| all k3 sets, boot | scroll write of the same value | 6 | 1 per set | none |
| all k3 sets, boot | copy | 2-3 | 1 per set | none |
| slspirit, boot | copy | 212 | 1 | none |
| flagrall | none: every copy and scroll write is in the vblank | | 0 | |

39 event frames, 39 OK: on every one, every row from line L + 2 down
equals MAME's frame S (line L + 1 was already being drawn when the change
landed at line L), and every row above equals the pre-change state drawn
by `k3_render.py`. 24 of the 39 show a visible difference; the other 15
change nothing on screen. The pre-change state is taken from frame S-1's
dump (the game skips its vblank write on these frames, m0_findings 5); the
M2 full-system run replaces that assumption with the real write timeline.

Everything else matches MAME exactly, and no other frame in any capture has
a visible-line copy or scroll write.

## 7. Decisions for Lee

1. **Mid-scan copies (R3).** Current design: live, as above. A scene change
   in attract mode (about one every 2,000 frames) and a rare gameplay
   frame show one split frame: the top part (rows 32-116) still shows the
   previous scene for 1/60 s. Alternatives:
   - latch the buffers and scroll at line 0: those frames show the whole
     previous image instead of a split one; still one frame behind MAME
     on exactly those frames, no added latency elsewhere;
   - MAME's behaviour on every frame needs the whole picture one frame
     late (draw frame N during frame N+1's scan-out), adding 16.8 ms of
     latency to every frame. Not recommended.
   Recommendation: keep live (most plausible for the PCB: the renderer
   cannot know a copy is coming), log the 24 frames as a known MAME
   difference, and let PCB footage of a scene change settle it.
2. **Sprites per line.** About 160 at the pessimistic port against 63 used.
   Fine as is; revisit only if R2 or a game shows heavier lines.

## 8. Synthesis sanity

No Quartus or Yosys run (Yosys is not installed here; Quartus belongs to
M4 on the compile PC). Verilator `-Wall` is clean. On-chip RAM by
construction (all with registered reads, mapped through `k3_dpram`):

| RAM | Words x bits | M10K (est.) |
|---|---|---|
| palette | 512 x 16 | 1 |
| tilemap RAM (CPU side) | 2,048 x 16 | 4 |
| sprite RAM 1, 2 (CPU side) | 2 x 2,048 x 16 | 8 |
| tilemap buffer | 1,024 x 16 | 2 |
| sprite buffers | 2 x 2,048 x 16 | 8 |
| line buffer | 1,024 x 16 (9 used) | 2 |
| sprite tile flags | 1,024 x 16 | 2 |
| **Total** | | **about 27 of 553** |

Flops: the three FIFOs (16 x 28, 8 x 12, 8 x 32 bits) and the control
state, a few hundred LUTs. The longest combinational paths are the
walker's 8-bit line test plus the flagrall 14-bit modulo subtract (one
stage), the 23-bit ROM address adders, and the writer's x add and
compare; none is deep at 96 MHz, but M4 timing analysis is the real check.

## 9. Notes for M2

- The system decodes 0x200000 (palette), 0x240000/0x280000 (sprite RAMs),
  0x2c0000-0x2c0fff (tilemap RAM incl. the unbuffered upper half),
  0x340000/0x380000 (scroll) and the 0x3c0000 control write; it raises
  `i_copy` on the k3 rising edge of bit 0 or the flagrall falling edge of
  bit 5 of (data & mask), keeping the flip-flop state from reset = 0.
- `o_vbl_irq` pulses at the first vblank line from the second frame on;
  IRQ4 is held until acknowledged (L662).
- The tile flag port (`i_tflag_*`) must be filled by the loader before
  the game runs.
