# QSPI-Interface

**Quad-SPI controller with OBI bus attachment** — developed for the *hatch*
SoC (RISC-V) at Hochschule München, reusable as a standalone IP with two OBI
subordinate ports. The controller maps external serial memories into the
address space as execution and data memory (XIP) and additionally offers a
register-driven **indirect mode** for arbitrary chip commands (init, status,
JEDEC ID, …).

Supported/validated target devices:

| Chip | Type | Access | Profile |
|---|---|---|---|
| Microchip **23LC1024** | 1 Mbit SRAM | read **and** write | SPI/SQI, 0/2 dummy clocks |
| Winbond **W25Q128JV** | 128 Mbit NOR flash | read | 0x03/0x0B/0x6B/0xEB, QE bit, 4–8 dummy clocks |

```{admonition} Status: Beta
:class: important
Fully simulation-verified (6 self-checking testbenches + SoC system
simulation) and **FPGA-validated** on Arty A7-100T boards, both the
open-source flow (two-board run inside the complete hatch SoC) and, since
2026-07-16, a Vivado flow with real bidirectional QSPI pins ({doc}`fpga_tests`
setup 3) — same two-board result, fewer wires.
Not yet **silicon-proven**. Details: {doc}`verification` and {doc}`changelog`.
```

## Contents

```{toctree}
:maxdepth: 2

getting_started
architecture
interfaces
registers
programmers_guide
microarchitecture
fpga_tests
verification
known_issues
changelog
```

## Quick links

- Build and simulate in 5 minutes → {doc}`getting_started`
- Register map (generated from `docs/regs.yaml`) → {doc}`registers`
- Software recipes + SoC integration → {doc}`programmers_guide`
- Why things are the way they are → {doc}`microarchitecture`
- SoC-level integration, simulation and FPGA flow of the *hatch* chip →
  hatch repository, `docs/` (published as GitLab Pages of the hatch project)
