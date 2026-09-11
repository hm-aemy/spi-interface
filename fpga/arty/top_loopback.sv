// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Single-board variant of the Phase-3 bring-up: spi_test_master AND the
// s23lc1024 model on the SAME Arty A7, wired together internally (no Pmod
// cable). First hardware smoke test before the two-board setup -- it proves
// synthesis, timing and the protocol logic on real silicon, everything
// except the physical inter-board wiring.
//
// Unlike top_master.sv it starts the test sequence automatically after
// configuration and reports the result over the USB-UART (FT2232 channel B,
// /dev/ttyUSBx on the host, 115200 8N1) every ~0.7 s:
//
//   "RUN. <p>\r\n"   test still running   (<p> = progress index, hex)
//   "PASS <p>\r\n"   all checks passed
//   "FAIL <p>\r\n"   mismatch in transaction <p>
//
//   LD4 heartbeat · LD5 PASS · LD6 FAIL · LD0..3 progress
//   BTN0 reset    · BTN1 restart test
//
// The tick interval, UART baud divider and SCK divider are parameters so
// the Verilator TB (test/tb_loopback.sv) can shrink them to simulation-
// friendly values while the synthesis defaults stay hardware-sane.
//
// CLOCKING (hardware lesson learnt): the whole core runs on an internal
// 50 MHz clock (100 MHz board clock / 2). nextpnr-xilinx placed this design
// at ~81-90 MHz Fmax -- at the raw 100 MHz board clock the master FSM
// misbehaves on real silicon while simulation (which knows no timing) is
// green. Halving the clock buys >30% margin and costs nothing here.

