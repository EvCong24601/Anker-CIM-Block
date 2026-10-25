task automatic load_as_gemm_os1_ws32_w8a16_vectors();
  int fd, status, k0, n0;
  longint signed dot, weight_sum;
  if (!$value$plusargs("GEMM_DATA_DIR=%s", data_dir)) $fatal(1, "AS GEMM: require +GEMM_DATA_DIR=PATH");
  fd = $fopen({data_dir, "/requant_params.txt"}, "r");
  if (!fd) $fatal(1, "AS GEMM: cannot open parameters");
  status = $fscanf(fd, "%d %d %d %d", multiplier, shift, output_zp, act_zp);
  $fclose(fd);
  if (status != 4 || act_zp == 0) $fatal(1, "AS GEMM: malformed or symmetric ACT parameters");
  $readmemh({data_dir, "/x_q.hex"}, x_q);
  $readmemh({data_dir, "/w_q.hex"}, w_q);
  $readmemh({data_dir, "/raw_golden.hex"}, raw_golden);
  $readmemh({data_dir, "/centered_golden.hex"}, centered_golden);
  $readmemh({data_dir, "/quant_golden.hex"}, quant_golden);
  $readmemh({data_dir, "/requant_zp.hex"}, zp);
  if ($test$plusargs("PER_CHANNEL_SCALE")) begin
    $readmemh({data_dir, "/requant_multiplier.hex"}, channel_multiplier);
    $readmemh({data_dir, "/requant_shift.hex"}, channel_shift);
  end
  $readmemh({data_dir, "/weight_rows.hex"}, weight_rows);
  $readmemh({data_dir, "/act_planes.hex"}, act_planes);
  $readmemh({data_dir, "/psum_history_golden.hex"}, history_golden);
  for (int m = 0; m < M; m++)
    for (int n = 0; n < N; n++) begin
      dot = 0;
      weight_sum = 0;
      for (int k = 0; k < K; k++) begin
        dot += longint'($signed(x_q[m*K+k])) * longint'($signed(w_q[k*N+n]));
        weight_sum += longint'($signed(w_q[k*N+n]));
      end
      if (raw_golden[m*N+n] !== 32'(dot) || centered_golden[m*N+n] !== 32'(dot - longint'(act_zp) * weight_sum))
        $fatal(1, "AS GEMM: unpacked matrix golden mismatch m=%0d n=%0d", m, n);
    end
  for (int tile = 0; tile < 2; tile++)
    for (int cx = 0; cx < 4; cx++)
      for (int macro = 0; macro < 8; macro++) begin
        k0 = tile * 256 + macro * 32;
        n0 = cx * 4;
        for (int oc = 0; oc < 4; oc++)
        for (int j = 0; j < 32; j++)
        if (weight_rows[(tile*4+cx)*8+macro][256*oc+8*j+:8] !== w_q[(k0+j)*N+n0+oc])
          $fatal(1, "AS GEMM: weight packing mismatch tile=%0d ctx=%0d macro=%0d", tile, cx, macro);
      end
  for (int m = 0; m < M; m++)
    for (int tile = 0; tile < 2; tile++)
      for (int ph = 0; ph < 4; ph++)
        for (int j = 0; j < 256; j++)
          if (act_planes[(m*2+tile)*4+ph][4*j+:4] !== x_q[m*K+tile*256+j][4*ph+:4])
            $fatal(1, "AS GEMM: ACT packing mismatch m=%0d tile=%0d slice=%0d", m, tile, ph);
endtask

task automatic load_as_weights();
  for (int address = 0; address < 8; address++)
    for (int macro = 0; macro < 8; macro++) begin
      @(negedge clock);
      sram_cs_en = 1;
      sram_wr_en = 1;
      sram_row_addr = BASE_ADDR + 8'(address);
      sram_macro_group = 1'(macro / 4);
      sram_bank_sel = 2'(macro % 4);
      sram_wrdata = weight_rows[address*8+macro];
      $display(
        "[WEIGHT_WRITE] time=%0.3f ns description=OS2-AS4-weight-layout k_tile=%0d ctx=%0d macro=%0d address=0x%02h",
        $realtime, address / 4, address % 4, macro, sram_row_addr);
    end
  @(negedge clock);
  sram_wr_en = 0;
  for (int address = 0; address < 8; address++)
    for (int macro = 0; macro < 8; macro++) begin
      sram_row_addr = BASE_ADDR + 8'(address);
      sram_macro_group = 1'(macro / 4);
      sram_bank_sel = 2'(macro % 4);
      @(posedge clock);
      #1;
      if (!sram_rd_valid || sram_rd_data !== weight_rows[address*8+macro]) $fatal(1, "AS GEMM: SRAM readback mismatch");
      @(negedge clock);
    end
  sram_cs_en = 0;
endtask

task automatic select_as_zp(input int tile, cx);
  requant_cfg_i = '0;
  requant_cfg_i.requant_multiplier = 32'(multiplier);
  requant_cfg_i.requant_shift = 10'(shift);
  if ($test$plusargs("PER_CHANNEL_SCALE")) begin
    requant_cfg_i.conv_mode = 1;
    requant_cfg_i.requant_mode = 1;
    for (int oc = 0; oc < 4; oc++) begin
      requant_cfg_i.requant_multiplier[32*oc+:32] = channel_multiplier[4*cx+oc];
      requant_cfg_i.requant_shift[10*oc+:10] = channel_shift[4*cx+oc];
    end
  end
  if ($test$plusargs("NEGATIVE_SCALE_RELOAD") && tile == 1 && cx == 1)
    requant_cfg_i.requant_multiplier[0] = ~requant_cfg_i.requant_multiplier[0];
  for (int oc = 0; oc < 4; oc++) begin
    requant_cfg_i.requant_zp[32*oc+:32] = zp[4*cx+oc];
  end
  if ($test$plusargs("NEGATIVE_ZP_RELOAD") && tile == 1 && cx == 1)
    requant_cfg_i.requant_zp[0] = ~requant_cfg_i.requant_zp[0];
endtask

task automatic send_as_row(input int m);
  cmd_i = '0;
  cmd_i.cim_os_cnt = 2;
  cmd_i.cim_as_cnt = 4;
  cmd_i.cim_ws_cnt = 1;
  cmd_i.cim_precision = 6;
  cmd_i.cim_signed_en = 1;
  cmd_i.cim_reduce_split_mask = 0;
  cmd_i.cim_macro_en_mask = 8'hff;
  cmd_i.cim_macro_oc_mask = 32'hffffffff;
  cmd_i.cim_act_slot_sel = 24'hfac688;
  for (int tile = 0; tile < 2; tile++) begin
    // 17 external edges per K Tile: four Commands+Planes, then thirteen
    // idle input cycles while the saved ACT is replayed across Contexts.
    for (int t = 0; t < 17; t++) begin
      @(negedge clock);
      if (t < 4) begin
        cmd_valid_i = 1;
        cmd_i.cim_weight_raddr = BASE_ADDR + 8'(4 * tile + t);
        select_as_zp(tile, t);
        act_data_i = act_planes[(m*2+tile)*4+t];
        $display(
          "[CMD_SEND] time=%0.3f ns description=AS-address-and-ACT-overlap m=%0d k_tile=%0d ctx=%0d slice=%0d address=0x%02h",
          $realtime, m, tile, t, t, cmd_i.cim_weight_raddr);
      end else begin
        cmd_valid_i = 0;
        act_data_i  = '1;
      end
      @(posedge clock);
      if (t < 4 && !cmd_ready_o) $fatal(1, "AS GEMM: Command not accepted at its planned edge");
      #1;
    end
  end
endtask
