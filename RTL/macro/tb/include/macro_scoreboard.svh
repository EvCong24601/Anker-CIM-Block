// 逐 OC 写镜像、Hold 与单拍结果检查；上升沿采样请求，NBA 后核对输出。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

always @(posedge clock or posedge reset) begin : scoreboard
  logic [1023:0] row;
  if (reset) begin
    for (int i = 0; i < EXPECTED_LATENCY; i++) if (expected_valid[i] === 1'b1) cancelled_count++;
    expected_valid = '0;
    for (int i = 0; i <= EXPECTED_LATENCY; i++) begin
      expected_data[i]  = '0;
      expected_mask[i]  = '0;
      expected_phase[i] = '0;
    end
    last_data = 0;
    last_mask = 0;
    last_phase = 0;
    reference_hold_valid = 0;
    pending_refresh = 0;
  end else if (!negative_mode) begin
    cycle_count++;
    // Commit a previous refresh at its completion edge, BEFORE checking
    // this edge's new reuse. Reset cancels a pending refresh above.
    if (pending_refresh) begin
      reference_hold = pending_hold_row;
      reference_hold_address = pending_hold_address;
      reference_hold_valid = 1;
    end
    pending_refresh = 0;
    for (int i = EXPECTED_LATENCY; i > 0; i--) begin
      expected_valid[i] = expected_valid[i-1];
      expected_data[i]  = expected_data[i-1];
      expected_mask[i]  = expected_mask[i-1];
      expected_phase[i] = expected_phase[i-1];
    end
    expected_valid[0] = cim_ren && (|cim_oc_mask);
    if (sram_wen) begin
      for (int b = 0; b < 128; b++) if (!sram_wmask[b/32]) reference_memory[sram_waddr][8*b+:8] = sram_wdata[8*b+:8];
      if (!(&sram_wmask)) reference_hold_valid = 0;
    end
    if (expected_valid[0]) begin
      accepted_count++;
      if (cim_station) begin
        row = reference_memory[cim_raddr];
        pending_hold_row = row;
        pending_hold_address = cim_raddr;
        pending_refresh = 1;
      end else begin
        if (!reference_hold_valid || cim_raddr != reference_hold_address)
          $fatal(1, "TB: legal stimulus reused invalid reference hold");
        row = reference_hold;
      end
      expected_data[0]  = golden_phase(row, cim_idata, cim_precision, cim_signed_en, cim_phase, cim_oc_mask);
      expected_mask[0]  = cim_oc_mask;
      expected_phase[0] = cim_phase;
    end else if (cim_ren) zero_mask_count++;
    else bubble_count++;
    #1;
    if (cim_odata_valid !== expected_valid[EXPECTED_LATENCY])
      $fatal(
        1,
        "TB: latency/valid mismatch cycle=%0d expected=%b got=%b",
        cycle_count,
        expected_valid[EXPECTED_LATENCY],
        cim_odata_valid
      );
    if (expected_valid[EXPECTED_LATENCY]) begin
      result_count++;
      for (int c = 0; c < 4; c++)
      if (expected_mask[EXPECTED_LATENCY][c]) last_data[18*c+:18] = expected_data[EXPECTED_LATENCY][18*c+:18];
      last_mask  = expected_mask[EXPECTED_LATENCY];
      last_phase = expected_phase[EXPECTED_LATENCY];
    end
    if (cim_odata !== last_data || cim_odata_oc_mask !== last_mask || cim_odata_phase !== last_phase)
      $fatal(
        1,
        "TB: data/tag/hold mismatch cycle=%0d expected=%h/%h/%h got=%h/%h/%h",
        cycle_count,
        last_data,
        last_mask,
        last_phase,
        cim_odata,
        cim_odata_oc_mask,
        cim_odata_phase
      );
  end
end
