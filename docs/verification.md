# Verification Plan

## Strategy

Three levels, each self-checking and CI-capable:

1. **Model verification** — the behavioural models of the target chips are
   tested protocol-strictly against the datasheets (bit-banging master in
   the TB, no controller involved). The models then serve as the
   *reference* for everything else.
2. **Controller verification** — `qspi_top` against both models, via both
   OBI ports, including error cases and timing properties (prefetch hit
   measurably faster than demand read).
3. **System/hardware verification** — hatch system simulation (the CPU runs
   the smoketest) and FPGA bring-up on real hardware.

All testbenches terminate with `$fatal` (nonzero exit) on errors.
`make test-core` (models + controller) is the CI gate for merge requests;
`make test-all` additionally covers the FPGA tops.

## Testbench inventory

| TB | DUT | Covered |
|---|---|---|
| `tb_s23lc1024` (33 checks) | SRAM model | SPI/SDI/SQI R/W, mode register (WRMR/RDMR), EQIO/EDIO/RSTIO incl. switch timing, dummy byte on non-SPI reads, page wrap (32 B), sequential wrap at the array end, don't-care address bits |
| `tb_w25q128jv` (107 checks) | flash model | 0x03/0x0B/0x3B/0x6B/0xEB with correct dummy counts, QE gating (0x6B without QE does not drive), setting QE via both paths, JEDEC ID, QPI cycle incl. 0xC0 read parameters, erased read (0xFF), **negative test** wrong dummy count |
| `tb_qspi_top` (24 checks) | controller ↔ SRAM | indirect single/quad R/W, instruction-only trigger, all three trigger paths, mmap reads (demand/hit/jump, hit < demand as timing check), mmap writes sb/sh/sw, endianness (chip byte = LSB), TEF + FCR, mmap errors (FSIZE, FMODE≠11, WCCR.DMODE=0), abort flow incl. FIFO flush |
| `tb_qspi_flash` (13 checks) | controller ↔ flash | JEDEC ID without address phase, setting QE via byte DR, 0x6B (8 dummy), **negative test** 6 instead of 8 dummy, mmap with FSIZE=23 incl. hit/jump/erased, mmap write block |
| `tb_arty_pair` | FPGA test master ↔ SRAM model | complete bring-up sequence, restart without model reset |
| `tb_loopback` | complete FPGA top | incl. UART reporter decoding; runs deliberately **without a reset button** (bitstream INIT start conditions as on real hardware) |
| `tb_hatch` (hatch repo) | whole SoC | CPU→xbar→qspi→model: mmap in single-SPI and SQI quad from C code, incl. the SDK bring-up (`qspi_mem_init`), UART-verified |

## Coverage goals

Current state: purely directed tests, no machine coverage collection.
Target picture for the beta → stable transition:

- [ ] **Line/branch coverage** via `verilator --coverage` in
      `make test-all`, target ≥ 90 % on `src/qspi_*.sv` (justified waivers
      for the rest).
- [ ] **Functional checklist** (below) complete; current gaps:
  - [ ] controller dual-lane data phase end-to-end (the models support SDI;
        the instruction-only dual path is now exercised by
        `qspi_bus_reset()` in the hatch system simulation, the data path is
        not)
  - [ ] alternate-byte phase end-to-end (0xEB profile in mmap)
  - [ ] FIFO backpressure corner cases under mmap (targeted stress test;
        currently only covered implicitly by the continuous prefetch)
  - [ ] randomised address/length sequences (constrained random) against a
        scoreboard
- [ ] OBI protocol assertions (gnt/rvalid relations) as SVA/`assert` in the
      TBs instead of only implicitly via the master tasks.

## Hardware validation

**Status: FPGA-validated (controller inside the full SoC, two boards), not
silicon-proven.**

- 2026-07-08, two Arty A7-100T: **complete hatch SoC on Board A**
  (RISC-V core + QSPI controller, program as BRAM init) ↔ **SRAM slave on
  Board B**, wired via Pmod. The core runs `software/fpgatest`; the host
  reads `QSPI FPGA TEST PASSED (D checks)` over the USB-UART — **all 13
  checks** (instruction-only, RDMR/WRMR, memory-mapped single-SPI + SQI
  quad, sub-word, endianness, prefetch, TEF) green on real hardware. This
  proves the QSPI **controller** in the real SoC over a physical SPI link.
  Setup: hatch docs, *Two-board FPGA test*.
- 2026-07-07, Arty A7-100T: `fpga/arty/top_loopback.sv` (test master +
  SRAM slave, wired internally), host reads `PASS 6` — first hardware proof
  of model + master + protocol sequence. Setup: {doc}`fpga_tests`.
- Board B runs the fully synchronous `fpga_sram_slave.sv` (not the async-CS
  behavioural model, which does not map in the FPGA flow —
  {doc}`known_issues`). Wiring is unidirectional (the tri-state `IOBUF` is
  non-functional in this flow).
- Open: tests against **real chips** (23LC1024/W25Q128JV on Pmod), the
  flash profile on two boards, and the silicon tapeout.

## Known limitations

- Non-contiguous byte enables at the MEM port → `err` (by design).
- `DR` overfill (more than DLR+1 bytes pushed) is not detected — software
  contract, see {doc}`registers`.
- Verilator-specific TB techniques (negedge stimulus, `#1ps` gnt check) are
  documented in `test/tb_qspi_top.sv` and must be adopted in new TBs
  (background: {doc}`known_issues`).
