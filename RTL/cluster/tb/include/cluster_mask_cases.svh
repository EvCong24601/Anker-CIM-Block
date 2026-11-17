int mask_empty_handoffs = 0, mask_hidden_deep = 0, mask_pending_psum = 0;
int mask_enable_changes = 0, mask_oc_changes = 0;

// This uses the TB's independent tree walk rather than the RTL lane decoder.
function automatic logic [31:0] channel_lanes(cluster_ctrl_t cfg);
  logic [31:0] mask;
  mask = 0;
  for (int m = 0; m < 8; m++)
  for (int c = 0; c < 4; c++)
    if (cfg.cim_macro_en_mask[m] && contributes(cfg,m,c))
      mask[4*group_of(cfg.cim_reduce_split_mask,m)+c] = 1;
  return mask;
endfunction

always @(posedge clock) begin : mask_coverage
  logic [31:0] live_lanes;
  live_lanes = channel_lanes(dut.batch_command);
  if (reset_n && $test$plusargs("MASK_PIPELINE_TEST")) begin
    if (cmd_valid_i && cmd_ready_o && offered_job > 0 && compatible(cmd_i,configs[offered_job-1])) begin
      if (cmd_i.cim_macro_en_mask != configs[offered_job-1].cim_macro_en_mask) mask_enable_changes++;
      if (cmd_i.cim_macro_oc_mask != configs[offered_job-1].cim_macro_oc_mask) mask_oc_changes++;
      if (channel_lanes(cmd_i) == 0) mask_empty_handoffs++;
    end
    for (int s = 3; s < 5; s++)
      if (dut.pipe_meta[s].valid) begin
        // Inspect the old command's own endpoint, not its successor's mask.
        for (int m = 0; m < 8; m++)
        for (int c = 0; c < 4; c++)
          if (dut.pipe_meta[s].check_cmd.cim_macro_en_mask[m] &&
              contributes(dut.pipe_meta[s].check_cmd,m,c) &&
              span(dut.pipe_meta[s].check_cmd.cim_reduce_split_mask,m) >= (s == 3 ? 4 : 8) &&
              !live_lanes[4*group_of(dut.pipe_meta[s].check_cmd.cim_reduce_split_mask,m)+c])
            mask_hidden_deep++;
      end
    if (channel_lanes(dut.batch_command) == 0 && dut.pending_psum) mask_pending_psum++;
  end
end

task automatic run_mask_cases();
  cluster_ctrl_t a,b,c,d,next_cfg;
  // All-zero EN and all-zero OC are each exercised without changing the
  // other mask, including restoration while older results still retire.
  for (int mode = 0; mode < 3; mode++) begin
    a=config_for(1,4,mode,mode == 0 ? 1 : 2,1);
    b=a; b.cim_macro_en_mask=0;
    compatible_pair(a,b);
    compatible_pair(b,a);
    c=a; c.cim_macro_oc_mask=0;
    compatible_pair(a,c);
    compatible_pair(c,a);
  end
  // Isolated EN and OC changes in both directions, combined changes through
  // an empty effective mask, then restoration. Counts shrink on the empty job.
  for (int p = 0; p < 7; p++)
  for (int split = 0; split < 5; split++)
  for (int mode = 0; mode < 3; mode++) begin
    a = config_for(p,split,mode,mode == 0 ? 1 : 2,1'(p%2));
    if (mode == 2) a.cim_as_cnt = 8;
    b=a;
    b.cim_macro_en_mask &= split%2 ? 8'haa : 8'h55;
    compatible_pair(a,b);
    compatible_pair(b,a);
    c=a;
    for (int m = 0; m < 8; m++) c.cim_macro_oc_mask[4*m+:4] = 4'b0001 << ((m+p+mode)%4);
    compatible_pair(a,c);
    d=c;
    d.cim_macro_en_mask=0;
    d.cim_macro_oc_mask=0;
    d.cim_ws_cnt=1;
    d.cim_as_cnt=mode == 2 ? 2 : 1;
    compatible_pair(c,d);
    compatible_pair(d,a);
  end

  // A deep live request -> one empty compatible request -> incompatible
  // route. The third command is offered while the FIRST job is still in flight.
  for (int mode = 0; mode < 3; mode++) begin
    a=config_for(0,3,mode,mode == 1 ? 2 : 1,1);
    a.cim_ws_cnt=1;
    a.cim_as_cnt=mode == 2 ? 2 : 1;
    b=a; b.cim_macro_oc_mask=0;
    compatible_pair(a,b);
    next_cfg=config_for(0,0,mode,mode == 1 ? 2 : 1,1);
    next_cfg.cim_ws_cnt=1;
    next_cfg.cim_as_cnt=mode == 2 ? 2 : 1;
    send_job(next_cfg,0,0);

    // Mixed tree: disable the old quad endpoint and enable only a short leaf.
    a=config_for(0,4,mode,mode == 1 ? 2 : 1,1);
    a.cim_ws_cnt=1;
    a.cim_as_cnt=mode == 2 ? 2 : 1;
    a.cim_macro_en_mask=8'h10;
    b=a; b.cim_macro_en_mask=1;
    compatible_pair(a,b);
    send_job(next_cfg,0,0);
  end

  // Alternate masks every issue with no opportunity to drain between jobs.
  a=config_for(0,4,0,1,1);
  a.cim_macro_en_mask=8'h10;
  b=a; b.cim_macro_en_mask=1; b.cim_macro_oc_mask=32'h55555555;
  repeat (12) begin
    compatible_pair(a,b);
    compatible_pair(b,a);
  end
  if (!mask_enable_changes || !mask_oc_changes) $fatal(1,"MASK: masks never changed");
endtask
