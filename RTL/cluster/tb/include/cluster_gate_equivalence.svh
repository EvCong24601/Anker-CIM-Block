// Same-edge A/B comparison: both Clusters consume exactly the same pins.
// The reference bypasses every Cluster/Macro ICG while retaining register CEs.
// Invalid-lane payload/holding state is compared too, not only final results.
if (CHECK_GATE_EQUIVALENCE) begin : g_gate_equivalence
  wire reference_ready, reference_sram_valid;
  wire [1023:0] reference_sram;
  wire [255:0] reference_quant;
  wire [31:0] reference_quant_valid;
  int checked_cycles=0, raw_events=0, quant_events=0;
  cluster_top #(
    .WGT_RADDR_BUFFER_DEPTH(WGT_RADDR_BUFFER_DEPTH), .MAX_CONTEXTS(MAX_CONTEXTS),
    .OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH), .REQUANT_CONTEXT_DEPTH(REQUANT_CONTEXT_DEPTH),
    .ENABLE_REQUANT(ENABLE_REQUANT), .USE_CLOCK_GATING(0)
  ) dut_ungated (
    .cmd_ready_o(reference_ready), .sram_rd_data(reference_sram), .sram_rd_valid(reference_sram_valid),
    .requant_data_o(reference_quant), .requant_valid_o(reference_quant_valid), .*
  );
  always @(posedge clock) begin
    #0.003;
    if (reference_ready !== cmd_ready_o || reference_sram !== sram_rd_data || reference_sram_valid !== sram_rd_valid ||
        reference_quant !== requant_data_o || reference_quant_valid !== requant_valid_o)
      $fatal(1,"CLUSTER_GATE_EQUIVALENCE: external data/valid/ready mismatch");
    if (dut_ungated.raw_data !== dut.raw_data || dut_ungated.raw_valid !== dut.raw_valid ||
        dut_ungated.act_buffer !== dut.act_buffer || dut_ungated.issue !== dut.issue ||
        dut_ungated.phase != dut.phase || dut_ungated.context_idx != dut.context_idx ||
        dut_ungated.tile != dut.tile || dut_ungated.macro_data !== dut.macro_data ||
        dut_ungated.macro_valid !== dut.macro_valid)
      $fatal(1,"CLUSTER_GATE_EQUIVALENCE: raw/Macro/schedule mismatch");
    for (int l=0;l<32;l++) begin
      if (dut_ungated.raw_context[l] != dut.raw_context[l] ||
          dut_ungated.tmp_result[l] !== dut.tmp_result[l])
        $fatal(1,"CLUSTER_GATE_EQUIVALENCE: Context/tmp mismatch lane=%0d",l);
      for (int d=0;d<OUTPUT_BUFFER_DEPTH;d++)
        if (dut_ungated.psum[d][l] !== dut.psum[d][l])
          $fatal(1,"CLUSTER_GATE_EQUIVALENCE: Psum mismatch depth=%0d lane=%0d",d,l);
    end
    for (int n=1;n<7;n++)
      for (int c=0;c<4;c++)
        if (dut_ungated.u_reduce.forward_q[n][c] !== dut.u_reduce.forward_q[n][c])
          $fatal(1,"CLUSTER_GATE_EQUIVALENCE: reduce mismatch node=%0d OC=%0d",n,c);
    for (int d=0;d<REQUANT_CONTEXT_DEPTH;d++)
      if (dut_ungated.requant_context_zp[d] !== dut.requant_context_zp[d] ||
          dut_ungated.requant_context_multiplier[d] !== dut.requant_context_multiplier[d] ||
          dut_ungated.requant_context_shift[d] !== dut.requant_context_shift[d])
        $fatal(1,"CLUSTER_GATE_EQUIVALENCE: parameter slot mismatch depth=%0d",d);
    if (!reset) begin
      checked_cycles++;
      raw_events+=$countones(dut.raw_valid);
      quant_events+=$countones(requant_valid_o);
    end
  end
  final begin
    if (checked_cycles==0) $error("CLUSTER_GATE_EQUIVALENCE: no compared cycles");
    $display("PASS cluster_gate_equivalence cycles=%0d raw_events=%0d quant_events=%0d",checked_cycles,raw_events,quant_events);
  end
end
