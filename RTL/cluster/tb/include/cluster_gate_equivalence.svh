// Same-edge A/B comparison: both Clusters consume exactly the same pins.
// The reference bypasses every Cluster/Macro ICG while retaining register CEs.
// Invalid-lane payload/holding state is compared too, not only final results.
if (CHECK_GATE_EQUIVALENCE) begin : g_gate_equivalence
  wire reference_ready, reference_sram_valid;
  wire [1023:0] reference_sram;
  wire [1023:0] reference_raw;
  wire [  31:0] reference_valid;
  int checked_cycles = 0, raw_events = 0;
  cluster_top #(
    .OUTPUT_PSUM_DEPTH(OUTPUT_PSUM_DEPTH),
    .WGT_RADDR_BUFFER_DEPTH(WGT_RADDR_BUFFER_DEPTH),
    .MAX_CONTEXTS(MAX_CONTEXTS),
    .OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH),
    .USE_CLOCK_GATING(0)
  ) dut_ungated (
    .cmd_ready_o(reference_ready),
    .sram_rd_data(reference_sram),
    .sram_rd_valid(reference_sram_valid),
    .raw_psum(reference_raw),
    .psum_valid(reference_valid),
    .*
  );
  for (genvar m = 0; m < 8; m++) begin : g_act_compare
    always @(posedge clock) begin
      #0.003;
      if (dut.g_macro[m].u_macro.activation_in !== dut_ungated.g_macro[m].u_macro.activation_in)
        $fatal(1, "CLUSTER_GATE_EQUIVALENCE: ACT bank capture/hold mismatch macro=%0d", m);
    end
  end
  always @(posedge clock) begin
    #0.003;
    if (reference_ready !== cmd_ready_o || reference_sram !== sram_rd_data || reference_sram_valid !== sram_rd_valid ||
      reference_raw !== raw_psum || reference_valid !== psum_valid)
      $fatal(1, "CLUSTER_GATE_EQUIVALENCE: external data/valid/ready mismatch");
    if (dut_ungated.raw_data !== dut.raw_data || dut_ungated.raw_valid !== dut.raw_valid ||
      dut_ungated.act_buffer !== dut.act_buffer || dut_ungated.issue !== dut.issue ||
      dut_ungated.phase != dut.phase || dut_ungated.context_idx != dut.context_idx ||
      dut_ungated.tile != dut.tile || dut_ungated.completion_path_done !== dut.completion_path_done ||
      dut_ungated.batch_active !== dut.batch_active || dut_ungated.macro_data !== dut.macro_data ||
      dut_ungated.macro_valid !== dut.macro_valid)
      $fatal(1, "CLUSTER_GATE_EQUIVALENCE: raw/Macro/schedule mismatch");
    for (int l = 0; l < 32; l++) begin
      if (dut_ungated.raw_context[l] != dut.raw_context[l] || dut_ungated.tmp_result[l] !== dut.tmp_result[l])
        $fatal(1, "CLUSTER_GATE_EQUIVALENCE: Context/tmp mismatch lane=%0d", l);
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++)
      if (dut_ungated.psum[d][l] !== dut.psum[d][l])
        $fatal(1, "CLUSTER_GATE_EQUIVALENCE: Psum mismatch depth=%0d lane=%0d", d, l);
    end
    for (int n = 1; n < 7; n++)
    for (int c = 0; c < 4; c++)
    if (dut_ungated.u_reduce.forward_q[n][c] !== dut.u_reduce.forward_q[n][c])
      $fatal(1, "CLUSTER_GATE_EQUIVALENCE: reduce mismatch node=%0d OC=%0d", n, c);
    if (!reset) begin
      checked_cycles++;
      raw_events += $countones(dut.raw_valid);
    end
  end
  final begin
    if (checked_cycles == 0) $error("CLUSTER_GATE_EQUIVALENCE: no compared cycles");
    $display("PASS cluster_gate_equivalence cycles=%0d raw_events=%0d", checked_cycles, raw_events);
  end
end
