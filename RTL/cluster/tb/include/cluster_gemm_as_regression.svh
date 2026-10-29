initial begin : as_gemm_regression
  int fd;
  load_as_gemm_os1_ws32_w8a16_vectors();
  $display(
    string'({"[CASE_START] time=%0.3f ns suite=gemm_as_weight_quantization ",
             "description=per-output-channel-or-tensor-W8-scale per_channel=%0d"}),
    $realtime, $test$plusargs("PER_CHANNEL_SCALE"));
  $display(
    string'({"[CASE_START] time=%0.3f ns suite=gemm_os2_as4 ",
             "description=single-Cluster-eight-Macro-reduction-asymmetric-A16-symmetric-W8 ",
             "M=%0d K=%0d N=%0d os=%0d as=%0d ws=1 multiplier=%0d shift=%0d act_zp=%0d output_zp=%0d"}),
    $realtime, M, K, N, OS, AS, multiplier, shift, act_zp, output_zp);
  trace_fd = $fopen({data_dir, "/gemm_observed_events.csv"}, "w");
  if (!trace_fd) $fatal(1, "AS GEMM: cannot open event trace");
  $fdisplay(trace_fd, "cycle,relative_cycle,event,m,k_tile,as_context,lane,n,value");
  for (int macro = 0; macro < 8; macro++) refreshes[macro] = 0;
  repeat (4) @(negedge clock);
  reset = 0;
  load_as_weights();
  for (int m = 0; m < M; m++) begin
    $display("[CASE_START] time=%0.3f ns suite=gemm_os2_as4_row description=two-K-Tiles-four-N-Contexts m=%0d",
             $realtime, m);
    active_m = m;
    first_accept = -1;
    row_commands = 0;
    row_issues = 0;
    row_raw = 0;
    row_quant = 0;
    for (int l = 0; l < 4; l++) begin
      raw_next[l]   = 0;
      quant_next[l] = 0;
    end
    monitoring = 1;
    send_as_row(m);
    for (int t = 0; t < 30; t++) begin
      @(negedge clock);
      if (row_quant == N && !dut.batch_active) break;
      if (t == 29) $fatal(1, "AS GEMM: row output timeout");
    end
    repeat (2) @(negedge clock);
    if (row_commands != OS * AS || row_issues != OS * 4 * AS || row_raw != N || row_quant != N ||
        out_valid_o != 0 || requant_valid_o != 0)
      $fatal(1, "AS GEMM: row counts or drain mismatch");
    for (int l = 0; l < 4; l++)
    if (raw_next[l] != AS || quant_next[l] != AS) $fatal(1, "AS GEMM: missing Context output");
    monitoring = 0;
  end
  if (total_commands != M * OS * AS || total_issues != M * OS * 4 * AS || raw_checks != M * N || quant_checks != M * N || psum_checks != M * OS * 4 * AS * 4)
    $fatal(1, "AS GEMM: incomplete matrix/history coverage");
  for (int macro = 0; macro < 8; macro++)
  if (refreshes[macro] != M * OS * 4 * AS) $fatal(1, "AS GEMM: incorrect weight refresh count");
  fd = $fopen({data_dir, "/gemm_observed_matrix.csv"}, "w");
  if (!fd) $fatal(1, "AS GEMM: cannot write observed matrix");
  $fdisplay(fd, "m,n,raw,quant");
  for (int m = 0; m < M; m++)
  for (int n = 0; n < N; n++)
  $fdisplay(fd, "%0d,%0d,%0d,%0d", m, n, $signed(observed_raw[m*N+n]), $signed(observed_quant[m*N+n]));
  $fclose(fd);
  $fclose(trace_fd);
  if (CHECK_SWITCH) report_as_gate_coverage();
  $display(
    string'({"PASS gemm_os%0d_as%0d_w8a16 M=%0d K=%0d N=%0d clusters=1 commands=%0d issues=%0d ",
             "raw_checks=%0d quant_checks=%0d psum_checks=%0d zp_bits=%0d zp_per_cycle=4 ",
             "first_raw_per_row=%0d last_raw_per_row=%0d first_quant_per_row=%0d last_quant_per_row=%0d"}),
    OS, AS, M, K, N, total_commands, total_issues, raw_checks, quant_checks, psum_checks, 128 * AS, FIRST_RAW, FIRST_RAW + AS - 1, FIRST_RAW + 1, FIRST_RAW + AS);
  $finish;
end
initial begin
  repeat (3000) @(posedge clock);
  $fatal(1, "AS GEMM: watchdog timeout");
end
