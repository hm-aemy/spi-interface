# Copyright 2026 University of Applied Sciences Munich
# Christopher Hinz <christopher.hinz@hm.edu>
#
# Board-B ("the memory") for the two-board bring-up, Vivado flow: same
# fpga_sram_slave.sv as fpga/arty/, but top_model's SIO0..3 are one real
# bidirectional Pmod bus instead of split pin_a2b/pin_b2a groups -- the
# mirror image of the hatch repo's fpga/vivado/, built for the same reason
# (real tri-state, fewer wires between the boards). See ../../docs/known_issues.md
# and the hatch repo's docs/fpga_vivado_flow.md for the rationale.
#
# Important targets:
#   make model.bit         bitstream (synth+impl via Vivado, batch mode)
#   make prog-model        program the board (FTDI_SERIAL selects it)
#   make check-fmax        print the post-route timing summary

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Machine-local toolchain path (same scheme as fpga/arty/local.mk)
-include local.mk

BOARD ?= arty_a7_100t

VIVADO      ?= vivado
FTDI_SERIAL ?=

ifeq ($(BOARD),arty_a7_100t)
PART := xc7a100tcsg324-1
else
PART := xc7a35tcsg324-1
endif

XDC  := arty_a7.xdc
# fpga_sram_slave.sv is reused directly from fpga/arty/ (single source of
# truth; no yosys/nextpnr-specific constructs in it, nothing Vivado-specific
# to adapt) -- no copy or symlink, just reference its real path.
SRCS := $(abspath $(CURDIR)/../arty/fpga_sram_slave.sv) $(CURDIR)/top_model.sv

.PHONY: all prog-model check-fmax clean

all: model.bit

model_files.tcl: Makefile
	@{ \
	echo 'set MODEL_TOP_MODULE top_model' ; \
	echo 'set MODEL_PART      $(PART)' ; \
	echo 'set MODEL_XDC       $(CURDIR)/$(XDC)' ; \
	echo 'set MODEL_SRCS [list \'; \
	for f in $(SRCS); do echo "  $$f \\"; done; \
	echo ']' ; \
	} > $@

model.bit: model_files.tcl build.tcl $(XDC) $(SRCS)
	$(VIVADO) -mode batch -source build.tcl -journal vivado.jou -log vivado.log

prog-model: model.bit
	openFPGALoader -b arty $(if $(FTDI_SERIAL),--ftdi-serial $(FTDI_SERIAL)) model.bit

check-fmax: model.bit
	@grep -A 10 "^| Design Timing Summary" timing_summary.rpt
	@grep -A 6  "^| Clock Summary"          timing_summary.rpt

clean:
	rm -f model_files.tcl model.bit
	rm -f *.dcp *.rpt *.jou *.log clockInfo.txt
	rm -rf .Xil
