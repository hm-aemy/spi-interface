`timescale 1ns/1ps

module tb_spi;
  import spi_pkg::*;

  logic clk;
  logic rst_ni;

  spi_obi_req_t obi_req;
  spi_obi_rsp_t obi_rsp;

  logic spi_cs_no;
  logic spi_sclk_o;
  logic spi_mosi_o;
  logic spi_miso_i;

  logic [31:0] read_data;
  logic [31:0] exp_data;

  spi i_dut (
    .clk_i      (clk),
    .rst_ni     (rst_ni),
    .obi_req_i  (obi_req),
    .obi_rsp_o  (obi_rsp),
    .spi_cs_no,
    .spi_sclk_o,
    .spi_mosi_o,
    .spi_miso_i
  );

  spi_sram_model i_sram (
    .spi_cs_no,
    .spi_sclk_i (spi_sclk_o),
    .spi_mosi_i (spi_mosi_o),
    .spi_miso_o (spi_miso_i)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    $dumpfile("tb_spi.fst");
    $dumpvars(0, tb_spi);

    obi_req      = '0;
    rst_ni       = 1'b0;
    exp_data     = 32'hA5A5_5A5A;

    repeat (5) @(posedge clk);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk);

    obi_write(32'h0000_0010, exp_data);
    obi_read (32'h0000_0010, read_data);

    if (read_data !== exp_data) begin
      $error("Readback mismatch: expected=%08x got=%08x", exp_data, read_data);
      $fatal(1);
    end

    $display("SPI OBI test PASSED: readback=%08x", read_data);
    $finish;
  end

  initial begin
    #50000;
    $error("Timeout in tb_spi");
    $fatal(1);
  end

  task automatic obi_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      obi_req.req          = 1'b1;
      obi_req.a.addr       = addr;
      obi_req.a.we         = 1'b1;
      obi_req.a.be         = 4'hf;
      obi_req.a.wdata      = data;
      obi_req.a.aid        = 4'h2;
      obi_req.a.a_optional = 1'b0;

      while (!obi_rsp.gnt) begin
        @(posedge clk);
      end

      @(posedge clk);

      obi_req.req = 1'b0;

      while (!obi_rsp.rvalid) begin
        @(posedge clk);
      end

      if (obi_rsp.r.err) begin
        $error("Write response indicated error");
        $fatal(1);
      end
    end
  endtask

  task automatic obi_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      obi_req.req          = 1'b1;
      obi_req.a.addr       = addr;
      obi_req.a.we         = 1'b0;
      obi_req.a.be         = 4'hf;
      obi_req.a.wdata      = 32'h0;
      obi_req.a.aid        = 4'h3;
      obi_req.a.a_optional = 1'b0;

      while (!obi_rsp.gnt) begin
        @(posedge clk);
      end

      @(posedge clk);

      obi_req.req = 1'b0;

      while (!obi_rsp.rvalid) begin
        @(posedge clk);
      end

      if (obi_rsp.r.err) begin
        $error("Read response indicated error");
        $fatal(1);
      end
      data = obi_rsp.r.rdata;
    end
  endtask

endmodule

module spi_sram_model (
  input  logic spi_cs_no,
  input  logic spi_sclk_i,
  input  logic spi_mosi_i,
  output logic spi_miso_o
);
  import spi_pkg::*;

  logic [31:0] mem [0:255];
  logic [ 7:0] cmd_shift;
  logic [23:0] addr_shift;
  logic [31:0] wdata_shift;
  logic [31:0] rdata_shift;
  logic        active;
  integer pos_cnt;

  initial begin
    integer i;
    for (i = 0; i < 256; i = i + 1) begin
      mem[i] = '0;
    end
  end

  always @(posedge spi_sclk_i or posedge spi_cs_no or negedge spi_cs_no) begin
    if (spi_cs_no) begin
      active      <= 1'b0;
      cmd_shift   <= '0;
      addr_shift  <= '0;
      wdata_shift <= '0;
      rdata_shift <= '0;
      pos_cnt     <= 0;
    end else if (!active) begin
      active      <= 1'b1;
      cmd_shift   <= '0;
      addr_shift  <= '0;
      wdata_shift <= '0;
      rdata_shift <= '0;
      pos_cnt     <= 0;
    end else begin
      if (pos_cnt < 8) begin
        cmd_shift <= {cmd_shift[6:0], spi_mosi_i};
      end else if (pos_cnt < 32) begin
        addr_shift <= {addr_shift[22:0], spi_mosi_i};
      end else if ((cmd_shift == SPI_CMD_WRITE) && (pos_cnt < 64)) begin
        wdata_shift <= {wdata_shift[30:0], spi_mosi_i};
        if (pos_cnt == 63) begin
          mem[addr_shift[9:2]] <= {wdata_shift[30:0], spi_mosi_i};
        end
      end

      if ((pos_cnt == 31) && (cmd_shift == SPI_CMD_READ)) begin
        rdata_shift <= mem[{addr_shift[22:0], spi_mosi_i}[9:2]];
      end

      pos_cnt <= pos_cnt + 1;
    end
  end

  always @(negedge spi_sclk_i or posedge spi_cs_no) begin
    if (spi_cs_no) begin
      spi_miso_o <= 1'b0;
    end else if ((cmd_shift == SPI_CMD_READ) && active && (pos_cnt >= 32) && (pos_cnt < 64)) begin
      spi_miso_o <= rdata_shift[63 - pos_cnt];
    end else begin
      spi_miso_o <= 1'b0;
    end
  end

endmodule