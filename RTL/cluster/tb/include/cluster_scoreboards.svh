// Four parallel checkers: ACT bank, ICG/hold, per-phase arithmetic history and
// Command/raw output.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

// A. ACT integrity: untouched regions are held; an address-only Command never reloads A0.
// Check the whole bank, including slices that are not read this cycle.
// An AS address-only command must never reload A0; a new ACT packet must
// wait until the preceding packet's final internal issue has consumed it.
always @(posedge clock) begin : act_buffer_scoreboard
  logic [4095:0] wanted;
  if (!reset) begin
    wanted = dut.act_buffer;
    if (cmd_valid_i && cmd_ready_o && !dut.packet_active) wanted[0+:1024] = act_data_i;
    if (dut.act_loading) wanted[1024*dut.external_phase+:1024] = act_data_i;
    if (dut.issue && !dut.act_slice_valid[dut.phase])
      $fatal(1, "ACT buffer issued before the selected Plane was received");
    if (dut.issue && dut.packet_cmd.cim_as_cnt > 1 && dut.context_idx >= dut.command_count)
      $fatal(1, "Internal issue before the selected Context address was received");
    if (dut.issue && cmd_valid_i && cmd_ready_o && !dut.packet_active)
      $fatal(1, "ACT input overwrites a packet still being issued");
    if (monitoring) begin
      // Readiness is checked independently of the DUT's issue expression.
      // A later AS address can arrive while an earlier Context is issued.
      if (dut.packet_active && !dut.batch_input_done &&
        dut.act_slice_valid[dut.phase] &&
        (case_as <= 1 || dut.context_idx < dut.command_count) && !dut.issue)
        $fatal(1, "Ready Plane/Context was unnecessarily stalled");
      if (dut.issue && dut.act_loading) act_issue_overlap++;
      if (dut.issue && cmd_valid_i && cmd_ready_o) address_issue_overlap++;
      if (dut.packet_active && dut.act_slice_valid[dut.phase] &&
        case_as > 1 && dut.context_idx >= dut.command_count) begin
        address_wait_cycles++;
        if (dut.act_complete) late_address_wait++;
      end
    end
    #0.002;
    if (dut.act_buffer !== wanted) $fatal(1, "ACT bank write/hold mismatch");
    if ($countones(dut.act_slice_valid) > max_act_planes) max_act_planes = $countones(dut.act_slice_valid);
    act_buffer_checks++;
  end
end

