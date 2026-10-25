initial begin : scenario_regression
  int fd;
  load_scenario_vectors();
  $display(
    string'({"[CASE_START] time=%0.3f ns suite=gemm_%s description=%s ",
             "M=%0d K=%0d N=%0d W%0dA%0d first_macro=%0d lane_base=%0d per_channel=%0d"}),
    $realtime, SCENARIO, description, m_count, k_count, n_count, wb, ab, first_macro, lane_base, per_channel);
  trace_fd = $fopen({data_dir, "/gemm_observed_events.csv"}, "w");
  if (!trace_fd) $fatal(1, "GEMM scenario: cannot create event trace");
  $fdisplay(trace_fd, "cycle,event,tile,m,n,lane,value");
  repeat (4) @(negedge clock);
  reset = 0;
  load_scenario_weights();
  for (int tile = 0; tile < n_tiles; tile++) begin
    $display(
      "[CASE_START] time=%0.3f ns suite=gemm_%s_N_tile description=high-group-OC-map-and-weight-reuse tile=%0d",
      $realtime, SCENARIO, tile);
    active_tile = tile;
    first_accept = -1;
    commands = 0;
    issues = 0;
    for (int c = 0; c < 4; c++) begin
      raw_next[c]   = 0;
      quant_next[c] = 0;
    end
    for (int macro = 0; macro < 8; macro++) refreshes[macro] = 0;
    monitoring = 1;
    send_scenario_tile(tile);
    for (int t = 0; t < 30; t++) begin
      @(negedge clock);
      if (!dut.batch_active && out_valid_o == 0 && requant_valid_o == 0) break;
      if (t == 29) $fatal(1, "GEMM scenario: output drain timeout");
    end
    repeat (2) @(negedge clock);
    if (commands != m_count || issues != m_count * phases) $fatal(1, "GEMM scenario: Command/issue coverage mismatch");
    for (int c = 0; c < 4; c++)
    if (raw_next[c] != (n_map[tile][c] >= 0 ? m_count : 0) || quant_next[c] != raw_next[c])
      $fatal(1, "GEMM scenario: missing or duplicate OC result");
    for (int macro = 0; macro < 8; macro++)
    if (refreshes[macro] !=
        ((macro >= first_macro && macro < first_macro + macro_count)
           ? ((active_tile == 0 && n_tiles == 1) ? 0 : 1) : 0))
      $fatal(1, "GEMM scenario: enabled/disabled Macro refresh count mismatch");
    monitoring = 0;
  end
  if (raw_checks != m_count * n_count || quant_checks != m_count * n_count)
    $fatal(1, "GEMM scenario: incomplete output matrix");
  fd = $fopen({data_dir, "/gemm_observed_matrix.csv"}, "w");
  if (!fd) $fatal(1, "GEMM scenario: cannot create observed matrix");
  $fdisplay(fd, "m,n,raw,quant");
  for (int m = 0; m < m_count; m++)
  for (int n = 0; n < n_count; n++)
  $fdisplay(fd, "%0d,%0d,%0d,%0d", m, n, $signed(observed_raw[m*n_count+n]), $signed(observed_quant[m*n_count+n]));
  $fclose(fd);
  $fclose(trace_fd);
  $display(
    "PASS gemm_%s description=%s raw_checks=%0d quant_checks=%0d commands=%0d issues=%0d lane_base=%0d latency=1",
    SCENARIO, description, raw_checks, quant_checks, total_commands, total_issues, lane_base);
  $finish;
end
initial begin
  repeat (2000) @(posedge clock);
  $fatal(1, "GEMM scenario: watchdog timeout");
end
