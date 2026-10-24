// 唯一回归入口：选 suite、初始化/关闭 CSV、检查覆盖率；含 watchdog 与 FSDB。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

initial begin : regression
  string data_dir;
  int capacity_precision, capacity_sign, zero_count, capacity_count, capacity_os;
  string requant_negative;
  if ($bits(requant_cfg_t) != 298) $fatal(1, "TB: Requant config must be 298 bits");
  if ($value$plusargs("REQUANT_NEGATIVE=%s", requant_negative)) begin
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (2) @(negedge clock);
    $display("[CASE_START] time=%0.3f ns suite=requant_negative description=reject-invalid-config-%s", $realtime,
             requant_negative);
    cmd_i = '0;
    cmd_i.cim_os_cnt = 1;
    cmd_i.cim_ws_cnt = 1;
    cmd_i.cim_as_cnt = 1;
    cmd_i.cim_precision = 6;
    cmd_i.cim_macro_en_mask = 8'hff;
    case (requant_negative)
      "as17_capacity": cmd_i.cim_as_cnt = 17;
      "mode": requant_cfg_i.requant_mode = 1;
      "shift_low": requant_cfg_i.requant_shift = -32;
      "shift_high": requant_cfg_i.requant_shift = 32;
      "unknown": requant_cfg_i.requant_multiplier = 'x;
      "channel_shift": begin
        requant_cfg_i.conv_mode = 1;
        requant_cfg_i.requant_mode = 1;
        requant_cfg_i.requant_shift[30+:10] = 32;
        cmd_i.cim_precision = 6;
        cmd_i.cim_macro_en_mask = 8'hff;
      end
      "conv_group": begin
        requant_cfg_i.conv_mode = 1;
        cmd_i.cim_precision = 4;
        cmd_i.cim_macro_en_mask = 8'hff;
        cmd_i.cim_reduce_split_mask = 1;
      end
      "zp_group": begin
        cmd_i.cim_precision = 6;
        cmd_i.cim_macro_en_mask = 8'hff;
        cmd_i.cim_reduce_split_mask = 1;
      end
      default: $fatal(1, "TB: unknown Requant negative scenario");
    endcase
    cmd_valid_i = 1;
    @(posedge clock);
    #1;
    $fatal(1, "TB: missing Requant configuration rejection");
  end
  if ($bits(cluster_ctrl_t) != 107 || $bits(cmd_i.cim_os_cnt) != 8 || $bits(cmd_i.cim_ws_cnt) != 8 || $bits(cmd_i.cim_as_cnt) != 8)
    $fatal(1, "TB: descriptor must contain three eight-bit counts and total 107 bits");
  if ($value$plusargs("ZERO_COUNT=%d", zero_count)) begin
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (2) @(negedge clock);
    $display("[CASE_START] time=%0.3f ns suite=count_range description=reject-zero-count field=%0d", $realtime,
             zero_count);
    cmd_i = '0;
    cmd_i.cim_os_cnt = 1;
    cmd_i.cim_ws_cnt = 1;
    cmd_i.cim_as_cnt = 1;
    case (zero_count)
      0: cmd_i.cim_os_cnt = 0;
      1: cmd_i.cim_ws_cnt = 0;
      2: cmd_i.cim_as_cnt = 0;
      default: $fatal(1, "TB: zero-count field must be 0..2");
    endcase
    cmd_valid_i = 1;
    @(posedge clock);
    #1;
    $fatal(1, "TB: missing zero-count rejection");
  end
  if ($test$plusargs("CONTEXT_CAPACITY_TEST")) begin
    capacity_precision = 1;
    capacity_sign = 0;
    if ($value$plusargs("CAPACITY_PRECISION=%d", capacity_precision)) begin
    end
    if ($value$plusargs("CAPACITY_SIGN=%d", capacity_sign)) begin
    end
    if (capacity_precision < 0 || capacity_precision > 6) $fatal(1, "TB: capacity precision must be 0..6");
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (2) @(negedge clock);
    cmd_i = '0;
    cmd_i.cim_os_cnt = ($test$plusargs("ADDRESS_CAPACITY_TEST") || $test$plusargs("METADATA_CAPACITY_TEST")) ? 1 : 2;
    cmd_i.cim_ws_cnt = 1;
    cmd_i.cim_as_cnt = ($test$plusargs("ADDRESS_CAPACITY_TEST") || $test$plusargs("METADATA_CAPACITY_TEST")) ? 16 : 64;
    capacity_count=int'(cmd_i.cim_as_cnt); capacity_os=int'(cmd_i.cim_os_cnt);
    if ($value$plusargs("CAPACITY_COUNT=%d",capacity_count)) begin end
    if ($value$plusargs("CAPACITY_OS=%d",capacity_os)) begin end
    cmd_i.cim_as_cnt=8'(capacity_count); cmd_i.cim_os_cnt=8'(capacity_os);
    cmd_i.cim_precision = 3'(capacity_precision);
    cmd_i.cim_signed_en = 1'(capacity_sign);
    cmd_i.cim_macro_en_mask = 8'hff;
    cmd_i.cim_macro_oc_mask = 32'hffffffff;
    $display(
      "[CASE_START] time=%0.3f ns suite=context_capacity description=reject-resource-capacity-overflow W%0dA%0d signed=%0d os=%0d ws=1 as=%0d psum_depth=%0d max_contexts=%0d weight_address_depth=%0d",
      $realtime, wbits(capacity_precision), abits(capacity_precision), capacity_sign,
      capacity_os, capacity_count, OUTPUT_BUFFER_DEPTH, MAX_CONTEXTS, WGT_RADDR_BUFFER_DEPTH);
    cmd_valid_i = 1;
    @(posedge clock);
    #1;
    $fatal(1, "TB: missing resource capacity rejection");
  end
  if ($test$plusargs(
      "SRAM_RW_TEST"
    ) || $test$plusargs(
      "SRAM_CONFLICT_WRITE_COMPUTE"
    ) || $test$plusargs(
      "SRAM_CONFLICT_COMPUTE"
    )) begin
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (2) @(negedge clock);
    if ($test$plusargs("SRAM_CONFLICT_WRITE_COMPUTE")) begin
      $display("[CASE_START] time=%0.3f ns suite=sram_negative description=reject-regular-write-during-active-compute", $realtime);
      load_weight_row(0, 8'd0, '0);
      @(negedge clock);
      cmd_i = '0;
      cmd_i.cim_os_cnt = 1; cmd_i.cim_ws_cnt = 1; cmd_i.cim_as_cnt = 1;
      cmd_i.cim_macro_en_mask = 1;
      cmd_i.cim_macro_oc_mask = 1;
      cmd_i.cim_reduce_split_mask = 7'h7f;
      cmd_valid_i = 1;
      @(posedge clock);
      if(!cmd_ready_o) $fatal(1,"SRAM conflict: compute command not accepted");
      @(negedge clock);
      cmd_valid_i = 0;
      // Target idle Macro1 while Macro0 computes: only the Cluster-wide
      // exclusion rule should reject this access, avoiding a competing
      // local SingleMacro simultaneous-read/write diagnostic.
      sram_bank_sel = 1;
      sram_cs_en = 1; sram_wr_en = 1;
      @(posedge clock);
      #1;
      $fatal(1,"Missing SRAM write/active-compute conflict rejection");
    end
    if ($test$plusargs("SRAM_CONFLICT_COMPUTE")) begin
      $display(
        "[CASE_START] time=%0.3f ns suite=sram_negative description=reject-regular-access-overlapping-compute-command",
        $realtime);
      sram_cs_en   = 1;
      cmd_valid_i = 1;
      @(posedge clock);
      #1;
      $fatal(1, "Missing SRAM/compute conflict rejection");
    end
    run_sram_cases();
    $finish;
  end
  if (OS_TILES < 1 || OS_TILES > 14 || PATTERNS < 1 || PATTERNS > 6 || SEED == 0)
    $fatal(1, "Require OS_TILES 1..14 (distinct weight rows), PATTERNS 1..6, nonzero seed");
  for (int mask = 0; mask < 128; mask++) if (canonical(7'(mask))) canonical_count++;
  if (canonical_count != 26) $fatal(1, "Expected 26 canonical trees");
  data_dir = ".";
  if ($value$plusargs("DATA_DIR=%s", data_dir)) begin
  end
  manifest = $fopen($sformatf("%s/split_cases.csv", data_dir), "w");
  operation_trace = $fopen($sformatf("%s/buffer_operations.csv", data_dir), "w");
  external_trace = $fopen($sformatf("%s/external_inputs.csv", data_dir), "w");
  if (!manifest || !operation_trace || !external_trace) $fatal(1, "Cannot open CSV output directory %s", data_dir);
  $fdisplay(external_trace,
            "input_cycle,case,precision,signed_en,tile,command,context,weight_address,act_sample,phase,act_hex");
  $fdisplay(
    operation_trace,
    "compute_cycle,case,precision,signed_en,tile,context,phase,lane,operation,tmp,fusion_a,fusion_b,acc_a,acc_b,result,done,tmp_stored,fusion_cycle");
  $fdisplay(
    manifest,
    "precision,signed_en,split_mask_hex,en_mask_hex,oc_mask_hex,slots_hex,group0_K,group1_K,group2_K,group3_K,group4_K,group5_K,group6_K,group7_K");
  repeat (4) @(negedge clock);
  reset = 0;
  repeat (2) @(negedge clock);
  if ($test$plusargs("SRAM_RESPONSE_TEST")) begin
    run_sram_response_suite();
    $finish;
  end
  // 专项 suite 独占一次仿真；默认 suite 另有 CSV、路由和门控覆盖检查。
  if ($test$plusargs("CONTEXT_BUFFER_TEST")) begin
    run_context_buffer_suite();
    $finish;
  end
  if ($test$plusargs("REQUANT_CONTEXT_TEST")) begin
    run_requant_context_suite();
    $finish;
  end
  if ($test$plusargs("REQUANT_BOUNDARY_TEST")) begin
    run_requant_boundary_suite();
    $finish;
  end
  if ($test$plusargs("REQUANT_RESET_TEST")) begin
    run_requant_reset_suite();
    $finish;
  end
  if ($test$plusargs("REQUANT_TEST")) begin
    run_requant_suite();
    $finish;
  end
  if ($test$plusargs("REQUANT_CHANNEL_TEST")) begin
    run_requant_channel_suite();
    $finish;
  end
  if ($test$plusargs("INPUT_OVERLAP_TEST")) begin
    run_input_overlap_suite();
    $finish;
  end
  if ($test$plusargs("OS_COUNT_LIMIT_TEST")) begin
    run_os_count_limit_suite();
    $finish;
  end
  if ($test$plusargs("CONTEXT_STRESS_TEST")) begin
    run_context_stress_suite();
    $finish;
  end
  if ($test$plusargs("OC_MERGE_TEST")) begin
    run_oc_merge_suite();
    $finish;
  end
  if ($test$plusargs("ACT_BUFFER_TEST")) begin
    run_act_buffer_suite();
    $finish;
  end
  if ($test$plusargs("FULL_ACT_TEST")) begin
    run_full_act_suite();
    $finish;
  end
  if ($test$plusargs("MIXED_CONTEXT_TEST")) begin
    run_mixed_context_suite();
    $finish;
  end
  run_default_suite();
  $fclose(manifest);
  $fclose(operation_trace);
  $fclose(external_trace);
  if (reuse_cycles == 0) $fatal(1, "Missing coverage: reuse=%0d", reuse_cycles);
  for (int n = 1; n < 7; n++) begin
    if (dut.u_reduce.gated_checks[n] == 0) $fatal(1, "No gated hold checks for node %0d", n);
    $display("CG node=t%0d active_edges=%0d gated_OC_checks=%0d", n, dut.u_reduce.active_edges[n],
             dut.u_reduce.gated_checks[n]);
  end
  if(dut.tmp_only_steps==0 || dut.as_seed_steps==0 || dut.as_fusion_steps==0 ||
       dut.as_acc_steps==0 || dut.ws_fusion_steps==0 || dut.ws_acc_steps==0 ||
       dut.ws_tile_commits==0 || dut.a4_acc_steps==0)
    $fatal(1, "Missing tmp/fusion/acc routing coverage");
  $display(
    "TMP_ROUTES os1=%0d AS_seed=%0d AS_fusion=%0d AS_acc=%0d WS_fusion=%0d WS_acc=%0d WS_tile_commit=%0d A4_acc=%0d",
    dut.tmp_only_steps, dut.as_seed_steps, dut.as_fusion_steps, dut.as_acc_steps, dut.ws_fusion_steps,
    dut.ws_acc_steps, dut.ws_tile_commits, dut.a4_acc_steps);
  if (buffer_gate_checks == 0 || bypass_psum_hold_checks == 0 || (OUTPUT_BUFFER_DEPTH > 2 && high_depth_checks == 0))
    $fatal(1, "Missing buffer gate checks");
  $display("BUFFER_ICG checks=%0d high_depth=%0d bypass_Psum_hold=%0d depth=%0d", buffer_gate_checks,
           high_depth_checks, bypass_psum_hold_checks, OUTPUT_BUFFER_DEPTH);
  $display("PASS configurations=%0d cases=%0d reuse=%0d seed=%08h", configurations, cases_run, reuse_cycles, SEED);
`ifdef CLUSTER_FSDB
  $fsdbDumpoff;
`endif
  $finish;
end
initial begin
  #200000000;
  $fatal(1, "Global watchdog");
end
