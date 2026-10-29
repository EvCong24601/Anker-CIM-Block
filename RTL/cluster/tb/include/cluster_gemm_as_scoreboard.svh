`include "include/requant_tb_helpers.svh"
always @(posedge clock) begin : as_gemm_scoreboard
  logic [31:0] previous_raw_valid;
  logic [255:0] previous_quant;
  bit check_history[4];
  logic [31:0] wanted_history[4];
  int hc[4], tile, cx, ph, index, n;
  logic [7:0] corrected_quant;
  cycle++;
  previous_raw_valid = out_valid_o;
  previous_quant = requant_data_o;
  for (int l = 0; l < 4; l++) check_history[l] = 0;
  if (!reset && monitoring) begin
    if (cmd_valid_i && cmd_ready_o) begin
      if (first_accept < 0) first_accept = cycle;
      tile = row_commands / AS;
      cx   = row_commands % AS;
      if (cycle != first_accept + TILE_CYCLES * tile + cx || cmd_i.cim_weight_raddr !== BASE_ADDR + 8'(AS * tile + logical_context(active_m, cx)))
        $fatal(1, "AS GEMM: external Command schedule/address mismatch");
      $fdisplay(trace_fd, "%0d,%0d,command,%0d,%0d,%0d,-1,-1,0", cycle, cycle - first_accept, active_m, tile, cx);
      row_commands++;
      total_commands++;
    end
    if (dut.issue) begin
      tile = row_issues / (4 * AS);
      ph   = (row_issues % (4 * AS)) / AS;
      cx   = row_issues % AS;
      if (cycle != first_accept + TILE_CYCLES * tile + 1 + AS * ph + cx || dut.tile != tile || dut.phase != ph ||
          dut.context_idx != cx || dut.command.cim_weight_raddr !== BASE_ADDR + 8'(AS * tile + logical_context(active_m, cx)) ||
          dut.plane !== act_planes[(active_m * OS + tile) * 4 + ph])
        $fatal(1, "AS GEMM: internal issue order/data/address mismatch");
      if (dut.ren !== 8'hff || dut.station !== 8'hff)
        $fatal(1, "AS GEMM: each Context switch must refresh all eight weights");
      for (int macro = 0; macro < 8; macro++) refreshes[macro]++;
      row_issues++;
      total_issues++;
    end
    for (int l = 0; l < 4; l++)
    if (dut.tmp_valid[l]) begin
      tile = dut.tmp_tag[l].kt;
      ph   = dut.tmp_tag[l].ph;
      cx   = dut.tmp_tag[l].ctx;
      if (!dut.psum_write[l]) $fatal(1, "AS GEMM: missing AS partial-sum update");
      index = ((((active_m * OS + tile) * 4 + ph) * AS + logical_context(active_m, cx)) * 4 + l);
      wanted_history[l] = history_golden[index];
      check_history[l] = 1;
      hc[l] = cx;
    end
  end
  #1;
  if (!reset && monitoring) begin
    if (dut.batch_active && dut.psum_depth_open !== 16'((1 << AS) - 1))
      $fatal(1, "AS GEMM: incorrect Psum Context enable mask");
    for (int l = 0; l < 4; l++)
    if (check_history[l]) begin
      if (dut.psum[hc[l]][l] !== wanted_history[l])
        $fatal(1, "AS GEMM: per-phase Psum history mismatch m=%0d ctx=%0d lane=%0d", active_m, hc[l], l);
      psum_checks++;
    end
    if ((out_valid_o & 32'hfffffff0) != 0 || (requant_valid_o & 32'hfffffff0) != 0)
      $fatal(1, "AS GEMM: inactive output lane valid");
    if (requant_valid_o !== previous_raw_valid) $fatal(1, "AS GEMM: Requant valid must follow raw by one cycle");
    for (int l = 0; l < 32; l++)
    if (!requant_valid_o[l] && requant_data_o[8*l+:8] !== previous_quant[8*l+:8])
      $fatal(1, "AS GEMM: INT8 output register did not hold");
    for (int l = 0; l < 4; l++) begin
      if (out_valid_o[l]) begin
        cx = raw_next[l];
        n  = 4 * logical_context(active_m, cx) + l;
        if (cx >= AS || cycle != first_accept + FIRST_RAW + cx || psum_data_o[32*l+:32] !== raw_golden[active_m*N+n])
          $fatal(1, "AS GEMM: raw matrix/order/timing mismatch m=%0d ctx=%0d lane=%0d", active_m, cx, l);
        observed_raw[active_m*N+n] = psum_data_o[32*l+:32];
        $fdisplay(trace_fd, "%0d,%0d,raw,%0d,1,%0d,%0d,%0d,%0d", cycle, cycle - first_accept, active_m, cx, l, n,
                  $signed(observed_raw[active_m*N+n]));
        raw_next[l]++;
        row_raw++;
        raw_checks++;
      end
      if (requant_valid_o[l]) begin
        cx = quant_next[l];
        n  = 4 * logical_context(active_m, cx) + l;
        if (requant_data_o[8*l+:8] !== cim_golden[active_m*N+n])
          $fatal(1, "GEMM: CIM INT8 before TB correction mismatch");
        corrected_quant = $test$plusargs("PER_CHANNEL_SCALE") ? requant_data_o[8*l+:8] :
            tb_correct_tensor($signed(requant_data_o[8*l+:8]), $signed(zp[n]));
        if (cx >= AS || cycle != first_accept + FIRST_RAW + 1 + cx || corrected_quant !== quant_golden[active_m*N+n])
          $fatal(1, "AS GEMM: INT8 matrix/Context-zp/timing mismatch m=%0d ctx=%0d lane=%0d", active_m, cx, l);
        observed_quant[active_m*N+n] = corrected_quant;
        $fdisplay(trace_fd, "%0d,%0d,quant,%0d,1,%0d,%0d,%0d,%0d", cycle, cycle - first_accept, active_m, cx, l, n,
                  $signed(observed_quant[active_m*N+n]));
        quant_next[l]++;
        row_quant++;
        quant_checks++;
      end
    end
  end
end
