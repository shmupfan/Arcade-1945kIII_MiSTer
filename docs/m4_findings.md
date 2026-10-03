# M4 findings: MiSTer shell, SDRAM, MRA, Quartus (prepared in parallel with M2)

Date: 2026-10-02. Status: prepared, not built. Written alongside M2 (which
owns rtl/k3_sys.sv, sim/m2/, sim/Makefile, docs/PLAN.md); nothing here edits
those files. sim/m4.mk holds the M4 targets until sim/Makefile includes it.

## 1. Names

| Item | Value |
|---|---|
| Repository (proposed) | Arcade-1945kIII_MiSTer |
| Quartus project / revision | Arcade-1945kIII |
| Released core | releases/Arcade-1945kIII_YYYYMMDD.rbf (MiSTer-devel strips "Arcade-": 1945kIII_YYYYMMDD.rbf) |
| MRA `<rbf>` | 1945kiii |
| OSD title | 1945kIII |

The core runs three games on one board family (Oriental Soft / Promat
SPR800E): 1945k III (4 sets), Solite Spirits, '96 Flag Rally. "Promat" or
"SPR800E" would also fit; 1945kIII is the name players search for.

## 2. Files

| File | Content |
|---|---|
| `Arcade-1945kIII.sv` | Template_MiSTer `emu`: hps_io, MAME default keyboard from the first build, inputs in the driver's port layout (spec 11), k3_board at 96 MHz, toggle hand-off of each pixel to the 48 MHz video clock (the pixel enable is fractional, 9/128), arcade_video at 48 MHz (Dooyong landmine: HQ2x fails at 96 MHz), screen_rotate for the ROT270 sets, 4:3 / rotated 3:4 |
| `rtl/k3_board.sv` | k3_sys + k3_sdram + ioctl: index 0 ROM stream (= sdram.bin), index 1 machine byte (bit 0 = Flag Rally), index 254 DSW (2 bytes); builds k3_video's 16,384-bit "tile has pixels" table from the sprite region as it streams; core in reset during downloads and until the SDRAM is ready; mono mix of the two M6295 |
| `rtl/k3_sdram.sv` | bank-per-region controller (section 3) |
| `Arcade-1945kIII.qpf/.qsf/.sdc/.srf`, `files.qip`, `pll.v`, `pll/`, `sys/`, `build_id.v`, `clean.bat` | Quartus 17.0 project; qsf, sys/, PLL (96, 96 at -90 degrees, 48 MHz) copied from Dooyong unchanged except names; sdc multicycles 2 inside fx68k (enables 3 clocks apart) and the jt6295s, false paths on the machine byte and DIPs |
| `tools/make_mra.py` | MRAs for all 6 sets, DIPs parsed from the driver's INPUT_PORTS (section 4) |
| `tools/pc_build.sh` | compile PC: push / task / run / status / fetch (section 6) |
| `sim/m4/tb_sdram.sv`, `tb_sdram.cpp`, `sdram_model.sv` | controller test (section 3) |
| `sim/m4/tb_board.sv`, `tb_board.cpp` | board harness: download through ioctl and SDRAM, frames as .rgbp |
| `sim/m4/lint_stubs.sv` | framework stubs (from Dooyong) to lint the shell under Verilator |

## 3. Program ROM in SDRAM, and the zero-wait requirement

