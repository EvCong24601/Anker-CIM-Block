`timescale 1ns/1ps
`default_nettype none
// Mode-independent mathematical sum: 16 unsigned9 rows per ACT plane.
// Synthesis chooses the adder/compressor topology; no structure is imposed.
module MacroW8MainTree (
    input wire [575:0] query_rows,
    input wire [17:0] correction,
    output wire signed [17:0] result
);
    // result = correction + sum_j sum_n (query_rows[j][n] * 2**j).
    // Unsigned18 arithmetic preserves the low 18 bits of the exact sum.
    // These loops describe combinational arithmetic, not clocked accumulation.
    function automatic [17:0] sum_rows (
        input logic [575:0] rows,
        input logic [17:0] bias
    );
        reg [17:0] total;
        begin
            total=bias;
            for (integer j=0;j<4;j=j+1)
                for (integer n=0;n<16;n=n+1)
                    total=total+({9'b0,rows[9*(16*j+n)+:9]} << j);
            sum_rows=total;
        end
    endfunction
    // Interpret the final 18-bit pattern as signed only at the output.
    assign result=sum_rows(query_rows,correction);
endmodule
`default_nettype wire
