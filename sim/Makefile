# 1945k III / Solite Spirits / Flag Rally simulation and oracle harness.
#
# M0 targets (MAME 0.288 on PATH, or MAME=...; ROM zips in ../roms):
#   make roms-check      CRC/SHA1/size of all 6 sets vs the table generated
#                        from reference/mame/1945kiii.cpp
#   make regions         rebuild every MAME region + SDRAM image (build/regions)
#   make mame-regions    dump regions from MAME for all 6 sets and compare
#                        byte for byte with `make regions`
#   make oracle          all captures below (runs in parallel, ~4 min)
#   make oracle-verify   Python renderer vs MAME on every captured frame
#   make analyze         write-log and sprite-list summaries of every capture
#   make m0              everything above, in order
#
# M1 targets (Verilator; need `make regions` and the M0 captures):
#   make m1-build        build the k3_video frame-replay harness
#   make m1-verify       RTL vs MAME on every M0 capture frame, all 6 sets (gate)
#   make m1-synth        synthetic scenes vs k3_render.py (gate)
#   make m1-midscan      targeted MAME captures of every frame with a copy or
#                        scroll write in the visible lines, replayed with the
#                        change at MAME's beam position (expected divergences)
#   make m1-capacity     sprites-per-line probe (not a gate: reports where the
#                        pessimistic ROM port runs out of line time)
#   make m1              build, verify, synth, midscan
#
# Every MAME run starts from a wiped cfg/nvram directory (mame/run_mame.sh),
# so captures are reproducible from power-on. Output lands in mame/out
# (gitignored, about 2.5 GB with the default plan).

PY      ?= python3
MAME    ?= mame
export MAME
OUT     := mame/out
RUN     := mame/run_mame.sh
ORACLE  := mame/k3_oracle.lua
ALLSETS := 1945kiii 1945kiiin 1945kiiio 1945kiiipt slspirit flagrall

# Capture plan (frame = MAME frame notifier count; k3 59.64 Hz, flagrall
# 49.61 Hz). 1945kiii attract: title/attract loop about 2,010-2,130 frames,
# a different stage demo each pass; the dense window 9,300-9,899 holds the
# busiest demo seen in the survey (up to 365 visible sprites).
K3_ATTRACT   := 1-12000/8,9300-9899
K3_PLAY      := 760-5200/4
SL_ATTRACT   := 1-9000/8,2000-2299
FR_ATTRACT   := 1-9000/8,3000-3299
FR_PLAY      := 760-4800/4
CLONE_FRAMES := 30-9000/30
CLONES       := 1945kiiin 1945kiiio 1945kiiipt
RUNS := k3_attract k3_play slspirit_attract flagrall_attract flagrall_play $(addprefix clone_,$(CLONES))

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out m1 m1-build m1-verify m1-synth m1-midscan m1-capacity m2-build m2-oracle m2-boot m2-compare m2-soak m2-okitest

roms-check:
	$(PY) ../tools/check_roms.py

regions:
	$(PY) ../tools/build_regions.py

mame-regions: regions
	@for s in $(ALLSETS); do \
	  DUMP_DIR=$(OUT)/regions/$$s $(RUN) $$s mame/dump_regions.lua -seconds_to_run 5 >/dev/null 2>&1 \
	    || echo "MAME failed on $$s"; \
	done
	$(PY) ../tools/compare_regions.py $(ALLSETS)

oracle:
	rm -rf $(addprefix $(OUT)/,$(RUNS))
	DUMP_DIR=$(OUT)/k3_attract DUMP_FRAMES=$(K3_ATTRACT) $(RUN) 1945kiii $(ORACLE) >$(OUT)/k3_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/k3_play DUMP_FRAMES=$(K3_PLAY) INPUTS="$$($(PY) ../tools/play_inputs.py k3 600 5200)" \
	  $(RUN) 1945kiii $(ORACLE) >$(OUT)/k3_play.log 2>&1 & \
	DUMP_DIR=$(OUT)/slspirit_attract DUMP_FRAMES=$(SL_ATTRACT) $(RUN) slspirit $(ORACLE) >$(OUT)/slspirit_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/flagrall_attract DUMP_FRAMES=$(FR_ATTRACT) $(RUN) flagrall $(ORACLE) >$(OUT)/flagrall_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/flagrall_play DUMP_FRAMES=$(FR_PLAY) INPUTS="$$($(PY) ../tools/play_inputs.py flagrall 600 4800)" \
	  $(RUN) flagrall $(ORACLE) >$(OUT)/flagrall_play.log 2>&1 & \
	for s in $(CLONES); do \
	  DUMP_DIR=$(OUT)/clone_$$s DUMP_FRAMES=$(CLONE_FRAMES) $(RUN) $$s $(ORACLE) >$(OUT)/clone_$$s.log 2>&1 & \
	done; wait
	@for r in $(RUNS); do test -s $(OUT)/$$r/summary.txt || { echo "run $$r did not finish"; exit 1; }; done

