SPI_TOP=$(PWD)/..

# Fail the target when the simulator fails, even though output runs through tee.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

VERILATOR ?= verilator

# Which testbench to build/run. Override on the command line, e.g.
#   make TOP=tb_spi
TOP ?= tb_s23lc1024
BIN := $(TOP)_sim
FST := $(TOP).fst

VERILATOR_ARGS := --binary --sv --timing -Wall -Wno-fatal
VERILATOR_ARGS += --trace-fst --trace-structs
VERILATOR_ARGS += +define+VERILATOR

# Source set per testbench.
ifeq ($(TOP),tb_spi)
SV_SRCS := \
	../src/spi_pkg.sv \
	../src/spi.sv \
	tb_spi.sv
else ifeq ($(TOP),tb_w25q128jv)
SV_SRCS := \
	../model/w25q128jv.sv \
	tb_w25q128jv.sv
else
SV_SRCS := \
	../model/s23lc1024.sv \
	tb_s23lc1024.sv
endif

.PHONY: all build run clean test-core test-all

all: build run

# Core set (models + controller): the CI gate that runs on every MR.
CORE_TOPS := tb_s23lc1024 tb_w25q128jv
TEST_TOPS := $(CORE_TOPS)

define run-tops
	@for top in $(1); do \
		rm -rf obj_dir; \
		$(MAKE) TOP=$$top || exit 1; \
		grep -q "TB PASSED" sim.log || { echo "$$top: no PASS marker"; exit 1; }; \
		echo "$$top: OK"; \
	done
endef

test-core:
	$(call run-tops,$(CORE_TOPS))

test-all:
	$(call run-tops,$(TEST_TOPS))

build:
	SPI_TOP=$(SPI_TOP) $(VERILATOR) $(VERILATOR_ARGS) -O3 --top $(TOP) -o $(BIN) $(SV_SRCS) 2>&1 | tee build.log

run: obj_dir/$(BIN)
	./obj_dir/$(BIN) 2>&1 | tee sim.log

clean:
	rm -rf obj_dir $(FST) sim.log build.log
