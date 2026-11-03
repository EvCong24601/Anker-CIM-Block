// Check physical lane positions, mask holes, exact timing and dense GEMM order.
always @(posedge clock) begin : edge_scoreboard
  int row, phase, n, index;
  cycle++;
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
        if (dut.station[macro] !== (issues == 0 && !(active_tile == 0 && n_tiles == 1)))
          $fatal(1, "GEMM scenario: WS weight hold refresh mismatch");
        if (dut.station[macro]) refreshes[macro]++;
      end
      issues++;
      total_issues++;
    end
    if ((|dut.psum_depth_open) || (|dut.psum_write)) $fatal(1, "GEMM scenario: OS1 must bypass Psum history");
  end
  #1;
  if (!reset && monitoring) begin
    if ((out_valid_o & ~active_mask) != 0)
      $fatal(1, "GEMM scenario: valid on inactive group or masked OC");
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

    end
  end
end
