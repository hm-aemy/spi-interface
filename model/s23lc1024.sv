// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Behavioural, protocol-strict simulation model of the Microchip 23LC1024
// serial SRAM (1 Mbit). SPI / SDI / SQI bus modes, byte/page/sequential
// operation modes, full command set.
//
// Pin convention (no inout in the core — tri-state is resolved by the TB):
//   sio_i  : what the bus drives  (model samples)
//   sio_o  : what the model drives
//   sio_oe : per-lane output enable (1 = drive, 0 = high-Z)
//
// SPI mode special case:  input  = SI = SIO0 (sio_i[0])
//                         output = SO = SIO1 (sio_o[1], sio_oe = 4'b0010)
//   SDI/SQI: both directions use the low `lane_width` lanes of SIO0..3.
//
// -----------------------------------------------------------------------------
// MODEL STRUCTURE (why it is built this way)
// -----------------------------------------------------------------------------
// The 23LC1024 is an SPI slave in mode 0 (CPOL=0, CPHA=0). In mode 0:
//   * The master presents data WHILE SCK is low.
//   * Both sides SAMPLE on the rising SCK edge.
//   * Whoever drives updates its output on the FALLING edge so the data is
//     stable by the next rising edge.
// The model therefore has two clocked blocks:
//   1. always @(posedge sclk)  -> SAMPLE (shift input in) + DECODE
//   2. always @(negedge sclk)  -> DRIVE (shift read/RDMR data out)
// A third block reacts to the rising CS edge (end of transaction) and applies
// a pending bus-mode switch (EQIO/EDIO/RSTIO).
//
// All protocol state is derived from ONE running bit counter `bit_cnt` (it
// advances by the lane width per SCK edge: SPI +1, SDI +2, SQI +4). The current
// phase (opcode / address / dummy / data) is computed purely from `bit_cnt`.
// That is the core of the "phase-based" approach: no explicit FSM with many
// states, just one bit boundary per phase. It keeps the model short and makes
// it independent of whether 1, 2 or 4 lanes are active — the counter already
// abstracts the lane width away.
// -----------------------------------------------------------------------------

