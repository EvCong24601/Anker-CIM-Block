`timescale 1ns / 1ps
`default_nettype none
// Full-weight pair LUTs, W2/W4 entry CSA, and a direct W8 main-tree path.
// SRAM/mask semantics retained; input n -> CSA n+1 -> output n+2, II=1.
module SingleMacro #(
  // Functional ICG; set to 0 to use register enables on the ordinary clock.
  parameter bit USE_CLOCK_GATING = 1'b1
) (
  input  logic          clock,
  input  logic          reset_n,
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
  logic [  1:0] weight_mode_in;  // Decoded W2/W4/W8 weight mode.
  logic         signed_en_in;  // Signed interpretation of weight digits.
  logic         activation_signed_in;  // Signed interpretation of this ACT digit.
  logic [  3:0] mask_in;  // Enabled OCs for this request.
  logic [  3:0] result_mask_in;
  logic [  1:0] phase_in;  // ACT digit phase returned with the result.
  logic csa_valid;
  logic [3:0] mask_csa,result_mask_csa;
  logic [1:0] phase_csa;

  wire          issue;
  wire          write_active;
  wire macro_clock, memory_clock;
  wire memory_active;
  wire sram_read_enable;
  // Drain both stages and preserve the final valid-clearing edge n+3.
  wire clock_active;
  assign issue = cim_ren && (|cim_oc_mask);
  assign write_active = sram_wen && !(&sram_wmask);
  // The caller keeps SRAM/compute requests inactive during reset_n. Reset is
  // not part of the combinational request or ICG-enable decode.
  assign memory_active = write_active || sram_ren || sram_read_enable;
  assign clock_active = issue || in_valid || csa_valid || cim_odata_valid;
  generate
    if (USE_CLOCK_GATING) begin : g_icg
      MacroClockGate u_clock_gate (
        .clock(clock),
        .enable(clock_active),
        .gated_clock(macro_clock)
      );
      MacroClockGate u_memory_gate (
        .clock(clock),
        .enable(memory_active),
        .gated_clock(memory_clock)
      );
    end else begin : g_no_icg
      assign macro_clock  = clock;
      assign memory_clock = clock;
    end
  endgenerate

  // ACT is an input boundary, separate from control/output drain clocks.
  // Decode the incoming request, not weight_mode_in from the previous issue.
  // Cluster supplies this request from its registered packet/scheduler state;
  // the ICG captures the enable during the low phase before the input edge.
  wire [1:0] input_weight_mode;
  wire [2:0] act_capture_en;
  assign input_weight_mode = decode_weight_mode(cim_precision);
  assign act_capture_en = {issue && input_weight_mode == W_MODE_2,
                           issue && input_weight_mode != W_MODE_8, issue};
  wire [2:0] act_clock;
  for (genvar bank = 0; bank < 3; bank++) begin : g_act_bank
    localparam int FIRST = bank == 0 ? 0 : bank == 1 ? 128 : 256;
    localparam int WIDTH = bank == 2 ? 256 : 128;
    MacroClockGate #(.ENABLE_GATING(USE_CLOCK_GATING)) u_clock_gate (
      .clock(clock),
      .enable(act_capture_en[bank]),
      .gated_clock(act_clock[bank])
    );
    // Inactive banks retain their old contents, including in the ICG-bypass
    // reference. Every newly needed bank updates on the same acceptance edge.
    always_ff @(posedge act_clock[bank] or negedge reset_n)
      if (!reset_n) activation_in[FIRST +: WIDTH] <= '0;
      else if (act_capture_en[bank]) activation_in[FIRST +: WIDTH] <= cim_idata[FIRST +: WIDTH];
  end

  logic [7:0] held_address;
  logic hold_valid;
  logic [3:0] held_oc_mask;
  wire [1023:0] sram_read_data;
  wire same_held_row = hold_valid && (held_address == cim_raddr);
  wire [3:0] missing_ocs = cim_oc_mask & ~held_oc_mask;
  assign sram_read_enable = issue && (cim_station || (same_held_row && (|missing_ocs)));
  wire [3:0] sram_read_oc_mask = sram_ren ? 4'hf : cim_station ? cim_oc_mask : missing_ocs;
  // Both refresh and reuse consume the SRAM's retained read output.
  // There is no second 1024-bit weight data register after the SRAM.
  // Keep precompute inputs stable across bubbles. Query outputs are isolated
  // after the highest-plane XOR; pooled correction joins after the CSA register.
  MacroWeightSRAM u_weight_sram (
    .clock(memory_clock),
    .write_enable(write_active),
    .write_address(sram_waddr),
    .write_data(sram_wdata),
    .write_mask(sram_wmask),
    .read_enable(sram_read_enable || sram_ren),
    .read_address(sram_ren ? sram_raddr : cim_raddr),
    .read_oc_mask(sram_read_oc_mask),
    .read_data(sram_read_data)
  );
  // Align local read qualification with the sampled request, not the next
  // request's live sram_ren. Payload remains in the synchronous SRAM output.
  logic sram_response_valid;
  always_ff @(posedge clock or negedge reset_n)
    if (!reset_n) sram_response_valid <= 0;
    else sram_response_valid <= sram_ren;
  assign sram_rdata = sram_response_valid ? sram_read_data : 1024'b0;

  // Only the selected OC slices of the SRAM output update on a compute read.
  // Track slices for the current row so a same-row OC change can fetch any
  // missing slice at the issue edge. A write invalidates the retained row.
  always_ff @(posedge memory_clock or negedge reset_n) begin
    if (!reset_n) begin
      held_address <= '0;
      hold_valid <= 1'b0;
      held_oc_mask <= '0;
    end else if (write_active) begin
      hold_valid <= 1'b0;
      held_oc_mask <= '0;
    end else if (sram_ren || sram_read_enable) begin
      held_address <= sram_ren ? sram_raddr : cim_raddr;
      hold_valid <= 1'b1;
      held_oc_mask <= (!sram_ren && same_held_row ? held_oc_mask : 4'b0) | sram_read_oc_mask;
    end
  end

  wire [17:0] correction_cpa;
  wire signed [17:0] phase_sum [0:3];
  // Only the four shared mode bits cross n+1. Decode correction in the CPA
  // cycle instead of storing an 18-bit correction payload for that cycle.
  logic [1:0] weight_mode_cpa;
  logic signed_en_cpa, activation_signed_cpa;
  wire cpa_mode_capture_en = in_valid && (|(mask_in & result_mask_in));
  // No payload reset: valid/masks cancel pending work across reset_n.
  always_ff @(posedge macro_clock) begin
    if (cpa_mode_capture_en) begin
      weight_mode_cpa <= weight_mode_in;
      signed_en_cpa <= signed_en_in;
      activation_signed_cpa <= activation_signed_in;
    end
  end
  MacroW8MainCorrection u_sign_control (
    .weight_mode(weight_mode_cpa), .signed_en(signed_en_cpa),
    .activation_signed(activation_signed_cpa),
    .correction(correction_cpa)
  );
  generate
    for (genvar c = 0; c < 4; c++) begin : g_oc
      wire csa_clock;
      wire csa_capture_en = in_valid && mask_in[c] && result_mask_in[c];
      MacroClockGate #(.ENABLE_GATING(USE_CLOCK_GATING)) u_csa_clock_gate (
        .clock(clock), .enable(csa_capture_en), .gated_clock(csa_clock)
      );
      wire result_clock;
      wire result_enable;
      assign result_enable = csa_valid && mask_csa[c] && result_mask_csa[c];
      if (USE_CLOCK_GATING) begin : g_result_icg
        MacroClockGate u_clock_gate (
          .clock(clock),
          .enable(result_enable),
          .gated_clock(result_clock)
        );
      end else begin : g_result_no_icg
        assign result_clock = clock;
      end
      // Masked OC payload holds. Valid/mask identify which values belong to
      // this request; shared ACT and SRAM retained output serve active OCs.
      // Parent-blocked OCs hold at both CSA and output boundaries. Tags/valid
      // still advance for every accepted request, including result_mask=0.
      always_ff @(posedge result_clock or negedge reset_n)
        if (!reset_n) cim_odata[18*c+:18] <= '0;
        else if (result_enable) cim_odata[18*c+:18] <= phase_sum[c];
      wire enabled_oc = in_valid && mask_in[c];
      // Shared CPA-stage correction follows the registered result masks,
      // not the next request's input-stage controls. Closed consumers see zero.
      wire [17:0] oc_correction = correction_cpa & {18{result_enable}};
      MacroW8MainOC u_compute (
        .csa_clock(csa_clock), .csa_capture_en(csa_capture_en),
        .weights(sram_read_data[256*c +: 256]), .activations(activation_in),
        .weight_mode(weight_mode_in), .weight_signed(signed_en_in),
        .activation_signed(activation_signed_in), .enable(enabled_oc),
        .correction(oc_correction), .result(phase_sum[c])
      );
    end
  endgenerate

  // Three boundaries: input n, CSA n+1, output n+2. All tags follow the data.
  always_ff @(posedge macro_clock or negedge reset_n) begin
    if (!reset_n) begin
      in_valid <= 1'b0;
      csa_valid <= 1'b0;
      mask_csa <= '0;
      result_mask_csa <= '0;
      phase_csa <= '0;
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
      csa_valid <= in_valid;
      cim_odata_valid <= csa_valid;
      if (issue) begin
        weight_mode_in <= decode_weight_mode(cim_precision);
        signed_en_in <= cim_signed_en;
        activation_signed_in <= digit_is_signed(cim_precision, cim_phase, cim_signed_en);
        mask_in <= cim_oc_mask;
        result_mask_in <= cim_result_mask;
        phase_in <= cim_phase;
      end
      if (in_valid) begin
        mask_csa <= mask_in;
        result_mask_csa <= result_mask_in;
        phase_csa <= phase_in;
      end
      if (csa_valid) begin
        cim_odata_oc_mask <= mask_csa;
        cim_odata_phase   <= phase_csa;
      end
    end
  end

