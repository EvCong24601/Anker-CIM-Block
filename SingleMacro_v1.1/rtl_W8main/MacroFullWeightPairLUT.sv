`timescale 1ns/1ps
`default_nettype none
// Two physical bytes: four W2 pairs, two W4 pairs, or one W8 pair.
// All table logic depends ONLY on held weights, mode, and weight sign.
module MacroFullWeightPairTable (
    input wire [7:0] weight0, weight1,
    input wire [1:0] weight_mode,
    input wire weight_signed,
    output wire [7:0] sum_body,
    output wire [3:0] ext00, ext01, ext10, ext11
);
    import single_macro_pkg::*;
    wire [7:0] p=weight0 ^ weight1;
    wire [7:0] g=weight0 & weight1;
    wire [3:0] group_p, group_g;
    wire [7:0] carry_in;
    wire join2=(weight_mode != W_MODE_2);
    wire join4=(weight_mode == W_MODE_8);
    for (genvar t=0; t<4; t=t+1) begin : g_group
        assign group_p[t]=p[2*t+1] & p[2*t];
        assign group_g[t]=g[2*t+1] | (p[2*t+1] & g[2*t]);
    end
    // Group lookahead, with lane boundaries cut before the next group.
    assign carry_in[0]=1'b0;
    assign carry_in[2]=join2 & group_g[0];
    assign carry_in[4]=join4 & (group_g[1] |
        (group_p[1] & join2 & group_g[0]));
    assign carry_in[6]=join2 & (group_g[2] |
        (group_p[2] & join4 & group_g[1]) |
        (group_p[2] & join4 & group_p[1] & join2 & group_g[0]));
    for (genvar t=0; t<4; t=t+1) begin : g_bit
        assign carry_in[2*t+1]=g[2*t] | (p[2*t] & carry_in[2*t]);
        // Isolate only the extension-table inputs. Shared carry_in and the
        // body sum remain active across the whole logical weight lane.
        wire lane_end=(weight_mode == W_MODE_2) |
            ((weight_mode == W_MODE_4) && ((t%2)==1)) | (t==3);
        wire wx_e=weight0[2*t+1] & lane_end;
        wire wy_e=weight1[2*t+1] & lane_end;
        wire sw_e=weight_signed & lane_end;
        wire ci_e=carry_in[2*t+1] & lane_end;
        wire sx_e=wx_e ^ sw_e;
        wire sy_e=wy_e ^ sw_e;
        // F = x*W0+y*W1+2**B*sw. Include the 00 candidate in isolation.
        assign ext00[t]=sw_e;
        assign ext01[t]=sw_e & ~wx_e;
        assign ext10[t]=sw_e & ~wy_e;
        assign ext11[t]=(sx_e & sy_e) | ((sx_e | sy_e) & ci_e);
    end
    assign sum_body=p ^ carry_in;
endmodule

module MacroFullWeightPairLUT (
    input wire [7:0] weight0, weight1,
    // Four 4-bit ACT digits, already broadcast to the physical 2-bit slices.
    input wire [15:0] activation0, activation1,
    input wire [1:0] weight_mode,
    input wire weight_signed, activation_signed, enable,
    // plane j: body[8*j+:8]; extension[4*j+t] belongs to slice t's MSB.
    output wire [31:0] body_planes,
    output wire [15:0] extension_planes
);
    import single_macro_pkg::*;
    wire [7:0] sum_body;
    wire [3:0] ext00,ext01,ext10,ext11;
    MacroFullWeightPairTable u_precompute (
        .weight0(weight0), .weight1(weight1), .weight_mode(weight_mode),
        .weight_signed(weight_signed), .sum_body(sum_body),
        .ext00(ext00), .ext01(ext01), .ext10(ext10), .ext11(ext11)
    );
    for (genvar t=0; t<4; t=t+1) begin : g_slice
        // Extensions sit at lane ENDS, not starts: 1111 / 1010 / 1000.
        wire lane_end=(weight_mode == W_MODE_2) |
            ((weight_mode == W_MODE_4) && ((t%2)==1)) | (t==3);
        for (genvar j=0; j<4; j=j+1) begin : g_plane
            wire x=activation0[4*t+j], y=activation1[4*t+j];
            wire d00=~x & ~y, d01=x & ~y, d10=~x & y, d11=x & y;
            wire [1:0] q=({2{d01}} & weight0[2*t+:2]) |
                         ({2{d10}} & weight1[2*t+:2]) |
                         ({2{d11}} & sum_body[2*t+:2]);
            wire e=(d00 & ext00[t]) | (d01 & ext01[t]) |
                   (d10 & ext10[t]) | (d11 & ext11[t]);
            wire invert=(j==3) && activation_signed;
            // Do not turn an isolated extension table's zero into one.
            // The body still uses the original, unqualified inversion.
            wire ext_invert=invert & lane_end;
            // Post-inversion masking also isolates uninitialized SRAM/X data.
            assign body_planes[8*j+2*t+:2]=(q ^ {2{invert}}) & {2{enable}};
            assign extension_planes[4*j+t]=(e ^ ext_invert) & enable;
        end
    end
endmodule
`default_nettype wire
