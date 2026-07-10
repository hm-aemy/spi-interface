# Programmer's & Integrator's Guide

## Software view

The SDK header `software/sdk/include/qspi.h` (in the hatch repository)
wraps the register accesses; all examples here use it. Without the SDK,
`volatile` pointers to the offsets from {doc}`registers` are sufficient —
or include the generated `sw/include/qspi_regs.h` from this repository,
which provides all offsets and bit-field macros.

### One-call initialisation (SDK)

For the supported memory chips the hatch SDK provides a single call that
performs the complete bring-up into quad memory-mapped mode — controller
reset, chip bus-mode recovery, chip init and frame setup:

```c
#include <qspi.h>

if (qspi_mem_init(QSPI_MEM_23LC1024, /*prescaler*/ 1) != 0)   // or QSPI_MEM_W25Q128JV
    panic();

volatile uint32_t *mem = (volatile uint32_t *)QSPI_MEM_BASE;
mem[0] = 0xDEADBEEF;              // plain loads/stores from here on
```

The recipes below show what such an init does at the register level.

### Basic initialisation

```c
#include <qspi.h>

// prescaler 1 -> SCK = clk/4; 23LC1024 = 128 KiB, 2 SCK CS-high time
QSPI_DCR = QSPI_DCR_FSIZE(16) | QSPI_DCR_CSHT(2);
QSPI_CR  = QSPI_CR_EN | QSPI_CR_PRESCALER(1);
```

### Recipe: instruction-only command (chip init)

```c
qspi_cmd(0x38);          // 23LC1024 EQIO: switch the chip to SQI mode
```

`qspi_cmd()` writes CCR with `IMODE=single, ADMODE=DMODE=skip, FMODE=00`
(→ trigger on the CCR write) and polls `SR.BUSY`.

### Recipe: indirect write with data (e.g. set the flash QE bit)

```c
qspi_cmd(0x50);                          // volatile SR write enable
QSPI_DLR = 0;                            // 1 data byte
QSPI_CCR = QSPI_CCR_VAL(0x31, QSPI_PH_SINGLE, QSPI_PH_SKIP, 0, 0,
                        QSPI_PH_SINGLE, QSPI_FM_IND_WRITE);
QSPI_DR8 = 0x02;                         // BYTE write: exactly DLR+1 bytes!
qspi_wait_idle();
```

### Recipe: indirect read (e.g. JEDEC ID)

```c
QSPI_DLR = 2;                            // 3 bytes
QSPI_CCR = QSPI_CCR_VAL(0x9F, QSPI_PH_SINGLE, QSPI_PH_SKIP, 0, 0,
                        QSPI_PH_SINGLE, QSPI_FM_IND_READ);   // starts immediately
qspi_wait_flevel(3);
uint32_t id = QSPI_DR & 0xFFFFFF;        // 0x1840EF (LSB = first byte)
qspi_wait_idle();
```

### Recipe: memory-mapped operation (XIP)

```c
// frame formats: reads from CCR, writes from WCCR
QSPI_WCCR = QSPI_CCR_VAL(0x02, QSPI_PH_QUAD, QSPI_PH_QUAD, 2, 0,
                         QSPI_PH_QUAD, QSPI_FM_IND_WRITE);
QSPI_CCR  = QSPI_CCR_VAL(0x03, QSPI_PH_QUAD, QSPI_PH_QUAD, 2, /*DCYC*/2,
                         QSPI_PH_QUAD, QSPI_FM_MEMMAP);      // mmap active

volatile uint32_t *mem = (volatile uint32_t *)QSPI_MEM_BASE; // 0x4000_0000
mem[0] = 0xDEADBEEF;                     // normal loads/stores from now on
uint32_t v = mem[0];

qspi_abort();                            // mandatory flow when leaving
```

Read-only device (flash): `QSPI_WCCR = 0;` — mmap stores then respond with a
bus error instead of writing to the chip.

### Reset, safe state and recovery

The controller has a well-defined **safe state** — the hardware-reset state
(all CSRs at their documented reset values, controller disabled, bus idle,
no lane driven). Three situations matter in practice:

**After an SoC reset/reboot** the controller is automatically in the safe
state; nothing needs to be done on the controller side.

**Forcing the safe state from software** works from *any* controller state,
including a running memory-mapped prefetch stream, because CR writes are
always accepted:

