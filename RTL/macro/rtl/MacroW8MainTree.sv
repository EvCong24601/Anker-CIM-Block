`timescale 1ns/1ps
`default_nettype none
// Extracted mapped CSA followed by a synthesizable final carry-propagate sum.
// CSA outputs are captured together; correction is decoded from shared
// n+1 mode registers and added during the CPA cycle, without payload DFFs.
module MacroW8MainTree (
    input wire csa_clock,
    input wire csa_capture_en,
    input wire [575:0] query_rows,
    input wire [17:0] correction,
    output wire signed [17:0] result
);
    wire [17:0] sum_row,carry_row;
    wire carry_in;
    logic [17:0] sum_row_q,carry_row_q;
    logic carry_in_q;
    MacroW8MainTreeCSA u_csa (
        .query_rows(query_rows),
        .correction(18'b0),
        .sum_row(sum_row),
        .carry_row(carry_row),
        .carry_in(carry_in)
    );
    // Payload needs no reset: top-level valid state cancels pending requests.
    always_ff @(posedge csa_clock) begin
        if (csa_capture_en) begin
            sum_row_q <= sum_row;
            carry_row_q <= carry_row;
            carry_in_q <= carry_in;
        end
    end
    // Three aligned 18-bit operands plus the original bit-zero carry.
    // The fixed CSA contributes no correction; add it exactly once here.
    // Retain the low 18 bits and interpret their bit pattern as signed.
    assign result = sum_row_q + carry_row_q + correction + {17'b0,carry_in_q};
endmodule
`default_nettype wire
