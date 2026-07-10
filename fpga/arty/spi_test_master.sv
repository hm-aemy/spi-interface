// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Synthesizable self-checking SPI/SQI test-master core for the 23LC1024
// Arty-A7 bring-up (Phase 3). Runs entirely on the board clock (no #delays,
// no tasks, no $display in the data path) so it can be placed on Board B and
// drive the s23lc1024 model instantiated on Board A over a Pmod cable.
//
// Sequence (fixed, deterministic, matches tb_s23lc1024.sv's protocol steps):
//   0. RSTIO on 4 lanes            -- defensive: brings the chip back to SPI
//                                      even if it was left in SQI by a
//                                      previous run (Board A is not reset
//                                      together with Board B, see primer
//                                      docs/01_chip_23lc1024.md §7.5).
//   1. SPI  WRITE 0x02 @ ADDR1, 8 pattern bytes (PATTERN1)
//   2. SPI  READ  0x03 @ ADDR1, 8 bytes back, compare against PATTERN1
//   3. SPI  EQIO  0x38             -- switch to SQI (applies at CS-rise)
//   4. SQI  WRITE 0x02 @ ADDR2, 8 pattern bytes (PATTERN2)
//   5. SQI  READ  0x03 @ ADDR2, 1 dummy byte + 8 bytes, compare vs PATTERN2
//   6. SQI  RSTIO 0xFF on 4 lanes  -- back to SPI, so the NEXT run (after a
//                                      Board-B-only reset) starts from a
//                                      known state again.
//
// -----------------------------------------------------------------------
// DESIGN IDIOM -- deliberately mirrors model/s23lc1024.sv
// -----------------------------------------------------------------------
// Just like the memory model, this core uses ONE unified bit counter
// (`bit_cnt`, counts by `lane` per SCK edge) to derive which protocol phase
// is active, instead of a big explicit FSM per bit. The two clocked actions
// are split the same way as in the model, just with TX/RX roles swapped
// (we are the master now):
//   - drive TX bytes (opcode/addr/write-data)   -> on the FALLING sck edge
//   - sample RX bytes (read-data) + advance
//     bit_cnt                                   -> on the RISING sck edge
// This symmetry is what makes the timing line up with the model without
// extra head-scratching: the model itself drives on negedge/samples on
// posedge, so "our fall" is exactly "its setup before its sample" and vice
// versa. See docs/07_verhaltensmodelle.md §3 for the underlying idea.
//
// One subtlety the model does not have to deal with: WE decide when a new
// transaction (CS low) starts, and the model is not clock-gated -- it reacts
// to whatever edges happen while cs_ni is low. If CS went low at a random
// point in the free-running SCK cycle, a stray rising edge could sneak in
// before we have the first bit ready, corrupting the whole bit alignment for
// that transaction. We avoid that by only ever asserting cs_no in the exact
// same cycle as the falling edge that also drives bit 0 (state ST_ARM below)
// -- CS and the first data bit become valid together, so the very next SCK
// event the model sees while cs_ni=0 is a rising edge sampling that bit 0,
// exactly as intended.
// -----------------------------------------------------------------------

