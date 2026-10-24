`timescale 1ns / 1ps
// Four edge scenarios share external SRAM/Command/ACT drivers and checking.
// Runtime dimensions come from Python; bounded arrays do not change DUT pins.
module tb_Cluster_GEMM_Edges;
  import cluster_pkg::*;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cluster_ctrl_t cmd_i = '0;
  requant_cfg_t requant_cfg_i = '0;
  logic cmd_valid_i = 0;
  wire cmd_ready_o;
  logic [1023:0] act_data_i = '0;
  logic cim_cs_en = 0, cim_wr_en = 0, cim_macro_group = 0;
  logic [1:0] cim_bank_sel = 0;
  logic [7:0] cim_row_addr = 0;
  logic [3:0] cim_wmask = 0;
  logic [1023:0] cim_wrdata = 0;
  wire [1023:0] cim_rd_data, psum_data_o;
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
    .cim_cs_en(cim_cs_en),
    .cim_wr_en(cim_wr_en),
    .cim_macro_group(cim_macro_group),
    .cim_bank_sel(cim_bank_sel),
    .cim_row_addr(cim_row_addr),
    .cim_wmask(cim_wmask),
    .cim_wrdata(cim_wrdata),
    .cim_rd_data(cim_rd_data),
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
  logic [7:0] w_q[0:2047], quant_golden[0:127];
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
  `include "include/cluster_gemm_edges_driver.svh"
  `include "include/cluster_gemm_edges_scoreboard.svh"
  `include "include/cluster_gemm_edges_regression.svh"

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_Edges_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_Edges, "+all");
  end
`endif
endmodule
