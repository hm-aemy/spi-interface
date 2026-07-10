# Design Rationale & Microarchitecture

This page explains the *why*s — the decisions you cannot see in the RTL,
including the failures that led to them.

## Why a register-driven controller with programmable frames?

The project started with a hard-wired SQI backend plus a 4 KiB direct-mapped
cache as prefetch (tag `archive/cache-xip-ref`). That direction was
deliberately abandoned:

| | cache + fixed backend (old) | FIFO + programmable frames (new) |
|---|---|---|
| second chip (flash) | new backend needed | just a different register setup |
| area cost | 4 KiB tag+data RAM | 32-byte FIFO |
| sequential fetch | cache-line fill | streaming without line boundaries |
| random access | cache hit possible | always a stream restart |
| software model | implicit | documented CSR model |

For the main use case — *sequential* code execution from external memory —
the stream prefetch is practically on par with the cache at a fraction of
the complexity. Random data accesses are slower but correct. The
register-driven CSR model (control/frame/status registers with trigger
rules and an abort flow) follows the programming model established by
commercial MCU quad-SPI peripherals, so the software patterns are
well-proven and documented.

## The job as central abstraction

`qspi_cmd_seq` knows neither registers nor bus windows — it executes exactly
one `qspi_job_t`. Indirect mode and memory-mapped mode therefore share the
same, once-verified datapath; `qspi_regs` and `qspi_mmap` are pure job
factories. Arbitration is trivial because `CCR.FMODE` makes the sources
mutually exclusive (no locking, no priorities).

## Phase FSM (`qspi_cmd_seq`)

```text
        start                 tick
 StIdle ─────► StCsLow(CS↓) ─────► StInstr ─► StAddr ─► StAlt ─► StDummy ─► StData
   ▲                                  │  (each phase: *MODE=00 → skip;           │
   │                                  │   abort_i → abort at a byte boundary)    │
   │            CSHT ticks            ▼                                          │
   └───────── StCsht ◄──── StCsHold(CS↑) ◄───────────────────────────────────────┘
                                             (data done ∨ abort)
```

Each phase reads its `*MODE` field and works **byte by byte**: one order to
`qspi_shift` per byte, with arbitrary time allowed in between. This is the
design's most important simplification — it is protocol-legal because static
SPI slaves only react to edges (SCK pauses with CS low are invisible). It
makes three problems trivial that would otherwise need a tightly coupled
pipeline:

- **TX underrun** (indirect write, FIFO empty): simply start no new byte,
  SCK rests.
- **RX backpressure** (FIFO full): the transfer pauses; hysteresis: resumes
  at ≥ 4 bytes free (avoids stutter at the full boundary).
- **Turnaround/dummy**: its own shift operation with `oe=0` and N clocks.

The dummy phase counts **SCK clocks** (not bytes) because the target chips
need different granularity (SRAM SQI: 2 clocks; flash 0xEB: 4; 0x0B/0x6B:
8).

## Shift unit: registered I/O and the first-bit trap

`qspi_shift` updates outputs on the falling and samples on the rising edge
(mode 0). The first bit of an output is driven at the *start* of the
operation (not at the first edge) — otherwise the device samples an invalid
bit on the first rising edge. Between operations the unit holds the last
drive values (harmless, no edges) but releases the lanes on dummy/input/CS
end.

An RX byte is captured into its own register on `done` before the FIFO push
(registered, +1 cycle) runs — the next shift order may overwrite the shift
register immediately. The backpressure threshold accounts for 1 byte of
headroom (`free ≥ 2` instead of `≥ 1`).

## One FIFO instead of four

TX data, RX data, prefetch and mmap write staging share **one** 32-byte
FIFO with a 4-byte bus port and a 1-byte serial port. Possible because all
four uses are mutually exclusive in time (FMODE + BUSY). The price is
muxing in `qspi_top` and the software rule "push exactly DLR+1 bytes"; the
gain: one memory, one verification, and the prefetch buffer comes "for
free". Depth 32 covers one 23LC1024 page (32 B) and ≥ 8 prefetch words.

## mmap frontend: stream semantics

`qspi_mmap` tracks the chip address of the FIFO head (`head`). A read at
`head` is a **hit** (pop word, `head += 4`); anything else is a **jump**:
abort (byte boundary!), FIFO flush, new unlimited read job. Why unlimited?
The sequencer then needs no notion of length for XIP, and backpressure
naturally limits the lookahead to the FIFO depth. Consequence: `BUSY` stays
1 permanently during mmap operation — documented, and the reason for the
mandatory abort flow on mode changes. A wait counter in the serve state
detects an externally aborted stream (software ABORT despite mmap) and
restarts it instead of hanging.

mmap writes stage their 1–4 bytes in the (freshly flushed) FIFO and run as
an ordinary write job via **WCCR**. A second CCR instead of bit-fiddling in
one: read and write frames differ on real chips almost always (SRAM: dummy
only on read; flash: no write at all) — and `WCCR.DMODE=00` doubles as the
write-protect semantics.

## Deliberate feature-set boundaries

Not implemented: interrupts (TCF/TEF/…), FIFO threshold flag, automatic
status polling, DMA, dual-SPI in the controller datapath (the models
support it), instruction-only-once optimisation (SIOO), DDR, mmap timeout,
CDC for SCK > clk/4. Each of these is a candidate for a later extension;
the register map leaves room at the customary spots.
