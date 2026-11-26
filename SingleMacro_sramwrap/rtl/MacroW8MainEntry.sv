`timescale 1ns/1ps
`default_nettype none
// One 32-bit weight group and ONE ACT plane: two physical pair-LUT outputs.
// W2: eight unsigned3 -> two unsigned6 rows.
// W4: four unsigned5 -> two unsigned7 rows.
// W2 and W4 share the final 5-bit 4:2. W8 directly bypasses compression.
module MacroW8MainEntry (
    input wire [15:0] body,
    input wire [7:0] extension,
    input wire [1:0] weight_mode,
    output logic [8:0] row0, row1
);
    import single_macro_pkg::*;
    logic [8*3-1:0] w2_operands;
    wire [4*4-1:0] w2_middle_rows;
    logic [4*5-1:0] shared_operands;
    wire [6:0] shared_sum,shared_carry;
    always_comb begin
        // Defaults isolate W2's first stage in W4/W8 and the shared stage in W8.
        w2_operands='0;
        shared_operands='0;
        row0='0;
        row1='0;
        case (weight_mode)
            W_MODE_2: begin
                for (integer n=0;n<8;n=n+1)
                    w2_operands[3*n+:3]={extension[n],body[2*n+:2]};
                // Four 4-bit carry-save rows occupy the shared 5-bit inputs.
                for (integer n=0;n<4;n=n+1)
                    shared_operands[5*n+:5]={1'b0,w2_middle_rows[4*n+:4]};
                row0={2'b00,shared_sum};
                row1={2'b00,shared_carry};
            end
            W_MODE_4: begin
                for (integer n=0;n<4;n=n+1)
                    shared_operands[5*n+:5]={extension[2*n+1],body[4*n+:4]};
                row0={2'b00,shared_sum};
                row1={2'b00,shared_carry};
            end
            W_MODE_8: begin
                row0={extension[3],body[7:0]};
                row1={extension[7],body[15:8]};
            end
            default: begin end
        endcase
    end
    // Module instances are elaborated statically, outside procedural case.
    for (genvar g=0;g<2;g=g+1) begin : g_w2_first
        MacroCompress4to2 #(.INPUT_WIDTH(3),.OUTPUT_WIDTH(4)) u_42 (
            .operands(w2_operands[12*g+:12]),
            .sum_row(w2_middle_rows[8*g+:4]),
            .carry_row(w2_middle_rows[8*g+4+:4]));
    end
    MacroCompress4to2 #(.INPUT_WIDTH(5),.OUTPUT_WIDTH(7)) u_shared_42 (
        .operands(shared_operands),.sum_row(shared_sum),.carry_row(shared_carry));
endmodule
`default_nettype wire
