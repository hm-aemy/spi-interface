// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Self-checking testbench for the behavioural 23LC1024 SRAM model.
//
// Drives the chip DIRECTLY via a bit-banging master (cs_n / sclk / sio[3:0]),
// Mode 0: master drives data while SCK is low, model samples on rising SCK and
// drives read data on falling SCK; the master samples read data on rising SCK.
//
// The TB is meant to grow IN LOCKSTEP with the model. Implement one rung of the
// ladder, run `make`, watch it stay green, then climb the next rung:
//
//   step 0  build + CS/SCK framing toggles            <-- works out of the box
//   step 1  Single-SPI WRITE 1 byte -> READ 1 byte
//   step 2  Sequential READ of N bytes
//   step 3  WRMR / RDMR (mode register, default 0x40)
//   step 4  EQIO -> SQI WRITE / READ (+ 1 dummy byte on read)
//   step 5  EDIO/SDI, RSTIO, page-wrap
//
`timescale 1ns/1ps

module tb_s23lc1024;

  // ------------------------------------------------------------------------
  // Bit-banging timing (sim-only; real chip is 20 MHz, here we just pick a
  // convenient SCK period). One full SCK cycle = TCK.
  // ------------------------------------------------------------------------
  localparam time TCK = 50ns;

  // Opcodes (datasheet) -- model-local copies for the master to send.
  localparam logic [7:0] CMD_READ  = 8'h03;
  localparam logic [7:0] CMD_WRITE = 8'h02;
  localparam logic [7:0] CMD_EDIO  = 8'h3B;
  localparam logic [7:0] CMD_EQIO  = 8'h38;
  localparam logic [7:0] CMD_RSTIO = 8'hFF;
  localparam logic [7:0] CMD_RDMR  = 8'h05;
  localparam logic [7:0] CMD_WRMR  = 8'h01;

  // ------------------------------------------------------------------------
  // DUT pins + master drive signals
  // ------------------------------------------------------------------------
  logic       cs_n;
  logic       sclk;

  // Master-driven lanes (m_oe[i]=1 -> master drives lane i).
  logic [3:0] m_o;
  logic [3:0] m_oe;

  // Model-driven lanes.
  logic [3:0] dut_o;
  logic [3:0] dut_oe;

  // Resolved bus. The protocol guarantees master and model never drive at the
  // same time, so a priority mux (model wins, else master, else idle-0) models
  // the shared net cleanly for Verilator -- no real 'z' needed.
  wire  [3:0] sio;
  for (genvar i = 0; i < 4; i++) begin : g_sio
    assign sio[i] = dut_oe[i] ? dut_o[i] : (m_oe[i] ? m_o[i] : 1'b0);
  end

  // ------------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------------
  s23lc1024 #(
    .INIT_FILE ("")
  ) dut (
    .cs_ni  (cs_n),
    .sclk_i (sclk),
    .sio_i  (sio),
    .sio_o  (dut_o),
    .sio_oe (dut_oe)
  );

  // ------------------------------------------------------------------------
  // Pass/Fail bookkeeping
  // ------------------------------------------------------------------------
  int unsigned errors = 0;

  task automatic check(input logic [7:0] got, input logic [7:0] exp,
                       input string what);
    if (got !== exp) begin
      $error("[FAIL] %s: got=%02x exp=%02x", what, got, exp);
      errors++;
    end else begin
      $display("[ ok ] %s = %02x", what, got);
    end
  endtask

  // ========================================================================
  // Low-level bus primitives  (INFRASTRUCTURE -- ready to use)
  // ========================================================================

  // Idle the bus: CS high, SCK low (Mode 0 rest state), master not driving.
  task automatic bus_idle;
    cs_n = 1'b1;
    sclk = 1'b0;
    m_o  = 4'b0000;
    m_oe = 4'b0000;
  endtask

  // Assert CS (start a transaction). Datasheet: setup time before first SCK.
  task automatic cs_assert;
    cs_n = 1'b0;
    #(TCK/2);
  endtask

  // Deassert CS (end a transaction). Model applies a pending bus-mode switch
  // (EQIO/EDIO/RSTIO) on this rising edge.
  task automatic cs_release;
    #(TCK/2);
    m_oe = 4'b0000;
    cs_n = 1'b1;
    #(TCK);
  endtask

  // One SCK cycle with the data lanes already set up by the caller:
  //   - data is expected to be valid now (SCK low),
  //   - rising edge  -> model samples,
  //   - falling edge -> model may drive the next read bit.
  // Returns the lane values sampled at the rising edge (for read paths).
  task automatic sck_cycle(output logic [3:0] sampled);
    #(TCK/2);
    sclk    = 1'b1;
    sampled = sio;     // sample on rising edge (model output is stable here)
    #(TCK/2);
    sclk    = 1'b0;
  endtask

  // ========================================================================
  // Byte-level master tasks
  //
  // All bytes are MSB-first. Use sck_cycle() per SCK tick and set m_o / m_oe
  // before each rising edge. Remember the lane mapping:
  //
  //   SPI : send on SI = sio[0]            (m_oe = 4'b0001)
  //         recv on SO = sio[1]
  //   SQI : send/recv on sio[3:0], top nibble first (m_oe = 4'b1111 to send)
  // ========================================================================

  // ---- Single-SPI -------------------------------------------------------
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
    m_oe = 4'b0000;  // release the bus (master not driving)
    for (int k = 7; k >= 0; k--) begin
      sck_cycle(s);
      b[k] = s[1];  // sample SO = sio[1]
    end
  endtask

  // ---- SQI (quad) -------------------------------------------------------
  task automatic sqi_send_byte(input logic [7:0] b);
    logic [3:0] dummy;

    m_oe = 4'b1111;
    m_o = b[7:4];
    sck_cycle(dummy);
    m_o = b[3:0];
    sck_cycle(dummy);
  endtask

  task automatic sqi_recv_byte(output logic [7:0] b);
    logic [3:0] s;
    b = '0;
    m_oe = 4'h0;

    sck_cycle(s);
    b[7:4] = s;
    sck_cycle(s);
    b[3:0] = s;
  endtask

  // ---- SDI (dual) -------------------------------------------------------
  task automatic sdi_send_byte(input logic [7:0] b);
    logic [3:0] dummy;
    m_oe = 4'b0011;
    for (int k = 3; k >= 0; k--) begin
      m_o[1:0] = b[2*k +: 2];
      sck_cycle(dummy);
    end
  endtask

  task automatic sdi_recv_byte(output logic [7:0] b);
    logic [3:0] s;
    b = '0;
    m_oe = 4'h0;
    for (int k = 3; k >= 0; k--) begin
      sck_cycle(s);
      b[2*k +: 2] = s[1:0];
    end
  endtask

  // ========================================================================
  // High-level command helpers  (build on the byte tasks -- TODO)
  // Tip: keep these protocol-accurate, then the test bodies read like prose.
  // ========================================================================

  // SPI WRITE: opcode 0x02, 24-bit addr, then data bytes.
  task automatic spi_write(input logic [23:0] addr, input logic [7:0] data []);
    cs_assert;
    spi_send_byte(CMD_WRITE);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    foreach (data[i]) begin
      spi_send_byte(data[i]);
    end
    cs_release;
  endtask

  // SPI READ: opcode 0x03, 24-bit addr, then read `n` bytes back.
  task automatic spi_read(input logic [23:0] addr, input int n,
                          output logic [7:0] data []);
    data = new[n];
    cs_assert;
    spi_send_byte(CMD_READ);
    spi_send_byte(addr[23:16]);
    spi_send_byte(addr[15:8]);
    spi_send_byte(addr[7:0]);
    for (int i = 0; i < n; i++) begin
      spi_recv_byte(data[i]);
    end
    cs_release;
  endtask

  // Single no-arg command in the CURRENT bus mode (EQIO/EDIO/RSTIO). The mode
  // switch takes effect at CS release.
  task automatic mode_cmd(input logic [7:0] op, input int lanes);
    cs_assert;
    case (lanes)
      1: spi_send_byte(op);
      2: sdi_send_byte(op);
      4: sqi_send_byte(op);
      default: $fatal(1, "bad lane count");
    endcase
    cs_release;
  endtask

  // WRMR / RDMR over single-SPI.
  task automatic spi_wrmr(input logic [7:0] mr);
    cs_assert;
    spi_send_byte(CMD_WRMR);
    spi_send_byte(mr);
    cs_release;
  endtask

  task automatic spi_rdmr(output logic [7:0] mr);
    cs_assert;
    spi_send_byte(CMD_RDMR);
    spi_recv_byte(mr);
    cs_release;
  endtask

  // SQI WRITE: instr(2 SCK) + addr(6 SCK) + data, no dummy.
  task automatic sqi_write(input logic [23:0] addr, input logic [7:0] data []);
    cs_assert;
    sqi_send_byte(CMD_WRITE);
    sqi_send_byte(addr[23:16]);
    sqi_send_byte(addr[15:8]);
    sqi_send_byte(addr[7:0]);
    foreach (data[i]) sqi_send_byte(data[i]);
    cs_release;
  endtask

  // SQI READ: instr + addr + 1 DUMMY byte (2 SCK, bus released) + data.
  task automatic sqi_read(input logic [23:0] addr, input int n,
                          output logic [7:0] data []);
    logic [7:0] scratch;
    data = new[n];
    cs_assert;
    sqi_send_byte(CMD_READ);
    sqi_send_byte(addr[23:16]);
    sqi_send_byte(addr[15:8]);
    sqi_send_byte(addr[7:0]);
    sqi_recv_byte(scratch);                  // dummy byte (bus turnaround)
    for (int i = 0; i < n; i++) sqi_recv_byte(data[i]);
    cs_release;
  endtask

  // SDI WRITE / READ (read has 1 dummy byte, like SQI).
  task automatic sdi_write(input logic [23:0] addr, input logic [7:0] data []);
    cs_assert;
    sdi_send_byte(CMD_WRITE);
    sdi_send_byte(addr[23:16]);
    sdi_send_byte(addr[15:8]);
    sdi_send_byte(addr[7:0]);
    foreach (data[i]) sdi_send_byte(data[i]);
    cs_release;
  endtask

  task automatic sdi_read(input logic [23:0] addr, input int n,
                          output logic [7:0] data []);
    logic [7:0] scratch;
    data = new[n];
    cs_assert;
    sdi_send_byte(CMD_READ);
    sdi_send_byte(addr[23:16]);
    sdi_send_byte(addr[15:8]);
    sdi_send_byte(addr[7:0]);
    sdi_recv_byte(scratch);                  // dummy byte
    for (int i = 0; i < n; i++) sdi_recv_byte(data[i]);
    cs_release;
  endtask

  // ========================================================================
  // Test sequences
  // ========================================================================

  // ---- step 0: build + framing baseline (works with an empty model) -----
  task automatic test_framing;
    logic [3:0] s;
    $display("== step 0: CS/SCK framing ==");
    cs_assert;
    repeat (8) sck_cycle(s);     // 8 idle clocks under CS -- just to see edges
    cs_release;
    $display("[ ok ] framing toggled (inspect tb_s23lc1024.fst in Surfer)");
  endtask

  // ---- step 1: Single-SPI write-then-read of one byte -------------------
  task automatic test_spi_single_byte;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 1: SPI write/read 1 byte ==");
    wr = '{8'hA5};
    spi_write(24'h00_1234, wr);
    rd = new[1];
    spi_read(24'h00_1234, 1, rd);
    check(rd[0], 8'hA5, "spi single byte @0x1234");
  endtask

  // ---- step 2: Sequential read of N bytes -------------------------------
  task automatic test_spi_sequential;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 2: SPI sequential write/read 8 bytes ==");
    wr = new[8];
    foreach (wr[i]) wr[i] = 8'h10 + 8'(i);
    spi_write(24'h00_0100, wr);
    spi_read(24'h00_0100, 8, rd);
    foreach (rd[i]) check(rd[i], wr[i], $sformatf("spi seq byte %0d", i));
  endtask

  // ---- step 3: WRMR / RDMR ----------------------------------------------
  task automatic test_mode_reg;
    logic [7:0] mr;
    $display("== step 3: WRMR/RDMR ==");
    spi_rdmr(mr);
    check(mr, 8'h40, "power-on mode reg (sequential)");
    spi_wrmr(8'h00);
    spi_rdmr(mr);
    check(mr, 8'h00, "mode reg after WRMR 0x00 (byte)");
    spi_wrmr(8'h40);
    spi_rdmr(mr);
    check(mr, 8'h40, "mode reg restored (sequential)");
  endtask

  // ---- step 4: EQIO -> SQI write/read ------------------------------------
  task automatic test_sqi;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 4: EQIO -> SQI write/read ==");
    mode_cmd(CMD_EQIO, 1);                    // sent in SPI, applies at CS rise
    wr = new[8];
    foreach (wr[i]) wr[i] = 8'hC0 ^ (8'(i) * 8'h11);
    sqi_write(24'h00_5678, wr);
    sqi_read(24'h00_5678, 8, rd);
    foreach (rd[i]) check(rd[i], wr[i], $sformatf("sqi byte %0d", i));
    // Cross-mode: data written earlier via SPI must be readable via SQI.
    sqi_read(24'h00_1234, 1, rd);
    check(rd[0], 8'hA5, "sqi reads spi-written byte @0x1234");
    // Back to SPI: RSTIO is sent on 4 lanes while still in SQI.
    mode_cmd(CMD_RSTIO, 4);
    spi_read(24'h00_5678, 1, rd);
    check(rd[0], wr[0], "spi reads sqi-written byte after RSTIO");
  endtask

  // ---- step 5a: EDIO -> SDI write/read ------------------------------------
  task automatic test_sdi;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 5a: EDIO -> SDI write/read ==");
    mode_cmd(CMD_EDIO, 1);
    wr = new[4];
    foreach (wr[i]) wr[i] = 8'h5A + 8'(i);
    sdi_write(24'h00_0800, wr);
    sdi_read(24'h00_0800, 4, rd);
    foreach (rd[i]) check(rd[i], wr[i], $sformatf("sdi byte %0d", i));
    mode_cmd(CMD_RSTIO, 2);                   // RSTIO on 2 lanes from SDI
  endtask

  // ---- step 5b: page-mode wrap (32-byte page) -----------------------------
  task automatic test_page_wrap;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 5b: page-mode 32B wrap ==");
    spi_wrmr(8'h80);                          // page mode
    wr = new[4];
    foreach (wr[i]) wr[i] = 8'hE0 + 8'(i);
    spi_write(24'h00_005E, wr);               // 0x5E,0x5F -> wrap -> 0x40,0x41
    spi_wrmr(8'h40);                          // sequential for readback
    spi_read(24'h00_005E, 2, rd);
    check(rd[0], wr[0], "page byte @0x5E");
    check(rd[1], wr[1], "page byte @0x5F");
    spi_read(24'h00_0040, 2, rd);
    check(rd[0], wr[2], "page-wrapped byte @0x40");
    check(rd[1], wr[3], "page-wrapped byte @0x41");
  endtask

  // ---- step 5c: sequential wrap at array end + addr don't-care bits -------
  task automatic test_seq_wrap;
    logic [7:0] wr [];
    logic [7:0] rd [];
    $display("== step 5c: sequential wrap 0x1FFFF -> 0x00000 ==");
    wr = '{8'hDE, 8'hAD};
    spi_write(24'h01_FFFF, wr);               // 2nd byte wraps to 0x00000
    spi_read(24'h01_FFFF, 1, rd);
    check(rd[0], 8'hDE, "byte @0x1FFFF");
    spi_read(24'h00_0000, 1, rd);
    check(rd[0], 8'hAD, "wrapped byte @0x00000");
    // Upper 7 address bits are don't-care: 0xFF_FFFF decodes to 0x1FFFF.
    spi_read(24'hFF_FFFF, 1, rd);
    check(rd[0], 8'hDE, "don't-care addr bits @0xFFFFFF");
  endtask

  // ========================================================================
  // Main
  // ========================================================================
  initial begin
    $dumpfile("tb_s23lc1024.fst");
    $dumpvars(0, tb_s23lc1024);

    bus_idle;
    #(TCK);

    test_spi_single_byte;
    test_spi_sequential;
    test_mode_reg;
    test_sqi;
    test_sdi;
    test_page_wrap;
    test_seq_wrap;

    if (errors == 0)
      $display("TB PASSED");
    else
      $fatal(1, "TB FAILED: %0d error(s)", errors);

    $finish;
  end

  // Watchdog
  initial begin
    #1_000_000;
    $error("Timeout in tb_s23lc1024");
    $fatal(1);
  end

endmodule
