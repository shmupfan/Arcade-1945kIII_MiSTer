# M3 findings: sound (two M6295)

Date: 2026-10-03. Scope: both jt6295 instances in k3_sys (command decode,
banking, ADPCM decode, attenuation, mix), against MAME 0.288, sample by
sample. The command streams themselves were already proven equal in M2.

Reproduce: `cd sim && make -f m3.mk m3-wav m3-build-mame m3-run m3-compare`
(MAME a few minutes; the core runs about an hour each on the Mac).
Decomposition: `python3 m3/decompose_oki.py <run>/okich.raw <run>/okibusy.txt
mame/out/m3wav_<run>.wav`.

## 1. Method

- **MAME side.** `-wavwrite` at `-samplerate 7575`, MAME 0.288's M6295
  stream rate. At that rate MAME writes the stream without resampling:
  every unclipped value is a multiple of 16 (checked on every run), i.e.
  16 x (OKI 1 + OKI 2) in the chip's 12-bit units, gain 1.0 per chip into
  one speaker (L676, L687), clipped to 16 bits.
- **Core side.** `m3/tb_snd.cpp` (k3_sys, same ROM models and input replay
  as M2) records each chip's output at its own sample enable, each chip's
  four channel values (the time-multiplexed values its accumulator adds,
  checked to sum exactly to the chip output one sample later), and every
  change of the busy bits.
- **Rate.** MAME 0.288 runs the M6295 at 1,000,000 / 132 computed as an
  integer (7,575 Hz instead of 7,575.76 Hz, m2_findings 5.3). Sample-level
  comparison uses the diagnostic build `OKI_HZ=999900` (MAME's effective
  rate); level and stream checks also ran at the hardware rate.
- **Decomposition** (`m3/decompose_oki.py`). MAME's sample = the sum over
  every phrase the core played of that phrase's channel values, each
  phrase moved by a whole number of M6295 samples and optionally ending
  up to 2 samples earlier, minus a rounding term (section 2). Phrases come
  from the busy log, per channel. Shifts are fitted per phrase (+-2
  samples, then a correlation search over +-1 s for any phrase still
  wrong). A sample is explained when 0 <= MAME - model <= the number of
  negative channel values in it. Every other sample is reported.

Runs (MAME-rate build, jt6295 with both patches, section 3):

| Run | Set | Frames | Sound samples | Exact | 1-LSB rounding | Unexplained | Phrase start shifts | OKI writes equal | Level vs MAME |
|---|---|---|---|---|---|---|---|---|---|
| k3_attract | 1945kiii | 6,001 | 391,822 | 538,034 | 224,160 | 34 | 268 at 0, 63 at -1, 3 further | 1,694 / 1,694 | +0.028 dB |
| k3_play (coin, start, stage 1) | 1945kiii | 5,201 | 509,428 | 293,677 | 366,928 | 9 | 55 at 0, 26 at -1, 1 at +1 | 237 / 237 | +0.060 dB |
| slspirit_attract | slspirit | 4,001 | 224,948 | 382,598 | 125,578 | 17 | 116 at 0, 39 at -1 | 1,167 / 1,167 | +0.033 dB |
| flagrall_attract | flagrall | 4,001 | 384,636 | 523,920 | 85,614 | 1,456 | 31 at 0, 17 at -1, 10 at 2-7 | 186 / 186 | +0.000 dB |
| flagrall_play (coin, start, racing) | flagrall | 4,801 | 637,798 | 603,848 | 129,304 | 4 | 35 at 0, 18 at -1, 17 at 2-10 | 228 / 228 | +0.005 dB |

("Exact" and "rounding" count every compared sample, silence included.)
In total 1,520 of 2,148,632 samples with sound are unexplained (0.07%),
1,456 of them in one Flag Rally window (section 4). Levels per 5 s segment
with sound: -0.026 to +0.593 dB (the largest on quiet segments, where the
rounding of section 2 is a larger share). Bank switching: both chips' banks
on the k3 sets and Flag Rally's three banks are exercised by these runs;
every phrase decodes to MAME's values, so the banked ROM addressing is
right.

