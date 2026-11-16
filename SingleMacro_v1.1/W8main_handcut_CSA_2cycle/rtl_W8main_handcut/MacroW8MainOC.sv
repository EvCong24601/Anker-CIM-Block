`timescale 1ns/1ps
`default_nettype none
module MacroW8MainOC (
    input wire csa_clock,csa_capture_en,
    input wire [255:0] weights,
    input wire [511:0] activations,
    input wire [1:0] weight_mode,
    input wire weight_signed, activation_signed, enable,
    input wire [17:0] correction,
    output wire signed [17:0] result
);
    import single_macro_pkg::*;
    wire [31:0] pair_body [0:15];
    wire [15:0] pair_extension [0:15];
    for (genvar k=0; k<16; k=k+1) begin : g_pair
        localparam integer X=2*k, Y=2*k+1;
        wire [15:0] act0,act1;
        for (genvar t=0; t<4; t=t+1) begin : g_address
            assign act0[4*t+:4]=(weight_mode == W_MODE_2) ? activations[4*(4*X+t)+:4]
                : (weight_mode == W_MODE_4) ? activations[4*(2*X+t/2)+:4]
                : activations[4*X+:4];
            assign act1[4*t+:4]=(weight_mode == W_MODE_2) ? activations[4*(4*Y+t)+:4]
                : (weight_mode == W_MODE_4) ? activations[4*(2*Y+t/2)+:4]
                : activations[4*Y+:4];
        end
        MacroFullWeightPairLUT u_lut (
            .weight0(weights[8*X+:8]),.weight1(weights[8*Y+:8]),
            .activation0(act0),.activation1(act1),.weight_mode(weight_mode),
            .weight_signed(weight_signed),.activation_signed(activation_signed),
            .enable(enable),.body_planes(pair_body[k]),
            .extension_planes(pair_extension[k]));
    end
    wire [575:0] query_rows;
    for (genvar j=0; j<4; j=j+1) begin : g_plane
        for (genvar g=0; g<8; g=g+1) begin : g_group
            MacroW8MainEntry u_entry (
                .body({pair_body[2*g+1][8*j+:8],pair_body[2*g][8*j+:8]}),
                .extension({pair_extension[2*g+1][4*j+:4],pair_extension[2*g][4*j+:4]}),
                .weight_mode(weight_mode),
                .row0(query_rows[9*(16*j+2*g)+:9]),
                .row1(query_rows[9*(16*j+2*g+1)+:9]));
        end
    end
    MacroW8MainTree u_main_tree (.csa_clock(csa_clock),.csa_capture_en(csa_capture_en),
        .query_rows(query_rows),.correction(correction),.result(result));
endmodule
`default_nettype wire
