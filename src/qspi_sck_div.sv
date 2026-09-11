// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// SCK prescaler: emits a single-cycle `tick_o` every (presc_i+1) clk cycles.
// One tick = half an SCK period, so SCK = clk / (2*(presc_i+1)).
// The counter only runs while `run_i` is high and restarts from zero when it
// rises, so the first half-period after enabling has full length.

module qspi_sck_div (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       run_i,
  input  logic [7:0] presc_i,
  output logic       tick_o
);

  logic [7:0] cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_q <= '0;
    end else if (!run_i) begin
      cnt_q <= '0;
    end else if (cnt_q == presc_i) begin
      cnt_q <= '0;
    end else begin
      cnt_q <= cnt_q + 8'd1;
    end
  end

  assign tick_o = run_i && (cnt_q == presc_i);

endmodule
