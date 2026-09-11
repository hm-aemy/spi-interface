// Copyright 2026 University of Applied Sciences Munich
// Christopher Hinz <christopher.hinz@hm.edu>
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

package spi_pkg;

	localparam int unsigned OBI_ADDR_WIDTH = 32;
	localparam int unsigned OBI_DATA_WIDTH = 32;
	localparam int unsigned OBI_ID_WIDTH   = 4;

	localparam logic [7:0] SPI_CMD_READ  = 8'h03;
	localparam logic [7:0] SPI_CMD_WRITE = 8'h02;

	typedef struct packed {
		logic [OBI_ADDR_WIDTH-1:0] addr;
		logic                      we;
		logic [OBI_DATA_WIDTH/8-1:0] be;
		logic [OBI_DATA_WIDTH-1:0] wdata;
		logic [OBI_ID_WIDTH-1:0]   aid;
		logic                      a_optional;
	} spi_obi_a_chan_t;

	typedef struct packed {
		spi_obi_a_chan_t a;
		logic            req;
	} spi_obi_req_t;

	typedef struct packed {
		logic [OBI_DATA_WIDTH-1:0] rdata;
		logic [OBI_ID_WIDTH-1:0]   rid;
		logic                      err;
		logic                      r_optional;
	} spi_obi_r_chan_t;

	typedef struct packed {
		spi_obi_r_chan_t r;
		logic            gnt;
		logic            rvalid;
	} spi_obi_rsp_t;

	typedef enum logic [2:0] {
		SpiIdle,
		SpiAssertCs,
		SpiXferLow,
		SpiXferHigh,
		SpiDeassertCs,
		SpiResp
	} spi_state_e;

endpackage