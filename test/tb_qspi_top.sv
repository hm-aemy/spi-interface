// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Self-checking testbench for the QSPI controller (qspi_top) against the
// behavioural 23LC1024 SRAM model. Drives both OBI ports directly (no CPU):
//
//   1  indirect single-SPI write/read (0x02 / 0x03)
//   2  instruction-only command (EQIO) + SQI indirect write/read (2 dummy SCK)
//   3  memory-mapped SQI reads incl. prefetch hit + address jump
//   4  memory-mapped writes (sw/sh/sb) + read-back, endianness check
//   5  error cases: FSIZE out-of-range (indirect TEF + mmap bus error),
//      mmap write with WCCR.DMODE=0, mmap access with FMODE!=11
//
`timescale 1ns/1ps

module tb_qspi_top import spi_pkg::*; import qspi_pkg::*;;

  localparam time TCLK = 10ns;

  logic clk, rst_n;
  always #(TCLK/2) clk = ~clk;

  // ------------------------------------------------------------------------
  // DUT + SRAM model, shared-bus priority mux (never both driving)
  // ------------------------------------------------------------------------
  spi_obi_req_t csr_req, mem_req;
  spi_obi_rsp_t csr_rsp, mem_rsp;

  logic       cs_n, sclk;
  logic [3:0] mst_o, mst_oe, mem_o, mem_oe;
  wire  [3:0] sio;

  for (genvar i = 0; i < 4; i++) begin : g_sio
    assign sio[i] = mst_oe[i] ? mst_o[i] : (mem_oe[i] ? mem_o[i] : 1'b0);
  end

  qspi_top #(
    .FifoDepth (32),
    .ChipAddrW (29)
  ) dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .obi_csr_req_i (csr_req),
    .obi_csr_rsp_o (csr_rsp),
    .obi_mem_req_i (mem_req),
    .obi_mem_rsp_o (mem_rsp),
    .spi_cs_no     (cs_n),
    .spi_sclk_o    (sclk),
    .spi_sio_o     (mst_o),
    .spi_sio_oe    (mst_oe),
    .spi_sio_i     (sio)
  );

  s23lc1024 #(.INIT_FILE("")) i_sram (
    .cs_ni  (cs_n),
    .sclk_i (sclk),
    .sio_i  (sio),
    .sio_o  (mem_o),
    .sio_oe (mem_oe)
  );

  // ------------------------------------------------------------------------
  // Bookkeeping
  // ------------------------------------------------------------------------
  int unsigned errors = 0;

  task automatic check32(input logic [31:0] got, input logic [31:0] exp,
                         input string what);
    if (got !== exp) begin
      $error("[FAIL] %s: got=%08x exp=%08x", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s = %08x", what, got);
    end
  endtask

  task automatic check1(input logic got, input logic exp, input string what);
    if (got !== exp) begin
      $error("[FAIL] %s: got=%b exp=%b", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s = %b", what, got);
    end
  endtask

  // ------------------------------------------------------------------------
  // OBI master tasks (single outstanding, blocking)
  // ------------------------------------------------------------------------
  task automatic obi_xfer(
    input  bit          is_mem,
    input  logic [31:0] addr,
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        err
  );
    spi_obi_req_t req;
    req              = '0;
    req.req          = 1'b1;
    req.a.addr       = addr;
    req.a.we         = we;
    req.a.be         = be;
    req.a.wdata      = wdata;
    req.a.aid        = 4'h3;
    // Race-free stimulus: the TB only acts on NEGEDGES, so it never competes
    // with the DUT flip-flops at a posedge. A signal observed mid-cycle is
    // exactly what the FFs will see at the following posedge. gnt must be
    // checked in the SAME cycle the request is raised (combinational grant),
    // otherwise the first acceptance is missed and the access double-fires.
    @(negedge clk);
    if (is_mem) mem_req = req; else csr_req = req;
    forever begin
      #1ps;                            // let combinational gnt settle
      if (is_mem ? mem_rsp.gnt : csr_rsp.gnt) break;
      @(negedge clk);
    end
    @(negedge clk);                    // acceptance posedge has passed
    if (is_mem) mem_req = '0; else csr_req = '0;
    while (!(is_mem ? mem_rsp.rvalid : csr_rsp.rvalid)) @(negedge clk);
    rdata = is_mem ? mem_rsp.r.rdata : csr_rsp.r.rdata;
    err   = is_mem ? mem_rsp.r.err   : csr_rsp.r.err;
`ifdef QSPI_DEBUG
    $display("[%0t] obi %s %s a=%08x d=%08x", $time, is_mem ? "mem" : "csr",
             we ? "wr" : "rd", addr, we ? wdata : rdata);
