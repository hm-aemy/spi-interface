// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Arty-A7 Board-B wrapper ("the tester") for the Phase-3 bring-up: wires the
// synthesizable spi_test_master core (fpga/arty/spi_test_master.sv, proven
// correct in simulation by fpga/arty/tb_arty_pair.sv) to Pmod header JA, so
// it can drive the s23lc1024 model running on Board A (top_model.sv) over a
// real cable. See docs/fpga_flow.md for wiring + build steps.
//
// Pin roles on JA (must match top_model.sv / arty_a7.xdc exactly, board A's
// JA1..JA8 wired straight to board B's JA1..JA8 with a common GND):
//   JA1 = CS_n   (output, driven by this board)
//   JA2 = SCLK   (output, driven by this board, ~1 MHz)
//   JA3 = SIO0   (inout)
//   JA4 = SIO1   (inout)
//   JA7 = SIO2   (inout)
//   JA8 = SIO3   (inout)
//   JA9/JA10     (unused)
//
// Buttons:
//   BTN0 = reset (this board's wrapper + the test-master core)
//   BTN1 = (re)start the test sequence
//
// LEDs:
//   LD4        = heartbeat (alive, same idiom as top_model.sv)
//   LD5        = PASS (steady on once done_o & pass_o)
//   LD6        = FAIL (steady on once done_o & ~pass_o)
//   LD7        = reserved, tied off
//   LD0..LD3   = progress (current/last transaction index, binary)
// -----------------------------------------------------------------------
module top_master #(
    parameter int unsigned SCK_HALF_PERIOD = 25  // 50 MHz / (2*25) = 1 MHz SCK
) (
    input  logic       clk100mhz,
    input  logic       btn0,        // reset, active-high when pressed
    input  logic       btn1,        // (re)start, active-high when pressed

    // Pmod JA towards Board A (the memory model).
    output logic       ja_cs_n,    // JA1
    output logic       ja_sclk,    // JA2
    inout  wire  [3:0] ja_sio,     // JA3, JA4, JA7, JA8 = SIO0..SIO3

    output logic       led4,        // heartbeat
    output logic       led5,        // PASS
    output logic       led6,        // FAIL
    output logic       led7,        // reserved, tied off
    output logic [3:0] led_progress // LD0..LD3
);

  // 100 MHz -> 50 MHz core clock. Lesson from the single-board loopback
  // bring-up (see top_loopback.sv / docs/14 §e): nextpnr-xilinx places this
  // design at ~81-90 MHz Fmax, so the raw 100 MHz board clock silently
  // breaks the FSM on real silicon while simulation stays green.
  logic clk_div_q = 1'b0;
  always_ff @(posedge clk100mhz) clk_div_q <= ~clk_div_q;
  wire clk_sys = clk_div_q;

  logic rst_n;
  assign rst_n = ~btn0;

  // -----------------------------------------------------------------------
  // BTN1 -> a single clean 1-cycle start pulse. A 2-FF synchronizer (BTN1 is
  // an asynchronous, unregistered pad input) followed by a rising-edge
  // detector. No debounce: a bouncing button can retrigger the sequence a
  // few extra times, which is harmless here (the sequence is idempotent --
  // it always opens with RSTIO, see spi_test_master.sv) and simply costs a
  // bit of extra run time. See docs/fpga_flow.md for the
  // real-hardware caveat.
  // -----------------------------------------------------------------------
  logic btn1_sync0, btn1_sync1, btn1_prev;
  logic start_pulse;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      btn1_sync0 <= 1'b0;
      btn1_sync1 <= 1'b0;
      btn1_prev  <= 1'b0;
    end else begin
      btn1_sync0 <= btn1;
      btn1_sync1 <= btn1_sync0;
      btn1_prev  <= btn1_sync1;
    end
  end
  assign start_pulse = btn1_sync1 & ~btn1_prev;

  // -----------------------------------------------------------------------
  // Tri-state at the single physical pin (same discipline as top_model.sv
  // and model/s23lc1024.sv: the core only ever drives o/oe, never the pin).
  // -----------------------------------------------------------------------
  logic [3:0] sio_i, sio_o, sio_oe;

  assign sio_i = ja_sio;
  for (genvar i = 0; i < 4; i++) begin : g_tristate
    assign ja_sio[i] = sio_oe[i] ? sio_o[i] : 1'bz;
  end

  logic       done, pass;
  logic [3:0] progress;

  spi_test_master #(
      .SCK_HALF_PERIOD (SCK_HALF_PERIOD)
  ) u_master (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .start_i    (start_pulse),
      .cs_no      (ja_cs_n),
      .sclk_o     (ja_sclk),
      .sio_i      (sio_i),
      .sio_o      (sio_o),
      .sio_oe     (sio_oe),
      .done_o     (done),
      .pass_o     (pass),
      .progress_o (progress)
  );

  // -----------------------------------------------------------------------
  // Heartbeat LED (LD4) -- same idiom as top_model.sv: if this is not
  // blinking, the bitstream problem is on this board, not in the protocol.
  // -----------------------------------------------------------------------
  logic [25:0] hb_cnt;
  always_ff @(posedge clk_sys) begin
    if (!rst_n) hb_cnt <= '0;
    else        hb_cnt <= hb_cnt + 1'b1;
  end
  assign led4 = hb_cnt[25];

  assign led5         = done & pass;
  assign led6         = done & ~pass;
  assign led7         = 1'b0;
  assign led_progress = progress;

endmodule