module s23lc1024 #(
    // Optional memory preload (hex file, byte per line). Empty = zero-filled.
    parameter string       INIT_FILE     = "",
    // Number of address bits actually BACKED BY MEMORY (mem[] size = 2**MEM_ADDR_BITS).
    // Default 17 = full 128 KiB (1 Mbit), matches the real chip and the existing
    // testbenches/sim behaviour bit-for-bit (do not change the default!).
    //
    // WHY this parameter exists (FPGA bring-up, see fpga/arty/top_model.sv):
    // `mem[]` is written on `posedge sclk_i` and read/driven on `negedge sclk_i`
    // -- i.e. BOTH edges of the SAME clock touch the same array. Xilinx block
    // RAMs are single-edge-per-port primitives, so a dual-edge-same-clock array
    // typically fails BRAM inference in yosys and falls back to distributed
    // LUTRAM. A 128 KiB LUTRAM does not fit an XC7A35T (it has no such amount of
    // LUT-RAM). For the FPGA bring-up we don't need the full 1 Mbit array to
    // prove the protocol works end-to-end over a real cable -- a few KiB are
    // enough. The wrapper therefore instantiates this model with a much smaller
    // `MEM_ADDR_BITS` (e.g. 12 -> 4 KiB), which comfortably fits into LUTRAM.
    // Simulation keeps the default (17) so all existing testbenches, which
    // exercise the full address range incl. the 0x1FFFF wrap, stay unchanged.
    parameter int unsigned MEM_ADDR_BITS = 17
) (
    input  logic       cs_ni,    // chip select, active low
    input  logic       sclk_i,   // serial clock (Mode 0)
    input  logic [3:0] sio_i,    // data lanes in
    output logic [3:0] sio_o,    // data lanes out
    output logic [3:0] sio_oe    // data lanes output-enable
);

  // -----------------------------------------------------------------------
  // Constants (datasheet)
  // -----------------------------------------------------------------------
  localparam logic [7:0] CMD_READ  = 8'h03;
  localparam logic [7:0] CMD_WRITE = 8'h02;
  localparam logic [7:0] CMD_EDIO  = 8'h3B;
  localparam logic [7:0] CMD_EQIO  = 8'h38;
  localparam logic [7:0] CMD_RSTIO = 8'hFF;
  localparam logic [7:0] CMD_RDMR  = 8'h05;
  localparam logic [7:0] CMD_WRMR  = 8'h01;

  localparam int unsigned MEM_BYTES = 1 << MEM_ADDR_BITS;  // see MEM_ADDR_BITS above
  localparam int unsigned ADDR_BITS = 24;        // 24 on the wire, MEM_ADDR_BITS decoded

  // Bit indices that delimit the phases (unified bit count, lane-agnostic).
  localparam int unsigned OPCODE_BITS = 8;
  localparam int unsigned ADDR_END    = OPCODE_BITS + ADDR_BITS;  // 32
  localparam int unsigned DUMMY_BITS  = 8;                        // 1 dummy byte

  // -----------------------------------------------------------------------
  // Bus mode (how many lanes per SCK)
  // -----------------------------------------------------------------------
  typedef enum logic [1:0] { BusSpi, BusDual, BusQuad } bus_mode_e;

  function automatic int unsigned lane_width(bus_mode_e m);
    case (m)
      BusSpi:  return 1;
      BusDual: return 2;
      BusQuad: return 4;
      default: return 1;
    endcase
  endfunction

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------
  logic [7:0]  mem [0:MEM_BYTES-1];

  bus_mode_e   bus_mode;      // current bus mode
  bus_mode_e   pending_mode;  // mode to apply at CS rise (EQIO/EDIO/RSTIO)
  logic [7:0]  mode_reg;      // operation mode register (bits 7:6)

  logic [31:0] shreg;         // generic MSB-first input shift register
  logic [7:0]  out_byte;      // byte currently being shifted out (reads/RDMR)

  logic [7:0]  opcode;        // latched after first 8 bits
  logic [23:0] addr;          // running address (increments per data byte)

  int unsigned bit_cnt;       // bits received since CS-low (counts by lane_width)
  logic        active;        // a transaction is in progress

  // -----------------------------------------------------------------------
  // Convenience decodes of the latched opcode.
  //
  // Why plain wires instead of decoding inside the clocked blocks: the opcode
  // is latched ONCE after 8 bits and then determines the behaviour of all
  // following phases. A few named boolean signals keep the clocked blocks
  // below readable.
  // -----------------------------------------------------------------------
  wire is_read  = (opcode == CMD_READ);
  wire is_write = (opcode == CMD_WRITE);
  wire is_rdmr  = (opcode == CMD_RDMR);
  wire is_wrmr  = (opcode == CMD_WRMR);

  // -----------------------------------------------------------------------
  // data_start(): at which bit number does the DATA phase begin?
  //
  // This is the pivot of the phase-based approach. Instead of states we
  // compute the phase boundary:
  //   READ  : opcode(8) + addr(24) [+ dummy(8) if NOT SPI]  -> 32 or 40
  //   WRITE : opcode(8) + addr(24)                          -> 32
  //   RDMR  : opcode(8)                    (no address!)    ->  8
  //   WRMR  : opcode(8)                    (no address!)    ->  8
  //   other : "infinite" -> there is no data phase (EQIO/EDIO/RSTIO)
  //
  // WHY the dummy byte applies to READ only and only outside SPI mode: in
  // dual/quad mode the data lanes must turn around from the (master-driven)
  // address to the (chip-driven) data stream — the datasheet inserts one dummy
  // byte as bus turnaround for that. In plain SPI, SI and SO are separate
  // lines, there is no turnaround, hence no dummy. During WRITE the master
  // stays the driver the whole time -> no dummy either.
  // -----------------------------------------------------------------------
  function automatic int unsigned data_start(input logic [7:0] op, input bus_mode_e m);
    case (op)
      CMD_READ:  data_start = ADDR_END + ((m != BusSpi) ? DUMMY_BITS : 0);
      CMD_WRITE: data_start = ADDR_END;
      CMD_RDMR:  data_start = OPCODE_BITS;
      CMD_WRMR:  data_start = OPCODE_BITS;
      default:   data_start = 32'hFFFF_FFFF;  // no data phase
    endcase
  endfunction

  // -----------------------------------------------------------------------
  // next_addr(): address advance per operation mode (mode register bits 7:6).
  //
  //   00 Byte       : no advance (the chip handles exactly 1 byte).
  //   01 Sequential : +1 across the whole array; the MEM_ADDR_BITS wrap at the
  //                   array end happens automatically because only
  //                   addr[MEM_ADDR_BITS-1:0] is decoded (default 17:
  //                   0x1FFFF -> 0x00000).  <-- power-on default (0x40), the
  //                   mode used for code execution.
  //   10 Page       : +1 with wrap inside a 32-byte page: only addr[4:0]
  //                   increments, the upper bits stay put.
  // -----------------------------------------------------------------------
  function automatic logic [23:0] next_addr(input logic [23:0] a, input logic [7:0] mr);
    case (mr[7:6])
      2'b00:   next_addr = a;                        // Byte-Mode
      2'b01:   next_addr = a + 24'd1;                // Sequential
      2'b10:   next_addr = {a[23:5], a[4:0] + 5'd1}; // Page-Wrap (32 B)
      default: next_addr = a + 24'd1;
    endcase
  endfunction

  // -----------------------------------------------------------------------
  // Power-on (datasheet §2.7 / primer §8): SPI, mode 0x40 (Sequential)
  // -----------------------------------------------------------------------
  initial begin
    bus_mode     = BusSpi;
    pending_mode = BusSpi;
    mode_reg     = 8'h40;
    sio_o        = '0;
    sio_oe       = '0;
    active       = 1'b0;
    bit_cnt      = 0;
    shreg        = '0;
    out_byte     = '0;
    opcode       = '0;
    addr         = '0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // -----------------------------------------------------------------------
  // SAMPLE / DECODE  — rising SCK edge, plus CS framing
  //
  // This is the ONLY block that drives `shreg`, `bit_cnt`, `opcode`, `addr`,
  // `mode_reg`, `mem`, `pending_mode` and `active`. Everything related to
  // protocol progress lives here. (Why the READ address advance sits here and
  // not in the negedge block is explained at note (R) below: `addr` must be
  // driven by exactly ONE always block.)
  // -----------------------------------------------------------------------
  always_ff @(posedge sclk_i or posedge cs_ni) begin
    if (cs_ni) begin
      // CS high -> transaction ends / not active.
      active  <= 1'b0;
      bit_cnt <= 0;
    end else begin
      // Local (automatic) helpers for this single edge.
      automatic int unsigned lw = lane_width(bus_mode);
      automatic logic [31:0] shreg_n;
      automatic int unsigned new_cnt;
      automatic logic [7:0]  op;
      automatic int unsigned ds;

      // --- accumulate lane_width input bits, MSB-first ---------------------
      // Bit order: the highest active lane carries the MSB. Appending on the
      // right (LSB side) of `shreg` keeps the lowest index rightmost, so
      // shreg[7:0] is always the most recently completed byte.
      //   SPI : SI = sio_i[0]
      //   SDI : {sio_i[1], sio_i[0]}  = bit(n+1), bit(n)
      //   SQI : {sio_i[3..0]}         = upper 4 bits of a nibble
      case (bus_mode)
        BusSpi:  shreg_n = {shreg[30:0], sio_i[0]};
        BusDual: shreg_n = {shreg[29:0], sio_i[1:0]};
        BusQuad: shreg_n = {shreg[27:0], sio_i[3:0]};
        default: shreg_n = {shreg[30:0], sio_i[0]};
      endcase
      new_cnt = bit_cnt + lw;

      shreg   <= shreg_n;
      bit_cnt <= new_cnt;
      active  <= 1'b1;

      // --- (1) OPCODE: latch when bit_cnt crosses 8 ------------------------
      // No-arg commands (EQIO/EDIO/RSTIO) have neither address nor data. They
      // only ARM the pending bus mode, which takes effect at the CS rise —
      // NOT immediately, because the rest of THIS transaction still runs in
      // the old mode (e.g. EQIO itself is still received serially in SPI).
      // RSTIO (0xFF) works from any mode: in SQI it is 2 clocks of 0xF ->
      // 8 ones.
      if (bit_cnt < OPCODE_BITS && new_cnt >= OPCODE_BITS) begin
        op     = shreg_n[7:0];
        opcode <= op;
        case (op)
          CMD_EQIO:  pending_mode <= BusQuad;
          CMD_EDIO:  pending_mode <= BusDual;
          CMD_RSTIO: pending_mode <= BusSpi;
          default: ;  // READ/WRITE/RDMR/WRMR: continue to the next phase
        endcase
      end

      // --- (2) ADDRESS: latch when bit_cnt crosses 32 (READ/WRITE only) ----
      // shreg_n now holds {opcode[7:0], addr[23:0]}; the lower 24 bits are the
      // address. Only 17 bits are actually decoded (addr[16:0]); the upper
      // 7 bits are don't-care per the datasheet.
      if ((is_read || is_write) &&
          bit_cnt < ADDR_END && new_cnt >= ADDR_END)
        addr <= shreg_n[ADDR_BITS-1:0];

      // --- (3)/(4) DATA phase, byte boundaries -----------------------------
      // `ds` = start bit of the data phase (see data_start()). A byte boundary
      // is reached when a multiple of 8 bits has passed since `ds`. The test
      // `new_cnt > ds` excludes the boundary `ds` itself (that is still the
      // last address/dummy bit, not a data byte).
      //
      // Note (R): for READ we ONLY advance the address here (the byte itself
      // is driven in the negedge block). The timing works out: once the master
      // has finished sampling the n-th output byte (new_cnt = ds + 8*n) we
      // increment addr, so the next falling edge already loads mem[addr+1].
      // This keeps `addr` in exactly one driving block.
      ds = data_start(opcode, bus_mode);
      if (new_cnt > ds && ((new_cnt - ds) % 8 == 0)) begin
        if (is_write) begin
          mem[addr[MEM_ADDR_BITS-1:0]] <= shreg_n[7:0];  // data byte into array
          addr            <= next_addr(addr, mode_reg);
        end else if (is_wrmr) begin
          mode_reg <= shreg_n[7:0];                 // WRMR: 1 byte -> mode reg
        end else if (is_read) begin
          addr <= next_addr(addr, mode_reg);        // see note (R)
        end
        // RDMR: only outputs mode_reg, no address involved -> nothing to do.
      end
    end
  end

  // -----------------------------------------------------------------------
  // DRIVE  — falling SCK edge (Mode 0, first-bit trap: drive on negedge)
  //
  // This block drives ONLY sio_o/sio_oe/out_byte. It READS addr and mem but
  // never modifies them (see note (R) above). The default is "do not drive"
  // (sio_oe = 0) — only during the read/RDMR data phase do we enable the
  // appropriate lanes.
  //
  // "First-bit trap": in mode 0 the first data bit must already be present
  // BEFORE the first rising edge of the data phase. Driving on the falling
  // edge achieves exactly that: the falling edge following the last
  // address/dummy bit presents bit 7 of the first byte; the master samples it
  // on the next rising edge.
  // -----------------------------------------------------------------------
  always_ff @(negedge sclk_i or posedge cs_ni) begin
    if (cs_ni) begin
      sio_o    <= '0;
      sio_oe   <= '0;
      out_byte <= '0;
    end else begin
      automatic int unsigned ds = data_start(opcode, bus_mode);
      automatic int unsigned lw = lane_width(bus_mode);
      automatic logic [7:0]  cur;
      automatic int unsigned k, b;

      // Default: input phases -> do not drive, leave the bus to the master.
      sio_o  <= '0;
      sio_oe <= '0;

      // (5) READ / RDMR Datenphase.
      if ((is_read || is_rdmr) && (bit_cnt >= ds)) begin
        k = bit_cnt - ds;   // bit position in the output stream
        b = k % 8;          // bit position within the current byte

        // At a byte boundary (b==0) load a fresh byte: from memory (READ) or
        // from the mode register (RDMR). Otherwise keep shifting the current
        // byte. Left-shifting by the lane width keeps the next bit to send at
        // the top (bit 7).
        if (b == 0) cur = is_rdmr ? mode_reg : mem[addr[MEM_ADDR_BITS-1:0]];
        else        cur = out_byte << lw;
        out_byte <= cur;

        // Drive the top `lane_width` bits — lane mapping per the datasheet:
        //   SPI : SO = SIO1                 (SIO0 stays an input!)
        //   SDI : SIO1:0 = bits 7:6
        //   SQI : SIO3:0 = bits 7:4
        case (bus_mode)
          BusSpi:  begin sio_o[1]   <= cur[7];   sio_oe <= 4'b0010; end
          BusDual: begin sio_o[1:0] <= cur[7:6]; sio_oe <= 4'b0011; end
          BusQuad: begin sio_o[3:0] <= cur[7:4]; sio_oe <= 4'b1111; end
          default: ;
        endcase
      end
    end
  end

  // -----------------------------------------------------------------------
  // CS RISE — end of transaction: apply pending bus-mode switch
  //
  // EQIO/EDIO/RSTIO take effect only NOW, because the chip finishes the rest
  // of the transaction that carried the command in the old mode. Otherwise
  // `pending_mode` equals bus_mode, so ordinary READ/WRITE transactions leave
  // the mode unchanged here.
  // -----------------------------------------------------------------------
  always_ff @(posedge cs_ni) begin
    bus_mode <= pending_mode;
  end

endmodule
