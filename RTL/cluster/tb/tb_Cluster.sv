`timescale 1ns/1ps
// 顶层只保留参数、接口、DUT 与共享状态；阅读顺序见末尾 include 列表。
module tb_Cluster;
  import cluster_pkg::*;
  parameter logic [7:0] EN_MASK=8'hff;
  parameter logic [31:0] OC_MASK=32'hffff_ffff;
  parameter int OS_TILES=1;
  parameter int PATTERNS=6;
  parameter int OUTPUT_BUFFER_DEPTH=16; // Context entries per channel
  parameter int WGT_RADDR_BUFFER_DEPTH=64; // Eight-bit AS addresses only
  parameter int MAX_CONTEXTS=64; // Completion/tag capacity; independent of Psum
  parameter int TIMEOUT_CYCLES=4000;
  parameter logic [31:0] SEED=32'h19e2a407;
  logic clock=0;
  always #5 clock=~clock;
  logic reset=1;
  cluster_ctrl_t cmd_i='0;
  requant_cfg_t requant_cfg_i='{requant_mode:1'b0,requant_multiplier:32'sd1,
                              requant_shift:10'sd0,requant_zp:32'sd0};
  requant_cfg_t expected_requant_cfg;
  wire [255:0] requant_data_o;
  wire [31:0] requant_valid_o;
  int requant_checks=0, requant_config_hold_checks=0;
  logic cmd_valid_i=0;
  wire cmd_ready_o;
  wire [31:0] out_valid_o;
  logic [1023:0] act_data_i='0;
  logic [7:0] weight_wen_i=0, weight_waddr_i=0;
  logic [8191:0] weight_wdata_i=0;
  // WLC 常规 SRAM 端口；与上方 TB preload 接口分别驱动。
  logic cim_cs_en=0, cim_wr_en=0, cim_macro_group=0;
  logic [1:0] cim_bank_sel=0;
  logic [7:0] cim_row_addr=0;
  logic [3:0] cim_wmask=0;
  logic [1023:0] cim_wrdata=0;
  wire [1023:0] cim_rd_data;
  wire [1023:0] psum_data_o;
  cluster_dut_adapter #(.WGT_RADDR_BUFFER_DEPTH(WGT_RADDR_BUFFER_DEPTH),
                        .MAX_CONTEXTS(MAX_CONTEXTS),
                        .OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH)) dut(.*);
  // 计算参考模型、输出预期及 case/握手计数。
  logic [31:0] rng=SEED;
  int unsigned activation[0:255][0:MAX_CONTEXTS-1][0:255];
  longint signed expected[0:MAX_CONTEXTS-1][0:31];
  logic [31:0] expected_mask;
  int golden_group[0:7];
  int cases_run=0, configurations=0, canonical_count=0, manifest;
  int standard_case=0; // six distinct chapter-4 configurations
  int cycle=0, issue_count, raw_count;
  int case_os, case_ws, case_as, case_r, case_p, first_issue, last_issue;
  int case_used_digits;
  int case_pattern;
  bit case_bubbles;
  int first_external=-1,input_commands=0,act_planes_received=0;
  int external_trace;
  int lane_due[0:MAX_CONTEXTS-1][0:31];
  bit raw_seen[0:MAX_CONTEXTS-1][0:31];
  bit monitoring=0, exact_ii=0;
  int reuse_cycles=0;
  bit held_cmd=0, held_act_for_cmd=0;
  cluster_ctrl_t last_cmd;
  logic [1023:0] last_act;
  int buffer_gate_checks=0, high_depth_checks=0, bypass_psum_hold_checks=0;
  int operation_trace;
  int act_buffer_checks=0, max_act_planes=0;
  int act_issue_overlap, address_issue_overlap, address_wait_cycles, late_address_wait;


  // Independent byte-oriented model: no hierarchical reads of DUT SRAM.
  logic [1023:0] sram_reference [0:7][0:255];
  int sram_read_checks=0, sram_write_cases=0;

  // 先定义参考函数和驱动，再安装检查器，最后定义 case 与启动回归。
  // include 不增加模块层次，latency_audit 和已有波形路径保持有效。
  `include "include/cluster_reference.svh"
  `include "include/cluster_driver.svh"
  `include "include/cluster_requant_cases.svh"
  `include "include/cluster_scoreboards.svh"
  `include "include/cluster_compute_cases.svh"
  `include "include/cluster_sram_cases.svh"
  `include "include/cluster_suites.svh"
  `include "include/cluster_regression.svh"
endmodule
