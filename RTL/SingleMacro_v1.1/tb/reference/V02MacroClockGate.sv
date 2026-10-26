`timescale 1ns/1ps
`default_nettype none
// Latch-based functional ICG model. Replace this module with the technology
// ICG cell for ASIC implementation; do not use an unlatched combinational gate.
module V02MacroClockGate (
    input  logic clock,
    input  logic enable,
    output wire  gated_clock
);
    logic enable_latched;
    always_latch begin
        if (!clock)
            enable_latched <= enable;
    end
    assign gated_clock = clock & enable_latched;
endmodule
`default_nettype wire
