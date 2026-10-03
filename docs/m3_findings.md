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

The board mixes OKI 1 + OKI 2 x8 with saturation (k3_board): 6 dB below
MAME's scale, chosen because MAME's own sum clips (Flag Rally attract peaks
at 2,415 units of 2,048, MAME clips 6 samples; gameplay 2,237, 10 samples).
At x8 the loudest sample of every run is 19,320 of 32,767, so the board
never clips. Checked per clock in the board harness (m4_findings).

## 7. Files

| File | Content |
|---|---|
| `sim/m3/tb_snd.cpp` | sound harness: per-chip samples, per-channel values, busy log, I/O log |
| `sim/m3/compare_oki.py` | stream, level, clipping, hardware-rate envelope |
| `sim/m3/decompose_oki.py` | per-phrase decomposition (section 1) |
| `sim/m3/jt6295_busy_patch.py` | the patch-2 edit, used to make the diagnostic copy and the vendored file |
| `sim/m3.mk` | m3-wav, m3-build, m3-build-mame, m3-build-fix, m3-run, m3-compare |
| `rtl/vendor/jt6295/hdl/jt6295_serial.v`, `PROVENANCE.md` | patch 2 |
| `rtl/k3_board.sv` | mix gain x8 with saturation |
