`timescale 1ns / 1ps
// One Cluster: eight Macros reduce K256, OS2 covers K512, AS4 covers N16.
// Each of the 32 X rows is one independent OS2/AS4 batch.
module tb_Cluster_GEMM_OS2_AS4;
  import cluster_pkg::*;
  parameter int ZP_DEPTH = 4;
  localparam int M = 32, K = 512, N = 16;
  localparam logic [7:0] BASE_ADDR = 8'h60;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cluster_ctrl_t cmd_i = '0;
  requant_cfg_t requant_cfg_i = '0;
  logic cmd_valid_i = 0;
  wire cmd_ready_o;
  logic [1023:0] act_data_i = '0;
  logic cim_cs_en = 0, cim_wr_en = 0, cim_macro_group = 0;
  logic [1:0] cim_bank_sel = 0;
  logic [7:0] cim_row_addr = BASE_ADDR;
  logic [3:0] cim_wmask = 0;
  logic [1023:0] cim_wrdata = 0;
  wire [1023:0] cim_rd_data, psum_data_o;
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

  logic [15:0] x_q[0:M*K-1];
  logic [7:0] w_q[0:K*N-1], quant_golden[0:M*N-1];
  logic [31:0] raw_golden[0:M*N-1], centered_golden[0:M*N-1], zp[0:N-1];
  logic [31:0] channel_multiplier[0:N-1];
  logic [9:0] channel_shift[0:N-1];
  logic [31:0] history_golden[0:M*2*4*4*4-1];
  logic [1023:0] weight_rows[0:63], act_planes[0:M*2*4-1];
  logic [31:0] observed_raw  [0:M*N-1];
  logic [ 7:0] observed_quant[0:M*N-1];
  int multiplier, shift, output_zp, act_zp;
  string data_dir;
  int cycle = 0, active_m = 0, first_accept = -1;
  int row_commands = 0, row_issues = 0, row_raw = 0, row_quant = 0;
  int total_commands = 0, total_issues = 0, raw_checks = 0, quant_checks = 0, psum_checks = 0;
  int raw_next[4], quant_next[4], refreshes[8];
  bit monitoring = 0;
  int trace_fd;
  `include "include/cluster_gemm_as_driver.svh"
  `include "include/cluster_gemm_as_scoreboard.svh"
  `include "include/cluster_gemm_as_regression.svh"

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_OS2_AS4_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_OS2_AS4, "+all");
  end
`endif
endmodule
