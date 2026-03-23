SPI_TOP=$(PWD)/..

VERILATOR ?= verilator

TOP := tb_spi
BIN := $(TOP)_sim
FST := $(TOP).fst
VLT := $(SPI_TOP)/test/spi.vlt

VERILATOR_ARGS := --binary --sv --timing -Wall -Wno-fatal
VERILATOR_ARGS += --trace-fst --trace-structs

SV_SRCS := \
	../src/spi_pkg.sv \
	../src/spi.sv \
	tb_spi.sv

.PHONY: all build run clean

all: build run

build:
	SPI_TOP=$(SPI_TOP) verilator $(VERILATOR_ARGS) -O3 --top $(TOP) -o $(BIN) -f $(VLT) $(SV_SRCS) 2>&1 | tee build.log

run: obj_dir/$(BIN)
	./obj_dir/$(BIN) 2>&1 | tee sim.log

clean:
	rm -rf obj_dir $(FST) sim.log build.log