// B. Clock/hold: predict this edge's write enables first, then check the real gated
// clocks and the data that must not change.
always @(posedge clock) begin : buffer_clock_scoreboard
  longint signed old_p[0:OUTPUT_BUFFER_DEPTH - 1][0:31];
  longint signed old_tmp[0:31], want_tmp[0:31];
  bit want_p[0:OUTPUT_BUFFER_DEPTH - 1][0:31];
  logic [31:0] want_input;
  int c, ph, ab, writes;
  bit writes_psum;
  if (!reset) begin
    want_input = dut.capture_valid;
    for (int l = 0; l < 32; l++) begin
      old_tmp[l]  = dut.tmp_result[l];
      want_tmp[l] = dut.capture_data[l];
      if (dut.capture_valid[l] && dut.capture_tag[l].cmd.cim_as_cnt <= 1 && dut.capture_tag[l].ph > 0)
        want_tmp[l] = old_tmp[l] + (dut.capture_data[l] <<< (4 * dut.capture_tag[l].ph));
    end
    for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++)
    for (int l = 0; l < 32; l++) begin
      old_p[d][l]  = dut.psum[d][l];
      want_p[d][l] = 0;
    end
    for (int l = 0; l < 32; l++)
    if (dut.tmp_valid[l]) begin
      c = dut.tmp_tag[l].ctx;
      ph = dut.tmp_tag[l].ph;
      ab = abits(int'(dut.tmp_tag[l].cmd.cim_precision));
      writes_psum = (dut.tmp_tag[l].cmd.cim_as_cnt > 1) ? 1 :
        (dut.tmp_tag[l].cmd.cim_os_cnt > 1 && ph == ab / 4 - 1);
      // A bypass Context can have an ID beyond the physical Psum array.
      if (writes_psum) begin
        if (c >= OUTPUT_BUFFER_DEPTH) $fatal(1, "TB: Psum Context exceeds depth");
        want_p[c][l] = 1;
      end
    end
    #0.001;
    if (dut.tmp_input_clock !== want_input) $fatal(1, "Advance tmp ICG mismatch");
    for (int l = 0; l < 32; l++) begin
      writes = 0;
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++) begin
        if (dut.psum_clock[d][l] !== want_p[d][l]) $fatal(1, "Psum ICG mismatch");
        if (dut.psum_clock[d][l]) writes++;
        if (dut.batch_active && d >= dut.batch_contexts) begin
          if (dut.psum_depth_open[d] || dut.psum_clock[d][l]) $fatal(1, "High Context entry not gated");
          high_depth_checks++;
        end
        buffer_gate_checks++;
      end
      if (writes > 1) $fatal(1, "More than one Context entry clocked for one OC");
    end
    #0.001;
    for (int l = 0; l < 32; l++)
    if (dut.tmp_result[l] !== (want_input[l] ? want_tmp[l] : old_tmp[l]))
      $fatal(1, "Single tmp register data/hold mismatch lane=%0d", l);
    for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++)
    for (int l = 0; l < 32; l++)
    if (!want_p[d][l]) begin
      if (dut.psum[d][l] !== old_p[d][l]) $fatal(1, "Gated Psum DFF changed");
      if (dut.batch_active && dut.batch_command.cim_os_cnt == 1) bypass_psum_hold_checks++;
    end
  end
