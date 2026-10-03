# jt6295 (OKI M6295)

Copied 2026-10-02 from the Dooyong core (dooyong-mister/rtl/vendor/jt6295,
repository commit d0445799bba5e09097d14e5c65e3794cfedf2b79). Jose Tejada,
GPL-3.0 (LICENSE). Two instances (PLAN M2/M3).

## Patch in this core (2026-10-02, m2_findings 5.3)

`hdl/jt6295_serial.v`: the phrase end. Original
`assign over = rom_addr >= stop_out;` ends a voice when its byte address
reaches the stop address, after playing only the first nibble of the stop
byte: 2 * (stop - start) + 1 samples. The MSM6295 phrase table gives the
last byte of the phrase as the stop address, and MAME's okim6295 plays
2 * (stop - start + 1) samples. Patched to
`assign over = cnt >= {stop_out, 1'b1};` (end after the second nibble of the
stop byte). Measured with sim/m2/okitest (jt6295 alone, phrases 1, 5, 9,
12 and 25 of Flag Rally's bank 1): the busy bit lasted 137 one-MHz enables
(1.04 samples) less than the nominal length before the patch, 5 enables
(start latency) less after it. '96 Flag Rally polls the busy bits once a
frame and restarts its music when a channel goes idle; with the original
end its 16.8 s track ended one poll early (frame 1505 instead of MAME's
1506), and the program diverged from MAME from there.

The Dooyong provenance note follows (it also covers jt51, which this core
does not use). Edits it lists that apply here: the ramstyle attribute in
jt6295_adpcm.v (Quartus) and the Verilator public comments in jt6295.v
(simulation only).

# jt51 and jt6295

Copied on 2026-09-28 from the Hyper Duel MiSTer core
(`hyperduel-mister/rtl/vendor/`, repository commit
e2f18f5a966213734d3f346f91e908eff52fde7d), where both are proven on
hardware. Upstream: jotego/jt51 and jotego/jt6295 (GPL-3.0, see each
LICENSE). Only `hdl/`, `LICENSE` and `README.md` were copied.

Carried-over patch (from Hyper Duel's `rtl/vendor/PATCHES.md`):
- `jt6295/hdl/jt6295_adpcm.v`: `(* ramstyle = "logic" *)` on `lut` and
  `gain_lut`, avoiding a Quartus 17.0 RAM-inference crash on these tiny
  tables. No functional change; Verilator ignores it.

Dooyong edits (simulation only, no effect on synthesis):
- `jt51/hdl/jt51_timers.v`: an `ifdef JT51_TIMER_EXACT` block (off by
  default) that counts the timers from the load write in phiM clocks, as
  MAME's ymfm does, instead of on jt51's internal sample-cycle tick. Used
  for the M3 investigation in `docs/m3_findings.md`; the core uses jt51's
  own timers.
- `jt6295/hdl/jt6295.v`: `verilator public_flat_rd` comments on the
  `busy`, `start` and `stop` wires so the harness can log channel state.
