# M2 findings: full-system boot in Verilator

Date: 2026-10-02. Scope: the main system of every set (68000, work RAM,
memory map, control register, inputs, both M6295, video) booted from power-on
and compared with MAME 0.288 frame by frame. Sound output itself is M3; the
OKIs run here because the games read their status.

Reproduce: `cd sim && make m2-oracle m2-build m2-boot m2-soak m2-okitest`
(MAME runs a few minutes; the boots run in parallel at 96 MHz, about 3.5 h
for k3_attract and 4.5 h for the 20,000-frame soak on this Mac with ten
simulations sharing it). The gate binary was built before the last
diagnostic-only additions (debug visibility markers, the `OKI_HZ` and trace
plumbing); the final RTL reproduces its output byte for byte (600 frames of
1945kiii and flagrall: 2,100 capture files and both I/O logs identical).

## 1. Gate

Every run boots from power-on at the hardware clock (96 MHz; program ROM
answering 9 clocks after each request, the M4 SDRAM controller's worst
case; graphics ROM one read per 8 clocks). I/O = writes to scroll, control
and the OKIs, compared in order and value with MAME's (section 3).

| Run | Set | Frames | I/O writes equal | Images: exact / live reads / unexplained | RAM (vblanks): persistent / transient | ROM-area writes (= MAME) |
|---|---|---|---|---|---|---|
| k3_attract | 1945kiii | 12,001 | 48,902 / 48,902 | 2,023 / 1 / 0 | 0 / 2 of 2,025 | 1,530 |
| k3_play (coin, start, stage 1, game over, stage 2; inputs replayed) | 1945kiii | 5,201 | 20,520 / 20,520 | 1,111 / 0 / 0 | 0 / 0 of 1,111 | 82 |
| slspirit_attract | slspirit | 9,001 | 35,880 / 35,880 | 1,385 / 1 / 0 | 0 / 0 of 1,387 | 1,026 |
| clone_1945kiiin | 1945kiiin | 9,001 | 36,248 / 36,248 | 299 / 1 / 0 | 0 / 0 of 300 | 1,089 |
| clone_1945kiiio | 1945kiiio | 9,001 | 34,232 / 34,232 | 300 / 0 / 0 | 0 / 0 of 300 | 32 |
| clone_1945kiiipt | 1945kiiipt | 9,001 | 35,880 / 35,880 | 300 / 0 / 0 | 0 / 0 of 300 | 1,026 |
| flagrall_play (coin, start, racing; inputs replayed) | flagrall | 4,801 | 29,159 / 29,159 | 1,009 / 2 / 0 | 0 / 3 of 1,011 | 0 |
| flagrall_attract | flagrall | 9,001 | equal to frame 1,505, then MAME's OKI rate (section 5.3) | 1,353 / 0 / 0, then 33 frames after frame 1,505 | from frame 3,905, after the divergence | 0 |
| flagrall_attract, OKI at MAME's 7,575 Hz (diagnostic, 5.3) | flagrall | 9,001 | 54,638 / 54,638 (equal to the end) | 1,353 / 0 / 0, then 33 frames whose RAM already differs (5.4) | from frame 3,905 (5.4) | 0 |
| flagrall_play, OKI at MAME's 7,575 Hz (diagnostic, 5.4) | flagrall | 4,801 | identical to flagrall_play in every figure: the OKI rate plays no part in its drift |
| soak (no captures) | 1945kiii | 20,000 | gate counters all 0: line overruns 0 (worst line 2,846 clocks), unmapped 0, late program reads 0, 18,160 copies with 0 snapshot mismatches; ROM-area writes 2,287 |

Gate counters in every run: line overruns 0 (worst line 2,875 of 6,144
clocks), unmapped accesses 0, 0x8c0000 accesses above 4 KB 0, late program
reads 0, copy snapshot mismatches 0 (10,894 copies in k3_attract with no
write inside a copy; flagrall_attract 18,153 copies with 24,364 CPU writes
landing inside them, flagrall_play 9,673 with 17,300). The ROM-area write
counts equal MAME's at every 500-frame checkpoint (`m2/romw_check.py`).

Live-read frames (each pixel-exact against the line-accurate model): the
three attract frames are mid-scan buffer copies at line 115 on a scene
change (k3_attract 7040, slspirit 2944, 1945kiiin 2939; R3, decision 5a in
PLAN.md); the two flagrall_play frames are section 5.4.

