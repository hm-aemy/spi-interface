// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Minimal UART transmitter, 8N1, parameterised baud divider. Feeds the Arty
// USB-UART (FT2232 channel B) so a host can verify the loopback test result
// without looking at LEDs.

module uart_tx #(
  parameter int unsigned ClkFreqHz = 100_000_000,
  parameter int unsigned Baud      = 115_200,
  localparam int unsigned Div      = ClkFreqHz / Baud
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       valid_i,     // byte request (held until ready_o)
  input  logic [7:0] data_i,
  output logic       ready_o,
  output logic       tx_o
);

  logic [$clog2(Div)-1:0] baud_q;
  logic [3:0]             bit_q;    // 0 idle, 1 start, 2..9 data, 10 stop
  logic [7:0]             sh_q;

  assign ready_o = (bit_q == 4'd0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      baud_q <= '0;
      bit_q  <= '0;
      sh_q   <= '0;
      tx_o   <= 1'b1;
    end else if (bit_q == 4'd0) begin
      tx_o   <= 1'b1;
      baud_q <= '0;
      if (valid_i) begin
        sh_q  <= data_i;
        bit_q <= 4'd1;
        tx_o  <= 1'b0;             // start bit
      end
    end else if (baud_q == $clog2(Div)'(Div - 1)) begin
      baud_q <= '0;
      if (bit_q == 4'd10) begin
        bit_q <= 4'd0;             // stop bit done
      end else begin
        bit_q <= bit_q + 4'd1;
        if (bit_q == 4'd9) tx_o <= 1'b1;               // stop bit
        else begin tx_o <= sh_q[0]; sh_q <= sh_q >> 1; end // LSB first
      end
    end else begin
      baud_q <= baud_q + 1'b1;
    end
  end

endmodule
