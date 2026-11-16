`timescale 1ns/1ps
`default_nettype none
// Extracted mapped CSA followed by a synthesizable final carry-propagate sum.
// CSA outputs are captured together; CPA uses only the registered rows.
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
        .correction(correction),
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
    // Both rows are already aligned. carry_in has weight 2**0.
    // Retain the low 18 bits and interpret their bit pattern as signed.
    assign result = sum_row_q + carry_row_q + {17'b0,carry_in_q};
endmodule
`default_nettype wire
