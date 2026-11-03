initial begin : gemm_regression
  int fd;
  load_gemm_os1_ws32_w8a16_vectors();
  $display("[CASE_START] time=%0.3f ns suite=raw_gemm description=signed32-matrix-dot-product", $realtime);
  trace_fd = $fopen({data_dir, "/gemm_observed_events.csv"}, "w");
  if (!trace_fd) $fatal(1, "GEMM: cannot open output event trace");
  $fdisplay(trace_fd, "cycle,relative_cycle,event,n_tile,m,cluster,lane,n,value");
  sram_wrdata[0] = '0;
  for (int tile = 0; tile < N_TILES; tile++) begin
    issues[tile] = 0;
    first_accept[tile] = -1;
    accepted[tile] = 0;
    for (int lane = 0; lane < 4; lane++) begin
      raw_rows[tile][lane]   = 0;
      raw_rows[tile][lane] = 0;
    end
    for (int macro = 0; macro < 8; macro++) refreshes[tile][macro] = 0;
  end
  repeat (4) @(negedge clock);
  reset = 0;
  load_gemm_weights();
  for (int tile = 0; tile < N_TILES; tile++) begin
    active_tile = tile;
    monitoring  = 1;
    $display(
      string'({"[CASE_START] time=%0.3f ns suite=cluster_gemm_N_tile ",
               "description=WS32-replay-X tile=%0d n_first=%0d n_last=%0d address=0x%02h"}),
      $realtime, tile, 4 * tile, 4 * tile + 3, WEIGHT_ADDR + 8'(tile));
    send_gemm_rows(tile);
    for (int t = 0; t < 100; t++) begin
      @(negedge clock);
      if (raw_checks == (tile + 1) * M * 4 && !(|batch_active)) break;
      if (t == 99) $fatal(1, "GEMM: output timeout");
    end
    repeat (2) @(negedge clock);
    if (accepted[tile] != 32 || issues[tile] != 128 || out_valid_o[0] != 0 || out_valid_o[0] != 0)
      $fatal(1, "GEMM: per-tile Command/issue/drain mismatch");
    for (int lane = 0; lane < 4; lane++)
    if (raw_rows[tile][lane] != 32)
      $fatal(1, "GEMM: per-tile lane coverage or WS refresh count mismatch");
    for (int macro = 0; macro < 8; macro++)
    if (refreshes[tile][macro] != 1) $fatal(1, "GEMM: per-Macro refresh count mismatch");
  end
  repeat (6) @(negedge clock);
  if (accepted[0] + accepted[1] + accepted[2] + accepted[3] != 128 || raw_checks != 512)
    $fatal(1, "GEMM: missing/duplicate Command or output");
  fd = $fopen({data_dir, "/gemm_observed_matrix.csv"}, "w");
  if (!fd) $fatal(1, "GEMM: cannot open output matrix");
  $fdisplay(fd, "m,n,raw");
  for (int m = 0; m < M; m++)
  for (int n = 0; n < N; n++)
  $fdisplay(fd, "%0d,%0d,%0d", m, n, $signed(observed_raw[m*N+n]));
  $fclose(fd);
  $fclose(trace_fd);
  $display("PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16 raw_checks=%0d", raw_checks);
  $finish;
end
initial begin
  repeat (1000) @(posedge clock);
  $fatal(1, "GEMM: watchdog timeout");
end
