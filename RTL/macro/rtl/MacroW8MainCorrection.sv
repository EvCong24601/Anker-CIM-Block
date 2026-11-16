`timescale 1ns/1ps
`default_nettype none
module MacroW8MainCorrection (
    input wire [1:0] weight_mode,
    input wire signed_en, activation_signed,
    input wire dw_compact,
    output reg [17:0] correction
);
    import single_macro_pkg::*;
    // Npairs=128/B; Cpair=15*2**B*sw+8*(2**(B+1)-1)*sa-16*2**B*sw*sa.
    // Output is -Npairs*Cpair modulo 2**18, shared by the four OCs.
    // Include sw=0,sa=1 for an independently complete arithmetic contract.
    always_comb begin
        correction=18'd0;
        case (weight_mode)
            W_MODE_2: case ({signed_en,activation_signed})
                2'b01: correction=18'h3F200;
                2'b10: correction=18'h3F100;
                2'b11: correction=18'h3F300;
                default: correction=18'd0;
            endcase
            W_MODE_4: case ({signed_en,activation_signed})
                2'b01: correction=18'h3E100;
                2'b10: correction=18'h3E200;
                2'b11: correction=18'h3E300;
                default: correction=18'd0;
            endcase
            W_MODE_8: case ({signed_en,activation_signed})
                2'b01: correction=18'h30080;
                2'b10: correction=18'h31000;
                2'b11: correction=18'h31080;
                default: correction=18'd0;
            endcase
            default: correction=18'd0;
        endcase
        if (dw_compact) begin
            // Compact DW has 16 logical pairs instead of 64/32/16 in W2/W4/W8.
            // Sign-extend the negative table value before scaling modulo 2**18.
            case (weight_mode)
                W_MODE_2: correction=$signed(correction) >>> 2;
                W_MODE_4: correction=$signed(correction) >>> 1;
                default: begin end
            endcase
        end
    end
endmodule
`default_nettype wire