The 68000 program region is 1 MB; the live code is 436-470 KB per set
(1945kiii's upper half mirrors the lower; 1945kiiio, slspirit and flagrall
are zero above 0x80000). That does not fit block RAM next to the 64 KB work
RAM and the video (553 M10K in all, 410+ needed for the ROM alone). So the
program is fetched from SDRAM, and the real board runs it with no wait
states (EPROMs, MAME's zero-wait model, spec 4).

k3_sdram puts each region in its own bank: program ROM bank 0, sprites bank
1, tiles bank 2, both OKI ROMs bank 3. Two engines share the command bus
(CPU first) and the data bus (BL1 reads at distinct command clocks):
- CPU engine, bank 0 only: ACT on the clock the request is seen, READ with
  auto precharge 3 clocks later (tRCD), data 3 clocks after that, passed
  straight through (combinational ok/data on the landing clock).
- Other engine, one job at a time: download, OKI 1, OKI 2, graphics (ACT,
  READ, READ+AP), refresh.
- Refresh runs only in the 6 clocks after a CPU word lands (the next fetch
  cannot be requested for about 17 clocks), with new graphics/OKI jobs held
  while a refresh is owed and a fetch is in flight, so the banks are idle
  when the window opens. While the CPU is in reset, refresh runs any time.
  Forced refreshes (debt 6, i.e. no fetch for 47 us) are counted.
- tRCD/tRP 3 clocks (the -7 part needs 21 ns), tRRD 2, tWR 2, tRFC 8,
  CL2, P_RET 3: Hyper Duel / Dooyong values, proven on the board.

`make -f m4.mk m4-sdram` (4M clocks, 1945kiii image downloaded through the
ioctl port): every word checked, model checks tRCD, tRP after auto
precharge, tWR+tRP, tRRD, tRFC, refresh with a row open, DQ contention.

| Measure | Result |
|---|---|
| CPU fetches | 107,398, 0 errors; latency 8 clocks (90,686), 9 clocks (12,284, an ACT to another bank one clock earlier: tRRD), 1 clock (4,428 repeats of the last word) |
| Graphics | 483,937 reads, one per 8.27 clocks at full pressure (M1's pessimistic port model: one per 8), 0 errors |
| OKI | 36,545 reads, 0 errors |
| Refresh | 5,348 issued (5,333 needed), 5 forced, all during the test's simulated 3,000-clock CPU idle gaps |
| All 6 sets (`m4-sdram-all`, 1M clocks each) | PASS (flagrall's 0x800000 image included) |

### 3.1 INTERFACE REQUIREMENT for k3_sys (M2): DTACK for program reads

fx68k timing (rtl/vendor/fx68k/fx68k.sv busControl): AS falls at the phi1
edge of S2; DTACK is sampled (rDtack) at the phi2 edge 9 clocks later at 96
MHz, i.e. AS + 9; read data is captured on every phi2 from T3 until the
cycle ends, last at AS + 15 (phi2 before the T1 that resumes the microcode).

k3_sys today asserts DTACK for a program read only after i_prom_ok
(MB_ROM -> MB_ACK). Its request rises at AS + 1; with the controller's 8-9
clock latency, DTACK would be low after AS + 9 or AS + 10: one clock too late
for the AS + 9 sample, so every program fetch would get a wait state (the
68000 one 16 MHz clock slower per fetch, a large timing error against MAME
and the PCB).

What k3_sys needs (its file, so its owner's change): treat a program read
like the other reads for DTACK (assert it at once, as the board's EPROM
decode does) and keep capturing i_prom_data into the read latch until
i_prom_ok, so the value fx68k captures at AS + 15 is the ROM word. The
controller's worst case (ok 9 clocks after the request, so latched by AS + 10)
leaves 5 clocks of margin. A debug counter for "ok after AS + 14" would catch
any fetch that misses (should stay 0). With that change no fetch inserts a
wait state; without it the board sim will show the CPU running about 20%
slow on program-heavy code.

## 4. MRAs

`make -f m4.mk m4-mra` (tools/make_mra.py): 6/6 MRAs reproduce
sim/build/regions/<set>/sdram.bin byte for byte through a replay of
Main_MiSTer's loader rules (same method as Dooyong; extended to 32-bit
interleaves for ROM_LOAD32_WORD / ROM_LOAD32_BYTE, numpy-based, 2 s for all).

| Set | MRA | Stream | Parts |
|---|---|---|---|
| 1945kiii | releases/1945k III (newer, OPCX2 PCB).mra | 0x880000 | 9 |
| 1945kiiin | releases/_alternatives/_1945k III/1945k III (newer, OPCX1 PCB).mra | 0x880000 | 18 |
| 1945kiiio | .../1945k III (older, OPCX1 PCB).mra | 0x880000 | 18 |
| 1945kiiipt | .../1945k III (Promat license, OPCX1 PCB).mra | 0x880000 | 18 |
| slspirit | releases/Solite Spirits.mra | 0x880000 | 19 |
| flagrall | releases/'96 Flag Rally.mra | 0x800000 | 19 |

DIP switches are parsed from each set's INPUT_PORTS block (k3, k3old,
solite, flagrall), never typed: defaults k3 EF,FE; k3old, solite and
flagrall EF,FF. MAME repeats labels for settings that behave alike (the old
sets' 1C/1C coin entries); the MRA numbers the repeats, the default
unnumbered. Unknown/unused switches are not exposed and default to 1.
Machine byte: 00 (k3 sets) or 01 (flagrall). Buttons: 4 on the k3 sets
(MAME maps 4; how many the games read is an M5 check), 2 on Flag Rally.

## 5. Shell notes

- Inputs follow the driver exactly: k3 P1 bits 0-3 up/down/left/right then
  B1-B4, P2 in the high byte; SYSTEM coin 1, (unknown), start 1, start 2.
  Flag Rally: P1 only (6 bits), SYSTEM coin 1, coin 2 (P2's coin), start 1.
  The k3 service switch is DIP SW1:8.
- No flip-screen control exists on this board (spec 4); `flip` is tied 0.
- Pause is not implemented: it needs a k3_sys input that holds the CPU and
  OKI enables while the video keeps scanning (M2 interface, optional).
- Audio: OKI 1 + OKI 2 (signed 14-bit each, explicitly signed sum), doubled
  to 16 bits. Level against MAME is an M3 item.
- Video totals 432 x 262 at 6.75 MHz = 59.64 Hz (k3), 432 x 315 = 49.60 Hz
  (flagrall), MAME's values (spec 5); sync positions are research item R5.

## 6. Compile PC

Reachable 2026-10-02 at buildhost (ssh user@, Windows 11, Quartus
17.0 Lite). Prepared, no compile started:
- `C:\k3_build` created; build inputs pushed once as a transfer test
  (`tools/pc_build.sh push`, tar over ssh, AppleDouble files excluded:
  macOS tar adds `._*` files unless COPYFILE_DISABLE=1).
- `C:\k3_build\runcompile.cmd` (quartus_sh --flow compile, `start /AFFINITY
  FFFF0000` = E-cores) and scheduled task `k3compile` (far-future trigger,
  runs only on `schtasks /run`), created by `tools/pc_build.sh task`.
- To build after M2 lands: `tools/pc_build.sh push`, then `run`, then
  `status` until "flow end", then `fetch`.

## 7. Board harness (prep)

`make -f m4.mk m4-build`: tb_board downloads the machine byte, DIPs and the
whole stream through k3_board's ioctl port (honouring ioctl_wait) into
k3_sdram and the SDRAM model, then runs from power-on and writes .rgbp
frames (m2/compare.py's format). First run on the M2 working copy of
k3_sys: section 8. The full M4 gate (RAM dumps and write logs compared with
MAME) should reuse m2/tb_sys.cpp's dump code once M2 is final.

## 8. First board run (M2 working copy of k3_sys, 2026-10-02)

`tb_board` on 1945kiii: 8,912,896-byte stream through ioctl in 44.6M clocks,
then 300 frames from power-on (529M clocks, about 4.5 minutes on the Mac).
The game boots through the real download and SDRAM path: Oriental Soft logo
by frame 90, the Team Muhaha logo by frame 270, every frame fully drawn from
frame 60. 0 line overruns (worst line 1,031 of 6,144 clocks), CPU fetch
latency at most 9 clocks, 5 forced refreshes, all before the first vblank.

Not yet compared with MAME: with k3_sys's current DTACK handling every
program fetch takes a wait state (section 3.1), so the CPU runs slow and
the frames drift from the oracle. The comparison belongs to the M4 gate
after the k3_sys change.

## Timing closure (2026-10-03)

Three Quartus 17.0 compiles on the compile PC (scheduled task `k3compile`,
E-core affinity; STA via task `k3sta`, `C:\k3_build\sta_paths.tcl`).

| Compile | Change | 96 MHz core setup slack | TNS |
|---|---|---|---|
| 1 | first build | -0.964 ns | -16.923 ns |
| 2 | k3_sdram: registered CPU request, pending-job slot, download FIFO in logic, refresh before download | -0.057 ns (1 path, pend_word to SDRAM_A) | -0.057 ns |
| 3 | k3_sdram: ACT address driven from the pending slot whenever the CPU leaves the bus; k3_video: copy marks of the queued write looked up one clock early | +0.766 ns | 0 |

Compile 1 failing paths (400 reported, all negative): about 270 into
`k3_sdram` SDRAM_A (the 68000 address bus, the program-hit compare, the OKI
addresses and the download FIFO output all reached the command decode and
address mux in one clock), about 90 in `k3_video` from the write queue
index through the 2,048-way copy-mark lookup to the live sprite RAM write
enables and port B address.

### k3_sdram changes

- **CPU request registered.** `i_cpu_req`, `i_cpu_addr` and the hit test
  are registered (`c_req_q`, `c_addr_q`, `c_hit_q`); the hit test uses the
  served word as it stands after the edge (a landing on that clock counts),
  so the word just fetched is never fetched again. Cost: one clock of
  program-fetch latency.
- **Pending slot.** The other engine's next job (download, OKI 1, OKI 2,
  graphics, same priority order) is chosen one clock ahead into `pend_*`;
  a graphics request is granted when it enters the slot. The ACT starts from
  registers, and its row and bank are driven onto the pins whenever the CPU
  engine leaves the command bus free (the SDRAM ignores them under NOP and
  REF), so only `cmd` waits for the start decision.
- **Refresh.** Refresh now goes before a download write. Before, a download
  at full rate starved refresh for the whole download (debt 8 at its end in
  the test bench, drained back to back just as the 68000 started fetching,
  which made one fetch take 12 clocks); a download that long without refresh
  would also risk SDRAM retention on a real board. Refresh may not start on
  the clock a new CPU request appears (`c_rise`: the registered request
  sees it one clock later; `o_prom_req` is a k3_sys state register).
- The download FIFO is forced to logic (`ramstyle "logic"`).

SDRAM test (`make -f m4.mk m4-sdram-all` and `m4-sdram`): every set PASS,
0 data errors, no timing violations, 0 forced refreshes (was 5), CPU
latency histogram 1: 4,386 (repeats), 9: 91,199, 10: 13,113 on the
4M-clock 1945kiii run; **worst case 10 clocks** (was 9), inside k3_sys's
12-clock limit (m2_findings 2.3). Download takes 1.2% longer because
refresh now interleaves.

### k3_video change (behaviour-neutral)

The marks of the queued write (`wq_mk_bg/s0/s1`) are looked up when the CPU
write enters stage R, from the CPU address, including the mark a save sets
on that same edge and the clear at a copy start, so they equal
`mk_*[wq_idx]` exactly and the save decision no longer contains the 2,048-way
mux.

### Verification

- M1 replay: 7,821 / 7,821 MAME frames exact (all 8 captures), synthetic
  scenes 172 / 172, line overruns 0.
- M2 harness, 600 frames from power-on, 1945kiii and flagrall: program ROM
  latency 9 vs 10 clocks gives byte-identical captures and I/O logs
  (1,872 and 3,622 writes, `promlate` 0); before vs after the k3_video
  change also byte-identical, including Flag Rally's 10,536 CPU writes
  during copies (the path the change touches); all gate counters equal.

### Result (compile 3)

| Clock | Setup | Hold |
|---|---|---|
| emu pll general[0] (96 MHz core, SDRAM) | +0.766 ns | +0.250 ns |
| emu pll general[2] (48 MHz video) | +2.448 ns | +0.250 ns |
| pll_hdmi | +0.435 ns | +0.161 ns |
| h2f_user0_clk | +4.301 ns | +0.355 ns |
| spi_sck | +5.110 ns | +0.327 ns |
| FPGA_CLK1_50 / FPGA_CLK2_50 | +7.799 / +11.784 ns | +0.416 / +0.359 ns |
| pll_audio | +15.707 ns | +0.362 ns |

Recovery and removal positive on every clock (worst +0.839 ns). No
multicycle constraints were added.

Resources: 17,044 / 41,910 ALMs (41%), 169 / 553 RAM blocks (31%),
1,276,032 block memory bits (23%), 36 DSP blocks.

RBF: `builds/20261003_0516_Arcade-1945kIII.rbf`, md5
`f8c9dc5352f816c9ba7d8572b4a8ba01`, 3,118,088 bytes.

PC note: the flow's own TimeQuest step crashed (access violation in
quartus_sta, `sta_find_duplicates_of_deleted_net_name`, the PC's known
instability) after the assembler had finished. A standalone `quartus_sta`
run on the same netlist produced the figures above, and re-running
`quartus_asm` alone gave a byte-identical RBF (same md5), so the bitstream
was not affected.

## 9. M4 board gate (2026-10-03)

Board harness (`sim/m4/tb_board.cpp`) now writes everything M2's harness
writes (frames, write logs, palette/tile/sprite/work RAM dumps at each
captured vblank, the I/O stream with beam positions) through k3_board: the
machine byte, DIP switches and the ROM stream go in through the ioctl
port, the program ROM, graphics and both OKIs come from k3_sdram and the
cycle-checked SDRAM model. It also checks the audio output every clock
(o_audio = OKI 1 + OKI 2, x8, saturated, one clock later) and prints every
k3_sys gate counter, now brought out of k3_board (late program reads,
unmapped accesses, ROM-area writes, 0x8c0000 above 4 KB, writes stalled by
a copy). `make -f m4.mk m4-boot` runs the five M2 runs (k3_attract,
k3_play, slspirit_attract, flagrall_attract, flagrall_play) and compares
each with MAME (m2/compare.py) and with the M2 run byte for byte
(m4/compare_m2.py); m4/compare_runs_prefix.py compares two runs over the
frames both have reached.

RTL under test: b124a9c (timing closure) plus jt6295 patch 2 (m3_findings
3), the pause wiring and the x8 audio mix (below).

Result, full length, board vs M2 (both with jt6295 patch 2):

| Run | Frames | Capture files identical | I/O writes identical (beam positions included) | Audio peak |
|---|---|---|---|---|
| k3_attract | 12,001 | 37,950 / 37,950 | 48,934 | 11,192 |
| k3_play | 5,201 | 24,442 / 24,442 | 20,524 | 5,448 |
| slspirit_attract | 9,001 | 27,214 / 27,214 | 35,912 | 5,240 |
| flagrall_attract | 9,001 | 24,740 / 24,740 | 54,686 | 21,032 |
| flagrall_play | 4,801 | 20,220 / 20,220 | 29,165 | 17,928 |

Every run: program fetch latency at most 10 clocks (limit 12), late
program reads 0, unmapped 0, 0x8c0000 above 4 KB 0, line overruns 0, no
forced refresh after the first vblank, copy snapshot mismatches 0, audio
check 0 mismatches and 0 saturated clocks; ROM-area writes equal to MAME's.
The renderer's worst line is longer on the board (up to 3,535 of 6,144
clocks, k3_attract) than in M2 (2,894) because graphics reads now come
through k3_sdram; no pixel changes. Since the board equals M2 byte for
byte, M2's comparison with MAME and its divergence list (m2_findings 1, 5,
8) hold for the board unchanged. Verdict: PASS.

Also verified: Flag Rally downloaded with the exact MRA stream (make_mra
replay of releases/'96 Flag Rally.mra: 0x800000 bytes, identical to the
first 0x800000 of sdram.bin) and with Solite Spirits run first and Flag
Rally downloaded over it (the MiSTer's same-RBF reload): frames identical
to the clean run.

Changes since section 8 (prep):
- Section 3.1 (DTACK for program reads) and section 5 (pause) are done in
  k3_sys (m2_findings 2.3, 6). Pause: OSD option "Pause when OSD is open"
  (O6, default on) and the P key toggle, into k3_board `i_pause`.
- Audio: the mix is now (OKI 1 + OKI 2) x8 with saturation instead of x2
  (18 dB too quiet against MAME's scale); m3_findings 6.
- sim/m4/sdram_model.sv: time counters 64-bit (a 32-bit count wrapped after
  2^31 clocks, 22 s at 96 MHz, and stopped the long runs with a false
  tRP error).

### 9.1 Known issue: black picture after a runtime switch to Flag Rally

On the MiSTer, Flag Rally loaded with `load_core` while Solite Spirits was
running on the same RBF (no bitstream reload) gave black screenshots at 50
and 70 s; loaded after menu.rbf (fresh bitstream) it is correct (title,
town attract, instructions at 12, 27, 57 s). The core switches at runtime
from the rotated framebuffer path (FB_EN, 224 lines, 59.64 Hz) to the
plain path (240 lines, 49.60 Hz), after about a second without syncs (the
core holds video in reset during the download). screen_rotate updates
FB_EN on each VSync and sys_top follows FB_EN at runtime (fb_crc), so the
core side looks right.

Shell simulation (sim/m4/shell: the whole emu module with the real
arcade_video, screen_rotate, scandoubler, hq2x and gamma_corr, a stub
hps_io and PLL, the SDRAM model): Solite Spirits for 120 output frames,
then Flag Rally downloaded over it with no reset, exactly the MiSTer
sequence. The emu outputs are correct: FB_EN falls from 1 to 0 on the
first Flag Rally VSync, VIDEO_ARX/ARY change from 3:4 to 4:3, and VGA_* carry
the picture (240 lines, 315 hsyncs per frame, mean RGB 112-128 at frames
50-100, the same as a fresh Flag Rally load). So the black picture is not
in the core or the emu shell; it is downstream, in sys_top / the HPS
scaler's handling of a runtime FB_EN 1 -> 0 change together with a
59.64 -> 49.60 Hz mode change (vsync_adjust=2 on this MiSTer). Not fixed
in the core. The shell sim needs a simulation-only copy of
sys/video_mixer.sv (m4/shell/video_mixer_sim.sv: HDMI_FREEZE and the gamma
enable tied low as Quartus ties them, colour nets hoisted out of an
unnamed generate block Verilator does not resolve); sys/ is unchanged.
Trigger: changing between a vertical and a horizontal set without an RBF
reload. Workaround: load from the menu (reloads the RBF). Tests that would
narrow it on hardware: the same switch with vsync_adjust=0; the reverse
switch; whether the analog output shows a picture while HDMI is black.
If it is the framework's, report it to MiSTer-devel with this trigger.

## Output gain and OSD volume (2026-10-03)

The board mix gain is now x48 for the k3 sets and x12 for Flag Rally (was x8 for all), with an OSD Volume option (O78: Normal, +6 dB, -6 dB, -12 dB). Measurements and the Final Star Force reference are in m3_findings 6. Board harness: o_audio equals the expected gain times the two M6295 outputs on every clock, 0 mismatches and 0 saturated clocks over 1,500 frames of k3_play (peak 32,688) and flagrall_play. Compile 5 (C:\k3_build2): every clock non-negative, core 96 MHz setup +0.994 ns, hold +0.318 ns, HDMI setup +0.502 ns. RBF builds/20261003_0955_Arcade-1945kIII.rbf, md5 ae796bf1a24c25f127f3ec61eb5f50fd.
