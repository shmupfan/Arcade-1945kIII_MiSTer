# M3 targets (sound). Included by sim/Makefile, or run on its own from sim/:
#   make -f m3.mk <target>
#
#   make m3-build       sound harness m3/tb_snd.cpp (k3_sys, hardware OKI rate)
#   make m3-build-mame  the same with OKI_HZ=999900: MAME 0.288's effective
#                       M6295 rate (diagnostic only, m2_findings 5.3)
#   make m3-wav         MAME WAVs at -samplerate 7575 (MAME's M6295 stream
#                       rate, so the WAV holds the raw stream: 16 x the sum
#                       of both chips in 12-bit units, clipped) for every run
#   make m3-run         every run on the MAME-rate build (sample comparison),
#                       the M3HW runs also on the hardware-rate build
#   make m3-compare     m3/compare_oki.py on every run
#   make m3             all of the above
#
# Runs mirror the M2 ones (same frames, DIP switches and inputs).

PY        ?= python3
VERILATOR ?= verilator
OUT       := mame/out
RUN       := mame/run_mame.sh
ORACLE    := mame/k3_oracle.lua
FX68K     := ../rtl/vendor/fx68k
M3RTL     := $(wildcard ../rtl/vendor/jt6295/hdl/*.v) $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv \
             ../rtl/k3_dpram.sv ../rtl/k3_fifo.sv ../rtl/k3_video.sv ../rtl/k3_sys.sv
M3DIR     := build/m3
M3BIN     := $(M3DIR)/hw/Vk3_sys
M3BINM    := $(M3DIR)/mame/Vk3_sys
M3OUT     := $(M3DIR)/runs

# <run>:<set>:<flagrall>:<frames>:<dsw>:<inputs game or ->
M3RUNS := k3_attract:1945kiii:0:6001:FEEF:- k3_play:1945kiii:0:5201:FEEF:k3 \
  slspirit_attract:slspirit:0:4001:FFEF:- flagrall_attract:flagrall:1:4001:FFEF:- \
  flagrall_play:flagrall:1:4801:FFEF:flagrall

# runs repeated on the hardware-rate build (level and envelope; the sample
# comparison needs MAME's rate)
M3HW := k3_play flagrall_play

.PHONY: m3 m3-build m3-build-mame m3-wav m3-run m3-compare

define VBUILD
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial fast \
	  --top-module k3_sys --Mdir $(1) -j 6 -GCLK_HZ=96000000 -GPIX_NUM=9 -GPIX_DEN=128 $(2) \
	  -CFLAGS -O2 $(M3RTL) m3/tb_snd.cpp
endef

$(M3BIN): $(M3RTL) m3/tb_snd.cpp
	$(call VBUILD,$(M3DIR)/hw,)
$(M3BINM): $(M3RTL) m3/tb_snd.cpp
	$(call VBUILD,$(M3DIR)/mame,-GOKI_HZ=999900)

# Diagnostic: the MAME-rate build with jt6295 patched to ignore a start
# command for a channel that is still playing (m3_findings 3). JT6295FIX is a
# patched copy of rtl/vendor/jt6295/hdl made by m3/jt6295_busy_patch.py.
JT6295FIX := $(M3DIR)/jt6295_fix
M3RTLF    := $(filter-out ../rtl/vendor/jt6295/hdl/%,$(M3RTL)) $(patsubst ../rtl/vendor/jt6295/hdl/%,$(JT6295FIX)/%,$(filter ../rtl/vendor/jt6295/hdl/%,$(M3RTL)))
M3BINF    := $(M3DIR)/mamefix/Vk3_sys
$(JT6295FIX)/jt6295_serial.v: ../rtl/vendor/jt6295/hdl/jt6295_serial.v m3/jt6295_busy_patch.py
	rm -rf $(JT6295FIX) && mkdir -p $(JT6295FIX) && cp ../rtl/vendor/jt6295/hdl/*.v $(JT6295FIX)/
	$(PY) m3/jt6295_busy_patch.py $(JT6295FIX)/jt6295_serial.v
$(M3BINF): $(JT6295FIX)/jt6295_serial.v $(M3RTL) m3/tb_snd.cpp
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial fast \
	  --top-module k3_sys --Mdir $(M3DIR)/mamefix -j 6 -GCLK_HZ=96000000 -GPIX_NUM=9 -GPIX_DEN=128 -GOKI_HZ=999900 \
	  -CFLAGS -O2 $(M3RTLF) m3/tb_snd.cpp
m3-build-fix: $(M3BINF)

m3-build: $(M3BIN)
m3-build-mame: $(M3BINM)

m3-wav:
	@for r in $(M3RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); nf=$$(echo $$r | cut -d: -f4); g=$$(echo $$r | cut -d: -f6); \
	  inp=""; [ "$$g" != "-" ] && inp="$$($(PY) ../tools/play_inputs.py $$g 600 $$nf)"; \
	  DUMP_DIR=$(OUT)/m3wav_$$run TOTAL=$$nf NO_SNAP=1 DUMP_FRAMES=$$nf INPUTS="$$inp" RT_TAG=m3_$$run \
	    $(RUN) $$set $(ORACLE) -wavwrite $(CURDIR)/$(OUT)/m3wav_$$run.wav -samplerate 7575 > $(OUT)/m3wav_$$run.log 2>&1 & \
	done; wait

m3-run: $(M3BIN) $(M3BINM)
	cp -f $(FX68K)/microrom.mem $(FX68K)/nanorom.mem .
	@for r in $(M3RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); fl=$$(echo $$r | cut -d: -f3); \
	  nf=$$(echo $$r | cut -d: -f4); dsw=$$(echo $$r | cut -d: -f5); g=$$(echo $$r | cut -d: -f6); \
	  inp=""; [ "$$g" != "-" ] && inp="+inputs=$(OUT)/m3wav_$$run/inputs.csv"; \
	  for b in mame $$(echo " $(M3HW) " | grep -q " $$run " && echo hw); do o=$(M3OUT)/$$b/$$run; mkdir -p $$o; bin=$(M3DIR)/$$b/Vk3_sys; \
	    $$bin +sdram=build/regions/$$set/sdram.bin +flagrall=$$fl +dsw=$$dsw +frames=$$nf $$inp \
	      +oki=$$o/oki.raw $$([ $$b = mame ] && echo +okich=$$o/okich.raw) +io=$$o/io.txt > $$o/run.log 2>&1 & \
	  done; \
	done; wait

m3-compare:
	@for r in $(M3RUNS); do run=$$(echo $$r | cut -d: -f1); fl=$$(echo $$r | cut -d: -f3); \
	  echo "== $$run"; \
	  $(PY) m3/compare_oki.py $(M3OUT)/mame/$$run/oki.raw $(OUT)/m3wav_$$run.wav --ch $(M3OUT)/mame/$$run/okich.raw --io $(M3OUT)/mame/$$run/io.txt --mame-io $(OUT)/m3wav_$$run/writes.csv $$([ -f $(M3OUT)/hw/$$run/oki.raw ] && echo --hw $(M3OUT)/hw/$$run/oki.raw); \
	done

m3: m3-wav m3-run m3-compare
