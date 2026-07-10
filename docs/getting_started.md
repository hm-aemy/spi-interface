# Getting Started

Goal: all self-tests green in under 5 minutes.

## Prerequisites

- **Verilator ≥ 5.020** (`apt install verilator` on Ubuntu 24.04 is enough)
- `make`, a C++ compiler
- optional: **Surfer** or GTKWave for waveforms (`.fst`)

## Build and run all tests

```bash
git clone <repo-url> spi-interface && cd spi-interface
cd test
make test-all
```

Expected output (abbreviated):

```text
TB PASSED
tb_s23lc1024: OK
tb_w25q128jv: OK
tb_qspi_top: OK
tb_qspi_flash: OK
tb_arty_pair: OK
tb_loopback: OK
```

Every testbench is self-checking and terminates with `$fatal` (nonzero exit
code) on errors. `make test-core` runs the model + controller testbenches
only (the CI gate for merge requests); `make test-all` additionally runs the
FPGA-top testbenches.

## A single testbench + waveform

```bash
cd test
make TOP=tb_qspi_top        # controller against the 23LC1024 SRAM model
surfer tb_qspi_top.fst      # or: gtkwave tb_qspi_top.fst
```

Available tops:

| `TOP=` | Tests |
|---|---|
| `tb_s23lc1024` | SRAM behavioural model (SPI/SDI/SQI, mode register, wraps) |
| `tb_w25q128jv` | flash behavioural model (read opcodes, dummy, QE, QPI) |
| `tb_qspi_top` | QSPI controller ↔ SRAM model (indirect + memory-mapped) |
| `tb_qspi_flash` | QSPI controller ↔ flash model (dummy phase, 16 MiB FSIZE) |
| `tb_arty_pair` | synthesisable FPGA test master ↔ SRAM model |
| `tb_loopback` | complete FPGA loopback top incl. UART report |

## Simulating inside the hatch SoC

The parent hatch repository runs a Verilator system simulation in which the
CPU executes a smoketest that uses this controller memory-mapped in
single-SPI **and** SQI quad mode. See the *hatch documentation*
(`docs/` in the hatch repository) for the full simulation and software-build
guide; the short version:

```bash
cd <hatch-repo>
make smoke
```

## On real hardware (Arty A7)

The quickest hardware proof is the **single-board loopback** (test master +
SRAM slave on one FPGA, result via USB-UART):

```bash
cd fpga/arty
make loopback.bit prog-loopback     # toolchain paths: local.mk, see fpga_tests
stty -F /dev/ttyUSB1 115200 raw -echo && cat /dev/ttyUSB1   # -> "PASS 6"
```

Toolchain installation and the two-board setups are described in
{doc}`fpga_tests`.

## Building the docs locally

```bash
pip install -r docs/requirements.txt
sphinx-build -b html docs public
xdg-open public/index.html
```
