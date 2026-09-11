// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Behavioural, protocol-strict simulation model of the Winbond W25Q128JV
// NOR flash (128 Mbit = 16 MByte). READ-focused: all array-write commands
// (Page Program, Erase) are NOT implemented; unknown opcodes are ignored
// until the CS rise (the model drives nothing).
//
// Pin convention -- identical to model/s23lc1024.sv (no inout in the core):
//   sio_i  : what the bus drives  (model samples)
//   sio_o  : what the model drives
//   sio_oe : per-lane output enable (1 = drive, 0 = high-Z)
//
// Mode 0 (CPOL=0, CPHA=0): the master presents data while SCK is low; both
// sides sample on the rising edge. Hence, like the SRAM model, two clocked
// blocks (SAMPLE/DECODE on posedge, DRIVE on negedge) plus a CS-rise block
// for the QPI mode switch.
//
// -----------------------------------------------------------------------------
// WHY THIS MODEL COUNTS DIFFERENTLY THAN THE 23LC1024 MODEL
// -----------------------------------------------------------------------------
// On the 23LC1024 the lane width is constant for a WHOLE transaction (SPI/
// SDI/SQI), so a single "bit_cnt" (advancing by the lane width per edge) is
// enough to express phase boundaries as bit thresholds.
//
// On the W25Q128JV the lane widths mix WITHIN one transaction: e.g. 0x6B
// (Fast Read Quad Output) has a SINGLE-lane address but QUAD-lane data; 0xEB
// (Fast Read Quad I/O) even has address/mode byte/data all quad while the
// instruction stays single (outside QPI). A pure bit counter would no longer
// yield clean, opcode-independent phase boundaries here.
//
// This model therefore counts CLOCK EDGES ("edge_cnt", +1 per SCK edge,
// INDEPENDENT of the lane width) instead of bits. The phase boundaries
// (instr/addr/mode/dummy/data) are computed as edge counts from the opcode
// (see the *_edges() functions below); each edge then decides, based on the
// current phase, how many bits (1/2/4) this particular edge actually
// transports. That is the consistent generalisation of the phase-based
// approach to mixed lane widths.
//
// IMPORTANT PITFALL (and how we avoid it): the opcode phase ends and the
// address/dummy/data phases begin on the SAME edge on which the opcode is
// latched. All phase boundaries from the address onwards depend on the
// opcode -- but at that moment the `opcode` register still holds the OLD one
// (previous transaction), because the non-blocking assignment only becomes
// visible AFTER this edge. Every phase-boundary computation that depends on
// `opcode` is therefore explicitly wrapped in `if (edge_cnt >= instr_end)`:
// that condition only becomes true from the edge AFTER the opcode latch,
// when `opcode` is guaranteed fresh.
// -----------------------------------------------------------------------------

