`timescale 1ns / 1ps
// Shared SRAM/Command/ACT drivers and checking for the concrete GEMM tops.
// Runtime dimensions come from Python; bounded arrays do not change DUT pins.
module ClusterGemmScenario #(
  parameter string SCENARIO = "w4a16_high_group"
);
  import cluster_pkg::*;
  `include "cluster_func.sv"
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
  logic [7:0] sram_row_addr = 0;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  wire [1023:0] sram_rd_data, psum_data_o;
  wire [255:0] requant_data_o;
  wire [31:0] out_valid_o, requant_valid_o;
  cluster_top dut (
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

  int m_count, k_count, n_count, wb, ab, precision, first_macro, macro_count, split, en, slots, base_address;
  int lane_base, first_raw, n_tiles, per_channel, act_zp, phases;
  int n_map[0:1][0:3];
  logic [15:0] x_q[0:4095];
  logic [7:0] w_q[0:2047], quant_golden[0:127], cim_golden[0:127];
  logic [31:0] raw_golden[0:127], zp[0:7], multiplier[0:7];
  logic [9:0] shift[0:7];
  logic [1023:0] weight_rows[0:15], act_planes[0:63];
  logic [31:0] observed_raw  [0:127];
  logic [ 7:0] observed_quant[0:127];
  logic [31:0] active_mask;
  int cycle = 0, active_tile = 0, first_accept = -1, commands = 0, issues = 0;
  int total_commands = 0, total_issues = 0, raw_checks = 0, quant_checks = 0;
  int raw_next[4], quant_next[4], refreshes[8];
  bit monitoring = 0;
  string data_dir, description;
  int trace_fd;
  `include "include/cluster_gemm_scenario_driver.svh"
  `include "include/cluster_gemm_scenario_scoreboard.svh"
  `include "include/cluster_gemm_scenario_regression.svh"

endmodule