oracle-verify:
	@rc=0; for r in $(RUNS); do \
	  echo "== $$r"; $(PY) oracle/compare_frames.py $(OUT)/$$r --quiet || rc=1; \
	done; exit $$rc

analyze:
	$(PY) ../tools/analyze_writes.py $(addprefix $(OUT)/,$(RUNS))

m0: roms-check mame-regions oracle oracle-verify analyze

clean-out:
	rm -rf $(OUT) build

# ---------------------------------------------------------------- M1
VERILATOR ?= verilator
M1RTL := ../rtl/k3_dpram.sv ../rtl/k3_fifo.sv ../rtl/k3_video.sv
M1BIN := build/m1/obj_dir/Vk3_video
M1RUNS := $(addprefix $(OUT)/,$(RUNS))
MIDRUNS := mid_k3_attract mid_k3_play mid_slspirit_attract mid_clone_1945kiiin mid_clone_1945kiiio mid_clone_1945kiiipt

$(M1BIN): $(M1RTL) m1/tb_video.cpp
	$(VERILATOR) --cc --exe --build -O3 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND \
	  --top-module k3_video --Mdir build/m1/obj_dir -j 0 \
	  -CFLAGS -O2 $(M1RTL) m1/tb_video.cpp

m1-build: $(M1BIN)

m1-verify: $(M1BIN)
	$(PY) m1/replay.py $(M1RUNS) --quiet

