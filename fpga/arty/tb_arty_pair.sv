// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Simulation-only proof that the synthesizable test-master core
// (spi_test_master, see fpga/arty/spi_test_master.sv) is protocol-correct
// BEFORE it goes anywhere near real hardware. Connects the core directly to
// the s23lc1024 behavioural model -- no real `inout`, tri-state resolved by
// a priority mux exactly like test/tb_s23lc1024.sv does (model wins, else
// master, else 0).
//
// This TB is the "proof of master correctness" gate mentioned in
// docs/fpga_flow.md: if this doesn't say TB PASSED, don't
// bother building bitstreams yet.
`timescale 1ns/1ps

module tb_arty_pair;

  // 100 MHz board clock, exactly like the real Arty A7.
  localparam time CLK_PERIOD = 10ns;

  logic clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  logic rst_n;
  logic start_i;

  // ------------------------------------------------------------------------
  // DUTs
  // ------------------------------------------------------------------------
  logic       cs_n;
  logic       sclk;
  logic [3:0] mst_o, mst_oe;
  logic [3:0] mdl_o, mdl_oe;
  logic       done, pass;
  logic [3:0] progress;

  // Shared bus: model wins if it drives, else master, else idle-0 -- same
  // resolution idiom as test/tb_s23lc1024.sv (no real 'z' needed for
  // simulation this way), and it matches how top_model.sv/top_master.sv
  // resolve the real Pmod-JA inout pins on hardware.
  wire [3:0] sio;
  for (genvar i = 0; i < 4; i++) begin : g_sio
    assign sio[i] = mdl_oe[i] ? mdl_o[i] : (mst_oe[i] ? mst_o[i] : 1'b0);
  end

  spi_test_master #(
      .SCK_HALF_PERIOD (5)   // faster than the real 50 -> shorter sim runtime
  ) master (
      .clk        (clk),
      .rst_n      (rst_n),
      .start_i    (start_i),
      .cs_no      (cs_n),
      .sclk_o     (sclk),
      .sio_i      (sio),
      .sio_o      (mst_o),
      .sio_oe     (mst_oe),
      .done_o     (done),
      .pass_o     (pass),
      .progress_o (progress)
  );

  s23lc1024 #(
      .INIT_FILE     (""),
      .MEM_ADDR_BITS (17)   // full array; protocol correctness, not capacity
  ) model (
      .cs_ni  (cs_n),
      .sclk_i (sclk),
      .sio_i  (sio),
      .sio_o  (mdl_o),
      .sio_oe (mdl_oe)
  );

  // Progress trace (sim-only, via hierarchical debug access into the DUT --
  // handy in Surfer/console without needing to add non-synthesizable probes
  // to spi_test_master.sv itself). Prints every transaction as it starts.
  logic [2:0] txn_prev;
  always @(posedge clk) begin
    if (!rst_n) begin
      txn_prev <= '0;
    end else begin
      if (master.txn !== txn_prev)
        $display("[ .. ] t=%0t master txn -> %s", $time, master.txn.name());
      txn_prev <= master.txn;
    end
  end

  // ------------------------------------------------------------------------
  // Drive reset + one start pulse, then a restart via a second pulse to make
  // sure the sequence is also correct the second time round (no model reset
  // in between -- this is exactly the "Master-Reset ohne Model-Reset" case
  // from the task).
  // ------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_arty_pair.fst");
    $dumpvars(0, tb_arty_pair);

    rst_n   = 1'b0;
    start_i = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // --- run 1 --------------------------------------------------------
    start_i = 1'b1;
    @(posedge clk);
    start_i = 1'b0;

    wait (done);
    @(posedge clk);
    if (pass) $display("[ ok ] run 1: pass_o=1");
    else $fatal(1, "[FAIL] run 1: pass_o=0 (fail_sticky was set)");

    // --- run 2: restart WITHOUT resetting the model -------------------
    // Board B can be reset independently of Board A on real hardware; the
    // sequence must still work because it opens with RSTIO on 4 lanes.
    repeat (20) @(posedge clk);
    start_i = 1'b1;
    @(posedge clk);
    start_i = 1'b0;

    wait (!done);          // done_o drops back to 0 while the new run is active
    wait (done);
    @(posedge clk);
    if (pass) $display("[ ok ] run 2 (no model reset): pass_o=1");
    else $fatal(1, "[FAIL] run 2 (no model reset): pass_o=0");

    $display("TB PASSED");
    $finish;
  end

  // Watchdog.
  initial begin
    #2_000_000;
    $error("Timeout in tb_arty_pair");
    $fatal(1);
  end

endmodule
