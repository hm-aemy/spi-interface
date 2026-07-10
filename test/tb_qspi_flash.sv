// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// QSPI controller (qspi_top) against the behavioural W25Q128JV flash model:
// the second chip profile of the plan (dummy cycles, QE bit, quad reads).
//
//   1  JEDEC ID (0x9F) via indirect read, no address phase
//   2  Quad-Enable: 0x50 (volatile SR write enable) + 0x31 (write SR2),
//      read back via 0x35
//   3  indirect Fast Read Quad Output 0x6B (single addr, 8 dummy, quad data)
//   4  negative test: 0x6B with 6 instead of 8 dummy cycles -> wrong data
//   5  memory-mapped reads with 0x6B profile (FSIZE = 16 MiB), prefetch hit
//      + address jump; mmap write must fail (flash WCCR.DMODE = 0)
//
`timescale 1ns/1ps

module tb_qspi_flash import spi_pkg::*, qspi_pkg::*; ();

  localparam time TCLK = 10ns;
  localparam string INIT_FILE = "w25q128jv_init.hex";
  localparam int unsigned INIT_BYTES = 256;

  logic clk, rst_n;
  always #(TCLK/2) clk = ~clk;

  // Reference image, same generator as w25q128jv_init.hex
  function automatic logic [7:0] ref_byte(input int unsigned i);
    return (i < INIT_BYTES) ? 8'((7 * i + 32'h11) & 32'hFF) : 8'hFF;
  endfunction

  function automatic logic [31:0] ref_word(input int unsigned a);
    return {ref_byte(a+3), ref_byte(a+2), ref_byte(a+1), ref_byte(a)};
  endfunction

  // ------------------------------------------------------------------------
  // DUT + flash model
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

  w25q128jv #(.INIT_FILE(INIT_FILE)) i_flash (
    .cs_ni  (cs_n),
    .sclk_i (sclk),
    .sio_i  (sio),
    .sio_o  (mem_o),
    .sio_oe (mem_oe)
  );

  // ------------------------------------------------------------------------
  // Bookkeeping / OBI master (same conventions as tb_qspi_top)
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
    req         = '0;
    req.req     = 1'b1;
    req.a.addr  = addr;
    req.a.we    = we;
    req.a.be    = be;
    req.a.wdata = wdata;
    req.a.aid   = 4'h5;
    @(negedge clk);
    if (is_mem) mem_req = req; else csr_req = req;
    forever begin
      #1ps;
      if (is_mem ? mem_rsp.gnt : csr_rsp.gnt) break;
      @(negedge clk);
    end
    @(negedge clk);
    if (is_mem) mem_req = '0; else csr_req = '0;
    while (!(is_mem ? mem_rsp.rvalid : csr_rsp.rvalid)) @(negedge clk);
    rdata = is_mem ? mem_rsp.r.rdata : csr_rsp.r.rdata;
    err   = is_mem ? mem_rsp.r.err   : csr_rsp.r.err;
    @(posedge clk);
  endtask

  task automatic csr_wr(input logic [7:0] off, input logic [31:0] data);
    logic [31:0] d; logic e;
    obi_xfer(0, 32'h2000_0000 | 32'(off), 1'b1, 4'hF, data, d, e);
  endtask

  // Byte-wide DR write: pushes exactly ONE byte into the FIFO (the DR port
  // pushes as many bytes as byte-enables are set -- match DLR+1 exactly).
  task automatic csr_wr_byte(input logic [7:0] off, input logic [7:0] data);
    logic [31:0] d; logic e;
    obi_xfer(0, 32'h2000_0000 | 32'(off), 1'b1, 4'b0001, {24'h0, data}, d, e);
  endtask

  task automatic csr_rd(input logic [7:0] off, output logic [31:0] data);
    logic e;
    obi_xfer(0, 32'h2000_0000 | 32'(off), 1'b0, 4'hF, 32'h0, data, e);
  endtask

  task automatic mem_rd(input logic [31:0] addr, output logic [31:0] data,
                        output logic err);
    obi_xfer(1, 32'h4000_0000 | addr, 1'b0, 4'hF, 32'h0, data, err);
  endtask

  task automatic wait_idle;
    logic [31:0] sr;
    do csr_rd(QSPI_SR, sr); while (sr[5]);
  endtask

  task automatic wait_flevel(input int n);
    logic [31:0] sr;
    do csr_rd(QSPI_SR, sr); while (32'(sr[13:8]) < 32'(n));
  endtask

  task automatic leave_mmap;
    csr_wr(QSPI_CR, 32'h0000_0103);
    wait_idle;
  endtask

  function automatic logic [31:0] mk_ccr(
    input logic [7:0] instr,
    input logic [1:0] imode, admode, dmode, fmode,
    input logic [1:0] adsize,
    input logic [4:0] dcyc
  );
    logic [31:0] w;
    w        = '0;
    w[7:0]   = instr;
    w[9:8]   = imode;
    w[11:10] = admode;
    w[13:12] = adsize;
    w[22:18] = dcyc;
    w[25:24] = dmode;
    w[27:26] = fmode;
    return w;
  endfunction

  localparam logic [1:0] MSkip = 2'b00, MSingle = 2'b01, MQuad = 2'b11;
  localparam logic [1:0] FWr = 2'b00, FRd = 2'b01, FMm = 2'b11;

  // ------------------------------------------------------------------------
  // Tests
  // ------------------------------------------------------------------------
  task automatic test_jedec;
    logic [31:0] d;
    $display("== 1: JEDEC ID (0x9F) ==");
    csr_wr(QSPI_DLR, 32'd2);           // 3 ID bytes
    csr_wr(QSPI_CCR, mk_ccr(8'h9F, MSingle, MSkip, MSingle, FRd, 2'd0, 5'd0));
    wait_flevel(3);
    csr_rd(QSPI_DR, d);
    check32(d & 32'hFF_FFFF, 32'h1840EF, "JEDEC ID EF 40 18 (LSB first)");
    wait_idle;
  endtask

  task automatic test_quad_enable;
    logic [31:0] d;
    $display("== 2: set QE via 0x50 + 0x31, read back 0x35 ==");
    // volatile SR write enable: instruction only
    csr_wr(QSPI_CCR, mk_ccr(8'h50, MSingle, MSkip, MSkip, FWr, 2'd0, 5'd0));
    wait_idle;
    // write SR2 = 0x02 (QE bit S9)
    csr_wr(QSPI_DLR, 32'd0);
    csr_wr(QSPI_CCR, mk_ccr(8'h31, MSingle, MSkip, MSingle, FWr, 2'd0, 5'd0));
    csr_wr_byte(QSPI_DR, 8'h02);
    wait_idle;
    // read SR2
    csr_wr(QSPI_DLR, 32'd0);
    csr_wr(QSPI_CCR, mk_ccr(8'h35, MSingle, MSkip, MSingle, FRd, 2'd0, 5'd0));
    wait_flevel(1);
    csr_rd(QSPI_DR, d);
    check32(d & 32'hFF, 32'h02, "SR2.QE set");
    wait_idle;
  endtask

  task automatic test_quad_read;
    logic [31:0] d;
    $display("== 3: indirect Fast Read Quad Output 0x6B ==");
    csr_wr(QSPI_DLR, 32'd7);           // 8 bytes
    csr_wr(QSPI_CCR, mk_ccr(8'h6B, MSingle, MSingle, MQuad, FRd, 2'd2, 5'd8));
    csr_wr(QSPI_AR,  32'h0000_0010);
    wait_flevel(8);
    csr_rd(QSPI_DR, d);
    check32(d, ref_word(32'h10), "0x6B quad read word 0 @0x10");
    csr_rd(QSPI_DR, d);
    check32(d, ref_word(32'h14), "0x6B quad read word 1 @0x14");
    wait_idle;
  endtask

  task automatic test_wrong_dummies;
    logic [31:0] d;
    $display("== 4: 0x6B with 6 instead of 8 dummy cycles (negative) ==");
    csr_wr(QSPI_DLR, 32'd3);
    csr_wr(QSPI_CCR, mk_ccr(8'h6B, MSingle, MSingle, MQuad, FRd, 2'd2, 5'd6));
    csr_wr(QSPI_AR,  32'h0000_0010);
    wait_flevel(4);
    csr_rd(QSPI_DR, d);
    check1(d != ref_word(32'h10), 1'b1, "wrong dummy count yields wrong data");
    wait_idle;
  endtask

  task automatic test_mmap_flash;
    logic [31:0] d; logic e;
    $display("== 5: memory-mapped 0x6B reads, FSIZE = 16 MiB ==");
    csr_wr(QSPI_DCR, 32'h0000_0217);   // FSIZE=23 (16 MiB), CSHT=2
    // flash is read-only: WCCR.DMODE stays 0 -> mmap writes must error
    csr_wr(QSPI_WCCR, 32'h0);
    csr_wr(QSPI_CCR, mk_ccr(8'h6B, MSingle, MSingle, MQuad, FMm, 2'd2, 5'd8));
    mem_rd(32'h00, d, e); check32(d, ref_word(32'h00), "mmap word @0x00");
    mem_rd(32'h04, d, e); check32(d, ref_word(32'h04), "mmap word @0x04 (hit)");
    mem_rd(32'h08, d, e); check32(d, ref_word(32'h08), "mmap word @0x08 (hit)");
    mem_rd(32'h40, d, e); check32(d, ref_word(32'h40), "mmap jump @0x40");
    // uninitialised flash reads as 0xFF
    mem_rd(32'h1000, d, e); check32(d, 32'hFFFF_FFFF, "erased flash @0x1000");
    // mmap write on the read-only profile
    obi_xfer(1, 32'h4000_0000, 1'b1, 4'hF, 32'h0, d, e);
    check1(e, 1'b1, "mmap write to flash profile errors");
    leave_mmap;
  endtask

  // ------------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_qspi_flash.fst");
    $dumpvars(0, tb_qspi_flash);

    clk     = 1'b0;
    rst_n   = 1'b0;
    csr_req = '0;
    mem_req = '0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // EN + prescaler 1; FSIZE=23 (16 MiB), CSHT=2
    csr_wr(QSPI_DCR, 32'h0000_0217);
    csr_wr(QSPI_CR,  32'h0000_0101);

    test_jedec;
    test_quad_enable;
    test_quad_read;
    test_wrong_dummies;
    test_mmap_flash;

    if (errors == 0) $display("TB PASSED");
    else             $fatal(1, "TB FAILED: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $error("Timeout in tb_qspi_flash");
    $fatal(1);
  end

endmodule
