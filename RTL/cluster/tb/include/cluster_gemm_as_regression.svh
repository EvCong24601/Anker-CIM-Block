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
             "M=32 K=512 N=16 os=2 as=4 ws=1 multiplier=%0d shift=%0d act_zp=%0d output_zp=%0d"}),
    $realtime, multiplier, shift, act_zp, output_zp);
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
      if (row_quant == 16 && !dut.batch_active) break;
      if (t == 29) $fatal(1, "AS GEMM: row output timeout");
    end
    repeat (2) @(negedge clock);
    if (row_commands != 8 || row_issues != 32 || row_raw != 16 || row_quant != 16 ||
        out_valid_o != 0 || requant_valid_o != 0)
      $fatal(1, "AS GEMM: row counts or drain mismatch");
    for (int l = 0; l < 4; l++)
    if (raw_next[l] != 4 || quant_next[l] != 4) $fatal(1, "AS GEMM: missing Context output");
    monitoring = 0;
  end
  if (total_commands != 256 || total_issues != 1024 || raw_checks != 512 || quant_checks != 512 || psum_checks != 4096)
    $fatal(1, "AS GEMM: incomplete matrix/history coverage");
  for (int macro = 0; macro < 8; macro++)
  if (refreshes[macro] != 1024) $fatal(1, "AS GEMM: incorrect weight refresh count");
  fd = $fopen({data_dir, "/gemm_observed_matrix.csv"}, "w");
  if (!fd) $fatal(1, "AS GEMM: cannot write observed matrix");
  $fdisplay(fd, "m,n,raw,quant");
  for (int m = 0; m < M; m++)
  for (int n = 0; n < N; n++)
  $fdisplay(fd, "%0d,%0d,%0d,%0d", m, n, $signed(observed_raw[m*N+n]), $signed(observed_quant[m*N+n]));
  $fclose(fd);
  $fclose(trace_fd);
  $display(
    string'({"PASS gemm_os2_as4_w8a16 M=32 K=512 N=16 clusters=1 commands=256 issues=1024 ",
             "raw_checks=%0d quant_checks=%0d psum_checks=%0d zp_bits=512 zp_per_cycle=4 ",
             "first_raw_per_row=35 last_raw_per_row=38 first_quant_per_row=36 last_quant_per_row=39"}),
    raw_checks, quant_checks, psum_checks);
  $finish;
end
initial begin
  repeat (3000) @(posedge clock);
  $fatal(1, "AS GEMM: watchdog timeout");
end
