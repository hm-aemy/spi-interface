# Register Map

```{note}
The tables on this page are generated at docs-build time from
**`docs/regs.yaml`** (`docs/gen_regmap.py`) — the YAML file is the single
source of truth. The same generator also produces the C header
**`sw/include/qspi_regs.h`** (register offsets, bit fields, field
encodings), which is checked into the repository so software can consume it
without running the generator; CI fails if it is out of date. Register
changes must be made in the YAML file (and in the RTL, `src/qspi_pkg.sv`),
never in this page or the header.
```

```{include} generated/registers_gen.md
```

## Command triggers (indirect mode)

A command starts only with `SR.BUSY = 0` and `CR.EN = 1`, triggered by the
*last* required CSR write:

| Write to | Condition | Typical case |
|---|---|---|
| **CCR** | `ADMODE=00` ∧ (`FMODE=01` ∨ `DMODE=00`) | instruction-only (EQIO, RSTIO, WREN) or read without address (JEDEC ID, status register) |
| **AR** | `ADMODE≠00` ∧ (`FMODE=01` ∨ `DMODE=00`) | read with address; write without data phase |
| **DR** | `FMODE=00` ∧ `DMODE≠00` | write with data (the first DR write starts) |

So the order is: configure DLR/CCR/AR first, the trigger write comes last.

## Software contracts

- **DR width = byte enables.** `sb` pushes/pops 1 byte, `sh` 2, `sw` 4.
  **Exactly `DLR+1` bytes** must be pushed — excess bytes stay in the FIFO
  and corrupt the next command (remedy: `CR.ABORT` flushes).
- **No reconfiguration while BUSY.** Writes to DLR/CCR/AR/ABR/WCCR are
  silently ignored while `SR.BUSY=1`. Poll `SR.BUSY` first or assert
  `CR.ABORT`.
- **Leaving mmap only via ABORT.** In memory-mapped mode the prefetch
  stream runs forever (`BUSY` stays 1); `CR.ABORT` ends it, flushes the
  FIFO, and only then does a CCR write (e.g. changing `FMODE`) take effect.
- **Reads:** check `SR.FLEVEL` before reading DR (enough bytes in the
  FIFO); `SR.TCF` signals the end of the whole transfer.
- **Error picture:** indirect out-of-range → `SR.TEF` (no start);
  mmap out-of-range / `EN=0` / `FMODE≠11` / write with `WCCR.DMODE=00` →
  OBI `err` response.
- **Endianness:** the chip byte at address *A* sits on byte lane *A mod 4*
  (little-endian, RISC-V-conformant); the first byte received is the LSB.
