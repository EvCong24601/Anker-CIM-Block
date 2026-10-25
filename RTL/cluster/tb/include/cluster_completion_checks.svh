// Simulation-only integrity state. The RTL uses three path-drained bits;
// this independent scoreboard retains lane-level reservation and completion
// checks without adding product DFFs or controlling batch completion.
logic [31:0] completion_reserved[0:MAX_CONTEXTS - 1];
logic [31:0] completion_seen[0:MAX_CONTEXTS - 1];
logic [31:0] completion_expected_mask;
int completion_expected_contexts, completion_reserved_count;
int completion_batch_checks = 0;
bit completion_was_active;
always @(posedge clock or posedge reset) begin : check_batch_completion
  if (reset) begin
    for (int c = 0; c < MAX_CONTEXTS; c++) begin
      completion_reserved[c] = '0;
      completion_seen[c] = '0;
    end
    completion_expected_mask = '0;
    completion_expected_contexts = 0;
    completion_reserved_count = 0;
    completion_was_active = 0;
  end else begin
    completion_was_active = dut.batch_active;
    if (dut.cmd_accept && !dut.batch_active) begin
      for (int c = 0; c < MAX_CONTEXTS; c++) begin
        completion_reserved[c] = '0;
        completion_seen[c] = '0;
      end
      completion_expected_contexts = int'(cmd_i.cim_ws_cnt > 1 ? cmd_i.cim_ws_cnt : cmd_i.cim_as_cnt);
      completion_reserved_count = 0;
      completion_expected_mask = dut.mask_for_batch(cmd_i);
    end
    if (dut.issue && dut.final_issue) begin
      completion_reserved[dut.context_idx] = dut.issue_mask;
      completion_reserved_count++;
    end
    // Observe the completed NBA state before the arithmetic scoreboard's #1.
    #0.006;
    if (!reset) begin
      for (int l = 0; l < 32; l++)
      if (dut.raw_valid[l]) begin
        if (dut.raw_context[l] >= completion_expected_contexts ||
            !completion_reserved[dut.raw_context[l]][l] || completion_seen[dut.raw_context[l]][l])
          $fatal(1, "CLUSTER_COMPLETION: unreserved or duplicate raw Context/lane");
        completion_seen[dut.raw_context[l]][l] = 1;
      end
      if (completion_was_active && !dut.batch_active) begin
        if (completion_reserved_count != completion_expected_contexts)
          $fatal(1, "CLUSTER_COMPLETION: batch closed before all final issues");
        for (int c = 0; c < completion_expected_contexts; c++)
        if (completion_reserved[c] !== completion_expected_mask || completion_seen[c] !== completion_expected_mask)
          $fatal(1, "CLUSTER_COMPLETION: batch closed before all Context/lane results");
        completion_batch_checks++;
      end
    end
  end
end