module w25q128jv #(
    // Optional memory preload (hex file, byte per line). Empty = all-erased.
    parameter string INIT_FILE = ""
) (
    input  logic       cs_ni,    // chip select, active low
    input  logic       sclk_i,   // serial clock (Mode 0)
    input  logic [3:0] sio_i,    // data lanes in
    output logic [3:0] sio_o,    // data lanes out
    output logic [3:0] sio_oe    // data lanes output-enable
);

  // -----------------------------------------------------------------------
  // Opcodes (datasheet, read-focused subset)
  // -----------------------------------------------------------------------
  localparam logic [7:0] CMD_READ   = 8'h03;  // Read Data
  localparam logic [7:0] CMD_FREAD  = 8'h0B;  // Fast Read
  localparam logic [7:0] CMD_DREAD  = 8'h3B;  // Fast Read Dual Output
  localparam logic [7:0] CMD_QREAD  = 8'h6B;  // Fast Read Quad Output
  localparam logic [7:0] CMD_QIO    = 8'hEB;  // Fast Read Quad I/O
  localparam logic [7:0] CMD_RDSR1  = 8'h05;  // Read Status Register 1
  localparam logic [7:0] CMD_RDSR2  = 8'h35;  // Read Status Register 2
  localparam logic [7:0] CMD_WREN   = 8'h06;  // Write Enable
  localparam logic [7:0] CMD_WRDI   = 8'h04;  // Write Disable
  localparam logic [7:0] CMD_VSRWE  = 8'h50;  // Volatile SR Write Enable
  localparam logic [7:0] CMD_WRSR2  = 8'h31;  // Write Status Register 2
  localparam logic [7:0] CMD_JEDEC  = 8'h9F;  // JEDEC ID
  localparam logic [7:0] CMD_ENQPI  = 8'h38;  // Enter QPI
  localparam logic [7:0] CMD_EXQPI  = 8'hFF;  // Exit QPI
  localparam logic [7:0] CMD_SETRP  = 8'hC0;  // Set Read Parameters (QPI only)

  localparam int unsigned ADDR_BITS = 24;     // 24 bits cover 16 MB exactly

  // -----------------------------------------------------------------------
  // Bus mode: standard SPI (instruction on 1 lane) vs. QPI (EVERYTHING quad)
  // -----------------------------------------------------------------------
  typedef enum logic { ModeSpi = 1'b0, ModeQpi = 1'b1 } qpi_mode_e;

  // -----------------------------------------------------------------------
  // Memory: do NOT allocate 16 MB naively. Associative array -- only bytes
  // actually written/initialised occupy storage; everything else reads as
  // 8'hFF (erased-flash state). $readmemh fills consecutively from index 0
  // with exactly as many entries as the file has lines -- the rest of the
  // 16 MB address space implicitly stays "not present".
  // -----------------------------------------------------------------------
  logic [7:0] mem [int unsigned];

  function automatic logic [7:0] mem_rd(input logic [23:0] a);
    automatic int unsigned ai = {8'b0, a};
    if (mem.exists(ai) != 0) mem_rd = mem[ai];
    else                     mem_rd = 8'hFF;
  endfunction

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------
  qpi_mode_e   mode;          // current bus mode
  qpi_mode_e   pending_mode;  // applied at CS rise (ENQPI/EXQPI)

  logic        WEL;           // Write Enable Latch (SR1 bit 1)
  logic        QE;            // Quad Enable (SR2 bit 1, "S9")
  logic        sr_we_once;    // one-shot SR write armed by 0x50

  logic [7:0]  read_param_dummy;  // dummy cycles for QPI 0x0B (Set Read Parameters)

  logic [31:0] shreg;         // generic MSB-first input shift register
  logic [7:0]  out_byte;      // byte currently being shifted out

  logic [7:0]  opcode;        // latched after the instruction phase
  logic [23:0] addr;          // running address (increments per data byte)

  int unsigned edge_cnt;      // SCK EDGES since CS-low (not bits! see above)
  logic        active;

  // -----------------------------------------------------------------------
  // Phase boundaries as functions of the edge count (see comment block at
  // the top). All of them return a NUMBER OF EDGES, not bits.
  // -----------------------------------------------------------------------

  // Instruction phase: 8 edges outside QPI (1 bit/edge), 2 edges in QPI
  // (4 bits/edge) -- depends ONLY on the (stable) bus mode, never on the
  // opcode, which only becomes known at the end of this phase.
  function automatic int unsigned instr_edges(input bit qpi);
    instr_edges = qpi ? 2 : 8;
  endfunction

  // Address lane width: 0 = no address phase (status/enable/JEDEC commands).
  // In QPI the address (and mode byte) is quad for 0x0B/0xEB; outside QPI the
  // address is single for most read variants, only 0xEB is quad by design
  // (hence the name "Quad I/O").
  function automatic int unsigned addr_lane_width(input logic [7:0] op, input bit qpi);
    if (qpi) begin
      case (op)
        CMD_FREAD, CMD_QIO: addr_lane_width = 4;
        default:            addr_lane_width = 0;
      endcase
    end else begin
      case (op)
        CMD_READ, CMD_FREAD, CMD_DREAD, CMD_QREAD: addr_lane_width = 1;
        CMD_QIO:                                    addr_lane_width = 4;
        default:                                     addr_lane_width = 0;
      endcase
    end
  endfunction

  // Mode byte (0xEB only): 1 byte, always quad -> 2 edges.
  function automatic bit has_mode_byte(input logic [7:0] op);
    has_mode_byte = (op == CMD_QIO);
  endfunction

  // Dummy edges between address/mode byte and data (bus turnaround).
  // In QPI, 0x0B is programmable via "Set Read Parameters" (0xC0, default 2);
  // 0xEB stays fixed at 4 dummy edges, in QPI as well.
  function automatic int unsigned dummy_edges(input logic [7:0] op, input bit qpi,
                                               input logic [7:0] rp_dummy);
    if (qpi) begin
      case (op)
        CMD_FREAD: dummy_edges = {24'b0, rp_dummy};
        CMD_QIO:   dummy_edges = 4;
        default:   dummy_edges = 0;
      endcase
    end else begin
      case (op)
        CMD_FREAD, CMD_DREAD, CMD_QREAD: dummy_edges = 8;
        CMD_QIO:                          dummy_edges = 4;
        default:                          dummy_edges = 0;
      endcase
    end
  endfunction

  // Data lane width. 0 = no data phase / model drives nothing (e.g. 0x6B or
  // 0xEB without QE=1 -- "quad output/IO not enabled").
  function automatic int unsigned data_lane_width(input logic [7:0] op, input bit qpi,
                                                   input logic qe);
    if (qpi) begin
      case (op)
        CMD_FREAD, CMD_QIO, CMD_RDSR1, CMD_RDSR2, CMD_SETRP: data_lane_width = 4;
        default:                                              data_lane_width = 0;
      endcase
    end else begin
      case (op)
        CMD_READ, CMD_FREAD:             data_lane_width = 1;
        CMD_DREAD:                       data_lane_width = 2;
        CMD_QREAD:                       data_lane_width = qe ? 4 : 0;
        CMD_QIO:                         data_lane_width = qe ? 4 : 0;
        CMD_RDSR1, CMD_RDSR2, CMD_JEDEC: data_lane_width = 1;
        CMD_WRSR2:                       data_lane_width = 1;  // input byte
        default:                         data_lane_width = 0;
      endcase
    end
  endfunction

  // Does the model drive during the data phase at all (read-like commands),
  // or is it an input byte from the master (WRSR2/SETRP)?
  function automatic bit is_output_op(input logic [7:0] op);
    case (op)
      CMD_READ, CMD_FREAD, CMD_DREAD, CMD_QREAD, CMD_QIO,
      CMD_RDSR1, CMD_RDSR2, CMD_JEDEC: is_output_op = 1'b1;
      default:                         is_output_op = 1'b0;
    endcase
  endfunction

  function automatic bit is_mem_read_op(input logic [7:0] op);
    case (op)
      CMD_READ, CMD_FREAD, CMD_DREAD, CMD_QREAD, CMD_QIO: is_mem_read_op = 1'b1;
      default:                                             is_mem_read_op = 1'b0;
    endcase
  endfunction

  function automatic logic [7:0] jedec_byte(input int unsigned idx3);
    case (idx3)
      0:       jedec_byte = 8'hEF;
      1:       jedec_byte = 8'h40;
      default: jedec_byte = 8'h18;  // idx3 == 2
    endcase
  endfunction

  // -----------------------------------------------------------------------
  // Power-on: standard SPI, 3-byte addresses, QE=0, WEL=0 (datasheet).
  // -----------------------------------------------------------------------
  initial begin
    mode             = ModeSpi;
    pending_mode     = ModeSpi;
    WEL              = 1'b0;
    QE               = 1'b0;
    sr_we_once       = 1'b0;
    read_param_dummy = 8'd2;
    sio_o            = '0;
    sio_oe           = '0;
    active           = 1'b0;
    edge_cnt         = 0;
    shreg            = '0;
    out_byte         = '0;
    opcode           = '0;
    addr             = '0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // -----------------------------------------------------------------------
  // SAMPLE / DECODE -- rising SCK edge, plus CS framing.
  // -----------------------------------------------------------------------
  always_ff @(posedge sclk_i or posedge cs_ni) begin
    if (cs_ni) begin
      active   <= 1'b0;
      edge_cnt <= 0;
    end else begin
      automatic bit           qpi       = (mode == ModeQpi);
      automatic int unsigned  instr_end = instr_edges(qpi);
      automatic int unsigned  lw_in;
      automatic logic [31:0]  shreg_n;
      automatic int unsigned  new_ec    = edge_cnt + 1;
      automatic logic [7:0]   op;

      // --- determine the lane width of THIS edge ----------------------------
      if (edge_cnt < instr_end) begin
        lw_in = qpi ? 4 : 1;
      end else begin
        // From here on `opcode` is guaranteed fresh (see comment block above).
        automatic int unsigned a_lw       = addr_lane_width(opcode, qpi);
        automatic int unsigned addr_end   = instr_end + ((a_lw == 0) ? 0 : (ADDR_BITS / a_lw));
        automatic int unsigned mode_end   = addr_end + (has_mode_byte(opcode) ? 2 : 0);
        automatic int unsigned data_begin = mode_end + dummy_edges(opcode, qpi, read_param_dummy);
        automatic int unsigned d_lw       = data_lane_width(opcode, qpi, QE);
        if (edge_cnt < mode_end)        lw_in = (a_lw != 0) ? a_lw : 1;  // address/mode byte
        else if (edge_cnt < data_begin) lw_in = 1;                       // dummy: unused anyway
        else                             lw_in = (d_lw != 0) ? d_lw : 1;  // data
      end

      // --- shift in lane_width bits, MSB-first -------------------------------
      case (lw_in)
        1:       shreg_n = {shreg[30:0], sio_i[0]};
        2:       shreg_n = {shreg[29:0], sio_i[1:0]};
        4:       shreg_n = {shreg[27:0], sio_i[3:0]};
        default: shreg_n = {shreg[30:0], sio_i[0]};
      endcase

      shreg    <= shreg_n;
      edge_cnt <= new_ec;
      active   <= 1'b1;

      // --- (1) OPCODE: latch + "immediate" no-data commands -----------------
      // WREN/WRDI/VSRWE take effect immediately (no further transfer needed);
      // ENQPI/EXQPI only arm the mode switch, which takes effect at the CS
      // rise (the rest of THIS transaction still runs in the old mode).
      if (edge_cnt < instr_end && new_ec >= instr_end) begin
        op     = shreg_n[7:0];
        opcode <= op;
        case (op)
          CMD_WREN:  WEL <= 1'b1;
          CMD_WRDI:  WEL <= 1'b0;
          CMD_VSRWE: sr_we_once <= 1'b1;
          CMD_ENQPI: if (QE) pending_mode <= ModeQpi;
          CMD_EXQPI: pending_mode <= ModeSpi;
          default: ;  // read/register commands: continue to the next phase
        endcase
      end

      // --- (2)-(4) address / data phase: ONLY with a fresh `opcode` ---------
      if (edge_cnt >= instr_end) begin
        automatic int unsigned a_lw       = addr_lane_width(opcode, qpi);
        automatic int unsigned addr_end   = instr_end + ((a_lw == 0) ? 0 : (ADDR_BITS / a_lw));
        automatic int unsigned mode_end   = addr_end + (has_mode_byte(opcode) ? 2 : 0);
        automatic int unsigned data_begin = mode_end + dummy_edges(opcode, qpi, read_param_dummy);
        automatic int unsigned d_lw       = data_lane_width(opcode, qpi, QE);
        automatic int unsigned bpb;

        // (2) ADDRESS: latched as soon as addr_end is reached.
        if (a_lw != 0 && edge_cnt < addr_end && new_ec >= addr_end)
          addr <= shreg_n[ADDR_BITS-1:0];

        // (3)/(4) DATA-phase byte boundaries: register writes / address advance.
        // The actual read output bytes are driven by the negedge block; here
        // we ONLY evaluate what the master shifts in (WRSR2/SETRP) and, for
        // memory reads, prepare the address for the NEXT byte.
        if (d_lw != 0) begin
          bpb = 8 / d_lw;
          if (new_ec > data_begin && ((new_ec - data_begin) % bpb == 0)) begin
            if (opcode == CMD_WRSR2) begin
              if (WEL || sr_we_once) QE <= shreg_n[1];
              WEL        <= 1'b0;
              sr_we_once <= 1'b0;
            end else if (opcode == CMD_SETRP) begin
              case (shreg_n[5:4])
                2'b00:   read_param_dummy <= 8'd2;
                2'b01:   read_param_dummy <= 8'd4;
                2'b10:   read_param_dummy <= 8'd6;
                default: read_param_dummy <= 8'd8;
              endcase
            end else if (is_mem_read_op(opcode)) begin
              addr <= addr + 24'd1;  // wrap at 16 MB is automatic (24-bit overflow)
            end
            // RDSR1/RDSR2/JEDEC: no state to advance.
          end
        end
      end
    end
  end

  // -----------------------------------------------------------------------
  // DRIVE -- falling SCK edge ("first-bit trap" as in the SRAM model: the
  // first data bit must already be present before the first rising edge of
  // the data phase -- hence we drive on the falling edge).
  // -----------------------------------------------------------------------
  always_ff @(negedge sclk_i or posedge cs_ni) begin
    if (cs_ni) begin
      sio_o    <= '0;
      sio_oe   <= '0;
      out_byte <= '0;
    end else begin
      automatic bit           qpi        = (mode == ModeQpi);
      automatic int unsigned  instr_end  = instr_edges(qpi);
      automatic int unsigned  a_lw       = addr_lane_width(opcode, qpi);
      automatic int unsigned  addr_end   = instr_end + ((a_lw == 0) ? 0 : (ADDR_BITS / a_lw));
      automatic int unsigned  mode_end   = addr_end + (has_mode_byte(opcode) ? 2 : 0);
      automatic int unsigned  data_begin = mode_end + dummy_edges(opcode, qpi, read_param_dummy);
      automatic int unsigned  d_lw       = data_lane_width(opcode, qpi, QE);
      automatic logic [7:0]   cur;
      automatic int unsigned  bpb, k, b, byte_num;

      // Default: do not drive (input phases, dummy, disabled quad reads).
      sio_o  <= '0;
      sio_oe <= '0;

      if (d_lw != 0 && is_output_op(opcode) && edge_cnt >= data_begin) begin
        bpb      = 8 / d_lw;
        k        = edge_cnt - data_begin;
        b        = k % bpb;
        byte_num = k / bpb;

        // Byte boundary: load a fresh byte, otherwise keep shifting.
        if (b == 0) begin
          case (opcode)
            CMD_READ, CMD_FREAD, CMD_DREAD, CMD_QREAD, CMD_QIO: cur = mem_rd(addr);
            CMD_RDSR1: cur = {6'b0, WEL, 1'b0};
            CMD_RDSR2: cur = {6'b0, QE,  1'b0};
            CMD_JEDEC: cur = jedec_byte(byte_num % 3);
            default:   cur = 8'h00;
          endcase
        end else begin
          cur = out_byte << d_lw;
        end
        out_byte <= cur;

        // Drive the top d_lw bits (SPI: SO=SIO1; dual: SIO1:0; quad: SIO3:0).
        case (d_lw)
          1:       begin sio_o[1]   <= cur[7];   sio_oe <= 4'b0010; end
          2:       begin sio_o[1:0] <= cur[7:6]; sio_oe <= 4'b0011; end
          4:       begin sio_o[3:0] <= cur[7:4]; sio_oe <= 4'b1111; end
          default: ;
        endcase
      end
    end
  end

  // -----------------------------------------------------------------------
  // CS RISE -- end of transaction: apply the pending mode switch.
  // -----------------------------------------------------------------------
  always_ff @(posedge cs_ni) begin
    mode <= pending_mode;
  end

endmodule