end
// C. Arithmetic history: accumulate phases independently per Context; data must never
// bleed between different Contexts.
// Independent arithmetic history; debug snapshots are TB-only, not DUT state.
always @(posedge clock) begin : arithmetic_scoreboard
  longint signed running_sum[0:MAX_CONTEXTS - 1][0:31];
  longint signed raw_slice[0:31], saved_fa[0:31], saved_fb[0:31];
  longint signed want[0:31], fa, fb, aa, bb;
  int cx[0:31], ph, kt, c, fc;
  bit check_p[0:31], traced, is_as, acc, fusion, trace_as;
  string trace_row, op;
  if (!reset && monitoring) begin
    traced = 0;
    trace_row = "";
    for (int l = 0; l < 32; l++) begin
      check_p[l] = 0;
      if (!dut.fusion_enable[l] && (dut.fusion_a[l] !== 0 || dut.fusion_b[l] !== 0))
        $fatal(1, "Unused fusion operands not isolated");
      if (!dut.acc_enable[l] && (dut.acc_a[l] !== 0 || dut.acc_b[l] !== 0))
        $fatal(1, "Unused acc operands not isolated");
      if (dut.tmp_valid[l]) begin
        c = dut.tmp_tag[l].ctx;
        ph = dut.tmp_tag[l].ph;
        kt = dut.tmp_tag[l].kt;
        is_as = dut.tmp_tag[l].cmd.cim_as_cnt > 1;
        cx[l] = c;
        if (ph == 0 && kt == 0) running_sum[c][l] = 0;
        running_sum[c][l] += raw_slice[l] <<< (4 * ph);
        want[l] = running_sum[c][l];
        check_p[l] = is_as ? 1 :
          (dut.tmp_tag[l].cmd.cim_os_cnt > 1 && ph == abits(int'(dut.tmp_tag[l].cmd.cim_precision)) / 4 - 1);
        if (dut.psum_write[l] !== check_p[l]) $fatal(1, "Psum write phase mismatch");
        acc = kt > 0 && (is_as ? ph == 0 : check_p[l]);
        fusion = ph > 0;
        if (dut.acc_enable[l] !== acc) $fatal(1, "Acc phase mismatch");
        if (is_as && (dut.fusion_enable[l] !== fusion)) $fatal(1, "AS fusion phase mismatch");
        if ((check_p[l] || dut.result_done[l]) && dut.arithmetic_result[l] !== want[l])
          $fatal(1, "Running Context arithmetic mismatch");
        if (standard_case != 0 && !traced) begin
          fa = is_as ? dut.fusion_a[l] : saved_fa[l];
          fb = is_as ? dut.fusion_b[l] : saved_fb[l];
          aa = dut.acc_a[l];
          bb = dut.acc_b[l];
          trace_as = is_as;
          op = fusion ? (acc ? "fusion_then_acc" : "fusion") : acc ? "acc" : "seed";
          trace_row = $sformatf(
            "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            standard_case,
            int'(dut.tmp_tag[l].cmd.cim_precision),
            int'(dut.tmp_tag[l].cmd.cim_signed_en),
            kt,
            c,
            ph,
            l,
            op,
            raw_slice[l],
            fa,
            fb,
            aa,
            bb,
            dut.arithmetic_result[l],
            int'(dut.result_done[l]),
            dut.tmp_result[l]
          );
          traced = 1;
        end
      end
    end
    // Save incoming reduction and WS fusion operands for the next tagged tmp consumer.
    for (int l = 0; l < 32; l++)
    if (dut.capture_valid[l]) begin
      raw_slice[l] = dut.capture_data[l];
      saved_fa[l]  = dut.fusion_a[l];
      saved_fb[l]  = dut.fusion_b[l];
    end
    #2;
    if (traced) begin
      fc = cycle - first_external - (trace_as ? 0 : 1);
      $fdisplay(operation_trace, "%0d,%s,%0d", cycle - first_external, trace_row, fc);
      $fflush(operation_trace);
    end
    for (int l = 0; l < 32; l++)
    if (check_p[l] && dut.psum[cx[l]][l] !== want[l]) $fatal(1, "Psum history mismatch ctx=%0d lane=%0d", cx[l], l);
  end
end

// D. End-to-end protocol/results: Command stability, actual issues, lane cycles and the
// value/duplicate checks.
// Capture accepted compute events before NBA, inspect raw result after NBA.
always @(posedge clock) begin : scoreboard
  int t, c, p, idx, tag, external_ctx, external_ph;
  bit act_sample, command_sample;
  cycle = cycle + 1;
  if (!reset && monitoring) begin
    if (held_cmd && (!cmd_valid_i || cmd_i !== last_cmd)) $fatal(1, "Command changed before ready");
    if (held_act_for_cmd && act_data_i !== last_act) $fatal(1, "ACT payload changed while its Command was stalled");
    held_cmd = cmd_valid_i && !cmd_ready_o;
    last_cmd = cmd_i;
    held_act_for_cmd = cmd_valid_i && !cmd_ready_o && dut.need_plane;
    last_act = act_data_i;
    if (cmd_valid_i && cmd_ready_o) begin
      display_command("ACCEPT", cmd_i);
      if (first_external < 0) first_external = cycle;
      input_commands++;
    end
    command_sample = cmd_valid_i && cmd_ready_o;
    act_sample = dut.act_loading || (command_sample && !dut.packet_active);
    if (act_sample) act_planes_received++;
    external_ctx = case_as > 1 ? (dut.packet_active ? dut.command_count : 0) : dut.context_idx;
    external_ph  = dut.act_loading ? dut.external_phase : 0;
    if (standard_case != 0 && (command_sample || act_sample))
      $fdisplay(
        external_trace,
        "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%02h,%0d,%0d,%s",
        cycle - first_external,
        standard_case,
        int'(cmd_i.cim_precision),
        int'(cmd_i.cim_signed_en),
        dut.tile,
        int'(command_sample),
        command_sample ? external_ctx : -1,
        cmd_i.cim_weight_raddr,
        int'(act_sample),
        act_sample ? external_ph : -1,
        act_sample ? $sformatf(
          "%0256h", act_data_i
        ) : ""
      );
    if (dut.issue) begin
      idx = issue_count;
      t   = idx / (case_r * case_p);
      if (case_as > 1) begin
        p = (idx / case_r) % case_p;
        c = idx % case_r;
      end else begin
        c = (idx / case_p) % case_r;
        p = idx % case_p;
      end
      if (dut.phase != p || dut.context_idx != c || dut.tile != t)
        $fatal(1, "Issue order differs from spec at index %0d", idx);
      // Check the consumed Plane, including AS reuse while external ACT
      // deliberately carries unrelated data. Sampling is tied to cmd_fire.
      for (int k = 0; k < 256; k++)
      if (dut.plane[4*k+:4] !== (k < case_used_digits ? 4'(activation[t][c][k] >> (4 * p)) : 4'd0))
        $fatal(1, "ACT Plane sampling/reuse mismatch tile=%0d ctx=%0d phase=%0d digit=%0d", t, c, p, k);
      if (dut.command.cim_weight_raddr !== 8'('h20 + 16 * t + (case_as > 1 ? c : 0)))
        $fatal(1, "Descriptor weight address mismatch");
      if (issue_count == 0) first_issue = cycle;
      if (exact_ii) begin
        if (case_as > 1) begin
          if (cycle - first_external != t * (1 + case_r * case_p) + 1 + (p * case_r + c))
            $fatal(1, "AS external-load/internal-issue timing mismatch");
        end else if (cycle - first_external != (t * case_r + c) * (case_p + 1) + 1 + p)
          $fatal(1, "WS external-load/internal-issue timing mismatch");
      end
      last_issue = cycle;
      issue_count++;
      if ((dut.ren & ~dut.station) != 0) reuse_cycles++;
      if (p == case_p - 1 && t == case_os - 1)
        for (int l = 0; l < 32; l++) if (expected_mask[l]) lane_due[c][l] = cycle + lane_latency(l);
    end
    #1;
    // Per-OC publication: every lane leaves the Cluster on its own endpoint
    // latency. Premature completion is checked against the per-Context done
    // bits; the due-cycle pulse against the published lane value.
    for (int cx = 0; cx < case_r; cx++)
    for (int l = 0; l < 32; l++)
    if (lane_due[cx][l] >= cycle) begin
      if (cycle < lane_due[cx][l] && completion_seen[cx][l])
        $fatal(1, "Premature terminal write ctx=%0d lane=%0d", cx, l);
      if (cycle == lane_due[cx][l] && (!completion_seen[cx][l] || !dut.raw_valid[l]))
        $fatal(1, "Missing direct terminal write ctx=%0d lane=%0d", cx, l);
    end
    if (dut.raw_valid != 0) begin
      if ((dut.raw_valid & ~expected_mask) != 0) $fatal(1, "Raw valid on masked lane");
      for (int l = 0; l < 32; l++)
      if (out_valid_o[l]) begin
        tag = dut.raw_context[l];
        if (tag < 0 || tag >= case_r) $fatal(1, "Raw context out of range %0d", tag);
        if (raw_seen[tag][l] || lane_due[tag][l] != cycle)
          $fatal(1, "Raw latency/seen mismatch ctx=%0d lane=%0d due=%0d actual=%0d", tag, l, lane_due[tag][l], cycle);
        if (psum_data_o[32*l+:32] !== 32'(expected[tag][l]))
          $fatal(
            1,
            "Raw mismatch case=%0d p=%0d sign=%0d ctx=%0d lane=%0d got=%0d expected=%0d",
            cases_run,
            cmd_i.cim_precision,
            cmd_i.cim_signed_en,
            tag,
            l,
            $signed(
              dut.raw_data[32*l+:32]
            ),
            expected[tag][l]
          );
        raw_seen[tag][l] = 1;
        raw_count++;
      end
    end
  end
end