`endif
    @(posedge clk);
  endtask

  task automatic csr_wr(input logic [7:0] off, input logic [31:0] data);
    logic [31:0] d; logic e;
    obi_xfer(0, 32'h2000_0000 | 32'(off), 1'b1, 4'hF, data, d, e);
  endtask

  task automatic csr_rd(input logic [7:0] off, output logic [31:0] data);
    logic e;
    obi_xfer(0, 32'h2000_0000 | 32'(off), 1'b0, 4'hF, 32'h0, data, e);
  endtask

  task automatic mem_wr(input logic [31:0] addr, input logic [3:0] be,
                        input logic [31:0] data, output logic err);
    logic [31:0] d;
    obi_xfer(1, 32'h4000_0000 | addr, 1'b1, be, data, d, err);
  endtask

  task automatic mem_rd(input logic [31:0] addr, output logic [31:0] data,
                        output logic err);
    obi_xfer(1, 32'h4000_0000 | addr, 1'b0, 4'hF, 32'h0, data, err);
  endtask

  // Wait until SR.BUSY == 0
  task automatic wait_idle;
    logic [31:0] sr;
    do csr_rd(QSPI_SR, sr); while (sr[5]);
  endtask

  // Wait until SR.FLEVEL >= n
  task automatic wait_flevel(input int n);
    logic [31:0] sr;
    do csr_rd(QSPI_SR, sr); while (32'(sr[13:8]) < 32'(n));
  endtask

  // Leave memory-mapped mode: abort the prefetch stream, then wait until
  // the sequencer is idle so CCR/WCCR writes are accepted again.
  task automatic leave_mmap;
    csr_wr(QSPI_CR, 32'h0000_0103);    // EN + PRESCALER + ABORT
    wait_idle;
  endtask

  // ------------------------------------------------------------------------
  // CCR builder
  // ------------------------------------------------------------------------
  function automatic logic [31:0] mk_ccr(
    input logic [7:0] instr,
    input logic [1:0] imode, admode, dmode, fmode,
    input logic [1:0] adsize,
    input logic [4:0] dcyc
  );
    logic [31:0] w;
    w         = '0;
    w[7:0]    = instr;
    w[9:8]    = imode;
    w[11:10]  = admode;
    w[13:12]  = adsize;
    w[22:18]  = dcyc;
    w[25:24]  = dmode;
    w[27:26]  = fmode;
    return w;
  endfunction

  localparam logic [1:0] MSkip = 2'b00, MSingle = 2'b01, MQuad = 2'b11;
  localparam logic [1:0] FWr = 2'b00, FRd = 2'b01, FMm = 2'b11;

  // ------------------------------------------------------------------------
  // Tests
  // ------------------------------------------------------------------------
  task automatic test_indirect_spi;
    logic [31:0] d;
    $display("== 1: indirect single-SPI write/read ==");
    // WRITE 0x02, 3-byte addr, single lanes, 4 data bytes
    csr_wr(QSPI_DLR, 32'd3);
    csr_wr(QSPI_CCR, mk_ccr(8'h02, MSingle, MSingle, MSingle, FWr, 2'd2, 5'd0));
    csr_wr(QSPI_AR,  32'h0000_0100);
    csr_wr(QSPI_DR,  32'hDEAD_BEEF);       // triggers the command
    wait_idle;
    // READ 0x03 (no dummy in single-SPI)
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MSingle, MSingle, MSingle, FRd, 2'd2, 5'd0));
    csr_wr(QSPI_AR,  32'h0000_0100);       // triggers the command
    wait_flevel(4);
    csr_rd(QSPI_DR, d);
    check32(d, 32'hDEAD_BEEF, "indirect SPI read-back @0x100");
    wait_idle;                         // let the CS/CSHT tail finish
  endtask

  task automatic test_rdmr_noaddr;
    logic [31:0] d;
    $display("== 1b: RDMR (read ohne Adressphase) ==");
    csr_wr(QSPI_DLR, 32'd0);
    csr_wr(QSPI_CCR, mk_ccr(8'h05, MSingle, MSkip, MSingle, FRd, 2'd0, 5'd0));
    wait_flevel(1);
    csr_rd(QSPI_DR, d);
    check32(d & 32'hFF, 32'h40, "RDMR power-on mode reg");
    wait_idle;
  endtask

  task automatic test_indirect_sqi;
    logic [31:0] d;
    $display("== 2: EQIO + indirect SQI write/read ==");
    // instruction-only command: EQIO 0x38 (starts on CCR write)
    csr_wr(QSPI_CCR, mk_ccr(8'h38, MSingle, MSkip, MSkip, FWr, 2'd0, 5'd0));
    wait_idle;
    // SQI write (no dummy)
    csr_wr(QSPI_DLR, 32'd3);
    csr_wr(QSPI_CCR, mk_ccr(8'h02, MQuad, MQuad, MQuad, FWr, 2'd2, 5'd0));
    csr_wr(QSPI_AR,  32'h0000_0200);
    csr_wr(QSPI_DR,  32'hCAFE_F00D);
    wait_idle;
    // SQI read: 1 dummy byte = 2 SCK cycles at quad
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FRd, 2'd2, 5'd2));
    csr_wr(QSPI_AR,  32'h0000_0200);
    wait_flevel(4);
    csr_rd(QSPI_DR, d);
    check32(d, 32'hCAFE_F00D, "indirect SQI read-back @0x200");
    wait_idle;
    // cross-check data written in test 1 via SQI
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FRd, 2'd2, 5'd2));
    csr_wr(QSPI_AR,  32'h0000_0100);
    wait_flevel(4);
    csr_rd(QSPI_DR, d);
    check32(d, 32'hDEAD_BEEF, "SQI reads SPI-written word @0x100");
    wait_idle;
  endtask

  task automatic test_mmap_read;
    logic [31:0] d; logic e;
    int t_first, t_hit;
    $display("== 3: memory-mapped SQI reads (prefetch) ==");
    // seed 16 bytes at 0x300 via indirect SQI writes
    for (int i = 0; i < 4; i++) begin
      csr_wr(QSPI_DLR, 32'd3);
      csr_wr(QSPI_CCR, mk_ccr(8'h02, MQuad, MQuad, MQuad, FWr, 2'd2, 5'd0));
      csr_wr(QSPI_AR,  32'h0000_0300 + 32'(4*i));
      csr_wr(QSPI_DR,  32'h1111_1111 * (32'(i) + 32'd1));
      wait_idle;
    end
    // switch to memory-mapped mode: read frame = SQI READ with 2 dummy SCK
    csr_wr(QSPI_WCCR, mk_ccr(8'h02, MQuad, MQuad, MQuad, FWr, 2'd2, 5'd0));
    csr_wr(QSPI_CCR,  mk_ccr(8'h03, MQuad, MQuad, MQuad, FMm, 2'd2, 5'd2));

    t_first = $time;
    mem_rd(32'h300, d, e); check32(d, 32'h1111_1111, "mmap word 0 (demand)");
    t_first = $time - t_first;
    t_hit = $time;
    mem_rd(32'h304, d, e); check32(d, 32'h2222_2222, "mmap word 1 (prefetch)");
    t_hit = $time - t_hit;
    mem_rd(32'h308, d, e); check32(d, 32'h3333_3333, "mmap word 2 (prefetch)");
    mem_rd(32'h30C, d, e); check32(d, 32'h4444_4444, "mmap word 3 (prefetch)");
    check1(t_hit < t_first, 1'b1, $sformatf(
      "prefetch hit faster than demand read (%0d < %0d ns)", t_hit, t_first));
    // address jump back into already-written area
    mem_rd(32'h100, d, e); check32(d, 32'hDEAD_BEEF, "mmap jump read @0x100");
    // and forward again
    mem_rd(32'h200, d, e); check32(d, 32'hCAFE_F00D, "mmap jump read @0x200");
  endtask

  task automatic test_mmap_write;
    logic [31:0] d; logic e;
    $display("== 4: memory-mapped writes + endianness ==");
    mem_wr(32'h400, 4'hF, 32'h0BAD_F00D, e);
    check1(e, 1'b0, "mmap sw accepted");
    mem_rd(32'h400, d, e); check32(d, 32'h0BAD_F00D, "mmap sw read-back");
    // sub-word writes
    mem_wr(32'h400, 4'b0011, 32'h0000_5566, e);
    mem_rd(32'h400, d, e); check32(d, 32'h0BAD_5566, "mmap sh (low half)");
    mem_wr(32'h400, 4'b0100, 32'h0077_0000, e);
    mem_rd(32'h400, d, e); check32(d, 32'h0B77_5566, "mmap sb (byte 2)");
    // endianness: byte at chip addr 0x400 must be the LSB (0x66)
    leave_mmap;                        // mandatory abort flow
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FRd, 2'd2, 5'd2));
    csr_wr(QSPI_DLR, 32'd0);
    csr_wr(QSPI_AR,  32'h0000_0400);
    wait_flevel(1);
    csr_rd(QSPI_DR, d);
    check32(d & 32'hFF, 32'h66, "little-endian: chip byte @0x400 is LSB");
    wait_idle;
  endtask

  task automatic test_errors;
    logic [31:0] d, sr; logic e;
    $display("== 5: error cases ==");
    // mmap read beyond FSIZE (128 KiB) -> bus error
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FMm, 2'd2, 5'd2));
    mem_rd(32'h0002_0000, d, e);
    check1(e, 1'b1, "mmap read beyond FSIZE errors");
    mem_rd(32'h300, d, e); check32(d, 32'h1111_1111, "mmap still alive");
    // mmap write with WCCR.DMODE=0 -> bus error (WCCR change needs idle seq)
    leave_mmap;
    csr_wr(QSPI_WCCR, mk_ccr(8'h02, MQuad, MQuad, MSkip, FWr, 2'd2, 5'd0));
    csr_wr(QSPI_CCR,  mk_ccr(8'h03, MQuad, MQuad, MQuad, FMm, 2'd2, 5'd2));
    mem_wr(32'h400, 4'hF, 32'h0, e);
    check1(e, 1'b1, "mmap write with WCCR.DMODE=0 errors");
    leave_mmap;
    csr_wr(QSPI_WCCR, mk_ccr(8'h02, MQuad, MQuad, MQuad, FWr, 2'd2, 5'd0));
    // indirect read beyond FSIZE -> TEF, no start
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FRd, 2'd2, 5'd2));
    csr_wr(QSPI_DLR, 32'd3);
    csr_wr(QSPI_AR,  32'h0002_0000);
    csr_rd(QSPI_SR, sr);
    check1(sr[0], 1'b1, "indirect out-of-range sets TEF");
    check1(sr[5], 1'b0, "no command started on TEF");
    csr_wr(QSPI_FCR, 32'h1);
    csr_rd(QSPI_SR, sr);
    check1(sr[0], 1'b0, "TEF cleared via FCR");
    // mmap access while FMODE != 11 -> bus error
    csr_wr(QSPI_CCR, mk_ccr(8'h03, MQuad, MQuad, MQuad, FRd, 2'd2, 5'd2));
    mem_rd(32'h300, d, e);
    check1(e, 1'b1, "mmap access with FMODE!=11 errors");
  endtask

  // ------------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_qspi_top.fst");
    $dumpvars(0, tb_qspi_top);

    clk     = 1'b0;
    rst_n   = 1'b0;
    csr_req = '0;
    mem_req = '0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // global config: EN, prescaler 1 (SCK = clk/4); FSIZE 16 = 128 KiB, CSHT 2
    csr_wr(QSPI_DCR, 32'h0000_0210);
    csr_wr(QSPI_CR,  32'h0000_0101);

    test_indirect_spi;
    test_rdmr_noaddr;
    test_indirect_sqi;
    test_mmap_read;
    test_mmap_write;
    test_errors;

    if (errors == 0) $display("TB PASSED");
    else             $fatal(1, "TB FAILED: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $error("Timeout in tb_qspi_top");
    $fatal(1);
  end

`ifdef QSPI_DEBUG
  always @(dut.i_seq.state_q)
    $display("[%0t] seq state=%0d dbytes=%0d", $time, dut.i_seq.state_q, dut.i_seq.dbytes_q);
  always @(dut.i_seq.i_shift.state_q)
    $display("[%0t]   shift state=%0d cyc=%0d", $time, dut.i_seq.i_shift.state_q, dut.i_seq.i_shift.cyc_q);
  always @(posedge dut.i_regs.start_o)
    $display("[%0t] regs start", $time);
  always @(dut.i_fifo.level_o)
    $display("[%0t] fifo lvl=%0d", $time, dut.i_fifo.level_o);
  always @(i_sram.opcode)
    $display("[%0t] sram opcode=%02x", $time, i_sram.opcode);
  always @(i_sram.addr)
    if (i_sram.addr < 24'h110)
      $display("[%0t] sram addr=%06x mem[100]=%02x", $time, i_sram.addr, i_sram.mem[17'h100]);
`endif

endmodule