```c
QSPI_CR = QSPI_CR_ABORT;      // stop sequencer (byte boundary), flush FIFO,
                              // EN=0 prevents anything from restarting
while (QSPI_SR & QSPI_SR_BUSY) { }
QSPI_CCR = 0; QSPI_WCCR = 0;  // leave mmap mode; then restore the other
QSPI_DLR = 0; QSPI_AR = 0;    // reset values and clear the flags
QSPI_ABR = 0; QSPI_DCR = 0x10;
QSPI_CR  = 0;
QSPI_FCR = QSPI_FCR_CTEF | QSPI_FCR_CTCF;
```

The hatch SDK wraps exactly this as `qspi_reset()`.

**The external chip is not covered by any of this.** The 23LC1024 and the
W25Q128JV have no reset pin; they keep their configured bus mode (SQI/QPI)
across an SoC reset or software restart. After a reboot, the controller's
single-SPI default frames would talk past a chip still stuck in quad mode.
The recovery sequence sends `0xFF` — 23LC1024 *RSTIO* (valid in every mode)
and W25Q128JV *exit QPI* — on 4, then 2, then 1 lanes; whichever variant
matches the chip's current mode resets it to single-SPI, the others are
ignored as incomplete/unknown commands:

```c
QSPI_CCR = QSPI_CCR_VAL(0xFF, QSPI_PH_QUAD, QSPI_PH_SKIP, 0, 0,
                        QSPI_PH_SKIP, QSPI_FM_IND_WRITE);
qspi_wait_idle();
QSPI_CCR = QSPI_CCR_VAL(0xFF, QSPI_PH_DUAL, QSPI_PH_SKIP, 0, 0,
                        QSPI_PH_SKIP, QSPI_FM_IND_WRITE);
qspi_wait_idle();
qspi_cmd(0xFF);
```

In the hatch SDK this is `qspi_bus_reset()`; `qspi_mem_init()` runs it
automatically. Note that RSTIO resets only the 23LC1024's *bus mode*, not
its mode register — an init must therefore always program the mode register
(sequential mode is required for the prefetch stream), which
`qspi_mem_init()` also uses as its chip-presence check.

### Chip profiles (cheat sheet)

| | 23LC1024 (SRAM) | W25Q128JV (flash) |
|---|---|---|
| `DCR.FSIZE` | 16 (128 KiB) | 23 (16 MiB) |
| init | `WRMR 0x40` + `EQIO 0x38` | `0x50` + `0x31` with QE=1 (for quad) |
| read single | `0x03`, DCYC 0 | `0x03`, DCYC 0 · `0x0B`, DCYC 8 |
| read quad | `0x03` all phases quad, **DCYC 2** | `0x6B` addr single/data quad, **DCYC 8** |
| mmap write | `0x02` in WCCR | WCCR = 0 (blocked) |

Tested end-to-end examples: `software/smoketest/main.c` and
`software/fpgatest/main.c` (hatch repository; run in the system simulation
and on FPGA hardware) and `test/tb_qspi_top.sv` / `test/tb_qspi_flash.sv`
(register sequences readable 1:1).

## SoC integration view

### Connection checklist

1. **Two OBI subordinate windows** in the address decoder (hatch:
   `user_pkg.sv` → `UserQspiCfg` 4 KiB + `UserSpi` 512 MiB) and connect both
   ports of `qspi_top` (hatch: `user_domain.sv`, incl. ID-width adaptation
   xbar→4 bit).
2. **Pads:** route `spi_sio_o/oe/i[3:0]`, `spi_cs_no`, `spi_sclk_o` to the
   chip top; tri-state exclusively there
   (`assign pad[i] = oe[i] ? o[i] : 1'bz`). In testbenches a priority mux is
   sufficient instead of real `z` (see `simulation/tb_hatch.sv` in hatch).
3. **Filelist:** `spi_pkg.sv`, `qspi_pkg.sv`, then the modules (order: see
   `test/Makefile`, variable `QSPI_SRCS`, or `simulation/hatch.vlt` in the
   hatch repository).
4. **Parameters:** adapt `FifoDepth` (power of two, default 32) and
   `ChipAddrW` (default 29 = 512 MiB window) to the SoC window.

### SoC-level operating rules

- The MEM port serves **one** outstanding transaction (gnt stalling);
  behind an xbar with `NumMaxTrans ≥ 2` this is uncritical since `gnt`
  paces the traffic.
- Code execution from the window (XIP) is efficient for sequential fetch
  thanks to the prefetch stream; jumps cost one stream restart each
  (abort + command latency).
- During mmap operation only `CR`, `SR`, `FCR` are meaningfully usable from
  software; everything else requires the abort flow.
- There are no interrupts (yet) — software polls `SR` (a deliberate
  restriction of the current feature set, see {doc}`microarchitecture`).
