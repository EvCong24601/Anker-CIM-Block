`timescale 1ns / 1ps
`default_nettype none
// V0.2: SRAM read and all arithmetic share one R_in -> R_out cycle.
module SingleMacro #(
  // Functional ICG; set to 0 to use register enables on the ordinary clock.
  parameter bit USE_CLOCK_GATING = 1'b1
) (
  input  logic          clock,
  input  logic          reset,
  input  logic          cim_ren,
  input  logic [ 511:0] cim_idata,
  input  logic [   7:0] cim_raddr,
  input  logic          cim_station,
  input  logic [   3:0] cim_oc_mask,
  // Consumer demand after all merge masks; standalone users tie to 4'hf.
  input  logic [   3:0] cim_result_mask,
  input  logic [   2:0] cim_precision,
  input  logic          cim_signed_en,
  input  logic [   1:0] cim_phase,
  input  logic          sram_wen,
  input  logic [   7:0] sram_waddr,
  input  logic [1023:0] sram_wdata,
  input  logic [   3:0] sram_wmask,
  input  logic          sram_ren,
  input  logic [   7:0] sram_raddr,
  output wire  [1023:0] sram_rdata,
  output logic [  71:0] cim_odata,
  output logic          cim_odata_valid,
  output logic [   3:0] cim_odata_oc_mask,
  output logic [   1:0] cim_odata_phase
);
  import single_macro_pkg::*;

  logic         in_valid;  // Valid request at the input boundary.
  logic [511:0] activation_in;  // Registered ACT digits shared by all OCs.
  logic [  7:0] read_address_in;  // Weight row address for this request.
  logic         station_in;  // 1: read SRAM and refresh Hold; 0: reuse Hold.
  logic [  1:0] weight_mode_in;  // Decoded W2/W4/W8 weight mode.
  logic         signed_en_in;  // Signed interpretation of weight digits.
  logic         activation_signed_in;  // Signed interpretation of this ACT digit.
  logic [  3:0] mask_in;  // Enabled OCs for this request.
  logic [  3:0] result_mask_in; // Registered one edge before result capture.
  logic [  1:0] phase_in;  // ACT digit phase returned with the result.

  wire          issue = !reset && cim_ren && (|cim_oc_mask);
  wire          write_active = sram_wen && !(&sram_wmask);
  wire          macro_clock, memory_clock, hold_clock;
  wire memory_active = !reset && (write_active || sram_ren || (issue && cim_station));
  wire hold_active = !reset && (write_active || (in_valid && station_in));
  // Include output valid to preserve the final valid-clearing edge n+2.
  wire          clock_active = !reset && (issue || in_valid || cim_odata_valid);
  generate
    if (USE_CLOCK_GATING) begin : g_icg
      MacroClockGate u_clock_gate (
        .clock(clock),
        .enable(clock_active),
        .gated_clock(macro_clock)
      );
      MacroClockGate u_memory_gate(.clock(clock), .enable(memory_active), .gated_clock(memory_clock));
      MacroClockGate u_hold_gate(.clock(clock), .enable(hold_active), .gated_clock(hold_clock));
    end else begin : g_no_icg
      assign macro_clock = clock;
      assign memory_clock = clock;
      assign hold_clock = clock;
    end
  endgenerate

  logic [1023:0] held_weight;
  logic [7:0] held_address;
  logic hold_valid;
  wire [1023:0] sram_read_data;
  wire sram_read_enable = !reset && issue && cim_station;
  // Refresh uses the current SRAM data directly, never an extra weight stage.
  wire [1023:0] compute_weight = !in_valid ? 1024'b0 : station_in ? sram_read_data : held_weight;
  MacroWeightSRAM u_weight_sram (
    .clock(memory_clock),
    .write_enable(!reset && write_active),
    .write_address(sram_waddr),
    .write_data(sram_wdata),
    .write_mask(sram_wmask),
    .read_enable(sram_read_enable || (!reset && sram_ren)),
    .read_address(sram_ren ? sram_raddr : cim_raddr),
    .read_data(sram_read_data)
  );
  // Align local read qualification with the sampled request, not the next
  // request's live sram_ren. Payload remains in the synchronous SRAM output.
  logic sram_response_valid;
  always_ff @(posedge clock or posedge reset)
    if (reset) sram_response_valid <= 0;
    else sram_response_valid <= sram_ren;
  assign sram_rdata = sram_response_valid ? sram_read_data : 1024'b0;

  // Persistent storage/reuse state, not a current-request pipeline stage.
  // Hold payload need not reset: only a valid, correctly addressed Hold may
  // be used. At n+1 a refresh commits while the next reuse enters R_in.
  always_ff @(posedge hold_clock) begin
    if (!reset && in_valid && station_in) held_weight <= sram_read_data;
  end
  always_ff @(posedge hold_clock or posedge reset) begin
    if (reset) begin
      held_address <= '0;
      hold_valid   <= 1'b0;
    end else if (write_active) begin
      hold_valid <= 1'b0;
    end else if (in_valid && station_in) begin
      held_address <= read_address_in;
      hold_valid   <= 1'b1;
    end
  end

  wire signed [6:0] product_comb[0:3][0:31][0:3];
  wire signed [12:0] slice_comb[0:3][0:31];
  wire signed [13:0] sum_l1[0:3][0:15];
  wire signed [14:0] sum_l2[0:3][0:7];
  wire signed [15:0] sum_l3[0:3][0:3];
  wire signed [16:0] sum_l4[0:3][0:1];
  wire signed [17:0] sum_l5[0:3];
  generate
    for (genvar c = 0; c < 4; c++) begin : g_oc
      wire result_clock;
      wire result_enable = !reset && in_valid && mask_in[c] && result_mask_in[c];
      if (USE_CLOCK_GATING) begin : g_result_icg
        MacroClockGate u_clock_gate (
          .clock(clock), .enable(result_enable), .gated_clock(result_clock)
        );
      end else begin : g_result_no_icg
        assign result_clock = clock;
      end
      // Masked OC payload holds. Valid/mask identify which values belong to
      // this request; shared ACT, SRAM and full-row Hold serve active OCs.
      // Parent-blocked OC results also hold; local valid/phase/Hold semantics
      // remain unchanged, so no extra pipeline stage or refresh is introduced.
      always_ff @(posedge result_clock or posedge reset)
        if (reset) cim_odata[18*c+:18] <= '0;
        else if (result_enable) cim_odata[18*c+:18] <= sum_l5[c];
      for (genvar s = 0; s < 32; s++) begin : g_slice
        for (genvar t = 0; t < 4; t++) begin : g_submul
          wire enabled_oc = in_valid && mask_in[c];
          wire [1:0] weight_bits = enabled_oc ? compute_weight[256*c+8*s+2*t+:2] : 2'b0;
          wire [3:0] activation_bits = !enabled_oc ? 4'b0
                        : (weight_mode_in == W_MODE_2) ? activation_in[4*(4*s+t) +: 4]
                        : (weight_mode_in == W_MODE_4) ? activation_in[4*(2*s+t/2) +: 4]
                        : activation_in[4*s +: 4];
          wire weight_signed = signed_en_in &&
                        ((weight_mode_in == W_MODE_2) ||
                         ((weight_mode_in == W_MODE_4) && ((t % 2) == 1)) ||
                         ((weight_mode_in == W_MODE_8) && (t == 3)));
          MacroMul2x4 u_mul (
            .weight_bits(weight_bits),
            .activation_bits(activation_bits),
            .weight_signed(weight_signed),
            .activation_signed(activation_signed_in),
            .product(product_comb[c][s][t])
          );
        end
        MacroSliceFusion u_slice_fusion (
          .weight_mode(weight_mode_in),
          .p0(product_comb[c][s][0]),
          .p1(product_comb[c][s][1]),
          .p2(product_comb[c][s][2]),
          .p3(product_comb[c][s][3]),
          .sum(slice_comb[c][s])
        );
      end
      // Five combinational levels. Extend both operands BEFORE addition.
      for (genvar i = 0; i < 16; i++) begin : g_l1
        assign sum_l1[c][i] = $signed(
          {slice_comb[c][2*i][12], slice_comb[c][2*i]}
        ) + $signed(
          {slice_comb[c][2*i+1][12], slice_comb[c][2*i+1]}
        );
      end
      for (genvar i = 0; i < 8; i++) begin : g_l2
        assign sum_l2[c][i] = $signed(
          {sum_l1[c][2*i][13], sum_l1[c][2*i]}
        ) + $signed(
          {sum_l1[c][2*i+1][13], sum_l1[c][2*i+1]}
        );
      end
      for (genvar i = 0; i < 4; i++) begin : g_l3
        assign sum_l3[c][i] = $signed(
          {sum_l2[c][2*i][14], sum_l2[c][2*i]}
        ) + $signed(
          {sum_l2[c][2*i+1][14], sum_l2[c][2*i+1]}
        );
      end
      for (genvar i = 0; i < 2; i++) begin : g_l4
        assign sum_l4[c][i] = $signed(
          {sum_l3[c][2*i][15], sum_l3[c][2*i]}
        ) + $signed(
          {sum_l3[c][2*i+1][15], sum_l3[c][2*i+1]}
        );
      end
      assign sum_l5[c] = $signed({sum_l4[c][0][16], sum_l4[c][0]}) + $signed({sum_l4[c][1][16], sum_l4[c][1]});
    end
  endgenerate

  // Only two compute boundaries: n samples input; n+1 registers its result.
  // Nonblocking updates preserve the previous request for output/Hold capture.
  always_ff @(posedge macro_clock or posedge reset) begin
    if (reset) begin
      in_valid <= 1'b0;
      activation_in <= '0;
      read_address_in <= '0;
      station_in <= 1'b0;
      weight_mode_in <= W_MODE_2;
      signed_en_in <= 1'b0;
      activation_signed_in <= 1'b0;
      mask_in <= '0;
      result_mask_in <= '0;
      phase_in <= '0;
      cim_odata_valid <= 1'b0;
      cim_odata_oc_mask <= '0;
      cim_odata_phase <= '0;
    end else begin
      in_valid <= issue;
      cim_odata_valid <= in_valid;
      if (issue) begin
        activation_in <= cim_idata;
        read_address_in <= cim_raddr;
        station_in <= cim_station;
        weight_mode_in <= decode_weight_mode(cim_precision);
        signed_en_in <= cim_signed_en;
        activation_signed_in <= digit_is_signed(cim_precision, cim_phase, cim_signed_en);
        mask_in <= cim_oc_mask;
        result_mask_in <= cim_result_mask;
        phase_in <= cim_phase;
      end
      if (in_valid) begin
        cim_odata_oc_mask <= mask_in;
        cim_odata_phase   <= phase_in;
      end
    end
  end

