# Copyright 2026 University of Applied Sciences Munich
# Christopher Hinz <christopher.hinz@hm.edu>
#
# Open-source FPGA flow for the Phase-3 Arty-A7 bring-up:
#   yosys (synthesis) -> nextpnr-xilinx (place & route, FASM) ->
#   prjxray fasm2frames + xc7frames2bit (bitstream) -> openFPGALoader (flash)
#
# See docs/fpga_flow.md for the full step-by-step guide
# (toolchain install, board wiring, running the test, troubleshooting).
#
# -----------------------------------------------------------------------
# STATUS: loopback flow TESTED END-TO-END on an Arty A7-100T (2026-07-07):
# yosys(slang) -> nextpnr-xilinx -> fasm2frames -> xc7frames2bit ->
# openFPGALoader, verified via the UART "PASS" report. model/master targets
# share the same commands but have not been run on two boards yet.
# See docs/fpga_flow.md §e for every pitfall found on the way.
# -----------------------------------------------------------------------
# The environment this was written in has Verilator but NEITHER yosys NOR
# nextpnr-xilinx NOR openFPGALoader installed, so none of the targets below
# (model.bit, master.bit, prog-model, prog-master) could actually be run.
# Everything up to and including the Verilator/tb_arty_pair.sv simulation
# (test/Makefile) IS verified -- that is what proves spi_test_master.sv is
# protocol-correct BEFORE it ever touches this flow. What follows is written
# carefully against the documented 2025/2026 CLI surface of yosys,
# nextpnr-xilinx and prjxray-tools, but treat every command below as a
# starting point to debug from, not a guarantee. The most likely failure
# points (and what to try) are listed in
# docs/fpga_flow.md §e (Troubleshooting):
#   - yosys's `read_verilog -sv` SystemVerilog subset may not accept every
#     construct used here (typedef enum, `automatic` locals inside
#     always_ff, unpacked-array localparams, generate-for tri-state loops).
#   - nextpnr-xilinx's exact `--chipdb`/`--xdc`/`--fasm` flag spelling has
#     changed across versions/forks.
#   - fasm2frames / xc7frames2bit CLI flag names (`--part_file` vs
#     `--part-file` etc.) vary between prjxray releases.
# -----------------------------------------------------------------------

# Machine-local tool paths/board (created during bring-up, see docs/14 §a).
-include local.mk

# BOARD selects the Arty variant: arty_a7_35t (default) or arty_a7_100t.
BOARD ?= arty_a7_35t

YOSYS          ?= yosys
NEXTPNR_XILINX ?= nextpnr-xilinx
OPENFPGALOADER ?= openFPGALoader
FASM2FRAMES    ?= fasm2frames
XC7FRAMES2BIT  ?= xc7frames2bit

# Directory containing the nextpnr-xilinx chip databases (xc7a35t.bin /
# xc7a100t.bin). Produced once during toolchain setup -- see
# docs/fpga_flow.md §a. openXC7 sets this up for you; if you
# built nextpnr-xilinx manually, point this at wherever you ran bbaexport.
CHIPDB ?=

# Root of the prjxray database checkout (contains database/artix7/<part>/
# part.yaml etc.), needed by fasm2frames/xc7frames2bit. openXC7 also sets
# this up for you.
XRAY_DIR ?=

ifeq ($(BOARD),arty_a7_100t)
XRAY_PART   := xc7a100tcsg324-1
CHIPDB_FILE := $(CHIPDB)/xc7a100t.bin
else ifeq ($(BOARD),arty_a7_35t)
XRAY_PART   := xc7a35tcsg324-1
CHIPDB_FILE := $(CHIPDB)/xc7a35t.bin
else
$(error Unknown BOARD '$(BOARD)' -- use arty_a7_35t or arty_a7_100t)
endif

XRAY_DATABASE_DIR := $(XRAY_DIR)/database/artix7
XRAY_PART_FILE     = $(XRAY_DATABASE_DIR)/$(XRAY_PART)/part.yaml

XDC := arty_a7.xdc

MODEL_SRCS    := fpga_sram_slave.sv top_model.sv
LOOPBACK_SRCS := ../../model/s23lc1024.sv spi_test_master.sv uart_tx.sv top_loopback.sv
MASTER_SRCS := spi_test_master.sv top_master.sv

.PHONY: all model master loopback prog-model prog-master prog-loopback clean check-env

all: model.bit master.bit

# -----------------------------------------------------------------------
# Fail fast (with a useful message) instead of yosys/nextpnr erroring deep
# into the flow if CHIPDB/XRAY_DIR were never set.
# -----------------------------------------------------------------------
check-env:
	@if [ -z "$(CHIPDB)" ]; then \
		echo "ERROR: CHIPDB is not set."; \
		echo "  Point it at the directory holding the nextpnr-xilinx chip"; \
		echo "  database for $(XRAY_PART) (e.g. CHIPDB=/opt/openxc7/xc7chipdb)."; \
		echo "  See docs/fpga_flow.md, step a."; \
		exit 1; \
	fi
	@if [ ! -f "$(CHIPDB_FILE)" ]; then \
		echo "ERROR: chip database not found: $(CHIPDB_FILE)"; \
		exit 1; \
	fi
	@if [ -z "$(XRAY_DIR)" ]; then \
		echo "ERROR: XRAY_DIR is not set."; \
		echo "  Point it at your prjxray database checkout root."; \
		echo "  See docs/fpga_flow.md, step a."; \
		exit 1; \
	fi
	@if [ ! -f "$(XRAY_PART_FILE)" ]; then \
		echo "ERROR: prjxray part file not found: $(XRAY_PART_FILE)"; \
		exit 1; \
	fi

