# M0 findings: ROM validation and MAME oracle bootstrap

Date: 2026-10-02. Oracle: MAME 0.288 (Homebrew build). ROMs: MAME 0.289
merged set in `roms/` (1945kiii.zip with its three clones, slspirit.zip,
flagrall.zip). Driver of record: `reference/mame/1945kiii.cpp` (master
ed715993). The 0.288 driver differs from it in one line only, a cosmetic
`SCREEN(config, m_screen, SCREEN_TYPE_RASTER)` constructor argument (L666),
so the spec and the oracle describe the same behaviour.

Reproduce: `cd sim && make m0` (about 2 minutes of wall time on the Mac;
outputs in `sim/build` and `sim/mame/out`, gitignored, about 2.9 GB).

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| All 6 sets pass CRC/SHA1/size | PASS | `make roms-check`: 6/6 complete against the table generated from the driver (86 files); notes only: 1945kiiipt's su4/su5 are stored under 1945kiiio's names in the merged zip (same CRC), and its gal16v8.u22 is NO_DUMP in MAME |
| Region images built | PASS | `make regions`: every region of all 6 sets rebuilt from the ROM_START blocks, sizes equal spec 12, `sdram.bin` per set in the PLAN 4.3 layout |
| Region images equal MAME's own view | PASS | `make mame-regions`: 6/6 MATCH byte for byte (1945kiiipt's NO_DUMP `plds` region skipped: MAME fills it with its own pattern and the core does not use it) |
| Python renderer pixel-exact on every captured frame | PASS | `make oracle-verify`: 7,821/7,821 frames (section 3) |
| Write-log findings recorded | PASS | sections 4-7, spec 4, 8.4, 9 |

## 2. Files

| Path | Purpose |
|---|---|
| `tools/romdefs.py` | ROM_START parser and region builder, ported from Dooyong with ROM_LOAD32_WORD, ROM_LOAD32_BYTE and NO_DUMP support |
| `tools/check_roms.py` | ROM check; `--table` prints the spec's Appendix A |
| `tools/build_regions.py` | region `.bin`/`.hex`, `sdram.bin`, `manifest.json` per set |
| `tools/compare_regions.py` | builder vs MAME region dumps |
| `tools/play_inputs.py` | deterministic gameplay input script for the oracle |
| `tools/analyze_writes.py` | write-log and sprite-list summaries (sections 4-7) |
| `sim/Makefile` | all M0 targets |
| `sim/mame/run_mame.sh`, `dump_regions.lua`, `frame_tools.py` | copied from Dooyong unchanged |
| `sim/mame/k3_oracle.lua` | write taps with beam position, read taps on the questioned RAM, per-frame dumps (palette, buffered and live tile/sprite RAM, tracked scroll, flip-flop state), snapshots, inputs/DIPs |
| `sim/oracle/k3_render.py` | reference renderer (spec 6-8) |
| `sim/oracle/compare_frames.py` | renderer vs MAME per frame, writes `render_stats.csv` |

Byte order of every `.bin`: 16-bit data high byte first (the 68000's
logical big-endian view); 8-bit regions as is.

## 3. Captures and renderer parity

| Run | Set | Frames run | Frames dumped | Content | Pixel-exact |
|---|---|---|---|---|---|
| k3_attract | 1945kiii | 11,994 | 2,025 (every 8th, plus 9,300-9,899 dense) | five full attract loops: title, ship roster, five different stage demos, rankings | 2,025/2,025 |
| k3_play | 1945kiii | 5,201 | 1,111 (760-5,200 every 4th) | coin, start, ship select, stage 1 with the boss, game over, continue, stage 2 | 1,111/1,111 |
| slspirit_attract | slspirit | 8,994 | 1,387 | attract loops | 1,387/1,387 |
| flagrall_attract | flagrall | 8,994 | 1,387 | attract loops (49.61 Hz raster) | 1,387/1,387 |
| flagrall_play | flagrall | 4,801 | 1,011 | coin, start, racing | 1,011/1,011 |
| clone_1945kiiin | 1945kiiin | 9,001 | 300 | attract | 300/300 |
| clone_1945kiiio | 1945kiiio | 9,001 | 300 | attract | 300/300 |
| clone_1945kiiipt | 1945kiiipt | 9,001 | 300 | attract | 300/300 |
| **Total** | | | **7,821** | | **7,821/7,821** |

