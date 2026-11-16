// Simulation-only per-lane queues support overlapping same-configuration jobs.
int completion_context[0:31][0:4095];
int completion_head[0:31], completion_tail[0:31];
int completion_batch_checks = 0;
always @(posedge clock or negedge reset_n) begin : check_batch_completion
  bit was_active;
  if (!reset_n) begin
    for (int l = 0; l < 32; l++) begin
      completion_head[l] = 0;
      completion_tail[l] = 0;
    end
  end else begin
    was_active = dut.batch_active;
    if (dut.issue && dut.final_issue)
      for (int l = 0; l < 32; l++)
      if (dut.issue_mask[l]) begin
        if (completion_tail[l] - completion_head[l] >= 4096) $fatal(1, "Completion checker capacity exceeded");
        completion_context[l][completion_tail[l]%4096] = int'(dut.context_idx);
        completion_tail[l]++;
      end
    #0.006;
    if (reset_n) begin
      for (int l = 0; l < 32; l++)
      if (dut.raw_valid[l]) begin
        if(completion_head[l]==completion_tail[l] ||
         dut.raw_context[l]!=completion_context[l][completion_head[l]%4096])
          $fatal(1, "CLUSTER_COMPLETION: unreserved, reordered or duplicate raw Context/lane");
        completion_head[l]++;
      end
      if (was_active && !dut.batch_active) begin
        for (int l = 0; l < 32; l++)
        if (completion_head[l] != completion_tail[l])
          $fatal(1, "CLUSTER_COMPLETION: configuration released before lane completion");
        completion_batch_checks++;
      end
    end
  end
end
