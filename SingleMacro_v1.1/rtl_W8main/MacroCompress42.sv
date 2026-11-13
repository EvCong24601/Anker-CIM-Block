`timescale 1ns/1ps
`default_nettype none
// Exact 4:2 column: a+b+c+d+cin = sum + 2*carry + 2*cout.
// cout depends only on a/b/c, so the horizontal connection is not a ripple
// carry-propagate path through successive columns.
module MacroCompress42Bit (
    input wire a,b,c,d,cin,
    output wire sum,carry,cout
);
    wire partial_sum=a ^ b ^ c;
    assign cout=(a & b) | (a & c) | (b & c);
    assign sum=partial_sum ^ d ^ cin;
    assign carry=(partial_sum & d) | (partial_sum & cin) | (d & cin);
endmodule

// Four native-width unsigned inputs, two already weight-aligned output rows.
// Both top carries are retained. No CPA, truncation, or caller-side padding.
module MacroCompress4to2 #(
    parameter integer INPUT_WIDTH=5,
    parameter integer OUTPUT_WIDTH=INPUT_WIDTH+2
) (
    input wire [4*INPUT_WIDTH-1:0] operands,
    output wire [OUTPUT_WIDTH-1:0] sum_row,carry_row
);
    wire [INPUT_WIDTH:0] horizontal_carry;
    wire [INPUT_WIDTH-1:0] column_sum,column_carry;
    assign horizontal_carry[0]=1'b0;
    for (genvar bit_index=0;bit_index<INPUT_WIDTH;bit_index=bit_index+1) begin : g_column
        MacroCompress42Bit u_42 (
            .a(operands[bit_index]),
            .b(operands[INPUT_WIDTH+bit_index]),
            .c(operands[2*INPUT_WIDTH+bit_index]),
            .d(operands[3*INPUT_WIDTH+bit_index]),
            .cin(horizontal_carry[bit_index]),
            .sum(column_sum[bit_index]),.carry(column_carry[bit_index]),
            .cout(horizontal_carry[bit_index+1]));
    end
    assign sum_row={{(OUTPUT_WIDTH-INPUT_WIDTH-1){1'b0}},
                    horizontal_carry[INPUT_WIDTH],column_sum};
    assign carry_row={{(OUTPUT_WIDTH-INPUT_WIDTH-1){1'b0}},column_carry,1'b0};
`ifndef SYNTHESIS
    initial begin
        if (INPUT_WIDTH<1 || OUTPUT_WIDTH<INPUT_WIDTH+1)
            $fatal(1,"MacroCompress4to2 requires INPUT_WIDTH>=1 and OUTPUT_WIDTH>=INPUT_WIDTH+1");
    end
`endif
endmodule

// Eight operands -> four rows -> two rows, using exact 4:2 blocks only.
module MacroCompress8to2 #(
    parameter integer INPUT_WIDTH=3,
    parameter integer OUTPUT_WIDTH=INPUT_WIDTH+3
) (
    input wire [8*INPUT_WIDTH-1:0] operands,
    output wire [OUTPUT_WIDTH-1:0] sum_row,carry_row
);
    localparam integer MID_WIDTH=INPUT_WIDTH+1;
    wire [4*MID_WIDTH-1:0] middle_rows;
    for (genvar group_index=0;group_index<2;group_index=group_index+1) begin : g_first
        MacroCompress4to2 #(.INPUT_WIDTH(INPUT_WIDTH),.OUTPUT_WIDTH(MID_WIDTH)) u_42 (
            .operands(operands[4*INPUT_WIDTH*group_index+:4*INPUT_WIDTH]),
            .sum_row(middle_rows[2*group_index*MID_WIDTH+:MID_WIDTH]),
            .carry_row(middle_rows[(2*group_index+1)*MID_WIDTH+:MID_WIDTH]));
    end
    MacroCompress4to2 #(.INPUT_WIDTH(MID_WIDTH),.OUTPUT_WIDTH(OUTPUT_WIDTH)) u_last (
        .operands(middle_rows),.sum_row(sum_row),.carry_row(carry_row));
endmodule
`default_nettype wire
