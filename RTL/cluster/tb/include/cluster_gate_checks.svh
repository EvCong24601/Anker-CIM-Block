// Compare advance requests against actual consumers at the capture edge.
// In particular, an empty batch must not borrow the next batch's OC mask.
always @(posedge clock) if (!reset && dut.tmp_input_cg_en !== dut.capture_valid)
  $fatal(1, "TMP clock request has no matching capture transaction");

// Independent endpoint walk for child output clock demand. Decode the endpoint
// top-down, then inspect each fixed-leftmost mask on this leaf's merge path.
function automatic bit expected_result_demand(input cluster_ctrl_t cmd, input int m, input int c);
  int node, first, size;
  node  = 0;
  first = 0;
  size  = 8;
  while (size > 1 && cmd.cim_reduce_split_mask[node]) begin
    size /= 2;
    if (m >= first + size) begin
      first += size;
      node = 2 * node + 2;
    end else node = 2 * node + 1;
  end
  for (int width = 1; width <= size; width *= 2) if (!cmd.cim_macro_oc_mask[4*((m/width)*width)+c]) return 0;
  return 1;
endfunction
// Physical clock checks use the pre-edge transaction/tag, never the live OC
// mask of a later Command. Root valid/control clocks deliberately keep running.
for (genvar lane = 0; lane < 32; lane++) begin : g_check_output_gate
  always @(posedge clock) begin
    bit raw_req;
    logic [31:0] wanted_raw;
    int wanted_context;
    if (!reset) begin
      raw_req = dut.result_done[lane];
      wanted_raw = 32'(dut.arithmetic_result[lane]);
      wanted_context = dut.tmp_tag[lane].ctx;
      #0.002;
      if (!reset) begin
        if (psum_valid[lane] !== raw_req)
          $fatal(1, "Output lane clock mismatch lane=%0d", lane);
        if (raw_req && (raw_psum[32*lane+:32] !== wanted_raw || dut.raw_context[lane] != wanted_context))
          $fatal(1, "Storage-backed raw view mismatch lane=%0d", lane);
      end
    end
  end
