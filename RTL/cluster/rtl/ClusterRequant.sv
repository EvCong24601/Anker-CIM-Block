`timescale 1ns / 1ps
// Four physical Requant channels. Gather the selected group's OC c, then
// scatter results to the original sparse lane positions. The owner guarantees
// at most one active reduction group; masks never compact OC indices.
// No clock, pipeline or data registers. LANES must be in 1..32.
// Channel c always selects entry c, even when another OC is masked off.
// Legal configuration: signed shift in -31..31. The owner validates
// configuration when loading it; unsupported configurations produce X data.
module ClusterRequant #(
  parameter int LANES = 32
) (
  input cluster_pkg::requant_cfg_t cfg_i,
  input logic [32*LANES-1:0] psum_i,
  input logic [LANES-1:0] valid_i,
  output wire [8*LANES-1:0] data_o,
  output wire [LANES-1:0] valid_o
);
  function automatic logic signed [7:0] quantize(input logic signed [31:0] psum, input logic signed [31:0] multiplier,
                                                 input logic signed [9:0] shift, input logic signed [31:0] zp);
    logic signed [63:0] product;
    logic [64:0] magnitude, rounded_magnitude;
    logic signed [95:0] scaled, shifted_zp;
    int shift_amount;
    product = psum * multiplier;
    shift_amount = int'(shift);
    magnitude = '0;
    rounded_magnitude = '0;
    scaled = {{32{product[63]}}, product};
    shifted_zp = {{64{zp[31]}}, zp};
    if (shift_amount < -31 || shift_amount > 31) return 'x;
    if (shift_amount >= 0) begin
      // Extend BEFORE shifting, preserving a full INT32*INT32 product.
      scaled = scaled <<< shift_amount;
    end else begin
      shift_amount = -shift_amount;
      magnitude = product[63] ? -$signed({product[63], product}) : {1'b0, product};
      rounded_magnitude = (magnitude + (65'd1 << (shift_amount - 1))) >> shift_amount;
      scaled = $signed({31'b0, rounded_magnitude});
      if (product[63]) scaled = -scaled;
    end
    // zp may cancel a large scaled value. Clip only after this addition.
    scaled = scaled + shifted_zp;
    if (scaled > 96'sd127) return 8'sd127;
    if (scaled < -96'sd128) return -8'sd128;
    return scaled[7:0];
  endfunction

  assign valid_o = valid_i;
  wire [7:0] channel_data[0:3];
  for (genvar c = 0; c < 4; c++) begin : g_channel
    logic [31:0] selected_psum;
    bit found;
    wire [1:0] entry_id = cfg_i.requant_mode ? 2'(c) : 2'd0;
    always_comb begin
      selected_psum = '0;
      found = 0;
      for (int l = c; l < LANES; l += 4) begin
        if (l == c) selected_psum = psum_i[32*l+:32];
        if (valid_i[l] && !found) begin
          selected_psum = psum_i[32*l+:32];
          found = 1;
        end
      end
    end
    assign channel_data[c] = quantize(
      $signed(
        selected_psum
      ),
      $signed(
        cfg_i.requant_multiplier[32*entry_id+:32]
      ),
      $signed(
        cfg_i.requant_shift[10*entry_id+:10]
      ),
      $signed(
        cfg_i.requant_zp[32*c+:32])
    );
  end
  for (genvar lane = 0; lane < LANES; lane++) assign data_o[8*lane+:8] = channel_data[lane%4];
endmodule
