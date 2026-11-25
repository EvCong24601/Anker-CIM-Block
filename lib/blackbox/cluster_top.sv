`timescale 1ns / 1ps
// Interface-only shell. Compile cluster_pkg.sv first.
module cluster_top #(
  // Unified integration depth. Individual overrides support capacity tests.
  parameter int OUTPUT_PSUM_DEPTH = 16,
  parameter int OUTPUT_BUFFER_DEPTH = OUTPUT_PSUM_DEPTH,
  parameter int WGT_RADDR_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH,
  // Context tag/completion capacity, independent of the Psum depth. Bounds the
  // WS/AS context count; for OS1 WS it is the only limit, so up to MAX_CONTEXTS
  // contexts (e.g. 64) are legal even beyond OUTPUT_BUFFER_DEPTH.
  parameter int MAX_CONTEXTS = 64,
  parameter bit USE_CLOCK_GATING = 1
) (
  input logic clock,
  input logic reset_n,
  input logic rstn_config,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [7:0] weight_raddr_i,
  input logic weight_valid_i,
  output wire weight_ready_o,
  input logic [1023:0] act_data_i,
  input logic act_valid_i,
  output wire act_ready_o,
  input logic sram_cs_en,
  input logic sram_wr_en,
  input logic sram_macro_group,
  input logic [1:0] sram_bank_sel,
  input logic [7:0] sram_row_addr,
  input logic [3:0] sram_wmask,
  input logic [1023:0] sram_wrdata,
  input logic [7:0] timing_config_i,
  input logic waen_i,
  input logic raen_i,
  output wire [1023:0] sram_rd_data,
  output logic sram_rd_valid,
  // Lane l carries signed32 raw_psum[32*l+:32], qualified by psum_valid[l].
  // No output backpressure. Invalid lane payload is unspecified.
  output wire [1023:0] raw_psum,
  output wire [31:0] psum_valid,
  // Idle Cluster only. Pulse start for one cycle with a complete Macro ID
  // and repair map. Byte 4*bank+sbk selects one 128-column subbank, low
  // SRAM first. The local map persists until reset or that Macro's next test.
  // Read the registered result at done && !busy; reload weights after MBIST.
  input  logic [2:0]  mbist_macro_id_i,
  input  logic [63:0] mbist_test_red_sbk_i,
  input  logic        mbist_test_memory_start_i,
  output logic [63:0] mbist_test_error_sbk_o,
  output logic        mbist_test_done_o,
  output logic        mbist_test_busy_o,
  output logic        mbist_test_memory_valid_o,
  output logic        mbist_out_of_repair_o
);
endmodule
