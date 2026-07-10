# Architecture Overview

## Block diagram

```text
                  ┌─────────────────────────── qspi_top ────────────────────────────┐
                  │                                                                  │
 OBI (CSR) ──────►│ ┌────────────┐  register file CR/DCR/SR/FCR/DLR/CCR/AR/ABR/WCCR │
 0x2000_0000      │ │ qspi_regs  │  + command triggers (indirect mode)              │
                  │ └─────┬──────┘                                                  │
                  │       │ job/start                    ┌──────────────┐           │
                  │       ▼                              │ qspi_sck_div │           │
 OBI (MEM) ──────►│ ┌────────────┐ job/start ┌───────────┴─┐  tick      │           │
 0x4000_0000      │ │ qspi_mmap  │──────────►│ qspi_cmd_seq│◄───────────┘           │
 (XIP window)     │ │ prefetch   │  abort    │ phase FSM:  │      ┌────────────┐    │
                  │ │ control,   │◄─────────►│ INSTR/ADDR/ │◄────►│ qspi_shift │────┼─► spi_cs_no
                  │ │ FSIZE check│           │ ALT/DUMMY/  │ byte │ 1/2/4 lanes│────┼─► spi_sclk_o
                  │ └─────┬──────┘           │ DATA        │      │ mode 0     │◄───┼─► spi_sio_o/oe/i[3:0]
                  │       │ pop (word)       └──────┬──────┘      └────────────┘    │   (tri-state at the pad)
                  │       ▼                         │ push/pop (byte)               │
                  │ ┌───────────────────────────────▼──────┐                        │
                  │ │        qspi_fifo (32 bytes)          │                        │
                  │ │  one FIFO for TX, RX and prefetch    │                        │
                  │ └──────────────────────────────────────┘                        │
                  └──────────────────────────────────────────────────────────────────┘
```

All modules live in `src/`; types and the register layout in
`src/qspi_pkg.sv`.

| Module | Task | LoC (approx.) |
|---|---|---|
| `qspi_regs` | CSR file, command-trigger rules, DR↔FIFO traffic | 270 |
| `qspi_mmap` | memory-mapped frontend: prefetch stream, address-jump detection, error responses, write staging | 230 |
| `qspi_cmd_seq` | phase FSM: executes exactly one *job* (frame), byte by byte | 290 |
| `qspi_shift` | bidirectional shift unit, 1/2/4 lanes, SPI mode 0, one operation = one byte (or N dummy clocks) | 140 |
| `qspi_fifo` | byte FIFO with up to 4-byte push/pop per cycle (32-bit bus side ↔ byte serial side) | 80 |
| `qspi_sck_div` | prescaler, generates half-period ticks | 35 |
| `qspi_top` | wiring, FIFO port muxing, job arbitration | 180 |

## Datapath

The central abstraction is the **job** (`qspi_job_t`): one complete,
programmable command frame — opcode, lane modes per phase, address,
alternate bytes, dummy cycles, data length and direction. Jobs come from
exactly two sources, which `CCR.FMODE` makes mutually exclusive:

Indirect mode (`FMODE` = 00/01)
: Software writes the CSRs; a write to CCR, AR or DR triggers the command
  (rules: {doc}`registers`). Data moves through the DR register via the
  FIFO — write data is pushed *before/with* the trigger, read data is popped
  after polling `SR.FLEVEL`.

Memory-mapped mode (`FMODE` = 11)
: The MEM OBI window behaves like ordinary memory. **Reads** start an
  *unlimited* sequential read job: CS stays low, the chip streams (the
  SRAM's sequential mode or the flash's natural address increment), bytes
  land in the FIFO. Sequential follow-up accesses are FIFO hits without SPI
  latency; an address jump aborts the stream (abort → flush → new job).
  **Writes** stage their 1–4 bytes in the FIFO and run as a short write job
  with the frame format from **WCCR**.

The **single shared FIFO** changes ownership: indirect TX (DR pushes,
sequencer pops), indirect RX (sequencer pushes, DR pops), prefetch
(sequencer pushes, mmap pops word-wise), mmap write staging (mmap pushes,
sequencer pops). The bus side moves up to 4 bytes per cycle, the serial side
exactly one — the FIFO balances the rates and doubles as the prefetch buffer
(backpressure: FIFO full → SCK pauses, resumes at ≥ 4 bytes free).

## Clock and reset

There is **one** clock domain (`clk_i`): SCK is generated as a register in
the system clock domain (`qspi_sck_div` provides half-period ticks,
`qspi_shift` toggles `sclk_o`). No CDC — this limits the SCK frequency to
`clk/4` (PRESCALER=1) and is a deliberate design decision
({doc}`microarchitecture`). Reset is asynchronous active-low (`rst_ni`), as
in the rest of the hatch SoC.

### Reset state and safe state

A hardware reset (`rst_ni`) puts the controller into the documented default
state: `CR = 0` (controller **disabled**, prescaler 0), `DCR = 0x10`
(FSIZE 16 → 128 KiB), all frame registers (CCR/WCCR/DLR/AR/ABR) zero — i.e.
**not** in memory-mapped mode — flags cleared, sequencer idle, `CS` high,
no lane driven. Software can force this same state at any time (see the
*Reset and recovery* section of the {doc}`programmers_guide`); the abort
flow is guaranteed to terminate even a running memory-mapped prefetch
stream.

Note that a controller reset does **not** reset the external memory chip:
the supported chips have no reset pin and keep their configured bus mode
(SQI/QPI) across an SoC reset. Recovery is a software sequence, also
described in the {doc}`programmers_guide`.

## Embedding in an SoC (hatch example)

```text
CPU ──► SoC xbar ──┬─► CSR window (hatch: 0x2000_0000) ─► qspi_top.CSR
                   └─► MEM window (hatch: 0x4000_0000) ─► qspi_top.MEM
                                                           │
                     pads (tri-state at the chip top) ◄────┘
                     cs_n · sclk · sio[3:0] (o/oe/i)
```

The controller exposes the SIO lanes as separate `o/oe/i` bundles; the
actual tri-state driver (`assign pad = oe ? o : 1'bz`) lives strictly at the
chip top or in the testbench — in the FPGA case in the board wrappers
(`fpga/arty/top_*.sv`).
