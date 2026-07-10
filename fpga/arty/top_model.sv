// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Arty-A7 Board-A wrapper ("the memory") for the two-board bring-up: wires
// the SRAM slave to Pmod header JA so a second Arty board (top_master.sv or
// the full hatch SoC) can drive it over a real cable. See docs/fpga_tests.md
// for wiring + build steps.
//
// Pin roles on JA (see fpga/arty/arty_a7.xdc for the exact package pins):
//   JA1 = CS_n   (input,  driven by Board B)
//   JA2 = SCLK   (input,  driven by Board B)
//   JA3 = SIO0   (inout)
//   JA4 = SIO1   (inout)
//   JA7 = SIO2   (inout)
//   JA8 = SIO3   (inout)
//   JA9/JA10     (unused)
//
// -----------------------------------------------------------------------
// Tri-state discipline: the slave itself has NO inout -- it only has
// o/oe/i bundles. On real hardware the wiring is unidirectional anyway
// (IOBUF is non-functional in the nextpnr flow, see docs/known_issues.md),
// so the lanes are split into a2b and b2a pin groups below.
// -----------------------------------------------------------------------
// Memory size for the FPGA build: see the MEM_ADDR_BITS parameter added to
// model/s23lc1024.sv. `mem[]` is written on posedge sclk_i and read/driven
// on negedge sclk_i of the SAME clock -- yosys/Xilinx block-RAM inference
// generally wants one edge per port, so this pattern is expected to fall
// back to distributed LUTRAM. The real chip's full 128 KiB (MEM_ADDR_BITS
// default 17) would be a LOT of LUTRAM for an XC7A35T; we only need enough
// capacity to prove the protocol over a real cable, so this wrapper uses a
// much smaller window (default 4 KiB, MEM_ADDR_BITS=12). Addresses used by
// spi_test_master.sv (0x000100, 0x000200 plus 8 bytes) comfortably fit.
// Simulation (tb_arty_pair.sv, test/tb_s23lc1024.sv) keeps the model's
// default of 17 bits, so none of the existing testbenches change behaviour.
// -----------------------------------------------------------------------
module top_model #(
    parameter int unsigned MEM_ADDR_BITS = 10  // 1 KiB -- like top_loopback: with -nolutram this becomes FFs, 1 KiB keeps P&R fast
) (
    input  logic       clk100mhz,  // 100 MHz onboard oscillator (E3)
    input  logic       btn0,       // reset button (D9), active-high when pressed

    // Pmod JA towards Board B (the test master).
    input  logic       ja_cs_n,    // JA1
    input  logic       ja_sclk,    // JA2
    input  logic [3:0] pin_a2b,   // JA3 JA4 JA7 JA8: driven by the master (SIO0..3 command/write data)
    output logic [3:0] pin_b2a,   // JA9 JA10 JB1 JB2: driven by the slave (SIO0..3 read data)

    // Status LEDs (basic, single-colour -- see arty_a7.xdc for the mapping
    // of these logical names to the board's silkscreen LEDs).
    output logic       led4,       // heartbeat: blinks whenever the FPGA is
                                    // configured and this design is actually
                                    // running (not just held in reset)
    output logic       led5,       // activity: stretched pulse on any CS-low
                                    // transaction seen from Board B
    output logic       led6,       // reserved, tied off
    output logic       led7        // reserved, tied off
);

  // Wrapper-local reset. NOTE: the SRAM model itself has no reset input --
  // just like the real 23LC1024, which has no reset pin either (only a
  // power-on-reset). BTN0 only resets the bookkeeping counters below.
  logic rst_n;
  assign rst_n = ~btn0;

  // -----------------------------------------------------------------------
  // Tri-state at the single physical pin (see header comment).
  // -----------------------------------------------------------------------
  logic [3:0] sio_i, sio_o, sio_oe;

  // Unidirectional (no tri-state, see docs/known_issues.md): master lanes
  // are read-only, slave lanes always drive.
  assign sio_i   = pin_a2b;
  assign pin_b2a = sio_o;
  wire _unused_oe = &{1'b0, sio_oe};

  // -----------------------------------------------------------------------
  // SPI/SQI slave. NOT the async-CS behavioural model (model/s23lc1024.sv):
  // its `posedge cs_ni` constructs (clock + async reset at once) do not map
  // in the openXC7 flow -- on hardware the slave stayed in CS reset forever
  // (two-board bring-up 2026-07-08, verified via bus-spy + slave UART: sclk
  // edges arrived, bit_cnt/active stayed 0). Hence the fully synchronous
  // fpga_sram_slave, which oversamples cs/sclk/data with 100 MHz.
  // -----------------------------------------------------------------------
  fpga_sram_slave #(
      .MEM_ADDR_BITS (MEM_ADDR_BITS)
  ) u_model (
      .clk     (clk100mhz),
      .cs_n    (ja_cs_n),
      .sclk    (ja_sclk),
      .sio_in  (sio_i),
      .sio_out (sio_o),
      .sio_oe  (sio_oe)
  );

  // -----------------------------------------------------------------------
  // Heartbeat LED (LD4): a free-running counter on clk100mhz. If this LED
  // is not blinking, the FPGA is either not configured, stuck in reset, or
  // the bitstream did not make it onto the device -- nothing to do with the
  // SPI/SQI protocol itself, so this is the very first thing to check.
  // -----------------------------------------------------------------------
  logic [25:0] hb_cnt;
  always_ff @(posedge clk100mhz) begin
    if (!rst_n) hb_cnt <= '0;
    else        hb_cnt <= hb_cnt + 1'b1;
  end
  assign led4 = hb_cnt[25];  // ~0.75 Hz

  // -----------------------------------------------------------------------
  // Activity LED (LD5): stretches bus activity into visible pulses. SIO0 (a
  // pure data net) is used as the source instead of CS: nextpnr promotes
  // CS/SCLK to BUFG clocks (the slave FFs are clocked by them), and a BUFG
  // net cannot reach slice data pins (the synchroniser) any more -- routing
  // would fail otherwise ("Unrouteable ... BUFGCTRL -> DFFMUX").
  // -----------------------------------------------------------------------
  logic sio_sync0, sio_sync1;
  logic [23:0] act_cnt;

  always_ff @(posedge clk100mhz) begin
    if (!rst_n) begin
      sio_sync0 <= 1'b0;
      sio_sync1 <= 1'b0;
    end else begin
      sio_sync0 <= sio_i[0];
      sio_sync1 <= sio_sync0;
    end
  end

  always_ff @(posedge clk100mhz) begin
    if (!rst_n) act_cnt <= '0;
    else if (sio_sync1 != sio_sync0) act_cnt <= '1;
    else if (act_cnt != 0) act_cnt <= act_cnt - 1'b1;
  end
  assign led5 = (act_cnt != 0);

  assign led6 = 1'b0;
  assign led7 = 1'b0;

endmodule
