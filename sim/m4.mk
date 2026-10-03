# M4 targets (MiSTer board, SDRAM, MRA). Included by sim/Makefile, or run on
# its own from sim/:  make -f m4.mk <target>
#
#   make m4-mra          generate every MRA and prove each one rebuilds
#                        sdram.bin byte for byte (Main_MiSTer loader rules)
#   make m4-sdram        k3_sdram + SDRAM model: download 1945kiii's image
#                        through the ioctl port, then CPU fetches, graphics at
#                        full pressure and both OKIs at once for 4M clocks;
#                        every word checked, CPU latency histogram, refresh
#                        accounting, model stops on any timing violation
#   make m4-sdram-all    the same for every set (flagrall's layout differs)
#   make m4-build        board harness (k3_board: k3_sys + k3_sdram + ioctl),
#                        needs M2's k3_sys
#   make m4-lint         Verilator lint of k3_sdram and k3_board
#
# sim/build/regions/<set>/sdram.bin comes from `make regions` (M0).

PY       ?= python3
VERILATOR ?= verilator
M4DIR    ?= build/m4
M4SETS   := 1945kiii 1945kiiin 1945kiiio 1945kiiipt slspirit flagrall

M4SDRTL  := ../rtl/k3_sdram.sv m4/sdram_model.sv m4/tb_sdram.sv
M4SDBIN  := $(M4DIR)/sdram_obj/Vtb_sdram

.PHONY: m4-mra m4-sdram m4-sdram-all m4-sdram-build m4-lint m4-build

m4-mra:
	cd .. && $(PY) tools/make_mra.py

$(M4SDBIN): $(M4SDRTL) m4/tb_sdram.cpp
	$(VERILATOR) --cc --exe --build -j 4 -Wno-fatal -Wno-MULTIDRIVEN --top-module tb_sdram \
	  -Mdir $(M4DIR)/sdram_obj -o Vtb_sdram -CFLAGS -O2 $(M4SDRTL) m4/tb_sdram.cpp

m4-sdram-build: $(M4SDBIN)

m4-sdram: $(M4SDBIN)
	$(M4SDBIN) +sdram=build/regions/1945kiii/sdram.bin +cycles=4000000 +seed=1 | tee $(M4DIR)/sdram_1945kiii.log
	@grep -q '^PASS' $(M4DIR)/sdram_1945kiii.log

m4-sdram-all: $(M4SDBIN)
	@for s in $(M4SETS); do \
	  $(M4SDBIN) +sdram=build/regions/$$s/sdram.bin +cycles=1000000 +seed=7 > $(M4DIR)/sdram_$$s.log; \
	  printf '%-11s ' $$s; tail -n 1 $(M4DIR)/sdram_$$s.log; \
	done

m4-lint:
	$(VERILATOR) --lint-only -Wall -Wno-MULTIDRIVEN --top-module k3_sdram ../rtl/k3_sdram.sv
	$(VERILATOR) --lint-only -Wall -Wno-MULTIDRIVEN -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
	  -I../rtl/vendor/fx68k -I../rtl/vendor/jt6295/hdl --top-module k3_board \
	  ../rtl/k3_dpram.sv ../rtl/k3_fifo.sv ../rtl/k3_video.sv ../rtl/k3_sys.sv \
	  ../rtl/vendor/fx68k/fx68k.sv ../rtl/vendor/fx68k/fx68kAlu.sv ../rtl/vendor/fx68k/uaddrPla.sv \
	  $(wildcard ../rtl/vendor/jt6295/hdl/*.v) ../rtl/k3_sdram.sv ../rtl/k3_board.sv

# Board harness: see sim/m4/README.md (built once M2's k3_sys is final).
M4BRTL := ../rtl/k3_dpram.sv ../rtl/k3_fifo.sv ../rtl/k3_video.sv ../rtl/k3_sys.sv \
          ../rtl/vendor/fx68k/fx68k.sv ../rtl/vendor/fx68k/fx68kAlu.sv ../rtl/vendor/fx68k/uaddrPla.sv \
          $(wildcard ../rtl/vendor/jt6295/hdl/*.v) ../rtl/k3_sdram.sv ../rtl/k3_board.sv \
          m4/sdram_model.sv m4/tb_board.sv
M4BBIN := $(M4DIR)/board_obj/Vtb_board

$(M4BBIN): $(M4BRTL) m4/tb_board.cpp
	$(VERILATOR) --cc --exe --build -j 6 -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN --x-assign fast --x-initial fast --top-module tb_board \
	  -I../rtl/vendor/fx68k -I../rtl/vendor/jt6295/hdl \
	  -Mdir $(M4DIR)/board_obj -o Vtb_board -CFLAGS -O2 $(M4BRTL) m4/tb_board.cpp

m4-build: $(M4BBIN)

# ---------------------------------------------------------------- M4 gate
# Board boots: the M2 runs (same frames, captures, DIP switches, inputs),
# but through k3_board: ioctl download, k3_sdram and the SDRAM model.
#   make m4-boot       run them (parallel), then m4-compare
#   make m4-compare    m2/compare.py against MAME (as M2), and every output
#                      file against the M2 run of the same game, byte for
#                      byte (io.txt includes the beam position of each write)
M4OUT  := build/m4/gate
M2GATE := build/m2/gate
M4RUNS := k3_attract:1945kiii:0:12001:FEEF k3_play:1945kiii:0:5201:FEEF \
  slspirit_attract:slspirit:0:9001:FFEF flagrall_attract:flagrall:1:9001:FFEF \
  flagrall_play:flagrall:1:4801:FFEF

.PHONY: m4-boot m4-compare
m4-boot: $(M4BBIN)
	@for r in $(M4RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); fl=$$(echo $$r | cut -d: -f3); \
	  nf=$$(echo $$r | cut -d: -f4); dsw=$$(echo $$r | cut -d: -f5); o=$(M4OUT)/$$run; \
	  rm -rf $$o && mkdir -p $$o; cp $(M2GATE)/$$run/cap.txt $$o/cap.txt; \
	  inp=""; [ -f mame/out/$$run/inputs.csv ] && [ $$(wc -l < mame/out/$$run/inputs.csv) -gt 1 ] && inp="+inputs=mame/out/$$run/inputs.csv"; \
	  $(M4BBIN) +sdram=build/regions/$$set/sdram.bin +machine=$$fl +dsw=$$dsw +frames=$$nf $$inp \
	    +cap=$$o/cap.txt +out=$$o +io=$$o/io.txt > $$o/run.log 2>&1 & \
	done; wait
	$(MAKE) -f m4.mk m4-compare

m4-compare:
	@rc=0; for r in $(M4RUNS); do run=$$(echo $$r | cut -d: -f1); \
	  echo "== $$run"; tail -n 2 $(M4OUT)/$$run/run.log | head -1; \
	  $(PY) m2/compare.py $(M4OUT)/$$run mame/out/$$run --ram mame/out/m2ram_$$run --quiet --diff $(M4OUT)/diff_$$run || rc=1; \
	  $(PY) m4/compare_m2.py $(M4OUT)/$$run $(M2GATE)/$$run || rc=1; \
	done; exit $$rc
