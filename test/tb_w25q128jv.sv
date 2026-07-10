// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Self-checking testbench for the behavioural W25Q128JV NOR-Flash model
// (model/w25q128jv.sv). Drives the chip DIRECTLY via a bit-banging master
// (cs_n / sclk / sio[3:0]), Mode 0 -- same conventions as tb_s23lc1024.sv:
// master drives data while SCK is low, model samples on rising SCK and
// drives read data on falling SCK.
//
// A small (256 B) deterministic reference image (w25q128jv_init.hex) is
// loaded into BOTH the DUT (via INIT_FILE) and a local `ref_mem` mirror, so
// every read can be self-checked against a known-good value. Addresses past
// the 256 preloaded bytes are expected to read back as 8'hFF (erased flash).
`timescale 1ns/1ps

module tb_w25q128jv;

  // ------------------------------------------------------------------------
  // Bit-banging timing (sim-only).
  // ------------------------------------------------------------------------
  localparam time TCK = 50ns;

  // Reference image: same file the DUT preloads, mirrored here for checking.
  localparam string INIT_FILE  = "w25q128jv_init.hex";
  localparam int unsigned REF_BYTES = 256;

  // Opcodes (datasheet) -- model-local copies for the master to send.
  localparam logic [7:0] CMD_READ   = 8'h03;
  localparam logic [7:0] CMD_FREAD  = 8'h0B;
  localparam logic [7:0] CMD_DREAD  = 8'h3B;
  localparam logic [7:0] CMD_QREAD  = 8'h6B;
  localparam logic [7:0] CMD_QIO    = 8'hEB;
  localparam logic [7:0] CMD_RDSR1  = 8'h05;
  localparam logic [7:0] CMD_RDSR2  = 8'h35;
  localparam logic [7:0] CMD_WREN   = 8'h06;
  localparam logic [7:0] CMD_VSRWE  = 8'h50;
  localparam logic [7:0] CMD_WRSR2  = 8'h31;
  localparam logic [7:0] CMD_JEDEC  = 8'h9F;
  localparam logic [7:0] CMD_ENQPI  = 8'h38;
  localparam logic [7:0] CMD_EXQPI  = 8'hFF;
  localparam logic [7:0] CMD_SETRP  = 8'hC0;

  // ------------------------------------------------------------------------
  // DUT pins + master drive signals
  // ------------------------------------------------------------------------
  logic       cs_n;
  logic       sclk;

  logic [3:0] m_o;
  logic [3:0] m_oe;

  logic [3:0] dut_o;
  logic [3:0] dut_oe;

  // Shared bus net: model wins, else master, else idle-0 (see tb_s23lc1024.sv
  // for why a priority mux is a faithful, Verilator-friendly stand-in for a
  // real tri-state net here: master and model never drive simultaneously).
  wire  [3:0] sio;
  for (genvar i = 0; i < 4; i++) begin : g_sio
    assign sio[i] = dut_oe[i] ? dut_o[i] : (m_oe[i] ? m_o[i] : 1'b0);
  end

  // ------------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------------
  w25q128jv #(
    .INIT_FILE (INIT_FILE)
  ) dut (
    .cs_ni  (cs_n),
    .sclk_i (sclk),
    .sio_i  (sio),
    .sio_o  (dut_o),
    .sio_oe (dut_oe)
  );

  // ------------------------------------------------------------------------
  // Reference image mirror (for self-checking).
  // ------------------------------------------------------------------------
  logic [7:0] ref_mem [0:REF_BYTES-1];
  initial $readmemh(INIT_FILE, ref_mem);

  function automatic logic [7:0] exp_byte(input int unsigned a);
    if (a < REF_BYTES) exp_byte = ref_mem[a];
    else                exp_byte = 8'hFF;  // uninitialized -> erased flash
  endfunction

  // ------------------------------------------------------------------------
  // Pass/Fail bookkeeping
  // ------------------------------------------------------------------------
  int unsigned errors = 0;
  int unsigned checks = 0;

  task automatic check(input logic [7:0] got, input logic [7:0] exp, input string what);
    checks++;
    if (got !== exp) begin
      $error("[FAIL] %s: got=%02x exp=%02x", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s = %02x", what, got);
    end
  endtask

  task automatic check_bit(input logic got, input logic exp, input string what);
    checks++;
    if (got !== exp) begin
      $error("[FAIL] %s: got=%0b exp=%0b", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s = %0b", what, got);
    end
  endtask

  task automatic check_oe(input logic [3:0] got, input logic [3:0] exp, input string what);
    checks++;
    if (got !== exp) begin
      $error("[FAIL] %s: got_oe=%04b exp_oe=%04b", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s (oe=%04b)", what, got);
    end
  endtask

  // ========================================================================
  // Low-level bus primitives
  // ========================================================================
  task automatic bus_idle;
    cs_n = 1'b1;
    sclk = 1'b0;
    m_o  = 4'b0000;
    m_oe = 4'b0000;
  endtask

  task automatic cs_assert;
    cs_n = 1'b0;
    #(TCK/2);
  endtask

  task automatic cs_release;
    #(TCK/2);
    m_oe = 4'b0000;
    cs_n = 1'b1;
    #(TCK);
  endtask

  // One SCK cycle: data must be valid before this call (SCK low); rising
  // edge -> model samples; falling edge -> model may drive next bit.
  task automatic sck_cycle(output logic [3:0] sampled);
    #(TCK/2);
    sclk    = 1'b1;
    sampled = sio;
    #(TCK/2);
    sclk    = 1'b0;
  endtask

  // ========================================================================
  // Byte-level master tasks (MSB-first)
  // ========================================================================

  // ---- Single lane (SI = sio[0] out, SO = sio[1] in) ---------------------
  task automatic spi_send_byte(input logic [7:0] b);
    logic [3:0] dummy;
    m_oe = 4'b0001;
    for (int k = 7; k >= 0; k--) begin
      m_o[0] = b[k];
      sck_cycle(dummy);
    end
  endtask

  task automatic spi_recv_byte(output logic [7:0] b);
    logic [3:0] s;
    b = '0;
    m_oe = 4'b0000;
    for (int k = 7; k >= 0; k--) begin
      sck_cycle(s);
      b[k] = s[1];
    end
  endtask

  // ---- Dual lane (sio[1:0]) -- read-data only in this model ---------------
  task automatic dual_recv_byte(output logic [7:0] b);
    logic [3:0] s;
    b = '0;
    m_oe = 4'h0;
    for (int k = 3; k >= 0; k--) begin
      sck_cycle(s);
      b[2*k +: 2] = s[1:0];
    end
  endtask

  // ---- Quad lane (sio[3:0]) -- used both for SPI-mode quad phases and for
  // EVERY phase once in QPI mode.
  task automatic quad_send_byte(input logic [7:0] b);
    logic [3:0] dummy;
    m_oe = 4'b1111;
    m_o  = b[7:4];
    sck_cycle(dummy);
    m_o  = b[3:0];
    sck_cycle(dummy);
  endtask

  task automatic quad_recv_byte(output logic [7:0] b);
    logic [3:0] s;
    b = '0;
    m_oe = 4'h0;
    sck_cycle(s);
    b[7:4] = s;
    sck_cycle(s);
    b[3:0] = s;
  endtask

  // 24-bit address sent as 6 quad nibbles (used for EBh addr phase, and for
  // 0x0B/0xEB address phase in QPI mode).
  task automatic quad_send_addr(input logic [23:0] a);
    logic [3:0] dummy;
    m_oe = 4'b1111;
    for (int nib = 5; nib >= 0; nib--) begin
      m_o = a[4*nib +: 4];
      sck_cycle(dummy);
    end
  endtask

  // N raw SCK cycles with nothing meaningfully driven -- used for dummy
  // (bus-turnaround) phases; lane width is irrelevant, the model ignores
  // whatever is sampled here.
  task automatic dummy_clocks(input int unsigned n);
    logic [3:0] s;
    m_oe = 4'b0000;
    repeat (n) sck_cycle(s);
  endtask

  // ========================================================================
  // High-level command helpers
  // ========================================================================

  // ---- 0x03 Read Data: single lane, no dummy. -----------------------------
  task automatic read03(input logic [23:0] addr, input int n, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_READ);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    for (int i = 0; i < n; i++) spi_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- 0x0B Fast Read: single lane, `ndummy` dummy clocks (datasheet: 8). -
  task automatic fast_read0B(input logic [23:0] addr, input int n, input int unsigned ndummy,
                             output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_FREAD);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    dummy_clocks(ndummy);
    for (int i = 0; i < n; i++) spi_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- 0x3B Fast Read Dual Output: addr single, 8 dummy, data dual. -------
  task automatic dual_read3B(input logic [23:0] addr, input int n, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_DREAD);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    dummy_clocks(8);
    for (int i = 0; i < n; i++) dual_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- 0x6B Fast Read Quad Output: addr single, 8 dummy, data quad. -------
  // Works regardless of QE -- caller checks dut_oe to see whether the model
  // actually drove anything.
  task automatic quad_read6B(input logic [23:0] addr, input int n, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_QREAD);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    dummy_clocks(8);
    for (int i = 0; i < n; i++) quad_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- 0xEB Fast Read Quad I/O: addr quad (6 clk) + mode byte quad (2 clk)
  // + 4 dummy clocks + data quad. `instr_quad` selects whether the
  // instruction itself is sent single (Standard-SPI) or quad (QPI).
  task automatic qio_readEB(input logic [23:0] addr, input logic [7:0] mode_byte,
                            input int n, input bit instr_quad, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    if (instr_quad) quad_send_byte(CMD_QIO);
    else             spi_send_byte(CMD_QIO);
    quad_send_addr(addr);
    quad_send_byte(mode_byte);
    dummy_clocks(4);
    for (int i = 0; i < n; i++) quad_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- 0x05 / 0x35 status register reads (single lane, Standard-SPI). -----
  task automatic rdsr(input logic [7:0] op, output logic [7:0] sr);
    cs_assert;
    spi_send_byte(op);
    spi_recv_byte(sr);
    cs_release;
  endtask

  // ---- Write-enable helpers + WRSR2 (single lane, Standard-SPI). ---------
  task automatic wren;
    cs_assert;
    spi_send_byte(CMD_WREN);
    cs_release;
  endtask

  task automatic vsrwe;
    cs_assert;
    spi_send_byte(CMD_VSRWE);
    cs_release;
  endtask

  task automatic wrsr2(input logic [7:0] val);
    cs_assert;
    spi_send_byte(CMD_WRSR2);
    spi_send_byte(val);
    cs_release;
  endtask

  // ---- 0x9F JEDEC ID (single lane, repeats EF/40/18). --------------------
  task automatic jedec_id(input int n, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_JEDEC);
    for (int i = 0; i < n; i++) spi_recv_byte(data[i]);
    cs_release;
  endtask

  // ---- Enter/Exit QPI (no-arg commands). ----------------------------------
  task automatic enter_qpi;
    cs_assert;
    spi_send_byte(CMD_ENQPI);
    cs_release;
  endtask

  task automatic exit_qpi;
    cs_assert;
    quad_send_byte(CMD_EXQPI);
    cs_release;
  endtask

  // ---- QPI-mode helpers: EVERY phase (incl. instruction) is quad. --------
  task automatic qpi_rdsr(input logic [7:0] op, output logic [7:0] sr);
    cs_assert;
    quad_send_byte(op);
    quad_recv_byte(sr);
    cs_release;
  endtask

  task automatic qpi_fast_read0B(input logic [23:0] addr, input int n,
                                 input int unsigned ndummy, output logic [7:0] data []);
    data = new[n];
    cs_assert;
    quad_send_byte(CMD_FREAD);
    quad_send_addr(addr);
    dummy_clocks(ndummy);
    for (int i = 0; i < n; i++) quad_recv_byte(data[i]);
    cs_release;
  endtask

  task automatic qpi_set_read_params(input logic [1:0] p54);
    cs_assert;
    quad_send_byte(CMD_SETRP);
    quad_send_byte({2'b00, p54, 4'b0000});
    cs_release;
  endtask

  // ========================================================================
  // Test sequences
  // ========================================================================

  // ---- 1: 0x03 single byte + sequential ----------------------------------
  task automatic test_read03;
    logic [7:0] rd [];
    $display("== 1: 0x03 Read Data (single + sequential) ==");
    read03(24'h00_0010, 1, rd);
    check(rd[0], exp_byte(32'h10), "0x03 single byte @0x10");

    read03(24'h00_0000, 16, rd);
    foreach (rd[i]) check(rd[i], exp_byte(i), $sformatf("0x03 sequential byte %0d", i));

    read03(24'h00_0055, 1, rd);
    check(rd[0], exp_byte(32'h55), "0x03 single byte @0x55 (random)");
  endtask

  // ---- 2: 0x0B Fast Read, exactly 8 dummies ------------------------------
  task automatic test_fast_read0B;
    logic [7:0] rd [];
    $display("== 2: 0x0B Fast Read (8 dummy clocks) ==");
    fast_read0B(24'h00_0020, 8, 8, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h20 + i), $sformatf("0x0B byte %0d", i));
  endtask

  // ---- 3: 0x3B Dual Output ------------------------------------------------
  task automatic test_dual_read3B;
    logic [7:0] rd [];
    $display("== 3: 0x3B Fast Read Dual Output ==");
    dual_read3B(24'h00_0030, 8, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h30 + i), $sformatf("0x3B byte %0d", i));
  endtask

  // ---- 4: 0x6B Quad Output WITHOUT QE -> model must not drive ------------
  task automatic test_quad_read6B_no_qe;
    logic [7:0] rd [];
    $display("== 4: 0x6B Fast Read Quad Output, QE=0 (must NOT drive) ==");
    quad_read6B(24'h00_0040, 2, rd);
    check_oe(dut_oe, 4'b0000, "0x6B without QE leaves dut_oe at 0");
  endtask

  // ---- 5: enable QE via 0x50+0x31, and again via 0x06+0x31 ----------------
  task automatic test_enable_qe;
    logic [7:0] sr2;
    $display("== 5: enable QE (0x50+0x31, then 0x06+0x31), verify via 0x35 ==");
    vsrwe;
    wrsr2(8'h02);                      // bit1 = QE = 1
    rdsr(CMD_RDSR2, sr2);
    check_bit(sr2[1], 1'b1, "QE after 0x50+0x31");

    wren;
    wrsr2(8'h02);                      // redundant, but exercises the WEL path
    rdsr(CMD_RDSR2, sr2);
    check_bit(sr2[1], 1'b1, "QE after 0x06+0x31");
  endtask

  // ---- 6: 0x6B WITH QE=1 -> correct data ----------------------------------
  task automatic test_quad_read6B_qe;
    logic [7:0] rd [];
    $display("== 6: 0x6B Fast Read Quad Output, QE=1 ==");
    quad_read6B(24'h00_0040, 8, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h40 + i), $sformatf("0x6B byte %0d", i));
  endtask

  // ---- 7: 0xEB Quad I/O (Standard SPI instruction) ------------------------
  task automatic test_qio_EB;
    logic [7:0] rd [];
    $display("== 7: 0xEB Fast Read Quad I/O ==");
    qio_readEB(24'h00_0050, 8'h00, 8, 1'b0, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h50 + i), $sformatf("0xEB byte %0d", i));
  endtask

  // ---- 8: negative test -- 0x0B with 6 instead of 8 dummies --------------
  task automatic test_bad_dummy;
    logic [7:0] rd [];
    bit mism;
    $display("== 8: NEGATIVE -- 0x0B with 6 (not 8) dummy clocks must mismatch ==");
    fast_read0B(24'h00_0020, 4, 6, rd);
    mism = 1'b0;
    foreach (rd[i]) if (rd[i] !== exp_byte(32'h20 + i)) mism = 1'b1;
    checks++;
    if (mism) $display("[ ok ] wrong dummy count -> data mismatch, as expected");
    else begin
      $error("[FAIL] wrong dummy count unexpectedly produced correct data");
      errors++;
    end
  endtask

  // ---- 9: JEDEC ID ---------------------------------------------------------
  task automatic test_jedec;
    logic [7:0] rd [];
    $display("== 9: 0x9F JEDEC ID ==");
    jedec_id(4, rd);
    check(rd[0], 8'hEF, "JEDEC byte 0");
    check(rd[1], 8'h40, "JEDEC byte 1");
    check(rd[2], 8'h18, "JEDEC byte 2");
    check(rd[3], 8'hEF, "JEDEC byte 3 (repeats)");
  endtask

  // ---- 10: QPI mode --------------------------------------------------------
  task automatic test_qpi;
    logic [7:0] sr1;
    logic [7:0] rd [];
    $display("== 10: Enter QPI, status/read/set-read-params, Exit QPI ==");

    enter_qpi;                        // takes effect at CS rise (QE=1 already)

    qpi_rdsr(CMD_RDSR1, sr1);
    check_bit(sr1[1], 1'b0, "QPI: WEL=0 after previous writes completed");

    qpi_fast_read0B(24'h00_0060, 8, 2, rd);   // default: 2 dummy clocks
    foreach (rd[i]) check(rd[i], exp_byte(32'h60 + i), $sformatf("QPI 0x0B(2 dummy) byte %0d", i));

    qpi_set_read_params(2'b11);       // P5-P4 = 11 -> 8 dummy clocks
    qpi_fast_read0B(24'h00_0070, 8, 8, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h70 + i), $sformatf("QPI 0x0B(8 dummy) byte %0d", i));

    qio_readEB(24'h00_0080, 8'h00, 8, 1'b1, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h80 + i), $sformatf("QPI 0xEB byte %0d", i));

    exit_qpi;                         // takes effect at CS rise

    read03(24'h00_0000, 4, rd);
    foreach (rd[i]) check(rd[i], exp_byte(i), $sformatf("post-QPI 0x03 byte %0d", i));
  endtask

  // ---- 11: read across the initialized/uninitialized boundary -------------
  task automatic test_uninitialized;
    logic [7:0] rd [];
    $display("== 11: read across initialized/uninitialized boundary -> 0xFF ==");
    read03(24'h00_00F8, 16, rd);
    foreach (rd[i]) check(rd[i], exp_byte(32'h00F8 + i), $sformatf("boundary byte %0d", i));
    read03(24'h01_2345, 4, rd);
    foreach (rd[i]) check(rd[i], 8'hFF, $sformatf("deep-uninitialized byte %0d", i));
  endtask

  // ========================================================================
  // Main
  // ========================================================================
  initial begin
    $dumpfile("tb_w25q128jv.fst");
    $dumpvars(0, tb_w25q128jv);

    bus_idle;
    #(TCK);

    test_read03;
    test_fast_read0B;
    test_dual_read3B;
    test_quad_read6B_no_qe;
    test_enable_qe;
    test_quad_read6B_qe;
    test_qio_EB;
    test_bad_dummy;
    test_jedec;
    test_qpi;
    test_uninitialized;

    if (errors == 0)
      $display("TB PASSED (%0d checks)", checks);
    else
      $fatal(1, "TB FAILED: %0d error(s) out of %0d checks", errors, checks);

    $finish;
  end

  // Watchdog
  initial begin
    #2_000_000;
    $error("Timeout in tb_w25q128jv");
    $fatal(1);
  end

endmodule
