`timescale 1ns / 1ps
// Ellipses = combinational reduction logic; t1..t6 = FORWARDING DFFs.
// Terminal results are tapped BEFORE these DFFs. No root/output/alignment DFF.
module ClusterReduceTree #(
  parameter bit USE_CLOCK_GATING = 1
) (
  input logic clock,
  input logic reset,
  input logic early_valid_i,
  input logic [6:0] early_split_i,
  input logic [7:0] early_en_i,
  input logic [31:0] early_oc_i,
  input logic valid_i,
  input logic [6:0] split_i,
  input logic [7:0] en_i,
  input logic [31:0] oc_i,
  input logic [575:0] macro_data_i,
  output logic [2:0] tap_valid_o,
  output logic [31:0] tap_mask_o[0:2],
  output logic [671:0] tap_data_o[0:2]
);
  import cluster_pkg::*;
  typedef struct packed {
    logic valid;
    logic [6:0] split;
    logic [7:0] en;
    logic [31:0] oc;
  } ctrl_t;
  ctrl_t early_ctrl, c0, c1, c2;
  ctrl_t source_ctrl[0:6];
  logic [3:0] cg_channel_req[1:6];
  wire [6:1] reduce_clock;
  wire signed [20:0] forward_q[1:6][0:3];
  logic signed [20:0] left_data[0:6][0:3], right_data[0:6][0:3];
  wire signed  [20:0] node_adder[0:6][0:3];
  logic signed [20:0] node_value[0:6][0:3];
  int unsigned gated_checks[0:6], active_edges[0:6];
  int unsigned terminal_writes[0:2];
  int unsigned downstream_hold_checks[0:2];

  function automatic int start_of(input int n);
    return n == 0 ? 0 : n < 3 ? (n - 1) * 4 : (n - 3) * 2;
  endfunction
  function automatic int size_of(input int n);
    return n == 0 ? 8 : n < 3 ? 4 : 2;
  endfunction
  // Every merge inherits the fixed leftmost Macro's OC mask, even when
  // that Macro is disabled. A masked child must not expose stale DFF data.
  function automatic bit subtree_live(input ctrl_t ctrl, input int first, count, c);
    if (count >= 2 && !ctrl.oc[4*first+c]) return 0;
    for (int m = 0; m < 8; m++)
    if (m >= first && m < first + count && ctrl.en[m] && ctrl.oc[4*m+c]) begin
      if (count >= 4 && !ctrl.oc[4*((m/2)*2)+c]) continue;
      if (count >= 8 && !ctrl.oc[4*((m/4)*4)+c]) continue;
      return 1;
    end
    return 0;
  endfunction
  function automatic bit side_live(input ctrl_t ctrl, input int n, c, side);
    int count;
    count = size_of(n) / 2;
    return subtree_live(ctrl, start_of(n) + side * count, count, c);
  endfunction
  function automatic logic [3:0] forward_mask(input ctrl_t ctrl, input int n);
    logic [3:0] result;
    bit continue_up;
    result = '0;
    // Propagate consumer demand through every ancestor up to the endpoint.
    // A blocked parent keeps its child forwarding outputs held.
    // Gate the RESULT DFF if this subtree terminates here. A terminal pair
    // leaves t3..t6 closed while its combinational result goes to the buffer.
    continue_up = n < 3 ? !ctrl.split[0] : !ctrl.split[1+(n-3)/2];
    if (ctrl.valid && !ctrl.split[n] && continue_up)
      for (int c = 0; c < 4; c++)
      result[c] = subtree_live(ctrl, start_of(n), size_of(n), c) &&
        merge_contributes(ctrl.split, ctrl.oc, start_of(n), c);
    return result;
  endfunction
  function automatic int span(input logic [6:0] split, input int first);
    int count;
    count = 0;
    for (int m = 0; m < 8; m++) if (m >= first && first_leaf(split, m) == first) count++;
    return count;
  endfunction

  always_comb begin
    early_ctrl = '{early_valid_i, early_split_i, early_en_i, early_oc_i};
    c0 = '{valid_i, split_i, en_i, oc_i};
    for (int n = 0; n < 7; n++) begin
      source_ctrl[n] = n == 0 ? c2 : n < 3 ? c1 : c0;
      for (int c = 0; c < 4; c++) begin
        if (n == 0) begin
          left_data[n][c]  = forward_q[1][c];
          right_data[n][c] = forward_q[2][c];
        end else if (n < 3) begin
          left_data[n][c]  = forward_q[3+2*(n-1)][c];
          right_data[n][c] = forward_q[4+2*(n-1)][c];
        end else begin
          left_data[n][c]  = $signed(macro_data_i[72*(2*(n-3))+18*c+:18]);
          right_data[n][c] = $signed(macro_data_i[72*(2*(n-3)+1)+18*c+:18]);
        end
      end
    end
  end
  for (genvar n = 0; n < 7; n++) begin : g_logic
    localparam int W = n == 0 ? 21 : n < 3 ? 20 : 19;
    wire signed [W - 2:0] lhs[0:3], rhs[0:3];
    wire signed [W - 1:0] sum[0:3];
    for (genvar c = 0; c < 4; c++) begin : g_oc
      assign lhs[c] = left_data[n][c];
      assign rhs[c] = right_data[n][c];
      assign sum[c] = $signed({lhs[c][W-2], lhs[c]}) + $signed({rhs[c][W-2], rhs[c]});
      assign node_adder[n][c] = sum[c];
    end
    always_comb
      for (int c = 0; c < 4; c++) begin
        if (side_live(source_ctrl[n], n, c, 0) && side_live(source_ctrl[n], n, c, 1))
          node_value[n][c] = node_adder[n][c];
        else if (side_live(source_ctrl[n], n, c, 0)) node_value[n][c] = left_data[n][c];
        else if (side_live(source_ctrl[n], n, c, 1)) node_value[n][c] = right_data[n][c];
        else node_value[n][c] = '0;
      end
  end

  // ICG enable is explicitly registered ONE edge before its forwarding DFF:
  // t3..t6 request at Cq+1, capture at Cq+2; t1/t2 request at Cq+2,
  // capture at Cq+3. Root writes the existing destination buffer at Cq+4.
  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      c1 <= '0;
      c2 <= '0;
      for (int n = 1; n < 7; n++) cg_channel_req[n] <= '0;
    end else begin
      c1 <= c0;
      c2 <= c1;
      for (int n = 1; n < 7; n++) begin
        cg_channel_req[n] <= forward_mask(n < 3 ? c0 : early_ctrl, n);
      end
    end
  end
  for (genvar n = 1; n < 7; n++) begin : g_forward
    localparam int W = n < 3 ? 20 : 19;
    logic signed [W - 1:0] result_q[0:3];
    wire [3:0] oc_clock;
    assign reduce_clock[n] = |oc_clock;
    for (genvar c = 0; c < 4; c++) begin : g_oc_clock
      MacroClockGate #(
        .ENABLE_GATING(USE_CLOCK_GATING)
      ) u_clock_gate (
        .clock(clock),
        .enable(cg_channel_req[n][c]),
        .gated_clock(oc_clock[c])
      );
      assign forward_q[n][c] = result_q[c];
      always_ff @(posedge oc_clock[c] or posedge reset)
        if (reset) result_q[c] <= '0;
        else if (cg_channel_req[n][c]) result_q[c] <= node_value[n][c];
    end
    // synthesis translate_off
    initial begin
      gated_checks[n] = 0;
      active_edges[n] = 0;
    end
    always @(posedge clock) begin : check_gating
      logic [3:0] sampled_req;
      logic signed [W - 1:0] saved[0:3];
      sampled_req = cg_channel_req[n];
      for (int c = 0; c < 4; c++) saved[c] = result_q[c];
      if (!reset) begin
        if (sampled_req != forward_mask(source_ctrl[n], n))
          $fatal(1, "Forward node %0d enable not predicted one cycle ahead", n);
        if (|sampled_req) active_edges[n]++;
        #1;
        if (!reset && oc_clock !== (USE_CLOCK_GATING ? sampled_req : 4'hf)) $fatal(1, "ICG pulse mismatch node %0d", n);
        if (!reset)
          for (int c = 0; c < 4; c++)
          if (!sampled_req[c]) begin
            if (result_q[c] !== saved[c]) $fatal(1, "Gated forwarding DFF t%0d OC%0d changed", n, c);
            gated_checks[n]++;
          end
      end
    end
    // synthesis translate_on
  end

  // Combinational taps BEFORE forwarding DFFs; receiver writes its existing
  // Fusion/Psum/output storage. Different depths may target different Contexts
  // in the same cycle, so each tap has its own mask/data and delayed metadata.
  always_comb begin : terminal_taps
    ctrl_t ctrl;
    int width, g, n;
    tap_valid_o = '0;
    for (int stage = 0; stage < 3; stage++) begin
      ctrl = stage == 0 ? c0 : stage == 1 ? c1 : c2;
      tap_mask_o[stage] = '0;
      tap_data_o[stage] = '0;
      if (ctrl.valid)
        for (int m = 0; m < 8; m++)
        if (first_leaf(ctrl.split, m) == m) begin
          width = span(ctrl.split, m);
          g = group_of(ctrl.split, m);
          if ((stage == 0 && width <= 2) || (stage == 1 && width == 4) || (stage == 2 && width == 8))
            for (int c = 0; c < 4; c++) begin
              if (width == 1) begin
                if (ctrl.en[m] && ctrl.oc[4*m+c]) begin
                  tap_mask_o[stage][4*g+c] = 1;
                  tap_data_o[stage][21*(4*g+c)+:21] = 21'($signed(macro_data_i[72*m+18*c+:18]));
                end
              end else begin
                n = width == 2 ? 3 + m / 2 : width == 4 ? 1 + m / 4 : 0;
                if (subtree_live(ctrl, start_of(n), size_of(n), c)) begin
                  tap_mask_o[stage][4*g+c] = 1;
                  tap_data_o[stage][21*(4*g+c)+:21] = node_value[n][c];
                end
              end
            end
        end
      tap_valid_o[stage] = |tap_mask_o[stage];
    end
  end
  // synthesis translate_off
  initial begin
    gated_checks[0] = 0;
    active_edges[0] = 0;
    for (int stage = 0; stage < 3; stage++) begin
      terminal_writes[stage] = 0;
      downstream_hold_checks[stage] = 0;
    end
  end
  always @(posedge clock) begin : check_downstream
    logic [3:0] changed_inputs[0:2];
    logic signed [20:0] saved_sum[0:2][0:3];
    if (!reset) begin
      for (int stage = 0; stage < 3; stage++) begin
        if (tap_valid_o[stage]) terminal_writes[stage]++;
        changed_inputs[stage] = stage == 0 ? cg_channel_req[1] | cg_channel_req[2] :
          cg_channel_req[3 + 2 * (stage - 1)] | cg_channel_req[4 + 2 * (stage - 1)];
        for (int c = 0; c < 4; c++) saved_sum[stage][c] = node_adder[stage][c];
      end
      #1;
      if (!reset)
        for (int n = 0; n < 3; n++)
        for (int c = 0; c < 4; c++)
        if (!changed_inputs[n][c]) begin
          if (node_adder[n][c] !== saved_sum[n][c]) $fatal(1, "Downstream adder t%0d toggled behind closed DFFs", n);
          downstream_hold_checks[n]++;
        end
    end
  end
  // synthesis translate_on
endmodule