`ifndef SYNTHESIS
`ifdef SINGLE_MACRO_ASSERTIONS
  // Verification state only; SRAM initialization survives logic reset_n.
  logic [3:0] initialized_ocs[0:255];
  initial for (int a = 0; a < 256; a++) initialized_ocs[a] = '0;
  always @(posedge clock) begin
    if (reset_n) begin
      if (sram_ren && (cim_ren || in_valid || sram_wen)) $fatal(1, "SM_PROTOCOL: regular read overlaps compute/write");
      if (sram_wen) begin
        if (cim_ren) $fatal(1, "SM_PROTOCOL: simultaneous read/write");
        // Only the pre-CSA stage still consumes SRAM output. A write at n+2
        // is legal while the previous request completes through its CPA.
        if (in_valid) $fatal(1, "SM_PROTOCOL: write before pipeline drain");
        // Reduction catches X/Z without simulator-specific handling of
        // $isunknown on a wide, temporary concatenation.
        if ((^{sram_waddr, sram_wdata, sram_wmask}) === 1'bx) $fatal(1, "SM_PROTOCOL: unknown write input");
        initialized_ocs[sram_waddr] <= initialized_ocs[sram_waddr] | ~sram_wmask;
      end
      if (issue) begin
        if ((^{cim_precision, cim_phase, cim_signed_en, cim_raddr, cim_station, cim_oc_mask,
               cim_result_mask, cim_idata}) === 1'bx)
          $fatal(1, "SM_PROTOCOL: unknown compute input");
        if (!legal_phase(cim_precision, cim_phase)) $fatal(1, "SM_PROTOCOL: illegal precision/phase");
        if (!cim_station) begin
          if (!hold_valid) $fatal(1, "SM_PROTOCOL: reuse invalid hold");
          if (cim_raddr != held_address) $fatal(1, "SM_PROTOCOL: reuse address mismatch");
        end
        // A bank write initializes only the two unmasked OCs.
        if ((initialized_ocs[cim_raddr] & cim_oc_mask) != cim_oc_mask)
          $fatal(1, "SM_PROTOCOL: read uninitialized row");
      end
    end
  end
`endif
`endif
endmodule
`default_nettype wire
