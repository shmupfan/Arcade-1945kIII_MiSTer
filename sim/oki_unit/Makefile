# jt6295 unit tests for patch 3 (rtl/vendor/jt6295/PROVENANCE.md): BUSY
# timing against the MSM6295 datasheet (rise 15 x n clocks after a start,
# fall at the next sample after a stop), BUSY length against the nominal
# phrase length, and Ganbare Ginkun's stop + start + repeated start.
# Needs ../build/regions/flagrall/oki1.bin (make regions in sim/).
HDL := ../../rtl/vendor/jt6295/hdl
ROM := ../build/regions/flagrall/oki1.bin
TESTS := busytiming length restart
all: $(TESTS:%=obj_%/Vjt6295)
	@for t in $(TESTS); do echo "== $$t"; obj_$$t/Vjt6295 $(ROM); done
obj_%/Vjt6295: tb_%.cpp $(wildcard $(HDL)/*.v)
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module jt6295 \
	  -I$(HDL) $(HDL)/*.v $< -Mdir obj_$*
clean:
	rm -rf obj_*
.PHONY: all clean
