// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Arty-A7 Board-B wrapper ("the memory"), Vivado flow. Identical role to
// fpga/arty/top_model.sv (drives fpga_sram_slave.sv onto Pmod JA for the
// two-board bring-up) except SIO0..3 are one real bidirectional bus
// (ja_sio[3:0]) instead of split pin_a2b/pin_b2a groups -- the mirror image
// of hatch's fpga/vivado/top_hatch_arty.sv, for the same reason: yosys'
// automatic inout lowering is output-only under nextpnr-xilinx (see
// docs/known_issues.md), Vivado's synthesis handles real tri-state natively.
// The two Vivado tops together need only 6 wires between the boards
// (CS_n, SCLK, SIO0..3 + GND) instead of the open-source flow's 10.
//
// Pin roles on JA (see arty_a7.xdc for the exact package pins):
//   JA1 = CS_n   (input,  driven by Board A / the hatch SoC)
//   JA2 = SCLK   (input,  driven by Board A)
//   JA3 = SIO0   (inout)
//   JA4 = SIO1   (inout)
//   JA7 = SIO2   (inout)
//   JA8 = SIO3   (inout)
//
// Memory size: MEM_ADDR_BITS=12 (4 KiB) to match FSIZE_4K in
// software/fpgatest/main.c (hatch repo) -- NOT the 1 KiB default used by
// this repo's own standalone master/model test (spi_test_master.sv only
// ever touches a couple of addresses; hatch's fpgatest exercises the
// prefetch test up to offset 0x43F and expects the TEF boundary at 0x1000).
module top_model #(
    parameter int unsigned MEM_ADDR_BITS = 12
) (
    input  logic       clk100mhz,  // 100 MHz onboard oscillator (E3)
    input  logic       btn0,       // reset button (D9), active-high when pressed

    // Pmod JA towards Board A (hatch SoC / the master).
    input  logic       ja_cs_n,    // JA1
    input  logic       ja_sclk,    // JA2
    inout  wire  [3:0] ja_sio,     // JA3 JA4 JA7 JA8, real bidirectional bus

    // Status LEDs (basic, single-colour -- see arty_a7.xdc for the mapping
    // of these logical names to the board's silkscreen LEDs).
    output logic       led4,       // heartbeat: blinks whenever the FPGA is
                                    // configured and this design is actually
                                    // running (not just held in reset)
    output logic       led5,       // activity: stretched pulse on any CS-low
                                    // transaction seen from Board A
    output logic       led6,       // reserved, tied off
    output logic       led7        // reserved, tied off
);

  // Wrapper-local reset. NOTE: the SRAM model itself has no reset input --
  // just like the real 23LC1024, which has no reset pin either (only a
  // power-on-reset). BTN0 only resets the bookkeeping counters below.
  logic rst_n;
  assign rst_n = ~btn0;

  // -----------------------------------------------------------------------
  // Real per-lane tri-state at the physical pin -- this is the part the
  // open-source flow cannot do (see docs/known_issues.md: IOBUF is
  // non-functional under nextpnr-xilinx).
  // -----------------------------------------------------------------------
  logic [3:0] sio_i, sio_o, sio_oe;

  for (genvar i = 0; i < 4; i++) begin : gen_sio_pad
    assign ja_sio[i] = sio_oe[i] ? sio_o[i] : 1'bz;
  end
  assign sio_i = ja_sio;

  // -----------------------------------------------------------------------
  // SPI/SQI slave. NOT the async-CS behavioural model (model/s23lc1024.sv):
  // its `posedge cs_ni` constructs (clock + async reset at once) are why
  // fpga_sram_slave.sv exists in the first place (see its header) -- reused
  // unchanged here rather than risking that construct on a second, untested
  // flow when the whole point of this file is only the pad-level wiring.
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
  // Heartbeat LED (LD4): a free-running counter on clk100mhz.
  // -----------------------------------------------------------------------
  logic [25:0] hb_cnt;
  always_ff @(posedge clk100mhz) begin
    if (!rst_n) hb_cnt <= '0;
    else        hb_cnt <= hb_cnt + 1'b1;
  end
  assign led4 = hb_cnt[25];  // ~0.75 Hz

  // -----------------------------------------------------------------------
  // Activity LED (LD5): stretches bus activity into visible pulses, sourced
  // from SIO0 (a pure data net) rather than CS/SCLK -- avoids the BUFG
  // vs. data-mux routing issue noted for the open-source flow (harmless
  // here under Vivado, kept for consistency with fpga/arty/top_model.sv).
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