Hardware-rate runs (the build that goes on the board), before patch 2:
k3_play +0.059 dB, flagrall_play +0.006 dB against MAME, 20 ms envelope
correlation 0.999 and 0.998, OKI command streams equal (237 and 228
writes). The M2 re-run with both patches is in m2_findings / m4_findings.

## 2. Rounding (R10): one LSB on negative attenuated values

MAME passes each channel's float product `m_adpcm.clock(nibble) *
m_volume` to `add_int`'s `s32` sample argument (okim6295.cpp L352), which
truncates toward zero. jt6295 multiplies by the same volume table (32, 22,
16, 11, 8, 6, 4, 3, 2 over 32) and takes `mul[16:5]`, a floor. The two
differ by one LSB (of 12 bits) on a negative product with a fraction, and
nowhere else. 931,584 samples across the five runs differ from MAME this
way: the core one LSB per negative channel below MAME at most, never
above it. Which rounding the chip uses
is unknown (research item R10); the core keeps jt6295's floor (what
dropping low bits in two's complement hardware gives). Inaudible: at most
-66 dB per channel.

## 3. Bug found and fixed: start command to a busy channel (R9)

**Symptom.** Before the fix, Solite Spirits' attract was +7.4 dB louder
than MAME overall and up to +15.6 dB in two stretches (20-24 s, 55-58 s);
1945k III's attract +3.6 dB (up to +10.9 dB). Everything else was within
0.1 dB.

**Cause.** The games send the same start command (phrase 0x21, channel 4,
attenuation 3) every frame while the channel is still playing it. MAME's
okim6295 ignores a start for a playing voice (L281-284, "Requested to play
sample on non-stopped voice"). jt6295 reloads the channel whenever a start
request comes round, busy or not (`jt6295_serial.v`: `up_start` drives the
reload of start, stop and attenuation), so the core restarted the phrase's
attack 60 times a second.

**Fix.** `start_ok = up_start & ~busy_out` in the reload terms; the request
is still acknowledged so jt6295_ctrl clears it. Documented as patch 2 in
`rtl/vendor/jt6295/PROVENANCE.md` with the evidence:
- MAME L281-284 (above);
- jt6295's own README (lines 31-33): "The current JT6295 is to ignore
  commands to the same channel as long as the playback has not ended"; the
  code does not do what its README says (upstream master the same,
  checked 2026-10-03);
- the games re-send the command every frame, which only makes sense on a
  chip that ignores it;
- the MSM6295 datasheet was not checked (jt6295's README: "has not been
  verified"): research item R9. Believed accurate: ignore.

**Result.** Solite Spirits +0.033 dB, 1945k III attract +0.028 dB, every
phrase explained (section 1). It also changes when busy bits fall on
these games (a re-sent start no longer extends the phrase), which feeds
the games' busy polls; the M2 boots were re-run with the patch (m4/m2
reports).

**Other cores.** The Dooyong and Hyper Duel cores ship jt6295 without this
patch and may restart phrases the same way if their games re-send starts.
Flagged for Lee; those repositories were not touched.

## 4. What is not explained

- **Flag Rally attract, 74-80 s (1,456 samples).** Music and effects are
  restarted by the game when its once-a-frame busy poll sees a channel go
  idle; around 74 s and 77-80 s several restarted phrases land 3 to 7
  samples away from MAME, and some samples there fit no single shift per
  phrase. Level there is within 0.1 dB. Likely the same phrase-end timing
  question as R7 (when the busy bit falls relative to the last sample); not
  traced further.
- **The other 64 samples** (k3_attract 34, slspirit 17, k3_play 9,
  flagrall_play 4) are single samples at phrase boundaries.

## 5. Phrase timing: what the shifts mean

A phrase that starts one sample apart on the two sides is a command that
landed in a different M6295 sample period: the write is a few pixels apart
(the 68000 interrupt acknowledge, m2_findings 5.1, R8) or the two sample
clocks have a different phase (the M6295's sample clock phase against the
CPU is set at power-on on a board and is arbitrary). About a third of the
phrases start one sample apart, none more than one on the k3 sets except
3 in k3_attract. Phrases that end one sample earlier in MAME (161 of 331 in
k3_attract, 62 of 155 in Solite Spirits, few on Flag Rally) are mostly
stop commands landing in an earlier period; whether every one is a stop
command, or part of it is the phrase-end timing of R7, was not separated.

## 6. Level on the board

Revised 2026-10-03 after Lee's hardware test ("the sound is quite low").
M3 checks the core against MAME's scale; the output level on the MiSTer
is a separate choice, because the PCB sets its level with a volume pot
after the two M6295 (VR1, driver notes L72/L94). The first board build
used x8 for every set, which left the k3 sets about 15 dB below the
other cores.

Reference: Final Star Force on the Tecmo 16 core, which Lee reports as
normal loudness. Its board mix (Tecmo 16 sim/build/m3, 48 kHz stereo),
1 s RMS over active seconds:

| Run | Peak | Median | p95 | Clipped samples |
|---|---|---|---|---|
| fs_play (64 s) | -0.0 dBFS | -16.4 dBFS | -13.0 dBFS | 44 |
| fs_attract (63 s) | -0.1 dBFS | -18.8 dBFS | -13.4 dBFS | 0 |
| Dooyong pollux / lastday / bluehawk | -0.0 / -3.1 / -2.6 dBFS | RMS -12.3 / -18.1 / -19.9 dBFS (whole run) | | |

This core, measured on the M3 runs (unclipped M6295 sum, 7,575.76 Hz):

| Run | Gain | Peak | Median | p95 | Clipped |
|---|---|---|---|---|---|
| k3_play | x8 (old) | -15.6 | -32.9 | -28.1 | 0 |
| k3_play | **x48** | -0.0 | -17.4 | -12.5 | 0 |
| k3_attract | **x48** | -0.4 | -19.3 | -12.6 | 0 |
| slspirit_attract | **x48** | -0.4 | -19.1 | -12.9 | 0 |
| k3 sets | x64 | -0.0 | -14.9 | -10.1 | 0.013-0.016% |
| flagrall_play | x8 (old) | -5.3 | -22.2 | -18.6 | 0 |
| flagrall_play | **x12** | -1.7 | -18.7 | -15.1 | 0 |
| flagrall_attract | **x12** | -1.1 | -18.6 | -15.0 | 0 |
| flagrall | x16 | -0.0 | -16.2 | -12.6 | about 0.001% |

Chosen: x48 for the k3 sets and x12 for Flag Rally (whose music runs
about 11 dB hotter in M6295 units). Typical gameplay lands within about
1-2 dB of Final Star Force and no sample of any M3 run clips; the
loudest k3 sample (681 units) gives 32,688 of 32,767. Saturation stays as
a safety net. An OSD option (O78 "Volume": Normal, +6 dB, -6 dB, -12 dB)
shifts the gain; at +6 dB loud passages saturate by design. The board
harness checks o_audio against 48 x (k3) or 12 x (Flag Rally) the two
M6295 outputs every clock: 0 mismatches and 0 saturated clocks over 1,500
frames of k3_play (peak 32,688) and flagrall_play. Only the final output
gain changed; nothing that the MAME comparisons read.

## 6.1 Silence during the continue countdown (Lee, 2026-10-03)

Lee heard no sound during the continue countdown. MAME does the same.
Run: 1945kiii and slspirit from power-on, coin at frame 600, start, six
taps of fire on the ship select, then no input (wiped cfg, `-wavwrite`
at 7,575 Hz, oracle `writes.csv`; `mame/out/cont_*`).

- 1945kiii: the ship dies, GAME OVER and CONTINUE? 9 appear at about
  44 s (frame 2,641) and count down to 1 at about 58 s. The game writes
  two OKI commands at 42 s (the game-over phrase), which has faded by
  about 50 s; then it writes no OKI command at all until frame 3,599
  (60.0 s), and the attract restarts at 62 s. MAME's output is silent
  (RMS 0) from 51 s to 61 s, and 6-9 s earlier during the stage start.
- slspirit: the same pattern.
- The core with the same inputs (M6295 at MAME's rate, the `mamefix`
  build): OKI commands equal MAME's in order, value and frame (58 of 58)
  to frame 1,491, and per-second levels match MAME's within about 1%
  for the first 25 s on both sets. A run to frame 3,800 was stopped at
  its two-hour limit before reaching the countdown (the Mac was shared
  with other simulations), so the countdown itself is not covered by a
  core run; the M2 gate already showed every OKI write equal to MAME's over 5,201
  frames of gameplay with coin, start, deaths and continues.

Verdict: the silent countdown is the game's own behaviour in MAME, and
the core reproduces MAME's command stream. Nothing to fix. PCB footage of
a continue countdown would confirm it on hardware (logged as R11).

## 7. Files

| File | Content |
|---|---|
| `sim/m3/tb_snd.cpp` | sound harness: per-chip samples, per-channel values, busy log, I/O log |
| `sim/m3/compare_oki.py` | stream, level, clipping, hardware-rate envelope |
| `sim/m3/decompose_oki.py` | per-phrase decomposition (section 1) |
| `sim/m3/jt6295_busy_patch.py` | the patch-2 edit, used to make the diagnostic copy and the vendored file |
| `sim/m3.mk` | m3-wav, m3-build, m3-build-mame, m3-build-fix, m3-run, m3-compare |
| `rtl/vendor/jt6295/hdl/jt6295_serial.v`, `PROVENANCE.md` | patches 1-3 (consolidated, section 8) |
| `rtl/k3_board.sv` | mix gain x48 (k3) / x12 (Flag Rally) with saturation, OSD volume |

## 8. Consolidated jt6295: patch 3 added (2026-10-03)

The jt6295 copy in this core and in the Tecmo 16 core is now one file with
three patches (rtl/vendor/jt6295/PROVENANCE.md): 1 inclusive stop byte,
2 start to a busy channel ignored, and 3 from the Tecmo 16 core: the busy
flags follow the channel state committed at cen4, so a stop that already
reads idle cannot be cancelled by the next start (Ganbare Ginkun's fade
steps, tecmo16-mister m3_findings 4). The three touch different terms of
jt6295_serial.v and do not interact (PROVENANCE.md).

Re-verification of this core with patch 3 (MAME-rate build for sound,
hardware-rate build for the I/O stream):

| Run | Check | Result |
|---|---|---|
| slspirit_attract, 4,001 frames | M3 decomposition against MAME | 17 unexplained samples (as before), +0.033 dB (as before), 1,167 / 1,167 OKI writes equal; exact samples 382,604 (was 382,598); phrases whose stop MAME applies one sample earlier: 20 (was 62) |
| k3_play | M3 core output | byte-identical to the earlier run to frame 2,500 (run stopped at the shell's two-hour limit) |
| flagrall_play | M3 core output | byte-identical to the earlier run to frame 2,000 (same) |
| k3_play | M2 I/O stream | byte-identical to the patch-2 gate, beam positions included, to frame 2,751 |
| flagrall_play | M2 I/O stream | byte-identical to the patch-2 gate over the full 4,801 frames (29,164 writes, the whole file) |

Patch 3 changes no command, no status read result and no level in this
core; the only measurable effect is on when a stop takes effect, which now
lands in the same M6295 sample as MAME's more often (20 phrases ending one
sample apart instead of 62). Believed accurate: the patched core, on the
Ginkun evidence in the Tecmo 16 core; MAME applies a stop at once.

Build with the consolidated file and compile 5's output gain (commit
670c024): compile 6, C:\k3_build2, 2026-10-03 13:28, every clock
non-negative (core 96 MHz setup +0.563 ns, hold +0.254 ns; HDMI +0.400
ns), 41% ALMs, 31% RAM blocks; `builds/20261003_1344_Arcade-1945kIII.rbf`,
md5 5a19ad4257396c379cca7c6e061c8fc7. Not yet on hardware.
