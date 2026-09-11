// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// TB (Verilator) for the single-board loopback top (fpga/arty/top_loopback.sv):
// clocks the WHOLE synthesis top (master + model + UART reporter), decodes
// the UART status lines like the host will on real hardware and passes once
// a "PASS" line has been received. This verifies everything that goes into
// loopback.bit except place & route itself.
//
`timescale 1ns/1ps

module tb_loopback;

  localparam time TCLK = 10ns;

  // Sim-friendly parameters: status tick every 2^16 clk (~0.65 ms),
  // UART at Div = 100M/6.25M = 16 clk per bit.
  localparam int unsigned UART_BAUD = 6_250_000;
  localparam int unsigned UART_DIV  = 100_000_000 / UART_BAUD;

  logic clk = 1'b0;
  always #(TCLK/2) clk = ~clk;

  logic btn0, btn1, uart;
  logic led4, led5, led6, led7;
  logic [3:0] led_progress;

  top_loopback #(
    .SCK_HALF_PERIOD (50),
    .UART_BAUD       (UART_BAUD),
    .TICK_BITS       (16),
    .BOOT_BITS       (8)
  ) dut (
    .clk100mhz    (clk),
    .btn0         (btn0),
    .btn1         (btn1),
    .led4         (led4),
    .led5         (led5),
    .led6         (led6),
    .led7         (led7),
    .led_progress (led_progress),
    .uart_rxd_out (uart)
  );

  // ------------------------------------------------------------------------
  // UART receiver (8N1), assembles lines
  // ------------------------------------------------------------------------
  task automatic uart_recv_byte(output logic [7:0] b);
    @(negedge uart);                       // start bit
    #(TCLK * UART_DIV * 3 / 2);            // middle of data bit 0
    for (int i = 0; i < 8; i++) begin
      b[i] = uart;
      #(TCLK * UART_DIV);
    end
    if (uart !== 1'b1) $fatal(1, "UART framing error (stop bit)");
  endtask

  string line;

  initial begin
    $dumpfile("tb_loopback.fst");
    $dumpvars(0, tb_loopback);

    // Hardware-like: NO reset button press -- the design must start from
    // bitstream INIT values alone (this is exactly what a freshly
    // configured board sees; a TB-only reset press hid a real HW hang).
    btn0 = 1'b0;
    btn1 = 1'b0;

    line = "";
    forever begin
      logic [7:0] c;
      uart_recv_byte(c);
      if (c == 8'h0A) begin
        $display("[uart] %s", line);
        if (line.substr(0, 3) == "PASS") begin
          $display("TB PASSED");
          $finish;
        end
        if (line.substr(0, 3) == "FAIL")
          $fatal(1, "TB FAILED: loopback top reports %s", line);
        line = "";
      end else if (c != 8'h0D) begin
        line = {line, string'(c)};
      end
    end
  end

  // Watchdog: test sequence at 1 MHz SCK takes ~1 ms, ticks every 0.65 ms.
  initial begin
    #20_000_000;                           // 20 ms
    $fatal(1, "Timeout in tb_loopback");
  end

endmodule
