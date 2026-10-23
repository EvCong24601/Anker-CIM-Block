`timescale 1ns/1ps
// Stateless per-tensor-scale INT8 Requant with per-lane INT32 zero points.
// No clock, pipeline or data registers. LANES must be in 1..32.
// Legal configuration: mode=0, signed shift in -31..31. The owner validates
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
  function automatic logic signed [7:0] quantize(
    input logic signed [31:0] psum,
    input cluster_pkg::requant_cfg_t cfg,
    input logic signed [31:0] zp
  );
    logic signed [63:0] product;
    logic [64:0] magnitude, rounded_magnitude;
    logic signed [95:0] scaled, shifted_zp;
    int shift_amount;
    product = psum * cfg.requant_multiplier;
    shift_amount = int'($signed(cfg.requant_shift));
    magnitude = '0;
    rounded_magnitude = '0;
    scaled = {{32{product[63]}}, product};
    shifted_zp = {{64{zp[31]}}, zp};
    if (cfg.requant_mode !== 1'b0 || shift_amount < -31 || shift_amount > 31)
      return 'x;
    if (shift_amount >= 0) begin
      // Extend BEFORE shifting, preserving a full INT32*INT32 product.
      scaled = scaled <<< shift_amount;
    end else begin
      shift_amount = -shift_amount;
      magnitude = product[63] ? -$signed({product[63],product}) : {1'b0,product};
      rounded_magnitude = (magnitude + (65'd1 << (shift_amount-1))) >> shift_amount;
      scaled = $signed({31'b0,rounded_magnitude});
      if (product[63]) scaled = -scaled;
    end
    // zp may cancel a large scaled value. Clip only after this addition.
    scaled = scaled + shifted_zp;
    if (scaled > 96'sd127) return 8'sd127;
    if (scaled < -96'sd128) return -8'sd128;
    return scaled[7:0];
  endfunction

  assign valid_o = valid_i;
  for (genvar lane=0; lane<LANES; lane++) begin: g_lane
    assign data_o[8*lane+:8] = quantize($signed(psum_i[32*lane+:32]),cfg_i,
                                      $signed(cfg_i.requant_zp[32*lane+:32]));
  end
endmodule
