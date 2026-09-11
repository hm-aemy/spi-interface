// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// CSR file + indirect-mode command triggering (register map: see qspi_pkg).
// OBI subordinate: gnt is immediate, rvalid follows one cycle later (two for
// multi-byte DR accesses, which move their bytes through the byte FIFO first).
//
// DR semantics (indirect mode only):
//   write -> pushes the byte-enabled lanes (in address order) into the FIFO;
//            triggers the command when FMODE=00 & DMODE!=00 & !BUSY.
//   read  -> pops as many bytes as lanes are enabled, head byte to the lowest
//            enabled lane. Software must check SR.FLEVEL before reading.

module qspi_regs import spi_pkg::*; import qspi_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  spi_obi_req_t obi_req_i,
  output spi_obi_rsp_t obi_rsp_o,

  // static config out
  output logic         en_o,
  output logic [7:0]   presc_o,
  output logic [2:0]   csht_o,
  output logic [4:0]   fsize_o,
  output ccr_t         ccr_o,
  output ccr_t         wccr_o,
  output logic [31:0]  abr_o,
  output logic         abort_o,      // level, self-clears when !busy

  // command port (indirect mode)
  output qspi_job_t    job_o,
  output logic         start_o,      // pulse
  input  logic         seq_busy_i,
  input  logic         tcf_i,        // pulse from sequencer

  // FIFO access (only driven for DR transfers, muxed in qspi_top)
  output logic [2:0]   fifo_push_cnt_o,
  output logic [31:0]  fifo_wdata_o,
  output logic [2:0]   fifo_pop_cnt_o,
  input  logic [31:0]  fifo_rdata_i,
  input  logic [5:0]   fifo_level_i
);

  logic [31:0] cr_q, dcr_q, dlr_q, ar_q, abr_q;
  ccr_t        ccr_q, wccr_q;
  logic        tef_q, tcf_q;
  logic        abort_q;

  assign en_o    = cr_q[0];
  assign presc_o = cr_q[15:8];
  assign csht_o  = dcr_q[10:8];
  assign fsize_o = dcr_q[4:0];
  assign ccr_o   = ccr_q;
  assign wccr_o  = wccr_q;
  assign abr_o   = abr_q;
  assign abort_o = abort_q;

  // Device size in bytes (2^(FSIZE+1)), as 33-bit to cover 4 GiB.
  logic [32:0] dev_size;
  assign dev_size = 33'd1 << (dcr_q[4:0] + 5'd1);

  // ---------------------------------------------------------------------
  // OBI request decoding
  // ---------------------------------------------------------------------
  logic        req_valid;
  logic [7:0]  reg_off;
  assign reg_off = {obi_req_i.a.addr[7:2], 2'b00};

  // DR accesses stall one cycle while a previous DR pop/push is still being
  // applied to the FIFO (registered FIFO ports), so back-to-back DR accesses
  // always see the updated FIFO state.
  logic dr_hazard;
  assign req_valid = obi_req_i.req && !dr_hazard;

  // Number of enabled byte lanes and packed/unpacked lane views for DR.
  function automatic logic [2:0] be_count(input logic [3:0] be);
    return 3'(be[0]) + 3'(be[1]) + 3'(be[2]) + 3'(be[3]);
  endfunction

  // Pack the enabled wdata lanes into the low bytes (address order).
  function automatic logic [31:0] pack_lanes(input logic [31:0] w, input logic [3:0] be);
    logic [31:0] r;
    int unsigned k;
    r = '0;
    k = 0;
    for (int unsigned i = 0; i < 4; i++) begin
      if (be[i]) begin
        r[8*k +: 8] = w[8*i +: 8];
        k++;
      end
    end
    return r;
  endfunction

  // Spread the low bytes of `p` onto the enabled lanes (address order).
  function automatic logic [31:0] unpack_lanes(input logic [31:0] p, input logic [3:0] be);
    logic [31:0] r;
    int unsigned k;
    r = '0;
    k = 0;
    for (int unsigned i = 0; i < 4; i++) begin
      if (be[i]) begin
        r[8*i +: 8] = p[8*k +: 8];
        k++;
      end
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------
  // Command trigger conditions (evaluated on the accepted request cycle)
  // ---------------------------------------------------------------------
  logic wr_en;
  assign wr_en = req_valid && obi_req_i.a.we;

  ccr_t ccr_wr;
  assign ccr_wr = ccr_from_word(obi_req_i.a.wdata);

  logic trig_ccr, trig_ar, trig_dr;
  // CCR write, no address phase: instruction-only or instruction+read-data.
  assign trig_ccr = wr_en && (reg_off == QSPI_CCR) && !seq_busy_i && cr_q[0]
                    && (ccr_wr.admode == PhSkip) && (ccr_wr.fmode != FmMemMap)
                    && ((ccr_wr.fmode == FmIndRead) || (ccr_wr.dmode == PhSkip));
  // AR write with address phase: read commands or write commands without data.
  assign trig_ar  = wr_en && (reg_off == QSPI_AR) && !seq_busy_i && cr_q[0]
                    && (ccr_q.admode != PhSkip) && (ccr_q.fmode != FmMemMap)
                    && ((ccr_q.fmode == FmIndRead) || (ccr_q.dmode == PhSkip));
  // First DR write of an indirect write command with data phase.
  assign trig_dr  = wr_en && (reg_off == QSPI_DR) && !seq_busy_i && cr_q[0]
                    && (ccr_q.fmode == FmIndWrite) && (ccr_q.dmode != PhSkip);

  // Out-of-range check for commands with an address phase (TEF, no start).
  logic addr_fault;
  logic [32:0] last_byte;
  assign last_byte  = 33'(trig_ar ? obi_req_i.a.wdata : ar_q) + 33'(dlr_q);
  assign addr_fault = (last_byte >= dev_size);

  always_comb begin
    job_o           = '0;
    job_o.ccr       = ccr_q;
    job_o.addr      = ar_q;
    job_o.alt       = abr_q;
    job_o.len_m1    = (ccr_q.dmode == PhSkip) ? 32'd0 : dlr_q;
    job_o.data_read = (ccr_q.fmode == FmIndRead);
    job_o.unlimited = 1'b0;
    if (trig_ccr) begin
      job_o.ccr       = ccr_wr;
      job_o.len_m1    = (ccr_wr.dmode == PhSkip) ? 32'd0 : dlr_q;
      job_o.data_read = (ccr_wr.fmode == FmIndRead);
    end else if (trig_ar) begin
      job_o.addr = obi_req_i.a.wdata;
    end
  end

  // ---------------------------------------------------------------------
  // Register writes, flags, response channel
  // ---------------------------------------------------------------------
  logic        rvalid_q;
  logic [31:0] rdata_q;
  logic [3:0]  rid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cr_q     <= '0;
      dcr_q    <= 32'h0000_0010;   // FSIZE=16 -> 128 KiB (23LC1024 default)
      dlr_q    <= '0;
      ccr_q    <= '0;
      wccr_q   <= '0;
      ar_q     <= '0;
      abr_q    <= '0;
      tef_q    <= 1'b0;
      tcf_q    <= 1'b0;
      abort_q  <= 1'b0;
      start_o  <= 1'b0;
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
      rid_q    <= '0;
      fifo_push_cnt_o <= '0;
      fifo_wdata_o    <= '0;
      fifo_pop_cnt_o  <= '0;
    end else begin
      start_o         <= 1'b0;
      fifo_push_cnt_o <= '0;
      fifo_pop_cnt_o  <= '0;

      if (tcf_i)                  tcf_q   <= 1'b1;
      if (abort_q && !seq_busy_i) abort_q <= 1'b0;   // abort done

      // ---- register write / DR traffic ----
      if (wr_en) begin
        unique case (reg_off)
          QSPI_CR: begin
            cr_q <= {16'h0, obi_req_i.a.wdata[15:8], 6'h0, 1'b0, obi_req_i.a.wdata[0]};
            if (obi_req_i.a.wdata[1]) abort_q <= 1'b1;
          end
          QSPI_DCR:  dcr_q <= obi_req_i.a.wdata & 32'h0000_071F;
          QSPI_FCR: begin
            if (obi_req_i.a.wdata[0]) tef_q <= 1'b0;
            if (obi_req_i.a.wdata[1]) tcf_q <= 1'b0;
          end
          QSPI_DLR:  if (!seq_busy_i) dlr_q <= obi_req_i.a.wdata;
          QSPI_CCR:  if (!seq_busy_i) ccr_q <= ccr_wr;
          QSPI_AR:   if (!seq_busy_i) ar_q  <= obi_req_i.a.wdata;
          QSPI_ABR:  if (!seq_busy_i) abr_q <= obi_req_i.a.wdata;
          QSPI_WCCR: if (!seq_busy_i) wccr_q <= ccr_wr;
          QSPI_DR: begin
            fifo_push_cnt_o <= be_count(obi_req_i.a.be);
            fifo_wdata_o    <= pack_lanes(obi_req_i.a.wdata, obi_req_i.a.be);
          end
          default: ;
        endcase
      end

      // ---- command start ----
      // trig_ccr commands have no address phase -> nothing to range-check.
      if (trig_ccr) begin
        start_o <= 1'b1;
        tcf_q   <= 1'b0;
      end else if (trig_ar) begin
        if (addr_fault) tef_q <= 1'b1;                // out-of-range: no start
        else begin start_o <= 1'b1; tcf_q <= 1'b0; end
      end else if (trig_dr) begin
        if (ccr_q.admode != PhSkip && addr_fault) tef_q <= 1'b1;
        else begin start_o <= 1'b1; tcf_q <= 1'b0; end
      end

      // ---- read data path (registered response) ----
      rvalid_q <= req_valid;
      rid_q    <= obi_req_i.a.aid;
      if (req_valid && !obi_req_i.a.we) begin
        unique case (reg_off)
          QSPI_CR:   rdata_q <= cr_q;
          QSPI_DCR:  rdata_q <= dcr_q;
          QSPI_SR:   rdata_q <= {18'h0, fifo_level_i, 2'b00, seq_busy_i, 2'b00,
                                 1'b0, tcf_q, tef_q};
          QSPI_FCR:  rdata_q <= '0;
          QSPI_DLR:  rdata_q <= dlr_q;
          QSPI_CCR:  rdata_q <= ccr_to_word(ccr_q);
          QSPI_AR:   rdata_q <= ar_q;
          QSPI_ABR:  rdata_q <= abr_q;
          QSPI_WCCR: rdata_q <= ccr_to_word(wccr_q);
          QSPI_DR: begin
            rdata_q        <= unpack_lanes(fifo_rdata_i, obi_req_i.a.be);
            fifo_pop_cnt_o <= be_count(obi_req_i.a.be);
          end
          default:   rdata_q <= 32'h0;
        endcase
      end
    end
  end

  assign dr_hazard = (reg_off == QSPI_DR) &&
                     ((fifo_pop_cnt_o != 3'd0) || (fifo_push_cnt_o != 3'd0));

  always_comb begin
    obi_rsp_o              = '0;
    obi_rsp_o.gnt          = req_valid;
    obi_rsp_o.rvalid       = rvalid_q;
    obi_rsp_o.r.rdata      = rdata_q;
    obi_rsp_o.r.rid        = rid_q;
    obi_rsp_o.r.err        = 1'b0;
    obi_rsp_o.r.r_optional = 1'b0;
  end

endmodule
