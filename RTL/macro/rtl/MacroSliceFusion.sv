`timescale 1ns / 1ps
`default_nettype none
module MacroSliceFusion (
  input logic [1:0] weight_mode,
  input logic signed [6:0] p0,
  input logic signed [6:0] p1,
  input logic signed [6:0] p2,
  input logic signed [6:0] p3,
  output wire signed [12:0] sum
);
  import single_macro_pkg::*;
  // Extend before shifting: a narrow left shift would discard bits.
  wire signed [12:0] x0 = {{6{p0[6]}}, p0};
  wire signed [12:0] x1 = {{6{p1[6]}}, p1};
  wire signed [12:0] x2 = {{6{p2[6]}}, p2};
  wire signed [12:0] x3 = {{6{p3[6]}}, p3};
  assign sum = (weight_mode == W_MODE_2) ? (x0 + x1 + x2 + x3)
               : (weight_mode == W_MODE_4) ? (x0 + (x1 <<< 2) + x2 + (x3 <<< 2))
               : (weight_mode == W_MODE_8) ? (x0 + (x1 <<< 2) + (x2 <<< 4) + (x3 <<< 6))
               : 13'sd0;
endmodule
`default_nettype wire
