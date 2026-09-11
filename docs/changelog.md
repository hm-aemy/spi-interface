# Changelog & Versioning

Versioning scheme: [SemVer](https://semver.org/) with a status suffix
(`-beta.N`); "stable" requires the open items from {doc}`verification`
(coverage, real-chip tests), "silicon-proven" a tapeout.

## Unreleased

- License: Solderpad Hardware License v2.1 (`LICENSE`; SPDX
  `Apache-2.0 WITH SHL-2.1`) replaces the "not yet finalised" notice.
- `SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1` in every file header;
  the generated `sw/include/qspi_regs.h` now carries the copyright and
  license lines too (emitted by `gen_regmap.py`).
- CI: GitHub Actions workflows (`.github/workflows/`) mirroring the GitLab
  pipeline — core testbenches and the generated-header check on every push
  (`ci.yml`), all six testbenches on `main`, on FPGA/model changes or
  manually (`fpga-tests.yml`), strict Sphinx build on every push and
  publication as GitHub Pages from `main` (`docs.yml`).

## 1.0.0-beta.3 — 2026-07-08

**Two-board FPGA validation inside the full SoC.**

- Complete hatch SoC (Board A) ↔ SRAM slave (Board B) on two Arty A7-100T:
  `software/fpgatest` reports `QSPI FPGA TEST PASSED (D checks)` over UART —
  the QSPI controller proven in the real SoC over a physical SPI link
  ({doc}`verification`; setup in the hatch docs).
- New: `software/fpgatest` in hatch (13 checks: instruction-only,
  RDMR/WRMR, mmap single/quad, sub-word, endianness, prefetch, TEF); hatch
  FPGA top (`<hatch>/fpga/arty/`); fully synchronous `fpga_sram_slave.sv`
  for Board B; functional two-board RTL sim `tb_twoboard.sv` (hatch).
- Fixes: `qspi_fifo` NBA array loop manually unrolled (Verilator
  BLKLOOPINIT with `--unroll-count 1`); several SoC-side fixes in hatch
  (linker script SRAM size, simulator pipefail — see the hatch changelog).
- Findings folded into {doc}`known_issues`: tri-state `IOBUF`
  non-functional in the nextpnr flow → unidirectional wiring; async-CS
  behavioural model does not map → synchronous slave.

## 1.0.0-beta.2 — 2026-07-07

**FPGA validation + hardening.**

- Single-board loopback (`fpga/arty/top_loopback.sv` + `uart_tx.sv`) built,
  programmed and UART-verified on an Arty A7-100T (`PASS`).
- Open-source flow productive: yosys **slang** frontend, nextpnr-xilinx,
  prjxray, openFPGALoader; machine-local paths via `fpga/arty/local.mk`.
- Fixes from the bring-up:
  - `spi_test_master`: `done_o`/`pass_o` are now levels instead of 1-cycle
    pulses; restart resets the transaction sequence;
    `(* fsm_encoding = "none" *)` against the yosys fsm miscompile.
  - `top_master`/`top_loopback`: core runs at board clock/2 (timing) and
    starts only ~10 ms after configuration (GSR).
  - XDC in nextpnr-compatible minimal syntax.
- Docs: Sphinx/MyST documentation (these pages), generated register map,
  GitLab Pages job.

## 1.0.0-beta.1 — 2026-07-06

**Complete controller + SoC integration:**

- Behavioural models: `model/s23lc1024.sv` (SPI/SDI/SQI, complete) and
  `model/w25q128jv.sv` (read-focused, QE/QPI/dummy) incl. TBs.
- QSPI controller `src/qspi_*.sv`: register-driven CSR model, indirect and
  memory-mapped mode, shared 32-byte FIFO with prefetch, programmable
  frames (instr/addr/alt/dummy/data, 1/2/4 lanes), FSIZE check, CSHT,
  abort flow.
- hatch integration: CSR window `0x2000_0000`, mmap `0x4000_0000`, quad
  pins through all levels, SDK header `qspi.h`, smoketest uses the
  controller in single-SPI and SQI quad (system simulation green).
- CI: `make test-all` as the test gate.

## 0.2.0 — 2026-06-23

Change of direction: a register-driven design with programmable frames and
FIFO prefetch replaces the cache/XIP approach (frozen as tag
`archive/cache-xip-ref`).

## 0.1.0 — starting point

Simple 1-bit SPI controller (OBI subordinate, fixed `READ 0x03` /
`WRITE 0x02` sequence, 64-bit shift) — preserved as `src/spi.sv` with
`test/tb_spi.sv`.
