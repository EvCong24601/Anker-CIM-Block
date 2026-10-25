`timescale 1ns/1ps
`default_nettype none
// Eight nonnegative, controlled-inversion bits; no local product or adder.
// pp[0:3] are b0,b1,b2,(b3^sa); pp[4:7] are (h0^sw),
// (h1^sw),(h2^sw),(h3^sw^sa), at columns 1,2,3,4.
module MacroPartialProducts2x4 (
    input  wire [1:0] weight_bits,
    input  wire [3:0] activation_bits,
    input  wire       weight_signed,
    input  wire       activation_signed,
    input  wire       enable,
    output wire [7:0] pp
);
    wire [3:0] b = {4{weight_bits[0]}} & activation_bits;
    wire [3:0] h = {4{weight_bits[1]}} & activation_bits;
    wire [7:0] inverted = {
        h[3] ^ weight_signed ^ activation_signed,
        h[2] ^ weight_signed, h[1] ^ weight_signed, h[0] ^ weight_signed,
        b[3] ^ activation_signed, b[2:0]
    };
    // Isolate AFTER inversion. The same enable must gate final compensation.
    assign pp = inverted & {8{enable}};
endmodule
`default_nettype wire
