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

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out m1 m1-build m1-verify m1-synth m1-midscan m1-capacity

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
