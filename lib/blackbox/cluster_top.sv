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
  input logic reset,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [1023:0] act_data_i,
  input logic sram_cs_en,
  input logic sram_wr_en,
  input logic sram_macro_group,
  input logic [1:0] sram_bank_sel,
  input logic [7:0] sram_row_addr,
  input logic [3:0] sram_wmask,
  input logic [1023:0] sram_wrdata,
  output wire [1023:0] sram_rd_data,
  output logic sram_rd_valid,
  // Lane l carries signed32 raw_psum[32*l+:32], qualified by psum_valid[l].
  // No output backpressure. Invalid lane payload is unspecified.
  output wire [1023:0] raw_psum,
  output wire [31:0] psum_valid
);
endmodule
