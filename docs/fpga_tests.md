# FPGA Test Setups (Arty A7)

This page describes the **SPI-specific hardware test setups** of this
repository on Digilent Arty A7 boards:

1. **Single-board loopback** — test master + SRAM slave inside one FPGA,
   result via USB-UART. Fastest hardware proof, no wiring at all.
2. **Two-board model test** — SRAM slave on Board A (`top_model.sv`),
   synthesisable test master on Board B (`top_master.sv`), connected via
   Pmod. Proves the protocol over a real cable. Open-source flow
   (`fpga/arty/`), unidirectional wiring (see {doc}`known_issues`).
3. **Two-board model, Vivado** (`fpga/vivado/`) — same `fpga_sram_slave.sv`,
   but `top_model`'s `SIO0..3` are one genuine bidirectional Pmod bus instead
   of split command/response pin groups. Fewer wires, and real tri-state.

The **complete hatch SoC on Board A** driving the SRAM slave on Board B (both
setups 2 and 3 above have a hatch-SoC counterpart) lives in the hatch
repository and is documented there (hatch docs, *Two-board FPGA test* /
*FPGA Flow, Vivado*); Board B is programmed exactly as described here either
way.

Setups 1 and 2 use the open-source toolchain only (`fpga/arty/`); setup 3
uses Vivado (`fpga/vivado/`). Hardware pitfalls found during bring-up are
collected separately in {doc}`known_issues`.

## Files involved

| File | Role |
|---|---|
| [`fpga/arty/fpga_sram_slave.sv`](../fpga/arty/fpga_sram_slave.sv) | fully synchronous SPI/SQI SRAM slave (23LC1024 subset) — what actually runs on Board A |
| [`fpga/arty/top_model.sv`](../fpga/arty/top_model.sv) | Board-A top: slave on Pmod JA + status LEDs |
| [`fpga/arty/spi_test_master.sv`](../fpga/arty/spi_test_master.sv) | synthesisable test-master core (FSM) |
| [`fpga/arty/top_master.sv`](../fpga/arty/top_master.sv) | Board-B top: test master on Pmod JA + buttons/LEDs |
| [`fpga/arty/top_loopback.sv`](../fpga/arty/top_loopback.sv) | loopback top: master + slave internal + UART reporter |
| [`fpga/arty/uart_tx.sv`](../fpga/arty/uart_tx.sv) | minimal UART transmitter for the loopback report |
| [`fpga/arty/tb_arty_pair.sv`](../fpga/arty/tb_arty_pair.sv) | Verilator TB: master against slave (proof before hardware) |
| [`fpga/arty/tb_loopback.sv` (in `test/`)](../test/tb_loopback.sv) | Verilator TB of the complete loopback top incl. UART decode |
| [`fpga/arty/arty_a7.xdc`](../fpga/arty/arty_a7.xdc) | pin constraints, ONE file for both boards |
| [`fpga/arty/Makefile`](../fpga/arty/Makefile) | yosys → nextpnr-xilinx → prjxray → openFPGALoader |
| `fpga/arty/local.mk` | machine-local toolchain paths (gitignored) |

Both testbenches run without hardware: `cd test && make TOP=tb_arty_pair`
and `make TOP=tb_loopback` — always do this first after changes.

## Toolchain

The flow is: **yosys** (synthesis, with the slang SystemVerilog frontend) →
**nextpnr-xilinx** (place & route) → **prjxray** tools
(`fasm2frames`/`xc7frames2bit`, bitstream) → **openFPGALoader**
(programming).

The recommended way to install all of it is **[openXC7](https://github.com/openXC7)**,
which bundles yosys, nextpnr-xilinx and the prjxray databases as one
consistent package — follow its installation guide. Alternatively, the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) provides
yosys (including `slang.so`), and nextpnr-xilinx can be built from source
(see its README; a chip database for your part must then be generated with
`bbaexport.py`/`bbasm`).

A step-by-step walkthrough of the toolchain installation — including a
root-less setup and the exact chipdb/prjxray environment — is part of the
hatch documentation (*FPGA flow* page), since the identical flow builds the
whole SoC there. For this repository it is sufficient to provide two paths,
either exported or entered in `fpga/arty/local.mk` (auto-included by the
Makefile):

```bash
export CHIPDB=/path/to/nextpnr-xilinx-chipdb      # contains xc7a100t.bin / xc7a35t.bin
export XRAY_DIR=/path/to/prjxray-db               # database/artix7/...
```

`make check-env` verifies both. For `openFPGALoader`, install the package
(`apt install openfpgaloader`) and its udev rules for the Digilent FTDI
(0403:6010), then re-plug the board; `openFPGALoader --scan-usb` must list
it without `sudo`.

## Setup 1: single-board loopback

```bash
cd fpga/arty
make loopback.bit prog-loopback      # only one board attached: no serial needed
stty -F /dev/ttyUSB1 115200 raw -echo && cat /dev/ttyUSB1
```

Expected: the host reads `PASS 6` cyclically (the loopback top re-runs the
sequence forever). The number counts the completed transactions of the test
sequence (RSTIO, single write/read, EQIO, quad write/read, RSTIO). The top
deliberately runs **without a reset button** — it starts from bitstream
INIT values just like after configuration, which `test/tb_loopback.sv`
replicates.

## Setup 2: two boards (test master ↔ SRAM slave)

