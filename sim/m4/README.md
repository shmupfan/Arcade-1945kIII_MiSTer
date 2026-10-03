# sim/m4: board-level simulation (M4)

Run from sim/ with `make -f m4.mk <target>` (or through sim/Makefile once it
includes m4.mk). Needs `make regions` (M0) for build/regions/<set>/sdram.bin.

| Target | What it proves |
|---|---|
| `m4-mra` | every MRA rebuilds its set's sdram.bin byte for byte (Main_MiSTer loader rules) |
| `m4-sdram` | k3_sdram against the SDRAM model: the 1945kiii stream downloaded through the ioctl port, then 68000-like fetches, graphics at full pressure and both OKIs together for 4M clocks; every word checked; CPU latency histogram; refresh accounting; the model stops on any protocol or timing violation (tRCD, tRP, tWR, tRRD, tRFC, refresh with a row open, DQ contention) |
| `m4-sdram-all` | the same, 1M clocks, every set |
| `m4-lint` | Verilator -Wall on k3_sdram and k3_board |
| `m4-build` | tb_board: k3_board + SDRAM model, everything through ioctl as on the MiSTer; writes .rgbp frames |

The shell lints with the framework stubs:

    verilator --lint-only -Wno-fatal -DLINT_STUBS -DMISTER_FB=1 -I.. -I../sys \
      -I../rtl/vendor/fx68k -I../rtl/vendor/jt6295/hdl --top-module emu \
      m4/lint_stubs.sv ../Arcade-1945kIII.sv ../rtl/*.sv ../rtl/vendor/fx68k/*.sv \
      ../rtl/vendor/jt6295/hdl/*.v

Full M4 gate (after M2): extend tb_board.cpp with m2/tb_sys.cpp's vblank
dumps and write logs (hierarchy prefix u_board.u_sys) and compare with
m2/compare.py, plus a "late program fetch" counter once k3_sys asserts DTACK
early for program reads (docs/m4_findings.md 3.1).
