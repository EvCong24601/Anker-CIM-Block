`timescale 1ns/1ps
`default_nettype none
// Shared across four OCs. Constants encode -(G<<8) in the 18-bit domain;
// no run-time divider, multiplier, or data-path subtractor is required.
module MacroSignControl (
    input  wire [1:0] weight_mode,
    input  wire       signed_en,
    input  wire       activation_signed,
    output reg  [3:0] weight_signed,
    output reg  [7:0] correction_g,
    output wire [17:0] correction
);
    import single_macro_pkg::*;
    reg [9:0] negative_g;
    always_comb begin
        weight_signed = 4'b0000;
        correction_g = 8'd0;
        negative_g = 10'd0;
        if (signed_en) begin
            case (weight_mode)
                W_MODE_2: begin
                    weight_signed = 4'b1111;
                    correction_g = activation_signed ? 8'd11 : 8'd15;
                    negative_g = activation_signed ? 10'd1013 : 10'd1009;
                end
                W_MODE_4: begin
                    weight_signed = 4'b1010;
                    correction_g = activation_signed ? 8'd28 : 8'd30;
                    negative_g = activation_signed ? 10'd996 : 10'd994;
                end
                W_MODE_8: begin
                    weight_signed = 4'b1000;
                    correction_g = activation_signed ? 8'd239 : 8'd240;
                    negative_g = activation_signed ? 10'd785 : 10'd784;
                end
                default: begin end // Illegal modes are checked at issue.
            endcase
        end
    end
    assign correction = {negative_g, 8'b0};
endmodule
`default_nettype wire
