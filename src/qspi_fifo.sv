// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Byte FIFO with up-to-4-byte push/pop per cycle (needed because the 32-bit
// DR port and the memory-mapped frontend move whole words, while the serial
// side moves single bytes). Head byte = lowest chip address = rdata_o[7:0]
// (little-endian word assembly falls out of this for free).
//
// The caller must respect `level_o` / `free_o`: pushing more than free or
// popping more than level is ignored bytewise (saturating), never corrupting
// the pointers beyond the valid region.

// Depth must be a power of two (pointer wrap-around is implicit).
module qspi_fifo #(
  parameter int unsigned Depth = 32,
  localparam int unsigned LvlW = $clog2(Depth) + 1
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            flush_i,

  input  logic [2:0]      push_cnt_i,  // 0..4 bytes from wdata_i (byte 0 first)
  input  logic [31:0]     wdata_i,

  input  logic [2:0]      pop_cnt_i,   // 0..4 bytes; head is rdata_o[7:0]
  output logic [31:0]     rdata_o,

  output logic [LvlW-1:0] level_o,
  output logic [LvlW-1:0] free_o
);

  localparam int unsigned PtrW = $clog2(Depth);

  logic [7:0]      mem_q [Depth];
  logic [PtrW-1:0] rd_q, wr_q;
  logic [LvlW-1:0] lvl_q;

  // Effective counts, saturated against fill state.
  logic [2:0] push_n, pop_n;
  assign pop_n  = (LvlW'(pop_cnt_i)  > lvl_q) ? 3'(lvl_q) : pop_cnt_i;
  assign push_n = (LvlW'(push_cnt_i) > (LvlW'(Depth) - lvl_q + LvlW'(pop_n)))
                  ? 3'((LvlW'(Depth) - lvl_q + LvlW'(pop_n))) : push_cnt_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_q  <= '0;
      wr_q  <= '0;
      lvl_q <= '0;
    end else if (flush_i) begin
      rd_q  <= '0;
      wr_q  <= '0;
      lvl_q <= '0;
    end else begin
      // Manually unrolled: non-blocking assignments into an array inside a
      // for loop do not build with --unroll-count 1 (hatch system sim,
      // BLKLOOPINIT error).
      if (push_n > 3'd0) mem_q[wr_q + PtrW'(0)] <= wdata_i[7:0];
      if (push_n > 3'd1) mem_q[wr_q + PtrW'(1)] <= wdata_i[15:8];
      if (push_n > 3'd2) mem_q[wr_q + PtrW'(2)] <= wdata_i[23:16];
      if (push_n > 3'd3) mem_q[wr_q + PtrW'(3)] <= wdata_i[31:24];
      wr_q  <= wr_q + PtrW'(push_n);
      rd_q  <= rd_q + PtrW'(pop_n);
      lvl_q <= lvl_q + LvlW'(push_n) - LvlW'(pop_n);
    end
  end

  // Fall-through view of the next 4 bytes (valid bytes limited by level_o).
  always_comb begin
    for (int unsigned i = 0; i < 4; i++)
      rdata_o[8*i +: 8] = mem_q[rd_q + PtrW'(i)];
  end

  assign level_o = lvl_q;
  assign free_o  = LvlW'(Depth) - lvl_q;

endmodule