**Verdict: PASS.** Every k3 run (both gameplay and attract, all five k3
sets) and the Flag Rally gameplay run match MAME in every I/O write and
every image, with RAM equal outside the stack except transients. Flag
Rally attract diverges at frame 1,505 because of MAME's integer OKI sample
rate (5.3, proven: with MAME's rate the I/O stream stays equal to the end);
its later RAM divergence from vblank 3,905 is the main-program drift of 5.4
reordering two routines at frame 3,410 (logged with R8). Every difference
has a documented cause and first frame.

## 2. What was built

| File | Content |
|---|---|
| `rtl/k3_sys.sv` | fx68k at 16 MHz, 64 KB work RAM, 4 KB at 0x8c0000, the memory map (spec 4), control register, IRQ4, both jt6295 with banking, k3_video, pause, gate counters |
| `rtl/k3_video.sv` | M1 video; the buffer copy is now a snapshot with copy-before-write (section 4) |
| `rtl/vendor/fx68k`, `rtl/vendor/jt6295` | from the Dooyong core, unchanged, with PROVENANCE.md |
| `sim/m2/tb_sys.cpp` | harness: SDRAM image, program ROM with SDRAM latency, OKI ROM latency, graphics ROM as M1, input replay, captures, I/O stream log, copy snapshot self-check, IACK log, pause test |
| `sim/m2/compare.py` | I/O stream, images (with the live-read model) and RAM against the oracle |
| `sim/m2/romw_check.py` | ROM-area write counts against MAME's at every 500-frame checkpoint |
| `sim/m2/okitest/tb_oki.cpp` | jt6295 on its own: busy length of a phrase against the nominal (5.3) |
| `sim/mame/k3_oracle.lua` | `MAINRAM=1`: work RAM, 0x8c0000 RAM and the CPU registers (PC, SP, SR) per dump frame; diagnostics `OKIRD=1` (status reads) and `TRACE=F0:F1:file` (MAME debugger trace) |
| `sim/mame/oki_reads.lua` | OKI status read log without the rest of the oracle |
| `sim/Makefile` | m2-build, m2-oracle, m2-boot, m2-compare, m2-soak, m2-okitest |

Harness diagnostics (`sim/m2/tb_sys.cpp`): `+io` (I/O stream), `+okird`
(status reads and OKI 1 busy changes), `+iack` (interrupt acknowledge
lengths), `+pctrace=F0:F1:file` (program-space fetches), `+pause=F:N`,
`+promlat=N`, `+inlag=N`. Build parameters for diagnostics only:
`VID_DELAY` (5.1), `OKI_HZ` (5.3), through `make m2-build M2PARAMS=-G...`.

### 2.1 k3_sys interface (stable; the M4 board wrapper depends on it)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | system clock (96 MHz), active-low reset |
| `i_flagrall` | in | 1 | 0: k3 sets, 1: '96 Flag Rally (raster, map, OKI, copy edge) |
| `i_pause` | in | 1 | holds the 68000 and OKI enables (accumulators hold, so they resume in phase); video keeps scanning; IRQ4 stays pending |
| `o_prom_req`, `o_prom_addr[19:1]` | out | 1, 19 | program ROM word request (held for the bus cycle) |
| `i_prom_data[15:0]`, `i_prom_ok` | in | 16, 1 | program word (high byte = even address), valid with ok; DTACK does not wait for it (section 2.3) |
| `o_oki1_addr[19:0]`, `i_oki1_data[7:0]`, `i_oki1_ok` | out/in | | OKI 1 ROM byte: {bank, 18-bit address} (k3 bank 1 bit, flagrall 2 bits) |
| `o_oki2_addr[18:0]`, `i_oki2_data[7:0]`, `i_oki2_ok` | out/in | | OKI 2 ROM byte (k3 only) |
| `o_oki1`, `o_oki2` | out | signed 14 | jt6295 outputs; `o_oki_sample` 48 kHz strobe |
| `i_inputs`, `i_system`, `i_dsw` | in | 16 each | INPUTS, SYSTEM, DSW ports, active low (spec 11) |
| `i_tflag_we`, `i_tflag_addr[9:0]`, `i_tflag_din[15:0]` | in | | sprite tile flags (k3_video, m1_findings 2.2), filled by the loader |
| `o_rom_req`, `o_rom_addr[22:0]`, `i_rom_gnt`, `i_rom_rv`, `i_rom_data[31:0]` | | | graphics ROM port (k3_video) |
| `o_r/g/b[7:0]`, `o_de`, `o_hblank`, `o_vblank`, `o_hs`, `o_vs`, `o_pen[8:0]`, `o_vbl_irq`, `o_ce_pix` | out | | video |
| `o_dbg_overruns`, `o_dbg_maxcyc` | out | 16 | renderer gate counters (M1) |
| `o_dbg_rom_writes`, `o_dbg_unmapped`, `o_dbg_ram8c_hi`, `o_dbg_wstall`, `o_dbg_prom_late` | out | 16 | ROM-area writes, unmapped accesses, 0x8c0000 accesses above 4 KB, tile/sprite writes during a copy, late program reads |
| `o_cpu_pc_dbg[23:0]` | out | 24 | address of the last program-space read |

Parameters: `CLK_HZ` (96,000,000), `PIX_NUM`/`PIX_DEN` (9/128: 6.75 MHz),
`VID_DELAY` (simulation only, 0 on hardware, section 5.1).

### 2.2 Clocks

Every enable is fractional from the system clock: pixel 6.75 MHz (27/4,
L667/L689), 68000 phases at 2 x 16 MHz (L655/L660), OKI 1 MHz (L675/L686).
268,288 CPU clocks per k3 frame, as in MAME. The gate runs at the hardware
clock, 96 MHz.

### 2.3 Bus

No wait states anywhere, as MAME's memory model and the board's own decode:
writes are acknowledged at once; reads take one clock for the BRAM outputs.
The program ROM (1 MB per set, unique content up to 0x6c632 bytes on
1945kiii, too large to sit in BRAM beside everything else) is external: a
program read asserts DTACK at once and keeps loading the read latch until
`i_prom_ok`. fx68k captures read data on every phi2 from T3 to the end of
the cycle (`fx68k.sv` busControl), so the last capture decides. Measured in
the full system at 96 MHz (1945kiii, 300 frames, program ROM answering N
clocks after the request):

| N | Result |
|---|---|
| 1, 9, 12 | exact against MAME; `o_dbg_prom_late` 0; the I/O logs of the three runs are identical byte for byte, beam positions included (860 writes), so no fetch waited |
| 13 | `o_dbg_prom_late` counts every fetch (36,157), the game crashes at once |

So the limit is 12 clocks (3 clocks of margin at 9), no program fetch
waits, and `o_dbg_prom_late` (late = ok after count 12 at 96
MHz, `PROM_LIMIT`) catches a controller that misses it. The harness drives
garbage (0xDEAD) on the data bus before ok, so an early capture cannot pass
by accident.

### 2.4 Decode facts settled with MAME

- OKI writes on the k3 sets are byte writes to the EVEN address 0x4c0000 /
  0x500000 (mask 0xff00 in MAME's log, 4,040 + 34 in the attract run): the
  byte handler at the odd address is mapped with `cswidth(16)` (L397-398),
  so any write to the word reaches the chip. Flag Rally writes words and
  its handler has no cswidth (L408): low byte only.
- OKI status reads are word reads returning 0x00F0 | busy bits (MAME read
  tap: 1945kiii reads 9 times in 3,000 frames, flagrall 933 times; values
  0x00F0-0x00FF). jt6295's status byte is {4'hF, busy | start}; the core
  returns it on the low byte with 0x00 above.
- The control register handler on the k3 sets ignores the byte mask
  (L335-346), and the 68000 puts a byte on both lanes, so the copy edge and
  OKI banks use the replicated byte; Flag Rally masks (L350).
- 0x8c0000: the k3 sets write and read back 0x8c0000-0x8c0ffe ten times at
  boot (m0_findings 7); the core has 4 KB there, mirrored over the 64 KB
  window; `o_dbg_ram8c_hi` counts any access above 4 KB (0 in every run;
  R4 stays open).
- ROM-area writes (0x00098a-0x0009d3, L373-375) are ignored and counted;
  the totals equal MAME's tap counts (section 1).

## 3. Comparison method

**I/O stream.** The harness logs every write to scroll X/Y, control and the
OKIs with its beam position (`+io`); MAME's `writes.csv` has the same. Both
streams must be equal in order and value up to the last captured frame;
the beam position of each write is compared (delta in pixels; 1 pixel =
2.37 CPU clocks). This is the most sensitive check of CPU-state parity:
any change in program flow shows as a different write.

**Images.** Our displayed frame N (pixels between vblank N and N+1) is MAME
frame N+1 (MAME draws frame M at its vblank M). A frame passes if it is
exact against MAME's snapshot, or exact against a line-accurate model of
the live reads (row y drawn during line y-1 from the buffers and scroll as
they stand, scanned out during line y with the palette as it stands), built
from our RAM dumps at vblank N and our own logged writes during the frame.
Frames after a divergence of the I/O stream are not accepted this way.

**RAM.** At each captured vblank N, against MAME frame N: palette, tilemap
and sprite RAMs (live and buffered) from the M0 captures; work RAM and the
0x8c0000 RAM from `make m2-oracle` (same frames and inputs, `MAINRAM=1`;
checked identical to the M0 captures on every shared file, 31,284 files).
Work RAM bytes below MAME's stack pointer at that instant are dead stack and
are reported separately (section 5.2).

**Inputs.** The gameplay runs replay the oracle's `inputs.csv`. An event the
oracle sets from its frame notifier N reaches the game one frame later
(MAME latches input field values at its next input frame update): with
events applied at vblank N the core answered the coin at frame 606 and
MAME at 607, with the identical write pattern. The harness applies events
at N + 1 (`+inlag`, default 1).

## 4. Bug found: the copy stalled the CPU

The first design (M1) copied the 2,048 words in 2,048 clocks and k3_sys
held the CPU (no DTACK) on a tile or sprite RAM write during the copy, so
the buffers were a snapshot. The k3 sets never write in that window, but
Flag Rally does about once a frame (its two copies per frame are followed
by sprite writes), and every stall delayed the CPU against MAME (whose
copy is instant): from vblank 33 the work RAM differed and write timing
drifted by up to 13,476 pixels.

Fix (`k3_video.sv`): copy-before-write. Every CPU write to these RAMs is
registered; if the engine has not read that word yet and it has not been
saved in this copy, the engine pauses one clock, the old word goes into the
buffer and is marked, the CPU write lands, and the engine skips marked
words. The CPU never waits. A harness self-check snapshots the CPU-side
RAMs at every copy pulse and compares the buffers when the copy ends:
0 mismatches over every copy of every run (flagrall_attract: 18,153 copies, 24,364 CPU writes inside them). M1 re-run after the change: 7,821/7,821 frames exact.

## 5. Divergences from MAME

### 5.1 Write timing (every run): a few pixels, no change in order or value

Every write lands within a few pixels of MAME's beam position: k3 sets
-7..+12 pixels (1 pixel = 2.37 CPU clocks), Flag Rally attract -60..+89,
Flag Rally gameplay -9,011..+5,179 (section 5.4). Two parts:

- A constant +3..+4 pixels (about 8 CPU clocks), present from the first
  write of the boot (frame 14, before interrupts are enabled): the power-on
  phase. fx68k leaves reset a few clocks later than MAME's 68000 relative
  to the video counters. On a board, reset release against the video
  counter is arbitrary; nothing to fix.
- Steps of about 4.2 pixels on some frames: one 68000 E-clock period (10
  CPU clocks). IRQ4 is autovectored, and a 68000 synchronises the VPA
  acknowledge to its E clock. fx68k runs the 68000's E-clock state machine
  from its own reset; MAME 0.288 approximates it (`m68000.cpp`
  `vpa_sync`: absolute cycle count mod 10, then +10 or +20 clocks). In our
  runs the acknowledge takes 34 to 66 clocks at 64 MHz (8.5 to 16.5 CPU
  clocks, five values) frame to frame. No video start offset removes the
  steps (`VID_DELAY` 24, 28, 32, 36, 40 clocks tried on 400 Flag Rally
  frames: identical streams, deltas still -18..+30), so it is the
  acknowledge rule, not a phase. Same class as the Dooyong core's R16.

First frame: 14 (constant part); the steps start with the first interrupts.
Believed accurate: fx68k, a gate-level reconstruction of the 68000 that
implements the E-clock VPA cycle, against MAME's arithmetic approximation.
Unprovable without a board (R8); it never changed a write's value or order
in any k3 run.

### 5.2 Stack region bytes (every run)

Work RAM is compared byte for byte except the stack region, which each
run derives from MAME's own dumps: the block at the top of RAM above the
largest always-zero gap (0x10fe72-0x10ffff on 1945kiii, 0x10fea7 slspirit,
0x10ff1b flagrall; the reset SSP is 0x10fffe on every set). Inside it, bytes
below MAME's stack pointer at the dump (MAME `cpu.json`) are dead, and
bytes above it are live frames (return addresses, saved registers). Both
differ at some vblanks (dead: up to 92 bytes; live: up to 38 bytes, mostly
Flag Rally) because the vblank catches the CPU at a different instruction of
the same program (5.1). Outside the stack region, work RAM equals MAME's at
every compared vblank except the transients in section 1 (a word written a
few pixels either side of the vblank instant; k3_attract 0x1009e6 at vblank
8,377 and 0x1009f8 at 10,257, equal again by the next dump).

### 5.3 '96 Flag Rally attract: MAME's OKI sample rate (first divergent frame 1,505)

The game plays a 16.8 s music track (phrase 25, bank 1, 63,760 bytes =
127,520 samples) on OKI channel 1, polls the busy bits once a frame at line
274 and restarts the track when the channel is idle. Started at frame 670
line 286, the track ends at frame 1,505 line 271 in the core: 3 lines before
that frame's poll, so the core restarts it at frame 1,505. MAME restarts it
at 1,506; from there the two runs play the music one frame apart, and later
the attract program differs (33 images, RAM from frame 3,905).

Root cause: MAME 0.288's okim6295 sets its stream rate with an integer
division, `clock() / divisor` into a `u32` (`okim6295.cpp` L121, L169;
`sound.h` `set_sample_rate(u32)`): 1,000,000 / 132 = 7,575 Hz instead of
7,575.76 Hz. Every MAME sample is 0.01% long; over this track that is 1.68
ms, which moves MAME's end to about line 303 of frame 1,505, after the poll.

Proof: a diagnostic build with the OKI enables at 999,900 Hz (7,575 x 132,
MAME's effective rate; parameter `OKI_HZ`, never used on hardware) keeps
the I/O stream identical to MAME's past frame 1,505, to the end of the run: 54,638 writes equal in order and value over 9,001 frames.

Believed accurate: the core. The M6295 divides its clock by 132 (pin 7
high); the PCB notes give 1.000 MHz (L64); MAME's rate is an artefact of
its integer stream rate. (MAME's sample counting itself, 2 x (stop - start
+ 1) samples, is what the core now does, below.)

Also found and fixed on the way (jt6295, documented in
`rtl/vendor/jt6295/PROVENANCE.md`): jt6295 ended a phrase on reaching the
stop byte, after its first nibble, so it played one sample less than
2 x (stop - start + 1) and cleared busy 137 us early (measured on phrases
1, 5, 9, 12 and 25 with `sim/m2/okitest`; 5 us after the patch, its start
latency). The patch makes the stop byte inclusive. Whether the real chip
plays that last nibble is research item R7; MAME's model and the phrase
table's stop address (the last byte of the phrase) say it does. Note:
the Dooyong and Hyper Duel cores ship the unpatched jt6295; whether to carry
this patch there (and upstream to jotego) is an open decision.

### 5.4 '96 Flag Rally: the main program drifts against the beam (frames 3,983 and 4,791)

All 29,159 gameplay writes are equal in order and value, but some land up
to 21 lines early or late against MAME (-9,011..+5,179 pixels), mostly
sound commands and the writes that follow them (109 of the 228 OKI writes).

Cause: on the k3 sets the main program finishes its frame and waits for the
vblank (the CPU sits at PC 0x0002c4 at most vblanks), so every frame starts
from the same point and the per-interrupt differences of 5.1 never add up.
Flag Rally's main program runs across frame boundaries: the vblank
interrupt catches it in the middle of its work (frame 400: MAME at
0x0335aa, the core near 0x033480). Each acknowledge that differs by an
E-clock step (5.1) then moves the rest of the main program, and nothing
resynchronises it until the program next waits. The interrupt handler's
own writes stay bounded (first handler write per frame: -56..+58 pixels
over 4,787 frames, mostly +3; the interrupt waits for whichever instruction
is running, up to about 160 CPU clocks for a DIVS, plus the 5.1 steps),
while the main program's writes wander (+3 pixels at frame 11, +71 at
1,695, +487 at 2,716, -2,034 at 1,575). The
handler's code path is the same on both sides (fetch trace of the frame-400
handler from the vector to the OKI write at 0x0440ba against MAME's
debugger trace; differences are prefetch only), and every OKI status read
returns the same value in the same frame (380 reads to frame 1,580).