`ifndef SYNTHESIS
`ifdef SINGLE_MACRO_ASSERTIONS
  // Verification state only; SRAM initialization survives logic reset.
  logic [3:0] initialized_ocs[0:255];
  initial for (int a = 0; a < 256; a++) initialized_ocs[a] = '0;
  always @(posedge clock) begin
    if (!reset) begin
      if (sram_ren && (cim_ren || in_valid || sram_wen)) $fatal(1, "SM_PROTOCOL: regular read overlaps compute/write");
      if (sram_wen) begin
        if (cim_ren) $fatal(1, "SM_PROTOCOL: simultaneous read/write");
        // Output valid alone is completed work: n+2 writes are legal.
        if (in_valid) $fatal(1, "SM_PROTOCOL: write before pipeline drain");
        // Reduction catches X/Z without simulator-specific handling of
        // $isunknown on a wide, temporary concatenation.
        if ((^{sram_waddr, sram_wdata, sram_wmask}) === 1'bx) $fatal(1, "SM_PROTOCOL: unknown write input");
        initialized_ocs[sram_waddr] <= initialized_ocs[sram_waddr] | ~sram_wmask;
      end
      if (issue) begin
        if ((^{cim_precision, cim_phase, cim_signed_en, cim_raddr, cim_station, cim_oc_mask, cim_idata}) === 1'bx)
          $fatal(1, "SM_PROTOCOL: unknown compute input");
        if (!legal_phase(cim_precision, cim_phase)) $fatal(1, "SM_PROTOCOL: illegal precision/phase");
        if (!cim_station) begin
          // A preceding refresh commits at THIS edge; evaluate the
          // resulting logical Hold rather than stale pre-NBA flags.
          if (in_valid && station_in) begin
            if (cim_raddr != read_address_in) $fatal(1, "SM_PROTOCOL: reuse address mismatch");
          end else begin
            if (!hold_valid) $fatal(1, "SM_PROTOCOL: reuse invalid hold");
            if (cim_raddr != held_address) $fatal(1, "SM_PROTOCOL: reuse address mismatch");
          end
        end
        // A partial write initializes only its unmasked OCs, even
        // when an earlier refresh already captured the whole row.
        if ((initialized_ocs[cim_raddr] & cim_oc_mask) != cim_oc_mask) $fatal(1, "SM_PROTOCOL: read uninitialized row");
      end
    end
  end
`endif
`endif
endmodule
`default_nettype wire
