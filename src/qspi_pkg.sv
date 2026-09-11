// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Types, register layout and constants of the QSPI controller.
// Register map (32-bit registers, byte offsets in the CSR window):
//
//   0x00 CR    [0] EN         enable controller
//              [1] ABORT      abort current transfer (self-clearing)
//              [15:8] PRESCALER  SCK = clk / (2*(PRESCALER+1))
//   0x04 DCR   [4:0]  FSIZE   device size = 2^(FSIZE+1) bytes
//              [10:8] CSHT    min. CS-high time between commands (SCK cycles)
//   0x08 SR    [0] TEF  [1] TCF  [5] BUSY  [13:8] FLEVEL (read-only)
//   0x0C FCR   [0] CTEF [1] CTCF          write 1 to clear
//   0x10 DLR   [31:0] data length - 1 (bytes) for indirect transfers
//   0x14 CCR   [7:0]   INSTRUCTION
//              [9:8]   IMODE   00 skip / 01 single / 10 dual / 11 quad
//              [11:10] ADMODE
//              [13:12] ADSIZE  address bytes - 1 (00=1 ... 11=4)
//              [15:14] ABMODE
//              [17:16] ABSIZE  alternate bytes - 1
//              [22:18] DCYC    dummy cycles (SCK)
//              [25:24] DMODE
//              [27:26] FMODE   00 ind. write / 01 ind. read / 11 memory-mapped
//   0x18 AR    transfer address (chip address)
//   0x1C ABR   alternate bytes (sent MSByte first)
//   0x20 DR    FIFO data port (byte/half/word by byte-enable)
//   0x24 WCCR  frame format for memory-mapped WRITES (same fields as CCR,
//              FMODE ignored). DMODE=00 -> mmap writes rejected (bus error).
//
// Command triggers (indirect mode, only when !BUSY):
//   - CCR write, ADMODE=00:  FMODE=01 -> start; FMODE=00 & DMODE=00 -> start
//   - AR  write, ADMODE!=00: FMODE=01 -> start; FMODE=00 & DMODE=00 -> start
//   - DR  write, FMODE=00 & DMODE!=00 -> start (data taken from FIFO)

package qspi_pkg;

  // CSR byte offsets
  localparam logic [7:0] QSPI_CR   = 8'h00;
  localparam logic [7:0] QSPI_DCR  = 8'h04;
  localparam logic [7:0] QSPI_SR   = 8'h08;
  localparam logic [7:0] QSPI_FCR  = 8'h0C;
  localparam logic [7:0] QSPI_DLR  = 8'h10;
  localparam logic [7:0] QSPI_CCR  = 8'h14;
  localparam logic [7:0] QSPI_AR   = 8'h18;
  localparam logic [7:0] QSPI_ABR  = 8'h1C;
  localparam logic [7:0] QSPI_DR   = 8'h20;
  localparam logic [7:0] QSPI_WCCR = 8'h24;

  // Phase / lane mode (per *MODE field)
  typedef enum logic [1:0] {
    PhSkip   = 2'b00,
    PhSingle = 2'b01,
    PhDual   = 2'b10,
    PhQuad   = 2'b11
  } phase_mode_e;

  // Functional mode (CCR.FMODE)
  typedef enum logic [1:0] {
    FmIndWrite = 2'b00,
    FmIndRead  = 2'b01,
    FmReserved = 2'b10,
    FmMemMap   = 2'b11
  } fmode_e;

  // Decoded CCR (identical layout for CCR and WCCR)
  typedef struct packed {
    fmode_e      fmode;    // [27:26]
    phase_mode_e dmode;    // [25:24]
    logic [4:0]  dcyc;     // [22:18]
    logic [1:0]  absize;   // [17:16]
    phase_mode_e abmode;   // [15:14]
    logic [1:0]  adsize;   // [13:12]
    phase_mode_e admode;   // [11:10]
    phase_mode_e imode;    // [9:8]
    logic [7:0]  instruction; // [7:0]
  } ccr_t;

  function automatic ccr_t ccr_from_word(input logic [31:0] w);
    ccr_t c;
    c.instruction = w[7:0];
    c.imode       = phase_mode_e'(w[9:8]);
    c.admode      = phase_mode_e'(w[11:10]);
    c.adsize      = w[13:12];
    c.abmode      = phase_mode_e'(w[15:14]);
    c.absize      = w[17:16];
    c.dcyc        = w[22:18];
    c.dmode       = phase_mode_e'(w[25:24]);
    c.fmode       = fmode_e'(w[27:26]);
    return c;
  endfunction

  function automatic logic [31:0] ccr_to_word(input ccr_t c);
    logic [31:0] w;
    w        = '0;
    w[7:0]   = c.instruction;
    w[9:8]   = c.imode;
    w[11:10] = c.admode;
    w[13:12] = c.adsize;
    w[15:14] = c.abmode;
    w[17:16] = c.absize;
    w[22:18] = c.dcyc;
    w[25:24] = c.dmode;
    w[27:26] = c.fmode;
    return w;
  endfunction

  // Lane count per phase mode (as a shift amount: bits per SCK = 1 << ln2)
  function automatic logic [1:0] lanes_ln2(input phase_mode_e m);
    case (m)
      PhSingle: return 2'd0;
      PhDual:   return 2'd1;
      PhQuad:   return 2'd2;
      default:  return 2'd0;
    endcase
  endfunction

  // One command job handed from regs/mmap to the sequencer.
  typedef struct packed {
    ccr_t        ccr;       // frame format (CCR or WCCR)
    logic [31:0] addr;      // chip address (already FSIZE-checked)
    logic [31:0] alt;       // alternate bytes
    logic [31:0] len_m1;    // data bytes - 1
    logic        data_read; // 1 = data phase reads, 0 = writes
    logic        unlimited; // 1 = ignore len (mmap prefetch, runs until abort)
  } qspi_job_t;

endpackage
