`timescale 1ns/1ps
`default_nettype none
package single_macro_pkg;
    localparam logic [1:0] W_MODE_2 = 2'd0;
    localparam logic [1:0] W_MODE_4 = 2'd1;
    localparam logic [1:0] W_MODE_8 = 2'd2;
    localparam int PIPE_LATENCY = 1;

// Decode the weight precision (W) from precision.
    function automatic logic [1:0] decode_weight_mode(input logic [2:0] precision);
        case (precision)
            3'd0, 3'd1: decode_weight_mode = W_MODE_2;
            3'd2, 3'd3, 3'd4: decode_weight_mode = W_MODE_4;
            default: decode_weight_mode = W_MODE_8;
        endcase
    endfunction

// Check phase legality using the activation precision (A).
    function automatic logic legal_phase(input logic [2:0] precision,
                                         input logic [1:0] phase);
        case (precision)
            3'd0, 3'd2: legal_phase = phase == 2'd0;
            3'd1, 3'd3, 3'd5: legal_phase = phase <= 2'd1;
            3'd4, 3'd6: legal_phase = 1'b1;
            default: legal_phase = 1'b0;
        endcase
    endfunction

// In signed mode, only the highest activation digit is signed.
    function automatic logic digit_is_signed(input logic [2:0] precision,
                                              input logic [1:0] phase,
                                              input logic signed_en);
        case (precision)
            3'd0, 3'd2: digit_is_signed = signed_en;
            3'd1, 3'd3, 3'd5: digit_is_signed = signed_en && phase == 2'd1;
            3'd4, 3'd6: digit_is_signed = signed_en && phase == 2'd3;
            default: digit_is_signed = 1'b0;
        endcase
    endfunction
endpackage
`default_nettype wire
