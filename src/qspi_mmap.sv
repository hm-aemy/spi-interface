// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Memory-mapped frontend (XIP): presents the external chip as normal memory.
// Reads ride an "unlimited" sequential read command (chip in sequential mode,
// CS held low) whose bytes land in the shared prefetch FIFO:
//   * sequential hit  -> word served straight from the FIFO (no SPI latency),
//   * address jump    -> abort stream, flush FIFO, start a new read command,
//   * write           -> abort stream, buffer the byte-enabled data in the
//                        FIFO, run one write command (frame format from WCCR),
//   * out-of-range / mmap disabled / WCCR.DMODE=0 on write -> OBI bus error.
//
// One outstanding OBI transaction (gnt held low while serving).

module qspi_mmap import spi_pkg::*; import qspi_pkg::*; #(
  parameter int unsigned ChipAddrW = 29   // window size = 2^ChipAddrW bytes
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  spi_obi_req_t obi_req_i,
  output spi_obi_rsp_t obi_rsp_o,

  // config from qspi_regs
  input  logic         en_i,        // CR.EN
  input  logic         mmap_en_i,   // CCR.FMODE == FmMemMap
  input  ccr_t         ccr_i,       // read frame format
  input  ccr_t         wccr_i,      // write frame format
  input  logic [31:0]  abr_i,       // alternate bytes (e.g. 0xEB mode byte)
  input  logic [4:0]   fsize_i,

  // command port to the sequencer (owned by mmap while CCR.FMODE=11)
  output qspi_job_t    job_o,
  output logic         start_o,     // pulse
  output logic         abort_o,     // level
  input  logic         seq_busy_i,

  // FIFO (owned by mmap while CCR.FMODE=11)
  output logic         flush_o,
  output logic [2:0]   push_cnt_o,  // write-data staging
  output logic [31:0]  push_data_o,
  output logic [2:0]   pop_cnt_o,
  input  logic [31:0]  fifo_rdata_i,
  input  logic [5:0]   fifo_level_i
);

  typedef enum logic [2:0] {
    MIdle, MAbort, MStartRd, MServe, MWrStage, MWrRun, MResp, MErr
  } state_e;

  state_e     state_q;
  logic [ChipAddrW-1:0]  head_q;       // chip address of the FIFO head byte
  logic                  stream_q;     // a prefetch stream is running & valid
  logic [ChipAddrW-1:0]  req_addr_q;   // word-aligned chip address of request
  logic [3:0]            rid_q;
  logic                  is_write_q;
  logic [31:0]           wdata_q;
  logic [3:0]            be_q;
  logic [31:0]           rdata_q;
  logic [1:0]            wait_q;

  logic [32:0] dev_size;
  assign dev_size = 33'd1 << (fsize_i + 5'd1);

  // Contiguous byte-enable decode (sb/sh/sw patterns): offset + length.
  function automatic logic [1:0] be_offset(input logic [3:0] be);
    if (be[0]) return 2'd0;
    if (be[1]) return 2'd1;
    if (be[2]) return 2'd2;
    return 2'd3;
  endfunction

  function automatic logic [2:0] be_len(input logic [3:0] be);
    return 3'(be[0]) + 3'(be[1]) + 3'(be[2]) + 3'(be[3]);
  endfunction

  function automatic logic be_contiguous(input logic [3:0] be);
    case (be)
      4'b0001, 4'b0010, 4'b0100, 4'b1000,
      4'b0011, 4'b0110, 4'b1100,
      4'b0111, 4'b1110, 4'b1111: return 1'b1;
      default:                   return 1'b0;
    endcase
  endfunction

  // Word-aligned chip address (byte enables select within the word).
  logic [ChipAddrW-1:0] chip_addr;
  assign chip_addr = {obi_req_i.a.addr[ChipAddrW-1:2], 2'b00};

  logic accept;
  assign accept = (state_q == MIdle) && obi_req_i.req;

  // Fault checks on the accepted request.
  logic fault;
  always_comb begin
    fault = !en_i || !mmap_en_i;
    if (33'(chip_addr) + 33'd3 >= dev_size) fault = 1'b1;
    if (obi_req_i.req && obi_req_i.a.we) begin
      if (wccr_i.dmode == PhSkip)          fault = 1'b1;
      if (!be_contiguous(obi_req_i.a.be))  fault = 1'b1;
    end
  end

  // Sequential hit: stream running and requested word starts at the head.
  logic hit;
  assign hit = stream_q && (chip_addr == head_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= MIdle;
      head_q      <= '0;
      stream_q    <= 1'b0;
      req_addr_q  <= '0;
      rid_q       <= '0;
      is_write_q  <= 1'b0;
      wdata_q     <= '0;
      be_q        <= '0;
      rdata_q     <= '0;
      wait_q      <= '0;
      start_o     <= 1'b0;
      flush_o     <= 1'b0;
      push_cnt_o  <= '0;
      push_data_o <= '0;
      pop_cnt_o   <= '0;
    end else begin
      start_o    <= 1'b0;
      flush_o    <= 1'b0;
      push_cnt_o <= '0;
      pop_cnt_o  <= '0;

      unique case (state_q)
        MIdle: begin
          if (accept) begin
            rid_q      <= obi_req_i.a.aid;
            req_addr_q <= chip_addr;
            is_write_q <= obi_req_i.a.we;
            wdata_q    <= obi_req_i.a.wdata;
            be_q       <= obi_req_i.a.be;
            if (fault) begin
              state_q <= MErr;
            end else if (obi_req_i.a.we) begin
              stream_q <= 1'b0;                    // write invalidates stream
              state_q  <= MAbort;
            end else if (hit) begin
              state_q <= MServe;
            end else begin
              stream_q <= 1'b0;
              state_q  <= MAbort;                  // jump: restart stream
            end
          end
        end

        // Tear down whatever the sequencer is doing, then flush the FIFO.
        MAbort: begin
          if (!seq_busy_i) begin
            flush_o <= 1'b1;
            state_q <= is_write_q ? MWrStage : MStartRd;
          end
        end

        MStartRd: begin
          start_o  <= 1'b1;
          head_q   <= req_addr_q;
          stream_q <= 1'b1;
          state_q  <= MServe;
        end

        // Wait until the word at the head is complete, then pop it. If the
        // stream died underneath us (e.g. software CR.ABORT while mmap was
        // still selected), restart it instead of hanging.
        MServe: begin
          if (fifo_level_i >= 6'd4) begin
            rdata_q   <= fifo_rdata_i;
            pop_cnt_o <= 3'd4;
            head_q    <= head_q + ChipAddrW'(4);
            state_q   <= MResp;
            wait_q    <= '0;
          end else if (wait_q != 2'd3) begin
            wait_q <= wait_q + 2'd1;
          end else if (!seq_busy_i && !start_o) begin
            stream_q <= 1'b0;
            wait_q   <= '0;
            state_q  <= MAbort;
          end
        end

        // Stage the write bytes in the (flushed) FIFO, then run the command.
        MWrStage: begin
          push_cnt_o  <= be_len(be_q);
          push_data_o <= wdata_q >> (8 * be_offset(be_q));
          start_o     <= 1'b1;
          state_q     <= MWrRun;
        end

        MWrRun: begin
          // start_o was just issued; wait for the command to finish.
          if (!seq_busy_i && !start_o) state_q <= MResp;
        end

        MResp:   state_q <= MIdle;
        MErr:    state_q <= MIdle;
        default: state_q <= MIdle;
      endcase
    end
  end

  // Job description. Reads: unlimited prefetch from the requested address.
  // Writes: WCCR frame, contiguous byte-enabled slice, data from the FIFO.
  always_comb begin
    job_o           = '0;
    if (is_write_q && state_q inside {MWrStage, MWrRun}) begin
      job_o.ccr       = wccr_i;
      job_o.ccr.fmode = FmIndWrite;
      job_o.addr      = 32'(req_addr_q) + 32'(be_offset(be_q));
      job_o.len_m1    = 32'(be_len(be_q)) - 32'd1;
      job_o.data_read = 1'b0;
      job_o.unlimited = 1'b0;
    end else begin
      job_o.ccr       = ccr_i;
      job_o.addr      = 32'(req_addr_q);
      job_o.len_m1    = '0;
      job_o.data_read = 1'b1;
      job_o.unlimited = 1'b1;
    end
    job_o.alt = abr_i;
  end

  // Abort the running prefetch stream whenever we need the sequencer idle.
  assign abort_o = (state_q == MAbort);

  always_comb begin
    obi_rsp_o              = '0;
    obi_rsp_o.gnt          = accept;
    obi_rsp_o.rvalid       = (state_q == MResp) || (state_q == MErr);
    obi_rsp_o.r.rdata      = rdata_q;
    obi_rsp_o.r.rid        = rid_q;
    obi_rsp_o.r.err        = (state_q == MErr);
    obi_rsp_o.r.r_optional = 1'b0;
  end

endmodule
