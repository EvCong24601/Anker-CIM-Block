`timescale 1ns/1ps
`default_nettype none
// Fused same-digit PP reduction, weight alignment and pooled correction.
// Arithmetic expressions describe the sum; synthesis chooses all adder and
// compressor topologies. No digit-reduction module/row interface is imposed.
module MacroWeightFusion (
    input  wire [1023:0] partial_products,
    input  wire [1:0]  weight_mode,
    input  wire [17:0] correction,
    output wire signed [17:0] result
);
    import single_macro_pkg::*;
    // PP layout: partial_products[256*t + 8*s + b]. Each group's maximum
    // nonnegative weighted sum is 32*45=1440, so unsigned11 is lossless.
    // The loop is combinational arithmetic, not a cycle-by-cycle accumulator.
    function automatic [10:0] reduce_digit(input logic [255:0] pp);
        reduce_digit = 11'd0;
        for (integer s = 0; s < 32; s++) begin
            reduce_digit = reduce_digit
                + {10'b0, pp[8*s]}
                + {9'b0, pp[8*s+1], 1'b0}
                + {8'b0, pp[8*s+2], 2'b0}
                + {7'b0, pp[8*s+3], 3'b0}
                + {9'b0, pp[8*s+4], 1'b0}
                + {8'b0, pp[8*s+5], 2'b0}
                + {7'b0, pp[8*s+6], 3'b0}
                + {6'b0, pp[8*s+7], 4'b0};
        end
    endfunction

    // Local mathematical values only: no registers, keep/dont_touch, or
    // separate module boundary between reduction and weight alignment.
    wire [10:0] digit_sum [0:3];
    wire [17:0] aligned_sum [0:3];
    generate
        for (genvar t = 0; t < 4; t++) begin : g_align
            assign digit_sum[t] = reduce_digit(partial_products[256*t +: 256]);
            // Zero extend BEFORE shifting so all weight bits are preserved.
            wire [17:0] u = {7'b0, digit_sum[t]};
            assign aligned_sum[t] = (weight_mode == W_MODE_2) ? u
                : (weight_mode == W_MODE_4) ? (u << (2*(t%2))) : (u << (2*t));
        end
    endgenerate
    // All five operands are unsigned18 bit patterns, including the modular
    // negative correction. Keep the low 18 bits and interpret as signed S.
    // No separate final subtraction is imposed.
    assign result = aligned_sum[0] + aligned_sum[1]
                  + aligned_sum[2] + aligned_sum[3] + correction;
endmodule
`default_nettype wire
