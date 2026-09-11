// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Phase FSM: executes one qspi_job_t as the programmable frame
//   [INSTR] [ADDR] [ALT] [DUMMY] [DATA]
// where each phase is skipped when its *MODE field is PhSkip (dummy: DCYC=0).
// Data moves byte-wise through the shared FIFO:
//   * write data: popped from the FIFO head (stalls with SCK idle when empty),
//   * read data:  pushed on completion of each byte; backpressure per plan:
//     when the FIFO runs full the transfer pauses and resumes only once at
//     least 4 bytes are free again (hysteresis).
// SCK pauses between bytes are protocol-legal (static-logic slaves, CS held).
//
// `abort_i` (level) finishes the byte in flight, raises CS and honours CSHT.
// Jobs with `unlimited` set (memory-mapped prefetch) read until abort.

module qspi_cmd_seq import qspi_pkg::*; (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  qspi_job_t  job_i,
  input  logic       start_i,      // pulse, only when !busy_o
  input  logic       abort_i,      // level
  output logic       busy_o,
  output logic       tcf_o,        // pulse: all len_m1+1 data bytes done

  input  logic [7:0] presc_i,
  input  logic [2:0] csht_i,       // min CS-high time in SCK cycles

  // FIFO, TX side (data-phase writes)
  input  logic       tx_valid_i,
  input  logic [7:0] tx_data_i,
  output logic       tx_pop_o,
  // FIFO, RX side (data-phase reads)
  output logic       rx_push_o,
  output logic [7:0] rx_data_o,
  input  logic [5:0] fifo_free_i,

  output logic       cs_no,
  output logic       sck_o,
  output logic [3:0] sio_o,
  output logic [3:0] sio_oe,
  input  logic [3:0] sio_i
);

  typedef enum logic [3:0] {
    StIdle, StCsLow, StInstr, StAddr, StAlt, StDummy, StData, StCsHold, StCsht
  } state_e;

  state_e     state_q;
  qspi_job_t   job_q;
  logic [31:0] mbuf_q;      // MSB-first byte buffer for ADDR/ALT phases
  logic [2:0]  pbytes_q;    // bytes left in ADDR/ALT phase
  logic [31:0] dbytes_q;    // data bytes left
  logic        stalled_q;   // read backpressure hysteresis
  logic        sh_start_q;  // registered start pulse to the shift unit

  logic        sh_busy, sh_done, tick;
  logic [7:0]  sh_rx;
  logic [1:0]  sh_ln2_q;
  logic        sh_dir_q, sh_dummy_q;
  logic [4:0]  sh_cyc_q;
  logic [7:0]  sh_tx_q;
  logic        sh_release;
  logic [3:0]  hold_q;      // tick counter for CsLow/CsHold/Csht

  qspi_sck_div i_div (
    .clk_i, .rst_ni,
    .run_i   (state_q != StIdle),
    .presc_i (presc_i),
    .tick_o  (tick)
  );

  qspi_shift i_shift (
    .clk_i, .rst_ni,
    .tick_i      (tick),
    .start_i     (sh_start_q),
    .tx_i        (sh_tx_q),
    .lanes_ln2_i (sh_ln2_q),
    .dir_out_i   (sh_dir_q),
    .dummy_i     (sh_dummy_q),
    .cycles_i    (sh_cyc_q),
    .release_i   (sh_release),
    .busy_o      (sh_busy),
    .done_o      (sh_done),
    .rx_o        (sh_rx),
    .sck_o, .sio_o, .sio_oe, .sio_i
  );

  // A new shift op may be issued when the unit is idle and no start is pending.
  logic sh_idle;
  assign sh_idle    = !sh_busy && !sh_start_q;
  assign sh_release = (state_q == StCsHold) || (state_q == StCsht) || (state_q == StIdle);

  // Read backpressure: pause when full, resume at >= 4 bytes free. The
  // non-stalled threshold is 2 because one completed byte may still be on its
  // way into the FIFO (registered push) when the next byte is issued.
  logic rx_room;
  assign rx_room = stalled_q ? (fifo_free_i >= 6'd4) : (fifo_free_i >= 6'd2);

  logic [7:0] rx_byte_q;   // completed read byte, stable while being pushed
  assign rx_data_o = rx_byte_q;

  // First byte of the next multi-byte phase, left-aligned (MSByte first).
  function automatic logic [31:0] left_align(input logic [31:0] v, input logic [1:0] size);
    return v << (8 * (2'd3 - size));
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= StIdle;
      job_q      <= '0;
      mbuf_q     <= '0;
      pbytes_q   <= '0;
      dbytes_q   <= '0;
      stalled_q  <= 1'b0;
      sh_start_q <= 1'b0;
      sh_ln2_q   <= '0;
      sh_dir_q   <= 1'b0;
      sh_dummy_q <= 1'b0;
      sh_cyc_q   <= '0;
      sh_tx_q    <= '0;
      hold_q     <= '0;
      cs_no      <= 1'b1;
      tcf_o      <= 1'b0;
      tx_pop_o   <= 1'b0;
      rx_push_o  <= 1'b0;
      rx_byte_q  <= '0;
    end else begin
      sh_start_q <= 1'b0;
      tcf_o      <= 1'b0;
      tx_pop_o   <= 1'b0;
      rx_push_o  <= 1'b0;

      // Backpressure hysteresis bookkeeping (read data phase only).
      if (state_q == StData && job_q.data_read) begin
        if (fifo_free_i == 6'd0)      stalled_q <= 1'b1;
        else if (fifo_free_i >= 6'd4) stalled_q <= 1'b0;
      end else begin
        stalled_q <= 1'b0;
      end

      unique case (state_q)
        StIdle: begin
          cs_no <= 1'b1;
          if (start_i) begin
            job_q    <= job_i;
            cs_no    <= 1'b0;
            hold_q   <= 4'd1;                  // one tick CS-setup
            state_q  <= StCsLow;
            dbytes_q <= job_i.len_m1 + 32'd1;
          end
        end

        // Wait `hold_q` ticks with CS low before the first edge.
        StCsLow: begin
          if (tick) begin
            if (hold_q <= 4'd1) state_q <= StInstr;
            else                hold_q  <= hold_q - 4'd1;
          end
        end

        StInstr: begin
          if (abort_i && sh_idle) begin
            state_q <= StCsHold; hold_q <= 4'd1;
          end else if (job_q.ccr.imode == PhSkip) begin
            state_q  <= StAddr;
            mbuf_q   <= left_align(job_q.addr, job_q.ccr.adsize);
            pbytes_q <= 3'(job_q.ccr.adsize) + 3'd1;
          end else if (sh_idle && !sh_done) begin
            sh_tx_q    <= job_q.ccr.instruction;
            sh_ln2_q   <= lanes_ln2(job_q.ccr.imode);
            sh_dir_q   <= 1'b1;
            sh_dummy_q <= 1'b0;
            sh_start_q <= 1'b1;
          end else if (sh_done) begin
            state_q  <= StAddr;
            mbuf_q   <= left_align(job_q.addr, job_q.ccr.adsize);
            pbytes_q <= 3'(job_q.ccr.adsize) + 3'd1;
          end
        end

        StAddr: begin
          if (abort_i && sh_idle) begin
            state_q <= StCsHold; hold_q <= 4'd1;
          end else if (job_q.ccr.admode == PhSkip) begin
            state_q  <= StAlt;
            mbuf_q   <= left_align(job_q.alt, job_q.ccr.absize);
            pbytes_q <= 3'(job_q.ccr.absize) + 3'd1;
          end else if (sh_idle && !sh_done && pbytes_q != 3'd0) begin
            sh_tx_q    <= mbuf_q[31:24];
            sh_ln2_q   <= lanes_ln2(job_q.ccr.admode);
            sh_dir_q   <= 1'b1;
            sh_dummy_q <= 1'b0;
            sh_start_q <= 1'b1;
          end else if (sh_done) begin
            mbuf_q   <= mbuf_q << 8;
            pbytes_q <= pbytes_q - 3'd1;
            if (pbytes_q == 3'd1) begin
              state_q  <= StAlt;
              mbuf_q   <= left_align(job_q.alt, job_q.ccr.absize);
              pbytes_q <= 3'(job_q.ccr.absize) + 3'd1;
            end
          end
        end

        StAlt: begin
          if (abort_i && sh_idle) begin
            state_q <= StCsHold; hold_q <= 4'd1;
          end else if (job_q.ccr.abmode == PhSkip) begin
            state_q <= StDummy;
          end else if (sh_idle && !sh_done && pbytes_q != 3'd0) begin
            sh_tx_q    <= mbuf_q[31:24];
            sh_ln2_q   <= lanes_ln2(job_q.ccr.abmode);
            sh_dir_q   <= 1'b1;
            sh_dummy_q <= 1'b0;
            sh_start_q <= 1'b1;
          end else if (sh_done) begin
            mbuf_q   <= mbuf_q << 8;
            pbytes_q <= pbytes_q - 3'd1;
            if (pbytes_q == 3'd1) state_q <= StDummy;
          end
        end

        StDummy: begin
          if (abort_i && sh_idle) begin
            state_q <= StCsHold; hold_q <= 4'd1;
          end else if (job_q.ccr.dcyc == 5'd0) begin
            state_q <= (job_q.ccr.dmode == PhSkip) ? StCsHold : StData;
            hold_q  <= 4'd1;
          end else if (sh_idle && !sh_done) begin
            sh_dummy_q <= 1'b1;
            sh_cyc_q   <= job_q.ccr.dcyc;
            sh_dir_q   <= 1'b0;
            sh_start_q <= 1'b1;
          end else if (sh_done) begin
            state_q <= (job_q.ccr.dmode == PhSkip) ? StCsHold : StData;
            hold_q  <= 4'd1;
          end
        end

        StData: begin
          if (sh_done && job_q.data_read) begin
            rx_byte_q <= sh_rx;
            rx_push_o <= 1'b1;
          end

          if (abort_i && sh_idle) begin
            state_q <= StCsHold; hold_q <= 4'd1;
          end else if (sh_idle && !job_q.unlimited && dbytes_q == 32'd0) begin
            tcf_o   <= 1'b1;
            state_q <= StCsHold;
            hold_q  <= 4'd1;
          end else if (sh_idle && !sh_done) begin
            if (job_q.data_read) begin
              if (rx_room) begin
                sh_ln2_q   <= lanes_ln2(job_q.ccr.dmode);
                sh_dir_q   <= 1'b0;
                sh_dummy_q <= 1'b0;
                sh_start_q <= 1'b1;
                dbytes_q   <= dbytes_q - 32'd1;
              end
            end else if (tx_valid_i) begin
              sh_tx_q    <= tx_data_i;
              tx_pop_o   <= 1'b1;
              sh_ln2_q   <= lanes_ln2(job_q.ccr.dmode);
              sh_dir_q   <= 1'b1;
              sh_dummy_q <= 1'b0;
              sh_start_q <= 1'b1;
              dbytes_q   <= dbytes_q - 32'd1;
            end
          end
        end

        // One tick of CS hold after the last edge, then CS high + CSHT.
        StCsHold: begin
          if (tick) begin
            cs_no   <= 1'b1;
            hold_q  <= (csht_i == 3'd0) ? 4'd1 : {csht_i, 1'b0};  // 2 ticks/SCK
            state_q <= StCsht;
          end
        end

        StCsht: begin
          if (tick) begin
            if (hold_q <= 4'd1) state_q <= StIdle;
            else                hold_q  <= hold_q - 4'd1;
          end
        end

        default: state_q <= StIdle;
      endcase
    end
  end

  assign busy_o = (state_q != StIdle);

endmodule
