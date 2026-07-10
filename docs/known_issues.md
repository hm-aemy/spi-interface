# Known Issues & Bring-up Findings

Pitfalls encountered while verifying and bringing up this IP, kept out of
the regular guides on purpose. Each entry states the symptom, the cause and
the fix/workaround as applied in this repository. SoC-level findings
(linker script, UART baud rate, simulator flags of the hatch build) are
documented in the hatch repository's *Known issues* page instead.

## Simulation / testbench

### TB race at the OBI port (Verilator `--timing`)

Task code that drives stimulus with blocking assignments right after a
`@(posedge clk)` resumption executes *before* the FFs of the same time
step. Consequences: double acceptance of requests and missed one-cycle
`rvalid` pulses. **Rule (applied in `test/tb_qspi_top.sv`, to be adopted in
new TBs): drive stimulus on negedges only, and check `gnt` in the request
cycle after a `#1ps` settle.**

### Yosys `fsm` pass miscompiles certain FSMs

FSMs whose state register is written in two places of the same process
(`spi_test_master.sv`) were re-encoded incorrectly: RTL sim green, netlist
dead (stuck in `StIdle`). **Fix: `(* fsm_encoding = "none" *)` on the state
signals.** Diagnosis method that found it: post-synthesis simulation of the
yosys netlist with Verilator + `cells_sim.v` against the same TB (`prep`
netlist OK, `synth_xilinx` netlist broken → pass bisection).

## Synthesis / place & route (openXC7 flow)

### yosys needs the slang frontend

`read_verilog -sv` already fails on `parameter string INIT_FILE`. Use
`yosys -m slang` with `read_slang` (the OSS CAD Suite ships `slang.so`).

### nextpnr-xilinx XDC parser is a minimal subset

No `set_property -dict { ... }`, no whitespace inside `{ }`
(`[get_ports { x }]` → assertion `str.back() == '}'`), no `-waveform`.
One property per line, `[get_ports {x}]` without spaces.

### `create_clock` is effectively ignored

nextpnr-xilinx checks timing against its 12 MHz default and reports "PASS"
even if the design is slower than the board clock. **Read Fmax from the log
yourself** (`make check-fmax` in the Makefiles). The FPGA tops here run on
half the board clock (50 MHz) for that reason; the hatch SoC top runs at
20 MHz.

### LUTRAM (`RAM256X1S`) cannot be placed

nextpnr-xilinx fails on distributed-RAM primitives. Synthesise with
`-nolutram`; small memories then become FFs — keep model memories small
(`MEM_ADDR_BITS`, loopback uses 1 KiB).

### `IOBUF` / tri-state is non-functional

yosys' automatic `inout` lowering produces output-only buffers in this
flow (confirmed by an isolation test). **All board-to-board lanes are
therefore wired unidirectionally** (separate a2b/b2a pin groups, see
{doc}`fpga_tests`); nothing in the test setups relies on `z` states.

### Async-CS constructs do not map

`model/s23lc1024.sv` uses `posedge cs_ni` simultaneously as a clock
(bus-mode switch) and as an async reset of the shift FFs. On the FPGA this
forces CS onto a global clock buffer *and* a data mux — unroutable, or the
slave hangs in CS reset (proven via a bus-spy bitstream: SCK edges arrived,
`bit_cnt`/`active` stayed 0). **On hardware, use the fully synchronous
`fpga_sram_slave.sv`**, which oversamples cs/sclk/data with the board
clock. The behavioural model remains the simulation reference.

### Auto-start pulse lost at configuration

A start pulse fired in the first cycles after configuration is swallowed
by the GSR release. `top_loopback` waits ~10 ms (`BOOT_BITS`) before
starting.

### BUFG-promoted pins cannot reach slice data pins

nextpnr promotes CS/SCLK to BUFG clocks; a BUFG net cannot additionally
route to slice data inputs ("Unrouteable ... BUFGCTRL -> DFFMUX"). The
activity LED therefore synchronises SIO0 (a pure data net) instead of CS.

## Board / host

### `openFPGALoader: unable to open ftdi device`

udev rules for the Digilent FTDI (0403:6010) missing or not reloaded.
Install the rules (usually shipped with the package), re-plug the board,
verify with `openFPGALoader --scan-usb` without `sudo`.

### Debug methodology for dead links

A single dead data wire (here: SIO0) looks exactly like a logic bug —
CS/SCK/other lanes arrive, one lane shows zero edges. Before debugging
logic, load a small **bus-spy bitstream on the slave board** that counts
edges per lane and reports the decoded opcode over its own UART. It
separates "command does not arrive" from "response does not come back" and
finds broken jumper wires in minutes.
