int compatible_pairs = 0, retiring_high_contexts = 0;
// Independent streams offer the next command before the old final operand,
// including A4 AS where the final address can issue on its acceptance edge.
task automatic compatible_pair(cluster_ctrl_t old_cfg, cluster_ctrl_t next_cfg);
  int j;
  j = offered_job+1;
  if (!compatible(old_cfg,next_cfg)) $fatal(1,"PIPELINE: test pair not compatible");
  configs[j] = old_cfg;
  configs[j+1] = next_cfg;
  fork
    begin
      offered_job = j;
      channel_cmd(old_cfg);
      offered_job = j+1;
      channel_cmd(next_cfg);
    end
    begin
      for (int job = j; job <= j+1; job++)
        for (int kt = 0; kt < int'(configs[job].cim_os_cnt); kt++)
        for (int cx = 0; cx < int'(configs[job].cim_as_cnt); cx++)
          channel_weight(8'(address(job,kt,cx)));
    end
    begin
      for (int job = j; job <= j+1; job++)
        for (int kt = 0; kt < int'(configs[job].cim_os_cnt); kt++)
        for (int cx = 0; cx < int'(configs[job].cim_ws_cnt); cx++)
        for (int ph = 0; ph < ab(int'(configs[job].cim_precision))/4; ph++)
          channel_act(make_plane(job,kt,cx,ph));
    end
  join
  while (first_issue[j+1] < 0) @(negedge clock);
  if (cmd_cycle[j+1] != last_issue[j] || first_issue[j+1] != last_issue[j]+1)
    $fatal(1,"PIPELINE: compatible pair bubble old=%0d next=%0d cmd=%0d first=%0d",
           last_issue[j],j+1,cmd_cycle[j+1],first_issue[j+1]);
  compatible_pairs++;
endtask

// Check physical per-Context clocks as well as the independent output oracle.
always @(posedge clock) begin
  logic [31:0] wanted_clock[16];
  if (reset_n && ($test$plusargs("PIPELINE_CONFIG_TEST") || $test$plusargs("MASK_PIPELINE_TEST") || $test$plusargs("PATH_CLASS_TEST"))) begin
    for (int d = 0; d < 16; d++)
    for (int l = 0; l < 32; l++) begin
      wanted_clock[d][l] = dut.tmp_valid[l] && dut.tmp_tag[l].ctx == d && dut.psum_write[l];
      if (dut.psum_cg_en[d][l] !== wanted_clock[d][l])
        $fatal(1,"PIPELINE: missing/spurious Context clock request");
      if (dut.psum_cg_en[d][l]) begin
        if (!dut.tmp_valid[l] || dut.tmp_tag[l].ctx != d || !dut.psum_write[l])
          $fatal(1,"PIPELINE: write request/tag mismatch Context=%0d lane=%0d",d,l);
        if (d >= dut.contexts) retiring_high_contexts++;
      end
    end
    #0.002;
    for (int d = 0; d < 16; d++)
      if (dut.psum_clock[d] !== wanted_clock[d])
        $fatal(1,"PIPELINE: physical Context clocks disagree with retiring transaction");
    for (int s = 0; s < 5; s++)
      if (dut.pipe_meta[s].valid &&
          (dut.pipe_meta[s].cfg.split_mask !== dut.pipe_meta[s].check_cmd.cim_reduce_split_mask ||
           dut.pipe_meta[s].cfg.macro_en_mask !== dut.pipe_meta[s].check_cmd.cim_macro_en_mask ||
           dut.pipe_meta[s].cfg.macro_oc_mask !== dut.pipe_meta[s].check_cmd.cim_macro_oc_mask ||
           int'(dut.pipe_meta[s].cfg.last_phase) != ab(int'(dut.pipe_meta[s].check_cmd.cim_precision))/4-1 ||
           int'(dut.pipe_meta[s].cfg.accum_mode) != (dut.pipe_meta[s].check_cmd.cim_as_cnt > 1 ? 2 :
             dut.pipe_meta[s].check_cmd.cim_os_cnt > 1 ? 1 : 0)))
        $fatal(1,"PIPELINE: configuration provenance mismatch stage=%0d",s);
  end
end
task automatic run_pipeline_cases();
  cluster_ctrl_t a,b;
  if ($bits(pipeline_cfg_t) != 51) $fatal(1,"PIPELINE: key must be 51 bits");
  // Isolate each excluded field before the combined transition sweep.
  for (int field = 0; field < 6; field++) begin
    a = config_for(1,0,field == 5 ? 2 : 0,field == 3 ? 2 : 1,1);
    a.cim_macro_en_mask = 8'h03;
    a.cim_act_slot_sel = 24'h000008;
    if (field == 4) a.cim_ws_cnt=64;
    if (field == 5) a.cim_as_cnt=8;
    b=a;
    case (field)
      0: b.cim_signed_en=0;
      1: b.cim_act_slot_sel=24'h000001;
      2: b.cim_precision=3;
      3: b.cim_os_cnt=3;
      4: b.cim_ws_cnt=1;
      5: b.cim_as_cnt=2;
    endcase
    compatible_pair(a,b);
  end
  for (int src = 0; src < 7; src++)
  for (int dst = 0; dst < 7; dst++)
  if (ab(src) == ab(dst))
  for (int mode = 0; mode < 3; mode++)
  for (int split = 0; split < 4; split++) begin
    a = config_for(src,split,mode,mode == 0 ? 1 : 2,1);
    a.cim_macro_en_mask = 8'h03;
    a.cim_act_slot_sel = 24'h000008; // Macro0 slot0, Macro1 slot1.
    a.cim_ws_cnt = mode == 2 ? 1 : 8;
    a.cim_as_cnt = mode == 2 ? 8 : 1;
    b = a;
    b.cim_precision = 3'(dst);
    b.cim_signed_en = 0;
    b.cim_act_slot_sel = 24'h000001; // Reverse the two full windows.
    b.cim_ws_cnt = 1;
    b.cim_as_cnt = mode == 2 ? 2 : 1;
    b.cim_os_cnt = mode == 0 ? 1 : mode == 1 ? 3 : 1;
    compatible_pair(a,b);
    compatible_pair(b,a); // Also grow Context counts and reverse signedness.
  end
  // Fields in the key retain the conservative resource-conflict drain guard.
  a = config_for(1,0,0,1,0);
  a.cim_macro_en_mask = 8'h03;
  a.cim_act_slot_sel = 24'h000008;
  send_job(a,0,0);
  b=a; b.cim_precision=4; send_job(b,0,0); // A8 -> A16.
  a=b; a.cim_os_cnt=2; send_job(a,0,0);   // TMP -> OS Psum.
  b=a; b.cim_as_cnt=2; send_job(b,0,0);   // OS Psum -> AS Psum.
  a=b; a.cim_reduce_split_mask=7'h01; send_job(a,0,0);
  b=a; b.cim_macro_en_mask=1; send_job(b,0,0);
  a=b; a.cim_macro_oc_mask[3:0]=3; send_job(a,0,0);
endtask
