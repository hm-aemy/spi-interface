// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Synthesis-friendly, FULLY SYNCHRONOUS SPI/SQI slave (23LC1024 subset)
// for Board B of the two-board setup.
//
// WHY this extra implementation (instead of model/s23lc1024.sv directly)?
// The behavioural model uses `posedge cs_ni` SIMULTANEOUSLY as a clock
// (bus_mode) and as an asynchronous reset of the shift FFs. On the FPGA this
// forces cs onto a global clock buffer AND a data mux at the same time --
// unroutable in the openXC7 flow, or the reset never releases (two-board
// bring-up 2026-07-07, proven via bus-spy + model UART: sclk edges arrived
// but the model's `active`/`bit_cnt` stayed 0). Hence this slave, which
// oversamples cs, sclk and the data lanes with the board clock and decodes
// purely synchronously -- no async-CS constructs, clean FPGA mapping.
//
// Supports exactly what software/fpgatest exercises:
//   single-SPI + SQI (quad), opcodes RDMR 0x05 / WRMR 0x01 / READ 0x03 /
//   WRITE 0x02 / EQIO 0x38 / RSTIO 0xFF, 24-bit address, 1 dummy byte on
//   non-SPI reads, mode register (power-on 0x40), sequential addressing.
// Memory: 2^MEM_ADDR_BITS bytes.

module fpga_sram_slave #(
    parameter int unsigned MEM_ADDR_BITS = 12
) (
    input  logic       clk,        // board clock (100 MHz), fully synchronous
    input  logic       cs_n,       // from the master (asynchronous, sampled)
    input  logic       sclk,       // from the master
    input  logic [3:0] sio_in,     // driven by the master (pin_a2b)
    output logic [3:0] sio_out,    // towards the master (pin_b2a)
    output logic [3:0] sio_oe      // informational only (unidirectional top)
);
  localparam logic [7:0] CMD_READ = 8'h03, CMD_WRITE = 8'h02;
  localparam logic [7:0] CMD_RDMR = 8'h05, CMD_WRMR  = 8'h01;
  localparam logic [7:0] CMD_EQIO = 8'h38, CMD_RSTIO = 8'hFF;

  // 2-FF synchronisers for all master signals
  logic       csn_q, csn_qq, sclk_q, sclk_qq;
  logic [3:0] din_q, din_qq;
  always_ff @(posedge clk) begin
    csn_q <= cs_n;  csn_qq <= csn_q;
    sclk_q <= sclk; sclk_qq <= sclk_q;
    din_q <= sio_in; din_qq <= din_q;
  end
  wire sclk_rise = ~sclk_qq &  sclk_q;   // master samples here (mode 0)
  wire sclk_fall =  sclk_qq & ~sclk_q;   // slave drives here
  wire cs_active = ~csn_qq;
  wire cs_start  =  csn_qq & ~csn_q;     // falling CS edge
  wire cs_end    = ~csn_qq &  csn_q;     // rising CS edge

  typedef enum logic [1:0] { LaneSpi, LaneQuad } lane_e;
  lane_e bus_mode, pending_mode;
  logic [7:0] mode_reg;

  logic [7:0] mem [0:(1<<MEM_ADDR_BITS)-1];

  logic [31:0] shreg;      // MSB-first input
  logic [7:0]  out_byte;   // output
  logic [7:0]  opcode;
  logic [23:0] addr;
  int unsigned bit_cnt;

  wire is_read  = (opcode == CMD_READ);
  wire is_write = (opcode == CMD_WRITE);
  wire is_rdmr  = (opcode == CMD_RDMR);
  wire is_wrmr  = (opcode == CMD_WRMR);

  function automatic int unsigned lane_w(lane_e m); return (m==LaneQuad)?4:1; endfunction

  // data_start: bit index at which the data phase begins (cf. s23lc1024)
  localparam int unsigned OPB = 8, ADDR_END = 8 + 24, DUMB = 8;
  function automatic int unsigned data_start(input logic [7:0] op, input lane_e m);
    case (op)
      CMD_READ:  return ADDR_END + ((m!=LaneSpi) ? DUMB : 0);
      CMD_WRITE: return ADDR_END;
      CMD_RDMR:  return OPB;
      CMD_WRMR:  return OPB;
      default:   return 32'hFFFF_FFFF;
    endcase
  endfunction

  function automatic logic [23:0] next_addr(input logic [23:0] a, input logic [7:0] mr);
    case (mr[7:6])
      2'b00:   return a;
      2'b10:   return {a[23:5], a[4:0] + 5'd1};
      default: return a + 24'd1;
    endcase
  endfunction

  initial begin
    bus_mode = LaneSpi; pending_mode = LaneSpi; mode_reg = 8'h40;
    shreg='0; out_byte='0; opcode='0; addr='0; bit_cnt=0;
    sio_out='0; sio_oe='0;
  end

  // ---- SAMPLE / DECODE (synchronous, at sclk_rise) ---------------------
  always_ff @(posedge clk) begin
    if (cs_start) begin
      bit_cnt <= 0; shreg <= '0; opcode <= '0;
    end else if (cs_end) begin
      bus_mode <= pending_mode;              // mode switch at end of transaction
    end else if (cs_active && sclk_rise) begin
      automatic int unsigned lw = lane_w(bus_mode);
      automatic logic [31:0] shn;
      automatic int unsigned nc, ds;
      shn = (bus_mode==LaneQuad) ? {shreg[27:0], din_qq[3:0]}
                                 : {shreg[30:0], din_qq[0]};
      nc = bit_cnt + lw;
      shreg <= shn; bit_cnt <= nc;

      if (bit_cnt < OPB && nc >= OPB) begin
        opcode <= shn[7:0];
        case (shn[7:0])
          CMD_EQIO:  pending_mode <= LaneQuad;
          CMD_RSTIO: pending_mode <= LaneSpi;
          default: ;
        endcase
      end
      if ((shn[7:0]==CMD_READ || shn[7:0]==CMD_WRITE || is_read || is_write) &&
          bit_cnt < ADDR_END && nc >= ADDR_END)
        addr <= shn[23:0];

      ds = data_start(opcode, bus_mode);
      if (nc > ds && ((nc - ds) % 8 == 0)) begin
        if (is_write) begin
          mem[addr[MEM_ADDR_BITS-1:0]] <= shn[7:0];
          addr <= next_addr(addr, mode_reg);
        end else if (is_wrmr) begin
          mode_reg <= shn[7:0];
        end else if (is_read) begin
          addr <= next_addr(addr, mode_reg);
        end
      end
    end
  end

  // ---- DRIVE (synchronous, at sclk_fall) -------------------------------
  always_ff @(posedge clk) begin
    if (!cs_active) begin
      sio_oe <= '0; out_byte <= '0;
    end else if (sclk_fall) begin
      automatic int unsigned ds = data_start(opcode, bus_mode);
      automatic int unsigned lw = lane_w(bus_mode);
      automatic logic [7:0]  cur;
      automatic int unsigned k, b;
      sio_oe <= '0;
      if ((is_read || is_rdmr) && (bit_cnt >= ds)) begin
        k = bit_cnt - ds; b = k % 8;
        cur = (b==0) ? (is_rdmr ? mode_reg : mem[addr[MEM_ADDR_BITS-1:0]])
                     : (out_byte << lw);
        out_byte <= cur;
        if (bus_mode==LaneQuad) begin sio_out[3:0] <= cur[7:4]; sio_oe <= 4'b1111; end
        else                    begin sio_out[1]   <= cur[7];   sio_oe <= 4'b0010; end
      end
    end
  end

endmodule
