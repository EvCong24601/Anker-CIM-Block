`timescale 1ns/1ps
`default_nettype none
// Synthesis-only stub. The behavioral 256x1024 array is not read, so Design
// Compiler keeps this instance as a black box. Compute logic in the parent
// stays in the netlist for PTPX. Do not use this file for simulation.
(* syn_black_box, dont_touch *)
module MacroWeightSRAM (
    input  logic          clock,
    input  logic          write_enable,
    input  logic [7:0]    write_address,
    input  logic [1023:0] write_data,
    input  logic          read_enable,
    input  logic [7:0]    read_address,
    output wire  [1023:0] read_data
);
    // synopsys black_box
endmodule
`default_nettype wire
