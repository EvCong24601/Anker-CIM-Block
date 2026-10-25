// 常规 SRAM case：独立逐字节镜像、全部掩码、隔离/保持、复位及写后计算。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

function automatic logic [1023:0] sram_pattern(int m, int a, int salt);
  logic [1023:0] row;
  for (int b = 0; b < 128; b++) row[8*b+:8] = 8'(m * 37 + a * 13 + b * 7 + salt);
  return row;
endfunction
task automatic sram_write(int m, int a, logic [1023:0] data, logic [3:0] mask, bit selected = 1);
  // 下降沿驱动，上升沿提交；镜像按字节更新，1-mask 的 32 B 不改动。
  $display(
    "[CASE_START] time=%0.3f ns suite=sram_write case=%0d description=32B-active-high-mask/write-isolation macro=%0d row=%0d mask=%h cs=%0d",
    $realtime, sram_write_cases, m, a, mask, selected);
  @(negedge clock);
  sram_cs_en = selected;
  sram_wr_en = 1;
  sram_macro_group = 1'(m / 4);
  sram_bank_sel = 2'(m % 4);
  sram_row_addr = 8'(a);
  sram_wrdata = data;
  sram_wmask = mask;
  @(posedge clock);
  #0.002;
  for (int b = 0; b < 128; b++) if (selected && !mask[b/32]) sram_reference[m][a][8*b+:8] = data[8*b+:8];
  @(negedge clock);
  sram_cs_en = 0;
  sram_wr_en = 0;
  sram_write_cases++;
endtask
task automatic sram_read_check(int m, int a, logic [3:0] mask = 0);
  // 同步读：上升沿采样地址，沿后比较完整 128 B。
  // 不读取 DUT.mem 作为 golden，避免地址译码错误被同源参考掩盖。
  $display(
    "[CASE_START] time=%0.3f ns suite=sram_read case=%0d description=full-row-read/macro-row-isolation/read-ignores-mask macro=%0d row=%0d mask=%h",
    $realtime, sram_read_checks, m, a, mask);
  @(negedge clock);
  sram_cs_en = 1;
  sram_wr_en = 0;
  sram_macro_group = 1'(m / 4);
  sram_bank_sel = 2'(m % 4);
  sram_row_addr = 8'(a);
  sram_wmask = mask;
  @(posedge clock);
  #1;
  if (!sram_rd_valid || sram_rd_data !== sram_reference[m][a])
    $fatal(1, "SRAM read mismatch macro=%0d row=%0d mask=%h", m, a, mask);
  if (cmd_ready_o !== 0) $fatal(1, "Command ready during regular SRAM access");
  sram_read_checks++;
  @(negedge clock);
  sram_cs_en = 0;
  #0.002;
  if (!sram_rd_valid || sram_rd_data !== sram_reference[m][a])
    $fatal(1, "Read response changed when request CS dropped");
  @(posedge clock);
  #0.002;
  if (sram_rd_valid || sram_rd_data !== 0) $fatal(1, "Read valid did not drain on idle edge");
