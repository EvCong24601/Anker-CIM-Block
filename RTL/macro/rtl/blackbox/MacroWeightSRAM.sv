`timescale 1ns / 1ps
`default_nettype none
// Synthesis-only stub for the logical 256x1024 SRAM interface. Compute logic
// in the parent stays in the netlist for PTPX. Do not use for simulation.
(* syn_black_box, dont_touch *)
module MacroWeightSRAM (
  input  logic          clock,
  input  logic [   7:0] timing_config,
  input  logic          waen,
  input  logic          raen,
  input  logic          write_enable,
  input  logic [   7:0] write_address,
  input  logic [1023:0] write_data,
  input  logic [   3:0] write_mask,
  input  logic          read_enable,
  input  logic [   7:0] read_address,
  input  logic [   3:0] read_oc_mask,
  output logic [1023:0] read_data,
  input  logic          reset_n,
  input  logic          mbist_start,
  input  logic [  63:0] repair_config,
  output logic          mbist_done,
  output logic          mbist_busy,
  output logic          mbist_valid,
  output logic          mbist_unrepairable,
  output logic [  63:0] mbist_errors
);

endmodule
`default_nettype wire
