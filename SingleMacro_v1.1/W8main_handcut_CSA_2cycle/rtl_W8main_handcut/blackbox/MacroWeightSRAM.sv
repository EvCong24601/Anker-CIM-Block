`timescale 1ns / 1ps
`default_nettype none
// Synthesis-only stub. The behavioral 256x1024 array is not read, so Design
// Compiler keeps this instance as a black box. Compute logic in the parent
// stays in the netlist for PTPX. Do not use this file for simulation.
// Port list matches rtl/MacroWeightSRAM.sv, including the byte-lane write mask.
(* syn_black_box, dont_touch *)
module MacroWeightSRAM (
  input  logic          clock,
  input  logic          write_enable,
  input  logic [   7:0] write_address,
  input  logic [1023:0] write_data,
  input  logic [   3:0] write_mask,
  input  logic          read_enable,
  input  logic [   7:0] read_address,
  output logic [1023:0] read_data
);

endmodule
`default_nettype wire
