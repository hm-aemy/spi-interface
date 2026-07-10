// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
//
// Bidirectional 1/2/4-lane shift unit, one operation = one byte (or a dummy
// stretch of N SCK cycles). SPI Mode 0:
//   * outputs are updated while SCK is low (registered on the falling edge /
//     at op start), so they are stable before the rising edge,
//   * inputs are sampled on the rising edge (the device drives on its falling
//     edge, i.e. half a period earlier).
//
// Lane mapping (master view):
//   single: drive SIO0 (MOSI), sample SIO1 (MISO)
//   dual  : drive/sample SIO1:0 (bit pairs, MSB on the higher lane)
//   quad  : drive/sample SIO3:0 (nibbles,  MSB on the higher lane)
//
// Between operations SCK rests low and the last driven values are held; a
// pause is protocol-legal for static-logic SPI slaves (no edges = no action).
// `release_i` (while idle) tri-states the lanes, used at bus turnaround / CS
// release by the sequencer.

module qspi_shift (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       tick_i,       // half-SCK-period tick from qspi_sck_div

  input  logic       start_i,      // pulse, only when !busy_o
  input  logic [7:0] tx_i,         // byte to send (output ops)
  input  logic [1:0] lanes_ln2_i,  // 0=single, 1=dual, 2=quad
  input  logic       dir_out_i,    // 1 = master drives the lanes
  input  logic       dummy_i,      // 1 = dummy op: cycles_i SCKs, lanes released
  input  logic [4:0] cycles_i,     // SCK cycles for a dummy op
  input  logic       release_i,    // while idle: stop driving the lanes

  output logic       busy_o,
  output logic       done_o,       // 1-cycle pulse, rx_o valid (input ops)
  output logic [7:0] rx_o,

  output logic       sck_o,
  output logic [3:0] sio_o,
  output logic [3:0] sio_oe,
  input  logic [3:0] sio_i
);

  typedef enum logic [1:0] { SIdle, SLow, SHigh } state_e;

  state_e     state_q;
  logic [7:0] sh_q;      // shift register, MSB-first
  logic [1:0] ln2_q;
  logic       dir_q, dummy_q;
  logic [4:0] cyc_q;     // remaining SCK cycles in this op

  // Drive the top (1 << ln2) bits of `sh` onto the lanes.
  function automatic logic [7:0] lane_drive(input logic [7:0] sh, input logic [1:0] ln2);
    // returns {oe[3:0], o[3:0]}
    case (ln2)
      2'd0:    return {4'b0001, 3'b000, sh[7]};
      2'd1:    return {4'b0011, 2'b00,  sh[7:6]};
      default: return {4'b1111, sh[7:4]};
    endcase
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= SIdle;
      sh_q    <= '0;
      ln2_q   <= '0;
      dir_q   <= 1'b0;
      dummy_q <= 1'b0;
      cyc_q   <= '0;
      sck_o   <= 1'b0;
      sio_o   <= '0;
      sio_oe  <= '0;
      done_o  <= 1'b0;
    end else begin
      done_o <= 1'b0;

      unique case (state_q)
        SIdle: begin
          if (start_i) begin
            sh_q    <= tx_i;
            ln2_q   <= lanes_ln2_i;
            dir_q   <= dir_out_i;
            dummy_q <= dummy_i;
            cyc_q   <= dummy_i ? cycles_i : 5'(4'd8 >> lanes_ln2_i);
            if (!dummy_i && dir_out_i)
              {sio_oe, sio_o} <= lane_drive(tx_i, lanes_ln2_i);
            else
              sio_oe <= '0;                    // input / dummy: bus released
            state_q <= SLow;
          end else if (release_i) begin
            sio_oe <= '0;
          end
        end

        SLow: begin
          if (tick_i) begin
            sck_o <= 1'b1;                     // rising edge: device samples,
            if (!dummy_q && !dir_q) begin      // master samples device data
              unique case (ln2_q)
                2'd0:    sh_q <= {sh_q[6:0], sio_i[1]};      // MISO = SIO1
                2'd1:    sh_q <= {sh_q[5:0], sio_i[1:0]};
                default: sh_q <= {sh_q[3:0], sio_i[3:0]};
              endcase
            end
            state_q <= SHigh;
          end
        end

        SHigh: begin
          if (tick_i) begin
            sck_o <= 1'b0;                     // falling edge: update outputs
            cyc_q <= cyc_q - 5'd1;
            if (cyc_q == 5'd1) begin
              done_o  <= 1'b1;
              state_q <= SIdle;
            end else begin
              if (!dummy_q && dir_q) begin
                {sio_oe, sio_o} <= lane_drive(sh_q << (8'd1 << ln2_q), ln2_q);
                sh_q <= sh_q << (8'd1 << ln2_q);
              end
              state_q <= SLow;
            end
          end
        end

        default: state_q <= SIdle;
      endcase
    end
  end

  assign busy_o = (state_q != SIdle);
  assign rx_o   = sh_q;

endmodule
