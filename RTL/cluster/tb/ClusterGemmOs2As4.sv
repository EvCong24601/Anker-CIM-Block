`timescale 1ns / 1ps
// Shared W8A16 AS driver/checker for OS2/AS4 and OS1/AS8 concrete tops.
// Eight Macros cover K256/N4; each X row is an independent batch.
module ClusterGemmOs2As4;
  import cluster_pkg::*;
  parameter int ZP_DEPTH = 16;
  parameter int M = 32, OS = 2, AS = 4;
  parameter logic [7:0] BASE_ADDR = 8'h60;
  parameter bit CHECK_SWITCH = 0;
  localparam int K = 256 * OS, N = 4 * AS;
  localparam int TILE_CYCLES = 4 * AS + 1;
  localparam int FIRST_RAW = (OS - 1) * TILE_CYCLES + 3 * AS + 6;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cluster_ctrl_t cmd_i = '0;
  requant_cfg_t requant_cfg_i = '0;
  logic cmd_valid_i = 0;
  wire cmd_ready_o;
  wire sram_rd_valid;
  logic [1023:0] act_data_i = '0;
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = BASE_ADDR;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  wire [1023:0] sram_rd_data, psum_data_o;
  wire [255:0] requant_data_o;
  wire [31:0] out_valid_o, requant_valid_o;
  cluster_top #(
    .REQUANT_CONTEXT_DEPTH(ZP_DEPTH)
  ) dut (
    .clock(clock),
    .reset(reset),
    .cmd_i(cmd_i),
    .requant_cfg_i(requant_cfg_i),
    .cmd_valid_i(cmd_valid_i),
    .cmd_ready_o(cmd_ready_o),
    .act_data_i(act_data_i),
    .sram_cs_en(sram_cs_en),
    .sram_wr_en(sram_wr_en),
    .sram_macro_group(sram_macro_group),
    .sram_bank_sel(sram_bank_sel),
    .sram_row_addr(sram_row_addr),
    .sram_wmask(sram_wmask),
    .sram_wrdata(sram_wrdata),
    .sram_rd_data(sram_rd_data),
    .sram_rd_valid(sram_rd_valid),
    .requant_data_o(requant_data_o),
    .requant_valid_o(requant_valid_o)
  );
  // TB-only raw observation; these aliases are not cluster_top ports.
  assign psum_data_o = dut.raw_data;
  assign out_valid_o = dut.raw_valid;

  logic [15:0] x_q[0:M * K - 1];
  logic [7:0] w_q[0:K * N - 1], quant_golden[0:M * N - 1], cim_golden[0:M * N - 1];
  logic [31:0] raw_golden[0:M * N - 1], centered_golden[0:M * N - 1], zp[0:N - 1];
  logic [31:0] channel_multiplier[0:N - 1];
  logic [9:0] channel_shift[0:N - 1];
  logic [31:0] history_golden[0:M * OS * 4 * AS * 4 - 1];
  logic [1023:0] weight_rows[0:OS * AS * 8 - 1], act_planes[0:M * OS * 4 - 1];
  logic [31:0] observed_raw  [0:M * N - 1];
  logic [ 7:0] observed_quant[0:M * N - 1];
  int multiplier, shift, output_zp, act_zp;
  string data_dir;
  int cycle = 0, active_m = 0, first_accept = -1;
  int row_commands = 0, row_issues = 0, row_raw = 0, row_quant = 0;
  int total_commands = 0, total_issues = 0, raw_checks = 0, quant_checks = 0, psum_checks = 0;
  int raw_next[4], quant_next[4], refreshes[8];
  bit monitoring = 0;
  int trace_fd;
  function automatic int logical_context(input int m, input int cx);
    return CHECK_SWITCH ? (cx + m) % AS : cx;
  endfunction
  `include "include/cluster_gemm_as_driver.svh"
  `include "include/cluster_gemm_as_gates.svh"
  `include "include/cluster_gemm_as_scoreboard.svh"
  `include "include/cluster_gemm_as_regression.svh"
endmodule
