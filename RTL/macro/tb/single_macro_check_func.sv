// Simulation-only checks and reference helpers. Include inside the consuming module.
// Used only by the SingleMacro protocol assertions.
  // Check phase legality using the activation precision (A).
  function automatic logic legal_phase(input logic [2:0] precision, input logic [1:0] phase);
    case (precision)
      3'd0, 3'd2: legal_phase = phase == 2'd0;
      3'd1, 3'd3, 3'd5: legal_phase = phase <= 2'd1;
      3'd4, 3'd6: legal_phase = 1'b1;
      default: legal_phase = 1'b0;
    endcase
  endfunction