m1-synth: $(M1BIN)
	$(PY) m1/make_scenes.py build/m1/scenes
	$(PY) m1/replay.py $(wildcard build/m1/scenes/*) --quiet

# frame lists from `m1/midscan.py --frames` over the M0 captures (S-1 and S
# for each frame S with a visible copy or scroll write)
m1-midscan: $(M1BIN)
	rm -rf $(addprefix $(OUT)/,$(MIDRUNS))
	( DUMP_DIR=$(OUT)/mid_k3_attract DUMP_FRAMES=14-15,37-38,868-869,2940-2941,4961-4962,7040-7041,9175-9176,11217-11218 \
	    $(RUN) 1945kiii $(ORACLE) >$(OUT)/mid_k3_attract.log 2>&1; \
	  DUMP_DIR=$(OUT)/mid_k3_play DUMP_FRAMES=14-15,37-38,607-608,667-668,961-962,3069-3070,4869-4870 \
	    INPUTS="$$($(PY) ../tools/play_inputs.py k3 600 5200)" $(RUN) 1945kiii $(ORACLE) >$(OUT)/mid_k3_play.log 2>&1 ) & \
	DUMP_DIR=$(OUT)/mid_slspirit_attract DUMP_FRAMES=14-15,29-30,866-867,2944-2945,5022-5023,7100-7101 \
	  $(RUN) slspirit $(ORACLE) >$(OUT)/mid_slspirit.log 2>&1 & \
	DUMP_DIR=$(OUT)/mid_clone_1945kiiin DUMP_FRAMES=14-15,37-38,868-869,2939-2940,4960-4961,7084-7085 \
	  $(RUN) 1945kiiin $(ORACLE) >$(OUT)/mid_kiiin.log 2>&1 & \
	DUMP_DIR=$(OUT)/mid_clone_1945kiiio DUMP_FRAMES=14-15,37-38,868-869,2940-2941,4961-4962,7040-7041 \
	  $(RUN) 1945kiiio $(ORACLE) >$(OUT)/mid_kiiio.log 2>&1 & \
	DUMP_DIR=$(OUT)/mid_clone_1945kiiipt DUMP_FRAMES=14-15,37-38,874-875,2952-2953,5030-5031,7108-7109 \
	  $(RUN) 1945kiiipt $(ORACLE) >$(OUT)/mid_kiiipt.log 2>&1 & \
	wait
	$(PY) m1/midscan.py $(M1RUNS) --csv build/m1/midscan.csv
	$(PY) m1/midscan_replay.py $(addprefix $(OUT)/,$(MIDRUNS)) --csv build/m1/midscan_replay.csv

m1-capacity: $(M1BIN)
	$(PY) m1/capacity.py build/m1/probe
	-$(PY) m1/replay.py $(wildcard build/m1/probe/*)

m1: m1-build m1-verify m1-synth m1-midscan

# ---------------------------------------------------------------- M2
# Full system (k3_sys: fx68k, work RAM, memory map, control, jt6295 x2,
# k3_video) at the hardware clock: 96 MHz, pixel enable 9/128 (6.75 MHz),
# 68000 phases every 3 clocks (16 MHz), OKI 1 MHz. Program ROM model: ok 9
# clocks after the request (the M4 SDRAM controller's worst case), garbage
# on the bus before; graphics ROM model as M1 (one read per 8 clocks,
# latency 9). M2PARAMS adds Verilator -G overrides (diagnostics only, e.g.
# -GVID_DELAY=N, m2_findings 5).
FX68K := ../rtl/vendor/fx68k
M2RTL := $(wildcard ../rtl/vendor/jt6295/hdl/*.v) $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv \
  $(M1RTL) ../rtl/k3_sys.sv
M2DIR ?= build/m2/obj_dir
M2BIN := $(M2DIR)/Vk3_sys
M2OUT := build/m2/gate
M2CLK ?= -GCLK_HZ=96000000 -GPIX_NUM=9 -GPIX_DEN=128

$(M2BIN): $(M2RTL) m2/tb_sys.cpp
	mkdir -p $(M2DIR)
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial fast \
	  --top-module k3_sys --Mdir $(M2DIR) -j 0 \
	  $(M2CLK) $(M2PARAMS) \
	  -CFLAGS -O2 $(M2RTL) m2/tb_sys.cpp
	cp -f $(FX68K)/microrom.mem $(FX68K)/nanorom.mem .   # fx68k $$readmemb, relative to the run directory

m2-build: $(M2BIN)

# m2-int: the MiSTer clock (m4_findings 10): 94.5 MHz, pixel enable 1/14
# (exactly 14 clocks a pixel for direct video), 68000 and OKI enables
# fractional. Same boot runs and comparison as m2-boot.
M2ICLK := -GCLK_HZ=94500000 -GPIX_NUM=1 -GPIX_DEN=14
m2-int:
	$(MAKE) m2-boot M2DIR=build/m2_int/obj_dir M2OUT=build/m2_int/gate M2CLK="$(M2ICLK)"

# MAME runs with work RAM dumps (k3_oracle.lua MAINRAM=1), same frames and
# inputs as the M0 captures, no snapshots: deterministic from power-on, so
# they show the RAM state of the same frames.
m2-oracle:
	DUMP_DIR=$(OUT)/m2ram_k3_attract DUMP_FRAMES=$(K3_ATTRACT) MAINRAM=1 NO_SNAP=1 $(RUN) 1945kiii $(ORACLE) >$(OUT)/m2ram_k3_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/m2ram_k3_play DUMP_FRAMES=$(K3_PLAY) MAINRAM=1 NO_SNAP=1 INPUTS="$$($(PY) ../tools/play_inputs.py k3 600 5200)" \
	  $(RUN) 1945kiii $(ORACLE) >$(OUT)/m2ram_k3_play.log 2>&1 & \
	DUMP_DIR=$(OUT)/m2ram_slspirit_attract DUMP_FRAMES=$(SL_ATTRACT) MAINRAM=1 NO_SNAP=1 $(RUN) slspirit $(ORACLE) >$(OUT)/m2ram_slspirit_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/m2ram_flagrall_attract DUMP_FRAMES=$(FR_ATTRACT) MAINRAM=1 NO_SNAP=1 $(RUN) flagrall $(ORACLE) >$(OUT)/m2ram_flagrall_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/m2ram_flagrall_play DUMP_FRAMES=$(FR_PLAY) MAINRAM=1 NO_SNAP=1 INPUTS="$$($(PY) ../tools/play_inputs.py flagrall 600 4800)" \
	  $(RUN) flagrall $(ORACLE) >$(OUT)/m2ram_flagrall_play.log 2>&1 & \
	for s in $(CLONES); do \
	  DUMP_DIR=$(OUT)/m2ram_clone_$$s DUMP_FRAMES=$(CLONE_FRAMES) MAINRAM=1 NO_SNAP=1 $(RUN) $$s $(ORACLE) >$(OUT)/m2ram_clone_$$s.log 2>&1 & \
	done; wait

# Boot runs from power-on through each M0 capture (images, RAM, I/O stream).
# <run>:<set>:<flagrall>:<frames>:<dsw>; DSW = MAME's power-on default (m0 7)
M2RUNS := k3_attract:1945kiii:0:12001:FEEF k3_play:1945kiii:0:5201:FEEF \
  slspirit_attract:slspirit:0:9001:FFEF flagrall_attract:flagrall:1:9001:FFEF \
  flagrall_play:flagrall:1:4801:FFEF clone_1945kiiin:1945kiiin:0:9001:FEEF \
  clone_1945kiiio:1945kiiio:0:9001:FFEF clone_1945kiiipt:1945kiiipt:0:9001:FFEF

m2-boot: $(M2BIN)
	@for r in $(M2RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); fl=$$(echo $$r | cut -d: -f3); \
	  nf=$$(echo $$r | cut -d: -f4); dsw=$$(echo $$r | cut -d: -f5); o=$(M2OUT)/$$run; \
	  rm -rf $$o && mkdir -p $$o; \
	  ls $(OUT)/$$run/frames | sed 's/^0*//' | awk '{print $$1; print $$1-1}' | sort -n | uniq | awk '$$1>0' > $$o/cap.txt; \
	  inp=""; [ -f $(OUT)/$$run/inputs.csv ] && [ $$(wc -l < $(OUT)/$$run/inputs.csv) -gt 1 ] && inp="+inputs=$(OUT)/$$run/inputs.csv"; \
	  $(M2BIN) +sdram=build/regions/$$set/sdram.bin +flagrall=$$fl +dsw=$$dsw +frames=$$nf $$inp \
	    +cap=$$o/cap.txt +out=$$o +io=$$o/io.txt > $$o/run.log 2>&1 & \
	done; wait
	$(MAKE) m2-compare

m2-compare:
	@rc=0; for r in $(M2RUNS); do run=$$(echo $$r | cut -d: -f1); \
	  echo "== $$run"; tail -n 1 $(M2OUT)/$$run/run.log; \
	  $(PY) m2/compare.py $(M2OUT)/$$run $(OUT)/$$run --ram $(OUT)/m2ram_$$run --quiet --diff $(M2OUT)/diff_$$run || rc=1; \
	done; exit $$rc

m2-soak: $(M2BIN)
	mkdir -p $(M2OUT)/soak && : > $(M2OUT)/soak/cap.txt
	$(M2BIN) +sdram=build/regions/1945kiii/sdram.bin +flagrall=0 +dsw=FEEF +frames=20000 \
	  +cap=$(M2OUT)/soak/cap.txt +out=$(M2OUT)/soak > $(M2OUT)/soak/run.log 2>&1; tail -n 1 $(M2OUT)/soak/run.log

# jt6295 phrase length against the nominal 2 x (stop - start + 1) samples
# (m2_findings 5.3): Flag Rally bank 1, phrases 1, 5, 9, 12, 25 on channel 1
m2-okitest:
	cd m2/okitest && $(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module jt6295 \
	  --Mdir obj -j 0 ../../../rtl/vendor/jt6295/hdl/*.v tb_oki.cpp > build.log 2>&1
	@for p in 1 5 9 12 25; do m2/okitest/obj/Vjt6295 build/regions/flagrall/oki1.bin 1 $$p 1; done
