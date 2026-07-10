// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// QSPI controller top level (see qspi_pkg for the register map). Two OBI
// subordinate ports:
//   * csr port : control/status registers, indirect mode (qspi_regs)
//   * mem port : memory-mapped window (qspi_mmap, active when CCR.FMODE=11)
//
// The single byte FIFO is shared; ownership follows CCR.FMODE:
//   indirect -> pushed/popped by DR accesses and the sequencer,
//   mmap     -> pushed by the sequencer (prefetch) / popped word-wise by mmap
//               (reads), staged by mmap and popped by the sequencer (writes).
//
// Pin interface: cs_n, sclk, sio 0..3 as separate in/out/oe bundles; the
// tri-state (or IOBUF/pad) lives strictly at the chip top level.

module qspi_top import spi_pkg::*; import qspi_pkg::*; #(
  parameter int unsigned FifoDepth = 32,
  parameter int unsigned ChipAddrW = 29
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  spi_obi_req_t obi_csr_req_i,
  output spi_obi_rsp_t obi_csr_rsp_o,

  input  spi_obi_req_t obi_mem_req_i,
  output spi_obi_rsp_t obi_mem_rsp_o,

  output logic         spi_cs_no,
  output logic         spi_sclk_o,
  output logic [3:0]   spi_sio_o,
  output logic [3:0]   spi_sio_oe,
  input  logic [3:0]   spi_sio_i
);

  // config
  logic       en;
  logic [7:0] presc;
  logic [2:0] csht;
  logic [4:0] fsize;
  ccr_t       ccr, wccr;
  logic       abort_sw;
  logic [31:0] abr;

  logic mmap_mode;
  assign mmap_mode = (ccr.fmode == FmMemMap);

  // command port arbitration
  qspi_job_t regs_job, mmap_job, job;
  logic regs_start, mmap_start, start;
  logic mmap_abort;
  logic seq_busy, tcf;

  assign job   = mmap_mode ? mmap_job   : regs_job;
  assign start = mmap_mode ? mmap_start : regs_start;

  // FIFO port muxing
  logic [2:0]  regs_push_cnt, mmap_push_cnt, seq_push_cnt;
  logic [31:0] regs_wdata,    mmap_wdata;
  logic [2:0]  regs_pop_cnt,  mmap_pop_cnt;
  logic        seq_tx_pop, seq_rx_push;
  logic [7:0]  seq_rx_data;
  logic [31:0] fifo_rdata;
  logic [5:0]  fifo_level, fifo_free;
  logic        mmap_flush;

  assign seq_push_cnt = seq_rx_push ? 3'd1 : 3'd0;

  logic [2:0]  push_cnt;
  logic [31:0] push_data;
  logic [2:0]  pop_cnt;
  always_comb begin
    // The sequencer pushes read bytes in both modes; DR (indirect) and the
    // mmap write staging are mutually exclusive with it by construction.
    push_cnt  = seq_push_cnt;
    push_data = {24'h0, seq_rx_data};
    if (mmap_mode) begin
      if (mmap_push_cnt != 3'd0) begin
        push_cnt  = mmap_push_cnt;
        push_data = mmap_wdata;
      end
      pop_cnt = seq_tx_pop ? 3'd1 : mmap_pop_cnt;
    end else begin
      if (regs_push_cnt != 3'd0) begin
        push_cnt  = regs_push_cnt;
        push_data = regs_wdata;
      end
      pop_cnt = seq_tx_pop ? 3'd1 : regs_pop_cnt;
    end
  end

  // Software abort (CR.ABORT) also empties the FIFO -- otherwise stale
  // prefetch bytes would be served to the next command.
  qspi_fifo #(
    .Depth (FifoDepth)
  ) i_fifo (
    .clk_i, .rst_ni,
    .flush_i    (mmap_flush || abort_sw),
    .push_cnt_i (push_cnt),
    .wdata_i    (push_data),
    .pop_cnt_i  (pop_cnt),
    .rdata_o    (fifo_rdata),
    .level_o    (fifo_level),
    .free_o     (fifo_free)
  );

  qspi_regs i_regs (
    .clk_i, .rst_ni,
    .obi_req_i       (obi_csr_req_i),
    .obi_rsp_o       (obi_csr_rsp_o),
    .en_o            (en),
    .presc_o         (presc),
    .csht_o          (csht),
    .fsize_o         (fsize),
    .ccr_o           (ccr),
    .wccr_o          (wccr),
    .abr_o           (abr),
    .abort_o         (abort_sw),
    .job_o           (regs_job),
    .start_o         (regs_start),
    .seq_busy_i      (seq_busy),
    .tcf_i           (tcf),
    .fifo_push_cnt_o (regs_push_cnt),
    .fifo_wdata_o    (regs_wdata),
    .fifo_pop_cnt_o  (regs_pop_cnt),
    .fifo_rdata_i    (fifo_rdata),
    .fifo_level_i    (fifo_level)
  );

  qspi_mmap #(
    .ChipAddrW (ChipAddrW)
  ) i_mmap (
    .clk_i, .rst_ni,
    .obi_req_i    (obi_mem_req_i),
    .obi_rsp_o    (obi_mem_rsp_o),
    .en_i         (en),
    .mmap_en_i    (mmap_mode),
    .ccr_i        (ccr),
    .wccr_i       (wccr),
    .abr_i        (abr),
    .fsize_i      (fsize),
    .job_o        (mmap_job),
    .start_o      (mmap_start),
    .abort_o      (mmap_abort),
    .seq_busy_i   (seq_busy),
    .flush_o      (mmap_flush),
    .push_cnt_o   (mmap_push_cnt),
    .push_data_o  (mmap_wdata),
    .pop_cnt_o    (mmap_pop_cnt),
    .fifo_rdata_i (fifo_rdata),
    .fifo_level_i (fifo_level)
  );

  qspi_cmd_seq i_seq (
    .clk_i, .rst_ni,
    .job_i       (job),
    .start_i     (start),
    .abort_i     (abort_sw || mmap_abort),
    .busy_o      (seq_busy),
    .tcf_o       (tcf),
    .presc_i     (presc),
    .csht_i      (csht),
    .tx_valid_i  (fifo_level != 6'd0),
    .tx_data_i   (fifo_rdata[7:0]),
    .tx_pop_o    (seq_tx_pop),
    .rx_push_o   (seq_rx_push),
    .rx_data_o   (seq_rx_data),
    .fifo_free_i (fifo_free),
    .cs_no       (spi_cs_no),
    .sck_o       (spi_sclk_o),
    .sio_o       (spi_sio_o),
    .sio_oe      (spi_sio_oe),
    .sio_i       (spi_sio_i)
  );

endmodule
