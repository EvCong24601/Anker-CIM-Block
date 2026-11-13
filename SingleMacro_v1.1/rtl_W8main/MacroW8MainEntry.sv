`timescale 1ns/1ps
`default_nettype none
// One 32-bit weight group and ONE ACT plane: two physical pair-LUT outputs.
// W2: eight unsigned3 -> two unsigned6 rows.
// W4: four unsigned5 -> two unsigned7 rows.
// Low-precision paths use exact 4:2 compression. W8 directly bypasses both.
module MacroW8MainEntry (
    input wire [15:0] body,
    input wire [7:0] extension,
    input wire [1:0] weight_mode,
    output logic [8:0] row0, row1
);
    import single_macro_pkg::*;
    logic [8*3-1:0] w2_operands;
    logic [4*5-1:0] w4_operands;
    wire [5:0] w2_sum,w2_carry;
    wire [6:0] w4_sum,w4_carry;
    always_comb begin
        // Native-width inputs. Default zeros isolate both inactive branches.
        w2_operands='0;
        w4_operands='0;
        row0='0;
        row1='0;
        case (weight_mode)
            W_MODE_2: begin
                for (integer n=0;n<8;n=n+1)
                    w2_operands[3*n+:3]={extension[n],body[2*n+:2]};
                row0={3'b000,w2_sum};
                row1={3'b000,w2_carry};
            end
            W_MODE_4: begin
                for (integer n=0;n<4;n=n+1)
                    w4_operands[5*n+:5]={extension[2*n+1],body[4*n+:4]};
                row0={2'b00,w4_sum};
                row1={2'b00,w4_carry};
            end
            W_MODE_8: begin
                row0={extension[3],body[7:0]};
                row1={extension[7],body[15:8]};
            end
            default: begin end
        endcase
    end
    // Module instances are elaborated statically, outside procedural case.
    MacroCompress8to2 #(.INPUT_WIDTH(3),.OUTPUT_WIDTH(6)) u_w2_42 (
        .operands(w2_operands),.sum_row(w2_sum),.carry_row(w2_carry));
    MacroCompress4to2 #(.INPUT_WIDTH(5),.OUTPUT_WIDTH(7)) u_w4_42 (
        .operands(w4_operands),.sum_row(w4_sum),.carry_row(w4_carry));
endmodule
`default_nettype wire
