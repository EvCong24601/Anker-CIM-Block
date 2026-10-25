`timescale 1ns / 1ps
`default_nettype none
// Maybe need PPA Optimization
// One unsigned 2x4 multiplier plus two's-complement digit corrections.
// Keep each 2-bit weight independently signed in W2 mode; W4/W8 sign only
// their highest weight digit. The parent supplies these interpretation flags.
module MacroMul2x4 (
  input  logic       [1:0] weight_bits,
  input  logic       [3:0] activation_bits,
  input  logic             weight_signed,
  input  logic             activation_signed,
  output wire signed [6:0] product
);
  wire [5:0] raw_product;
  wire neg_w;
  wire neg_a;
  wire signed [7:0] raw_extended;
  wire signed [7:0] w_correction;
  wire signed [7:0] a_correction;
  wire signed [7:0] corrected;
  assign raw_product = weight_bits * activation_bits;
  assign neg_w = weight_signed && weight_bits[1];
  assign neg_a = activation_signed && activation_bits[3];
  assign raw_extended = $signed({2'b00, raw_product});
  assign w_correction = neg_w ? $signed({2'b00, activation_bits, 2'b00}) : 8'sd0;
  assign a_correction = neg_a ? $signed({2'b00, weight_bits, 4'b0000}) : 8'sd0;
  assign corrected = raw_extended - w_correction - a_correction + ((neg_w && neg_a) ? 8'sd64 : 8'sd0);
  assign product = corrected[6:0];
endmodule
`default_nettype wire