### Wiring

**Both boards are powered separately via USB** (power AND programming over
the same USB cable per board). The Pmod connection carries **no** supply
voltage.

Due to the unidirectional wiring (no tri-state, see {doc}`known_issues`)
the command and response lanes use separate pins:

| Signal | Direction | Board B (master) | ↔ | Board A (slave) |
|---|---|---|---|---|
| CS_n  | B→A | JA1 | ↔ | JA1 |
| SCLK  | B→A | JA2 | ↔ | JA2 |
| SIO0..3 (command/write data) | B→A | JA3 JA4 JA7 JA8 | ↔ | JA3 JA4 JA7 JA8 |
| SIO0..3 (read data back)     | A→B | JA9 JA10 JB1 JB2 | ↔ | JA9 JA10 JB1 JB2 |
| GND | — | JA GND | ↔ | JA GND (**mandatory**) |

```{warning}
3.3 V levels — do NOT connect the Pmod VCC pins. Each board is powered by
its own USB; a shared VCC could drive equalising currents at differing
power-up states. A common GND, however, is mandatory.
```

Keep cables short (**< 15 cm** recommended). The default SCK of the test
master is 1 MHz (`SCK_HALF_PERIOD` parameter in `spi_test_master.sv`) —
generous margins for jumper wires, and further reducible for debugging.

### Build, program, run

```bash
cd fpga/arty
make model.bit master.bit
openFPGALoader --scan-usb                    # note the two FTDI serials
make prog-model  FTDI_SERIAL_MODEL=<serial-of-board-A>
make prog-master FTDI_SERIAL_MASTER=<serial-of-board-B>
```

Then: reset Board A (BTN0), reset Board B (BTN0), press **BTN1 on Board B**
to start the sequence.

### LED interpretation

- **Board A, LD4**: heartbeat (~0.75 Hz) — FPGA configured and running. If
  this does not blink, the problem is the bitstream/configuration, not the
  SPI protocol.
- **Board A, LD5**: activity — stretched pulse on any bus traffic.
- **Board B, LD4**: heartbeat, same meaning.
- **Board B, LD0..LD3**: progress — current/last transaction in binary
  (0=RSTIO, 1=WRITE single, 2=READ single, 3=EQIO, 4=WRITE quad,
  5=READ quad, 6=final RSTIO). Stuck at 0/1 → Board A does not answer.
- **Board B, LD5**: **PASS** — lights permanently after a clean run.
- **Board B, LD6**: **FAIL** — some byte comparison failed.

### If it fails

1. Lower SCK: increase `SCK_HALF_PERIOD` (e.g. `5000` → 10 kHz), rebuild
   `master.bit`, flash again.
2. Scope/logic analyser on JA1/JA2 of Board B: does SCLK toggle at the
   expected rate? Does CS_n frame transactions?
3. Typical culprits: missing common GND; swapped SIO2/SIO3 (only shows up
   from the SQI transactions on, progress stuck at 3/4); model bitstream on
   the master board or vice versa (Board A's inputs then never move).
4. Check which signals physically arrive with a counting bus-spy bitstream
   before debugging logic — see the methodology notes in
   {doc}`known_issues`.

## Setup 3: two boards, Vivado (real bidirectional pins)

`fpga/vivado/` builds the same `fpga_sram_slave.sv` behind a different
`top_model`: `SIO0..3` is one genuine bidirectional `inout` bus (`ja_sio`)
instead of the open-source flow's split command/response pin groups. Reason
and wiring implications: {doc}`known_issues` (`IOBUF` non-functional under
nextpnr-xilinx) and the hatch repository's `docs/fpga_vivado_flow.md`, which
covers the mirror-image change on the SoC side in full.

```{note}
This only replaces `top_model` (Board A/the memory in this repo's own
naming, "Board B" in the hatch two-board doc — see the wiring tables, the
naming direction differs between the two repos' docs). There is no Vivado
counterpart of `top_master.sv`/`spi_test_master.sv` yet; setup 3 has so far
only been run against the hatch SoC (`fpga/vivado/hatch.bit` in the hatch
repository), not against this repository's own standalone test master.
```

```bash
cd fpga/vivado
make model.bit                       # needs Vivado; local.mk: VIVADO := /path/to/vivado
make prog-model FTDI_SERIAL=<serial-of-the-model-board>
```

Confirmed 2026-07-16 on two Arty A7-100T, cables unchanged from the
unidirectional setup (the now-unused former response pins JA9/JA10/JB1/JB2
simply stay wired but undriven on both ends — harmless): hatch SoC
(`fpga/vivado/hatch.bit`) against this `model.bit`,
`QSPI FPGA TEST PASSED (13 checks)`, all 13 checks green including SQI quad
mode — the tri-state switching works correctly on both ends of a real cable,
not just within one FPGA's own pad ring.

## Outlook: flash model on Board A

The same setup can later be repeated with `model/w25q128jv.sv` on Board A
(pure read test). A `top_model_flash.sv` would instantiate the flash model;
the test master needs a second sequence with the flash opcodes
(`0x03`/`0x0B`/`0x6B`) and an 8-dummy-cycle phase. Wiring and toolchain
stay unchanged. Note that the behavioural flash model has the same async-CS
constructs as the SRAM model — expect to need a synchronous slave variant
(cf. `fpga_sram_slave.sv` and {doc}`known_issues`).