The OKI is not the cause: the same run with the OKI at MAME's 7,575 Hz
(5.3) gives the identical result (same deltas, same two frames below).

On two frames the drift moved a main-program write to sprite RAM 2 to the
other side of a buffer copy, so one sprite word differs for one frame
(transient at vblanks 3,984 and 4,792; the images are pixel-exact against
the model of our own state).

Believed accurate: as 5.1 (fx68k's acknowledge; R8). It never changed a
write's value or order in this run.

**The same drift reorders two routines in the Flag Rally attract (first
divergent frame 3,410).** With the OKI at MAME's rate (5.3) the attract run
keeps every I/O write equal in order and value to the end (54,638 writes),
but work RAM 0x1075d5-0x10760f differs from vblank 3,905 on. A write tap on
that range on both sides (`WTAP` in the oracle, `+wtap` in the harness)
finds the first difference at frame 3,410: the main program's routine at
0x04265a (writes 0x1075e6) and the one at 0x03bb1e (writes 0x10760c,
0x107602) run in the opposite order inside the vblank. Core: 0x04265a at
line 281, then 0x03bb1e at line 307. MAME: 0x03bb1e at line 300, then
0x04265a at line 313. The values written are the same; only their order
in time changes. The frames before show the main-program drift of this
section (I/O deltas +41 pixels at frame 3,407, -1 at 3,410, +16 at 3,411;
the tapped writes at frame 3,408 line 16 land 44 pixels later than MAME's).
The game appears to pick its next task by where the beam is, so the
routines swapped order; the task state in 0x1075xx then follows its own
course (RAM from vblank 3,905, 33 images whose video RAM already differs).
Not proven down to the instruction (that needs a cycle trace of frames
3,407-3,410 on both sides); logged with R8. Believed accurate: the core, by
the same argument as 5.1.

### 5.5 Mid-scan copies (R3)

As M1: a copy during the active lines shows from the next line drawn, MAME
shows it on the whole frame. Three captured frames (section 1). Kept live by
Lee's decision (PLAN.md 5a): the most plausible PCB behaviour, unconfirmed;
R3 stays open until frame-by-frame PCB footage of a scene change, or proof
that the two KM681000 are a sprite framebuffer, settles it.

### 5.6 Inputs (harness, not the core)

MAME latches input field values set from a frame notifier at its next input
frame update, one frame later; the harness applies the oracle's events at
N + 1 (section 3). With that, both gameplay runs follow MAME exactly.

## 6. Pause

`+pause=200:60` on 1945kiii: the 57 fully paused frames are identical, the
CPU makes no write while paused, and the I/O stream after the pause equals
MAME's continuation in order and value (580 writes before, 2,248 after).

## 7. Notes for M3 and M4

- M3: the OKI command streams already match MAME's in order and value in
  every run (they are part of the I/O stream); M3 compares sample output
  and level.
- M4: program ROM latency must stay within 12 clocks of the request at
  96 MHz (section 2.3); the board must fill the sprite tile flags before
  reset is released; `i_pause` is available for the OSD pause.

## 8. Re-run with jt6295 patch 2 (2026-10-03, m3_findings 3)

All eight M2 runs re-run on the patched RTL (start to a busy channel
ignored) and compared with the runs above and with MAME:
- k3_play, slspirit_attract, flagrall_attract, flagrall_play, 1945kiiio,
  1945kiiipt: byte-identical to the unpatched runs (every capture file and
  every I/O write, beam positions included).
- k3_attract and 1945kiiin: every I/O write equal in order and value; from
  frame 5,696 (k3_attract) and 7,803 (1945kiiin) some OKI writes land one
  pixel later than before, and on k3_attract 72 of 37,950 capture files
  (write logs and one RAM dump) differ by those timings. The patch is the
  only change; it alters when a channel's busy bit falls after a re-sent
  start, which the program reads. Against MAME the gate figures are the
  same as before the patch: all 48,902 / 36,248 writes equal in order and
  value, beam delta -7..+12 pixels, images 2,023 + 1 live-read (k3_attract)
  and 299 + 1 (1945kiiin), 0 unexplained, 0 persistent RAM differences.
Verdict unchanged: PASS.