module top_loopback #(
    parameter int unsigned SCK_HALF_PERIOD = 25,           // 1 MHz SCK @ 50 MHz
    parameter int unsigned UART_BAUD       = 115_200,
    parameter int unsigned TICK_BITS       = 25,            // ~0.7 s @ 50 MHz
    parameter int unsigned BOOT_BITS       = 19             // ~10 ms auto-start delay
) (
    input  logic       clk100mhz,
    input  logic       btn0,          // reset, active-high when pressed
    input  logic       btn1,          // restart test
    output logic       led4,          // heartbeat
    output logic       led5,          // PASS
    output logic       led6,          // FAIL
    output logic       led7,          // running
    output logic [3:0] led_progress,  // LD0..LD3
    output logic       uart_rxd_out   // FPGA -> host (Arty net name)
);

  // 100 MHz -> 50 MHz core clock (nextpnr routes fabric clocks via BUFG).
  logic clk_div_q = 1'b0;
  always_ff @(posedge clk100mhz) clk_div_q <= ~clk_div_q;
  wire clk_sys = clk_div_q;

  logic rst_n;
  assign rst_n = ~btn0;

  // -----------------------------------------------------------------------
  // Start pulse: once automatically ~10 ms after configuration/reset, again
  // on BTN1 (2-FF sync + edge detect, same idiom as top_master.sv).
  //
  // WHY the delay (hardware lesson learnt): a start pulse in the very FIRST
  // clock cycle after configuration is lost on real silicon -- right at GSR
  // release the FSM is not reliably listening yet, and the board then sits
  // in StIdle forever ("RUN. 0" on the UART). Waiting a few milliseconds
  // costs nothing and makes the auto-start robust. In simulation BOOT_BITS
  // is shrunk so the TB does not have to sit through the delay.
  // -----------------------------------------------------------------------
  logic btn1_sync0, btn1_sync1, btn1_prev;
  logic [BOOT_BITS-1:0] boot_q;
  logic start_pulse;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      btn1_sync0 <= 1'b0;
      btn1_sync1 <= 1'b0;
      btn1_prev  <= 1'b0;
      boot_q     <= '0;
    end else begin
      btn1_sync0 <= btn1;
      btn1_sync1 <= btn1_sync0;
      btn1_prev  <= btn1_sync1;
      if (!(&boot_q)) boot_q <= boot_q + 1'b1;
    end
  end
  assign start_pulse = (boot_q == {BOOT_BITS{1'b1}} - 1'b1)   // one cycle
                     | (btn1_sync1 & ~btn1_prev);

  // -----------------------------------------------------------------------
  // Master + model, internally wired: priority mux instead of a pad
  // tri-state (master and model never drive simultaneously; same discipline
  // as the testbenches).
  // -----------------------------------------------------------------------
  logic       cs_n, sclk;
  logic [3:0] m_o, m_oe, s_o, s_oe, sio_bus;
  logic       done, pass;
  logic [3:0] progress;

  always_comb begin
    for (int i = 0; i < 4; i++)
      sio_bus[i] = m_oe[i] ? m_o[i] : (s_oe[i] ? s_o[i] : 1'b0);
  end

  spi_test_master #(
      .SCK_HALF_PERIOD (SCK_HALF_PERIOD)
  ) u_master (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .start_i    (start_pulse),
      .cs_no      (cs_n),
      .sclk_o     (sclk),
      .sio_i      (sio_bus),
      .sio_o      (m_o),
      .sio_oe     (m_oe),
      .done_o     (done),
      .pass_o     (pass),
      .progress_o (progress)
  );

  // Shrunk memory (1 KiB) so the dual-edge array maps to LUTRAM/BRAM
  // comfortably; the test only touches addresses 0x100/0x200.
  s23lc1024 #(
      .INIT_FILE     (""),
      .MEM_ADDR_BITS (10)
  ) u_model (
      .cs_ni  (cs_n),
      .sclk_i (sclk),
      .sio_i  (sio_bus),
      .sio_o  (s_o),
      .sio_oe (s_oe)
  );

  // -----------------------------------------------------------------------
  // LEDs
  // -----------------------------------------------------------------------
  logic [25:0] hb_cnt;
  always_ff @(posedge clk_sys) begin
    if (!rst_n) hb_cnt <= '0;
    else        hb_cnt <= hb_cnt + 1'b1;
  end
  assign led4         = hb_cnt[25];
  assign led5         = done & pass;
  assign led6         = done & ~pass;
  assign led7         = ~done;
  assign led_progress = progress;

  // -----------------------------------------------------------------------
  // UART status reporter: one 8-char line per tick
  // -----------------------------------------------------------------------
  logic       tx_valid, tx_ready;
  logic [7:0] tx_data;

  uart_tx #(
      .ClkFreqHz (50_000_000),
      .Baud      (UART_BAUD)
  ) u_uart (
      .clk_i   (clk_sys),
      .rst_ni  (rst_n),
      .valid_i (tx_valid),
      .data_i  (tx_data),
      .ready_o (tx_ready),
      .tx_o    (uart_rxd_out)
  );

  function automatic logic [7:0] hex_char(input logic [3:0] v);
    return (v < 4'd10) ? (8'h30 + 8'(v)) : (8'h37 + 8'(v));   // 0-9, A-F
  endfunction

  function automatic logic [7:0] msg_char(input logic d, input logic p,
                                          input logic [3:0] prog,
                                          input logic [2:0] idx);
    unique case (idx)
      3'd0:    return d ? (p ? 8'h50 : 8'h46) : 8'h52;        // P / F / R
      3'd1:    return d ? 8'h41 : 8'h55;                      // A / U
      3'd2:    return d ? (p ? 8'h53 : 8'h49) : 8'h4E;        // S / I / N
      3'd3:    return d ? (p ? 8'h53 : 8'h4C) : 8'h2E;        // S / L / .
      3'd4:    return 8'h20;                                  // space
      3'd5:    return hex_char(prog);
      3'd6:    return 8'h0D;                                  // \r
      default: return 8'h0A;                                  // \n
    endcase
  endfunction

  logic [TICK_BITS-1:0] tick_q;
  logic [2:0]           idx_q;
  logic                 sending_q;

  always_ff @(posedge clk_sys) begin
    if (!rst_n) begin
      tick_q    <= '0;
      idx_q     <= '0;
      sending_q <= 1'b0;
      tx_valid  <= 1'b0;
      tx_data   <= '0;
    end else begin
      tick_q <= tick_q + 1'b1;
      if (!sending_q) begin
        tx_valid <= 1'b0;
        if (tick_q == '0) begin
          sending_q <= 1'b1;
          idx_q     <= '0;
        end
      end else if (!tx_valid) begin
        tx_data  <= msg_char(done, pass, progress, idx_q);
        tx_valid <= 1'b1;
      end else if (tx_ready && tx_valid) begin
        tx_valid <= 1'b0;                       // byte accepted this edge
        if (idx_q == 3'd7) sending_q <= 1'b0;
        else               idx_q     <= idx_q + 3'd1;
      end
    end
  end

endmodule
