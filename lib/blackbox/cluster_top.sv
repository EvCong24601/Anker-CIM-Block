`timescale 1ns / 1ps
// Interface-only shell; no functional implementation.
// Compile RTL/cluster/rtl/cluster_pkg.sv before this file.
// Use this shell in place of the implementation, not together with it.
module cluster_top #(
  parameter int OUTPUT_PSUM_DEPTH = 16,
  parameter int OUTPUT_BUFFER_DEPTH = OUTPUT_PSUM_DEPTH,
  parameter int WGT_RADDR_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH,
  parameter int MAX_CONTEXTS = 64,
  parameter int REQUANT_CONTEXT_DEPTH = OUTPUT_BUFFER_DEPTH,
  parameter bit USE_CLOCK_GATING = 1,
  parameter bit ENABLE_REQUANT = 1
) (
  input logic clock,
  input logic reset,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input cluster_pkg::requant_cfg_t requant_cfg_i,
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
  output logic [255:0] requant_data_o,
  output logic [31:0] requant_valid_o
);

endmodule