# -----------------------------------------------------------------------
# model.bit -- Board A (the memory)
# -----------------------------------------------------------------------
model.json: $(MODEL_SRCS)
	$(YOSYS) -m slang -p "read_slang $(MODEL_SRCS) --top top_model; synth_xilinx -flatten -abc9 -arch xc7 -nolutram -top top_model; write_json model.json"

model_routed.json model.fasm: model.json $(XDC) | check-env
	$(NEXTPNR_XILINX) --chipdb $(CHIPDB_FILE) --xdc $(XDC) \
		--json model.json --write model_routed.json --fasm model.fasm

model.frames: model.fasm | check-env
	$(FASM2FRAMES) --db-root $(XRAY_DATABASE_DIR) --part $(XRAY_PART) \
		model.fasm model.frames

model.bit: model.frames | check-env
	$(XC7FRAMES2BIT) --part_file $(XRAY_PART_FILE) --part_name $(XRAY_PART) \
		--frm_file model.frames --output_file model.bit

# -----------------------------------------------------------------------
# master.bit -- Board B (the tester)
# -----------------------------------------------------------------------
master.json: $(MASTER_SRCS)
	$(YOSYS) -m slang -p "read_slang $(MASTER_SRCS) --top top_master; synth_xilinx -flatten -abc9 -arch xc7 -nolutram -top top_master; write_json master.json"

master_routed.json master.fasm: master.json $(XDC) | check-env
	$(NEXTPNR_XILINX) --chipdb $(CHIPDB_FILE) --xdc $(XDC) \
		--json master.json --write master_routed.json --fasm master.fasm

master.frames: master.fasm | check-env
	$(FASM2FRAMES) --db-root $(XRAY_DATABASE_DIR) --part $(XRAY_PART) \
		master.fasm master.frames

master.bit: master.frames | check-env
	$(XC7FRAMES2BIT) --part_file $(XRAY_PART_FILE) --part_name $(XRAY_PART) \
		--frm_file master.frames --output_file master.bit

# -----------------------------------------------------------------------
# loopback.bit -- single-board smoke test: master + model + UART reporter
# on ONE Arty (no Pmod cable). Verified in sim by test/tb_loopback.sv.
# -----------------------------------------------------------------------
loopback.json: $(LOOPBACK_SRCS)
	$(YOSYS) -m slang -p "read_slang $(LOOPBACK_SRCS) --top top_loopback; synth_xilinx -abc9 -arch xc7 -nolutram -top top_loopback; write_json loopback.json"

loopback_routed.json loopback.fasm: loopback.json $(XDC) | check-env
	$(NEXTPNR_XILINX) --chipdb $(CHIPDB_FILE) --xdc $(XDC) \
		--json loopback.json --write loopback_routed.json --fasm loopback.fasm

loopback.frames: loopback.fasm | check-env
	$(FASM2FRAMES) --db-root $(XRAY_DATABASE_DIR) --part $(XRAY_PART) \
		loopback.fasm loopback.frames

loopback.bit: loopback.frames | check-env
	$(XC7FRAMES2BIT) --part_file $(XRAY_PART_FILE) --part_name $(XRAY_PART) \
		--frm_file loopback.frames --output_file loopback.bit

prog-loopback: loopback.bit
	$(OPENFPGALOADER) -b arty loopback.bit

model: model.bit
master: master.bit

# -----------------------------------------------------------------------
# Flashing. If both boards are plugged in at once, openFPGALoader needs to
# be told WHICH one to target -- see docs/fpga_flow.md §c
# for how to find each board's FTDI serial (`openFPGALoader --scan-usb` /
# `lsusb`). Override e.g.:
#   make prog-model FTDI_SERIAL_MODEL=<serial-of-board-A>
# -----------------------------------------------------------------------
FTDI_SERIAL_MODEL  ?=
FTDI_SERIAL_MASTER ?=

prog-model: model.bit
	$(OPENFPGALOADER) -b arty $(if $(FTDI_SERIAL_MODEL),--ftdi-serial $(FTDI_SERIAL_MODEL)) model.bit

prog-master: master.bit
	$(OPENFPGALOADER) -b arty $(if $(FTDI_SERIAL_MASTER),--ftdi-serial $(FTDI_SERIAL_MASTER)) master.bit

clean:
	rm -f model.json model_routed.json model.fasm model.frames model.bit
	rm -f master.json master_routed.json master.fasm master.frames master.bit
	rm -f loopback.json loopback_routed.json loopback.fasm loopback.frames loopback.bit
