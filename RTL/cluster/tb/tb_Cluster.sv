`timescale 1ns / 1ps
// The top level keeps only parameters, interfaces, the DUT and shared state; see the
// include list at the end for the reading order.
module tb_Cluster;
  import cluster_pkg::*;
  `include "cluster_func.sv"
  `include "cluster_check_func.sv"
  parameter logic [7:0] EN_MASK = 8'hff;
  parameter logic [31:0] OC_MASK = 32'hffff_ffff;
  parameter int OS_TILES = 1;
  parameter int PATTERNS = 6;
  parameter int OUTPUT_PSUM_DEPTH = 16;  // Unified Psum/address/Requant depth
  parameter int OUTPUT_BUFFER_DEPTH = OUTPUT_PSUM_DEPTH;  // Context entries per channel
  parameter int WGT_RADDR_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH;  // Eight-bit AS addresses only
  parameter int MAX_CONTEXTS = 64;  // Completion/tag capacity; independent of Psum
  parameter int REQUANT_CONTEXT_DEPTH = OUTPUT_BUFFER_DEPTH;  // Deep AS parameter capacity
  parameter bit CHECK_GATE_EQUIVALENCE = 0;  // Optional ungated mirror under identical inputs
  parameter bit ENABLE_REQUANT = 0;  // Raw-only tree suites; quant suites override 1
  parameter int TIMEOUT_CYCLES = 4000;
  parameter logic [31:0] SEED = 32'h19e2a407;
  logic clock = 0;
  always #5 clock = ~clock;
  logic reset = 1;
  cluster_ctrl_t cmd_i = '0;
  requant_cfg_t requant_cfg_i = '{
    conv_mode: 1'b0,
    requant_multiplier: 32'sd1,
    requant_shift: 10'sd0,
    requant_zp: 32'sd0,
    default: '0
  };
  requant_cfg_t expected_requant_cfg;
  wire [255:0] requant_data_o;
  wire [31:0] requant_valid_o;
  int requant_checks = 0, requant_config_hold_checks = 0;
  logic cmd_valid_i = 0;
  wire cmd_ready_o;
  wire [31:0] out_valid_o;
  logic [1023:0] act_data_i = '0;
  // WLC regular SRAM port: every test writes and reads back weights through it.
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = 0;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  wire [1023:0] sram_rd_data;
  wire sram_rd_valid;
  wire [1023:0] psum_data_o;
  cluster_top #(
    .OUTPUT_PSUM_DEPTH(OUTPUT_PSUM_DEPTH),
    .WGT_RADDR_BUFFER_DEPTH(WGT_RADDR_BUFFER_DEPTH),
    .MAX_CONTEXTS(MAX_CONTEXTS),
    .OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH),
    .REQUANT_CONTEXT_DEPTH(REQUANT_CONTEXT_DEPTH),
    .ENABLE_REQUANT(ENABLE_REQUANT)
  ) dut (
    .*
  );
  // TB-only raw observation; cluster_top exports Requant results only.
  assign psum_data_o = dut.raw_data;
  assign out_valid_o = dut.raw_valid;
  // Golden model, expected outputs and case/handshake counters.
  logic [31:0] rng = SEED;
  int unsigned activation[0:510][0:MAX_CONTEXTS - 1][0:255];
  longint signed expected[0:MAX_CONTEXTS - 1][0:31];
  logic [31:0] expected_mask;
  int golden_group[0:7];
  int cases_run = 0, configurations = 0, canonical_count = 0, manifest;
  int standard_case = 0;  // six distinct chapter-4 configurations
  int cycle = 0, issue_count, raw_count;
  int case_os, case_ws, case_as, case_r, case_p, first_issue, last_issue;
  int case_used_digits;
  int case_pattern;
  bit case_bubbles;
  int first_external = -1, input_commands = 0, act_planes_received = 0;
  int external_trace;
  int lane_due[0:MAX_CONTEXTS - 1][0:31];
  bit raw_seen[0:MAX_CONTEXTS - 1][0:31];
  bit monitoring = 0, exact_ii = 0;
  int reuse_cycles = 0;
  bit held_cmd = 0, held_act_for_cmd = 0;
  cluster_ctrl_t last_cmd;
  logic [1023:0] last_act;
  int buffer_gate_checks = 0, high_depth_checks = 0, bypass_psum_hold_checks = 0;
  int operation_trace;
  int act_buffer_checks = 0, max_act_planes = 0;
  int act_issue_overlap, address_issue_overlap, address_wait_cycles, late_address_wait;


  // Independent byte-oriented model: no hierarchical reads of DUT SRAM.
  logic [1023:0] sram_reference[0:7][0:255];
  int sram_read_checks = 0, sram_write_cases = 0;

  // Define the reference functions and drivers first, then install the checkers, and
  // finally define the cases and launch the regression.
  // Includes add no module scope, so latency_audit and existing waveform paths stay valid.
  `include "include/cluster_reference.svh"
  `include "include/cluster_driver.svh"
  `include "include/cluster_requant_cases.svh"
  `include "include/cluster_context_buffer_cases.svh"
  `include "include/cluster_gate_checks.svh"
  `include "include/cluster_gate_equivalence.svh"
  `include "include/cluster_completion_checks.svh"
  `include "include/cluster_scoreboards.svh"
  `include "include/cluster_compute_cases.svh"
  `include "include/cluster_sram_cases.svh"
  `include "include/cluster_sram_response_cases.svh"
  `include "include/cluster_suites.svh"
  `include "include/cluster_empty_batch_cases.svh"
  `include "include/cluster_regression.svh"

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster, "+all");
  end
`endif
endmodule
