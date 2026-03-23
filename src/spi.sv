// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>

module spi import spi_pkg::*; #(
) (
	input  logic         clk_i,
	input  logic         rst_ni,
	input  spi_obi_req_t obi_req_i,
	output spi_obi_rsp_t obi_rsp_o,
	output logic         spi_cs_no,
	output logic         spi_sclk_o,
	output logic         spi_mosi_o,
	input  logic         spi_miso_i
);

	spi_state_e state_q, state_d;

	logic [63:0] tx_shift_q, tx_shift_d;
	logic [31:0] rx_shift_q, rx_shift_d;
	logic [ 5:0] bit_idx_q, bit_idx_d;
	logic [ 3:0] rid_q, rid_d;
	logic [31:0] rsp_rdata_q, rsp_rdata_d;
	logic        rsp_err_q, rsp_err_d;

	logic accept_req;
	logic full_word_access;

	assign accept_req       = (state_q == SpiIdle) && obi_req_i.req;
	assign full_word_access = (obi_req_i.a.be == 4'hf);

	always_comb begin
		state_d     = state_q;
		tx_shift_d  = tx_shift_q;
		rx_shift_d  = rx_shift_q;
		bit_idx_d   = bit_idx_q;
		rid_d       = rid_q;
		rsp_rdata_d = rsp_rdata_q;
		rsp_err_d   = rsp_err_q;

		if (accept_req) begin
			rid_d = obi_req_i.a.aid;
			if (!full_word_access) begin
				rsp_rdata_d = 32'h0;
				rsp_err_d   = 1'b1;
				state_d     = SpiResp;
			end else if (obi_req_i.a.we) begin
				tx_shift_d  = {SPI_CMD_WRITE, obi_req_i.a.addr[23:0], obi_req_i.a.wdata};
				rx_shift_d  = '0;
				bit_idx_d   = 6'd63;
				rsp_rdata_d = 32'h0;
				rsp_err_d   = 1'b0;
				state_d     = SpiAssertCs;
			end else begin
				tx_shift_d  = {SPI_CMD_READ, obi_req_i.a.addr[23:0], 32'h0000_0000};
				rx_shift_d  = '0;
				bit_idx_d   = 6'd63;
				rsp_rdata_d = 32'h0;
				rsp_err_d   = 1'b0;
				state_d     = SpiAssertCs;
			end
		end else begin
			unique case (state_q)
				SpiIdle: begin
				end

				SpiAssertCs: begin
					state_d = SpiXferLow;
				end

				SpiXferLow: begin
					state_d = SpiXferHigh;
				end

				SpiXferHigh: begin
					if (bit_idx_q <= 6'd31) begin
						rx_shift_d[bit_idx_q[4:0]] = spi_miso_i;
					end

					if (bit_idx_q == 6'd0) begin
						state_d = SpiDeassertCs;
					end else begin
						bit_idx_d = bit_idx_q - 6'd1;
						state_d   = SpiXferLow;
					end
				end

				SpiDeassertCs: begin
					rsp_rdata_d = rx_shift_q;
					state_d     = SpiResp;
				end

				SpiResp: begin
					state_d = SpiIdle;
				end

				default: begin
					state_d = SpiIdle;
				end
			endcase
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			state_q     <= SpiIdle;
			tx_shift_q  <= '0;
			rx_shift_q  <= '0;
			bit_idx_q   <= '0;
			rid_q       <= '0;
			rsp_rdata_q <= '0;
			rsp_err_q   <= 1'b0;
		end else begin
			state_q     <= state_d;
			tx_shift_q  <= tx_shift_d;
			rx_shift_q  <= rx_shift_d;
			bit_idx_q   <= bit_idx_d;
			rid_q       <= rid_d;
			rsp_rdata_q <= rsp_rdata_d;
			rsp_err_q   <= rsp_err_d;
		end
	end

	always_comb begin
		obi_rsp_o              = '0;
		obi_rsp_o.gnt          = accept_req;
		obi_rsp_o.rvalid       = (state_q == SpiResp);
		obi_rsp_o.r.rdata      = rsp_rdata_q;
		obi_rsp_o.r.rid        = rid_q;
		obi_rsp_o.r.err        = rsp_err_q;
		obi_rsp_o.r.r_optional = 1'b0;

		spi_cs_no  = 1'b1;
		spi_sclk_o = 1'b0;
		spi_mosi_o = 1'b0;

		unique case (state_q)
			SpiAssertCs: begin
				spi_cs_no = 1'b0;
			end

			SpiXferLow: begin
				spi_cs_no  = 1'b0;
				spi_sclk_o = 1'b0;
				spi_mosi_o = tx_shift_q[bit_idx_q[5:0]];
			end

			SpiXferHigh: begin
				spi_cs_no  = 1'b0;
				spi_sclk_o = 1'b1;
				spi_mosi_o = tx_shift_q[bit_idx_q[5:0]];
			end

			SpiDeassertCs: begin
				spi_cs_no = 1'b1;
			end

			default: begin
			end
		endcase
	end

endmodule