Each frame is checked twice: against MAME's snapshot (rotated for ROT270)
and against `screen:pixels()` taken one notifier later with the palette of
that moment. The second check was skipped on 11 frames that showed palette
entries never written since power-on (MAME shows a default pen pattern
there; real SRAM would be undefined); the snapshot check passed on those.
Every written palette entry decodes to MAME's pen exactly on every frame.

The renderer was pixel-exact on the first canary (30 frames) and then on
every capture without changes. Features exercised: opaque tilemap with
scroll wrap; sprites in list order with wrap copies; the flicker pen 0x1FF
(visible flicker sprites in 275 dumped frames: 172 in 1945kiii attract,
12 in gameplay, 56 slspirit, 35 in the 1945kiiin/1945kiiio clones; none in
flagrall or 1945kiiipt); tilemap codes past the end of the tile region
(modulo, 64 frames: 23 1945kiii, 23 slspirit, 6 in each of the three clones); both rasters;
all ROM layouts. Not exercised by any game frame: sprite tile codes past
the end of the sprite region, and the sprite budget cut (section 6); M1
covers both with synthetic scenes.

## 4. Scroll writes (spec 7, 9)

| Run | Scroll writes | In the visible area | Beam line of the rest |
|---|---|---|---|
| 1945kiii attract | 10,881 | 1 (boot, line 6) | 257 |
| 1945kiii play | 5,060 | 5 (lines 4-6, lag frames) | 257 |
| slspirit, clones | 8,125-8,161 each | 1 (boot) | 257 |
| flagrall attract/play | 8,983 / 4,790 | 0 | 272 (also 268, 278, 300) |

Scroll is written once per frame from the IRQ4 handler, inside the vblank,
in every frame except boot and five lag frames in gameplay where the
handler runs late into lines 4-6 of the next scan-out. No frame has two
scroll values on screen in MAME's model.

## 5. Buffer flip-flop (spec 9)

k3 sets: the handler writes 0x14 (bit 0 clear) at line 224 and 0x15 (bit
0 set, the copy) at line 257. Copies per run and where they land:

| Run | Copies | At line 257 | Elsewhere | Frames between copies |
|---|---|---|---|---|
| 1945kiii attract | 10,887 | 10,880 | line 2 (boot), line 115 x6 | 1: 10,081; 2: 528; 3: 265; 4: 6 |
| 1945kiii play | 5,061 | 5,055 | line 2 (boot), lines 4-5 x4, line 176 x1 | 1: 4,973; 2: 69; 3: 16; 4: 1 |
| slspirit attract | 8,165 | 8,160 | lines 115 x4, 212 x1 | |
| clones | 8,129-8,164 | all but 5 | lines 2-3 (boot), 115 x4 | |

Gaps of 2-4 frames are game lag: no copy, the same image is shown again.
The line-115 copies come at scene changes: the handler skips its 257
write, writes 0x14 at line 259, and the 0x15 lands at line 113-115 of the
next scan-out. In gameplay a few copies land at lines 4-5 (late handler)
and one at line 176.

flagrall: two copy edges per frame (falling bit 5), normally at lines 260
and 272 (8,807 frames of the attract run), otherwise at lines 245-300 (246,
266 and 278 in 174 frames each, 245, 288, 300 once), all inside the vblank
(lines 240-314). Control values alternate 0x34/0x14, 0x32/0x12, 0x30/0x10:
bit 5 toggles twice, bits 2:1 carry the OKI bank.

