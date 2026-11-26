`timescale 1ns/1ps
`default_nettype none

// Standalone register-to-register synthesis boundary for the CSA.
// Inputs sampled at edge n produce the registered rows at edge n+1.
module MacroW8MainTreeCSATop (
    input  wire         clock,
    input  wire [575:0] query_rows,
    output logic [17:0] sum_row,
    output logic [17:0] carry_row,
    output logic        carry_in
);
    logic [575:0] query_rows_q;
    wire [17:0] csa_sum_row, csa_carry_row;
    wire csa_carry_in;

    always_ff @(posedge clock) begin
        query_rows_q <= query_rows;
        sum_row <= csa_sum_row;
        carry_row <= csa_carry_row;
        carry_in <= csa_carry_in;
    end

    MacroW8MainTreeCSA u_csa (
        .query_rows(query_rows_q),
        .correction(18'b0),
        .sum_row(csa_sum_row),
        .carry_row(csa_carry_row),
        .carry_in(csa_carry_in)
    );
endmodule

`default_nettype wire
