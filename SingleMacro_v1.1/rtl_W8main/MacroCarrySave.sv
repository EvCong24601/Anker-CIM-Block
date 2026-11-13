`timescale 1ns/1ps
`default_nettype none
// Combinational 3:2 reduction only. Carry rows already include their <<1.
// Arithmetic is modulo 2**WIDTH. Use sufficient WIDTH for exact local sums.
module MacroCarrySave #(
    parameter integer COUNT = 3,
    parameter integer WIDTH = 18
) (
    input wire [COUNT*WIDTH-1:0] operands,
    output wire [WIDTH-1:0] sum_row, carry_row
);
    generate
        if (COUNT == 1) begin : g_one
            assign sum_row = operands;
            assign carry_row = {WIDTH{1'b0}};
        end else if (COUNT == 2) begin : g_two
            assign sum_row = operands[0 +: WIDTH];
            assign carry_row = operands[WIDTH +: WIDTH];
        end else begin : g_reduce
            localparam integer TRIPLES = COUNT/3;
            localparam integer NEXT_COUNT = 2*TRIPLES + COUNT%3;
            wire [NEXT_COUNT*WIDTH-1:0] next_rows;
            for (genvar n=0; n<TRIPLES; n=n+1) begin : g_csa
                wire [WIDTH-1:0] a=operands[(3*n)*WIDTH +: WIDTH];
                wire [WIDTH-1:0] b=operands[(3*n+1)*WIDTH +: WIDTH];
                wire [WIDTH-1:0] c=operands[(3*n+2)*WIDTH +: WIDTH];
                assign next_rows[(2*n)*WIDTH +: WIDTH] = a ^ b ^ c;
                assign next_rows[(2*n+1)*WIDTH +: WIDTH] =
                    ((a & b) | (a & c) | (b & c)) << 1;
            end
            for (genvar n=0; n<COUNT%3; n=n+1) begin : g_remainder
                assign next_rows[(2*TRIPLES+n)*WIDTH +: WIDTH] =
                    operands[(3*TRIPLES+n)*WIDTH +: WIDTH];
            end
            MacroCarrySave #(.COUNT(NEXT_COUNT), .WIDTH(WIDTH)) u_next (
                .operands(next_rows), .sum_row(sum_row), .carry_row(carry_row)
            );
        end
    endgenerate
endmodule
`default_nettype wire
