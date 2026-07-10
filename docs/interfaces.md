# Interface Specification

## Port list (`qspi_top`)

### Clock/reset

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk_i` | in | 1 | system clock (all logic, including SCK generation) |
| `rst_ni` | in | 1 | asynchronous reset, active low |

### OBI subordinate ports

Two identical OBI ports (types `spi_obi_req_t`/`spi_obi_rsp_t` from
`spi_pkg.sv`, 32-bit address/data, 4-bit ID):

| Port | Window (hatch) | Function |
|---|---|---|
| `obi_csr_req_i` / `obi_csr_rsp_o` | `0x2000_0000 – 0x2000_0FFF` | registers (indirect mode) |
| `obi_mem_req_i` / `obi_mem_rsp_o` | `0x4000_0000 – 0x5FFF_FFFF` | memory-mapped window |

### Serial side (QSPI)

| Signal | Direction | Width | Description |
|---|---|---|---|
| `spi_cs_no` | out | 1 | chip select, active low |
| `spi_sclk_o` | out | 1 | serial clock, mode 0 (idles low), max. `clk_i`/4 |
| `spi_sio_o` | out | 4 | drive values of lanes SIO0…3 |
| `spi_sio_oe` | out | 4 | output enable per lane (1 = drive) |
| `spi_sio_i` | in | 4 | sampled lane values |

Lane assignment: single-SPI transmits on SIO0 (MOSI) and receives on SIO1
(MISO); dual uses SIO1:0, quad SIO3:0 (MSB on the highest lane). The
tri-state belongs at the pad/chip top:
`assign pad[i] = oe[i] ? o[i] : 1'bz;`.

## OBI protocol (subset used)

Single-beat OBI: request channel with `req`/`gnt`, response channel with
`rvalid` (no `rready` — the response is valid for exactly one cycle). `gnt`
is combinational; a transfer happens on every clock edge with `req && gnt`.
The CSR port responds in the following cycle; DR accesses may delay `gnt` by
one cycle (FIFO hazard, see below). The MEM port withholds `gnt` while a
transaction is in flight (single outstanding) and responds after the
transfer ends — on errors (FSIZE, mmap off, `WCCR.DMODE=0`) with `err=1`.

CSR read (response one cycle later):

```{wavedrom}
{ "signal": [
  {"name": "clk",     "wave": "p......"},
  {"name": "req",     "wave": "01.0...", "node": ".a"},
  {"name": "addr",    "wave": "x=.x...", "data": ["SR"]},
  {"name": "gnt",     "wave": "01.0..."},
  {"name": "rvalid",  "wave": "0.10...", "node": "..b"},
  {"name": "rdata",   "wave": "x.=x...", "data": ["SR value"]}
],
  "edge": ["a~>b response 1 cycle later"],
  "config": {"hscale": 2}
}
```

mmap read with prefetch hit vs. demand read (schematic):

```{wavedrom}
{ "signal": [
  {"name": "clk",    "wave": "p........."},
  {"name": "req",    "wave": "01.0.1...0"},
  {"name": "addr",   "wave": "x=.x.=...x", "data": ["A (hit)", "B (jump)"]},
  {"name": "gnt",    "wave": "01.0.1...0"},
  {"name": "rvalid", "wave": "0..10....1", "node": "...h.....d"},
  {"name": "BUSY",   "wave": "1........."}
],
  "edge": ["h FIFO hit: a few cycles", "d jump: abort+flush+SPI latency"],
  "config": {"hscale": 2}
}
```

Byte enables: reads always return the full word (`be` ignored); writes
evaluate `be` — the MEM port only accepts **contiguous** patterns
(`sb`/`sh`/`sw`), otherwise `err`. At the DR register, `be` selects the
transfer width (1/2/4 bytes).

## SPI timing (mode 0)

The controller drives outputs on the **falling** and samples inputs on the
**rising** SCK edge; the device mirrors this. SCK idles low (`CKMODE=0`).
CS goes low half an SCK period before the first edge and high again after
the last edge; `DCR.CSHT` then enforces a minimum CS-high time.

Single-SPI frame, instruction phase (MSB first):

```{wavedrom}
{ "signal": [
  {"name": "cs_n",  "wave": "10........|1"},
  {"name": "sclk",  "wave": "0.10101010|0"},
  {"name": "sio0",  "wave": "x=.=.=.=.x|x", "data": ["i7","i6","i5","i4"]},
  {"name": "oe[0]", "wave": "01........|0"}
],
  "config": {"hscale": 1},
  "head": {"text": "master drives on the falling edge, device samples on the rising edge"}
}
```

SQI read (23LC1024 profile): instruction + address quad from the master,
then **2 dummy clocks** (bus turnaround, all lanes high-Z), then data quad
from the device:

```{wavedrom}
{ "signal": [
  {"name": "cs_n",      "wave": "10..........|.1"},
  {"name": "sclk",      "wave": "0.1010101010|10"},
  {"name": "sio[3:0]",  "wave": "x=.=.=.=.z.z=.=", "data": ["op hi","op lo","a..","a..","d hi","d lo"]},
  {"name": "oe[3:0]",   "wave": "0=.......0..|..", "data": ["F"]},
  {"name": "Phase",     "wave": "x=...=...=..=..", "data": ["INSTR","ADDR","DUMMY","DATA"]}
],
  "config": {"hscale": 1}
}
```

SCK may **pause** between two bytes (CS stays low) — static SPI slaves only
react to edges. The controller uses this for FIFO backpressure and
TX-underrun stalls; visible on the bus as SCK gaps within a frame. This is
protocol-legal for both target chips.

## Configuration limits

| Parameter | Value | Note |
|---|---|---|
| SCK | `clk / (2·(PRESCALER+1))`, max. `clk/4` | one clock domain, no CDC |
| FIFO | 32 bytes (parameter `FifoDepth`, power of two) | doubles as prefetch buffer |
| Address space | `ChipAddrW` = 29 bit (512 MiB window) | FSIZE limits effectively |
| Dummy | 0–31 SCK clocks (`CCR.DCYC`) | |
| Address | 1–4 bytes (`CCR.ADSIZE`) | both target chips: 3 |
