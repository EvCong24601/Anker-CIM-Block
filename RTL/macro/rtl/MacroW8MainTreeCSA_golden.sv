`timescale 1ns/1ps
`default_nettype none
// Arithmetic simulation model selected by MACRO_W8_CSA_GOLDEN in MacroW8MainTree.
// This model has no PDK dependency and does not model the fixed FA/HA topology,
// internal carry-save representation, propagation delay, or switching activity.
`ifndef SYNTHESIS
module MacroW8MainTreeCSA_golden (
    input wire [575:0] query_rows,
    input wire [17:0] correction,
    output wire [17:0] sum_row, carry_row,
    output wire carry_in
);
    logic [17:0] total;
    always_comb begin
        total = correction;
        // Four ACT bit-planes, each containing sixteen unsigned 9-bit rows.
        // The plane supplies the bit weight; correction is added once modulo
        // 2**18. Do not sign-extend the offset-encoded query rows.
        for (int plane = 0; plane < 4; plane++)
            for (int row = 0; row < 16; row++)
                total = total + ({9'b0, query_rows[9*(16*plane+row)+:9]} << plane);
    end
    // Canonical representation of the arithmetic result. The observable
    // contract is sum_row + carry_row + carry_in, not each row individually.
    // The real MacroW8MainTree still captures these at n+1 and runs its CPA.
    assign sum_row = total;
    assign carry_row = 18'b0;
    assign carry_in = 1'b0;
endmodule
`endif
`default_nettype wire