end
for (genvar macro_id = 0; macro_id < 8; macro_id++) begin : g_check_act_bank_gate
  for (genvar bank = 0; bank < 3; bank++) begin : g_bank
    localparam int FIRST = bank == 0 ? 0 : bank == 1 ? 128 : 256;
    localparam int WIDTH = bank == 2 ? 256 : 128;
    always @(posedge clock or posedge reset) begin
      bit want;
      logic [WIDTH - 1:0] saved, expected_act;
      if (reset) begin
        #0.002;
        if (dut.g_macro[macro_id].u_macro.activation_in[FIRST +: WIDTH] !== '0)
          $fatal(1, "Cluster ACT bank reset failed macro=%0d bank=%0d", macro_id, bank);
      end else begin
        want = dut.ren[macro_id] &&
               (bank == 0 || (bank == 1 && dut.command.cim_precision <= 4) ||
                             (bank == 2 && dut.command.cim_precision <= 1));
        saved = dut.g_macro[macro_id].u_macro.activation_in[FIRST +: WIDTH];
        expected_act = dut.g_macro[macro_id].idata[FIRST +: WIDTH];
        #0.002;
        if (!reset) begin
          if (dut.g_macro[macro_id].u_macro.act_clock[bank] !== want)
            $fatal(1, "Cluster ACT bank clock mismatch macro=%0d bank=%0d", macro_id, bank);
          if (dut.g_macro[macro_id].u_macro.activation_in[FIRST +: WIDTH] !== (want ? expected_act : saved))
            $fatal(1, "Cluster ACT bank capture/hold mismatch macro=%0d bank=%0d", macro_id, bank);
        end
      end
    end
  end
end
for (genvar macro_id = 0; macro_id < 8; macro_id++) begin : g_check_macro_gate
  for (genvar oc = 0; oc < 4; oc++) begin : g_oc
    always @(posedge clock) begin
      bit want;
      bit consumer;
      logic [17:0] saved;
      if (!reset) begin
        consumer = expected_result_demand(dut.in_tag.cmd, macro_id, oc);
        if (dut.g_macro[macro_id].u_macro.in_valid && dut.g_macro[macro_id].u_macro.result_mask_in[oc] !== consumer)
          $fatal(1, "Macro consumer request not aligned ahead of result macro=%0d OC=%0d", macro_id, oc);
        want  = dut.g_macro[macro_id].u_macro.in_valid && dut.g_macro[macro_id].u_macro.mask_in[oc] && consumer;
        saved = dut.macro_data[72*macro_id+18*oc+:18];
        #0.002;
        if (!reset) begin
          if (dut.g_macro[macro_id].u_macro.g_oc[oc].result_clock !== want)
            $fatal(1, "Macro OC clock mismatch macro=%0d OC=%0d", macro_id, oc);
          if (!want && dut.macro_data[72*macro_id+18*oc+:18] !== saved)
            $fatal(1, "Masked Macro OC payload changed macro=%0d OC=%0d", macro_id, oc);
        end
      end
    end
  end
  always @(posedge clock) begin
    bit compute_req, memory_req;
    if (!reset) begin
      compute_req = dut.ren[macro_id] || dut.g_macro[macro_id].u_macro.in_valid ||
                  dut.g_macro[macro_id].u_macro.cim_odata_valid;
      memory_req = dut.memory_wen[macro_id] || (dut.regular_read && dut.regular_macro_id == macro_id) ||
                 (dut.ren[macro_id] && dut.station[macro_id]);
      #0.002;
      if (!reset && (dut.g_macro[macro_id].u_macro.macro_clock !== compute_req ||
                   dut.g_macro[macro_id].u_macro.memory_clock !== memory_req))
        $fatal(1, "Macro clock domain mismatch macro=%0d", macro_id);
    end
  end
end
for (genvar pair_id = 0; pair_id < 4; pair_id++) begin : g_check_pair_source_hold
  for (genvar oc = 0; oc < 4; oc++) begin : g_oc
    always @(posedge clock) begin
      bit left_update, right_update;
      logic signed [20:0] saved_left, saved_right, saved_adder;
      if (!reset) begin
        left_update  = dut.g_macro[2*pair_id].u_macro.g_oc[oc].result_enable;
        right_update = dut.g_macro[2*pair_id+1].u_macro.g_oc[oc].result_enable;
        saved_left   = dut.u_reduce.left_data[3+pair_id][oc];
        saved_right  = dut.u_reduce.right_data[3+pair_id][oc];
        saved_adder  = dut.u_reduce.node_adder[3+pair_id][oc];
        #0.002;
        if (!reset) begin
          if (!left_update && dut.u_reduce.left_data[3+pair_id][oc] !== saved_left)
            $fatal(1, "Closed left child changed pair adder input pair=%0d OC=%0d", pair_id, oc);
          if (!right_update && dut.u_reduce.right_data[3+pair_id][oc] !== saved_right)
            $fatal(1, "Closed right child changed pair adder input pair=%0d OC=%0d", pair_id, oc);
          if (!left_update && !right_update && dut.u_reduce.node_adder[3+pair_id][oc] !== saved_adder)
            $fatal(1, "Pair adder toggled behind closed child clocks pair=%0d OC=%0d", pair_id, oc);
        end
      end
    end
  end
end

// Three delay paths share compact metadata; no per-lane Command registers.
for (genvar path = 0; path < 3; path++) begin : g_check_shared_meta
  always @(posedge clock) begin
    bit tmp_req, raw_req;
    logic [$bits(dut.tmp_path_meta[0]) - 1:0] saved_tmp;
    int want_ph, want_ctx, want_kt, raw_ctx, saved_raw_ctx;
    if (!reset) begin
      tmp_req = |(dut.capture_valid & dut.path_lanes[path]);
      raw_req = |(dut.result_done & dut.path_lanes[path]);
      want_ph = dut.tap_tag[path].ph;
      want_ctx = dut.tap_tag[path].ctx;
      want_kt = dut.tap_tag[path].kt;
      raw_ctx = int'(dut.tmp_path_meta[path].ctx);
      saved_tmp = dut.tmp_path_meta[path];
      saved_raw_ctx = int'(dut.raw_path_context[path]);
      #0.002;
      if (!reset) begin
        if (dut.g_shared_meta[path].tmp_meta_clock !== tmp_req ||
            dut.g_shared_meta[path].raw_meta_clock !== raw_req)
          $fatal(1, "Shared metadata advance clock mismatch path=%0d", path);
        if (tmp_req && (dut.tmp_path_meta[path].ph != want_ph ||
            dut.tmp_path_meta[path].ctx != want_ctx || dut.tmp_path_meta[path].kt != want_kt))
          $fatal(1, "Shared tmp metadata alignment mismatch path=%0d", path);
        if (!tmp_req && dut.tmp_path_meta[path] !== saved_tmp)
          $fatal(1, "Inactive shared metadata changed path=%0d", path);
        if (dut.raw_path_context[path] != (raw_req ? raw_ctx : saved_raw_ctx))
          $fatal(1, "Shared result Context mismatch path=%0d", path);
      end
    end
  end
end

// A shared OC adder must never be demanded by two scheduling operations.
always @(posedge clock) begin : check_shared_adder
  if (!reset)
    for (int l = 0; l < 32; l++) begin
      if (dut.fusion_enable[l] && dut.acc_enable[l])
        $fatal(1, "SHARED_ADDER: simultaneous fusion/acc demand lane=%0d", l);
      if (!dut.fusion_enable[l] && !dut.acc_enable[l] &&
          (dut.shared_add_a[l] !== 0 || dut.shared_add_b[l] !== 0))
        $fatal(1, "SHARED_ADDER: inactive operands not isolated lane=%0d", l);
    end
end
