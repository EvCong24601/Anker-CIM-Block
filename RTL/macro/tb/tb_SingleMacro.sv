`timescale 1ns / 1ps
`default_nettype none
// The top level holds parameters, the DUT/primitive instances and shared state; tasks
// are split into include/ by responsibility.
module tb_SingleMacro;
  parameter bit CLOCK_GATING = 1'b1;
  logic clock = 1'b0;
  always #5 clock = ~clock;
  logic reset = 1'b0;
  logic cim_ren = 0, cim_station = 1, cim_signed_en = 0, sram_wen = 0;
  logic [511:0] cim_idata = '0;
  logic [7:0] cim_raddr = '0, sram_waddr = '0;
  logic [3:0] cim_oc_mask = '0;
  logic [2:0] cim_precision = '0;
  logic [1:0] cim_phase = '0;
  logic [1023:0] sram_wdata = '0;
  logic [3:0] sram_wmask = '0;
  logic sram_ren = 0;
  logic [7:0] sram_raddr = '0;
  wire [1023:0] sram_rdata;
  wire [71:0] cim_odata;
  wire cim_odata_valid;
  wire [3:0] cim_odata_oc_mask;
  wire [1:0] cim_odata_phase;
  wire [3:0] cim_result_mask = 4'hf;  // Standalone: every enabled OC has a consumer.
  SingleMacro #(.USE_CLOCK_GATING(CLOCK_GATING)) dut (.*);

  // Exhaustive primitive test is independent of the macro datapath.
  logic [1:0] mul_w = 0;
  logic [3:0] mul_a = 0;
  logic mul_sw = 0, mul_sa = 0;
  wire signed [6:0] mul_product;
  MacroMul2x4 primitive_dut (
    .weight_bits(mul_w),
    .activation_bits(mul_a),
    .weight_signed(mul_sw),
    .activation_signed(mul_sa),
    .product(mul_product)
  );

  logic [1023:0] reference_memory[0:255];
  logic [1023:0] reference_hold;
  logic [7:0] reference_hold_address;
  logic reference_hold_valid = 0;
  // Independent interface expectation: never import the DUT latency constant.
  localparam int EXPECTED_LATENCY = 1;
  logic [EXPECTED_LATENCY:0] expected_valid = 0;
  logic [71:0] expected_data[0:EXPECTED_LATENCY];
  logic [3:0] expected_mask[0:EXPECTED_LATENCY];
  logic [1:0] expected_phase[0:EXPECTED_LATENCY];
  logic pending_refresh = 0;
  logic [1023:0] pending_hold_row;
  logic [7:0] pending_hold_address;
  logic [71:0] last_data = 0;
  logic [3:0] last_mask = 0;
  logic [1:0] last_phase = 0;
  integer cycle_count = 0, accepted_count = 0, result_count = 0, cancelled_count = 0;
  integer bubble_count = 0, zero_mask_count = 0, primitive_count = 0;
  logic negative_mode = 0;
  string negative_case;
  string case_description = "initialization";
  int test_case_id = 0;
  logic [31:0] random_state = 32'h13579bdf;

  `include "include/macro_reference.svh"
  `include "include/macro_driver.svh"
  `include "include/macro_scoreboard.svh"
  `include "include/macro_negative_cases.svh"
  `include "include/macro_regression.svh"

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_SingleMacro_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_SingleMacro, "+all");
  end
`endif
  // Dump FST under --trace-fst (wave-mcp reads it directly); leave CLUSTER_FST
  // undefined for VCS/Icarus runs.
`ifdef CLUSTER_FST
  initial begin : case_fst_dump
    string fst_file;
    if (!$value$plusargs("FST_FILE=%s", fst_file)) fst_file = "tb_SingleMacro_default.fst";
    $display("[WAVE] file=%s", fst_file);
    $dumpfile(fst_file);
    $dumpvars(0, tb_SingleMacro);
  end
`endif
endmodule
`default_nettype wire
