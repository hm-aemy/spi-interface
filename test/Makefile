VERILATOR ?= verilator

TOP := tb_spi
BIN := $(TOP)_sim
FST := $(TOP).fst

VERILATOR_ARGS := --binary --sv --timing -Wall -Wno-fatal
VERILATOR_ARGS += --trace-fst --trace-structs

SV_SRCS := \
	../src/spi_pkg.sv \
	../src/spi.sv \
	tb_spi.sv

.PHONY: all run clean

all: run

obj_dir/$(BIN): $(SV_SRCS)
	$(VERILATOR) $(VERILATOR_ARGS) --top-module $(TOP) -o $(BIN) $(SV_SRCS)

run: obj_dir/$(BIN)
	./obj_dir/$(BIN)

clean:
	rm -rf obj_dir $(FST)