endtask
task automatic sram_compute_check(bit patched);
  // 用实际 W4A4 结果核对 Hold：被修改的 Macro5.OC1 为 128，其余为 64。
  int received;
  $display("[CASE_START] time=%0.3f ns suite=sram_compute description=write-to-compute/Hold-refresh W4A4 patched=%0d",
           $realtime, patched);
  @(negedge clock);
  cmd_i = '0;
  cmd_i.cim_os_cnt = 1;
  cmd_i.cim_ws_cnt = 1;
  cmd_i.cim_as_cnt = 1;
  cmd_i.cim_reduce_split_mask = 7'h7f;
  cmd_i.cim_macro_en_mask = 8'hff;
  cmd_i.cim_macro_oc_mask = 32'hffffffff;
  cmd_i.cim_weight_raddr = 8'd7;
  cmd_i.cim_precision = 3'd2;  // W4A4, 64 weights per OC, UINT
  act_data_i = {256{4'h1}};
  cmd_valid_i = 1;
  do begin
    @(posedge clock);
  end while (!cmd_ready_o);
  @(negedge clock);
  cmd_valid_i = 0;
  received = 0;
  repeat (30) begin
    @(negedge clock);
    for (int l = 0; l < 32; l++)
    if (out_valid_o[l]) begin
      if ($signed(psum_data_o[32*l+:32]) != ((patched && l == 21) ? 128 : 64))
        $fatal(1, "SRAM write-to-compute mismatch lane=%0d patched=%0d", l, patched);
      received++;
    end
    if (received == 32 && !dut.batch_active) break;
  end
  if (received != 32) $fatal(1, "SRAM compute did not publish exactly 32 channels");
  repeat (3) @(negedge clock);
endtask
task automatic run_sram_cases;
  // 场景顺序：全地址 -> 全掩码/隔离 -> 片选关闭 -> 连续写 -> 复位保留
  //           -> 逐 Macro 写入/读回 -> 写后计算/Hold 失效与全屏蔽保持。
  int a;
  logic [7:0] saved_hold;
  // Every physical address and Macro has a distinct complete row.
  for (int m = 0; m < 8; m++) for (int row = 0; row < 256; row++) sram_write(m, row, sram_pattern(m, row, 0), 4'h0);
  for (int m = 0; m < 8; m++) for (int row = 0; row < 256; row++) sram_read_check(m, row);
  // All masks at low/high and interior addresses; verify all other Macros.
  for (int m = 0; m < 8; m++)
    for (int boundary = 0; boundary < 4; boundary++) begin
      case (boundary)
        0: a = 0;
        1: a = 1;
        2: a = 127;
        default: a = 255;
      endcase
      for (int mask = 0; mask < 16; mask++) begin
        sram_write(m, a, sram_pattern(m, a, mask + 91), 4'(mask));
        for (int other = 0; other < 8; other++) sram_read_check(other, a, 4'(mask));
      end
    end
  // With CS low writes must have no effect; read ignores all 16 masks.
  for (int m = 0; m < 8; m++) begin
    sram_write(m, 0, '1, 4'h0, 0);
    for (int mask = 0; mask < 16; mask++) sram_read_check(m, 0, 4'(mask));
  end
  // Back-to-back writes change Macro, group, row and mask on every cycle.
  for (int n = 0; n < 32; n++) begin
    $display(
      "[CASE_START] time=%0.3f ns suite=sram_back_to_back case=%0d description=consecutive-writes/change-macro-row-mask",
      $realtime, n);
    @(negedge clock);
    sram_cs_en = 1;
    sram_wr_en = 1;
    sram_macro_group = 1'((n % 8) / 4);
    sram_bank_sel = 2'(n % 4);
    sram_row_addr = 8'(200 + n / 8);
    sram_wmask = 4'(n % 16);
    sram_wrdata = sram_pattern(n % 8, 200 + n / 8, n + 171);
    @(posedge clock);
    #0.002;
    for (int b = 0; b < 128; b++) if (!sram_wmask[b/32]) sram_reference[n%8][200+n/8][8*b+:8] = sram_wrdata[8*b+:8];
    sram_write_cases++;
  end
  @(negedge clock);
  sram_cs_en = 0;
  sram_wr_en = 0;
  // Reset must preserve all initialized SRAM, including masked neighbors.
  $display("[CASE_START] time=%0.3f ns suite=sram_reset description=reset-retains-all-8x256-rows", $realtime);
  reset = 1;
  repeat (3) @(negedge clock);
  reset = 0;
  for (int m = 0; m < 8; m++) for (int row = 0; row < 256; row++) sram_read_check(m, row);
  // Per-Macro writes and public readback share the same addressed storage.
  $display("[CASE_START] time=%0.3f ns suite=sram_row_load description=regular-write-and-readback-all-macros",
           $realtime);
  for (int m = 0; m < 8; m++) sram_write(m, 8, sram_pattern(m, 8, 231), 4'h0);
  for (int m = 0; m < 8; m++) sram_read_check(m, 8);
  for (int m = 0; m < 8; m++) sram_write(m, 7, {128{8'h11}}, 4'h0);
  sram_compute_check(0);
  saved_hold = dut.hold_valid;
  sram_read_check(5, 8);
  if (dut.hold_valid !== saved_hold || dut.hold_addr[5] !== 8)
    $fatal(1, "Ordinary read did not retag the selected Macro SRAM output");
  sram_compute_check(0); // Macro5 must refresh Row7 rather than reuse Row8.
  sram_write(5, 7, {128{8'h22}}, 4'b1101);  // only OC1 changes
  if (dut.hold_valid !== 8'hdf) $fatal(1, "Masked write did not invalidate only Macro5 Hold");
  sram_compute_check(1);
  sram_write(5, 7, '1, 4'hf);
  if (dut.hold_valid !== 8'hff) $fatal(1, "All-masked write invalidated Hold");
  sram_read_check(5, 7);
  sram_compute_check(1);
  $display("PASS sram_rw writes=%0d reads=%0d masks=16 macros=8 rows=256 compute=4", sram_write_cases,
           sram_read_checks);
endtask
