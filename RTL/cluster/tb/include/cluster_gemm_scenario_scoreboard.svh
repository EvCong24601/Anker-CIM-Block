// Check physical lane positions, mask holes, exact timing and dense GEMM order.
always @(posedge clock) begin : edge_scoreboard
  logic [ 31:0] previous_valid;
  logic [255:0] previous_quant;
  int row, phase, n, index;
  cycle++;
  previous_valid = out_valid_o;
  previous_quant = requant_data_o;
  if (!reset && monitoring) begin
    if (cmd_valid_i && cmd_ready_o) begin
      if (first_accept < 0) first_accept = cycle;
      if (cycle != first_accept + (phases + 1) * commands || cmd_i.cim_weight_raddr !== 8'(base_address + active_tile))
        $fatal(1, "GEMM scenario: Command cycle or address mismatch");
      commands++;
      total_commands++;
    end
    if (dut.issue) begin
      row   = issues / phases;
      phase = issues % phases;
      if (cycle != first_accept + (phases + 1) * row + 1 + phase || dut.context_idx != row || dut.phase != phase ||
        dut.plane !== act_planes[row * phases + phase] || dut.ren !== 8'(en) ||
        dut.command.cim_weight_raddr !== 8'(base_address + active_tile))
        $fatal(1, "GEMM scenario: internal ACT/Context/phase/weight route mismatch");
      for (int macro = first_macro; macro < first_macro + macro_count; macro++) begin
        // One-tile preload readback already retains the first weight row.
        if (dut.station[macro] !== (issues == 0 && !(active_tile == 0 && n_tiles == 1))) $fatal(1, "GEMM scenario: WS weight hold refresh mismatch");
        if (dut.station[macro]) refreshes[macro]++;
      end
      issues++;
      total_issues++;
    end
    if ((|dut.psum_depth_open) || (|dut.psum_write)) $fatal(1, "GEMM scenario: OS1 must bypass Psum history");
  end
  #1;
  if (!reset && monitoring) begin
    if ((out_valid_o & ~active_mask) != 0 || (requant_valid_o & ~active_mask) != 0)
      $fatal(1, "GEMM scenario: valid on inactive group or masked OC");
    if (requant_valid_o !== previous_valid) $fatal(1, "GEMM scenario: quant valid must follow raw by one cycle");
    for (int lane = 0; lane < 32; lane++)
    if (!requant_valid_o[lane] && requant_data_o[8*lane+:8] !== previous_quant[8*lane+:8])
      $fatal(1, "GEMM scenario: inactive output register changed");
    for (int c = 0; c < 4; c++) begin
      n = n_map[active_tile][c];
      if (out_valid_o[lane_base+c]) begin
        row   = raw_next[c];
        index = row * n_count + n;
        if (n < 0 || row >= m_count || cycle != first_accept + row * (phases + 1) + first_raw ||
          psum_data_o[32 * (lane_base + c) +: 32] !== raw_golden[index])
          $fatal(1, "GEMM scenario: raw matrix/timing mismatch row=%0d n=%0d OC=%0d", row, n, c);
        observed_raw[index] = psum_data_o[32*(lane_base+c)+:32];
        raw_next[c]++;
        raw_checks++;
        $fdisplay(trace_fd, "%0d,raw,%0d,%0d,%0d,%0d,%0d", cycle, active_tile, row, n, lane_base + c,
                  $signed(observed_raw[index]));
      end
      if (requant_valid_o[lane_base+c]) begin
        row   = quant_next[c];
        index = row * n_count + n;
        if (n < 0 || row >= m_count || cycle != first_accept + row * (phases + 1) + first_raw + 1 ||
          requant_data_o[8 * (lane_base + c) +: 8] !== quant_golden[index])
          $fatal(1, "GEMM scenario: INT8 matrix/OC-parameter/timing mismatch row=%0d n=%0d OC=%0d", row, n, c);
        observed_quant[index] = requant_data_o[8*(lane_base+c)+:8];
        quant_next[c]++;
        quant_checks++;
        $fdisplay(trace_fd, "%0d,quant,%0d,%0d,%0d,%0d,%0d", cycle, active_tile, row, n, lane_base + c,
                  $signed(observed_quant[index]));
      end
    end
  end
end