**Consequence for M1.** MAME renders frame N at vblank (line 224) from the
buffers as they stand then, so a copy anywhere in frame N's scan-out is
visible in the whole of frame N. A line renderer that latches the buffers
at line 0 matches MAME on every frame where the copy lands in the vblank
(99.9% of copies) and differs for one frame at each mid-scan copy (about
6 per 12,000 attract frames, 6 per 5,000 gameplay frames): it shows the
new image one frame later. Which of the two the PCB does is R3.

## 6. Sprite list use (spec 8.4)

| Run | Budget (entries) | Most visible entries in a frame | Highest visible index | Visible entries past the budget |
|---|---|---|---|---|
| 1945kiii attract | 857 | 381 | 425 | 0 |
| 1945kiii play | 857 | 227 | 261 | 0 |
| slspirit attract | 857 | 249 | 266 | 0 |
| clones | 857 | 250-256 | 257-273 | 0 |
| flagrall attract | 1,030 | 319 | 797 | 0 |
| flagrall play | 1,030 | 450 | 799 | 0 |

"Visible entry" = a list entry whose tile has a non-zero pixel and whose
box (any of the four wrap copies) overlaps the visible area; computed from
the buffered RAM by `analyze_writes.py` and, independently, counted by the
renderer while drawing (`render_stats.csv`); both agree on every run.
MAME's budget never cuts a visible sprite in any capture. The flagrall
list reaches index 799, so it uses the upper part of the list.

## 7. Questioned RAM and ports

- 0x8c0000-0x8cffff (k3 sets): written with zeros at 0x8c0000-0x8c0ffe ten
  times during boot (frames 22-36; 15-29 on slspirit) and read back the same
  number of times (read tap: 20,480 reads in 12,000 frames): a 4 KB boot
  RAM test. Never touched afterwards. The core must answer it like RAM; R4.
- 0x2c0800-0x2c0fff: no reads or writes in any capture (U4 answered for
  these captures: the map is 32 x 32).
- ROM-space writes: 0x00098a-0x0009d4, data looks like stray register or
  opcode values (0x2626, 0x2121, 0x4e71); MAME ignores them, so does the core.
- OKI: 1945kiii attract 4,040 writes to oki1, 34 to oki2; flagrall 389 to
  its single OKI. Byte data appears on both lanes (68000 byte writes).
- DSW power-on values read from MAME: 1945kiii/1945kiiin 0xFEEF; 1945kiiio,
  1945kiiipt, slspirit, flagrall 0xFFEF (spec 11).

## 8. Timing facts measured

- Notifier (vblank start) at line 224 hpos 0 (k3), line 240 (flagrall),
  matching `set_raw` (L667, L689).
- Frame period 16.768 ms (59.64 Hz) k3, 20.160 ms (49.61 Hz) flagrall;
  line 64.0 us (432 pixels at 6.75 MHz).

## 9. Open questions for M1

1. Architecture A (line renderer) or B (sprite framebuffer), PLAN 4.1.
   The data favour A for parity: per-frame sprite use is under half the
   budget, scroll and buffer copies land in the vblank, and a line
   renderer latched at line 0 matches MAME on all but the mid-scan copy
   frames. B is the likelier hardware (R1), and matters only if the PCB
   shows sprite lag or budget effects.
2. Mid-scan buffer copies (section 5): accept the one-frame difference on
   those frames (log as a known MAME difference, R3) or emulate MAME's
   whole-frame behaviour (impossible without a frame of latency).
3. Sprite budget: model MAME's per-frame 857/1,030 cut in M1 so that
   synthetic lists beyond it match, even though no game frame reaches it.
4. Per-line worst case for A: the most list entries covering one visible
   line in any dumped frame is 63 (1945kiii attract frame 9,374, line 71;
   gameplay 51; flagrall 40). At 16 pixels each that is about 1,000
   pixel writes per line, inside the 6,144-clock line at 96 MHz, but the
   walk itself must test up to 857 (k3) or 1,030 (flagrall) entries per
   line, so a single-pass hit test needs at least one entry per clock or
   a per-frame pre-sort by line.