module spi_test_master #(
    // SCK = clk / (2*SCK_HALF_PERIOD). Default 50 -> 1 MHz SCK @ 100 MHz clk
    // (comfortably below the chip's 20 MHz max -- see docs/01_chip_23lc1024.md
    // §5.2). Bump this up (e.g. 5000 -> ~10 kHz) if the inter-board cable is
    // too flaky for 1 MHz; see docs/fpga_flow.md §d/e.
    parameter int unsigned SCK_HALF_PERIOD = 50
) (
    input  logic       clk,      // board clock (100 MHz on Arty A7)
    input  logic       rst_n,    // sync reset, active low
    input  logic       start_i,  // 1-cycle pulse: (re)start the test sequence

    // Bus towards the memory model. Tri-state is resolved OUTSIDE this
    // module (top_master.sv for the real board, tb_arty_pair.sv in sim) --
    // same o/oe/i discipline as model/s23lc1024.sv.
    output logic       cs_no,
    output logic       sclk_o,
    input  logic [3:0] sio_i,
    output logic [3:0] sio_o,
    output logic [3:0] sio_oe,

    // Status
    output logic       done_o,      // sequence finished, stays high until start_i
    output logic       pass_o,      // valid while done_o: 1 = all checks passed
    output logic [3:0] progress_o   // current/last transaction index (LD0..3)
);

  // -----------------------------------------------------------------------
  // Constants -- shared opcodes with model/s23lc1024.sv, kept as local copies
  // (this module must stand alone as synthesizable RTL, no shared package).
  // -----------------------------------------------------------------------
  localparam logic [7:0] CMD_READ  = 8'h03;
  localparam logic [7:0] CMD_WRITE = 8'h02;
  localparam logic [7:0] CMD_EQIO  = 8'h38;
  localparam logic [7:0] CMD_RSTIO = 8'hFF;

  localparam logic [23:0] ADDR1 = 24'h000100;  // single-SPI write/read target
  localparam logic [23:0] ADDR2 = 24'h000200;  // SQI write/read target

  localparam logic [7:0] PATTERN1[0:7] = '{
      8'hA0, 8'hA1, 8'hA2, 8'hA3, 8'hA4, 8'hA5, 8'hA6, 8'hA7
  };
  localparam logic [7:0] PATTERN2[0:7] = '{
      8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57
  };

  // -----------------------------------------------------------------------
  // Transaction sequence
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] {
    TxnRstio0,
    TxnWr1,
    TxnRd1,
    TxnEqio,
    TxnWr2,
    TxnRd2,
    TxnRstio1
  } txn_e;

  function automatic int unsigned txn_lane(txn_e t);
    case (t)
      TxnWr1, TxnRd1, TxnEqio: txn_lane = 1;
      default:                 txn_lane = 4;  // TxnRstio0/1, TxnWr2, TxnRd2
    endcase
  endfunction

  // Number of bytes the MASTER drives (opcode + address + write-data).
  function automatic int unsigned n_tx_bytes(txn_e t);
    case (t)
      TxnRstio0, TxnEqio, TxnRstio1: n_tx_bytes = 1;
      TxnWr1, TxnWr2:                n_tx_bytes = 12;  // op(1)+addr(3)+data(8)
      TxnRd1, TxnRd2:                n_tx_bytes = 4;   // op(1)+addr(3)
      default:                       n_tx_bytes = 0;
    endcase
  endfunction

  // Dummy byte only on the SQI read (bus turnaround, see primer §6.2).
  function automatic int unsigned n_dummy_bytes(txn_e t);
    n_dummy_bytes = (t == TxnRd2) ? 1 : 0;
  endfunction

  function automatic int unsigned n_rx_bytes(txn_e t);
    n_rx_bytes = (t == TxnRd1 || t == TxnRd2) ? 8 : 0;
  endfunction

  function automatic txn_e next_txn(txn_e t);
    case (t)
      TxnRstio0: next_txn = TxnWr1;
      TxnWr1:    next_txn = TxnRd1;
      TxnRd1:    next_txn = TxnEqio;
      TxnEqio:   next_txn = TxnWr2;
      TxnWr2:    next_txn = TxnRd2;
      TxnRd2:    next_txn = TxnRstio1;
      default:   next_txn = TxnRstio1;  // TxnRstio1: stays (ST_GAP handles DONE)
    endcase
  endfunction

  // Byte value the master drives at TX byte index `idx` (0-based) of txn `t`.
  function automatic logic [7:0] tx_byte_value(txn_e t, int unsigned idx);
    case (t)
      TxnRstio0, TxnRstio1: tx_byte_value = CMD_RSTIO;
      TxnEqio:              tx_byte_value = CMD_EQIO;
      TxnWr1: begin
        case (idx)
          0: tx_byte_value = CMD_WRITE;
          1: tx_byte_value = ADDR1[23:16];
          2: tx_byte_value = ADDR1[15:8];
          3: tx_byte_value = ADDR1[7:0];
          default: tx_byte_value = PATTERN1[idx-4];
        endcase
      end
      TxnRd1: begin
        case (idx)
          0: tx_byte_value = CMD_READ;
          1: tx_byte_value = ADDR1[23:16];
          2: tx_byte_value = ADDR1[15:8];
          default: tx_byte_value = ADDR1[7:0];  // idx == 3
        endcase
      end
      TxnWr2: begin
        case (idx)
          0: tx_byte_value = CMD_WRITE;
          1: tx_byte_value = ADDR2[23:16];
          2: tx_byte_value = ADDR2[15:8];
          3: tx_byte_value = ADDR2[7:0];
          default: tx_byte_value = PATTERN2[idx-4];
        endcase
      end
      TxnRd2: begin
        case (idx)
          0: tx_byte_value = CMD_READ;
          1: tx_byte_value = ADDR2[23:16];
          2: tx_byte_value = ADDR2[15:8];
          default: tx_byte_value = ADDR2[7:0];  // idx == 3
        endcase
      end
      default: tx_byte_value = 8'h00;
    endcase
  endfunction

  // Expected value of RX byte index `idx` (0-based) of txn `t`.
  function automatic logic [7:0] expected_rx_byte(txn_e t, int unsigned idx);
    case (t)
      TxnRd1:  expected_rx_byte = PATTERN1[idx];
      TxnRd2:  expected_rx_byte = PATTERN2[idx];
      default: expected_rx_byte = 8'h00;
    endcase
  endfunction

  // -----------------------------------------------------------------------
  // SCK generator: two combinational one-cycle-wide pulses, no extra latency
  // relative to the sclk_o register update (see header comment).
  // -----------------------------------------------------------------------
  localparam int unsigned DIV_W = $clog2(SCK_HALF_PERIOD + 1);
  logic [DIV_W-1:0] div_cnt;
  logic             sck_r;

  wire sck_tick = (div_cnt == DIV_W'(SCK_HALF_PERIOD - 1));
  wire sck_fall = sck_tick & sck_r;
  wire sck_rise = sck_tick & ~sck_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_cnt <= '0;
      sck_r   <= 1'b0;
    end else if (sck_tick) begin
      div_cnt <= '0;
      sck_r   <= ~sck_r;
    end else begin
      div_cnt <= div_cnt + 1'b1;
    end
  end

  assign sclk_o = sck_r;

  // -----------------------------------------------------------------------
  // Main sequencer + bit engine
  // -----------------------------------------------------------------------
  typedef enum logic [2:0] { StIdle, StArm, StActive, StEndWait, StGap } state_e;

  (* fsm_encoding = "none" *) state_e state;
  (* fsm_encoding = "none" *) txn_e txn;
  int unsigned bit_cnt;    // unified counter, counts by `lane` per SCK edge
  logic [7:0]  out_byte;   // TX shift-out register (mirrors model's out_byte)
  logic [7:0]  shreg;      // RX shift-in accumulator (mirrors model's shreg)
  logic [15:0] gap_cnt;    // inter-transaction CS-high hold
  logic        fail_sticky;

  localparam int unsigned GAP_CYCLES = 4 * SCK_HALF_PERIOD;  // >> tCSH=50ns

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= StIdle;
      txn         <= TxnRstio0;
      bit_cnt     <= 0;
      out_byte    <= '0;
      shreg       <= '0;
      gap_cnt     <= '0;
      fail_sticky <= 1'b0;
      cs_no       <= 1'b1;
      sio_o       <= '0;
      sio_oe      <= '0;
      done_o      <= 1'b0;
      pass_o      <= 1'b0;
    end else begin
      // Local, per-cycle decodes of the active transaction (cheap combinational
      // logic re-evaluated every cycle; txn only changes at transaction
      // boundaries, so this is stable for the whole transaction).
      automatic int unsigned lane     = txn_lane(txn);
      automatic int unsigned tx_end   = 8 * n_tx_bytes(txn);
      automatic int unsigned dmy_end  = tx_end + 8 * n_dummy_bytes(txn);
      automatic int unsigned rx_end   = dmy_end + 8 * n_rx_bytes(txn);

      case (state)
        // ---------------------------------------------------------------
        StIdle: begin
          // done_o/pass_o are LEVELS: they hold the last result until the
          // next start (an unconditional clear here would shrink done_o to a
          // single-cycle pulse that level-sampling consumers -- LEDs, the
          // UART reporter in top_loopback.sv -- would simply miss).
          if (start_i) begin
            done_o      <= 1'b0;
            fail_sticky <= 1'b0;
            txn         <= TxnRstio0;   // restart runs the FULL sequence
            bit_cnt     <= 0;
            state       <= StArm;
          end
        end

        // ---------------------------------------------------------------
        // Waiting (CS still high) for the falling edge that will both
        // assert CS and drive bit 0 of the first TX byte -- see header.
        StArm: begin
          if (sck_fall) begin
            cs_no <= 1'b0;
            state <= StActive;
            // Fall through to the same drive logic as StActive/bit_cnt==0
            // below (bit_cnt is already 0 here).
          end
        end

        // ---------------------------------------------------------------
        StActive: begin
          // Nothing state-level to do here besides the shared edge logic
          // below; the transition out of StActive (-> StEndWait) happens
          // there.
        end

        // ---------------------------------------------------------------
        // The last bit was sampled on a RISING edge (in StActive, below).
        // We deliberately do NOT drop cs_no on that same edge: the model
        // latches its last received byte / advances its address using that
        // very rising edge too (posedge sclk_i), and also reacts to CS-high
        // on `posedge cs_ni`. Changing cs_no in the same delta cycle as the
        // model's sampling edge is a simulation race (two events on one
        // sensitivity list at the same time step) that can corrupt the last
        // byte of a transaction. Waiting for the NEXT falling edge before
        // asserting cs_no mirrors the real half-period CS-hold used by
        // test/tb_s23lc1024.sv's cs_release task and sidesteps the race.
        StEndWait: begin
          if (sck_fall) begin
            cs_no   <= 1'b1;
            sio_oe  <= '0;
            gap_cnt <= '0;
            state   <= StGap;
          end
        end

        // ---------------------------------------------------------------
        StGap: begin
          sio_oe <= '0;
          if (gap_cnt == 16'(GAP_CYCLES - 1)) begin
            gap_cnt <= '0;
            if (txn == TxnRstio1) begin
              done_o <= 1'b1;
              pass_o <= ~fail_sticky;
              state  <= StIdle;
            end else begin
              txn     <= next_txn(txn);
              bit_cnt <= 0;
              state   <= StArm;
            end
          end else begin
            gap_cnt <= gap_cnt + 1'b1;
          end
        end

        default: ;  // state_e is 3 bits wide for 5 values; unreachable otherwise
      endcase

      // -------------------------------------------------------------------
      // Shared bit engine -- runs whenever a transaction is in progress
      // (StArm's arming fall counts as bit_cnt==0 of StActive; both states
      // are covered by the same TX-drive condition below).
      // -------------------------------------------------------------------
      if ((state == StArm && sck_fall) || (state == StActive)) begin
        // ---- FALL: drive the next TX bits (mirrors model's drive block) --
        if (sck_fall && bit_cnt < tx_end) begin
          automatic logic [7:0] cur;
          automatic int unsigned b = bit_cnt % 8;
          cur = (b == 0) ? tx_byte_value(txn, bit_cnt / 8) : (out_byte << lane);
          out_byte <= cur;
          case (lane)
            1: begin
              sio_o[0] <= cur[7];
              sio_oe   <= 4'b0001;
            end
            4: begin
              sio_o[3:0] <= cur[7:4];
              sio_oe     <= 4'b1111;
            end
            default: ;
          endcase
        end else if (sck_fall) begin
          // Dummy phase or nothing left to drive: release the bus.
          sio_oe <= '0;
        end

        // ---- RISE: advance bit_cnt, sample RX bits (mirrors sample block) -
        if (sck_rise && state == StActive) begin
          automatic logic [7:0]  shreg_n;
          automatic int unsigned new_cnt = bit_cnt + lane;

          // SPI special case (lane==1): the model drives read-data on SO =
          // SIO1, not SIO0 (SIO0 stays the master's SI the whole time) --
          // see model/s23lc1024.sv's drive block and
          // test/tb_s23lc1024.sv::spi_recv_byte.
          case (lane)
            4: shreg_n = {shreg[3:0], sio_i[3:0]};
            default: shreg_n = {shreg[6:0], sio_i[1]};
          endcase

          if (bit_cnt >= dmy_end) shreg <= shreg_n;

          if (bit_cnt >= dmy_end && new_cnt > dmy_end &&
              ((new_cnt - dmy_end) % 8 == 0)) begin
            automatic int unsigned rxi = (new_cnt - dmy_end) / 8 - 1;
            if (shreg_n != expected_rx_byte(txn, rxi)) fail_sticky <= 1'b1;
          end

          if (new_cnt >= rx_end) begin
            // Transaction's last bit just sampled. Do NOT touch cs_no here
            // -- see the StEndWait comment above. Just park bit_cnt and wait
            // for the next falling edge to actually release CS.
            bit_cnt <= 0;
            state   <= StEndWait;
          end else begin
            bit_cnt <= new_cnt;
          end
        end
      end
    end
  end

  assign progress_o = {1'b0, txn};

endmodule
