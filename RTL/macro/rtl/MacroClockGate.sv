`timescale 1ns / 1ps
`default_nettype none
// Latch-based functional ICG model. Replace this module with the technology
// ICG cell for ASIC implementation; do not use an unlatched combinational gate.
module MacroClockGate #(
  parameter bit ENABLE_GATING = 1
) (
  input  logic clock,
  input  logic enable,
  output wire  gated_clock
);
  generate
    if (ENABLE_GATING) begin : g_icg
      logic enable_latched;
      always_latch begin
        if (!clock) enable_latched <= enable;
      end
      assign gated_clock = clock & enable_latched;
    end else begin : g_bypass
      // Verification/reference configuration; receiving registers retain CEs.
      assign gated_clock = clock;
    end
  endgenerate
endmodule
`default_nettype wire
