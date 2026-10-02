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

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out

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
