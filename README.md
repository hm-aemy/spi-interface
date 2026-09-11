# QSPI-Interface

[![ci](https://github.com/hm-aemy/spi-interface/actions/workflows/ci.yml/badge.svg)](https://github.com/hm-aemy/spi-interface/actions/workflows/ci.yml)
[![docs](https://github.com/hm-aemy/spi-interface/actions/workflows/docs.yml/badge.svg)](https://github.com/hm-aemy/spi-interface/actions/workflows/docs.yml)

**Quad-SPI controller with OBI attachment** — maps external serial memories
into the address space as execution and data memory (XIP) and offers a
register-driven indirect mode for arbitrary chip commands. Developed for the
*hatch* SoC (RISC-V) at Hochschule München; reusable as a standalone IP with
two OBI subordinate ports.

**Status: Beta** — simulation-verified (6 self-checking testbenches + SoC
system simulation, CI) and FPGA-validated (Arty A7-100T, open-source flow,
incl. a two-board run inside the complete hatch SoC). Not silicon-proven.

## Features

- Memory-mapped mode (XIP) with stream prefetch through a 32-byte FIFO:
  sequential accesses without SPI latency, writes with a separate write
  frame format (WCCR), bus error on range/mode violations
- Indirect mode: programmable opcode + frame format
  (instruction/address/alternate/dummy/data, each phase 1/2/4 lanes or skip)
- Register-driven CSR model (CR/DCR/SR/FCR/DLR/CCR/AR/ABR/DR/WCCR) with
  documented trigger rules and abort flow
- Chip profiles by register setup: Microchip **23LC1024** (SRAM, R/W, SQI)
  and Winbond **W25Q128JV** (flash, read: 0x03/0x0B/0x6B/0xEB, QE bit)
- Behavioural models of both chips (`model/`) as verification reference,
  plus a synthesis-friendly SRAM slave for FPGA test setups (`fpga/arty/`)
- Register map generated from one source (`docs/regs.yaml`): documentation
  tables **and** the C header `sw/include/qspi_regs.h` (CI-checked)

## Quick start

```bash
cd test && make test-all          # Verilator >= 5.020; all 6 TBs -> PASSED
make TOP=tb_qspi_top              # single TB, waveform: tb_qspi_top.fst
```

FPGA smoke test on an Arty A7 (result arrives as `PASS` over the USB-UART):
`cd fpga/arty && make loopback.bit prog-loopback`

## Documentation

Full documentation (architecture, interface spec with timing diagrams,
generated register map, programmer's guide, design rationale, verification
plan, FPGA test setups, known issues): **`docs/`** (Sphinx/MyST), built by
CI and published as GitHub Pages:
<https://aemy.cs.hm.edu/spi-interface/> (on a GitLab hosting: as GitLab
Pages of the project).

Build locally:

```bash
pip install -r docs/requirements.txt
sphinx-build -b html docs public
```

SoC-level documentation (simulation, software/SDK, FPGA flow of the whole
chip) lives in the hatch repository under `docs/`.

## Repository layout

```
src/    controller RTL (qspi_*.sv) + legacy controller (spi.sv)
model/  behavioural models 23LC1024 / W25Q128JV
sw/     generated C register header (qspi_regs.h)
test/   self-checking testbenches + Makefile (make test-all / test-core)
fpga/   Arty A7 test setups (wrappers, XDC, open-source-flow Makefile)
docs/   Sphinx documentation (published as GitHub Pages)
```

## License

Copyright 2026 Hochschule München (University of Applied Sciences Munich),
Christopher Hinz.

Licensed under the Solderpad Hardware License v 2.1 (the "License"); you
may not use this work except in compliance with the License, or, at your
option, the Apache License version 2.0. You may obtain a copy of the
License at <https://solderpad.org/licenses/SHL-2.1/>; the full text is in
[`LICENSE`](LICENSE).

`SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1`
